class_name TinyBlockBotContract
extends RefCounted

## Shared, transport-independent contracts for the Tiny Block bot.
##
## The bot brain is intentionally limited to these high-level actions.  A
## provider may suggest one of them, but the safety policy and executor are the
## only layers allowed to turn a suggestion into a network command.

const ACTION_WAIT := "WAIT"
const ACTION_LOOK_AT := "LOOK_AT"
const ACTION_MOVE_NEAR_PLAYER := "MOVE_NEAR_PLAYER"
const ACTION_MOVE_TO := "MOVE_TO"
const ACTION_FOLLOW := "FOLLOW"
const ACTION_MINE := "MINE"
const ACTION_PLACE := "PLACE"
const ACTION_ATTACK_CREATURE := "ATTACK_CREATURE"
const ACTION_FIRE_BOW := "FIRE_BOW"
const ACTION_FLEE_FROM := "FLEE_FROM"
const ACTION_RETALIATE_ONCE := "RETALIATE_ONCE"
const ACTION_ATTACK_PLAYER := "ATTACK_PLAYER"
const ACTION_SEND_EMOJI := "SEND_EMOJI"
const ACTION_CRAFT := "CRAFT"
const ACTION_EQUIP := "EQUIP"
const ACTION_OPEN_CONTAINER := "OPEN_CONTAINER"

const GOAL_IDLE := "IDLE"
const GOAL_SOCIAL_FOLLOW := "SOCIAL_FOLLOW"
const GOAL_EXPLORE := "EXPLORE"
const GOAL_GATHER := "GATHER"
const GOAL_BUILD := "BUILD"
const GOAL_CRAFT := "CRAFT"
const GOAL_ACHIEVEMENT := "ACHIEVEMENT"
const GOAL_DIG_ROUTE := "DIG_ROUTE"
const GOAL_SURVIVE := "SURVIVE"
const GOAL_SELF_DEFENSE := "SELF_DEFENSE"
const MIN_SUPPORTED_CLIENT_VERSION := "1.4.2"

const ALL_ACTIONS: PackedStringArray = [
	ACTION_WAIT,
	ACTION_LOOK_AT,
	ACTION_MOVE_NEAR_PLAYER,
	ACTION_MOVE_TO,
	ACTION_FOLLOW,
	ACTION_MINE,
	ACTION_PLACE,
	ACTION_ATTACK_CREATURE,
	ACTION_FIRE_BOW,
	ACTION_FLEE_FROM,
	ACTION_RETALIATE_ONCE,
	ACTION_ATTACK_PLAYER,
	ACTION_SEND_EMOJI,
	ACTION_CRAFT,
	ACTION_EQUIP,
	ACTION_OPEN_CONTAINER,
]

const SOCIAL_EMOJIS: PackedStringArray = [
	"😀", "🤔", "😡", "👍", "💪", "👋", "❤️", "🎉", "❓", "⛏️",
]


static func is_known_action(action: String) -> bool:
	return action in ALL_ACTIONS


static func normalize_legal_actions(raw: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if not raw is Array and not raw is PackedStringArray:
		return result
	for raw_action in raw:
		var action := str(raw_action).strip_edges().to_upper()
		if is_known_action(action) and action not in result:
			result.append(action)
	return result


static func normalize_decision(raw: Variant, fallback_action: String = ACTION_WAIT) -> Dictionary:
	var decision: Dictionary = raw.duplicate(true) if raw is Dictionary else {}
	var action := str(decision.get("action", fallback_action)).strip_edges().to_upper()
	if not is_known_action(action):
		action = fallback_action if is_known_action(fallback_action) else ACTION_WAIT
	decision["action"] = action
	decision["goal"] = str(decision.get("goal", GOAL_IDLE)).strip_edges().to_upper()
	decision["target_id"] = str(decision.get("target_id", ""))
	decision["emoji"] = str(decision.get("emoji", ""))
	decision["commit_for_ms"] = clampi(int(decision.get("commit_for_ms", 0)), 0, 30_000)
	decision["confidence"] = clampf(float(decision.get("confidence", 0.0)), 0.0, 1.0)
	return decision


static func target_position(raw: Variant) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Vector2i:
		return Vector2(raw)
	if raw is Array and raw.size() >= 2:
		return Vector2(float(raw[0]), float(raw[1]))
	if raw is Dictionary:
		var value := raw as Dictionary
		if value.has("position"):
			return target_position(value.get("position"))
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	return Vector2.ZERO


static func distance_between(a: Variant, b: Variant) -> float:
	return target_position(a).distance_to(target_position(b))


static func client_version_at_least(version: String, minimum: String = MIN_SUPPORTED_CLIENT_VERSION) -> bool:
	var actual := _version_parts(version)
	var required := _version_parts(minimum)
	if actual.is_empty() or required.is_empty():
		return false
	for index in range(maxi(actual.size(), required.size())):
		var actual_part := int(actual[index]) if index < actual.size() else 0
		var required_part := int(required[index]) if index < required.size() else 0
		if actual_part != required_part:
			return actual_part > required_part
	return true


static func _version_parts(version: String) -> Array[int]:
	var normalized := version.strip_edges().split("-", false, 1)[0]
	var parts: Array[int] = []
	for raw_part in normalized.split("."):
		if raw_part.is_empty() or not raw_part.is_valid_int():
			return []
		parts.append(int(raw_part))
	return parts if parts.size() >= 2 else []
