class_name BotSession
extends Node

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const Perception = preload("res://gameplay/scripts/bot/bot_perception.gd")
const Navigator = preload("res://gameplay/scripts/bot/bot_navigator.gd")
const BlockDefs = preload("res://gameplay/scripts/block_defs.gd")
const Social = preload("res://gameplay/scripts/bot/bot_social.gd")
const BehaviorClass = preload("res://gameplay/scripts/bot/bot_behavior.gd")
const RuleProviderClass = preload("res://gameplay/scripts/bot/bot_rule_provider.gd")
const SafetyClass = preload("res://gameplay/scripts/bot/bot_safety_policy.gd")
const ExecutorClass = preload("res://gameplay/scripts/bot/bot_executor.gd")

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
var _last_emoji_sent_msec := -1
var _previous_emoji := ""
var _social_last_sent_msec := -1
var _welcome_emoji_due_msec := -1
var _welcome_emoji_pending := false
var _movement_step_callable: Callable
var _desired_input := {"left": false, "right": false, "jump": false}
var _last_player_input_msec := -1
var _social := Social.new()
var _last_player_snapshot_msec := -1
var _equipment_slots := {"hand": "", "feet": ""}
var _pending_action_targets: Dictionary = {}
var _blocked_action_targets: Dictionary = {}
var _terrain_tiles: Dictionary = {}
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
var _host_player_id := ""
var _pvp_enemy_player_id := ""
var _duel_started := false
var _pvp_chest_opened := false
var _last_duel_ready_msec := -1
var _craft_pending_output := ""
var _craft_retry_after_msec := -1
var _craft_blocked_outputs: Dictionary = {}
var _population_logged := false
const PLAYER_SNAPSHOT_INTERVAL_MSEC := 100
const PLAYER_INPUT_INTERVAL_MSEC := 50
const DUEL_PROTOCOL_VERSION := 3
const NETWORK_PHYSICS_TICKS_PER_SECOND := 60.0
const CRAFT_RESPONSE_TIMEOUT_MSEC := 4_000
const CRAFT_RETRY_DELAY_MSEC := 8_000
const ACTION_RETRY_BLOCK_MSEC := 4_000
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


func configure(backend_adapter: Object = null, multiplayer_adapter: Object = null, options: Dictionary = {}) -> void:
	backend = backend_adapter
	network_client = multiplayer_adapter
	protocol_version = int(options.get("protocol_version", protocol_version))
	empty_grace_msec = maxi(0, int(float(options.get("empty_grace_seconds", float(empty_grace_msec) / 1000.0)) * 1000.0))
	observation_radius = maxf(32.0, float(options.get("observation_radius", observation_radius)))
	_movement_step_callable = options.get("movement_step", Callable(self, "_default_movement_step")) if options.get("movement_step", Callable(self, "_default_movement_step")) is Callable else Callable(self, "_default_movement_step")
	if options.get("response_enabled", true) is bool:
		safety.response_enabled = bool(options.get("response_enabled", true))
	if options.has("retaliation_window_msec"):
		safety.retaliation_window_msec = maxi(0, int(options.get("retaliation_window_msec", safety.retaliation_window_msec)))
	if options.has("decision_provider") and options.get("decision_provider") is BotDecisionProvider:
		behavior.provider = options.get("decision_provider")
	executor.configure(network_client, Callable(), _movement_step_callable, Callable(safety, "consume_retaliation"))
	_connect_network_signals()


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
	_last_player_snapshot_msec = -1
	_last_player_input_msec = -1
	_desired_input = {"left": false, "right": false, "jump": false}
	_pending_action_targets.clear()
	_blocked_action_targets.clear()
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
	_host_player_id = ""
	_pvp_enemy_player_id = ""
	_duel_started = false
	_pvp_chest_opened = false
	_last_duel_ready_msec = -1
	_session_world_mode = str(record.get("world_mode", record.get("mode", ""))).to_lower()
	_craft_pending_output = ""
	_craft_retry_after_msec = -1
	_craft_blocked_outputs.clear()
	_population_logged = false
	safety.reset_session()
	_world_snapshot.clear()
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
		"health": clampi(int(local.get("health", 10)), 0, 10),
		"nourishment": clampi(int(local.get("nourishment", 100)), 0, 100),
		"respawn_revision": int(local.get("respawn_revision", 0)),
		"skin": BOT_SKIN.duplicate(true),
		"equipment_slots": _equipment_slots.duplicate(true),
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
	var hint := "" if _is_pvp_world() else (route_kind if route_kind in ["jump", "climb"] else _movement_hint(origin, destination))
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
	# Duel arenas have two fixed six-block islands centered at -18 and 18.
	# Stop at the edge before the next input can carry the bot into the void;
	# the next provider decision can then place a bounded bridge block.
	return (direction < 0.0 and support.x <= 13 and support.x >= 10) or (direction > 0.0 and support.x >= -13 and support.x <= -10)


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
		var key := "%d:%d" % [int(tile.get("x", 0)), int(tile.get("y", 0))]
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
	_physics_route_replan_msec = 0


