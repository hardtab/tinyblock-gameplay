class_name BotSession
extends Node

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const Perception = preload("res://gameplay/scripts/bot/bot_perception.gd")
const Navigator = preload("res://gameplay/scripts/bot/bot_navigator.gd")
const BlockDefs = preload("res://gameplay/scripts/block_defs.gd")
const Social = preload("res://gameplay/scripts/bot/bot_social.gd")
const BehaviorClass = preload("res://gameplay/scripts/bot/bot_behavior.gd")
const RuleProviderClass = preload("res://gameplay/scripts/bot/bot_rule_provider.gd")
const SafetyClass = preload("res://gameplay/scripts/bot/bot_safety_policy.gd")
const ExecutorClass = preload("res://gameplay/scripts/bot/bot_executor.gd")

signal state_changed(state: String)
signal sync_started(session_id: String)
signal session_ready(session_id: String, player_id: String)
signal human_player_count_changed(count: int)
signal empty_world_ready()
signal session_left(reason: String)
signal decision_logged(event: Dictionary)
signal structured_log(event: Dictionary)

const STATE_IDLE := "IDLE"
const STATE_JOINING := "JOINING"
const STATE_SYNCING := "SYNCING"
const STATE_PLAYING := "PLAYING"
const STATE_LEAVING := "LEAVING"

const DEFAULT_SYNC_TIMEOUT_MSEC := 45_000
const DEFAULT_EMPTY_GRACE_MSEC := 30_000
const DEFAULT_OBSERVATION_RADIUS := 256.0

var backend: Object
var network_client: Object
var behavior: BotBehavior
var safety: BotSafetyPolicy
var executor: BotExecutor
var state := STATE_IDLE
var session_id := ""
var own_player_id := ""
var world_id := ""
var protocol_version := 2
var dedicated_server := false
var empty_grace_msec := DEFAULT_EMPTY_GRACE_MSEC
var observation_radius := DEFAULT_OBSERVATION_RADIUS
var human_player_count := 0
var empty_since_msec := -1
var sync_complete := false
var _sync_started_msec := -1
var _empty_emitted := false
var _left_emitted := false
var _join_in_flight := false
var _disconnect_requested := false
var _network_signals_connected := false
var _snapshot_transfer_id := ""
var _snapshot_expected_chunks := 0
var _snapshot_chunks: Array[String] = []
var _world_snapshot: Dictionary = {}
var _roster: Dictionary = {}
var _recent_events: Array[Dictionary] = []
var _last_emoji_sent_msec := -1
var _previous_emoji := ""
var _social_last_sent_msec := -1
var _welcome_emoji_due_msec := -1
var _welcome_emoji_pending := false
var _movement_step_callable: Callable
var _social := Social.new()
var _last_player_snapshot_msec := -1
var _equipment_slots := {"hand": "", "feet": ""}
var _pending_action_targets: Dictionary = {}
var _host_player_id := ""
var _craft_pending_output := ""
var _craft_retry_after_msec := -1
var _craft_blocked_outputs: Dictionary = {}
var _population_logged := false
const PLAYER_SNAPSHOT_INTERVAL_MSEC := 100
const CRAFT_RESPONSE_TIMEOUT_MSEC := 4_000
const CRAFT_RETRY_DELAY_MSEC := 8_000
const BOT_SKIN := {
	"skin": "#8b5a3c",
	"shirt": "#76b852",
	"shirt_dark": "#4f7b36",
	"accent": "#b5d96a",
	"pants": "#294f2f",
	"hair": "#55352b",
}


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	safety = SafetyClass.new()
	executor = ExecutorClass.new()
	behavior = BehaviorClass.new(RuleProviderClass.new(1), safety, executor)
	behavior.decision_proposed.connect(_on_decision_proposed)
	behavior.decision_rejected.connect(_on_decision_rejected)
	behavior.decision_started.connect(_on_decision_started)


