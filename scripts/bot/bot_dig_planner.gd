class_name BotDigPlanner
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const Perception = preload("res://gameplay/scripts/bot/bot_perception.gd")

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


static func next_step(observation: Dictionary, explicit_route_target: Dictionary = {}) -> Dictionary:
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	if terrain.is_empty():
		return {}
	var origin := _grounded_support_tile(observation.get("self", {}), terrain)
	# A climbing/ghosted avatar can end up with its body inside wood or leaves.
	# Route searches then have no usable origin, while the ordinary gatherer
	# rejects the same block as unapproachable. Clear only the occupied body cell,
	# never the support beneath the feet; _mine_step retains tier, protection and
	# retry guards, and the host remains authoritative for the actual mine.
	if bool((observation.get("self", {}) as Dictionary).get("on_ground", false)) and _solid(terrain, origin.x, origin.y - 1):
		var occupied_clear := _mine_step(origin.x, origin.y - 1, origin, origin, observation)
		if not occupied_clear.is_empty():
			return occupied_clear
	var target := _target_tile(observation, origin, explicit_route_target)
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
			return _place_step(next_x, origin.y - 1, origin, target, observation, terrain)
		if _solid(terrain, next_x, origin.y - 2):
			return _mine_step(next_x, origin.y - 2, origin, target, observation)
		# An isolated block is still a valid landing one tile above the bot. Mining
		# it merely because the cell beneath is empty deletes the only stair and
		# drops the bot farther into a pit. A ceiling three tiles above the support
		# is outside the safety policy's mining reach, so neither can be cleared by
		# this one-step route planner.
		return {}
	if target.y > origin.y:
		# A lower destination needs a one-step descending landing, not a bridge
		# stranded at the current height. Clear only the next landing's two body
		# cells, then attach its support to the known column beneath our feet.
		for body_y in [origin.y, origin.y - 1]:
			if _solid(terrain, next_x, body_y):
				return _mine_step(next_x, body_y, origin, target, observation)
		if not _solid(terrain, next_x, origin.y + 1):
			return _place_down_step(next_x, origin.y + 1, origin, target, observation, terrain)
		return {}
	# Clear the two-cell player corridor before trying to walk through a wall.
	for head_y in [origin.y - 1, origin.y - 2]:
		if _solid(terrain, next_x, head_y):
			return _mine_step(next_x, head_y, origin, target, observation)
	# If the next column has no floor, bridge a bounded gap.  The next decision
	# will see the new support block and continue one block at a time.
	if not _solid(terrain, next_x, origin.y):
		if _solid(terrain, next_x, origin.y + 1):
			return _place_step(next_x, origin.y, origin, target, observation, terrain)
		# An unsupported void is unsafe to bridge without a nearby lower support.
		return {}
	return {}


## When ordinary route search has no useful escape waypoint, a grounded avatar in a
## shallow excavation can still work toward a *seen* higher landing. Return
## only one ordinary, host-checked dig/step action; never invent a route through
## unknown terrain or choose a landing beside harmful fluid.
static func trapped_upward_step(observation: Dictionary) -> Dictionary:
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if not bool(self_state.get("on_ground", false)):
		return {}
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _grounded_support_tile(self_state, terrain)
	if not _solid(terrain, origin.x, origin.y):
		return {}
	var waypoints: Array = observation.get("safe_exploration_waypoints", []) if observation.get("safe_exploration_waypoints", []) is Array else []
	if _has_useful_escape_waypoint(waypoints, observation, self_state, origin):
		return {}
	var best := _invalid_tile()
	var best_score := 999999
	for raw_tile in observation.get("terrain_tiles", []):
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var candidate := Vector2i(int(tile.get("x", 0)), int(tile.get("y", 0)))
		var dx := absi(candidate.x - origin.x)
		var rise := origin.y - candidate.y
		if dx < 1 or dx > 4 or rise < 1 or rise > 3 or not _solid(terrain, candidate.x, candidate.y):
			continue
		if not _known_empty_cell(observation, terrain, candidate.x, candidate.y - 1) or not _known_empty_cell(observation, terrain, candidate.x, candidate.y - 2):
			continue
		if _overlaps_any_player(candidate, observation) or _near_harmful_fluid(candidate, observation):
			continue
		var score := dx * 4 + rise
		if score < best_score:
			best = candidate
			best_score = score
	if best != _invalid_tile():
		# With no verified route, an adjacent constructed roof may be the only
		# obstruction above an otherwise solid step. Allow clearing that roof while
		# _mine_step still preserves stations, floors, player support and lava seals.
		var recovery_observation := observation.duplicate(false)
		recovery_observation["allow_escape_clear_protected"] = true
		var upward := next_step(recovery_observation, {"x": float(best.x * TILE + 6), "y": float(best.y * TILE - 28)})
		if not upward.is_empty():
			return upward
	# A one-high wall can seal the only same-level floor corridor while a higher
	# landing is still out of reach. Clear its *body* cell only when its own
	# support remains intact and known. This opens a reversible walk route in the
	# next authoritative snapshot; it never mines the floor under either player.
	var directions := [1, -1]
	if best != _invalid_tile() and best.x < origin.x:
		directions = [-1, 1]
	for direction in directions:
		var side_x: int = origin.x + direction
		var side_floor := Vector2i(side_x, origin.y)
		var blocker := Vector2i(side_x, origin.y - 1)
		if (
			not _solid(terrain, side_floor.x, side_floor.y)
			or not _solid(terrain, blocker.x, blocker.y)
			or not _known_empty_cell(observation, terrain, side_x, origin.y - 2)
			or _near_harmful_fluid(side_floor, observation)
			or _overlaps_any_player(blocker, observation)
		):
			continue
		var clear := _mine_step(blocker.x, blocker.y, origin, side_floor, observation)
		if not clear.is_empty():
			return clear
	return {}


