class_name BotBehavior
extends RefCounted

signal decision_proposed(decision: Dictionary)
signal decision_rejected(decision: Dictionary, reason: String)
signal decision_started(decision: Dictionary)
signal goal_changed(goal: String)

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const BotDecisionProviderClass = preload("res://gameplay/scripts/bot/bot_decision_provider.gd")
const BotRuleProviderClass = preload("res://gameplay/scripts/bot/bot_rule_provider.gd")
const BotSafetyPolicyClass = preload("res://gameplay/scripts/bot/bot_safety_policy.gd")
const BotExecutorClass = preload("res://gameplay/scripts/bot/bot_executor.gd")

const DEFAULT_DECISION_INTERVAL_MSEC := 900
const REJECTION_RETRY_MSEC := 350
const AGGRESSIVE_PLAYER_DECISION_INTERVAL_MSEC := 450
const AGGRESSIVE_PLAYER_COMMIT_SCALE := 0.5
const AGGRESSIVE_PLAYER_COMMIT_MIN_MSEC := 250
const AGGRESSIVE_PLAYER_ACTIONS: PackedStringArray = [
	Contract.ACTION_MOVE_NEAR_PLAYER,
	Contract.ACTION_MOVE_TO,
	Contract.ACTION_FOLLOW,
	Contract.ACTION_PLACE,
	Contract.ACTION_FIRE_BOW,
	Contract.ACTION_RETALIATE_ONCE,
	Contract.ACTION_ATTACK_PLAYER,
	Contract.ACTION_EQUIP,
]

var provider: BotDecisionProvider
var safety: BotSafetyPolicy
var executor: BotExecutor
var decision_interval_msec := DEFAULT_DECISION_INTERVAL_MSEC
var _next_decision_msec := 0
var _last_goal := ""


func _init(
	decision_provider: BotDecisionProvider = null,
	safety_policy: BotSafetyPolicy = null,
	action_executor: BotExecutor = null,
) -> void:
	provider = decision_provider if decision_provider != null else BotRuleProviderClass.new()
	safety = safety_policy if safety_policy != null else BotSafetyPolicyClass.new()
	executor = action_executor if action_executor != null else BotExecutorClass.new()


func request_decision(now_msec: int = 0) -> void:
	_next_decision_msec = now_msec


func reset(now_msec: int = 0) -> void:
	executor.cancel("behavior_reset")
	safety.reset_session()
	if provider != null and provider.has_method("reset"):
		provider.call("reset")
	_last_goal = ""
	_next_decision_msec = now_msec


func tick(observation: Dictionary, delta: float, now_msec: int) -> void:
	# Mining can last several seconds. A duel opponent or a recent player
	# attacker may become actionable after the mining decision started, so do not
	# let the busy executor hide that combat state until the block is destroyed.
	# Route excavation can opt in explicitly when it is the only way to reach the
	# target; ordinary resource gathering is always interrupted.
	if _combat_should_preempt_mining(observation):
		executor.cancel("combat_preempted")
	executor.tick(delta, observation, now_msec)
	if executor.is_busy() or now_msec < _next_decision_msec:
		return
	if provider == null:
		provider = BotRuleProviderClass.new()
	var proposed := Contract.normalize_decision(provider.decide(observation))
	decision_proposed.emit(proposed.duplicate(true))
	var approved := safety.approve_decision(proposed, observation, now_msec)
	if not bool(approved.get("allowed", false)):
		decision_rejected.emit(proposed.duplicate(true), str(approved.get("reason", "rejected")))
		_next_decision_msec = now_msec + REJECTION_RETRY_MSEC
		return
	var decision: Dictionary = approved.get("decision", {}) if approved.get("decision", {}) is Dictionary else {}
	if decision.is_empty():
		decision = Contract.normalize_decision({"action": Contract.ACTION_WAIT})
	var aggressive_player := _is_aggressive_player_decision(decision, observation)
	if aggressive_player:
		decision = decision.duplicate(true)
		var original_commit_msec := int(decision.get("commit_for_ms", 0))
		if original_commit_msec > 0:
			decision["commit_for_ms"] = maxi(
				AGGRESSIVE_PLAYER_COMMIT_MIN_MSEC,
				int(round(float(original_commit_msec) * AGGRESSIVE_PLAYER_COMMIT_SCALE)),
			)
	var goal := str(decision.get("goal", Contract.GOAL_IDLE))
	if goal != _last_goal:
		_last_goal = goal
		goal_changed.emit(goal)
	if not executor.start(decision, observation, now_msec):
		_next_decision_msec = now_msec + REJECTION_RETRY_MSEC
		return
	decision_started.emit(decision.duplicate(true))
	var next_interval_msec := AGGRESSIVE_PLAYER_DECISION_INTERVAL_MSEC if aggressive_player else decision_interval_msec
	_next_decision_msec = now_msec + maxi(next_interval_msec, int(decision.get("commit_for_ms", 0)))


