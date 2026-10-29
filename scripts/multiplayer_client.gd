extends Node

signal connected(role: String, player_id: String, session_id: String)
signal disconnected(reason: String)
signal message_received(message: Dictionary)
signal transport_changed(mode: String)
signal voice_packet_received(sender_player_id: String, sequence: int, audio: PackedByteArray)

const PROTOCOL_VERSION := 2
const DUEL_PROTOCOL_VERSION := 3
const MANAGED_PROTOCOL_VERSION := 4
const CLIENT_VERSION_SETTING := "application/config/version"
const MAX_PLAYERS := 4
const HEARTBEAT_SECONDS := 15.0
const RTC_CONNECT_TIMEOUT_SECONDS := 4.0
const RTC_PING_SECONDS := 2.0
const RTC_SILENCE_TIMEOUT_SECONDS := 7.0
const RTC_PING_RESPONSE_GRACE_SECONDS := 3.0
const RTC_RECONNECT_TIMEOUT_SECONDS := 6.0
const RTC_MAX_RECONNECT_ATTEMPTS := 3
const RTC_MAX_OFFER_GENERATION := 2147483647
const RTC_MAX_FUTURE_OFFER_GENERATION_GAP := RTC_MAX_RECONNECT_ATTEMPTS + 1
const RTC_MAX_FUTURE_OFFER_GENERATIONS_PER_PEER := RTC_MAX_RECONNECT_ATTEMPTS + 1
const RTC_MAX_FUTURE_CANDIDATES_PER_PEER := 32
const RTC_MAX_FUTURE_CANDIDATE_BYTES_PER_PEER := 16 * 1024
const RTC_MAX_CANDIDATE_TEXT_LENGTH := 2048
const RTC_MAX_CANDIDATE_MEDIA_LENGTH := 64
const RTC_MAX_CONNECTION_ID_LENGTH := 128
const RTC_DIAGNOSTIC_TRACE_LIMIT := 64
const RTC_DIAGNOSTIC_CANDIDATES_PER_PEER := 8
const RTC_SILENCE_RECOVERY_WEBSOCKET := "websocket"
const RTC_SILENCE_RECOVERY_RECONNECT := "reconnecting"
const RTC_SILENCE_RECOVERY_DROP_PEER := "drop_peer"
const RTC_CHANNEL_ID := 1
const RTC_VOICE_CHANNEL_ID := 2
const VOICE_PACKET_MAGIC := 0x56
const VOICE_PACKET_VERSION := 1
const VOICE_MAX_PLAYER_ID_BYTES := 64
const VOICE_MAX_AUDIO_BYTES := 1024
const RTC_CONFIGURATION := {
	"iceServers": [
		{"urls": ["stun:stun.l.google.com:19302"]},
		{"urls": ["stun:stun1.l.google.com:19302"]},
		{"urls": ["stun:stun.cloudflare.com:3478"]},
		{"urls": ["stun:global.stun.twilio.com:3478"]},
	]
}

var socket: WebSocketPeer
var role := ""
var player_id := ""
var session_id := ""
var join_code := ""
var transport_mode := "websocket"
var last_websocket_close_code := -1
var last_websocket_close_was_clean := false
var websocket_fallback_enabled := false
var session_protocol_version := PROTOCOL_VERSION
var _session_max_players := MAX_PLAYERS
var _dedicated_server_session := false
var _session_classification := ""
var _heartbeat_left := HEARTBEAT_SECONDS
var _was_open := false
var _known_players: Dictionary = {}
var _rtc_peers: Dictionary = {}
var _rtc_channels: Dictionary = {}
var _rtc_voice_channels: Dictionary = {}
var _rtc_remote_description_set: Dictionary = {}
var _rtc_pending_candidates: Dictionary = {}
var _rtc_future_candidate_buffers: Dictionary = {}
var _rtc_ready_peers: Dictionary = {}
var _rtc_connection_ids: Dictionary = {}
var _rtc_offer_generations: Dictionary = {}
var _rtc_highest_offer_generations: Dictionary = {}
var _rtc_highest_offer_connection_ids: Dictionary = {}
var _rtc_last_seen_msec: Dictionary = {}
var _rtc_last_ping_sent_msec: Dictionary = {}
var _rtc_silence_probe_deadline_msec: Dictionary = {}
var _rtc_silence_probe_diagnostics: Dictionary = {}
var _guest_host_id := ""
var _guest_connected_message: Dictionary = {}
var _guest_connect_time_left := 0.0
var _connected_message_emitted := false
var _rtc_ping_left := RTC_PING_SECONDS
var _rtc_offer_generation := 0
var _rtc_last_poll_msec := 0
var _rtc_last_poll_gap_msec := 0
var _rtc_last_ping_put_ok: Dictionary = {}
var _rtc_diagnostic_trace: Array[Dictionary] = []
var _rtc_observed_state_signatures: Dictionary = {}
var _rtc_diagnostic_candidate_counts: Dictionary = {}
var _rtc_diagnostic_event_counts: Dictionary = {}
var rtc_diagnostics_enabled := false
var last_rtc_silence_diagnostics: Dictionary = {}
var _rtc_reconnect_attempt := 0
var _rtc_reconnect_left := -1.0
var _rtc_reconnect_connect_left := 0.0
var _rtc_reconnecting := false


func client_version() -> String:
	return str(ProjectSettings.get_setting(CLIENT_VERSION_SETTING, "0.0.0"))


func _ready() -> void:
	# The host must keep its signaling heartbeat alive while a fullscreen ad
	# pauses gameplay; otherwise the public session expires after 45 seconds.
	process_mode = Node.PROCESS_MODE_ALWAYS
	rtc_diagnostics_enabled = OS.get_environment("TINYBLOCK_MANAGED_RTC_DIAGNOSTICS") == "1"


func is_online() -> bool:
	return socket != null and socket.get_ready_state() == WebSocketPeer.STATE_OPEN


func is_host() -> bool:
	return is_online() and role == "host"


func is_guest() -> bool:
	return is_online() and role == "guest"


func host_player_id() -> String:
	"""Return the authoritative host id for the current guest session.

	Dedicated sessions do not include the headless host in the player count shown
	to users, but the host can still appear in the initial roster/control stream.
	The bot uses this identity to avoid treating the server process as a human.
	"""
	return _guest_host_id if is_guest() else ""


func is_p2p() -> bool:
	if is_guest():
		return _rtc_channel_open(_guest_host_id)
	if is_host():
		return not _rtc_ready_peers.is_empty()
	return false


func player_count() -> int:
	var count := _known_players.size()
	if _dedicated_server_session:
		for raw_id in _known_players:
			if str(_known_players[raw_id]) == "host":
				count -= 1
				break
	return maxi(0, count)


func is_dedicated_server_session() -> bool:
	return _dedicated_server_session


func set_dedicated_server_session(enabled: bool) -> void:
	_dedicated_server_session = enabled


func is_community() -> bool:
	return _dedicated_server_session and _session_classification != "official"


func is_official_dedicated() -> bool:
	return _dedicated_server_session and _session_classification == "official"


func session_classification() -> String:
	return _session_classification


func set_session_classification(classification: String) -> void:
	_session_classification = classification


func max_players() -> int:
	return _session_max_players


func set_session_max_players(limit: int) -> void:
	_session_max_players = maxi(limit, 1)


func can_send_voice() -> bool:
	if is_guest():
		return transport_mode == "p2p" and _rtc_voice_channel_open(_guest_host_id)
	if is_host():
		for raw_peer_id in _rtc_voice_channels:
			if _rtc_voice_channel_open(str(raw_peer_id)):
				return true
	return false


func send_voice_frame(audio: PackedByteArray, sequence: int) -> bool:
	if not can_send_voice() or audio.is_empty() or audio.size() > VOICE_MAX_AUDIO_BYTES:
		return false
	var packet := encode_voice_packet(player_id, sequence, audio)
	if packet.is_empty():
		return false
	if is_guest():
		return _send_rtc_voice(_guest_host_id, packet)
	var sent := false
	for raw_peer_id in _rtc_voice_channels:
		var remote_id := str(raw_peer_id)
		if _rtc_voice_channel_open(remote_id):
			sent = _send_rtc_voice(remote_id, packet) or sent
	return sent


func connect_with_ticket(websocket_url: String, ticket: String, code: String = "", allow_websocket_fallback: bool = false, protocol_version: int = PROTOCOL_VERSION) -> Error:
	disconnect_from_session()
	last_websocket_close_code = -1
	last_websocket_close_was_clean = false
	last_rtc_silence_diagnostics.clear()
	_rtc_last_poll_msec = 0
	_rtc_last_poll_gap_msec = 0
	_rtc_last_ping_put_ok.clear()
	_rtc_diagnostic_trace.clear()
	_rtc_observed_state_signatures.clear()
	_rtc_diagnostic_candidate_counts.clear()
	_rtc_diagnostic_event_counts.clear()
	_rtc_offer_generation = 0
	_rtc_highest_offer_generations.clear()
	_rtc_highest_offer_connection_ids.clear()
	if websocket_url.is_empty() or ticket.is_empty():
		return ERR_INVALID_PARAMETER
	join_code = code
	session_protocol_version = protocol_version
	websocket_fallback_enabled = allow_websocket_fallback
	socket = WebSocketPeer.new()
	var separator := "&" if websocket_url.contains("?") else "?"
	var error := socket.connect_to_url("%s%sticket=%s" % [websocket_url, separator, ticket.uri_encode()])
	if error != OK:
		socket = null
	return error