static func _has_useful_escape_waypoint(waypoints: Array, observation: Dictionary, self_state: Dictionary, origin: Vector2i) -> bool:
	if waypoints.is_empty():
		return false
	var players: Array = observation.get("players", []) if observation.get("players", []) is Array else []
	var nearest_player := Vector2.ZERO
	var player_distance := INF
	var self_position := Vector2(float(self_state.get("x", 0.0)), float(self_state.get("y", 0.0)))
	for raw_player in players:
		if not raw_player is Dictionary or not bool((raw_player as Dictionary).get("alive", true)):
			continue
		var player := raw_player as Dictionary
		var position := Vector2(float(player.get("x", 0.0)), float(player.get("y", 0.0)))
		var distance := self_position.distance_to(position)
		if distance < player_distance:
			player_distance = distance
			nearest_player = position
	for raw_waypoint in waypoints:
		if not raw_waypoint is Dictionary:
			continue
		var waypoint := raw_waypoint as Dictionary
		if not bool(waypoint.get("reachable", true)):
			continue
		var raw_tile: Variant = waypoint.get("support_tile", [])
		if not raw_tile is Array or (raw_tile as Array).size() < 2:
			continue
		var tile := Vector2i(int((raw_tile as Array)[0]), int((raw_tile as Array)[1]))
		if tile.y < origin.y:
			return true
		if player_distance == INF:
			return true
		var candidate := Vector2(float(tile.x * TILE + 6), float(tile.y * TILE - 28))
		if candidate.distance_to(nearest_player) + float(TILE) * 0.5 < player_distance:
			return true
	return false


## If a narrow raised platform has no useful round-trip waypoint, open a
## one-block lower, supported landing beside it. Removing the adjacent upper
## floor keeps the bot's own support intact and makes a reversible step down;
## never excavate a station, another player's footing, or a fluid seal.
static func isolated_platform_descent_step(observation: Dictionary) -> Dictionary:
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if not bool(self_state.get("on_ground", false)) or bool(observation.get("pvp_world", false)):
		return {}
	var waypoints: Array = observation.get("safe_exploration_waypoints", []) if observation.get("safe_exploration_waypoints", []) is Array else []
	if waypoints.size() > 1:
		return {}
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _grounded_support_tile(self_state, terrain)
	if not _solid(terrain, origin.x, origin.y):
		return {}
	for direction in [-1, 1]:
		var neighbor := origin + Vector2i(direction, 0)
		var landing := neighbor + Vector2i.DOWN
		if (
			not _solid(terrain, landing.x, landing.y)
			or not _known_empty_cell(observation, terrain, neighbor.x, neighbor.y - 1)
			or not _known_empty_cell(observation, terrain, neighbor.x, neighbor.y - 2)
			or _near_harmful_fluid(landing, observation)
			or _overlaps_any_player(landing, observation)
		):
			continue
		if _solid(terrain, neighbor.x, neighbor.y):
			var clearance := observation.duplicate(false)
			clearance["allow_isolated_platform_descent"] = true
			var mine := _mine_step(neighbor.x, neighbor.y, origin, landing, clearance)
			if not mine.is_empty():
				return mine
		elif _known_empty_cell(observation, terrain, neighbor.x, neighbor.y):
			var blocked: Dictionary = observation.get("blocked_action_targets", {}) if observation.get("blocked_action_targets", {}) is Dictionary else {}
			var move_id := "platform:descend:%d:%d" % [landing.x, landing.y]
			if int(blocked.get(move_id, 0)) > int(observation.get("observed_at_msec", 0)):
				continue
			var body_width := float(self_state.get("w", 20.0))
			var body_height := float(self_state.get("h", 28.0))
			return {
				"action": Contract.ACTION_MOVE_TO,
				"goal": Contract.GOAL_DIG_ROUTE,
				"target_id": move_id,
				"target": {
					"id": move_id,
					"position": [float(landing.x * TILE) + (float(TILE) - body_width) * 0.5, float(landing.y * TILE) - body_height],
					"support_tile": [landing.x, landing.y],
					"reachable": true,
				},
				"commit_for_ms": 2200,
				"confidence": 0.7,
			}
	return {}


