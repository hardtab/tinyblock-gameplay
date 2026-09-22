class_name BotSession
extends Node

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const Perception = preload("res://gameplay/scripts/bot/bot_perception.gd")
const Navigator = preload("res://gameplay/scripts/bot/bot_navigator.gd")
const BlockDefs = preload("res://gameplay/scripts/block_defs.gd")
const Social = preload("res://gameplay/scripts/bot/bot_social.gd")
const EmojiReactions = preload("res://gameplay/scripts/emoji_reactions.gd")
const BehaviorClass = preload("res://gameplay/scripts/bot/bot_behavior.gd")
const RuleProviderClass = preload("res://gameplay/scripts/bot/bot_rule_provider.gd")
const SafetyClass = preload("res://gameplay/scripts/bot/bot_safety_policy.gd")
const ExecutorClass = preload("res://gameplay/scripts/bot/bot_executor.gd")
const ActionLoop = preload("res://gameplay/scripts/bot/bot_action_loop.gd")
const AiClientClass = preload("res://gameplay/scripts/bot/bot_ai_client.gd")

signal state_changed(state: String)
signal sync_started(session_id: String)
signal session_ready(session_id: String, player_id: String)
signal human_player_count_changed(count: int)
signal empty_world_ready()
signal session_left(reason: String)
signal decision_logged(event: Dictionary)
signal structured_log(event: Dictionary)

const STATE_IDLE := "IDLE"
const STATE_JOINING := "JOINING"
const STATE_SYNCING := "SYNCING"
const STATE_PLAYING := "PLAYING"
const STATE_LEAVING := "LEAVING"

const DEFAULT_SYNC_TIMEOUT_MSEC := 45_000
const DEFAULT_EMPTY_GRACE_MSEC := 30_000
const DEFAULT_OBSERVATION_RADIUS := 256.0

var backend: Object
var network_client: Object
var behavior: BotBehavior
var safety: BotSafetyPolicy
var executor: BotExecutor
var state := STATE_IDLE
var session_id := ""
var own_player_id := ""
var world_id := ""
var _session_world_mode := ""
var protocol_version := 2
var dedicated_server := false
var empty_grace_msec := DEFAULT_EMPTY_GRACE_MSEC
var observation_radius := DEFAULT_OBSERVATION_RADIUS
var human_player_count := 0
var empty_since_msec := -1
var sync_complete := false
var _sync_started_msec := -1
var _empty_emitted := false
var _left_emitted := false
var _join_in_flight := false
var _disconnect_requested := false
var _network_signals_connected := false
var _snapshot_transfer_id := ""
var _snapshot_expected_chunks := 0
var _snapshot_chunks: Array[String] = []
var _world_snapshot: Dictionary = {}
var _roster: Dictionary = {}
var _recent_events: Array[Dictionary] = []
var _recent_emoji_events: Array[Dictionary] = []
var _action_history: Array[Dictionary] = []
var _action_loop_blocked_until: Dictionary = {}
var _last_emoji_sent_msec := -1
var _previous_emoji := ""
var _social_last_sent_msec := -1
var _welcome_emoji_due_msec := -1
var _welcome_emoji_pending := false
var _pending_social_emoji := ""
var _pending_social_emoji_target_id := ""
var _emoji_reply_inflight := false
var ai_client: BotAiClient
var _movement_step_callable: Callable
var _desired_input := {"left": false, "right": false, "jump": false}
var _last_player_input_msec := -1
var _social := Social.new()
var _last_player_snapshot_msec := -1
var _equipment_slots := {"hand": "", "feet": ""}
var _pending_action_targets: Dictionary = {}
var _blocked_action_targets: Dictionary = {}
var _terrain_tiles: Dictionary = {}
var _plant_tiles: Dictionary = {}
var _physics_route: Array[Dictionary] = []
var _physics_route_target := Vector2i(2147483647, 2147483647)
var _physics_route_target_id := ""
var _physics_route_replan_msec := -1
var _jump_active := false
var _jump_velocity := 0.0
var _jump_ground_y := 0.0
var _jump_start_x := 0.0
var _climb_active := false
var _climb_column := 0
var _climb_time_left_msec := 0
var _support_place_attempted := false
var _support_place_last_attempt_msec := -1
var _was_in_harmful_fluid := false
var _harmful_fluid_damage_cooldown := 0.0
var _guest_defeat_pending := false
var _guest_defeat_retry_after_msec := -1
var _host_player_id := ""
var _pvp_enemy_player_id := ""
var _duel_started := false
var _pvp_chest_opened := false
var _last_duel_ready_msec := -1
var _craft_pending_output := ""
var _craft_retry_after_msec := -1
## output_name -> blocked_until_msec. Timed so a missed craft_recipe ack
## cannot permanently starve plank/tool progression for the session.
var _craft_blocked_outputs: Dictionary = {}
var _food_eat_cooldown_until_msec := -1
var _inventory_host_revision := 0
var _inventory_client_revision := 0
var _population_logged := false
## One-shot: drop wooden_pickaxe + trail_boots after join so craft+equip can be
## proven from scratch on a community world that still had leftover gear.
var _strip_progression_gear := false
var _progression_gear_stripped := false
const PLAYER_SNAPSHOT_INTERVAL_MSEC := 100
const PLAYER_INPUT_INTERVAL_MSEC := 50
const HARMFUL_FLUID_DAMAGE_INTERVAL := 20.0 / 60.0
const GUEST_DEFEAT_RETRY_MSEC := 400
const DUEL_PROTOCOL_VERSION := 3
const NETWORK_PHYSICS_TICKS_PER_SECOND := 60.0
const TREE_CLIMB_SPEED := -3.2
const CRAFT_RESPONSE_TIMEOUT_MSEC := 4_000
const CRAFT_RETRY_DELAY_MSEC := 8_000
const CRAFT_BLOCK_COOLDOWN_MSEC := 12_000
const FOOD_EAT_COOLDOWN_MSEC := 8_000
const ACTION_RETRY_BLOCK_MSEC := 8_000
const EMOJI_EVENT_TTL_MSEC := 8_000
const SUPPORT_PLACE_COOLDOWN_MSEC := 650
const SUPPORT_PLACE_MAX_DISTANCE := BlockDefs.TILE * 4.5
const SUPPORT_PLACE_INVALID_TILE := Vector2i(2147483647, 2147483647)
const SUPPORT_BLOCK_PRIORITY: PackedStringArray = [
	"planks", "palm_planks", "pine_planks", "weeping_planks",
	"stone_bricks", "cobblestone", "stone", "dirt",
]
const BOT_SKIN := {
	"skin": "#8b5a3c",
	"shirt": "#76b852",
	"shirt_dark": "#4f7b36",
	"accent": "#b5d96a",
	"pants": "#294f2f",
	"hair": "#55352b",
}


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	safety = SafetyClass.new()
	executor = ExecutorClass.new()
	behavior = BehaviorClass.new(RuleProviderClass.new(1), safety, executor)
	behavior.decision_proposed.connect(_on_decision_proposed)
	behavior.decision_rejected.connect(_on_decision_rejected)
	behavior.decision_started.connect(_on_decision_started)
	executor.action_finished.connect(_on_executor_action_finished)
	executor.action_failed.connect(_on_executor_action_failed)


func configure(backend_adapter: Object = null, multiplayer_adapter: Object = null, options: Dictionary = {}) -> void:
	backend = backend_adapter
	network_client = multiplayer_adapter
	protocol_version = int(options.get("protocol_version", protocol_version))
	empty_grace_msec = maxi(0, int(float(options.get("empty_grace_seconds", float(empty_grace_msec) / 1000.0)) * 1000.0))
	observation_radius = maxf(32.0, float(options.get("observation_radius", observation_radius)))
	_strip_progression_gear = bool(options.get("strip_progression_gear", _strip_progression_gear))
	_movement_step_callable = options.get("movement_step", Callable(self, "_default_movement_step")) if options.get("movement_step", Callable(self, "_default_movement_step")) is Callable else Callable(self, "_default_movement_step")
	if options.get("response_enabled", true) is bool:
		safety.response_enabled = bool(options.get("response_enabled", true))
	if options.has("retaliation_window_msec"):
		safety.retaliation_window_msec = maxi(0, int(options.get("retaliation_window_msec", safety.retaliation_window_msec)))
	if options.has("decision_provider") and options.get("decision_provider") is BotDecisionProvider:
		behavior.provider = options.get("decision_provider")
	if options.has("ai_client") and options.get("ai_client") is BotAiClient:
		_bind_ai_client(options.get("ai_client") as BotAiClient)
	elif options.get("ai_options", {}) is Dictionary and not (options.get("ai_options", {}) as Dictionary).is_empty():
		_ensure_ai_client(options.get("ai_options", {}) as Dictionary)
	executor.configure(network_client, Callable(), _movement_step_callable, Callable(safety, "consume_retaliation"))
	_connect_network_signals()


func _ensure_ai_client(ai_options: Dictionary) -> void:
	if ai_client == null:
		ai_client = AiClientClass.new()
		add_child(ai_client)
	ai_client.configure(ai_options)
	_bind_ai_client(ai_client)


func _bind_ai_client(client: BotAiClient) -> void:
	if client == null:
		return
	if ai_client != null and ai_client != client and ai_client.emoji_reply_ready.is_connected(_on_ai_emoji_reply):
		ai_client.emoji_reply_ready.disconnect(_on_ai_emoji_reply)
		if ai_client.request_failed.is_connected(_on_ai_emoji_failed):
			ai_client.request_failed.disconnect(_on_ai_emoji_failed)
	ai_client = client
	if not ai_client.emoji_reply_ready.is_connected(_on_ai_emoji_reply):
		ai_client.emoji_reply_ready.connect(_on_ai_emoji_reply)
	if not ai_client.request_failed.is_connected(_on_ai_emoji_failed):
		ai_client.request_failed.connect(_on_ai_emoji_failed)


func _connect_network_signals() -> void:
	if _network_signals_connected or network_client == null:
		return
	_network_signals_connected = true
	if network_client.has_signal("connected"):
		network_client.connect("connected", Callable(self, "_on_network_connected"))
	if network_client.has_signal("disconnected"):
		network_client.connect("disconnected", Callable(self, "_on_network_disconnected"))
	if network_client.has_signal("message_received"):
		network_client.connect("message_received", Callable(self, "_on_network_message"))


func join_session(record: Dictionary) -> void:
	if _join_in_flight or state in [STATE_JOINING, STATE_SYNCING, STATE_PLAYING]:
		return
	_left_emitted = false
	_disconnect_requested = false
	sync_complete = false
	empty_since_msec = -1
	_empty_emitted = false
	_snapshot_transfer_id = ""
	_snapshot_expected_chunks = 0
	_snapshot_chunks.clear()
	_roster.clear()
	_recent_events.clear()
	_recent_emoji_events.clear()
	_pending_social_emoji = ""
	_pending_social_emoji_target_id = ""
	_emoji_reply_inflight = false
	_last_player_snapshot_msec = -1
	_last_player_input_msec = -1
	_desired_input = {"left": false, "right": false, "jump": false}
	_pending_action_targets.clear()
	_blocked_action_targets.clear()
	_action_loop_blocked_until.clear()
	_terrain_tiles.clear()
	_physics_route.clear()
	_physics_route_target = Vector2i(2147483647, 2147483647)
	_physics_route_target_id = ""
	_physics_route_replan_msec = -1
	_jump_active = false
	_jump_velocity = 0.0
	_jump_ground_y = 0.0
	_jump_start_x = 0.0
	_climb_active = false
	_climb_column = 0
	_climb_time_left_msec = 0
	_support_place_attempted = false
	_support_place_last_attempt_msec = -1
	_was_in_harmful_fluid = false
	_harmful_fluid_damage_cooldown = 0.0
	_guest_defeat_pending = false
	_guest_defeat_retry_after_msec = -1
	_host_player_id = ""
	_pvp_enemy_player_id = ""
	_duel_started = false
	_pvp_chest_opened = false
	_last_duel_ready_msec = -1
	_session_world_mode = str(record.get("world_mode", record.get("mode", ""))).to_lower()
	_craft_pending_output = ""
	_craft_retry_after_msec = -1
	_craft_blocked_outputs.clear()
	_food_eat_cooldown_until_msec = -1
	_inventory_host_revision = 0
	_inventory_client_revision = 0
	_population_logged = false
	_progression_gear_stripped = false
	safety.reset_session()
	_world_snapshot.clear()
	_equipment_slots = {"hand": "", "feet": ""}
	world_id = str(record.get("world_id", ""))
	_set_state(STATE_JOINING)
	if backend == null or not backend.has_method("join_multiplayer_session"):
		_emit_left("backend_unavailable")
		return
	_join_in_flight = true
	var response: Variant = await backend.call(
		"join_multiplayer_session",
		str(record.get("session_id", "")),
		str(record.get("join_code", "")),
		protocol_version,
	)
	_join_in_flight = false
	if state == STATE_LEAVING or _left_emitted:
		return
	if not response is Dictionary or not bool((response as Dictionary).get("ok", false)):
		_emit_left(str((response as Dictionary).get("error", "join_failed")) if response is Dictionary else "join_failed")
		return
	_connect_join_response(response as Dictionary, record)


func connect_join_response(response: Dictionary, record: Dictionary = {}) -> bool:
	return _connect_join_response(response, record)


func _connect_join_response(response: Dictionary, record: Dictionary) -> bool:
	var body: Dictionary = response.get("body", {}) if response.get("body", {}) is Dictionary else {}
	var metadata: Dictionary = body.get("session", {}) if body.get("session", {}) is Dictionary else {}
	if metadata.is_empty():
		metadata = record
	session_id = str(metadata.get("session_id", body.get("session_id", record.get("session_id", ""))))
	world_id = str(metadata.get("world_id", body.get("world_id", world_id)))
	var metadata_world_mode := str(metadata.get("world_mode", metadata.get("mode", ""))).to_lower()
	if not metadata_world_mode.is_empty():
		_session_world_mode = metadata_world_mode
	dedicated_server = bool(metadata.get("dedicated_server", body.get("dedicated_server", false)))
	if network_client == null or not network_client.has_method("connect_with_ticket"):
		_emit_left("network_unavailable")
		return false
	if network_client.has_method("set_session_max_players"):
		network_client.call("set_session_max_players", int(metadata.get("max_players", 4)))
	if network_client.has_method("set_dedicated_server_session"):
		network_client.call("set_dedicated_server_session", dedicated_server)
	if network_client.has_method("set_session_classification") and metadata.has("classification"):
		network_client.call("set_session_classification", str(metadata.get("classification", "")))
	var error: Variant = network_client.call(
		"connect_with_ticket",
		str(body.get("websocket_url", "")),
		str(body.get("ws_ticket", "")),
		str(body.get("join_code", metadata.get("join_code", ""))),
		bool(body.get("relay_fallback_enabled", false)),
		protocol_version,
	)
	if int(error) != OK:
		_emit_left("connect_error_%d" % int(error))
		return false
	return true


