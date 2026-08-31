extends RefCounted

const BUBBLE_SECONDS := 3.0
const SEND_COOLDOWN_MSEC := 450
const MAX_TEXT_LENGTH := 8
const DEFAULT_EMOJIS: PackedStringArray = [
	"😀", "😂", "🥰", "😎", "🤔", "😭", "😡", "😱",
	"👍", "👎", "👏", "🙏", "💪", "👋", "❤️", "🔥",
	"🎉", "✨", "💯", "✅", "❓", "💡", "🏠", "⛏️",
]


const EMOJI_TEXTURE_PATHS := {
	"😀": "res://gameplay/assets/emoji/emoji_u1f600.svg", "😂": "res://gameplay/assets/emoji/emoji_u1f602.svg",
	"🥰": "res://gameplay/assets/emoji/emoji_u1f970.svg", "😎": "res://gameplay/assets/emoji/emoji_u1f60e.svg",
	"🤔": "res://gameplay/assets/emoji/emoji_u1f914.svg", "😭": "res://gameplay/assets/emoji/emoji_u1f62d.svg",
	"😡": "res://gameplay/assets/emoji/emoji_u1f621.svg", "😱": "res://gameplay/assets/emoji/emoji_u1f631.svg",
	"👍": "res://gameplay/assets/emoji/emoji_u1f44d.svg", "👎": "res://gameplay/assets/emoji/emoji_u1f44e.svg",
	"👏": "res://gameplay/assets/emoji/emoji_u1f44f.svg", "🙏": "res://gameplay/assets/emoji/emoji_u1f64f.svg",
	"💪": "res://gameplay/assets/emoji/emoji_u1f4aa.svg", "👋": "res://gameplay/assets/emoji/emoji_u1f44b.svg",
	"❤️": "res://gameplay/assets/emoji/emoji_u2764.svg", "🔥": "res://gameplay/assets/emoji/emoji_u1f525.svg",
	"🎉": "res://gameplay/assets/emoji/emoji_u1f389.svg", "✨": "res://gameplay/assets/emoji/emoji_u2728.svg",
	"💯": "res://gameplay/assets/emoji/emoji_u1f4af.svg", "✅": "res://gameplay/assets/emoji/emoji_u2705.svg",
	"❓": "res://gameplay/assets/emoji/emoji_u2753.svg", "💡": "res://gameplay/assets/emoji/emoji_u1f4a1.svg",
	"🏠": "res://gameplay/assets/emoji/emoji_u1f3e0.svg", "⛏️": "res://gameplay/assets/emoji/emoji_u26cf.svg",
	"💬": "res://gameplay/assets/emoji/emoji_u1f4ac.svg",
}


static func texture_for(emoji: String) -> Texture2D:
	var path := str(EMOJI_TEXTURE_PATHS.get(emoji, ""))
	return load(path) as Texture2D if not path.is_empty() else null


static func sanitize(raw_value: Variant) -> String:
	var value := str(raw_value).strip_edges()
	if value.is_empty() or value.length() > MAX_TEXT_LENGTH:
		return ""
	return value if EMOJI_TEXTURE_PATHS.has(value) else ""


static func most_used(usage: Dictionary, limit: int = 3) -> Array[String]:
	var entries: Array[Dictionary] = []
	for raw_emoji in usage:
		var emoji := sanitize(raw_emoji)
		if emoji.is_empty() or not usage[raw_emoji] is Dictionary:
			continue
		var stats := usage[raw_emoji] as Dictionary
		entries.append({
			"emoji": emoji,
			"count": maxi(0, int(stats.get("count", 0))),
			"last_used": maxi(0, int(stats.get("last_used", 0))),
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["count"]) != int(b["count"]):
			return int(a["count"]) > int(b["count"])
		return int(a["last_used"]) > int(b["last_used"])
	)
	var result: Array[String] = []
	for entry in entries:
		if result.size() >= maxi(0, limit):
			break
		result.append(str(entry["emoji"]))
	return result
