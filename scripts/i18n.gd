class_name TinyBlockI18n
extends RefCounted

const DEFAULT_LOCALE := "en"
const SUPPORTED_LOCALES: PackedStringArray = [
	"en", "ja", "ko", "zh_Hans", "zh_Hant", "de", "fr", "es",
	"pt_BR", "it", "ar", "ru",
]


static func normalize_locale(locale: String) -> String:
	var raw := locale.strip_edges().replace("-", "_")
	if raw.is_empty():
		return DEFAULT_LOCALE
	var parts := raw.split("_", false)
	var language := parts[0].to_lower()
	if parts.size() == 1:
		return language
	var suffix := String(parts[1])
	if suffix.length() == 4:
		suffix = suffix.substr(0, 1).to_upper() + suffix.substr(1).to_lower()
	else:
		suffix = suffix.to_upper()
	return "%s_%s" % [language, suffix]


static func locale_candidates(locale: String) -> PackedStringArray:
	var normalized := normalize_locale(locale)
	var candidates := PackedStringArray()
	_add_unique(candidates, normalized)

	var language := normalized.get_slice("_", 0)
	if language == "zh":
		if normalized in ["zh_Hant", "zh_TW", "zh_HK", "zh_MO"]:
			_add_unique(candidates, "zh_Hant")
		else:
			_add_unique(candidates, "zh_Hans")
	elif language == "pt":
		_add_unique(candidates, "pt_BR")
	else:
		_add_unique(candidates, language)

	_add_unique(candidates, DEFAULT_LOCALE)
	return candidates


static func localized_value(values: Variant, locale: String = "", fallback: String = "") -> String:
	if not values is Dictionary:
		return fallback
	var translations := values as Dictionary
	var requested := locale if not locale.is_empty() else TranslationServer.get_locale()
	for candidate in locale_candidates(requested):
		for raw_key in translations.keys():
			if normalize_locale(str(raw_key)) != candidate:
				continue
			var value := str(translations[raw_key]).strip_edges()
			if not value.is_empty():
				return value
	return fallback


static func display_name(definition: Dictionary, locale: String = "") -> String:
	var fallback := str(definition.get("name", "")).strip_edges()
	var display: Dictionary = definition.get("display", {}) if definition.get("display", {}) is Dictionary else {}
	var localized_names: Variant = definition.get("localized_names", display.get("name", {}))
	if fallback.is_empty():
		fallback = localized_value(localized_names, DEFAULT_LOCALE, "")
	if fallback.is_empty():
		fallback = str(definition.get("slug", definition.get("id", ""))).strip_edges()
	if fallback.is_empty():
		fallback = str(definition.get("content_id", "")).strip_edges()
	if fallback.is_empty():
		fallback = TranslationServer.translate("ENTITY_UNKNOWN")
	return localized_value(localized_names, locale, fallback)


static func display_description(definition: Dictionary, locale: String = "") -> String:
	var fallback := str(definition.get("description", "")).strip_edges()
	var display: Dictionary = definition.get("display", {}) if definition.get("display", {}) is Dictionary else {}
	var localized_descriptions: Variant = definition.get("localized_descriptions", display.get("description", {}))
	if fallback.is_empty():
		fallback = localized_value(localized_descriptions, DEFAULT_LOCALE, "")
	return localized_value(localized_descriptions, locale, fallback)


static func is_rtl_locale(locale: String = "") -> bool:
	var requested := locale if not locale.is_empty() else TranslationServer.get_locale()
	return normalize_locale(requested).get_slice("_", 0) in ["ar", "fa", "he", "ur"]


static func _add_unique(values: PackedStringArray, value: String) -> void:
	if not values.has(value):
		values.append(value)
