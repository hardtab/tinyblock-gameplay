class_name BotDescentPlanner
extends RefCounted

## Conservative staircase descent for the `below_surface` achievement.
## This planner never edits terrain. It proposes one ahead-block to clear, then
## one adjacent lower support to walk to. A return route must be proven through
## cached, authoritative terrain before either proposal is emitted.

const Navigator = preload("res://gameplay/scripts/bot/bot_navigator.gd")
const BlockDefs = preload("res://gameplay/scripts/block_defs.gd")

const TILE_SIZE := 32
const MAX_ROUTE_NODES := 128
const STATIC_KNOWN_RADIUS_X := 8
const STATIC_KNOWN_RADIUS_Y := 6
const UNKNOWN_TILE := ""
const SUPPORTED_MODES: PackedStringArray = ["procedural", "one_block", "skyblock", "floating_islands"]

var _session_id := ""
var _world_id := ""
var _world_mode := ""
var _pvp_world := false
var _one_block_source := Vector2i(2147483647, 2147483647)
var _initial_snapshot_complete := false
var _root_support := Vector2i(2147483647, 2147483647)
var _authoritative_support := Vector2i(2147483647, 2147483647)
var _support_path: Array[Vector2i] = []
var _pending_from := Vector2i(2147483647, 2147483647)
var _pending_to := Vector2i(2147483647, 2147483647)
var _preferred_direction := 1
var _last_plan: Dictionary = {}


func begin_session(session_id: String, world_id: String, world_mode: String, pvp_world: bool, source: Vector2i = Vector2i(2147483647, 2147483647)) -> void:
	var mode := world_mode.strip_edges().to_lower()
	if session_id == _session_id and world_id == _world_id and mode == _world_mode and pvp_world == _pvp_world:
		_one_block_source = source
		return
	_session_id = session_id
	_world_id = world_id
	_world_mode = mode
	_pvp_world = pvp_world
	_one_block_source = source
	_initial_snapshot_complete = false
	_root_support = _invalid_tile()
	_authoritative_support = _invalid_tile()
	_support_path.clear()
	_pending_from = _invalid_tile()
	_pending_to = _invalid_tile()
	_preferred_direction = 1
	_last_plan.clear()


func set_world_context(world_mode: String, pvp_world: bool, source: Vector2i = Vector2i(2147483647, 2147483647)) -> void:
	var mode := world_mode.strip_edges().to_lower()
	if mode != _world_mode or pvp_world != _pvp_world:
		_world_mode = mode
		_pvp_world = pvp_world
		_one_block_source = source
		_root_support = _invalid_tile()
		_authoritative_support = _invalid_tile()
		_support_path.clear()
		_pending_from = _invalid_tile()
		_pending_to = _invalid_tile()
		_preferred_direction = 1
		_last_plan.clear()
		_initial_snapshot_complete = false
	else:
		_one_block_source = source


func observe_initial_snapshot(self_state: Dictionary, terrain: Dictionary, coverage: Dictionary) -> bool:
	_initial_snapshot_complete = bool(coverage.get("complete", false))
	if not _initial_snapshot_complete or not _mode_is_allowed():
		return false
	var support := _support_for_position(self_state)
	if not bool(self_state.get("on_ground", false)) or not _safe_standable(support, terrain, coverage, support):
		return false
	if _root_support == _invalid_tile():
		_root_support = support
		_authoritative_support = support
		_support_path = [support]
	return true