func handle_message(message: Dictionary) -> void:
	var kind := str(message.get("kind", ""))
	var message_type := str(message.get("type", ""))
	var payload: Dictionary = message.get("payload", {}) if message.get("payload", {}) is Dictionary else {}
	if kind == "control" and message_type == "player_joined":
		var joined_id := str(message.get("player_id", ""))
		if not _peer_client_version_supported(message):
			leave("legacy_client")
			return
		if sync_complete and not joined_id.is_empty() and joined_id != own_player_id and joined_id != _host_player_id:
			_roster[joined_id] = {"id": joined_id, "health": 10, "alive": true, "role": str(message.get("role", "guest"))}
			if _pvp_enemy_player_id.is_empty() and _is_pvp_world():
				_pvp_enemy_player_id = joined_id
			_record_event("player_joined", {"player_id": joined_id})
			_update_human_count()
		return
	# MultiplayerClient emits its connected signal as soon as the authenticated
	# WebSocket handshake is complete, but the guest's WebRTC data channel is
	# only usable a moment later.  The regular game requests the snapshot from
	# this message path for exactly that reason.  Waiting here prevents the bot's
	# first request from being dropped while the channel is still negotiating.
	if kind == "control" and message_type == "connected":
		if not _connected_peers_supported(message.get("players", [])):
			leave("legacy_client")
			return
		if state in [STATE_JOINING, STATE_SYNCING] and network_client != null and network_client.has_method("send_command"):
			network_client.call("send_command", "snapshot_request", {})
		return
	if kind == "control" and message_type == "player_left":
		var left_id := str(message.get("player_id", ""))
		_roster.erase(left_id)
		_record_event("player_left", {"player_id": left_id})
		_update_human_count()
		return
	if kind == "control" and message_type == "session_closed":
		leave("session_closed")
		return
	if message_type == "snapshot_start":
		_prepare_snapshot(payload)
		return
	if message_type == "snapshot_chunk":
		_prepare_snapshot(payload)
		var transfer_id := str(payload.get("transfer_id", ""))
		if transfer_id == _snapshot_transfer_id:
			var index := int(payload.get("index", -1))
			if index >= 0 and index < _snapshot_chunks.size():
				_snapshot_chunks[index] = str(payload.get("data", ""))
			_apply_snapshot_if_complete()
		return
	if message_type == "snapshot_complete":
		_prepare_snapshot(payload)
		_apply_snapshot_if_complete()
		return
	if message_type == "players_snapshot":
		_apply_players_snapshot(payload)
		return
	if message_type == "creatures_snapshot":
		_apply_creatures_snapshot(payload)
		_record_event(message_type, payload)
		behavior.request_decision(Time.get_ticks_msec())
		return
	if message_type == "player_inventory":
		_apply_inventory_snapshot(payload)
		return
	if message_type == "player_hit":
		if safety.record_player_hit(payload, own_player_id, Time.get_ticks_msec()):
			_record_event("player_hit", {"attacker_player_id": safety.attacker_player_id(), "damage": int(payload.get("damage", 0))})
		else:
			_record_event("player_hit_unattributed", {"target_player_id": str(payload.get("target_player_id", ""))})
		behavior.request_decision(Time.get_ticks_msec())
		return
	if message_type == "duel_start":
		_record_event("duel_start", payload)
		_duel_started = true
		# The host can open the lobby with a generic world snapshot and only then
		# switch the simulation to the duel ruleset. Promote that transition here
		# so the bot does not spend the match mining or wandering before it pins
		# its single opponent.
		var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
		generation["mode"] = "duel"
		_world_snapshot["generation"] = generation
		if _pvp_enemy_player_id.is_empty() and not _roster.is_empty():
			_pvp_enemy_player_id = str(_roster.keys()[0])
		behavior.request_decision(Time.get_ticks_msec())
		return
	if message_type == "action_result":
		_handle_action_result(payload)
		_record_event(message_type, payload)
		return
	if message_type == "tile_batch":
		_apply_tile_batch(payload)
		_record_event(message_type, payload)
		return
	if message_type == "plant_batch":
		_apply_plant_batch(payload)
		_record_event(message_type, payload)
		return
	if message_type == "emoji_reaction":
		_record_event(message_type, payload)
		_record_emoji_event(message, payload)
		behavior.request_decision(Time.get_ticks_msec())
		return
	if message_type in ["emoji_reaction", "creatures_snapshot", "tile_batch", "plant_batch", "region_complete"]:
		_record_event(message_type, payload)


func _process(delta: float) -> void:
	var now_msec := Time.get_ticks_msec()
	if state == STATE_SYNCING:
		if _sync_started_msec >= 0 and now_msec - _sync_started_msec >= DEFAULT_SYNC_TIMEOUT_MSEC:
			_emit_left("snapshot_timeout")
		return
	if state != STATE_PLAYING:
		return
	_expire_craft_pending(now_msec)
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	# Hazard contact must tick even while WAIT/idle, otherwise a bot standing in
	# lava only takes damage when a movement action happens to run physics.
	_apply_local_harmful_fluid(self_state, delta)
	_world_snapshot["self"] = self_state
	var self_alive := int(self_state.get("health", 10)) > 0
	if not self_alive:
		_set_desired_input(false, false, false)
		_send_guest_defeat_if_due(now_msec)
		_send_player_input_if_due(now_msec)
		_send_player_snapshot_if_due(now_msec)
		return
	_guest_defeat_pending = false
	var observation := _build_observation(now_msec)
	if _is_pvp_world() and not _duel_started and now_msec - _last_duel_ready_msec >= 1000:
		_send_duel_ready(now_msec)
	# The brain may run at a much lower cadence than physics. Reset the held
	# controls every frame; a movement executor reasserts them for this frame.
	_desired_input = {"left": false, "right": false, "jump": false}
	behavior.tick(observation, delta, now_msec)
	_send_player_input_if_due(now_msec)
	# Keep the legacy snapshot during rollout. New hosts ignore its coordinates
	# after the first player_input packet, while old hosts can still display the
	# bot until they receive the new protocol.
	_send_player_snapshot_if_due(now_msec)
	if not _empty_emitted and Perception.empty_world_should_leave(sync_complete, human_player_count, empty_since_msec, now_msec, empty_grace_msec):
		_empty_emitted = true
		empty_world_ready.emit()


func leave(reason: String = "leaving") -> void:
	if _left_emitted:
		return
	_set_state(STATE_LEAVING)
	_disconnect_requested = true
	behavior.reset(Time.get_ticks_msec())
	if network_client != null and network_client.has_method("disconnect_from_session"):
		network_client.call("disconnect_from_session")
	_emit_left(reason)


func _on_network_connected(role: String, player_id: String, network_session_id: String) -> void:
	if state != STATE_JOINING and state != STATE_SYNCING:
		return
	if role != "guest":
		_emit_left("unexpected_role")
		return
	own_player_id = player_id
	_host_player_id = _host_id_from_network()
	if not network_session_id.is_empty():
		session_id = network_session_id
	_set_state(STATE_SYNCING)
	_sync_started_msec = Time.get_ticks_msec()
	sync_started.emit(session_id)


func _send_player_snapshot_if_due(now_msec: int) -> void:
	if network_client == null or not network_client.has_method("send_command") or own_player_id.is_empty():
		return
	if _last_player_snapshot_msec >= 0 and now_msec - _last_player_snapshot_msec < PLAYER_SNAPSHOT_INTERVAL_MSEC:
		return
	_last_player_snapshot_msec = now_msec
	var local: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	network_client.call("send_command", "player_snapshot", {
		"x": float(local.get("x", 0.0)),
		"y": float(local.get("y", 0.0)),
		"facing": int(local.get("facing", 1)),
		"vx": float(local.get("vx", 0.0)),
		"vy": float(local.get("vy", 0.0)),
		"on_ground": bool(local.get("on_ground", false)),
		"tree_ghost": bool(local.get("tree_ghost", false)),
		"climbing": bool(local.get("climbing", false)),
		"climb_col": int(local.get("climb_col", -1)),
		"health": clampi(int(local.get("health", 10)), 0, 10),
		"nourishment": clampi(int(local.get("nourishment", 100)), 0, 100),
		"respawn_revision": int(local.get("respawn_revision", 0)),
		"skin": BOT_SKIN.duplicate(true),
		"equipment_slots": _replicated_equipment_slots(),
	})


func _send_player_input_if_due(now_msec: int) -> void:
	if network_client == null or not network_client.has_method("send_command") or own_player_id.is_empty():
		return
	if _last_player_input_msec >= 0 and now_msec - _last_player_input_msec < PLAYER_INPUT_INTERVAL_MSEC:
		return
	_last_player_input_msec = now_msec
	network_client.call("send_command", "player_input", {
		"left": bool(_desired_input.get("left", false)),
		"right": bool(_desired_input.get("right", false)),
		"jump": bool(_desired_input.get("jump", false)),
	})


func _default_movement_step(action: String, decision: Dictionary, observation: Dictionary, delta: float) -> Dictionary:
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	var origin := Contract.target_position(self_state)
	var target := Contract.target_position(decision.get("target", {}))
	var target_id := str(decision.get("target_id", ""))
	if target_id != "":
		for raw_player in observation.get("players", []):
			if raw_player is Dictionary and str((raw_player as Dictionary).get("id", "")) == target_id:
				target = Contract.target_position(raw_player)
				break

	if action == Contract.ACTION_LOOK_AT:
		_set_desired_input(false, false, false)
		_jump_active = false
		_climb_active = false
		_advance_local_physics(self_state, delta, false)
		if target.x != origin.x:
			self_state["facing"] = 1 if target.x > origin.x else -1
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "look_complete"}
	if target == origin and not _jump_active and not _climb_active:
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "already_at_target"}

	var destination := target
	if action in [Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_FOLLOW]:
		destination = Navigator.preferred_follow_target(Vector2(target.x, origin.y), origin, float(observation.get("preferred_player_distance", 84.0)))
	elif action == Contract.ACTION_FLEE_FROM:
		destination = Navigator.step_away_from(origin, Vector2(target.x, origin.y), 120.0)
	elif action == Contract.ACTION_MOVE_TO and _is_pvp_world():
		# Preserve the enemy's vertical position in a duel. The previous generic
		# movement branch flattened every destination to the bot's current Y, so a
		# player who jumped onto a block looked horizontally reachable and the bot
		# waited instead of starting a jump.
		destination = target
	else:
		destination.y = origin.y
	# In a duel, never let the short-horizon jump planner consume an input at
	# the island lip.  The bridge planner needs the bot grounded at the edge;
	# checking only after route/jump selection lets one speculative jump start an
	# airborne arc and the recovery helper then places a block in mid-air.
	var pvp_surface_y := float(WorldSim.ISLAND_CY * BlockDefs.TILE) - float(self_state.get("h", 28.0))
	var pvp_grounded_window := bool(self_state.get("on_ground", false)) or absf(origin.y - pvp_surface_y) <= float(BlockDefs.TILE) * 3.0
	if _is_pvp_world() and pvp_grounded_window and _pvp_gap_ahead(origin, destination):
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "edge_guard"}

	# Duel traversal has a dedicated one-cell bridge planner.  The generic
	# short-horizon route is allowed to invent jump arcs over unknown cells and
	# makes the guest oscillate above the bridge instead of requesting its next
	# support block.  The arena lane is flat, so keep this transition grounded.
	var route_step := {} if _is_pvp_world() else _physics_route_step(origin, destination, target_id)
	var route_kind := str(route_step.get("kind", ""))
	if not route_step.is_empty():
		destination = route_step.get("position", destination)
	var hint := ""
	if _is_pvp_world():
		hint = _pvp_jump_hint(origin, destination)
	else:
		hint = route_kind if route_kind in ["jump", "climb"] else _movement_hint(origin, destination)
	if _climb_active or hint == "climb":
		_set_desired_input(signf(destination.x - origin.x) < 0.0, signf(destination.x - origin.x) > 0.0, true)
		return _climb_step(self_state, destination, delta)
	if hint == "jump" and not _jump_active:
		_jump_active = true
		_jump_start_x = float(self_state.get("x", origin.x))
	if _jump_active:
		_set_desired_input(signf(destination.x - origin.x) < 0.0, signf(destination.x - origin.x) > 0.0, true)
		return _jump_step(self_state, destination, delta)

	var direction := signf(destination.x - origin.x)
	# Movement snapshots are still needed for older P2P hosts.  Run those
	# snapshots through the same collision/gravity adapter as the dedicated
	# host instead of teleporting x/y and claiming the player is grounded.
	if bool(self_state.get("on_ground", false)) and _would_step_into_void(origin, destination):
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		# Finish the movement action at a safe edge so the rule provider can
		# re-evaluate the next step. In PvP this hands control to the bounded
		# bridge planner instead of holding MOVE_TO until the bot walks/falls off
		# the island.
		return {"done": true, "reason": "edge_guard"}
	# Flee may still need to step out of lava underfoot. Ordinary MOVE_TO /
	# FOLLOW / wander must not walk onto a known lava column.
	if action != Contract.ACTION_FLEE_FROM and bool(self_state.get("on_ground", false)) and _would_step_into_lava(origin, destination):
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "lava_guard"}
	_set_desired_input(direction < 0.0, direction > 0.0, false)
	_advance_local_physics(self_state, delta, false)
	var next_position := Contract.target_position(self_state)
	var horizontal_progress := absf(next_position.x - origin.x)
	var blocked_ahead := (
		bool(self_state.get("on_ground", false))
		and not is_zero_approx(direction)
		and horizontal_progress < 0.25
		and not _local_collision(
			float(self_state.get("x", origin.x)) + direction * 2.0,
			float(self_state.get("y", origin.y)),
			float(self_state.get("w", 20.0)),
			float(self_state.get("h", 28.0)),
		).is_empty()
	)
	if blocked_ahead:
		# Never keep holding into a solid wall. Finish this movement action so the
		# next behavior decision can choose a different target or interaction.
		_physics_route.clear()
		_physics_route_replan_msec = 0
		_set_desired_input(false, false, false)
		self_state["vx"] = 0.0
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "blocked_obstacle"}
	var done := next_position.distance_to(destination) <= 8.0 and bool(self_state.get("on_ground", false))
	if done:
		_set_desired_input(false, false, false)
		self_state["vx"] = 0.0
	_world_snapshot["self"] = self_state
	return {"done": done, "reason": "movement_step"}


func _pvp_jump_hint(origin: Vector2, destination: Vector2) -> String:
	# The edge guard above still owns void traversal and bridge placement. Once
	# the bot is on a solid island, use the same collision-aware jump hint as
	# ordinary worlds and additionally jump when the pinned opponent is visibly
	# above us. This keeps duel traversal grounded without disabling pursuit.
	var terrain_hint := _movement_hint(origin, destination)
	if terrain_hint in ["jump", "climb"]:
		return terrain_hint
	if destination.y < origin.y - float(BlockDefs.TILE) * 0.45:
		return "jump"
	return ""


func _pvp_gap_ahead(origin: Vector2, destination: Vector2) -> bool:
	if not _is_pvp_world():
		return false
	var direction := signf(destination.x - origin.x)
	if is_zero_approx(direction):
		return false
	var support := _support_tile_for_position(origin)
	var next_x := support.x + int(direction)
	# A bridge placement is acknowledged by the host asynchronously. Once the
	# tile batch containing that block arrives, it is a valid support cell and
	# must let the movement controller advance onto it. Without this guard the
	# edge check below keeps treating the same island lip as a void forever,
	# causing an endless MOVE_TO -> edge_guard loop after the first bridge block.
	if _terrain_solid_at(next_x, support.y):
		return false
	# Stop before any empty next column on the duel lane — the unfinished bridge
	# tip is the same hazard as the original island lip.
	if _terrain_solid_at(next_x, support.y + 1):
		return false
	return not _terrain_tiles.has("%d:%d" % [next_x, support.y]) or str(_terrain_tiles.get("%d:%d" % [next_x, support.y], "")).is_empty()


func _set_desired_input(move_left: bool, move_right: bool, jump: bool) -> void:
	# Never hold both horizontal buttons. This mirrors the mobile/desktop input
	# resolver and keeps a target exactly on the bot's x-axis from oscillating.
	_desired_input = {
		"left": move_left and not move_right,
		"right": move_right and not move_left,
		"jump": jump,
	}


func _physics_route_step(origin: Vector2, destination: Vector2, target_id: String) -> Dictionary:
	if _terrain_tiles.is_empty():
		return {}
	var origin_tile := _support_tile_for_position(origin)
	var target_tile := _support_tile_for_position(destination)
	var now := Time.get_ticks_msec()
	var needs_replan := (
		_physics_route.is_empty()
		or _physics_route_target != target_tile
		or _physics_route_target_id != target_id
		or _physics_route_replan_msec < 0
		or now >= _physics_route_replan_msec
	)
	if needs_replan:
		_physics_route = Navigator.physics_route(
			origin_tile,
			target_tile,
			Callable(self, "_terrain_standable_tile"),
			Callable(self, "_terrain_climbable_tile"),
		)
		_physics_route_target = target_tile
		_physics_route_target_id = target_id
		_physics_route_replan_msec = now + 450
	if _physics_route.size() <= 1:
		return {}
	while _physics_route.size() > 1:
		var next_tile: Vector2i = _physics_route[1].get("tile", origin_tile)
		var next_position := _world_position_for_support_tile(next_tile)
		if origin.distance_to(next_position) > 12.0:
			return {
				"position": next_position,
				"kind": str(_physics_route[1].get("kind", "walk")),
			}
		_physics_route.pop_front()
	return {}


