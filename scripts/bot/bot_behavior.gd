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
	_last_goal = ""
	_next_decision_msec = now_msec


func tick(observation: Dictionary, delta: float, now_msec: int) -> void:
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
	var goal := str(decision.get("goal", Contract.GOAL_IDLE))
	if goal != _last_goal:
		_last_goal = goal
		goal_changed.emit(goal)
	if not executor.start(decision, observation, now_msec):
		_next_decision_msec = now_msec + REJECTION_RETRY_MSEC
		return
	decision_started.emit(decision.duplicate(true))
	_next_decision_msec = now_msec + maxi(decision_interval_msec, int(decision.get("commit_for_ms", 0)))
