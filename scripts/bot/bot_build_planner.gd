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
# The only purposeless expansion allowed by policy is a tiny safety margin
# around the single regenerative source in One Block. Route-backed bridges and
# stairs do not use this cap because they have an explicit destination.
const DESIRED_PLATFORM_WIDTH := 3
const MAX_PLACEMENT_REACH_TILES := 2
const MAX_GOAL_DISTANCE_TILES := 10
const SUPPORT_BLOCK_NAMES: PackedStringArray = [
	"stone_bricks", "cobblestone", "stone", "dirt", "grass", "packed_ice",
]
const PLANK_BLOCK_NAMES: PackedStringArray = [
	"planks", "palm_planks", "pine_planks", "weeping_planks",
]
const SKYBLOCK_HOME_EXPANSION_LIMIT := 4
const SKYBLOCK_LEAF_RESERVE := 4
const SKYBLOCK_LAVA_CLEARANCE_TILES := 2
const FLOATING_BRIDGE_RETURN_RESERVE := 4
const ESCAPE_BRIDGE_FAILURE_COOLDOWN_MSEC := 10_000


## When retreat is verified impossible because a one-cell fluid gap separates
## the bot from dry ground, put a single support *above* the source. This keeps
## island stone generators intact. The follow-up move uses ordinary physics
## routing and stops if its jump/drop cannot be validated.
static func urgent_fluid_escape_bridge_step(observation: Dictionary, threat: Dictionary) -> Dictionary:
	if bool(observation.get("placement_pending", false)):
		return {}
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if not bool(self_state.get("on_ground", false)):
		return {}
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _supported_origin(self_state, terrain)
	if not _solid(terrain, origin.x, origin.y):
		return {}
	var self_center := Contract.target_position(self_state) + Vector2(float(self_state.get("w", 20.0)) * 0.5, 0.0)
	var threat_center := Contract.target_position(threat) + Vector2(float(threat.get("w", 20.0)) * 0.5, 0.0)
	var direction := signi(roundi(self_center.x - threat_center.x))
	if direction == 0:
		return {}
	var gap_x := origin.x + direction
	var shore_x := origin.x + direction * 2
	var row := origin.y
	var fluid := str(terrain.get("%d:%d" % [gap_x, row], "")).to_lower().trim_prefix("core.")
	if fluid not in ["water", "lava"]:
		return {}
	var known: Dictionary = observation.get("terrain_known_cells", {}) if observation.get("terrain_known_cells", {}) is Dictionary else {}
	for cell in [Vector2i(gap_x, row - 1), Vector2i(gap_x, row - 2), Vector2i(gap_x, row - 3), Vector2i(shore_x, row), Vector2i(shore_x, row - 1), Vector2i(shore_x, row - 2)]:
		if not bool(known.get("%d:%d" % [cell.x, cell.y], false)):
			return {}
	if not _solid(terrain, shore_x, row) or not _empty(terrain, shore_x, row - 1) or not _empty(terrain, shore_x, row - 2):
		return {}
	if not _empty(terrain, gap_x, row - 2) or not _empty(terrain, gap_x, row - 3):
		return {}
	var bridge := Vector2i(gap_x, row - 1)
	var shore := Vector2i(shore_x, row)
	var move_id := "escape_bridge:shore:%d:%d" % [shore.x, shore.y]
	var now := int(observation.get("observed_at_msec", 0))
	for raw_event in _as_array(observation.get("action_history", [])):
		if not raw_event is Dictionary:
			continue
		var event := raw_event as Dictionary
		if str(event.get("action", "")) == Contract.ACTION_MOVE_TO and str(event.get("target_id", "")) == move_id and str(event.get("phase", "")) == "finished" and str(event.get("reason", "")) in ["unsafe_jump_route", "unsafe_drop_route", "route_unreachable", "edge_guard", "blocked_obstacle"] and now - int(event.get("at_msec", 0)) < ESCAPE_BRIDGE_FAILURE_COOLDOWN_MSEC:
			return {}
	if _solid(terrain, bridge.x, bridge.y):
		return {
			"action": Contract.ACTION_MOVE_TO,
			"target": {"id": move_id, "position": [float(shore.x * TILE + 6), float(shore.y * TILE - 28)], "support_tile": [shore.x, shore.y], "escape_bridge": true},
		}
	if not _empty(terrain, bridge.x, bridge.y) or _overlaps_any_player(bridge, observation):
		return {}
	var blocked: Dictionary = observation.get("blocked_action_targets", {}) if observation.get("blocked_action_targets", {}) is Dictionary else {}
	if int(blocked.get("tile:%d:%d" % [bridge.x, bridge.y], 0)) > now:
		return {}
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	for block_name in ["dirt", "planks", "palm_planks", "pine_planks", "weeping_planks", "cobblestone", "stone"]:
		if int(inventory.get(block_name, 0)) > 0:
			var placement := _placement(bridge, origin, shore, block_name, "escape_over_fluid")
			placement["action"] = Contract.ACTION_PLACE
			return placement
	return {}


## Pick up a nearby *source*, never flowing fluid. This is a local clearance
## action, not a reason to walk into a pool or dismantle an island generator.
static func obstructing_fluid_source_step(observation: Dictionary) -> Dictionary:
	var mode := str(observation.get("world_mode", "")).to_lower()
	if mode in ["skyblock", "floating_islands"]:
		return {}
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if not bool(self_state.get("on_ground", false)):
		return {}
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _supported_origin(self_state, terrain)
	if not _solid(terrain, origin.x, origin.y):
		return {}
	var body_x := floori((float(self_state.get("x", 0.0)) + float(self_state.get("w", 20.0)) * 0.5) / float(TILE))
	var body_y := floori((float(self_state.get("y", 0.0)) + float(self_state.get("h", 28.0)) * 0.5) / float(TILE))
	var body_left := floori(float(self_state.get("x", 0.0)) / float(TILE))
	var body_right := floori((float(self_state.get("x", 0.0)) + float(self_state.get("w", 20.0)) - 0.001) / float(TILE))
	if not _empty(terrain, body_x, body_y) or not _empty(terrain, origin.x, origin.y - 1):
		return {}
	var blocked: Dictionary = observation.get("blocked_action_targets", {}) if observation.get("blocked_action_targets", {}) is Dictionary else {}
	var now := int(observation.get("observed_at_msec", 0))
	var best: Dictionary = {}
	var best_priority := -1
	for raw_tile in _as_array(observation.get("terrain_tiles", [])):
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var name := str(tile.get("block_name", "")).to_lower().trim_prefix("core.")
		if name not in ["water", "lava"] or int(tile.get("fluid_level", -1)) != 0 or bool(tile.get("regenerates_on_mine", false)):
			continue
		var x := int(tile.get("x", 0))
		var y := int(tile.get("y", 0))
		if y != origin.y or absi(x - origin.x) != 1 or not _solid(terrain, x, y + 1) or (x >= body_left and x <= body_right):
			continue
		var retreat_x := origin.x - signi(x - origin.x)
		if not _solid(terrain, retreat_x, origin.y) or not _empty(terrain, retreat_x, origin.y - 1) or not _empty(terrain, retreat_x, origin.y - 2):
			continue
		if int(blocked.get("tile:%d:%d" % [x, y], 0)) > now:
			continue
		var priority := 2 if name == "lava" else 1
		if priority > best_priority:
			best_priority = priority
			best = {
				"id": "tile:%d:%d" % [x, y], "x": x, "y": y,
				"block_name": name, "content_id": "core.%s" % name,
				"fluid_level": 0, "harvest_tier": 0,
				"hardness": float(tile.get("hardness", 5.0 if name == "lava" else 4.0)),
				"position": [float(x * TILE + TILE / 2), float(y * TILE + TILE / 2)],
				"reachable": true, "reason": "obstructing_fluid_source",
			}
	return {"action": Contract.ACTION_MINE, "target": best} if not best.is_empty() else {}


