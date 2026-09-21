class_name BotSupervisor
extends Node

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const Perception = preload("res://gameplay/scripts/bot/bot_perception.gd")
const SessionClass = preload("res://gameplay/scripts/bot/bot_session.gd")

signal state_changed(state: String)
signal session_selected(session: Dictionary)
signal session_finished(session: Dictionary, reason: String)
signal structured_log(event: Dictionary)

const STATE_BOOT := "BOOT"
const STATE_DISCOVERING := "DISCOVERING"
const STATE_JOINING := "JOINING"
const STATE_SYNCING := "SYNCING"
const STATE_PLAYING := "PLAYING"
const STATE_LEAVING := "LEAVING"
const STATE_COOLDOWN := "COOLDOWN"

const DEFAULT_PROTOCOL_VERSION := 2
const DEFAULT_DISCOVERY_INTERVAL_SECONDS := 12.0
const DEFAULT_EMPTY_GRACE_SECONDS := 30.0
const DEFAULT_SESSION_COOLDOWN_SECONDS := 300.0
const DEFAULT_MAX_SESSION_SECONDS := 1800.0
const DEFAULT_RETRY_BASE_SECONDS := 5.0
const DEFAULT_RETRY_MAX_SECONDS := 300.0
## Community servers are operated by us but are reported by the backend as
## `official`.  They are safe for the bot because they use the dedicated
## server protocol; first-party official worlds must still remain excluded.
const MANAGED_COMMUNITY_WORLD_IDS := [
	"world_skyloft",
	"world_pandora",
	"world_b612",
	"world_wonderland",
]

var backend: Object
var network_client: Object
var session: BotSession
var state := STATE_BOOT
var protocol_version := DEFAULT_PROTOCOL_VERSION
var discovery_limit := 50
var discovery_interval_seconds := DEFAULT_DISCOVERY_INTERVAL_SECONDS
var empty_grace_seconds := DEFAULT_EMPTY_GRACE_SECONDS
var session_cooldown_seconds := DEFAULT_SESSION_COOLDOWN_SECONDS
var max_session_seconds := DEFAULT_MAX_SESSION_SECONDS
var enabled := true
var kill_switch := false
var allow_world_ids: PackedStringArray = []
var recently_visited: Dictionary = {}
var blacklisted_sessions: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _next_discovery_msec := 0
var _cooldown_until_msec := 0
var _retry_attempt := 0
var _discovery_in_flight := false
var _current_session_record: Dictionary = {}
var _session_started_msec := -1


func _init() -> void:
	_rng.randomize()
	process_mode = Node.PROCESS_MODE_ALWAYS


func configure(backend_adapter: Object = null, multiplayer_adapter: Object = null, options: Dictionary = {}) -> void:
	backend = backend_adapter
	network_client = multiplayer_adapter
	protocol_version = int(options.get("protocol_version", protocol_version))
	discovery_limit = clampi(int(options.get("discovery_limit", discovery_limit)), 1, 50)
	discovery_interval_seconds = maxf(1.0, float(options.get("discovery_interval_seconds", discovery_interval_seconds)))
	empty_grace_seconds = maxf(0.0, float(options.get("empty_grace_seconds", empty_grace_seconds)))
	session_cooldown_seconds = maxf(0.0, float(options.get("session_cooldown_seconds", session_cooldown_seconds)))
	max_session_seconds = maxf(0.0, float(options.get("max_session_seconds", max_session_seconds)))
	enabled = bool(options.get("enabled", enabled))
	kill_switch = bool(options.get("kill_switch", kill_switch))
	allow_world_ids = _normalize_string_array(options.get("allow_world_ids", options.get("allowed_world_ids", [])))
	if options.has("seed"):
		_rng.seed = int(options.get("seed", 0))


func start() -> void:
	if not enabled or kill_switch:
		_log("disabled", {})
		return
	_retry_attempt = 0
	_set_state(STATE_DISCOVERING)
	_next_discovery_msec = 0


