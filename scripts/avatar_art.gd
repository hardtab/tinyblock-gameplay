extends RefCounted
class_name AvatarArt

const DEFAULT_APPEARANCE := {
	"skin": "#e8b184",
	"shirt": "#159d91",
	"shirt_dark": "#0f746c",
	"accent": "#f59e0b",
	"pants": "#4a3426",
	"hair": "#3a2417",
	"body_shape": "classic",
	"antenna": "none",
	"arms": "classic",
	"legs": "classic",
	"face": "none",
	"particles": "none",
}
const ENUM_OPTIONS := {
	"body_shape": ["classic", "round", "boxy"],
	"antenna": ["none", "sprout", "twin"],
	"arms": ["classic", "long", "tiny"],
	"legs": ["classic", "short", "spring"],
	"face": ["none", "mustache", "whiskers"],
	"particles": ["none", "flowers", "fireflies", "stars", "sparks", "fire"],
}


static func normalize_appearance(source: Variant, fallback: Variant = {}) -> Dictionary:
	var appearance := DEFAULT_APPEARANCE.duplicate(true)
	if fallback is Dictionary:
		for key in DEFAULT_APPEARANCE:
			if (fallback as Dictionary).has(key):
				appearance[key] = (fallback as Dictionary)[key]
	if source is Dictionary:
		for key in DEFAULT_APPEARANCE:
			if (source as Dictionary).has(key):
				appearance[key] = (source as Dictionary)[key]
	for key in ["skin", "shirt", "shirt_dark", "accent", "pants", "hair"]:
		var value := str(appearance.get(key, ""))
		if not Color.html_is_valid(value):
			appearance[key] = DEFAULT_APPEARANCE[key]
		else:
			appearance[key] = Color.from_string(value, Color.WHITE).to_html(false)
	for key in ENUM_OPTIONS:
		var allowed: Array = ENUM_OPTIONS[key]
		if str(appearance.get(key, "")) not in allowed:
			appearance[key] = DEFAULT_APPEARANCE[key]
	return appearance


static func draw_avatar(
	canvas: CanvasItem,
	origin: Vector2,
	size: Vector2,
	raw_appearance: Variant,
	facing: int = 1,
	animation_time: float = 0.0,
	moving: bool = false,
	draw_shadow: bool = true,
) -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var appearance := normalize_appearance(raw_appearance)
	var sx := size.x / 20.0
	var sy := size.y / 28.0
	var skin := _color(appearance, "skin")
	var shirt := _color(appearance, "shirt")
	var shirt_dark := _color(appearance, "shirt_dark")
	var accent := _color(appearance, "accent")
	var pants := _color(appearance, "pants")
	var hair := _color(appearance, "hair")

	if moving and str(appearance.get("particles", "none")) != "none":
		_draw_particles(canvas, origin, sx, sy, str(appearance.particles), animation_time)
	if draw_shadow:
		canvas.draw_rect(_rect(origin, sx, sy, 1.0, 25.0, 18.0, 4.0), Color(0.0, 0.0, 0.0, 0.16))

	_draw_legs(canvas, origin, sx, sy, pants, pants.darkened(0.24), skin, str(appearance.legs))
	_draw_torso(canvas, origin, sx, sy, shirt, shirt_dark, accent, str(appearance.body_shape))
	_draw_arms(canvas, origin, sx, sy, shirt_dark, skin, str(appearance.arms))
	_draw_head(canvas, origin, sx, sy, skin, hair, Color("#1a1a1a"), facing, appearance)