func disconnect_from_session() -> void:
	if socket != null:
		if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
			socket.close(1000, "leaving")
		socket = null
	var had_session := not role.is_empty()
	_close_rtc("session_disconnect")
	role = ""
	player_id = ""
	session_id = ""
	join_code = ""
	session_protocol_version = PROTOCOL_VERSION
	_was_open = false
	_heartbeat_left = HEARTBEAT_SECONDS
	_known_players.clear()
	_dedicated_server_session = false
	_session_classification = ""
	_guest_host_id = ""
	_guest_connected_message.clear()
	_guest_connect_time_left = 0.0
	_connected_message_emitted = false
	_reset_rtc_reconnect_state()
	websocket_fallback_enabled = false
	_session_max_players = MAX_PLAYERS
	_set_transport_mode("websocket")
	if had_session:
		disconnected.emit("client_closed")


func send_command(type: String, payload: Dictionary = {}, sequence: int = 0) -> bool:
	var message := {"kind": "command", "type": type, "payload": payload, "seq": sequence}
	if is_guest() and _rtc_channel_open(_guest_host_id):
		return _send_rtc(_guest_host_id, message)
	if is_guest() and not websocket_fallback_enabled:
		return false
	return _send_ws(message)


func send_state(type: String, payload: Dictionary = {}, target_player_id: String = "", sequence: int = 0) -> bool:
	var message := {"kind": "state", "type": type, "payload": payload, "seq": sequence}
	if not target_player_id.is_empty():
		if is_host() and _rtc_channel_open(target_player_id):
			return _send_rtc(target_player_id, message)
		if is_host() and not websocket_fallback_enabled:
			return false
		message["target_player_id"] = target_player_id
		return _send_ws(message)
	if not is_host():
		return _send_ws(message)
	var guests: Array[String] = []
	for raw_id in _known_players:
		var remote_id := str(raw_id)
		if remote_id != player_id and str(_known_players[raw_id]) == "guest":
			guests.append(remote_id)
	if guests.is_empty():
		return true
	var sent := true
	for guest_id in guests:
		if _rtc_channel_open(guest_id):
			sent = _send_rtc(guest_id, message) and sent
		else:
			if not websocket_fallback_enabled:
				sent = false
				continue
			var fallback := message.duplicate(true)
			fallback["target_player_id"] = guest_id
			sent = _send_ws(fallback) and sent
	return sent


func _process(delta: float) -> void:
	_poll_websocket(delta)
	_poll_rtc(delta)


func _poll_websocket(delta: float) -> void:
	if socket == null:
		return
	socket.poll()
	var state := socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			_send_ws({
				"kind": "control",
				"type": "hello",
				"payload": {
					"protocol_version": session_protocol_version,
					"client_version": client_version(),
				},
			})
		_heartbeat_left -= delta
		if _heartbeat_left <= 0.0:
			_heartbeat_left = HEARTBEAT_SECONDS
			_send_ws({"kind": "control", "type": "heartbeat", "payload": {}})
		# Handlers may call disconnect_from_session() / _fail_p2p_connection()
		# and null `socket` mid-loop (e.g. session_closed → lobby teardown).
		while socket != null and socket.get_available_packet_count() > 0:
			_handle_ws_packet(socket.get_packet())
	elif state == WebSocketPeer.STATE_CLOSED:
		var reason := socket.get_close_reason()
		last_websocket_close_code = socket.get_close_code()
		last_websocket_close_was_clean = last_websocket_close_code != -1
		socket = null
		_close_rtc("websocket_closed")
		role = ""
		player_id = ""
		session_id = ""
		join_code = ""
		_known_players.clear()
		_guest_host_id = ""
		_guest_connected_message.clear()
		_guest_connect_time_left = 0.0
		_connected_message_emitted = false
		_reset_rtc_reconnect_state()
		websocket_fallback_enabled = false
		_set_transport_mode("websocket")
		_was_open = false
		disconnected.emit(reason if not reason.is_empty() else "connection_closed")
func _poll_rtc(delta: float) -> void:
	var now := Time.get_ticks_msec()
	_rtc_last_poll_gap_msec = now - _rtc_last_poll_msec if _rtc_last_poll_msec > 0 else 0
	_rtc_last_poll_msec = now
	var open_game_peers: Array[String] = []
	for raw_peer_id in _rtc_peers.keys():
		var remote_id := str(raw_peer_id)
		var peer: WebRTCPeerConnection = _rtc_peers[raw_peer_id]
		peer.poll()
		_rtc_diag_record_peer_state(remote_id, peer)
		var channel: WebRTCDataChannel = _rtc_channels.get(remote_id)
		if channel != null and channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			if not _rtc_ready_peers.has(remote_id):
				_rtc_ready_peers[remote_id] = true
				_rtc_last_seen_msec[remote_id] = now
				_rtc_silence_probe_deadline_msec.erase(remote_id)
				_rtc_silence_probe_diagnostics.erase(remote_id)
				print("Multiplayer P2P channel open: peer_key=%s" % remote_id.sha256_text().substr(0, 12))
				_rtc_diag_event("game_channel_open", remote_id)
				if is_guest() and remote_id == _guest_host_id:
					_reset_rtc_reconnect_state()
					_set_transport_mode("p2p")
					_emit_guest_connected_message()
			while channel.get_available_packet_count() > 0:
				_handle_rtc_packet(remote_id, channel.get_packet())
			if _rtc_channel_open(remote_id):
				open_game_peers.append(remote_id)
		elif _rtc_ready_peers.has(remote_id):
			_rtc_ready_peers.erase(remote_id)
			print("Multiplayer P2P channel closed: peer_key=%s" % remote_id.sha256_text().substr(0, 12))
			if is_guest() and remote_id == _guest_host_id:
				if websocket_fallback_enabled:
					_set_transport_mode("websocket")
				else:
					_schedule_rtc_reconnect("data_channel_closed")
		var voice_channel: WebRTCDataChannel = _rtc_voice_channels.get(remote_id)
		if voice_channel != null and voice_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			while voice_channel.get_available_packet_count() > 0:
				_handle_rtc_voice_packet(remote_id, voice_channel.get_packet())
	if is_guest() and not _connected_message_emitted and not _guest_connected_message.is_empty():
		_guest_connect_time_left -= delta
		if _guest_connect_time_left <= 0.0:
			if websocket_fallback_enabled:
				_set_transport_mode("websocket")
				_emit_guest_connected_message()
			else:
				_schedule_rtc_reconnect("initial_connect_timeout")
	if not open_game_peers.is_empty():
		_rtc_ping_left -= delta
		if _rtc_ping_left <= 0.0:
			_rtc_ping_left = RTC_PING_SECONDS
			for ping_peer_id in open_game_peers:
				var ping_put_ok := _send_rtc(ping_peer_id, {"kind": "control", "type": "p2p_ping", "payload": {"sent_msec": now}})
				_rtc_last_ping_put_ok[ping_peer_id] = ping_put_ok
				if ping_put_ok:
					_rtc_last_ping_sent_msec[ping_peer_id] = now
		for silent_peer_id in open_game_peers:
			var last_seen := int(_rtc_last_seen_msec.get(silent_peer_id, now))
			var probe_deadline := int(_rtc_silence_probe_deadline_msec.get(silent_peer_id, 0))
			match rtc_silence_probe_action(
				now,
				last_seen,
				probe_deadline,
				int(RTC_SILENCE_TIMEOUT_SECONDS * 1000.0),
			):
				"probe":
					var already_probed_this_frame: bool = (
						bool(_rtc_last_ping_put_ok.get(silent_peer_id, false))
						and int(_rtc_last_ping_sent_msec.get(silent_peer_id, 0)) == now
					)
					var probe_put_ok: bool = already_probed_this_frame
					if not probe_put_ok:
						probe_put_ok = _send_rtc(silent_peer_id, {"kind": "control", "type": "p2p_ping", "payload": {"sent_msec": now}})
						_rtc_last_ping_put_ok[silent_peer_id] = probe_put_ok
						if probe_put_ok:
							_rtc_last_ping_sent_msec[silent_peer_id] = now
					var probe_peer: WebRTCPeerConnection = _rtc_peers.get(silent_peer_id)
					var probe_channel: WebRTCDataChannel = _rtc_channels.get(silent_peer_id)
					_rtc_silence_probe_diagnostics[silent_peer_id] = {
						"poll_gap_ms": clampi(_rtc_last_poll_gap_msec, 0, 600000),
						"last_seen_age_ms": clampi(now - last_seen, 0, 600000),
						"last_ping_put_ok": probe_put_ok,
						"connection_state": probe_peer.get_connection_state() if probe_peer != null else -1,
						"game_channel_state": probe_channel.get_ready_state() if probe_channel != null else -1,
					}
					_rtc_silence_probe_deadline_msec[silent_peer_id] = now + int(RTC_PING_RESPONSE_GRACE_SECONDS * 1000.0)
					_rtc_diag_event("silence_probe", silent_peer_id, str(_rtc_connection_ids.get(silent_peer_id, "")), int(_rtc_offer_generations.get(silent_peer_id, -1)), {
						"rtc_send_ok": probe_put_ok,
						"last_seen_age_ms": clampi(now - last_seen, 0, 600000),
						"probe_grace_ms": int(RTC_PING_RESPONSE_GRACE_SECONDS * 1000.0),
					})
				"recover":
					_recover_silent_rtc_peer(silent_peer_id)
				"wait":
					pass
	_tick_rtc_reconnect(delta)


