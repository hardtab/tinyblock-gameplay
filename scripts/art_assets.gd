extends Node

const PIXEL := 6.0
const SKY_GRADIENT_BANDS := 64
const HAZE_BANDS := 10
const VIGNETTE_BANDS := 9


func draw_sky(canvas: CanvasItem, view: Vector2, time_sec: float = 0.0, scroll_x: float = 0.0, day_phase: float = 0.0, daylight: float = 1.0, world_seed: int = 0, biome_sky: Color = Color("#67b8e3"), daylight_tint: Color = Color("#fff7df"), include_background: bool = true) -> void:
	var day_mix := clampf((daylight - 0.12) / 0.88, 0.0, 1.0)
	var sunset := _golden_hour(day_phase)
	var top_color := Color("#070b22").lerp(Color("#4ea8de"), day_mix)
	var middle_color := Color("#101b3e").lerp(Color("#87ceeb"), day_mix)
	var bottom_color := Color("#1b3158").lerp(Color("#b8e0f5"), day_mix)
	top_color = top_color.lerp(biome_sky.darkened(0.18), day_mix * 0.38)
	middle_color = middle_color.lerp(biome_sky, day_mix * 0.42)
	bottom_color = bottom_color.lerp(daylight_tint, day_mix * 0.22)
	top_color = top_color.lerp(Color("#123d91"), sunset * 0.72)
	middle_color = middle_color.lerp(Color("#c44f70"), sunset * 0.9)
	bottom_color = bottom_color.lerp(Color("#ff8738"), sunset)
	# A one-pixel band per physical screen row created 720+ Canvas commands every
	# frame on phones. The subtle color delta was invisible in the pixel-art sky,
	# but saturated Samsung's Vulkan submission thread. Thirty-two bands preserve
	# the gradient while cutting its command count by more than 20x.
	if include_background:
		var steps := maxi(1, mini(SKY_GRADIENT_BANDS, int(view.y)))
		for i in steps:
			var y0 := floorf(float(i) * view.y / float(steps))
			var y1 := ceilf(float(i + 1) * view.y / float(steps))
			var t: float = (float(i) + 0.5) / float(steps)
			var c := top_color.lerp(middle_color, t / 0.52) if t < 0.52 else middle_color.lerp(bottom_color, (t - 0.52) / 0.48)
			canvas.draw_rect(Rect2(0.0, y0, view.x, y1 - y0), c)

		_draw_horizon_haze(canvas, view, day_mix, sunset, biome_sky, daylight_tint)

	var night_alpha := 1.0 - day_mix
	if night_alpha > 0.01:
		_draw_stars(canvas, view, time_sec, scroll_x, world_seed, night_alpha)
		_draw_moon(canvas, view, day_phase, night_alpha)
	_draw_distant_cloud_banks(canvas, view, scroll_x, world_seed, day_mix, sunset, biome_sky)
	_draw_sun(canvas, view, day_phase, day_mix, sunset)

	var parallax := scroll_x * 0.04
	for i in 7:
		_draw_cloud(canvas, view, i, time_sec, parallax, day_mix, sunset)


