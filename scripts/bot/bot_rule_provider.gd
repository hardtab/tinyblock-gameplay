class_name BotRuleProvider
extends BotDecisionProvider

const DigPlanner = preload("res://gameplay/scripts/bot/bot_dig_planner.gd")

var _rng := RandomNumberGenerator.new()
var _build_step := 0
var _last_build_msec := -1

const PREFERRED_PLAYER_DISTANCE := 84.0
const WANDER_RADIUS := 96.0
const WANDER_COMMIT_MSEC := 1800
const BOW_ARROW_MIN_SPEED := 250.0
const BOW_ARROW_MAX_SPEED := 560.0
const BOW_ARROW_GRAVITY := 310.0
const CREATURE_DANGER_RADIUS := 224.0
const BUILD_ACTION_COOLDOWN_MSEC := 8_000
const GENERIC_OUTPUTS := ["planks", "palm_planks", "pine_planks", "weeping_planks", "stone", "cobblestone", "workbench", "chest", "furnace", "glass", "stone_bricks"]


func _init(seed: int = 0) -> void:
	if seed == 0:
		_rng.randomize()
	else:
		_rng.seed = seed


func provider_name() -> String:
	return "rules"


func decide(observation: Dictionary) -> Dictionary:
	var legal := Contract.normalize_legal_actions(observation.get("legal_actions", Contract.ALL_ACTIONS))
	if legal.is_empty():
		legal = PackedStringArray([Contract.ACTION_WAIT])
	if bool(observation.get("pvp_world", false)) and not bool(observation.get("duel_started", true)):
		return _decision(Contract.GOAL_SELF_DEFENSE, Contract.ACTION_WAIT, {}, 700, 0.99)
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	var health := int(self_state.get("health", 10))
	var max_health := maxi(1, int(self_state.get("max_health", 10)))
	var low_health := float(health) / float(max_health) <= 0.35

	# Immediate survival has priority over social or gathering behaviour.
	var threats: Array = _as_array(observation.get("threats", []))
	var creature_threat := _dangerous_creature_threat(observation, threats)
	var arrow_cover := _incoming_arrow_cover_decision(observation)
	if not arrow_cover.is_empty() and Contract.ACTION_PLACE in legal:
		return arrow_cover
	if low_health and not creature_threat.is_empty() and Contract.ACTION_FLEE_FROM in legal:
		return _decision(Contract.GOAL_SURVIVE, Contract.ACTION_FLEE_FROM, creature_threat, 1600, 0.96)

	# Hostile creatures are an immediate survival concern even while the bot is
	# still at full health.  The old policy only fled when health was already low
	# and otherwise let crafting, following, or a mining tool win the decision;
	# that made an attacking animal look harmless until the first hit landed.
	if not creature_threat.is_empty():
		var creature_distance := float(creature_threat.get("distance", 9999.0))
		var combat_tool := _creature_combat_tool(observation)
		if not combat_tool.is_empty() and Contract.ACTION_EQUIP in legal:
			return _decision(Contract.GOAL_SURVIVE, Contract.ACTION_EQUIP, {"id": combat_tool}, 350, 0.98)
		var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
		var hand := str(equipment.get("hand", ""))
		var inventory := _inventory(observation)
		var bow_ready := hand.to_lower() == "bow" and int(inventory.get("arrow", 0)) > 0
		var bow_distance := float(observation.get("bow_attack_distance", 320.0))
		if bow_ready and creature_distance <= bow_distance and Contract.ACTION_FIRE_BOW in legal:
			return _creature_bow_decision(observation, creature_threat)
		if creature_distance <= float(observation.get("creature_attack_distance", 48.0)) and Contract.ACTION_ATTACK_CREATURE in legal and _is_melee_weapon(hand):
			return _decision(Contract.GOAL_SURVIVE, Contract.ACTION_ATTACK_CREATURE, creature_threat, 500, 0.92)
		if Contract.ACTION_FLEE_FROM in legal:
			return _decision(Contract.GOAL_SURVIVE, Contract.ACTION_FLEE_FROM, creature_threat, 1200, 0.97)

	# The safety policy writes an explicit, short-lived retaliation grant into
	# the observation.  The rule provider never infers an attacker from nearby
	# players and never emits a generic player attack.
	var defense: Dictionary = observation.get("self_defense", {}) if observation.get("self_defense", {}) is Dictionary else {}
	var attacker_id := str(defense.get("attacker_player_id", ""))
	if not attacker_id.is_empty() and bool(defense.get("can_retaliate", false)) and Contract.ACTION_RETALIATE_ONCE in legal:
		return _decision(Contract.GOAL_SELF_DEFENSE, Contract.ACTION_RETALIATE_ONCE, {"id": attacker_id}, 700, 0.99)

	var social_target: Dictionary = _first_dictionary(_as_array(observation.get("players", [])))
	var social_target_id := str(social_target.get("id", observation.get("social_target_id", "")))
	var social_distance := float(social_target.get("distance", 9999.0))
	var preferred_distance := float(observation.get("preferred_player_distance", PREFERRED_PLAYER_DISTANCE))
	var welcome_emoji := str(observation.get("social_emoji", ""))
	var bridge_step := _approach_bridge_step(observation, social_target)
	# A pending wave should wait until the bot can actually reach the player.
	# Crossing the gap comes first; the same emoji stays available next decision.
	var social_bridge_ready := (
		not bridge_step.is_empty()
		and str(bridge_step.get("goal", "")) == Contract.GOAL_SOCIAL_FOLLOW
		and Contract.ACTION_PLACE in legal
	)
	if not welcome_emoji.is_empty() and Contract.ACTION_SEND_EMOJI in legal and not social_bridge_ready:
		return _decision(Contract.GOAL_SOCIAL_FOLLOW, Contract.ACTION_SEND_EMOJI, {"id": social_target_id, "emoji": welcome_emoji}, 500, 0.78)

	# Duel arenas provide a shared battle chest. Loot it before committing to the
	# pinned opponent: otherwise the bot can start the match empty-handed and
	# never get a chance to equip the bow, weapon, pickaxe, footwear, or blocks.
	var pvp_chest := _pvp_loadout_container(observation)
	if not pvp_chest.is_empty() and bool(observation.get("pvp_world", false)) and not bool(observation.get("pvp_chest_opened", false)) and not _has_pvp_loadout(observation):
		if bool(pvp_chest.get("reachable", false)) and Contract.ACTION_OPEN_CONTAINER in legal:
			return _decision(Contract.GOAL_SELF_DEFENSE, Contract.ACTION_OPEN_CONTAINER, pvp_chest, 900, 0.98)
		if not _has_pvp_loadout(observation) and Contract.ACTION_MOVE_TO in legal:
			return _decision(Contract.GOAL_SELF_DEFENSE, Contract.ACTION_MOVE_TO, pvp_chest, 1800, 0.94)

	if not bridge_step.is_empty() and Contract.ACTION_PLACE in legal:
		return Contract.normalize_decision(bridge_step)

	# Equip battle gear before choosing the combat action. The pvp-aware helper
	# keeps the bot from cycling through every tool after the chest is looted.
	var equip_target := _equipable_tool(observation)
	if not equip_target.is_empty() and Contract.ACTION_EQUIP in legal:
		return _decision(Contract.GOAL_SELF_DEFENSE, Contract.ACTION_EQUIP, {"id": equip_target}, 350, 0.96)

	# A bow is a deliberate ranged activity.  In a PvP world the enemy is
	# pinned for the lifetime of the session; outside PvP, only hostile creatures
	# are valid targets so nearby players are never attacked unsolicited.
	var ranged_target := _ranged_target(observation)
	if not ranged_target.is_empty() and Contract.ACTION_FIRE_BOW in legal:
		var self_position := Contract.target_position(self_state)
		var target_position := Contract.target_position(ranged_target)
		# Arrow physics applies gravity after release. Aim at the player's center
		# with a ballistic compensation instead of pointing at the stale top-left
		# snapshot coordinate; otherwise long shots consistently pass underneath.
		var relative_target := (target_position + Vector2(10.0, 14.0)) - (self_position + Vector2(10.0, 11.76))
		var direction := bow_aim_direction(relative_target, 1.0)
		return _decision(
			Contract.GOAL_SELF_DEFENSE if bool(observation.get("pvp_world", false)) else Contract.GOAL_SURVIVE,
			Contract.ACTION_FIRE_BOW,
			ranged_target.merged({"direction": [direction.x, direction.y], "charge": 1.0}),
			650,
			0.9,
		)

	# A duel has one permanent opponent. If the bot has no bow (or the target is
	# already in melee range), close the distance and keep attacking that player
	# until the authoritative duel result ends the session.
	var pvp_target := _pvp_target(observation)
	if not pvp_target.is_empty():
		var pvp_distance := float(pvp_target.get("distance", 9999.0))
		var melee_distance := float(observation.get("retaliation_distance", 52.0))
		if pvp_distance <= melee_distance and Contract.ACTION_ATTACK_PLAYER in legal:
			return _decision(Contract.GOAL_SELF_DEFENSE, Contract.ACTION_ATTACK_PLAYER, pvp_target, 550, 0.98)
		if Contract.ACTION_MOVE_TO in legal:
			return _decision(Contract.GOAL_SELF_DEFENSE, Contract.ACTION_MOVE_TO, pvp_target, 1800, 0.94)

	var craft_target := _craftable_output(observation)
	if not craft_target.is_empty() and Contract.ACTION_CRAFT in legal:
		return _decision(Contract.GOAL_ACHIEVEMENT, Contract.ACTION_CRAFT, {"id": craft_target}, 700, 0.9)
	if not threats.is_empty() and Contract.ACTION_ATTACK_CREATURE in legal:
		var creature := _first_dictionary(threats)
		if float(creature.get("distance", 9999.0)) <= float(observation.get("creature_attack_distance", 48.0)):
			return _decision(Contract.GOAL_SURVIVE, Contract.ACTION_ATTACK_CREATURE, creature, 500, 0.78)

	# When a player or a valuable resource is just beyond a solid column, make
	# one safe excavation/step action before falling back to ordinary movement.
	# The planner is intentionally after equip and combat priorities, so it only
	# digs with a tool already in hand and never tunnels while under threat.
	var dig_step := DigPlanner.next_step(observation)
	if not dig_step.is_empty():
		var dig_action := str(dig_step.get("action", ""))
		if dig_action in legal:
			return Contract.normalize_decision(dig_step)

	var resources: Array = _as_array(observation.get("visible_resources", []))
	if not resources.is_empty() and Contract.ACTION_MINE in legal:
		var resource := _best_resource(resources, observation)
		if not resource.is_empty():
			var mining_tool := _mining_tool_for_target(observation, resource)
			if not mining_tool.is_empty() and Contract.ACTION_EQUIP in legal:
				return _decision(Contract.GOAL_GATHER, Contract.ACTION_EQUIP, {"id": mining_tool}, 350, 0.94)
			if bool(resource.get("reachable", false)):
				if _has_required_mining_tier(observation, resource):
					return _decision(Contract.GOAL_GATHER, Contract.ACTION_MINE, resource, 2200, 0.88)
			if Contract.ACTION_MOVE_TO in legal:
				return _decision(Contract.GOAL_GATHER, Contract.ACTION_MOVE_TO, resource, 2200, 0.7)

	var containers: Array = _as_array(observation.get("visible_containers", []))
	if not containers.is_empty() and Contract.ACTION_OPEN_CONTAINER in legal:
		for raw_container in containers:
			if not raw_container is Dictionary:
				continue
			var container := raw_container as Dictionary
			# The PvP battle chest is a one-shot loadout action. Once its request
			# is in flight, do not route it through this generic container pass and
			# issue the same command again while inventory sync is travelling back.
			if bool(observation.get("pvp_world", false)) and bool(observation.get("pvp_chest_opened", false)) and str(container.get("kind", "")) == "chest":
				continue
			if bool(container.get("reachable", false)):
				return _decision(Contract.GOAL_ACHIEVEMENT, Contract.ACTION_OPEN_CONTAINER, container, 900, 0.76)

	# Building is a low-frequency background activity.  Resource gathering and
	# containers always win first; otherwise the bot can place dirt on top of the
	# same local mining target and look idle while it repeats PLACE commands.
	var build_target := _build_target(observation)
	if not build_target.is_empty() and Contract.ACTION_PLACE in legal:
		return _decision(Contract.GOAL_BUILD, Contract.ACTION_PLACE, build_target, 700, 0.61)

	# Social proximity is a context, not the bot's whole job.  Only follow after
	# the nearby achievement, gathering, and building opportunities have been
	# checked; otherwise a player standing beside the bot would starve all useful
	# actions and leave the avatar idling at their shoulder.
	if not social_target_id.is_empty() and social_distance > preferred_distance:
		if Contract.ACTION_MOVE_NEAR_PLAYER in legal:
			return _decision(Contract.GOAL_SOCIAL_FOLLOW, Contract.ACTION_MOVE_NEAR_PLAYER, social_target, 2400, 0.58)
		if Contract.ACTION_FOLLOW in legal:
			return _decision(Contract.GOAL_SOCIAL_FOLLOW, Contract.ACTION_FOLLOW, social_target, 2400, 0.58)

	# Do not freeze once the bot has reached the comfortable social distance.
	# Small, non-combat wander steps make the avatar feel alive while keeping it
	# separate from real players and away from unsolicited PvP.  A high but not
	# guaranteed probability gives the next decision a chance to pick up a newly
	# visible resource or recipe instead of repeating a patrol forever.
	if Contract.ACTION_MOVE_TO in legal and _rng.randf() < 0.72:
		return _decision(Contract.GOAL_EXPLORE, Contract.ACTION_MOVE_TO, _wander_target(self_state), WANDER_COMMIT_MSEC, 0.55)

	if Contract.ACTION_LOOK_AT in legal and not social_target_id.is_empty() and _rng.randf() < 0.28:
		return _decision(Contract.GOAL_SOCIAL_FOLLOW, Contract.ACTION_LOOK_AT, social_target, 700, 0.51)
	if Contract.ACTION_WAIT in legal:
		return _decision(Contract.GOAL_IDLE, Contract.ACTION_WAIT, {}, _rng.randi_range(700, 1800), 0.45)
	return _decision(Contract.GOAL_IDLE, str(legal[0]), {}, 500, 0.2)