func _handle_ws_packet(packet: PackedByteArray) -> void:
	var parsed = JSON.parse_string(packet.get_string_from_utf8())
	if not parsed is Dictionary:
		return
	var message := parsed as Dictionary
	var kind := str(message.get("kind", ""))
	var type := str(message.get("type", ""))
	if kind == "control" and type == "connected":
		_handle_connected(message)
		return
	if kind == "control" and type == "player_joined":
		var joined_id := str(message.get("player_id", ""))
		if not joined_id.is_empty():
			_known_players[joined_id] = "guest"
	elif kind == "control" and type == "player_left":
		var left_id := str(message.get("player_id", ""))
		_known_players.erase(left_id)
		_rtc_future_candidate_buffers.erase(left_id)
		_close_rtc_peer(left_id, "player_left")
		_rtc_highest_offer_generations.erase(left_id)
		_rtc_highest_offer_connection_ids.erase(left_id)
	if type in ["rtc_offer", "rtc_answer", "rtc_candidate"]:
		_handle_rtc_signal(message)
		return
	message_received.emit(message)


func _handle_connected(message: Dictionary) -> void:
	role = str(message.get("role", ""))
	player_id = str(message.get("player_id", ""))
	session_id = str(message.get("session_id", ""))
	# Session metadata is normally established by the authenticated HTTP create/
	# join response. Older WebSocket gateways do not repeat these fields, so an
	# omitted value must not turn a 16-player dedicated session back into 4-player
	# P2P or make the headless host visible again.
	if message.has("dedicated_server"):
		_dedicated_server_session = bool(message.get("dedicated_server", false))
	if message.has("classification"):
		_session_classification = str(message.get("classification", ""))
	if message.has("max_players"):
		set_session_max_players(int(message.get("max_players", MAX_PLAYERS)))
	_known_players.clear()
	var players: Array = message.get("players", []) if message.get("players", []) is Array else []
	for raw_player in players:
		if raw_player is Dictionary:
			var entry := raw_player as Dictionary
			_known_players[str(entry.get("player_id", ""))] = str(entry.get("role", ""))
	connected.emit(role, player_id, session_id)
	if role == "guest":
		_guest_connected_message = message.duplicate(true)
		_guest_connect_time_left = RTC_CONNECT_TIMEOUT_SECONDS
		for raw_id in _known_players:
			if str(_known_players[raw_id]) == "host":
				_guest_host_id = str(raw_id)
				break
		if _guest_host_id.is_empty() or not _create_rtc_peer(_guest_host_id):
			if websocket_fallback_enabled:
				_emit_guest_connected_message()
			else:
				_fail_p2p_connection()
		else:
			var peer: WebRTCPeerConnection = _rtc_peers[_guest_host_id]
			if peer.create_offer() != OK:
				if websocket_fallback_enabled:
					_emit_guest_connected_message()
				else:
					_fail_p2p_connection()
	else:
		_connected_message_emitted = true
		message_received.emit(message)


func _emit_guest_connected_message() -> void:
	if _connected_message_emitted or _guest_connected_message.is_empty():
		return
	_connected_message_emitted = true
	message_received.emit(_guest_connected_message)


func _schedule_rtc_reconnect(reason: String = "retry_timeout") -> void:
	if not is_guest() or websocket_fallback_enabled:
		return
	if _rtc_reconnecting:
		return
	_close_rtc_peer(_guest_host_id, "guest_reconnect")
	_rtc_reconnect_attempt += 1
	if _rtc_reconnect_attempt > RTC_MAX_RECONNECT_ATTEMPTS:
		_fail_p2p_connection()
		return
	_rtc_reconnecting = true
	_rtc_reconnect_connect_left = 0.0
	_rtc_reconnect_left = rtc_reconnect_delay(_rtc_reconnect_attempt)
	_set_transport_mode("reconnecting")
	print("Multiplayer P2P reconnect scheduled: attempt %d, reason=%s" % [_rtc_reconnect_attempt, reason])


static func rtc_silence_recovery_mode(guest_connection: bool, fallback_enabled: bool) -> String:
	if not guest_connection:
		return RTC_SILENCE_RECOVERY_DROP_PEER
	if fallback_enabled:
		return RTC_SILENCE_RECOVERY_WEBSOCKET
	return RTC_SILENCE_RECOVERY_RECONNECT


static func rtc_silence_probe_action(now_msec: int, last_seen_msec: int, probe_deadline_msec: int, timeout_msec: int = 7000) -> String:
	if maxi(0, now_msec - last_seen_msec) < maxi(0, timeout_msec):
		return "none"
	if probe_deadline_msec <= 0:
		return "probe"
	return "recover" if now_msec >= probe_deadline_msec else "wait"


static func managed_rtc_offer_decision(
	incoming_generation: Variant,
	incoming_connection_id: String,
	highest_generation: int,
	highest_connection_id: String,
	current_peer_exists: bool,
) -> String:
	var generation := _managed_rtc_offer_generation_value(incoming_generation)
	if generation <= 0 or incoming_connection_id.is_empty():
		return "invalid"
	if generation > highest_generation:
		return "accept"
	if generation < highest_generation:
		return "stale"
	if incoming_connection_id != highest_connection_id:
		return "stale"
	return "duplicate" if current_peer_exists else "stale"


static func managed_rtc_offer_generation_matches(protocol_version: int, incoming_generation: Variant, current_generation: int) -> bool:
	if protocol_version != MANAGED_PROTOCOL_VERSION:
		return true
	return current_generation > 0 and _managed_rtc_offer_generation_value(incoming_generation) == current_generation


static func _managed_rtc_generation_rejection_reason(protocol_version: int, incoming_generation: Variant, current_generation: int) -> String:
	if protocol_version != MANAGED_PROTOCOL_VERSION:
		return "accepted"
	var generation := _managed_rtc_offer_generation_value(incoming_generation)
	if generation <= 0:
		return "invalid_generation"
	return "accepted" if current_generation > 0 and generation == current_generation else "generation_mismatch"


static func managed_rtc_future_candidate_decision(
	protocol_version: int,
	incoming_generation: Variant,
	incoming_connection_id: String,
	highest_generation: int,
	has_generation_slot: bool,
	slot_connection_id: String,
	buffered_generation_count: int,
	buffered_candidate_count: int,
	buffered_bytes: int,
	candidate_bytes: int,
) -> String:
	if protocol_version != MANAGED_PROTOCOL_VERSION:
		return "legacy_unsupported"
	var generation := _managed_rtc_offer_generation_value(incoming_generation)
	if generation <= 0:
		return "invalid_generation"
	if incoming_connection_id.is_empty() or incoming_connection_id.length() > RTC_MAX_CONNECTION_ID_LENGTH:
		return "invalid_connection_id"
	if generation <= highest_generation:
		return "stale_generation"
	if generation - highest_generation > RTC_MAX_FUTURE_OFFER_GENERATION_GAP:
		return "future_generation_too_far"
	if has_generation_slot and incoming_connection_id != slot_connection_id:
		return "same_generation_connection_mismatch"
	if not has_generation_slot and buffered_generation_count >= RTC_MAX_FUTURE_OFFER_GENERATIONS_PER_PEER:
		return "future_generation_capacity"
	if buffered_candidate_count >= RTC_MAX_FUTURE_CANDIDATES_PER_PEER or candidate_bytes < 0 or buffered_bytes + candidate_bytes > RTC_MAX_FUTURE_CANDIDATE_BYTES_PER_PEER:
		return "future_candidate_capacity"
	return "buffer"