func draw_resonant_deep(canvas: CanvasItem, view: Vector2, time_sec: float, scroll_x: float, world_seed: int, biome_id: String, biome_sky: Color) -> void:
	var top := biome_sky.darkened(0.58)
	var bottom := biome_sky.darkened(0.26)
	for band in 32:
		var y0 := floorf(float(band) * view.y / 32.0)
		var y1 := ceilf(float(band + 1) * view.y / 32.0)
		canvas.draw_rect(Rect2(0.0, y0, view.x, y1 - y0), top.lerp(bottom, float(band) / 31.0))
	var parallax := scroll_x * 0.018
	var seed_offset := posmod(world_seed, 4093)
	# Layered silhouettes read as distant cavern walls instead of outdoor clouds.
	for layer in 3:
		var cell := 32.0 + float(layer) * 13.0
		var columns := int(ceil(view.x / cell)) + 4
		var base_y := view.y * (0.42 + float(layer) * 0.13)
		var wall_color := Color("#111827").lerp(biome_sky.darkened(0.4), 0.34 + float(layer) * 0.12)
		for column in columns:
			var world_column := floori((float(column) * cell + parallax * (1.0 + layer)) / cell)
			var noise := _hash(world_column + seed_offset, 701 + layer * 37)
			var height := cell * (0.8 + noise * 2.1)
			var x := float(column - 2) * cell - fposmod(parallax * (1.0 + layer), cell)
			canvas.draw_rect(Rect2(floorf(x), floorf(base_y - height), ceilf(cell + 2.0), ceilf(height + view.y)), wall_color)
	# Each biome gets a cheap background motif made from a fixed number of simple
	# draw calls. These are visual only and never enter the world light map.
	if biome_id == "lumenroot_groves":
		for strand in 14:
			var hx := _hash(seed_offset + strand * 43, 811)
			var length := view.y * (0.08 + _hash(seed_offset + strand * 61, 877) * 0.18)
			var x := fposmod(hx * (view.x + 90.0) - scroll_x * 0.035, view.x + 90.0) - 45.0
			var pulse := 0.55 + 0.45 * sin(time_sec * 0.55 + hx * TAU)
			canvas.draw_rect(Rect2(floorf(x), 0.0, 3.0, floorf(length)), Color("#77e4ca", 0.13 + pulse * 0.08))
			canvas.draw_rect(Rect2(floorf(x - 2.0), floorf(length), 7.0, 3.0), Color("#b7ff8a", 0.22 + pulse * 0.12))
	elif biome_id == "glass_tide_caverns":
		for current in 9:
			var current_y := view.y * (0.16 + float(current) * 0.075)
			var wave_x := fposmod(scroll_x * 0.025 + float(current) * 53.0, 96.0)
			canvas.draw_line(Vector2(-96.0 + wave_x, current_y), Vector2(view.x + wave_x, current_y + 18.0), Color("#78cfe0", 0.09), 3.0)
	elif biome_id == "chorus_river":
		for current in 11:
			var current_y := view.y * (0.22 + float(current) * 0.052)
			var wave_x := fposmod(time_sec * 14.0 + float(current) * 37.0 - scroll_x * 0.03, 84.0)
			canvas.draw_line(Vector2(-84.0 + wave_x, current_y), Vector2(view.x + wave_x, current_y - 9.0), Color("#78f2df", 0.1), 2.0)
	elif biome_id == "inverted_orchard":
		for root in 13:
			var hx := _hash(seed_offset + root * 53, 867)
			var x := fposmod(hx * (view.x + 100.0) - scroll_x * 0.03, view.x + 100.0) - 50.0
			var length := view.y * (0.12 + _hash(root, 869) * 0.26)
			canvas.draw_line(Vector2(x, 0.0), Vector2(x + sin(hx * TAU) * 18.0, length), Color("#a776b0", 0.12), 5.0)
	elif biome_id == "bone_choir":
		for rib in 9:
			var x := float(rib) * view.x / 8.0 - fposmod(scroll_x * 0.018, view.x / 8.0)
			var height := view.y * (0.18 + _hash(seed_offset + rib, 871) * 0.2)
			canvas.draw_arc(Vector2(x, view.y), height, PI, TAU, 10, Color("#c8bccb", 0.09), 5.0)
	elif biome_id == "prism_chasm":
		for shard in 12:
			var hx := _hash(seed_offset + shard * 47, 853)
			var x := fposmod(hx * (view.x + 100.0) - scroll_x * 0.025, view.x + 100.0) - 50.0
			var height := view.y * (0.08 + _hash(seed_offset + shard * 31, 859) * 0.18)
			var color: Color = [Color("#b38cff"), Color("#ef86bd"), Color("#70e7bd")][shard % 3]
			canvas.draw_colored_polygon(PackedVector2Array([Vector2(x - 6.0, view.y), Vector2(x, view.y - height), Vector2(x + 7.0, view.y)]), Color(color, 0.09))
	else:
		for tower in 10:
			var hx := _hash(seed_offset + tower * 41, 883)
			var x := fposmod(hx * (view.x + 80.0) - scroll_x * 0.02, view.x + 80.0) - 40.0
			var height := view.y * (0.1 + _hash(seed_offset + tower * 67, 887) * 0.19)
			canvas.draw_rect(Rect2(x, view.y - height, 12.0, height), Color("#756386", 0.08))
			canvas.draw_rect(Rect2(x - 5.0, view.y - height, 22.0, 4.0), Color("#92d8c6", 0.08))
	for mote in 32:
		var hx := _hash(seed_offset + mote * 29, 929)
		var hy := _hash(seed_offset + mote * 47, 977)
		var drift := time_sec * (2.0 + _hash(mote, 991) * 3.0)
		var x := fposmod(hx * (view.x + 40.0) + drift - scroll_x * 0.006, view.x + 40.0) - 20.0
		var y := fposmod(hy * view.y - drift * 0.12, view.y)
		var mote_color := {
			"lumenroot_groves": Color("#9effc5"),
			"chorus_river": Color("#72f5df"),
			"glass_tide_caverns": Color("#91e8ff"),
			"prism_chasm": Color("#e3a2ff"),
			"magnetic_ruins": Color("#d8bf90"),
			"inverted_orchard": Color("#e0a7e7"),
			"bone_choir": Color("#ded4e4"),
			"shagot_lockworks": Color("#8ff3d5"),
		}.get(biome_id, Color("#91e8ff")) as Color
		canvas.draw_rect(Rect2(floorf(x), floorf(y), 2.0, 2.0), Color(mote_color, 0.16))