## A finite Skyblock island needs a usable work area even when no distant
## resource/player supplies a route destination. Build only from a reachable
## exterior edge, keep a material reserve, and stop after a bounded project.
## A chest on the new pad makes the extension a functional outpost rather than
## a directionless bridge. The host still validates every placement.
static func skyblock_home_step(observation: Dictionary, island_mode: String = "skyblock") -> Dictionary:
	if island_mode not in ["skyblock", "floating_islands"] or str(observation.get("world_mode", "")).to_lower() != island_mode or bool(observation.get("placement_pending", false)):
		return {}
	var expansion_reason := "skyblock_expand" if island_mode == "skyblock" else "floating_island_expand"
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if not bool(self_state.get("on_ground", false)):
		return {}
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _supported_origin(self_state, terrain)
	if not _solid(terrain, origin.x, origin.y):
		return {}
	var protected: Dictionary = observation.get("protected_build_cells", {}) if observation.get("protected_build_cells", {}) is Dictionary else {}
	var blocked: Dictionary = observation.get("blocked_action_targets", {}) if observation.get("blocked_action_targets", {}) is Dictionary else {}
	var now := int(observation.get("observed_at_msec", 0))
	var completed: Array[Vector2i] = []
	for raw_key in protected:
		var record: Dictionary = protected[raw_key] if protected[raw_key] is Dictionary else {}
		if str(record.get("reason", "")) != expansion_reason or not bool(record.get("confirmed", false)):
			continue
		var parts := str(raw_key).split(":")
		if parts.size() == 2:
			completed.append(Vector2i(int(parts[0]), int(parts[1])))
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	if completed.size() >= 2 and int(inventory.get("chest", 0)) > 0:
		completed.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return abs(a.x - origin.x) < abs(b.x - origin.x))
		for foundation in completed:
			var chest_tile := foundation + Vector2i.UP
			if not _ground_anchored_worksite(terrain, protected, foundation) or not _empty(terrain, chest_tile.x, chest_tile.y):
				continue
			if not _empty(terrain, chest_tile.x, chest_tile.y - 1) or _overlaps_any_player(chest_tile, observation):
				continue
			if _lava_near(terrain, chest_tile, SKYBLOCK_LAVA_CLEARANCE_TILES):
				continue
			if int(blocked.get("tile:%d:%d" % [chest_tile.x, chest_tile.y], 0)) > now:
				continue
			if absi(foundation.x - origin.x) <= MAX_PLACEMENT_REACH_TILES and absi(foundation.y - origin.y) <= MAX_PLACEMENT_REACH_TILES:
				var chest := _placement(chest_tile, origin, _invalid_tile(), "chest", "skyblock_home_chest" if island_mode == "skyblock" else "floating_island_home_chest")
				chest["action"] = Contract.ACTION_PLACE
				return chest
			var chest_route := _known_safe_worksite(observation, foundation)
			if not chest_route.is_empty():
				return chest_route
	if completed.size() >= SKYBLOCK_HOME_EXPANSION_LIMIT:
		return {}
	var block_name := _skyblock_home_support_block(inventory)
	if block_name.is_empty():
		return {}
	var best := {}
	var best_score := INF
	var worksites: Array[Vector2i] = [origin]
	# A neighboring edge can be placed from the current supported foot without
	# walking onto the edge at all. The round-trip waypoint graph deliberately
	# omits some edge cells; that must not hide a safe two-tile-reach placement.
	for offset in [-2, -1, 1, 2]:
		var nearby := origin + Vector2i(offset, 0)
		var connected := true
		for step_x in range(mini(origin.x, nearby.x), maxi(origin.x, nearby.x) + 1):
			if not _solid(terrain, step_x, origin.y) or not _empty(terrain, step_x, origin.y - 1) or not _empty(terrain, step_x, origin.y - 2):
				connected = false
				break
		if connected:
			worksites.append(nearby)
	for raw_waypoint in _as_array(observation.get("safe_exploration_waypoints", [])):
		if not raw_waypoint is Dictionary:
			continue
		var waypoint := raw_waypoint as Dictionary
		if not bool(waypoint.get("reachable", false)):
			continue
		var raw_tile: Array = waypoint.get("support_tile", []) if waypoint.get("support_tile", []) is Array else []
		if raw_tile.size() == 2:
			worksites.append(Vector2i(int(raw_tile[0]), int(raw_tile[1])))
	for worksite in worksites:
		if not _ground_anchored_worksite(terrain, protected, worksite) or not _empty(terrain, worksite.x, worksite.y - 1) or not _empty(terrain, worksite.x, worksite.y - 2):
			continue
		if _worksite_corridor_has_lava(terrain, origin, worksite):
			continue
		for direction in [-1, 1]:
			var target := worksite + Vector2i(direction, 0)
			if not _empty(terrain, target.x, target.y) or not _empty(terrain, target.x, target.y + 1) or not _empty(terrain, target.x, target.y + 2):
				continue
			if not _empty(terrain, target.x, target.y - 1) or not _empty(terrain, target.x, target.y - 2):
				continue
			if _lava_near(terrain, target, SKYBLOCK_LAVA_CLEARANCE_TILES) or _overlaps_any_player(target, observation):
				continue
			if protected.has("%d:%d" % [target.x, target.y]) or int(blocked.get("tile:%d:%d" % [target.x, target.y], 0)) > now:
				continue
			var score := origin.distance_to(worksite) + float(completed.size()) * 0.01
			if score >= best_score:
				continue
			best_score = score
			if absi(worksite.x - origin.x) <= MAX_PLACEMENT_REACH_TILES and absi(worksite.y - origin.y) <= MAX_PLACEMENT_REACH_TILES:
				best = _placement(target, origin, _invalid_tile(), block_name, expansion_reason)
				best["action"] = Contract.ACTION_PLACE
			else:
				best = _known_safe_worksite(observation, worksite)
	return best