func _decision(goal: String, action: String, target: Dictionary, commit_for_ms: int, confidence: float) -> Dictionary:
	var decision := {
		"goal": goal,
		"action": action,
		"target_id": str(target.get("id", "")),
		"target": target.duplicate(true),
		"emoji": str(target.get("emoji", "")),
		"commit_for_ms": commit_for_ms,
		"confidence": confidence,
	}
	if target.has("block"):
		decision["block"] = str(target.get("block", ""))
	return Contract.normalize_decision(decision)


func _as_array(value: Variant) -> Array:
	return value as Array if value is Array else []


func _dangerous_creature_threat(observation: Dictionary, threats: Array) -> Dictionary:
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	var danger_radius := float(observation.get("creature_danger_distance", CREATURE_DANGER_RADIUS))
	var best := {}
	var best_distance := INF
	for raw_threat in threats:
		if not raw_threat is Dictionary:
			continue
		var threat := raw_threat as Dictionary
		if not bool(threat.get("alive", true)) or int(threat.get("health", 1)) <= 0:
			continue
		var distance := float(threat.get("distance", Contract.distance_between(self_state, threat)))
		if distance > danger_radius:
			continue
		var profile := _creature_profile(threat)
		var damage := int(profile.get("damage", 0))
		if damage <= 0:
			continue
		var temperament := str(profile.get("temperament", "passive")).to_lower()
		var attack_trigger := str(profile.get("attack_trigger", "never")).to_lower()
		var provoked_ticks := int(threat.get("provoked_ticks", 0))
		var explicitly_attacking := bool(threat.get("is_attacking", false)) or bool(threat.get("attacking", false))
		var recently_attacked := int(threat.get("attack_cooldown", 0)) > 0
		var awareness_blocks := clampf(float(profile.get("awareness_blocks", 7.0)), 1.0, 16.0)
		var within_awareness := distance <= awareness_blocks * 32.0
		var active_attack := explicitly_attacking or recently_attacked
		if attack_trigger == "always":
			active_attack = active_attack or within_awareness
		elif attack_trigger == "provoked":
			active_attack = active_attack or provoked_ticks > 0
		# Defensive animals are safe until provoked; aggressive animals with an
		# always-on trigger are dangerous as soon as they become aware of the bot.
		if temperament == "aggressive" and attack_trigger == "never":
			active_attack = active_attack or within_awareness
		if not active_attack:
			continue
		if distance < best_distance:
			best = threat
			best_distance = distance
	return best