static func _draw_torso(
	canvas: CanvasItem, origin: Vector2, sx: float, sy: float,
	shirt: Color, dark: Color, accent: Color, shape: String
) -> void:
	if shape == "round":
		_polygon(canvas, origin, sx, sy, [
			Vector2(5, 10), Vector2(15, 10), Vector2(17, 12), Vector2(17, 18),
			Vector2(15, 20), Vector2(5, 20), Vector2(3, 18), Vector2(3, 12),
		], shirt)
	elif shape == "boxy":
		canvas.draw_rect(_rect(origin, sx, sy, 2, 10, 16, 10), shirt)
	else:
		canvas.draw_rect(_rect(origin, sx, sy, 3, 10, 14, 10), shirt)
	canvas.draw_rect(_rect(origin, sx, sy, 2, 9, 16, 2), accent)
	canvas.draw_rect(_rect(origin, sx, sy, 4, 13, 10, 2), dark)
	canvas.draw_rect(_rect(origin, sx, sy, 7, 13, 3, 2), accent)


static func _draw_legs(
	canvas: CanvasItem, origin: Vector2, sx: float, sy: float,
	pants: Color, dark: Color, skin: Color, style: String
) -> void:
	if style == "spring":
		canvas.draw_rect(_rect(origin, sx, sy, 2, 18, 16, 4), pants)
		for leg_x in [6.0, 14.0]:
			var points := PackedVector2Array([
				_point(origin, sx, sy, leg_x, 22),
				_point(origin, sx, sy, leg_x - 2, 23.5),
				_point(origin, sx, sy, leg_x + 2, 25),
				_point(origin, sx, sy, leg_x - 2, 26.5),
				_point(origin, sx, sy, leg_x + 1, 27),
			])
			for index in range(points.size() - 1):
				canvas.draw_line(points[index], points[index + 1], dark, maxf(1.0, 1.6 * sx), true)
		canvas.draw_rect(_rect(origin, sx, sy, 3, 26, 5, 2), dark)
		canvas.draw_rect(_rect(origin, sx, sy, 12, 26, 5, 2), dark)
		return
	var leg_bottom := 25.0 if style == "short" else 28.0
	var leg_top := 19.0 if style == "short" else 18.0
	canvas.draw_rect(_rect(origin, sx, sy, 2, leg_top, 16, leg_bottom - leg_top), pants)
	canvas.draw_rect(_rect(origin, sx, sy, 9, leg_top + 2, 2, leg_bottom - leg_top - 2), dark)
	if style == "short":
		canvas.draw_rect(_rect(origin, sx, sy, 2, 25, 6, 3), dark)
		canvas.draw_rect(_rect(origin, sx, sy, 12, 25, 6, 3), dark)


static func _draw_arms(
	canvas: CanvasItem, origin: Vector2, sx: float, sy: float,
	dark: Color, skin: Color, style: String
) -> void:
	var arm_top := 11.0 if style == "long" else 12.0
	var arm_height := 11.0 if style == "long" else (4.0 if style == "tiny" else 8.0)
	var arm_width := 3.0 if style != "tiny" else 2.5
	canvas.draw_rect(_rect(origin, sx, sy, 1, arm_top, arm_width, arm_height), dark)
	canvas.draw_rect(_rect(origin, sx, sy, 19.0 - arm_width, arm_top, arm_width, arm_height), dark)
	if style == "long":
		canvas.draw_rect(_rect(origin, sx, sy, 1, 20, arm_width, 2), skin)
		canvas.draw_rect(_rect(origin, sx, sy, 19.0 - arm_width, 20, arm_width, 2), skin)