func draw_atmosphere(canvas: CanvasItem, view: Vector2, time_sec: float, scroll_x: float, world_seed: int, day_phase: float, daylight: float, biome_id: String, biome_sky: Color) -> void:
	var day_mix := clampf((daylight - 0.12) / 0.88, 0.0, 1.0)
	var sunset := _golden_hour(day_phase)
	var seed_offset := posmod(world_seed, 7919)
	var particle_count := 34 if biome_id in ["volcanic", "cavern"] else 24
	for i in particle_count:
		var hx := _hash(seed_offset + i * 37, 211)
		var hy := _hash(seed_offset + i * 53, 263)
		var hs := _hash(seed_offset + i * 71, 307)
		var drift := time_sec * (2.0 + hs * 4.0)
		var x := fposmod(hx * (view.x + 80.0) + drift - scroll_x * (0.004 + hs * 0.006), view.x + 80.0) - 40.0
		var y := fposmod(hy * (view.y + 70.0) - drift * (0.12 + hs * 0.2), view.y + 70.0) - 25.0
		var pulse := 0.55 + 0.45 * sin(time_sec * (0.8 + hs) + hx * TAU)
		var particle_color := Color("#ff6a24") if biome_id == "volcanic" else Color("#8deaff")
		if biome_id not in ["volcanic", "cavern"]:
			particle_color = biome_sky.lightened(0.48).lerp(Color("#ffd37a"), sunset * 0.72)
		var alpha := (0.035 + hs * 0.08) * (0.45 + pulse * 0.55)
		if biome_id == "volcanic":
			alpha *= 1.8
		elif biome_id == "cavern":
			alpha *= 1.35
		else:
			alpha *= 0.55 + day_mix * 0.45
		var size := 2.0 if hs < 0.78 else 3.0
		canvas.draw_rect(Rect2(floorf(x), floorf(y), size, size), Color(particle_color, alpha))
		if hs > 0.92:
			canvas.draw_rect(Rect2(floorf(x) - 2.0, floorf(y) + 1.0, size + 4.0, 1.0), Color(particle_color, alpha * 0.55))
			canvas.draw_rect(Rect2(floorf(x) + 1.0, floorf(y) - 2.0, 1.0, size + 4.0), Color(particle_color, alpha * 0.55))
	_draw_vignette(canvas, view, day_mix, sunset, biome_id)


func _draw_horizon_haze(canvas: CanvasItem, view: Vector2, day_mix: float, sunset: float, biome_sky: Color, daylight_tint: Color) -> void:
	var horizon := view.y * 0.44
	var height := view.y * 0.46
	var haze_color := biome_sky.lightened(0.38).lerp(daylight_tint, 0.5)
	haze_color = haze_color.lerp(Color("#ffb34f"), sunset * 0.92)
	for band in HAZE_BANDS:
		var t := float(band) / float(HAZE_BANDS)
		var concentration := clampf(1.0 - absf(t - 0.58) / 0.58, 0.0, 1.0)
		var alpha := concentration * (0.012 + day_mix * 0.024 + sunset * 0.085)
		var y := horizon + t * height
		canvas.draw_rect(Rect2(0.0, y, view.x, height / float(HAZE_BANDS) + 1.0), Color(haze_color, alpha))


