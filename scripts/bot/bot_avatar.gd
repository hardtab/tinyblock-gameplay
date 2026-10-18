extends RefCounted

const AvatarArt = preload("res://gameplay/scripts/avatar_art.gd")

const SKIN_TONES: PackedStringArray = [
	"#f8dcc4", "#f2c7a5", "#e8b184", "#d99a6c", "#c98255",
	"#ae6842", "#8d5135", "#70402d", "#563225", "#3d251d",
]
const HAIR_COLORS: PackedStringArray = [
	"#23170f", "#3a2417", "#5a3822", "#754c2d", "#9a6538", "#c89452", "#2e2522", "#6b2d2d",
]


static func random_appearance(rng: RandomNumberGenerator, previous: Variant = {}) -> Dictionary:
	var generator := rng
	if generator == null:
		generator = RandomNumberGenerator.new()
		generator.randomize()

	var hue := generator.randf()
	var shirt := Color.from_hsv(hue, generator.randf_range(0.5, 0.9), generator.randf_range(0.65, 0.98))
	var appearance: Dictionary = AvatarArt.DEFAULT_APPEARANCE.duplicate(true)
	appearance.merge({
		"skin": SKIN_TONES[generator.randi_range(0, SKIN_TONES.size() - 1)],
		"shirt": shirt.to_html(false),
		"shirt_dark": shirt.darkened(0.28).to_html(false),
		"accent": Color.from_hsv(fposmod(hue + generator.randf_range(0.25, 0.65), 1.0), 0.65, 1.0).to_html(false),
		"pants": shirt.darkened(0.55).lerp(Color("#342c28"), 0.3).to_html(false),
		"hair": HAIR_COLORS[generator.randi_range(0, HAIR_COLORS.size() - 1)],
	}, true)
	for key in AvatarArt.ENUM_OPTIONS:
		var values: Array = AvatarArt.ENUM_OPTIONS[key]
		appearance[key] = values[generator.randi_range(0, values.size() - 1)]
	appearance = AvatarArt.normalize_appearance(appearance)

	if previous is Dictionary and not (previous as Dictionary).is_empty():
		var previous_appearance := AvatarArt.normalize_appearance(previous)
		if appearance == previous_appearance:
			# A collision is extraordinarily unlikely because colors are generated
			# continuously, but make consecutive joins distinct by construction.
			var body_shapes: Array = AvatarArt.ENUM_OPTIONS["body_shape"]
			var previous_shape := str(previous_appearance.get("body_shape", body_shapes[0]))
			var next_shape_index := (body_shapes.find(previous_shape) + 1) % body_shapes.size()
			appearance["body_shape"] = body_shapes[next_shape_index]

	return appearance