static func _draw_head(
	canvas: CanvasItem, origin: Vector2, sx: float, sy: float,
	skin: Color, hair: Color, eye: Color, facing: int, appearance: Dictionary
) -> void:
	var shape := str(appearance.get("body_shape", "classic"))
	if shape == "round":
		_polygon(canvas, origin, sx, sy, [
			Vector2(7, 2), Vector2(13, 2), Vector2(15, 4), Vector2(15, 9),
			Vector2(13, 12), Vector2(7, 12), Vector2(5, 9), Vector2(5, 4),
		], skin)
	elif shape == "boxy":
		canvas.draw_rect(_rect(origin, sx, sy, 4, 2, 12, 10), skin)
	else:
		canvas.draw_rect(_rect(origin, sx, sy, 5, 2, 10, 10), skin)
	canvas.draw_rect(_rect(origin, sx, sy, 4, 0, 12, 4), hair)
	var eye_x := 10.0 if facing >= 0 else 6.0
	canvas.draw_rect(_rect(origin, sx, sy, eye_x, 5, 2, 2), eye)
	match str(appearance.get("face", "none")):
		"mustache":
			canvas.draw_rect(_rect(origin, sx, sy, 7, 8, 3, 1.5), hair)
			canvas.draw_rect(_rect(origin, sx, sy, 10, 8, 3, 1.5), hair)
			canvas.draw_rect(_rect(origin, sx, sy, 9, 9, 2, 1), hair.darkened(0.12))
		"whiskers":
			for side in [-1.0, 1.0]:
				var start := _point(origin, sx, sy, 6.0 if side < 0 else 14.0, 8.0)
				canvas.draw_line(start, start + Vector2(side * 3.0 * sx, -1.0 * sy), hair, maxf(0.7, 0.8 * sx), true)
				canvas.draw_line(start, start + Vector2(side * 3.0 * sx, 1.0 * sy), hair, maxf(0.7, 0.8 * sx), true)
	_draw_antenna_style(canvas, origin, sx, sy, _color(appearance, "accent"), str(appearance.get("antenna", "none")))


static func _draw_antenna_style(canvas: CanvasItem, origin: Vector2, sx: float, sy: float, accent: Color, style: String) -> void:
	if style == "sprout":
		var stem_start := _point(origin, sx, sy, 10, 1)
		var stem_end := _point(origin, sx, sy, 10, -2)
		canvas.draw_line(stem_start, stem_end, Color("#4b8c45"), maxf(1.0, sx), true)
		canvas.draw_circle(_point(origin, sx, sy, 8.5, -1.5), 1.5 * minf(sx, sy), Color("#62bd65"))
		canvas.draw_circle(_point(origin, sx, sy, 11.5, -1.5), 1.5 * minf(sx, sy), Color("#8bdd70"))
	elif style == "twin":
		for antenna_x in [7.0, 13.0]:
			canvas.draw_line(_point(origin, sx, sy, antenna_x, 1), _point(origin, sx, sy, antenna_x - 1.0, -3), Color("#546b9e"), maxf(1.0, sx), true)
			canvas.draw_circle(_point(origin, sx, sy, antenna_x - 1.0, -3), 1.5 * minf(sx, sy), accent)


