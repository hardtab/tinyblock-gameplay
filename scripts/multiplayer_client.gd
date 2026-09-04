extends Node

signal connected(role: String, player_id: String, session_id: String)
signal disconnected(reason: String)
signal message_received(message: Dictionary)
signal transport_changed(mode: String)
signal voice_packet_received(sender_player_id: String, sequence: int, audio: PackedByteArray)

const PROTOCOL_VERSION := 2
const DUEL_PROTOCOL_VERSION := 3
const MAX_PLAYERS := 4
const HEARTBEAT_SECONDS := 15.0
const RTC_CONNECT_TIMEOUT_SECONDS := 4.0
const RTC_PING_SECONDS := 2.0
const RTC_SILENCE_TIMEOUT_SECONDS := 7.0
const RTC_RECONNECT_TIMEOUT_SECONDS := 6.0
const RTC_MAX_RECONNECT_ATTEMPTS := 3
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
	]
}

var socket: WebSocketPeer
var role := ""
var player_id := ""
var session_id := ""
var join_code := ""
var transport_mode := "websocket"
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
var _rtc_ready_peers: Dictionary = {}
var _rtc_connection_ids: Dictionary = {}
var _rtc_last_seen_msec: Dictionary = {}
var _guest_host_id := ""
var _guest_connected_message: Dictionary = {}
var _guest_connect_time_left := 0.0
var _connected_message_emitted := false
var _rtc_ping_left := RTC_PING_SECONDS
var _rtc_reconnect_attempt := 0
var _rtc_reconnect_left := -1.0
var _rtc_reconnect_connect_left := 0.0
var _rtc_reconnecting := false


func _ready() -> void:
	# The host must keep its signaling heartbeat alive while a fullscreen ad
	# pauses gameplay; otherwise the public session expires after 45 seconds.
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_online() -> bool:
	return socket != null and socket.get_ready_state() == WebSocketPeer.STATE_OPEN


func is_host() -> bool:
	return is_online() and role == "host"


func is_guest() -> bool:
	return is_online() and role == "guest"


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
	_close_rtc()
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
			_send_ws({"kind": "control", "type": "hello", "payload": {"protocol_version": session_protocol_version}})
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
		socket = null
		_close_rtc()
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
	var open_game_peers: Array[String] = []
	for raw_peer_id in _rtc_peers.keys():
		var remote_id := str(raw_peer_id)
		var peer: WebRTCPeerConnection = _rtc_peers[raw_peer_id]
		peer.poll()
		var channel: WebRTCDataChannel = _rtc_channels.get(remote_id)
		if channel != null and channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			if not _rtc_ready_peers.has(remote_id):
				_rtc_ready_peers[remote_id] = true
				_rtc_last_seen_msec[remote_id] = now
				print("Multiplayer P2P channel open: %s" % remote_id)
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
			print("Multiplayer P2P channel closed: %s" % remote_id)
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
				_send_rtc(ping_peer_id, {"kind": "control", "type": "p2p_ping", "payload": {"sent_msec": now}})
		for silent_peer_id in open_game_peers:
			var last_seen := int(_rtc_last_seen_msec.get(silent_peer_id, now))
			if now - last_seen >= int(RTC_SILENCE_TIMEOUT_SECONDS * 1000.0):
				_recover_silent_rtc_peer(silent_peer_id)
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
		_close_rtc_peer(left_id)
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
	_close_rtc_peer(_guest_host_id)
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


func _recover_silent_rtc_peer(remote_id: String) -> void:
	var guest_connection := is_guest() and remote_id == _guest_host_id
	var recovery_mode := rtc_silence_recovery_mode(guest_connection, websocket_fallback_enabled)
	print("Multiplayer P2P channel silent: %s, recovery=%s" % [remote_id, recovery_mode])
	_close_rtc_peer(remote_id)
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
		_close_rtc_peer(_guest_host_id)
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
		active_socket.close(4000, "p2p_unavailable")
	_close_rtc()
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


func _create_rtc_peer(remote_id: String, connection_id: String = "") -> bool:
	if remote_id.is_empty():
		return false
	if _rtc_peers.has(remote_id):
		return true
	if connection_id.is_empty():
		connection_id = Crypto.new().generate_random_bytes(8).hex_encode()
	var peer := WebRTCPeerConnection.new()
	if peer.initialize(RTC_CONFIGURATION) != OK:
		return false
	var channel := peer.create_data_channel("tinyblock", {"negotiated": true, "id": RTC_CHANNEL_ID, "ordered": true})
	if channel == null:
		peer.close()
		return false
	var voice_channel := peer.create_data_channel("tinyblock-voice", {
		"negotiated": true,
		"id": RTC_VOICE_CHANNEL_ID,
		"ordered": false,
		"maxRetransmits": 0,
	})
	if voice_channel == null:
		channel.close()
		peer.close()
		return false
	peer.session_description_created.connect(_on_rtc_session_created.bind(remote_id))
	peer.ice_candidate_created.connect(_on_rtc_ice_candidate.bind(remote_id))
	_rtc_peers[remote_id] = peer
	_rtc_channels[remote_id] = channel
	_rtc_voice_channels[remote_id] = voice_channel
	_rtc_remote_description_set[remote_id] = false
	_rtc_pending_candidates[remote_id] = []
	_rtc_connection_ids[remote_id] = connection_id
	return true


