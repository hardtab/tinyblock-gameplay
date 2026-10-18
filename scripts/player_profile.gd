extends Node

const PROFILE_VERSION := 1
const DEFAULT_PROFILE_PATH := "user://player_profile.json"
const SKIN_TONES: PackedStringArray = [
	"#f8dcc4", "#f2c7a5", "#e8b184", "#d99a6c", "#c98255",
	"#ae6842", "#8d5135", "#70402d", "#563225", "#3d251d",
]
const CLOTHING_COLORS: PackedStringArray = [
	"#e4572e", "#f59e0b", "#65a30d", "#159d91", "#168aad", "#2563eb",
	"#6d5bd0", "#a855f7", "#d9468f", "#dc4b4b", "#64748b", "#8b5a2b",
]
const HAIR_COLORS: PackedStringArray = [
	"#23170f", "#3a2417", "#5a3822", "#754c2d", "#9a6538", "#c89452", "#2e2522", "#6b2d2d",
]
const COLOR_KEYS: PackedStringArray = ["skin", "shirt", "shirt_dark", "accent", "pants", "hair"]
const ENUM_OPTIONS := {
	"body_shape": ["classic", "round", "boxy"],
	"antenna": ["none", "sprout", "twin"],
	"arms": ["classic", "long", "tiny"],
	"legs": ["classic", "short", "spring"],
	"face": ["none", "mustache", "whiskers"],
	"particles": ["none", "flowers", "fireflies", "stars", "sparks", "fire"],
}

signal appearance_changed(skin: Dictionary)

var profile_path := DEFAULT_PROFILE_PATH
var profile_id := ""
var skin: Dictionary = {}


func _init(custom_profile_path: String = "") -> void:
	if not custom_profile_path.is_empty():
		profile_path = custom_profile_path


func _ready() -> void:
	load_or_create()


func load_or_create() -> void:
	if _load_profile():
		return
	profile_id = Crypto.new().generate_random_bytes(16).hex_encode()
	skin = _with_appearance_defaults(_skin_from_id(profile_id), profile_id)
	_save_profile()


func color(key: String) -> Color:
	var fallback: String = str({
		"skin": "#e8b184",
		"shirt": "#159d91",
		"shirt_dark": "#0f746c",
		"accent": "#f59e0b",
		"pants": "#4a3426",
		"hair": "#3a2417",
	}.get(key, "#ffffff"))
	return Color.from_string(str(skin.get(key, fallback)), Color.from_string(str(fallback), Color.WHITE))


func _skin_from_id(id: String) -> Dictionary:
	var skin_index := posmod((id + ":skin").hash(), SKIN_TONES.size())
	var shirt_index := posmod((id + ":shirt").hash(), CLOTHING_COLORS.size())
	var accent_offset := 3 + posmod((id + ":accent").hash(), CLOTHING_COLORS.size() - 4)
	var accent_index := posmod(shirt_index + accent_offset, CLOTHING_COLORS.size())
	var hair_index := posmod((id + ":hair").hash(), HAIR_COLORS.size())
	var shirt := Color.from_string(CLOTHING_COLORS[shirt_index], Color("#159d91"))
	var accent := Color.from_string(CLOTHING_COLORS[accent_index], Color("#f59e0b"))
	var pants := shirt.darkened(0.52).lerp(Color("#3d3028"), 0.35)
	return {
		"skin": SKIN_TONES[skin_index],
		"shirt": shirt.to_html(false),
		"shirt_dark": shirt.darkened(0.28).to_html(false),
		"accent": accent.lightened(0.08).to_html(false),
		"pants": pants.to_html(false),
		"hair": HAIR_COLORS[hair_index],
		"body_shape": "classic",
		"antenna": "none",
		"arms": "classic",
		"legs": "classic",
		"face": "none",
		"particles": "none",
	}


func _load_profile() -> bool:
	if not FileAccess.file_exists(profile_path):
		return false
	var file := FileAccess.open(profile_path, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or int(parsed.get("version", -1)) != PROFILE_VERSION:
		return false
	var loaded_id := str(parsed.get("profile_id", ""))
	var loaded_skin = parsed.get("skin", null)
	if loaded_id.length() < 16 or not loaded_skin is Dictionary:
		return false
	for key in COLOR_KEYS:
		if not (loaded_skin as Dictionary).has(key) or not Color.html_is_valid(str((loaded_skin as Dictionary)[key])):
			return false
	var migrated_skin := _with_appearance_defaults(loaded_skin as Dictionary, loaded_id)
	profile_id = loaded_id
	skin = migrated_skin
	# Older profiles contain only colors. Save once after loading so the new
	# appearance fields survive the next launch without changing their colors.
	if migrated_skin != loaded_skin:
		_save_profile()
	return true


func _save_profile() -> bool:
	var file := FileAccess.open(profile_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"version": PROFILE_VERSION, "profile_id": profile_id, "skin": skin}))
	file.flush()
	file.close()
	return true


func set_appearance_value(key: String, value: Variant) -> bool:
	var previous_value: Variant = skin.get(key, null)
	if key in COLOR_KEYS:
		var color_value := ""
		if value is Color:
			var picker_color: Color = value
			color_value = picker_color.to_html(false)
		else:
			color_value = str(value).strip_edges()
		if not Color.html_is_valid(color_value):
			return false
		color_value = Color.from_string(color_value, Color.WHITE).to_html(false)
		if str(skin.get(key, "")) == color_value:
			return true
		skin[key] = color_value
	elif ENUM_OPTIONS.has(key):
		var enum_value := str(value)
		if enum_value not in ENUM_OPTIONS[key]:
			return false
		if str(skin.get(key, "")) == enum_value:
			return true
		skin[key] = enum_value
	else:
		return false
	if not _save_profile():
		if previous_value == null:
			skin.erase(key)
		else:
			skin[key] = previous_value
		return false
	appearance_changed.emit(skin.duplicate(true))
	return true


func _with_appearance_defaults(loaded_skin: Dictionary, id: String) -> Dictionary:
	var migrated := _skin_from_id(id)
	for key in COLOR_KEYS:
		if loaded_skin.has(key) and Color.html_is_valid(str(loaded_skin[key])):
			migrated[key] = str(loaded_skin[key])
	for key in ENUM_OPTIONS:
		var allowed: Array = ENUM_OPTIONS[key]
		if loaded_skin.has(key) and str(loaded_skin[key]) in allowed:
			migrated[key] = str(loaded_skin[key])
	return migrated
