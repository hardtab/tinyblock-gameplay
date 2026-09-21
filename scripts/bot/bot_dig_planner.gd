class_name BotDigPlanner
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")

## Bounded excavation planner used by the rule provider.
##
## This is deliberately a one-step planner.  It never teleports the bot or
## edits terrain locally: it returns one authoritative MINE or PLACE command,
## then replans from the next terrain snapshot.  That makes a staircase an
## ordinary sequence of game actions and keeps the host's reach, harvest, and
## collision checks authoritative.

const TILE := 32
const MAX_HORIZONTAL_STEP := 1
const MAX_VERTICAL_STEP := 2
const MAX_TARGET_DISTANCE_TILES := 8
const MINING_TOOL_NAMES: PackedStringArray = [
	"wooden_pickaxe", "stone_pickaxe", "copper_pickaxe", "crystal_pickaxe",
	"obsidian_pickaxe", "resonance_pickaxe", "stone_axe",
]
const SUPPORT_BLOCK_NAMES: PackedStringArray = [
	"planks", "palm_planks", "pine_planks", "weeping_planks",
	"stone_bricks", "cobblestone", "stone", "dirt",
]


static func next_step(observation: Dictionary) -> Dictionary:
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	if terrain.is_empty() or not _has_equipped_mining_tool(observation):
		return {}
	var origin := _support_tile(observation.get("self", {}))
	var target := _target_tile(observation, origin)
	if target == _invalid_tile() or origin.distance_to(target) > MAX_TARGET_DISTANCE_TILES:
		return {}
	var horizontal_direction := signi(target.x - origin.x)
	if horizontal_direction == 0:
		# A vertical target can still be reached by making the next upward step.
		if target.y < origin.y:
			return _upward_step(origin, origin.x, terrain, observation)
		return {}
	var next_x := origin.x + horizontal_direction * MAX_HORIZONTAL_STEP
	if target.y < origin.y:
		# A solid block one level above is a usable natural/constructed step. Do
		# not mine the step we just placed; only clear a ceiling above it.
		if not _solid(terrain, next_x, origin.y - 1):
			return _place_step(next_x, origin.y - 1, origin, target, observation)
		if _solid(terrain, next_x, origin.y - 2):
			return _mine_step(next_x, origin.y - 2, origin, target, observation)
		return {}
	# Clear the two-cell player corridor before trying to walk through a wall.
	for head_y in [origin.y - 1, origin.y - 2]:
		if _solid(terrain, next_x, head_y):
			return _mine_step(next_x, head_y, origin, target, observation)
	# If the next column has no floor, bridge a bounded gap.  The next decision
	# will see the new support block and continue one block at a time.
	if not _solid(terrain, next_x, origin.y):
		if _solid(terrain, next_x, origin.y + 1):
			return _place_step(next_x, origin.y, origin, target, observation)
		# An unsupported void is unsafe to bridge without a nearby lower support.
		return {}
	return {}


static func _target_tile(observation: Dictionary, origin: Vector2i) -> Vector2i:
	var players: Array = observation.get("players", []) if observation.get("players", []) is Array else []
	var preferred_distance := float(observation.get("preferred_player_distance", 84.0))
	for raw_player in players:
		if not raw_player is Dictionary:
			continue
		var player := raw_player as Dictionary
		if float(player.get("distance", 9999.0)) <= preferred_distance:
			continue
		var candidate := _support_tile(player)
		if abs(candidate.x - origin.x) <= MAX_TARGET_DISTANCE_TILES and abs(candidate.y - origin.y) <= MAX_TARGET_DISTANCE_TILES:
			return candidate
	# Resource entries are intentionally chosen only when they are not already
	# reachable.  Reachable resources continue through the regular MINE action.
	var resources: Array = observation.get("visible_resources", []) if observation.get("visible_resources", []) is Array else []
	var best := _invalid_tile()
	var best_distance := 999999.0
	for raw_resource in resources:
		if not raw_resource is Dictionary:
			continue
		var resource := raw_resource as Dictionary
		if bool(resource.get("reachable", false)) or not _interesting_resource(str(resource.get("block_name", resource.get("content_id", "")))):
			continue
		var candidate := _tile_from_target(resource)
		var distance := origin.distance_to(candidate)
		if candidate == _invalid_tile() or distance > MAX_TARGET_DISTANCE_TILES or distance >= best_distance:
			continue
		best = candidate
		best_distance = distance
	return best


static func _mine_step(x: int, y: int, origin: Vector2i, target: Vector2i, observation: Dictionary) -> Dictionary:
	return {
		"action": Contract.ACTION_MINE,
		"goal": Contract.GOAL_DIG_ROUTE,
		"target_id": "dig:%d:%d" % [x, y],
		"target": {
			"id": "dig:%d:%d" % [x, y],
			"x": x,
			"y": y,
			"dig_route": true,
			"route_target": [target.x, target.y],
			"origin": [origin.x, origin.y],
			"reachable": true,
			"harvest_tier": _terrain_harvest_tier(observation, x, y),
			"hardness": _terrain_hardness(observation, x, y),
		},
		"commit_for_ms": 1200,
		"confidence": 0.74,
	}


