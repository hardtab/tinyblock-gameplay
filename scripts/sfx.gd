extends Node
const ACHIEVEMENT_STREAM_PATH := "res://gameplay/assets/audio/sfx/achievement_unlocked.mp3"

var _enabled := not OS.has_feature("dedicated_server")


func set_enabled(on: bool) -> void:
	_enabled = on


func _tone(freq: float, dur: float, wave: int = 0, vol: float = 0.07, slide: float = 0.0) -> void:
	if not _enabled:
		return
	var player := AudioStreamPlayer.new()
	player.stream = _make_tone(freq, dur, wave, vol, slide)
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func _make_tone(freq: float, dur: float, wave: int, vol: float, slide: float) -> AudioStreamWAV:
	var sample_rate := 22050
	var count := int(sample_rate * dur)
	var data := PackedByteArray()
	data.resize(count * 2)
	for i in count:
		var t := float(i) / sample_rate
		var f := freq
		if slide != 0.0:
			f = freq * pow(max(40.0, freq + slide) / freq, t / dur)
		var s := 0.0
		match wave:
			0: s = sign(sin(TAU * f * t))
			1: s = asin(sin(TAU * f * t)) / (PI / 2.0)
			2: s = 2.0 * (f * t - floor(f * t + 0.5))
			_: s = sin(TAU * f * t)
		var env := exp(-6.0 * t / dur)
		var sample := int(clamp(s * vol * env * 32767.0, -32768.0, 32767.0))
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = data
	return stream


