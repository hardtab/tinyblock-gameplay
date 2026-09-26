class_name BotPerception
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const BlockDefs = preload("res://gameplay/scripts/block_defs.gd")

const DEFAULT_RADIUS := 256.0
const DEFAULT_MAX_EVENTS := 12
const REACHABLE_DISTANCE := float(BlockDefs.TILE) * 2.5
const SAFE_SUPPORT_MINE_DROP_TILES := 8


static func build(snapshot: Dictionary, own_player_id: String, radius: float = DEFAULT_RADIUS, now_msec: int = 0) -> Dictionary:
	var self_state := _dictionary(snapshot.get("self", {})).duplicate(true)
	var self_position := Contract.target_position(self_state)
	# Duel snapshots deliberately include the host as the bot's pinned enemy.
	# Outside PvP, keep the existing human-only social filter so ordinary host
	# metadata can never become an unsolicited target.
	var players := _normalize_entities(snapshot.get("players", []), own_player_id, self_position, radius, bool(snapshot.get("pvp_world", false)))
	var threats := _normalize_entities(snapshot.get("threats", snapshot.get("creatures", [])), "", self_position, radius, true)
	var resources := _normalize_entities(snapshot.get("visible_resources", snapshot.get("resources", [])), "", self_position, radius, false)
	for resource in resources:
		# Recalculate reachability from the current self position. Snapshot tiles are
		# built once and would otherwise keep a stale reachable=true after the bot
		# walks or falls away from the block.
		resource["reachable"] = float(resource.get("distance", 9999.0)) <= REACHABLE_DISTANCE
	players.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("distance", 9999.0)) < float(b.get("distance", 9999.0)))
	threats.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("distance", 9999.0)) < float(b.get("distance", 9999.0)))
	resources.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("distance", 9999.0)) < float(b.get("distance", 9999.0)))

	var recent_events := _bounded_events(snapshot.get("recent_events", []), DEFAULT_MAX_EVENTS)
	var emoji_events := _normalize_emoji_events(snapshot.get("emoji_events", []), own_player_id, self_position, radius)
	var regenerating_block := _dictionary(snapshot.get("regenerating_block", {})).duplicate(true)
	if not regenerating_block.is_empty():
		var source_position := Contract.target_position(regenerating_block)
		regenerating_block["position"] = [source_position.x, source_position.y]
		regenerating_block["relative_position"] = [source_position.x - self_position.x, source_position.y - self_position.y]
		regenerating_block["distance"] = self_position.distance_to(source_position)
		regenerating_block["reachable"] = float(regenerating_block["distance"]) <= REACHABLE_DISTANCE
	var observation := {
		"observed_at_msec": now_msec,
		"self": self_state,
		"players": players,
		"threats": threats,
		"visible_resources": resources,
		"visible_containers": _normalize_entities(snapshot.get("visible_containers", []), "", self_position, radius, false),
		"terrain_tiles": _as_array(snapshot.get("terrain_tiles", [])).duplicate(true),
		"inventory_summary": _dictionary(snapshot.get("inventory_summary", snapshot.get("inventory", {}))).duplicate(true),
		"legal_actions": Contract.normalize_legal_actions(snapshot.get("legal_actions", Contract.ALL_ACTIONS)),
		"current_goal": str(snapshot.get("current_goal", Contract.GOAL_IDLE)),
		"recent_events": recent_events,
		"emoji_events": emoji_events,
		"action_history": _bounded_events(snapshot.get("action_history", []), DEFAULT_MAX_EVENTS),
		"loaded_radius": radius,
		"world_id": str(snapshot.get("world_id", "")),
		"own_player_id": own_player_id,
		"active_projectiles": _as_array(snapshot.get("active_projectiles", [])).duplicate(true),
		"regenerating_block": regenerating_block,
	}
	for key in ["self_defense", "social_emoji", "social_target_id", "preferred_player_distance", "creature_attack_distance", "bow_attack_distance", "pvp_world", "duel_started", "enemy_player_id", "aggressive_player_id", "pvp_chest_opened", "world_mode", "recipes", "achievements", "biome_waypoints", "safe_exploration_waypoints", "equipment_slots", "craft_pending_output", "craft_retry_after_msec", "craft_blocked_outputs", "food_eat_cooldown_until_msec", "action_loop_blocked", "protected_build_cells", "descent_plan", "verified_safe_exit", "descent_protected_supports"]:
		if snapshot.has(key):
			observation[key] = snapshot[key]
	return observation