func _creature_profile(threat: Dictionary) -> Dictionary:
	var block_name := str(threat.get("block_name", ""))
	var entry := _block_entry(block_name)
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	var behavior: Dictionary = definition.get("behavior", {}) if definition.get("behavior", {}) is Dictionary else {}
	var stats: Dictionary = definition.get("stats", {}) if definition.get("stats", {}) is Dictionary else {}
	return {
		"damage": int(threat.get("damage", threat.get("attack_damage", stats.get("damage", 0)))),
		"temperament": str(threat.get("temperament", behavior.get("temperament", "passive"))),
		"attack_trigger": str(threat.get("attack_trigger", behavior.get("attack_trigger", "never"))),
		"awareness_blocks": float(threat.get("awareness_blocks", behavior.get("awareness_blocks", 7.0))),
	}


func _creature_combat_tool(observation: Dictionary) -> String:
	var inventory := _inventory(observation)
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var current := str(equipment.get("hand", ""))
	if _is_melee_weapon(current):
		return ""
	if current.to_lower() == "bow" and int(inventory.get("arrow", 0)) > 0:
		return ""
	if int(inventory.get("bow", 0)) > 0 and int(inventory.get("arrow", 0)) > 0:
		return "bow"
	for preferred in ["stone_sword", "stone_axe"]:
		if int(inventory.get(preferred, 0)) > 0:
			return preferred
	for raw_name in inventory.keys():
		var name := str(raw_name)
		if int(inventory.get(name, 0)) > 0 and _is_melee_weapon(name):
			return name
	return ""


