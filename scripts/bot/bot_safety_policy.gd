class_name BotSafetyPolicy
extends RefCounted

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const Perception = preload("res://gameplay/scripts/bot/bot_perception.gd")
const BuildPlanner = preload("res://gameplay/scripts/bot/bot_build_planner.gd")
const EmojiReactions = preload("res://gameplay/scripts/emoji_reactions.gd")
const BlockDefsClass = preload("res://gameplay/scripts/block_defs.gd")
const LIGHTER_ITEM_NAME := "lighter"

const DEFAULT_RETALIATION_WINDOW_MSEC := 10_000
const DEFAULT_MAX_RETALIATIONS := 1
const LOW_HEALTH_RATIO := 0.6

var retaliation_window_msec := DEFAULT_RETALIATION_WINDOW_MSEC
var max_retaliations := DEFAULT_MAX_RETALIATIONS
var response_enabled := true
var _duel_block_defs: Node
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
			if _descent_support_is_protected(observation, mine_target):
				return _rejected(decision, "descent_return_support_protected")
			if Perception.mine_target_opens_harmful_fluid_path(observation, mine_target):
				return _rejected(decision, "mine_target_harmful_fluid_breach")
			if bool(decision.get("descent_clear", false)) and not _valid_descent_clear(decision, observation):
				return _rejected(decision, "descent_clear_target_mismatch")
			if not Perception.mine_target_is_safe(observation, mine_target):
				return _rejected(decision, "mine_target_unsafe_support")
			if bool(mine_target.get("dig_route", false)):
				if not _valid_dig_route_target(decision, observation):
					return _rejected(decision, "dig_target_unsafe")
			else:
				var safe_fluid_step := BuildPlanner.obstructing_fluid_source_step(observation) if str(mine_target.get("reason", "")) == "obstructing_fluid_source" else {}
				var safe_fluid_target: Dictionary = safe_fluid_step.get("target", {}) if safe_fluid_step.get("target", {}) is Dictionary else {}
				if str(mine_target.get("reason", "")) == "obstructing_fluid_source" and (
					str(safe_fluid_target.get("id", "")) != target_id
					or int(safe_fluid_target.get("x", 2147483647)) != int(mine_target.get("x", 0))
					or int(safe_fluid_target.get("y", 2147483647)) != int(mine_target.get("y", 0))
					or str(safe_fluid_target.get("block_name", "")) != str(mine_target.get("block_name", ""))
				):
					return _rejected(decision, "fluid_source_not_safe")
				if not _reachable_resource_exists(observation.get("visible_resources", []), target_id) and str(safe_fluid_target.get("id", "")) != target_id:
					return _rejected(decision, "mine_target_not_reachable")
				if not _target_has_required_tool(observation, mine_target):
					return _rejected(decision, "required_mining_tool_missing")
		Contract.ACTION_OPEN_CONTAINER:
			if not _reachable_container_exists(observation.get("visible_containers", []), target_id):
				return _rejected(decision, "container_target_not_reachable")
		Contract.ACTION_IGNITE_TNT:
			var ignite_target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
			var ignition_item := str(decision.get("item_name", ignite_target.get("item_name", "lighter")))
			var ignite_reason := _duel_tnt_target_safety_reason(ignite_target, observation, true, str(ignite_target.get("block_name", "tnt")), ignition_item)
			if not ignite_reason.is_empty():
				return _rejected(decision, ignite_reason)
		Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_FOLLOW, Contract.ACTION_LOOK_AT:
			if not _target_exists(observation.get("players", []), target_id):
				return _rejected(decision, "player_target_not_visible")
		Contract.ACTION_SEND_EMOJI:
			var emoji := EmojiReactions.sanitize(decision.get("emoji", ""))
			if emoji.is_empty():
				return _rejected(decision, "emoji_not_allowed")
			decision["emoji"] = emoji
		Contract.ACTION_CRAFT, Contract.ACTION_EAT, Contract.ACTION_EQUIP:
			if target_id.is_empty():
				return _rejected(decision, "item_target_missing")
		Contract.ACTION_PLACE:
			var block_name := str(decision.get("block", ""))
			if block_name.is_empty() or not decision.has("target"):
				return _rejected(decision, "place_target_missing")
			if not _duel_explosive_profile(block_name).is_empty():
				var place_target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
				var place_reason := _duel_tnt_target_safety_reason(place_target, observation, false, block_name)
				if not place_reason.is_empty():
					return _rejected(decision, place_reason)
		Contract.ACTION_MOVE_TO:
			if bool(decision.get("descent_transition", false)) and not _valid_descent_transition(decision, observation):
				return _rejected(decision, "descent_transition_unverified")
		Contract.ACTION_WAIT:
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