func _make_thunder() -> AudioStreamWAV:
	var sample_rate := 22050
	var duration := 0.78
	var count := int(sample_rate * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var filtered_noise := 0.0
	for i in count:
		var t := float(i) / float(sample_rate)
		var white := randf_range(-1.0, 1.0)
		filtered_noise = filtered_noise * 0.91 + white * 0.09
		var crack := white * exp(-52.0 * t)
		var rumble_env := exp(-3.4 * t) * minf(1.0, t * 24.0)
		var low_rumble := filtered_noise * 2.8 + sin(TAU * 54.0 * t) * 0.18
		var echo := sin(TAU * 82.0 * t) * exp(-7.0 * maxf(0.0, t - 0.11)) * (0.12 if t >= 0.11 else 0.0)
		var value := (crack * 0.72 + low_rumble * rumble_env + echo) * 0.18
		var sample := int(clamp(value * 32767.0, -32768.0, 32767.0))
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = data
	return stream


func _make_chest_open() -> AudioStreamWAV:
	var sample_rate := 22050
	var duration := 0.24
	var count := int(sample_rate * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var noise_seed := 739391
	for i in count:
		var t := float(i) / float(sample_rate)
		noise_seed = posmod(noise_seed * 1664525 + 1013904223, 2147483647)
		var noise := float(noise_seed) / 1073741823.5 - 1.0
		# A low wooden knock, followed by a short rising-lid hinge creak and latch click.
		var wood := (sin(TAU * 112.0 * t) + sin(TAU * 168.0 * t) * 0.45) * exp(-23.0 * t)
		var creak := 0.0
		if t >= 0.025 and t <= 0.205:
			var u := (t - 0.025) / 0.18
			var phase := TAU * (235.0 * (t - 0.025) - 82.0 * pow(t - 0.025, 2.0))
			creak = asin(sin(phase)) / (PI * 0.5) * sin(PI * u) * 0.38
		var first_click := noise * exp(-150.0 * t)
		var latch_time := maxf(0.0, t - 0.19)
		var latch_click := noise * exp(-190.0 * latch_time) * (0.38 if t >= 0.19 else 0.0)
		var value := (wood * 0.64 + creak + first_click * 0.22 + latch_click) * 0.115
		var sample := int(clamp(value * 32767.0, -32768.0, 32767.0))
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = data
	return stream


func _make_tool_break() -> AudioStreamWAV:
	var sample_rate := 22050
	var duration := 0.19
	var count := int(sample_rate * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var noise_seed := 486187739
	for i in count:
		var t := float(i) / float(sample_rate)
		noise_seed = posmod(noise_seed * 1664525 + 1013904223, 2147483647)
		var noise := float(noise_seed) / 1073741823.5 - 1.0
		# A dry snap followed by a short descending metallic/wooden rattle.
		var snap: float = noise * exp(-92.0 * t)
		var frequency: float = lerpf(680.0, 105.0, t / duration)
		var crack: float = signf(sin(TAU * frequency * t)) * exp(-18.0 * t)
		var splinter: float = sin(TAU * 173.0 * t) * exp(-12.0 * t)
		var value: float = (snap * 0.68 + crack * 0.31 + splinter * 0.18) * 0.11
		var sample := int(clamp(value * 32767.0, -32768.0, 32767.0))
		data[i * 2] = sample & 0xFF
		data[i * 2 + 1] = (sample >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = data
	return stream


func _burst(freqs: Array, dur: float, wave: int, vol: float) -> void:
	for i in freqs.size():
		var f: float = freqs[i]
		get_tree().create_timer(i * 0.018).timeout.connect(func(): _tone(f, dur, wave, vol * (1.0 - i * 0.15)))


func mine_hit(name: String) -> void:
	if name in ["stone", "cobblestone", "obsidian"]:
		_tone(180.0, 0.04, 0, 0.03)
	elif name == "wood":
		_tone(140.0, 0.05, 1, 0.045)
	elif name in ["water", "lava"]:
		pass
	else:
		_tone(220.0 + randf() * 40.0, 0.035, 1, 0.035)


func attack() -> void:
	# A short descending swipe reads as an immediate strike rather than a mining tick.
	_tone(410.0, 0.065, 2, 0.045, -250.0)


func break_block(name: String) -> void:
	if name in ["stone", "cobblestone", "obsidian"]:
		_burst([220.0, 160.0, 110.0], 0.07, 0, 0.06)
	elif name == "wood":
		_burst([120.0, 90.0], 0.08, 1, 0.07)
	elif name in ["leaves", "grass"]:
		_burst([420.0, 520.0, 380.0], 0.05, 1, 0.04)
	elif name == "water":
		_tone(260.0, 0.08, 2, 0.03, -80.0)
	elif name == "lava":
		_tone(90.0, 0.12, 2, 0.05)
	else:
		_burst([180.0, 140.0], 0.06, 1, 0.05)


func place(name: String) -> void:
	if name == "water":
		_tone(300.0, 0.06, 2, 0.03, -60.0)
	elif name == "lava":
		_tone(110.0, 0.08, 2, 0.04)
	elif name in ["stone", "cobblestone", "obsidian"]:
		_tone(160.0, 0.05, 0, 0.045, -30.0)
	else:
		_tone(200.0, 0.04, 1, 0.04, -20.0)


func mix_stone() -> void:
	_burst([140.0, 100.0], 0.09, 0, 0.06)


func discovery(kind: String = "entity", first_in_world: bool = true) -> void:
	if not _enabled:
		return
	# A compact major arpeggio followed by a bright three-note celebration.
	# Plants sound softer, creatures slightly bouncier; all share one recognizable cue.
	var wave := 3 if kind == "plant" else (1 if kind == "creature" else 0)
	var notes: Array[float] = [523.25, 659.25, 783.99, 1046.5]
	for index in notes.size():
		var frequency := notes[index]
		get_tree().create_timer(float(index) * 0.075).timeout.connect(
			func(): _tone(frequency, 0.16, wave, 0.045, 55.0)
		)
	var finale_delay := 0.34
	for index in 3:
		var frequency: float = float([1046.5, 1318.5, 1568.0][index])
		get_tree().create_timer(finale_delay + float(index) * 0.022).timeout.connect(
			func(): _tone(frequency, 0.34 if first_in_world else 0.24, 3, 0.048, 25.0)
		)


func lightning() -> void:
	if not _enabled:
		return
	var player := AudioStreamPlayer.new()
	player.stream = _make_thunder()
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func tideglass_crystallize(step_index: int, total_steps: int) -> void:
	if not _enabled:
		return
	var denominator := maxi(1, total_steps - 1)
	var progress := clampf(float(step_index) / float(denominator), 0.0, 1.0)
	var frequency := lerpf(420.0, 980.0, progress)
	# Each segment adds one short crystalline ping. The rising pitch makes the
	# direction and imminent completion legible even when the bridge is off-center.
	_tone(frequency, 0.12, 3, 0.035, 95.0)
	if step_index == total_steps - 1:
		_burst([1046.5, 1318.5, 1568.0], 0.18, 3, 0.036)


func chest_open() -> void:
	if not _enabled:
		return
	var player := AudioStreamPlayer.new()
	player.stream = _make_chest_open()
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func tool_break() -> void:
	if not _enabled:
		return
	var player := AudioStreamPlayer.new()
	player.stream = _make_tool_break()
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()

func achievement_unlocked() -> void:
	if not _enabled:
		return
	var stream := load(ACHIEVEMENT_STREAM_PATH) as AudioStreamMP3
	if stream == null:
		push_warning("Achievement sound could not be loaded.")
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()



func jump() -> void:
	_tone(360.0, 0.075, 3, 0.022, 180.0)


func shagot_voice(role: String = "neutral") -> void:
	if not _enabled:
		return
	var base := 245.0
	if role == "friendly":
		base = 320.0
	elif role == "hostile":
		base = 175.0
	_tone(base, 0.09, 1, 0.026, 35.0 if role != "hostile" else -25.0)
	get_tree().create_timer(0.075).timeout.connect(
		func(): _tone(base * (1.18 if role == "friendly" else 0.88), 0.11, 2, 0.022, 18.0)
	)


func shagot_work(action: String) -> void:
	if action == "building":
		_tone(150.0, 0.055, 0, 0.018, -15.0)
		get_tree().create_timer(0.045).timeout.connect(func(): _tone(205.0, 0.07, 3, 0.016, -30.0))
	else:
		_tone(118.0, 0.07, 2, 0.02, -25.0)


func hurt() -> void:
	_tone(90.0, 0.18, 2, 0.08, -30.0)


func land() -> void:
	_tone(200.0, 0.05, 3, 0.018, -40.0)
