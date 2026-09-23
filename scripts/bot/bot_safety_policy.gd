class_name BotSafetyPolicy
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const Perception = preload("res://gameplay/scripts/bot/bot_perception.gd")
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
		Contract.ACTION_ATTACK_PLAYER:
			var attack_target_id := (
				str(observation.get("enemy_player_id", ""))
				if bool(observation.get("pvp_world", false))
				else str(observation.get("aggressive_player_id", ""))
			)
			if attack_target_id.is_empty() or attack_target_id != target_id:
				return _rejected(decision, "aggressive_player_target_required")
			if _target_snapshot_is_stale(observation.get("players", []), target_id):
				return _rejected(decision, "pvp_enemy_snapshot_stale")
			if not _player_is_near(observation, target_id, float(observation.get("retaliation_distance", 52.0))):
				return _rejected(decision, "enemy_out_of_range")
		Contract.ACTION_ATTACK_CREATURE:
			if not _target_exists(observation.get("threats", []), target_id):
				return _rejected(decision, "creature_target_not_visible")
		Contract.ACTION_FIRE_BOW:
			if not _bow_is_ready(observation):
				return _rejected(decision, "bow_or_arrows_missing")
			var pvp_world := bool(observation.get("pvp_world", false))
			var enemy_id := str(observation.get("enemy_player_id", ""))
			var aggressive_player_id := str(observation.get("aggressive_player_id", ""))
			var player_target_id := enemy_id if pvp_world else aggressive_player_id
			if not player_target_id.is_empty():
				if target_id != player_target_id:
					return _rejected(decision, "aggressive_player_target_required")
				if not _target_exists(observation.get("players", []), target_id):
					return _rejected(decision, "pvp_enemy_not_visible")
				if _target_snapshot_is_stale(observation.get("players", []), target_id):
					return _rejected(decision, "pvp_enemy_snapshot_stale")
			else:
				if not _target_exists(observation.get("threats", []), target_id):
					return _rejected(decision, "ranged_target_not_visible")
			var ranged_target := _find_target(observation, target_id)
			if ranged_target.is_empty() or float(ranged_target.get("distance", 9999.0)) > float(observation.get("bow_attack_distance", 320.0)):
				return _rejected(decision, "ranged_target_out_of_range")
			if not Perception.has_clear_bow_line_of_sight(observation, ranged_target):
				return _rejected(decision, "ranged_target_blocked")
			var direction := Contract.target_position(decision.get("direction", decision.get("target", {})))
			if direction.length() < 0.1:
				return _rejected(decision, "ranged_direction_missing")
		Contract.ACTION_FLEE_FROM:
			if target_id.is_empty() and _first_target_id(observation.get("threats", []), target_id).is_empty():
				return _rejected(decision, "flee_target_missing")
		Contract.ACTION_MINE:
			var mine_target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
			if _player_combat_focus_active(observation) and not bool(mine_target.get("combat_route", false)):
				return _rejected(decision, "combat_target_has_priority")
			if not Perception.mine_target_is_safe(observation, mine_target):
				return _rejected(decision, "mine_target_unsafe_support")
			if bool(mine_target.get("dig_route", false)):
				if not _valid_dig_route_target(decision, observation):
					return _rejected(decision, "dig_target_unsafe")
			else:
				if not _reachable_resource_exists(observation.get("visible_resources", []), target_id):
					return _rejected(decision, "mine_target_not_reachable")
				if not _target_has_required_tool(observation, mine_target):
					return _rejected(decision, "required_mining_tool_missing")
		Contract.ACTION_OPEN_CONTAINER:
			if not _reachable_container_exists(observation.get("visible_containers", []), target_id):
				return _rejected(decision, "container_target_not_reachable")
		Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_FOLLOW, Contract.ACTION_LOOK_AT:
			if not _target_exists(observation.get("players", []), target_id):
				return _rejected(decision, "player_target_not_visible")
		Contract.ACTION_SEND_EMOJI:
			var emoji := EmojiReactions.sanitize(decision.get("emoji", ""))
			if emoji.is_empty():
				return _rejected(decision, "emoji_not_allowed")
			decision["emoji"] = emoji
		Contract.ACTION_CRAFT, Contract.ACTION_DISCOVER, Contract.ACTION_EAT, Contract.ACTION_EQUIP:
			if target_id.is_empty():
				return _rejected(decision, "item_target_missing")
		Contract.ACTION_PLACE:
			if str(decision.get("block", "")).is_empty() or not decision.has("target"):
				return _rejected(decision, "place_target_missing")
		Contract.ACTION_WAIT, Contract.ACTION_MOVE_TO:
			pass

	return {"allowed": true, "decision": decision, "reason": ""}


func is_low_health(self_state: Dictionary) -> bool:
	var maximum := maxi(1, int(self_state.get("max_health", 10)))
	return float(int(self_state.get("health", maximum))) / float(maximum) <= LOW_HEALTH_RATIO