func observe_authoritative_position(self_state: Dictionary, terrain: Dictionary, coverage: Dictionary) -> bool:
	if not _initial_snapshot_complete or not bool(coverage.get("complete", false)) or not _mode_is_allowed():
		return false
	if not bool(self_state.get("on_ground", false)):
		return false
	var support := _support_for_position(self_state)
	if not _safe_standable(support, terrain, coverage, support):
		return false
	if _root_support == _invalid_tile() or _support_path.is_empty():
		# The initial world snapshot can arrive before the bot has a grounded
		# authoritative position. In that case, anchor the return chain on the
		# first later host-confirmed landing, but only after the complete terrain
		# snapshot above has been accepted.
		_root_support = support
		_authoritative_support = support
		_support_path = [support]
		_pending_from = _invalid_tile()
		_pending_to = _invalid_tile()
		return true
	if _pending_to != _invalid_tile():
		if support == _pending_to and _support_path.size() > 0 and _pending_from == _support_path.back():
			if support.y > _pending_from.y and support.x != _pending_from.x and not _support_path.has(support):
				_support_path.append(support)
				_preferred_direction = signi(support.x - _pending_from.x)
			_pending_from = _invalid_tile()
			_pending_to = _invalid_tile()
		elif support.y > _pending_from.y and support != _pending_to:
			# A deeper but different landing did not complete the authorized
			# staircase transition. Do not extend the return chain from it.
			_pending_from = _invalid_tile()
			_pending_to = _invalid_tile()
	_authoritative_support = support
	return true


func plan_next(self_state: Dictionary, terrain: Dictionary, coverage: Dictionary) -> Dictionary:
	var result := _empty_plan()
	if not _mode_is_allowed():
		result["reason"] = "mode_not_supported"
		_last_plan = result.duplicate(true)
		return result
	if not _initial_snapshot_complete or not bool(coverage.get("complete", false)):
		result["reason"] = "authoritative_terrain_incomplete"
		_last_plan = result.duplicate(true)
		return result
	if _root_support == _invalid_tile() or _support_path.is_empty():
		result["reason"] = "safe_root_support_missing"
		_last_plan = result.duplicate(true)
		return result
	var current := _support_for_position(self_state)
	if current == _invalid_tile() or current != _authoritative_support or _support_path.back() != current:
		result["reason"] = "current_support_not_authoritatively_on_return_path"
		_last_plan = result.duplicate(true)
		return result
	if not bool(self_state.get("on_ground", false)) or not _safe_standable(current, terrain, coverage, current):
		result["reason"] = "current_support_unsafe_or_airborne"
		_last_plan = result.duplicate(true)
		return result
	var current_to_root := _physics_route(current, _root_support, terrain, coverage, {})
	if current_to_root.is_empty():
		result["reason"] = "return_route_unproven"
		_last_plan = result.duplicate(true)
		return result

	var source := _one_block_source_for(coverage)
	var candidates: Array[Dictionary] = []
	for dx in [1, -1]:
		var next_support := current + Vector2i(dx, 1)
		if _world_mode == "one_block" and next_support == source:
			continue
		if not _safe_support_candidate(next_support, terrain, coverage, current):
			continue
		var clear_cells := _known_body_cells(next_support, terrain, coverage, current)
		if clear_cells.is_empty():
			continue
		var blockers: Array[Vector2i] = []
		for cell in clear_cells:
			if _tile_is_solid(cell, terrain):
				blockers.append(cell)
		var projected_air: Dictionary = {}
		for blocker in blockers:
			projected_air[blocker] = true
		var projected_to_root := _physics_route(next_support, _root_support, terrain, coverage, projected_air)
		if projected_to_root.is_empty():
			continue
		var clear_tile := _invalid_tile()
		if not blockers.is_empty():
			# Clear only the nearest lower obstruction ahead. Recompute after the
			# authoritative tile batch so no action mines a speculative tunnel.
			blockers.sort_custom(func(a: Vector2i, b: Vector2i):
				var a_distance := current.distance_squared_to(a)
				var b_distance := current.distance_squared_to(b)
				return a_distance < b_distance or (a_distance == b_distance and a.y > b.y)
			)
			clear_tile = blockers[0]
			if clear_tile == current or _support_path.has(clear_tile) or _is_regenerating_source(clear_tile, source):
				continue
			if _route_has_support(current_to_root, clear_tile):
				continue
			if not _tile_is_safe_to_clear(clear_tile, terrain):
				continue
			if not _return_route_survives_clear(current, _root_support, terrain, coverage, clear_tile):
				continue
		var candidate := {
			"next_support": next_support,
			"clear_tile": clear_tile,
			"phase": "clear" if clear_tile != _invalid_tile() else "move",
			"current_route": current_to_root,
			"projected_route": projected_to_root,
			"distance": current.distance_squared_to(next_support),
		}
		candidates.append(candidate)
	if candidates.is_empty():
		result["reason"] = "no_proven_adjacent_landing"
		result["return_route"] = _route_for_observation(current_to_root)
		result["protected_supports"] = _protected_supports(current_to_root)
		_last_plan = result.duplicate(true)
		return result
	candidates.sort_custom(func(a: Dictionary, b: Dictionary):
		var a_tile: Vector2i = a["next_support"]
		var b_tile: Vector2i = b["next_support"]
		# Keep each staircase traveling in its established lateral direction.
		var a_preferred := signi(a_tile.x - current.x) == _preferred_direction
		var b_preferred := signi(b_tile.x - current.x) == _preferred_direction
		return a_preferred and not b_preferred
	)
	var selected: Dictionary = candidates[0]
	var selected_support: Vector2i = selected["next_support"]
	var selected_clear: Vector2i = selected["clear_tile"]
	result["eligible"] = true
	result["verified_safe_exit"] = true
	result["phase"] = str(selected["phase"])
	result["reason"] = "return_route_proven"
	result["current_support"] = _tile_array(current)
	result["root_support"] = _tile_array(_root_support)
	result["next_support"] = _tile_array(selected_support)
	result["clear_tile"] = _tile_array(selected_clear) if selected_clear != _invalid_tile() else []
	result["return_route"] = _route_for_observation(selected["current_route"])
	result["projected_return_route"] = _route_for_observation(selected["projected_route"])
	result["protected_supports"] = _protected_supports(selected["current_route"])
	result["protected_supports"].append(_tile_array(selected_support))
	_last_plan = result.duplicate(true)
	return result