static func _managed_rtc_candidate_payload(payload: Dictionary) -> Dictionary:
	var media_value: Variant = payload.get("media", "")
	var index_value: Variant = payload.get("index", null)
	var name_value: Variant = payload.get("name", "")
	if typeof(media_value) != TYPE_STRING or typeof(name_value) != TYPE_STRING:
		return {"ok": false, "reason": "invalid_candidate"}
	var media := str(media_value)
	var candidate_name := str(name_value)
	if media.is_empty() or media.to_utf8_buffer().size() > RTC_MAX_CANDIDATE_MEDIA_LENGTH:
		return {"ok": false, "reason": "invalid_candidate"}
	if candidate_name.is_empty() or candidate_name.to_utf8_buffer().size() > RTC_MAX_CANDIDATE_TEXT_LENGTH:
		return {"ok": false, "reason": "invalid_candidate"}
	var candidate_index := -1
	if typeof(index_value) == TYPE_INT:
		candidate_index = int(index_value)
	elif typeof(index_value) == TYPE_FLOAT:
		var numeric_index := float(index_value)
		if is_finite(numeric_index) and floorf(numeric_index) == numeric_index and numeric_index >= 0.0 and numeric_index <= 65535.0:
			candidate_index = int(numeric_index)
	if candidate_index < 0 or candidate_index > 65535:
		return {"ok": false, "reason": "invalid_candidate"}
	return {
		"ok": true,
		"candidate": {"media": media, "index": candidate_index, "name": candidate_name},
	}


func _managed_rtc_offer_rejection_reason(
	incoming_generation: Variant,
	incoming_connection_id: String,
	highest_generation: int,
	highest_connection_id: String,
	current_peer_exists: bool,
) -> String:
	var generation := _managed_rtc_offer_generation_value(incoming_generation)
	if generation <= 0:
		return "invalid_generation"
	if incoming_connection_id.is_empty():
		return "missing_connection_id"
	if generation < highest_generation:
		return "older_generation"
	if generation == highest_generation:
		if incoming_connection_id != highest_connection_id:
			return "same_generation_connection_mismatch"
		return "duplicate_current_offer" if current_peer_exists else "retired_generation"
	return "unclassified_rejection"