func _support_tile_for_position(position: Vector2) -> Vector2i:
	return Vector2i(
		floori((position.x + 10.0) / float(BlockDefs.TILE)),
		floori((position.y + 28.0) / float(BlockDefs.TILE)),
	)


func _world_position_for_support_tile(tile: Vector2i) -> Vector2:
	return Vector2(
		(float(tile.x) + 0.5) * float(BlockDefs.TILE) - 10.0,
		float(tile.y * BlockDefs.TILE) - 28.0,
	)


func _terrain_standable_tile(tile: Vector2i) -> bool:
	return (
		_terrain_solid_at(tile.x, tile.y)
		and not _terrain_solid_at(tile.x, tile.y - 1)
		and not _terrain_solid_at(tile.x, tile.y - 2)
	)


func _terrain_climbable_tile(tile: Vector2i) -> bool:
	return (
		_terrain_climbable_at(tile.x, tile.y)
		or _terrain_climbable_at(tile.x, tile.y - 1)
		or _terrain_climbable_at(tile.x, tile.y + 1)
	)


func _rebuild_terrain_index(raw_tiles: Variant) -> void:
	_terrain_tiles.clear()
	if not raw_tiles is Array:
		return
	for raw_tile in raw_tiles:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var name := _block_name_for_content_id(str(tile.get("content_id", "")))
		if name.is_empty():
			name = str(tile.get("block_name", ""))
		if not name.is_empty():
			_terrain_tiles["%d:%d" % [int(tile.get("x", 0)), int(tile.get("y", 0))]] = name
	_physics_route_replan_msec = 0


func _rebuild_plant_index(raw_plants: Variant) -> void:
	_plant_tiles.clear()
	if not raw_plants is Array:
		return
	for raw_plant in raw_plants:
		if not raw_plant is Dictionary:
			continue
		_ingest_plant_entry(raw_plant as Dictionary)


func _seed_tree_growth_resources(raw_growth: Variant) -> void:
	# Growing trees place wood/leaves over time. Until those tile_batches arrive,
	# keep the known trunk/foliage cells visible so the bot can climb them.
	if not raw_growth is Array:
		return
	for raw_entry in raw_growth:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		var data: Dictionary = entry.get("data", {}) if entry.get("data", {}) is Dictionary else {}
		var trunk := str(data.get("trunk_block_name", "wood"))
		var foliage := str(data.get("foliage_block_name", "leaves"))
		var anchor_x := int(entry.get("x", 0))
		var anchor_y := int(entry.get("y", 0))
		_terrain_tiles["%d:%d" % [anchor_x, anchor_y]] = trunk if not trunk.is_empty() else "wood"
		for dy in range(0, 6):
			var key := "%d:%d" % [anchor_x, anchor_y - dy]
			if not _terrain_tiles.has(key):
				_terrain_tiles[key] = trunk if dy < 4 else foliage


func _apply_plant_batch(payload: Dictionary) -> void:
	var plants: Array = payload.get("plants", []) if payload.get("plants", []) is Array else []
	for raw_plant in plants:
		if raw_plant is Dictionary:
			_ingest_plant_entry(raw_plant as Dictionary)


func _ingest_plant_entry(entry: Dictionary) -> void:
	var anchor_x := int(entry.get("anchor_x", entry.get("x", 0)))
	var anchor_y := int(entry.get("anchor_y", entry.get("y", 0)))
	var data: Dictionary = entry.get("data", {}) if entry.get("data", {}) is Dictionary else {}
	var exists := bool(entry.get("exists", true))
	if entry.has("data") and data.is_empty():
		exists = false
	var block_name := str(entry.get("block_name", data.get("block_name", "leaves")))
	if block_name.is_empty():
		block_name = "leaves"
	# Map growable plants onto craftable leaf/wood so trail boots and planks can
	# still progress when the host only synced the plant overlay.
	if block_name.contains("pine"):
		block_name = "pine_needles"
	elif block_name.contains("palm"):
		block_name = "palm_leaves"
	elif block_name.contains("weeping"):
		block_name = "weeping_leaves"
	elif block_name.contains("plant") or block_name.contains("oak") or block_name.contains("tree"):
		block_name = "leaves"
	var cells: Array = entry.get("cells", data.get("cells", [])) if entry.get("cells", data.get("cells", [])) is Array else []
	if cells.is_empty():
		cells = [{"x": anchor_x, "y": anchor_y}]
	for raw_cell in cells:
		var cell_x := anchor_x
		var cell_y := anchor_y
		if raw_cell is Dictionary:
			cell_x = int((raw_cell as Dictionary).get("x", anchor_x))
			cell_y = int((raw_cell as Dictionary).get("y", anchor_y))
		elif raw_cell is Vector2i:
			cell_x = (raw_cell as Vector2i).x
			cell_y = (raw_cell as Vector2i).y
		var key := "%d:%d" % [cell_x, cell_y]
		if exists:
			_plant_tiles[key] = block_name
		else:
			_plant_tiles.erase(key)


func _seed_duel_fallback_terrain() -> void:
	"""Keep both deterministic duel island surfaces collidable for a guest.

	P2P hosts can send a snapshot centered on their own island. A bot that
	spawns on the opposite island would otherwise see no support tiles, run its
	local physics through empty space, and only then attempt a bridge while
	falling. Seed only the known surface row and never overwrite authoritative
	tiles; subsequent tile batches remain the source of truth for every change.
	"""
	for start_x in [-24, 12]:
		for tile_x in range(start_x, start_x + 12):
			var key := "%d:%d" % [tile_x, 8]
			if not _terrain_tiles.has(key):
				_terrain_tiles[key] = "grass"
	_physics_route_replan_msec = 0


func _apply_tile_batch(payload: Dictionary) -> void:
	var tiles: Array = payload.get("tiles", []) if payload.get("tiles", []) is Array else []
	for raw_tile in tiles:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var tile_x := int(tile.get("x", 0))
		var tile_y := int(tile.get("y", 0))
		var key := "%d:%d" % [tile_x, tile_y]
		var name := _block_name_for_content_id(str(tile.get("content_id", "")))
		if name.is_empty():
			name = str(tile.get("block_name", ""))
		if name.is_empty() and tile.has("block_id"):
			var defs := get_node_or_null("/root/BlockDefs")
			if defs != null and defs.has_method("get_block_name"):
				name = str(defs.call("get_block_name", int(tile.get("block_id", 0))))
		if int(tile.get("block_id", 1)) == 0 or name == "air":
			_terrain_tiles.erase(key)
		elif not name.is_empty():
			_terrain_tiles[key] = name
		# Host death caches / chests arrive on the same tile_batch as terrain.
		# Without this merge the bot never learns about a cache created after join
		# (including its own drop after lava/combat defeat).
		if tile.has("container"):
			_update_snapshot_container(key, tile.get("container", null))
	_physics_route_replan_msec = 0


func _terrain_name_at(tx: int, ty: int) -> String:
	return str(_terrain_tiles.get("%d:%d" % [tx, ty], ""))


func _terrain_solid_at(tx: int, ty: int) -> bool:
	var name := _terrain_name_at(tx, ty)
	return not name.is_empty() and bool(_block_entry(name).get("solid", false))


func _terrain_climbable_at(tx: int, ty: int) -> bool:
	var name := _terrain_name_at(tx, ty).to_lower()
	if name.is_empty():
		name = str(_plant_tiles.get("%d:%d" % [tx, ty], "")).to_lower()
	if name.is_empty():
		return false
	return (
		name in ["wood", "leaves", "pine_needles", "shagot_scaffold"]
		or name.ends_with("_wood")
		or name.ends_with("_leaves")
		or name.ends_with("_needles")
	)


func _local_ignores_trees(self_state: Dictionary) -> bool:
	return bool(self_state.get("tree_ghost", false)) or bool(self_state.get("climbing", false)) or _climb_active


func _local_overlaps_climbable(self_state: Dictionary) -> bool:
	var px := float(self_state.get("x", 0.0))
	var py := float(self_state.get("y", 0.0))
	var width := float(self_state.get("w", 20.0))
	var height := float(self_state.get("h", 28.0))
	var left := floori(px / float(BlockDefs.TILE))
	var right := floori((px + width - 0.001) / float(BlockDefs.TILE))
	var top := floori(py / float(BlockDefs.TILE))
	var bottom := floori((py + height - 0.001) / float(BlockDefs.TILE))
	for tile_y in range(top, bottom + 1):
		for tile_x in range(left, right + 1):
			if _terrain_climbable_at(tile_x, tile_y):
				return true
	return false


func _side_climbable_hit(self_state: Dictionary, direction: float) -> bool:
	if is_zero_approx(direction):
		return false
	var width := float(self_state.get("w", 20.0))
	var height := float(self_state.get("h", 28.0))
	var probe := 3.0
	var next_x := float(self_state.get("x", 0.0)) + (probe if direction > 0.0 else -probe)
	var hit := _local_collision(next_x, float(self_state.get("y", 0.0)), width, height, false)
	if hit.is_empty():
		return false
	var tile_x := floori(float(hit.get("bx", 0.0)) / float(BlockDefs.TILE))
	var tile_y := floori(float(hit.get("by", 0.0)) / float(BlockDefs.TILE))
	return _terrain_climbable_at(tile_x, tile_y)


func _update_local_tree_ghost(self_state: Dictionary, direction: float) -> void:
	"""Mirror WorldSim tree traversal so foliage is passable instead of a cage.

	Seeded tree-growth cells and live leaf batches are solid for normal walking.
	Without tree_ghost the bot wedges inside the canopy while mining or climbing.
	"""
	if _local_ignores_trees(self_state):
		if not _climb_active and not _local_overlaps_climbable(self_state) and not _side_climbable_hit(self_state, direction):
			self_state["tree_ghost"] = false
			self_state["climbing"] = false
			self_state["climb_col"] = -1
		return
	if bool(self_state.get("on_ground", false)) and _side_climbable_hit(self_state, direction):
		self_state["tree_ghost"] = true
		return
	# Already embedded in foliage (mining, host snap, growth seed) — ghost instead
	# of fighting the canopy as an ordinary wall.
	if _local_overlaps_climbable(self_state):
		self_state["tree_ghost"] = true


func _movement_hint(origin: Vector2, destination: Vector2) -> String:
	var direction := signf(destination.x - origin.x)
	if is_zero_approx(direction):
		return ""
	var center_x := origin.x + 10.0
	var ground_tile_y := floori((origin.y + 28.0) / float(BlockDefs.TILE))
	var next_tile_x := floori((center_x + direction * 18.0) / float(BlockDefs.TILE))
	if _terrain_climbable_at(next_tile_x, ground_tile_y) or _terrain_climbable_at(next_tile_x, ground_tile_y - 1):
		return "climb"
	if _terrain_solid_at(next_tile_x, ground_tile_y - 1):
		return "jump"
	# A one-block drop ahead is a small pit. Short gaps are jumpable; wider gaps
	# remain a reason to slow down rather than repeatedly launch into the void.
	if not _terrain_solid_at(next_tile_x, ground_tile_y) and _terrain_solid_at(next_tile_x, ground_tile_y + 1):
		return "jump"
	return ""


func _jump_step(self_state: Dictionary, destination: Vector2, delta: float) -> Dictionary:
	var origin := Contract.target_position(self_state)
	if not _jump_active:
		_jump_active = true
		_jump_start_x = origin.x
	var direction := signf(destination.x - origin.x)
	_set_desired_input(direction < 0.0, direction > 0.0, true)
	var was_airborne := not bool(self_state.get("on_ground", false))
	_advance_local_physics(self_state, delta, true)
	var landed := was_airborne and bool(self_state.get("on_ground", false))
	if landed:
		_jump_active = false
	var next_x := float(self_state.get("x", origin.x))
	_world_snapshot["self"] = self_state
	if landed and absf(next_x - _jump_start_x) < 4.0 and absf(destination.x - next_x) > 8.0:
		_physics_route.clear()
		_physics_route_replan_msec = 0
		_set_desired_input(false, false, false)
		self_state["vx"] = 0.0
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "blocked_obstacle"}
	return {"done": landed and absf(destination.x - next_x) <= 8.0, "reason": "jump_step"}


func _advance_local_physics(self_state: Dictionary, delta: float, jump_pressed: bool) -> void:
	"""Apply a small, deterministic copy of WorldSim player physics.

	Older P2P hosts do not simulate guest input.  Their only view of the bot is
	the player_snapshot stream, so that stream must contain collision-resolved
	coordinates rather than a kinematic target position that can float over a
	gap.  Dedicated hosts still correct these values from their own simulation.
	"""
	_eject_local_self_from_solid(self_state)
	var step := clampf(maxf(delta, 0.0) * NETWORK_PHYSICS_TICKS_PER_SECOND, 0.25, 2.0)
	var width := float(self_state.get("w", 20.0))
	var height := float(self_state.get("h", 28.0))
	var x := float(self_state.get("x", 0.0))
	var y := float(self_state.get("y", 0.0))
	var vx := float(self_state.get("vx", 0.0))
	var vy := float(self_state.get("vy", 0.0))
	var on_ground := bool(self_state.get("on_ground", false))
	var direction := (-1.0 if bool(_desired_input.get("left", false)) else (1.0 if bool(_desired_input.get("right", false)) else 0.0))
	_update_local_tree_ghost(self_state, direction)
	var ignore_trees := _local_ignores_trees(self_state)
	var target_vx := direction * BlockDefs.MOVE
	vx = lerpf(vx, target_vx, clampf(step, 0.0, 1.0)) if on_ground else target_vx
	if jump_pressed and on_ground:
		vy = BlockDefs.JUMP
		on_ground = false
	elif on_ground:
		vy = 0.0
	else:
		vy += BlockDefs.GRAVITY * step

	var substeps := maxi(1, int(ceil(maxf(absf(vx), absf(vy)) * step / 6.0)))
	var substep := step / float(substeps)
	for _index in substeps:
		if not is_zero_approx(vx):
			var next_x := x + vx * substep
			var horizontal_hit := _local_collision(next_x, y, width, height, ignore_trees)
			if horizontal_hit.is_empty():
				x = next_x
			else:
				# Walking into a tree trunk/foliage should ghost, not pin the
				# avatar against the canopy like a stone wall.
				var hit_tx := floori(float(horizontal_hit.get("bx", 0.0)) / float(BlockDefs.TILE))
				var hit_ty := floori(float(horizontal_hit.get("by", 0.0)) / float(BlockDefs.TILE))
				if not ignore_trees and _terrain_climbable_at(hit_tx, hit_ty):
					self_state["tree_ghost"] = true
					ignore_trees = true
					x = next_x
				else:
					x = float(horizontal_hit.get("bx", x)) - width if vx > 0.0 else float(horizontal_hit.get("bx", x)) + float(BlockDefs.TILE)
					vx = 0.0
		var next_y := y + vy * substep
		var vertical_hit := _local_collision(x, next_y, width, height, ignore_trees)
		if vertical_hit.is_empty():
			y = next_y
			on_ground = is_zero_approx(vy) and not _local_collision(x, y + 1.5, width, height, ignore_trees).is_empty()
		else:
			var hit_tx := floori(float(vertical_hit.get("bx", 0.0)) / float(BlockDefs.TILE))
			var hit_ty := floori(float(vertical_hit.get("by", 0.0)) / float(BlockDefs.TILE))
			if not ignore_trees and _terrain_climbable_at(hit_tx, hit_ty) and vy < 0.0:
				# Rising into foliage (jump/climb) ghosts instead of ceiling-sticking.
				self_state["tree_ghost"] = true
				ignore_trees = true
				y = next_y
				on_ground = false
			else:
				var hit_y := float(vertical_hit.get("by", y))
				if vy >= 0.0:
					y = hit_y - height
					on_ground = true
				else:
					y = hit_y + float(BlockDefs.TILE)
					on_ground = false
				vy = 0.0

	self_state["x"] = x
	self_state["y"] = y
	self_state["vx"] = vx
	self_state["vy"] = vy
	self_state["facing"] = -1 if direction < 0.0 else (1 if direction > 0.0 else int(self_state.get("facing", 1)))
	self_state["on_ground"] = on_ground
	_update_local_tree_ghost(self_state, direction)
	if on_ground:
		# A support placement is scoped to one airborne arc.  Re-arm only after
		# the authoritative/local collision adapter has put the bot on ground.
		_support_place_attempted = false
	else:
		_try_place_support_block(self_state)


