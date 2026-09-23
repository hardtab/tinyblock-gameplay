class_name BotBuildPlanner
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")

## Terrain-aware, one-placement construction planner.
##
## Construction is treated as navigation infrastructure, not as a fixed
## blueprint. Every returned block either extends an existing walkable surface
## or creates a supported step toward an observed goal. The host remains
## authoritative for reach, inventory, placement, and collision validation.

const TILE := 32
const DESIRED_PLATFORM_WIDTH := 5
const MAX_PLACEMENT_REACH_TILES := 2
const MAX_GOAL_DISTANCE_TILES := 10
const SUPPORT_BLOCK_NAMES: PackedStringArray = [
	"stone_bricks", "cobblestone", "stone", "dirt", "grass", "packed_ice",
]
const PLANK_BLOCK_NAMES: PackedStringArray = [
	"planks", "palm_planks", "pine_planks", "weeping_planks",
]


static func next_step(observation: Dictionary) -> Dictionary:
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	if terrain.is_empty():
		return {}
	var origin := _support_tile(observation.get("self", {}))
	if not _solid(terrain, origin.x, origin.y):
		# Never infer a foundation from a world mode or stale airborne position.
		return {}
	var block_name := _support_block(observation)
	if block_name.is_empty():
		return {}

	var goal := _navigation_goal(observation, origin)
	var goal_direction := 0
	if goal != _invalid_tile():
		goal_direction = signi(goal.x - origin.x)
		if goal_direction != 0 and goal.y < origin.y:
			var step := _supported_stair(origin, goal_direction, goal, terrain, observation, block_name)
			if not step.is_empty():
				return step

	var left_run := _walkable_run(terrain, origin, -1)
	var right_run := _walkable_run(terrain, origin, 1)
	var platform_width := left_run + 1 + right_run
	var directions: Array[int] = []
	if goal_direction != 0:
		directions.append(goal_direction)
		directions.append(-goal_direction)
	elif left_run < right_run:
		directions.assign([-1, 1])
	elif right_run < left_run:
		directions.assign([1, -1])
	else:
		# Stable variation avoids every bot growing the platform on the same side,
		# while the next terrain snapshot naturally rebalances the shorter edge.
		var first := -1 if (int(observation.get("observed_at_msec", 0)) / 1000) % 2 == 0 else 1
		directions.assign([first, -first])

	if platform_width >= DESIRED_PLATFORM_WIDTH and goal_direction == 0:
		return {}
	for direction in directions:
		var run := left_run if direction < 0 else right_run
		var target := Vector2i(origin.x + direction * (run + 1), origin.y)
		if abs(target.x - origin.x) > MAX_PLACEMENT_REACH_TILES:
			continue
		if not _placeable(terrain, target.x, target.y):
			continue
		if not _empty(terrain, target.x, target.y - 1) or not _empty(terrain, target.x, target.y - 2):
			continue
		# Horizontal attachment is what makes an unsupported cell a bridge rather
		# than a floating decoration. Replan after every authoritative placement.
		if not _solid(terrain, target.x - direction, target.y):
			continue
		if _overlaps_any_player(target, observation):
			continue
		var reason := "bridge_to_goal" if direction == goal_direction and goal_direction != 0 else "expand_platform"
		return _placement(target, origin, goal, block_name, reason)
	return {}


static func _supported_stair(origin: Vector2i, direction: int, goal: Vector2i, terrain: Dictionary, observation: Dictionary, block_name: String) -> Dictionary:
	var target := Vector2i(origin.x + direction, origin.y - 1)
	# A stair is only valid when the block directly below already exists. This
	# forbids diagonal/floating stairs and leaves two cells of headroom above it.
	if not _solid(terrain, target.x, target.y + 1):
		return {}
	if not _placeable(terrain, target.x, target.y):
		return {}
	if not _empty(terrain, target.x, target.y - 1) or not _empty(terrain, target.x, target.y - 2):
		return {}
	if _overlaps_any_player(target, observation):
		return {}
	return _placement(target, origin, goal, block_name, "build_stair")


static func _placement(target: Vector2i, origin: Vector2i, goal: Vector2i, block_name: String, reason: String) -> Dictionary:
	return {
		"id": "build:%s:%d:%d" % [reason, target.x, target.y],
		"block": block_name,
		"x": target.x,
		"y": target.y,
		"reason": reason,
		"origin": [origin.x, origin.y],
		"route_target": [] if goal == _invalid_tile() else [goal.x, goal.y],
		"structurally_connected": true,
	}