func configure(backend_adapter: Object = null, multiplayer_adapter: Object = null, options: Dictionary = {}) -> void:
	backend = backend_adapter
	network_client = multiplayer_adapter
	protocol_version = int(options.get("protocol_version", protocol_version))
	empty_grace_msec = maxi(0, int(float(options.get("empty_grace_seconds", float(empty_grace_msec) / 1000.0)) * 1000.0))
	observation_radius = maxf(32.0, float(options.get("observation_radius", observation_radius)))
	_movement_step_callable = options.get("movement_step", Callable(self, "_default_movement_step")) if options.get("movement_step", Callable(self, "_default_movement_step")) is Callable else Callable(self, "_default_movement_step")
	if options.get("response_enabled", true) is bool:
		safety.response_enabled = bool(options.get("response_enabled", true))
	if options.has("retaliation_window_msec"):
		safety.retaliation_window_msec = maxi(0, int(options.get("retaliation_window_msec", safety.retaliation_window_msec)))
	if options.has("decision_provider") and options.get("decision_provider") is BotDecisionProvider:
		behavior.provider = options.get("decision_provider")
	executor.configure(network_client, Callable(), _movement_step_callable, Callable(safety, "consume_retaliation"))
	_connect_network_signals()


func _connect_network_signals() -> void:
	if _network_signals_connected or network_client == null:
		return
	_network_signals_connected = true
	if network_client.has_signal("connected"):
		network_client.connect("connected", Callable(self, "_on_network_connected"))
	if network_client.has_signal("disconnected"):
		network_client.connect("disconnected", Callable(self, "_on_network_disconnected"))
	if network_client.has_signal("message_received"):
		network_client.connect("message_received", Callable(self, "_on_network_message"))


func join_session(record: Dictionary) -> void:
	if _join_in_flight or state in [STATE_JOINING, STATE_SYNCING, STATE_PLAYING]:
		return
	_left_emitted = false
	_disconnect_requested = false
	sync_complete = false
	empty_since_msec = -1
	_empty_emitted = false
	_snapshot_transfer_id = ""
	_snapshot_expected_chunks = 0
	_snapshot_chunks.clear()
	_roster.clear()
	_recent_events.clear()
	_last_player_snapshot_msec = -1
	_pending_action_targets.clear()
	_host_player_id = ""
	_craft_pending_output = ""
	_craft_retry_after_msec = -1
	_craft_blocked_outputs.clear()
	_population_logged = false
	safety.reset_session()
	_world_snapshot.clear()
	world_id = str(record.get("world_id", ""))
	_set_state(STATE_JOINING)
	if backend == null or not backend.has_method("join_multiplayer_session"):
		_emit_left("backend_unavailable")
		return
	_join_in_flight = true
	var response: Variant = await backend.call(
		"join_multiplayer_session",
		str(record.get("session_id", "")),
		str(record.get("join_code", "")),
		protocol_version,
	)
	_join_in_flight = false
	if state == STATE_LEAVING or _left_emitted:
		return
	if not response is Dictionary or not bool((response as Dictionary).get("ok", false)):
		_emit_left(str((response as Dictionary).get("error", "join_failed")) if response is Dictionary else "join_failed")
		return
	_connect_join_response(response as Dictionary, record)


func connect_join_response(response: Dictionary, record: Dictionary = {}) -> bool:
	return _connect_join_response(response, record)


func _connect_join_response(response: Dictionary, record: Dictionary) -> bool:
	var body: Dictionary = response.get("body", {}) if response.get("body", {}) is Dictionary else {}
	var metadata: Dictionary = body.get("session", {}) if body.get("session", {}) is Dictionary else {}
	if metadata.is_empty():
		metadata = record
	session_id = str(metadata.get("session_id", body.get("session_id", record.get("session_id", ""))))
	world_id = str(metadata.get("world_id", body.get("world_id", world_id)))
	dedicated_server = bool(metadata.get("dedicated_server", body.get("dedicated_server", false)))
	if network_client == null or not network_client.has_method("connect_with_ticket"):
		_emit_left("network_unavailable")
		return false
	if network_client.has_method("set_session_max_players"):
		network_client.call("set_session_max_players", int(metadata.get("max_players", 4)))
	if network_client.has_method("set_dedicated_server_session"):
		network_client.call("set_dedicated_server_session", dedicated_server)
	if network_client.has_method("set_session_classification") and metadata.has("classification"):
		network_client.call("set_session_classification", str(metadata.get("classification", "")))
	var error: Variant = network_client.call(
		"connect_with_ticket",
		str(body.get("websocket_url", "")),
		str(body.get("ws_ticket", "")),
		str(body.get("join_code", metadata.get("join_code", ""))),
		bool(body.get("relay_fallback_enabled", false)),
		protocol_version,
	)
	if int(error) != OK:
		_emit_left("connect_error_%d" % int(error))
		return false
	return true


