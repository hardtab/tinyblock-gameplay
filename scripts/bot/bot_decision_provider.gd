class_name BotDecisionProvider
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")

## Base interface for a bot brain.
##
## Providers are deliberately synchronous at this boundary.  A remote provider
## can perform its asynchronous request outside this class and feed the result
## back into the session, while the deterministic fallback remains usable when
## the network or an external model is unavailable.

func provider_name() -> String:
	return "base"


func decide(_observation: Dictionary) -> Dictionary:
	return Contract.normalize_decision({
		"goal": Contract.GOAL_IDLE,
		"action": Contract.ACTION_WAIT,
		"commit_for_ms": 900,
		"confidence": 0.0,
	})


func can_decide(_observation: Dictionary) -> bool:
	return true