static func _place_step(x: int, y: int, origin: Vector2i, target: Vector2i, observation: Dictionary) -> Dictionary:
	var block := _support_block(observation)
	if block.is_empty():
		return {}
	return {
		"action": Contract.ACTION_PLACE,
		"goal": Contract.GOAL_DIG_ROUTE,
		"target_id": "dig-step:%d:%d" % [x, y],
		"target": {
			"id": "dig-step:%d:%d" % [x, y],
			"x": x,
			"y": y,
			"dig_route": true,
			"route_target": [target.x, target.y],
			"origin": [origin.x, origin.y],
		},
		"block": block,
		"commit_for_ms": 900,
		"confidence": 0.7,
	}


static func _upward_step(origin: Vector2i, x: int, terrain: Dictionary, observation: Dictionary) -> Dictionary:
	if _solid(terrain, x, origin.y - 1):
		return {}
	return _place_step(x, origin.y - 1, origin, Vector2i(x, origin.y - 2), observation)


static func _has_equipped_mining_tool(observation: Dictionary) -> bool:
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var equipped := str(equipment.get("hand", ""))
	return equipped in MINING_TOOL_NAMES


static func _support_block(observation: Dictionary) -> String:
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	for name in SUPPORT_BLOCK_NAMES:
		if int(inventory.get(name, 0)) > 0:
			return name
	return ""


static func _terrain_map(raw: Variant) -> Dictionary:
	var result := {}
	if raw is Dictionary:
		for key in raw:
			result[str(key)] = str(raw[key])
		return result
	if not raw is Array:
		return result
	for raw_tile in raw:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var name := str(tile.get("block_name", tile.get("name", tile.get("content_id", ""))))
		if name.is_empty():
			continue
		result["%d:%d" % [int(tile.get("x", 0)), int(tile.get("y", 0))]] = name
	return result


static func _support_tile(raw: Variant) -> Vector2i:
	var position := Vector2.ZERO
	if raw is Dictionary:
		var state := raw as Dictionary
		if state.has("x") or state.has("y"):
			position = Vector2(float(state.get("x", 0.0)), float(state.get("y", 0.0)))
		elif state.get("position", []) is Array and (state.get("position", []) as Array).size() >= 2:
			var coordinates: Array = state.get("position", [])
			position = Vector2(float(coordinates[0]), float(coordinates[1]))
	return Vector2i(floori((position.x + 10.0) / float(TILE)), floori((position.y + 28.0) / float(TILE)))


static func _tile_from_target(target: Dictionary) -> Vector2i:
	if target.has("x") and target.has("y"):
		return Vector2i(int(target.get("x", 0)), int(target.get("y", 0)))
	var position: Variant = target.get("position", [])
	if position is Array and (position as Array).size() >= 2:
		return Vector2i(floori(float((position as Array)[0]) / float(TILE)), floori(float((position as Array)[1]) / float(TILE)))
	return _invalid_tile()


static func _solid(terrain: Dictionary, x: int, y: int) -> bool:
	var name := str(terrain.get("%d:%d" % [x, y], ""))
	var normalized := name.to_lower()
	if normalized.is_empty() or normalized in ["air", "core.air"]:
		return false
	if normalized.contains("water") or normalized.contains("lava") or normalized.contains("item."):
		return false
	return true


static func _interesting_resource(name: String) -> bool:
	var normalized := name.to_lower()
	for token in ["ore", "crystal", "gem", "coal", "copper", "iron", "gold", "diamond", "obsidian", "aegisite", "stone", "flint"]:
		if normalized.contains(token):
			return true
	return false


static func _terrain_harvest_tier(observation: Dictionary, x: int, y: int) -> int:
	var raw_tiles: Variant = observation.get("terrain_tiles", [])
	if not raw_tiles is Array:
		return 0
	for raw_tile in raw_tiles:
		if raw_tile is Dictionary and int((raw_tile as Dictionary).get("x", 0)) == x and int((raw_tile as Dictionary).get("y", 0)) == y:
			return int((raw_tile as Dictionary).get("harvest_tier", 0))
	return 0


static func _terrain_hardness(observation: Dictionary, x: int, y: int) -> float:
	var raw_tiles: Variant = observation.get("terrain_tiles", [])
	if not raw_tiles is Array:
		return 0.0
	for raw_tile in raw_tiles:
		if raw_tile is Dictionary and int((raw_tile as Dictionary).get("x", 0)) == x and int((raw_tile as Dictionary).get("y", 0)) == y:
			return float((raw_tile as Dictionary).get("hardness", 0.0))
	return 0.0


static func _invalid_tile() -> Vector2i:
	return Vector2i(2147483647, 2147483647)