## When a full inter-island span is not yet affordable, use expendable local
## material for a small anchored work pad instead of waiting indefinitely.
## This shares the same dry-ground, return-route and material-reserve guards as
## Skyblock; it does not claim to have completed a bridge to another island.
static func floating_island_home_step(observation: Dictionary) -> Dictionary:
	return skyblock_home_step(observation, "floating_islands")


## A bridge has a real destination, unlike a decorative edge extension.  For
## Every selected span receives a reversible one-step-at-a-time ramp, including
## when the destination shore sits above or below the current island.
## The project keeps its source/target when the avatar is partway across.
static func floating_island_bridge_step(observation: Dictionary) -> Dictionary:
	if str(observation.get("world_mode", "")).to_lower() != "floating_islands" or bool(observation.get("placement_pending", false)):
		return {}
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if not bool(self_state.get("on_ground", false)):
		return {}
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _supported_origin(self_state, terrain)
	if not _solid(terrain, origin.x, origin.y):
		return {}
	var raw_layout: Array = _as_array(observation.get("floating_islands", []))
	if raw_layout.size() < 2 or raw_layout.size() > 32:
		return {}
	var project: Dictionary = observation.get("build_project_state", {}) if observation.get("build_project_state", {}) is Dictionary else {}
	var active := str(project.get("status", "")) == "active" and str(project.get("target_kind", "")) == "island"
	var source: Dictionary = {}
	var target: Dictionary = {}
	if active:
		for raw_island in raw_layout:
			if not raw_island is Dictionary:
				continue
			var island := raw_island as Dictionary
			if int(island.get("x", 2147483647)) == int(project.get("source_x", 2147483647)) and int(island.get("y", 2147483647)) == int(project.get("source_y", 2147483647)):
				source = island
			if int(island.get("x", 2147483647)) == int(project.get("target_x", 2147483647)) and int(island.get("y", 2147483647)) == int(project.get("target_y", 2147483647)):
				target = island
		if source.is_empty() or target.is_empty():
			return {}
	else:
		for raw_island in raw_layout:
			if not raw_island is Dictionary:
				continue
			var island := raw_island as Dictionary
			var half_width := int(island.get("half_width", 0))
			if half_width < 2 or half_width > 16:
				continue
			if origin.y == int(island.get("y", 2147483647)) and absi(origin.x - int(island.get("x", 0))) <= half_width:
				source = island
				break
		if source.is_empty() or not _ground_anchored_worksite(terrain, {}, origin):
			return {}
		var visited: Dictionary = observation.get("visited_floating_islands", {}) if observation.get("visited_floating_islands", {}) is Dictionary else {}
		var best_cost := 2147483647
		for raw_island in raw_layout:
			if not raw_island is Dictionary:
				continue
			var island := raw_island as Dictionary
			if island == source:
				continue
			if bool(visited.get("%d:%d" % [int(island.get("x", 0)), int(island.get("y", 0))], false)):
				continue
			var direction := signi(int(island.get("x", 0)) - int(source.get("x", 0)))
			if direction == 0:
				continue
			var plan := floating_island_ramp_plan(source, island)
			if plan.is_empty() or plan.size() >= best_cost:
				continue
			var first: Dictionary = plan[0]
			var first_tile: Array = first.get("tile", [])
			var first_worksite: Array = first.get("worksite", [])
			if first_tile.size() != 2 or first_worksite.size() != 2:
				continue
			var tile := Vector2i(int(first_tile[0]), int(first_tile[1]))
			var worksite := Vector2i(int(first_worksite[0]), int(first_worksite[1]))
			if not _solid(terrain, worksite.x, worksite.y) or not _empty(terrain, tile.x, tile.y):
				continue
			if _lava_near(terrain, tile, SKYBLOCK_LAVA_CLEARANCE_TILES) or _worksite_corridor_has_lava(terrain, origin, worksite):
				continue
			if _floating_bridge_block(observation, plan.size()).is_empty():
				continue
			best_cost = plan.size()
			target = island
		if target.is_empty():
			return {}
	var direction := signi(int(target.get("x", 0)) - int(source.get("x", 0)))
	var target_row := int(target.get("y", 0))
	if direction == 0:
		return {}
	var row := int(source.get("y", 0))
	var far_shore_x := int(target.get("x", 0)) - direction * int(target.get("half_width", 0))
	var plan := floating_island_ramp_plan(source, target)
	if plan.is_empty():
		return {}
	var confirmed := maxi(0, int(project.get("confirmed_placements", 0))) if active else 0
	if confirmed >= plan.size():
		if not _solid(terrain, far_shore_x, target_row) or not _empty(terrain, far_shore_x, target_row - 1) or not _empty(terrain, far_shore_x, target_row - 2):
			return {}
		if absi(origin.x - far_shore_x) <= 1 and origin.y == target_row:
			return {"project_complete": true, "project_id": str(project.get("id", ""))} if active else {}
		return {
			"action": Contract.ACTION_MOVE_TO,
			"id": "island:arrive:%d:%d" % [far_shore_x, target_row],
			"position": [float(far_shore_x * TILE + 6), float(target_row * TILE - 28)],
			"support_tile": [far_shore_x, target_row],
		}
	var next: Dictionary = plan[confirmed]
	var raw_next: Array = next.get("tile", []) if next.get("tile", []) is Array else []
	var raw_worksite: Array = next.get("worksite", []) if next.get("worksite", []) is Array else []
	if raw_next.size() != 2 or raw_worksite.size() != 2:
		return {}
	var next_tile := Vector2i(int(raw_next[0]), int(raw_next[1]))
	var worksite := Vector2i(int(raw_worksite[0]), int(raw_worksite[1]))
	var block_name := _floating_bridge_block(observation, plan.size() - confirmed)
	if block_name.is_empty():
		return {}
	# A player may be standing on the nominal shore worksite. The next bridge
	# cell remains in reach from one cell farther inland, so stage there when it
	# is solid and clear instead of repeatedly walking into that player.
	if _overlaps_other_player(worksite + Vector2i.UP, observation):
		var inland_worksite := worksite + Vector2i(-direction, 0)
		if absi(inland_worksite.x - next_tile.x) > MAX_PLACEMENT_REACH_TILES:
			return {}
		worksite = inland_worksite
	if not _solid(terrain, worksite.x, worksite.y) or not _empty(terrain, worksite.x, worksite.y - 1) or not _empty(terrain, worksite.x, worksite.y - 2):
		return {}
	if _worksite_corridor_has_lava(terrain, origin, worksite):
		return {}
	if absi(origin.x - next_tile.x) > MAX_PLACEMENT_REACH_TILES or absi(origin.y - next_tile.y) > MAX_PLACEMENT_REACH_TILES:
		var worksite_id := "island:worksite:%d:%d" % [worksite.x, worksite.y]
		if _recent_build_worksite_failure(observation, worksite_id):
			return {}
		return {
			"action": Contract.ACTION_MOVE_TO,
			"id": worksite_id,
			"position": [float(worksite.x * TILE + 6), float(worksite.y * TILE - 28)],
			"support_tile": [worksite.x, worksite.y],
		}
	var known: Dictionary = observation.get("terrain_known_cells", {}) if observation.get("terrain_known_cells", {}) is Dictionary else {}
	if not known.is_empty() and not bool(known.get("%d:%d" % [next_tile.x, next_tile.y], false)):
		return {}
	if not _empty(terrain, next_tile.x, next_tile.y):
		return {}
	if str(next.get("kind", "")) != "ramp_brace" and (not _empty(terrain, next_tile.x, next_tile.y - 1) or not _empty(terrain, next_tile.x, next_tile.y - 2)):
		return {}
	if _lava_near(terrain, next_tile, SKYBLOCK_LAVA_CLEARANCE_TILES) or _overlaps_any_player(next_tile, observation):
		return {}
	var blocked: Dictionary = observation.get("blocked_action_targets", {}) if observation.get("blocked_action_targets", {}) is Dictionary else {}
	if int(blocked.get("tile:%d:%d" % [next_tile.x, next_tile.y], 0)) > int(observation.get("observed_at_msec", 0)):
		return {}
	var project_data := {
		"id": "island:%d:%d:to:%d:%d" % [int(source.get("x", 0)), row, int(target.get("x", 0)), target_row],
		"target_kind": "island",
		"target_id": "island:%d:%d" % [int(target.get("x", 0)), target_row],
		"source_x": int(source.get("x", 0)),
		"source_y": row,
		"target_x": int(target.get("x", 0)),
		"target_y": target_row,
		"target_biome": str(target.get("biome", "")),
		"goal_tile": [far_shore_x, target_row],
	}
	var placement := _placement(next_tile, origin, Vector2i(far_shore_x, target_row), block_name, "bridge_to_island", project_data)
	placement["bridge_segment_kind"] = str(next.get("kind", ""))
	placement["action"] = Contract.ACTION_PLACE
	return placement