static func _draw_particles(
	canvas: CanvasItem, origin: Vector2, sx: float, sy: float, style: String, elapsed: float
) -> void:
	var unit := minf(sx, sy)
	var particle_origin := origin
	match style:
		"flowers":
			for index in range(3):
				var phase := elapsed * 2.1 + float(index) * 2.1
				var x := 3.0 + float(index) * 7.0 + sin(phase) * 1.5
				var y := 23.0 + fposmod(float(index) * 2.7 + elapsed * 5.0, 5.0)
				canvas.draw_line(_point(particle_origin, sx, sy, x, y + 3.0), _point(particle_origin, sx, sy, x, y + 6.0), Color("#4a9d53"), maxf(0.8, unit), true)
				var center := _point(particle_origin, sx, sy, x, y)
				var radius := maxf(0.8, unit * 0.85)
				var petal: Color = [Color("#ffc857"), Color("#ff8fab"), Color("#b6a1ff")][index]
				for offset in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
					canvas.draw_circle(center + Vector2(offset.x * radius * 1.4, offset.y * radius * 1.4), radius, petal)
				canvas.draw_circle(center, maxf(0.7, radius * 0.6), Color("#fff2a3"))
		"fireflies":
			for index in range(4):
				var phase := elapsed * 2.6 + float(index) * 1.55
				var center := _point(particle_origin, sx, sy, 2.0 + float(index % 2) * 15.0 + sin(phase) * 2.0, 8.0 + float(index) * 4.0 + cos(phase * 0.8) * 2.0)
				var glow := Color("#f5d76e")
				glow.a = 0.2 + 0.16 * sin(phase)
				canvas.draw_circle(center, 2.4 * unit, glow)
				canvas.draw_circle(center, maxf(0.8, 0.8 * unit), Color("#fff4ac"))
		"stars":
			for index in range(3):
				var phase := elapsed * 3.0 + float(index) * 2.05
				var center := _point(particle_origin, sx, sy, 1.0 + float(index) * 9.0, 5.0 + fposmod(float(index) * 3.0 + elapsed * 8.0, 19.0))
				var radius := (1.1 + 0.6 * (0.5 + 0.5 * sin(phase))) * unit
				_draw_star(canvas, center, radius, Color("#fff18b"))
		"sparks":
			for index in range(4):
				var phase := elapsed * 5.0 + float(index) * 1.6
				var x := 2.0 + float(index) * 5.2 + sin(phase) * 1.8
				var y := 20.0 + fposmod(float(index) * 2.8 + elapsed * 10.0, 7.0)
				var point := _point(particle_origin, sx, sy, x, y)
				var tail := point + Vector2(-cos(phase) * 2.0 * sx, 2.6 * sy)
				canvas.draw_line(tail, point, Color("#ff8838", 0.9), maxf(0.8, unit), true)
				canvas.draw_circle(point, maxf(0.8, unit * 0.7), Color("#ffe29a"))

		"fire":
			const FIRE_PREVIEW_LIFETIME := 0.3
			for index in range(2):
				var age := fposmod(elapsed + float(index) * FIRE_PREVIEW_LIFETIME / 2.0, FIRE_PREVIEW_LIFETIME)
				var position := _point(particle_origin, sx, sy, 3.0 + float(index) * 13.5, 27.0 - age * 9.0)
				draw_trail_particle(
					canvas, position, "fire", age, FIRE_PREVIEW_LIFETIME, float(index) * 1.7, unit * 0.6
				)


static func trail_alpha(age: float, lifetime: float) -> float:
	return pow(clampf(1.0 - age / maxf(0.01, lifetime), 0.0, 1.0), 1.3)


static func draw_trail_particle(canvas: CanvasItem, position: Vector2, style: String, age: float, lifetime: float, phase: float, unit: float = 1.0) -> void:
	var alpha := trail_alpha(age, lifetime)
	var radius := unit * (1.2 + alpha * 0.7)
	match style:
		"flowers":
			var petal := Color.from_hsv(fposmod(phase / TAU, 1.0), 0.45, 1.0, alpha)
			canvas.draw_line(position, position + Vector2(0, 3.0 * unit), Color(0.3, 0.65, 0.3, alpha), unit)
			for offset in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
				canvas.draw_circle(position + offset * radius, radius * 0.7, petal)
			canvas.draw_circle(position, radius * 0.5, Color(1.0, 0.9, 0.45, alpha))
		"fireflies":
			var pulse := 0.7 + 0.3 * sin(phase + age * 8.0)
			canvas.draw_circle(position, radius * 2.4, Color(1.0, 0.85, 0.3, alpha * 0.15 * pulse))
			canvas.draw_circle(position, radius * 0.65, Color(1.0, 1.0, 0.6, alpha * pulse))
		"stars":
			_draw_star(canvas, position, radius, Color(1.0, 0.93, 0.45, alpha))
		"sparks":
			canvas.draw_line(position + Vector2(sin(phase) * -2.0, 3.0) * unit, position, Color(1.0, 0.4, 0.15, alpha), unit)
			canvas.draw_circle(position, radius * 0.6, Color(1.0, 0.9, 0.6, alpha))
		"fire":
			var height := (4.0 + alpha * 4.0 + sin(phase + age * 17.0)) * unit
			canvas.draw_circle(position - Vector2(0, height * 0.3), radius * 2.6, Color(1.0, 0.25, 0.04, alpha * 0.12))
			canvas.draw_colored_polygon(PackedVector2Array([
				position + Vector2(-radius * 1.3, 0), position + Vector2(-radius, -height * 0.5),
				position + Vector2(sin(phase + age * 12.0) * unit, -height),
				position + Vector2(radius * 0.7, -height * 0.55), position + Vector2(radius * 1.3, 0),
			]), Color(1.0, 0.28 + alpha * 0.2, 0.05, alpha))
			canvas.draw_colored_polygon(PackedVector2Array([
				position + Vector2(-radius * 0.6, 0), position + Vector2(0, -height * 0.65), position + Vector2(radius * 0.6, 0),
			]), Color(1.0, 0.87, 0.35, alpha))
			canvas.draw_circle(position + Vector2(sin(phase) * 3.0 * unit, -height - age * 3.0 * unit), unit * 0.5, Color(1.0, 0.7, 0.2, alpha))