static func count_live_humans(roster: Variant, own_player_id: String, excluded_ids: Array = [], dedicated_server: bool = false) -> int:
	var count := 0
	if roster is Dictionary:
		for raw_id in roster:
			var entry := _dictionary((roster as Dictionary)[raw_id])
			var player_id := str(raw_id)
			if entry.has("player_id"):
				player_id = str(entry.get("player_id", player_id))
			if _is_live_human_entry(entry, player_id, own_player_id, excluded_ids, dedicated_server):
				count += 1
	else:
		for raw_entry in _as_array(roster):
			var entry := _dictionary(raw_entry)
			var player_id := str(entry.get("id", entry.get("player_id", "")))
			if _is_live_human_entry(entry, player_id, own_player_id, excluded_ids, dedicated_server):
				count += 1
	return count


static func empty_world_should_leave(sync_complete: bool, human_count: int, empty_since_msec: int, now_msec: int, grace_msec: int) -> bool:
	return sync_complete and human_count <= 0 and empty_since_msec >= 0 and now_msec - empty_since_msec >= maxi(0, grace_msec)


static func nearest_player(observation: Dictionary) -> Dictionary:
	var players: Array = _as_array(observation.get("players", []))
	return _dictionary(players[0]) if not players.is_empty() and players[0] is Dictionary else {}


static func has_clear_bow_line_of_sight(observation: Dictionary, target: Dictionary) -> bool:
	var raw_terrain: Variant = observation.get("terrain_tiles", [])
	if not raw_terrain is Array or (raw_terrain as Array).is_empty():
		# An incomplete terrain window must not make a valid target permanently
		# unshootable. The host remains authoritative for the projectile collision.
		return true
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	var origin := Contract.target_position(self_state) + Vector2(10.0, 11.76)
	var destination := Contract.target_position(target) + Vector2(10.0, 14.0)
	var distance := origin.distance_to(destination)
	if distance < 1.0:
		return true
	var tile_size := 32.0
	var origin_tile := Vector2i(floori(origin.x / tile_size), floori(origin.y / tile_size))
	var target_tile := Vector2i(floori(destination.x / tile_size), floori(destination.y / tile_size))
	var terrain := {}
	for raw_tile in raw_terrain:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var block_name := str(tile.get("block_name", "")).to_lower()
		if block_name.is_empty() or block_name in ["air", "core.air"]:
			continue
		terrain[Vector2i(int(tile.get("x", 0)), int(tile.get("y", 0)))] = true
	var samples := maxi(1, int(ceil(distance / 8.0)))
	for index in range(1, samples):
		var point := origin.lerp(destination, float(index) / float(samples))
		var tile := Vector2i(floori(point.x / tile_size), floori(point.y / tile_size))
		if tile == origin_tile or tile == target_tile:
			continue
		if terrain.has(tile):
			return false
	return true


static func mine_target_is_safe(observation: Dictionary, target: Dictionary) -> bool:
	if not target.has("x") or not target.has("y"):
		# Legacy/resource-provider entries may carry only id + world position. They
		# cannot be identified as the current support tile, so preserve the existing
		# reach/tool checks instead of treating every such resource as unsafe.
		return true
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if self_state.is_empty():
		return false
	var tile_size := float(BlockDefs.TILE)
	var player_x := float(self_state.get("x", 0.0))
	var player_y := float(self_state.get("y", 0.0))
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var height := maxf(1.0, float(self_state.get("h", 28.0)))
	var left := floori(player_x / tile_size)
	var right := floori((player_x + width - 0.001) / tile_size)
	var support_y := floori((player_y + height + 0.01) / tile_size)
	var target_x := int(target.get("x", 2147483647))
	var target_y := int(target.get("y", 2147483647))
	if target_y != support_y or target_x < left or target_x > right:
		return true
	# Some authoritative cells are replaced atomically when mined. Treat that as
	# an explicit tile capability instead of special-casing a world mode.
	if bool(target.get("preserves_support_on_mine", false)):
		return true
	var terrain := _terrain_cell_map(observation.get("terrain_tiles", []))
	terrain.erase(Vector2i(target_x, target_y))
	# A wide avatar may still have another solid support cell under its feet.
	for support_x in range(left, right + 1):
		if _safe_solid_terrain(terrain.get(Vector2i(support_x, support_y), {})):
			return true
	# Otherwise the bot will fall vertically. Allow that only when the loaded
	# terrain proves a non-hazardous landing within the bounded observation.
	var landing_x := floori((player_x + width * 0.5) / tile_size)
	for drop in range(1, SAFE_SUPPORT_MINE_DROP_TILES + 1):
		var landing_cell: Dictionary = terrain.get(Vector2i(landing_x, support_y + drop), {}) if terrain.get(Vector2i(landing_x, support_y + drop), {}) is Dictionary else {}
		if landing_cell.is_empty():
			continue
		return _safe_solid_terrain(landing_cell)
	return false


