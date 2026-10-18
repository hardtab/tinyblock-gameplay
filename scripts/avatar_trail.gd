extends RefCounted

const AvatarArtClass = preload("res://gameplay/scripts/avatar_art.gd")
const MAX_PARTICLES := 384
const MAX_EMITTERS := 64
const SPACING := 5.0
const FIRE_DENSITY := 0.7
const TELEPORT_DISTANCE := 96.0
const MAX_EMISSIONS_PER_STEP := 8
const STYLES: Array[String] = ["flowers", "fireflies", "stars", "sparks", "fire"]

var particles: Array[Dictionary] = []
var _emitters: Dictionary = {}
var _sequence := 0


func clear() -> void:
	particles.clear()
	_emitters.clear()


func advance(delta: float, actors: Dictionary) -> void:
	for index in range(particles.size() - 1, -1, -1):
		particles[index]["age"] = float(particles[index]["age"]) + maxf(0.0, delta)
		if float(particles[index]["age"]) >= float(particles[index]["lifetime"]):
			particles.remove_at(index)
	var active_actors: Dictionary = {}
	for raw_id in actors:
		if active_actors.size() >= MAX_EMITTERS:
			break
		active_actors[raw_id] = actors[raw_id]
	for player_id in _emitters.keys():
		if not active_actors.has(player_id):
			_drop_emitter(str(player_id))
	for raw_id in active_actors:
		var player_id := str(raw_id)
		var actor: Dictionary = active_actors[raw_id]
		var position: Vector2 = actor["position"]
		var style := str(actor.get("style", "none"))
		var revision := int(actor.get("revision", 0))
		if style not in STYLES:
			_drop_emitter(player_id)
			continue
		var previous: Dictionary = _emitters.get(player_id, {})
		if previous.is_empty() or previous["style"] != style or int(previous["revision"]) != revision:
			_drop_emitter(player_id)
			_emitters[player_id] = {"position": position, "style": style, "revision": revision, "carry": 0.0}
			continue
		var last_position: Vector2 = previous["position"]
		var distance := last_position.distance_to(position)
		if distance >= TELEPORT_DISTANCE or delta > 0.25:
			_drop_emitter(player_id)
			previous["carry"] = 0.0
		elif bool(actor.get("moving", true)) and distance > 0.1:
			var spacing := SPACING / FIRE_DENSITY if style == "fire" else SPACING
			var next_distance := spacing - float(previous["carry"])
			var emitted := 0
			while next_distance <= distance and emitted < MAX_EMISSIONS_PER_STEP:
				_spawn(player_id, last_position.lerp(position, next_distance / distance), style)
				next_distance += spacing
				emitted += 1
			previous["carry"] = fposmod(float(previous["carry"]) + distance, spacing)
		else:
			previous["carry"] = 0.0
		previous["position"] = position
		_emitters[player_id] = previous


func draw(canvas: CanvasItem) -> void:
	for particle in particles:
		var age := float(particle["age"])
		var position: Vector2 = particle["position"] + particle["drift"] * age
		AvatarArtClass.draw_trail_particle(canvas, position, str(particle["style"]), age, float(particle["lifetime"]), float(particle["phase"]))


func _drop_emitter(player_id: String) -> void:
	if not _emitters.has(player_id):
		return
	_emitters.erase(player_id)
	for index in range(particles.size() - 1, -1, -1):
		if particles[index]["player_id"] == player_id:
			particles.remove_at(index)


func _spawn(player_id: String, position: Vector2, style: String) -> void:
	var count := 2 if style == "fire" else 1
	for index in count:
		_sequence += 1
		var phase := fposmod(float(player_id.hash() % 1000) * 0.1 + float(_sequence) * 2.39996, TAU)
		var lifetime := 2.0 if style == "flowers" else (0.8 if style in ["fire", "sparks"] else 1.3)
		var drift := Vector2.ZERO if style == "flowers" else Vector2(sin(phase) * 2.0, -6.0 if style == "fireflies" else -10.0)
		particles.append({
			"player_id": player_id, "style": style,
			"position": position + Vector2(sin(phase) * 4.0, cos(phase) * 1.5),
			"drift": drift, "age": 0.0, "lifetime": lifetime, "phase": phase,
		})
		if particles.size() > MAX_PARTICLES:
			particles.pop_front()
