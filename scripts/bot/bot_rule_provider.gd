class_name BotRuleProvider
extends BotDecisionProvider

var _rng := RandomNumberGenerator.new()
var _build_step := 0

const PREFERRED_PLAYER_DISTANCE := 84.0
const WANDER_RADIUS := 96.0
const WANDER_COMMIT_MSEC := 1800


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

	var craft_target := _craftable_output(observation)
	if not craft_target.is_empty() and Contract.ACTION_CRAFT in legal:
		return _decision(Contract.GOAL_ACHIEVEMENT, Contract.ACTION_CRAFT, {"id": craft_target}, 700, 0.9)
	var equip_target := _equipable_tool(observation)
	if not equip_target.is_empty() and Contract.ACTION_EQUIP in legal:
		return _decision(Contract.GOAL_ACHIEVEMENT, Contract.ACTION_EQUIP, {"id": equip_target}, 350, 0.86)
	if not social_target_id.is_empty() and social_distance > preferred_distance:
		if Contract.ACTION_MOVE_NEAR_PLAYER in legal:
			return _decision(Contract.GOAL_SOCIAL_FOLLOW, Contract.ACTION_MOVE_NEAR_PLAYER, social_target, 2400, 0.72)
		if Contract.ACTION_FOLLOW in legal:
			return _decision(Contract.GOAL_SOCIAL_FOLLOW, Contract.ACTION_FOLLOW, social_target, 2400, 0.72)

	# Do not freeze once the bot has reached the comfortable social distance.
	# Small, non-combat wander steps make the avatar feel alive while keeping it
	# separate from real players and away from unsolicited PvP.
	if Contract.ACTION_MOVE_TO in legal and _rng.randf() < 0.32:
		return _decision(Contract.GOAL_EXPLORE, Contract.ACTION_MOVE_TO, _wander_target(self_state), WANDER_COMMIT_MSEC, 0.48)

	if not threats.is_empty() and Contract.ACTION_ATTACK_CREATURE in legal:
		var creature := _first_dictionary(threats)
		if float(creature.get("distance", 9999.0)) <= float(observation.get("creature_attack_distance", 48.0)):
			return _decision(Contract.GOAL_SURVIVE, Contract.ACTION_ATTACK_CREATURE, creature, 500, 0.78)

	var resources: Array = _as_array(observation.get("visible_resources", []))
	if not resources.is_empty() and Contract.ACTION_MINE in legal:
		var resource := _first_dictionary(resources)
		if bool(resource.get("reachable", false)):
			return _decision(Contract.GOAL_GATHER, Contract.ACTION_MINE, resource, 1800, 0.67)

	var build_target := _build_target(observation)
	if not build_target.is_empty() and Contract.ACTION_PLACE in legal:
		return _decision(Contract.GOAL_BUILD, Contract.ACTION_PLACE, build_target, 700, 0.61)

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
	var inventory := _inventory(observation)
	var achievements: Dictionary = observation.get("achievements", {}) if observation.get("achievements", {}) is Dictionary else {}
	var unlocked: Array = achievements.get("unlocked", []) if achievements.get("unlocked", []) is Array else []
	var recipes: Array = observation.get("recipes", []) if observation.get("recipes", []) is Array else []
	var priority := ["stone_pickaxe", "stone_axe", "trail_boots", "stone_sword"]
	for wanted in priority:
		if wanted in inventory or (wanted == "stone_pickaxe" and "stone_age" in unlocked):
			continue
		if _recipe_available(recipes, inventory, wanted):
			return wanted
	for raw_recipe in recipes:
		if not raw_recipe is Dictionary:
			continue
		var recipe := raw_recipe as Dictionary
		var output: Dictionary = recipe.get("out", {}) if recipe.get("out", {}) is Dictionary else {}
		for raw_name in output:
			var name := str(raw_name)
			if int(inventory.get(name, 0)) <= 0 and _recipe_inputs_available(recipe, inventory):
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
	for preferred in ["stone_pickaxe", "copper_pickaxe", "crystal_pickaxe", "obsidian_pickaxe", "resonance_pickaxe", "stone_axe", "stone_sword"]:
		if int(inventory.get(preferred, 0)) > 0 and current != preferred:
			return preferred
	return ""


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