func handle_message(message: Dictionary) -> void:
	var kind := str(message.get("kind", ""))
	var message_type := str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {}) if message.get("payload", {}) is Dictionary else {}
	if kind == "control" and message_type == "player_joined":
		var joined_id := str(message.get("player_id", ""))
		if not joined_id.is_empty() and joined_id != own_player_id and joined_id != _host_player_id:
			_roster[joined_id] = {"id": joined_id, "health": 10, "alive": true, "role": str(message.get("role", "guest"))}
			_record_event("player_joined", {"player_id": joined_id})
			_update_human_count()
		return
	# MultiplayerClient emits its connected signal as soon as the authenticated
	# WebSocket handshake is complete, but the guest's WebRTC data channel is
	# only usable a moment later.  The regular game requests the snapshot from
	# this message path for exactly that reason.  Waiting here prevents the bot's
	# first request from being dropped while the channel is still negotiating.
	if kind == "control" and message_type == "connected":
		if state in [STATE_JOINING, STATE_SYNCING] and network_client != null and network_client.has_method("send_command"):
			network_client.call("send_command", "snapshot_request", {})
		return
	if kind == "control" and message_type == "player_left":
		var left_id := str(message.get("player_id", ""))
		_roster.erase(left_id)
		_record_event("player_left", {"player_id": left_id})
		_update_human_count()
		return
	if kind == "control" and message_type == "session_closed":
		leave("session_closed")
		return
	if message_type == "snapshot_start":
		_prepare_snapshot(payload)
		return
	if message_type == "snapshot_chunk":
		_prepare_snapshot(payload)
		var transfer_id := str(payload.get("transfer_id", ""))
		if transfer_id == _snapshot_transfer_id:
			var index := int(payload.get("index", -1))
			if index >= 0 and index < _snapshot_chunks.size():
				_snapshot_chunks[index] = str(payload.get("data", ""))
			_apply_snapshot_if_complete()
		return
	if message_type == "snapshot_complete":
		_prepare_snapshot(payload)
		_apply_snapshot_if_complete()
		return
	if message_type == "players_snapshot":
		_apply_players_snapshot(payload)
		return
	if message_type == "player_inventory":
		_apply_inventory_snapshot(payload)
		return
	if message_type == "player_hit":
		if safety.record_player_hit(payload, own_player_id, Time.get_ticks_msec()):
			_record_event("player_hit", {"attacker_player_id": safety.attacker_player_id(), "damage": int(payload.get("damage", 0))})
		else:
			_record_event("player_hit_unattributed", {"target_player_id": str(payload.get("target_player_id", ""))})
		behavior.request_decision(Time.get_ticks_msec())
		return
	if message_type == "action_result":
		_handle_action_result(payload)
		_record_event(message_type, payload)
		return
	if message_type in ["emoji_reaction", "creatures_snapshot", "tile_batch", "plant_batch", "region_complete"]:
		_record_event(message_type, payload)


func _process(delta: float) -> void:
	var now_msec := Time.get_ticks_msec()
	if state == STATE_SYNCING:
		if _sync_started_msec >= 0 and now_msec - _sync_started_msec >= DEFAULT_SYNC_TIMEOUT_MSEC:
			_emit_left("snapshot_timeout")
		return
	if state != STATE_PLAYING:
		return
	_expire_craft_pending(now_msec)
	var observation := _build_observation(now_msec)
	_send_player_snapshot_if_due(now_msec)
	behavior.tick(observation, delta, now_msec)
	if not _empty_emitted and Perception.empty_world_should_leave(sync_complete, human_player_count, empty_since_msec, now_msec, empty_grace_msec):
		_empty_emitted = true
		empty_world_ready.emit()


func leave(reason: String = "leaving") -> void:
	if _left_emitted:
		return
	_set_state(STATE_LEAVING)
	_disconnect_requested = true
	behavior.reset(Time.get_ticks_msec())
	if network_client != null and network_client.has_method("disconnect_from_session"):
		network_client.call("disconnect_from_session")
	_emit_left(reason)


