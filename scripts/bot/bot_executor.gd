class_name BotExecutor
extends RefCounted

signal action_started(decision: Dictionary)
signal action_finished(decision: Dictionary, reason: String)
signal action_failed(decision: Dictionary, reason: String)
signal command_sent(command: String, payload: Dictionary)

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const EmojiReactions = preload("res://gameplay/scripts/emoji_reactions.gd")

const DEFAULT_ACTION_MSEC := 900
const DEFAULT_MOVE_MSEC := 2200
const DEFAULT_COMMAND_MSEC := 500

var client: Object
var send_command_callable: Callable
var movement_callable: Callable
var retaliation_consumer: Callable
var current_decision: Dictionary = {}
var current_observation: Dictionary = {}
var action_started_msec := -1
var action_deadline_msec := -1
var _mine_next_progress_msec := -1
var _mine_progress_stage := -1
var _mine_final_sent := false
var _busy := false


func configure(
	client_adapter: Object = null,
	send_command: Callable = Callable(),
	movement_step: Callable = Callable(),
	retaliation_consume: Callable = Callable(),
) -> void:
	client = client_adapter
	send_command_callable = send_command
	movement_callable = movement_step
	retaliation_consumer = retaliation_consume


func is_busy() -> bool:
	return _busy


func current_action() -> String:
	return str(current_decision.get("action", "")) if _busy else ""


func start(raw_decision: Variant, observation: Dictionary, now_msec: int) -> bool:
	if _busy:
		return false
	var decision := Contract.normalize_decision(raw_decision)
	var action := str(decision.get("action", Contract.ACTION_WAIT))
	var commit_msec := int(decision.get("commit_for_ms", 0))
	if commit_msec <= 0:
		commit_msec = _default_duration_msec(action)
	decision["commit_for_ms"] = commit_msec
	if action == Contract.ACTION_SEND_EMOJI:
		var emoji := EmojiReactions.sanitize(decision.get("emoji", ""))
		if emoji.is_empty():
			action_failed.emit(decision, "emoji_not_allowed")
			return false
		decision["emoji"] = emoji
	if action == Contract.ACTION_DISCOVER:
		var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
		var inputs: Array = target.get("inputs", []) if target.get("inputs", []) is Array else []
		if inputs.is_empty():
			action_failed.emit(decision, "discover_inputs_missing")
			return false
	if action == Contract.ACTION_EAT:
		var food_name := str(decision.get("target_id", ""))
		if food_name.is_empty():
			action_failed.emit(decision, "food_target_missing")
			return false
	if action == Contract.ACTION_RETALIATE_ONCE and retaliation_consumer.is_valid():
		var target_id := str(decision.get("target_id", ""))
		if not bool(retaliation_consumer.call(target_id, now_msec)):
			action_failed.emit(decision, "retaliation_not_consumed")
			return false
	current_decision = decision
	current_observation = observation.duplicate(true)
	action_started_msec = now_msec
	if action == Contract.ACTION_MINE:
		commit_msec = _mine_duration_msec(decision, observation, commit_msec)
		decision["commit_for_ms"] = commit_msec
	action_deadline_msec = now_msec + commit_msec
	_busy = true
	action_started.emit(current_decision.duplicate(true))
	if action == Contract.ACTION_MINE:
		_mine_next_progress_msec = now_msec
		_mine_progress_stage = -1
		_mine_final_sent = false
		_send_mine_progress(now_msec, 0)
		return true

	if action in [Contract.ACTION_SEND_EMOJI, Contract.ACTION_MINE, Contract.ACTION_PLACE, Contract.ACTION_ATTACK_CREATURE, Contract.ACTION_FIRE_BOW, Contract.ACTION_RETALIATE_ONCE, Contract.ACTION_ATTACK_PLAYER, Contract.ACTION_CRAFT, Contract.ACTION_EAT, Contract.ACTION_OPEN_CONTAINER, Contract.ACTION_EQUIP]:
		if action == Contract.ACTION_EAT:
			# Eating is applied locally by the session and synced through
			# inventory_snapshot, matching human guests.
			_finish("command_sent")
			return true
		if not _send_network_action(action, decision):
			_fail("command_rejected")
			return false
		# These are acknowledged optimistically; action_result/snapshot updates
		# will be observed by the next decision cycle.
		_finish("command_sent")
	return true