func _is_melee_weapon(item_name: String) -> bool:
	var normalized := item_name.to_lower()
	return normalized.contains("sword") or (normalized.contains("axe") and not normalized.contains("pickaxe"))


func _creature_bow_decision(observation: Dictionary, creature: Dictionary) -> Dictionary:
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	var self_position := Contract.target_position(self_state)
	var target_position := Contract.target_position(creature)
	var relative_target := (target_position + Vector2(10.0, 14.0)) - (self_position + Vector2(10.0, 11.76))
	var direction := bow_aim_direction(relative_target, 1.0)
	return _decision(
		Contract.GOAL_SURVIVE,
		Contract.ACTION_FIRE_BOW,
		creature.merged({"direction": [direction.x, direction.y], "charge": 1.0}),
		650,
		0.94,
	)


func _first_dictionary(values: Array) -> Dictionary:
	for value in values:
		if value is Dictionary:
			return value as Dictionary
	return {}


func _best_resource(values: Array, observation: Dictionary = {}) -> Dictionary:
	var best := {}
	var best_score := INF
	for raw_value in values:
		if not raw_value is Dictionary:
			continue
		var resource := raw_value as Dictionary
		if resource.has("solid") and not bool(resource.get("solid", true)):
			continue
		# A resource marked unreachable is not a movement waypoint.  Following its
		# coordinates makes the physics controller hold into a wall or an empty
		# drop, then the next observation selects the same tile again.  DigPlanner
		# runs before resource selection and owns the cases where a bounded route
		# can actually make this block reachable.
		if not bool(resource.get("reachable", false)):
			continue
		# A solid block that needs a tool must never become a movement target when
		# the bot cannot mine it.  Chasing the block centre makes the physics
		# controller push into the wall, finish the action, and select the same
		# adjacent block on the next decision, producing the visible left/right
		# oscillation instead of useful work.
		if not observation.is_empty():
			var required_tier := int(resource.get("harvest_tier", 0))
			if required_tier > 0 and not _has_required_mining_tier(observation, resource) and _mining_tool_for_target(observation, resource).is_empty():
				continue
		var score := float(resource.get("distance", 9999.0))
		if not bool(resource.get("reachable", false)):
			score += 1000.0
		# Prefer harvestable targets over blocks that require a better tool.
		if int(resource.get("harvest_tier", 0)) > 0:
			score -= 2.0
		if score < best_score:
			best_score = score
			best = resource
	return best