static func _near_harmful_fluid(candidate: Vector2i, observation: Dictionary) -> bool:
	for raw_tile in observation.get("terrain_tiles", []):
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		if not bool(tile.get("harmful_fluid", false)) and not str(tile.get("block_name", tile.get("content_id", ""))).to_lower().contains("lava"):
			continue
		if absi(int(tile.get("x", 0)) - candidate.x) <= 1 and absi(int(tile.get("y", 0)) - candidate.y) <= 1:
			return true
	return false


static func _grounded_support_tile(raw_self: Variant, terrain: Dictionary) -> Vector2i:
	var center := _support_tile(raw_self)
	if _solid(terrain, center.x, center.y) or not raw_self is Dictionary:
		return center
	var self_state := raw_self as Dictionary
	if not bool(self_state.get("on_ground", false)):
		return center
	var left := float(self_state.get("x", 0.0))
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var foot_left := floori((left + 3.0) / float(TILE))
	var foot_right := floori((left + width - 3.001) / float(TILE))
	for x in range(foot_left, foot_right + 1):
		if _solid(terrain, x, center.y):
			return Vector2i(x, center.y)
	return center


static func _target_tile(observation: Dictionary, origin: Vector2i, explicit_route_target: Dictionary = {}) -> Vector2i:
	if not explicit_route_target.is_empty():
		# Explicit route targets are live player observations in pixel coordinates,
		# unlike resource targets which may already contain tile coordinates.
		return _support_tile(explicit_route_target)
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
	# During a duel excavation is only allowed toward the currently observed
	# opponent. A missing player snapshot must not make the planner reinterpret a
	# nearby ore block as a useful combat route.
	if bool(observation.get("pvp_world", false)):
		return _invalid_tile()
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
	if _retry_cooldown_active(observation, x, y) or not _can_clear_route_block(observation, x, y):
		return {}
	# Match BotSafetyPolicy's two-tile reach from the *actual* body centre, not
	# the re-anchored support cell. A high ceiling above a pit can otherwise be
	# proposed and rejected on every policy tick without ever making progress.
	var body_tile := _support_tile(observation.get("self", {}))
	if absi(x - body_tile.x) > 2 or absi(y - body_tile.y) > 2:
		return {}
	# A functional station is not expendable route filler, including after a
	# reconnect when the short action history no longer remembers who placed it.
	if str(_terrain_tile(observation, x, y).get("block_name", "")).to_lower().trim_prefix("core.") in ["workbench", "furnace"]:
		return {}
	if _is_protected_build_cell(observation, x, y):
		# Never excavate a cell the session deliberately constructed.  Without this
		# guard a placed step (for example a workbench) reads back as a solid
		# blocker and the planner places then mines the same tile forever.
		# After repeated failed movement, one adjacent non-station wall block may
		# be removed to escape a pocket the bot built around itself. Never clear a
		# floor/support or a workbench/furnace; the descent guard below still applies.
		var upper_wall_clear: bool = bool(observation.get("allow_escape_clear_protected", false)) and abs(x - origin.x) == 1 and y in [origin.y - 1, origin.y - 2]
		var adjacent_descent_clear: bool = bool(observation.get("allow_isolated_platform_descent", false)) and abs(x - origin.x) == 1 and y == origin.y and _solid(_terrain_map(observation.get("terrain_tiles", [])), x, y + 1)
		if not (upper_wall_clear or adjacent_descent_clear) or str(_terrain_tile(observation, x, y).get("block_name", "")) not in SUPPORT_BLOCK_NAMES:
			return {}
	if _is_descent_return_support(observation, x, y):
		# The generic obstacle planner must honor the same return-route invariant
		# as the descent planner. Otherwise safety rejects this identical MINE
		# proposal on every tick, preventing all lower-priority activities.
		return {}
	var mine_target := {
		"id": "dig:%d:%d" % [x, y],
		"x": x,
		"y": y,
		"dig_route": true,
		"combat_route": bool(observation.get("pvp_world", false)),
		"route_target": [target.x, target.y],
		"origin": [origin.x, origin.y],
		"reachable": true,
		"harvest_tier": _terrain_harvest_tier(observation, x, y),
		"hardness": _terrain_hardness(observation, x, y),
	}
	# Safety will check the same invariant again at execution time. Checking it
	# before proposing avoids hundreds of rejected decisions per minute when a
	# potential route cell also supports the bot or the stationary host.
	if not Perception.mine_target_is_safe(observation, mine_target):
		return {}
	return {
		"action": Contract.ACTION_MINE,
		"goal": Contract.GOAL_DIG_ROUTE,
		"target_id": "dig:%d:%d" % [x, y],
		"target": mine_target,
		"commit_for_ms": 1200,
		"confidence": 0.74,
	}