func _on_rtc_session_created(type: String, sdp: String, remote_id: String) -> void:
	var peer: WebRTCPeerConnection = _rtc_peers.get(remote_id)
	if peer == null or peer.set_local_description(type, sdp) != OK:
		return
	if role == "guest" and type == "offer":
		_send_ws({"kind": "command", "type": "rtc_offer", "payload": {"sdp": sdp, "connection_id": str(_rtc_connection_ids.get(remote_id, ""))}, "seq": 0})
	elif role == "host" and type == "answer":
		_send_ws({
			"kind": "state",
			"type": "rtc_answer",
			"payload": {"sdp": sdp, "connection_id": str(_rtc_connection_ids.get(remote_id, ""))},
			"target_player_id": remote_id,
			"seq": 0,
		})


func _on_rtc_ice_candidate(media: String, index: int, name: String, remote_id: String) -> void:
	var payload := {"media": media, "index": index, "name": name, "connection_id": str(_rtc_connection_ids.get(remote_id, ""))}
	if role == "guest":
		_send_ws({"kind": "command", "type": "rtc_candidate", "payload": payload, "seq": 0})
	elif role == "host":
		_send_ws({
			"kind": "state",
			"type": "rtc_candidate",
			"payload": payload,
			"target_player_id": remote_id,
			"seq": 0,
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
	if type == "rtc_offer":
		if role != "host" or connection_id.is_empty():
			return
		if _rtc_peers.has(remote_id) and str(_rtc_connection_ids.get(remote_id, "")) != connection_id:
			_close_rtc_peer(remote_id)
		if not _create_rtc_peer(remote_id, connection_id):
			return
		_set_rtc_remote_description(remote_id, "offer", str(payload.get("sdp", "")))
	elif type == "rtc_answer":
		if role == "guest" and connection_id == str(_rtc_connection_ids.get(remote_id, "")):
			_set_rtc_remote_description(remote_id, "answer", str(payload.get("sdp", "")))
	elif type == "rtc_candidate":
		if connection_id.is_empty() or connection_id != str(_rtc_connection_ids.get(remote_id, "")):
			return
		var candidate := {
			"media": str(payload.get("media", "")),
			"index": int(payload.get("index", 0)),
			"name": str(payload.get("name", "")),
		}
		if not _rtc_peers.has(remote_id) or not bool(_rtc_remote_description_set.get(remote_id, false)):
			if not _rtc_pending_candidates.has(remote_id):
				_rtc_pending_candidates[remote_id] = []
			(_rtc_pending_candidates[remote_id] as Array).append(candidate)
		else:
			_add_rtc_candidate(remote_id, candidate)


func _set_rtc_remote_description(remote_id: String, type: String, sdp: String) -> void:
	var peer: WebRTCPeerConnection = _rtc_peers.get(remote_id)
	if peer == null or sdp.is_empty() or peer.set_remote_description(type, sdp) != OK:
		return
	_rtc_remote_description_set[remote_id] = true
	var pending: Array = _rtc_pending_candidates.get(remote_id, []) if _rtc_pending_candidates.get(remote_id, []) is Array else []
	for raw_candidate in pending:
		if raw_candidate is Dictionary:
			_add_rtc_candidate(remote_id, raw_candidate as Dictionary)
	_rtc_pending_candidates[remote_id] = []


func _add_rtc_candidate(remote_id: String, candidate: Dictionary) -> void:
	var peer: WebRTCPeerConnection = _rtc_peers.get(remote_id)
	if peer != null:
		peer.add_ice_candidate(str(candidate.get("media", "")), int(candidate.get("index", 0)), str(candidate.get("name", "")))


func _handle_rtc_packet(remote_id: String, packet: PackedByteArray) -> void:
	_rtc_last_seen_msec[remote_id] = Time.get_ticks_msec()
	var parsed = JSON.parse_string(packet.get_string_from_utf8())
	if not parsed is Dictionary:
		return
	var message := parsed as Dictionary
	var kind := str(message.get("kind", ""))
	var type := str(message.get("type", ""))
	if kind == "control" and type == "p2p_ping":
		_send_rtc(remote_id, {"kind": "control", "type": "p2p_pong", "payload": message.get("payload", {})})
		return
	if kind == "control" and type == "p2p_pong":
		return
	message["sender_player_id"] = remote_id
	message_received.emit(message)


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
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return socket.send_text(JSON.stringify(message)) == OK


func _set_transport_mode(mode: String) -> void:
	if transport_mode == mode:
		return
	transport_mode = mode
	transport_changed.emit(mode)


func _close_rtc_peer(remote_id: String) -> void:
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
	_rtc_last_seen_msec.erase(remote_id)


func _close_rtc() -> void:
	for raw_peer_id in _rtc_peers.keys():
		_close_rtc_peer(str(raw_peer_id))
	_rtc_peers.clear()
	_rtc_channels.clear()
	_rtc_voice_channels.clear()
	_rtc_remote_description_set.clear()
	_rtc_pending_candidates.clear()
	_rtc_ready_peers.clear()
	_rtc_connection_ids.clear()
	_rtc_last_seen_msec.clear()