func _on_network_connected(role: String, player_id: String, network_session_id: String) -> void:
	if state != STATE_JOINING and state != STATE_SYNCING:
		return
	if role != "guest":
		_emit_left("unexpected_role")
		return
	own_player_id = player_id
	_host_player_id = _host_id_from_network()
	if not network_session_id.is_empty():
		session_id = network_session_id
	_set_state(STATE_SYNCING)
	_sync_started_msec = Time.get_ticks_msec()
	sync_started.emit(session_id)


func _send_player_snapshot_if_due(now_msec: int) -> void:
	if network_client == null or not network_client.has_method("send_command") or own_player_id.is_empty():
		return
	if _last_player_snapshot_msec >= 0 and now_msec - _last_player_snapshot_msec < PLAYER_SNAPSHOT_INTERVAL_MSEC:
		return
	_last_player_snapshot_msec = now_msec
	var local: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	network_client.call("send_command", "player_snapshot", {
		"x": float(local.get("x", 0.0)),
		"y": float(local.get("y", 0.0)),
		"facing": int(local.get("facing", 1)),
		"vx": float(local.get("vx", 0.0)),
		"vy": float(local.get("vy", 0.0)),
		"on_ground": bool(local.get("on_ground", false)),
		"health": clampi(int(local.get("health", 10)), 0, 10),
		"nourishment": clampi(int(local.get("nourishment", 100)), 0, 100),
		"respawn_revision": int(local.get("respawn_revision", 0)),
		"skin": BOT_SKIN.duplicate(true),
		"equipment_slots": _equipment_slots.duplicate(true),
	})


func _default_movement_step(action: String, decision: Dictionary, observation: Dictionary, delta: float) -> Dictionary:
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	var origin := Contract.target_position(self_state)
	var target := Contract.target_position(decision.get("target", {}))
	var target_id := str(decision.get("target_id", ""))
	if target_id != "":
		for raw_player in observation.get("players", []):
			if raw_player is Dictionary and str((raw_player as Dictionary).get("id", "")) == target_id:
				target = Contract.target_position(raw_player)
				break

	if action == Contract.ACTION_LOOK_AT:
		if target.x != origin.x:
			self_state["facing"] = 1 if target.x > origin.x else -1
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "look_complete"}
	if target == origin:
		return {"done": true, "reason": "already_at_target"}

	var destination := target
	if action in [Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_FOLLOW]:
		destination = Navigator.preferred_follow_target(Vector2(target.x, origin.y), origin, float(observation.get("preferred_player_distance", 84.0)))
	elif action == Contract.ACTION_FLEE_FROM:
		destination = Navigator.step_away_from(origin, Vector2(target.x, origin.y), 120.0)
	else:
		destination.y = origin.y

	var step_distance := maxf(1.0, 72.0 * maxf(delta, 0.0))
	var next_position := Navigator.step_towards(origin, destination, step_distance)
	self_state["x"] = next_position.x
	self_state["y"] = next_position.y
	self_state["vx"] = (next_position.x - origin.x) / maxf(delta, 0.001)
	self_state["vy"] = (next_position.y - origin.y) / maxf(delta, 0.001)
	self_state["facing"] = 1 if next_position.x >= origin.x else -1
	self_state["on_ground"] = true
	_world_snapshot["self"] = self_state
	return {"done": next_position.distance_to(destination) <= 8.0, "reason": "movement_step"}


func _on_network_disconnected(reason: String) -> void:
	if _left_emitted or state == STATE_LEAVING or _disconnect_requested:
		return
	_emit_left("disconnected_%s" % reason)


func _on_network_message(message: Dictionary) -> void:
	handle_message(message)


func _prepare_snapshot(payload: Dictionary) -> void:
	var transfer_id := str(payload.get("transfer_id", ""))
	var total := int(payload.get("total", 0))
	if transfer_id.is_empty() or total <= 0 or total > 1024:
		return
	if _snapshot_transfer_id != transfer_id or _snapshot_expected_chunks != total:
		_snapshot_transfer_id = transfer_id
		_snapshot_expected_chunks = total
		_snapshot_chunks.clear()
		_snapshot_chunks.resize(total)