func _wander_target(self_state: Dictionary) -> Dictionary:
	var origin := Contract.target_position(self_state)
	var direction := -1.0 if _rng.randf() < 0.5 else 1.0
	return {"position": [origin.x + direction * WANDER_RADIUS, origin.y]}


func _inventory(observation: Dictionary) -> Dictionary:
	return observation.get("inventory_summary", {}) as Dictionary if observation.get("inventory_summary", {}) is Dictionary else {}


func _craftable_output(observation: Dictionary) -> String:
	if not str(observation.get("craft_pending_output", "")).is_empty():
		return ""
	if int(observation.get("craft_retry_after_msec", -1)) > int(observation.get("observed_at_msec", 0)):
		return ""
	var blocked_outputs: Array = observation.get("craft_blocked_outputs", []) if observation.get("craft_blocked_outputs", []) is Array else []
	var inventory := _inventory(observation)
	var achievements: Dictionary = observation.get("achievements", {}) if observation.get("achievements", {}) is Dictionary else {}
	var unlocked: Array = achievements.get("unlocked", []) if achievements.get("unlocked", []) is Array else []
	var recipes: Array = observation.get("recipes", []) if observation.get("recipes", []) is Array else []
	var priority := ["stone_pickaxe", "stone_axe", "trail_boots", "stone_sword"]
	for wanted in priority:
		if wanted in inventory or wanted in blocked_outputs or (wanted == "stone_pickaxe" and "stone_age" in unlocked):
			continue
		if _recipe_available(recipes, inventory, wanted) and wanted not in blocked_outputs:
			return wanted
	# Do not repeatedly crush the same raw material merely because a server
	# without the newer craft command has not acknowledged the request yet.
	for raw_recipe in recipes:
		if not raw_recipe is Dictionary:
			continue
		var recipe := raw_recipe as Dictionary
		var output: Dictionary = recipe.get("out", {}) if recipe.get("out", {}) is Dictionary else {}
		for raw_name in output:
			var name := str(raw_name)
			if name in GENERIC_OUTPUTS and name not in blocked_outputs and int(inventory.get(name, 0)) <= 0 and _recipe_inputs_available(recipe, inventory):
				return name
	return ""


func _recipe_available(recipes: Array, inventory: Dictionary, output_name: String) -> bool:
	for raw_recipe in recipes:
		if not raw_recipe is Dictionary:
			continue
		var recipe := raw_recipe as Dictionary
		var output: Dictionary = recipe.get("out", {}) if recipe.get("out", {}) is Dictionary else {}
		if output.has(output_name) and _recipe_inputs_available(recipe, inventory):
			return true
	return false


func _recipe_inputs_available(recipe: Dictionary, inventory: Dictionary) -> bool:
	var inputs: Dictionary = recipe.get("in", {}) if recipe.get("in", {}) is Dictionary else {}
	if inputs.is_empty() or recipe.has("station_available") and not bool(recipe.get("station_available", false)):
		return false
	for raw_name in inputs:
		if int(inventory.get(str(raw_name), 0)) < int(inputs[raw_name]):
			return false
	return true


func _equipable_tool(observation: Dictionary) -> String:
	var inventory := _inventory(observation)
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var pvp_world := bool(observation.get("pvp_world", false))
	# Footwear is the current defensive equipment slot in Tiny Block. Equip it
	# once after opening the duel chest, before changing the combat hand item.
	if pvp_world and str(equipment.get("feet", "")).is_empty():
		for footwear in ["trail_boots", "palm_sandals", "ice_boots", "moonstone_boots"]:
			if int(inventory.get(footwear, 0)) > 0:
				return footwear
	var current := str(equipment.get("hand", ""))
	if pvp_world:
		# A loaded bow is the bot's preferred PvP weapon. Do not immediately
		# switch to a melee tool on the next decision or the bot oscillates between
		# bow and axe before it ever gets a shot off.
		if current == "bow" and int(inventory.get("arrow", 0)) > 0:
			return ""
		if int(inventory.get("bow", 0)) > 0 and int(inventory.get("arrow", 0)) > 0 and current != "bow":
			return "bow"
		# Once the bow is empty, keep one offensive fallback equipped.  Cycling
		# through pickaxes here prevents the next MOVE_TO/ATTACK_PLAYER decision
		# from ever running, leaving the bot stranded at bow range.
		for preferred in ["stone_sword", "stone_axe"]:
			if int(inventory.get(preferred, 0)) > 0:
				return "" if current == preferred else preferred
		return ""
	for preferred in ["bow", "stone_pickaxe", "copper_pickaxe", "crystal_pickaxe", "obsidian_pickaxe", "resonance_pickaxe", "stone_axe", "stone_sword"]:
		if int(inventory.get(preferred, 0)) > 0 and current != preferred:
			return preferred
	return ""


func _has_pvp_loadout(observation: Dictionary) -> bool:
	var inventory := _inventory(observation)
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	for name in ["bow", "stone_sword", "stone_axe", "wooden_pickaxe", "stone_pickaxe", "copper_pickaxe", "trail_boots", "palm_sandals", "ice_boots", "moonstone_boots"]:
		if int(inventory.get(name, 0)) > 0 or str(equipment.get("hand", "")) == name or str(equipment.get("feet", "")) == name:
			return true
	return false