func note_intended_transition(decision: Dictionary) -> bool:
	if not bool(decision.get("descent_transition", false)) or str(decision.get("action", "")) != "MOVE_TO":
		return false
	if not bool(_last_plan.get("eligible", false)) or not bool(_last_plan.get("verified_safe_exit", false)):
		return false
	var from_tile := _vector_from_pair(decision.get("descent_from_support", []))
	var to_tile := _vector_from_pair(decision.get("descent_to_support", []))
	if from_tile != _vector_from_pair(_last_plan.get("current_support", [])):
		return false
	if to_tile != _vector_from_pair(_last_plan.get("next_support", [])):
		return false
	if str(_last_plan.get("phase", "")) != "move":
		return false
	_pending_from = from_tile
	_pending_to = to_tile
	return true


func protected_supports() -> Array:
	var result: Array = []
	for tile in _support_path:
		result.append(_tile_array(tile))
	return result


func latest_plan() -> Dictionary:
	return _last_plan.duplicate(true)


func reset_session() -> void:
	begin_session("", "", "", false)


func cancel_intended_transition() -> void:
	_pending_from = _invalid_tile()
	_pending_to = _invalid_tile()


func _mode_is_allowed() -> bool:
	return (
		not _pvp_world
		and _world_mode in SUPPORTED_MODES
		and (_world_mode != "one_block" or _one_block_source != _invalid_tile())
	)


func _empty_plan() -> Dictionary:
	return {
		"eligible": false,
		"verified_safe_exit": false,
		"phase": "stop",
		"reason": "not_planned",
		"current_support": [],
		"root_support": _tile_array(_root_support) if _root_support != _invalid_tile() else [],
		"next_support": [],
		"clear_tile": [],
		"return_route": [],
		"projected_return_route": [],
		"protected_supports": protected_supports(),
	}


func _support_for_position(self_state: Dictionary) -> Vector2i:
	if not self_state.has("x") or not self_state.has("y"):
		return _invalid_tile()
	return Vector2i(
		floori((float(self_state.get("x", 0.0)) + 10.0) / float(TILE_SIZE)),
		floori((float(self_state.get("y", 0.0)) + float(self_state.get("h", 28.0))) / float(TILE_SIZE)),
	)