func _draw_distant_cloud_banks(canvas: CanvasItem, view: Vector2, scroll_x: float, world_seed: int, day_mix: float, sunset: float, biome_sky: Color) -> void:
	var seed_offset := posmod(world_seed, 1009)
	for layer in 2:
		var cell := 12.0 + float(layer) * 4.0
		var base_y := view.y * (0.61 + float(layer) * 0.075)
		var columns := int(ceil(view.x / cell)) + 6
		var parallax := scroll_x * (0.008 + float(layer) * 0.006)
		var bank_color := Color("#26395f").lerp(biome_sky.lightened(0.25), day_mix * 0.72)
		bank_color = bank_color.lerp(Color("#d98282"), sunset * (0.58 - float(layer) * 0.12))
		var alpha := 0.15 + day_mix * 0.055 - float(layer) * 0.025
		for column in columns:
			var world_column := floori((float(column) * cell + parallax) / cell)
			var cluster := _hash(floori(float(world_column + seed_offset) / 5.0), 557 + layer * 43)
			if cluster < 0.34:
				continue
			var wave := sin(float(world_column + seed_offset) * 0.43 + float(layer) * 1.7)
			var broad_wave := sin(float(world_column + seed_offset) * 0.13 + 2.4)
			var noise := _hash(world_column + seed_offset, 401 + layer * 31)
			var stack := maxi(0, int(round(0.15 + wave * 1.0 + broad_wave * 1.15 + noise * 2.0)))
			var x := float(column - 3) * cell - fposmod(parallax, cell)
			for row in stack:
				var row_alpha := alpha * (0.72 + float(row) * 0.08)
				canvas.draw_rect(Rect2(floorf(x), floorf(base_y - float(row + 1) * cell * 0.58), ceilf(cell + 1.0), ceilf(cell * 0.62)), Color(bank_color, row_alpha))


func _golden_hour(day_phase: float) -> float:
	var sunset := 1.0 - absf(day_phase - 0.535) / 0.075
	var dawn_distance := minf(absf(day_phase - 0.982), 1.0 - absf(day_phase - 0.982))
	var dawn := 1.0 - dawn_distance / 0.075
	return clampf(maxf(sunset, dawn), 0.0, 1.0)


func _draw_vignette(canvas: CanvasItem, view: Vector2, day_mix: float, sunset: float, biome_id: String) -> void:
	var side_width := view.x * 0.105
	var top_height := view.y * 0.105
	var bottom_height := view.y * 0.125
	var strength := 0.17 if biome_id in ["cavern", "volcanic"] else 0.105
	strength += (1.0 - day_mix) * 0.035 - sunset * 0.018
	var shade := Color("#050914") if biome_id != "volcanic" else Color("#16080b")
	for band in VIGNETTE_BANDS:
		var outer := float(VIGNETTE_BANDS - band) / float(VIGNETTE_BANDS)
		var alpha := strength * outer * outer / float(VIGNETTE_BANDS) * 2.1
		var sx := float(band) * side_width / float(VIGNETTE_BANDS)
		var sw := side_width / float(VIGNETTE_BANDS) + 1.0
		var ty := float(band) * top_height / float(VIGNETTE_BANDS)
		var th := top_height / float(VIGNETTE_BANDS) + 1.0
		var by := view.y - float(band + 1) * bottom_height / float(VIGNETTE_BANDS)
		var bh := bottom_height / float(VIGNETTE_BANDS) + 1.0
		canvas.draw_rect(Rect2(sx, 0.0, sw, view.y), Color(shade, alpha))
		canvas.draw_rect(Rect2(view.x - sx - sw, 0.0, sw, view.y), Color(shade, alpha))
		canvas.draw_rect(Rect2(0.0, ty, view.x, th), Color(shade, alpha * 0.8))
		canvas.draw_rect(Rect2(0.0, by, view.x, bh), Color(shade, alpha))