func _terrain_name_at(tx: int, ty: int) -> String:
	return str(_terrain_tiles.get("%d:%d" % [tx, ty], ""))


func _terrain_solid_at(tx: int, ty: int) -> bool:
	var name := _terrain_name_at(tx, ty)
	return not name.is_empty() and bool(_block_entry(name).get("solid", false))


func _terrain_climbable_at(tx: int, ty: int) -> bool:
	var name := _terrain_name_at(tx, ty)
	return name in ["wood", "leaves", "shagot_scaffold"] or name.ends_with("_wood") or name.ends_with("_leaves")


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
	var step := clampf(maxf(delta, 0.0) * NETWORK_PHYSICS_TICKS_PER_SECOND, 0.25, 2.0)
	var width := float(self_state.get("w", 20.0))
	var height := float(self_state.get("h", 28.0))
	var x := float(self_state.get("x", 0.0))
	var y := float(self_state.get("y", 0.0))
	var vx := float(self_state.get("vx", 0.0))
	var vy := float(self_state.get("vy", 0.0))
	var on_ground := bool(self_state.get("on_ground", false))
	var direction := (-1.0 if bool(_desired_input.get("left", false)) else (1.0 if bool(_desired_input.get("right", false)) else 0.0))
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
			var horizontal_hit := _local_collision(next_x, y, width, height)
			if horizontal_hit.is_empty():
				x = next_x
			else:
				x = float(horizontal_hit.get("bx", x)) - width if vx > 0.0 else float(horizontal_hit.get("bx", x)) + float(BlockDefs.TILE)
				vx = 0.0
		var next_y := y + vy * substep
		var vertical_hit := _local_collision(x, next_y, width, height)
		if vertical_hit.is_empty():
			y = next_y
			on_ground = is_zero_approx(vy) and not _local_collision(x, y + 1.5, width, height).is_empty()
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
	if on_ground:
		# A support placement is scoped to one airborne arc.  Re-arm only after
		# the authoritative/local collision adapter has put the bot on ground.
		_support_place_attempted = false
	else:
		_try_place_support_block(self_state)


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


func _local_collision(px: float, py: float, width: float, height: float) -> Dictionary:
	var left := floori(px / float(BlockDefs.TILE))
	var right := floori((px + width - 0.001) / float(BlockDefs.TILE))
	var top := floori(py / float(BlockDefs.TILE))
	var bottom := floori((py + height - 0.001) / float(BlockDefs.TILE))
	for tile_y in range(top, bottom + 1):
		for tile_x in range(left, right + 1):
			if _terrain_solid_at(tile_x, tile_y):
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