func _combat_should_preempt_mining(observation: Dictionary) -> bool:
	if executor == null or executor.current_action() != Contract.ACTION_MINE:
		return false
	var target: Dictionary = executor.current_decision.get("target", {}) if executor.current_decision.get("target", {}) is Dictionary else {}
	if bool(target.get("combat_route", false)):
		return false
	return _player_combat_focus_active(observation)


func _player_combat_focus_active(observation: Dictionary) -> bool:
	if bool(observation.get("pvp_world", false)) and bool(observation.get("duel_started", false)):
		# The duel enemy is pinned for the match lifetime. Treat a temporarily
		# missing roster entry as network jitter, not permission to go mining.
		return true
	var defense: Dictionary = observation.get("self_defense", {}) if observation.get("self_defense", {}) is Dictionary else {}
	var attacker_id := str(defense.get("attacker_player_id", ""))
	var aggressive_player_id := str(observation.get("aggressive_player_id", ""))
	return (
		not aggressive_player_id.is_empty()
		or (not attacker_id.is_empty() and _observation_has_player(observation, attacker_id))
	)


func _is_aggressive_player_decision(decision: Dictionary, observation: Dictionary) -> bool:
	var action := str(decision.get("action", ""))
	if action not in AGGRESSIVE_PLAYER_ACTIONS:
		return false
	var target_id := str(decision.get("target_id", ""))
	if target_id.is_empty() and decision.get("target", {}) is Dictionary:
		target_id = str((decision.get("target", {}) as Dictionary).get("id", ""))
	var enemy_id := str(observation.get("enemy_player_id", ""))
	var aggressive_player_id := str(observation.get("aggressive_player_id", ""))
	var defense: Dictionary = observation.get("self_defense", {}) if observation.get("self_defense", {}) is Dictionary else {}
	var attacker_id := str(defense.get("attacker_player_id", ""))
	var targets_player := (
		(not target_id.is_empty() and target_id in [enemy_id, attacker_id, aggressive_player_id])
		or _observation_has_player(observation, target_id)
	)
	var goal := str(decision.get("goal", ""))
	# Friendly social follow must not use the duel chase cadence. Treating every
	# MOVE_NEAR_PLAYER toward a nearby human as "aggressive" re-decided every
	# ~450ms and produced the endless jump-beside-player loop on community.
	if goal == Contract.GOAL_SOCIAL_FOLLOW:
		return false
	if action in [Contract.ACTION_FIRE_BOW, Contract.ACTION_RETALIATE_ONCE, Contract.ACTION_ATTACK_PLAYER]:
		return targets_player
	if action in [Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_MOVE_TO, Contract.ACTION_FOLLOW]:
		if targets_player and (goal == Contract.GOAL_SELF_DEFENSE or target_id in [enemy_id, attacker_id, aggressive_player_id]):
			return true
		return goal == Contract.GOAL_SELF_DEFENSE and (not enemy_id.is_empty() or not attacker_id.is_empty() or not aggressive_player_id.is_empty())
	if action in [Contract.ACTION_PLACE, Contract.ACTION_EQUIP]:
		return goal == Contract.GOAL_SELF_DEFENSE and (
			targets_player or not enemy_id.is_empty() or not attacker_id.is_empty() or not aggressive_player_id.is_empty()
		)
	return false


func _observation_has_player(observation: Dictionary, target_id: String) -> bool:
	if target_id.is_empty():
		return false
	var players: Variant = observation.get("players", [])
	if not players is Array:
		return false
	for raw_player in players:
		if raw_player is Dictionary and str((raw_player as Dictionary).get("id", "")) == target_id:
			return true
	return false
