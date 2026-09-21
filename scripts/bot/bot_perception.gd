class_name BotPerception
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")

const DEFAULT_RADIUS := 256.0
const DEFAULT_MAX_EVENTS := 12


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
		resource["reachable"] = bool(resource.get("reachable", false))
	players.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("distance", 9999.0)) < float(b.get("distance", 9999.0)))
	threats.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("distance", 9999.0)) < float(b.get("distance", 9999.0)))
	resources.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("distance", 9999.0)) < float(b.get("distance", 9999.0)))

	var recent_events := _bounded_events(snapshot.get("recent_events", []), DEFAULT_MAX_EVENTS)
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
		"action_history": _bounded_events(snapshot.get("action_history", []), DEFAULT_MAX_EVENTS),
		"loaded_radius": radius,
		"world_id": str(snapshot.get("world_id", "")),
		"own_player_id": own_player_id,
		"active_projectiles": _as_array(snapshot.get("active_projectiles", [])).duplicate(true),
	}
	for key in ["self_defense", "social_emoji", "social_target_id", "preferred_player_distance", "creature_attack_distance", "bow_attack_distance", "pvp_world", "duel_started", "enemy_player_id", "pvp_chest_opened", "recipes", "achievements", "equipment_slots", "craft_pending_output", "craft_retry_after_msec", "craft_blocked_outputs"]:
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


static func _dictionary(value: Variant) -> Dictionary:
	return value as Dictionary if value is Dictionary else {}


static func _as_array(value: Variant) -> Array:
	return value as Array if value is Array else []