func _duel_tnt_target_safety_reason(target: Dictionary, observation: Dictionary, require_existing_tnt: bool, explosive_name: String = "tnt", ignition_item: String = "") -> String:
	if not bool(observation.get("pvp_world", false)) or not bool(observation.get("duel_started", false)):
		return "tnt_duel_only"
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	if require_existing_tnt:
		var incendiary_name := _duel_normalize_block_name(ignition_item) if not ignition_item.is_empty() else LIGHTER_ITEM_NAME
		var incendiary: Dictionary = _duel_block_definitions().get(incendiary_name, {})
		var incendiary_definition: Dictionary = incendiary.get("definition", {}) if incendiary.get("definition", {}) is Dictionary else {}
		var incendiary_effects: Dictionary = incendiary_definition.get("effects", {}) if incendiary_definition.get("effects", {}) is Dictionary else {}
		var incendiary_profile: Dictionary = incendiary_effects.get("incendiary", {}) if incendiary_effects.get("incendiary", {}) is Dictionary else {}
		if _duel_inventory_count(inventory, incendiary_name) <= 0 or not bool(incendiary.get("item", false)) or str(incendiary_definition.get("category", "")) != "incendiary" or incendiary_profile.is_empty():
			return "tnt_lighter_missing"
	else:
		explosive_name = _duel_normalize_block_name(explosive_name)
		if _duel_inventory_count(inventory, explosive_name) <= 0:
			return "tnt_inventory_missing"
		if _duel_explosive_profile(explosive_name).is_empty():
			return "tnt_explosive_unknown"
	if not target.has("x") or not target.has("y"):
		return "tnt_target_missing"
	var tx := int(target.get("x", 0))
	var ty := int(target.get("y", 0))
	var tile_key := "%d:%d" % [tx, ty]
	var terrain_map := {}
	for raw_tile in _as_array(observation.get("terrain_tiles", [])):
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		terrain_map["%d:%d" % [int(tile.get("x", 0)), int(tile.get("y", 0))]] = _duel_normalize_block_name(str(tile.get("block_name", "")))
	if require_existing_tnt:
		if str(terrain_map.get(tile_key, "")) != _duel_normalize_block_name(explosive_name) or _duel_explosive_profile(explosive_name).is_empty():
			return "tnt_not_visible"
	else:
		var known_cells: Dictionary = observation.get("terrain_known_cells", {}) if observation.get("terrain_known_cells", {}) is Dictionary else {}
		if not known_cells.has(tile_key) or terrain_map.has(tile_key):
			return "tnt_placement_cell_unverified"
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	if self_state.is_empty():
		return "tnt_self_position_missing"
	var tile_size := 32.0
	var target_center := Vector2((float(tx) + 0.5) * tile_size, (float(ty) + 0.5) * tile_size)
	var self_position := Contract.target_position(self_state)
	var self_width := float(self_state.get("w", 20.0))
	var self_height := float(self_state.get("h", 28.0))
	var self_center := self_position + Vector2(self_width * 0.5, self_height * 0.5)
	if self_center.distance_to(target_center) >= tile_size * 4.5:
		return "tnt_target_out_of_reach"
	var self_support := Vector2(
		floori((self_position.x + self_width * 0.5) / tile_size),
		floori((self_position.y + self_height) / tile_size),
	)
	if self_support.distance_to(Vector2(tx, ty)) <= 3.0:
		return "tnt_too_close_to_self"
	var enemy_id := str(observation.get("enemy_player_id", ""))
	if enemy_id.is_empty():
		return "tnt_enemy_missing"
	var enemy: Dictionary = _find_target(observation, enemy_id)
	if enemy.is_empty() or not bool(enemy.get("alive", true)) or _target_snapshot_is_stale(observation.get("players", []), enemy_id):
		return "tnt_enemy_not_fresh"
	var enemy_position := Contract.target_position(enemy)
	var enemy_width := float(enemy.get("w", 20.0))
	var enemy_height := float(enemy.get("h", 28.0))
	var enemy_support := Vector2(
		floori((enemy_position.x + enemy_width * 0.5) / tile_size),
		floori((enemy_position.y + enemy_height) / tile_size),
	)
	var explosive_profile := _duel_explosive_profile(explosive_name)
	if not _duel_explosion_contains_tile(tx, ty, int(enemy_support.x), int(enemy_support.y), str(explosive_profile.get("blast_shape", "circle")), int(explosive_profile.get("blast_radius_blocks", 2))):
		return "tnt_enemy_outside_blast_radius"
	return ""