static func _terrain_cell_map(raw_terrain: Variant) -> Dictionary:
	var terrain := {}
	for raw_tile in _as_array(raw_terrain):
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var block_name := str(tile.get("block_name", "")).to_lower()
		if block_name.is_empty() or block_name in ["air", "core.air"]:
			continue
		var hazardous_fluid := block_name in ["lava", "core.lava", "water", "core.water", "glass_tide", "chorus_brine"]
		terrain[Vector2i(int(tile.get("x", 0)), int(tile.get("y", 0)))] = {
			"name": block_name,
			"solid": bool(tile.get("solid", not hazardous_fluid)),
			"fluid": bool(tile.get("fluid", hazardous_fluid)),
		}
	return terrain


static func _safe_solid_terrain(cell: Variant) -> bool:
	if not cell is Dictionary:
		return false
	var terrain_cell := cell as Dictionary
	var block_name := str(terrain_cell.get("name", "")).to_lower()
	if block_name.is_empty() or block_name in ["air", "core.air", "lava", "core.lava"]:
		return false
	return bool(terrain_cell.get("solid", false)) and not bool(terrain_cell.get("fluid", false))


static func _normalize_entities(raw_entities: Variant, own_player_id: String, origin: Vector2, radius: float, hostile_default: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var entries: Array = []
	if raw_entities is Dictionary:
		for raw_id in raw_entities:
			var item := _dictionary((raw_entities as Dictionary)[raw_id]).duplicate(true)
			if not item.has("id"):
				item["id"] = str(raw_id)
			entries.append(item)
	else:
		entries = _as_array(raw_entities)
	for raw_item in entries:
		if not raw_item is Dictionary:
			continue
		var item := (raw_item as Dictionary).duplicate(true)
		var entity_id := str(item.get("id", item.get("player_id", item.get("creature_id", ""))))
		if entity_id.is_empty() or entity_id == own_player_id:
			continue
		var position := Contract.target_position(item)
		var distance := origin.distance_to(position)
		if distance > radius:
			continue
		var health := int(item.get("health", item.get("hp", 10)))
		var max_health := maxi(1, int(item.get("max_health", 10)))
		if not hostile_default:
			var actor_kind := str(item.get("actor_kind", "")).to_lower()
			var role := str(item.get("role", "")).to_lower()
			if bool(item.get("is_bot", false)) or actor_kind == "bot" or role == "host" or role == "bot":
				continue
			if health <= 0 or (item.has("alive") and not bool(item.get("alive", false))):
				continue
		item["id"] = entity_id
		item["position"] = [position.x, position.y]
		item["relative_position"] = [position.x - origin.x, position.y - origin.y]
		item["distance"] = distance
		item["alive"] = health > 0
		item["health"] = health
		item["max_health"] = max_health
		if hostile_default and not item.has("hostile"):
			item["hostile"] = true
		result.append(item)
	return result


static func _is_live_human_entry(entry: Dictionary, player_id: String, own_player_id: String, excluded_ids: Array, dedicated_server: bool) -> bool:
	if player_id.is_empty() or player_id == own_player_id or player_id in excluded_ids:
		return false
	if bool(entry.get("is_bot", false)) or str(entry.get("actor_kind", "")).to_lower() == "bot":
		return false
	if dedicated_server and str(entry.get("role", "")).to_lower() == "host":
		return false
	if entry.has("alive") and not bool(entry.get("alive", false)):
		return false
	return int(entry.get("health", entry.get("hp", 10))) > 0


static func _bounded_events(raw_events: Variant, limit: int) -> Array:
	var events := _as_array(raw_events)
	var result: Array = []
	var start := maxi(0, events.size() - maxi(0, limit))
	for index in range(start, events.size()):
		if events[index] is Dictionary:
			result.append((events[index] as Dictionary).duplicate(true))
	return result


static func _normalize_emoji_events(raw_events: Variant, own_player_id: String, origin: Vector2, radius: float) -> Array:
	var result: Array = []
	for raw_event in _as_array(raw_events):
		if not raw_event is Dictionary:
			continue
		var event := (raw_event as Dictionary).duplicate(true)
		var player_id := str(event.get("player_id", event.get("sender_player_id", "")))
		var emoji := str(event.get("emoji", ""))
		if player_id.is_empty() or player_id == own_player_id or emoji.is_empty():
			continue
		var position := Contract.target_position(event)
		var distance := origin.distance_to(position)
		if event.has("position") or event.has("x") or event.has("y"):
			if distance > radius:
				continue
			event["position"] = [position.x, position.y]
			event["relative_position"] = [position.x - origin.x, position.y - origin.y]
			event["distance"] = distance
		event["player_id"] = player_id
		event["emoji"] = emoji
		result.append(event)
	return _bounded_events(result, DEFAULT_MAX_EVENTS)


static func _dictionary(value: Variant) -> Dictionary:
	return value as Dictionary if value is Dictionary else {}


static func _as_array(value: Variant) -> Array:
	return value as Array if value is Array else []