## Draws a tiny cosmetic halo above the darkness overlay. `darkness` is 0 in
## bright areas and 1 in fully dark areas; this deliberately does not light
## terrain or affect visibility beyond the few pixels around the particle.
static func draw_trail_glow(
	canvas: CanvasItem,
	position: Vector2,
	style: String,
	age: float,
	lifetime: float,
	phase: float,
	darkness: float,
	unit: float = 1.0
) -> void:
	if style not in ["fireflies", "stars", "fire"]:
		return
	var particle_alpha := trail_alpha(age, lifetime)
	if particle_alpha < 0.22:
		return
	var night_factor := smoothstep(0.16, 0.82, clampf(darkness, 0.0, 1.0))
	if night_factor <= 0.0:
		return
	var pulse := 0.86 + 0.14 * sin(phase + age * (8.0 if style == "fireflies" else 3.0))
	var color := Color(1.0, 0.86, 0.38)
	if style == "stars":
		color = Color(1.0, 0.94, 0.62)
	elif style == "fire":
		color = Color(1.0, 0.34, 0.1)
	var radius := clampf(5.0 * maxf(unit, 0.25), 3.5, 6.0)
	var strength := night_factor * particle_alpha * pulse
	# Low-alpha nested circles approximate a soft halo while keeping each glow
	# local and cheap enough for a moving trail on mobile.
	canvas.draw_circle(position, radius, Color(color, 0.04 * strength))
	canvas.draw_circle(position, radius * 0.62, Color(color, 0.065 * strength))
	canvas.draw_circle(position, radius * 0.3, Color(color.lightened(0.18), 0.1 * strength))
	# Keep a tiny warm point visible above the darkness overlay. It marks the
	# cosmetic effect itself without casting light onto nearby terrain.
	canvas.draw_circle(position, clampf(unit * 0.8, 0.7, 1.2), Color(color.lightened(0.35), 0.22 * strength))


static func _draw_star(canvas: CanvasItem, center: Vector2, radius: float, color: Color) -> void:
	var points := PackedVector2Array([
		center + Vector2(0, -radius * 1.7),
		center + Vector2(radius * 0.45, -radius * 0.45),
		center + Vector2(radius * 1.7, 0),
		center + Vector2(radius * 0.45, radius * 0.45),
		center + Vector2(0, radius * 1.7),
		center + Vector2(-radius * 0.45, radius * 0.45),
		center + Vector2(-radius * 1.7, 0),
		center + Vector2(-radius * 0.45, -radius * 0.45),
	])
	canvas.draw_colored_polygon(points, color)


static func _polygon(canvas: CanvasItem, origin: Vector2, sx: float, sy: float, points: Array, color: Color) -> void:
	var scaled := PackedVector2Array()
	for point: Vector2 in points:
		scaled.append(_point(origin, sx, sy, point.x, point.y))
	canvas.draw_colored_polygon(scaled, color)


static func _rect(origin: Vector2, sx: float, sy: float, x: float, y: float, width: float, height: float) -> Rect2:
	return Rect2(_point(origin, sx, sy, x, y), Vector2(width * sx, height * sy))


static func _point(origin: Vector2, sx: float, sy: float, x: float, y: float) -> Vector2:
	return origin + Vector2(x * sx, y * sy)


static func _color(appearance: Dictionary, key: String) -> Color:
	return Color.from_string(str(appearance.get(key, DEFAULT_APPEARANCE[key])), Color.WHITE)