## Tell the gathering policy how much *usable* support the cheapest reachable
## island still needs. Without this, the generic cobblestone cap makes the bot
## wait forever even though it knows a concrete bridge destination.
static func floating_island_bridge_material_shortfall(observation: Dictionary) -> int:
	if str(observation.get("world_mode", "")).to_lower() != "floating_islands":
		return 0
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if not bool(self_state.get("on_ground", false)):
		return 0
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _supported_origin(self_state, terrain)
	var raw_layout: Array = _as_array(observation.get("floating_islands", []))
	var project: Dictionary = observation.get("build_project_state", {}) if observation.get("build_project_state", {}) is Dictionary else {}
	var active := str(project.get("status", "")) == "active" and str(project.get("target_kind", "")) == "island"
	var source: Dictionary = {}
	for raw_island in raw_layout:
		if not raw_island is Dictionary:
			continue
		var island := raw_island as Dictionary
		if active:
			if int(island.get("x", 2147483647)) == int(project.get("source_x", 2147483647)) and int(island.get("y", 2147483647)) == int(project.get("source_y", 2147483647)):
				source = island
		elif origin.y == int(island.get("y", 2147483647)) and absi(origin.x - int(island.get("x", 0))) <= int(island.get("half_width", 0)):
			source = island
	if source.is_empty():
		return 0
	var visited: Dictionary = observation.get("visited_floating_islands", {}) if observation.get("visited_floating_islands", {}) is Dictionary else {}
	var best_cost := 2147483647
	for raw_island in raw_layout:
		if not raw_island is Dictionary:
			continue
		var island := raw_island as Dictionary
		if island == source or (active and (int(island.get("x", 0)) != int(project.get("target_x", 0)) or int(island.get("y", 0)) != int(project.get("target_y", 0)))):
			continue
		if not active and bool(visited.get("%d:%d" % [int(island.get("x", 0)), int(island.get("y", 0))], false)):
			continue
		var plan := floating_island_ramp_plan(source, island)
		if plan.is_empty():
			continue
		if not active:
			var first: Dictionary = plan[0]
			var first_tile: Array = first.get("tile", [])
			var first_worksite: Array = first.get("worksite", [])
			if first_tile.size() != 2 or first_worksite.size() != 2:
				continue
			var tile := Vector2i(int(first_tile[0]), int(first_tile[1]))
			var worksite := Vector2i(int(first_worksite[0]), int(first_worksite[1]))
			if not _solid(terrain, worksite.x, worksite.y) or not _empty(terrain, tile.x, tile.y) or _lava_near(terrain, tile, SKYBLOCK_LAVA_CLEARANCE_TILES):
				continue
		best_cost = mini(best_cost, maxi(0, plan.size() - int(project.get("confirmed_placements", 0))) if active else plan.size())
	if best_cost == 2147483647:
		return 0
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	return maxi(0, best_cost + FLOATING_BRIDGE_RETURN_RESERVE - _floating_bridge_usable_support_count(inventory))


