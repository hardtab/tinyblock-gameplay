class_name BotSocial
extends RefCounted

const EmojiReactions = preload("res://gameplay/scripts/emoji_reactions.gd")

const TRANSPORT_COOLDOWN_MSEC := EmojiReactions.SEND_COOLDOWN_MSEC
## Keep reactions sparse. A short social cooldown still let the bot feel chatty
## once the send gate raced ahead of the cooldown bookkeeping.
const SOCIAL_COOLDOWN_MSEC := 45_000


func emoji_can_send(last_sent_msec: int, now_msec: int, emoji: String, previous_emoji: String = "", social_last_sent_msec: int = -1) -> bool:
	var sanitized := EmojiReactions.sanitize(emoji)
	if sanitized.is_empty():
		return false
	# Never repeat the immediately previous reaction. Players already saw it.
	if not previous_emoji.is_empty() and sanitized == previous_emoji:
		return false
	if last_sent_msec >= 0 and now_msec - last_sent_msec < TRANSPORT_COOLDOWN_MSEC:
		return false
	if social_last_sent_msec >= 0 and now_msec - social_last_sent_msec < SOCIAL_COOLDOWN_MSEC:
		return false
	return true


func can_send_emoji(last_sent_msec: int, now_msec: int, emoji: String, previous_emoji: String = "", social_last_sent_msec: int = -1) -> bool:
	return emoji_can_send(last_sent_msec, now_msec, emoji, previous_emoji, social_last_sent_msec)


func is_emoji_allowed(last_sent_msec: int, now_msec: int, emoji: String, previous_emoji: String = "", social_last_sent_msec: int = -1) -> bool:
	return emoji_can_send(last_sent_msec, now_msec, emoji, previous_emoji, social_last_sent_msec)


static func context_emoji(event_name: String) -> String:
	match event_name:
		"joined", "player_near", "goodbye":
			return "👋"
		"helped", "gifted":
			return "👍"
		"blocked", "stuck":
			return "🤔"
		"attacked":
			return "😡"
		"danger":
			return "😱"
		"victory":
			return "🎉"
	return ""


## Fallback reply when no remote model is configured. Maps an incoming player
## emoji to one allowed response so the bot still answers social signals.
static func reply_emoji(incoming_emoji: String) -> String:
	var incoming := EmojiReactions.sanitize(incoming_emoji)
	if incoming.is_empty():
		return "👋"
	match incoming:
		"👋", "🥰", "😀", "😎":
			return "👋"
		"😂", "🎉", "✨", "🔥", "💯":
			return "😂"
		"👍", "👏", "🙏", "💪", "✅":
			return "👍"
		"❤️":
			return "❤️"
		"🤔", "❓", "💡":
			return "🤔"
		"😭", "😱":
			return "🥰"
		"😡", "👎":
			return "🤔"
		"⛏️", "🏠":
			return "👍"
	if incoming in EmojiReactions.DEFAULT_EMOJIS:
		return "👋"
	return "👋"