func _local_touches_harmful_fluid(self_state: Dictionary) -> bool:
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var height := maxf(1.0, float(self_state.get("h", 28.0)))
	var left := floori(float(self_state.get("x", 0.0)) / float(BlockDefs.TILE))
	var right := floori((float(self_state.get("x", 0.0)) + width - 0.001) / float(BlockDefs.TILE))
	var top := floori(float(self_state.get("y", 0.0)) / float(BlockDefs.TILE))
	var bottom := floori((float(self_state.get("y", 0.0)) + height - 0.001) / float(BlockDefs.TILE))
	for tile_y in range(top, bottom + 1):
		for tile_x in range(left, right + 1):
			var name := _terrain_name_at(tile_x, tile_y).to_lower()
			if name == "lava" or name.ends_with(".lava"):
				return true
			var entry := _block_entry(name)
			if bool(entry.get("fluid", false)) and float(entry.get("temperature", 0.0)) >= 0.8:
				return true
	return false


func _apply_local_harmful_fluid(self_state: Dictionary, delta: float) -> void:
	_harmful_fluid_damage_cooldown = maxf(0.0, _harmful_fluid_damage_cooldown - maxf(delta, 0.0))
	var touching := _local_touches_harmful_fluid(self_state)
	if touching and (not _was_in_harmful_fluid or _harmful_fluid_damage_cooldown <= 0.0):
		var health := maxi(0, int(self_state.get("health", 10)) - 1)
		self_state["health"] = health
		_harmful_fluid_damage_cooldown = HARMFUL_FLUID_DAMAGE_INTERVAL
		if health <= 0:
			_guest_defeat_pending = true
			_guest_defeat_retry_after_msec = 0
			structured_log.emit({
				"event": "local_lava_defeat",
				"health": health,
				"at_msec": Time.get_ticks_msec(),
			})
	_was_in_harmful_fluid = touching


func _send_guest_defeat_if_due(now_msec: int) -> void:
	if not _guest_defeat_pending:
		return
	if _guest_defeat_retry_after_msec >= 0 and now_msec < _guest_defeat_retry_after_msec:
		return
	if network_client == null or not network_client.has_method("send_command"):
		return
	var local: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	network_client.call("send_command", "player_defeated", {
		"respawn_revision": int(local.get("respawn_revision", 0)),
	})
	_guest_defeat_retry_after_msec = now_msec + GUEST_DEFEAT_RETRY_MSEC
	structured_log.emit({
		"event": "guest_defeat_requested",
		"respawn_revision": int(local.get("respawn_revision", 0)),
		"at_msec": now_msec,
	})


func _eject_local_self_from_solid(self_state: Dictionary) -> void:
	"""Stop local prediction from tunneling once already overlapping a solid tile.

	Incomplete tile streams or a delayed host snap can embed the avatar. Ordinary
	per-axis resolution then walks through the wall one cell at a time and older
	hosts that still trust player_snapshot show the bot clipping.
	"""
	# Foliage/wood use WorldSim's tree-ghost passage. Prefer that over shoving the
	# avatar out of a canopy cell, which left the bot oscillating inside leaves.
	if _local_overlaps_climbable(self_state) and _local_collision(
		float(self_state.get("x", 0.0)),
		float(self_state.get("y", 0.0)),
		float(self_state.get("w", 20.0)),
		float(self_state.get("h", 28.0)),
		true,
	).is_empty():
		self_state["tree_ghost"] = true
		return
	var width := float(self_state.get("w", 20.0))
	var height := float(self_state.get("h", 28.0))
	var ignore_trees := _local_ignores_trees(self_state)
	for _attempt in 8:
		var hit := _local_collision(
			float(self_state.get("x", 0.0)),
			float(self_state.get("y", 0.0)),
			width,
			height,
			ignore_trees,
		)
		if hit.is_empty():
			return
		var mid := float(self_state.get("x", 0.0)) + width * 0.5
		var block_mid := float(hit.get("bx", 0.0)) + float(BlockDefs.TILE) * 0.5
		if mid < block_mid:
			self_state["x"] = float(hit.get("bx", self_state.get("x", 0.0))) - width
		else:
			self_state["x"] = float(hit.get("bx", self_state.get("x", 0.0))) + float(BlockDefs.TILE)
		var vertical := _local_collision(float(self_state.get("x", 0.0)), float(self_state.get("y", 0.0)), width, height, ignore_trees)
		if not vertical.is_empty():
			var feet := float(self_state.get("y", 0.0)) + height
			var block_top := float(vertical.get("by", feet))
			if feet > block_top:
				self_state["y"] = block_top - height
			else:
				self_state["y"] = float(vertical.get("by", self_state.get("y", 0.0))) + float(BlockDefs.TILE)
		self_state["vx"] = 0.0
		self_state["vy"] = 0.0


func _try_place_support_block(self_state: Dictionary) -> bool:
	"""Ask the authoritative host to place one solid block beneath a falling bot.

	This is deliberately a network action, not a local position correction.  It
	is only attempted while the player is descending, and the host still applies
	its normal reach, collision, inventory, and placement validation.
	"""
	if _support_place_attempted or network_client == null or not network_client.has_method("send_command"):
		return false
	# PvP gaps are handled by the grounded one-cell bridge planner.  Do not
	# place beneath an airborne duel avatar: that creates a misleading vertical
	# pillar when a stale remote snapshot already drifted below the island.
	if _is_pvp_world():
		return false
	if bool(self_state.get("on_ground", false)) or float(self_state.get("vy", 0.0)) <= 0.05:
		return false
	var now_msec := Time.get_ticks_msec()
	if _support_place_last_attempt_msec >= 0 and now_msec - _support_place_last_attempt_msec < SUPPORT_PLACE_COOLDOWN_MSEC:
		return false
	var block_name := _support_block_name()
	if block_name.is_empty():
		return false
	var target := _support_place_target(self_state)
	if target == SUPPORT_PLACE_INVALID_TILE:
		return false
	var payload := {"x": target.x, "y": target.y, "block_name": block_name, "block": block_name}
	var sent: Variant = network_client.call("send_command", "place_block", payload)
	if sent is bool and not bool(sent):
		return false
	_support_place_attempted = true
	_support_place_last_attempt_msec = now_msec
	var key := "%d:%d" % [target.x, target.y]
	_pending_action_targets[key] = {
		"action": Contract.ACTION_PLACE,
		"block": block_name,
		"content_id": str(_block_entry(block_name).get("content_id", "")),
	}
	structured_log.emit({
		"event": "support_block_place_requested",
		"x": target.x,
		"y": target.y,
		"block": block_name,
		"at_msec": now_msec,
	})
	return true


func _support_place_target(self_state: Dictionary) -> Vector2i:
	if bool(self_state.get("on_ground", false)) or float(self_state.get("vy", 0.0)) <= 0.05:
		return SUPPORT_PLACE_INVALID_TILE
	var x := float(self_state.get("x", 0.0))
	var y := float(self_state.get("y", 0.0))
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var height := maxf(1.0, float(self_state.get("h", 28.0)))
	var tx := floori((x + width * 0.5) / float(BlockDefs.TILE))
	# Use the first complete cell below the player's feet.  This prevents the
	# placement from intersecting the avatar while still catching a short fall.
	var ty := ceili((y + height - 0.01) / float(BlockDefs.TILE))
	if absi(tx) > 100000 or absi(ty) > 100000:
		return SUPPORT_PLACE_INVALID_TILE
	var tile_top := float(ty * BlockDefs.TILE)
	var tile_left := float(tx * BlockDefs.TILE)
	var player_bottom := y + height
	if tile_top < player_bottom - 0.01:
		return SUPPORT_PLACE_INVALID_TILE
	var tile_name := _terrain_name_at(tx, ty)
	# Empty terrain is represented by an absent key.  Refuse known solid or
	# fluid cells; an unknown non-air cell must never be overwritten locally.
	if not tile_name.is_empty():
		return SUPPORT_PLACE_INVALID_TILE
	# If the cell immediately above the candidate is already solid, the bot is
	# falling beside/over an existing floor.  Placing beneath that floor would
	# create an invisible pillar instead of a recovery step.
	if _terrain_solid_at(tx, ty - 1):
		return SUPPORT_PLACE_INVALID_TILE
	var player_center := Vector2(x + width * 0.5, y + height * 0.5)
	var tile_center := Vector2(tile_left + BlockDefs.TILE * 0.5, tile_top + BlockDefs.TILE * 0.5)
	if player_center.distance_to(tile_center) > SUPPORT_PLACE_MAX_DISTANCE:
		return SUPPORT_PLACE_INVALID_TILE
	return Vector2i(tx, ty)


func _support_block_name() -> String:
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	for candidate in SUPPORT_BLOCK_PRIORITY:
		if int(inventory.get(candidate, 0)) <= 0:
			continue
		var definition := _block_entry(candidate)
		if definition.is_empty() or not bool(definition.get("solid", false)):
			continue
		if bool(definition.get("item", false)) or bool(definition.get("plant", false)) or bool(definition.get("creature_item", false)):
			continue
		if bool(definition.get("fluid", false)) or bool(definition.get("falls_when_unsupported", false)):
			continue
		return candidate
	return ""


func _local_collision(px: float, py: float, width: float, height: float, ignore_trees: bool = false) -> Dictionary:
	var left := floori(px / float(BlockDefs.TILE))
	var right := floori((px + width - 0.001) / float(BlockDefs.TILE))
	var top := floori(py / float(BlockDefs.TILE))
	var bottom := floori((py + height - 0.001) / float(BlockDefs.TILE))
	for tile_y in range(top, bottom + 1):
		for tile_x in range(left, right + 1):
			if not _terrain_solid_at(tile_x, tile_y):
				continue
			if ignore_trees and _terrain_climbable_at(tile_x, tile_y):
				continue
			return {"bx": tile_x * BlockDefs.TILE, "by": tile_y * BlockDefs.TILE}
	return {}


func _would_step_into_void(origin: Vector2, destination: Vector2) -> bool:
	if _terrain_tiles.is_empty():
		return false
	var direction := signf(destination.x - origin.x)
	if is_zero_approx(direction):
		return false
	var support := _support_tile_for_position(origin)
	if not _terrain_solid_at(support.x, support.y):
		return false
	var next_x := floori((origin.x + 10.0 + direction * 18.0) / float(BlockDefs.TILE))
	# A solid neighbour or a one-block drop is handled by normal collision or
	# the jump hint. Only stop when the next column has no known landing cell.
	if _terrain_solid_at(next_x, support.y) or _terrain_solid_at(next_x, support.y - 1):
		return false
	if _terrain_solid_at(next_x, support.y + 1) or _terrain_solid_at(next_x, support.y + 2):
		return false
	return true


func _terrain_is_lava_at(tx: int, ty: int) -> bool:
	var name := _terrain_name_at(tx, ty).to_lower()
	if name == "lava" or name.ends_with(".lava"):
		return true
	var entry := _block_entry(name)
	return bool(entry.get("fluid", false)) and float(entry.get("temperature", 0.0)) >= 0.8


func _would_step_into_lava(origin: Vector2, destination: Vector2) -> bool:
	if _terrain_tiles.is_empty():
		return false
	var direction := signf(destination.x - origin.x)
	if is_zero_approx(direction):
		return false
	var support := _support_tile_for_position(origin)
	var next_x := floori((origin.x + 10.0 + direction * 18.0) / float(BlockDefs.TILE))
	# Feet of the next column, plus the immediate drop, match how lava pools
	# sit relative to a standing avatar on Skyblock pads.
	for dy in range(-1, 3):
		if _terrain_is_lava_at(next_x, support.y + dy):
			return true
	return false


func _climb_step(self_state: Dictionary, destination: Vector2, delta: float) -> Dictionary:
	var origin := Contract.target_position(self_state)
	if not _local_climb_contact(self_state):
		_climb_active = false
		self_state["tree_ghost"] = false
		self_state["climbing"] = false
		self_state["climb_col"] = -1
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": false, "reason": "climb_contact_lost"}
	if not _climb_active:
		var direction := signf(destination.x - origin.x)
		_climb_column = floori((origin.x + 10.0 + direction * 18.0) / float(BlockDefs.TILE))
		_climb_active = true
		_climb_time_left_msec = 1_200
	# Mirror WorldSim's climb state in the legacy player snapshot.  Without
	# these flags the host treats the foliage as an ordinary solid block and
	# immediately pushes the bot back into the same cell after every frame.
	self_state["tree_ghost"] = true
	self_state["climbing"] = true
	self_state["climb_col"] = _climb_column
	_climb_time_left_msec -= int(maxf(delta, 0.0) * 1000.0)
	var climb_step := absf(TREE_CLIMB_SPEED) * maxf(delta, 0.0) * NETWORK_PHYSICS_TICKS_PER_SECOND
	var next_x := lerpf(origin.x, float(_climb_column * BlockDefs.TILE + 6), clampf(delta * 8.0, 0.0, 1.0))
	var next_y := origin.y - climb_step
	var still_on_tree := _terrain_climbable_at(_climb_column, floori((next_y + 14.0) / float(BlockDefs.TILE))) or _terrain_climbable_at(_climb_column, floori((next_y + 30.0) / float(BlockDefs.TILE)))
	if _climb_time_left_msec <= 0 or not still_on_tree:
		_climb_active = false
	if _climb_active:
		self_state["x"] = next_x
		self_state["y"] = next_y
		self_state["vx"] = 0.0
		self_state["vy"] = TREE_CLIMB_SPEED
		self_state["facing"] = 1 if destination.x >= origin.x else -1
		self_state["on_ground"] = false
	else:
		self_state["tree_ghost"] = false
		self_state["climbing"] = false
		self_state["climb_col"] = -1
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
	_world_snapshot["self"] = self_state
	return {"done": not _climb_active and absf(destination.x - next_x) <= 8.0, "reason": "climb_step"}


func _local_climb_contact(self_state: Dictionary) -> bool:
	var px := float(self_state.get("x", 0.0))
	var py := float(self_state.get("y", 0.0))
	var width := float(self_state.get("w", 20.0))
	var height := float(self_state.get("h", 28.0))
	var left := floori((px - 3.0) / float(BlockDefs.TILE))
	var right := floori((px + width + 3.0 - 0.001) / float(BlockDefs.TILE))
	var top := floori(py / float(BlockDefs.TILE))
	var bottom := floori((py + height - 0.001) / float(BlockDefs.TILE))
	for tile_y in range(top, bottom + 1):
		for tile_x in range(left, right + 1):
			if _terrain_climbable_at(tile_x, tile_y):
				return true
	return false


func _on_network_disconnected(reason: String) -> void:
	if _left_emitted or state == STATE_LEAVING or _disconnect_requested:
		return
	_emit_left("disconnected_%s" % reason)


func _on_network_message(message: Dictionary) -> void:
	handle_message(message)


func _connected_peers_supported(raw_players: Variant) -> bool:
	if not raw_players is Array:
		return true
	for raw_player in raw_players:
		if raw_player is Dictionary and not _peer_client_version_supported(raw_player as Dictionary):
			return false
	return true


func _peer_client_version_supported(entry: Dictionary) -> bool:
	var player_id := str(entry.get("player_id", entry.get("id", "")))
	var role := str(entry.get("role", "")).to_lower()
	if player_id.is_empty() or player_id == own_player_id:
		return true
	var is_host := player_id == _host_player_id or role == "host"
	if is_host:
		# Dedicated hosts are server processes rather than game clients.  A P2P
		# host, however, is the authority for the whole world and must advertise
		# a supported client when that metadata is available.  Discovery already
		# rejects listings with no host version; this runtime check covers a
		# stale/racing listing without breaking older dedicated gateways.
		var host_version := str(entry.get("client_version", ""))
		return dedicated_server or host_version.is_empty() or Contract.client_version_at_least(
			host_version,
			Contract.MIN_SUPPORTED_CLIENT_VERSION,
		)
	return Contract.client_version_at_least(
		str(entry.get("client_version", "")),
		Contract.MIN_SUPPORTED_CLIENT_VERSION,
	)