func stop(reason: String = "stopped") -> void:
	enabled = false
	if session != null:
		_set_state(STATE_LEAVING)
		session.leave(reason)
	else:
		_set_state(STATE_COOLDOWN)
		_cooldown_until_msec = Time.get_ticks_msec() + int(session_cooldown_seconds * 1000.0)


func _process(_delta: float) -> void:
	if not enabled or kill_switch:
		return
	var now_msec := Time.get_ticks_msec()
	if session != null:
		if max_session_seconds > 0.0 and _session_started_msec >= 0 and now_msec - _session_started_msec >= int(max_session_seconds * 1000.0):
			_set_state(STATE_LEAVING)
			session.leave("max_session_time")
		return
	if state == STATE_COOLDOWN:
		if now_msec >= _cooldown_until_msec:
			_set_state(STATE_DISCOVERING)
			_next_discovery_msec = now_msec
		return
	if state in [STATE_BOOT, STATE_DISCOVERING] and now_msec >= _next_discovery_msec and not _discovery_in_flight:
		_discover()


func _discover() -> void:
	if backend == null or not backend.has_method("list_multiplayer_sessions"):
		_schedule_retry("backend_unavailable")
		return
	_discovery_in_flight = true
	_set_state(STATE_DISCOVERING)
	var response: Variant = await backend.call("list_multiplayer_sessions", discovery_limit)
	_discovery_in_flight = false
	if not enabled or kill_switch:
		return
	if not response is Dictionary or not bool((response as Dictionary).get("ok", false)):
		_schedule_retry(str((response as Dictionary).get("error", "discovery_failed")) if response is Dictionary else "discovery_failed")
		return
	var body: Dictionary = (response as Dictionary).get("body", {}) if (response as Dictionary).get("body", {}) is Dictionary else {}
	var candidates := filter_public_sessions(body.get("sessions", []), protocol_version, Time.get_ticks_msec(), recently_visited)
	if not allow_world_ids.is_empty():
		candidates = candidates.filter(func(entry: Dictionary): return str(entry.get("world_id", "")) in allow_world_ids)
	if candidates.is_empty():
		_schedule_retry("no_eligible_world")
		return
	var selected := pick_session(candidates, _rng.randf())
	if selected.is_empty():
		_schedule_retry("selection_failed")
		return
	_current_session_record = selected.duplicate(true)
	_current_session_record["selected_at_msec"] = Time.get_ticks_msec()
	session_selected.emit(_current_session_record.duplicate(true))
	_log("session_selected", {"session_id": str(selected.get("session_id", "")), "world_id": str(selected.get("world_id", ""))})
	_create_session()
	_set_state(STATE_JOINING)
	session.join_session(selected)


func _create_session() -> void:
	if session != null:
		session.queue_free()
	session = SessionClass.new()
	add_child(session)
	session.configure(backend, network_client, {
		"empty_grace_seconds": empty_grace_seconds,
		"protocol_version": protocol_version,
	})
	session.session_ready.connect(_on_session_ready)
	session.sync_started.connect(_on_session_sync_started)
	session.empty_world_ready.connect(_on_empty_world_ready)
	session.session_left.connect(_on_session_left)
	session.structured_log.connect(_on_session_log)
	session.decision_logged.connect(_on_session_decision)


func _on_session_sync_started(_session_id: String) -> void:
	_set_state(STATE_SYNCING)


func _on_session_ready(_session_id: String, _player_id: String) -> void:
	_retry_attempt = 0
	_session_started_msec = Time.get_ticks_msec()
	_set_state(STATE_PLAYING)


func _on_empty_world_ready() -> void:
	if session == null:
		return
	_set_state(STATE_LEAVING)
	session.leave("empty_world_grace_elapsed")


