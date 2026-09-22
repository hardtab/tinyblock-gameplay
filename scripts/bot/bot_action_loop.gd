class_name BotActionLoop
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")

const STREAK_LIMIT := 5
const COOLDOWN_MSEC := 10_000

## Actions that must stay available so the bot can recover from a bad streak.
const ALWAYS_LEGAL: PackedStringArray = [
	Contract.ACTION_WAIT,
	Contract.ACTION_LOOK_AT,
]

## Social chase actions alternate in the rule provider; treat them as one streak
## so MOVE_NEAR_PLAYER ↔ FOLLOW cannot bypass the cooldown forever.
const SOCIAL_MOVE_FAMILY: PackedStringArray = [
	Contract.ACTION_MOVE_NEAR_PLAYER,
	Contract.ACTION_FOLLOW,
]


static func _streak_family(action: String) -> PackedStringArray:
	if action in SOCIAL_MOVE_FAMILY:
		return SOCIAL_MOVE_FAMILY
	return PackedStringArray([action])


static func consecutive_started_streak(history: Array, action: String) -> int:
	if action.is_empty():
		return 0
	var family := _streak_family(action)
	var streak := 0
	for index in range(history.size() - 1, -1, -1):
		if not history[index] is Dictionary:
			continue
		var entry := history[index] as Dictionary
		if str(entry.get("phase", "")) != "started":
			continue
		if str(entry.get("action", "")) not in family:
			break
		streak += 1
	return streak


static func refresh_blocked_actions(
	history: Array,
	blocked_until: Dictionary,
	now_msec: int,
) -> Dictionary:
	var result := blocked_until.duplicate(true)
	for raw_action in result.keys():
		if now_msec >= int(result[raw_action]):
			result.erase(raw_action)
	for raw_action in Contract.ALL_ACTIONS:
		var action := str(raw_action)
		if action in ALWAYS_LEGAL:
			continue
		if consecutive_started_streak(history, action) >= STREAK_LIMIT:
			var until := maxi(int(result.get(action, 0)), now_msec + COOLDOWN_MSEC)
			for related in _streak_family(action):
				result[str(related)] = maxi(int(result.get(str(related), 0)), until)
	return result


static func filter_legal_actions(
	all_actions: Variant,
	blocked_until: Dictionary,
	now_msec: int,
) -> PackedStringArray:
	var normalized := Contract.normalize_legal_actions(all_actions)
	if normalized.is_empty():
		normalized = Contract.ALL_ACTIONS.duplicate()
	var filtered := PackedStringArray()
	for raw_action in normalized:
		var action := str(raw_action)
		if now_msec < int(blocked_until.get(action, 0)):
			continue
		filtered.append(action)
	for fallback in ALWAYS_LEGAL:
		if fallback not in filtered:
			filtered.append(fallback)
	return filtered


static func active_blocks(blocked_until: Dictionary, now_msec: int) -> Array[String]:
	var active: Array[String] = []
	for raw_action in blocked_until.keys():
		var action := str(raw_action)
		if now_msec < int(blocked_until.get(action, 0)):
			active.append(action)
	return active