static func _managed_rtc_offer_generation_value(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		var integer_value := int(value)
		return integer_value if integer_value > 0 and integer_value <= RTC_MAX_OFFER_GENERATION else -1
	if typeof(value) != TYPE_FLOAT:
		return -1
	var numeric := float(value)
	if not is_finite(numeric) or floorf(numeric) != numeric or numeric <= 0.0 or numeric > float(RTC_MAX_OFFER_GENERATION):
		return -1
	return int(numeric)


func _rtc_diag_event(
	event: String,
	remote_id: String,
	connection_id: String = "",
	offer_generation: int = -1,
	extra: Dictionary = {},
) -> void:
	if not rtc_diagnostics_enabled:
		return
	var event_key := remote_id if not remote_id.is_empty() else "session"
	if not _rtc_diagnostic_event_counts.has(event_key) and _rtc_diagnostic_event_counts.size() >= maxi(1, _session_max_players):
		return
	var event_count := int(_rtc_diagnostic_event_counts.get(event_key, 0))
	if event_count >= 24:
		return
	_rtc_diagnostic_event_counts[event_key] = event_count + 1
	var entry := {
		"at_utc_ms": int(Time.get_unix_time_from_system() * 1000.0),
		"tick_ms": Time.get_ticks_msec(),
		"poll_gap_ms": clampi(_rtc_last_poll_gap_msec, 0, 600000),
		"event": event,
		"role": role if role in ["host", "guest"] else "other",
	}
	if not remote_id.is_empty():
		entry["peer_key"] = remote_id.sha256_text().substr(0, 12)
	if not connection_id.is_empty():
		entry["connection_key"] = connection_id.sha256_text().substr(0, 12)
	if offer_generation >= 0:
		entry["offer_generation"] = offer_generation
	var peer: WebRTCPeerConnection = _rtc_peers.get(remote_id)
	if peer != null:
		entry["connection_state"] = peer.get_connection_state()
		entry["gathering_state"] = peer.get_gathering_state()
		entry["signaling_state"] = peer.get_signaling_state()
	entry["remote_description_set"] = bool(_rtc_remote_description_set.get(remote_id, false))
	var channel: WebRTCDataChannel = _rtc_channels.get(remote_id)
	entry["game_channel_state"] = channel.get_ready_state() if channel != null else -1
	var pending: Variant = _rtc_pending_candidates.get(remote_id, [])
	entry["pending_candidates"] = pending.size() if pending is Array else 0
	if socket != null:
		entry["websocket_state"] = socket.get_ready_state()
		entry["websocket_outbound_bytes"] = clampi(socket.get_current_outbound_buffered_amount(), 0, 10000000)
	for key in extra:
		if key in [
			"signal_type", "decision", "reason", "description_type", "result_code", "candidate_type",
			"candidate_index", "candidate_count", "candidate_action", "websocket_send_ok", "websocket_outbound_before_bytes",
			"websocket_outbound_after_bytes", "websocket_send_result", "send_error", "incoming_generation", "highest_generation",
			"rtc_send_ok", "last_seen_age_ms", "probe_grace_ms", "close_reason",
		]:
			entry[key] = extra[key]
	_rtc_diagnostic_trace.append(entry)
	if _rtc_diagnostic_trace.size() > RTC_DIAGNOSTIC_TRACE_LIMIT:
		_rtc_diagnostic_trace.pop_front()
	print("Managed RTC diagnostic: " + JSON.stringify(entry))


func rtc_diagnostic_trace() -> Array[Dictionary]:
	return _rtc_diagnostic_trace.duplicate(true)


func _rtc_diag_record_peer_state(remote_id: String, peer: WebRTCPeerConnection) -> void:
	if not rtc_diagnostics_enabled or peer == null:
		return
	var channel: WebRTCDataChannel = _rtc_channels.get(remote_id)
	var signature := "%d:%d:%d:%d" % [
		peer.get_connection_state(),
		peer.get_gathering_state(),
		peer.get_signaling_state(),
		channel.get_ready_state() if channel != null else -1,
	]
	if str(_rtc_observed_state_signatures.get(remote_id, "")) == signature:
		return
	_rtc_observed_state_signatures[remote_id] = signature
	_rtc_diag_event("peer_state_change", remote_id, str(_rtc_connection_ids.get(remote_id, "")), int(_rtc_offer_generations.get(remote_id, -1)))


func _rtc_diag_candidate_type(candidate: String) -> String:
	var lower_candidate := candidate.to_lower()
	for candidate_type in ["host", "srflx", "prflx", "relay"]:
		if lower_candidate.contains(" typ %s " % candidate_type):
			return candidate_type
	return "other"


func _rtc_diag_can_record_candidate(remote_id: String, direction: String) -> bool:
	if not rtc_diagnostics_enabled:
		return false
	var key := "%s:%s" % [remote_id, direction]
	var count := int(_rtc_diagnostic_candidate_counts.get(key, 0))
	if count >= RTC_DIAGNOSTIC_CANDIDATES_PER_PEER:
		return false
	_rtc_diagnostic_candidate_counts[key] = count + 1
	return true


func _recover_silent_rtc_peer(remote_id: String) -> void:
	var guest_connection := is_guest() and remote_id == _guest_host_id
	var recovery_mode := rtc_silence_recovery_mode(guest_connection, websocket_fallback_enabled)
	var now := Time.get_ticks_msec()
	var last_seen := int(_rtc_last_seen_msec.get(remote_id, now))
	var peer: WebRTCPeerConnection = _rtc_peers.get(remote_id)
	var channel: WebRTCDataChannel = _rtc_channels.get(remote_id)
	var probe_metrics: Dictionary = _rtc_silence_probe_diagnostics.get(remote_id, {})
	last_rtc_silence_diagnostics = {
		"poll_gap_ms": clampi(int(probe_metrics.get("poll_gap_ms", _rtc_last_poll_gap_msec)), 0, 600000),
		"last_seen_age_ms": clampi(int(probe_metrics.get("last_seen_age_ms", now - last_seen)), 0, 600000),
		"last_ping_age_ms": clampi(now - int(_rtc_last_ping_sent_msec.get(remote_id, now)), 0, 600000),
		"probe_remaining_ms": maxi(0, int(_rtc_silence_probe_deadline_msec.get(remote_id, now)) - now),
		"last_ping_put_ok": probe_metrics.get("last_ping_put_ok", _rtc_last_ping_put_ok.get(remote_id, false)) == true,
		"connection_state": int(probe_metrics.get("connection_state", peer.get_connection_state() if peer != null else -1)),
		"game_channel_state": int(probe_metrics.get("game_channel_state", channel.get_ready_state() if channel != null else -1)),
	}
	if rtc_diagnostics_enabled:
		print("Multiplayer P2P channel silent: peer_key=%s, recovery=%s" % [remote_id.sha256_text().substr(0, 12), recovery_mode])
		print("Multiplayer P2P silence diagnostics: poll_gap_ms=%d last_seen_age_ms=%d last_ping_age_ms=%d probe_remaining_ms=%d last_ping_put_ok=%s connection_state=%d game_channel_state=%d" % [
			last_rtc_silence_diagnostics["poll_gap_ms"],
			last_rtc_silence_diagnostics["last_seen_age_ms"],
			last_rtc_silence_diagnostics["last_ping_age_ms"],
			last_rtc_silence_diagnostics["probe_remaining_ms"],
			str(last_rtc_silence_diagnostics["last_ping_put_ok"]).to_lower(),
			last_rtc_silence_diagnostics["connection_state"],
			last_rtc_silence_diagnostics["game_channel_state"],
		])
	_close_rtc_peer(remote_id, "silent_timeout")
	match recovery_mode:
		RTC_SILENCE_RECOVERY_WEBSOCKET:
			_reset_rtc_reconnect_state()
			_set_transport_mode("websocket")
		RTC_SILENCE_RECOVERY_RECONNECT:
			_schedule_rtc_reconnect("game_channel_silent")


func _tick_rtc_reconnect(delta: float) -> void:
	if not _rtc_reconnecting:
		return
	if _rtc_reconnect_left >= 0.0:
		_rtc_reconnect_left -= delta
		if _rtc_reconnect_left <= 0.0:
			_rtc_reconnect_left = -1.0
			_start_rtc_reconnect()
		return
	if _rtc_reconnect_connect_left > 0.0:
		_rtc_reconnect_connect_left -= delta
		if _rtc_reconnect_connect_left <= 0.0:
			_rtc_reconnecting = false
			_schedule_rtc_reconnect("offer_timeout")


func _start_rtc_reconnect() -> void:
	if not is_guest() or _guest_host_id.is_empty():
		_fail_p2p_connection()
		return
	if not _create_rtc_peer(_guest_host_id):
		_rtc_reconnecting = false
		_schedule_rtc_reconnect("peer_creation_failed")
		return
	var peer: WebRTCPeerConnection = _rtc_peers.get(_guest_host_id)
	if peer == null or peer.create_offer() != OK:
		_close_rtc_peer(_guest_host_id, "offer_creation_failed")
		_rtc_reconnecting = false
		_schedule_rtc_reconnect("offer_creation_failed")
		return
	_rtc_reconnect_connect_left = RTC_RECONNECT_TIMEOUT_SECONDS


func _reset_rtc_reconnect_state() -> void:
	_rtc_ping_left = RTC_PING_SECONDS
	_rtc_reconnect_attempt = 0
	_rtc_reconnect_left = -1.0
	_rtc_reconnect_connect_left = 0.0
	_rtc_reconnecting = false


static func rtc_reconnect_delay(attempt: int) -> float:
	return minf(8.0, 0.5 * pow(2.0, maxi(0, attempt - 1)))


func _fail_p2p_connection() -> void:
	if socket == null:
		return
	print("Multiplayer P2P connection failed; WebSocket fallback is disabled")
	var active_socket := socket
	socket = null
	if active_socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		last_websocket_close_code = 4000
		last_websocket_close_was_clean = false
		active_socket.close(4000, "p2p_unavailable")
	_close_rtc("p2p_failed")
	role = ""
	player_id = ""
	session_id = ""
	join_code = ""
	_known_players.clear()
	_dedicated_server_session = false
	_session_classification = ""
	_guest_host_id = ""
	_guest_connected_message.clear()
	_guest_connect_time_left = 0.0
	_connected_message_emitted = false
	_reset_rtc_reconnect_state()
	websocket_fallback_enabled = false
	_set_transport_mode("websocket")
	_was_open = false
	disconnected.emit("p2p_unavailable")


func _create_rtc_peer(remote_id: String, connection_id: String = "", offer_generation: int = -1) -> bool:
	if remote_id.is_empty():
		return false
	if _rtc_peers.has(remote_id):
		return true
	if connection_id.is_empty():
		connection_id = Crypto.new().generate_random_bytes(8).hex_encode()
	if offer_generation < 0:
		if role == "guest" and session_protocol_version == MANAGED_PROTOCOL_VERSION:
			if _rtc_offer_generation >= RTC_MAX_OFFER_GENERATION:
				return false
			_rtc_offer_generation += 1
			offer_generation = _rtc_offer_generation
		else:
			offer_generation = 0
	if offer_generation < 0 or offer_generation > RTC_MAX_OFFER_GENERATION:
		_rtc_diag_event("peer_create_rejected", remote_id, connection_id, offer_generation, {"reason": "invalid_generation"})
		return false
	var peer := WebRTCPeerConnection.new()
	var initialize_result := peer.initialize(RTC_CONFIGURATION)
	if initialize_result != OK:
		_rtc_diag_event("peer_create_failed", remote_id, connection_id, offer_generation, {"reason": "initialize", "result_code": initialize_result})
		return false
	var channel := peer.create_data_channel("tinyblock", {"negotiated": true, "id": RTC_CHANNEL_ID, "ordered": true})
	if channel == null:
		_rtc_diag_event("peer_create_failed", remote_id, connection_id, offer_generation, {"reason": "game_channel"})
		peer.close()
		return false
	var voice_channel := peer.create_data_channel("tinyblock-voice", {
		"negotiated": true,
		"id": RTC_VOICE_CHANNEL_ID,
		"ordered": false,
		"maxRetransmits": 0,
	})
	if voice_channel == null:
		_rtc_diag_event("peer_create_failed", remote_id, connection_id, offer_generation, {"reason": "voice_channel"})
		channel.close()
		peer.close()
		return false
	var peer_instance_id := peer.get_instance_id()
	peer.session_description_created.connect(_on_rtc_session_created.bind(remote_id, peer_instance_id, connection_id, offer_generation))
	peer.ice_candidate_created.connect(_on_rtc_ice_candidate.bind(remote_id, peer_instance_id, connection_id, offer_generation))
	_rtc_peers[remote_id] = peer
	_rtc_channels[remote_id] = channel
	_rtc_voice_channels[remote_id] = voice_channel
	_rtc_remote_description_set[remote_id] = false
	_rtc_pending_candidates[remote_id] = []
	_rtc_connection_ids[remote_id] = connection_id
	_rtc_offer_generations[remote_id] = offer_generation
	_rtc_diag_event("peer_created", remote_id, connection_id, offer_generation)
	return true


func _rtc_callback_is_current(remote_id: String, origin_peer_instance_id: int, connection_id: String, offer_generation: int) -> bool:
	var current_peer: WebRTCPeerConnection = _rtc_peers.get(remote_id)
	return (
		current_peer != null
		and current_peer.get_instance_id() == origin_peer_instance_id
		and str(_rtc_connection_ids.get(remote_id, "")) == connection_id
		and int(_rtc_offer_generations.get(remote_id, -1)) == offer_generation
	)


func _rtc_peer_is_current(remote_id: String, expected_peer: WebRTCPeerConnection, connection_id: String, offer_generation: int) -> bool:
	return (
		expected_peer != null
		and _rtc_peers.get(remote_id) == expected_peer
		and str(_rtc_connection_ids.get(remote_id, "")) == connection_id
		and int(_rtc_offer_generations.get(remote_id, -1)) == offer_generation
	)


func _rtc_signal_payload(remote_id: String, fields: Dictionary) -> Dictionary:
	var payload := fields.duplicate(true)
	payload["connection_id"] = str(_rtc_connection_ids.get(remote_id, ""))
	var offer_generation := int(_rtc_offer_generations.get(remote_id, 0))
	if session_protocol_version == MANAGED_PROTOCOL_VERSION and offer_generation > 0:
		payload["offer_generation"] = offer_generation
	return payload


func _on_rtc_session_created(
	type: String,
	sdp: String,
	remote_id: String,
	origin_peer_instance_id: int,
	connection_id: String,
	offer_generation: int,
) -> void:
	if not _rtc_callback_is_current(remote_id, origin_peer_instance_id, connection_id, offer_generation):
		_rtc_diag_event("stale_sdp_callback_dropped", remote_id, connection_id, offer_generation, {"description_type": type})
		return
	var peer: WebRTCPeerConnection = _rtc_peers.get(remote_id)
	if peer == null:
		return
	var local_description_result := peer.set_local_description(type, sdp)
	_rtc_diag_event("local_sdp_result", remote_id, connection_id, offer_generation, {"description_type": type, "result_code": local_description_result})
	if local_description_result != OK:
		return
	if role == "guest" and type == "offer":
		var outbound_before := _rtc_websocket_buffered_bytes()
		var offer_send_result := _send_ws_result({"kind": "command", "type": "rtc_offer", "payload": _rtc_signal_payload(remote_id, {"sdp": sdp}), "seq": 0})
		_rtc_diag_event("rtc_signal_sent", remote_id, connection_id, offer_generation, {
			"signal_type": "rtc_offer",
			"websocket_send_ok": offer_send_result == OK,
			"websocket_send_result": offer_send_result,
			"websocket_outbound_before_bytes": outbound_before,
			"websocket_outbound_after_bytes": _rtc_websocket_buffered_bytes(),
		})
	elif role == "host" and type == "answer":
		var outbound_before := _rtc_websocket_buffered_bytes()
		var answer_send_result := _send_ws_result({
			"kind": "state",
			"type": "rtc_answer",
			"payload": _rtc_signal_payload(remote_id, {"sdp": sdp}),
			"target_player_id": remote_id,
			"seq": 0,
		})
		_rtc_diag_event("rtc_signal_sent", remote_id, connection_id, offer_generation, {
			"signal_type": "rtc_answer",
			"websocket_send_ok": answer_send_result == OK,
			"websocket_send_result": answer_send_result,
			"websocket_outbound_before_bytes": outbound_before,
			"websocket_outbound_after_bytes": _rtc_websocket_buffered_bytes(),
		})


func _on_rtc_ice_candidate(
	media: String,
	index: int,
	name: String,
	remote_id: String,
	origin_peer_instance_id: int,
	connection_id: String,
	offer_generation: int,
) -> void:
	if not _rtc_callback_is_current(remote_id, origin_peer_instance_id, connection_id, offer_generation):
		_rtc_diag_event("stale_ice_callback_dropped", remote_id, connection_id, offer_generation, {"candidate_type": _rtc_diag_candidate_type(name)})
		return
	var payload := _rtc_signal_payload(remote_id, {"media": media, "index": index, "name": name})
	var record_candidate := _rtc_diag_can_record_candidate(remote_id, "local")
	var candidate_type := _rtc_diag_candidate_type(name)
	var outbound_before := _rtc_websocket_buffered_bytes()
	var send_result := ERR_UNAVAILABLE
	if role == "guest":
		send_result = _send_ws_result({"kind": "command", "type": "rtc_candidate", "payload": payload, "seq": 0})
	elif role == "host":
		send_result = _send_ws_result({
			"kind": "state",
			"type": "rtc_candidate",
			"payload": payload,
			"target_player_id": remote_id,
			"seq": 0,
		})
	if record_candidate:
		_rtc_diag_event("rtc_signal_sent", remote_id, connection_id, offer_generation, {
			"signal_type": "rtc_candidate",
			"candidate_type": candidate_type,
			"candidate_index": index,
			"websocket_send_ok": send_result == OK,
			"websocket_send_result": send_result,
			"websocket_outbound_before_bytes": outbound_before,
			"websocket_outbound_after_bytes": _rtc_websocket_buffered_bytes(),
		})


func _handle_rtc_signal(message: Dictionary) -> void:
	var type := str(message.get("type", ""))
	var remote_id := str(message.get("sender_player_id", ""))
	if role == "guest":
		remote_id = _guest_host_id
	if remote_id.is_empty():
		return
	var payload: Dictionary = message.get("payload", {}) if message.get("payload", {}) is Dictionary else {}
	var connection_id := str(payload.get("connection_id", ""))
	var incoming_generation := _managed_rtc_offer_generation_value(payload.get("offer_generation", null))
	_rtc_diag_event("rtc_signal_received", remote_id, connection_id, incoming_generation, {
		"signal_type": type,
		"incoming_generation": incoming_generation,
	})
	if type == "rtc_offer":
		if role != "host" or connection_id.is_empty():
			_rtc_diag_event("rtc_offer_rejected", remote_id, connection_id, incoming_generation, {"reason": "wrong_role" if role != "host" else "missing_connection_id"})
			return
		var offer_generation := 0
		if session_protocol_version == MANAGED_PROTOCOL_VERSION:
			if not _rtc_highest_offer_generations.has(remote_id) and _rtc_highest_offer_generations.size() >= _session_max_players:
				_rtc_diag_event("rtc_offer_rejected", remote_id, connection_id, incoming_generation, {"reason": "participant_capacity"})
				return
			var offer_action := managed_rtc_offer_decision(
				payload.get("offer_generation", null),
				connection_id,
				int(_rtc_highest_offer_generations.get(remote_id, 0)),
				str(_rtc_highest_offer_connection_ids.get(remote_id, "")),
				_rtc_peers.has(remote_id),
			)
			if offer_action != "accept":
				_rtc_diag_event("rtc_offer_rejected", remote_id, connection_id, incoming_generation, {
					"decision": offer_action,
					"reason": _managed_rtc_offer_rejection_reason(
						payload.get("offer_generation", null),
						connection_id,
						int(_rtc_highest_offer_generations.get(remote_id, 0)),
						str(_rtc_highest_offer_connection_ids.get(remote_id, "")),
						_rtc_peers.has(remote_id),
					),
				})
				return
			offer_generation = _managed_rtc_offer_generation_value(payload.get("offer_generation", null))
		if _rtc_peers.has(remote_id) and (
			str(_rtc_connection_ids.get(remote_id, "")) != connection_id
			or int(_rtc_offer_generations.get(remote_id, 0)) != offer_generation
		):
			_rtc_diag_event("rtc_peer_replaced", remote_id, str(_rtc_connection_ids.get(remote_id, "")), int(_rtc_offer_generations.get(remote_id, -1)), {
				"reason": "newer_offer",
				"incoming_generation": incoming_generation,
			})
			_close_rtc_peer(remote_id, "newer_offer")
		if not _create_rtc_peer(remote_id, connection_id, offer_generation):
			_rtc_diag_event("rtc_offer_rejected", remote_id, connection_id, incoming_generation, {"reason": "peer_create_failed"})
			return
		if session_protocol_version == MANAGED_PROTOCOL_VERSION:
			# Record the generation only after peer creation succeeds. If native
			# initialization fails, the same offer can be retried; once accepted,
			# the high-water mark survives later peer recovery.
			_rtc_highest_offer_generations[remote_id] = offer_generation
			_rtc_highest_offer_connection_ids[remote_id] = connection_id
		_rtc_diag_event("rtc_offer_accepted", remote_id, connection_id, offer_generation, {"decision": "accept"})
		_set_rtc_remote_description(remote_id, "offer", str(payload.get("sdp", "")))
	elif type == "rtc_answer":
		var answer_rejection_reason := "accepted"
		if role != "guest":
			answer_rejection_reason = "wrong_role"
		else:
			answer_rejection_reason = _managed_rtc_generation_rejection_reason(
				session_protocol_version,
				payload.get("offer_generation", null),
				int(_rtc_offer_generations.get(remote_id, 0)),
			)
			if answer_rejection_reason == "accepted" and connection_id.is_empty():
				answer_rejection_reason = "missing_connection_id"
			elif answer_rejection_reason == "accepted" and connection_id != str(_rtc_connection_ids.get(remote_id, "")):
				answer_rejection_reason = "connection_id_mismatch"
		var answer_matches := answer_rejection_reason == "accepted"
		_rtc_diag_event("rtc_answer_result", remote_id, connection_id, incoming_generation, {
			"decision": "accept" if answer_matches else "reject",
			"reason": answer_rejection_reason,
		})
		if answer_matches:
			_set_rtc_remote_description(remote_id, "answer", str(payload.get("sdp", "")))
	elif type == "rtc_candidate":
		var candidate_rejection_reason := _managed_rtc_generation_rejection_reason(
			session_protocol_version,
			payload.get("offer_generation", null),
			int(_rtc_offer_generations.get(remote_id, 0)),
		)
		var candidate: Dictionary = {}
		if session_protocol_version == MANAGED_PROTOCOL_VERSION:
			var candidate_payload := _managed_rtc_candidate_payload(payload)
			if not bool(candidate_payload.get("ok", false)):
				_rtc_diag_event("rtc_candidate_rejected", remote_id, connection_id, incoming_generation, {"reason": str(candidate_payload.get("reason", "invalid_candidate"))})
				return
			candidate = candidate_payload.get("candidate", {})
		else:
			candidate = {
				"media": str(payload.get("media", "")),
				"index": int(payload.get("index", 0)),
				"name": str(payload.get("name", "")),
			}
		if candidate_rejection_reason == "accepted" and connection_id.is_empty():
			candidate_rejection_reason = "missing_connection_id"
		elif candidate_rejection_reason == "accepted" and connection_id != str(_rtc_connection_ids.get(remote_id, "")):
			candidate_rejection_reason = "connection_id_mismatch"
		var current_generation := int(_rtc_offer_generations.get(remote_id, 0))
		if role == "host" and session_protocol_version == MANAGED_PROTOCOL_VERSION and incoming_generation > current_generation:
			var queue_result := _queue_future_rtc_candidate(remote_id, connection_id, incoming_generation, candidate)
			if queue_result in ["buffer", "duplicate"]:
				_rtc_diag_event("future_candidate_buffered", remote_id, connection_id, incoming_generation, {
					"decision": "accept" if queue_result == "buffer" else "duplicate",
					"candidate_type": _rtc_diag_candidate_type(str(candidate.get("name", ""))),
					"candidate_index": int(candidate.get("index", 0)),
				})
				return
			_rtc_diag_event("rtc_candidate_rejected", remote_id, connection_id, incoming_generation, {"reason": queue_result})
			return
		if candidate_rejection_reason != "accepted":
			_rtc_diag_event("rtc_candidate_rejected", remote_id, connection_id, incoming_generation, {"reason": candidate_rejection_reason})
			return
		if not _rtc_peers.has(remote_id) or not bool(_rtc_remote_description_set.get(remote_id, false)):
			if not _rtc_pending_candidates.has(remote_id):
				_rtc_pending_candidates[remote_id] = []
			var pending_candidates: Array = _rtc_pending_candidates[remote_id]
			if session_protocol_version == MANAGED_PROTOCOL_VERSION:
				var pending_bytes := 0
				for raw_candidate in pending_candidates:
					if raw_candidate is Dictionary:
						pending_bytes += _rtc_candidate_byte_size(raw_candidate as Dictionary)
				if pending_candidates.size() >= RTC_MAX_FUTURE_CANDIDATES_PER_PEER or pending_bytes + _rtc_candidate_byte_size(candidate) > RTC_MAX_FUTURE_CANDIDATE_BYTES_PER_PEER:
					_rtc_diag_event("rtc_candidate_rejected", remote_id, connection_id, incoming_generation, {"reason": "pending_candidate_capacity"})
					return
			pending_candidates.append(candidate)
			_rtc_pending_candidates[remote_id] = pending_candidates
			if _rtc_diag_can_record_candidate(remote_id, "remote"):
				_rtc_diag_event("remote_candidate_queued", remote_id, connection_id, incoming_generation, {
					"candidate_type": _rtc_diag_candidate_type(str(candidate.get("name", ""))),
					"candidate_index": int(candidate.get("index", 0)),
					"candidate_action": "queued",
				})
		else:
			_add_rtc_candidate(remote_id, candidate)


func _set_rtc_remote_description(remote_id: String, type: String, sdp: String) -> void:
	var peer: WebRTCPeerConnection = _rtc_peers.get(remote_id)
	var connection_id := str(_rtc_connection_ids.get(remote_id, ""))
	var offer_generation := int(_rtc_offer_generations.get(remote_id, -1))
	var result_code := ERR_DOES_NOT_EXIST
	var reason := "peer_missing"
	if peer != null:
		if sdp.is_empty():
			reason = "sdp_empty"
		else:
			result_code = peer.set_remote_description(type, sdp)
			reason = "accepted" if result_code == OK else "set_remote_failed"
	_rtc_diag_event("remote_sdp_result", remote_id, str(_rtc_connection_ids.get(remote_id, "")), int(_rtc_offer_generations.get(remote_id, -1)), {
		"description_type": type,
		"result_code": result_code,
		"decision": "accept" if peer != null and not sdp.is_empty() and result_code == OK else "reject",
		"reason": reason,
	})
	if peer == null or sdp.is_empty() or result_code != OK:
		return
	if not _rtc_peer_is_current(remote_id, peer, connection_id, offer_generation):
		return
	_rtc_remote_description_set[remote_id] = true
	var pending: Array = _rtc_pending_candidates.get(remote_id, []) if _rtc_pending_candidates.get(remote_id, []) is Array else []
	_rtc_pending_candidates[remote_id] = []
	if role == "host" and session_protocol_version == MANAGED_PROTOCOL_VERSION and type == "offer":
		pending.append_array(_flush_future_rtc_candidates(remote_id, connection_id, offer_generation, peer))
	for raw_candidate in pending:
		if not _rtc_peer_is_current(remote_id, peer, connection_id, offer_generation):
			break
		if raw_candidate is Dictionary:
			_add_rtc_candidate(remote_id, raw_candidate as Dictionary, peer, connection_id, offer_generation)


func _queue_future_rtc_candidate(remote_id: String, connection_id: String, generation: int, candidate: Dictionary) -> String:
	var slots: Array = _rtc_future_candidate_buffers.get(remote_id, []) if _rtc_future_candidate_buffers.get(remote_id, []) is Array else []
	var slot_index := -1
	var slot_connection_id := ""
	var buffered_candidate_count := 0
	var buffered_bytes := 0
	for index in slots.size():
		var slot: Variant = slots[index]
		if not slot is Dictionary:
			continue
		var slot_candidates: Variant = slot.get("candidates", [])
		if not slot_candidates is Array:
			continue
		for raw_candidate in slot_candidates:
			if raw_candidate is Dictionary:
				buffered_candidate_count += 1
				buffered_bytes += _rtc_candidate_byte_size(raw_candidate as Dictionary)
		if int(slot.get("offer_generation", -1)) == generation:
			slot_index = index
			slot_connection_id = str(slot.get("connection_id", ""))
			if slot_candidates.has(candidate):
				return "duplicate"
	var incoming_candidate_bytes := _rtc_candidate_byte_size(candidate)
	var decision := managed_rtc_future_candidate_decision(
		session_protocol_version,
		generation,
		connection_id,
		int(_rtc_highest_offer_generations.get(remote_id, 0)),
		slot_index >= 0,
		slot_connection_id,
		slots.size(),
		buffered_candidate_count,
		buffered_bytes,
		incoming_candidate_bytes,
	)
	if decision != "buffer":
		return decision
	if slot_index < 0:
		slots.append({"offer_generation": generation, "connection_id": connection_id, "candidates": []})
		slot_index = slots.size() - 1
	var target_slot: Dictionary = slots[slot_index]
	var target_candidates: Array = target_slot.get("candidates", []) if target_slot.get("candidates", []) is Array else []
	target_candidates.append(candidate.duplicate(true))
	target_slot["candidates"] = target_candidates
	slots[slot_index] = target_slot
	_rtc_future_candidate_buffers[remote_id] = slots
	return "buffer"


func _flush_future_rtc_candidates(
	remote_id: String,
	connection_id: String,
	generation: int,
	expected_peer: WebRTCPeerConnection,
) -> Array:
	if (
		expected_peer == null
		or not bool(_rtc_remote_description_set.get(remote_id, false))
		or not _rtc_peer_is_current(remote_id, expected_peer, connection_id, generation)
	):
		return []
	var raw_slots: Variant = _rtc_future_candidate_buffers.get(remote_id, [])
	var slots: Array = raw_slots if raw_slots is Array else []
	var retained: Array = []
	var flushed: Array = []
	for raw_slot in slots:
		if not raw_slot is Dictionary:
			continue
		var slot := raw_slot as Dictionary
		var slot_generation := int(slot.get("offer_generation", -1))
		var slot_connection_id := str(slot.get("connection_id", ""))
		if slot_generation == generation and slot_connection_id == connection_id:
			var candidates: Variant = slot.get("candidates", [])
			if candidates is Array:
				for raw_candidate in candidates:
					if raw_candidate is Dictionary and flushed.size() < RTC_MAX_FUTURE_CANDIDATES_PER_PEER:
						flushed.append((raw_candidate as Dictionary).duplicate(true))
		elif slot_generation > generation and slot_generation - generation <= RTC_MAX_FUTURE_OFFER_GENERATION_GAP:
			retained.append(slot)
	if retained.is_empty():
		_rtc_future_candidate_buffers.erase(remote_id)
	else:
		_rtc_future_candidate_buffers[remote_id] = retained
	if not flushed.is_empty():
		_rtc_diag_event("future_candidates_flushed", remote_id, connection_id, generation, {
			"decision": "accept",
			"candidate_count": flushed.size(),
		})
	return flushed


static func _rtc_candidate_byte_size(candidate: Dictionary) -> int:
	return str(candidate.get("media", "")).to_utf8_buffer().size() + str(candidate.get("name", "")).to_utf8_buffer().size() + 8


func _add_rtc_candidate(
	remote_id: String,
	candidate: Dictionary,
	expected_peer: WebRTCPeerConnection = null,
	expected_connection_id: String = "",
	expected_generation: int = -1,
) -> void:
	var peer: WebRTCPeerConnection = _rtc_peers.get(remote_id)
	var connection_id := str(_rtc_connection_ids.get(remote_id, ""))
	var generation := int(_rtc_offer_generations.get(remote_id, -1))
	if expected_peer != null:
		if (
			peer != expected_peer
			or connection_id != expected_connection_id
			or generation != expected_generation
			or not bool(_rtc_remote_description_set.get(remote_id, false))
		):
			return
		peer = expected_peer
	if peer != null:
		var add_result := peer.add_ice_candidate(str(candidate.get("media", "")), int(candidate.get("index", 0)), str(candidate.get("name", "")))
		if _rtc_diag_can_record_candidate(remote_id, "remote_added"):
			_rtc_diag_event("remote_candidate_added", remote_id, connection_id, generation, {
				"candidate_type": _rtc_diag_candidate_type(str(candidate.get("name", ""))),
				"candidate_index": int(candidate.get("index", 0)),
				"result_code": add_result,
				"candidate_action": "added",
			})


func _handle_rtc_packet(remote_id: String, packet: PackedByteArray) -> void:
	var parsed = JSON.parse_string(packet.get_string_from_utf8())
	if not parsed is Dictionary:
		return
	var message := parsed as Dictionary
	var kind := str(message.get("kind", ""))
	var type := str(message.get("type", ""))
	# A host must prove that its outbound path works. Guest commands and pings only
	# prove the opposite direction, so only the pong to our own ping refreshes the
	# host watchdog. A guest can use any valid inbound packet as proof that the
	# authoritative host-to-guest path is alive.
	if rtc_packet_refreshes_watchdog(role == "guest", kind, type):
		_rtc_last_seen_msec[remote_id] = Time.get_ticks_msec()
		_rtc_silence_probe_deadline_msec.erase(remote_id)
		_rtc_silence_probe_diagnostics.erase(remote_id)
	if kind == "control" and type == "p2p_ping":
		_send_rtc(remote_id, {"kind": "control", "type": "p2p_pong", "payload": message.get("payload", {})})
		return
	if kind == "control" and type == "p2p_pong":
		return
	message["sender_player_id"] = remote_id
	message_received.emit(message)


static func rtc_packet_refreshes_watchdog(guest_connection: bool, kind: String, type: String) -> bool:
	return guest_connection or (kind == "control" and type == "p2p_pong")


func _handle_rtc_voice_packet(remote_id: String, packet: PackedByteArray) -> void:
	# Voice is a separate unordered channel. It must never refresh the reliable
	# game-channel watchdog: one SCTP stream can remain active while another is
	# closed or head-of-line blocked, which otherwise masks a frozen world.
	var decoded := decode_voice_packet(packet)
	if decoded.is_empty():
		return
	var sender_id := str(decoded.get("sender_player_id", ""))
	var sequence := int(decoded.get("sequence", 0))
	var audio: PackedByteArray = decoded.get("audio", PackedByteArray())
	if is_host():
		# A guest cannot impersonate another player. The host rewrites the envelope
		# before relaying the compressed frame to the other direct peers.
		sender_id = remote_id
		packet = encode_voice_packet(sender_id, sequence, audio)
		for raw_peer_id in _rtc_voice_channels:
			var target_id := str(raw_peer_id)
			if target_id != remote_id and _rtc_voice_channel_open(target_id):
				_send_rtc_voice(target_id, packet)
	elif remote_id != _guest_host_id or (sender_id != remote_id and not _known_players.has(sender_id)):
		return
	voice_packet_received.emit(sender_id, sequence, audio)


static func encode_voice_packet(sender_player_id: String, sequence: int, audio: PackedByteArray) -> PackedByteArray:
	var sender_bytes := sender_player_id.to_utf8_buffer()
	if sender_bytes.is_empty() or sender_bytes.size() > VOICE_MAX_PLAYER_ID_BYTES or audio.is_empty() or audio.size() > VOICE_MAX_AUDIO_BYTES:
		return PackedByteArray()
	var packet := PackedByteArray()
	packet.resize(5 + sender_bytes.size() + audio.size())
	packet[0] = VOICE_PACKET_MAGIC
	packet[1] = VOICE_PACKET_VERSION
	packet[2] = sender_bytes.size()
	var normalized_sequence := posmod(sequence, 65536)
	packet[3] = (normalized_sequence >> 8) & 0xff
	packet[4] = normalized_sequence & 0xff
	for index in sender_bytes.size():
		packet[5 + index] = sender_bytes[index]
	for index in audio.size():
		packet[5 + sender_bytes.size() + index] = audio[index]
	return packet


static func decode_voice_packet(packet: PackedByteArray) -> Dictionary:
	if packet.size() < 7 or packet[0] != VOICE_PACKET_MAGIC or packet[1] != VOICE_PACKET_VERSION:
		return {}
	var sender_size := int(packet[2])
	var audio_offset := 5 + sender_size
	var audio_size := packet.size() - audio_offset
	if sender_size <= 0 or sender_size > VOICE_MAX_PLAYER_ID_BYTES or audio_size <= 0 or audio_size > VOICE_MAX_AUDIO_BYTES:
		return {}
	var sender_id := packet.slice(5, audio_offset).get_string_from_utf8()
	if sender_id.is_empty():
		return {}
	return {
		"sender_player_id": sender_id,
		"sequence": (int(packet[3]) << 8) | int(packet[4]),
		"audio": packet.slice(audio_offset),
	}


static func is_newer_voice_sequence(sequence: int, previous: int) -> bool:
	if previous < 0:
		return true
	var delta := posmod(sequence - previous, 65536)
	return delta > 0 and delta < 32768


func _rtc_channel_open(remote_id: String) -> bool:
	if remote_id.is_empty() or not _rtc_channels.has(remote_id):
		return false
	var channel: WebRTCDataChannel = _rtc_channels[remote_id]
	return channel != null and channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN


func _rtc_voice_channel_open(remote_id: String) -> bool:
	if remote_id.is_empty() or not _rtc_voice_channels.has(remote_id):
		return false
	var channel: WebRTCDataChannel = _rtc_voice_channels[remote_id]
	return channel != null and channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN


func _send_rtc(remote_id: String, message: Dictionary) -> bool:
	if not _rtc_channel_open(remote_id):
		return false
	var channel: WebRTCDataChannel = _rtc_channels[remote_id]
	return channel.put_packet(JSON.stringify(message).to_utf8_buffer()) == OK


func _send_rtc_voice(remote_id: String, packet: PackedByteArray) -> bool:
	if not _rtc_voice_channel_open(remote_id):
		return false
	var channel: WebRTCDataChannel = _rtc_voice_channels[remote_id]
	return channel.put_packet(packet) == OK


func _send_ws(message: Dictionary) -> bool:
	return _send_ws_result(message) == OK


func _send_ws_result(message: Dictionary) -> int:
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNAVAILABLE
	return socket.send_text(JSON.stringify(message))


func _rtc_websocket_buffered_bytes() -> int:
	if socket == null:
		return -1
	return clampi(socket.get_current_outbound_buffered_amount(), 0, 10000000)


func _set_transport_mode(mode: String) -> void:
	if transport_mode == mode:
		return
	transport_mode = mode
	transport_changed.emit(mode)


func _close_rtc_peer(remote_id: String, close_reason: String = "unspecified") -> void:
	if _rtc_peers.has(remote_id):
		_rtc_diag_event("peer_closed", remote_id, str(_rtc_connection_ids.get(remote_id, "")), int(_rtc_offer_generations.get(remote_id, -1)), {
			"close_reason": close_reason,
		})
	if _rtc_channels.has(remote_id):
		var channel: WebRTCDataChannel = _rtc_channels[remote_id]
		if channel != null:
			channel.close()
	if _rtc_voice_channels.has(remote_id):
		var voice_channel: WebRTCDataChannel = _rtc_voice_channels[remote_id]
		if voice_channel != null:
			voice_channel.close()
	if _rtc_peers.has(remote_id):
		var peer: WebRTCPeerConnection = _rtc_peers[remote_id]
		if peer != null:
			peer.close()
	_rtc_channels.erase(remote_id)
	_rtc_voice_channels.erase(remote_id)
	_rtc_peers.erase(remote_id)
	_rtc_remote_description_set.erase(remote_id)
	_rtc_pending_candidates.erase(remote_id)
	_rtc_ready_peers.erase(remote_id)
	_rtc_connection_ids.erase(remote_id)
	_rtc_offer_generations.erase(remote_id)
	_rtc_last_seen_msec.erase(remote_id)
	_rtc_last_ping_put_ok.erase(remote_id)
	_rtc_last_ping_sent_msec.erase(remote_id)
	_rtc_silence_probe_deadline_msec.erase(remote_id)
	_rtc_silence_probe_diagnostics.erase(remote_id)
	_rtc_observed_state_signatures.erase(remote_id)
	_rtc_diagnostic_event_counts.erase(remote_id)
	for direction in ["local", "remote", "remote_added"]:
		_rtc_diagnostic_candidate_counts.erase("%s:%s" % [remote_id, direction])


func _close_rtc(close_reason: String = "session_closed") -> void:
	for raw_peer_id in _rtc_peers.keys():
		_close_rtc_peer(str(raw_peer_id), close_reason)
	_rtc_peers.clear()
	_rtc_channels.clear()
	_rtc_voice_channels.clear()
	_rtc_remote_description_set.clear()
	_rtc_pending_candidates.clear()
	_rtc_ready_peers.clear()
	_rtc_connection_ids.clear()
	_rtc_offer_generations.clear()
	_rtc_highest_offer_generations.clear()
	_rtc_highest_offer_connection_ids.clear()
	_rtc_future_candidate_buffers.clear()
	_rtc_last_seen_msec.clear()
	_rtc_last_ping_put_ok.clear()
	_rtc_last_ping_sent_msec.clear()
	_rtc_silence_probe_deadline_msec.clear()
	_rtc_silence_probe_diagnostics.clear()
	_rtc_observed_state_signatures.clear()
	_rtc_diagnostic_candidate_counts.clear()
	_rtc_diagnostic_event_counts.clear()
	_rtc_offer_generation = 0