func _on_session_left(reason: String) -> void:
	var finished := _current_session_record.duplicate(true)
	finished["reason"] = reason
	var visited_key := str(finished.get("world_id", finished.get("session_id", "")))
	if not visited_key.is_empty():
		recently_visited[visited_key] = Time.get_ticks_msec()
	session_finished.emit(finished, reason)
	if session != null:
		session.queue_free()
	session = null
	_session_started_msec = -1
	_current_session_record.clear()
	_set_state(STATE_COOLDOWN)
	_cooldown_until_msec = Time.get_ticks_msec() + int(session_cooldown_seconds * 1000.0)


func _on_session_log(event: Dictionary) -> void:
	structured_log.emit(event.duplicate(true))


func _on_session_decision(event: Dictionary) -> void:
	var entry := {"event": "bot_decision"}
	for key in event:
		entry[key] = event[key]
	structured_log.emit(entry)


func _schedule_retry(reason: String) -> void:
	_retry_attempt += 1
	var delay := retry_delay_seconds(_retry_attempt, _rng.randf())
	_next_discovery_msec = Time.get_ticks_msec() + int(delay * 1000.0)
	_set_state(STATE_DISCOVERING)
	_log("discovery_retry", {"attempt": _retry_attempt, "delay_seconds": delay, "reason": reason})


func _set_state(next_state: String) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(state)


func _log(event_name: String, data: Dictionary) -> void:
	var event := {"event": event_name, "at_msec": Time.get_ticks_msec()}
	for key in data:
		event[key] = data[key]
	structured_log.emit(event)


func filter_public_sessions(sessions: Array, expected_protocol_version: int = DEFAULT_PROTOCOL_VERSION, now_msec: int = 0, recently_visited_sessions: Dictionary = {}) -> Array:
	var result: Array = []
	for raw_session in sessions:
		if not raw_session is Dictionary:
			continue
		var entry := (raw_session as Dictionary).duplicate(true)
		var session_id := str(entry.get("session_id", ""))
		var world_id := str(entry.get("world_id", ""))
		var access_mode := str(entry.get("access_mode", "public")).to_lower()
		var world_mode := str(entry.get("world_mode", "")).to_lower()
		var player_count := _display_player_count(entry)
		var max_players := int(entry.get("max_players", 0))
		var blacklist_until := int(entry.get("blacklisted_until_msec", blacklisted_sessions.get(session_id, 0)))
		var recent_at := int(recently_visited_sessions.get(world_id, recently_visited_sessions.get(session_id, 0)))
		var current_now := now_msec if now_msec > 0 else Time.get_ticks_msec()
		var official := bool(entry.get("official", entry.get("is_official", false)))
		var dedicated_server := bool(entry.get("dedicated_server", false))
		if session_id.is_empty() or access_mode != "public" or world_mode == "duel":
			continue
		# Managed community worlds are marked `official` by the backend even
		# though they are intended to be visible in the community pool.  Keep
		# first-party official worlds out, but allow those known dedicated worlds.
		var managed_community := dedicated_server and world_id in MANAGED_COMMUNITY_WORLD_IDS
		if official and not managed_community:
			continue
		# P2P worlds are host-authoritative.  Only join when the listing carries
		# the host/creator version proving it understands the current protocol;
		# an absent version is deliberately rejected rather than guessed.
		if not dedicated_server and not _p2p_host_supported(entry):
			continue
		var minimum_client_version := str(entry.get("minimum_client_version", entry.get("min_client_version", "")))
		if not minimum_client_version.is_empty() and not Contract.client_version_at_least(
			minimum_client_version,
			Contract.MIN_SUPPORTED_CLIENT_VERSION,
		):
			continue
		if int(entry.get("protocol_version", -1)) != expected_protocol_version:
			continue
		if player_count < 1 or (max_players > 0 and player_count >= max_players):
			continue
		if blacklist_until > current_now or (recent_at > 0 and current_now - recent_at < int(session_cooldown_seconds * 1000.0)):
			continue
		result.append(entry)
	return result