## An island's observed source-water and source-lava can make renewable stone.
## The worker stays on dry natural ground *outside* one of the pools and cuts
## the three intervening surface cells from there. No source cell, avatar
## support, unobserved floor, or flooded worksite is ever a mining target.
## While an earlier jump/host correction is settling over a dry support on the
## same side, do not replace this mode objective with an unrelated long-range
## search. The ordinary host physics continues during WAIT.
static func island_stone_generator_settle_step(observation: Dictionary) -> Dictionary:
	var mode := str(observation.get("world_mode", "")).to_lower()
	if mode not in ["skyblock", "floating_islands"] or bool(observation.get("pvp_world", false)):
		return {}
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if bool(self_state.get("on_ground", false)):
		return {}
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	if int(inventory.get("cobblestone", 0)) >= 12:
		return {}
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var px := float(self_state.get("x", 0.0))
	var py := float(self_state.get("y", 0.0))
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var bottom := py + maxf(1.0, float(self_state.get("h", 28.0)))
	var body_left := floori(px / float(TILE))
	var body_right := floori((px + width - 0.001) / float(TILE))
	var tiles := _as_array(observation.get("terrain_tiles", []))
	for raw_water in tiles:
		if not raw_water is Dictionary:
			continue
		var water := raw_water as Dictionary
		if str(water.get("block_name", "")).to_lower().trim_prefix("core.") != "water" or int(water.get("fluid_level", -1)) != 0:
			continue
		for raw_lava in tiles:
			if not raw_lava is Dictionary:
				continue
			var lava := raw_lava as Dictionary
			var row := int(lava.get("y", 0))
			if str(lava.get("block_name", "")).to_lower().trim_prefix("core.") != "lava" or int(lava.get("fluid_level", -1)) != 0 or row != int(water.get("y", 0)) or absi(int(lava.get("x", 0)) - int(water.get("x", 0))) != 4:
				continue
			var work_x := int(lava.get("x", 0)) + signi(int(lava.get("x", 0)) - int(water.get("x", 0)))
			var staging_x := work_x + signi(work_x - int(lava.get("x", 0)))
			if body_left < mini(work_x, staging_x) or body_right > maxi(work_x, staging_x):
				continue
			if bottom > float(row * TILE) + 2.0 or bottom < float((row - 3) * TILE):
				continue
			var dry_landing := true
			for foot_x in range(body_left, body_right + 1):
				if not _solid(terrain, foot_x, row):
					dry_landing = false
					break
				for tile_y in range(floori(bottom / float(TILE)), row):
					var name := str(terrain.get("%d:%d" % [foot_x, tile_y], "")).to_lower()
					if name.contains("water") or name.contains("lava"):
						dry_landing = false
						break
			if dry_landing:
				return {"action": Contract.ACTION_WAIT, "reason": "island_generator_safe_settle"}
	return {}


static func island_stone_generator_step(observation: Dictionary) -> Dictionary:
	var mode := str(observation.get("world_mode", "")).to_lower()
	if mode not in ["skyblock", "floating_islands"] or bool(observation.get("pvp_world", false)):
		return {}
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if not bool(self_state.get("on_ground", false)):
		return {}
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _supported_origin(self_state, terrain)
	if not _solid(terrain, origin.x, origin.y):
		return {}
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	if int(inventory.get("cobblestone", 0)) >= 12 and (mode != "floating_islands" or floating_island_bridge_material_shortfall(observation) <= 0):
		return {}
	var sources: Array[Dictionary] = []
	for raw_tile in _as_array(observation.get("terrain_tiles", [])):
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var name := str(tile.get("block_name", "")).to_lower().trim_prefix("core.")
		if name in ["water", "lava"] and int(tile.get("fluid_level", -1)) == 0:
			sources.append({"x": int(tile.get("x", 0)), "y": int(tile.get("y", 0)), "name": name})
	var best: Dictionary = {}
	var best_distance := 2147483647
	for water in sources:
		if str(water.get("name", "")) != "water":
			continue
		for lava in sources:
			if str(lava.get("name", "")) != "lava" or int(water["y"]) != int(lava["y"]) or absi(int(water["x"]) - int(lava["x"])) != 4:
				continue
			var row := int(water["y"])
			var left := mini(int(water["x"]), int(lava["x"]))
			var right := maxi(int(water["x"]), int(lava["x"]))
			var lined := true
			for gap_x in range(left + 1, right):
				if not _solid(terrain, gap_x, row + 1):
					lined = false
					break
			if not lined:
				continue
			# The final cut is next to lava. Work only from the exterior side
			# *behind* that source, so released lava travels away from the bot.
			var lava_work_x := int(lava["x"]) + signi(int(lava["x"]) - int(water["x"]))
			for work_x in [lava_work_x]:
				var worksite := Vector2i(work_x, row)
				# The avatar is 28 px high inside one 32 px headroom tile. A
				# platform two cells above its feet does not block standing/mining;
				# requiring that extra air made a useful Skyblock worksite disappear
				# after the bot placed an overhead bridge block.
				if not _solid(terrain, work_x, row) or not _empty(terrain, work_x, row - 1):
					continue
				# A worksite one tile from the source is safe only when reached
				# along a level, supported exterior corridor. A graph waypoint can
				# otherwise route off a nearby raised station, then the guest falls
				# into the lava while the host corrects that speculative jump.
				if origin != worksite and not _generator_level_approach(terrain, origin, worksite, int(lava["x"])):
					continue
				var waypoint := {} if origin == worksite else _known_safe_worksite(observation, worksite)
				if origin != worksite and waypoint.is_empty():
					continue
				var distance := absi(origin.x - work_x) + absi(origin.y - row)
				if distance < best_distance:
					best_distance = distance
					best = {"water_x": int(water["x"]), "lava_x": int(lava["x"]), "row": row, "left": left, "right": right, "worksite": worksite, "waypoint": waypoint}
	if best.is_empty():
		return {}
	var worksite: Vector2i = best["worksite"]
	if origin != worksite:
		return best["waypoint"]
	var row := int(best["row"])
	var center := int(best["left"]) + 2
	var water_adjacent := int(best["water_x"]) + signi(center - int(best["water_x"]))
	var lava_adjacent := int(best["lava_x"]) + signi(center - int(best["lava_x"]))
	var blocked: Dictionary = observation.get("blocked_action_targets", {}) if observation.get("blocked_action_targets", {}) is Dictionary else {}
	var now := int(observation.get("observed_at_msec", 0))
	var resources := _as_array(observation.get("visible_resources", []))
	# Open the middle, water side, then lava side. Hot fluid is released only
	# after the cool side is ready to meet it; all cuts stay in mine reach.
	for gap_x in [center, water_adjacent, lava_adjacent]:
		if not _solid(terrain, gap_x, row):
			continue
		var target: Dictionary = {}
		for raw_resource in resources:
			if raw_resource is Dictionary and int((raw_resource as Dictionary).get("x", 2147483647)) == gap_x and int((raw_resource as Dictionary).get("y", 2147483647)) == row:
				target = raw_resource as Dictionary
				break
		if target.is_empty() or not bool(target.get("reachable", false)) or int(blocked.get("tile:%d:%d" % [gap_x, row], 0)) > now:
			return {}
		target = target.duplicate(true)
		target["reason"] = "island_stone_generator"
		target["generator_channel"] = true
		return {"action": Contract.ACTION_MINE, "target": target}
	return {}