func _duel_explosive_profile(block_name: String) -> Dictionary:
	var normalized := _duel_normalize_block_name(block_name)
	var block: Dictionary = _duel_block_definitions().get(normalized, {})
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	var profile: Dictionary = effects.get("explosive", {}) if effects.get("explosive", {}) is Dictionary else {}
	return profile


func _duel_inventory_count(inventory: Dictionary, block_name: String) -> int:
	var normalized := _duel_normalize_block_name(block_name)
	var total := 0
	for raw_name in inventory.keys():
		if _duel_normalize_block_name(str(raw_name)) == normalized:
			total += maxi(0, int(inventory.get(raw_name, 0)))
	return total


func _duel_normalize_block_name(block_name: String) -> String:
	var raw_name := block_name.to_lower().strip_edges()
	var definitions := _duel_block_definitions()
	if definitions.has(raw_name):
		return raw_name
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		var root_defs: Node = (main_loop as SceneTree).root.get_node_or_null("BlockDefs")
		if root_defs != null and root_defs.has_method("name_for_content_id"):
			var resolved := str(root_defs.call("name_for_content_id", raw_name))
			if not resolved.is_empty() and definitions.has(resolved):
				return resolved
	if _duel_block_defs != null and _duel_block_defs.has_method("name_for_content_id"):
		var fallback_resolved := str(_duel_block_defs.call("name_for_content_id", raw_name))
		if not fallback_resolved.is_empty() and definitions.has(fallback_resolved):
			return fallback_resolved
	var normalized := raw_name.trim_prefix("core.")
	if normalized.begins_with("explosive."):
		normalized = normalized.trim_prefix("explosive.")
	elif normalized.begins_with("item."):
		normalized = normalized.trim_prefix("item.")
	return normalized


func _duel_block_definitions() -> Dictionary:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		var block_defs: Node = (main_loop as SceneTree).root.get_node_or_null("BlockDefs")
		if block_defs != null:
			return block_defs.BLOCKS
	if _duel_block_defs == null:
		_duel_block_defs = BlockDefsClass.new()
	return _duel_block_defs.BLOCKS


func _duel_explosion_contains_tile(origin_x: int, origin_y: int, target_x: int, target_y: int, shape: String, radius: int) -> bool:
	var dx := absi(target_x - origin_x)
	var dy := absi(target_y - origin_y)
	match shape:
		"square": return dx <= radius and dy <= radius
		"cross": return (dx == 0 or dy == 0) and maxi(dx, dy) <= radius
		"diamond": return dx + dy <= radius
		_: return Vector2(float(dx), float(dy)).length() <= float(radius)


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
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	# Dig reach is measured from the avatar body, not the tile below its feet.
	# Using the support tile rejected a reachable roof above a pit forever.
	var origin_x := floori((float(self_state.get("x", 0.0)) + float(self_state.get("w", 20.0)) * 0.5) / 32.0)
	var origin_y := floori((float(self_state.get("y", 0.0)) + float(self_state.get("h", 28.0)) * 0.5) / 32.0)
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
		return _hand_can_clear_tile(hand, tile)
	return false


func _hand_can_clear_tile(hand: String, tile: Dictionary) -> bool:
	# An authoritative harvest_tier 0 target is harvestable bare-handed: the
	# host's WorldSim.can_harvest_block only requires active_harvest_tier >= 0,
	# so clearing dirt, wood, leaves, and similar blockers needs no tool.
	if tile.has("harvest_tier") and int(tile.get("harvest_tier", 0)) <= 0:
		return true
	# Higher (or unknown) tiers still require a mining tool, and a tool that is
	# too low for the block's tier does not qualify.
	if not (hand.contains("pickaxe") or hand == "stone_axe"):
		return false
	var required_tier := int(tile.get("harvest_tier", 0))
	if required_tier > 0 and _tool_harvest_tier(hand) < required_tier:
		return false
	return true