func _player_combat_focus_active(observation: Dictionary) -> bool:
	if bool(observation.get("pvp_world", false)) and bool(observation.get("duel_started", false)):
		return true
	var defense: Dictionary = observation.get("self_defense", {}) if observation.get("self_defense", {}) is Dictionary else {}
	var attacker_id := str(defense.get("attacker_player_id", ""))
	var aggressive_player_id := str(observation.get("aggressive_player_id", ""))
	return (
		not aggressive_player_id.is_empty()
		or (not attacker_id.is_empty() and _target_exists(observation.get("players", []), attacker_id))
	)


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


func _target_snapshot_is_stale(raw_targets: Variant, target_id: String) -> bool:
	for raw_target in _as_array(raw_targets):
		if not raw_target is Dictionary or str((raw_target as Dictionary).get("id", "")) != target_id:
			continue
		return bool((raw_target as Dictionary).get("stale", (raw_target as Dictionary).get("last_known", false)))
	return false


func _target_exists(raw_targets: Variant, target_id: String) -> bool:
	if target_id.is_empty():
		return false
	for raw_target in _as_array(raw_targets):
		if raw_target is Dictionary and str((raw_target as Dictionary).get("id", "")) == target_id:
			return true
	return false


func _find_target(observation: Dictionary, target_id: String) -> Dictionary:
	for key in ["players", "threats"]:
		for raw_target in _as_array(observation.get(key, [])):
			if raw_target is Dictionary and str((raw_target as Dictionary).get("id", "")) == target_id:
				return raw_target as Dictionary
	return {}


func _bow_is_ready(observation: Dictionary) -> bool:
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var hand := str(equipment.get("hand", "")).to_lower()
	if not hand.contains("bow"):
		return false
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	return int(inventory.get("arrow", 0)) > 0


func _reachable_resource_exists(raw_targets: Variant, target_id: String) -> bool:
	for raw_target in _as_array(raw_targets):
		if not raw_target is Dictionary:
			continue
		var target := raw_target as Dictionary
		if str(target.get("id", "")) == target_id:
			return bool(target.get("reachable", false))
	return false


func _target_has_required_tool(observation: Dictionary, target: Dictionary) -> bool:
	var required_tier := int(target.get("harvest_tier", 0))
	if required_tier <= 0:
		return true
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var hand := str(equipment.get("hand", ""))
	var entry: Dictionary = _block_entry(hand)
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	if str(definition.get("category", "")) != "mining_tool":
		return false
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return int(effects.get("harvest_tier", 0)) >= required_tier


func _block_entry(block_name: String) -> Dictionary:
	var loop := Engine.get_main_loop()
	if loop == null or not loop.has_method("get_root"):
		return {}
	var root: Node = loop.get_root()
	var defs := root.get_node_or_null("BlockDefs")
	if defs == null or not defs.get("BLOCKS") is Dictionary:
		return {}
	var blocks: Dictionary = defs.get("BLOCKS")
	return blocks.get(block_name, {}) if blocks.get(block_name, {}) is Dictionary else {}


func _reachable_container_exists(raw_targets: Variant, target_id: String) -> bool:
	for raw_target in _as_array(raw_targets):
		if not raw_target is Dictionary:
			continue
		var target := raw_target as Dictionary
		if str(target.get("id", "")) == target_id:
			return bool(target.get("reachable", false))
	return false


func _valid_dig_route_target(decision: Dictionary, observation: Dictionary) -> bool:
	var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
	if not bool(target.get("dig_route", false)) or not target.has("x") or not target.has("y"):
		return false
	var equipment: Dictionary = observation.get("equipment_slots", {}) if observation.get("equipment_slots", {}) is Dictionary else {}
	var hand := str(equipment.get("hand", ""))
	if not (hand.contains("pickaxe") or hand == "stone_axe"):
		return false
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	var origin_x := floori((float(self_state.get("x", 0.0)) + 10.0) / 32.0)
	var origin_y := floori((float(self_state.get("y", 0.0)) + 28.0) / 32.0)
	var target_x := int(target.get("x", 0))
	var target_y := int(target.get("y", 0))
	if abs(target_x - origin_x) > 2 or abs(target_y - origin_y) > 2:
		return false
	var terrain: Array = observation.get("terrain_tiles", []) if observation.get("terrain_tiles", []) is Array else []
	for raw_tile in terrain:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		if int(tile.get("x", 0)) != target_x or int(tile.get("y", 0)) != target_y:
			continue
		var block_name := str(tile.get("block_name", ""))
		if block_name.is_empty() or block_name in ["air", "core.air"]:
			return false
		var required_tier := int(tile.get("harvest_tier", 0))
		if required_tier > 0 and _tool_harvest_tier(hand) < required_tier:
			return false
		return true
	return false


func _tool_harvest_tier(block_name: String) -> int:
	var entry := _block_entry(block_name)
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	if str(definition.get("category", "")) != "mining_tool":
		return 0
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return int(effects.get("harvest_tier", 0))


func _first_target_id(raw_targets: Variant, fallback: String) -> String:
	for raw_target in _as_array(raw_targets):
		if raw_target is Dictionary:
			var candidate := str((raw_target as Dictionary).get("id", ""))
			if not candidate.is_empty():
				return candidate
	return fallback


func _as_array(value: Variant) -> Array:
	return value as Array if value is Array else []