func _p2p_host_supported(entry: Dictionary) -> bool:
	var host_version := _session_host_client_version(entry)
	if host_version.strip_edges().is_empty():
		return false
	return Contract.client_version_at_least(host_version, Contract.MIN_SUPPORTED_CLIENT_VERSION)


func _session_host_client_version(entry: Dictionary) -> String:
	for key in [
		"host_client_version",
		"creator_client_version",
		"owner_client_version",
		"host_version",
		"creator_version",
		"owner_version",
	]:
		if entry.has(key):
			return str(entry.get(key, ""))
	for container_key in ["host", "creator", "owner", "host_player", "creator_player"]:
		var nested: Variant = entry.get(container_key, null)
		if not nested is Dictionary:
			continue
		var nested_entry := nested as Dictionary
		for key in ["client_version", "version"]:
			if nested_entry.has(key):
				return str(nested_entry.get(key, ""))
	return ""


func filter_sessions(sessions: Array, expected_protocol_version: int = DEFAULT_PROTOCOL_VERSION, now_msec: int = 0, recently_visited_sessions: Dictionary = {}) -> Array:
	return filter_public_sessions(sessions, expected_protocol_version, now_msec, recently_visited_sessions)


func pick_session(sessions: Array, random_unit: float = 0.5) -> Dictionary:
	if sessions.is_empty():
		return {}
	var weighted: Array[Dictionary] = []
	var total := 0.0
	for raw_session in sessions:
		if not raw_session is Dictionary:
			continue
		var entry := raw_session as Dictionary
		var count := _display_player_count(entry)
		var weight := 1.0 + (0.35 if count <= 3 else 0.0)
		weighted.append({"entry": entry, "weight": weight})
		total += weight
	if weighted.is_empty():
		return {}
	var cursor := clampf(random_unit, 0.0, 0.999999) * total
	for item in weighted:
		cursor -= float(item["weight"])
		if cursor <= 0.0:
			return (item["entry"] as Dictionary).duplicate(true)
	return (weighted.back()["entry"] as Dictionary).duplicate(true)


func human_player_count(players: Variant, bot_player_id: String, dedicated_server: bool = false, host_player_id: String = "") -> int:
	var excluded_ids: Array = []
	if not host_player_id.is_empty():
		excluded_ids.append(host_player_id)
	return Perception.count_live_humans(players, bot_player_id, excluded_ids, dedicated_server)


func _display_player_count(entry: Dictionary) -> int:
	var count := int(entry.get("player_count", entry.get("players", 0)))
	if bool(entry.get("dedicated_server_includes_host", false)):
		count -= 1
	return maxi(0, count)


func count_human_players(players: Variant, bot_player_id: String, dedicated_server: bool = false, host_player_id: String = "") -> int:
	return human_player_count(players, bot_player_id, dedicated_server, host_player_id)


func should_leave_empty_world(empty_since_msec: int, now_msec: int, grace_msec: int) -> bool:
	return Perception.empty_world_should_leave(true, 0, empty_since_msec, now_msec, grace_msec)


func empty_grace_elapsed(empty_since_msec: int, now_msec: int, grace_msec: int) -> bool:
	return should_leave_empty_world(empty_since_msec, now_msec, grace_msec)


func retry_delay_seconds(attempt: int, jitter_unit: float = 0.5) -> float:
	var backoff := minf(DEFAULT_RETRY_MAX_SECONDS, DEFAULT_RETRY_BASE_SECONDS * pow(2.0, float(maxi(0, attempt - 1))))
	var jitter := (clampf(jitter_unit, 0.0, 1.0) * 2.0 - 1.0) * 0.2
	return minf(DEFAULT_RETRY_MAX_SECONDS, backoff * (1.0 + jitter))


func _normalize_string_array(value: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if value is PackedStringArray or value is Array:
		for raw_value in value:
			var normalized := str(raw_value).strip_edges()
			if not normalized.is_empty() and normalized not in result:
				result.append(normalized)
	return result