static func _retry_cooldown_active(observation: Dictionary, x: int, y: int) -> bool:
	var blocked_targets: Dictionary = observation.get("blocked_action_targets", {}) if observation.get("blocked_action_targets", {}) is Dictionary else {}
	var now_msec := int(observation.get("observed_at_msec", Time.get_ticks_msec()))
	return int(blocked_targets.get("tile:%d:%d" % [x, y], 0)) > now_msec


static func _is_protected_build_cell(observation: Dictionary, x: int, y: int) -> bool:
	var key := "%d:%d" % [x, y]
	var protected_cells: Variant = observation.get("protected_build_cells", {})
	if protected_cells is Dictionary and (protected_cells as Dictionary).has(key):
		return true
	var raw_history: Variant = observation.get("action_history", [])
	if not raw_history is Array:
		return false
	for raw_entry in raw_history:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		if str(entry.get("action", "")) != Contract.ACTION_PLACE:
			continue
		var parts := str(entry.get("target_id", "")).split(":")
		if parts.size() < 3 or not parts[-1].is_valid_int() or not parts[-2].is_valid_int():
			continue
		if int(parts[-2]) == x and int(parts[-1]) == y:
			return true
	return false


static func _is_descent_return_support(observation: Dictionary, x: int, y: int) -> bool:
	var protected_supports: Array = []
	var raw_supports: Variant = observation.get("descent_protected_supports", [])
	if raw_supports is Array:
		protected_supports.append_array(raw_supports as Array)
	var descent_plan: Dictionary = observation.get("descent_plan", {}) if observation.get("descent_plan", {}) is Dictionary else {}
	raw_supports = descent_plan.get("protected_supports", [])
	if raw_supports is Array:
		protected_supports.append_array(raw_supports as Array)
	for raw_support in protected_supports:
		if not raw_support is Array or (raw_support as Array).size() < 2:
			continue
		var support := raw_support as Array
		if int(support[0]) == x and int(support[1]) == y:
			return true
	return false


static func _place_step(
	x: int,
	y: int,
	origin: Vector2i,
	target: Vector2i,
	observation: Dictionary,
	terrain: Dictionary,
) -> Dictionary:
	if (
		not _known_empty_cell(observation, terrain, x, y)
		or not _solid(terrain, x, y + 1)
		or not _known_empty_cell(observation, terrain, x, y - 1)
		or not _known_empty_cell(observation, terrain, x, y - 2)
		or _retry_cooldown_active(observation, x, y)
		or _overlaps_any_player(Vector2i(x, y), observation)
	):
		return {}
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
			"combat_route": bool(observation.get("pvp_world", false)),
			"route_target": [target.x, target.y],
			"origin": [origin.x, origin.y],
		},
		"block": block,
		"commit_for_ms": 900,
		"confidence": 0.7,
	}


