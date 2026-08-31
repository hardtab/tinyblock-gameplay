extends Node

signal state_changed(available: bool, talking: bool)
signal problem(message_key: String)

const SAMPLE_RATE := 16000
const FRAME_SAMPLES := 320
const JITTER_FRAMES := 3
const MAX_QUEUED_SAMPLES := 8000
const FULL_VOLUME_DISTANCE_TILES := 3.0
const MAX_DISTANCE_TILES := 18.0
const AVAILABILITY_POLL_SECONDS := 0.25
const ANDROID_MIC_PERMISSION := "android.permission.RECORD_AUDIO"
const APPLE_MIC_PERMISSION := "appleembedded.permission.AUDIO_RECORD"

var talking := false
var _available := false
var _input_active := false
var _capture_samples := PackedFloat32Array()
var _resample_position := 0.0
var _sequence := 0
var _peers: Dictionary = {}
var _availability_poll_left := 0.0


func _init() -> void:
	# The audio driver must be input-capable for on-demand capture to work, but
	# that project setting can make a platform open the device during startup.
	# Close it at the earliest autoload lifecycle point; begin_talking() is the
	# only path that activates it again after permission and P2P checks pass.
	AudioServer.set_input_device_active(false)


func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		set_process(false)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	MultiplayerClient.voice_packet_received.connect(_on_voice_packet)
	MultiplayerClient.disconnected.connect(func(_reason: String): reset_session())
	MultiplayerClient.transport_changed.connect(func(_mode: String): _refresh_availability())
	set_process(true)


func _process(_delta: float) -> void:
	_availability_poll_left -= _delta
	if _availability_poll_left <= 0.0:
		_availability_poll_left = AVAILABILITY_POLL_SECONDS
		_refresh_availability()
	if talking:
		_capture_and_send()
	if not _peers.is_empty():
		_pump_playback()


func is_available() -> bool:
	return _available


func begin_talking() -> bool:
	if talking:
		return true
	_refresh_availability()
	if not _available:
		problem.emit("VOICE_P2P_REQUIRED")
		return false
	if not _ensure_microphone_permission():
		problem.emit("VOICE_MIC_PERMISSION")
		return false
	if AudioServer.set_input_device_active(true) != OK:
		problem.emit("VOICE_MIC_UNAVAILABLE")
		return false
	_input_active = true
	talking = true
	_capture_samples.clear()
	_resample_position = 0.0
	_discard_input_frames()
	# Push-to-talk is intentionally half-duplex in the first version. Muting and
	# clearing remote playback while recording prevents speaker audio from being
	# captured and relayed back without requiring an acoustic echo canceller.
	for raw_peer_id in _peers:
		var peer: Dictionary = _peers[raw_peer_id]
		var queued_samples: PackedFloat32Array = peer.get("samples", PackedFloat32Array())
		queued_samples.clear()
		peer["samples"] = queued_samples
		var playback: AudioStreamGeneratorPlayback = peer.get("playback")
		if playback != null:
			playback.clear_buffer()
		peer["started"] = false
	state_changed.emit(_available, talking)
	return true


func end_talking() -> void:
	var state_was_active := talking or _input_active
	talking = false
	_capture_samples.clear()
	_resample_position = 0.0
	# Always issue the stop call. This also repairs stale native state after an
	# interrupted permission request, app resume, or an older saved build that
	# activated input before VoiceChat recorded ownership in _input_active.
	AudioServer.set_input_device_active(false)
	_input_active = false
	if state_was_active:
		state_changed.emit(_available, talking)


func reset_session() -> void:
	end_talking()
	for raw_peer_id in _peers.keys():
		remove_peer(str(raw_peer_id))
	_refresh_availability()


func remove_peer(peer_id: String) -> void:
	if _peers.has(peer_id):
		var peer: Dictionary = _peers[peer_id]
		var player: AudioStreamPlayer = peer.get("player")
		if is_instance_valid(player):
			player.queue_free()
		_peers.erase(peer_id)
	# The roster and RTC channels are updated before Main forwards player_left.
	# Refresh immediately so a host never keeps recording after the last guest
	# leaves, even though the periodic availability poll has not run yet.
	_refresh_availability()


