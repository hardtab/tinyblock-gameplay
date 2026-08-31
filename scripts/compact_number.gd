class_name CompactNumber
extends RefCounted


static func format(value: int) -> String:
	var magnitude := absi(value)
	if magnitude >= 999_500_000:
		return _scaled(value, 1_000_000_000.0, "B", true)
	if magnitude >= 999_500:
		return _scaled(value, 1_000_000.0, "M", true)
	if magnitude >= 1_000:
		return _scaled(value, 1_000.0, "K", false)
	return str(value)


static func _scaled(value: int, divisor: float, suffix: String, precise: bool) -> String:
	var scaled := float(value) / divisor
	var magnitude := absf(scaled)
	var decimals := (2 if magnitude < 10.0 else (1 if magnitude < 100.0 else 0)) if precise else (1 if magnitude < 10.0 else 0)
	var text := "%.2f" % scaled if decimals == 2 else ("%.1f" % scaled if decimals == 1 else "%.0f" % scaled)
	while text.contains(".") and text.ends_with("0"):
		text = text.left(-1)
	if text.ends_with("."):
		text = text.left(-1)
	return text + suffix