func tick(delta: float, observation: Dictionary, now_msec: int) -> void:
	if not _busy:
		return
	current_observation = observation.duplicate(true)
	var action := str(current_decision.get("action", Contract.ACTION_WAIT))
	if action == Contract.ACTION_MINE:
		_tick_mining(now_msec)
		return
	if action in [Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_MOVE_TO, Contract.ACTION_FOLLOW, Contract.ACTION_FLEE_FROM, Contract.ACTION_LOOK_AT]:
		if movement_callable.is_valid():
			var result: Variant = movement_callable.call(action, current_decision.duplicate(true), current_observation.duplicate(true), delta)
			if result is Dictionary and bool((result as Dictionary).get("done", false)):
				_finish(str((result as Dictionary).get("reason", "movement_done")))
				return
			if result is bool and bool(result):
				_finish("movement_done")
				return
	if now_msec >= action_deadline_msec:
		_finish("timeout" if action != Contract.ACTION_WAIT else "wait_complete")


func cancel(reason: String = "cancelled") -> void:
	if _busy:
		_finish(reason)
	current_decision.clear()
	current_observation.clear()
	action_started_msec = -1
	action_deadline_msec = -1
	_mine_next_progress_msec = -1
	_mine_progress_stage = -1
	_mine_final_sent = false


func _send_network_action(action: String, decision: Dictionary) -> bool:
	var command := ""
	var payload: Dictionary = {}
	match action:
		Contract.ACTION_SEND_EMOJI:
			command = "emoji_reaction"
			payload = {"emoji": str(decision.get("emoji", ""))}
		Contract.ACTION_MINE:
			command = "mine_block"
			payload = _tile_payload(decision)
		Contract.ACTION_PLACE:
			command = "place_block"
			payload = _tile_payload(decision)
			payload["block"] = str(decision.get("block", ""))
			payload["block_name"] = str(decision.get("block", ""))
		Contract.ACTION_ATTACK_CREATURE:
			command = "attack_creature"
			payload = {"creature_id": str(decision.get("target_id", ""))}
		Contract.ACTION_FIRE_BOW:
			command = "fire_bow"
			var direction: Vector2 = Contract.target_position(decision.get("direction", decision.get("target", {})))
			payload = {
				"direction_x": direction.x,
				"direction_y": direction.y,
				"charge": clampf(float(decision.get("charge", 1.0)), 0.0, 1.0),
			}
		Contract.ACTION_RETALIATE_ONCE:
			command = "attack_player"
			payload = {"target_player_id": str(decision.get("target_id", ""))}
		Contract.ACTION_ATTACK_PLAYER:
			command = "attack_player"
			payload = {"target_player_id": str(decision.get("target_id", ""))}
		Contract.ACTION_CRAFT:
			command = "craft_recipe"
			payload = {"output": str(decision.get("target_id", ""))}
		Contract.ACTION_OPEN_CONTAINER:
			command = "open_container"
			payload = _tile_payload(decision)
		Contract.ACTION_EQUIP:
			command = "equip_item"
			payload = {"item": str(decision.get("target_id", ""))}
		_:
			return true
	var sent := _send_command(command, payload)
	if sent:
		command_sent.emit(command, payload.duplicate(true))
	return sent


func _send_command(command: String, payload: Dictionary) -> bool:
	if send_command_callable.is_valid():
		var result: Variant = send_command_callable.call(command, payload)
		return bool(result) if result is bool else true
	if client != null and client.has_method("send_command"):
		var result: Variant = client.call("send_command", command, payload)
		return bool(result) if result is bool else true
	return false


