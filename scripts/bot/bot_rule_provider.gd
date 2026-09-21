class_name BotRuleProvider
extends BotDecisionProvider

const DigPlanner = preload("res://gameplay/scripts/bot/bot_dig_planner.gd")

var _rng := RandomNumberGenerator.new()
var _build_step := 0

const PREFERRED_PLAYER_DISTANCE := 84.0
const WANDER_RADIUS := 96.0
const WANDER_COMMIT_MSEC := 1800
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
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	var health := int(self_state.get("health", 10))
	var max_health := maxi(1, int(self_state.get("max_health", 10)))
	var low_health := float(health) / float(max_health) <= 0.35

	# Immediate survival has priority over social or gathering behaviour.
	var threats: Array = _as_array(observation.get("threats", []))
	if low_health and not threats.is_empty() and Contract.ACTION_FLEE_FROM in legal:
		var threat := _first_dictionary(threats)
		return _decision(Contract.GOAL_SURVIVE, Contract.ACTION_FLEE_FROM, threat, 1600, 0.96)

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
	if not welcome_emoji.is_empty() and Contract.ACTION_SEND_EMOJI in legal:
		return _decision(Contract.GOAL_SOCIAL_FOLLOW, Contract.ACTION_SEND_EMOJI, {"id": social_target_id, "emoji": welcome_emoji}, 500, 0.78)

	# A bow is a deliberate ranged activity.  In a PvP world the enemy is
	# pinned for the lifetime of the session; outside PvP, only hostile creatures
	# are valid targets so nearby players are never attacked unsolicited.
	var ranged_target := _ranged_target(observation)
	if not ranged_target.is_empty() and Contract.ACTION_FIRE_BOW in legal:
		var self_position := Contract.target_position(self_state)
		var target_position := Contract.target_position(ranged_target)
		var direction := target_position - self_position
		return _decision(
			Contract.GOAL_SELF_DEFENSE if bool(observation.get("pvp_world", false)) else Contract.GOAL_SURVIVE,
			Contract.ACTION_FIRE_BOW,
			ranged_target.merged({"direction": [direction.x, direction.y], "charge": 1.0}),
			650,
			0.9,
		)

	var craft_target := _craftable_output(observation)
	if not craft_target.is_empty() and Contract.ACTION_CRAFT in legal:
		return _decision(Contract.GOAL_ACHIEVEMENT, Contract.ACTION_CRAFT, {"id": craft_target}, 700, 0.9)
	var equip_target := _equipable_tool(observation)
	if not equip_target.is_empty() and Contract.ACTION_EQUIP in legal:
		return _decision(Contract.GOAL_ACHIEVEMENT, Contract.ACTION_EQUIP, {"id": equip_target}, 350, 0.86)
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

	var build_target := _build_target(observation)
	if not build_target.is_empty() and Contract.ACTION_PLACE in legal:
		return _decision(Contract.GOAL_BUILD, Contract.ACTION_PLACE, build_target, 700, 0.61)

	var resources: Array = _as_array(observation.get("visible_resources", []))
	if not resources.is_empty() and Contract.ACTION_MINE in legal:
		var resource := _first_dictionary(resources)
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
			if raw_container is Dictionary and bool((raw_container as Dictionary).get("reachable", false)):
				return _decision(Contract.GOAL_ACHIEVEMENT, Contract.ACTION_OPEN_CONTAINER, raw_container, 900, 0.76)

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


func _first_dictionary(values: Array) -> Dictionary:
	for value in values:
		if value is Dictionary:
			return value as Dictionary
	return {}


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
	var current := str(equipment.get("hand", ""))
	for preferred in ["bow", "stone_pickaxe", "copper_pickaxe", "crystal_pickaxe", "obsidian_pickaxe", "resonance_pickaxe", "stone_axe", "stone_sword"]:
		if int(inventory.get(preferred, 0)) > 0 and current != preferred:
			return preferred
	return ""


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


func _build_target(observation: Dictionary) -> Dictionary:
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
	var offset: Vector2i = offsets[_build_step % offsets.size()]
	_build_step += 1
	return {"id": "build:%d" % _build_step, "block": block_name, "x": tile_x + offset.x, "y": tile_y + offset.y}