func update_proximity(local_position: Vector2, remote_players: Dictionary, tile_size: float) -> void:
	var safe_tile_size := maxf(1.0, tile_size)
	for raw_peer_id in _peers:
		var peer_id := str(raw_peer_id)
		var peer: Dictionary = _peers[raw_peer_id]
		var gain := 0.0
		if remote_players.get(peer_id) is Dictionary:
			var remote: Dictionary = remote_players[peer_id]
			var remote_position := Vector2(float(remote.get("x", 0.0)), float(remote.get("y", 0.0)))
			gain = proximity_gain(local_position.distance_to(remote_position) / safe_tile_size)
		peer["gain"] = gain
		var player: AudioStreamPlayer = peer.get("player")
		if is_instance_valid(player):
			player.volume_db = -80.0 if talking or gain <= 0.001 else linear_to_db(gain)


static func proximity_gain(distance_tiles: float) -> float:
	if not is_finite(distance_tiles) or distance_tiles >= MAX_DISTANCE_TILES:
		return 0.0
	if distance_tiles <= FULL_VOLUME_DISTANCE_TILES:
		return 1.0
	var normalized := (distance_tiles - FULL_VOLUME_DISTANCE_TILES) / (MAX_DISTANCE_TILES - FULL_VOLUME_DISTANCE_TILES)
	var remaining := 1.0 - clampf(normalized, 0.0, 1.0)
	return remaining * remaining


static func encode_mulaw(samples: PackedFloat32Array) -> PackedByteArray:
	var encoded := PackedByteArray()
	encoded.resize(samples.size())
	for index in samples.size():
		encoded[index] = _linear_sample_to_mulaw(samples[index])
	return encoded


static func decode_mulaw(encoded: PackedByteArray) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(encoded.size())
	for index in encoded.size():
		samples[index] = _mulaw_to_linear_sample(encoded[index])
	return samples


static func _linear_sample_to_mulaw(sample: float) -> int:
	var pcm := clampi(roundi(clampf(sample, -1.0, 1.0) * 32767.0), -32768, 32767)
	var sign := 0x80 if pcm < 0 else 0
	pcm = absi(pcm)
	pcm = mini(pcm, 32635) + 0x84
	var exponent := 7
	var mask := 0x4000
	while exponent > 0 and (pcm & mask) == 0:
		exponent -= 1
		mask >>= 1
	var mantissa := (pcm >> (exponent + 3)) & 0x0f
	return (~(sign | (exponent << 4) | mantissa)) & 0xff


static func _mulaw_to_linear_sample(encoded: int) -> float:
	var value := (~encoded) & 0xff
	var sign := value & 0x80
	var exponent := (value >> 4) & 0x07
	var mantissa := value & 0x0f
	var pcm := (((mantissa << 3) + 0x84) << exponent) - 0x84
	if sign != 0:
		pcm = -pcm
	return clampf(float(pcm) / 32768.0, -1.0, 1.0)


func _refresh_availability() -> void:
	var next_available := voice_available_for_session(
		MultiplayerClient.can_send_voice(),
		MultiplayerClient.player_count(),
	)
	if next_available == _available:
		return
	_available = next_available
	if not _available:
		end_talking()
	state_changed.emit(_available, talking)


static func voice_available_for_session(transport_available: bool, player_count: int) -> bool:
	return transport_available and player_count > 1


func _ensure_microphone_permission() -> bool:
	var permission := ""
	if OS.get_name() == "Android":
		permission = ANDROID_MIC_PERMISSION
	elif OS.get_name() == "iOS":
		permission = APPLE_MIC_PERMISSION
	if permission.is_empty() or OS.get_granted_permissions().has(permission):
		return true
	return OS.request_permission(permission)