func _climb_step(self_state: Dictionary, destination: Vector2, delta: float) -> Dictionary:
	var origin := Contract.target_position(self_state)
	if not _local_climb_contact(self_state):
		_climb_active = false
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": false, "reason": "climb_contact_lost"}
	if not _climb_active:
		var direction := signf(destination.x - origin.x)
		_climb_column = floori((origin.x + 10.0 + direction * 18.0) / float(BlockDefs.TILE))
		_climb_active = true
		_climb_time_left_msec = 1_200
	_climb_time_left_msec -= int(maxf(delta, 0.0) * 1000.0)
	var climb_step := 3.2 * maxf(delta, 0.0) * NETWORK_PHYSICS_TICKS_PER_SECOND
	var next_x := lerpf(origin.x, float(_climb_column * BlockDefs.TILE + 6), clampf(delta * 8.0, 0.0, 1.0))
	var next_y := origin.y - climb_step
	var still_on_tree := _terrain_climbable_at(_climb_column, floori((next_y + 14.0) / float(BlockDefs.TILE))) or _terrain_climbable_at(_climb_column, floori((next_y + 30.0) / float(BlockDefs.TILE)))
	if _climb_time_left_msec <= 0 or not still_on_tree:
		_climb_active = false
	if _climb_active:
		self_state["x"] = next_x
		self_state["y"] = next_y
		self_state["vx"] = (next_x - origin.x) / NETWORK_PHYSICS_TICKS_PER_SECOND
		self_state["vy"] = -3.2
		self_state["facing"] = 1 if destination.x >= origin.x else -1
		self_state["on_ground"] = false
	else:
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
	var snapshot_generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	var snapshot_is_duel := str(snapshot_generation.get("mode", "")).to_lower() == "duel"
	if not selected_world_mode.is_empty() and (snapshot_generation.is_empty() or selected_world_mode == "duel"):
		snapshot_generation["mode"] = selected_world_mode
		_world_snapshot["generation"] = snapshot_generation
		snapshot_is_duel = selected_world_mode == "duel"
	_rebuild_terrain_index(_world_snapshot.get("tiles", []))
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
	_world_snapshot["inventory_summary"] = _inventory_by_name(snapshot.get("inventory", {}))
	_world_snapshot["recipes"] = _recipe_catalog(snapshot)
	_equipment_slots = _equipment_by_name(snapshot.get("equipment_slots", {}))
	_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	_world_snapshot["craft_pending_output"] = _craft_pending_output
	_world_snapshot["craft_retry_after_msec"] = _craft_retry_after_msec
	_world_snapshot["craft_blocked_outputs"] = _craft_blocked_outputs.keys()
	_world_snapshot["visible_resources"] = _visible_resources_from_tiles(_world_snapshot.get("tiles", []), local_state)
	_world_snapshot["visible_containers"] = _visible_containers_from_snapshot(_world_snapshot, local_state)
	_world_snapshot["threats"] = _threats_from_creatures(_world_snapshot.get("creatures", []))
	sync_complete = true
	_snapshot_transfer_id = ""
	_snapshot_expected_chunks = 0
	_snapshot_chunks.clear()
	_update_human_count()
	_set_state(STATE_PLAYING)
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
			# collision dimensions from the initial snapshot, but reconcile movement
			# and physics state from the server at the normal snapshot cadence.
			var local_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
			for field in ["x", "y", "facing", "vx", "vy", "on_ground", "health", "nourishment", "respawn_revision", "tree_ghost", "climbing", "climb_col"]:
				if entry.has(field):
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