func _draw_stars(canvas: CanvasItem, view: Vector2, time_sec: float, scroll_x: float, world_seed: int, alpha: float) -> void:
	var seed_offset := posmod(world_seed, 100003)
	for i in 72:
		var hx := _hash(i * 17 + seed_offset, 113)
		var hy := _hash(i * 29 + seed_offset, 157)
		var hs := _hash(i * 43 + seed_offset, 191)
		var x := fposmod(hx * view.x - scroll_x * (0.006 + hs * 0.008), view.x)
		var y := view.y * (0.035 + hy * 0.57)
		var twinkle := 0.72 + 0.28 * sin(time_sec * (0.9 + hs * 1.6) + hx * TAU)
		var star_alpha := alpha * twinkle * (0.62 + hs * 0.38)
		var size := 2.0 if hs < 0.72 else 3.0
		var color := Color(0.88 + hs * 0.12, 0.9 + hs * 0.1, 1.0, star_alpha)
		canvas.draw_rect(Rect2(floorf(x), floorf(y), size, size), color)
		if hs > 0.9:
			canvas.draw_rect(Rect2(floorf(x) - 2.0, floorf(y) + 1.0, size + 4.0, 1.0), Color(color, star_alpha * 0.65))
			canvas.draw_rect(Rect2(floorf(x) + 1.0, floorf(y) - 2.0, 1.0, size + 4.0), Color(color, star_alpha * 0.65))


func _draw_moon(canvas: CanvasItem, view: Vector2, day_phase: float, alpha: float) -> void:
	if day_phase < 0.5:
		return
	var u := clampf((day_phase - 0.5) / 0.5, 0.0, 1.0)
	var center := Vector2(
		view.x * lerpf(0.06, 0.94, u),
		view.y * (0.64 - sin(u * PI) * 0.5)
	)
	var pixel := maxf(3.0, floorf(view.y / 180.0))
	for my in range(-4, 5):
		for mx in range(-4, 5):
			if mx * mx + my * my > 17:
				continue
			var crater := _hash(mx + 17, my + 31)
			var moon_color := Color("#d7e6f5") if crater > 0.2 else Color("#9fb4cc")
			moon_color.a = alpha * 0.96
			canvas.draw_rect(Rect2(center + Vector2(mx, my) * pixel, Vector2.ONE * pixel), moon_color)


func _draw_sun(canvas: CanvasItem, view: Vector2, day_phase: float, alpha: float, sunset: float) -> void:
	if day_phase > 0.59 or alpha <= 0.01:
		return
	var u := clampf(day_phase / 0.575, 0.0, 1.0)
	var center := Vector2(
		view.x * lerpf(0.06, 0.94, u),
		view.y * (0.64 - sin(u * PI) * 0.5)
	)
	var sun_color := Color("#fff2a8").lerp(Color("#ffb24f"), sunset)
	sun_color.a = clampf(alpha + sunset * 0.35, 0.0, 1.0)
	var radius := maxf(18.0, view.y * 0.04)
	var ray_color := Color("#ffd06f").lerp(Color("#ff8250"), sunset)
	var ray_alpha := (0.018 + sunset * 0.028) * alpha
	canvas.draw_colored_polygon(PackedVector2Array([
		center + Vector2(-radius * 0.35, radius * 0.2),
		Vector2(maxf(0.0, center.x - view.x * 0.42), view.y),
		Vector2(minf(view.x, center.x + view.x * 0.12), view.y),
		center + Vector2(radius * 0.35, radius * 0.2),
	]), Color(ray_color, ray_alpha))
	for ring in range(9, 0, -1):
		var ring_t := float(ring) / 9.0
		var ring_radius := radius * (1.0 + ring_t * 7.5)
		var ring_alpha := (1.0 - ring_t * 0.76) * (0.018 + sunset * 0.022) * alpha
		canvas.draw_circle(center, ring_radius, Color(ray_color, ring_alpha))
	canvas.draw_circle(center, radius * 1.55, Color(ray_color, 0.14 * alpha))
	canvas.draw_circle(center, radius, sun_color)
	canvas.draw_circle(center - Vector2.ONE * radius * 0.16, radius * 0.46, Color("#fffbd0", minf(1.0, sun_color.a + 0.08)))