func _apply_snapshot_if_complete() -> void:
	if _snapshot_expected_chunks <= 0 or _snapshot_chunks.any(func(part: String): return part.is_empty()):
		return
	var compressed := Marshalls.base64_to_raw("".join(_snapshot_chunks))
	var raw := compressed.decompress_dynamic(64 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not parsed is Dictionary:
		_emit_left("snapshot_invalid")
		return
	_apply_world_snapshot(parsed as Dictionary)


func _apply_world_snapshot(snapshot: Dictionary) -> void:
	_world_snapshot = snapshot.duplicate(true)
	world_id = str(snapshot.get("world_id", world_id))
	var local_state: Dictionary = snapshot.get("player", {}) if snapshot.get("player", {}) is Dictionary else {}
	var multiplayer_state: Dictionary = snapshot.get("multiplayer", {}) if snapshot.get("multiplayer", {}) is Dictionary else {}
	var player_states: Dictionary = multiplayer_state.get("player_states", {}) if multiplayer_state.get("player_states", {}) is Dictionary else {}
	_roster.clear()
	for raw_id in player_states:
		var player_id := str(raw_id)
		if player_id == own_player_id or player_id == _host_player_id:
			continue
		var player_state := player_states[raw_id] as Dictionary if player_states[raw_id] is Dictionary else {}
		player_state["id"] = player_id
		player_state["alive"] = int(player_state.get("health", 10)) > 0
		_roster[player_id] = player_state.duplicate(true)
	_world_snapshot["self"] = local_state.duplicate(true)
	_world_snapshot["inventory_summary"] = _inventory_by_name(snapshot.get("inventory", {}))
	_world_snapshot["recipes"] = _recipe_catalog(snapshot)
	_equipment_slots = _equipment_by_name(snapshot.get("equipment_slots", {}))
	_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	_world_snapshot["craft_pending_output"] = _craft_pending_output
	_world_snapshot["craft_retry_after_msec"] = _craft_retry_after_msec
	_world_snapshot["craft_blocked_outputs"] = _craft_blocked_outputs.keys()
	_world_snapshot["visible_resources"] = _visible_resources_from_tiles(_world_snapshot.get("tiles", []), local_state)
	_world_snapshot["threats"] = _threats_from_creatures(_world_snapshot.get("creatures", []))
	sync_complete = true
	_snapshot_transfer_id = ""
	_snapshot_expected_chunks = 0
	_snapshot_chunks.clear()
	_update_human_count()
	_set_state(STATE_PLAYING)
	_send_inventory_snapshot()
	_welcome_emoji_pending = human_player_count > 0
	_welcome_emoji_due_msec = Time.get_ticks_msec() + 900 if _welcome_emoji_pending else -1
	behavior.request_decision(Time.get_ticks_msec())
	session_ready.emit(session_id, own_player_id)


func _block_name_for_content_id(content_id: String) -> String:
	var defs := get_node_or_null("/root/BlockDefs")
	if defs != null and defs.has_method("name_for_content_id"):
		var resolved := str(defs.call("name_for_content_id", content_id))
		if not resolved.is_empty():
			return resolved
	var blocks: Dictionary = defs.get("BLOCKS") if defs != null and defs.get("BLOCKS") is Dictionary else {}
	for block_name: String in blocks:
		if str(blocks[block_name].get("content_id", "core.%s" % block_name)) == content_id:
			return block_name
	return ""


func _block_entry(block_name: String) -> Dictionary:
	var defs := get_node_or_null("/root/BlockDefs")
	var blocks: Dictionary = defs.get("BLOCKS") if defs != null and defs.get("BLOCKS") is Dictionary else {}
	return blocks.get(block_name, {}) if blocks.get(block_name, {}) is Dictionary else {}


func _inventory_by_name(raw_inventory: Variant) -> Dictionary:
	var result := {}
	if not raw_inventory is Dictionary:
		return result
	for raw_id in raw_inventory:
		var name := _block_name_for_content_id(str(raw_id))
		if not name.is_empty():
			result[name] = int((raw_inventory as Dictionary)[raw_id])
	return result


func _equipment_by_name(raw_equipment: Variant) -> Dictionary:
	var result := {"hand": "", "feet": ""}
	if not raw_equipment is Dictionary:
		return result
	for slot_name in result:
		result[slot_name] = _block_name_for_content_id(str((raw_equipment as Dictionary).get(slot_name, "")))
	return result


func _recipe_catalog(snapshot: Dictionary) -> Array:
	var result: Array = []
	for raw_recipe in BlockDefs.RECIPES:
		var recipe := _resolve_content_recipe(raw_recipe)
		if not recipe.is_empty():
			recipe["station_available"] = _station_available(snapshot, str(recipe.get("station", "")))
			result.append(recipe)
	for raw_recipe in BlockDefs.CONTENT_RECIPES:
		var recipe := _resolve_content_recipe(raw_recipe)
		if not recipe.is_empty():
			recipe["station_available"] = _station_available(snapshot, str(recipe.get("station", "")))
			result.append(recipe)
	return result


func _resolve_content_recipe(raw_recipe: Dictionary) -> Dictionary:
	var resolved := {"in": {}, "out": {}}
	for side in ["in", "out"]:
		var values: Dictionary = raw_recipe.get(side, {}) if raw_recipe.get(side, {}) is Dictionary else {}
		for raw_id in values:
			var raw_name := str(raw_id)
			var name := raw_name if not _block_entry(raw_name).is_empty() else _block_name_for_content_id(raw_name)
			if name.is_empty():
				return {}
			resolved[side][name] = int(values[raw_id])
	var station := str(raw_recipe.get("station", ""))
	if not station.is_empty():
		resolved["station"] = station
	return resolved


func _station_available(snapshot: Dictionary, station: String) -> bool:
	if station.is_empty():
		return true
	var tiles: Array = snapshot.get("tiles", []) if snapshot.get("tiles", []) is Array else []
	for raw_tile in tiles:
		if not raw_tile is Dictionary:
			continue
		var name := _block_name_for_content_id(str((raw_tile as Dictionary).get("content_id", "")))
		if not name.is_empty() and str(_block_entry(name).get("station", "")) == station:
			return true
	return false


func _apply_players_snapshot(payload: Dictionary) -> void:
	var players: Dictionary = payload.get("players", {}) if payload.get("players", {}) is Dictionary else {}
	# The host sends the complete authoritative roster on every snapshot. Do not
	# retain IDs from an earlier player_joined stream after those players leave.
	_roster.clear()
	for raw_id in players:
		var player_id := str(raw_id)
		if player_id == own_player_id or player_id == _host_player_id or not players[raw_id] is Dictionary:
			continue
		var entry := (players[raw_id] as Dictionary).duplicate(true)
		entry["id"] = player_id
		entry["alive"] = int(entry.get("health", 10)) > 0
		_roster[player_id] = entry
	_update_human_count()


func _send_inventory_snapshot() -> void:
	if network_client == null or not network_client.has_method("send_command"):
		return
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	network_client.call("send_command", "inventory_snapshot", {
		"inventory_host_revision": 0,
		"inventory_client_revision": 0,
		"inventory": inventory.duplicate(true),
		"item_durability": {},
		"footwear_wear_distance": 0.0,
		"inventory_order": inventory.keys(),
		"hotbar_slots": ["", "", "", "", "", ""],
		"equipment_slots": _equipment_slots.duplicate(true),
		"active_hotbar_slot": 0,
		"selected": "",
		"nourishment": int((_world_snapshot.get("self", {}) as Dictionary).get("nourishment", 100)),
		"craft_slots": [null, null, null, null],
		"craft_slot_durability": [0, 0, 0, 0],
	})


func _apply_inventory_snapshot(payload: Dictionary) -> void:
	var inventory: Dictionary = payload.get("inventory", {}) if payload.get("inventory", {}) is Dictionary else {}
	_world_snapshot["inventory_summary"] = inventory.duplicate(true)
	_equipment_slots = payload.get("equipment_slots", _equipment_slots).duplicate(true) if payload.get("equipment_slots", _equipment_slots) is Dictionary else _equipment_slots
	_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	if not _craft_pending_output.is_empty() and int(inventory.get(_craft_pending_output, 0)) > 0:
		_craft_blocked_outputs.erase(_craft_pending_output)
		_craft_pending_output = ""
		_craft_retry_after_msec = Time.get_ticks_msec() + CRAFT_RETRY_DELAY_MSEC


func _update_human_count() -> void:
	var next_count := Perception.count_live_humans(_roster, own_player_id, [_host_player_id], dedicated_server)
	var changed := next_count != human_player_count
	if not changed and _population_logged:
		return
	human_player_count = next_count
	if sync_complete and human_player_count <= 0:
		if empty_since_msec < 0:
			empty_since_msec = Time.get_ticks_msec()
	else:
		empty_since_msec = -1
	human_player_count_changed.emit(human_player_count)
	if changed or not _population_logged:
		structured_log.emit({
			"event": "player_population",
			"human_player_count": next_count,
			"roster_count": _roster.size(),
			"host_player_id": _host_player_id,
			"dedicated_server": dedicated_server,
			"at_msec": Time.get_ticks_msec(),
		})
		_population_logged = true
	var achievements := get_node_or_null("/root/Achievements")
	if achievements != null and achievements.has_method("record_multiplayer_players"):
		achievements.call("record_multiplayer_players", human_player_count + 1)


func _build_observation(now_msec: int) -> Dictionary:
	var snapshot := _world_snapshot.duplicate(true)
	snapshot["self"] = snapshot.get("self", {"health": 10, "x": 0.0, "y": 0.0})
	snapshot["players"] = _roster.values()
	snapshot["recent_events"] = _recent_events.duplicate(true)
	snapshot["world_id"] = world_id
	snapshot["legal_actions"] = Contract.ALL_ACTIONS
	snapshot["self_defense"] = safety.observation_state(now_msec)
	snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	snapshot["craft_pending_output"] = _craft_pending_output
	snapshot["craft_retry_after_msec"] = _craft_retry_after_msec
	snapshot["craft_blocked_outputs"] = _craft_blocked_outputs.keys()
	var achievements := get_node_or_null("/root/Achievements")
	snapshot["achievements"] = {"unlocked": achievements.call("unlocked_ids") if achievements != null and achievements.has_method("unlocked_ids") else []}
	if _welcome_emoji_pending and now_msec >= _welcome_emoji_due_msec:
		snapshot["social_emoji"] = "👋"
	else:
		snapshot["social_emoji"] = ""
	return Perception.build(snapshot, own_player_id, observation_radius, now_msec)


func _visible_resources_from_tiles(raw_tiles: Variant, self_state: Dictionary) -> Array:
	var resources: Array = []
	if not raw_tiles is Array:
		return resources
	var origin := Contract.target_position(self_state)
	var max_distance := observation_radius + float(BlockDefs.TILE)
	for raw_tile in raw_tiles:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var tile_x := int(tile.get("x", 0))
		var tile_y := int(tile.get("y", 0))
		var position := Vector2((float(tile_x) + 0.5) * BlockDefs.TILE, (float(tile_y) + 0.5) * BlockDefs.TILE)
		if origin.distance_to(position) > max_distance:
			continue
		resources.append({
			"id": "tile:%d:%d" % [tile_x, tile_y],
			"x": tile_x,
			"y": tile_y,
			"content_id": str(tile.get("content_id", "")),
			"position": [position.x, position.y],
			"reachable": origin.distance_to(position) <= float(BlockDefs.TILE) * 2.5,
		})
		if resources.size() >= 256:
			break
	return resources


func _threats_from_creatures(raw_creatures: Variant) -> Array:
	var threats: Array = []
	if not raw_creatures is Array:
		return threats
	for raw_creature in raw_creatures:
		if not raw_creature is Dictionary:
			continue
		var creature := (raw_creature as Dictionary).duplicate(true)
		if bool(creature.get("dead", false)):
			continue
		var position := Vector2((float(creature.get("x", 0.0)) + 0.5) * BlockDefs.TILE, (float(creature.get("y", 0.0)) + 0.5) * BlockDefs.TILE)
		creature["position"] = [position.x, position.y]
		creature["hostile"] = true
		threats.append(creature)
	return threats


func _record_event(event_name: String, data: Dictionary) -> void:
	var event := {"type": event_name, "at_msec": Time.get_ticks_msec()}
	for key in data:
		event[key] = data[key]
	_recent_events.append(event)
	while _recent_events.size() > 12:
		_recent_events.pop_front()


func _on_decision_proposed(decision: Dictionary) -> void:
	decision_logged.emit({"event": "decision_proposed", "decision": decision.duplicate(true), "at_msec": Time.get_ticks_msec()})


func _on_decision_rejected(decision: Dictionary, reason: String) -> void:
	decision_logged.emit({"event": "decision_rejected", "decision": decision.duplicate(true), "reason": reason, "at_msec": Time.get_ticks_msec()})


func _on_decision_started(decision: Dictionary) -> void:
	var now_msec := Time.get_ticks_msec()
	var action := str(decision.get("action", ""))
	if action == Contract.ACTION_EQUIP:
		var item_name := str(decision.get("target_id", ""))
		if not item_name.is_empty():
			if item_name.contains("boots") or item_name.contains("sandals"):
				_equipment_slots["feet"] = item_name
			else:
				_equipment_slots["hand"] = item_name
		_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	elif action == Contract.ACTION_MINE or action == Contract.ACTION_PLACE:
		var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
		var key := "%d:%d" % [int(target.get("x", 0)), int(target.get("y", 0))]
		_pending_action_targets[key] = {"action": action, "block": str(decision.get("block", "")), "content_id": str(target.get("content_id", ""))}
	elif action == Contract.ACTION_CRAFT:
		_craft_pending_output = str(decision.get("target_id", ""))
		_craft_retry_after_msec = now_msec + CRAFT_RESPONSE_TIMEOUT_MSEC
		_pending_action_targets["craft"] = {"action": action, "output": _craft_pending_output}
	if action == Contract.ACTION_SEND_EMOJI:
		var emoji := str(decision.get("emoji", ""))
		if _social.emoji_can_send(_last_emoji_sent_msec, now_msec, emoji, _previous_emoji, _social_last_sent_msec):
			_last_emoji_sent_msec = now_msec
			_social_last_sent_msec = now_msec
			_previous_emoji = emoji
			_welcome_emoji_pending = false
		else:
			behavior.executor.cancel("emoji_cooldown")
	decision_logged.emit({"event": "decision_started", "decision": decision.duplicate(true), "at_msec": now_msec})


func _handle_action_result(payload: Dictionary) -> void:
	var action := str(payload.get("action", ""))
	if action == "craft_recipe":
		var accepted := bool(payload.get("accepted", false))
		var craft: Dictionary = _pending_action_targets.get("craft", {}) if _pending_action_targets.get("craft", {}) is Dictionary else {}
		var output := str(craft.get("output", payload.get("output", "")))
		_craft_pending_output = ""
		if not accepted and not output.is_empty():
			_craft_blocked_outputs[output] = true
		elif accepted:
			_craft_blocked_outputs.erase(output)
		_craft_retry_after_msec = Time.get_ticks_msec() + (CRAFT_RETRY_DELAY_MSEC if not accepted else 2_000)
		_pending_action_targets.erase("craft")
		var achievements := get_node_or_null("/root/Achievements")
		if accepted and achievements != null and achievements.has_method("record_craft"):
			achievements.call("record_craft", output)
		return
	if not bool(payload.get("accepted", false)):
		return
	var achievements := get_node_or_null("/root/Achievements")
	if achievements == null:
		return
	var key := "%d:%d" % [int(payload.get("x", 0)), int(payload.get("y", 0))]
	var target: Dictionary = _pending_action_targets.get(key, {}) if _pending_action_targets.get(key, {}) is Dictionary else {}
	_pending_action_targets.erase(key)
	if action == "mine_block" and achievements.has_method("record_block_mined"):
		achievements.call("record_block_mined", _block_name_for_content_id(str(target.get("content_id", ""))))
	elif action == "place_block" and achievements.has_method("record_block_placed"):
		achievements.call("record_block_placed", str(target.get("block", "")))


func _emit_left(reason: String) -> void:
	if _left_emitted:
		return
	_left_emitted = true
	_set_state(STATE_LEAVING)
	structured_log.emit({"event": "session_left", "session_id": session_id, "reason": reason, "at_msec": Time.get_ticks_msec()})
	session_left.emit(reason)


func _host_id_from_network() -> String:
	if network_client != null and network_client.has_method("host_player_id"):
		return str(network_client.call("host_player_id"))
	return ""


func _expire_craft_pending(now_msec: int) -> void:
	if _craft_pending_output.is_empty() or _craft_retry_after_msec < 0 or now_msec < _craft_retry_after_msec:
		return
	# Older community hosts may ignore the newer craft_recipe command. Mark the
	# output unavailable for this session instead of retrying forever and
	# starving the bot's mining/building goals.
	_craft_blocked_outputs[_craft_pending_output] = true
	_craft_pending_output = ""
	_craft_retry_after_msec = -1


func _set_state(next_state: String) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(state)