static func _generator_level_approach(terrain: Dictionary, origin: Vector2i, worksite: Vector2i, lava_x: int) -> bool:
	if origin.y != worksite.y or signi(origin.x - lava_x) != signi(worksite.x - lava_x):
		return false
	for x in range(mini(origin.x, worksite.x), maxi(origin.x, worksite.x) + 1):
		if not _solid(terrain, x, worksite.y) or not _empty(terrain, x, worksite.y - 1):
			return false
	return true


static func _floating_bridge_block(observation: Dictionary, remaining: int) -> String:
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	# Every segment is reversible. Start a directed span with only the next
	# expendable block, keeping a fixed repair/return reserve; requiring the full
	# span up front stranded small islands with useful materials and no action.
	if remaining <= 0 or _floating_bridge_usable_support_count(inventory) <= FLOATING_BRIDGE_RETURN_RESERVE:
		return ""
	for name in _floating_bridge_candidates():
		var recipe_reserve := 8 if name == "cobblestone" or name.ends_with("planks") else 0
		if int(inventory.get(name, 0)) > recipe_reserve:
			return name
	return ""


static func _floating_bridge_usable_support_count(inventory: Dictionary) -> int:
	var usable := 0
	for name in _floating_bridge_candidates():
		var recipe_reserve := 8 if name == "cobblestone" or name.ends_with("planks") else 0
		usable += maxi(0, int(inventory.get(name, 0)) - recipe_reserve)
	return usable


static func _floating_bridge_candidates() -> Array[String]:
	return ["dirt", "stone_bricks", "stone", "grass", "packed_ice", "leaves", "palm_leaves", "pine_needles", "weeping_leaves", "cobblestone", "planks", "palm_planks", "pine_planks", "weeping_planks"]


static func _recent_build_worksite_failure(observation: Dictionary, target_id: String) -> bool:
	var now := int(observation.get("observed_at_msec", 0))
	for raw_entry in _as_array(observation.get("action_history", [])):
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		if str(entry.get("target_id", "")) != target_id or str(entry.get("action", "")) != Contract.ACTION_MOVE_TO:
			continue
		if str(entry.get("phase", "")) not in ["finished", "failed"] or str(entry.get("reason", "")) not in ["blocked_obstacle", "route_unreachable", "unsafe_jump_route", "edge_guard", "timeout"]:
			continue
		var age := now - int(entry.get("at_msec", -1))
		if age >= 0 and age < 30_000:
			return true
	return false