func _pvp_loadout_container(observation: Dictionary) -> Dictionary:
	for raw_container in _as_array(observation.get("visible_containers", [])):
		if not raw_container is Dictionary:
			continue
		var container := raw_container as Dictionary
		if str(container.get("kind", "")) == "chest":
			return container
	# Some P2P hosts send the duel snapshot before the container catalog has
	# arrived.  Duel geometry is deterministic, so recover the chest beside the
	# bot's island from the pinned enemy side instead of starting the match
	# empty-handed and walking into the void.
	if bool(observation.get("pvp_world", false)) and not _has_pvp_loadout(observation):
		var enemy := _pvp_target(observation)
		if not enemy.is_empty():
			var enemy_position := Contract.target_position(enemy)
			var chest_x := 15 if enemy_position.x < 0.0 else -15
			var chest_y := 7
			var self_position := Contract.target_position(observation.get("self", {}))
			var chest_position := Vector2((float(chest_x) + 0.5) * BlockDefs.TILE, (float(chest_y) + 0.5) * BlockDefs.TILE)
			return {
				"id": "container:%d:%d" % [chest_x, chest_y],
				"x": chest_x,
				"y": chest_y,
				"position": [chest_position.x, chest_position.y],
				"kind": "chest",
				"reachable": self_position.distance_to(chest_position) <= float(BlockDefs.TILE) * 4.5,
			}
	return {}


func _approach_bridge_step(observation: Dictionary, social_target: Dictionary) -> Dictionary:
	var approach := social_target
	var goal := Contract.GOAL_SOCIAL_FOLLOW
	var min_distance := float(observation.get("preferred_player_distance", PREFERRED_PLAYER_DISTANCE))
	if bool(observation.get("pvp_world", false)):
		approach = _pvp_target(observation)
		goal = Contract.GOAL_SELF_DEFENSE
		min_distance = float(BlockDefs.TILE) * 2.5
	if approach.is_empty() or float(approach.get("distance", 0.0)) <= min_distance:
		return {}
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	# A bridge cell is an extension of the current support row. During a jump or
	# a fall the avatar's y coordinate is an airborne position, not a valid
	# support level; placing at that y creates a vertical trail in the void and
	# makes the next movement decision chase an impossible route. Let physics
	# finish the arc and re-evaluate from the landed tile instead.
	if not bool(self_state.get("on_ground", false)):
		return {}
	var tile := float(BlockDefs.TILE)
	var origin := Vector2i(floori((float(self_state.get("x", 0.0)) + 10.0) / tile), floori((float(self_state.get("y", 0.0)) + 28.0) / tile))
	var approach_position := Contract.target_position(approach)
	var approach_tile := Vector2i(floori((approach_position.x + 10.0) / tile), floori((approach_position.y + 28.0) / tile))
	var direction := signi(approach_tile.x - origin.x)
	if direction == 0:
		return {}
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var current_key := "%d:%d" % [origin.x, origin.y]
	var next_x := origin.x + direction
	var next_key := "%d:%d" % [next_x, origin.y]
	# Only bridge from a known solid support into a known empty adjacent cell.
	# This bounds each placement to one tile and leaves reach/collision checks to
	# the authoritative host. The same step is used to close a duel gap and to
	# walk up to another player for a wave.
	var pvp_edge_fallback := bool(observation.get("pvp_world", false)) and (
		(direction < 0 and origin.x <= 12 and origin.x >= 10)
		or (direction > 0 and origin.x >= -12 and origin.x <= -10)
	)
	if (not _terrain_solid(terrain, current_key) and not pvp_edge_fallback) or terrain.has(next_key) and not str(terrain[next_key]).is_empty():
		return {}
	var inventory := _inventory(observation)
	for block_name in ["cobblestone", "planks", "palm_planks", "pine_planks", "weeping_planks", "stone", "dirt"]:
		if int(inventory.get(block_name, 0)) > 0:
			return {
				"action": Contract.ACTION_PLACE,
				"goal": goal,
				"target_id": "bridge:%d:%d" % [next_x, origin.y],
				"target": {"id": "bridge:%d:%d" % [next_x, origin.y], "x": next_x, "y": origin.y, "reachable": true},
				"block": block_name,
				"commit_for_ms": 700,
				"confidence": 0.92 if goal == Contract.GOAL_SELF_DEFENSE else 0.8,
			}
	return {}


func _terrain_map(raw: Variant) -> Dictionary:
	var result := {}
	if not raw is Array:
		return result
	for raw_tile in raw:
		if raw_tile is Dictionary:
			var tile := raw_tile as Dictionary
			result["%d:%d" % [int(tile.get("x", 0)), int(tile.get("y", 0))]] = str(tile.get("block_name", ""))
	return result


func _terrain_solid(terrain: Dictionary, key: String) -> bool:
	var name := str(terrain.get(key, "")).to_lower()
	return not name.is_empty() and name not in ["air", "core.air", "water", "lava"]