func _draw_cloud(canvas: CanvasItem, view: Vector2, index: int, time_sec: float, parallax: float, day_mix: float, sunset: float) -> void:
	var h0 := _hash(index, 11)
	var h1 := _hash(index, 29)
	var h2 := _hash(index, 47)
	var h3 := _hash(index, 71)

	var puff_count := 3 + int(h0 * 3.0)
	var puffs: Array[Dictionary] = []
	var min_x := 999.0
	var max_x := -999.0
	var min_y := 999.0
	var max_y := -999.0

	for p in puff_count:
		var ph0 := _hash(index * 19 + p, 23)
		var ph1 := _hash(index * 19 + p, 41)
		var ph2 := _hash(index * 19 + p, 67)
		var cx := (ph0 - 0.5) * (4.5 + h1 * 5.0)
		var cy := (ph1 - 0.55) * (1.6 + h2 * 1.8)
		var rx := 2.2 + ph2 * 2.8 + h0 * 1.2
		var ry := 1.4 + ph0 * 1.6 + h3 * 0.8
		puffs.append({"cx": cx, "cy": cy, "rx": rx, "ry": ry})
		min_x = minf(min_x, cx - rx)
		max_x = maxf(max_x, cx + rx)
		min_y = minf(min_y, cy - ry)
		max_y = maxf(max_y, cy + ry)

	var col0 := int(floor(min_x)) - 1
	var col1 := int(ceil(max_x)) + 1
	var row0 := int(floor(min_y)) - 1
	var row1 := int(ceil(max_y)) + 1
	var cloud_w := float(col1 - col0 + 1) * PIXEL
	var cloud_h := float(row1 - row0 + 1) * PIXEL

	var speed := (6.0 + h3 * 10.0) / 6.0
	var band := view.y * (0.06 + h0 * 0.26)
	var y := band + sin(time_sec * 0.018 + h1 * TAU) * (3.0 + h2 * 4.0)

	var pad := cloud_w + PIXEL * 6.0
	var span := view.x + pad * 2.0
	var x := fposmod(h2 * span + time_sec * speed - parallax * (0.5 + h3), span) - pad

	var edge := _edge_fade(x, cloud_w, view.x)
	if edge < 0.02:
		return

	var alpha := (0.5 + day_mix * 0.36 + h1 * 0.08) * edge
	var cloud_base := Color("#4b5879").lerp(Color.WHITE, day_mix).lerp(Color("#ffd0a0"), sunset * 0.72)
	var cloud_shade := Color("#303b5c").lerp(Color("#e0eaf3"), day_mix).lerp(Color("#b95d72"), sunset * 0.62)
	var color := Color(cloud_base, alpha)
	var shade := Color(cloud_shade, alpha * 0.72)

	for row in range(row0, row1 + 1):
		for col in range(col0, col1 + 1):
			var inside := false
			var bottomish := false
			for puff in puffs:
				var nx: float = (float(col) - float(puff["cx"])) / float(puff["rx"])
				var ny: float = (float(row) - float(puff["cy"])) / float(puff["ry"])
				var d2 := nx * nx + ny * ny
				var noise := _hash(index * 47 + row * 13 + col, 31) * 0.28
				if d2 <= 1.0 - noise * 0.35:
					inside = true
					if ny > 0.25:
						bottomish = true
			if not inside:
				continue
			var cell := _hash(index * 31 + row * 13 + col, 19)
			var px := x + float(col - col0) * PIXEL
			var py := y + float(row - row0) * PIXEL
			var fill := shade if bottomish or cell > 0.85 else color
			canvas.draw_rect(Rect2(px, py, PIXEL, PIXEL), fill)


func _edge_fade(x: float, w: float, view_w: float) -> float:
	var fade := maxf(w, PIXEL * 10.0)
	var from_left := clampf((x + w) / fade, 0.0, 1.0)
	var from_right := clampf((view_w - x) / fade, 0.0, 1.0)
	return minf(from_left, from_right)


func _hash(a: int, b: int) -> float:
	return float(((a * 374761 + b * 668265) & 0xffff)) / 65535.0