func _discard_input_frames() -> void:
	var available := AudioServer.get_input_frames_available()
	# Do not let a continuously filling native input ring keep this frame busy.
	for _batch in 4:
		if available <= 0:
			break
		var count := mini(available, 4096)
		AudioServer.get_input_frames(count)
		available = AudioServer.get_input_frames_available()


func _capture_and_send() -> void:
	if not _available:
		end_talking()
		return
	var available := AudioServer.get_input_frames_available()
	if available <= 0:
		return
	var input_frames := AudioServer.get_input_frames(mini(available, 4096))
	if input_frames.is_empty():
		return
	_append_resampled(input_frames, AudioServer.get_input_mix_rate())
	while _capture_samples.size() >= FRAME_SAMPLES:
		var frame := _capture_samples.slice(0, FRAME_SAMPLES)
		_capture_samples = _capture_samples.slice(FRAME_SAMPLES)
		if MultiplayerClient.send_voice_frame(encode_mulaw(frame), _sequence):
			_sequence = (_sequence + 1) & 0xffff


func _append_resampled(input_frames: PackedVector2Array, input_rate: float) -> void:
	if input_frames.is_empty() or input_rate <= 0.0:
		return
	var step := input_rate / float(SAMPLE_RATE)
	while _resample_position < input_frames.size():
		var index := mini(floori(_resample_position), input_frames.size() - 1)
		var sample := input_frames[index]
		_capture_samples.append(clampf((sample.x + sample.y) * 0.5, -1.0, 1.0))
		_resample_position += step
	_resample_position -= input_frames.size()


func _on_voice_packet(sender_player_id: String, sequence: int, audio: PackedByteArray) -> void:
	if sender_player_id.is_empty() or sender_player_id == MultiplayerClient.player_id or talking:
		return
	var peer := _ensure_peer(sender_player_id)
	var previous_sequence := int(peer.get("last_sequence", -1))
	if not MultiplayerClient.is_newer_voice_sequence(sequence, previous_sequence):
		return
	peer["last_sequence"] = sequence
	var samples: PackedFloat32Array = peer.get("samples", PackedFloat32Array())
	samples.append_array(decode_mulaw(audio))
	if samples.size() > MAX_QUEUED_SAMPLES:
		samples = samples.slice(samples.size() - MAX_QUEUED_SAMPLES)
	peer["samples"] = samples


func _ensure_peer(peer_id: String) -> Dictionary:
	if _peers.get(peer_id) is Dictionary:
		return _peers[peer_id]
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = SAMPLE_RATE
	generator.buffer_length = 0.3
	var player := AudioStreamPlayer.new()
	player.name = "Voice_%s" % peer_id.left(12)
	player.stream = generator
	player.volume_db = -80.0
	add_child(player)
	player.play()
	var peer := {
		"player": player,
		"playback": player.get_stream_playback() as AudioStreamGeneratorPlayback,
		"samples": PackedFloat32Array(),
		"started": false,
		"last_sequence": -1,
		"gain": 0.0,
	}
	_peers[peer_id] = peer
	return peer


func _pump_playback() -> void:
	for raw_peer_id in _peers:
		var peer: Dictionary = _peers[raw_peer_id]
		var samples: PackedFloat32Array = peer.get("samples", PackedFloat32Array())
		if not bool(peer.get("started", false)):
			if samples.size() < FRAME_SAMPLES * JITTER_FRAMES:
				continue
			peer["started"] = true
		var playback: AudioStreamGeneratorPlayback = peer.get("playback")
		if playback == null:
			continue
		var count := mini(playback.get_frames_available(), samples.size())
		if count <= 0:
			continue
		var frames := PackedVector2Array()
		frames.resize(count)
		for index in count:
			frames[index] = Vector2(samples[index], samples[index])
		playback.push_buffer(frames)
		samples = samples.slice(count)
		peer["samples"] = samples
		if samples.is_empty():
			peer["started"] = false
