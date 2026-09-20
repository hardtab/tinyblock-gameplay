class_name BotSafetyPolicy
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const EmojiReactions = preload("res://gameplay/scripts/emoji_reactions.gd")

const DEFAULT_RETALIATION_WINDOW_MSEC := 10_000
const DEFAULT_MAX_RETALIATIONS := 1
const LOW_HEALTH_RATIO := 0.35

var retaliation_window_msec := DEFAULT_RETALIATION_WINDOW_MSEC
var max_retaliations := DEFAULT_MAX_RETALIATIONS
var response_enabled := true
var _attacker_player_id := ""
var _attacker_seen_msec := -1
var _retaliations_used := 0


func reset_session() -> void:
	_attacker_player_id = ""
	_attacker_seen_msec = -1
	_retaliations_used = 0


func record_player_hit(payload: Dictionary, own_player_id: String, now_msec: int) -> bool:
	if str(payload.get("target_player_id", "")) != own_player_id:
		return false
	var attacker := str(payload.get("attacker_player_id", ""))
	var damage := int(payload.get("damage", 0))
	# A legacy player_hit without attacker metadata is intentionally not enough
	# to authorize PvP.  The bot may flee, but it cannot guess a target.
	if attacker.is_empty() or attacker == own_player_id or damage <= 0:
		return false
	_attacker_player_id = attacker
	_attacker_seen_msec = now_msec
	_retaliations_used = 0
	return true


func attacker_player_id() -> String:
	return _attacker_player_id


func can_retaliate(target_player_id: String, now_msec: int) -> bool:
	return response_enabled and defensive_window_active(
		_attacker_player_id,
		_attacker_seen_msec,
		target_player_id,
		now_msec,
		retaliation_window_msec,
	) and _retaliations_used < max_retaliations


func consume_retaliation(target_player_id: String, now_msec: int) -> bool:
	if not can_retaliate(target_player_id, now_msec):
		return false
	_retaliations_used += 1
	return true


func observation_state(now_msec: int) -> Dictionary:
	return {
		"attacker_player_id": _attacker_player_id,
		"attacker_seen_msec": _attacker_seen_msec,
		"retaliations_used": _retaliations_used,
		"can_retaliate": can_retaliate(_attacker_player_id, now_msec),
	}


func approve_decision(raw_decision: Variant, observation: Dictionary, now_msec: int) -> Dictionary:
	if raw_decision is Dictionary:
		var raw_action := str((raw_decision as Dictionary).get("action", Contract.ACTION_WAIT)).strip_edges().to_upper()
		if not Contract.is_known_action(raw_action):
			return _rejected(raw_decision as Dictionary, "action_unknown")
	var decision := Contract.normalize_decision(raw_decision)
	var action := str(decision.get("action", Contract.ACTION_WAIT))
	var legal := Contract.normalize_legal_actions(observation.get("legal_actions", Contract.ALL_ACTIONS))
	if legal.is_empty():
		legal = PackedStringArray([Contract.ACTION_WAIT])
	if action not in legal:
		return _rejected(decision, "action_not_legal")

	var target_id := str(decision.get("target_id", ""))
	match action:
		Contract.ACTION_RETALIATE_ONCE:
			if not can_retaliate(target_id, now_msec):
				return _rejected(decision, "no_active_direct_hit")
			if not _player_is_near(observation, target_id, float(observation.get("retaliation_distance", 52.0))):
				return _rejected(decision, "attacker_out_of_range")
		Contract.ACTION_ATTACK_CREATURE:
			if not _target_exists(observation.get("threats", []), target_id):
				return _rejected(decision, "creature_target_not_visible")
		Contract.ACTION_FLEE_FROM:
			if target_id.is_empty() and _first_target_id(observation.get("threats", []), target_id).is_empty():
				return _rejected(decision, "flee_target_missing")
		Contract.ACTION_MINE:
			if not _reachable_resource_exists(observation.get("visible_resources", []), target_id):
				return _rejected(decision, "mine_target_not_reachable")
		Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_FOLLOW, Contract.ACTION_LOOK_AT:
			if not _target_exists(observation.get("players", []), target_id):
				return _rejected(decision, "player_target_not_visible")
		Contract.ACTION_SEND_EMOJI:
			var emoji := EmojiReactions.sanitize(decision.get("emoji", ""))
			if emoji.is_empty():
				return _rejected(decision, "emoji_not_allowed")
			decision["emoji"] = emoji
		Contract.ACTION_PLACE:
			if str(decision.get("block", "")).is_empty() or not decision.has("target"):
				return _rejected(decision, "place_target_missing")
		Contract.ACTION_WAIT, Contract.ACTION_MOVE_TO:
			pass

	return {"allowed": true, "decision": decision, "reason": ""}


func is_low_health(self_state: Dictionary) -> bool:
	var maximum := maxi(1, int(self_state.get("max_health", 10)))
	return float(int(self_state.get("health", maximum))) / float(maximum) <= LOW_HEALTH_RATIO


static func defensive_window_active(attacker_player_id: String, hit_msec: int, target_player_id: String, now_msec: int, window_msec: int = DEFAULT_RETALIATION_WINDOW_MSEC) -> bool:
	return (
		not attacker_player_id.is_empty()
		and attacker_player_id == target_player_id
		and hit_msec >= 0
		and now_msec >= hit_msec
		and now_msec - hit_msec <= maxi(0, window_msec)
	)


func _rejected(decision: Dictionary, reason: String) -> Dictionary:
	return {"allowed": false, "decision": Contract.normalize_decision({"action": Contract.ACTION_WAIT, "goal": Contract.GOAL_IDLE, "commit_for_ms": 700}), "rejected": decision, "reason": reason}


func _player_is_near(observation: Dictionary, player_id: String, max_distance: float) -> bool:
	for raw_player in _as_array(observation.get("players", [])):
		if not raw_player is Dictionary:
			continue
		var player := raw_player as Dictionary
		if str(player.get("id", "")) == player_id:
			return float(player.get("distance", 9999.0)) <= max_distance
	return false


func _target_exists(raw_targets: Variant, target_id: String) -> bool:
	if target_id.is_empty():
		return false
	for raw_target in _as_array(raw_targets):
		if raw_target is Dictionary and str((raw_target as Dictionary).get("id", "")) == target_id:
			return true
	return false


func _reachable_resource_exists(raw_targets: Variant, target_id: String) -> bool:
	for raw_target in _as_array(raw_targets):
		if not raw_target is Dictionary:
			continue
		var target := raw_target as Dictionary
		if str(target.get("id", "")) == target_id:
			return bool(target.get("reachable", false))
	return false


func _first_target_id(raw_targets: Variant, fallback: String) -> String:
	for raw_target in _as_array(raw_targets):
		if raw_target is Dictionary:
			var candidate := str((raw_target as Dictionary).get("id", ""))
			if not candidate.is_empty():
				return candidate
	return fallback


func _as_array(value: Variant) -> Array:
	return value as Array if value is Array else []