func _safe_standable(tile: Vector2i, terrain: Dictionary, coverage: Dictionary, reference: Vector2i, projected_air: Dictionary = {}) -> bool:
	if tile == _invalid_tile() or not _tile_is_known(tile, coverage, reference):
		return false
	if not _tile_is_solid(tile, terrain) or not _tile_is_safe(tile, terrain):
		return false
	var support_entry := _tile_entry(tile, terrain)
	if bool(support_entry.get("falls_when_unsupported", false)):
		return false
	for offset_y in [-1, -2]:
		var body_cell := tile + Vector2i(0, offset_y)
		if not _tile_is_known(body_cell, coverage, reference):
			return false
		if projected_air.has(body_cell):
			continue
		if _tile_is_solid(body_cell, terrain) or not _tile_is_safe(body_cell, terrain):
			return false
	return true


func _safe_support_tile(tile: Vector2i, terrain: Dictionary, coverage: Dictionary, reference: Vector2i, projected_air: Dictionary = {}) -> bool:
	if _world_mode == "one_block" and tile == _one_block_source:
		return false
	return _safe_standable(tile, terrain, coverage, reference, projected_air)


func _safe_support_candidate(tile: Vector2i, terrain: Dictionary, coverage: Dictionary, reference: Vector2i) -> bool:
	if _world_mode == "one_block" and tile == _one_block_source:
		return false
	if tile == _invalid_tile() or not _tile_is_known(tile, coverage, reference):
		return false
	var support_entry := _tile_entry(tile, terrain)
	if not _tile_is_solid(tile, terrain) or not _tile_is_safe(tile, terrain) or bool(support_entry.get("falls_when_unsupported", false)):
		return false
	return not _known_body_cells(tile, terrain, coverage, reference).is_empty()