func _incoming_arrow_cover_decision(observation: Dictionary) -> Dictionary:
	var projectiles := _as_array(observation.get("active_projectiles", []))
	if projectiles.is_empty():
		return {}
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	var self_center := Vector2(
		float(self_state.get("x", 0.0)) + float(self_state.get("w", 20.0)) * 0.5,
		float(self_state.get("y", 0.0)) + float(self_state.get("h", 28.0)) * 0.5,
	)
	var own_player_id := str(observation.get("own_player_id", ""))
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var inventory := _inventory(observation)
	var block_name := ""
	for candidate in ["cobblestone", "stone", "planks", "palm_planks", "pine_planks", "weeping_planks", "dirt"]:
		if int(inventory.get(candidate, 0)) > 0:
			block_name = candidate
			break
	if block_name.is_empty():
		return {}

	var best_time := INF
	var best_target := Vector2i.ZERO
	for raw_projectile in projectiles:
		if not raw_projectile is Dictionary:
			continue
		var projectile := raw_projectile as Dictionary
		if str(projectile.get("kind", "arrow")) != "arrow":
			continue
		var owner_id := str(projectile.get("owner_player_id", ""))
		if not own_player_id.is_empty() and owner_id == own_player_id:
			continue
		if float(projectile.get("age", 0.0)) > 1.5:
			continue
		var position := Vector2(float(projectile.get("x", INF)), float(projectile.get("y", INF)))
		var velocity := Vector2(float(projectile.get("vx", 0.0)), float(projectile.get("vy", 0.0)))
		var speed_squared := velocity.length_squared()
		if not is_finite(position.x) or not is_finite(position.y) or not is_finite(velocity.x) or not is_finite(velocity.y) or speed_squared < 1.0:
			continue
		var time_to_closest := (self_center - position).dot(velocity) / speed_squared
		if time_to_closest < 0.0 or time_to_closest > 0.85:
			continue
		var closest := position + velocity * time_to_closest
		var hit_radius := maxf(26.0, maxf(float(self_state.get("w", 20.0)), float(self_state.get("h", 28.0))) * 0.65)
		if closest.distance_to(self_center) > hit_radius:
			continue
		var toward_arrow := (position - self_center).normalized()
		if toward_arrow.length_squared() < 0.1:
			continue
		var cover_center := self_center + toward_arrow * 24.0
		var base_tile := Vector2i(floori(cover_center.x / float(BlockDefs.TILE)), floori(cover_center.y / float(BlockDefs.TILE)))
		var offsets := [Vector2i.ZERO, Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
		for offset in offsets:
			var candidate: Vector2i = base_tile + offset
			var key := "%d:%d" % [candidate.x, candidate.y]
			if _terrain_solid(terrain, key) or _tile_overlaps_player(candidate, self_state):
				continue
			var tile_center := Vector2((float(candidate.x) + 0.5) * BlockDefs.TILE, (float(candidate.y) + 0.5) * BlockDefs.TILE)
			if tile_center.distance_to(self_center) > float(BlockDefs.TILE) * 3.0:
				continue
			if time_to_closest < best_time:
				best_time = time_to_closest
				best_target = candidate
			break
	if best_time == INF:
		return {}
	var target_id := "arrow-cover:%d:%d" % [best_target.x, best_target.y]
	return {
		"action": Contract.ACTION_PLACE,
		"goal": Contract.GOAL_SELF_DEFENSE,
		"target_id": target_id,
		"target": {"id": target_id, "x": best_target.x, "y": best_target.y, "reachable": true, "reason": "incoming_arrow"},
		"block": block_name,
		"commit_for_ms": 350,
		"confidence": 0.97,
	}


func _tile_overlaps_player(tile: Vector2i, self_state: Dictionary) -> bool:
	var tile_rect := Rect2(float(tile.x * BlockDefs.TILE), float(tile.y * BlockDefs.TILE), float(BlockDefs.TILE), float(BlockDefs.TILE))
	var player_rect := Rect2(
		float(self_state.get("x", 0.0)),
		float(self_state.get("y", 0.0)),
		float(self_state.get("w", 20.0)),
		float(self_state.get("h", 28.0)),
	)
	return tile_rect.grow(-1.0).intersects(player_rect.grow(-1.0))


func _mining_tool_for_target(observation: Dictionary, target: Dictionary) -> String:
	var required_tier := int(target.get("harvest_tier", 0))
	if required_tier <= 0:
		return ""
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	if _tool_harvest_tier(str(equipment.get("hand", ""))) >= required_tier:
		return ""
	var inventory := _inventory(observation)
	var best := ""
	var best_tier := 99
	for raw_name in inventory.keys():
		var name := str(raw_name)
		if int(inventory.get(name, 0)) <= 0:
			continue
		var tier := _tool_harvest_tier(name)
		if tier >= required_tier and tier < best_tier:
			best = name
			best_tier = tier
	return best


func _has_required_mining_tier(observation: Dictionary, target: Dictionary) -> bool:
	var required_tier := int(target.get("harvest_tier", 0))
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	return _tool_harvest_tier(str(equipment.get("hand", ""))) >= required_tier


func _tool_harvest_tier(block_name: String) -> int:
	var entry := _block_entry(block_name)
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	if str(definition.get("category", "")) != "mining_tool":
		return 0
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return int(effects.get("harvest_tier", 0))


func _block_entry(block_name: String) -> Dictionary:
	var loop := Engine.get_main_loop()
	if loop == null or not loop.has_method("get_root"):
		return {}
	var root: Node = loop.get_root()
	var defs := root.get_node_or_null("BlockDefs")
	if defs == null or not defs.get("BLOCKS") is Dictionary:
		return {}
	var blocks: Dictionary = defs.get("BLOCKS")
	return blocks.get(block_name, {}) if blocks.get(block_name, {}) is Dictionary else {}


func _ranged_target(observation: Dictionary) -> Dictionary:
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var inventory := _inventory(observation)
	if not str(equipment.get("hand", "")).to_lower().contains("bow") or int(inventory.get("arrow", 0)) <= 0:
		return {}
	var max_distance := float(observation.get("bow_attack_distance", 320.0))
	var enemy_id := str(observation.get("enemy_player_id", ""))
	if bool(observation.get("pvp_world", false)) and not enemy_id.is_empty():
		for raw_player in _as_array(observation.get("players", [])):
			if raw_player is Dictionary and str((raw_player as Dictionary).get("id", "")) == enemy_id:
				var enemy := raw_player as Dictionary
				if bool(enemy.get("alive", true)) and float(enemy.get("distance", 9999.0)) <= max_distance:
					return enemy
		return {}
	var threats := _as_array(observation.get("threats", []))
	for raw_threat in threats:
		if not raw_threat is Dictionary:
			continue
		var threat := raw_threat as Dictionary
		if bool(threat.get("alive", true)) and float(threat.get("distance", 9999.0)) <= max_distance:
			return threat
	return {}


static func bow_aim_direction(relative_target: Vector2, charge: float = 1.0, arrow_speed: float = BOW_ARROW_MAX_SPEED, gravity: float = BOW_ARROW_GRAVITY) -> Vector2:
	if relative_target.length() < 0.1:
		return Vector2.RIGHT
	var speed := lerpf(BOW_ARROW_MIN_SPEED, arrow_speed, clampf(charge, 0.0, 1.0) if arrow_speed > BOW_ARROW_MIN_SPEED else 1.0)
	var horizontal_distance := absf(relative_target.x)
	if horizontal_distance < 0.1 or speed <= 0.0:
		return relative_target.normalized()
	# Iterate once: the initial horizontal flight estimate gives a useful drop,
	# then the compensated angle gives a better flight-time estimate for the
	# second drop correction. Coordinates use +Y downward, so compensation is
	# upward (more negative Y).
	var flight_time := horizontal_distance / speed
	var compensated_y := relative_target.y - 0.5 * gravity * flight_time * flight_time
	var direction := Vector2(relative_target.x, compensated_y).normalized()
	var horizontal_speed := maxf(absf(direction.x) * speed, 1.0)
	flight_time = horizontal_distance / horizontal_speed
	compensated_y = relative_target.y - 0.5 * gravity * flight_time * flight_time
	return Vector2(relative_target.x, compensated_y).normalized()


func _pvp_target(observation: Dictionary) -> Dictionary:
	if not bool(observation.get("pvp_world", false)):
		return {}
	var enemy_id := str(observation.get("enemy_player_id", ""))
	if enemy_id.is_empty():
		return {}
	for raw_player in _as_array(observation.get("players", [])):
		if raw_player is Dictionary and str((raw_player as Dictionary).get("id", "")) == enemy_id:
			var player := raw_player as Dictionary
			if bool(player.get("alive", true)):
				return player
	return {}


func _build_target(observation: Dictionary) -> Dictionary:
	var now_msec := int(observation.get("observed_at_msec", 0))
	if _last_build_msec >= 0 and now_msec - _last_build_msec < BUILD_ACTION_COOLDOWN_MSEC:
		return {}
	var inventory := _inventory(observation)
	var block_name := ""
	for preferred in ["planks", "palm_planks", "pine_planks", "weeping_planks", "stone_bricks", "cobblestone", "stone", "dirt"]:
		if int(inventory.get(preferred, 0)) > 0:
			block_name = preferred
			break
	if block_name.is_empty():
		return {}
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	var tile_x := floori(float(self_state.get("x", 0.0)) / 32.0)
	var tile_y := floori((float(self_state.get("y", 0.0)) + 28.0) / 32.0)
	var offsets := [Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, -1), Vector2i(2, -1), Vector2i(0, -1), Vector2i(3, 0)]
	var occupied: Dictionary = {}
	for raw_tile in _as_array(observation.get("terrain_tiles", [])):
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		occupied["%d:%d" % [int(tile.get("x", 0)), int(tile.get("y", 0))]] = str(tile.get("block_name", ""))
	for offset_index in range(offsets.size()):
		var offset: Vector2i = offsets[(_build_step + offset_index) % offsets.size()]
		var target_x := tile_x + offset.x
		var target_y := tile_y + offset.y
		var occupied_name := str(occupied.get("%d:%d" % [target_x, target_y], ""))
		if not occupied_name.is_empty() and occupied_name.to_lower() not in ["air", "core.air"]:
			continue
		var conflicts_with_resource := false
		for raw_resource in _as_array(observation.get("visible_resources", [])):
			if not raw_resource is Dictionary:
				continue
			var resource := raw_resource as Dictionary
			if int(resource.get("x", 2147483647)) == target_x and int(resource.get("y", 2147483647)) == target_y:
				conflicts_with_resource = true
				break
		if conflicts_with_resource:
			continue
		_build_step = (_build_step + offset_index + 1) % offsets.size()
		_last_build_msec = now_msec
		return {"id": "build:%d" % now_msec, "block": block_name, "x": target_x, "y": target_y}
	return {}