static func _place_down_step(x: int, y: int, origin: Vector2i, target: Vector2i, observation: Dictionary, terrain: Dictionary) -> Dictionary:
	if (
		y != origin.y + 1
		or not _solid(terrain, origin.x, y)
		or not _known_empty_cell(observation, terrain, x, y)
		or not _known_empty_cell(observation, terrain, x, y - 1)
		or not _known_empty_cell(observation, terrain, x, y - 2)
		or _retry_cooldown_active(observation, x, y)
		or _overlaps_any_player(Vector2i(x, y), observation)
	):
		return {}
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
			"combat_route": bool(observation.get("pvp_world", false)),
			"route_target": [target.x, target.y],
			"origin": [origin.x, origin.y],
		},
		"block": block,
		"commit_for_ms": 900,
		"confidence": 0.74,
	}


static func _upward_step(origin: Vector2i, x: int, terrain: Dictionary, observation: Dictionary) -> Dictionary:
	if _solid(terrain, x, origin.y - 1):
		return {}
	return _place_step(x, origin.y - 1, origin, Vector2i(x, origin.y - 2), observation, terrain)


static func _known_empty_cell(observation: Dictionary, terrain: Dictionary, x: int, y: int) -> bool:
	var key := "%d:%d" % [x, y]
	var known_cells: Dictionary = observation.get("terrain_known_cells", {}) if observation.get("terrain_known_cells", {}) is Dictionary else {}
	if not known_cells.has(key):
		return false
	var block_name := str(terrain.get(key, "")).to_lower()
	return block_name.is_empty() or block_name in ["air", "core.air"]


static func _overlaps_any_player(tile: Vector2i, observation: Dictionary) -> bool:
	if _overlaps_player(tile, observation.get("self", {})):
		return true
	var players: Array = observation.get("players", []) if observation.get("players", []) is Array else []
	for raw_player in players:
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
	# Match WorldSim.place_block's strict rectangle overlap. Shrinking both
	# rectangles let a sub-pixel body intrusion pass here while the host rejected
	# the exact same placement on every retry.
	return tile_rect.intersects(player_rect)


static func _has_equipped_mining_tool(observation: Dictionary) -> bool:
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var equipped := str(equipment.get("hand", ""))
	return equipped in MINING_TOOL_NAMES


static func _can_clear_route_block(observation: Dictionary, x: int, y: int) -> bool:
	var tile := _terrain_tile(observation, x, y)
	if tile.is_empty() or not tile.has("harvest_tier"):
		# No authoritative harvest tier is known for this cell, so keep the
		# previous conservative behaviour and require a mining tool.
		return _has_equipped_mining_tool(observation)
	var required_tier := int(tile.get("harvest_tier", 0))
	if required_tier <= 0:
		# Authoritative tier-0 blocks (dirt, sand, wood, leaves, and other
		# starter material) are harvestable bare-handed: the host's
		# WorldSim.can_harvest_block only requires active_harvest_tier >= 0.
		# This lets the bot clear its own enclosed origin without first
		# crafting a pickaxe.
		return true
	return _equipped_mining_tool_tier(observation) >= required_tier


static func _equipped_mining_tool_tier(observation: Dictionary) -> int:
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var hand := str(equipment.get("hand", ""))
	if hand.is_empty() or not hand in MINING_TOOL_NAMES:
		return 0
	var entry := _block_entry(hand)
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	if str(definition.get("category", "")) != "mining_tool":
		return 0
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return int(effects.get("harvest_tier", 0))


static func _terrain_tile(observation: Dictionary, x: int, y: int) -> Dictionary:
	var raw_tiles: Variant = observation.get("terrain_tiles", [])
	if not raw_tiles is Array:
		return {}
	for raw_tile in raw_tiles:
		if raw_tile is Dictionary and int((raw_tile as Dictionary).get("x", 0)) == x and int((raw_tile as Dictionary).get("y", 0)) == y:
			return raw_tile as Dictionary
	return {}


static func _block_entry(block_name: String) -> Dictionary:
	var loop := Engine.get_main_loop()
	if loop == null or not loop.has_method("get_root"):
		return {}
	var root: Node = loop.get_root()
	var defs := root.get_node_or_null("BlockDefs")
	if defs == null or not defs.get("BLOCKS") is Dictionary:
		return {}
	var blocks: Dictionary = defs.get("BLOCKS")
	return blocks.get(block_name, {}) if blocks.get(block_name, {}) is Dictionary else {}


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
	# Wood/leaves are included so the starter-tooling fallback has a bounded,
	# useful route target when the bot is enclosed and needs its first tool.
	for token in ["ore", "crystal", "gem", "coal", "copper", "iron", "gold", "diamond", "obsidian", "aegisite", "stone", "flint", "wood", "log", "leaves"]:
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