func _tick_mining(now_msec: int) -> void:
	var commit_msec := maxi(600, int(current_decision.get("commit_for_ms", 2200)))
	if not _mine_final_sent:
		if now_msec >= _mine_next_progress_msec:
			var elapsed := maxi(0, now_msec - action_started_msec)
			var stage := clampi(int(float(elapsed) / float(commit_msec) * 5.0), 0, 5)
			if stage > _mine_progress_stage:
				_send_mine_progress(now_msec, stage)
			_mine_next_progress_msec = now_msec + 250
		if now_msec >= action_deadline_msec:
			_send_mine_progress(now_msec, 5)
			var payload := _tile_payload(current_decision)
			if not _send_command("mine_block", payload):
				_fail("mine_command_rejected")
				return
			_mine_final_sent = true
			_mine_next_progress_msec = -1
			action_deadline_msec = now_msec + 3_000
		return
	if now_msec >= action_deadline_msec:
		_finish("mine_ack_timeout")


func _mine_duration_msec(decision: Dictionary, observation: Dictionary, fallback_msec: int) -> int:
	var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
	var hardness := float(target.get("hardness", 0.0))
	if hardness <= 0.0:
		return maxi(600, fallback_msec)
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var hand := str(equipment.get("hand", ""))
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	var multiplier := 1.0
	# The rule layer already checked the harvest tier. This lightweight lookup
	# keeps the hold duration proportional to the equipped tool without coupling
	# the executor to WorldSim internals.
	if not hand.is_empty() and int(inventory.get(hand, 0)) > 0:
		var loop := Engine.get_main_loop()
		if loop != null and loop.has_method("get_root"):
			var defs: Node = loop.get_root().get_node_or_null("BlockDefs")
			if defs != null and defs.get("BLOCKS") is Dictionary:
				var entry: Dictionary = defs.get("BLOCKS").get(hand, {}) if defs.get("BLOCKS").get(hand, {}) is Dictionary else {}
				var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
				var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
				multiplier = maxf(1.0, float(effects.get("mining_speed_multiplier", 1.0)))
	return clampi(roundi((850.0 + hardness * 58.0) / multiplier), 600, 6000)


func _send_mine_progress(now_msec: int, stage: int) -> void:
	var payload := _tile_payload(current_decision)
	payload["stage"] = clampi(stage, 0, 5)
	var target: Dictionary = current_decision.get("target", {}) if current_decision.get("target", {}) is Dictionary else {}
	payload["block_name"] = str(target.get("block_name", target.get("content_id", "")))
	if _send_command("mine_progress", payload):
		_mine_progress_stage = stage
		command_sent.emit("mine_progress", payload.duplicate(true))


func _tile_payload(decision: Dictionary) -> Dictionary:
	var target: Variant = decision.get("target", {})
	if target is Dictionary:
		var target_data := target as Dictionary
		return {"x": int(target_data.get("x", target_data.get("tile_x", 0))), "y": int(target_data.get("y", target_data.get("tile_y", 0)))}
	if target is Array and (target as Array).size() >= 2:
		return {"x": int((target as Array)[0]), "y": int((target as Array)[1])}
	return {"x": int(decision.get("x", 0)), "y": int(decision.get("y", 0))}


func _default_duration_msec(action: String) -> int:
	if action in [Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_MOVE_TO, Contract.ACTION_FOLLOW, Contract.ACTION_FLEE_FROM, Contract.ACTION_LOOK_AT]:
		return DEFAULT_MOVE_MSEC
	if action in [Contract.ACTION_MINE, Contract.ACTION_PLACE, Contract.ACTION_ATTACK_CREATURE, Contract.ACTION_FIRE_BOW, Contract.ACTION_RETALIATE_ONCE, Contract.ACTION_ATTACK_PLAYER, Contract.ACTION_SEND_EMOJI, Contract.ACTION_CRAFT, Contract.ACTION_OPEN_CONTAINER]:
		return DEFAULT_COMMAND_MSEC
	return DEFAULT_ACTION_MSEC


func _finish(reason: String) -> void:
	if not _busy:
		return
	var finished := current_decision.duplicate(true)
	_busy = false
	action_finished.emit(finished, reason)


func _fail(reason: String) -> void:
	if not _busy:
		return
	var failed := current_decision.duplicate(true)
	_busy = false
	action_failed.emit(failed, reason)