static func _navigation_goal(observation: Dictionary, origin: Vector2i) -> Vector2i:
	var preferred_distance := float(observation.get("preferred_player_distance", 84.0))
	var best := _invalid_tile()
	var best_distance := INF
	for raw_player in _as_array(observation.get("players", [])):
		if not raw_player is Dictionary or not bool((raw_player as Dictionary).get("alive", true)):
			continue
		var player := raw_player as Dictionary
		if float(player.get("distance", 9999.0)) <= preferred_distance:
			continue
		var candidate := _target_tile(player)
		var distance := origin.distance_to(candidate)
		if candidate != _invalid_tile() and distance <= MAX_GOAL_DISTANCE_TILES and distance < best_distance:
			best = candidate
			best_distance = distance
	for raw_resource in _as_array(observation.get("visible_resources", [])):
		if not raw_resource is Dictionary or bool((raw_resource as Dictionary).get("reachable", false)):
			continue
		var candidate := _target_tile(raw_resource as Dictionary)
		var distance := origin.distance_to(candidate)
		if candidate != _invalid_tile() and distance <= MAX_GOAL_DISTANCE_TILES and distance < best_distance:
			best = candidate
			best_distance = distance
	return best


static func _walkable_run(terrain: Dictionary, origin: Vector2i, direction: int) -> int:
	var count := 0
	for distance in range(1, MAX_GOAL_DISTANCE_TILES + 1):
		var x := origin.x + direction * distance
		if not _solid(terrain, x, origin.y):
			break
		if not _empty(terrain, x, origin.y - 1) or not _empty(terrain, x, origin.y - 2):
			break
		count += 1
	return count


static func _support_block(observation: Dictionary) -> String:
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	for name in SUPPORT_BLOCK_NAMES:
		if int(inventory.get(name, 0)) > 0:
			return name
	# Keep four matching planks for starter tools/workbench progression.
	for name in PLANK_BLOCK_NAMES:
		if int(inventory.get(name, 0)) > 4:
			return name
	return ""


static func _terrain_map(raw: Variant) -> Dictionary:
	var result := {}
	if not raw is Array:
		return result
	for raw_tile in raw:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var name := str(tile.get("block_name", tile.get("name", tile.get("content_id", ""))))
		if not name.is_empty():
			result["%d:%d" % [int(tile.get("x", 0)), int(tile.get("y", 0))]] = name
	return result


static func _support_tile(raw: Variant) -> Vector2i:
	var position := Contract.target_position(raw)
	return Vector2i(
		floori((position.x + 10.0) / float(TILE)),
		floori((position.y + 28.0) / float(TILE)),
	)


static func _target_tile(target: Dictionary) -> Vector2i:
	if target.has("position"):
		var position := Contract.target_position(target.get("position"))
		return Vector2i(floori((position.x + 10.0) / float(TILE)), floori((position.y + 28.0) / float(TILE)))
	if target.has("x") and target.has("y"):
		return Vector2i(int(target.get("x", 0)), int(target.get("y", 0)))
	return _invalid_tile()


static func _overlaps_any_player(tile: Vector2i, observation: Dictionary) -> bool:
	if _overlaps_player(tile, observation.get("self", {})):
		return true
	for raw_player in _as_array(observation.get("players", [])):
		if raw_player is Dictionary and _overlaps_player(tile, raw_player):
			return true
	return false


static func _overlaps_player(tile: Vector2i, raw_player: Variant) -> bool:
	if not raw_player is Dictionary:
		return false
	var player := raw_player as Dictionary
	var position := Contract.target_position(player)
	var tile_rect := Rect2(float(tile.x * TILE), float(tile.y * TILE), float(TILE), float(TILE))
	var player_rect := Rect2(position.x, position.y, float(player.get("w", 20.0)), float(player.get("h", 28.0)))
	return tile_rect.grow(-1.0).intersects(player_rect.grow(-1.0))


static func _placeable(terrain: Dictionary, x: int, y: int) -> bool:
	return _empty(terrain, x, y)


static func _empty(terrain: Dictionary, x: int, y: int) -> bool:
	var normalized := str(terrain.get("%d:%d" % [x, y], "")).to_lower()
	return normalized.is_empty() or normalized in ["air", "core.air"]


static func _solid(terrain: Dictionary, x: int, y: int) -> bool:
	var normalized := str(terrain.get("%d:%d" % [x, y], "")).to_lower()
	if normalized.is_empty() or normalized in ["air", "core.air"]:
		return false
	return not normalized.contains("water") and not normalized.contains("lava") and not normalized.contains("item.")


static func _as_array(value: Variant) -> Array:
	return value as Array if value is Array else []


static func _invalid_tile() -> Vector2i:
	return Vector2i(2147483647, 2147483647)
