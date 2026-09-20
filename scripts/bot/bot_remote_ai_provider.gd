class_name BotRemoteAIProvider
extends BotDecisionProvider

## Adapter for a private bot-brain service.
##
## The game client never receives a provider secret.  A deployment may inject a
## Callable that performs the authenticated request (or a local test double),
## and this adapter validates the small decision dictionary before returning it.

var request_callable: Callable
var fallback: BotDecisionProvider
var last_error := ""


func _init(request: Callable = Callable(), fallback_provider: BotDecisionProvider = null) -> void:
	request_callable = request
	fallback = fallback_provider


func provider_name() -> String:
	return "remote"


func can_decide(_observation: Dictionary) -> bool:
	return request_callable.is_valid()


func decide(observation: Dictionary) -> Dictionary:
	last_error = ""
	if not request_callable.is_valid():
		last_error = "provider_unavailable"
		return _fallback(observation)
	var response: Variant
	# Remote adapters receive an already bounded observation.  The adapter never
	# exposes player inventory or raw network objects itself.
	response = request_callable.call(observation.duplicate(true))
	if response is Dictionary and not (response as Dictionary).is_empty():
		return Contract.normalize_decision(response)
	last_error = "invalid_provider_response"
	return _fallback(observation)


func decide_async(observation: Dictionary, completed: Callable) -> void:
	if not completed.is_valid():
		return
	var response := decide(observation)
	completed.call(response, last_error)


func _fallback(observation: Dictionary) -> Dictionary:
	if fallback != null:
		return Contract.normalize_decision(fallback.decide(observation))
	return Contract.normalize_decision({"action": Contract.ACTION_WAIT, "commit_for_ms": 900, "confidence": 0.0})