## A monotone support path across the gap. A rise uses a horizontally attached
## base plus the next step above it; a descent uses a brace below the previous
## support plus the lower step. Every transition is reversible by a one-block
## jump, and every new cell shares an edge with already solid terrain or the
## immediately preceding project cell. The first/last shore cells are natural
## terrain and are never included in the placement list.
static func floating_island_ramp_plan(source: Dictionary, target: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var direction := signi(int(target.get("x", 0)) - int(source.get("x", 0)))
	if direction == 0:
		return result
	var source_row := int(source.get("y", 0))
	var target_row := int(target.get("y", 0))
	var source_shore_x := int(source.get("x", 0)) + direction * int(source.get("half_width", 0))
	var target_shore_x := int(target.get("x", 0)) - direction * int(target.get("half_width", 0))
	var steps := absi(target_shore_x - source_shore_x)
	if steps < 2 or steps > 41 or absi(target_row - source_row) > steps:
		return result
	var previous := Vector2i(source_shore_x, source_row)
	for index in range(1, steps + 1):
		var next_row := roundi(lerpf(float(source_row), float(target_row), float(index) / float(steps)))
		var next := Vector2i(source_shore_x + direction * index, next_row)
		if absi(next.y - previous.y) > 1:
			return []
		var is_far_shore := index == steps
		if next.y < previous.y:
			# The natural target island already has a block under its shore.
			if not is_far_shore:
				result.append({"tile": [next.x, previous.y], "worksite": [previous.x, previous.y], "kind": "ramp_base"})
				result.append({"tile": [next.x, next.y], "worksite": [previous.x, previous.y], "kind": "ramp_step"})
		elif next.y > previous.y:
			# The natural source shore already has a solid layer below it.
			if index > 1:
				result.append({"tile": [previous.x, next.y], "worksite": [previous.x, previous.y], "kind": "ramp_brace"})
			if not is_far_shore:
				result.append({"tile": [next.x, next.y], "worksite": [previous.x, previous.y], "kind": "ramp_step"})
		elif not is_far_shore:
			result.append({"tile": [next.x, next.y], "worksite": [previous.x, previous.y], "kind": "bridge_floor"})
		previous = next
	return result


static func _skyblock_home_support_block(inventory: Dictionary) -> String:
	# Soil and excess foliage are expendable here; cobblestone and planks are
	# ingredients for the stone pickaxe, furnace and chest, not free filler.
	for name in ["dirt", "grass", "packed_ice", "stone_bricks"]:
		if int(inventory.get(name, 0)) > 1:
			return name
	for name in ["leaves", "palm_leaves", "pine_needles", "weeping_leaves"]:
		if int(inventory.get(name, 0)) > SKYBLOCK_LEAF_RESERVE:
			return name
	if int(inventory.get("cobblestone", 0)) > 6:
		return "cobblestone"
	if int(inventory.get("stone", 0)) > 2:
		return "stone"
	for name in PLANK_BLOCK_NAMES:
		if int(inventory.get(name, 0)) > 6:
			return name
	return ""


static func _known_safe_worksite(observation: Dictionary, tile: Vector2i) -> Dictionary:
	var target_id := "skyblock:worksite:%d:%d" % [tile.x, tile.y]
	if _recent_build_worksite_failure(observation, target_id):
		return {}
	for raw_waypoint in _as_array(observation.get("safe_exploration_waypoints", [])):
		if not raw_waypoint is Dictionary:
			continue
		var waypoint := raw_waypoint as Dictionary
		if waypoint.get("support_tile", []) == [tile.x, tile.y] and bool(waypoint.get("reachable", false)):
			return {
				"action": Contract.ACTION_MOVE_TO,
				"id": target_id,
				"position": waypoint.get("position", []),
				"support_tile": [tile.x, tile.y],
			}
	return {}


static func _lava_near(terrain: Dictionary, tile: Vector2i, radius: int) -> bool:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if str(terrain.get("%d:%d" % [tile.x + dx, tile.y + dy], "")).to_lower().contains("lava"):
				return true
	return false


static func _worksite_corridor_has_lava(terrain: Dictionary, origin: Vector2i, worksite: Vector2i) -> bool:
	# A waypoint can be topologically reachable yet the live motion guard
	# refuses its jump over the source pool. Island maintenance need not cross
	# that hazard; leave long crossings to a dedicated bridge project.
	# The avatar can overshoot a nominally dry worksite during an interrupted
	# jump or host correction. Keep a full neighboring column of clearance from
	# lava along the whole approach, including both endpoint foot positions.
	for x in range(mini(origin.x, worksite.x) - 1, maxi(origin.x, worksite.x) + 2):
		for y in range(mini(origin.y, worksite.y) - 1, maxi(origin.y, worksite.y) + 2):
			if str(terrain.get("%d:%d" % [x, y], "")).to_lower().contains("lava"):
				return true
	return false


static func _ground_anchored_worksite(terrain: Dictionary, protected: Dictionary, tile: Vector2i, depth: int = 0) -> bool:
	if not _solid(terrain, tile.x, tile.y):
		return false
	var name := str(terrain.get("%d:%d" % [tile.x, tile.y], "")).to_lower()
	# These are ground/foundation materials, including a mined block reused as
	# a floor. A tree leaf or branch is not an island edge just because it is
	# solid under the bot's feet.
	if name in ["grass", "dirt", "stone", "cobblestone", "stone_bricks", "ice", "packed_ice", "sand", "snow"]:
		return true
	var below := str(terrain.get("%d:%d" % [tile.x, tile.y + 1], "")).to_lower()
	if below in ["grass", "dirt", "stone", "cobblestone", "stone_bricks", "ice", "packed_ice", "sand", "snow"]:
		return true
	var record: Dictionary = protected.get("%d:%d" % [tile.x, tile.y], {}) if protected.get("%d:%d" % [tile.x, tile.y], {}) is Dictionary else {}
	if depth >= SKYBLOCK_HOME_EXPANSION_LIMIT or str(record.get("reason", "")) not in ["skyblock_expand", "floating_island_expand"] or not bool(record.get("confirmed", false)):
		return false
	for direction in [-1, 1]:
		if _ground_anchored_worksite(terrain, protected, tile + Vector2i(direction, 0), depth + 1):
			return true
	return false


static func next_step(observation: Dictionary) -> Dictionary:
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _supported_origin(observation.get("self", {}), terrain)
	var project_state: Dictionary = observation.get("build_project_state", {}) if observation.get("build_project_state", {}) is Dictionary else {}
	var navigation_goal := _navigation_goal(observation, origin, project_state)
	if str(navigation_goal.get("status", "")) == "complete":
		return {"project_complete": true, "project_id": str(navigation_goal.get("project_id", ""))}
	if str(navigation_goal.get("status", "")) == "paused":
		return {}
	var goal: Vector2i = navigation_goal.get("tile", _invalid_tile())
	var has_goal := goal != _invalid_tile()
	var build_project: Dictionary = navigation_goal.get("build_project", {}) if navigation_goal.get("build_project", {}) is Dictionary else {}
	if terrain.is_empty():
		return {}
	if not _solid(terrain, origin.x, origin.y):
		# Never infer a foundation from a world mode or stale airborne position.
		return {}
	var block_name := _support_block(observation)
	if block_name.is_empty():
		return {}
	var goal_direction := 0
	if has_goal:
		goal_direction = signi(goal.x - origin.x)
		if goal_direction == 0:
			# Do not disguise a route that cannot be built horizontally as an
			# unrelated platform expansion.
			return {}
		if goal.y > origin.y:
			# The dig-route planner clears headroom and adds a lower attached step.
			# A level bridge here increases distance from the lower destination and
			# can leave the avatar marooned above its original platform.
			return {}
		if goal_direction != 0 and goal.y < origin.y:
			var step := _supported_stair(origin, goal_direction, goal, terrain, observation, block_name, build_project)
			if not step.is_empty():
				return step
	elif str(observation.get("world_mode", "")).to_lower() != "one_block":
		# A destination-less safety apron is only useful around One Block's lone
		# regenerating source; other placements must advance an observed route.
		return {}

	var left_run := _walkable_run(terrain, origin, -1)
	var right_run := _walkable_run(terrain, origin, 1)
	var platform_width := left_run + 1 + right_run
	var directions: Array[int] = []
	if has_goal:
		directions.append(goal_direction)
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
		return _placement(target, origin, goal, block_name, reason, build_project)
	return {}


static func station_work_area_step(observation: Dictionary, station_name: String) -> Dictionary:
	# A station in inventory is useful only if it can be placed beside a walkable
	# surface. Extend that surface by one attached cell when no existing station
	# footprint is available; this is a functional destination, not decoration.
	var terrain := _terrain_map(observation.get("terrain_tiles", []))
	var origin := _supported_origin(observation.get("self", {}), terrain)
	if not _solid(terrain, origin.x, origin.y):
		return {}
	var block_name := _support_block(observation)
	if block_name.is_empty():
		return {}
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	var blocked_tiles: Dictionary = observation.get("blocked_action_targets", {}) if observation.get("blocked_action_targets", {}) is Dictionary else {}
	var now_msec := int(observation.get("observed_at_msec", 0))
	if str(observation.get("world_mode", "")).to_lower() == "skyblock" and int(inventory.get(block_name, 0)) <= 1:
		return {}
	# A supported empty footprint may simply be on a host-retry cooldown. Do
	# not spend another block making a duplicate pad in that case.
	for offset_x in [1, -1, 2, -2, 3, -3]:
		var footprint := Vector2i(origin.x + offset_x, origin.y - 1)
		if _empty(terrain, footprint.x, footprint.y) and _solid(terrain, footprint.x, footprint.y + 1) and not _overlaps_any_player(footprint, observation):
			return {}
	for direction in [1, -1]:
		# An occupied station/work cell can obstruct walking above an otherwise
		# continuous shelf. The new foundation still attaches to that shelf;
		# station reach and navigation are validated separately by the host.
		var run := _support_run(terrain, origin, direction)
		var target := Vector2i(origin.x + direction * (run + 1), origin.y)
		if int(blocked_tiles.get("tile:%d:%d" % [target.x, target.y], 0)) > now_msec:
			continue
		if abs(target.x - origin.x) > MAX_PLACEMENT_REACH_TILES:
			continue
		if not _placeable(terrain, target.x, target.y) or not _solid(terrain, target.x - direction, target.y):
			continue
		if not _empty(terrain, target.x, target.y - 1) or not _empty(terrain, target.x, target.y - 2):
			continue
		if _overlaps_any_player(target, observation) or _overlaps_any_player(target + Vector2i.UP, observation):
			continue
		var placement := _placement(target, origin, _invalid_tile(), block_name, "station_work_area")
		placement["station"] = station_name
		return placement
	return {}


static func _supported_stair(origin: Vector2i, direction: int, goal: Vector2i, terrain: Dictionary, observation: Dictionary, block_name: String, build_project: Dictionary) -> Dictionary:
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
	return _placement(target, origin, goal, block_name, "build_stair", build_project)


static func _placement(target: Vector2i, origin: Vector2i, goal: Vector2i, block_name: String, reason: String, build_project: Dictionary = {}) -> Dictionary:
	var placement := {
		"id": "build:%s:%d:%d" % [reason, target.x, target.y],
		"block": block_name,
		"x": target.x,
		"y": target.y,
		"reason": reason,
		"origin": [origin.x, origin.y],
		"route_target": [] if goal == _invalid_tile() else [goal.x, goal.y],
		"structurally_connected": true,
	}
	if not build_project.is_empty():
		placement["build_project"] = build_project.duplicate(true)
	return placement


static func _navigation_goal(observation: Dictionary, origin: Vector2i, project_state: Dictionary = {}) -> Dictionary:
	var preferred_distance := float(observation.get("preferred_player_distance", 84.0))
	var active_project_id := str(project_state.get("id", "")) if str(project_state.get("status", "")) == "active" else ""
	var active_target_id := str(project_state.get("target_id", "")) if not active_project_id.is_empty() else ""
	var best: Dictionary = {}
	var best_distance := INF
	for raw_player in _as_array(observation.get("players", [])):
		if not raw_player is Dictionary or not bool((raw_player as Dictionary).get("alive", true)):
			continue
		var player := raw_player as Dictionary
		var player_id := str(player.get("id", ""))
		if not active_project_id.is_empty() and player_id == active_target_id:
			if float(player.get("distance", INF)) <= preferred_distance and bool(player.get("route_reachable", false)):
				return {"status": "complete", "project_id": active_project_id}
			var active_tile := _target_tile(player)
			if active_tile == _invalid_tile():
				return {"status": "paused"}
			return _route_goal("player", player_id, active_tile, player, active_project_id)
		if not active_project_id.is_empty():
			continue
		if float(player.get("distance", 9999.0)) <= preferred_distance:
			continue
		var candidate := _target_tile(player)
		var distance := origin.distance_to(candidate)
		if candidate != _invalid_tile() and distance <= MAX_GOAL_DISTANCE_TILES and distance < best_distance:
			best = _route_goal("player", player_id, candidate, player)
			best_distance = distance
	for raw_resource in _as_array(observation.get("visible_resources", [])):
		if not raw_resource is Dictionary:
			continue
		var resource := raw_resource as Dictionary
		var candidate := _target_tile(resource)
		var resource_id := str(resource.get("id", ""))
		if not active_project_id.is_empty() and resource_id == active_target_id:
			return {"status": "complete", "project_id": active_project_id} if bool(resource.get("reachable", false)) else _route_goal("resource", resource_id, candidate, resource, active_project_id)
		if not active_project_id.is_empty():
			continue
		if bool(resource.get("reachable", false)):
			continue
		var distance := origin.distance_to(candidate)
		if candidate != _invalid_tile() and distance <= MAX_GOAL_DISTANCE_TILES and distance < best_distance:
			best = _route_goal("resource", resource_id, candidate, resource)
			best_distance = distance
	if not active_project_id.is_empty():
		# The target left the current observation. Preserve the project rather
		# than silently switching to a closer distraction; resume if it reappears.
		return {"status": "paused"}
	return best


static func _route_goal(kind: String, target_id: String, tile: Vector2i, raw_target: Dictionary, active_project_id: String = "") -> Dictionary:
	if tile == _invalid_tile() or target_id.is_empty():
		return {}
	if target_id.begins_with("achievement:challenge:"):
		return {"status": "active", "tile": tile, "build_project": {}}
	var project_id := active_project_id if not active_project_id.is_empty() else "route:%s:%s" % [kind, target_id]
	return {
		"status": "active",
		"tile": tile,
		"build_project": {
			"id": project_id,
			"target_id": target_id,
			"target_kind": kind,
			"goal_tile": [tile.x, tile.y],
			"target_position": raw_target.get("position", []),
		},
	}


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


static func _support_run(terrain: Dictionary, origin: Vector2i, direction: int) -> int:
	var count := 0
	for distance in range(1, MAX_GOAL_DISTANCE_TILES + 1):
		if not _solid(terrain, origin.x + direction * distance, origin.y):
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


static func _supported_origin(raw: Variant, terrain: Dictionary) -> Vector2i:
	var naive := _support_tile(raw)
	if not raw is Dictionary or not bool((raw as Dictionary).get("on_ground", false)):
		return naive
	var self_state := raw as Dictionary
	var px := float(self_state.get("x", 0.0))
	var py := float(self_state.get("y", 0.0))
	var width := float(self_state.get("w", 20.0))
	var height := float(self_state.get("h", 28.0))
	# Mirror WorldSim.find_ground_support: an avatar may be grounded on the
	# neighboring block under its foot even while its centre is over empty air.
	var row := floori((py + height + 1.5) / float(TILE))
	var left := floori((px + 3.0) / float(TILE))
	var right := floori((px + width - 3.001) / float(TILE))
	for x in range(left, right + 1):
		if _solid(terrain, x, row):
			return Vector2i(x, row)
	return naive


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
	return _overlaps_other_player(tile, observation)


static func _overlaps_other_player(tile: Vector2i, observation: Dictionary) -> bool:
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