func _send_inventory_snapshot() -> void:
	if network_client == null or not network_client.has_method("send_command"):
		return
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	network_client.call("send_command", "inventory_snapshot", {
		"inventory_host_revision": 0,
		"inventory_client_revision": 0,
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


func _apply_inventory_snapshot(payload: Dictionary) -> void:
	var inventory: Dictionary = payload.get("inventory", {}) if payload.get("inventory", {}) is Dictionary else {}
	_world_snapshot["inventory_summary"] = inventory.duplicate(true)
	_equipment_slots = payload.get("equipment_slots", _equipment_slots).duplicate(true) if payload.get("equipment_slots", _equipment_slots) is Dictionary else _equipment_slots
	_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	if not _craft_pending_output.is_empty() and int(inventory.get(_craft_pending_output, 0)) > 0:
		_craft_blocked_outputs.erase(_craft_pending_output)
		_craft_pending_output = ""
		_craft_retry_after_msec = Time.get_ticks_msec() + CRAFT_RETRY_DELAY_MSEC


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
	snapshot["players"] = _roster.values()
	snapshot["recent_events"] = _recent_events.duplicate(true)
	snapshot["world_id"] = world_id
	snapshot["legal_actions"] = Contract.ALL_ACTIONS
	snapshot["self_defense"] = safety.observation_state(now_msec)
	snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	snapshot["craft_pending_output"] = _craft_pending_output
	snapshot["craft_retry_after_msec"] = _craft_retry_after_msec
	snapshot["craft_blocked_outputs"] = _craft_blocked_outputs.keys()
	snapshot["terrain_tiles"] = _terrain_observation(snapshot["self"] as Dictionary)
	snapshot["visible_containers"] = _visible_containers_from_snapshot(snapshot, snapshot["self"] as Dictionary)
	if _is_pvp_world() and not _pvp_chest_opened and _duel_fallback_container(snapshot["self"] as Dictionary).size() > 0:
		var has_chest := false
		for raw_container in snapshot["visible_containers"]:
			if raw_container is Dictionary and str((raw_container as Dictionary).get("kind", "")) == "chest":
				has_chest = true
				break
		if not has_chest:
			snapshot["visible_containers"].append(_duel_fallback_container(snapshot["self"] as Dictionary))
	snapshot["visible_resources"] = _filter_blocked_resources(snapshot.get("visible_resources", []), now_msec)
	var generation: Dictionary = snapshot.get("generation", {}) if snapshot.get("generation", {}) is Dictionary else {}
	snapshot["pvp_world"] = _is_pvp_world()
	snapshot["duel_started"] = _duel_started
	snapshot["pvp_chest_opened"] = _pvp_chest_opened
	snapshot["enemy_player_id"] = _enemy_player_id()
	snapshot["bow_attack_distance"] = BlockDefs.TILE * 10.0
	snapshot["achievements"] = _achievement_observation()
	if _welcome_emoji_pending and now_msec >= _welcome_emoji_due_msec:
		snapshot["social_emoji"] = "👋"
	else:
		snapshot["social_emoji"] = ""
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
	var chest_x := 14 if enemy_position.x < 0.0 else -14
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


func _on_decision_proposed(decision: Dictionary) -> void:
	decision_logged.emit({"event": "decision_proposed", "decision": decision.duplicate(true), "at_msec": Time.get_ticks_msec()})


func _on_decision_rejected(decision: Dictionary, reason: String) -> void:
	decision_logged.emit({"event": "decision_rejected", "decision": decision.duplicate(true), "reason": reason, "at_msec": Time.get_ticks_msec()})


func _on_decision_started(decision: Dictionary) -> void:
	var now_msec := Time.get_ticks_msec()
	var action := str(decision.get("action", ""))
	if action == Contract.ACTION_EQUIP:
		var item_name := str(decision.get("target_id", ""))
		# Equipment is now applied by the authoritative host through equip_item.
		# Do not overwrite the replicated inventory optimistically: an older host
		# snapshot would otherwise clear the slot and make the provider equip the
		# same boots/pickaxe forever.
		if not item_name.is_empty():
			_pending_action_targets["equip"] = {"action": action, "item": item_name, "sent_at_msec": now_msec}
	elif action == Contract.ACTION_MINE or action == Contract.ACTION_PLACE:
		var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
		var key := "%d:%d" % [int(target.get("x", 0)), int(target.get("y", 0))]
		_pending_action_targets[key] = {"action": action, "block": str(decision.get("block", "")), "content_id": str(target.get("content_id", "")), "sent_at_msec": now_msec}
	elif action == Contract.ACTION_CRAFT:
		_craft_pending_output = str(decision.get("target_id", ""))
		_craft_retry_after_msec = now_msec + CRAFT_RESPONSE_TIMEOUT_MSEC
		_pending_action_targets["craft"] = {"action": action, "output": _craft_pending_output}
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
		if _social.emoji_can_send(_last_emoji_sent_msec, now_msec, emoji, _previous_emoji, _social_last_sent_msec):
			_last_emoji_sent_msec = now_msec
			_social_last_sent_msec = now_msec
			_previous_emoji = emoji
			_welcome_emoji_pending = false
		else:
			behavior.executor.cancel("emoji_cooldown")
	decision_logged.emit({"event": "decision_started", "decision": decision.duplicate(true), "at_msec": now_msec})


func _handle_action_result(payload: Dictionary) -> void:
	var action := str(payload.get("action", ""))
	if action == "equip_item":
		_pending_action_targets.erase("equip")
		if bool(payload.get("accepted", false)) and payload.get("equipment_slots", null) is Dictionary:
			_equipment_slots = (payload.get("equipment_slots") as Dictionary).duplicate(true)
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
			_craft_blocked_outputs[output] = true
		elif accepted:
			_craft_blocked_outputs.erase(output)
		_craft_retry_after_msec = Time.get_ticks_msec() + (CRAFT_RETRY_DELAY_MSEC if not accepted else 2_000)
		_pending_action_targets.erase("craft")
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
		return
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
	# Older community hosts may ignore the newer craft_recipe command. Mark the
	# output unavailable for this session instead of retrying forever and
	# starving the bot's mining/building goals.
	_craft_blocked_outputs[_craft_pending_output] = true
	_craft_pending_output = ""
	_craft_retry_after_msec = -1


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