func _descent_support_is_protected(observation: Dictionary, target: Dictionary) -> bool:
	if not target.has("x") or not target.has("y"):
		return false
	# A host-confirmed regenerating source may be mined even when it is also
	# the bot's recorded return support: the host replaces it atomically and
	# explicitly guarantees that support remains. Do not trust capability flags
	# copied only into a proposed decision; match the exact observed resource.
	if _observed_mine_preserves_support(observation, target):
		return false
	var target_x := int(target.get("x", 2147483647))
	var target_y := int(target.get("y", 2147483647))
	for raw_support in _as_array(observation.get("descent_protected_supports", [])):
		var support := _tile_pair(raw_support)
		if support != Vector2i(2147483647, 2147483647) and support == Vector2i(target_x, target_y):
			return true
	var plan: Dictionary = observation.get("descent_plan", {}) if observation.get("descent_plan", {}) is Dictionary else {}
	for raw_support in _as_array(plan.get("protected_supports", [])):
		var support := _tile_pair(raw_support)
		if support != Vector2i(2147483647, 2147483647) and support == Vector2i(target_x, target_y):
			return true
	return false


func _observed_mine_preserves_support(observation: Dictionary, target: Dictionary) -> bool:
	if not target.has("x") or not target.has("y"):
		return false
	var target_id := str(target.get("id", ""))
	if target_id.is_empty():
		return false
	var target_x := int(target.get("x", 2147483647))
	var target_y := int(target.get("y", 2147483647))
	for raw_resource in _as_array(observation.get("visible_resources", [])):
		if not raw_resource is Dictionary:
			continue
		var resource := raw_resource as Dictionary
		if str(resource.get("id", "")) != target_id:
			continue
		if int(resource.get("x", 2147483647)) != target_x or int(resource.get("y", 2147483647)) != target_y:
			continue
		return bool(resource.get("regenerates_on_mine", false)) and bool(resource.get("preserves_support_on_mine", false))
	return false


func _valid_descent_clear(decision: Dictionary, observation: Dictionary) -> bool:
	var plan: Dictionary = observation.get("descent_plan", {}) if observation.get("descent_plan", {}) is Dictionary else {}
	if not bool(plan.get("eligible", false)) or not bool(plan.get("verified_safe_exit", false)) or str(plan.get("phase", "")) != "clear":
		return false
	var expected := _tile_pair(plan.get("clear_tile", []))
	var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
	if expected == Vector2i(2147483647, 2147483647) or not target.has("x") or not target.has("y") or expected != Vector2i(int(target.get("x", 0)), int(target.get("y", 0))):
		return false
	var key := "%d:%d" % [expected.x, expected.y]
	var protected: Dictionary = observation.get("protected_build_cells", {}) if observation.get("protected_build_cells", {}) is Dictionary else {}
	if protected.has(key):
		return false
	for raw_entry in _as_array(observation.get("action_history", [])):
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		if str(entry.get("action", "")) != Contract.ACTION_PLACE:
			continue
		var parts := str(entry.get("target_id", "")).split(":")
		if parts.size() >= 3 and parts[-2].is_valid_int() and parts[-1].is_valid_int() and int(parts[-2]) == expected.x and int(parts[-1]) == expected.y:
			return false
	return true


func _valid_descent_transition(decision: Dictionary, observation: Dictionary) -> bool:
	var plan: Dictionary = observation.get("descent_plan", {}) if observation.get("descent_plan", {}) is Dictionary else {}
	if not bool(plan.get("eligible", false)) or not bool(plan.get("verified_safe_exit", false)) or str(plan.get("phase", "")) != "move":
		return false
	var expected_from := _tile_pair(plan.get("current_support", []))
	var expected_to := _tile_pair(plan.get("next_support", []))
	if expected_from == Vector2i(2147483647, 2147483647) or expected_to == Vector2i(2147483647, 2147483647):
		return false
	if _tile_pair(decision.get("descent_from_support", [])) != expected_from or _tile_pair(decision.get("descent_to_support", [])) != expected_to:
		return false
	# The gameplay MOVE_TO target is the bot's top-left coordinate that stands
	# directly above the nominated support tile, not the tile coordinate itself.
	var target := Contract.target_position(decision.get("target", {}))
	var expected_position := Vector2((float(expected_to.x) + 0.5) * 32.0 - 10.0, float(expected_to.y * 32) - 28.0)
	return target.distance_to(expected_position) <= 1.0


func _tile_pair(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	if value is Dictionary and (value as Dictionary).has("x") and (value as Dictionary).has("y"):
		return Vector2i(int((value as Dictionary).get("x", 0)), int((value as Dictionary).get("y", 0)))
	return Vector2i(2147483647, 2147483647)


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