func _known_body_cells(support: Vector2i, terrain: Dictionary, coverage: Dictionary, reference: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for offset_y in [-1, -2]:
		var cell := support + Vector2i(0, offset_y)
		if not _tile_is_known(cell, coverage, reference) or not _tile_is_safe(cell, terrain):
			return []
		cells.append(cell)
	return cells


func _tile_is_known(tile: Vector2i, coverage: Dictionary, reference: Vector2i) -> bool:
	var observed_cells: Dictionary = coverage.get("observed_cells", {}) if coverage.get("observed_cells", {}) is Dictionary else {}
	if observed_cells.has(_tile_key(tile)):
		return true
	var mode := str(coverage.get("mode", _world_mode)).to_lower()
	if mode == "procedural":
		var chunk_x := floori(float(tile.x) / float(int(coverage.get("chunk_width", 16))))
		var known_chunks: Dictionary = coverage.get("generated_chunks", {}) if coverage.get("generated_chunks", {}) is Dictionary else {}
		return bool(known_chunks.get(str(chunk_x), known_chunks.get(chunk_x, false)))
	if mode in ["one_block", "skyblock", "floating_islands"] and bool(coverage.get("complete", false)):
		return abs(tile.x - reference.x) <= STATIC_KNOWN_RADIUS_X and abs(tile.y - reference.y) <= STATIC_KNOWN_RADIUS_Y
	return false


func _tile_entry(tile: Vector2i, terrain: Dictionary) -> Dictionary:
	var raw: Variant = terrain.get(_tile_key(tile), {})
	return raw as Dictionary if raw is Dictionary else {}


func _tile_is_solid(tile: Vector2i, terrain: Dictionary) -> bool:
	var entry := _tile_entry(tile, terrain)
	return bool(entry.get("solid", _block_entry(str(entry.get("block_name", entry.get("name", "")))).get("solid", false)))


func _tile_is_safe(tile: Vector2i, terrain: Dictionary) -> bool:
	var entry := _tile_entry(tile, terrain)
	if entry.is_empty():
		return true
	var block_name := str(entry.get("block_name", entry.get("name", ""))).to_lower()
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	var block := _block_entry(block_name)
	var block_definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	if bool(entry.get("fluid", block.get("fluid", false))):
		return false
	if float(entry.get("temperature", block.get("temperature", 0.0))) >= 0.75:
		return false
	for key in ["hazard", "hazardous", "damage", "contact_damage", "damage_per_tick"]:
		if bool(entry.get(key, definition.get(key, block.get(key, block_definition.get(key, false))))):
			return false
	var tags: Array = definition.get("tags", block_definition.get("tags", [])) if definition.get("tags", block_definition.get("tags", [])) is Array else []
	for raw_tag in tags:
		if str(raw_tag).to_lower() in ["hazard", "hazardous", "danger", "dangerous", "damage"]:
			return false
	return true


func _tile_is_safe_to_clear(tile: Vector2i, terrain: Dictionary) -> bool:
	var entry := _tile_entry(tile, terrain)
	return not entry.is_empty() and _tile_is_solid(tile, terrain) and _tile_is_safe(tile, terrain)


func _physics_route(origin: Vector2i, destination: Vector2i, terrain: Dictionary, coverage: Dictionary, projected_air: Dictionary) -> Array[Dictionary]:
	return Navigator.physics_route(
		origin,
		destination,
		func(tile: Vector2i) -> bool: return _safe_standable(tile, terrain, coverage, origin, projected_air),
		Callable(),
		MAX_ROUTE_NODES,
	)


func _return_route_survives_clear(origin: Vector2i, destination: Vector2i, terrain: Dictionary, coverage: Dictionary, cleared: Vector2i) -> bool:
	var projected_air := {cleared: true}
	return not _physics_route(origin, destination, terrain, coverage, projected_air).is_empty()


func _route_has_support(route: Array, tile: Vector2i) -> bool:
	for raw_step in route:
		if not raw_step is Dictionary:
			continue
		if _vector_from_pair((raw_step as Dictionary).get("tile", [])) == tile:
			return true
	return false


func _protected_supports(route: Array) -> Array:
	var seen: Dictionary = {}
	var result: Array = []
	for tile in _support_path:
		if not seen.has(tile):
			seen[tile] = true
			result.append(_tile_array(tile))
	for raw_step in route:
		if not raw_step is Dictionary:
			continue
		var step: Dictionary = raw_step
		var tile := _vector_from_pair(step.get("tile", []))
		if tile != _invalid_tile() and not seen.has(tile):
			seen[tile] = true
			result.append(_tile_array(tile))
	return result


func _route_for_observation(route: Array) -> Array:
	var result: Array = []
	for raw_step in route:
		if not raw_step is Dictionary:
			continue
		var step: Dictionary = raw_step
		result.append({"tile": _tile_array(_vector_from_pair(step.get("tile", []))), "kind": str(step.get("kind", "walk"))})
	return result


func _one_block_source_for(coverage: Dictionary) -> Vector2i:
	if _world_mode != "one_block":
		return _invalid_tile()
	if coverage.get("one_block_source", []) is Array:
		var source := _vector_from_pair(coverage.get("one_block_source", []))
		if source != _invalid_tile():
			return source
	return _one_block_source


func _is_regenerating_source(tile: Vector2i, source: Vector2i) -> bool:
	return _world_mode == "one_block" and tile == source


func _block_entry(block_name: String) -> Dictionary:
	if block_name.is_empty():
		return {}
	var loop := Engine.get_main_loop()
	if loop == null or not loop.has_method("get_root"):
		return {}
	var root: Node = loop.get_root()
	var defs := root.get_node_or_null("BlockDefs")
	if defs == null or not defs.get("BLOCKS") is Dictionary:
		return {}
	var blocks: Dictionary = defs.get("BLOCKS")
	return blocks.get(block_name, {}) if blocks.get(block_name, {}) is Dictionary else {}


func _tile_key(tile: Vector2i) -> String:
	return "%d:%d" % [tile.x, tile.y]


func _tile_array(tile: Vector2i) -> Array[int]:
	return [tile.x, tile.y]


func _vector_from_pair(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	if value is Dictionary and (value as Dictionary).has("x") and (value as Dictionary).has("y"):
		return Vector2i(int(value.x), int(value.y))
	return _invalid_tile()


func _invalid_tile() -> Vector2i:
	return Vector2i(2147483647, 2147483647)