func _prepare_snapshot(payload: Dictionary) -> void:
	var transfer_id := str(payload.get("transfer_id", ""))
	var total := int(payload.get("total", 0))
	if transfer_id.is_empty() or total <= 0 or total > 1024:
		return
	if _snapshot_transfer_id != transfer_id or _snapshot_expected_chunks != total:
		_snapshot_transfer_id = transfer_id
		_snapshot_expected_chunks = total
		_snapshot_chunks.clear()
		_snapshot_chunks.resize(total)


func _apply_snapshot_if_complete() -> void:
	if _snapshot_expected_chunks <= 0 or _snapshot_chunks.any(func(part: String): return part.is_empty()):
		return
	var compressed := Marshalls.base64_to_raw("".join(_snapshot_chunks))
	var raw := compressed.decompress_dynamic(64 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not parsed is Dictionary:
		_emit_left("snapshot_invalid")
		return
	_apply_world_snapshot(parsed as Dictionary)


func _apply_world_snapshot(snapshot: Dictionary) -> void:
	var selected_world_mode := _session_world_mode
	_world_snapshot = snapshot.duplicate(true)
	if _world_snapshot.has("active_projectiles"):
		_world_snapshot["active_projectiles"] = _validated_projectile_snapshot(_world_snapshot.get("active_projectiles", []))
	var snapshot_generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	var snapshot_is_duel := str(snapshot_generation.get("mode", "")).to_lower() == "duel"
	if not selected_world_mode.is_empty() and (snapshot_generation.is_empty() or selected_world_mode == "duel"):
		snapshot_generation["mode"] = selected_world_mode
		_world_snapshot["generation"] = snapshot_generation
		snapshot_is_duel = selected_world_mode == "duel"
	_rebuild_terrain_index(_world_snapshot.get("tiles", []))
	_rebuild_plant_index(_world_snapshot.get("plant_growth", _world_snapshot.get("plants", [])))
	_seed_tree_growth_resources(_world_snapshot.get("tree_growth", []))
	if str(snapshot_generation.get("mode", "")).to_lower() == "duel":
		_seed_duel_fallback_terrain()
	world_id = str(snapshot.get("world_id", world_id))
	var multiplayer_state: Dictionary = snapshot.get("multiplayer", {}) if snapshot.get("multiplayer", {}) is Dictionary else {}
	var player_states: Dictionary = multiplayer_state.get("player_states", {}) if multiplayer_state.get("player_states", {}) is Dictionary else {}
	# `player` is the host's local avatar in a P2P snapshot. A guest bot must
	# start from its own authoritative state in multiplayer.player_states or it
	# inherits the host coordinates and immediately falls through the terrain.
	var local_state: Dictionary = player_states.get(own_player_id, {}) if player_states.get(own_player_id, {}) is Dictionary else {}
	if local_state.is_empty():
		local_state = snapshot.get("player", {}) if snapshot.get("player", {}) is Dictionary else {}
	else:
		var template: Dictionary = snapshot.get("player", {}) if snapshot.get("player", {}) is Dictionary else {}
		for field in ["w", "h", "max_health"]:
			if not local_state.has(field) and template.has(field):
				local_state[field] = template[field]
	_roster.clear()
	for raw_id in player_states:
		var player_id := str(raw_id)
		if player_id == own_player_id or (player_id == _host_player_id and not _is_pvp_world()):
			continue
		var player_state := player_states[raw_id] as Dictionary if player_states[raw_id] is Dictionary else {}
		player_state["id"] = player_id
		player_state["alive"] = int(player_state.get("health", 10)) > 0
		_roster[player_id] = player_state.duplicate(true)
	if _is_pvp_world() and _pvp_enemy_player_id.is_empty() and not _roster.is_empty():
		_pvp_enemy_player_id = str(_roster.keys()[0])
	# A guest that reconnects after the host has already started the duel will
	# not receive the one-shot `duel_start` control message. The host's world
	# snapshot is authoritative and only exists for an active game, so a duel
	# snapshot with another player is sufficient to restore the started state.
	# Waiting lobbies do not send a game snapshot and therefore remain safe.
	if _is_pvp_world() and snapshot_is_duel and not _roster.is_empty() and not _duel_started:
		_duel_started = true
		_record_event("duel_start_inferred", {"reason": "active_duel_snapshot"})
	_world_snapshot["self"] = local_state.duplicate(true)
	# Root-level inventory/equipment belong to the host avatar. A guest bot must
	# start empty unless its own multiplayer.player_states entry already exists.
	_world_snapshot["inventory_summary"] = _inventory_summary_from_player_state(local_state)
	_inventory_host_revision = maxi(0, int(local_state.get("inventory_host_revision", 0)))
	_inventory_client_revision = maxi(_inventory_client_revision, int(local_state.get("inventory_client_revision", 0)))
	_world_snapshot["recipes"] = _recipe_catalog(snapshot)
	_equipment_slots = _equipment_from_player_state(local_state)
	_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	_world_snapshot["craft_pending_output"] = _craft_pending_output
	_world_snapshot["craft_retry_after_msec"] = _craft_retry_after_msec
	_world_snapshot["craft_blocked_outputs"] = _active_craft_blocked_outputs(Time.get_ticks_msec())
	_world_snapshot["visible_resources"] = _visible_resources_from_tiles(_world_snapshot.get("tiles", []), local_state)
	_world_snapshot["visible_containers"] = _visible_containers_from_snapshot(_world_snapshot, local_state)
	_world_snapshot["threats"] = _threats_from_creatures(_world_snapshot.get("creatures", []))
	sync_complete = true
	_snapshot_transfer_id = ""
	_snapshot_expected_chunks = 0
	_snapshot_chunks.clear()
	_update_human_count()
	_set_state(STATE_PLAYING)
	_maybe_strip_progression_gear()
	_send_inventory_snapshot()
	_welcome_emoji_pending = human_player_count > 0
	_welcome_emoji_due_msec = Time.get_ticks_msec() + 900 if _welcome_emoji_pending else -1
	_send_duel_ready(Time.get_ticks_msec())
	behavior.request_decision(Time.get_ticks_msec())
	session_ready.emit(session_id, own_player_id)


func _send_duel_ready(now_msec: int) -> void:
	if not _is_pvp_world() or network_client == null or not network_client.has_method("send_command"):
		return
	if _last_duel_ready_msec >= 0 and now_msec - _last_duel_ready_msec < 1000:
		return
	_last_duel_ready_msec = now_msec
	network_client.call("send_command", "duel_ready", {"world_id": world_id})


func _block_name_for_content_id(content_id: String) -> String:
	var defs := get_node_or_null("/root/BlockDefs")
	if defs != null and defs.has_method("name_for_content_id"):
		var resolved := str(defs.call("name_for_content_id", content_id))
		if not resolved.is_empty():
			return resolved
	var blocks: Dictionary = defs.get("BLOCKS") if defs != null and defs.get("BLOCKS") is Dictionary else {}
	for block_name: String in blocks:
		if str(blocks[block_name].get("content_id", "core.%s" % block_name)) == content_id:
			return block_name
	return ""


func _block_entry(block_name: String) -> Dictionary:
	var defs := get_node_or_null("/root/BlockDefs")
	var blocks: Dictionary = defs.get("BLOCKS") if defs != null and defs.get("BLOCKS") is Dictionary else {}
	return blocks.get(block_name, {}) if blocks.get(block_name, {}) is Dictionary else {}


func _inventory_by_name(raw_inventory: Variant) -> Dictionary:
	var result := {}
	if not raw_inventory is Dictionary:
		return result
	for raw_id in raw_inventory:
		var name := _block_name_for_content_id(str(raw_id))
		if not name.is_empty():
			result[name] = int((raw_inventory as Dictionary)[raw_id])
	return result


func _inventory_summary_from_player_state(player_state: Dictionary) -> Dictionary:
	var raw_inventory = player_state.get("inventory", {})
	if not raw_inventory is Dictionary:
		return {}
	var result := {}
	for raw_key in raw_inventory:
		var amount := int((raw_inventory as Dictionary)[raw_key])
		if amount <= 0:
			continue
		var key := str(raw_key)
		var name := _block_name_for_content_id(key)
		if name.is_empty():
			name = key
		if not name.is_empty():
			result[name] = amount
	return result


func _replicated_equipment_slots() -> Dictionary:
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	var slots := _equipment_slots.duplicate(true)
	for slot_name in ["hand", "feet"]:
		var item_name := str(slots.get(slot_name, ""))
		if not item_name.is_empty() and int(inventory.get(item_name, 0)) <= 0:
			slots[slot_name] = ""
	return slots


func _equipment_from_player_state(player_state: Dictionary) -> Dictionary:
	var result := {"hand": "", "feet": ""}
	var raw_equipment = player_state.get("equipment_slots", {})
	if not raw_equipment is Dictionary:
		return result
	for slot_name in result:
		var raw_value := str((raw_equipment as Dictionary).get(slot_name, ""))
		if raw_value.is_empty():
			continue
		var name := _block_name_for_content_id(raw_value)
		if name.is_empty():
			name = raw_value
		result[slot_name] = name
	return result


func _equipment_by_name(raw_equipment: Variant) -> Dictionary:
	var result := {"hand": "", "feet": ""}
	if not raw_equipment is Dictionary:
		return result
	for slot_name in result:
		result[slot_name] = _block_name_for_content_id(str((raw_equipment as Dictionary).get(slot_name, "")))
	return result


func _recipe_catalog(snapshot: Dictionary) -> Array:
	var result: Array = []
	for raw_recipe in BlockDefs.RECIPES:
		var recipe := _resolve_content_recipe(raw_recipe)
		if not recipe.is_empty():
			recipe["station_available"] = _station_available(snapshot, str(recipe.get("station", "")))
			result.append(recipe)
	for raw_recipe in BlockDefs.CONTENT_RECIPES:
		var recipe := _resolve_content_recipe(raw_recipe)
		if not recipe.is_empty():
			recipe["station_available"] = _station_available(snapshot, str(recipe.get("station", "")))
			result.append(recipe)
	return result


func _resolve_content_recipe(raw_recipe: Dictionary) -> Dictionary:
	var resolved := {"in": {}, "out": {}}
	for side in ["in", "out"]:
		var values: Dictionary = raw_recipe.get(side, {}) if raw_recipe.get(side, {}) is Dictionary else {}
		for raw_id in values:
			var raw_name := str(raw_id)
			var name := raw_name if not _block_entry(raw_name).is_empty() else _block_name_for_content_id(raw_name)
			if name.is_empty():
				return {}
			resolved[side][name] = int(values[raw_id])
	var station := str(raw_recipe.get("station", ""))
	if not station.is_empty():
		resolved["station"] = station
	return resolved


func _station_available(snapshot: Dictionary, station: String) -> bool:
	if station.is_empty():
		return true
	var tiles: Array = snapshot.get("tiles", []) if snapshot.get("tiles", []) is Array else []
	for raw_tile in tiles:
		if not raw_tile is Dictionary:
			continue
		var name := _block_name_for_content_id(str((raw_tile as Dictionary).get("content_id", "")))
		if not name.is_empty() and str(_block_entry(name).get("station", "")) == station:
			return true
	return false


func _apply_players_snapshot(payload: Dictionary) -> void:
	var players: Dictionary = payload.get("players", {}) if payload.get("players", {}) is Dictionary else {}
	if payload.has("active_projectiles"):
		_world_snapshot["active_projectiles"] = _validated_projectile_snapshot(payload.get("active_projectiles", []))
	# The host sends the complete authoritative roster on every snapshot. Do not
	# retain IDs from an earlier player_joined stream after those players leave.
	_roster.clear()
	for raw_id in players:
		var player_id := str(raw_id)
		if not players[raw_id] is Dictionary:
			continue
		var entry := (players[raw_id] as Dictionary).duplicate(true)
		if player_id == own_player_id:
			# Input-driven hosts are authoritative for the bot's position. Keep the
			# collision dimensions from the initial snapshot, but do not hard-snap
			# mid-jump: a late players_snapshot would yank the local prediction back
			# to the previous edge and look like a teleport.
			var local_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
			var host_revision := int(entry.get("respawn_revision", local_state.get("respawn_revision", 0)))
			var local_revision := int(local_state.get("respawn_revision", 0))
			var respawned := host_revision > local_revision
			var reconcile_motion := respawned or (not _jump_active and not _climb_active)
			if respawned:
				_was_in_harmful_fluid = false
				_harmful_fluid_damage_cooldown = 0.0
				_guest_defeat_pending = false
				_jump_active = false
				_climb_active = false
			for field in ["x", "y", "facing", "vx", "vy", "on_ground", "health", "nourishment", "respawn_revision", "tree_ghost", "climbing", "climb_col"]:
				if not entry.has(field):
					continue
				if field in ["x", "y", "vx", "vy", "on_ground"] and not reconcile_motion:
					continue
				# Delayed host echoes of nourishment jump the bar backwards after a
				# local eat and make the bot spam EAT while berries are still present.
				if field == "nourishment":
					local_state[field] = clampi(int(local_state.get("nourishment", entry[field])), 0, 100)
					continue
				if field == "health":
					if respawned:
						local_state[field] = clampi(int(entry[field]), 0, 10)
					else:
						# Keep the more damaged reading so a late full-health echo cannot
						# cancel an in-progress local lava death before the host respawns.
						local_state[field] = mini(int(local_state.get("health", entry[field])), int(entry[field]))
					continue
				local_state[field] = entry[field]
			_world_snapshot["self"] = local_state
			continue
		if player_id == _host_player_id and not _is_pvp_world():
			continue
		entry["id"] = player_id
		entry["alive"] = int(entry.get("health", 10)) > 0
		_roster[player_id] = entry
	if _is_pvp_world() and _pvp_enemy_player_id.is_empty() and not _roster.is_empty():
		_pvp_enemy_player_id = str(_roster.keys()[0])
	_update_human_count()


func _apply_creatures_snapshot(payload: Dictionary) -> void:
	var raw_creatures: Array = payload.get("creatures", []) if payload.get("creatures", []) is Array else []
	var previous: Dictionary = {}
	var previous_entries: Array = _world_snapshot.get("creatures", []) if _world_snapshot.get("creatures", []) is Array else []
	for raw_previous in previous_entries:
		if raw_previous is Dictionary:
			previous[str((raw_previous as Dictionary).get("id", ""))] = raw_previous
	var creatures: Array = []
	for raw_entry in raw_creatures:
		if raw_entry is Dictionary:
			var dictionary_creature := (raw_entry as Dictionary).duplicate(true)
			if not str(dictionary_creature.get("id", "")).is_empty():
				creatures.append(dictionary_creature)
			continue
		if not raw_entry is Array or (raw_entry as Array).size() < 6:
			continue
		var entry := raw_entry as Array
		var creature_id := str(entry[0])
		var block_name := str(entry[5])
		if creature_id.is_empty() or block_name.is_empty():
			continue
		var creature: Dictionary = (previous.get(creature_id, {}) as Dictionary).duplicate(true)
		creature["id"] = creature_id
		creature["block_name"] = block_name
		creature["x"] = float(entry[1])
		creature["y"] = float(entry[2])
		creature["facing"] = -1 if int(entry[3]) < 0 else 1
		creature["health"] = maxi(0, int(entry[4]))
		creature["dead"] = int(creature["health"]) <= 0
		if entry.size() > 6:
			creature["work_action"] = str(entry[6])
		if entry.size() > 7:
			creature["work_action_ticks"] = maxi(0, int(entry[7]))
		if entry.size() > 10:
			creature["carried_materials"] = maxi(0, int(entry[10]))
		# Newer hosts may append these fields. Keeping them optional preserves
		# compatibility with older P2P/community hosts while letting a bot react
		# immediately after a defensive creature has been provoked or attacked.
		if entry.size() > 11:
			creature["provoked_ticks"] = maxi(0, int(entry[11]))
		if entry.size() > 12:
			creature["attack_cooldown"] = maxi(0, int(entry[12]))
		creatures.append(creature)
	_world_snapshot["creatures"] = creatures
	_world_snapshot["threats"] = _threats_from_creatures(creatures)


func _validated_projectile_snapshot(raw_projectiles: Variant) -> Array:
	var result: Array = []
	if not raw_projectiles is Array:
		return result
	for raw_projectile in raw_projectiles:
		if not raw_projectile is Dictionary:
			continue
		var projectile := raw_projectile as Dictionary
		if str(projectile.get("kind", "arrow")) != "arrow":
			continue
		var x := float(projectile.get("x", INF))
		var y := float(projectile.get("y", INF))
		var vx := float(projectile.get("vx", 0.0))
		var vy := float(projectile.get("vy", 0.0))
		if not is_finite(x) or not is_finite(y) or not is_finite(vx) or not is_finite(vy) or Vector2(vx, vy).length_squared() < 1.0:
			continue
		var shot_id := str(projectile.get("shot_id", projectile.get("id", "")))
		if shot_id.is_empty():
			continue
		result.append({
			"id": str(projectile.get("id", "arrow:%s" % shot_id)),
			"kind": "arrow",
			"shot_id": shot_id,
			"owner_player_id": str(projectile.get("owner_player_id", "")),
			"x": x,
			"y": y,
			"vx": clampf(vx, -2000.0, 2000.0),
			"vy": clampf(vy, -2000.0, 2000.0),
			"age": clampf(float(projectile.get("age", 0.0)), 0.0, 10.0),
			"damage": clampi(int(projectile.get("damage", 1)), 1, 10),
		})
		if result.size() >= 64:
			break
	return result


func _send_inventory_snapshot() -> void:
	if network_client == null or not network_client.has_method("send_command"):
		return
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	# Hosts reject guest snapshots whose host revision does not match the last
	# acknowledged inventory_host_revision. Sending 0 forever made every post-mine
	# craft/eat snapshot bounce, leaving the bot stuck retrying CRAFT planks.
	_inventory_client_revision += 1
	network_client.call("send_command", "inventory_snapshot", {
		"inventory_host_revision": _inventory_host_revision,
		"inventory_client_revision": _inventory_client_revision,
		"inventory": inventory.duplicate(true),
		"item_durability": {},
		"footwear_wear_distance": 0.0,
		"inventory_order": inventory.keys(),
		"hotbar_slots": ["", "", "", "", "", ""],
		"equipment_slots": _equipment_slots.duplicate(true),
		"active_hotbar_slot": 0,
		"selected": "",
		"nourishment": int((_world_snapshot.get("self", {}) as Dictionary).get("nourishment", 100)),
		"craft_slots": [null, null, null, null],
		"craft_slot_durability": [0, 0, 0, 0],
	})


func _maybe_strip_progression_gear() -> void:
	if not _strip_progression_gear or _progression_gear_stripped:
		return
	_progression_gear_stripped = true
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	var next := inventory.duplicate(true)
	var removed: Array[String] = []
	for item_name in ["wooden_pickaxe", "trail_boots"]:
		if int(next.get(item_name, 0)) > 0:
			next.erase(item_name)
			removed.append(item_name)
	var cleared_slots: Array[String] = []
	for slot_name in ["hand", "feet"]:
		var equipped := str(_equipment_slots.get(slot_name, ""))
		if equipped in ["wooden_pickaxe", "trail_boots"]:
			_equipment_slots[slot_name] = ""
			cleared_slots.append(slot_name)
	if removed.is_empty() and cleared_slots.is_empty():
		structured_log.emit({
			"event": "progression_gear_strip_skipped",
			"reason": "already_empty",
			"at_msec": Time.get_ticks_msec(),
		})
		return
	_world_snapshot["inventory_summary"] = next
	_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	structured_log.emit({
		"event": "progression_gear_stripped",
		"removed": removed,
		"cleared_slots": cleared_slots,
		"at_msec": Time.get_ticks_msec(),
	})


func _apply_inventory_snapshot(payload: Dictionary) -> void:
	var inventory: Dictionary = payload.get("inventory", {}) if payload.get("inventory", {}) is Dictionary else {}
	# Host payloads may still use content ids; normalize to short block names so
	# craft/eat rule checks match recipe inputs.
	var normalized := {}
	for raw_key in inventory.keys():
		var key := str(raw_key)
		var name := key if not _block_entry(key).is_empty() else _block_name_for_content_id(key)
		if name.is_empty():
			name = key
		var amount := int(inventory.get(raw_key, 0))
		if amount <= 0:
			continue
		normalized[name] = int(normalized.get(name, 0)) + amount
	if payload.has("inventory_client_revision"):
		var incoming_client := maxi(0, int(payload.get("inventory_client_revision", 0)))
		if incoming_client < _inventory_client_revision:
			# Stale host echo must not erase a newer local craft/eat. Adopt the
			# host revision and resubmit so the replacement can land.
			if payload.has("inventory_host_revision"):
				var incoming_host := maxi(0, int(payload.get("inventory_host_revision", 0)))
				if incoming_host != _inventory_host_revision:
					_inventory_host_revision = incoming_host
					_send_inventory_snapshot()
			return
	_world_snapshot["inventory_summary"] = normalized
	if payload.has("inventory_host_revision"):
		_inventory_host_revision = maxi(0, int(payload.get("inventory_host_revision", 0)))
	if payload.has("inventory_client_revision"):
		_inventory_client_revision = maxi(_inventory_client_revision, int(payload.get("inventory_client_revision", 0)))
	var incoming_equipment: Dictionary = payload.get("equipment_slots", _equipment_slots).duplicate(true) if payload.get("equipment_slots", _equipment_slots) is Dictionary else _equipment_slots.duplicate(true)
	_equipment_slots = _merge_equipment_with_pending(incoming_equipment, normalized)
	_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	if payload.has("nourishment"):
		var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
		var current := clampi(int(self_state.get("nourishment", 100)), 0, 100)
		var incoming := clampi(int(payload.get("nourishment", 100)), 0, 100)
		# Keep a just-eaten local increase until the host catches up; still accept
		# higher host values and never let a stale echo undo a successful bite.
		self_state["nourishment"] = maxi(current, incoming)
		_world_snapshot["self"] = self_state
	if not _craft_pending_output.is_empty() and int(normalized.get(_craft_pending_output, 0)) > 0:
		_craft_blocked_outputs.erase(_craft_pending_output)
		_craft_pending_output = ""
		_craft_retry_after_msec = Time.get_ticks_msec() + CRAFT_RETRY_DELAY_MSEC


func _merge_equipment_with_pending(incoming_equipment: Dictionary, inventory: Dictionary) -> Dictionary:
	var merged := {
		"hand": str(incoming_equipment.get("hand", "")),
		"feet": str(incoming_equipment.get("feet", "")),
	}
	var pending_equip: Dictionary = _pending_action_targets.get("equip", {}) if _pending_action_targets.get("equip", {}) is Dictionary else {}
	var pending_item := str(pending_equip.get("item", ""))
	if not pending_item.is_empty() and int(inventory.get(pending_item, 0)) > 0:
		var slot_name := "feet" if pending_item.ends_with("_boots") or pending_item.ends_with("_sandals") else "hand"
		merged[slot_name] = pending_item
	# Keep a locally equipped progression item when a stale craft snapshot clears
	# the slot but the item is still owned.
	for slot_name in ["hand", "feet"]:
		var local_item := str(_equipment_slots.get(slot_name, ""))
		if merged[slot_name].is_empty() and not local_item.is_empty() and int(inventory.get(local_item, 0)) > 0:
			merged[slot_name] = local_item
	return merged


func _apply_local_craft(output_name: String) -> bool:
	"""Optimistically apply a known progression craft and push it via inventory_snapshot.

	Phone hosts may ignore craft_recipe or fail fill_craft while still accepting a
	revision-matched inventory replacement. Keep the transaction aligned with the
	recipes the rule provider already selected.
	"""
	output_name = output_name.strip_edges()
	if output_name.is_empty():
		return false
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	var next := inventory.duplicate(true)
	if output_name in ["planks", "palm_planks", "pine_planks", "weeping_planks"]:
		var wood_name := "wood"
		if output_name == "palm_planks":
			wood_name = "palm_wood"
		elif output_name == "pine_planks":
			wood_name = "pine_wood"
		elif output_name == "weeping_planks":
			wood_name = "weeping_wood"
		if int(next.get(wood_name, 0)) <= 0:
			return false
		next[wood_name] = int(next.get(wood_name, 0)) - 1
		if int(next[wood_name]) <= 0:
			next.erase(wood_name)
		next[output_name] = int(next.get(output_name, 0)) + 4
	elif output_name == "wooden_pickaxe":
		var plank_name := ""
		for candidate in ["planks", "palm_planks", "pine_planks", "weeping_planks"]:
			if int(next.get(candidate, 0)) >= 3:
				plank_name = candidate
				break
		if plank_name.is_empty():
			return false
		next[plank_name] = int(next.get(plank_name, 0)) - 3
		if int(next[plank_name]) <= 0:
			next.erase(plank_name)
		next["wooden_pickaxe"] = int(next.get("wooden_pickaxe", 0)) + 1
	elif output_name == "stick":
		var plank_name := ""
		for candidate in ["planks", "palm_planks", "pine_planks", "weeping_planks"]:
			if int(next.get(candidate, 0)) >= 2:
				plank_name = candidate
				break
		if plank_name.is_empty():
			return false
		next[plank_name] = int(next.get(plank_name, 0)) - 2
		if int(next[plank_name]) <= 0:
			next.erase(plank_name)
		next["stick"] = int(next.get("stick", 0)) + 4
	elif output_name == "workbench":
		var plank_name := ""
		for candidate in ["planks", "palm_planks", "pine_planks", "weeping_planks"]:
			if int(next.get(candidate, 0)) >= 4:
				plank_name = candidate
				break
		if plank_name.is_empty():
			return false
		next[plank_name] = int(next.get(plank_name, 0)) - 4
		if int(next[plank_name]) <= 0:
			next.erase(plank_name)
		next["workbench"] = int(next.get("workbench", 0)) + 1
	elif output_name == "chest":
		var plank_name := ""
		for candidate in ["planks", "palm_planks", "pine_planks", "weeping_planks"]:
			if int(next.get(candidate, 0)) >= 3:
				plank_name = candidate
				break
		var wood_name := "wood"
		if plank_name == "palm_planks":
			wood_name = "palm_wood"
		elif plank_name == "pine_planks":
			wood_name = "pine_wood"
		elif plank_name == "weeping_planks":
			wood_name = "weeping_wood"
		if plank_name.is_empty() or int(next.get(wood_name, 0)) <= 0:
			return false
		next[plank_name] = int(next.get(plank_name, 0)) - 3
		if int(next[plank_name]) <= 0:
			next.erase(plank_name)
		next[wood_name] = int(next.get(wood_name, 0)) - 1
		if int(next[wood_name]) <= 0:
			next.erase(wood_name)
		next["chest"] = int(next.get("chest", 0)) + 1
	elif output_name == "trail_boots":
		var leaf_name := ""
		for candidate in ["leaves", "palm_leaves", "pine_needles", "weeping_leaves"]:
			if int(next.get(candidate, 0)) >= 2:
				leaf_name = candidate
				break
		var plank_name := ""
		for candidate in ["planks", "palm_planks", "pine_planks", "weeping_planks"]:
			if int(next.get(candidate, 0)) >= 1:
				plank_name = candidate
				break
		if leaf_name.is_empty() or plank_name.is_empty():
			return false
		next[leaf_name] = int(next.get(leaf_name, 0)) - 2
		if int(next[leaf_name]) <= 0:
			next.erase(leaf_name)
		next[plank_name] = int(next.get(plank_name, 0)) - 1
		if int(next[plank_name]) <= 0:
			next.erase(plank_name)
		next["trail_boots"] = int(next.get("trail_boots", 0)) + 1
	else:
		return false
	_world_snapshot["inventory_summary"] = next
	structured_log.emit({
		"event": "craft_applied_local",
		"output": output_name,
		"inventory": next.duplicate(true),
		"at_msec": Time.get_ticks_msec(),
	})
	return true


func _update_human_count() -> void:
	var next_count := Perception.count_live_humans(_roster, own_player_id, [_host_player_id], dedicated_server)
	var changed := next_count != human_player_count
	if not changed and _population_logged:
		return
	human_player_count = next_count
	if sync_complete and human_player_count <= 0:
		if empty_since_msec < 0:
			empty_since_msec = Time.get_ticks_msec()
	else:
		empty_since_msec = -1
	human_player_count_changed.emit(human_player_count)
	if changed or not _population_logged:
		structured_log.emit({
			"event": "player_population",
			"human_player_count": next_count,
			"roster_count": _roster.size(),
			"host_player_id": _host_player_id,
			"dedicated_server": dedicated_server,
			"at_msec": Time.get_ticks_msec(),
		})
		_population_logged = true
	var achievements := get_node_or_null("/root/Achievements")
	if achievements != null and achievements.has_method("record_multiplayer_players"):
		achievements.call("record_multiplayer_players", human_player_count + 1)


func _build_observation(now_msec: int) -> Dictionary:
	_expire_stale_action_targets(now_msec)
	var snapshot := _world_snapshot.duplicate(true)
	snapshot["self"] = snapshot.get("self", {"health": 10, "x": 0.0, "y": 0.0})
	snapshot["own_player_id"] = own_player_id
	snapshot["players"] = _roster.values()
	snapshot["recent_events"] = _recent_events.duplicate(true)
	snapshot["emoji_events"] = _active_emoji_events(now_msec)
	snapshot["action_history"] = _action_history.duplicate(true)
	snapshot["world_id"] = world_id
	_action_loop_blocked_until = ActionLoop.refresh_blocked_actions(
		_action_history,
		_action_loop_blocked_until,
		now_msec,
	)
	snapshot["legal_actions"] = ActionLoop.filter_legal_actions(
		Contract.ALL_ACTIONS,
		_action_loop_blocked_until,
		now_msec,
	)
	snapshot["action_loop_blocked"] = ActionLoop.active_blocks(_action_loop_blocked_until, now_msec)
	snapshot["self_defense"] = safety.observation_state(now_msec)
	snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	snapshot["craft_pending_output"] = _craft_pending_output
	snapshot["craft_retry_after_msec"] = _craft_retry_after_msec
	snapshot["craft_blocked_outputs"] = _active_craft_blocked_outputs(now_msec)
	snapshot["food_eat_cooldown_until_msec"] = _food_eat_cooldown_until_msec
	snapshot["terrain_tiles"] = _terrain_observation(snapshot["self"] as Dictionary)
	# Rebuild every tick from the live terrain index. A one-shot list from the
	# join snapshot froze the bot on nearby ice while the starter tree grew and
	# stayed out of the stale resource set.
	snapshot["visible_resources"] = _filter_blocked_resources(
		_visible_resources_from_terrain(snapshot["self"] as Dictionary),
		now_msec,
	)
	snapshot["visible_containers"] = _visible_containers_from_snapshot(snapshot, snapshot["self"] as Dictionary)
	if _is_pvp_world() and not _pvp_chest_opened and _duel_fallback_container(snapshot["self"] as Dictionary).size() > 0:
		var has_chest := false
		for raw_container in snapshot["visible_containers"]:
			if raw_container is Dictionary and str((raw_container as Dictionary).get("kind", "")) == "chest":
				has_chest = true
				break
		if not has_chest:
			snapshot["visible_containers"].append(_duel_fallback_container(snapshot["self"] as Dictionary))
	var generation: Dictionary = snapshot.get("generation", {}) if snapshot.get("generation", {}) is Dictionary else {}
	snapshot["pvp_world"] = _is_pvp_world()
	snapshot["duel_started"] = _duel_started
	snapshot["pvp_chest_opened"] = _pvp_chest_opened
	snapshot["enemy_player_id"] = _enemy_player_id()
	snapshot["bow_attack_distance"] = BlockDefs.TILE * 10.0
	snapshot["achievements"] = _achievement_observation()
	var candidate_emoji := ""
	if _welcome_emoji_pending and now_msec >= _welcome_emoji_due_msec:
		candidate_emoji = "👋"
	elif not _pending_social_emoji.is_empty():
		candidate_emoji = _pending_social_emoji
		if not _pending_social_emoji_target_id.is_empty():
			snapshot["social_target_id"] = _pending_social_emoji_target_id
	# Only expose a reaction when the social gate would actually allow a send.
	# Otherwise the rule provider keeps selecting SEND_EMOJI, the executor
	# transmits before the cooldown check runs, and the pending emoji never
	# clears — producing a wave every ~700 ms.
	if not candidate_emoji.is_empty() and _social.emoji_can_send(
		_last_emoji_sent_msec,
		now_msec,
		candidate_emoji,
		_previous_emoji,
		_social_last_sent_msec,
	):
		snapshot["social_emoji"] = candidate_emoji
	else:
		snapshot["social_emoji"] = ""
		# Same-as-previous can never become legal; drop it. Cooldown-only
		# failures keep the pending reply until the social window reopens.
		if not candidate_emoji.is_empty() and not _previous_emoji.is_empty() and candidate_emoji == _previous_emoji:
			_clear_social_emoji_queue()
	# Duel arenas may place the pinned opponent farther away than the ordinary
	# social observation radius. The provider still filters to the single pinned
	# enemy, so expanding only this read radius cannot authorize random PvP.
	var perception_radius := maxf(observation_radius, 4096.0) if _is_pvp_world() else observation_radius
	return Perception.build(snapshot, own_player_id, perception_radius, now_msec)


func _filter_blocked_resources(raw_resources: Variant, now_msec: int) -> Array:
	var resources: Array = raw_resources as Array if raw_resources is Array else []
	var filtered: Array = []
	for raw_resource in resources:
		if not raw_resource is Dictionary:
			continue
		var resource := raw_resource as Dictionary
		var key := str(resource.get("id", ""))
		var blocked_until := int(_blocked_action_targets.get(key, 0))
		if blocked_until > 0 and now_msec >= blocked_until:
			_blocked_action_targets.erase(key)
			blocked_until = 0
		if blocked_until <= now_msec:
			filtered.append(resource)
	return filtered


func _expire_stale_action_targets(now_msec: int) -> void:
	for raw_key in _pending_action_targets.keys():
		var key := str(raw_key)
		var pending: Dictionary = _pending_action_targets[raw_key] if _pending_action_targets[raw_key] is Dictionary else {}
		var sent_at := int(pending.get("sent_at_msec", -1))
		if sent_at < 0 or now_msec - sent_at < 2_200:
			continue
		if str(pending.get("action", "")) in [Contract.ACTION_MINE, Contract.ACTION_PLACE] and key.contains(":"):
			_blocked_action_targets["tile:%s" % key] = now_msec + ACTION_RETRY_BLOCK_MSEC
		_pending_action_targets.erase(raw_key)


func _enemy_player_id() -> String:
	return _pvp_enemy_player_id if _is_pvp_world() else ""


func _is_pvp_world() -> bool:
	var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	return (
		str(generation.get("mode", "")).to_lower() == "duel"
		or _session_world_mode == "duel"
		or protocol_version == DUEL_PROTOCOL_VERSION
	)


func _terrain_observation(self_state: Dictionary) -> Array:
	var result: Array = []
	var origin := Contract.target_position(self_state)
	var center_x := floori((origin.x + 10.0) / float(BlockDefs.TILE))
	var center_y := floori((origin.y + 28.0) / float(BlockDefs.TILE))
	# Digging is local and one action at a time. Keep this compact so the
	# observation remains cheap even when the initial snapshot contains a whole
	# region, while still covering a short staircase/bridge route.
	for key in _terrain_tiles:
		var parts := str(key).split(":")
		if parts.size() != 2:
			continue
		var tile_x := int(parts[0])
		var tile_y := int(parts[1])
		if abs(tile_x - center_x) > 10 or abs(tile_y - center_y) > 8:
			continue
		var block_name := str(_terrain_tiles[key])
		var block := _block_entry(block_name)
		result.append({
			"x": tile_x,
			"y": tile_y,
			"block_name": block_name,
			"harvest_tier": _block_harvest_tier(block),
			"hardness": float(block.get("hardness", 0.0)),
		})
	return result


func _visible_resources_from_terrain(self_state: Dictionary) -> Array:
	var resources: Array = []
	var origin := Contract.target_position(self_state)
	# Starter trees sit above the ice/dirt pad. Keep a wide read so the bot can
	# still lock onto wood after it digs a few blocks downward.
	var max_distance := maxf(observation_radius, 420.0) + float(BlockDefs.TILE)
	var seen: Dictionary = {}
	for key in _terrain_tiles:
		var parts := str(key).split(":")
		if parts.size() != 2:
			continue
		var tile_x := int(parts[0])
		var tile_y := int(parts[1])
		var block_name := str(_terrain_tiles[key])
		_append_visible_resource(resources, seen, self_state, origin, max_distance, tile_x, tile_y, block_name)
		if resources.size() >= 256:
			return resources
	for key in _plant_tiles:
		var parts := str(key).split(":")
		if parts.size() != 2:
			continue
		var tile_x := int(parts[0])
		var tile_y := int(parts[1])
		var block_name := str(_plant_tiles[key])
		_append_visible_resource(resources, seen, self_state, origin, max_distance, tile_x, tile_y, block_name)
		if resources.size() >= 256:
			return resources
	# Join snapshots may carry tiles the live terrain index missed (or lost after
	# a sparse tile_batch). Merge them so the starter tree remains visible.
	var snapshot_tiles: Array = _world_snapshot.get("tiles", []) if _world_snapshot.get("tiles", []) is Array else []
	for raw_tile in snapshot_tiles:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var tile_x := int(tile.get("x", 0))
		var tile_y := int(tile.get("y", 0))
		var block_name := _block_name_for_content_id(str(tile.get("content_id", "")))
		if block_name.is_empty():
			block_name = str(tile.get("block_name", ""))
		if block_name.is_empty():
			continue
		_append_visible_resource(resources, seen, self_state, origin, max_distance, tile_x, tile_y, block_name)
		if resources.size() >= 256:
			break
	return resources


func _append_visible_resource(
	resources: Array,
	seen: Dictionary,
	self_state: Dictionary,
	origin: Vector2,
	max_distance: float,
	tile_x: int,
	tile_y: int,
	block_name: String,
) -> void:
	var key := "%d:%d" % [tile_x, tile_y]
	if seen.has(key):
		return
	var block_definition: Dictionary = _block_entry(block_name)
	var solid := bool(block_definition.get("solid", false)) and not bool(block_definition.get("fluid", false))
	if block_name.is_empty() or block_name == "air" or not solid:
		return
	var position := Vector2((float(tile_x) + 0.5) * BlockDefs.TILE, (float(tile_y) + 0.5) * BlockDefs.TILE)
	if origin.distance_to(position) > max_distance:
		return
	seen[key] = true
	var content_id := str(block_definition.get("content_id", "core.%s" % block_name))
	resources.append({
		"id": "tile:%d:%d" % [tile_x, tile_y],
		"x": tile_x,
		"y": tile_y,
		"content_id": content_id,
		"block_name": block_name,
		"harvest_tier": _block_harvest_tier(block_definition),
		"hardness": float(block_definition.get("hardness", 0.0)),
		"position": [position.x, position.y],
		"reachable": origin.distance_to(position) <= float(BlockDefs.TILE) * 2.5,
	})


func _visible_resources_from_tiles(raw_tiles: Variant, self_state: Dictionary) -> Array:
	var resources: Array = []
	if not raw_tiles is Array:
		return resources
	var origin := Contract.target_position(self_state)
	var max_distance := observation_radius + float(BlockDefs.TILE)
	for raw_tile in raw_tiles:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var tile_x := int(tile.get("x", 0))
		var tile_y := int(tile.get("y", 0))
		var content_id := str(tile.get("content_id", ""))
		var block_name := _block_name_for_content_id(content_id)
		var block_definition: Dictionary = _block_entry(block_name)
		var solid := bool(block_definition.get("solid", false)) and not bool(block_definition.get("fluid", false))
		if block_name.is_empty() or block_name == "air" or not solid:
			continue
		var position := Vector2((float(tile_x) + 0.5) * BlockDefs.TILE, (float(tile_y) + 0.5) * BlockDefs.TILE)
		if origin.distance_to(position) > max_distance:
			continue
		resources.append({
			"id": "tile:%d:%d" % [tile_x, tile_y],
			"x": tile_x,
			"y": tile_y,
			"content_id": content_id,
			"block_name": block_name,
			"harvest_tier": _block_harvest_tier(block_definition),
			"hardness": float(block_definition.get("hardness", 0.0)),
			"position": [position.x, position.y],
			"reachable": origin.distance_to(position) <= float(BlockDefs.TILE) * 2.5,
		})
		if resources.size() >= 256:
			break
	return resources


func _block_harvest_tier(block: Dictionary) -> int:
	if block.is_empty() or not bool(block.get("solid", false)) or bool(block.get("fluid", false)):
		return 0
	if block.has("harvest_tier"):
		return clampi(int(block.get("harvest_tier", 0)), 0, 6)
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	if "obsidian" in tags or ("rare" in tags and ("ore" in tags or "crystal" in tags or "mineral" in tags)):
		return 4
	if "ore" in tags or "crystal" in tags or "gem" in tags or "mineral" in tags:
		return 3
	var hardness := int(block.get("hardness", 0))
	if hardness >= 50:
		return 4
	if hardness >= 26:
		return 2
	if hardness >= 18:
		return 1
	return 0


func _visible_containers_from_snapshot(snapshot: Dictionary, self_state: Dictionary) -> Array:
	var containers: Array = []
	var raw_containers: Variant = snapshot.get("containers", [])
	if not raw_containers is Array:
		return containers
	var origin := Contract.target_position(self_state)
	var max_distance := observation_radius + float(BlockDefs.TILE)
	for raw_entry in raw_containers:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		var data: Dictionary = entry.get("data", {}) if entry.get("data", {}) is Dictionary else {}
		var tile_x := int(entry.get("x", 0))
		var tile_y := int(entry.get("y", 0))
		var position := Vector2((float(tile_x) + 0.5) * BlockDefs.TILE, (float(tile_y) + 0.5) * BlockDefs.TILE)
		if origin.distance_to(position) > max_distance:
			continue
		var death_cache := bool(data.get("death_cache", false))
		var one_use_cache := bool(data.get("one_use_cache", false))
		var contents: Dictionary = data.get("contents", {}) if data.get("contents", {}) is Dictionary else {}
		var loot_generated := bool(data.get("loot_generated", true))
		# An already-opened empty chest is not an activity target. Caches remain
		# visible regardless of owner: multiplayer recovery intentionally allows a
		# nearby player to pick up another player's death cache.
		if not death_cache and not one_use_cache and loot_generated and contents.is_empty():
			continue
		var kind := "death_cache" if death_cache else ("one_use_cache" if one_use_cache else "chest")
		containers.append({
			"id": "container:%d:%d" % [tile_x, tile_y],
			"x": tile_x,
			"y": tile_y,
			"position": [position.x, position.y],
			"kind": kind,
			"death_cache": death_cache,
			"one_use_cache": one_use_cache,
			"owner_player_id": str(data.get("owner_player_id", "")),
			"reachable": origin.distance_to(position) <= float(BlockDefs.TILE) * 4.5,
		})
		if containers.size() >= 32:
			break
	return containers


func _duel_fallback_container(self_state: Dictionary) -> Dictionary:
	if not _is_pvp_world() or _pvp_enemy_player_id.is_empty():
		return {}
	var enemy: Dictionary = _roster.get(_pvp_enemy_player_id, {}) if _roster.get(_pvp_enemy_player_id, {}) is Dictionary else {}
	if enemy.is_empty():
		return {}
	var enemy_position := Contract.target_position(enemy)
	var chest_x := 15 if enemy_position.x < 0.0 else -15
	var chest_y := 7
	var chest_position := Vector2((float(chest_x) + 0.5) * BlockDefs.TILE, (float(chest_y) + 0.5) * BlockDefs.TILE)
	return {
		"id": "container:%d:%d" % [chest_x, chest_y],
		"x": chest_x,
		"y": chest_y,
		"position": [chest_position.x, chest_position.y],
		"kind": "chest",
		"reachable": Contract.target_position(self_state).distance_to(chest_position) <= float(BlockDefs.TILE) * 4.5,
	}


func _threats_from_creatures(raw_creatures: Variant) -> Array:
	var threats: Array = []
	if not raw_creatures is Array:
		return threats
	for raw_creature in raw_creatures:
		if not raw_creature is Dictionary:
			continue
		var creature := (raw_creature as Dictionary).duplicate(true)
		if bool(creature.get("dead", false)):
			continue
		var position := Vector2((float(creature.get("x", 0.0)) + 0.5) * BlockDefs.TILE, (float(creature.get("y", 0.0)) + 0.5) * BlockDefs.TILE)
		creature["position"] = [position.x, position.y]
		creature["hostile"] = true
		threats.append(creature)
	return threats


func _record_event(event_name: String, data: Dictionary) -> void:
	var event := {"type": event_name, "at_msec": Time.get_ticks_msec()}
	for key in data:
		event[key] = data[key]
	_recent_events.append(event)
	while _recent_events.size() > 12:
		_recent_events.pop_front()


func _record_emoji_event(message: Dictionary, payload: Dictionary) -> void:
	var emoji := EmojiReactions.sanitize(payload.get("emoji", message.get("emoji", "")))
	if emoji.is_empty():
		return
	var player_id := str(payload.get("player_id", payload.get("sender_player_id", message.get("player_id", message.get("sender_player_id", "")))))
	if player_id.is_empty() or player_id == own_player_id:
		return
	var event := {"player_id": player_id, "emoji": emoji, "at_msec": Time.get_ticks_msec()}
	var actor: Dictionary = _roster.get(player_id, {}) if _roster.get(player_id, {}) is Dictionary else {}
	var x := float(payload.get("x", actor.get("x", 0.0)))
	var y := float(payload.get("y", actor.get("y", 0.0)))
	if payload.has("position") and payload.get("position") is Array and (payload.get("position") as Array).size() >= 2:
		x = float((payload.get("position") as Array)[0])
		y = float((payload.get("position") as Array)[1])
	event["position"] = [x, y]
	_recent_emoji_events.append(event)
	while _recent_emoji_events.size() > Perception.DEFAULT_MAX_EVENTS:
		_recent_emoji_events.pop_front()
	_queue_emoji_reply(event)


func _queue_emoji_reply(event: Dictionary) -> void:
	if not _pending_social_emoji.is_empty() or _emoji_reply_inflight:
		return
	var incoming := str(event.get("emoji", ""))
	var sender_id := str(event.get("player_id", ""))
	var fallback := Social.reply_emoji(incoming, _previous_emoji)
	if fallback.is_empty():
		return
	var context := {
		"incoming_emoji": incoming,
		"player_id": sender_id,
		"avoid_emoji": _previous_emoji,
		"previous_emoji": _previous_emoji,
		"at_msec": int(event.get("at_msec", Time.get_ticks_msec())),
	}
	if ai_client != null and ai_client.is_available() and not ai_client.is_busy():
		_emoji_reply_inflight = true
		if ai_client.request_emoji_reply(context):
			structured_log.emit({"event": "emoji_ai_requested", "incoming_emoji": incoming, "player_id": sender_id, "avoid_emoji": _previous_emoji, "at_msec": Time.get_ticks_msec()})
			return
		_emoji_reply_inflight = false
	_pending_social_emoji = fallback
	_pending_social_emoji_target_id = sender_id
	structured_log.emit({
		"event": "emoji_reply_queued",
		"incoming_emoji": incoming,
		"reply_emoji": _pending_social_emoji,
		"source": "fallback",
		"player_id": sender_id,
		"at_msec": Time.get_ticks_msec(),
	})


func _on_ai_emoji_reply(emoji: String, context: Dictionary) -> void:
	_emoji_reply_inflight = false
	var avoid := str(context.get("avoid_emoji", _previous_emoji))
	var sanitized := EmojiReactions.sanitize(emoji)
	if sanitized.is_empty() or sanitized == avoid:
		sanitized = Social.reply_emoji(str(context.get("incoming_emoji", "")), avoid)
	if sanitized.is_empty():
		return
	_pending_social_emoji = sanitized
	_pending_social_emoji_target_id = str(context.get("player_id", ""))
	structured_log.emit({
		"event": "emoji_reply_queued",
		"incoming_emoji": str(context.get("incoming_emoji", "")),
		"reply_emoji": _pending_social_emoji,
		"source": "ai",
		"player_id": _pending_social_emoji_target_id,
		"at_msec": Time.get_ticks_msec(),
	})


func _on_ai_emoji_failed(reason: String, context: Dictionary) -> void:
	_emoji_reply_inflight = false
	var avoid := str(context.get("avoid_emoji", _previous_emoji))
	var fallback := Social.reply_emoji(str(context.get("incoming_emoji", "")), avoid)
	if fallback.is_empty():
		return
	_pending_social_emoji = fallback
	_pending_social_emoji_target_id = str(context.get("player_id", ""))
	structured_log.emit({
		"event": "emoji_ai_failed",
		"reason": reason,
		"reply_emoji": _pending_social_emoji,
		"player_id": _pending_social_emoji_target_id,
		"at_msec": Time.get_ticks_msec(),
	})


func _active_emoji_events(now_msec: int) -> Array[Dictionary]:
	var active: Array[Dictionary] = []
	for event in _recent_emoji_events:
		var at_msec := int(event.get("at_msec", 0))
		if at_msec > 0 and now_msec - at_msec <= EMOJI_EVENT_TTL_MSEC:
			active.append(event.duplicate(true))
	_recent_emoji_events = active
	return active


func _on_decision_proposed(decision: Dictionary) -> void:
	decision_logged.emit({"event": "decision_proposed", "decision": decision.duplicate(true), "at_msec": Time.get_ticks_msec()})


func _on_decision_rejected(decision: Dictionary, reason: String) -> void:
	_record_action_history("rejected", decision, reason)
	decision_logged.emit({"event": "decision_rejected", "decision": decision.duplicate(true), "reason": reason, "at_msec": Time.get_ticks_msec()})


func _on_decision_started(decision: Dictionary) -> void:
	var now_msec := Time.get_ticks_msec()
	_record_action_history("started", decision)
	var action := str(decision.get("action", ""))
	if action == Contract.ACTION_EQUIP:
		var item_name := str(decision.get("target_id", ""))
		# Apply a local optimistic slot so the rule provider does not re-select
		# EQUIP every 350 ms while the host ack is in flight. Host snapshots still
		# overwrite these slots when they arrive.
		if not item_name.is_empty():
			_pending_action_targets["equip"] = {"action": action, "item": item_name, "sent_at_msec": now_msec}
			var slot_name := "feet" if item_name.ends_with("_boots") or item_name.ends_with("_sandals") else "hand"
			_equipment_slots[slot_name] = item_name
			_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
			# Persist the optimistic slot through inventory_snapshot. A craft that
			# lands just before this EQUIP otherwise echoes feet/hand empty and
			# the bot spam-equips forever on community hosts.
			_send_inventory_snapshot()
	elif action == Contract.ACTION_MINE or action == Contract.ACTION_PLACE:
		var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
		var key := "%d:%d" % [int(target.get("x", 0)), int(target.get("y", 0))]
		_pending_action_targets[key] = {"action": action, "block": str(decision.get("block", "")), "content_id": str(target.get("content_id", "")), "sent_at_msec": now_msec}
	elif action == Contract.ACTION_CRAFT:
		var craft_output := str(decision.get("target_id", ""))
		_pending_action_targets["craft"] = {"action": action, "output": craft_output}
		# Apply + inventory_snapshot only (executor skips craft_recipe). Clear the
		# pending gate immediately on success so wooden_pickaxe can follow planks
		# on the next decision tick instead of waiting for a craft_recipe ack.
		if _apply_local_craft(craft_output):
			_send_inventory_snapshot()
			_craft_blocked_outputs.erase(craft_output)
			_craft_pending_output = ""
			_craft_retry_after_msec = now_msec + 500
			_pending_action_targets.erase("craft")
			structured_log.emit({
				"event": "craft_synced",
				"output": craft_output,
				"inventory_host_revision": _inventory_host_revision,
				"inventory_client_revision": _inventory_client_revision,
				"at_msec": now_msec,
			})
		else:
			# Unsupported/unavailable recipe: cool only that output so it cannot
			# freeze the whole craft progression gate for several seconds.
			_block_craft_output(craft_output, now_msec)
			_craft_pending_output = ""
			_craft_retry_after_msec = now_msec + 500
			_pending_action_targets.erase("craft")
			behavior.executor.cancel("craft_failed")
			decision_logged.emit({"event": "decision_failed", "decision": decision.duplicate(true), "reason": "craft_failed", "at_msec": now_msec})
			return
	elif action == Contract.ACTION_EAT:
		if not _apply_local_eat(str(decision.get("target_id", ""))):
			behavior.executor.cancel("eat_failed")
			decision_logged.emit({"event": "decision_failed", "decision": decision.duplicate(true), "reason": "eat_failed", "at_msec": now_msec})
			return
	elif action == Contract.ACTION_OPEN_CONTAINER:
		var container_target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
		var container_key := "%d:%d" % [int(container_target.get("x", 0)), int(container_target.get("y", 0))]
		_pending_action_targets[container_key] = {"action": action}
		# Duel chest commands are authoritative and may acknowledge after the
		# next behaviour tick. Mark the one-shot loadout request as in flight so a
		# delayed response cannot make the bot spam OPEN_CONTAINER every 900 ms.
		if _is_pvp_world():
			_pvp_chest_opened = true
	if action == Contract.ACTION_SEND_EMOJI:
		var emoji := str(decision.get("emoji", ""))
		# The executor already transmitted. Only bookkeep + clear the queue here;
		# the observation gate above must prevent unsendable reactions from
		# reaching start() in the first place.
		if _social.emoji_can_send(_last_emoji_sent_msec, now_msec, emoji, _previous_emoji, _social_last_sent_msec):
			_last_emoji_sent_msec = now_msec
			_social_last_sent_msec = now_msec
			_previous_emoji = emoji
			_clear_social_emoji_queue()
		else:
			_clear_social_emoji_queue()
			behavior.executor.cancel("emoji_cooldown")
	decision_logged.emit({"event": "decision_started", "decision": decision.duplicate(true), "at_msec": now_msec})


func _clear_social_emoji_queue() -> void:
	_welcome_emoji_pending = false
	_welcome_emoji_due_msec = -1
	_pending_social_emoji = ""
	_pending_social_emoji_target_id = ""
	_emoji_reply_inflight = false


func _on_executor_action_finished(decision: Dictionary, reason: String) -> void:
	var target_id := str(decision.get("target_id", ""))
	if reason in ["blocked_obstacle", "edge_guard", "timeout"] and target_id.begins_with("tile:"):
		_blocked_action_targets[target_id] = Time.get_ticks_msec() + ACTION_RETRY_BLOCK_MSEC
	_record_action_history("finished", decision, reason)


func _on_executor_action_failed(decision: Dictionary, reason: String) -> void:
	_record_action_history("failed", decision, reason)


func _record_action_history(phase: String, decision: Dictionary, reason: String = "") -> void:
	var entry := {
		"at_msec": Time.get_ticks_msec(),
		"phase": phase,
		"action": str(decision.get("action", "")),
		"goal": str(decision.get("goal", "")),
		"target_id": str(decision.get("target_id", "")),
	}
	if not reason.is_empty():
		entry["reason"] = reason
	_action_history.append(entry)
	while _action_history.size() > Perception.DEFAULT_MAX_EVENTS:
		_action_history.pop_front()


func _apply_local_eat(food_name: String) -> bool:
	food_name = food_name.strip_edges()
	if food_name.is_empty():
		return false
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	if int(inventory.get(food_name, 0)) <= 0:
		return false
	var restore := _item_nourishment_value(food_name)
	if restore <= 0:
		return false
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	var nourishment := clampi(int(self_state.get("nourishment", 100)), 0, 100)
	if nourishment >= 100:
		return false
	inventory[food_name] = int(inventory.get(food_name, 0)) - 1
	if int(inventory[food_name]) <= 0:
		inventory.erase(food_name)
	self_state["nourishment"] = mini(100, nourishment + restore)
	_world_snapshot["inventory_summary"] = inventory
	_world_snapshot["self"] = self_state
	_food_eat_cooldown_until_msec = Time.get_ticks_msec() + FOOD_EAT_COOLDOWN_MSEC
	_send_inventory_snapshot()
	structured_log.emit({
		"event": "food_consumed",
		"food": food_name,
		"nourishment": int(self_state.get("nourishment", 0)),
		"at_msec": Time.get_ticks_msec(),
	})
	return true


func _item_nourishment_value(block_name: String) -> int:
	var block := _block_entry(block_name)
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	var restore := maxi(0, int(effects.get("nourishment", 0)))
	if restore > 0:
		return restore
	if block_name == "wild_berries":
		return 28
	if block_name == "prepared_meal":
		return 64
	return 0


func _handle_action_result(payload: Dictionary) -> void:
	var action := str(payload.get("action", ""))
	_record_action_history("result", {
		"action": action,
		"target_id": str(payload.get("target_id", "")),
	}, "accepted" if bool(payload.get("accepted", false)) else "rejected")
	if action == "equip_item":
		var pending_equip: Dictionary = _pending_action_targets.get("equip", {}) if _pending_action_targets.get("equip", {}) is Dictionary else {}
		_pending_action_targets.erase("equip")
		if bool(payload.get("accepted", false)) and payload.get("equipment_slots", null) is Dictionary:
			_equipment_slots = (payload.get("equipment_slots") as Dictionary).duplicate(true)
			_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
		elif not bool(payload.get("accepted", false)):
			# Roll back the optimistic hand/feet slot so a rejected equip does not
			# permanently look equipped and starve later tool swaps.
			var rejected_item := str(pending_equip.get("item", ""))
			for slot_name in ["hand", "feet"]:
				if str(_equipment_slots.get(slot_name, "")) == rejected_item:
					_equipment_slots[slot_name] = ""
			_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
		return
	if action == "open_container":
		var container_key := "%d:%d" % [int(payload.get("x", 0)), int(payload.get("y", 0))]
		_pending_action_targets.erase(container_key)
		if bool(payload.get("accepted", false)) and _is_pvp_world():
			_pvp_chest_opened = true
			# The authoritative inventory snapshot follows this acknowledgement. Do
			# not let a stale chest payload trigger another open before it arrives.
			_update_snapshot_container(container_key, {"contents": {}, "loot_generated": true})
		else:
			_apply_tile_batch({"tiles": [payload]})
			_update_snapshot_container(container_key, payload.get("container", null))
		return
	if action == "craft_recipe":
		var accepted := bool(payload.get("accepted", false))
		var craft: Dictionary = _pending_action_targets.get("craft", {}) if _pending_action_targets.get("craft", {}) is Dictionary else {}
		var output := str(craft.get("output", payload.get("output", "")))
		_craft_pending_output = ""
		if not accepted and not output.is_empty():
			# Keep retrying when the local inventory snapshot already owns the
			# output; only cool down outputs that are still missing.
			var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
			if int(inventory.get(output, 0)) <= 0:
				_block_craft_output(output)
		elif accepted:
			_craft_blocked_outputs.erase(output)
		_craft_retry_after_msec = Time.get_ticks_msec() + (CRAFT_RETRY_DELAY_MSEC if not accepted else 2_000)
		_pending_action_targets.erase("craft")
		structured_log.emit({
			"event": "craft_result",
			"output": output,
			"accepted": accepted,
			"at_msec": Time.get_ticks_msec(),
		})
		var achievements := get_node_or_null("/root/Achievements")
		if accepted and achievements != null and achievements.has_method("record_craft"):
			achievements.call("record_craft", output)
		return
	if not bool(payload.get("accepted", false)):
		var rejected_key := "%d:%d" % [int(payload.get("x", 0)), int(payload.get("y", 0))]
		_blocked_action_targets["tile:%s" % rejected_key] = Time.get_ticks_msec() + ACTION_RETRY_BLOCK_MSEC
		_pending_action_targets.erase(rejected_key)
		if action == "mine_block" and behavior != null and behavior.executor != null and behavior.executor.current_action() == Contract.ACTION_MINE:
			behavior.executor.cancel("mine_rejected")
		return
	var key := "%d:%d" % [int(payload.get("x", 0)), int(payload.get("y", 0))]
	var target: Dictionary = _pending_action_targets.get(key, {}) if _pending_action_targets.get(key, {}) is Dictionary else {}
	_pending_action_targets.erase(key)
	_blocked_action_targets.erase("tile:%s" % key)
	if action == "mine_block" and behavior != null and behavior.executor != null and behavior.executor.current_action() == Contract.ACTION_MINE:
		behavior.executor.cancel("mine_acknowledged")
	var achievements := get_node_or_null("/root/Achievements")
	if achievements == null:
		return
	if action == "mine_block" and achievements.has_method("record_block_mined"):
		achievements.call("record_block_mined", _block_name_for_content_id(str(target.get("content_id", ""))))
	elif action == "place_block" and achievements.has_method("record_block_placed"):
		achievements.call("record_block_placed", str(target.get("block", "")))


func _update_snapshot_container(key: String, raw_container: Variant) -> void:
	var raw_containers: Variant = _world_snapshot.get("containers", [])
	if not raw_containers is Array:
		raw_containers = []
		_world_snapshot["containers"] = raw_containers
	var parts := key.split(":")
	if parts.size() != 2:
		return
	var wanted_x := int(parts[0])
	var wanted_y := int(parts[1])
	var containers: Array = raw_containers as Array
	for index in range(containers.size() - 1, -1, -1):
		if not containers[index] is Dictionary:
			continue
		var entry := containers[index] as Dictionary
		if int(entry.get("x", 0)) != wanted_x or int(entry.get("y", 0)) != wanted_y:
			continue
		if raw_container is Dictionary:
			entry["data"] = (raw_container as Dictionary).duplicate(true)
			containers[index] = entry
		else:
			containers.remove_at(index)
		_world_snapshot["containers"] = containers
		return
	if raw_container is Dictionary:
		containers.append({"x": wanted_x, "y": wanted_y, "data": (raw_container as Dictionary).duplicate(true)})
		_world_snapshot["containers"] = containers


func _emit_left(reason: String) -> void:
	if _left_emitted:
		return
	_left_emitted = true
	_set_state(STATE_LEAVING)
	structured_log.emit({"event": "session_left", "session_id": session_id, "reason": reason, "at_msec": Time.get_ticks_msec()})
	session_left.emit(reason)


func _host_id_from_network() -> String:
	if network_client != null and network_client.has_method("host_player_id"):
		return str(network_client.call("host_player_id"))
	return ""


func _expire_craft_pending(now_msec: int) -> void:
	if _craft_pending_output.is_empty() or _craft_retry_after_msec < 0 or now_msec < _craft_retry_after_msec:
		return
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	# Do not cool down an output the local snapshot already owns — that is the
	# inventory_snapshot success path waiting on a slow host echo.
	if int(inventory.get(_craft_pending_output, 0)) <= 0:
		_block_craft_output(_craft_pending_output, now_msec)
	_craft_pending_output = ""
	_craft_retry_after_msec = -1


func _block_craft_output(output: String, now_msec: int = -1) -> void:
	output = output.strip_edges()
	if output.is_empty():
		return
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	_craft_blocked_outputs[output] = now_msec + CRAFT_BLOCK_COOLDOWN_MSEC


func _active_craft_blocked_outputs(now_msec: int) -> Array:
	var active: Array = []
	for raw_output in _craft_blocked_outputs.keys():
		var output := str(raw_output)
		if now_msec < int(_craft_blocked_outputs[raw_output]):
			active.append(output)
		else:
			_craft_blocked_outputs.erase(raw_output)
	return active


func _achievement_observation() -> Dictionary:
	var achievements := get_node_or_null("/root/Achievements")
	if achievements != null and achievements.has_method("observation_for_bot"):
		var payload: Variant = achievements.call("observation_for_bot")
		if payload is Dictionary:
			return (payload as Dictionary).duplicate(true)
	if achievements != null and achievements.has_method("unlocked_ids"):
		return {"unlocked": achievements.call("unlocked_ids"), "open": []}
	return {"unlocked": [], "open": []}


func _set_state(next_state: String) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(state)
