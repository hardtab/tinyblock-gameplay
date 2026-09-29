class_name BotSession
extends Node

const Contract = preload("res://gameplay/scripts/bot/bot_contract.gd")
const Perception = preload("res://gameplay/scripts/bot/bot_perception.gd")
const BuildPlanner = preload("res://gameplay/scripts/bot/bot_build_planner.gd")
const DigPlanner = preload("res://gameplay/scripts/bot/bot_dig_planner.gd")
const Navigator = preload("res://gameplay/scripts/bot/bot_navigator.gd")
const BlockDefs = preload("res://gameplay/scripts/block_defs.gd")
const WorldScriptResource = preload("res://gameplay/scripts/world.gd")
const Social = preload("res://gameplay/scripts/bot/bot_social.gd")
const EmojiReactions = preload("res://gameplay/scripts/emoji_reactions.gd")
const BehaviorClass = preload("res://gameplay/scripts/bot/bot_behavior.gd")
const RuleProviderClass = preload("res://gameplay/scripts/bot/bot_rule_provider.gd")
const SafetyClass = preload("res://gameplay/scripts/bot/bot_safety_policy.gd")
const DescentPlannerClass = preload("res://gameplay/scripts/bot/bot_descent_planner.gd")
const AchievementRegistryClass = preload("res://gameplay/scripts/bot/bot_achievement_registry.gd")
const ExecutorClass = preload("res://gameplay/scripts/bot/bot_executor.gd")
const ActionLoop = preload("res://gameplay/scripts/bot/bot_action_loop.gd")
const AiClientClass = preload("res://gameplay/scripts/bot/bot_ai_client.gd")

signal state_changed(state: String)
signal sync_started(session_id: String)
signal session_ready(session_id: String, player_id: String)
signal human_player_count_changed(count: int)
signal empty_world_ready()
signal session_left(reason: String)
signal world_block_requested(world_id: String, killer_player_id: String, kill_count: int)
signal decision_logged(event: Dictionary)
signal structured_log(event: Dictionary)

const STATE_IDLE := "IDLE"
const STATE_JOINING := "JOINING"
const STATE_SYNCING := "SYNCING"
const STATE_PLAYING := "PLAYING"
const STATE_LEAVING := "LEAVING"

const DEFAULT_SYNC_TIMEOUT_MSEC := 45_000
const INITIAL_INVENTORY_ECHO_RETRY_MSEC := 2_000
const INITIAL_INVENTORY_ECHO_TIMEOUT_MSEC := 30_000
## The shared multiplayer client emits `connected` only once per session, so a
## P2P RTC reconnect can leave the bot waiting in SYNCING with no further
## request. Mirror the human guest path: retry the full request until a transfer
## starts, then request only the missing chunks, then restart a fresh transfer.
## The existing 45s hard timeout still bounds the whole attempt.
const SNAPSHOT_RETRY_INTERVAL_MSEC := 6_000
const SNAPSHOT_RETRY_LIMIT := 3
const DEFAULT_EMPTY_GRACE_MSEC := 30_000
const DEFAULT_OBSERVATION_RADIUS := 256.0
const DEFAULT_STRUCTURAL_MEMORY_PATH := "user://bot_structural_memory.json"
const MAX_STRUCTURAL_MEMORY_WORLDS := 32
const MAX_STRUCTURAL_MEMORY_CELLS := 1024
const CHEST_OBSERVATION_RADIUS := 512.0
const STARTER_TOOLING_RESOURCE_SCAN_RADIUS := 1536.0
const MID_TIER_TOOL_SEARCH_TIMEOUT_MSEC := 120_000
const MID_TIER_TOOL_NO_FRONTIER_TIMEOUT_MSEC := 5_000
const MID_TIER_TOOL_SEARCH_RETRY_MSEC := 90_000
const MID_TIER_TOOL_MAX_SEARCH_ATTEMPTS := 2

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
var _live_one_block_mined := 0
var _live_challenge_best_distance := 0
## Progression state is scoped to the active world and advances only from the
## authoritative initial/player-inventory snapshots or action acknowledgements.
var _stone_age_goal_state: Dictionary = {}
## Post-Stone-Age tool crafting is a world-local objective. A missing ingredient
## keeps the same output pinned while the bot safely explores, and host inventory
## is the only signal that completes that output.
var _mid_tier_tool_goal_state: Dictionary = {}
var _stone_age_authoritative_inventory: Dictionary = {}
var _host_tree_inventory_names: Dictionary = {}
var _stone_age_authoritative_equipment := {"hand": "", "feet": ""}
## Goal-level retries for achievement strategies other than Stone Age. State is
## deliberately scoped to one world; a new world never inherits old attempts.
var _achievement_goal_states: Dictionary = {}
## Achievement ids that were already unlocked when this world's goal states
## were first synced. Persisted credit is baseline, not in-session progress, so
## these never emit goal_completed; that event stays reserved for real unlocks
## the bot observes while it is playing.
var _achievement_goal_unlocked_baseline: Dictionary = {}
## A route-backed construction is a small persistent project: keep the same
## observed destination across placement steps and finish only when it becomes
## reachable according to the next authoritative observation.
var _build_project_state: Dictionary = {}
var _visited_floating_islands: Dictionary = {}
var _build_project_route_cache_key := ""
var _build_project_route_checked_msec := -1
var _build_project_route_reachable := false
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
var _transport_reconnect_started_msec := -1
var _snapshot_transfer_id := ""
var _snapshot_expected_chunks := 0
var _snapshot_chunks: Array[String] = []
var _snapshot_retry_at_msec := -1
var _snapshot_retry_count := 0
var _region_incoming_transfers: Dictionary = {}
var _region_chunk_request_msec: Dictionary = {}
var _region_received_chunks: Dictionary = {}
var _last_region_chunk_request_msec := -1
var _world_snapshot: Dictionary = {}
var _first_observation_probe_pending := true
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
var _protected_build_cells: Dictionary = {}
var _structural_memory_path := DEFAULT_STRUCTURAL_MEMORY_PATH
var _structural_memory_cells: Dictionary = {}
var _opened_generated_chest_cells: Dictionary = {}
var _terrain_tiles: Dictionary = {}
## Only host-reported level zero is a collectible water/lava source. A tile
## name alone cannot distinguish it from a temporary flow.
var _terrain_fluid_levels: Dictionary = {}
var _jump_landing_cache: Dictionary = {}
var _terrain_revision := 0
## Converting every known tile into a descent-planner entry on each 10 Hz
## players_snapshot stalls large worlds, including the initial inventory echo.
## Terrain mutations already invalidate _terrain_revision via the jump cache.
var _descent_terrain_cache: Dictionary = {}
var _descent_terrain_cache_revision := -1
var _last_flee_route_diagnostic_msec := -1
var _last_flee_motion_diagnostic_msec := -1
var _last_pursuit_route_diagnostic_msec := -1
## Fully replicated procedural chunks prove that omitted cells are air. Static
## worlds instead use a small bounded area from their complete initial snapshot.
var _terrain_known_chunks: Dictionary = {}
var _safe_exploration_waypoint_cache: Array[Dictionary] = []
var _safe_exploration_waypoint_cache_origin := Vector2i(2147483647, 2147483647)
var _safe_exploration_waypoint_cache_checked_msec := -1
var _safe_exploration_waypoint_cache_state_signature := ""
## Explicitly observed tile coordinates. Missing terrain is treated as air only
## when a complete static-world snapshot or generated chunk proves that cell.
var _terrain_observed_cells: Dictionary = {}
var _descent_snapshot_complete := false
var _descent_planner = DescentPlannerClass.new()
var _descent_last_plan: Dictionary = {}
var _support_preserving_mine_tiles: Dictionary = {}
var _plant_tiles: Dictionary = {}
var _physics_route: Array[Dictionary] = []
var _physics_route_target := Vector2i(2147483647, 2147483647)
var _physics_route_target_id := ""
var _physics_route_replan_msec := -1
var _physics_route_first_step_guarded := false
var _physics_route_later_step_guarded := false
var _last_movement_stall_probe_msec := -1
var _host_rejected_transitions: Dictionary = {}
var _active_air_transition: Dictionary = {}
var _host_rejected_transition_from := Vector2i(2147483647, 2147483647)
var _host_rejected_transition_until_msec := -1
var _physics_advanced_this_frame := false
var _jump_active := false
var _jump_predicted_landed := false
var _jump_velocity := 0.0
var _jump_ground_y := 0.0
var _jump_start_x := 0.0
var _jump_started_msec := -1
var _decision_probe_observation: Dictionary = {}
var _last_island_idle_probe_msec := -1
var _climb_active := false
var _climb_column := 0
var _climb_time_left_msec := 0
var _support_place_attempted := false
var _support_place_last_attempt_msec := -1
var _was_in_harmful_fluid := false
var _harmful_fluid_damage_cooldown := 0.0
var _lava_retreat_active := false
var _guest_defeat_pending := false
var _guest_defeat_retry_after_msec := -1
var _guest_defeat_sent_revision := -1
var _host_player_id := ""
var _aggressive_player_id := ""
var _last_player_damage_attacker_id := ""
var _last_player_damage_msec := -1
var _player_death_count := 0
var _host_kill_streak := 0
var _host_kill_leave_at_msec := -1
var _world_block_requested := false
var _pvp_enemy_player_id := ""
var _pvp_enemy_last_known_state: Dictionary = {}
var _pvp_enemy_last_seen_msec := -1
var _duel_started := false
var _pvp_chest_opened := false
var _last_duel_ready_msec := -1
## Authoritative end-of-match control from the host. Once set, combat
## decisions and commands stop for the rest of the session so the bot cannot
## keep shooting or chasing a resolved duel.
var _duel_result_received := false
var _duel_result: Dictionary = {}
var _craft_pending_output := ""
var _craft_retry_after_msec := -1
## output_name -> blocked_until_msec. Timed so a missed craft_recipe ack
## cannot permanently starve plank/tool progression for the session.
var _craft_blocked_outputs: Dictionary = {}
var _food_eat_cooldown_until_msec := -1
var _inventory_host_revision := 0
var _inventory_client_revision := 0
var _initial_loadout_source := ""
var _initial_inventory_request_msec := -1
var _initial_inventory_last_request_msec := -1
var _initial_inventory_echo_logged := false
var _action_started_before_inventory_echo := false
var _population_logged := false
## True only while this session owns the /root/Achievements community lock, so
## a leave never unlocks a lock another system (e.g. the local host player) set.
var _achievements_lock_owned := false
## output_name -> true. Host-confirmed inventory snapshots and craft_recipe
## acknowledgements both funnel through _record_craft_achievement once.
var _achievements_recorded_crafts: Dictionary = {}
## One-shot: drop wooden_pickaxe + trail_boots after join so craft+equip can be
## proven from scratch on a community world that still had leftover gear.
var _strip_progression_gear := false
var _progression_gear_stripped := false
const PLAYER_SNAPSHOT_INTERVAL_MSEC := 100
const PLAYER_INPUT_INTERVAL_MSEC := 50
const HARMFUL_FLUID_DAMAGE_INTERVAL := 20.0 / 60.0
const GUEST_DEFEAT_RETRY_MSEC := 400
const RECENT_PLAYER_KILL_MSEC := 2_500
const HOST_KILL_LIMIT := 3
const HOST_KILL_LEAVE_DELAY_MSEC := 650
const HOST_KILL_EMOJIS: PackedStringArray = ["😱", "😡", "👎"]
const DUEL_PROTOCOL_VERSION := 3
const NETWORK_PHYSICS_TICKS_PER_SECOND := 60.0
const LOCAL_MAX_FALL_SPEED := 12.0
const MAX_AUTHORITATIVE_MOTION_DIVERGENCE := BlockDefs.TILE * 3.0
## Host snapshots can trail input-driven prediction by several physics frames.
## Live traces show a normal grounded echo up to about 37 px from the local pose;
## a smaller window misclassified that network lag as a rejected jump and
## blacklisted an otherwise usable edge for eight seconds.
const HOST_GROUNDED_AIR_REJECTION_TOLERANCE := maxf(BlockDefs.TILE * 1.25, absf(BlockDefs.JUMP))
const HOST_JUMP_ECHO_GRACE_MSEC := 900
const HOST_REJECTED_TRANSITION_COOLDOWN_MSEC := 8_000
const TREE_CLIMB_SPEED := -3.2
const FLEE_EMERGENCY_MAX_CLOSURE := BlockDefs.TILE * 1.25
const FLEE_EMERGENCY_MIN_STANDOFF := 48.0 + BlockDefs.TILE * 0.25
const CRAFT_RESPONSE_TIMEOUT_MSEC := 4_000
const CRAFT_RETRY_DELAY_MSEC := 8_000
const CRAFT_BLOCK_COOLDOWN_MSEC := 12_000
const STATION_RADIUS_TILES := 4
const MIN_PREPARED_MEAL_CREATURE_SIZE := 0.65
const FOOD_EAT_COOLDOWN_MSEC := 8_000
const STONE_AGE_CONFIRM_TIMEOUT_MSEC := 20_000
const STONE_AGE_RETRY_COOLDOWN_MSEC := 12_000
const STONE_AGE_ABANDON_COOLDOWN_MSEC := 60_000
const STONE_AGE_MAX_STAGE_FAILURES := 3
const STONE_AGE_NO_ACTION_TIMEOUT_MSEC := 15_000
const ACHIEVEMENT_GOAL_RETRY_MSEC := 20_000
const ACHIEVEMENT_GOAL_ABANDON_MSEC := 90_000
const ACHIEVEMENT_GOAL_MAX_FAILURES := 3
const ACHIEVEMENT_GOAL_CONFIRM_TIMEOUT_MSEC := 45_000
const ACHIEVEMENT_GOAL_MOVE_TIMEOUT_MSEC := 90_000
const BUILD_PROJECT_MAX_FAILURES := 3
const BUILD_PROJECT_RETRY_MSEC := 30_000
const BUILD_PROJECT_ROUTE_REPLAN_MSEC := 500
const ACTION_RETRY_BLOCK_MSEC := 8_000
const DESCENT_RETURN_ROUTE_RETRY_MSEC := 12_000
const MINE_REJECTION_RETRY_MSEC := 60_000
const DIG_ROUTE_CLEAR_REVISIT_MSEC := 20_000
const HARMFUL_FLUID_MINE_RETRY_MSEC := 300_000
const STATION_ROUTE_RETRY_BLOCK_MSEC := 30_000
const CONTAINER_RETRY_BLOCK_MSEC := 30_000
# Movement-route failures toward a chest are usually transient: the origin is
# mid-air for one frame, or the first step is momentarily blocked and the route
# is recomputed every tick. Cooling the chest for the full terminal window hid
# reachable chests. Only a genuine OPEN_CONTAINER terminal failure (an
# ack-timeout or host rejection) keeps CONTAINER_RETRY_BLOCK_MSEC.
const CONTAINER_MOVE_RETRY_BLOCK_MSEC := 1_500
const UNSAFE_ROUTE_RETRY_BLOCK_MSEC := 30_000
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
	_structural_memory_path = str(options.get("structural_memory_path", DEFAULT_STRUCTURAL_MEMORY_PATH))
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
	if network_client.has_signal("transport_changed"):
		network_client.connect("transport_changed", Callable(self, "_on_network_transport_changed"))


func join_session(record: Dictionary) -> void:
	if _join_in_flight or state in [STATE_JOINING, STATE_SYNCING, STATE_PLAYING]:
		return
	_left_emitted = false
	_disconnect_requested = false
	_transport_reconnect_started_msec = -1
	sync_complete = false
	empty_since_msec = -1
	_empty_emitted = false
	_snapshot_transfer_id = ""
	_snapshot_expected_chunks = 0
	_snapshot_chunks.clear()
	_snapshot_retry_at_msec = -1
	_snapshot_retry_count = 0
	_region_incoming_transfers.clear()
	_region_chunk_request_msec.clear()
	_region_received_chunks.clear()
	_last_region_chunk_request_msec = -1
	_roster.clear()
	_recent_events.clear()
	_recent_emoji_events.clear()
	_pending_social_emoji = ""
	_pending_social_emoji_target_id = ""
	_emoji_reply_inflight = false
	_last_player_snapshot_msec = -1
	_last_player_input_msec = -1
	_last_flee_motion_diagnostic_msec = -1
	_live_one_block_mined = 0
	_live_challenge_best_distance = 0
	_desired_input = {"left": false, "right": false, "jump": false}
	_pending_action_targets.clear()
	_blocked_action_targets.clear()
	_protected_build_cells.clear()
	_structural_memory_cells.clear()
	_opened_generated_chest_cells.clear()
	_action_loop_blocked_until.clear()
	_terrain_tiles.clear()
	_terrain_fluid_levels.clear()
	_invalidate_jump_landing_cache()
	_terrain_known_chunks.clear()
	_terrain_observed_cells.clear()
	_descent_snapshot_complete = false
	_descent_last_plan.clear()
	_support_preserving_mine_tiles.clear()
	_physics_route.clear()
	_physics_route_target = Vector2i(2147483647, 2147483647)
	_physics_route_target_id = ""
	_physics_route_first_step_guarded = false
	_physics_route_later_step_guarded = false
	_physics_route_replan_msec = -1
	_host_rejected_transitions.clear()
	_active_air_transition.clear()
	_host_rejected_transition_from = Vector2i(2147483647, 2147483647)
	_host_rejected_transition_until_msec = -1
	_jump_active = false
	_jump_predicted_landed = false
	_jump_velocity = 0.0
	_jump_ground_y = 0.0
	_jump_start_x = 0.0
	_jump_started_msec = -1
	_decision_probe_observation.clear()
	_last_island_idle_probe_msec = -1
	_climb_active = false
	_climb_column = 0
	_climb_time_left_msec = 0
	_support_place_attempted = false
	_support_place_last_attempt_msec = -1
	_was_in_harmful_fluid = false
	_harmful_fluid_damage_cooldown = 0.0
	_lava_retreat_active = false
	_guest_defeat_pending = false
	_guest_defeat_retry_after_msec = -1
	_guest_defeat_sent_revision = -1
	_host_player_id = ""
	_aggressive_player_id = ""
	_last_player_damage_attacker_id = ""
	_last_player_damage_msec = -1
	_player_death_count = 0
	_host_kill_streak = 0
	_host_kill_leave_at_msec = -1
	_world_block_requested = false
	_pvp_enemy_player_id = ""
	_pvp_enemy_last_known_state.clear()
	_pvp_enemy_last_seen_msec = -1
	_duel_started = false
	_pvp_chest_opened = false
	_last_duel_ready_msec = -1
	_duel_result_received = false
	_duel_result.clear()
	_session_world_mode = str(record.get("world_mode", record.get("mode", ""))).to_lower()
	_descent_planner.reset_session()
	_descent_planner.begin_session(
		str(record.get("session_id", "")),
		str(record.get("world_id", "")),
		_session_world_mode,
		_session_world_mode == "duel",
		Vector2i(2147483647, 2147483647),
	)
	_stone_age_goal_state.clear()
	_mid_tier_tool_goal_state.clear()
	_achievement_goal_states.clear()
	_achievement_goal_unlocked_baseline.clear()
	_build_project_state.clear()
	_visited_floating_islands.clear()
	_build_project_route_cache_key = ""
	_build_project_route_checked_msec = -1
	_build_project_route_reachable = false
	_stone_age_authoritative_inventory.clear()
	_host_tree_inventory_names.clear()
	_stone_age_authoritative_equipment = {"hand": "", "feet": ""}
	_craft_pending_output = ""
	_craft_retry_after_msec = -1
	_craft_blocked_outputs.clear()
	_food_eat_cooldown_until_msec = -1
	_inventory_host_revision = 0
	_inventory_client_revision = 0
	_population_logged = false
	_achievements_recorded_crafts.clear()
	_progression_gear_stripped = false
	_initial_loadout_source = ""
	_initial_inventory_request_msec = -1
	_initial_inventory_last_request_msec = -1
	_initial_inventory_echo_logged = false
	_action_started_before_inventory_echo = false
	safety.reset_session()
	_world_snapshot.clear()
	_first_observation_probe_pending = true
	_equipment_slots = {"hand": "", "feet": ""}
	session_id = str(record.get("session_id", ""))
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
		var failure := response as Dictionary if response is Dictionary else {}
		structured_log.emit(join_failure_log_event(record, failure))
		_emit_left(str(failure.get("error", "join_failed")))
		return
	_connect_join_response(response as Dictionary, record)


func join_failure_log_event(record: Dictionary, response: Dictionary) -> Dictionary:
	var event := {
		"event": "session_join_failed",
		"session_id": str(record.get("session_id", session_id)),
		"world_id": str(record.get("world_id", world_id)),
		"reason": str(response.get("error", "join_failed")),
		"at_msec": Time.get_ticks_msec(),
	}
	if response.has("code"):
		event["transport_code"] = int(response.get("code", 0))
	if response.has("status_code"):
		event["status_code"] = int(response.get("status_code", 0))
	return event


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
	# Mirror the host player's achievement scoping: managed community sessions
	# keep progression out of the shared account, official/dedicated sessions
	# keep it. Unknown dedicated metadata is treated as community.
	_sync_achievements_community_lock()
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
		# MultiplayerClient emits `connected` before it finishes extracting the
		# host id from the peer list. Refresh it here so an omitted client_version
		# on a P2P host is not mistaken for a legacy guest.
		_host_player_id = _host_id_from_network()
		if not _connected_peers_supported(message.get("players", [])):
			leave("legacy_client")
			return
		if state in [STATE_JOINING, STATE_SYNCING]:
			_send_snapshot_request()
			# A fresh connected event starts a new exchange; reset the retry
			# cadence so the first resend happens only after the normal interval.
			_snapshot_retry_count = 0
			_snapshot_retry_at_msec = Time.get_ticks_msec() + SNAPSHOT_RETRY_INTERVAL_MSEC
		return
	if kind == "control" and message_type == "player_left":
		var left_id := str(message.get("player_id", ""))
		_roster.erase(left_id)
		if left_id == _pvp_enemy_player_id:
			_pvp_enemy_last_known_state.clear()
			_pvp_enemy_last_seen_msec = -1
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
		var hit_msec := Time.get_ticks_msec()
		_record_recent_player_damage(payload, hit_msec)
		if safety.record_player_hit(payload, own_player_id, hit_msec):
			_record_event("player_hit", {"attacker_player_id": safety.attacker_player_id(), "damage": int(payload.get("damage", 0))})
		else:
			_record_event("player_hit_unattributed", {"target_player_id": str(payload.get("target_player_id", ""))})
		behavior.request_decision(Time.get_ticks_msec())
		return
	if message_type == "duel_start":
		_record_event("duel_start", payload)
		_duel_started = true
		# A rematch in the same session is a fresh match: clear the terminal
		# result so the bot can fight again instead of staying frozen.
		_duel_result_received = false
		_duel_result.clear()
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
	if message_type == "duel_result":
		_handle_duel_result(payload)
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
	if message_type == "region_start":
		structured_log.emit({
			"event": "region_transfer_started",
			"chunk_x": int(payload.get("chunk_x", WorldSim.COORD_LIMIT)),
			"total_chunks": int(payload.get("total", 0)),
			"at_msec": Time.get_ticks_msec(),
		})
		_prepare_region_transfer(payload)
		return
	if message_type == "region_chunk":
		_store_region_transfer_chunk(payload)
		return
	if message_type == "region_complete":
		structured_log.emit({
			"event": "region_transfer_complete_received",
			"chunk_x": int(payload.get("chunk_x", WorldSim.COORD_LIMIT)),
			"total_chunks": int(payload.get("total", 0)),
			"at_msec": Time.get_ticks_msec(),
		})
		_apply_completed_region_transfer(payload)
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
	for raw_transfer_id in _region_incoming_transfers.keys():
		var transfer_id := str(raw_transfer_id)
		var transfer: Dictionary = _region_incoming_transfers[transfer_id]
		if now_msec - int(transfer.get("started_at_msec", now_msec)) > 30_000:
			_region_incoming_transfers.erase(transfer_id)
	if state == STATE_SYNCING:
		if _sync_started_msec >= 0 and now_msec - _sync_started_msec >= DEFAULT_SYNC_TIMEOUT_MSEC:
			_emit_left("snapshot_timeout")
			return
		if _snapshot_retry_at_msec < 0:
			# Defensive: if the sync started without scheduling a retry, arm it.
			_snapshot_retry_at_msec = now_msec + SNAPSHOT_RETRY_INTERVAL_MSEC
		elif now_msec >= _snapshot_retry_at_msec:
			_retry_snapshot_sync(now_msec)
		return
	if state != STATE_PLAYING:
		return
	if _host_kill_leave_at_msec >= 0:
		_set_desired_input(false, false, false)
		_send_player_input_if_due(now_msec)
		_send_player_snapshot_if_due(now_msec)
		if now_msec >= _host_kill_leave_at_msec:
			leave("host_kill_limit")
		return
	if _transport_reconnect_started_msec >= 0:
		# The host cannot receive controls or return authoritative acknowledgements
		# while the guest RTC channel is being renegotiated. Freeze bot decisions,
		# predicted motion, and acknowledgement expiry until the transport recovers.
		_set_desired_input(false, false, false)
		return
	if _initial_inventory_request_msec >= 0 and not _initial_inventory_echo_logged:
		# The initial world snapshot may contain only the host's inventory. Wait
		# for the host's reply to our own inventory transaction before gathering,
		# crafting, or spending anything; otherwise an early action makes the
		# starting loadout impossible to verify and can race the inventory echo.
		_set_desired_input(false, false, false)
		_send_player_input_if_due(now_msec)
		_send_player_snapshot_if_due(now_msec)
		_check_empty_world_grace(now_msec)
		if now_msec - _initial_inventory_last_request_msec >= INITIAL_INVENTORY_ECHO_RETRY_MSEC:
			# The first inventory_snapshot can arrive before the host has registered
			# this guest in _remote_players and be ignored. Resend the exact same
			# revision after our player snapshot establishes that roster entry.
			_send_inventory_snapshot(false)
			_initial_inventory_last_request_msec = now_msec
		if now_msec - _initial_inventory_request_msec >= INITIAL_INVENTORY_ECHO_TIMEOUT_MSEC:
			structured_log.emit({
				"event": "initial_inventory_echo_timeout",
				"world_id": world_id,
				"at_msec": now_msec,
			})
			leave("initial_inventory_echo_timeout")
		return
	_request_missing_region_chunks(now_msec)
	_expire_craft_pending(now_msec)
	_expire_stone_age_pending(now_msec)
	_expire_achievement_goal_pending(now_msec)
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	# Hazard contact must tick even while WAIT/idle, otherwise a bot standing in
	# lava only takes damage when a movement action happens to run physics.
	_apply_local_harmful_fluid(self_state, delta)
	_world_snapshot["self"] = self_state
	var self_alive := int(self_state.get("health", 10)) > 0
	if not self_alive:
		# Death freezes ordinary decisions until the host confirms a respawn. Cancel
		# the in-flight action first so it cannot remain busy forever behind this
		# early return or resume stale movement on the next life.
		if behavior != null and behavior.executor != null and behavior.executor.is_busy():
			var interrupted_decision: Dictionary = behavior.executor.current_decision.duplicate(true)
			behavior.executor.cancel("bot_dead")
			structured_log.emit({
				"event": "dead_action_cancelled",
				"action": str(interrupted_decision.get("action", "")),
				"goal": str(interrupted_decision.get("goal", "")),
				"at_msec": now_msec,
			})
		_set_desired_input(false, false, false)
		_send_guest_defeat_if_due(now_msec)
		_send_player_input_if_due(now_msec)
		_send_player_snapshot_if_due(now_msec)
		_check_empty_world_grace(now_msec)
		return
	_guest_defeat_pending = false
	if _duel_result_received:
		# The host declared the outcome, so no further combat decisions or
		# movement commands should fire. Keep publishing input/snapshot so the
		# host still sees a stationary bot instead of a stale combat pose.
		_set_desired_input(false, false, false)
		_send_player_input_if_due(now_msec)
		_send_player_snapshot_if_due(now_msec)
		_check_empty_world_grace(now_msec)
		return
	var observation := _build_observation(now_msec)
	_decision_probe_observation = observation
	if _is_pvp_world() and not _duel_started and now_msec - _last_duel_ready_msec >= 1000:
		_send_duel_ready(now_msec)
	# The brain may run at a much lower cadence than physics. Reset the held
	# controls every frame; a movement executor reasserts them for this frame.
	_desired_input = {"left": false, "right": false, "jump": false}
	_physics_advanced_this_frame = false
	behavior.tick(observation, delta, now_msec)
	_decision_probe_observation = {}
	_advance_local_physics_if_needed(delta)
	_send_player_input_if_due(now_msec)
	# Keep the legacy snapshot during rollout. New hosts ignore its coordinates
	# after the first player_input packet, while old hosts can still display the
	# bot until they receive the new protocol.
	_send_player_snapshot_if_due(now_msec)
	_check_empty_world_grace(now_msec)


func _check_empty_world_grace(now_msec: int) -> void:
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
	_snapshot_retry_count = 0
	# The shared client suppresses a second `connected` event on RTC reconnect,
	# so the bot arms its own retry cadence instead of trusting that message.
	_snapshot_retry_at_msec = _sync_started_msec + SNAPSHOT_RETRY_INTERVAL_MSEC
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


func _should_settle_airborne(self_state: Dictionary, origin: Vector2) -> bool:
	# A host correction or an earlier action timeout can leave the real avatar
	# between supports without an active jump. Ground routes have no valid origin
	# there, so movement branches must resolve gravity before replanning instead
	# of declaring a valid destination unreachable on a transient airborne frame.
	return (
		not _climb_active
		and not bool(self_state.get("on_ground", false))
		and not _local_pose_has_support(self_state)
		and _active_verified_drop_step(origin, self_state).is_empty()
	)


func _default_movement_step(action: String, decision: Dictionary, observation: Dictionary, delta: float) -> Dictionary:
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	var origin := Contract.target_position(self_state)
	var target := Contract.target_position(decision.get("target", {}))
	var physics_first_step_guard := Callable()
	var flee_target_x := target.x
	var target_id := str(decision.get("target_id", ""))
	var player_target := false
	var emergency_fluid_escape_jump := false
	var flee_selected_support: Variant = []
	if target_id != "":
		for raw_player in observation.get("players", []):
			if raw_player is Dictionary and str((raw_player as Dictionary).get("id", "")) == target_id:
				var player_state := raw_player as Dictionary
				target = Contract.target_position(player_state)
				flee_target_x = target.x + maxf(1.0, float(player_state.get("w", 20.0))) * 0.5
				player_target = true
				break
	# Combat approach is a live intercept, not a point-in-time destination. A
	# creature can cover several tiles during a movement action; following the
	# position embedded in the decision made the bot chase a stale point until the
	# action timed out. Keep the originally chosen side and gap, but recompute the
	# approach point from each fresh threat observation while the executor is busy.
	var decision_target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
	var explicit_target_tile: Array = []
	if action == Contract.ACTION_MOVE_TO and decision_target.get("support_tile", []) is Array:
		explicit_target_tile = (decision_target.get("support_tile", []) as Array).duplicate()
	if action == Contract.ACTION_MOVE_TO and bool(decision_target.get("combat_approach", false)) and not target_id.is_empty():
		for raw_threat in observation.get("threats", []):
			if not raw_threat is Dictionary:
				continue
			var threat := raw_threat as Dictionary
			if str(threat.get("id", "")) != target_id or not bool(threat.get("alive", true)):
				continue
			var approach_side := signf(float(decision_target.get("combat_approach_side", 0.0)))
			if is_zero_approx(approach_side):
				approach_side = signf(origin.x - Contract.target_position(threat).x)
			if is_zero_approx(approach_side):
				approach_side = -1.0 if int(self_state.get("facing", 1)) > 0 else 1.0
			var live_threat_position := Contract.target_position(threat)
			var approach_gap := clampf(float(decision_target.get("combat_approach_gap", 32.0)), 16.0, 48.0)
			target = Vector2(live_threat_position.x + approach_side * approach_gap, live_threat_position.y)
			break
	if action == Contract.ACTION_MOVE_TO and target_id.begins_with("container:"):
		# Containers are solid blocks. Route to a supported interaction position,
		# then use a proven intermediate waypoint when the chest is farther than
		# the bounded route graph can solve in one action.
		# An already verified jump/drop can span two short decision windows. Let
		# the shared movement executor finish that transition before asking the
		# grounded route graph for another waypoint from its airborne midpoint.
		var continuing_verified_transition := _jump_active or not _active_verified_drop_step(origin, self_state).is_empty()
		if not continuing_verified_transition and origin.distance_to(target) <= float(BlockDefs.TILE) * 4.5:
			_set_desired_input(false, false, false)
			return {"done": true, "reason": "already_at_target"}
		# The generic airborne settling guard below runs *after* this branch, so
		# a transient airborne origin (host correction or a previous action
		# timeout) would make container routing report route_unreachable and then
		# cool the chest for the full container retry window. Settle gravity
		# first and let the same route be replanned on the next tick.
		if not continuing_verified_transition and _should_settle_airborne(self_state, origin):
			_set_desired_input(false, false, false)
			_advance_local_physics(self_state, delta, false)
			_world_snapshot["self"] = self_state
			return {"done": false, "reason": "airborne_settling"}
		if not continuing_verified_transition:
			var container_stand := _reachable_stand_position_for_block(origin, decision_target)
			if not container_stand.is_empty():
				target = Contract.target_position(container_stand)
			else:
				var container_waypoint := _safe_pursuit_waypoint(origin, target, _safe_jump_first_step_filter(self_state))
				if container_waypoint.is_empty():
					_set_desired_input(false, false, false)
					return {"done": true, "reason": "route_unreachable"}
				target = Contract.target_position(container_waypoint)
	if (
		action == Contract.ACTION_MOVE_TO
		and target_id.begins_with("tile:")
		and not _jump_active
		and _active_verified_drop_step(origin, self_state).is_empty()
	):
		# A previously verified jump must reach its planned landing before the
		# resource interaction side is replanned. The same applies to an already
		# verified drop: its in-air support cell is not a new ground-route origin.
		if _should_settle_airborne(self_state, origin):
			_set_desired_input(false, false, false)
			_advance_local_physics(self_state, delta, false)
			_world_snapshot["self"] = self_state
			return {"done": false, "reason": "airborne_settling"}
		var requested_approach: Variant = decision_target.get("approach_position", [])
		var stand_position: Dictionary = {}
		if requested_approach is Array and (requested_approach as Array).size() >= 2:
			stand_position = _reachable_explicit_stand_position(origin, self_state, requested_approach as Array)
		if stand_position.is_empty() and decision_target.has("x") and decision_target.has("y"):
			# Observation and execution are separated by network updates. The bot can
			# move, be reseated by the host, or receive a newly rejected transition
			# after the policy selected this resource. Re-select any currently
			# reachable interaction side before treating the original stand tile as
			# unreachable; otherwise a stale approach can strand a still-reachable
			# resource and trigger its long target cooldown.
			stand_position = _reachable_stand_position_for_block(origin, decision_target)
		if not stand_position.is_empty():
			target = Contract.target_position(stand_position)
			var stand_support: Variant = stand_position.get("support_tile", [])
			if stand_support is Array and (stand_support as Array).size() >= 2:
				explicit_target_tile = (stand_support as Array).duplicate()
		else:
			# The resource may be reachable but farther away than one bounded route
			# search. Advance along a physics-proven support waypoint and reconsider
			# its interaction side after the next observation. The shared first-step
			# and landing guards still reject unverified jumps and drops.
			var resource_waypoint := _safe_pursuit_waypoint(
				origin,
				target,
				_safe_jump_first_step_filter(self_state),
			)
			if resource_waypoint.is_empty():
				_set_desired_input(false, false, false)
				_advance_local_physics(self_state, delta, false)
				_world_snapshot["self"] = self_state
				return {"done": true, "reason": "route_unreachable"}
			target = resource_waypoint.get("position", target)
			var waypoint_support: Variant = resource_waypoint.get("support_tile", Vector2i(2147483647, 2147483647))
			if typeof(waypoint_support) == TYPE_VECTOR2I:
				explicit_target_tile = [waypoint_support.x, waypoint_support.y]

	if action == Contract.ACTION_LOOK_AT:
		_set_desired_input(false, false, false)
		_jump_active = false
		_jump_predicted_landed = false
		_jump_started_msec = -1
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
	# When fleeing, complete an already-launched jump toward its verified landing
	# before planning a fresh ground route. FLEE_FROM used to search from
	# the unsupported mid-jump pose first, settle in place, and time out beside
	# the hostile without ever reaching this jump continuation.
	var active_landing: Variant = _active_air_transition.get("to")
	if action == Contract.ACTION_FLEE_FROM and _jump_active and typeof(active_landing) == TYPE_VECTOR2I:
		_log_flee_motion(origin, target, {"support_tile": active_landing}, "jump_continuation", self_state)
		return _jump_step(self_state, _world_position_for_support_tile(active_landing), delta)

	var destination := target
	if action in [Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_FOLLOW]:
		# Keep vertical separation when choosing the comfortable follow radius.
		# Flattening the player's Y made a bot directly above/below them appear
		# close enough horizontally, so MOVE_NEAR_PLAYER repeatedly completed at
		# its current position instead of navigating down a tree or ledge.
		destination = Navigator.preferred_follow_target(target, origin, float(observation.get("preferred_player_distance", 84.0)))
		if not _is_pvp_world():
			# Reachability alone can hand pursuit a support tile that is closer to
			# the player yet enterable only through a jump the movement guard below
			# refuses with unsafe_jump_route. That abort repeated every frame while
			# the bot stood still beside its target. Constrain the direct route and
			# the fallback pursuit waypoint to the same first edges with a proven
			# landing so a safe walk/drop/climb alternative wins instead.
			physics_first_step_guard = _safe_jump_first_step_filter(self_state)
	elif action == Contract.ACTION_FLEE_FROM:
		# A straight-line escape vector can point through water, a ravine or an
		# unsupported edge. Pick an actually reachable support tile that increases
		# distance from the threat; the same physics route will execute that choice.
		if _local_touches_harmful_fluid(self_state):
			var fluid_escape := _safe_harmful_fluid_escape_waypoint(self_state, origin, target)
			if fluid_escape.is_empty():
				_set_desired_input(false, false, false)
				_advance_local_physics(self_state, delta, false)
				_world_snapshot["self"] = self_state
				return {"done": true, "reason": "flee_no_dry_fluid_landing"}
			destination = fluid_escape.get("position", target)
			emergency_fluid_escape_jump = true
		elif not _terrain_tiles.is_empty():
			var body_center := origin + Vector2(
				float(self_state.get("w", 20.0)) * 0.5,
				float(self_state.get("h", 28.0)) * 0.5,
			)
			var threat_center := target + Vector2(
				float(decision.get("target", {}).get("w", 20.0)) * 0.5,
				float(decision.get("target", {}).get("h", 28.0)) * 0.5,
			)
			if player_target:
				for raw_player in observation.get("players", []):
					if raw_player is Dictionary and str((raw_player as Dictionary).get("id", "")) == target_id:
						var player_state := raw_player as Dictionary
						threat_center = target + Vector2(
							float(player_state.get("w", 20.0)) * 0.5,
							float(player_state.get("h", 28.0)) * 0.5,
						)
						break
			physics_first_step_guard = _safe_flee_first_step_filter(self_state, origin, threat_center)
			var allow_emergency_closing_step := target_id.begins_with("creature_") and not player_target
			var flee_waypoint := _safe_flee_waypoint(
				self_state, origin, threat_center, physics_first_step_guard, allow_emergency_closing_step
			)
			if flee_waypoint.is_empty():
				# A falling avatar has no standable origin for the ground-route search.
				# This is a transient physics state, not proof that escape is impossible.
				if _should_settle_airborne(self_state, origin):
					_log_flee_motion(origin, target, {}, "airborne_settling", self_state)
					_set_desired_input(false, false, false)
					_advance_local_physics(self_state, delta, false)
					_world_snapshot["self"] = self_state
					return {"done": false, "reason": "airborne_settling"}
				_log_flee_motion(origin, target, {}, "no_safe_waypoint", self_state)
				_set_desired_input(false, false, false)
				_advance_local_physics(self_state, delta, false)
				_world_snapshot["self"] = self_state
				return {"done": true, "reason": "flee_no_safe_waypoint"}
			flee_selected_support = flee_waypoint.get("support_tile", [])
			if bool(flee_waypoint.get("emergency_closure", false)):
				# Tier 3 is intentionally a single, host-known adjacent step. Validate
				# the same limited closure again while executing it; do not route past
				# the hostile or allow the normal player-flee path to approach one.
				physics_first_step_guard = _safe_flee_emergency_step_filter(self_state, origin, threat_center)
			destination = flee_waypoint.get("position", destination)
		else:
			# With no terrain snapshot there is no landing to verify. Let physics
			# resolve the current pose instead of steering blindly toward an unknown
			# horizontal tile.
			var body_center := origin + Vector2(float(self_state.get("w", 20.0)) * 0.5, 0.0)
			if not _local_touches_harmful_fluid(self_state):
				var away_center := Navigator.step_away_from(body_center, Vector2(flee_target_x, body_center.y), 120.0)
				destination = away_center - Vector2(float(self_state.get("w", 20.0)) * 0.5, 0.0)
	elif action == Contract.ACTION_MOVE_TO:
		# Explicit MOVE_TO targets already carry a validated standing Y: duel
		# opponents who jumped onto a block, plus exploration/biome waypoints that
		# sit on a supported step at another elevation. Flattening them to the
		# bot's current Y turned a supported target into a *different*, unsupported
		# tile and stalled the route planner with route_unreachable instead of
		# climbing the step. Only the non-position-directed actions keep the
		# horizontal flattening below.
		destination = target
		if not _is_pvp_world():
			# The route graph is intentionally broad; validate its first jump with
			# the same simulated landing arc used by the movement executor. Otherwise
			# exploration can repeatedly select graph-reachable edges that are
			# physically rejected as unsafe_jump_route.
			physics_first_step_guard = _safe_jump_first_step_filter(self_state)
	else:
		destination.y = origin.y
	# Once a jump was validated and launched, do not re-run grounded pathfinding
	# from its unsupported airborne pose. That made pursuit classify the middle
	# of every real jump as origin_not_reachable, cancel the held input, and start
	# over on the next policy tick. Finish the already-proven transition toward
	# its planned landing support; no new jump or speculative route is introduced.
	if _jump_active:
		var jump_destination := destination
		var planned_landing: Variant = _active_air_transition.get("to")
		if typeof(planned_landing) == TYPE_VECTOR2I:
			jump_destination = _world_position_for_support_tile(planned_landing)
		var jump_direction := signf(jump_destination.x - origin.x)
		_set_desired_input(jump_direction < 0.0, jump_direction > 0.0, true)
		return _jump_step(self_state, jump_destination, delta)
	# A host correction or an earlier action timeout can leave the real avatar
	# between supports without an active jump. Ground routes have no valid origin
	# there. Resolve gravity before replanning, rather than declaring a verified
	# exploration destination unreachable merely because this frame is airborne.
	# Do not invent horizontal steering over an unverified gap.
	if _should_settle_airborne(self_state, origin):
		if action == Contract.ACTION_FLEE_FROM:
			_log_flee_motion(origin, target, {"position": [destination.x, destination.y]}, "airborne_settling_after_waypoint", self_state)
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": false, "reason": "airborne_settling"}
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
	var emergency_lava_escape := action == Contract.ACTION_FLEE_FROM and _local_touches_harmful_fluid(self_state)
	var route_step := (
		{}
		if _is_pvp_world() or emergency_lava_escape
		else _physics_route_step(origin, destination, target_id, physics_first_step_guard, explicit_target_tile)
	)
	if action == Contract.ACTION_FLEE_FROM:
		_log_flee_motion(origin, target, {"position": [destination.x, destination.y], "support_tile": flee_selected_support, "route_step": route_step}, "route_step", self_state)
	if bool(route_step.get("unreachable", false)) and _host_rejected_transition_blocks_origin(_support_tile_for_position(origin)):
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "edge_guard"}
	if bool(route_step.get("unreachable", false)) and player_target and not _is_pvp_world():
		# The physics graph is intentionally bounded. When the player is farther
		# away than that horizon, keep pursuing through a known, supported tile
		# that makes measurable progress instead of falling back to a speculative
		# straight-line jump toward the player's full-distance position.
		# Follow's preferred-radius point may be suspended in air or fluid even
		# when the player has a reachable supported landing below. Measure waypoint
		# progress against the actual player, not that unsupported comfort point.
		var pursuit_goal := target if player_target else destination
		var pursuit_waypoint := _safe_pursuit_waypoint(origin, pursuit_goal, physics_first_step_guard)
		if pursuit_waypoint.is_empty():
			_set_desired_input(false, false, false)
			_advance_local_physics(self_state, delta, false)
			_world_snapshot["self"] = self_state
			return {"done": true, "reason": "pursuit_no_safe_waypoint"}
		destination = pursuit_waypoint.get("position", destination)
		# Execute the waypoint through the same first-step guard that proved it, so
		# the planned edge and the executed edge cannot disagree mid-route.
		route_step = _physics_route_step(origin, destination, target_id, physics_first_step_guard)
		if bool(route_step.get("unreachable", false)):
			_set_desired_input(false, false, false)
			_advance_local_physics(self_state, delta, false)
			_world_snapshot["self"] = self_state
			return {"done": true, "reason": "pursuit_waypoint_unreachable"}
	# Exploration and emergency-bridge targets must not fall back to direct
	# steering when the physics graph cannot prove a route across the gap.
	# For ordinary movement,
	# keep the collision/edge guards below in charge so a failed route search around
	# a wall still reports blocked_obstacle/edge_guard instead of masking it.
	if bool(route_step.get("unreachable", false)) and not player_target and (target_id.begins_with("explore:") or target_id.begins_with("escape_bridge:")):
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "route_unreachable"}
	var route_kind := str(route_step.get("kind", ""))
	var verified_drop := false
	if route_kind == "drop":
		var drop_from: Vector2i = route_step.get("from_tile", _support_tile_for_position(origin))
		var drop_to: Vector2i = route_step.get("to_tile", _support_tile_for_position(route_step.get("position", destination)))
		verified_drop = _physics_transition_allowed(drop_from, drop_to, "drop")
		if not verified_drop:
			_physics_route.clear()
			_physics_route_replan_msec = Time.get_ticks_msec() + 450
			_set_desired_input(false, false, false)
			_advance_local_physics(self_state, delta, false)
			_world_snapshot["self"] = self_state
			return {"done": true, "reason": "unsafe_drop_route"}
	if not route_step.is_empty():
		destination = route_step.get("position", destination)
	if route_kind == "jump" and not _jump_route_has_safe_landing(self_state, destination):
		# A standable destination alone does not prove that the actual player arc
		# can reach it: a wall/ceiling or an optimistic graph edge can still turn
		# the jump into a fall. Validate the same collision trajectory before any
		# jump input is emitted.
		_physics_route.clear()
		_physics_route_replan_msec = Time.get_ticks_msec() + 450
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "unsafe_jump_route"}
	# Guard the edge before a movement hint can start a jump. A navigator jump is
	# still allowed because its destination was built from a known standable tile;
	# direct movement toward unknown void has no such landing guarantee.
	if (
		(bool(self_state.get("on_ground", false)) or _local_pose_has_support(self_state))
		and _would_step_into_void(origin, destination)
		and route_kind != "jump"
		and not (route_kind == "drop" and verified_drop)
	):
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "edge_guard"}
	var hint := ""
	if _is_pvp_world():
		hint = _pvp_jump_hint(origin, destination)
	else:
		# The route graph already proved a supported walk edge, including through
		# ghostable foliage. A local tree cue must not replace that edge with a
		# vertical climb that never advances toward the waypoint.
		hint = route_kind if route_kind in ["walk", "jump", "climb"] else _movement_hint(origin, destination)
		if route_kind == "drop":
			# A verified drop is entered by walking off its known edge; do not let
			# the local one-block pit heuristic turn the descent into a jump.
			hint = "walk"
	if emergency_lava_escape:
		# Direct contact uses a landing proven dry by local terrain and a simulated
		# jump arc. Reset any stale transition, then hold the jump toward that tile.
		_jump_active = false
		_jump_predicted_landed = false
		_jump_started_msec = -1
		_climb_active = false
		_active_air_transition.clear()
		self_state["tree_ghost"] = false
		self_state["climbing"] = false
		self_state["climb_col"] = -1
		hint = "jump" if emergency_fluid_escape_jump else "walk"
	# A local obstacle hint is only a one-column cue; it must not turn the full
	# player/resource destination into one large speculative jump. Route jumps
	# have already been checked above. Direct hints use the same landing proof,
	# except in duels where the arena edge guard owns traversal, plus the host-
	# rejected-edge cooldown before they can latch an air transition.
	if hint == "jump" and not _jump_active and route_kind not in ["jump", "drop"]:
		var transition_from := _support_tile_for_position(origin)
		var transition_to := _support_tile_for_position(destination)
		if not _physics_transition_allowed(transition_from, transition_to, "jump"):
			_physics_route.clear()
			_physics_route_replan_msec = Time.get_ticks_msec() + 450
			_set_desired_input(false, false, false)
			_advance_local_physics(self_state, delta, false)
			_world_snapshot["self"] = self_state
			return {"done": true, "reason": "unsafe_jump_route"}
		if not _is_pvp_world() and not _jump_route_has_safe_landing(self_state, destination, emergency_fluid_escape_jump):
			# Preserve the normal obstacle detector for nearby walls. The original
			# hint is only one column wide; never turn it into a jump to a distant
			# target, but let horizontal collision handling choose blocked_obstacle.
			var direction := signf(destination.x - origin.x)
			var immediate_obstacle := not _local_collision(
				float(self_state.get("x", origin.x)) + direction * 2.0,
				float(self_state.get("y", origin.y)),
				float(self_state.get("w", 20.0)),
				float(self_state.get("h", 28.0)),
			).is_empty()
			if immediate_obstacle:
				hint = "walk"
			else:
				_physics_route.clear()
				_physics_route_replan_msec = Time.get_ticks_msec() + 450
				_set_desired_input(false, false, false)
				_advance_local_physics(self_state, delta, false)
				_world_snapshot["self"] = self_state
				return {"done": true, "reason": "unsafe_jump_route"}
	if route_kind == "walk" and _climb_active:
		_climb_active = false
		self_state["climbing"] = false
		self_state["climb_col"] = -1
	if _climb_active or hint == "climb":
		if not _climb_active:
			_active_air_transition = {
				"from": _support_tile_for_position(origin),
				"to": _support_tile_for_position(destination),
			}
		_set_desired_input(signf(destination.x - origin.x) < 0.0, signf(destination.x - origin.x) > 0.0, true)
		return _climb_step(self_state, destination, delta)
	if hint == "jump" and not _jump_active:
		_active_air_transition = {
			"from": _support_tile_for_position(origin),
			"to": _support_tile_for_position(destination),
		}
		_jump_active = true
		_jump_predicted_landed = false
		_jump_start_x = float(self_state.get("x", origin.x))
		_jump_started_msec = Time.get_ticks_msec()
	if _jump_active:
		_set_desired_input(signf(destination.x - origin.x) < 0.0, signf(destination.x - origin.x) > 0.0, true)
		return _jump_step(self_state, destination, delta)

	var direction := signf(destination.x - origin.x)
	# Movement snapshots are still needed for older P2P hosts.  Run those
	# snapshots through the same collision/gravity adapter as the dedicated
	# host instead of teleporting x/y and claiming the player is grounded.
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


func _physics_route_step(
	origin: Vector2,
	destination: Vector2,
	target_id: String,
	first_step_allowed: Callable = Callable(),
	explicit_target_tile: Array = [],
) -> Dictionary:
	if _terrain_tiles.is_empty():
		return {}
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	if not first_step_allowed.is_valid():
		first_step_allowed = _safe_jump_first_step_filter(self_state)
	var later_step_allowed := _safe_jump_later_step_filter(self_state)
	var origin_tile := _route_origin_support_tile(
		origin,
		self_state,
	)
	var active_drop_step := _active_verified_drop_step(origin, self_state)
	if not active_drop_step.is_empty():
		return active_drop_step
	# A host-confirmed grounded pose can occasionally map into an invalid support
	# cell after terrain reconciliation (for example, the body is beside a newly
	# replicated obstruction). Let the collision-controlled avatar take exactly
	# one known, same-row walk onto an adjacent standable tile before invoking the
	# route graph. Never use this recovery in air or substitute a jump/drop.
	if not _terrain_standable_tile(origin_tile):
		var origin_recovery := _grounded_origin_walk_step(
			origin,
			self_state,
			destination,
			first_step_allowed,
		)
		if not origin_recovery.is_empty():
			return origin_recovery
		return {"unreachable": true}
	var target_tile := _support_tile_for_position(destination)
	if explicit_target_tile.size() >= 2:
		target_tile = Vector2i(int(explicit_target_tile[0]), int(explicit_target_tile[1]))
	var now := Time.get_ticks_msec()
	var active_drop_in_flight := false
	if _physics_route.size() > 1 and str(_physics_route[1].get("kind", "")) == "drop":
		var active_drop_from: Vector2i = _physics_route[0].get("tile", origin_tile)
		var active_drop_to: Vector2i = _physics_route[1].get("tile", origin_tile)
		active_drop_in_flight = (
			origin_tile != active_drop_from
			and origin_tile != active_drop_to
			and _physics_transition_allowed(active_drop_from, active_drop_to, "drop")
		)
	var needs_replan := not active_drop_in_flight and (
		_physics_route.is_empty()
		or _physics_route_target != target_tile
		or _physics_route_target_id != target_id
		or _physics_route_first_step_guarded != first_step_allowed.is_valid()
		or not _physics_route_later_step_guarded
		or _physics_route_replan_msec < 0
		or now >= _physics_route_replan_msec
	)
	if needs_replan:
		_physics_route = Navigator.physics_route(
			origin_tile,
			target_tile,
			Callable(self, "_terrain_standable_tile"),
			Callable(self, "_terrain_climbable_tile"),
			Navigator.MAX_PHYSICS_ROUTE_NODES,
			Callable(self, "_physics_transition_allowed"),
			first_step_allowed,
			later_step_allowed,
		)
		_physics_route_target = target_tile
		_physics_route_target_id = target_id
		_physics_route_first_step_guarded = first_step_allowed.is_valid()
		_physics_route_later_step_guarded = later_step_allowed.is_valid()
		_physics_route_replan_msec = now + (250 if first_step_allowed.is_valid() else 450)
	if _physics_route.is_empty() and origin_tile != target_tile:
		return {"unreachable": true}
	if _physics_route.size() <= 1:
		return {}
	while _physics_route.size() > 1:
		var next_tile: Vector2i = _physics_route[1].get("tile", origin_tile)
		var next_position := _world_position_for_support_tile(next_tile)
		if origin.distance_to(next_position) > 12.0:
			return {
				"position": next_position,
				"kind": str(_physics_route[1].get("kind", "walk")),
				"from_tile": _physics_route[0].get("tile", origin_tile),
				"to_tile": _physics_route[1].get("tile", origin_tile),
			}
		_physics_route.pop_front()
	return {}


## Continue the current movement input only while the avatar is inside the
## physical corridor of the first edge of a previously verified drop. Falling
## poses do not have a standable route origin, so asking the route graph to
## replan at that point would cancel a safe descent halfway through. This does
## not authorize a new drop or recover an arbitrary airborne pose.
func _active_verified_drop_step(origin: Vector2, self_state: Dictionary) -> Dictionary:
	if (
		bool(self_state.get("on_ground", false))
		or _jump_active
		or _climb_active
		or _physics_route.size() < 2
		or str(_physics_route[1].get("kind", "")) != "drop"
	):
		return {}
	var from_variant: Variant = _physics_route[0].get("tile")
	var to_variant: Variant = _physics_route[1].get("tile")
	if typeof(from_variant) != TYPE_VECTOR2I or typeof(to_variant) != TYPE_VECTOR2I:
		return {}
	var from_tile: Vector2i = from_variant
	var to_tile: Vector2i = to_variant
	if not _physics_transition_allowed(from_tile, to_tile, "drop"):
		return {}
	var from_position := _world_position_for_support_tile(from_tile)
	var to_position := _world_position_for_support_tile(to_tile)
	var min_x := minf(from_position.x, to_position.x) - 4.0
	var max_x := maxf(from_position.x, to_position.x) + 4.0
	if (
		origin.x < min_x
		or origin.x > max_x
		or origin.y < from_position.y - 2.0
		or origin.y > to_position.y + 2.0
	):
		return {}
	return {
		"position": to_position,
		"kind": "drop",
		"from_tile": from_tile,
		"to_tile": to_tile,
		"active_drop_continuation": true,
	}


func _safe_jump_first_step_filter(self_state: Dictionary) -> Callable:
	# Graph reachability does not prove a jump's arc is executable. Reject a
	# first jump whose simulated landing fails so movement can choose a safe
	# walk/drop/climb alternative or report the target unreachable before input.
	return func(_from_tile: Vector2i, to_tile: Vector2i, kind: String) -> bool:
		if kind != "jump":
			return true
		return _jump_route_has_safe_landing(self_state, _world_position_for_support_tile(to_tile))


func _safe_jump_later_step_filter(template_state: Dictionary) -> Callable:
	# Later edges are evaluated from a hypothetical, canonical grounded pose at
	# their source support tile. The first edge continues to use the real host
	# pose through _safe_jump_first_step_filter because its velocity, fluids, and
	# small ground-snap offset can change the actual landing arc.
	return func(from_tile: Vector2i, to_tile: Vector2i, kind: String) -> bool:
		if kind != "jump":
			return true
		var cache_key := "%d|%.1f|%.1f|%d:%d>%d:%d" % [
			_terrain_revision,
			float(template_state.get("w", 20.0)),
			float(template_state.get("h", 28.0)),
			from_tile.x,
			from_tile.y,
			to_tile.x,
			to_tile.y,
		]
		if _jump_landing_cache.has(cache_key):
			return bool(_jump_landing_cache[cache_key])
		var hypothetical_state := template_state.duplicate(true)
		var source_position := _world_position_for_support_tile(from_tile)
		hypothetical_state["x"] = source_position.x
		hypothetical_state["y"] = source_position.y
		hypothetical_state["vx"] = 0.0
		hypothetical_state["vy"] = 0.0
		hypothetical_state["on_ground"] = true
		var safe := _jump_route_has_safe_landing(
			hypothetical_state,
			_world_position_for_support_tile(to_tile),
		)
		if _jump_landing_cache.size() >= 2048:
			_jump_landing_cache.clear()
		_jump_landing_cache[cache_key] = safe
		return safe


func _invalidate_jump_landing_cache() -> void:
	_terrain_revision += 1
	_jump_landing_cache.clear()


func _safe_pursuit_waypoint(origin: Vector2, destination: Vector2, first_step_allowed: Callable = Callable()) -> Dictionary:
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	var origin_tile: Vector2i = _route_origin_support_tile(origin, self_state)
	if not first_step_allowed.is_valid():
		first_step_allowed = _safe_jump_first_step_filter(self_state)
	var later_step_allowed := _safe_jump_later_step_filter(self_state)
	if _terrain_tiles.is_empty():
		_emit_pursuit_route_unavailable(origin_tile, "terrain_empty", first_step_allowed, {})
		return {}
	var reachable_first_steps := Navigator.physics_reachable_first_steps(
		origin_tile,
		Callable(self, "_terrain_standable_tile"),
		Callable(self, "_terrain_climbable_tile"),
		Navigator.MAX_PHYSICS_ROUTE_NODES,
		Callable(self, "_physics_transition_allowed"),
		first_step_allowed,
		later_step_allowed,
	)
	if not reachable_first_steps.has(origin_tile):
		var origin_recovery_steps := _grounded_origin_walk_steps(origin, self_state, first_step_allowed)
		var recovery_waypoint: Dictionary = {}
		var recovery_distance := origin.distance_to(destination)
		for recovery_step in origin_recovery_steps:
			var recovery_position: Vector2 = recovery_step.get("position", Vector2.ZERO)
			var remaining_distance := recovery_position.distance_to(destination)
			if remaining_distance + float(BlockDefs.TILE) * 0.5 >= recovery_distance:
				continue
			recovery_distance = remaining_distance
			recovery_waypoint = {
				"position": recovery_position,
				"support_tile": recovery_step.get("to_tile", origin_tile),
				"remaining_distance": remaining_distance,
			}
		if not recovery_waypoint.is_empty():
			return recovery_waypoint
		_emit_pursuit_route_unavailable(origin_tile, "origin_not_reachable", first_step_allowed, reachable_first_steps)
		return {}
	var origin_distance := origin.distance_to(destination)
	var best_score := origin_distance
	var best_distance := origin_distance
	var best_position := Vector2.ZERO
	var found_waypoint := false
	for raw_tile in reachable_first_steps.keys():
		if typeof(raw_tile) != TYPE_VECTOR2I:
			continue
		var tile: Vector2i = raw_tile
		if tile == origin_tile or not _terrain_standable_tile(tile):
			continue
		var first_edge: Dictionary = reachable_first_steps[raw_tile]
		var position := _world_position_for_support_tile(tile)
		var remaining_distance := position.distance_to(destination)
		# A route can need a short lateral or vertical detour before getting closer
		# to the player (for example, going around a wall). Rank the complete
		# bounded route, not just its endpoint's straight-line distance, and allow
		# the first safe edge to move away only when the reachable approach still
		# repays that travel cost. This avoids both false no-waypoint stops and
		# aimless wandering.
		var route_steps := int(first_edge.get("steps", 0))
		var route_score := remaining_distance + float(route_steps) * float(BlockDefs.TILE) * 0.25
		if route_score + float(BlockDefs.TILE) * 0.25 >= origin_distance:
			continue
		if route_score >= best_score:
			continue
		best_score = route_score
		best_distance = remaining_distance
		best_position = position
		found_waypoint = true
	if not found_waypoint:
		_emit_pursuit_route_unavailable(origin_tile, "no_closer_waypoint", first_step_allowed, reachable_first_steps)
		return {}
	return {
		"position": best_position,
		"support_tile": _support_tile_for_position(best_position),
		"remaining_distance": best_distance,
	}


## Throttled route evidence for pursuit deadlocks. This is a local diagnostic
## journal record: it deliberately contains no target/player/session/world IDs
## or destination coordinates, only bounded terrain around the bot.
func _emit_pursuit_route_unavailable(
	origin_tile: Vector2i,
	failure_kind: String,
	first_step_allowed: Callable,
	reachable_first_steps: Dictionary,
) -> void:
	var now_msec := Time.get_ticks_msec()
	if _last_pursuit_route_diagnostic_msec >= 0 and now_msec - _last_pursuit_route_diagnostic_msec < 30_000:
		return
	_last_pursuit_route_diagnostic_msec = now_msec
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	var self_position := Contract.target_position(self_state)
	var self_width := float(self_state.get("w", 20.0))
	var self_height := float(self_state.get("h", 28.0))
	var feet_y := self_position.y + self_height
	var host_support_row := floori((feet_y + 1.5) / float(BlockDefs.TILE))
	var nearby_solids: Array[Dictionary] = []
	for tile_y in range(origin_tile.y - 3, origin_tile.y + 4):
		for tile_x in range(origin_tile.x - 3, origin_tile.x + 4):
			var block_name := _terrain_name_at(tile_x, tile_y)
			if block_name.is_empty():
				continue
			nearby_solids.append({
				"offset": [tile_x - origin_tile.x, tile_y - origin_tile.y],
				"block": block_name,
			})
	var direct_candidates: Array[Dictionary] = []
	for direction in [Vector2i.LEFT, Vector2i.RIGHT]:
		var candidates: Array[Dictionary] = [
			{"tile": origin_tile + direction, "kind": "walk"},
			{"tile": origin_tile + direction + Vector2i.UP, "kind": "jump"},
			{"tile": origin_tile + direction * 2, "kind": "jump"},
			{"tile": origin_tile + direction * 2 + Vector2i.UP, "kind": "jump"},
		]
		for candidate in candidates:
			var tile: Vector2i = candidate.get("tile", origin_tile)
			var kind := str(candidate.get("kind", "walk"))
			var standable := _terrain_standable_tile(tile)
			var transition_allowed := standable and _physics_transition_allowed(origin_tile, tile, kind)
			var jump_safe := kind != "jump" or (
				standable
				and _jump_route_has_safe_landing(
					_world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {},
					_world_position_for_support_tile(tile),
				)
			)
			direct_candidates.append({
				"offset": [tile.x - origin_tile.x, tile.y - origin_tile.y],
				"kind": kind,
				"standable": standable,
				"transition_allowed": transition_allowed,
				"jump_safe": jump_safe,
				"first_edge_allowed": not first_step_allowed.is_valid() or bool(first_step_allowed.call(origin_tile, tile, kind)),
			})
	structured_log.emit({
		"event": "pursuit_route_unavailable",
		"at_msec": now_msec,
		"failure_kind": failure_kind,
		"origin_tile": [origin_tile.x, origin_tile.y],
		"origin_standable": _terrain_standable_tile(origin_tile),
		"self_position": [self_position.x, self_position.y],
		"self_on_ground": bool(self_state.get("on_ground", false)),
		"self_velocity": [float(self_state.get("vx", 0.0)), float(self_state.get("vy", 0.0))],
		"self_size": [self_width, self_height],
		"host_support_row": host_support_row,
		"feet_from_host_support_top": snappedf(feet_y - float(host_support_row * BlockDefs.TILE), 0.01),
		"terrain_tile_count": _terrain_tiles.size(),
		"observed_cell_count": _terrain_observed_cells.size(),
		"known_chunk_count": _terrain_known_chunks.size(),
		"reachable_support_count": reachable_first_steps.size(),
		"nearby_solids": nearby_solids,
		"direct_candidates": direct_candidates,
	})


func _safe_flee_first_step_filter(self_state: Dictionary, origin: Vector2, threat: Vector2) -> Callable:
	var origin_distance := origin.distance_to(threat)
	# The escape destination itself must move measurably away from the threat
	# (enforced by _safe_flee_waypoint). The first step only has to avoid closing
	# that gap, so a lateral or step-up move that later leads somewhere farther
	# is allowed; requiring the first hop to already gain distance pruned whole
	# escape branches and left the bot with no waypoint.
	var max_closure := float(BlockDefs.TILE) * 0.5
	return func(_from_tile: Vector2i, to_tile: Vector2i, kind: String) -> bool:
		var first_position := _world_position_for_support_tile(to_tile)
		if first_position.distance_to(threat) < origin_distance - max_closure:
			return false
		if kind == "jump" and not _flee_jump_landing_has_hazard_margin(to_tile):
			return false
		return kind != "jump" or _jump_route_has_safe_landing(self_state, first_position)


func _safe_flee_emergency_step_filter(self_state: Dictionary, origin: Vector2, threat: Vector2) -> Callable:
	var origin_distance := origin.distance_to(threat)
	return func(_from_tile: Vector2i, to_tile: Vector2i, kind: String) -> bool:
		var first_position := _world_position_for_support_tile(to_tile)
		var first_distance := first_position.distance_to(threat)
		if first_distance < FLEE_EMERGENCY_MIN_STANDOFF:
			return false
		if first_distance < origin_distance - FLEE_EMERGENCY_MAX_CLOSURE:
			return false
		if kind == "jump" and not _flee_jump_landing_has_hazard_margin(to_tile):
			return false
		return kind != "jump" or _jump_route_has_safe_landing(self_state, first_position)


func _flee_jump_landing_has_hazard_margin(tile: Vector2i) -> bool:
	# A jump that lands on the lip directly above/beside lava may pass the local
	# collision arc but still overshoot when the authoritative host catches up.
	# Keep a full neighboring column clear for emergency evasive jumps.
	for x in range(tile.x - 1, tile.x + 2):
		for y in range(tile.y - 1, tile.y + 2):
			if _terrain_is_lava_at(x, y):
				return false
	return true


func _log_flee_motion(origin: Vector2, threat: Vector2, waypoint: Dictionary, phase: String, self_state: Dictionary) -> void:
	var now_msec := Time.get_ticks_msec()
	if _last_flee_motion_diagnostic_msec >= 0 and now_msec - _last_flee_motion_diagnostic_msec < 500:
		return
	_last_flee_motion_diagnostic_msec = now_msec
	var support: Variant = waypoint.get("support_tile", [])
	var support_coords: Array = []
	if typeof(support) == TYPE_VECTOR2I:
		support_coords = [support.x, support.y]
	elif support is Array:
		support_coords = (support as Array).duplicate()
	var planned: Variant = waypoint.get("position", [])
	var planned_coords: Array = []
	if typeof(planned) == TYPE_VECTOR2:
		planned_coords = [planned.x, planned.y]
	elif planned is Array:
		planned_coords = (planned as Array).duplicate()
	var route_step: Dictionary = waypoint.get("route_step", {}) if waypoint.get("route_step", {}) is Dictionary else {}
	structured_log.emit({
		"event": "flee_motion_probe",
		"at_msec": now_msec,
		"phase": phase,
		"origin": [origin.x, origin.y],
		"threat": [threat.x, threat.y],
		"planned": planned_coords,
		"support_tile": support_coords,
		"route_kind": str(route_step.get("kind", "")),
		"route_unreachable": bool(route_step.get("unreachable", false)),
		"on_ground": bool(self_state.get("on_ground", false)),
		"vx": float(self_state.get("vx", 0.0)),
		"vy": float(self_state.get("vy", 0.0)),
		"jump_active": _jump_active,
		"desired_input": _desired_input.duplicate(),
	})


func _safe_flee_waypoint(
	self_state: Dictionary,
	origin: Vector2,
	threat: Vector2,
	first_step_allowed: Callable = Callable(),
	allow_emergency_closing_step: bool = false,
) -> Dictionary:
	if _terrain_tiles.is_empty():
		return {}
	var origin_tile := _route_origin_support_tile(origin, self_state)
	var origin_distance := origin.distance_to(threat)
	if not first_step_allowed.is_valid():
		first_step_allowed = _safe_flee_first_step_filter(self_state, origin, threat)
	var later_step_allowed := _safe_jump_later_step_filter(self_state)
	var reachable_first_steps := Navigator.physics_reachable_first_steps(
		origin_tile,
		Callable(self, "_terrain_standable_tile"),
		Callable(self, "_terrain_climbable_tile"),
		Navigator.MAX_PHYSICS_ROUTE_NODES,
		Callable(self, "_physics_transition_allowed"),
		first_step_allowed,
		later_step_allowed,
	)
	if not reachable_first_steps.has(origin_tile):
		# The reachability search refuses to start when the tile under the bot is
		# not itself "standable" (shallow water, foliage, missing replication).
		# Fall back to a bounded one-step scan so a known reachable ledge beside
		# the bot still counts as an escape.
		var step_escape := _safe_flee_step_escape(self_state, origin_tile, threat, origin_distance, first_step_allowed)
		if not step_escape.is_empty():
			return step_escape
		# Tier 2: no strictly farther escape exists, so allow a same-distance
		# reposition instead of standing still and re-entering WAIT.
		var reposition := _safe_flee_reposition_waypoint(self_state, origin_tile, threat, origin_distance, first_step_allowed)
		if reposition.is_empty() and allow_emergency_closing_step:
			reposition = _safe_flee_emergency_closing_step(self_state, origin_tile, threat, origin_distance)
		if reposition.is_empty():
			_emit_flee_route_unavailable(
				self_state, origin, threat, origin_tile, origin_distance, first_step_allowed, reachable_first_steps
			)
		return reposition
	var best_distance := origin_distance + float(BlockDefs.TILE) * 0.25
	var best_position := Vector2.ZERO
	var best_tile := origin_tile
	var found_waypoint := false
	for raw_tile in reachable_first_steps.keys():
		if typeof(raw_tile) != TYPE_VECTOR2I:
			continue
		var tile: Vector2i = raw_tile
		if tile == origin_tile or not _terrain_standable_tile(tile):
			continue
		var position := _world_position_for_support_tile(tile)
		# A far tile beyond the hostile can have a larger final separation while
		# the route to it runs straight through the animal. Keep the retreat on
		# the bot's side unless they are already within one tile of each other.
		if _flee_destination_crosses_hostile(origin, threat, position):
			continue
		var distance_from_threat := position.distance_to(threat)
		if distance_from_threat <= best_distance:
			continue
		var first_edge: Dictionary = reachable_first_steps[raw_tile]
		# Distance closure is already enforced by first_step_allowed; only the
		# simulated jump arc still needs an explicit check here.
		if (
			str(first_edge.get("kind", "walk")) == "jump"
			and not _jump_route_has_safe_landing(self_state, _world_position_for_support_tile(first_edge.get("tile", origin_tile)))
		):
			continue
		best_distance = distance_from_threat
		best_position = position
		best_tile = tile
		found_waypoint = true
	if not found_waypoint:
		var step_escape := _safe_flee_step_escape(self_state, origin_tile, threat, origin_distance, first_step_allowed)
		if not step_escape.is_empty():
			return step_escape
		# Tier 2: a strictly farther tile may be unreachable while a legitimate
		# lateral/step-up reposition that keeps threat distance is. Return that so
		# FLEE_FROM does not collapse into flee_no_safe_waypoint -> WAIT.
		var reposition := _safe_flee_reposition_waypoint(
			self_state, origin_tile, threat, origin_distance, first_step_allowed, reachable_first_steps
		)
		if reposition.is_empty() and allow_emergency_closing_step:
			reposition = _safe_flee_emergency_closing_step(self_state, origin_tile, threat, origin_distance)
		if reposition.is_empty():
			_emit_flee_route_unavailable(
				self_state, origin, threat, origin_tile, origin_distance, first_step_allowed, reachable_first_steps
			)
		return reposition
	return {
		"position": best_position,
		"support_tile": best_tile,
		"distance_from_threat": best_distance,
	}


func _flee_destination_crosses_hostile(origin: Vector2, threat: Vector2, destination: Vector2) -> bool:
	var threat_dx := threat.x - origin.x
	return absf(threat_dx) > float(BlockDefs.TILE) and threat_dx * (threat.x - destination.x) <= 0.0


## Emergency escape from a fluid the avatar is already touching. The old direct
## horizontal command could steer deeper into a pool or off the island. Require
## a locally observed dry support and a simulated jump arc that clears the
## starting hazard before considering the route executable.
func _safe_harmful_fluid_escape_waypoint(self_state: Dictionary, origin: Vector2, threat: Vector2) -> Dictionary:
	if _terrain_tiles.is_empty():
		return {}
	var origin_tile := _route_origin_support_tile(origin, self_state)
	var best: Dictionary = {}
	var best_score := -INF
	var candidates: Array[Vector2i] = []
	for direction in [-1, 1]:
		candidates.append(origin_tile + Vector2i(direction, 0))
		candidates.append(origin_tile + Vector2i(direction * 2, 0))
		candidates.append(origin_tile + Vector2i(direction, -1))
		candidates.append(origin_tile + Vector2i(direction * 2, -1))
	for landing_tile in candidates:
		if not _terrain_standable_tile(landing_tile):
			continue
		if not _physics_transition_allowed(origin_tile, landing_tile, "jump"):
			continue
		var landing := _world_position_for_support_tile(landing_tile)
		if not _jump_route_has_safe_landing(self_state, landing, true):
			continue
		var hazard_clearance := _nearest_harmful_fluid_clearance(landing, self_state)
		var threat_clearance := landing.distance_to(threat)
		var score := hazard_clearance * 2.0 + threat_clearance * 0.1
		if score <= best_score:
			continue
		best_score = score
		best = {
			"position": landing,
			"support_tile": landing_tile,
			"distance_from_threat": threat_clearance,
			"emergency_fluid_escape": true,
		}
	return best


func _nearest_harmful_fluid_clearance(position: Vector2, self_state: Dictionary) -> float:
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var height := maxf(1.0, float(self_state.get("h", 28.0)))
	var nearest := INF
	for key in _terrain_tiles:
		var parts := str(key).split(":")
		if parts.size() != 2:
			continue
		var tile_x := int(parts[0])
		var tile_y := int(parts[1])
		if not _terrain_is_lava_at(tile_x, tile_y):
			continue
		var tile_left := float(tile_x * BlockDefs.TILE)
		var tile_top := float(tile_y * BlockDefs.TILE)
		var dx := maxf(maxf(tile_left - (position.x + width), position.x - (tile_left + float(BlockDefs.TILE))), 0.0)
		var dy := maxf(maxf(tile_top - (position.y + height), position.y - (tile_top + float(BlockDefs.TILE))), 0.0)
		nearest = minf(nearest, Vector2(dx, dy).length())
	return nearest


## Tier 3 for a hostile creature only: if every safe escape and non-closing
## reposition is blocked, take exactly one validated adjacent step toward it,
## but stay outside melee range plus a small buffer. The next policy tick must
## re-evaluate the live threat and terrain; this is not a route through the
## creature and must never be used to flee from a player.
func _safe_flee_emergency_closing_step(
	self_state: Dictionary,
	origin_tile: Vector2i,
	threat: Vector2,
	origin_distance: float,
) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := -INF
	var best_tile := origin_tile
	var minimum_closure := float(BlockDefs.TILE) * 0.5
	var candidates: Array[Dictionary] = []
	for direction in [Vector2i.LEFT, Vector2i.RIGHT]:
		candidates.append({"tile": origin_tile + direction, "kind": "walk"})
		candidates.append({"tile": origin_tile + direction + Vector2i.UP, "kind": "jump"})
		candidates.append({"tile": origin_tile + direction * 2, "kind": "jump"})
		candidates.append({"tile": origin_tile + direction * 2 + Vector2i.UP, "kind": "jump"})
	for candidate in candidates:
		var tile: Vector2i = candidate.get("tile", origin_tile)
		var kind := str(candidate.get("kind", "walk"))
		if tile == origin_tile or not _terrain_standable_tile(tile):
			continue
		if not _physics_transition_allowed(origin_tile, tile, kind):
			continue
		var position := _world_position_for_support_tile(tile)
		var distance_from_threat := position.distance_to(threat)
		var closure := origin_distance - distance_from_threat
		if closure <= minimum_closure or closure > FLEE_EMERGENCY_MAX_CLOSURE:
			continue
		if distance_from_threat < FLEE_EMERGENCY_MIN_STANDOFF:
			continue
		if kind == "jump" and not _jump_route_has_safe_landing(self_state, position):
			continue
		if distance_from_threat <= best_distance:
			continue
		best_distance = distance_from_threat
		best_tile = tile
		best = {
			"position": position,
			"support_tile": tile,
			"distance_from_threat": distance_from_threat,
			"reposition_only": true,
			"emergency_closure": true,
		}
	if not best.is_empty():
		structured_log.emit({
			"event": "flee_emergency_step",
			"at_msec": Time.get_ticks_msec(),
			"origin_tile": [origin_tile.x, origin_tile.y],
			"support_tile": [best_tile.x, best_tile.y],
			"origin_distance": origin_distance,
			"distance_from_threat": best_distance,
		})
	return best


## Bounded one-step escape scan used when the reachability search cannot start or
## found no branch. Each candidate support tile is the direct physics neighbour
## of the origin (walk, one-block/gap jump, or verified drop), validated with the
## exact transition rules the movement executor uses. This is what lets a bot in
## shallow water beside a sand ledge step onto the ledge instead of standing
## still, while every jump still passes the simulated landing filter.
func _safe_flee_step_escape(
	self_state: Dictionary,
	origin_tile: Vector2i,
	threat: Vector2,
	origin_distance: float,
	first_step_allowed: Callable,
) -> Dictionary:
	var best_distance := origin_distance + float(BlockDefs.TILE) * 0.25
	var best: Dictionary = {}
	for direction in [Vector2i.LEFT, Vector2i.RIGHT]:
		var candidates: Array[Dictionary] = [{"tile": origin_tile + direction, "kind": "walk"}]
		candidates.append({"tile": origin_tile + direction + Vector2i.UP, "kind": "jump"})
		candidates.append({"tile": origin_tile + direction * 2, "kind": "jump"})
		candidates.append({"tile": origin_tile + direction * 2 + Vector2i.UP, "kind": "jump"})
		for drop_tiles in range(1, Navigator.MAX_VERIFIED_DROP_TILES + 1):
			candidates.append({"tile": origin_tile + direction + Vector2i.DOWN * drop_tiles, "kind": "drop"})
		for candidate in candidates:
			var tile: Vector2i = candidate.get("tile", origin_tile)
			var kind := str(candidate.get("kind", "walk"))
			if tile == origin_tile or not _terrain_standable_tile(tile):
				continue
			if not _physics_transition_allowed(origin_tile, tile, kind):
				continue
			if first_step_allowed.is_valid() and not bool(first_step_allowed.call(origin_tile, tile, kind)):
				continue
			var position := _world_position_for_support_tile(tile)
			if _flee_destination_crosses_hostile(_world_position_for_support_tile(origin_tile), threat, position):
				continue
			var distance_from_threat := position.distance_to(threat)
			if distance_from_threat <= best_distance:
				continue
			best_distance = distance_from_threat
			best = {
				"position": position,
				"support_tile": tile,
				"distance_from_threat": best_distance,
			}
	return best


## Tier-2 escape fallback. The strict escape (and its one-step scan) only accepts
## destinations measurably farther from the threat, so a cornered bot that has no
## strictly farther reachable tile used to return nothing and collapse into
## flee_no_safe_waypoint -> WAIT. When that happens, permit a host-known,
## standable, physics-reachable destination whose distance to the hostile does
## not decrease (<=1px closure). The destination still has to pass the exact same
## first-edge guard, jump-landing simulation, hazard and rejected-transition
## checks as the strict route, so this never turns into a closer, unknown-terrain
## or unsafe-fall move. Results carry `reposition_only=true` for diagnostics.
func _safe_flee_reposition_waypoint(
	self_state: Dictionary,
	origin_tile: Vector2i,
	threat: Vector2,
	origin_distance: float,
	first_step_allowed: Callable,
	reachable_first_steps: Dictionary = {},
) -> Dictionary:
	var min_distance := origin_distance - 1.0
	var best_distance := -INF
	var best: Dictionary = {}
	if not reachable_first_steps.is_empty():
		for raw_tile in reachable_first_steps.keys():
			if typeof(raw_tile) != TYPE_VECTOR2I:
				continue
			var tile: Vector2i = raw_tile
			if tile == origin_tile or not _terrain_standable_tile(tile):
				continue
			var position := _world_position_for_support_tile(tile)
			if _flee_destination_crosses_hostile(_world_position_for_support_tile(origin_tile), threat, position):
				continue
			var distance_from_threat := position.distance_to(threat)
			if distance_from_threat < min_distance or distance_from_threat <= best_distance:
				continue
			var first_edge: Dictionary = reachable_first_steps[raw_tile]
			if (
				str(first_edge.get("kind", "walk")) == "jump"
				and not _jump_route_has_safe_landing(self_state, _world_position_for_support_tile(first_edge.get("tile", origin_tile)))
			):
				continue
			best_distance = distance_from_threat
			best = {
				"position": position,
				"support_tile": tile,
				"distance_from_threat": distance_from_threat,
				"reposition_only": true,
			}
		if not best.is_empty():
			return best
	return _safe_flee_reposition_step(self_state, origin_tile, threat, origin_distance, first_step_allowed)


## Direct-neighbour variant of the tier-2 fallback, used when the reachability
## search cannot start from the bot's tile (shallow water, foliage, missing
## replication). Mirrors _safe_flee_step_escape but accepts a non-decreasing
## threat distance within 1px instead of requiring a measurable gain.
func _safe_flee_reposition_step(
	self_state: Dictionary,
	origin_tile: Vector2i,
	threat: Vector2,
	origin_distance: float,
	first_step_allowed: Callable,
) -> Dictionary:
	var min_distance := origin_distance - 1.0
	var best_distance := -INF
	var best: Dictionary = {}
	for direction in [Vector2i.LEFT, Vector2i.RIGHT]:
		var candidates: Array[Dictionary] = [{"tile": origin_tile + direction, "kind": "walk"}]
		candidates.append({"tile": origin_tile + direction + Vector2i.UP, "kind": "jump"})
		candidates.append({"tile": origin_tile + direction * 2, "kind": "jump"})
		candidates.append({"tile": origin_tile + direction * 2 + Vector2i.UP, "kind": "jump"})
		for drop_tiles in range(1, Navigator.MAX_VERIFIED_DROP_TILES + 1):
			candidates.append({"tile": origin_tile + direction + Vector2i.DOWN * drop_tiles, "kind": "drop"})
		for candidate in candidates:
			var tile: Vector2i = candidate.get("tile", origin_tile)
			var kind := str(candidate.get("kind", "walk"))
			if tile == origin_tile or not _terrain_standable_tile(tile):
				continue
			if not _physics_transition_allowed(origin_tile, tile, kind):
				continue
			if first_step_allowed.is_valid() and not bool(first_step_allowed.call(origin_tile, tile, kind)):
				continue
			var position := _world_position_for_support_tile(tile)
			if _flee_destination_crosses_hostile(_world_position_for_support_tile(origin_tile), threat, position):
				continue
			if kind == "jump" and not _jump_route_has_safe_landing(self_state, position):
				continue
			var distance_from_threat := position.distance_to(threat)
			if distance_from_threat < min_distance or distance_from_threat <= best_distance:
				continue
			best_distance = distance_from_threat
			best = {
				"position": position,
				"support_tile": tile,
				"distance_from_threat": distance_from_threat,
				"reposition_only": true,
			}
	return best


## Emit a throttled, local-only journal breadcrumb when every safe flee route is
## rejected. This captures enough known support/transition geometry to diagnose
## live deadlocks without shipping analytics or dumping the full world snapshot.
func _emit_flee_route_unavailable(
	self_state: Dictionary,
	origin: Vector2,
	threat: Vector2,
	origin_tile: Vector2i,
	origin_distance: float,
	first_step_allowed: Callable,
	reachable_first_steps: Dictionary,
) -> void:
	var now_msec := Time.get_ticks_msec()
	if _last_flee_route_diagnostic_msec >= 0 and now_msec - _last_flee_route_diagnostic_msec < 30_000:
		return
	_last_flee_route_diagnostic_msec = now_msec
	var nearby_standable: Array[Dictionary] = []
	var nearby_solids: Array[Dictionary] = []
	for tile_y in range(origin_tile.y - 4, origin_tile.y + 5):
		for tile_x in range(origin_tile.x - 4, origin_tile.x + 5):
			var tile := Vector2i(tile_x, tile_y)
			var block_name := _terrain_name_at(tile_x, tile_y)
			if not block_name.is_empty():
				nearby_solids.append({"tile": [tile_x, tile_y], "block": block_name})
			if not _terrain_standable_tile(tile):
				continue
			var position := _world_position_for_support_tile(tile)
			nearby_standable.append({
				"tile": [tile.x, tile.y],
				"distance": snappedf(position.distance_to(threat), 0.1),
				"reachable": reachable_first_steps.has(tile),
			})
	var direct_candidates: Array[Dictionary] = []
	for direction in [Vector2i.LEFT, Vector2i.RIGHT]:
		var candidates: Array[Dictionary] = [
			{"tile": origin_tile + direction, "kind": "walk"},
			{"tile": origin_tile + direction + Vector2i.UP, "kind": "jump"},
			{"tile": origin_tile + direction * 2, "kind": "jump"},
			{"tile": origin_tile + direction * 2 + Vector2i.UP, "kind": "jump"},
		]
		for candidate in candidates:
			var tile: Vector2i = candidate.get("tile", origin_tile)
			var kind := str(candidate.get("kind", "walk"))
			var standable := _terrain_standable_tile(tile)
			var transition_allowed := standable and _physics_transition_allowed(origin_tile, tile, kind)
			var jump_safe := kind != "jump" or (standable and _jump_route_has_safe_landing(self_state, _world_position_for_support_tile(tile)))
			var first_edge_allowed := (
				not first_step_allowed.is_valid()
				or bool(first_step_allowed.call(origin_tile, tile, kind))
			)
			direct_candidates.append({
				"tile": [tile.x, tile.y],
				"kind": kind,
				"standable": standable,
				"transition_allowed": transition_allowed,
				"jump_safe": jump_safe,
				"first_edge_allowed": first_edge_allowed,
				"distance": snappedf(_world_position_for_support_tile(tile).distance_to(threat), 0.1) if standable else -1.0,
			})
	structured_log.emit({
		"event": "flee_route_unavailable",
		"at_msec": now_msec,
		"origin": [origin.x, origin.y],
		"origin_tile": [origin_tile.x, origin_tile.y],
		"origin_standable": _terrain_standable_tile(origin_tile),
		"threat_position": [threat.x, threat.y],
		"origin_distance": snappedf(origin_distance, 0.1),
		"reachable_first_step_count": reachable_first_steps.size(),
		"nearby_solids": nearby_solids,
		"nearby_standable": nearby_standable,
		"direct_candidates": direct_candidates,
	})


func _host_rejected_transition_blocks_origin(origin_tile: Vector2i) -> bool:
	if origin_tile != _host_rejected_transition_from:
		return false
	if Time.get_ticks_msec() >= _host_rejected_transition_until_msec:
		_host_rejected_transition_from = Vector2i(2147483647, 2147483647)
		_host_rejected_transition_until_msec = -1
		return false
	return true


func _physics_transition_key(from_tile: Vector2i, to_tile: Vector2i) -> String:
	return "%d:%d>%d:%d" % [from_tile.x, from_tile.y, to_tile.x, to_tile.y]


func _physics_transition_allowed(from_tile: Vector2i, to_tile: Vector2i, kind: String = "") -> bool:
	if kind == "drop" and not _verified_drop_transition(from_tile, to_tile):
		return false
	var key := _physics_transition_key(from_tile, to_tile)
	if not _host_rejected_transitions.has(key):
		return true
	if Time.get_ticks_msec() >= int(_host_rejected_transitions.get(key, 0)):
		_host_rejected_transitions.erase(key)
		return true
	return false


func _verified_drop_transition(from_tile: Vector2i, to_tile: Vector2i) -> bool:
	var drop_tiles := to_tile.y - from_tile.y
	if (
		drop_tiles <= 0
		or drop_tiles > Navigator.MAX_VERIFIED_DROP_TILES
		or absi(to_tile.x - from_tile.x) != 1
		or not _terrain_standable_tile(from_tile)
		or not _terrain_standable_tile(to_tile)
		or _terrain_is_lava_at(to_tile.x, to_tile.y)
	):
		return false
	# The player body crosses the neighboring column from the source headroom
	# through the landing headroom. Empty cells count as safe only if the host has
	# actually replicated them; water is traversable, but lava and solid blocks
	# are not.
	for corridor_y in range(from_tile.y - 1, to_tile.y):
		if not _terrain_cell_is_known(to_tile.x, corridor_y):
			return false
		if _terrain_solid_at(to_tile.x, corridor_y) or _terrain_is_lava_at(to_tile.x, corridor_y):
			return false
	if not _terrain_cell_is_known(to_tile.x, to_tile.y - 2):
		return false
	if _terrain_is_lava_at(to_tile.x, to_tile.y - 2):
		return false
	return true


func _terrain_cell_is_known(tx: int, ty: int) -> bool:
	var key := "%d:%d" % [tx, ty]
	if _terrain_observed_cells.has(key) or _terrain_tiles.has(key):
		return true
	var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	var mode := str(generation.get("mode", _session_world_mode)).to_lower()
	if mode in ["procedural", "challenge_run"]:
		var chunk_x := floori(float(tx) / float(WorldSim.CHUNK_WIDTH))
		return _terrain_known_chunks.has(chunk_x)
	if _descent_snapshot_complete and mode in ["one_block", "skyblock", "floating_islands"]:
		var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
		if self_state.is_empty():
			return false
		var reference := _support_tile_for_position(Contract.target_position(self_state))
		return (
			absi(tx - reference.x) <= DescentPlannerClass.STATIC_KNOWN_RADIUS_X
			and absi(ty - reference.y) <= DescentPlannerClass.STATIC_KNOWN_RADIUS_Y
		)
	return false


func _rebuild_known_chunk_index(raw_chunks: Variant) -> void:
	_terrain_known_chunks.clear()
	if raw_chunks is Array:
		for raw_chunk in raw_chunks:
			if not raw_chunk is Dictionary or not (raw_chunk as Dictionary).has("x"):
				continue
			var chunk_x := int((raw_chunk as Dictionary).get("x", WorldSim.COORD_LIMIT))
			if absi(chunk_x) <= WorldSim.COORD_LIMIT / WorldSim.CHUNK_WIDTH:
				_terrain_known_chunks[chunk_x] = true
	elif raw_chunks is Dictionary:
		for raw_chunk_x in raw_chunks:
			var chunk_x := int(raw_chunk_x)
			if absi(chunk_x) <= WorldSim.COORD_LIMIT / WorldSim.CHUNK_WIDTH:
				_terrain_known_chunks[chunk_x] = true


func _reachable_stand_position_for_block(origin: Vector2, target: Dictionary) -> Dictionary:
	if not target.has("x") or not target.has("y") or _terrain_tiles.is_empty():
		return {}
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	var candidates := _resource_stand_candidates(target)
	var origin_support := _route_origin_support_tile(origin, self_state)
	var best_position := {}
	var best_cost := INF
	for candidate in candidates:
		if not _terrain_standable_tile(candidate):
			continue
		var route := _physics_route_to_support_tile(origin_support, candidate, self_state)
		if route.is_empty() or Vector2i((route.back() as Dictionary).get("tile", origin_support)) != candidate:
			continue
		var position := _world_position_for_support_tile(candidate)
		var cost := float(route.size()) * float(BlockDefs.TILE) + origin.distance_to(position)
		if cost >= best_cost:
			continue
		best_cost = cost
		best_position = {
			"position": [position.x, position.y],
			"support_tile": [candidate.x, candidate.y],
		}
	return best_position


func _resource_stand_candidates(target: Dictionary) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	if not target.has("x") or not target.has("y"):
		return candidates
	var tile := Vector2i(int(target.get("x", 0)), int(target.get("y", 0)))
	candidates = [
		tile + Vector2i.LEFT,
		tile + Vector2i.RIGHT,
		tile + Vector2i.LEFT * 2,
		tile + Vector2i.RIGHT * 2,
		tile + Vector2i.LEFT + Vector2i.DOWN,
		tile + Vector2i.RIGHT + Vector2i.DOWN,
		tile + Vector2i.LEFT * 2 + Vector2i.DOWN,
		tile + Vector2i.RIGHT * 2 + Vector2i.DOWN,
		# Logs can hang two or three tiles above a floor; the avatar can mine
		# them from a supported tile under the block.
		tile + Vector2i.DOWN * 2,
		tile + Vector2i.LEFT + Vector2i.DOWN * 2,
		tile + Vector2i.RIGHT + Vector2i.DOWN * 2,
		tile + Vector2i.LEFT * 2 + Vector2i.DOWN * 2,
		tile + Vector2i.RIGHT * 2 + Vector2i.DOWN * 2,
		tile + Vector2i.DOWN * 3,
		tile + Vector2i.LEFT + Vector2i.DOWN * 3,
		tile + Vector2i.RIGHT + Vector2i.DOWN * 3,
	]
	# A host-confirmed regenerating tile may remain safe support while mined.
	if bool(target.get("preserves_support_on_mine", false)):
		candidates.push_front(tile)
	return candidates


func _physics_route_to_support_tile(origin_support: Vector2i, target_support: Vector2i, self_state: Dictionary) -> Array[Dictionary]:
	return Navigator.physics_route(
		origin_support,
		target_support,
		Callable(self, "_terrain_standable_tile"),
		Callable(self, "_terrain_climbable_tile"),
		Navigator.MAX_PHYSICS_ROUTE_NODES,
		Callable(self, "_physics_transition_allowed"),
		_safe_jump_first_step_filter(self_state),
		_safe_jump_later_step_filter(self_state),
	)


func _reachable_explicit_stand_position(origin: Vector2, self_state: Dictionary, raw_position: Array) -> Dictionary:
	if raw_position.size() < 2:
		return {}
	var position := Vector2(float(raw_position[0]), float(raw_position[1]))
	var support_tile := _support_tile_for_position(position)
	if not _terrain_standable_tile(support_tile):
		return {}
	var origin_support := _route_origin_support_tile(origin, self_state)
	var route := _physics_route_to_support_tile(origin_support, support_tile, self_state)
	if route.is_empty() or Vector2i((route.back() as Dictionary).get("tile", origin_support)) != support_tile:
		return {}
	return {
		"position": [position.x, position.y],
		"support_tile": [support_tile.x, support_tile.y],
	}


func _support_tile_for_position(position: Vector2) -> Vector2i:
	return Vector2i(
		floori((position.x + 10.0) / float(BlockDefs.TILE)),
		floori((position.y + 28.0) / float(BlockDefs.TILE)),
	)


## Route origin support tile for a bot pose.
##
## The host grounds a player when any solid tile sits under the foot span
## (WorldSim.find_ground_support scans px+3 .. px+w-3), while
## `_support_tile_for_position` maps the pose to the single centre column. A bot
## standing on a platform lip therefore has a real support tile beside its
## centre even though the centre cell is empty. Route planners must start from
## that real tile or bounded reachability refuses the origin and movement stalls
## with `origin_not_reachable`. Grounded and near-stationary poses inside the
## host's ground-snap envelope are re-anchored; freely falling poses keep the
## plain centre mapping. Nothing here moves the bot.
func _route_origin_support_tile(position: Vector2, self_state: Dictionary) -> Vector2i:
	var tile := _support_tile_for_position(position)
	if _terrain_standable_tile(tile):
		return tile
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var height := maxf(1.0, float(self_state.get("h", 28.0)))
	var feet_y := position.y + height
	var row := floori((feet_y + 1.5) / float(BlockDefs.TILE))
	var feet_from_support_top := feet_y - float(row * BlockDefs.TILE)
	var within_ground_snap := feet_from_support_top >= -0.05 and feet_from_support_top <= 1.5
	var nearly_stationary_vertically := absf(float(self_state.get("vy", 0.0))) <= 0.05
	if not bool(self_state.get("on_ground", false)) and not (within_ground_snap and nearly_stationary_vertically):
		return tile
	var foot_left := position.x + 3.0
	var foot_right := position.x + width - 3.0
	# Match WorldSim.find_ground_support's 1.5px snap tolerance. A grounded
	# avatar may sit just above the tile boundary, so plain floor(feet / TILE)
	# can select the empty row immediately above the host's actual support row.
	var left := floori(foot_left / float(BlockDefs.TILE))
	var right := floori((foot_right - 0.001) / float(BlockDefs.TILE))
	var best_tile := tile
	var best_distance := 2147483647
	for candidate_x in range(left, right + 1):
		var candidate := Vector2i(candidate_x, row)
		if candidate == tile or not _terrain_standable_tile(candidate):
			continue
		var distance := absi(candidate.x - tile.x) + absi(candidate.y - tile.y)
		if distance < best_distance:
			best_distance = distance
			best_tile = candidate
	# The host can also set on_ground from a swept-body collision before its
	# inset-foot support probe returns a tile. On a one-pixel ledge, the body may
	# overlap the neighbouring solid while px+3..px+w-3 lies entirely over a
	# centre-column notch. Trust this wider footprint only when the authoritative
	# player state explicitly says grounded, and only on the same snapped row.
	if best_tile == tile and bool(self_state.get("on_ground", false)):
		var body_left := floori(position.x / float(BlockDefs.TILE))
		var body_right := floori((position.x + width - 0.001) / float(BlockDefs.TILE))
		for candidate_x in range(body_left, body_right + 1):
			var candidate := Vector2i(candidate_x, row)
			if candidate == tile or not _terrain_standable_tile(candidate):
				continue
			var distance := absi(candidate.x - tile.x)
			if distance < best_distance:
				best_distance = distance
				best_tile = candidate
	return best_tile


## Returns verified horizontal walk exits for a grounded pose whose mapped
## support cell is invalid. This is deliberately a one-edge recovery: it does
## not relax destination standability or let the planner route from a fictional
## support tile. Physics still moves the player and resolves collision.
func _grounded_origin_walk_steps(
	origin: Vector2,
	self_state: Dictionary,
	first_step_allowed: Callable = Callable(),
) -> Array[Dictionary]:
	var steps: Array[Dictionary] = []
	if not bool(self_state.get("on_ground", false)):
		return steps
	var origin_tile := _route_origin_support_tile(origin, self_state)
	if _terrain_standable_tile(origin_tile):
		return steps
	for direction in [Vector2i.LEFT, Vector2i.RIGHT]:
		var destination_tile: Vector2i = origin_tile + direction
		if not _terrain_standable_tile(destination_tile):
			continue
		if not _physics_transition_allowed(origin_tile, destination_tile, "walk"):
			continue
		if first_step_allowed.is_valid() and not bool(first_step_allowed.call(origin_tile, destination_tile, "walk")):
			continue
		steps.append({
			"position": _world_position_for_support_tile(destination_tile),
			"from_tile": origin_tile,
			"to_tile": destination_tile,
			"kind": "walk",
			"origin_recovery": true,
		})
	return steps


func _grounded_origin_walk_step(
	origin: Vector2,
	self_state: Dictionary,
	destination: Vector2,
	first_step_allowed: Callable = Callable(),
) -> Dictionary:
	var steps := _grounded_origin_walk_steps(origin, self_state, first_step_allowed)
	var best_step: Dictionary = {}
	var best_distance := origin.distance_to(destination)
	for step in steps:
		var step_position: Vector2 = step.get("position", Vector2.ZERO)
		var remaining_distance := step_position.distance_to(destination)
		if remaining_distance >= best_distance:
			continue
		best_distance = remaining_distance
		best_step = step
	return best_step


func _world_position_for_support_tile(tile: Vector2i) -> Vector2:
	return Vector2(
		(float(tile.x) + 0.5) * float(BlockDefs.TILE) - 10.0,
		float(tile.y * BlockDefs.TILE) - 28.0,
	)


func _terrain_standable_tile(tile: Vector2i) -> bool:
	if not (
		_terrain_solid_at(tile.x, tile.y)
		and (
			not _terrain_solid_at(tile.x, tile.y - 1)
			# WorldSim turns tree_ghost on when a grounded player moves into a
			# tree-traversal block. That collision exception applies to wood,
			# foliage and Shagot passage blocks, so a supported route node with
			# one of those blocks in its head cell is physically enterable.
			or _terrain_climbable_at(tile.x, tile.y - 1)
		)
	):
		return false
	var body_left := (tile.x * BlockDefs.TILE)
	var body_top := tile.y * BlockDefs.TILE - 28
	var body_right := body_left + BlockDefs.TILE - 1
	var body_bottom := tile.y * BlockDefs.TILE - 1
	for body_y in range(floori(float(body_top) / float(BlockDefs.TILE)), floori(float(body_bottom) / float(BlockDefs.TILE)) + 1):
		for body_x in range(floori(float(body_left) / float(BlockDefs.TILE)), floori(float(body_right) / float(BlockDefs.TILE)) + 1):
			if _terrain_is_lava_at(body_x, body_y):
				return false
	return true


func _terrain_climbable_tile(tile: Vector2i) -> bool:
	return (
		_terrain_climbable_at(tile.x, tile.y)
		or _terrain_climbable_at(tile.x, tile.y - 1)
		or _terrain_climbable_at(tile.x, tile.y + 1)
	)


func _rebuild_terrain_index(raw_tiles: Variant) -> void:
	_terrain_tiles.clear()
	_terrain_fluid_levels.clear()
	_invalidate_jump_landing_cache()
	_terrain_observed_cells.clear()
	_support_preserving_mine_tiles.clear()
	_safe_exploration_waypoint_cache.clear()
	_safe_exploration_waypoint_cache_origin = Vector2i(2147483647, 2147483647)
	_safe_exploration_waypoint_cache_checked_msec = -1
	if not raw_tiles is Array:
		return
	for raw_tile in raw_tiles:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var key := "%d:%d" % [int(tile.get("x", 0)), int(tile.get("y", 0))]
		_terrain_observed_cells[key] = true
		var name := _block_name_for_content_id(str(tile.get("content_id", "")))
		if name.is_empty():
			name = str(tile.get("block_name", ""))
		if not name.is_empty():
			_terrain_tiles[key] = name
			if bool(tile.get("preserves_support_on_mine", false)):
				_support_preserving_mine_tiles[key] = true
	_physics_route_replan_msec = 0


func _rebuild_fluid_levels(raw_fluids: Variant) -> void:
	_terrain_fluid_levels.clear()
	if not raw_fluids is Array:
		return
	for raw_fluid in raw_fluids:
		if not raw_fluid is Dictionary:
			continue
		var fluid := raw_fluid as Dictionary
		var x := int(fluid.get("x", WorldSim.COORD_LIMIT + 1))
		var y := int(fluid.get("y", WorldSim.COORD_LIMIT + 1))
		var key := "%d:%d" % [x, y]
		if absi(x) <= WorldSim.COORD_LIMIT and absi(y) <= WorldSim.COORD_LIMIT and str(_terrain_tiles.get(key, "")) in ["water", "lava", "core.water", "core.lava"]:
			_terrain_fluid_levels[key] = int(fluid.get("level", -1))


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
	if not (raw_growth as Array).is_empty():
		_invalidate_jump_landing_cache()
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
	if not plants.is_empty():
		_invalidate_jump_landing_cache()
	for raw_plant in plants:
		if raw_plant is Dictionary:
			_ingest_plant_entry(raw_plant as Dictionary)


func _prepare_region_transfer(payload: Dictionary) -> void:
	var transfer_id := str(payload.get("transfer_id", ""))
	var total := int(payload.get("total", 0))
	var chunk_x := int(payload.get("chunk_x", WorldSim.COORD_LIMIT))
	if transfer_id.is_empty() or total <= 0 or total > 512 or absi(chunk_x) > WorldSim.COORD_LIMIT / WorldSim.CHUNK_WIDTH:
		_record_region_transfer_failure("invalid_start", chunk_x, {"total": total})
		return
	if not _region_incoming_transfers.has(transfer_id) and _region_incoming_transfers.size() >= 8:
		var oldest_id := ""
		var oldest_at := 2147483647
		for raw_existing_id in _region_incoming_transfers:
			var existing_id := str(raw_existing_id)
			var existing: Dictionary = _region_incoming_transfers[existing_id]
			var started_at := int(existing.get("started_at_msec", 0))
			if started_at < oldest_at:
				oldest_at = started_at
				oldest_id = existing_id
		if not oldest_id.is_empty():
			_region_incoming_transfers.erase(oldest_id)
	var chunks: Array[String] = []
	chunks.resize(total)
	_region_incoming_transfers[transfer_id] = {
		"chunk_x": chunk_x,
		"chunks": chunks,
		"started_at_msec": Time.get_ticks_msec(),
	}


func _store_region_transfer_chunk(payload: Dictionary) -> void:
	var transfer_id := str(payload.get("transfer_id", ""))
	if transfer_id.is_empty() or not _region_incoming_transfers.has(transfer_id):
		_record_region_transfer_failure("chunk_without_start", int(payload.get("chunk_x", WorldSim.COORD_LIMIT)), {
			"index": int(payload.get("index", -1)),
			"total": int(payload.get("total", -1)),
		})
		return
	var transfer: Dictionary = _region_incoming_transfers[transfer_id]
	var chunks: Array[String] = transfer.get("chunks", [])
	var index := int(payload.get("index", -1))
	if (
		int(payload.get("total", -1)) != chunks.size()
		or int(payload.get("chunk_x", WorldSim.COORD_LIMIT)) != int(transfer.get("chunk_x", WorldSim.COORD_LIMIT))
		or index < 0
		or index >= chunks.size()
		or str(payload.get("data", "")).length() > 12_000
	):
		_record_region_transfer_failure("invalid_chunk", int(transfer.get("chunk_x", WorldSim.COORD_LIMIT)), {
			"index": index,
			"total": int(payload.get("total", -1)),
			"expected_total": chunks.size(),
		})
		_region_incoming_transfers.erase(transfer_id)
		return
	chunks[index] = str(payload.get("data", ""))
	transfer["chunks"] = chunks
	_region_incoming_transfers[transfer_id] = transfer
	var received_event := {
		"event": "region_transfer_chunk_received",
		"chunk_x": int(transfer.get("chunk_x", WorldSim.COORD_LIMIT)),
		"index": index,
		"total": chunks.size(),
		"data_chars": str(payload.get("data", "")).length(),
		"at_msec": Time.get_ticks_msec(),
	}
	structured_log.emit(received_event)
	_record_event("region_transfer_chunk_received", received_event)


func _apply_completed_region_transfer(payload: Dictionary) -> void:
	var transfer_id := str(payload.get("transfer_id", ""))
	if transfer_id.is_empty() or not _region_incoming_transfers.has(transfer_id):
		_record_region_transfer_failure("complete_without_start", int(payload.get("chunk_x", WorldSim.COORD_LIMIT)), {
			"total": int(payload.get("total", -1)),
		})
		return
	var transfer: Dictionary = _region_incoming_transfers[transfer_id]
	_region_incoming_transfers.erase(transfer_id)
	var chunks: Array[String] = transfer.get("chunks", [])
	if (
		chunks.is_empty()
		or chunks.any(func(part: String): return part.is_empty())
		or int(payload.get("total", -1)) != chunks.size()
		or int(payload.get("chunk_x", WorldSim.COORD_LIMIT)) != int(transfer.get("chunk_x", WorldSim.COORD_LIMIT))
	):
		_record_region_transfer_failure("incomplete_transfer", int(transfer.get("chunk_x", WorldSim.COORD_LIMIT)), {
			"received_chunks": chunks.size() - chunks.count(""),
			"expected_chunks": chunks.size(),
			"total": int(payload.get("total", -1)),
		})
		return
	var compressed := Marshalls.base64_to_raw("".join(chunks))
	var raw := compressed.decompress_dynamic(16 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		_record_region_transfer_failure("decompression_failed", int(transfer.get("chunk_x", WorldSim.COORD_LIMIT)), {"encoded_chars": "".join(chunks).length()})
		return
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not parsed is Dictionary or int((parsed as Dictionary).get("chunk_x", WorldSim.COORD_LIMIT)) != int(transfer.get("chunk_x", WorldSim.COORD_LIMIT)):
		_record_region_transfer_failure("invalid_payload", int(transfer.get("chunk_x", WorldSim.COORD_LIMIT)), {
			"json_dictionary": parsed is Dictionary,
			"payload_chunk_x": int((parsed as Dictionary).get("chunk_x", WorldSim.COORD_LIMIT)) if parsed is Dictionary else WorldSim.COORD_LIMIT,
		})
		return
	var region_state := parsed as Dictionary
	if _merge_streamed_chunk_terrain(region_state):
		var chunk_x := int(transfer.get("chunk_x", 0))
		_region_received_chunks[chunk_x] = Time.get_ticks_msec()
		_region_chunk_request_msec.erase(chunk_x)
		var region_tiles: Array = region_state.get("tiles", []) if region_state.get("tiles", []) is Array else []
		_record_event("region_complete", {
			"chunk_x": chunk_x,
			"terrain_tiles": region_tiles.size(),
		})
		structured_log.emit({
			"event": "region_transfer_applied",
			"chunk_x": chunk_x,
			"terrain_tiles": region_tiles.size(),
			"container_count": (region_state.get("containers", []) as Array).size() if region_state.get("containers", []) is Array else 0,
			"at_msec": Time.get_ticks_msec(),
		})
		behavior.request_decision(Time.get_ticks_msec())
	else:
		_record_region_transfer_failure("terrain_merge_rejected", int(transfer.get("chunk_x", WorldSim.COORD_LIMIT)), {
			"has_chunk": region_state.get("chunk", null) is Dictionary,
			"tiles_array": region_state.get("tiles", null) is Array,
			"fluids_array": region_state.get("fluids", null) is Array,
			"tile_count": (region_state.get("tiles", []) as Array).size() if region_state.get("tiles", []) is Array else -1,
		})


func _record_region_transfer_failure(reason: String, chunk_x: int, details: Dictionary = {}) -> void:
	var event := {"reason": reason, "chunk_x": chunk_x}
	event.merge(details, true)
	_record_event("region_transfer_failed", event)
	var log_event := event.duplicate(true)
	log_event["event"] = "region_transfer_failed"
	log_event["at_msec"] = Time.get_ticks_msec()
	structured_log.emit(log_event)


func _request_missing_region_chunks(now_msec: int) -> void:
	if network_client == null or not network_client.has_method("send_command"):
		return
	if _last_region_chunk_request_msec >= 0 and now_msec - _last_region_chunk_request_msec < 500:
		return
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	if self_state.is_empty():
		return
	var tile_x := floori(float(self_state.get("x", 0.0)) / float(BlockDefs.TILE))
	var center_chunk := floori(float(tile_x) / float(WorldSim.CHUNK_WIDTH))
	var direction := 0
	if bool(_desired_input.get("right", false)) and not bool(_desired_input.get("left", false)):
		direction = 1
	elif bool(_desired_input.get("left", false)) and not bool(_desired_input.get("right", false)):
		direction = -1
	if direction == 0:
		direction = 1 if float(self_state.get("facing", 1.0)) >= 0.0 else -1
	for chunk_x in [center_chunk, center_chunk + direction, center_chunk - direction]:
		if _region_received_chunks.has(chunk_x):
			continue
		var last_requested := int(_region_chunk_request_msec.get(chunk_x, -1))
		if last_requested >= 0 and now_msec - last_requested < 5_000:
			continue
		_region_chunk_request_msec[chunk_x] = now_msec
		_last_region_chunk_request_msec = now_msec
		var sent := bool(network_client.call("send_command", "chunk_request", {"chunk_x": chunk_x}))
		if sent:
			structured_log.emit({"event": "region_chunk_requested", "chunk_x": chunk_x, "at_msec": now_msec})
		return


func _merge_streamed_chunk_terrain(state: Dictionary) -> bool:
	var chunk_x := int(state.get("chunk_x", WorldSim.COORD_LIMIT))
	var raw_tiles: Variant = state.get("tiles", null)
	var raw_fluids: Variant = state.get("fluids", null)
	if (
		absi(chunk_x) > WorldSim.COORD_LIMIT / WorldSim.CHUNK_WIDTH
		or not state.get("chunk", null) is Dictionary
		or not raw_tiles is Array
		or not raw_fluids is Array
	):
		return false
	var defs := get_node_or_null("/root/BlockDefs")
	var generated_definitions: Array = state.get("generated_definitions", []) if state.get("generated_definitions", []) is Array else []
	if defs != null and defs.has_method("register_generated_block"):
		for raw_definition in generated_definitions:
			if raw_definition is Dictionary:
				defs.call("register_generated_block", raw_definition)
	var resolved_tiles: Array[Dictionary] = []
	for raw_tile in raw_tiles:
		if not raw_tile is Dictionary:
			return false
		var tile := raw_tile as Dictionary
		var tile_x := int(tile.get("x", WorldSim.COORD_LIMIT + 1))
		var tile_y := int(tile.get("y", WorldSim.COORD_LIMIT + 1))
		var block_name := _block_name_for_content_id(str(tile.get("content_id", "")))
		if (
			absi(tile_x) > WorldSim.COORD_LIMIT
			or absi(tile_y) > WorldSim.COORD_LIMIT
			or floori(float(tile_x) / float(WorldSim.CHUNK_WIDTH)) != chunk_x
			or block_name.is_empty()
			or block_name == "air"
		):
			return false
		resolved_tiles.append({"x": tile_x, "y": tile_y, "block_name": block_name, "content_id": str(tile.get("content_id", ""))})
	# Containers ride on the same authoritative chunk payload. Validate them
	# before any mutation so a malformed coordinate cannot corrupt the cached
	# container index; an absent field means "not streamed" and leaves the
	# existing cache untouched, while an explicit array (even empty) replaces
	# the whole chunk.
	var has_container_payload := state.has("containers")
	var raw_container_entries: Variant = state.get("containers", [])
	var incoming_containers: Array = []
	if has_container_payload:
		if not raw_container_entries is Array:
			return false
		incoming_containers = raw_container_entries
		for raw_container in incoming_containers:
			if not raw_container is Dictionary:
				return false
			var container_entry := raw_container as Dictionary
			var container_x := int(container_entry.get("x", WorldSim.COORD_LIMIT + 1))
			var container_y := int(container_entry.get("y", WorldSim.COORD_LIMIT + 1))
			if (
				absi(container_x) > WorldSim.COORD_LIMIT
				or absi(container_y) > WorldSim.COORD_LIMIT
				or floori(float(container_x) / float(WorldSim.CHUNK_WIDTH)) != chunk_x
			):
				return false
	# The chunk transfer is a complete authoritative view of this generated
	# region, unlike sparse tile_batch deltas. Replace cached cells within its
	# horizontal bounds so old/absent cells cannot survive a procedural update.
	_erase_chunk_index_keys(_terrain_tiles, chunk_x)
	_erase_chunk_index_keys(_terrain_fluid_levels, chunk_x)
	_erase_chunk_index_keys(_terrain_observed_cells, chunk_x)
	_erase_chunk_index_keys(_support_preserving_mine_tiles, chunk_x)
	_erase_chunk_index_keys(_plant_tiles, chunk_x)
	for tile in resolved_tiles:
		var key := "%d:%d" % [int(tile["x"]), int(tile["y"])]
		_terrain_tiles[key] = str(tile["block_name"])
		_terrain_observed_cells[key] = true
	for raw_fluid in raw_fluids:
		if not raw_fluid is Dictionary:
			continue
		var fluid := raw_fluid as Dictionary
		var key := "%d:%d" % [int(fluid.get("x", WorldSim.COORD_LIMIT + 1)), int(fluid.get("y", WorldSim.COORD_LIMIT + 1))]
		if str(_terrain_tiles.get(key, "")) in ["water", "lava", "core.water", "core.lava"]:
			_terrain_fluid_levels[key] = int(fluid.get("level", -1))
	_terrain_known_chunks[chunk_x] = true
	var plant_entries: Array = state.get("plant_growth", []) if state.get("plant_growth", []) is Array else []
	for raw_plant in plant_entries:
		if raw_plant is Dictionary:
			_ingest_plant_entry(raw_plant as Dictionary)
	var snapshot_tiles: Array = _world_snapshot.get("tiles", []) if _world_snapshot.get("tiles", []) is Array else []
	snapshot_tiles = snapshot_tiles.duplicate(true)
	snapshot_tiles = snapshot_tiles.filter(func(tile: Variant): return not tile is Dictionary or floori(float(int((tile as Dictionary).get("x", WorldSim.COORD_LIMIT))) / float(WorldSim.CHUNK_WIDTH)) != chunk_x)
	snapshot_tiles.append_array(resolved_tiles)
	_world_snapshot["tiles"] = snapshot_tiles
	var snapshot_plants: Array = _world_snapshot.get("plant_growth", []) if _world_snapshot.get("plant_growth", []) is Array else []
	snapshot_plants = snapshot_plants.duplicate(true)
	snapshot_plants = snapshot_plants.filter(func(plant: Variant): return not plant is Dictionary or floori(float(int((plant as Dictionary).get("x", (plant as Dictionary).get("anchor_x", WorldSim.COORD_LIMIT)))) / float(WorldSim.CHUNK_WIDTH)) != chunk_x)
	snapshot_plants.append_array(plant_entries)
	_world_snapshot["plant_growth"] = snapshot_plants
	if has_container_payload:
		_merge_streamed_chunk_containers(chunk_x, incoming_containers)
	_invalidate_jump_landing_cache()
	_safe_exploration_waypoint_cache.clear()
	_safe_exploration_waypoint_cache_checked_msec = -1
	_physics_route.clear()
	_physics_route_replan_msec = 0
	return true


## A streamed chunk transfer is a complete authoritative view of its generated
## region, so it must replace the cached container entries inside that chunk.
## Without this an ordinary generated structure chest that arrives only through
## chunk streaming stays invisible, and a chest the host removed (looted/erased)
## or re-emitted would linger or duplicate as a stale entry.
func _merge_streamed_chunk_containers(chunk_x: int, raw_containers: Array) -> void:
	var incoming: Array = raw_containers
	var kept: Array = []
	var existing: Variant = _world_snapshot.get("containers", [])
	if existing is Array:
		var existing_entries: Array = existing
		for raw_entry in existing_entries:
			if not raw_entry is Dictionary:
				continue
			var entry := raw_entry as Dictionary
			var entry_x := int(entry.get("x", WorldSim.COORD_LIMIT))
			if floori(float(entry_x) / float(WorldSim.CHUNK_WIDTH)) == chunk_x:
				continue
			kept.append(entry)
	var merged: Array = kept
	for raw_entry in incoming:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		var tile_x := int(entry.get("x", WorldSim.COORD_LIMIT))
		if floori(float(tile_x) / float(WorldSim.CHUNK_WIDTH)) != chunk_x:
			continue
		merged.append({"x": tile_x, "y": int(entry.get("y", 0)), "data": _container_entry_data(entry)})
	_world_snapshot["containers"] = merged
	if not incoming.is_empty():
		structured_log.emit({
			"event": "region_containers_merged",
			"chunk_x": chunk_x,
			"container_count": merged.size(),
			"at_msec": Time.get_ticks_msec(),
		})


func _erase_chunk_index_keys(index: Dictionary, chunk_x: int) -> void:
	for raw_key in index.keys().duplicate():
		var parts := str(raw_key).split(":")
		if parts.size() == 2 and floori(float(parts[0].to_int()) / float(WorldSim.CHUNK_WIDTH)) == chunk_x:
			index.erase(raw_key)


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
	_invalidate_jump_landing_cache()
	_physics_route_replan_msec = 0


func _apply_tile_batch(payload: Dictionary) -> void:
	var tiles: Array = payload.get("tiles", []) if payload.get("tiles", []) is Array else []
	if not tiles.is_empty():
		_invalidate_jump_landing_cache()
		_safe_exploration_waypoint_cache_checked_msec = -1
	for raw_tile in tiles:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var tile_x := int(tile.get("x", 0))
		var tile_y := int(tile.get("y", 0))
		var key := "%d:%d" % [tile_x, tile_y]
		_terrain_observed_cells[key] = true
		var name := _block_name_for_content_id(str(tile.get("content_id", "")))
		if name.is_empty():
			name = str(tile.get("block_name", ""))
		if name.is_empty() and tile.has("block_id"):
			var defs := get_node_or_null("/root/BlockDefs")
			if defs != null and defs.has_method("get_block_name"):
				name = str(defs.call("get_block_name", int(tile.get("block_id", 0))))
		if int(tile.get("block_id", 1)) == 0 or name == "air":
			_terrain_tiles.erase(key)
			_terrain_fluid_levels.erase(key)
			_support_preserving_mine_tiles.erase(key)
			_forget_protected_build_cell(key)
			_opened_generated_chest_cells.erase(key)
		elif not name.is_empty():
			_terrain_tiles[key] = name
			if _structural_memory_cells.has(key) and _normalized_block_name(str((_structural_memory_cells[key] as Dictionary).get("block", ""))) != _normalized_block_name(name):
				_forget_protected_build_cell(key)
			elif _protected_build_cells.has(key) and _normalized_block_name(str((_protected_build_cells[key] as Dictionary).get("block", ""))) != _normalized_block_name(name):
				_forget_protected_build_cell(key)
			elif _structural_memory_cells.has(key) and _normalized_block_name(str((_structural_memory_cells[key] as Dictionary).get("block", ""))) == _normalized_block_name(name):
				_protected_build_cells[key] = (_structural_memory_cells[key] as Dictionary).duplicate(true)
			if name in ["water", "lava", "core.water", "core.lava"] and tile.has("level"):
				_terrain_fluid_levels[key] = int(tile.get("level", -1))
			else:
				_terrain_fluid_levels.erase(key)
			if name != "chest":
				_opened_generated_chest_cells.erase(key)
			if tile.has("preserves_support_on_mine"):
				if bool(tile.get("preserves_support_on_mine", false)):
					_support_preserving_mine_tiles[key] = true
				else:
					_support_preserving_mine_tiles.erase(key)
		# Host death caches / chests arrive on the same tile_batch as terrain.
		# Without this merge the bot never learns about a cache created after join
		# (including its own drop after lava/combat defeat).
		if tile.has("container"):
			_update_snapshot_container(key, tile.get("container", null))
	_physics_route_replan_msec = 0
	_sync_stone_age_goal(_achievement_observation(), Time.get_ticks_msec())


func _terrain_name_at(tx: int, ty: int) -> String:
	return str(_terrain_tiles.get("%d:%d" % [tx, ty], ""))


func _normalized_block_name(name: String) -> String:
	return name.to_lower().trim_prefix("core.")


func _read_structural_memory() -> Dictionary:
	if _structural_memory_path.is_empty() or not FileAccess.file_exists(_structural_memory_path):
		return {}
	var file := FileAccess.open(_structural_memory_path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or int((parsed as Dictionary).get("version", 0)) != 1:
		return {}
	var worlds: Variant = (parsed as Dictionary).get("worlds", {})
	return worlds if worlds is Dictionary else {}


func _load_structural_memory_world() -> void:
	_protected_build_cells.clear()
	_structural_memory_cells.clear()
	if world_id.is_empty():
		return
	var metadata: Variant = _read_structural_memory().get(world_id, {})
	if not metadata is Dictionary:
		return
	var cells: Variant = (metadata as Dictionary).get("cells", {})
	if not cells is Dictionary:
		return
	for raw_key in cells:
		if _structural_memory_cells.size() >= MAX_STRUCTURAL_MEMORY_CELLS:
			break
		var cell: Variant = (cells as Dictionary)[raw_key]
		if cell is Dictionary and not str((cell as Dictionary).get("block", "")).is_empty():
			_structural_memory_cells[str(raw_key)] = {
				"block": str((cell as Dictionary).get("block", "")),
				"reason": str((cell as Dictionary).get("reason", "")),
				"confirmed": true,
			}


func _restore_protected_build_cells() -> void:
	for key in _structural_memory_cells.keys():
		# The snapshot can be partial. Restore only cells for which the host
		# actually supplied matching terrain; retain unknown cells for tile_batch.
		if _terrain_tiles.has(key) and _normalized_block_name(str(_terrain_tiles[key])) == _normalized_block_name(str((_structural_memory_cells[key] as Dictionary).get("block", ""))):
			_protected_build_cells[key] = (_structural_memory_cells[key] as Dictionary).duplicate(true)
		elif _terrain_tiles.has(key):
			_forget_protected_build_cell(key)


func _save_protected_build_cell(key: String) -> void:
	if world_id.is_empty() or not _protected_build_cells.has(key):
		return
	var cell: Dictionary = _protected_build_cells[key]
	var block := str(cell.get("block", ""))
	if block.is_empty() or not bool(cell.get("confirmed", false)):
		return
	_structural_memory_cells[key] = {"block": block, "reason": str(cell.get("reason", "")), "confirmed": true}
	_write_structural_memory()


func _forget_protected_build_cell(key: String) -> void:
	_protected_build_cells.erase(key)
	if _structural_memory_cells.erase(key):
		_write_structural_memory()


func _write_structural_memory() -> void:
	if _structural_memory_path.is_empty() or world_id.is_empty():
		return
	var worlds := _read_structural_memory()
	if _structural_memory_cells.is_empty():
		worlds.erase(world_id)
	else:
		while _structural_memory_cells.size() > MAX_STRUCTURAL_MEMORY_CELLS:
			_structural_memory_cells.erase(_structural_memory_cells.keys()[0])
		worlds[world_id] = {"updated_unix": Time.get_unix_time_from_system(), "cells": _structural_memory_cells.duplicate(true)}
	while worlds.size() > MAX_STRUCTURAL_MEMORY_WORLDS:
		var oldest_id := ""
		var oldest_time := INF
		for candidate in worlds:
			var candidate_metadata: Dictionary = worlds[candidate] if worlds[candidate] is Dictionary else {}
			var updated := float(candidate_metadata.get("updated_unix", 0.0))
			if updated < oldest_time:
				oldest_time = updated
				oldest_id = str(candidate)
		worlds.erase(oldest_id)
	var absolute_path := ProjectSettings.globalize_path(_structural_memory_path)
	if DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir()) != OK:
		return
	var temporary_path := "%s.tmp" % absolute_path
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"version": 1, "worlds": worlds}))
	file.flush()
	file.close()
	if FileAccess.file_exists(absolute_path):
		DirAccess.remove_absolute(absolute_path)
	DirAccess.rename_absolute(temporary_path, absolute_path)


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


## Authoritative terrain verdict for the support cell directly under an avatar's
## feet. "unknown" means the bot has no terrain data there and must not conclude
## the cell is unsupported; fluid and climbable cells are legitimate support.
func _authoritative_support_verdict(tile: Vector2i) -> String:
	var name := _terrain_name_at(tile.x, tile.y)
	if not name.is_empty():
		var entry := _block_entry(name)
		if bool(entry.get("fluid", false)):
			return "fluid"
		if bool(entry.get("solid", false)) or _terrain_climbable_at(tile.x, tile.y):
			return "supported"
		return "unsupported"
	if not _terrain_cell_is_known(tile.x, tile.y):
		return "unknown"
	if _terrain_climbable_at(tile.x, tile.y):
		return "supported"
	return "unsupported"


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
	if _jump_predicted_landed:
		# The private predictor is not proof that the host landed. Keep the
		# verified transition active, but release jump/steering while waiting for
		# the authoritative pose so a new route cannot walk into a nearby hazard.
		_set_desired_input(false, false, false)
		_advance_local_physics(self_state, delta, false)
		_world_snapshot["self"] = self_state
		return {"done": false, "reason": "await_host_landing"}
	if not _jump_active:
		_jump_active = true
		_jump_start_x = origin.x
		_jump_started_msec = Time.get_ticks_msec()
	var direction := signf(destination.x - origin.x)
	# Preserve the actual jump/hold controls, but release horizontal steering once
	# the requested landing column is reached. Holding left/right for the entire
	# arc overshoots one-block steps (especially step-ups) because jump airtime is
	# much longer than the 32 px support-tile transition.
	var landing_column_reached := absf(destination.x - origin.x) <= 8.0
	_set_desired_input(not landing_column_reached and direction < 0.0, not landing_column_reached and direction > 0.0, true)
	var was_airborne := not bool(self_state.get("on_ground", false))
	_advance_local_physics(self_state, delta, true)
	var landed := was_airborne and bool(self_state.get("on_ground", false))
	var next_x := float(self_state.get("x", origin.x))
	_world_snapshot["self"] = self_state
	if landed and absf(next_x - _jump_start_x) < 4.0 and absf(destination.x - next_x) > 8.0:
		_physics_route.clear()
		_physics_route_replan_msec = 0
		_set_desired_input(false, false, false)
		self_state["vx"] = 0.0
		_world_snapshot["self"] = self_state
		return {"done": true, "reason": "blocked_obstacle"}
	if landed and absf(destination.x - next_x) <= 8.0:
		_jump_predicted_landed = true
		_set_desired_input(false, false, false)
		return {"done": false, "reason": "await_host_landing"}
	if landed:
		_jump_active = false
		_jump_started_msec = -1
	return {"done": false, "reason": "jump_step"}


func _jump_route_has_safe_landing(
	self_state: Dictionary,
	destination: Vector2,
	allow_starting_hazard_escape: bool = false,
) -> bool:
	var origin := Contract.target_position(self_state)
	var origin_support := _route_origin_support_tile(origin, self_state)
	var landing_support := _support_tile_for_position(destination)
	var horizontal_tiles := absi(landing_support.x - origin_support.x)
	if horizontal_tiles <= 0 or horizontal_tiles > 2:
		return false
	# The navigator only advertises same-level and one-block-up jumps. Drops are
	# walked normally; larger climbs need a dig/climb route rather than hope.
	if landing_support.y < origin_support.y - 1 or landing_support.y > origin_support.y:
		return false
	if not _terrain_standable_tile(landing_support):
		return false
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var height := maxf(1.0, float(self_state.get("h", 28.0)))
	var direction := signf(destination.x - origin.x)
	if is_zero_approx(direction):
		return false
	var x := float(self_state.get("x", origin.x))
	var y := float(self_state.get("y", origin.y))
	var cleared_starting_hazard := not _position_touches_harmful_fluid(x, y, width, height)
	var fluid := _local_fluid_physics(x, y, width, height)
	var vx := direction * (BlockDefs.MOVE * float(fluid.get("move_speed_multiplier", 1.0)))
	var vy := BlockDefs.JUMP * float(fluid.get("jump_multiplier", 1.0))
	for _frame in range(90):
		var substeps := maxi(1, int(ceil(maxf(absf(vx), absf(vy)) / 6.0)))
		var substep := 1.0 / float(substeps)
		for _substep_index in substeps:
			var horizontal_direction := direction if absf(destination.x - x) > 8.0 else 0.0
			var next_x := x + horizontal_direction * (BlockDefs.MOVE * float(fluid.get("move_speed_multiplier", 1.0))) * substep
			var horizontal_hit := _local_collision(next_x, y, width, height)
			if horizontal_hit.is_empty():
				x = next_x
			else:
				# WorldSim resolves horizontal contact against the block face and then
				# applies this substep's vertical motion. Rejecting the arc here instead
				# made the body-width overlap at a one-block ledge look like a blocked
				# jump, so flee/pathfinding discarded the only safe step-up route.
				var block_x := float(horizontal_hit.get("bx", 0.0))
				var resolved_x := block_x - width if horizontal_direction > 0.0 else block_x + float(BlockDefs.TILE)
				if not _local_collision(resolved_x, y, width, height).is_empty():
					# The face is only resolved for the row the avatar occupies before
					# this substep's rise. While the lower few pixels still overlap a
					# one-block ledge the pre-rise probe keeps hitting it, yet the same
					# tick lifts the body clear, so mirror the authoritative order by
					# re-testing the resolved face at the risen row. Only a pose that is
					# still blocked after the rise is real side penetration.
					var risen_y := y + vy * substep
					if vy >= 0.0 or not _local_collision(resolved_x, risen_y, width, height).is_empty():
						return false
				x = resolved_x
			var next_y := y + vy * substep
			var vertical_hit := _local_collision(x, next_y, width, height)
			if vertical_hit.is_empty():
				y = next_y
			else:
				if vy < 0.0:
					return false
				y = float(vertical_hit.get("by", y)) - height
				if _position_touches_harmful_fluid(x, y, width, height) and (not allow_starting_hazard_escape or cleared_starting_hazard):
					return false
				return _support_tile_for_position(Vector2(x, y)) == landing_support
			var touches_hazard := _position_touches_harmful_fluid(x, y, width, height)
			if touches_hazard:
				if not allow_starting_hazard_escape or cleared_starting_hazard:
					return false
			else:
				cleared_starting_hazard = true
		# Re-evaluate the center-tile fluid each frame so an arc that enters or
		# leaves water tracks the same speed/gravity the authoritative host uses.
		fluid = _local_fluid_physics(x, y, width, height)
		vx = direction * (BlockDefs.MOVE * float(fluid.get("move_speed_multiplier", 1.0)))
		vy = minf(float(fluid.get("max_fall", LOCAL_MAX_FALL_SPEED)), vy + BlockDefs.GRAVITY * float(fluid.get("gravity_multiplier", 1.0)))
		if y > origin.y + float(BlockDefs.TILE) * 4.0:
			return false
	return false


## Mirrors WorldSim.move_player's center-tile fluid modifiers so the private
## predictor and the route validator stay in lockstep with the authoritative
## host. Returns an empty dictionary when the avatar's center tile is not a
## fluid, which keeps land movement on the original constants.
func _local_fluid_physics(x: float, y: float, width: float, height: float) -> Dictionary:
	var center_x := floori((x + width * 0.5) / float(BlockDefs.TILE))
	var center_y := floori((y + height * 0.5) / float(BlockDefs.TILE))
	var name := _terrain_name_at(center_x, center_y).to_lower()
	if name.is_empty():
		return {}
	var entry := _block_entry(name)
	if not bool(entry.get("fluid", false)):
		return {}
	var in_water := name == "water"
	var in_lava := name == "lava"
	var viscosity := clampf(float(entry.get("viscosity", 0.08 if in_water else (0.92 if in_lava else 0.3))), 0.0, 1.0)
	return {
		"viscosity": viscosity,
		"move_speed_multiplier": lerpf(0.62, 0.32, viscosity),
		"gravity_multiplier": lerpf(0.32, 0.55, viscosity),
		"jump_multiplier": lerpf(0.56, 0.44, viscosity),
		"max_fall": lerpf(6.5, 4.5, viscosity),
	}


func _advance_local_physics(self_state: Dictionary, delta: float, jump_pressed: bool) -> void:
	"""Apply a small, deterministic copy of WorldSim player physics.

	Older P2P hosts do not simulate guest input.  Their only view of the bot is
	the player_snapshot stream, so that stream must contain collision-resolved
	coordinates rather than a kinematic target position that can float over a
	gap.  Dedicated hosts still correct these values from their own simulation.
	"""
	_physics_advanced_this_frame = true
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
	var fluid := _local_fluid_physics(x, y, width, height)
	var in_fluid := not fluid.is_empty()
	var gravity := BlockDefs.GRAVITY * float(fluid.get("gravity_multiplier", 1.0))
	var jump_power := BlockDefs.JUMP * float(fluid.get("jump_multiplier", 1.0))
	var max_fall := float(fluid.get("max_fall", LOCAL_MAX_FALL_SPEED))
	var target_vx := direction * (BlockDefs.MOVE * float(fluid.get("move_speed_multiplier", 1.0)))
	if in_fluid:
		# WorldSim drops friction in fluids and writes the target velocity
		# directly; matching that keeps grounded-host reconciliation exact.
		vx = target_vx
	elif on_ground:
		vx = lerpf(vx, target_vx, clampf(step, 0.0, 1.0))
	else:
		vx = target_vx
	# Match WorldSim.can_jump(): fluid permits a jump from mid-water, but only
	# once the avatar is falling/grounded. Jump input remains held for the whole
	# route; without the velocity guard this predictor restarted the water jump
	# every tick while rising, diverging from the host and triggering recovery.
	if jump_pressed and (on_ground or in_fluid) and vy >= -0.05:
		vy = jump_power
		on_ground = false
	elif on_ground:
		vy = 0.0
	else:
		# Match WorldSim's terminal velocity. An incomplete support snapshot must
		# never make the legacy predictor accelerate to enormous coordinates while
		# it waits for the authoritative host to reconcile the player.
		vy = minf(max_fall, vy + gravity * step)

	var substeps := maxi(1, int(ceil(maxf(absf(vx), absf(vy)) * step / 6.0)))
	var substep := step / float(substeps)
	for _index in substeps:
		if not is_zero_approx(vx):
			var next_x := x + vx * substep
			# Policy and route targets can change while a step is in flight. Guard
			# the actual body footprint on every physics substep, not just the
			# chosen support column, so an overshoot cannot walk into known lava.
			var feet_row := floori((y + height + 0.01) / float(BlockDefs.TILE))
			var next_edge_x := floori((next_x if vx < 0.0 else next_x + width - 0.001) / float(BlockDefs.TILE))
			var current_edge_x := floori((x if vx < 0.0 else x + width - 0.001) / float(BlockDefs.TILE))
			var new_lava_support := (
				on_ground and not jump_pressed and next_edge_x != current_edge_x
				and _terrain_is_lava_at(next_edge_x, feet_row)
				and not _terrain_is_lava_at(current_edge_x, feet_row)
			)
			if new_lava_support or (not _position_touches_harmful_fluid(x, y, width, height) and _position_touches_harmful_fluid(next_x, y, width, height)):
				vx = 0.0
				_set_desired_input(false, false, bool(_desired_input.get("jump", false)))
				continue
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


func _advance_local_physics_if_needed(delta: float) -> void:
	if _physics_advanced_this_frame:
		return
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	if self_state.is_empty():
		return
	_advance_local_physics(self_state, delta, false)
	_world_snapshot["self"] = self_state


func _local_touches_harmful_fluid(self_state: Dictionary) -> bool:
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var height := maxf(1.0, float(self_state.get("h", 28.0)))
	return _position_touches_harmful_fluid(
		float(self_state.get("x", 0.0)),
		float(self_state.get("y", 0.0)),
		width,
		height,
	)


func _position_touches_harmful_fluid(x: float, y: float, width: float, height: float) -> bool:
	var left := floori(x / float(BlockDefs.TILE))
	var right := floori((x + width - 0.001) / float(BlockDefs.TILE))
	var top := floori(y / float(BlockDefs.TILE))
	var bottom := floori((y + height - 0.001) / float(BlockDefs.TILE))
	for tile_y in range(top, bottom + 1):
		for tile_x in range(left, right + 1):
			var name := _terrain_name_at(tile_x, tile_y).to_lower()
			if name == "lava" or name.ends_with(".lava"):
				return true
			var entry := _block_entry(name)
			if bool(entry.get("fluid", false)) and float(entry.get("temperature", 0.0)) >= 0.8:
				return true
	return false


func _update_lava_retreat_state(self_state: Dictionary) -> bool:
	if _local_touches_harmful_fluid(self_state):
		_lava_retreat_active = true
	if not _lava_retreat_active:
		return false
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var height := maxf(1.0, float(self_state.get("h", 28.0)))
	var x := float(self_state.get("x", 0.0))
	var y := float(self_state.get("y", 0.0))
	var closest_clearance := INF
	for key in _terrain_tiles:
		var parts := str(key).split(":")
		if parts.size() != 2:
			continue
		var tile_x := int(parts[0])
		var tile_y := int(parts[1])
		if not _terrain_is_lava_at(tile_x, tile_y):
			continue
		var tile_left := float(tile_x * BlockDefs.TILE)
		var tile_top := float(tile_y * BlockDefs.TILE)
		var dx := maxf(maxf(tile_left - (x + width), x - (tile_left + float(BlockDefs.TILE))), 0.0)
		var dy := maxf(maxf(tile_top - (y + height), y - (tile_top + float(BlockDefs.TILE))), 0.0)
		closest_clearance = minf(closest_clearance, Vector2(dx, dy).length())
	# Keep survival ahead of crafting/following until the avatar has cleared the
	# immediate hazard area. If the host no longer provides terrain, do not pin
	# the bot in survival forever on stale data.
	if is_inf(closest_clearance) or closest_clearance >= float(BlockDefs.TILE) * 2.0:
		_lava_retreat_active = false
	return _lava_retreat_active


func _apply_local_harmful_fluid(self_state: Dictionary, delta: float) -> void:
	_harmful_fluid_damage_cooldown = maxf(0.0, _harmful_fluid_damage_cooldown - maxf(delta, 0.0))
	var touching := _local_touches_harmful_fluid(self_state)
	if touching and (not _was_in_harmful_fluid or _harmful_fluid_damage_cooldown <= 0.0):
		var health := maxi(0, int(self_state.get("health", 10)) - 1)
		self_state["health"] = health
		_harmful_fluid_damage_cooldown = HARMFUL_FLUID_DAMAGE_INTERVAL
		if health <= 0 and not _guest_defeat_pending:
			# Environmental deaths break a consecutive player-kill streak. Do not
			# attribute a recent, non-lethal player hit to the lava respawn. The
			# host can echo the same dead pose before respawning; claim this local
			# death only once for that life.
			_last_player_damage_attacker_id = ""
			_last_player_damage_msec = -1
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
	var respawn_revision := int(local.get("respawn_revision", 0))
	if respawn_revision == _guest_defeat_sent_revision:
		return
	var sent := bool(network_client.call("send_command", "player_defeated", {
		"respawn_revision": respawn_revision,
	}))
	if not sent:
		_guest_defeat_retry_after_msec = now_msec + GUEST_DEFEAT_RETRY_MSEC
		return
	_guest_defeat_sent_revision = respawn_revision
	_guest_defeat_retry_after_msec = -1
	structured_log.emit({
		"event": "guest_defeat_requested",
		"respawn_revision": respawn_revision,
		"at_msec": now_msec,
	})


func _record_recent_player_damage(payload: Dictionary, now_msec: int) -> void:
	if str(payload.get("target_player_id", "")) != own_player_id:
		return
	var attacker_id := str(payload.get("attacker_player_id", ""))
	if attacker_id.is_empty() or attacker_id == own_player_id or int(payload.get("damage", 0)) <= 0:
		return
	_last_player_damage_attacker_id = attacker_id
	_last_player_damage_msec = now_msec


func _handle_confirmed_respawn(now_msec: int) -> void:
	_guest_defeat_sent_revision = -1
	_guest_defeat_retry_after_msec = -1
	# The action that was running before death targets the old life/position. In
	# particular, a long MOVE_TO can otherwise survive every respawn and keep the
	# bot walking back into the same danger instead of re-evaluating survival.
	if behavior != null and behavior.executor != null and behavior.executor.is_busy():
		var interrupted_decision: Dictionary = behavior.executor.current_decision.duplicate(true)
		behavior.executor.cancel("respawn_replan")
		structured_log.emit({
			"event": "respawn_action_cancelled",
			"action": str(interrupted_decision.get("action", "")),
			"goal": str(interrupted_decision.get("goal", "")),
			"at_msec": now_msec,
		})
	var death_state: Dictionary = (_world_snapshot.get("self", {}) as Dictionary).duplicate(true) if _world_snapshot.get("self", {}) is Dictionary else {}
	var recent_death_actions: Array[Dictionary] = []
	for raw_action in _action_history.slice(maxi(0, _action_history.size() - 4)):
		if raw_action is Dictionary:
			recent_death_actions.append((raw_action as Dictionary).duplicate(true))
	var nearby_threat_ids: Array[String] = []
	var raw_threats: Variant = _world_snapshot.get("threats", [])
	if raw_threats is Array:
		for raw_threat in raw_threats:
			if raw_threat is Dictionary:
				nearby_threat_ids.append(str((raw_threat as Dictionary).get("id", "")))
	var killer_id := ""
	if (
		not _last_player_damage_attacker_id.is_empty()
		and _last_player_damage_msec >= 0
		and now_msec - _last_player_damage_msec <= RECENT_PLAYER_KILL_MSEC
	):
		killer_id = _last_player_damage_attacker_id
	_last_player_damage_attacker_id = ""
	_last_player_damage_msec = -1
	_player_death_count += 1
	if killer_id.is_empty():
		_aggressive_player_id = ""
		_host_kill_streak = 0
	else:
		_aggressive_player_id = killer_id
		_host_kill_streak = _host_kill_streak + 1 if killer_id == _host_player_id and not _host_player_id.is_empty() else 0
	var emoji := death_reaction_emoji(killer_id, _host_player_id, _host_kill_streak)
	_send_death_reaction(emoji, killer_id, now_msec)
	structured_log.emit({
		"event": "bot_death_confirmed",
		"killer_player_id": killer_id,
		"host_kill_streak": _host_kill_streak,
		"death_count": _player_death_count,
		"emoji": emoji,
		"death_state": {
			"x": float(death_state.get("x", 0.0)),
			"y": float(death_state.get("y", 0.0)),
			"health": int(death_state.get("health", -1)),
			"nourishment": int(death_state.get("nourishment", -1)),
			"vy": float(death_state.get("vy", 0.0)),
			"on_ground": bool(death_state.get("on_ground", false)),
			"touching_harmful_fluid": _local_touches_harmful_fluid(death_state) if not death_state.is_empty() else false,
		},
		"nearby_threat_ids": nearby_threat_ids,
		"recent_actions": recent_death_actions,
		"at_msec": now_msec,
	})
	behavior.request_decision(now_msec)
	if _host_kill_streak < HOST_KILL_LIMIT or _world_block_requested:
		return
	_world_block_requested = true
	_host_kill_leave_at_msec = now_msec + HOST_KILL_LEAVE_DELAY_MSEC
	world_block_requested.emit(world_id, killer_id, _host_kill_streak)
	structured_log.emit({
		"event": "world_block_requested",
		"world_id": world_id,
		"killer_player_id": killer_id,
		"host_kill_streak": _host_kill_streak,
		"leave_at_msec": _host_kill_leave_at_msec,
		"at_msec": now_msec,
	})


func _send_death_reaction(emoji: String, killer_id: String, now_msec: int) -> void:
	var sanitized := EmojiReactions.sanitize(emoji)
	if sanitized.is_empty():
		return
	if network_client != null and network_client.has_method("send_command"):
		network_client.call("send_command", "emoji_reaction", {"emoji": sanitized})
	_last_emoji_sent_msec = now_msec
	_social_last_sent_msec = now_msec
	_previous_emoji = sanitized
	_clear_social_emoji_queue()
	structured_log.emit({
		"event": "death_emoji_sent",
		"emoji": sanitized,
		"killer_player_id": killer_id,
		"at_msec": now_msec,
	})


static func death_reaction_emoji(killer_id: String, host_player_id: String, host_kill_streak: int) -> String:
	if killer_id.is_empty():
		return "😭"
	if killer_id == host_player_id and not host_player_id.is_empty():
		return HOST_KILL_EMOJIS[clampi(host_kill_streak - 1, 0, HOST_KILL_EMOJIS.size() - 1)]
	return "😡"


## Terminal `duel_result` handling. The host owns the outcome, so the bot only
## records it, cancels anything still in flight, and stops issuing combat
## decisions for the resolved match.
func _handle_duel_result(payload: Dictionary) -> void:
	if _duel_result_received:
		return
	# A stray or spoofed control packet must not end combat in a world the bot
	# is not actually fighting in.
	if not _is_pvp_world() and not _duel_started:
		_record_event("duel_result_ignored", {"reason": "non_pvp_world"})
		return
	var payload_world_id := str(payload.get("world_id", ""))
	if not payload_world_id.is_empty() and not world_id.is_empty() and payload_world_id != world_id:
		_record_event("duel_result_ignored", {
			"reason": "world_mismatch",
			"world_id": payload_world_id,
		})
		return
	var now_msec := Time.get_ticks_msec()
	var winner_id := str(payload.get("winner_player_id", ""))
	var loser_id := str(payload.get("loser_player_id", ""))
	var bot_won := not winner_id.is_empty() and winner_id == own_player_id
	_duel_result_received = true
	_duel_result = {
		"winner_player_id": winner_id,
		"loser_player_id": loser_id,
		"bot_won": bot_won,
		"received_at_msec": now_msec,
	}
	_record_event("duel_result", _duel_result.duplicate(true))
	structured_log.emit({
		"event": "duel_result",
		"winner_player_id": winner_id,
		"loser_player_id": loser_id,
		"bot_won": bot_won,
		"at_msec": now_msec,
	})
	_stop_duel_combat(now_msec)
	_send_duel_result_emoji(bot_won, now_msec)


func _stop_duel_combat(now_msec: int) -> void:
	if behavior != null and behavior.executor != null and behavior.executor.is_busy():
		var interrupted_decision: Dictionary = behavior.executor.current_decision.duplicate(true)
		behavior.executor.cancel("duel_result")
		structured_log.emit({
			"event": "duel_result_action_cancelled",
			"action": str(interrupted_decision.get("action", "")),
			"goal": str(interrupted_decision.get("goal", "")),
			"at_msec": now_msec,
		})
	_set_desired_input(false, false, false)
	structured_log.emit({
		"event": "duel_combat_stopped",
		"bot_won": bool(_duel_result.get("bot_won", false)),
		"at_msec": now_msec,
	})


func _send_duel_result_emoji(bot_won: bool, now_msec: int) -> void:
	var sanitized := EmojiReactions.sanitize("🎉" if bot_won else "😭")
	if sanitized.is_empty():
		return
	if not _social.emoji_can_send(_last_emoji_sent_msec, now_msec, sanitized, _previous_emoji, _social_last_sent_msec):
		return
	if network_client != null and network_client.has_method("send_command"):
		network_client.call("send_command", "emoji_reaction", {"emoji": sanitized})
	_last_emoji_sent_msec = now_msec
	_social_last_sent_msec = now_msec
	_previous_emoji = sanitized
	_clear_social_emoji_queue()
	structured_log.emit({
		"event": "duel_result_emoji_sent",
		"emoji": sanitized,
		"bot_won": bot_won,
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
	_protected_build_cells[key] = {"block": block_name, "reason": "fall_support", "at_msec": now_msec}
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
	# An existing workbench/furnace one cell below is already a landing. A
	# midair clutch on top of it creates a roof over the only step back from an
	# island edge and can strand the bot behind its own station.
	if str(_terrain_name_at(tx, ty + 1)).to_lower().trim_prefix("core.") in ["workbench", "furnace"]:
		return SUPPORT_PLACE_INVALID_TILE
	# A falling placement must attach to real terrain. This preserves the useful
	# block-clutch ability beside a ledge or above a pillar without manufacturing
	# isolated blocks in empty sky from a stale predicted fall.
	if not (
		_terrain_solid_at(tx - 1, ty)
		or _terrain_solid_at(tx + 1, ty)
		or _terrain_solid_at(tx, ty + 1)
	):
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


func _local_pose_has_support(self_state: Dictionary) -> bool:
	if _terrain_tiles.is_empty():
		return false
	var width := maxf(1.0, float(self_state.get("w", 20.0)))
	var height := maxf(1.0, float(self_state.get("h", 28.0)))
	var x := float(self_state.get("x", 0.0))
	var y := float(self_state.get("y", 0.0))
	var support := _support_tile_for_position(Vector2(x, y))
	if not _terrain_solid_at(support.x, support.y):
		return false
	var expected_y := float(support.y * BlockDefs.TILE) - height
	if absf(y - expected_y) > 1.75:
		return false
	var foot_left := x + 3.0
	var foot_right := x + width - 3.0
	var block_left := float(support.x * BlockDefs.TILE)
	return foot_right > block_left and foot_left < block_left + float(BlockDefs.TILE)


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
	# Match the host's climb control: climbing changes y, not the player's x.
	var next_x := origin.x
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


func _on_network_transport_changed(mode: String) -> void:
	var now_msec := Time.get_ticks_msec()
	if mode == "reconnecting":
		if state != STATE_PLAYING or _transport_reconnect_started_msec >= 0:
			return
		_transport_reconnect_started_msec = now_msec
		if behavior != null and behavior.executor != null:
			behavior.executor.suspend(now_msec)
		_set_desired_input(false, false, false)
		structured_log.emit({"event": "transport_pause_started", "transport": mode, "world_id": world_id, "at_msec": now_msec})
		return
	if _transport_reconnect_started_msec < 0:
		return
	var paused_msec := maxi(0, now_msec - _transport_reconnect_started_msec)
	_shift_transport_pause_deadlines(paused_msec)
	if behavior != null and behavior.executor != null:
		behavior.executor.resume(now_msec)
	_transport_reconnect_started_msec = -1
	if behavior != null:
		behavior.request_decision(now_msec)
	structured_log.emit({"event": "transport_pause_ended", "transport": mode, "pause_msec": paused_msec, "world_id": world_id, "at_msec": now_msec})


func _shift_transport_pause_deadlines(paused_msec: int) -> void:
	if paused_msec <= 0:
		return
	for raw_key in _pending_action_targets.keys():
		var pending: Dictionary = _pending_action_targets.get(raw_key, {}) if _pending_action_targets.get(raw_key, {}) is Dictionary else {}
		if int(pending.get("sent_at_msec", -1)) >= 0:
			pending["sent_at_msec"] = int(pending["sent_at_msec"]) + paused_msec
			_pending_action_targets[raw_key] = pending
	if not _craft_pending_output.is_empty() and _craft_retry_after_msec >= 0:
		_craft_retry_after_msec += paused_msec
	var stone_pending: Dictionary = _stone_age_goal_state.get("pending", {}) if _stone_age_goal_state.get("pending", {}) is Dictionary else {}
	if int(stone_pending.get("started_at_msec", -1)) >= 0:
		stone_pending["started_at_msec"] = int(stone_pending["started_at_msec"]) + paused_msec
		_stone_age_goal_state["pending"] = stone_pending
	for raw_goal_id in _achievement_goal_states.keys():
		var entry: Dictionary = _achievement_goal_states.get(raw_goal_id, {}) if _achievement_goal_states.get(raw_goal_id, {}) is Dictionary else {}
		var pending: Dictionary = entry.get("pending", {}) if entry.get("pending", {}) is Dictionary else {}
		if int(pending.get("started_at_msec", -1)) >= 0:
			pending["started_at_msec"] = int(pending["started_at_msec"]) + paused_msec
			entry["pending"] = pending
			_achievement_goal_states[raw_goal_id] = entry
	var placement: Dictionary = _build_project_state.get("pending_placement", {}) if _build_project_state.get("pending_placement", {}) is Dictionary else {}
	if int(placement.get("at_msec", -1)) >= 0:
		placement["at_msec"] = int(placement["at_msec"]) + paused_msec
		_build_project_state["pending_placement"] = placement


func _on_network_message(message: Dictionary) -> void:
	handle_message(message)


func _connected_peers_supported(raw_players: Variant) -> bool:
	if not raw_players is Array:
		return true
	var peer_checks: Array[Dictionary] = []
	for raw_player in raw_players:
		if not raw_player is Dictionary:
			continue
		var entry := raw_player as Dictionary
		var player_id := str(entry.get("player_id", entry.get("id", "")))
		var role := str(entry.get("role", "")).to_lower()
		var is_host := player_id == _host_player_id or role == "host"
		var supported := _peer_client_version_supported(entry)
		peer_checks.append({
			"role": role,
			"is_host": is_host,
			"has_client_version": not str(entry.get("client_version", "")).is_empty(),
			"client_version": str(entry.get("client_version", "")),
			"supported": supported,
		})
		if not supported:
			structured_log.emit({
				"event": "unsupported_connected_peer_version",
				"host_id_known": not _host_player_id.is_empty(),
				"peers": peer_checks,
				"at_msec": Time.get_ticks_msec(),
			})
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
		# A genuinely new transfer resets the missing-chunk retry budget. A
		# repeated packet for the same transfer never discards collected chunks.
		_snapshot_retry_count = 0
		_snapshot_retry_at_msec = Time.get_ticks_msec() + SNAPSHOT_RETRY_INTERVAL_MSEC


func _send_snapshot_request() -> void:
	if network_client == null or not network_client.has_method("send_command"):
		return
	network_client.call("send_command", "snapshot_request", {})


func _retry_snapshot_sync(now_msec: int) -> void:
	_snapshot_retry_at_msec = now_msec + SNAPSHOT_RETRY_INTERVAL_MSEC
	if network_client == null or not network_client.has_method("send_command"):
		return
	if _snapshot_expected_chunks <= 0:
		# No transfer started; the initial request was likely dropped while the
		# P2P data channel was still negotiating. Ask again in full.
		_send_snapshot_request()
		_record_event("snapshot_request_retried", {"attempt": _snapshot_retry_count})
		return
	var missing: Array[int] = []
	for index in _snapshot_chunks.size():
		if _snapshot_chunks[index].is_empty():
			missing.append(index)
	_snapshot_retry_count += 1
	if _snapshot_retry_count >= SNAPSHOT_RETRY_LIMIT:
		# Bounded restart: drop the stalled transfer and request a fresh one so
		# a lost snapshot_start/complete packet cannot strand the bot.
		_snapshot_transfer_id = ""
		_snapshot_expected_chunks = 0
		_snapshot_chunks.clear()
		_snapshot_retry_count = 0
		_send_snapshot_request()
		_record_event("snapshot_restart", {"missing": missing.size()})
		return
	network_client.call("send_command", "snapshot_retry", {
		"transfer_id": _snapshot_transfer_id,
		"missing": missing,
	})
	_record_event("snapshot_missing_retry", {"missing": missing.size(), "attempt": _snapshot_retry_count})


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
	var incoming_world_id := str(snapshot.get("world_id", world_id))
	if not world_id.is_empty() and not incoming_world_id.is_empty() and incoming_world_id != world_id:
		_stone_age_goal_state.clear()
		_mid_tier_tool_goal_state.clear()
		_stone_age_authoritative_inventory.clear()
		_stone_age_authoritative_equipment = {"hand": "", "feet": ""}
		_initial_loadout_source = ""
		_initial_inventory_request_msec = -1
		_initial_inventory_last_request_msec = -1
		_initial_inventory_echo_logged = false
		_action_started_before_inventory_echo = false
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
	if str(snapshot_generation.get("mode", "")).to_lower() == "one_block":
		var one_block_state: Dictionary = _world_snapshot.get("one_block", {}) if _world_snapshot.get("one_block", {}) is Dictionary else {}
		_live_one_block_mined = maxi(_live_one_block_mined, maxi(0, int(one_block_state.get("mined", 0))))
	elif str(snapshot_generation.get("mode", "")).to_lower() == "challenge_run":
		var challenge_state: Dictionary = _world_snapshot.get("challenge", {}) if _world_snapshot.get("challenge", {}) is Dictionary else {}
		_live_challenge_best_distance = maxi(_live_challenge_best_distance, maxi(0, int(challenge_state.get("best_distance", 0))))
	_rebuild_known_chunk_index(snapshot_generation.get("chunks", []))
	_rebuild_terrain_index(_world_snapshot.get("tiles", []))
	_rebuild_fluid_levels(_world_snapshot.get("fluids", []))
	_rebuild_plant_index(_world_snapshot.get("plant_growth", _world_snapshot.get("plants", [])))
	_seed_tree_growth_resources(_world_snapshot.get("tree_growth", []))
	if str(snapshot_generation.get("mode", "")).to_lower() == "duel":
		_seed_duel_fallback_terrain()
	world_id = incoming_world_id
	_load_structural_memory_world()
	_restore_protected_build_cells()
	var multiplayer_state: Dictionary = snapshot.get("multiplayer", {}) if snapshot.get("multiplayer", {}) is Dictionary else {}
	var player_states: Dictionary = multiplayer_state.get("player_states", {}) if multiplayer_state.get("player_states", {}) is Dictionary else {}
	# `player` is the host's local avatar in a P2P snapshot. A guest bot must
	# start from its own authoritative state in multiplayer.player_states or it
	# inherits the host coordinates and immediately falls through the terrain.
	var raw_authoritative_self: Variant = player_states.get(own_player_id, {})
	var has_authoritative_self_state := raw_authoritative_self is Dictionary and not (raw_authoritative_self as Dictionary).is_empty()
	var local_state: Dictionary = raw_authoritative_self as Dictionary if has_authoritative_self_state else {}
	if local_state.is_empty():
		local_state = snapshot.get("player", {}) if snapshot.get("player", {}) is Dictionary else {}
	else:
		var template: Dictionary = snapshot.get("player", {}) if snapshot.get("player", {}) is Dictionary else {}
		for field in ["w", "h", "max_health"]:
			if not local_state.has(field) and template.has(field):
				local_state[field] = template[field]
	# Keep the host-provided self state separate from the local spawn recovery
	# below. The planner may seed its return root only from an already-grounded
	# authoritative position, never from our locally normalized pose. If this
	# snapshot had no bot entry, the fallback `player` belongs to the host and is
	# intentionally not used as the bot's descent root.
	var descent_initial_self_state: Dictionary = local_state.duplicate(true) if has_authoritative_self_state else {}
	_roster.clear()
	for raw_id in player_states:
		var player_id := str(raw_id)
		if player_id == own_player_id or (dedicated_server and player_id == _host_player_id and not _is_pvp_world()):
			continue
		var player_state := player_states[raw_id] as Dictionary if player_states[raw_id] is Dictionary else {}
		player_state["id"] = player_id
		player_state["alive"] = int(player_state.get("health", 10)) > 0
		_roster[player_id] = player_state.duplicate(true)
	if _is_pvp_world() and _pvp_enemy_player_id.is_empty() and not _roster.is_empty():
		_pvp_enemy_player_id = str(_roster.keys()[0])
	if _is_pvp_world() and _roster.get(_pvp_enemy_player_id, null) is Dictionary:
		_remember_pvp_enemy(_pvp_enemy_player_id, _roster[_pvp_enemy_player_id] as Dictionary)
	# A guest that reconnects after the host has already started the duel will
	# not receive the one-shot `duel_start` control message. The host's world
	# snapshot is authoritative and only exists for an active game, so a duel
	# snapshot with another player is sufficient to restore the started state.
	# Waiting lobbies do not send a game snapshot and therefore remain safe.
	if _is_pvp_world() and snapshot_is_duel and not _roster.is_empty() and not _duel_started:
		_duel_started = true
		_record_event("duel_start_inferred", {"reason": "active_duel_snapshot"})
	var spawn_support_recovered := _stabilize_initial_supported_pose(local_state)
	_world_snapshot["self"] = local_state.duplicate(true)
	# Root-level inventory/equipment belong to the host avatar. A guest bot must
	# start empty unless its own multiplayer.player_states entry already exists:
	# never seed them from the fallback root `player` object.
	var inventory_self_state := own_authoritative_state(local_state, has_authoritative_self_state)
	_world_snapshot["inventory_summary"] = _inventory_summary_from_player_state(inventory_self_state)
	_stone_age_authoritative_inventory = (_world_snapshot["inventory_summary"] as Dictionary).duplicate(true)
	_inventory_host_revision = maxi(0, int(local_state.get("inventory_host_revision", 0)))
	_inventory_client_revision = maxi(_inventory_client_revision, int(local_state.get("inventory_client_revision", 0)))
	_world_snapshot["recipes"] = _recipe_catalog(_world_snapshot)
	_equipment_slots = _equipment_from_player_state(inventory_self_state)
	_stone_age_authoritative_equipment = _equipment_slots.duplicate(true)
	_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	_world_snapshot["craft_pending_output"] = _craft_pending_output
	_world_snapshot["craft_retry_after_msec"] = _craft_retry_after_msec
	_world_snapshot["craft_blocked_outputs"] = _active_craft_blocked_outputs(Time.get_ticks_msec())
	_world_snapshot["visible_resources"] = _visible_resources_from_tiles(_world_snapshot.get("tiles", []), local_state)
	_world_snapshot["visible_containers"] = _visible_containers_from_snapshot(_world_snapshot, local_state)
	_world_snapshot["threats"] = _threats_from_creatures(_world_snapshot.get("creatures", []))
	_session_world_mode = str(snapshot_generation.get("mode", _session_world_mode)).to_lower()
	var loadout_source := "own_player_state" if has_authoritative_self_state else "empty_fallback_no_own_state"
	if _initial_loadout_source != "own_player_state" and (_initial_loadout_source.is_empty() or has_authoritative_self_state):
		structured_log.emit({
			"event": "bot_initial_loadout",
			"world_id": world_id,
			"world_mode": _session_world_mode,
			"source": loadout_source,
			"inventory": (_world_snapshot.get("inventory_summary", {}) as Dictionary).duplicate(true),
			"equipment": _equipment_slots.duplicate(true),
			"at_msec": Time.get_ticks_msec(),
		})
		_initial_loadout_source = loadout_source
	_descent_planner.begin_session(
		session_id,
		world_id,
		_session_world_mode,
		_session_world_mode == "duel",
		_descent_one_block_source(),
	)
	_descent_snapshot_complete = true
	_descent_planner.observe_initial_snapshot(descent_initial_self_state, _descent_terrain_map(), _descent_coverage())
	_sync_stone_age_goal(_achievement_observation(), Time.get_ticks_msec())
	_sync_mid_tier_tool_goal(Time.get_ticks_msec())
	var initial_support := _support_tile_for_position(Contract.target_position(local_state))
	var initial_visible_containers: Array = _world_snapshot.get("visible_containers", []) if _world_snapshot.get("visible_containers", []) is Array else []
	structured_log.emit({
		"event": "snapshot_ready",
		"x": float(local_state.get("x", 0.0)),
		"y": float(local_state.get("y", 0.0)),
		"on_ground": bool(local_state.get("on_ground", false)),
		"support_x": initial_support.x,
		"support_y": initial_support.y,
		"support_block": _terrain_name_at(initial_support.x, initial_support.y),
		"terrain_tile_count": _terrain_tiles.size(),
		"visible_container_count": initial_visible_containers.size(),
		"generated_chest_count": _generated_chest_count(initial_visible_containers),
		"spawn_support_recovered": spawn_support_recovered,
		"at_msec": Time.get_ticks_msec(),
	})
	sync_complete = true
	_snapshot_transfer_id = ""
	_snapshot_expected_chunks = 0
	_snapshot_chunks.clear()
	_snapshot_retry_at_msec = -1
	_snapshot_retry_count = 0
	_update_human_count()
	structured_log.emit({"event": "snapshot_post_population", "at_msec": Time.get_ticks_msec()})
	_set_state(STATE_PLAYING)
	_maybe_strip_progression_gear()
	_send_inventory_snapshot()
	structured_log.emit({"event": "snapshot_inventory_request_sent", "at_msec": Time.get_ticks_msec()})
	_initial_inventory_request_msec = Time.get_ticks_msec()
	_initial_inventory_last_request_msec = _initial_inventory_request_msec
	_welcome_emoji_pending = human_player_count > 0
	_welcome_emoji_due_msec = Time.get_ticks_msec() + 900 if _welcome_emoji_pending else -1
	_send_duel_ready(Time.get_ticks_msec())
	behavior.request_decision(Time.get_ticks_msec())
	_sync_achievements_community_lock()
	_record_world_state_achievements()
	var initial_player_biomes: Dictionary = snapshot.get("player_biomes", {}) if snapshot.get("player_biomes", {}) is Dictionary else {}
	_record_authoritative_location_achievements(str(initial_player_biomes.get(own_player_id, "")), local_state)
	session_ready.emit(session_id, own_player_id)


func _stabilize_initial_supported_pose(local_state: Dictionary) -> bool:
	"""Normalize a newly joined guest onto nearby authoritative terrain.

	A P2P snapshot can briefly report on_ground=false or omit a new guest's
	state. This runs once, before PLAYING, and uses only the generic terrain map;
	it does not depend on a world mode or suppress later legitimate jumps.
	"""
	if local_state.is_empty() or _terrain_tiles.is_empty():
		return false
	var width := maxf(1.0, float(local_state.get("w", 20.0)))
	var height := maxf(1.0, float(local_state.get("h", 28.0)))
	if _local_pose_has_support(local_state):
		var support := _support_tile_for_position(Contract.target_position(local_state))
		var changed := not bool(local_state.get("on_ground", false)) or not is_zero_approx(float(local_state.get("vy", 0.0)))
		local_state["y"] = float(support.y * BlockDefs.TILE) - height
		local_state["vx"] = 0.0
		local_state["vy"] = 0.0
		local_state["on_ground"] = true
		return changed
	var origin := _support_tile_for_position(Contract.target_position(local_state))
	var best_tile := Vector2i(2147483647, 2147483647)
	var best_distance := INF
	const RECOVERY_RADIUS := 8
	for dy in range(-RECOVERY_RADIUS, RECOVERY_RADIUS + 1):
		for dx in range(-RECOVERY_RADIUS, RECOVERY_RADIUS + 1):
			var candidate := origin + Vector2i(dx, dy)
			if not _terrain_standable_tile(candidate):
				continue
			var candidate_position := _world_position_for_support_tile(candidate)
			var distance := Contract.target_position(local_state).distance_squared_to(candidate_position)
			if distance < best_distance:
				best_distance = distance
				best_tile = candidate
	if best_tile.x == 2147483647:
		return false
	var recovered_position := _world_position_for_support_tile(best_tile)
	local_state["x"] = recovered_position.x + (20.0 - width) * 0.5
	local_state["y"] = float(best_tile.y * BlockDefs.TILE) - height
	local_state["vx"] = 0.0
	local_state["vy"] = 0.0
	local_state["on_ground"] = true
	return true


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


## The root `player` object of a world snapshot is the host avatar. A guest bot
## may adopt inventory/equipment only from an authoritative
## `multiplayer.player_states` row for its own player id; the fallback host
## avatar must never seed them.
static func own_authoritative_state(local_state: Dictionary, has_authoritative_self_state: bool) -> Dictionary:
	return local_state if has_authoritative_self_state else {}


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
		var name := _canonical_inventory_name(key)
		if name.is_empty():
			name = key
		if not name.is_empty():
			result[name] = int(result.get(name, 0)) + amount
	return result


func _canonical_inventory_name(key: String) -> String:
	# Older Android hosts serialize system-tree blocks with the pre-1.4.5
	# generated hash name. Retain that wire name for inventory snapshots, but
	# use the stable tree name in all bot goals and recipe decisions.
	for content_id in BlockDefs.CORE_TREE_CONTENT_IDS:
		var canonical := str(content_id).trim_prefix("core.")
		if key == "generated_%s" % str(content_id).sha256_text().substr(0, 12):
			_host_tree_inventory_names[canonical] = key
			return canonical
	var resolved := _block_name_for_content_id(key)
	return resolved if not resolved.is_empty() else key


func _host_inventory_wire_names(inventory: Dictionary) -> Dictionary:
	var result := {}
	for raw_name in inventory:
		var name := str(raw_name)
		var wire_name := str(_host_tree_inventory_names.get(name, name))
		result[wire_name] = int(result.get(wire_name, 0)) + int(inventory[raw_name])
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
	# Mirror WorldSim.get_all_recipes(): collectible, non-sapient creatures of a
	# useful size can be prepared at a nearby furnace. Without this dynamic part
	# the bot could own food ingredients yet never know a meal recipe existed.
	var defs := get_node_or_null("/root/BlockDefs")
	var blocks: Dictionary = defs.get("BLOCKS") if defs != null and defs.get("BLOCKS") is Dictionary else {}
	for raw_name in blocks:
		var block_name := str(raw_name)
		if _creature_can_be_prepared_as_meal(block_name):
			result.append({
				"in": {block_name: 1},
				"out": {"prepared_meal": 1},
				"station": "furnace",
				"station_available": _station_available(snapshot, "furnace"),
			})
	return result


func _creature_can_be_prepared_as_meal(block_name: String) -> bool:
	var entry := _block_entry(block_name)
	if not bool(entry.get("creature_item", false)):
		return false
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	if "sapient" in (definition.get("tags", []) as Array):
		return false
	var stats: Dictionary = definition.get("stats", {}) if definition.get("stats", {}) is Dictionary else {}
	return float(stats.get("size", 0.0)) >= MIN_PREPARED_MEAL_CREATURE_SIZE


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
	var self_state: Dictionary = snapshot.get("self", {}) if snapshot.get("self", {}) is Dictionary else {}
	var center := Vector2i(
		floori((float(self_state.get("x", 0.0)) + float(self_state.get("w", 20.0)) * 0.5) / float(BlockDefs.TILE)),
		floori((float(self_state.get("y", 0.0)) + float(self_state.get("h", 28.0)) * 0.5) / float(BlockDefs.TILE)),
	)
	for tile_y in range(center.y - STATION_RADIUS_TILES, center.y + STATION_RADIUS_TILES + 1):
		for tile_x in range(center.x - STATION_RADIUS_TILES, center.x + STATION_RADIUS_TILES + 1):
			var name := str(_terrain_tiles.get("%d:%d" % [tile_x, tile_y], ""))
			if not name.is_empty() and str(_block_entry(name).get("station", "")) == station:
				return true
	return false


func _apply_players_snapshot(payload: Dictionary) -> void:
	var players: Dictionary = payload.get("players", {}) if payload.get("players", {}) is Dictionary else {}
	var player_biomes: Dictionary = payload.get("player_biomes", {}) if payload.get("player_biomes", {}) is Dictionary else {}
	if payload.has("world_underfoot_waypoints") and payload.get("world_underfoot_waypoints") is Dictionary:
		# The host only advertises already-generated safe surface cells. Keep the
		# authoritative map with the latest world state; the bot still validates
		# local terrain and physics reachability before choosing a destination.
		_world_snapshot["world_underfoot_waypoints"] = (payload["world_underfoot_waypoints"] as Dictionary).duplicate(true)
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
			# collision dimensions from the initial snapshot, and only predict a jump
			# until the host confirms that the avatar actually left the ground.
			var local_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
			var host_revision := int(entry.get("respawn_revision", local_state.get("respawn_revision", 0)))
			var local_revision := int(local_state.get("respawn_revision", 0))
			var respawned := host_revision > local_revision
			var local_position := Contract.target_position(local_state)
			var host_position := Contract.target_position(entry)
			var motion_diverged := (
				entry.has("x")
				and entry.has("y")
					and local_position.distance_to(host_position) > MAX_AUTHORITATIVE_MOTION_DIVERGENCE
			)
			var host_grounded := entry.has("on_ground") and bool(entry.get("on_ground", false))
			# Roster snapshots can echo the grounded takeoff pose after a jump has
			# already started locally. Air beneath a rising avatar is expected, not
			# proof of a floating predictor. Wait one bounded jump/snapshot window
			# before treating that *takeoff* echo as a rejected transition; a host
			# pose on the actual landing tile is still reconciled immediately.
			var fresh_takeoff_echo := false
			if host_grounded and _jump_active and _jump_started_msec >= 0 and not _active_air_transition.is_empty():
				var jump_age := Time.get_ticks_msec() - _jump_started_msec
				var takeoff_tile: Vector2i = _active_air_transition.get("from", Vector2i(2147483647, 2147483647))
				if takeoff_tile.x != 2147483647 and jump_age >= 0 and jump_age < HOST_JUMP_ECHO_GRACE_MSEC:
					var echo_tile := _support_tile_for_position(host_position)
					var takeoff_y := float(takeoff_tile.y * BlockDefs.TILE) - float(local_state.get("h", 28.0))
					fresh_takeoff_echo = (
						abs(echo_tile.x - takeoff_tile.x) <= 1
						and echo_tile.y == takeoff_tile.y
						and (not _jump_predicted_landed or echo_tile == takeoff_tile)
						and (
							_jump_predicted_landed
							or (
								not bool(local_state.get("on_ground", false))
								and local_position.y < takeoff_y - 1.0
								and local_position.y >= takeoff_y - float(BlockDefs.TILE) * 4.0
							)
						)
						and absf(local_position.x - _jump_start_x) <= float(BlockDefs.TILE) * 3.0
						and local_position.distance_to(host_position) <= float(BlockDefs.TILE) * 5.0
					)
			if fresh_takeoff_echo:
				motion_diverged = false
			# The private jump/climb predictor can be left hovering over a cell the
			# authoritative terrain proves has nothing to stand on - its support was
			# mined away, or the host never reproduced the landing. The grounded
			# rejection above cannot catch that because the host may report the own
			# avatar airborne. When the host pose itself sits on authoritative
			# support, that pose wins: reseat and end the local arc instead of
			# floating at an unsupported tile. Fluid and climbable cells are
			# legitimate support, so they never trigger this.
			var host_support_reseat := false
			var host_support_tile := Vector2i(2147483647, 2147483647)
			if entry.has("x") and entry.has("y") and (_jump_active or _climb_active):
				var local_support_tile := _support_tile_for_position(local_position)
				host_support_tile = _support_tile_for_position(host_position)
				var local_support_verdict := _authoritative_support_verdict(local_support_tile)
				var host_support_verdict := _authoritative_support_verdict(host_support_tile)
				var support_tile_separation := maxi(
					absi(local_support_tile.x - host_support_tile.x),
					absi(local_support_tile.y - host_support_tile.y),
				)
				host_support_reseat = (
					local_support_verdict == "unsupported"
					and host_support_verdict == "supported"
					and not fresh_takeoff_echo
					# A one-cell support-row change is a normal jump/step transition;
					# only reseat when the predictor is more than one cell off.
					and support_tile_separation > 1
				)
			# A grounded host pose can confirm that a jump reached a valid nearby
			# landing before the private arc has caught up. Treat that as a landing
			# reconciliation, not a rejected transition/cooldown. Live Android
			# snapshots showed this echo just 3.7 px beyond the old distance cutoff.
			var host_confirmed_near_landing := false
			if host_grounded and not fresh_takeoff_echo and entry.has("x") and entry.has("y") and _jump_active and not _active_air_transition.is_empty():
				var landing_tile: Vector2i = _active_air_transition.get("to", Vector2i(2147483647, 2147483647))
				if landing_tile.x != 2147483647:
					var host_tile := _support_tile_for_position(host_position)
					var tile_distance := maxi(absi(host_tile.x - landing_tile.x), absi(host_tile.y - landing_tile.y))
					var landing_position := _world_position_for_support_tile(landing_tile)
					var intended_dx := landing_position.x - _jump_start_x
					var host_dx := host_position.x - _jump_start_x
					host_confirmed_near_landing = (
						tile_distance <= 1
						and host_tile != _active_air_transition.get("from", Vector2i(2147483647, 2147483647))
						and absf(intended_dx) > 0.001
						and absf(host_dx) >= 8.0
						and intended_dx * host_dx > 0.0
						and absf(float(entry.get("vx", 0.0))) <= 0.05
						and (
							_jump_predicted_landed
							or local_position.distance_to(host_position) > HOST_GROUNDED_AIR_REJECTION_TOLERANCE
						)
						and _authoritative_support_verdict(host_tile) in ["supported", "fluid"]
					)
			# A support reseat normally just reconciles stale local terrain. If the
			# authoritative host is still grounded on the transition's takeoff tile
			# after the bounded jump echo grace, though, the host never accepted that
			# jump edge. Cool it down so route planning can choose another edge.
			# Keep nearby confirmed landings and fresh takeoff echoes out of this path.
			var host_rejected_transition_at_source := false
			if (
				host_grounded
				and host_support_reseat
				and not fresh_takeoff_echo
				and not host_confirmed_near_landing
				and _jump_active
				and _jump_started_msec >= 0
				and not _active_air_transition.is_empty()
			):
				var transition_from: Vector2i = _active_air_transition.get("from", Vector2i(2147483647, 2147483647))
				var transition_to: Vector2i = _active_air_transition.get("to", Vector2i(2147483647, 2147483647))
				var transition_age := Time.get_ticks_msec() - _jump_started_msec
				host_rejected_transition_at_source = (
					transition_from.x != 2147483647
					and transition_from != transition_to
					and host_support_tile == transition_from
					and transition_age >= HOST_JUMP_ECHO_GRACE_MSEC
				)
			# When terrain proves the local predicted support is absent and the host
			# pose is on support, this is a stale local arc, not evidence that the
			# intended edge was rejected. Reseat without poisoning the transition.
			var host_rejected_air_motion: bool = (
				host_grounded
				and not fresh_takeoff_echo
				and (not host_support_reseat or host_rejected_transition_at_source)
				and not host_confirmed_near_landing
				and (
					local_position.distance_to(host_position) > HOST_GROUNDED_AIR_REJECTION_TOLERANCE
					or (
						_jump_predicted_landed
						and _jump_started_msec >= 0
						and Time.get_ticks_msec() - _jump_started_msec >= HOST_JUMP_ECHO_GRACE_MSEC
						and host_support_tile == _active_air_transition.get("from", Vector2i(2147483647, 2147483647))
					)
				)
				and (
					_jump_active
					or (_climb_active and not bool(entry.get("climbing", false)) and not bool(entry.get("tree_ghost", false)))
				)
			)
			var reconcile_motion := (
				respawned
				or motion_diverged
				or host_rejected_air_motion
				or host_support_reseat
				or host_confirmed_near_landing
				or (not _jump_active and not _climb_active)
			)
			if motion_diverged or host_rejected_air_motion or host_support_reseat or host_confirmed_near_landing:
				# Never let a host-rejected jump/climb leave the local predictor
				# airborne. Even a small drift matters here: continuing the private
				# arc makes later plans target terrain the authoritative avatar never
				# reached, eventually causing snap-backs and apparent floating.
				if host_rejected_air_motion and not _active_air_transition.is_empty():
					var transition_from: Vector2i = _active_air_transition.get("from", Vector2i(2147483647, 2147483647))
					var transition_to: Vector2i = _active_air_transition.get("to", Vector2i(2147483647, 2147483647))
					if transition_from != transition_to and transition_from.x != 2147483647:
						var transition_key := _physics_transition_key(transition_from, transition_to)
						var retry_after_msec := Time.get_ticks_msec() + HOST_REJECTED_TRANSITION_COOLDOWN_MSEC
						_host_rejected_transitions[transition_key] = retry_after_msec
						_host_rejected_transition_from = transition_from
						_host_rejected_transition_until_msec = retry_after_msec
						_safe_exploration_waypoint_cache_checked_msec = -1
						structured_log.emit({
							"event": "host_rejected_air_transition",
							"from": [transition_from.x, transition_from.y],
							"to": [transition_to.x, transition_to.y],
							"retry_after_msec": retry_after_msec,
							"at_msec": Time.get_ticks_msec(),
						})
				_active_air_transition.clear()
				_jump_active = false
				_jump_predicted_landed = false
				_jump_started_msec = -1
				_climb_active = false
				_physics_route.clear()
				_physics_route_replan_msec = 0
				_set_desired_input(false, false, false)
				var recovery_reason := "distance_diverged"
				if host_confirmed_near_landing:
					recovery_reason = "host_confirmed_transition_landing"
				elif host_rejected_air_motion:
					recovery_reason = "host_rejected_air_motion"
				elif host_support_reseat:
					recovery_reason = "local_support_unsupported"
				structured_log.emit({
					"event": "authoritative_motion_recovered",
					"reason": recovery_reason,
					"local_x": local_position.x,
					"local_y": local_position.y,
					"host_x": host_position.x,
					"host_y": host_position.y,
					"distance": local_position.distance_to(host_position),
					"at_msec": Time.get_ticks_msec(),
				})
			if respawned:
				_handle_confirmed_respawn(Time.get_ticks_msec())
				_was_in_harmful_fluid = false
				_harmful_fluid_damage_cooldown = 0.0
				_guest_defeat_pending = false
				_jump_active = false
				_jump_predicted_landed = false
				_jump_started_msec = -1
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
			if entry.has("x") and entry.has("y") and entry.has("on_ground"):
				_descent_planner.set_world_context(
					_session_world_mode,
					_session_world_mode == "duel",
					_descent_one_block_source(),
				)
				_descent_planner.observe_authoritative_position(entry, _descent_terrain_map(), _descent_coverage())
			_record_live_challenge_distance(entry)
			_record_authoritative_location_achievements(str(player_biomes.get(player_id, "")), entry)
			continue
		if dedicated_server and player_id == _host_player_id and not _is_pvp_world():
			continue
		entry["id"] = player_id
		entry["alive"] = int(entry.get("health", 10)) > 0
		_roster[player_id] = entry
	if _is_pvp_world() and _pvp_enemy_player_id.is_empty() and not _roster.is_empty():
		_pvp_enemy_player_id = str(_roster.keys()[0])
	if _is_pvp_world() and _roster.get(_pvp_enemy_player_id, null) is Dictionary:
		_remember_pvp_enemy(_pvp_enemy_player_id, _roster[_pvp_enemy_player_id] as Dictionary)
	else:
		_retain_last_known_pvp_enemy()
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
		if entry.size() > 13:
			creature["damage"] = maxi(0, int(entry[13]))
		if entry.size() > 14:
			creature["temperament"] = str(entry[14])
		if entry.size() > 15:
			creature["attack_trigger"] = str(entry[15])
		if entry.size() > 16:
			creature["awareness_blocks"] = clampf(float(entry[16]), 1.0, 16.0)
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


func _send_inventory_snapshot(increment_revision: bool = true) -> void:
	if network_client == null or not network_client.has_method("send_command"):
		return
	var inventory: Dictionary = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	var wire_inventory := _host_inventory_wire_names(inventory)
	# Hosts reject guest snapshots whose host revision does not match the last
	# acknowledged inventory_host_revision. Sending 0 forever made every post-mine
	# craft/eat snapshot bounce, leaving the bot stuck retrying CRAFT planks.
	if increment_revision:
		_inventory_client_revision += 1
	network_client.call("send_command", "inventory_snapshot", {
		"inventory_host_revision": _inventory_host_revision,
		"inventory_client_revision": _inventory_client_revision,
		"inventory": wire_inventory,
		"item_durability": {},
		"footwear_wear_distance": 0.0,
		"inventory_order": wire_inventory.keys(),
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
		var name := _canonical_inventory_name(key)
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
	_stone_age_authoritative_inventory = normalized.duplicate(true)
	if payload.has("inventory_host_revision"):
		_inventory_host_revision = maxi(0, int(payload.get("inventory_host_revision", 0)))
	if payload.has("inventory_client_revision"):
		_inventory_client_revision = maxi(_inventory_client_revision, int(payload.get("inventory_client_revision", 0)))
	var incoming_equipment: Dictionary = payload.get("equipment_slots", _equipment_slots).duplicate(true) if payload.get("equipment_slots", _equipment_slots) is Dictionary else _equipment_slots.duplicate(true)
	if payload.has("equipment_slots") and payload.get("equipment_slots") is Dictionary:
		_stone_age_authoritative_equipment = _equipment_from_player_state({"equipment_slots": payload.get("equipment_slots", {})})
	_equipment_slots = _merge_equipment_with_pending(incoming_equipment, normalized)
	_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
	if not _initial_inventory_echo_logged:
		_initial_inventory_echo_logged = true
		structured_log.emit({
			"event": "bot_initial_inventory_echo",
			"world_id": world_id,
			"world_mode": _session_world_mode,
			"snapshot_source": _initial_loadout_source,
			"action_started_before_echo": _action_started_before_inventory_echo,
			"inventory": normalized.duplicate(true),
			"equipment": _stone_age_authoritative_equipment.duplicate(true),
			"at_msec": Time.get_ticks_msec(),
		})
	if payload.has("nourishment"):
		var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
		var current := clampi(int(self_state.get("nourishment", 100)), 0, 100)
		var incoming := clampi(int(payload.get("nourishment", 100)), 0, 100)
		# Keep a just-eaten local increase until the host catches up; still accept
		# higher host values and never let a stale echo undo a successful bite.
		self_state["nourishment"] = maxi(current, incoming)
		_world_snapshot["self"] = self_state
	if not _craft_pending_output.is_empty() and int(normalized.get(_craft_pending_output, 0)) > 0:
		_record_craft_achievement(_craft_pending_output)
		_craft_blocked_outputs.erase(_craft_pending_output)
		_craft_pending_output = ""
		_craft_retry_after_msec = Time.get_ticks_msec() + CRAFT_RETRY_DELAY_MSEC
	var now_msec := Time.get_ticks_msec()
	_sync_stone_age_goal(_achievement_observation(), now_msec)
	_sync_mid_tier_tool_goal(now_msec)


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
	elif output_name == "furnace":
		if int(next.get("cobblestone", 0)) < 4:
			return false
		next["cobblestone"] = int(next.get("cobblestone", 0)) - 4
		if int(next["cobblestone"]) <= 0:
			next.erase("cobblestone")
		next["furnace"] = int(next.get("furnace", 0)) + 1
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
	var excluded_ids: Array = [_host_player_id] if dedicated_server and not _host_player_id.is_empty() else []
	var next_count := Perception.count_live_humans(_roster, own_player_id, excluded_ids, dedicated_server)
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
	var probe_start := Time.get_ticks_msec()
	if _first_observation_probe_pending:
		structured_log.emit({"event": "first_observation_started", "at_msec": probe_start, "terrain_tile_count": _terrain_tiles.size()})
	_expire_stale_action_targets(now_msec)
	_expire_stone_age_pending(now_msec)
	_expire_achievement_goal_pending(now_msec)
	_sync_stone_age_goal(_achievement_observation(), now_msec)
	_sync_mid_tier_tool_goal(now_msec)
	var snapshot := _world_snapshot.duplicate(true)
	snapshot["self"] = snapshot.get("self", {"health": 10, "x": 0.0, "y": 0.0})
	snapshot["own_player_id"] = own_player_id
	snapshot["players"] = _roster.values()
	snapshot["recent_events"] = _recent_events.duplicate(true)
	snapshot["emoji_events"] = _active_emoji_events(now_msec)
	snapshot["action_history"] = _action_history.duplicate(true)
	snapshot["protected_build_cells"] = _protected_build_cells.duplicate(true)
	snapshot["opened_generated_chest_cells"] = _opened_generated_chest_cells.duplicate(true)
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
	snapshot["terrain_known_cells"] = _terrain_known_cell_window(snapshot["self"] as Dictionary)
	snapshot["lava_retreat_required"] = _update_lava_retreat_state(snapshot["self"] as Dictionary)
	snapshot["safe_exploration_waypoints"] = _safe_exploration_waypoints(snapshot["self"] as Dictionary)
	# Station availability changes when the bot places a workbench/furnace or
	# walks out of its radius, so recipes cannot remain frozen at join time.
	snapshot["recipes"] = _recipe_catalog(snapshot)
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
	snapshot["world_mode"] = str(generation.get("mode", _session_world_mode)).to_lower()
	_sync_build_project_scope(str(snapshot["world_mode"]), now_msec)
	snapshot["build_project_state"] = _build_project_state.duplicate(true)
	_descent_planner.set_world_context(
		str(snapshot["world_mode"]),
		str(snapshot["world_mode"]) == "duel",
		_descent_one_block_source(),
	)
	_descent_last_plan = _descent_planner.plan_next(
		snapshot["self"] as Dictionary,
		_descent_terrain_map(),
		_descent_coverage(),
	)
	if bool(_descent_last_plan.get("eligible", false)) and str(_descent_last_plan.get("phase", "")) == "move" and not _projected_descent_return_leg_is_executable(_descent_last_plan, snapshot["self"] as Dictionary):
		# The descent planner proves a static support-graph route. Before taking
		# the next lower step, also prove that ordinary player controls can make
		# its first return jump from the *future* landing. A geometric staircase
		# is not a safe exit when water/ceiling/collision blocks that jump arc.
		_descent_last_plan["eligible"] = false
		_descent_last_plan["verified_safe_exit"] = false
		_descent_last_plan["reason"] = "return_jump_unexecutable"
	snapshot["descent_plan"] = _descent_last_plan.duplicate(true)
	snapshot["verified_safe_exit"] = bool(_descent_last_plan.get("eligible", false)) and bool(_descent_last_plan.get("verified_safe_exit", false))
	snapshot["descent_protected_supports"] = (_descent_last_plan.get("protected_supports", []) as Array).duplicate(true)
	snapshot["biome_waypoints"] = _reachable_world_underfoot_waypoints(snapshot)
	var mode_progress := _mode_progress_from_snapshot()
	var regenerating_block := _regenerating_block_observation()
	if regenerating_block.is_empty():
		snapshot.erase("regenerating_block")
	else:
		snapshot["regenerating_block"] = regenerating_block
	snapshot["pvp_world"] = _is_pvp_world()
	snapshot["duel_started"] = _duel_started
	snapshot["pvp_chest_opened"] = _pvp_chest_opened
	snapshot["enemy_player_id"] = _enemy_player_id()
	snapshot["aggressive_player_id"] = _aggressive_player_id
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
	var perception_radius := maxf(observation_radius, 4096.0) if _is_pvp_world() else _decision_observation_radius()
	var observation := Perception.build(snapshot, own_player_id, perception_radius, now_msec)
	# Perception.build whitelists keys, so attach transaction state to the final
	# policy observation rather than only to the intermediate snapshot.
	observation["host_confirmed_inventory_summary"] = _stone_age_authoritative_inventory.duplicate(true)
	var placement_pending := false
	for raw_pending in _pending_action_targets.values():
		if raw_pending is Dictionary and str((raw_pending as Dictionary).get("action", "")) == Contract.ACTION_PLACE:
			placement_pending = true
			break
	observation["placement_pending"] = placement_pending
	var source_material_catalog := _one_block_source_material_catalog()
	if not source_material_catalog.is_empty():
		observation["source_material_catalog"] = source_material_catalog
	# The progression policy needs to know whether moving toward a player can
	# expose terrain outside the area already scanned for starter wood.
	observation["resource_scan_radius"] = _decision_observation_radius() if _stone_age_gathering_wood() else 0.0
	# Perception.build whitelists its keys, so attach the mode-scoped maximums
	# here for the decision provider: 0 outside their mode, world_mode disambiguates.
	observation["one_block_mined"] = int(mode_progress.get("one_block_mined", 0))
	observation["challenge_best_distance"] = int(mode_progress.get("challenge_best_distance", 0))
	# Placement retries recorded on the host rejection/timeout paths are only
	# useful to policy if the cooled tiles travel with the observation.
	observation["blocked_action_targets"] = _active_blocked_action_targets(now_msec)
	observation["stone_age_goal"] = _stone_age_goal_state.duplicate(true)
	observation["mid_tier_tool_goal"] = _mid_tier_tool_goal_state.duplicate(true)
	observation["achievement_goal_states"] = _achievement_goal_states.duplicate(true)
	observation["build_project_state"] = _build_project_state.duplicate(true)
	if str(snapshot.get("world_mode", "")) == "floating_islands":
		var island_layout: Variant = generation.get("floating_islands", [])
		if island_layout is Array:
			# The layout was supplied by the authoritative host. Policy sees only
			# island geometry, never a guessed biome from raw coordinates.
			observation["floating_islands"] = (island_layout as Array).duplicate(true)
			observation["visited_floating_islands"] = _visited_floating_islands.duplicate(true)
	_annotate_active_build_project_route(observation, now_msec)
	if _first_observation_probe_pending:
		_first_observation_probe_pending = false
		structured_log.emit({"event": "first_observation_finished", "at_msec": Time.get_ticks_msec(), "duration_msec": Time.get_ticks_msec() - probe_start})
	return observation


## The bundled One Block phase table describes normal sources before
## Afterphase. Include block rolls and chest loot/gifts: an item need not be a
## mined block to be an attainable recipe ingredient. The snapshot's generator
## marker must match before this local model can prove absence; on an
## older/unknown host the list is advisory and policy keeps exploring.
func _one_block_source_material_catalog() -> Dictionary:
	var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	if str(generation.get("mode", _session_world_mode)).to_lower() != "one_block":
		return {}
	var phases: Array = WorldScriptResource.ONE_BLOCK_PHASES if WorldScriptResource.ONE_BLOCK_PHASES is Array else []
	if phases.is_empty():
		return {}
	var materials: Dictionary = {}
	var currently_available: Dictionary = {}
	var complete := true
	var source_state: Dictionary = _world_snapshot.get("one_block", {}) if _world_snapshot.get("one_block", {}) is Dictionary else {}
	var mined := maxi(0, int(source_state.get("mined", _live_one_block_mined)))
	var current_phase := clampi(int(source_state.get("phase", _one_block_phase_for_mined(mined))), 0, phases.size())
	for phase_index in phases.size():
		var raw_phase: Variant = phases[phase_index]
		if not raw_phase is Dictionary:
			complete = false
			continue
		var phase := raw_phase as Dictionary
		var blocks: Dictionary = phase.get("blocks", {}) if phase.get("blocks", {}) is Dictionary else {}
		var gift: Dictionary = phase.get("gift", {}) if phase.get("gift", {}) is Dictionary else {}
		var loot: Array = phase.get("loot", []) if phase.get("loot", []) is Array else []
		for raw_content_id in blocks.keys() + gift.keys() + loot:
			var content_id := str(raw_content_id)
			var material := _block_name_for_content_id(content_id)
			if material.is_empty() and content_id.begins_with("core.plant."):
				# Core plants are generated definitions; headless bot-only builds do
				# not necessarily register them through a WorldSim instance.
				material = "generated_%s" % content_id.sha256_text().substr(0, 12)
			if material.is_empty():
				complete = false
			else:
				materials[material] = true
				if phase_index <= current_phase:
					currently_available[material] = true
	var names: Array = materials.keys()
	names.sort()
	var available_names: Array = currently_available.keys()
	available_names.sort()
	var generation_version := str(generation.get("generator_version", "")).strip_edges()
	return {
		"materials": names,
		"available_materials": available_names,
		"phase": current_phase,
		"authoritative": complete and current_phase < phases.size() and not generation_version.is_empty() and generation_version == str(WorldScriptResource.GENERATOR_VERSION),
		"source": "one_block_phases",
	}


func _one_block_phase_for_mined(mined: int) -> int:
	for index in WorldScriptResource.ONE_BLOCK_PHASES.size():
		if mined < int(WorldScriptResource.ONE_BLOCK_PHASES[index].get("end", 0)):
			return index
	return WorldScriptResource.ONE_BLOCK_PHASES.size()


func _annotate_active_build_project_route(observation: Dictionary, now_msec: int = -1) -> void:
	var project: Dictionary = observation.get("build_project_state", {}) if observation.get("build_project_state", {}) is Dictionary else {}
	if str(project.get("status", "")) != "active" or str(project.get("target_kind", "")) != "player":
		_build_project_route_cache_key = ""
		_build_project_route_checked_msec = -1
		_build_project_route_reachable = false
		return
	var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
	var target_id := str(project.get("target_id", ""))
	if target_id.is_empty():
		return
	var players: Array = observation.get("players", []) if observation.get("players", []) is Array else []
	var self_state: Dictionary = observation.get("self", {}) if observation.get("self", {}) is Dictionary else {}
	var origin_tile := _route_origin_support_tile(Contract.target_position(self_state), self_state)
	var preferred_distance := float(observation.get("preferred_player_distance", 84.0))
	for index in range(players.size()):
		if not players[index] is Dictionary:
			continue
		var player: Dictionary = players[index]
		if str(player.get("id", "")) != target_id:
			continue
		if float(player.get("distance", INF)) > preferred_distance:
			_build_project_route_cache_key = ""
			_build_project_route_checked_msec = -1
			_build_project_route_reachable = false
			player["route_reachable"] = false
			players[index] = player
			observation["players"] = players
			return
		var target_tile := _support_tile_for_position(Contract.target_position(player))
		var cache_key := "%s|%s|%s|%s|%d:%d>%d:%d" % [world_id, session_id, str(project.get("id", "")), target_id, origin_tile.x, origin_tile.y, target_tile.x, target_tile.y]
		if cache_key != _build_project_route_cache_key or _build_project_route_checked_msec < 0 or now - _build_project_route_checked_msec >= BUILD_PROJECT_ROUTE_REPLAN_MSEC:
			var first_step_allowed := _safe_jump_first_step_filter(self_state)
			var later_step_allowed := _safe_jump_later_step_filter(self_state)
			var route := Navigator.physics_route(
				origin_tile,
				target_tile,
				Callable(self, "_terrain_standable_tile"),
				Callable(self, "_terrain_climbable_tile"),
				Navigator.MAX_PHYSICS_ROUTE_NODES,
				Callable(self, "_physics_transition_allowed"),
				first_step_allowed,
				later_step_allowed,
			)
			_build_project_route_reachable = not route.is_empty() and Vector2i((route.back() as Dictionary).get("tile", origin_tile)) == target_tile
			_build_project_route_cache_key = cache_key
			_build_project_route_checked_msec = now
		player["route_reachable"] = _build_project_route_reachable
		players[index] = player
		observation["players"] = players
		return
	_build_project_route_cache_key = ""
	_build_project_route_checked_msec = -1
	_build_project_route_reachable = false


func _reachable_world_underfoot_waypoints(snapshot: Dictionary) -> Array[Dictionary]:
	if str(snapshot.get("world_mode", "")).to_lower() != "procedural":
		return []
	var all_waypoints: Dictionary = snapshot.get("world_underfoot_waypoints", {}) if snapshot.get("world_underfoot_waypoints", {}) is Dictionary else {}
	var own_waypoints: Variant = all_waypoints.get(own_player_id, [])
	if not own_waypoints is Array:
		return []
	var self_state: Dictionary = snapshot.get("self", {}) if snapshot.get("self", {}) is Dictionary else {}
	var origin_position := Contract.target_position(self_state)
	var origin_tile := _route_origin_support_tile(origin_position, self_state)
	var reachable: Array[Dictionary] = []
	for raw_waypoint in own_waypoints:
		if not raw_waypoint is Dictionary:
			continue
		var waypoint := raw_waypoint as Dictionary
		var biome_id := str(waypoint.get("biome_id", "")).strip_edges().to_lower()
		if biome_id.is_empty() or not waypoint.has("x") or not waypoint.has("y"):
			continue
		# Host x/y are support-tile coordinates (the solid tile directly beneath
		# a standing player), matching BotNavigator's physics-route contract.
		var target_tile := Vector2i(int(waypoint.get("x", 0)), int(waypoint.get("y", 0)))
		if not _terrain_standable_tile(target_tile):
			continue
		var first_step_allowed := _safe_jump_first_step_filter(self_state)
		var later_step_allowed := _safe_jump_later_step_filter(self_state)
		var route := Navigator.physics_route(
			origin_tile,
			target_tile,
			Callable(self, "_terrain_standable_tile"),
			Callable(self, "_terrain_climbable_tile"),
			Navigator.MAX_PHYSICS_ROUTE_NODES,
			Callable(self, "_physics_transition_allowed"),
			first_step_allowed,
			later_step_allowed,
		)
		if route.is_empty() or Vector2i((route.back() as Dictionary).get("tile", origin_tile)) != target_tile:
			continue
		var target_position := _world_position_for_support_tile(target_tile)
		var candidate := waypoint.duplicate(true)
		candidate["biome_id"] = biome_id
		candidate["tile_x"] = target_tile.x
		candidate["tile_y"] = target_tile.y
		candidate["support_tile"] = [target_tile.x, target_tile.y]
		candidate["position"] = [target_position.x, target_position.y]
		candidate["distance"] = origin_position.distance_to(target_position)
		candidate["route_steps"] = maxi(0, route.size() - 1)
		candidate["reachable"] = true
		reachable.append(candidate)
	return reachable


func _safe_exploration_waypoints(self_state: Dictionary) -> Array[Dictionary]:
	if _terrain_tiles.is_empty():
		return []
	var origin := Contract.target_position(self_state)
	var origin_tile := _route_origin_support_tile(origin, self_state)
	var first_step_allowed := _safe_jump_first_step_filter(self_state)
	var later_step_allowed := _safe_jump_later_step_filter(self_state)
	var state_signature := "%.1f:%.1f:%.1f:%.1f" % [
		float(self_state.get("x", origin.x)),
		float(self_state.get("y", origin.y)),
		float(self_state.get("w", 20.0)),
		float(self_state.get("h", 28.0)),
	]
	var now := Time.get_ticks_msec()
	if (
		origin_tile == _safe_exploration_waypoint_cache_origin
		and state_signature == _safe_exploration_waypoint_cache_state_signature
		and _safe_exploration_waypoint_cache_checked_msec >= 0
		and now - _safe_exploration_waypoint_cache_checked_msec < 450
	):
		return _safe_exploration_waypoint_cache.duplicate(true)
	var reachable := Navigator.physics_roundtrip_first_steps(
		origin_tile,
		Callable(self, "_terrain_standable_tile"),
		Callable(self, "_terrain_climbable_tile"),
		Navigator.MAX_PHYSICS_ROUTE_NODES,
		Callable(self, "_physics_transition_allowed"),
		first_step_allowed,
		later_step_allowed,
	)
	var result: Array[Dictionary] = []
	var max_horizontal_tiles := ceili(STARTER_TOOLING_RESOURCE_SCAN_RADIUS / float(BlockDefs.TILE))
	for raw_tile in reachable:
		if typeof(raw_tile) != TYPE_VECTOR2I:
			continue
		var tile: Vector2i = raw_tile
		if tile == origin_tile or abs(tile.x - origin_tile.x) > max_horizontal_tiles:
			continue
		var route_info: Dictionary = reachable.get(raw_tile, {}) if reachable.get(raw_tile, {}) is Dictionary else {}
		var position := _world_position_for_support_tile(tile)
		result.append({
			"support_tile": [tile.x, tile.y],
			"position": [position.x, position.y],
			"route_steps": int(route_info.get("steps", 0)),
			"reachable": true,
		})
	_safe_exploration_waypoint_cache = result
	_safe_exploration_waypoint_cache_origin = origin_tile
	_safe_exploration_waypoint_cache_checked_msec = now
	_safe_exploration_waypoint_cache_state_signature = state_signature
	return result.duplicate(true)


func _projected_descent_return_leg_is_executable(plan: Dictionary, self_state: Dictionary) -> bool:
	var raw_next: Variant = plan.get("next_support", [])
	var raw_route: Variant = plan.get("projected_return_route", [])
	if not raw_next is Array or (raw_next as Array).size() < 2 or not raw_route is Array or (raw_route as Array).size() < 2:
		return false
	var route := raw_route as Array
	var return_step: Dictionary = route[1] if route[1] is Dictionary else {}
	var raw_return_tile: Variant = return_step.get("tile", [])
	if not raw_return_tile is Array or (raw_return_tile as Array).size() < 2:
		return false
	var next_support := Vector2i(int((raw_next as Array)[0]), int((raw_next as Array)[1]))
	var return_tile := Vector2i(int((raw_return_tile as Array)[0]), int((raw_return_tile as Array)[1]))
	if next_support == return_tile or not _terrain_standable_tile(next_support) or not _terrain_standable_tile(return_tile):
		return false
	var projected_self := self_state.duplicate(true)
	var landing := _world_position_for_support_tile(next_support)
	projected_self["x"] = landing.x
	projected_self["y"] = landing.y
	projected_self["vx"] = 0.0
	projected_self["vy"] = 0.0
	projected_self["on_ground"] = true
	var reachable := Navigator.physics_reachable_first_steps(
		next_support,
		Callable(self, "_terrain_standable_tile"),
		Callable(self, "_terrain_climbable_tile"),
		Navigator.MAX_PHYSICS_ROUTE_NODES,
		Callable(self, "_physics_transition_allowed"),
		_safe_jump_first_step_filter(projected_self),
		_safe_jump_later_step_filter(projected_self),
	)
	return reachable.has(return_tile)


func _descent_one_block_source() -> Vector2i:
	if _session_world_mode != "one_block":
		return Vector2i(2147483647, 2147483647)
	var source: Dictionary = _world_snapshot.get("one_block", {}) if _world_snapshot.get("one_block", {}) is Dictionary else {}
	if not source.has("x") or not source.has("y"):
		return Vector2i(2147483647, 2147483647)
	return Vector2i(int(source.get("x", 0)), int(source.get("y", 0)))


func _descent_terrain_map() -> Dictionary:
	if _descent_terrain_cache_revision == _terrain_revision:
		return _descent_terrain_cache
	var result: Dictionary = {}
	for raw_key in _terrain_tiles.keys():
		var key := str(raw_key)
		var block_name := str(_terrain_tiles[raw_key])
		var block := _block_entry(block_name)
		var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
		result[key] = {
			"block_name": block_name,
			"solid": bool(block.get("solid", false)),
			"tree_traversal": _terrain_climbable_at(int(key.get_slice(":", 0)), int(key.get_slice(":", 1))),
			"fluid": bool(block.get("fluid", false)),
			"fluid_level": int(_terrain_fluid_levels.get(key, -1)) if bool(block.get("fluid", false)) else -1,
			"falls_when_unsupported": bool(block.get("falls_when_unsupported", false)),
			"hazard": bool(block.get("hazard", false)),
			"hazardous": bool(block.get("hazardous", false)),
			"damage": bool(block.get("damage", false)),
			"contact_damage": bool(block.get("contact_damage", false)),
			"damage_per_tick": bool(block.get("damage_per_tick", false)),
			"definition": definition.duplicate(true),
		}
	_descent_terrain_cache = result
	_descent_terrain_cache_revision = _terrain_revision
	return result


func _descent_coverage() -> Dictionary:
	var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	var mode := str(generation.get("mode", _session_world_mode)).to_lower()
	var generated_chunks: Dictionary = {}
	var raw_chunks: Variant = generation.get("chunks", [])
	if raw_chunks is Array:
		for raw_chunk in raw_chunks:
			if raw_chunk is Dictionary and (raw_chunk as Dictionary).has("x"):
				generated_chunks[str(int((raw_chunk as Dictionary).get("x", 0)))] = true
	elif raw_chunks is Dictionary:
		for raw_chunk_x in raw_chunks:
			generated_chunks[str(raw_chunk_x)] = true
	var one_block_source := _descent_one_block_source()
	var coverage := {
		"mode": mode,
		"complete": _descent_snapshot_complete,
		"chunk_width": 16,
		"generated_chunks": generated_chunks,
		"observed_cells": _terrain_observed_cells,
		"one_block_source": [one_block_source.x, one_block_source.y] if one_block_source.x != 2147483647 else [],
	}
	# Only the host-confirmed regenerating source may reseed a descent root while
	# the block is transiently air locally. Absent confirmation leaves the planner
	# without capability metadata, so it will not treat the source as standable.
	var regenerating_source := _regenerating_block_observation()
	if not regenerating_source.is_empty():
		coverage["one_block_source_capability"] = {
			"regenerates_on_mine": bool(regenerating_source.get("regenerates_on_mine", false)),
			"preserves_support_on_mine": bool(regenerating_source.get("preserves_support_on_mine", false)),
		}
	return coverage


func _filter_blocked_resources(raw_resources: Variant, now_msec: int) -> Array:
	var resources: Array = raw_resources as Array if raw_resources is Array else []
	var filtered: Array = []
	var needs_approach_proof := false
	for raw_resource in resources:
		if raw_resource is Dictionary and not bool((raw_resource as Dictionary).get("reachable", false)):
			needs_approach_proof = true
			break
	var reachable_support_tiles: Dictionary = {}
	if needs_approach_proof and not _terrain_tiles.is_empty():
		var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
		var origin := Contract.target_position(self_state)
		var first_step_allowed := _safe_jump_first_step_filter(self_state)
		for raw_tile in _physics_reachable_support_tiles(_route_origin_support_tile(origin, self_state), first_step_allowed):
			if typeof(raw_tile) == TYPE_VECTOR2I:
				reachable_support_tiles[raw_tile] = true
	for raw_resource in resources:
		if not raw_resource is Dictionary:
			continue
		var resource := raw_resource as Dictionary
		var key := str(resource.get("id", ""))
		var blocked_until := int(_blocked_action_targets.get(key, 0))
		if blocked_until > 0 and now_msec >= blocked_until:
			_blocked_action_targets.erase(key)
			blocked_until = 0
		var observed_resource := resource.duplicate(true)
		if not bool(observed_resource.get("reachable", false)):
			var approach := _resource_approach_stand_position(observed_resource, reachable_support_tiles)
			observed_resource["approachable"] = blocked_until <= now_msec and not approach.is_empty()
			if not approach.is_empty() and blocked_until <= now_msec:
				observed_resource["approach_position"] = approach.get("position", [])
				observed_resource["approach_support_tile"] = approach.get("support_tile", [])
			else:
				observed_resource.erase("approach_position")
				observed_resource.erase("approach_support_tile")
		if blocked_until > now_msec:
			# Keep a failed target in the observation, but make it unselectable until
			# its bounded retry window expires. Dropping it entirely made progression
			# forget that nearby wood existed and sometimes explore in the opposite
			# direction while the target was cooling down.
			observed_resource["reachable"] = false
			observed_resource["approachable"] = false
			observed_resource["blocked_until_msec"] = blocked_until
		filtered.append(observed_resource)
	return filtered


func _active_blocked_action_targets(now_msec: int) -> Dictionary:
	# Expose only policy-relevant targets, so selectors can choose a different
	# resource, station, or container after a failed attempt.
	var targets: Dictionary = {}
	for raw_key in _blocked_action_targets.keys():
		var key := str(raw_key)
		if not key.begins_with("tile:") and not key.begins_with("station:") and not key.begins_with("container:") and not key.begins_with("descent-return:"):
			continue
		var blocked_until := int(_blocked_action_targets[raw_key])
		if blocked_until <= now_msec:
			_blocked_action_targets.erase(raw_key)
			continue
		targets[key] = blocked_until
	# An OPEN_CONTAINER request is still awaiting its host acknowledgement.
	# Treat it as temporarily unavailable so another decision cannot reset its
	# sent_at clock and prevent the terminal timeout/cooldown from ever firing.
	for raw_key in _pending_action_targets.keys():
		var pending: Dictionary = _pending_action_targets[raw_key] if _pending_action_targets[raw_key] is Dictionary else {}
		if str(pending.get("action", "")) != Contract.ACTION_OPEN_CONTAINER:
			continue
		var sent_at := int(pending.get("sent_at_msec", -1))
		if sent_at >= 0 and now_msec - sent_at < 2_200:
			targets["container:%s" % str(raw_key)] = sent_at + 2_200
	return targets


func _physics_reachable_support_tiles(origin_tile: Vector2i, first_step_allowed: Callable = Callable()) -> Dictionary:
	# A resource approach must also have a route back. A survivable long drop
	# onto a lower island is not a safe gathering trip when the bot cannot jump
	# back to its origin; treating forward reachability as sufficient sent it
	# down toward wood and lava far below the starting Floating Island.
	# Preserve the bounded route metadata for the executable outbound leg.
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	if not first_step_allowed.is_valid():
		first_step_allowed = _safe_jump_first_step_filter(self_state)
	return Navigator.physics_roundtrip_first_steps(
		origin_tile,
		Callable(self, "_terrain_standable_tile"),
		Callable(self, "_terrain_climbable_tile"),
		Navigator.MAX_PHYSICS_ROUTE_NODES,
		Callable(self, "_physics_transition_allowed"),
		first_step_allowed,
		_safe_jump_later_step_filter(self_state),
	)


func _resource_has_reachable_stand_tile(resource: Dictionary, reachable_support_tiles: Dictionary) -> bool:
	return not _resource_approach_stand_position(resource, reachable_support_tiles).is_empty()


func _resource_approach_stand_position(resource: Dictionary, reachable_support_routes: Dictionary) -> Dictionary:
	if not resource.has("x") or not resource.has("y") or reachable_support_routes.is_empty():
		return {}
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	var origin := Contract.target_position(self_state)
	var best := {}
	var best_cost := INF
	for candidate in _resource_stand_candidates(resource):
		if not reachable_support_routes.has(candidate) or not _terrain_standable_tile(candidate):
			continue
		var route_info: Variant = reachable_support_routes[candidate]
		var route_steps := 0
		if route_info is Dictionary:
			route_steps = int((route_info as Dictionary).get("steps", 0))
		var position := _world_position_for_support_tile(candidate)
		var cost := float(route_steps + 1) * float(BlockDefs.TILE) + origin.distance_to(position)
		if cost >= best_cost:
			continue
		best_cost = cost
		best = {
			"position": [position.x, position.y],
			"support_tile": [candidate.x, candidate.y],
		}
	return best


func _expire_stale_action_targets(now_msec: int) -> void:
	for raw_key in _pending_action_targets.keys():
		var key := str(raw_key)
		var pending: Dictionary = _pending_action_targets[raw_key] if _pending_action_targets[raw_key] is Dictionary else {}
		var sent_at := int(pending.get("sent_at_msec", -1))
		if sent_at < 0 or now_msec - sent_at < 2_200:
			continue
		if str(pending.get("action", "")) in [Contract.ACTION_MINE, Contract.ACTION_PLACE] and key.contains(":"):
			_blocked_action_targets["tile:%s" % key] = now_msec + ACTION_RETRY_BLOCK_MSEC
		if str(pending.get("action", "")) == Contract.ACTION_OPEN_CONTAINER:
			_blocked_action_targets["container:%s" % key] = now_msec + CONTAINER_RETRY_BLOCK_MSEC
		if str(pending.get("action", "")) == Contract.ACTION_PLACE:
			_note_build_project_failure(pending, "place_ack_timeout", now_msec)
		_pending_action_targets.erase(raw_key)


func _enemy_player_id() -> String:
	return _pvp_enemy_player_id if _is_pvp_world() else ""


func _remember_pvp_enemy(player_id: String, raw_state: Dictionary) -> void:
	if not _is_pvp_world() or player_id.is_empty() or raw_state.is_empty():
		return
	if _pvp_enemy_player_id.is_empty():
		_pvp_enemy_player_id = player_id
	if player_id != _pvp_enemy_player_id:
		return
	var remembered := raw_state.duplicate(true)
	remembered["id"] = player_id
	remembered["alive"] = int(remembered.get("health", 10)) > 0
	remembered["stale"] = false
	remembered["last_known"] = false
	remembered.erase("snapshot_age_msec")
	_pvp_enemy_last_known_state = remembered
	_pvp_enemy_last_seen_msec = Time.get_ticks_msec()


func _retain_last_known_pvp_enemy() -> void:
	if (
		not _is_pvp_world()
		or _pvp_enemy_player_id.is_empty()
		or _roster.has(_pvp_enemy_player_id)
		or _pvp_enemy_last_known_state.is_empty()
	):
		return
	var fallback := _pvp_enemy_last_known_state.duplicate(true)
	fallback["id"] = _pvp_enemy_player_id
	fallback["stale"] = true
	fallback["last_known"] = true
	fallback["snapshot_age_msec"] = maxi(0, Time.get_ticks_msec() - _pvp_enemy_last_seen_msec) if _pvp_enemy_last_seen_msec >= 0 else 0
	_roster[_pvp_enemy_player_id] = fallback


func _is_pvp_world() -> bool:
	var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	return (
		str(generation.get("mode", "")).to_lower() == "duel"
		or _session_world_mode == "duel"
		or protocol_version == DUEL_PROTOCOL_VERSION
	)


func _regenerating_block_observation() -> Dictionary:
	var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	if str(generation.get("mode", _session_world_mode)).to_lower() != "one_block":
		return {}
	var source: Dictionary = _world_snapshot.get("one_block", {}) if _world_snapshot.get("one_block", {}) is Dictionary else {}
	if not source.has("x") or not source.has("y"):
		return {}
	var tile_x := int(source.get("x", 0))
	var tile_y := int(source.get("y", 0))
	return {
		"id": "tile:%d:%d" % [tile_x, tile_y],
		"x": tile_x,
		"y": tile_y,
		"position": [
			(float(tile_x) + 0.5) * BlockDefs.TILE,
			(float(tile_y) + 0.5) * BlockDefs.TILE,
		],
		"mined": maxi(0, int(source.get("mined", 0))),
		"phase": maxi(0, int(source.get("phase", 0))),
		"regenerates_on_mine": true,
		"preserves_support_on_mine": true,
	}


func _is_regenerating_block_tile(tile_x: int, tile_y: int) -> bool:
	var source := _regenerating_block_observation()
	return (
		not source.is_empty()
		and int(source.get("x", 2147483647)) == tile_x
		and int(source.get("y", 2147483647)) == tile_y
	)


## A host-confirmed source that both regenerates on mine and preserves its own
## support stays a valid, safe target even while bootstrap perception is
## narrowed to wood. This is capability-based: any tile the host confirms as
## regenerating and support-preserving qualifies, independent of world mode or
## block name, so ordinary filler is still filtered.
func _is_host_authoritative_regenerating_source(tile_x: int, tile_y: int) -> bool:
	var source := _regenerating_block_observation()
	return (
		not source.is_empty()
		and int(source.get("x", 2147483647)) == tile_x
		and int(source.get("y", 2147483647)) == tile_y
		and bool(source.get("regenerates_on_mine", false))
		and bool(source.get("preserves_support_on_mine", false))
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
		var regenerates_on_mine := _is_regenerating_block_tile(tile_x, tile_y)
		result.append({
			"x": tile_x,
			"y": tile_y,
			"block_name": block_name,
			"solid": bool(block.get("solid", false)),
			"fluid": bool(block.get("fluid", false)),
			"fluid_level": int(_terrain_fluid_levels.get(key, -1)) if bool(block.get("fluid", false)) else -1,
			"temperature": float(block.get("temperature", 0.0)),
			"harmful_fluid": bool(block.get("fluid", false)) and float(block.get("temperature", 0.0)) >= 0.8,
			"harvest_tier": _block_harvest_tier(block),
			"hardness": float(block.get("hardness", 0.0)),
			"preserves_support_on_mine": bool(_support_preserving_mine_tiles.get(key, false)) or regenerates_on_mine,
			"regenerates_on_mine": regenerates_on_mine,
		})
	return result


## Compact authoritative coverage for the immediate movement/building area. An
## absent tile in `terrain_tiles` is not automatically air; route stair placement
## needs proof the candidate and its headroom were actually observed empty.
func _terrain_known_cell_window(self_state: Dictionary) -> Dictionary:
	var known_cells: Dictionary = {}
	var origin := _support_tile_for_position(Contract.target_position(self_state))
	# A three-step climb needs both empty cells above its landing. The terrain
	# observation already reaches eight rows up; exposing six *known* rows lets
	# the pit planner verify that headroom without treating unseen air as empty.
	for tile_y in range(origin.y - 6, origin.y + 3):
		for tile_x in range(origin.x - 4, origin.x + 5):
			if _terrain_cell_is_known(tile_x, tile_y):
				known_cells["%d:%d" % [tile_x, tile_y]] = true
	return known_cells


func _visible_resources_from_terrain(self_state: Dictionary) -> Array:
	var resources: Array = []
	var origin := Contract.target_position(self_state)
	# Trees can sit well above the bot's current tile after it has dug or fallen.
	# Keep a wide, wood-only read during either Stone Age bootstrap goal.
	var scan_radius := maxf(observation_radius, STARTER_TOOLING_RESOURCE_SCAN_RADIUS) if _stone_age_gathering_wood() else maxf(observation_radius, 420.0)
	var max_distance := scan_radius + float(BlockDefs.TILE)
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
		# Join snapshots are only a sparse fallback. Once a live host update has
		# observed this cell, the terrain mirror is authoritative even when the
		# updated cell is air and therefore absent from _terrain_tiles. Otherwise
		# a mined block from the stale join snapshot reappears as a resource.
		if _terrain_observed_cells.has("%d:%d" % [tile_x, tile_y]):
			continue
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
	# Keep a looted generated chest visible during starter-wood gathering. The
	# rule provider may safely mine that physical block after OPEN_CONTAINER;
	# filtering it out here left the chest behind while the bot chased logs.
	if _stone_age_gathering_wood() and not _is_starter_wood_log_name(block_name) and block_name.to_lower() != "chest":
		if not _is_host_authoritative_regenerating_source(tile_x, tile_y):
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
	var regenerates_on_mine := _is_regenerating_block_tile(tile_x, tile_y)
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
		"preserves_support_on_mine": bool(_support_preserving_mine_tiles.get(key, false)) or regenerates_on_mine,
		"regenerates_on_mine": regenerates_on_mine,
	})


func _stone_age_gathering_wood() -> bool:
	return (
		str(_stone_age_goal_state.get("goal_id", "")) in ["stone_age", "starter_tooling"]
		and str(_stone_age_goal_state.get("status", "")) == "active"
		and str(_stone_age_goal_state.get("stage", "")) == "gather_wood"
	)


func _is_starter_wood_log_name(block_name: String) -> bool:
	var normalized := block_name.strip_edges().to_lower()
	return normalized in ["wood", "palm_wood", "pine_wood", "weeping_wood"] or normalized.ends_with("_wood")


func _decision_observation_radius() -> float:
	if _stone_age_gathering_wood():
		return maxf(observation_radius, STARTER_TOOLING_RESOURCE_SCAN_RADIUS)
	return observation_radius


func _visible_resources_from_tiles(raw_tiles: Variant, self_state: Dictionary) -> Array:
	var resources: Array = []
	if not raw_tiles is Array:
		return resources
	var origin := Contract.target_position(self_state)
	var scan_radius := maxf(observation_radius, STARTER_TOOLING_RESOURCE_SCAN_RADIUS) if _stone_age_gathering_wood() else observation_radius
	var max_distance := scan_radius + float(BlockDefs.TILE)
	for raw_tile in raw_tiles:
		if not raw_tile is Dictionary:
			continue
		var tile := raw_tile as Dictionary
		var tile_x := int(tile.get("x", 0))
		var tile_y := int(tile.get("y", 0))
		var content_id := str(tile.get("content_id", ""))
		var block_name := _block_name_for_content_id(content_id)
		if _stone_age_gathering_wood() and not _is_starter_wood_log_name(block_name):
			if not _is_host_authoritative_regenerating_source(tile_x, tile_y):
				continue
		var block_definition: Dictionary = _block_entry(block_name)
		var solid := bool(block_definition.get("solid", false)) and not bool(block_definition.get("fluid", false))
		if block_name.is_empty() or block_name == "air" or not solid:
			continue
		var position := Vector2((float(tile_x) + 0.5) * BlockDefs.TILE, (float(tile_y) + 0.5) * BlockDefs.TILE)
		if origin.distance_to(position) > max_distance:
			continue
		var key := "%d:%d" % [tile_x, tile_y]
		var regenerates_on_mine := _is_regenerating_block_tile(tile_x, tile_y)
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
			"preserves_support_on_mine": bool(tile.get("preserves_support_on_mine", _support_preserving_mine_tiles.get(key, false))) or regenerates_on_mine,
			"regenerates_on_mine": regenerates_on_mine,
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
	var max_distance := maxf(observation_radius, CHEST_OBSERVATION_RADIUS) + float(BlockDefs.TILE)
	if _stone_age_gathering_wood():
		# A generated chest can be the only attainable bootstrap supply in a
		# treeless biome. When the wide wood scan finds no approachable log,
		# inspect chests over that same already-known area before choosing an
		# arbitrary exploration heading. This does not reveal unstreamed chunks.
		var has_accessible_wood := false
		var resources: Array = snapshot.get("visible_resources", []) if snapshot.get("visible_resources", []) is Array else []
		for raw_resource in resources:
			if not raw_resource is Dictionary:
				continue
			var resource := raw_resource as Dictionary
			if (
				_is_starter_wood_log_name(str(resource.get("block_name", "")))
				and (bool(resource.get("reachable", false)) or bool(resource.get("approachable", false)))
			):
				has_accessible_wood = true
				break
		if not has_accessible_wood:
			max_distance = maxf(max_distance, STARTER_TOOLING_RESOURCE_SCAN_RADIUS + float(BlockDefs.TILE))
	for entry in _normalized_container_entries(raw_containers):
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
			"generated": kind == "chest" and not str(data.get("loot_key", "")).is_empty(),
			"death_cache": death_cache,
			"one_use_cache": one_use_cache,
			"owner_player_id": str(data.get("owner_player_id", "")),
			"reachable": origin.distance_to(position) <= float(BlockDefs.TILE) * 4.5,
		})
		if containers.size() >= 32:
			break
	return containers


## Hosts serialize containers in two shapes. A full save snapshot
## (`WorldSim.serialize_state`) writes the container fields flat on the entry
## (`contents`, `loot_key`, `loot_generated`, `death_cache`, ...), while live
## tile batches and streamed chunk transfers nest the same fields under `data`.
## Some payloads also wrap a nested `containers` array (a chunk entry carrying
## its own region). Normalize every shape into `{x, y, data}` so an ordinary
## generated structure chest is never mistaken for an opened empty chest.
func _normalized_container_entries(raw_containers: Array) -> Array:
	var entries: Array = []
	for raw_entry in raw_containers:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		var nested: Variant = entry.get("containers", null)
		if nested is Array:
			entries.append_array(_normalized_container_entries(nested))
			continue
		var data: Dictionary = _container_entry_data(entry)
		entries.append({
			"x": int(entry.get("x", 0)),
			"y": int(entry.get("y", 0)),
			"data": data,
		})
	return entries


## Prefer a nested `data` payload whenever the entry carries one (live tile
## batches and streamed chunk transfers), otherwise fall back to the flat host
## snapshot fields on the entry itself.
func _container_entry_data(entry: Dictionary) -> Dictionary:
	if entry.has("data") and entry.get("data", null) is Dictionary:
		return (entry.get("data", {}) as Dictionary).duplicate(true)
	if _looks_like_flat_container_entry(entry):
		return entry.duplicate(true)
	return {}


func _looks_like_flat_container_entry(entry: Dictionary) -> bool:
	for key in ["contents", "loot_key", "death_cache", "one_use_cache", "loot_generated", "owner_player_id"]:
		if entry.has(key):
			return true
	return false


func _generated_chest_count(containers: Array) -> int:
	var count := 0
	for raw_container in containers:
		if raw_container is Dictionary and bool((raw_container as Dictionary).get("generated", false)):
			count += 1
	return count


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
	var now_msec := Time.get_ticks_msec()
	_stone_age_note_no_action(decision, now_msec)
	_log_island_idle_probe(decision, now_msec)
	decision_logged.emit({"event": "decision_proposed", "decision": decision.duplicate(true), "at_msec": now_msec})


func _log_island_idle_probe(decision: Dictionary, now_msec: int) -> void:
	var mode := str(_decision_probe_observation.get("world_mode", ""))
	if mode not in ["skyblock", "floating_islands", "procedural"] or str(decision.get("action", "")) not in [Contract.ACTION_WAIT, Contract.ACTION_LOOK_AT]:
		return
	if _last_island_idle_probe_msec >= 0 and now_msec - _last_island_idle_probe_msec < 15_000:
		return
	_last_island_idle_probe_msec = now_msec
	var observation := _decision_probe_observation
	var inventory: Dictionary = observation.get("inventory_summary", {}) if observation.get("inventory_summary", {}) is Dictionary else {}
	var bridge: Dictionary = BuildPlanner.floating_island_bridge_step(observation) if mode == "floating_islands" else {}
	var home: Dictionary = BuildPlanner.floating_island_home_step(observation) if mode == "floating_islands" else BuildPlanner.skyblock_home_step(observation)
	var generator: Dictionary = BuildPlanner.island_stone_generator_step(observation)
	var pit_escape: Dictionary = DigPlanner.trapped_upward_step(observation)
	var pit_terrain: Dictionary = DigPlanner._terrain_map(observation.get("terrain_tiles", []))
	var pit_origin: Vector2i = DigPlanner._grounded_support_tile(observation.get("self", {}), pit_terrain)
	var self_position := Contract.target_position(observation.get("self", {}))
	var nearest_player_distance := 999999.0
	var nearest_player_vertical_gap := 0.0
	for raw_player in observation.get("players", []):
		if not raw_player is Dictionary or not bool((raw_player as Dictionary).get("alive", true)):
			continue
		var player_position := Contract.target_position(raw_player)
		var player_distance := self_position.distance_to(player_position)
		if player_distance < nearest_player_distance:
			nearest_player_distance = player_distance
			nearest_player_vertical_gap = self_position.y - player_position.y
	var pit_sides: Array = []
	for direction in [1, -1]:
		var side_x: int = pit_origin.x + direction
		pit_sides.append({
			"x": side_x,
			"floor": DigPlanner._solid(pit_terrain, side_x, pit_origin.y),
			"wall": DigPlanner._solid(pit_terrain, side_x, pit_origin.y - 1),
			"headroom_known": DigPlanner._known_empty_cell(observation, pit_terrain, side_x, pit_origin.y - 2),
			"lava_nearby": DigPlanner._near_harmful_fluid(Vector2i(side_x, pit_origin.y), observation),
			"player_overlap": DigPlanner._overlaps_any_player(Vector2i(side_x, pit_origin.y - 1), observation),
			"mine_action": str(DigPlanner._mine_step(side_x, pit_origin.y - 1, pit_origin, Vector2i(side_x, pit_origin.y), observation).get("action", "")),
		})
	var project: Dictionary = observation.get("build_project_state", {}) if observation.get("build_project_state", {}) is Dictionary else {}
	structured_log.emit({
		"event": "procedural_idle_probe" if mode == "procedural" else "island_idle_probe",
		"at_msec": now_msec,
		"world_mode": mode,
		"on_ground": bool((observation.get("self", {}) as Dictionary).get("on_ground", false)),
		"visible_resources": (observation.get("visible_resources", []) as Array).size(),
		"safe_waypoints": (observation.get("safe_exploration_waypoints", []) as Array).size(),
		"usable_bridge_blocks": BuildPlanner._floating_bridge_usable_support_count(inventory) if mode == "floating_islands" else 0,
		"bridge_shortfall": BuildPlanner.floating_island_bridge_material_shortfall(observation) if mode == "floating_islands" else 0,
		"bridge_action": str(bridge.get("action", "")),
		"home_action": str(home.get("action", "")),
		"generator_action": str(generator.get("action", "")),
		"pit_origin": [pit_origin.x, pit_origin.y],
		"pit_escape_action": str(pit_escape.get("action", "")),
		"pit_escape_target_id": str(pit_escape.get("target_id", "")),
		"nearest_player_distance": nearest_player_distance,
		"nearest_player_vertical_gap": nearest_player_vertical_gap,
		"pit_sides": pit_sides,
		"project_status": str(project.get("status", "")),
	})


func _stone_age_note_no_action(decision: Dictionary, now_msec: int) -> void:
	if _stone_age_goal_state.is_empty() or str(_stone_age_goal_state.get("status", "")) != "active":
		return
	var pending: Dictionary = _stone_age_goal_state.get("pending", {}) if _stone_age_goal_state.get("pending", {}) is Dictionary else {}
	if not pending.is_empty():
		_stone_age_goal_state["no_action_since_msec"] = -1
		return
	var stage := str(_stone_age_goal_state.get("stage", ""))
	var decision_stage := str(decision.get("stone_age_stage", ""))
	var decision_goal := str(decision.get("stone_age_goal_id", _stone_age_goal_name()))
	if decision_stage == stage and decision_goal == _stone_age_goal_name():
		# A real Stone Age choice (including a safe MOVE_TO search) means the
		# stage is actionable; don't classify it as a stall.
		_stone_age_goal_state["no_action_since_msec"] = -1
		_stone_age_goal_state["no_action_failures"] = 0
		return
	var action := str(decision.get("action", ""))
	var behavior_goal := str(decision.get("goal", ""))
	if behavior_goal in [Contract.GOAL_SURVIVE, Contract.GOAL_SELF_DEFENSE]:
		# A safety or combat response legitimately suspends long-term progression.
		_stone_age_goal_state["no_action_since_msec"] = -1
		return
	var non_progress_goal := behavior_goal in [
		Contract.GOAL_IDLE,
		Contract.GOAL_SOCIAL_FOLLOW,
		Contract.GOAL_EXPLORE,
	]
	if action not in [Contract.ACTION_WAIT, Contract.ACTION_LOOK_AT] and not non_progress_goal:
		# Mining/crafting/building and other substantive goals count as activity.
		# Social orbiting and exploratory MOVE_TO retries do not by themselves
		# advance a crafting stage, so they must not keep an unavailable stage alive.
		_stone_age_goal_state["no_action_since_msec"] = -1
		return
	var since := int(_stone_age_goal_state.get("no_action_since_msec", -1))
	if since < 0:
		_stone_age_goal_state["no_action_since_msec"] = now_msec
		return
	if now_msec - since < STONE_AGE_NO_ACTION_TIMEOUT_MSEC:
		return
	var failures := int(_stone_age_goal_state.get("no_action_failures", 0)) + 1
	var abandoned := failures >= STONE_AGE_MAX_STAGE_FAILURES
	_stone_age_goal_state["no_action_failures"] = failures
	_stone_age_goal_state["no_action_since_msec"] = -1
	_stone_age_goal_state["status"] = "abandoned" if abandoned else "cooldown"
	_stone_age_goal_state["retry_after_msec"] = now_msec + (STONE_AGE_ABANDON_COOLDOWN_MSEC if abandoned else STONE_AGE_RETRY_COOLDOWN_MSEC)
	structured_log.emit({
		"event": "goal_abandoned" if abandoned else "step_failed",
		"goal": _stone_age_goal_name(),
		"stage": stage,
		"reason": "no_actionable_step",
		"failures": failures,
		"retry_after_msec": _stone_age_goal_state["retry_after_msec"],
		"world_id": world_id,
		"at_msec": now_msec,
	})


func _on_decision_rejected(decision: Dictionary, reason: String) -> void:
	if reason == "mine_target_harmful_fluid_breach":
		_block_harmful_fluid_mine_target(decision)
	_record_action_history("rejected", decision, reason)
	_stone_age_note_failure(decision, reason, Time.get_ticks_msec())
	_achievement_goal_note_failure(decision, reason, Time.get_ticks_msec())
	decision_logged.emit({"event": "decision_rejected", "decision": decision.duplicate(true), "reason": reason, "at_msec": Time.get_ticks_msec()})


func _block_harmful_fluid_mine_target(decision: Dictionary) -> void:
	if str(decision.get("action", "")) != Contract.ACTION_MINE:
		return
	var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
	if not target.has("x") or not target.has("y"):
		return
	var target_id := "tile:%d:%d" % [int(target.get("x", 0)), int(target.get("y", 0))]
	var now_msec := Time.get_ticks_msec()
	_blocked_action_targets[target_id] = now_msec + HARMFUL_FLUID_MINE_RETRY_MSEC
	structured_log.emit({
		"event": "harmful_fluid_mine_cooled_down",
		"blocked_until_msec": int(_blocked_action_targets[target_id]),
		"world_id": world_id,
		"at_msec": now_msec,
	})


func _on_decision_started(decision: Dictionary) -> void:
	var now_msec := Time.get_ticks_msec()
	_record_action_history("started", decision)
	_stone_age_note_action_started(decision, now_msec)
	_mid_tier_tool_note_action_started(decision, now_msec)
	_achievement_goal_note_action_started(decision, now_msec)
	var action := str(decision.get("action", ""))
	var decision_target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
	if bool(decision_target.get("build_project_complete", false)):
		_complete_build_project(str(decision_target.get("project_id", "")), now_msec)
	if bool(decision.get("descent_transition", false)):
		var armed: bool = _descent_planner.note_intended_transition(decision)
		structured_log.emit({
			"event": "descent_transition_armed" if armed else "descent_transition_not_armed",
			"from_support": decision.get("descent_from_support", []),
			"to_support": decision.get("descent_to_support", []),
			"at_msec": now_msec,
		})
	if action == Contract.ACTION_EQUIP:
		var item_name := str(decision.get("target_id", ""))
		# Apply a local optimistic slot so the rule provider does not re-select
		# EQUIP every 350 ms while the host ack is in flight. Host snapshots still
		# overwrite these slots when they arrive.
		if not item_name.is_empty():
			_pending_action_targets["equip"] = {"action": action, "item": item_name, "stone_age_stage": str(decision.get("stone_age_stage", "")), "sent_at_msec": now_msec}
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
		var pending_target := {
			"action": action,
			"dig_route": action == Contract.ACTION_MINE and bool(target.get("dig_route", false)),
			"block": str(decision.get("block", "")),
			"x": int(target.get("x", 0)),
			"y": int(target.get("y", 0)),
			"content_id": str(target.get("content_id", "")),
			"stone_age_stage": str(decision.get("stone_age_stage", "")),
			"build_project": target.get("build_project", {}).duplicate(true) if target.get("build_project", {}) is Dictionary else {},
			"sent_at_msec": now_msec,
		}
		if action == Contract.ACTION_MINE and _is_one_block_source_target(target):
			pending_target["one_block_source"] = true
			pending_target["one_block_mined_before"] = int(_mode_progress_from_snapshot().get("one_block_mined", 0))
		_pending_action_targets[key] = pending_target
		if action == Contract.ACTION_PLACE:
			# A placement result may arrive after the next policy tick. Keep the
			# selected cell unavailable while its acknowledgement is in flight so
			# the bot does not send duplicate PLACE commands against stale terrain.
			_blocked_action_targets["tile:%s" % key] = now_msec + 2_200
			var build_project: Dictionary = target.get("build_project", {}) if target.get("build_project", {}) is Dictionary else {}
			if not build_project.is_empty():
				_note_build_project_started(build_project, target, now_msec)
			var was_confirmed := bool((_protected_build_cells.get(key, {}) as Dictionary).get("confirmed", false))
			_protected_build_cells[key] = {
				"block": str(decision.get("block", "")),
				"reason": str(target.get("reason", decision.get("goal", ""))),
				"at_msec": now_msec,
				"confirmed": was_confirmed,
			}
	elif action == Contract.ACTION_CRAFT:
		var craft_output := str(decision.get("target_id", ""))
		_pending_action_targets["craft"] = {"action": action, "output": craft_output, "stone_age_stage": str(decision.get("stone_age_stage", ""))}
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
			# Station recipes must be resolved by the authoritative host so recipe
			# proximity and multi-input inventory updates stay identical to a human
			# player. The executor intentionally skips CRAFT network sends; send the
			# one request here and wait for action_result/inventory_snapshot.
			var sent := false
			if network_client != null and network_client.has_method("send_command"):
				var send_result: Variant = network_client.call("send_command", "craft_recipe", {"output": craft_output})
				sent = bool(send_result) if send_result is bool else true
			if sent:
				_craft_pending_output = craft_output
				_craft_retry_after_msec = now_msec + CRAFT_RESPONSE_TIMEOUT_MSEC
				structured_log.emit({
					"event": "craft_requested",
					"output": craft_output,
					"at_msec": now_msec,
				})
			else:
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
		_pending_action_targets[container_key] = {
			"action": action,
			"sent_at_msec": now_msec,
			"kind": str(container_target.get("kind", "")),
			"generated": bool(container_target.get("generated", false)),
			"death_cache": bool(container_target.get("death_cache", false)) or str(container_target.get("kind", "")) == "death_cache",
			"owner_player_id": str(container_target.get("owner_player_id", "")),
		}
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


func _sync_build_project_scope(mode: String, now_msec: int) -> void:
	if _build_project_state.is_empty():
		return
	if str(_build_project_state.get("world_id", "")) != world_id or str(_build_project_state.get("world_mode", "")) != mode:
		structured_log.emit({"event": "build_project_abandoned", "project_id": str(_build_project_state.get("id", "")), "reason": "world_scope_changed", "world_id": world_id, "world_mode": mode, "at_msec": now_msec})
		_build_project_state.clear()
		return
	var status := str(_build_project_state.get("status", ""))
	if status not in ["cooldown", "abandoned"] or now_msec < int(_build_project_state.get("retry_after_msec", 0)):
		return
	if status == "abandoned":
		var old_id := str(_build_project_state.get("id", ""))
		_build_project_state.clear()
		structured_log.emit({"event": "build_project_reconsidered", "project_id": old_id, "world_id": world_id, "world_mode": mode, "at_msec": now_msec})
		return
	_build_project_state["status"] = "active"
	_build_project_state["retry_after_msec"] = 0
	_build_project_state["pending_placement"] = {}
	structured_log.emit({"event": "build_project_resumed", "project_id": str(_build_project_state.get("id", "")), "world_id": world_id, "world_mode": mode, "at_msec": now_msec})


func _note_build_project_started(project: Dictionary, target: Dictionary, now_msec: int) -> void:
	var project_id := str(project.get("id", ""))
	if project_id.is_empty():
		return
	if str(_build_project_state.get("id", "")) != project_id:
		_build_project_state = project.duplicate(true)
		_build_project_state["world_id"] = world_id
		_build_project_state["world_mode"] = str((_world_snapshot.get("generation", {}) as Dictionary).get("mode", _session_world_mode)).to_lower() if _world_snapshot.get("generation", {}) is Dictionary else _session_world_mode
		_build_project_state["started_at_msec"] = now_msec
		_build_project_state["confirmed_placements"] = 0
		_build_project_state["failures"] = 0
		_build_project_state["retry_after_msec"] = 0
		_build_project_state["status"] = "active"
		structured_log.emit({"event": "build_project_started", "project_id": project_id, "target_id": str(project.get("target_id", "")), "target_kind": str(project.get("target_kind", "")), "world_id": world_id, "world_mode": str(_build_project_state["world_mode"]), "at_msec": now_msec})
	else:
		for key in ["target_id", "target_kind", "goal_tile", "target_position"]:
			if project.has(key):
				_build_project_state[key] = project[key]
	_build_project_state["pending_placement"] = {"x": int(target.get("x", 0)), "y": int(target.get("y", 0)), "at_msec": now_msec}


func _note_build_project_placement(pending_target: Dictionary, cell_key: String, now_msec: int) -> void:
	var project: Dictionary = pending_target.get("build_project", {}) if pending_target.get("build_project", {}) is Dictionary else {}
	var project_id := str(project.get("id", ""))
	if project_id.is_empty() or str(_build_project_state.get("id", "")) != project_id:
		return
	_build_project_state["confirmed_placements"] = int(_build_project_state.get("confirmed_placements", 0)) + 1
	var pending_placement: Dictionary = _build_project_state.get("pending_placement", {}) if _build_project_state.get("pending_placement", {}) is Dictionary else {}
	if int(pending_placement.get("x", 2147483647)) == int(pending_target.get("x", -1)) and int(pending_placement.get("y", 2147483647)) == int(pending_target.get("y", -1)):
		_build_project_state["pending_placement"] = {}
	_build_project_state["failures"] = 0
	_build_project_state["status"] = "active"
	_build_project_state["retry_after_msec"] = 0
	structured_log.emit({"event": "build_project_step_confirmed", "project_id": project_id, "cell": cell_key, "confirmed_placements": int(_build_project_state["confirmed_placements"]), "world_id": world_id, "at_msec": now_msec})


func _note_build_project_failure(pending_target: Dictionary, reason: String, now_msec: int) -> void:
	var project: Dictionary = pending_target.get("build_project", {}) if pending_target.get("build_project", {}) is Dictionary else {}
	var project_id := str(project.get("id", ""))
	if project_id.is_empty() or str(_build_project_state.get("id", "")) != project_id:
		return
	var pending_placement: Dictionary = _build_project_state.get("pending_placement", {}) if _build_project_state.get("pending_placement", {}) is Dictionary else {}
	if pending_placement.is_empty() or int(pending_placement.get("x", -1)) != int(pending_target.get("x", -2)) or int(pending_placement.get("y", -1)) != int(pending_target.get("y", -2)):
		return
	var failures := int(_build_project_state.get("failures", 0)) + 1
	var abandoned := failures >= BUILD_PROJECT_MAX_FAILURES
	var retry_delay := ACTION_RETRY_BLOCK_MSEC if reason == "place_ack_timeout" else BUILD_PROJECT_RETRY_MSEC
	_build_project_state["failures"] = failures
	_build_project_state["pending_placement"] = {}
	_build_project_state["status"] = "abandoned" if abandoned else "cooldown"
	_build_project_state["retry_after_msec"] = now_msec + (60_000 if abandoned else retry_delay)
	structured_log.emit({"event": "build_project_abandoned" if abandoned else "build_project_step_failed", "project_id": project_id, "reason": reason, "failures": failures, "retry_after_msec": int(_build_project_state["retry_after_msec"]), "world_id": world_id, "world_mode": str(_build_project_state.get("world_mode", "")), "at_msec": now_msec})


func _complete_build_project(project_id: String, now_msec: int) -> void:
	if project_id.is_empty() or str(_build_project_state.get("id", "")) != project_id:
		return
	var pending_placement: Dictionary = _build_project_state.get("pending_placement", {}) if _build_project_state.get("pending_placement", {}) is Dictionary else {}
	if not pending_placement.is_empty():
		return
	var completed := _build_project_state.duplicate(true)
	_build_project_state.clear()
	structured_log.emit({"event": "build_project_completed", "project_id": project_id, "target_id": str(completed.get("target_id", "")), "confirmed_placements": int(completed.get("confirmed_placements", 0)), "world_id": world_id, "world_mode": str(completed.get("world_mode", "")), "at_msec": now_msec})


func _on_executor_action_finished(decision: Dictionary, reason: String) -> void:
	if _made_bounded_route_progress(decision, reason):
		# A short movement window is not a failed route when it advanced toward
		# the same chest or pit exit. Keep that goal eligible on the next tick.
		reason = "route_progress"
	_log_movement_stall_probe(decision, reason)
	_clear_aborted_movement_transition_if_needed(decision, reason)
	if reason == "mine_target_became_unsafe":
		_block_harmful_fluid_mine_target(decision)
	if bool(decision.get("descent_transition", false)) and reason not in ["movement_step"]:
		_descent_planner.cancel_intended_transition()
	var target_id := str(decision.get("target_id", ""))
	_note_flee_route_failure(decision, reason)
	if reason in ["blocked_obstacle", "edge_guard", "unsafe_jump_route", "route_unreachable", "lava_guard", "timeout"] and target_id.begins_with("tile:"):
		var retry_delay := UNSAFE_ROUTE_RETRY_BLOCK_MSEC if reason in ["unsafe_jump_route", "route_unreachable"] else ACTION_RETRY_BLOCK_MSEC
		_blocked_action_targets[target_id] = Time.get_ticks_msec() + retry_delay
	if target_id.begins_with("descent-return:") and reason in ["blocked_obstacle", "edge_guard", "unsafe_jump_route", "unsafe_drop_route", "route_unreachable", "lava_guard"]:
		# The host can change a formerly verified stair (or its jump arc can be
		# unexecutable from the current pose). Do not hammer the same return step
		# every decision tick; allow terrain/position updates and other safe work.
		_blocked_action_targets[target_id] = Time.get_ticks_msec() + DESCENT_RETURN_ROUTE_RETRY_MSEC
	if target_id.begins_with("pit-return:") and reason in ["blocked_obstacle", "edge_guard", "unsafe_jump_route", "unsafe_drop_route", "route_unreachable", "lava_guard", "timeout"]:
		_blocked_action_targets[target_id] = Time.get_ticks_msec() + ACTION_RETRY_BLOCK_MSEC
	if (
		str(decision.get("action", "")) in [Contract.ACTION_MOVE_TO, Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_FOLLOW]
		and reason in [
			"blocked_obstacle", "edge_guard", "unsafe_jump_route", "unsafe_drop_route",
			"route_unreachable", "pursuit_no_safe_waypoint", "pursuit_waypoint_unreachable", "lava_guard", "timeout",
		]
		and (target_id.begins_with("station:") or target_id.begins_with("container:"))
	):
		# A movement-route failure toward a chest is normally transient (a
		# mid-air settling origin or a momentarily blocked first step) and the
		# route is replanned on the next tick, so it must not cool the chest for
		# the full terminal window. A genuine hazard refusal (lava) keeps the
		# long cool-down; terminal OPEN_CONTAINER failures keep
		# CONTAINER_RETRY_BLOCK_MSEC through their own ack-timeout/rejection paths.
		var route_retry_delay := STATION_ROUTE_RETRY_BLOCK_MSEC
		if target_id.begins_with("container:"):
			route_retry_delay = CONTAINER_RETRY_BLOCK_MSEC if reason == "lava_guard" else CONTAINER_MOVE_RETRY_BLOCK_MSEC
		_blocked_action_targets[target_id] = Time.get_ticks_msec() + route_retry_delay
	if reason in ["blocked_obstacle", "edge_guard", "unsafe_jump_route", "route_unreachable", "lava_guard", "pursuit_no_safe_waypoint", "pursuit_waypoint_unreachable", "timeout", "mine_ack_timeout"]:
		_stone_age_note_failure(decision, reason, Time.get_ticks_msec())
		_achievement_goal_note_failure(decision, reason, Time.get_ticks_msec())
	_record_action_history("finished", decision, reason)


func _log_movement_stall_probe(decision: Dictionary, reason: String) -> void:
	var target_id := str(decision.get("target_id", ""))
	if str(decision.get("action", "")) != Contract.ACTION_MOVE_TO or reason not in ["timeout", "route_unreachable"] or not (target_id.begins_with("explore:") or target_id.begins_with("tile:")):
		return
	var now := Time.get_ticks_msec()
	if _last_movement_stall_probe_msec >= 0 and now - _last_movement_stall_probe_msec < 5000:
		return
	_last_movement_stall_probe_msec = now
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	var route_next: Dictionary = _physics_route[1] if _physics_route.size() > 1 else {}
	var next_tile: Vector2i = route_next.get("tile", Vector2i(2147483647, 2147483647))
	structured_log.emit({
		"event": "movement_stall_probe", "at_msec": now,
		"target_id": target_id, "reason": reason,
		"x": float(self_state.get("x", 0.0)), "y": float(self_state.get("y", 0.0)),
		"vx": float(self_state.get("vx", 0.0)), "vy": float(self_state.get("vy", 0.0)),
		"on_ground": bool(self_state.get("on_ground", false)),
		"tree_ghost": bool(self_state.get("tree_ghost", false)),
		"route_size": _physics_route.size(), "next_kind": str(route_next.get("kind", "")),
		"next_tile": [next_tile.x, next_tile.y],
	})


func _made_bounded_route_progress(decision: Dictionary, reason: String) -> bool:
	if reason != "timeout" or str(decision.get("action", "")) != Contract.ACTION_MOVE_TO:
		return false
	var target_id := str(decision.get("target_id", ""))
	if not (target_id.begins_with("container:") or target_id.begins_with("pit-return:")):
		return false
	var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	if not target.has("position") or not target.has("distance") or self_state.is_empty():
		return false
	var initial_distance := float(target.get("distance", INF))
	var current_distance := Contract.distance_between(self_state, target)
	return is_finite(initial_distance) and initial_distance - current_distance >= float(BlockDefs.TILE) * 0.5


func _on_executor_action_failed(decision: Dictionary, reason: String) -> void:
	_clear_aborted_movement_transition_if_needed(decision, reason)
	_note_flee_route_failure(decision, reason)
	if bool(decision.get("descent_transition", false)):
		_descent_planner.cancel_intended_transition()
	_stone_age_note_failure(decision, reason, Time.get_ticks_msec())
	_achievement_goal_note_failure(decision, reason, Time.get_ticks_msec())
	_record_action_history("failed", decision, reason)


func _note_flee_route_failure(decision: Dictionary, reason: String) -> void:
	if str(decision.get("action", "")) != Contract.ACTION_FLEE_FROM:
		return
	if behavior == null or behavior.provider == null or not behavior.provider.has_method("note_flee_route_failure"):
		return
	behavior.provider.call(
		"note_flee_route_failure",
		str(decision.get("target_id", "")),
		reason,
		Time.get_ticks_msec(),
	)


func _clear_aborted_movement_transition_if_needed(decision: Dictionary, reason: String) -> void:
	var action := str(decision.get("action", ""))
	if action not in [Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_MOVE_TO, Contract.ACTION_FOLLOW, Contract.ACTION_FLEE_FROM, Contract.ACTION_LOOK_AT]:
		return
	if reason in ["movement_step", "jump_step", "climb_step", "look_complete", "already_at_target", "movement_done", "route_progress"]:
		return
	# A terminal guard, timeout, or cancellation can end an action halfway through
	# a locally predicted transition. Do not carry its held jump/climb state into
	# the next target; ordinary physics still resolves the current airborne pose.
	_active_air_transition.clear()
	_jump_active = false
	_jump_predicted_landed = false
	_jump_started_msec = -1
	_jump_velocity = 0.0
	_jump_ground_y = 0.0
	_jump_start_x = 0.0
	_climb_active = false
	_climb_column = 0
	_climb_time_left_msec = 0
	_set_desired_input(false, false, false)
	var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
	if not self_state.is_empty():
		self_state["climbing"] = false
		self_state["climb_col"] = -1
		_world_snapshot["self"] = self_state


func _record_action_history(phase: String, decision: Dictionary, reason: String = "") -> void:
	if phase == "started" and not _initial_inventory_echo_logged:
		_action_started_before_inventory_echo = true
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
	# Mirror the action-history phase into the structured journal. This is a
	# privacy-safe projection that omits target_id and any player, name, or
	# coordinate detail, so live journals reveal started/finished/failed/
	# rejected/result outcomes without leaking identifying data.
	var log_event := {
		"event": "bot_action_history",
		"phase": phase,
		"action": str(decision.get("action", "")),
		"goal": str(decision.get("goal", "")),
		"at_msec": int(entry["at_msec"]),
	}
	if not reason.is_empty():
		log_event["reason"] = reason
	structured_log.emit(log_event)


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
	var target_id := str(payload.get("target_id", ""))
	if target_id.is_empty() and action == "mine_block" and payload.has("x") and payload.has("y"):
		target_id = "tile:%d:%d" % [int(payload.get("x", 0)), int(payload.get("y", 0))]
	_record_action_history("result", {
		"action": action,
		"target_id": target_id,
	}, "accepted" if bool(payload.get("accepted", false)) else "rejected")
	if action == "mine_block" and payload.has("block_id"):
		# The host's action acknowledgement carries the authoritative post-action
		# tile state. Apply it even on rejection: a block may already have changed
		# while the bot's region/tile update was in flight, and retaining the stale
		# local block makes policy retry the same impossible mine after cooldown.
		_apply_tile_batch({"tiles": [payload]})
		var plant_state: Variant = payload.get("plant", null)
		if plant_state is Dictionary:
			_ingest_plant_entry(plant_state as Dictionary)
	if action == "equip_item":
		var pending_equip: Dictionary = _pending_action_targets.get("equip", {}) if _pending_action_targets.get("equip", {}) is Dictionary else {}
		_pending_action_targets.erase("equip")
		if bool(payload.get("accepted", false)) and payload.get("equipment_slots", null) is Dictionary:
			_equipment_slots = (payload.get("equipment_slots") as Dictionary).duplicate(true)
			_stone_age_authoritative_equipment = _equipment_from_player_state({"equipment_slots": payload.get("equipment_slots", {})})
			_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
		elif bool(payload.get("accepted", false)):
			# The host's positive equip acknowledgement is authoritative even on
			# older peers that omit the full slots object from action_result.
			var accepted_item := str(pending_equip.get("item", ""))
			if not accepted_item.is_empty():
				var accepted_slot := "feet" if accepted_item.ends_with("_boots") or accepted_item.ends_with("_sandals") else "hand"
				_stone_age_authoritative_equipment[accepted_slot] = accepted_item
				_equipment_slots[accepted_slot] = accepted_item
				_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
		elif not bool(payload.get("accepted", false)):
			# Roll back the optimistic hand/feet slot so a rejected equip does not
			# permanently look equipped and starve later tool swaps.
			var rejected_item := str(pending_equip.get("item", ""))
			for slot_name in ["hand", "feet"]:
				if str(_equipment_slots.get(slot_name, "")) == rejected_item:
					_equipment_slots[slot_name] = ""
			_world_snapshot["equipment_slots"] = _equipment_slots.duplicate(true)
			_stone_age_fail_pending(str(pending_equip.get("stone_age_stage", "")), "equip_rejected", Time.get_ticks_msec())
		_sync_stone_age_goal(_achievement_observation(), Time.get_ticks_msec())
		return
	if action == "open_container":
		var container_key := "%d:%d" % [int(payload.get("x", 0)), int(payload.get("y", 0))]
		var pending_container: Dictionary = _pending_action_targets.get(container_key, {}) if _pending_action_targets.get(container_key, {}) is Dictionary else {}
		_pending_action_targets.erase(container_key)
		var accepted := bool(payload.get("accepted", false))
		if not accepted:
			_blocked_action_targets["container:%s" % container_key] = Time.get_ticks_msec() + CONTAINER_RETRY_BLOCK_MSEC
		else:
			_blocked_action_targets.erase("container:%s" % container_key)
		var container_data: Dictionary = payload.get("container", {}) if payload.get("container", {}) is Dictionary else {}
		var generated_chest := bool(pending_container.get("generated", false)) or (
			not str(container_data.get("loot_key", "")).is_empty()
			and not bool(container_data.get("death_cache", false))
			and not bool(container_data.get("one_use_cache", false))
		)
		if accepted and not _is_pvp_world() and generated_chest:
			_opened_generated_chest_cells[container_key] = true
		if _should_award_death_cache_recovery(accepted, str(pending_container.get("owner_player_id", ""))) and bool(pending_container.get("death_cache", false)):
			var achievements := get_node_or_null("/root/Achievements")
			if achievements != null and achievements.has_method("record_death_cache_recovered"):
				achievements.call("record_death_cache_recovered")
		if accepted and _is_pvp_world():
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
			_stone_age_fail_pending(str(craft.get("stone_age_stage", "")), "craft_rejected", Time.get_ticks_msec())
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
		if accepted:
			_record_craft_achievement(output)
		_sync_stone_age_goal(_achievement_observation(), Time.get_ticks_msec())
		return
	if not bool(payload.get("accepted", false)):
		var rejected_key := "%d:%d" % [int(payload.get("x", 0)), int(payload.get("y", 0))]
		var retry_delay := MINE_REJECTION_RETRY_MSEC if action == "mine_block" else ACTION_RETRY_BLOCK_MSEC
		_blocked_action_targets["tile:%s" % rejected_key] = Time.get_ticks_msec() + retry_delay
		var rejected_target: Dictionary = _pending_action_targets.get(rejected_key, {}) if _pending_action_targets.get(rejected_key, {}) is Dictionary else {}
		_stone_age_fail_pending(str(rejected_target.get("stone_age_stage", "")), "action_rejected", Time.get_ticks_msec())
		_pending_action_targets.erase(rejected_key)
		if action == "place_block":
			# An accepted placement may be followed by a delayed rejection for a
			# duplicate request against the same occupied cell. Keep its confirmed
			# protection, or the planner mines and replaces the bridge forever.
			if not bool((_protected_build_cells.get(rejected_key, {}) as Dictionary).get("confirmed", false)):
				_protected_build_cells.erase(rejected_key)
			_note_build_project_failure(rejected_target, "place_rejected", Time.get_ticks_msec())
		if action == "mine_block" and behavior != null and behavior.executor != null and behavior.executor.current_action() == Contract.ACTION_MINE:
			behavior.executor.cancel("mine_rejected")
		return
	var key := "%d:%d" % [int(payload.get("x", 0)), int(payload.get("y", 0))]
	var target: Dictionary = _pending_action_targets.get(key, {}) if _pending_action_targets.get(key, {}) is Dictionary else {}
	_pending_action_targets.erase(key)
	# A successful obstacle mine may immediately regrow (ice over moving
	# water, granular refill, etc.). Do not reinterpret that same cell as a
	# fresh route obstruction every few seconds. Ordinary resource mining and
	# the deliberate renewable-stone generator remain repeatable.
	if action == "mine_block" and bool(target.get("dig_route", false)):
		_blocked_action_targets["tile:%s" % key] = Time.get_ticks_msec() + DIG_ROUTE_CLEAR_REVISIT_MSEC
	elif not (action == "mine_block" and target.is_empty()):
		# A duplicate acknowledgement has no pending decision and must not erase
		# the cooldown established by the first accepted result.
		_blocked_action_targets.erase("tile:%s" % key)
	if action == "place_block":
		var protected_cell: Dictionary = _protected_build_cells.get(key, {}) if _protected_build_cells.get(key, {}) is Dictionary else {}
		if not target.is_empty() or not protected_cell.is_empty():
			protected_cell["confirmed"] = true
			if str(protected_cell.get("block", "")).is_empty():
				protected_cell["block"] = str(target.get("block", ""))
			_protected_build_cells[key] = protected_cell
			_save_protected_build_cell(key)
		_note_build_project_placement(target, key, Time.get_ticks_msec())
	if action == "mine_block" and behavior != null and behavior.executor != null and behavior.executor.current_action() == Contract.ACTION_MINE:
		behavior.executor.cancel("mine_acknowledged")
	if action == "mine_block" and bool(target.get("one_block_source", false)):
		_record_accepted_one_block_mine(int(target.get("one_block_mined_before", 0)))
	_sync_stone_age_goal(_achievement_observation(), Time.get_ticks_msec())
	var achievements := get_node_or_null("/root/Achievements")
	if achievements == null:
		return
	if action == "mine_block" and achievements.has_method("record_block_mined"):
		achievements.call("record_block_mined", _block_name_for_content_id(str(target.get("content_id", ""))))
	elif action == "place_block" and achievements.has_method("record_block_placed"):
		achievements.call("record_block_placed", str(target.get("block", "")))


func _should_award_death_cache_recovery(accepted: bool, owner_player_id: String) -> bool:
	return accepted and not own_player_id.is_empty() and not owner_player_id.is_empty() and owner_player_id == own_player_id


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
	_clear_achievements_community_lock()
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
	var observation: Dictionary = {"unlocked": [], "open": []}
	if achievements != null and achievements.has_method("observation_for_bot"):
		var payload: Variant = achievements.call("observation_for_bot")
		if payload is Dictionary:
			observation = (payload as Dictionary).duplicate(true)
	elif achievements != null and achievements.has_method("unlocked_ids"):
		observation["unlocked"] = achievements.call("unlocked_ids")
	if achievements != null:
		if achievements.has_method("is_community_locked"):
			observation["community_locked"] = bool(achievements.call("is_community_locked"))
		else:
			observation["community_locked"] = bool(achievements.get("community_locked"))
	return observation


func _sync_mid_tier_tool_goal(now_msec: int = -1) -> void:
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	var mode := str(generation.get("mode", _session_world_mode)).strip_edges().to_lower()
	if world_id.is_empty():
		_mid_tier_tool_goal_state.clear()
		return
	if (
		str(_mid_tier_tool_goal_state.get("world_id", "")) != world_id
		or str(_mid_tier_tool_goal_state.get("world_mode", "")) != mode
	):
		_mid_tier_tool_goal_state = {
			"world_id": world_id,
			"world_mode": mode,
			"status": "idle",
			"output": "",
			"completed_outputs": {},
			"exhausted_outputs": {},
			"retry_after_by_output": {},
			"search_attempts": {},
			"search_item": "",
			"search_started_msec": -1,
			"search_deadline_msec": -1,
			"search_without_frontier": false,
			"search_inventory_count": 0,
			"search_source_mined": -1,
		}
	var achievements := _achievement_observation()
	var mode_allowed := (
		mode in AchievementRegistryClass.TOOL_PROGRESSION_MODES
		and not _is_pvp_world()
		and not bool(achievements.get("community_locked", false))
	)
	if not mode_allowed:
		_mid_tier_tool_goal_state["status"] = "paused"
		_mid_tier_tool_goal_state["search_item"] = ""
		_mid_tier_tool_goal_state["search_started_msec"] = -1
		_mid_tier_tool_goal_state["search_deadline_msec"] = -1
		_mid_tier_tool_goal_state["search_without_frontier"] = false
		return
	var stone_goal: Dictionary = _stone_age_goal_state if _stone_age_goal_state is Dictionary else {}
	if (
		str(stone_goal.get("goal_id", "")) in ["stone_age", "starter_tooling"]
		and str(stone_goal.get("status", "")) != "completed"
		and str(stone_goal.get("stage", "")) != "complete"
	):
		_mid_tier_tool_goal_state["status"] = "paused"
		_mid_tier_tool_goal_state["search_item"] = ""
		_mid_tier_tool_goal_state["search_started_msec"] = -1
		_mid_tier_tool_goal_state["search_deadline_msec"] = -1
		_mid_tier_tool_goal_state["search_without_frontier"] = false
		return
	_mid_tier_tool_goal_state["status"] = "active"
	var inventory: Dictionary = _stone_age_authoritative_inventory
	if inventory.is_empty():
		inventory = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
	var output := str(_mid_tier_tool_goal_state.get("output", ""))
	var search_item := str(_mid_tier_tool_goal_state.get("search_item", ""))
	var search_started := int(_mid_tier_tool_goal_state.get("search_started_msec", -1))
	var search_deadline := int(_mid_tier_tool_goal_state.get("search_deadline_msec", -1))
	if not output.is_empty() and search_started >= 0 and not search_item.is_empty():
		var progress_made := false
		var item_count := int(inventory.get(search_item, 0))
		var previous_item_count := int(_mid_tier_tool_goal_state.get("search_inventory_count", item_count))
		if item_count > previous_item_count:
			_mid_tier_tool_goal_state["search_inventory_count"] = item_count
			progress_made = true
		if mode == "one_block":
			var source_mined := int(_mode_progress_from_snapshot().get("one_block_mined", 0))
			var previous_source_mined := int(_mid_tier_tool_goal_state.get("search_source_mined", source_mined))
			if source_mined > previous_source_mined:
				_mid_tier_tool_goal_state["search_source_mined"] = source_mined
				progress_made = true
		if progress_made:
			_mid_tier_tool_goal_state["search_deadline_msec"] = maxi(search_deadline, now_msec + MID_TIER_TOOL_SEARCH_TIMEOUT_MSEC)
	if not output.is_empty() and int(inventory.get(output, 0)) > 0:
		var completed: Dictionary = _mid_tier_tool_goal_state.get("completed_outputs", {}) if _mid_tier_tool_goal_state.get("completed_outputs", {}) is Dictionary else {}
		completed[output] = true
		_mid_tier_tool_goal_state["completed_outputs"] = completed
		structured_log.emit({
			"event": "tool_progression_completed",
			"output": output,
			"world_id": world_id,
			"world_mode": mode,
			"at_msec": now_msec,
		})
		_mid_tier_tool_goal_state["output"] = ""
		_mid_tier_tool_goal_state["search_item"] = ""
		_mid_tier_tool_goal_state["search_started_msec"] = -1
		_mid_tier_tool_goal_state["search_deadline_msec"] = -1
		_mid_tier_tool_goal_state["search_without_frontier"] = false
		_mid_tier_tool_goal_state["search_inventory_count"] = 0
		_mid_tier_tool_goal_state["search_source_mined"] = -1
		_mid_tier_tool_goal_state["status"] = "idle"
		output = ""
	search_started = int(_mid_tier_tool_goal_state.get("search_started_msec", -1))
	search_deadline = int(_mid_tier_tool_goal_state.get("search_deadline_msec", -1))
	if not output.is_empty() and search_started >= 0 and search_deadline >= 0 and now_msec >= search_deadline:
		var attempts: Dictionary = _mid_tier_tool_goal_state.get("search_attempts", {}) if _mid_tier_tool_goal_state.get("search_attempts", {}) is Dictionary else {}
		var attempt_count := int(attempts.get(output, 0)) + 1
		attempts[output] = attempt_count
		_mid_tier_tool_goal_state["search_attempts"] = attempts
		_mid_tier_tool_goal_state["search_item"] = ""
		_mid_tier_tool_goal_state["search_started_msec"] = -1
		_mid_tier_tool_goal_state["search_deadline_msec"] = -1
		_mid_tier_tool_goal_state["search_without_frontier"] = false
		if attempt_count >= MID_TIER_TOOL_MAX_SEARCH_ATTEMPTS:
			var exhausted: Dictionary = _mid_tier_tool_goal_state.get("exhausted_outputs", {}) if _mid_tier_tool_goal_state.get("exhausted_outputs", {}) is Dictionary else {}
			exhausted[output] = true
			_mid_tier_tool_goal_state["exhausted_outputs"] = exhausted
			_mid_tier_tool_goal_state["output"] = ""
			_mid_tier_tool_goal_state["status"] = "idle"
			structured_log.emit({"event": "tool_progression_search_exhausted", "output": output, "world_id": world_id, "world_mode": mode, "at_msec": now_msec})
		else:
			var retries: Dictionary = _mid_tier_tool_goal_state.get("retry_after_by_output", {}) if _mid_tier_tool_goal_state.get("retry_after_by_output", {}) is Dictionary else {}
			retries[output] = now_msec + MID_TIER_TOOL_SEARCH_RETRY_MSEC
			_mid_tier_tool_goal_state["retry_after_by_output"] = retries
			_mid_tier_tool_goal_state["output"] = ""
			_mid_tier_tool_goal_state["status"] = "cooldown"
			structured_log.emit({"event": "tool_progression_search_cooldown", "output": output, "attempt": attempt_count, "world_id": world_id, "world_mode": mode, "at_msec": now_msec})
	var retries: Dictionary = _mid_tier_tool_goal_state.get("retry_after_by_output", {}) if _mid_tier_tool_goal_state.get("retry_after_by_output", {}) is Dictionary else {}
	for raw_output in retries.keys():
		if now_msec >= int(retries[raw_output]):
			retries.erase(raw_output)
	_mid_tier_tool_goal_state["retry_after_by_output"] = retries


func _mid_tier_tool_note_action_started(decision: Dictionary, now_msec: int) -> void:
	var output := str(decision.get("mid_tier_tool_output", ""))
	if output.is_empty() or _mid_tier_tool_goal_state.is_empty():
		return
	var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	var current_mode := str(generation.get("mode", _session_world_mode)).strip_edges().to_lower()
	if str(_mid_tier_tool_goal_state.get("world_id", "")) != world_id or str(_mid_tier_tool_goal_state.get("world_mode", "")) != current_mode:
		return
	if output != str(_mid_tier_tool_goal_state.get("output", "")):
		_mid_tier_tool_goal_state["output"] = output
		_mid_tier_tool_goal_state["search_item"] = ""
		_mid_tier_tool_goal_state["search_started_msec"] = -1
		_mid_tier_tool_goal_state["search_deadline_msec"] = -1
		_mid_tier_tool_goal_state["search_without_frontier"] = false
		_mid_tier_tool_goal_state["search_inventory_count"] = 0
		_mid_tier_tool_goal_state["search_source_mined"] = -1
		_mid_tier_tool_goal_state["status"] = "active"
	if bool(decision.get("mid_tier_tool_search", false)):
		var missing_item := str(decision.get("mid_tier_tool_missing_item", ""))
		var no_frontier := bool(decision.get("mid_tier_tool_no_frontier", false))
		var starts_new_search := (
			missing_item != str(_mid_tier_tool_goal_state.get("search_item", ""))
			or int(_mid_tier_tool_goal_state.get("search_started_msec", -1)) < 0
		)
		if starts_new_search:
			_mid_tier_tool_goal_state["search_item"] = missing_item
			_mid_tier_tool_goal_state["search_started_msec"] = now_msec
			_mid_tier_tool_goal_state["search_deadline_msec"] = now_msec + (MID_TIER_TOOL_NO_FRONTIER_TIMEOUT_MSEC if no_frontier else MID_TIER_TOOL_SEARCH_TIMEOUT_MSEC)
			var inventory: Dictionary = _stone_age_authoritative_inventory
			if inventory.is_empty():
				inventory = _world_snapshot.get("inventory_summary", {}) if _world_snapshot.get("inventory_summary", {}) is Dictionary else {}
			_mid_tier_tool_goal_state["search_inventory_count"] = int(inventory.get(missing_item, 0))
			_mid_tier_tool_goal_state["search_source_mined"] = int(_mode_progress_from_snapshot().get("one_block_mined", -1)) if current_mode == "one_block" else -1
		elif (
			bool(_mid_tier_tool_goal_state.get("search_without_frontier", false))
			and not no_frontier
			and int(_mid_tier_tool_goal_state.get("search_deadline_msec", -1)) <= int(_mid_tier_tool_goal_state.get("search_started_msec", -1)) + MID_TIER_TOOL_NO_FRONTIER_TIMEOUT_MSEC
		):
			# A frontier or renewable source became available before the short idle
			# bound expired. Upgrade it once to a real search window; subsequent
			# WAIT↔MINE alternation never restarts that deadline.
			_mid_tier_tool_goal_state["search_deadline_msec"] = maxi(
				int(_mid_tier_tool_goal_state.get("search_deadline_msec", -1)),
				now_msec + MID_TIER_TOOL_SEARCH_TIMEOUT_MSEC,
			)
		_mid_tier_tool_goal_state["search_without_frontier"] = no_frontier
		_mid_tier_tool_goal_state["status"] = "searching"
	else:
		_mid_tier_tool_goal_state["search_item"] = ""
		_mid_tier_tool_goal_state["search_started_msec"] = -1
		_mid_tier_tool_goal_state["search_deadline_msec"] = -1
		_mid_tier_tool_goal_state["search_without_frontier"] = false
		_mid_tier_tool_goal_state["search_inventory_count"] = 0
		_mid_tier_tool_goal_state["search_source_mined"] = -1
		_mid_tier_tool_goal_state["status"] = "active"


func _sync_stone_age_goal(achievements: Dictionary, now_msec: int = -1) -> void:
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	var mode := str((_world_snapshot.get("generation", {}) as Dictionary).get("mode", _session_world_mode)).to_lower() if _world_snapshot.get("generation", {}) is Dictionary else _session_world_mode
	_sync_achievement_goal_states(achievements, mode, now_msec)
	var state_world_id := str(_stone_age_goal_state.get("world_id", ""))
	if not state_world_id.is_empty() and (state_world_id != world_id or str(_stone_age_goal_state.get("world_mode", "")) != mode):
		_stone_age_goal_state.clear()
	var unlocked: Array = achievements.get("unlocked", []) if achievements.get("unlocked", []) is Array else []
	var open_goals: Array = achievements.get("open", []) if achievements.get("open", []) is Array else []
	var stone_age_open := false
	for raw_goal in open_goals:
		if raw_goal is Dictionary and str((raw_goal as Dictionary).get("id", "")) == "stone_age" and not bool((raw_goal as Dictionary).get("locked", false)):
			stone_age_open = true
			break
	var community_locked := bool(achievements.get("community_locked", false))
	if _stone_age_goal_state.is_empty():
		if not _stone_age_progression_allowed(mode) or world_id.is_empty():
			return
		var goal_id := ""
		if not community_locked and stone_age_open and "stone_age" not in unlocked:
			goal_id = "stone_age"
		elif _starter_tooling_needed():
			goal_id = "starter_tooling"
		if goal_id.is_empty():
			return
		_stone_age_goal_state = {
			"world_id": world_id,
			"world_mode": mode,
			"goal_id": goal_id,
			"achievement_id": "stone_age" if goal_id == "stone_age" else "",
			"stage": "gather_wood",
			"status": "active",
			"stage_failures": 0,
			"stage_attempts": 0,
			"no_action_failures": 0,
			"no_action_since_msec": -1,
			"retry_after_msec": 0,
			"pending": {},
		}
		structured_log.emit({"event": "goal_selected", "goal": goal_id, "stage": "gather_wood", "world_id": world_id, "world_mode": mode, "at_msec": now_msec})
	if not _stone_age_progression_allowed(mode):
		_stone_age_goal_state["status"] = "paused"
		_stone_age_goal_state["no_action_since_msec"] = -1
		return
	if community_locked and _stone_age_goal_name() == "stone_age":
		_stone_age_goal_state["status"] = "paused"
		_stone_age_goal_state["no_action_since_msec"] = -1
		return
	if str(_stone_age_goal_state.get("status", "")) == "completed":
		return
	if str(_stone_age_goal_state.get("status", "")) in ["cooldown", "abandoned"]:
		if now_msec < int(_stone_age_goal_state.get("retry_after_msec", 0)):
			return
		_stone_age_goal_state["status"] = "active"
		_stone_age_goal_state["stage_failures"] = 0
		_stone_age_goal_state["retry_after_msec"] = 0
		structured_log.emit({"event": "goal_resumed", "goal": _stone_age_goal_name(), "stage": str(_stone_age_goal_state.get("stage", "")), "world_id": world_id, "at_msec": now_msec})
	elif str(_stone_age_goal_state.get("status", "")) == "paused":
		_stone_age_goal_state["status"] = "active"
		_stone_age_goal_state["no_action_since_msec"] = -1
	_stone_age_confirm_pending_if_observed(now_msec)
	var next_stage := _stone_age_authoritative_stage()
	var previous_stage := str(_stone_age_goal_state.get("stage", ""))
	if next_stage == "complete":
		_stone_age_goal_state["stage"] = "complete"
		_stone_age_goal_state["status"] = "completed"
		_stone_age_goal_state["pending"] = {}
		_stone_age_goal_state["no_action_since_msec"] = -1
		_stone_age_goal_state["no_action_failures"] = 0
		structured_log.emit({"event": "goal_completed", "goal": _stone_age_goal_name(), "world_id": world_id, "at_msec": now_msec})
		return
	if next_stage != previous_stage:
		_stone_age_goal_state["stage"] = next_stage
		_stone_age_goal_state["stage_failures"] = 0
		_stone_age_goal_state["stage_attempts"] = 0
		_stone_age_goal_state["no_action_failures"] = 0
		_stone_age_goal_state["no_action_since_msec"] = -1
		_stone_age_goal_state["retry_after_msec"] = 0
		_stone_age_goal_state["pending"] = {}
		structured_log.emit({"event": "step_confirmed", "goal": _stone_age_goal_name(), "previous_stage": previous_stage, "stage": next_stage, "world_id": world_id, "at_msec": now_msec})
	var details := _stone_age_stage_details(next_stage)
	_stone_age_goal_state["required_planks"] = int(details.get("required_planks", 0))
	_stone_age_goal_state["target_output"] = str(details.get("target_output", ""))


func _stone_age_progression_allowed(mode: String) -> bool:
	mode = mode.strip_edges().to_lower()
	return (
		mode in AchievementRegistryClass.stone_age_progression_modes()
		and mode not in ["challenge_run", "duel", "pvp"]
		and not _is_pvp_world()
	)


func _stone_age_goal_name() -> String:
	var goal_id := str(_stone_age_goal_state.get("goal_id", "stone_age"))
	return goal_id if goal_id in ["stone_age", "starter_tooling"] else "stone_age"


func _starter_tooling_needed() -> bool:
	# A fresh world should bootstrap the bot to a stone-tier pickaxe when a
	# persisted achievement profile would otherwise suppress the Stone Age
	# strategy. Existing stone-tier or better pickaxes make the fallback moot.
	for raw_name in _stone_age_authoritative_inventory:
		var item_name := str(raw_name).to_lower()
		if item_name.ends_with("_pickaxe") and _stone_age_tool_tier(item_name) >= 2 and int(_stone_age_authoritative_inventory[raw_name]) > 0:
			return false
	var equipped_hand := str(_stone_age_authoritative_equipment.get("hand", "")).to_lower()
	return not (equipped_hand.ends_with("_pickaxe") and _stone_age_tool_tier(equipped_hand) >= 2)


func _sync_achievement_goal_states(achievements: Dictionary, mode: String, now_msec: int) -> void:
	mode = mode.strip_edges().to_lower()
	var state_world_id := str(_achievement_goal_states.get("_world_id", ""))
	var state_world_mode := str(_achievement_goal_states.get("_world_mode", ""))
	if not state_world_id.is_empty() and (state_world_id != world_id or state_world_mode != mode):
		_achievement_goal_states.clear()
		_achievement_goal_unlocked_baseline.clear()
	if world_id.is_empty():
		_achievement_goal_states.clear()
		_achievement_goal_unlocked_baseline.clear()
		return
	_achievement_goal_states["_world_id"] = world_id
	_achievement_goal_states["_world_mode"] = mode
	var unlocked: Array = achievements.get("unlocked", []) if achievements.get("unlocked", []) is Array else []
	# Snapshot the persisted unlock set exactly once per world. A goal that is
	# already unlocked here is baseline credit; only ids missing from this
	# snapshot can report goal_completed during the session.
	if str(_achievement_goal_unlocked_baseline.get("_world_id", "")) != world_id:
		_achievement_goal_unlocked_baseline.clear()
		_achievement_goal_unlocked_baseline["_world_id"] = world_id
		for raw_unlocked_goal in unlocked:
			_achievement_goal_unlocked_baseline[str(raw_unlocked_goal)] = true
	var open_by_id: Dictionary = {}
	for raw_goal in achievements.get("open", []) if achievements.get("open", []) is Array else []:
		if not raw_goal is Dictionary:
			continue
		var goal := raw_goal as Dictionary
		var goal_id := str(goal.get("id", ""))
		if not goal_id.is_empty() and not bool(goal.get("locked", false)):
			open_by_id[goal_id] = goal
	var community_locked := bool(achievements.get("community_locked", false))
	for goal_id in AchievementRegistryClass.tracked_goal_ids():
		var entry: Dictionary = _achievement_goal_states.get(goal_id, {}) if _achievement_goal_states.get(goal_id, {}) is Dictionary else {}
		if goal_id in unlocked:
			var was_completed := str(entry.get("status", "")) == "completed"
			if entry.is_empty():
				entry = {"achievement_id": goal_id, "failures": 0, "attempts": 0, "pending": {}}
			entry["status"] = "completed"
			entry["pending"] = {}
			entry["world_id"] = world_id
			entry["world_mode"] = mode
			_achievement_goal_states[goal_id] = entry
			if not was_completed:
				if not _achievement_goal_unlocked_baseline.has(goal_id):
					structured_log.emit({"event": "goal_completed", "goal": goal_id, "world_id": world_id, "world_mode": mode, "at_msec": now_msec})
			continue
		if not _achievement_goal_mode_allowed(goal_id, mode):
			if not entry.is_empty():
				entry["status"] = "paused"
				_achievement_goal_states[goal_id] = entry
			continue
		if community_locked:
			if not entry.is_empty():
				entry["status"] = "paused"
				_achievement_goal_states[goal_id] = entry
			continue
		if not open_by_id.has(goal_id):
			if not entry.is_empty() and str(entry.get("status", "")) not in ["completed", "cooldown", "abandoned"]:
				entry["status"] = "inactive"
				entry["pending"] = {}
				_achievement_goal_states[goal_id] = entry
			continue
		var open_goal: Dictionary = open_by_id[goal_id]
		if entry.is_empty():
			entry = {
				"achievement_id": goal_id,
				"world_id": world_id,
				"world_mode": mode,
				"status": "active",
				"progress": maxi(0, int(open_goal.get("progress", 0))),
				"failures": 0,
				"attempts": 0,
				"retry_after_msec": 0,
				"pending": {},
			}
			_achievement_goal_states[goal_id] = entry
			structured_log.emit({"event": "goal_selected", "goal": goal_id, "world_id": world_id, "world_mode": mode, "at_msec": now_msec})
		var progress := maxi(0, int(open_goal.get("progress", 0)))
		var previous_progress := int(entry.get("progress", progress))
		if progress > previous_progress:
			var pending: Dictionary = entry.get("pending", {}) if entry.get("pending", {}) is Dictionary else {}
			structured_log.emit({"event": "step_confirmed", "goal": goal_id, "step": str(pending.get("step", "achievement_progress")), "source": "achievement_progress", "progress": progress, "world_id": world_id, "at_msec": now_msec})
			entry["pending"] = {}
			entry["failures"] = 0
			entry["retry_after_msec"] = 0
			entry["status"] = "active"
		entry["progress"] = progress
		entry["world_id"] = world_id
		entry["world_mode"] = mode
		_achievement_goal_confirm_pending_if_observed(goal_id, entry, now_msec)
		var status := str(entry.get("status", "active"))
		if status in ["cooldown", "abandoned"] and now_msec >= int(entry.get("retry_after_msec", 0)):
			if status == "abandoned":
				entry["failures"] = 0
			entry["status"] = "active"
			entry["retry_after_msec"] = 0
			structured_log.emit({"event": "goal_resumed", "goal": goal_id, "world_id": world_id, "world_mode": mode, "at_msec": now_msec})
		elif status in ["paused", "inactive"]:
			entry["status"] = "active"
			entry["pending"] = {}
			structured_log.emit({"event": "goal_resumed", "goal": goal_id, "world_id": world_id, "world_mode": mode, "at_msec": now_msec})
		_achievement_goal_states[goal_id] = entry


func _achievement_goal_mode_allowed(goal_id: String, mode: String) -> bool:
	return AchievementRegistryClass.goal_mode_allowed(goal_id, mode)


func _achievement_goal_step_id(decision: Dictionary) -> String:
	var action := str(decision.get("action", ""))
	var target_id := str(decision.get("target_id", ""))
	if target_id.is_empty():
		var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
		if target.has("x") or target.has("y"):
			target_id = "%s:%s" % [str(target.get("x", "")), str(target.get("y", ""))]
	return "%s:%s" % [action, target_id]


func _achievement_goal_note_action_started(decision: Dictionary, now_msec: int) -> void:
	var goal_id := str(decision.get("achievement_goal_id", ""))
	if goal_id.is_empty():
		return
	var entry: Dictionary = _achievement_goal_states.get(goal_id, {}) if _achievement_goal_states.get(goal_id, {}) is Dictionary else {}
	if entry.is_empty() or str(entry.get("status", "")) != "active":
		return
	var step_id := _achievement_goal_step_id(decision)
	var pending: Dictionary = entry.get("pending", {}) if entry.get("pending", {}) is Dictionary else {}
	if str(pending.get("step", "")) == step_id:
		return
	var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
	var expected_item := ""
	var action := str(decision.get("action", ""))
	if action == Contract.ACTION_CRAFT:
		expected_item = str(decision.get("target_id", ""))
	var expected_slot := ""
	if action == Contract.ACTION_EQUIP:
		var equipped_item := str(decision.get("target_id", ""))
		expected_slot = "feet" if equipped_item.ends_with("_boots") or equipped_item.ends_with("_sandals") else "hand"
	pending = {
		"step": step_id,
		"action": action,
		"target_id": str(decision.get("target_id", "")),
		"started_at_msec": now_msec,
		"expected_item": expected_item,
		"baseline_inventory": int(_stone_age_authoritative_inventory.get(expected_item, 0)) if not expected_item.is_empty() else 0,
		"expected_equipment": str(decision.get("target_id", "")) if action == Contract.ACTION_EQUIP else "",
		"expected_equipment_slot": expected_slot,
		"target_position": target.get("position", []),
		"target_x": int(target.get("x", 2147483647)),
		"target_y": int(target.get("y", 2147483647)),
		"expected_block": str(target.get("block_name", "")) if action == Contract.ACTION_MINE else str(decision.get("block", "")) if action == Contract.ACTION_PLACE else "",
	}
	entry["pending"] = pending
	entry["attempts"] = int(entry.get("attempts", 0)) + 1
	_achievement_goal_states[goal_id] = entry
	structured_log.emit({"event": "step_started", "goal": goal_id, "step": step_id, "world_id": world_id, "world_mode": _session_world_mode, "at_msec": now_msec})


func _achievement_goal_confirm_pending_if_observed(goal_id: String, entry: Dictionary, now_msec: int) -> void:
	var pending: Dictionary = entry.get("pending", {}) if entry.get("pending", {}) is Dictionary else {}
	if pending.is_empty():
		return
	var confirmed := false
	var expected_item := str(pending.get("expected_item", ""))
	if not expected_item.is_empty() and int(_stone_age_authoritative_inventory.get(expected_item, 0)) > int(pending.get("baseline_inventory", 0)):
		confirmed = true
	var expected_equipment := str(pending.get("expected_equipment", ""))
	var expected_slot := str(pending.get("expected_equipment_slot", "hand"))
	if not expected_equipment.is_empty() and str(_stone_age_authoritative_equipment.get(expected_slot, "")) == expected_equipment:
		confirmed = true
	var expected_block := str(pending.get("expected_block", ""))
	var target_x := int(pending.get("target_x", 2147483647))
	var target_y := int(pending.get("target_y", 2147483647))
	if not confirmed and not expected_block.is_empty() and target_x != 2147483647 and target_y != 2147483647:
		var observed_block := str(_terrain_tiles.get("%d:%d" % [target_x, target_y], ""))
		confirmed = observed_block.is_empty() if str(pending.get("action", "")) == Contract.ACTION_MINE else observed_block == expected_block
	var target_position: Variant = pending.get("target_position", [])
	if not confirmed and target_position is Array and (target_position as Array).size() >= 2:
		var self_state: Dictionary = _world_snapshot.get("self", {}) if _world_snapshot.get("self", {}) is Dictionary else {}
		var current_position := Vector2(float(self_state.get("x", 0.0)), float(self_state.get("y", 0.0)))
		var expected_position := Contract.target_position(target_position)
		confirmed = current_position.distance_to(expected_position) <= BlockDefs.TILE * 1.5
	if not confirmed:
		return
	structured_log.emit({"event": "step_confirmed", "goal": goal_id, "step": str(pending.get("step", "")), "source": "world_state", "world_id": world_id, "at_msec": now_msec})
	entry["pending"] = {}
	entry["failures"] = 0
	entry["retry_after_msec"] = 0
	entry["status"] = "active"


func _achievement_goal_note_failure(decision: Dictionary, reason: String, now_msec: int) -> void:
	var goal_id := str(decision.get("achievement_goal_id", ""))
	if goal_id.is_empty():
		return
	var entry: Dictionary = _achievement_goal_states.get(goal_id, {}) if _achievement_goal_states.get(goal_id, {}) is Dictionary else {}
	var pending: Dictionary = entry.get("pending", {}) if entry.get("pending", {}) is Dictionary else {}
	if entry.is_empty() or str(entry.get("status", "")) != "active":
		return
	var step_id := _achievement_goal_step_id(decision)
	if pending.is_empty():
		# A policy/safety rejection happens before action_started, so it has no
		# pending step to fail. Record this rejected proposal as the failed step;
		# otherwise the provider can select the same unsafe achievement action
		# on every planning tick without entering the normal retry cooldown.
		pending = {"step": step_id}
		entry["pending"] = pending
	elif str(pending.get("step", "")) != step_id:
		return
	_achievement_goal_fail(goal_id, entry, reason, now_msec)


func _achievement_goal_fail(goal_id: String, entry: Dictionary, reason: String, now_msec: int) -> void:
	var pending: Dictionary = entry.get("pending", {}) if entry.get("pending", {}) is Dictionary else {}
	var failures := int(entry.get("failures", 0)) + 1
	var abandoned := failures >= ACHIEVEMENT_GOAL_MAX_FAILURES
	var delay := ACHIEVEMENT_GOAL_ABANDON_MSEC if abandoned else ACHIEVEMENT_GOAL_RETRY_MSEC
	entry["pending"] = {}
	entry["failures"] = failures
	entry["status"] = "abandoned" if abandoned else "cooldown"
	entry["retry_after_msec"] = now_msec + delay
	_achievement_goal_states[goal_id] = entry
	var log_entry := {
		"event": "goal_abandoned" if abandoned else "step_failed",
		"goal": goal_id,
		"step": str(pending.get("step", "")),
		"reason": reason,
		"failures": failures,
		"retry_after_msec": entry["retry_after_msec"],
		"world_id": world_id,
		"world_mode": _session_world_mode,
		"at_msec": now_msec,
	}
	if goal_id == "one_block_world" and reason == "route_unreachable":
		# Explain why a renewable source could not be reached without logging any
		# player identity or inventory data. The same snapshot feeds the safe
		# descent fallback, so this distinguishes missing coverage/support from a
		# valid step that simply did not approach the source.
		log_entry["safe_descent_plan"] = _descent_last_plan.duplicate(true)
		log_entry["safe_descent_verified"] = bool(_descent_last_plan.get("verified_safe_exit", false))
	structured_log.emit(log_entry)


func _expire_achievement_goal_pending(now_msec: int) -> void:
	for raw_goal_id in _achievement_goal_states.keys():
		var goal_id := str(raw_goal_id)
		if goal_id.begins_with("_"):
			continue
		var entry: Dictionary = _achievement_goal_states.get(goal_id, {}) if _achievement_goal_states.get(goal_id, {}) is Dictionary else {}
		var pending: Dictionary = entry.get("pending", {}) if entry.get("pending", {}) is Dictionary else {}
		if pending.is_empty():
			continue
		var timeout := ACHIEVEMENT_GOAL_MOVE_TIMEOUT_MSEC if str(pending.get("action", "")) in [Contract.ACTION_MOVE_TO, Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_FOLLOW] else ACHIEVEMENT_GOAL_CONFIRM_TIMEOUT_MSEC
		if now_msec - int(pending.get("started_at_msec", now_msec)) < timeout:
			continue
		_achievement_goal_fail(goal_id, entry, "authoritative_confirmation_timeout", now_msec)


func _stone_age_authoritative_stage() -> String:
	var inventory := _stone_age_authoritative_inventory
	if int(inventory.get("stone_pickaxe", 0)) > 0 and str(_stone_age_authoritative_equipment.get("hand", "")) == "stone_pickaxe":
		return "complete"
	if int(inventory.get("stone_pickaxe", 0)) > 0:
		return "equip_stone_pickaxe"
	if not _stone_age_has_tool_tier(inventory, 1):
		if _stone_age_has_plank_stack(inventory, 3):
			return "craft_wooden_pickaxe"
		if _stone_age_has_raw_wood(inventory):
			return "craft_planks"
		return "gather_wood"
	var has_workbench := _station_available(_world_snapshot, "workbench")
	if not has_workbench:
		if int(inventory.get("workbench", 0)) > 0:
			return "place_workbench"
		if _stone_age_has_plank_stack(inventory, 4):
			return "craft_workbench"
		if _stone_age_has_raw_wood(inventory):
			return "craft_planks"
		return "gather_wood"
	if not _stone_age_hand_has_tier(1):
		return "equip_cobblestone_tool"
	if int(inventory.get("cobblestone", 0)) < 2:
		return "mine_cobblestone"
	if _stone_age_has_plank_stack(inventory, 2):
		return "craft_stone_pickaxe"
	if _stone_age_has_raw_wood(inventory):
		return "craft_planks"
	return "gather_wood"


func _stone_age_stage_details(stage: String) -> Dictionary:
	match stage:
		"craft_wooden_pickaxe":
			return {"target_output": "wooden_pickaxe"}
		"craft_workbench":
			return {"target_output": "workbench"}
		"craft_stone_pickaxe":
			return {"target_output": "stone_pickaxe"}
		"craft_planks":
			var inventory := _stone_age_authoritative_inventory
			var needed := 3 if not _stone_age_has_tool_tier(inventory, 1) else (4 if not _station_available(_world_snapshot, "workbench") and int(inventory.get("workbench", 0)) <= 0 else 2)
			return {"required_planks": needed}
	return {}


func _stone_age_has_raw_wood(inventory: Dictionary) -> bool:
	for name in ["wood", "palm_wood", "pine_wood", "weeping_wood"]:
		if int(inventory.get(name, 0)) > 0:
			return true
	return false


func _stone_age_has_plank_stack(inventory: Dictionary, count: int) -> bool:
	for name in ["planks", "palm_planks", "pine_planks", "weeping_planks"]:
		if int(inventory.get(name, 0)) >= count:
			return true
	return false


func _stone_age_has_tool_tier(inventory: Dictionary, required_tier: int) -> bool:
	for raw_name in inventory:
		if int(inventory[raw_name]) <= 0:
			continue
		if _stone_age_tool_tier(str(raw_name)) >= required_tier:
			return true
	return false


func _stone_age_hand_has_tier(required_tier: int) -> bool:
	return _stone_age_tool_tier(str(_stone_age_authoritative_equipment.get("hand", ""))) >= required_tier


func _stone_age_tool_tier(item_name: String) -> int:
	var definition: Dictionary = _block_entry(item_name).get("definition", {}) if _block_entry(item_name).get("definition", {}) is Dictionary else {}
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	var tier := int(effects.get("harvest_tier", 0))
	if tier <= 0 and item_name in ["wooden_pickaxe", "stone_pickaxe", "copper_pickaxe", "crystal_pickaxe", "obsidian_pickaxe", "resonance_pickaxe"]:
		tier = ["wooden_pickaxe", "stone_pickaxe", "copper_pickaxe", "crystal_pickaxe", "obsidian_pickaxe", "resonance_pickaxe"].find(item_name) + 1
	return tier


func _stone_age_note_action_started(decision: Dictionary, now_msec: int) -> void:
	var stage := str(decision.get("stone_age_stage", ""))
	var decision_goal := str(decision.get("stone_age_goal_id", _stone_age_goal_name()))
	if stage.is_empty() or _stone_age_goal_state.is_empty() or decision_goal != _stone_age_goal_name() or str(_stone_age_goal_state.get("stage", "")) != stage or str(_stone_age_goal_state.get("status", "")) != "active":
		return
	var action := str(decision.get("action", ""))
	if action not in [Contract.ACTION_CRAFT, Contract.ACTION_MINE, Contract.ACTION_PLACE, Contract.ACTION_EQUIP]:
		return
	var target: Dictionary = decision.get("target", {}) if decision.get("target", {}) is Dictionary else {}
	var target_id := str(decision.get("target_id", ""))
	var previous: Dictionary = _stone_age_goal_state.get("pending", {}) if _stone_age_goal_state.get("pending", {}) is Dictionary else {}
	if str(previous.get("stage", "")) == stage and str(previous.get("target_id", "")) == target_id and not previous.is_empty():
		return
	_stone_age_goal_state["no_action_since_msec"] = -1
	_stone_age_goal_state["no_action_failures"] = 0
	var pending := {
		"stage": stage,
		"action": action,
		"target_id": target_id,
		"started_at_msec": now_msec,
		"baseline_inventory": int(_stone_age_authoritative_inventory.get(target_id, 0)),
		"target_x": int(target.get("x", -2147483648)),
		"target_y": int(target.get("y", -2147483648)),
		"block": str(decision.get("block", target.get("block_name", ""))),
	}
	if action == Contract.ACTION_MINE:
		pending["target_id"] = target_id
		pending["expected_item"] = str(target.get("block_name", ""))
		if stage == "mine_cobblestone":
			pending["expected_item"] = "cobblestone"
	elif action == Contract.ACTION_CRAFT:
		pending["expected_item"] = target_id
	elif action == Contract.ACTION_EQUIP:
		pending["expected_equipment"] = target_id
	elif action == Contract.ACTION_PLACE and str(decision.get("block", "")) == "workbench":
		pending["expected_station"] = "workbench"
	_stone_age_goal_state["pending"] = pending
	_stone_age_goal_state["stage_attempts"] = int(_stone_age_goal_state.get("stage_attempts", 0)) + 1
	structured_log.emit({"event": "step_started", "goal": decision_goal, "stage": stage, "action": action, "target_id": target_id, "world_id": world_id, "at_msec": now_msec})


func _stone_age_confirm_pending_if_observed(now_msec: int) -> void:
	if _stone_age_goal_state.is_empty():
		return
	var pending: Dictionary = _stone_age_goal_state.get("pending", {}) if _stone_age_goal_state.get("pending", {}) is Dictionary else {}
	if pending.is_empty():
		return
	var confirmed := false
	var expected_item := str(pending.get("expected_item", ""))
	if not expected_item.is_empty() and int(_stone_age_authoritative_inventory.get(expected_item, 0)) > int(pending.get("baseline_inventory", 0)):
		confirmed = true
	var expected_equipment := str(pending.get("expected_equipment", ""))
	if not expected_equipment.is_empty() and str(_stone_age_authoritative_equipment.get("hand", "")) == expected_equipment:
		confirmed = true
	var expected_station := str(pending.get("expected_station", ""))
	if not expected_station.is_empty() and _station_available(_world_snapshot, expected_station):
		confirmed = true
	if not confirmed:
		return
	structured_log.emit({"event": "step_confirmed", "goal": _stone_age_goal_name(), "stage": str(pending.get("stage", "")), "action": str(pending.get("action", "")), "target_id": str(pending.get("target_id", "")), "world_id": world_id, "at_msec": now_msec})
	_stone_age_goal_state["pending"] = {}
	_stone_age_goal_state["stage_failures"] = 0
	_stone_age_goal_state["stage_attempts"] = 0
	_stone_age_goal_state["no_action_failures"] = 0
	_stone_age_goal_state["no_action_since_msec"] = -1
	_stone_age_goal_state["retry_after_msec"] = 0
	if str(_stone_age_goal_state.get("status", "")) in ["cooldown", "abandoned"]:
		_stone_age_goal_state["status"] = "active"


func _expire_stone_age_pending(now_msec: int) -> void:
	if _stone_age_goal_state.is_empty():
		return
	var pending: Dictionary = _stone_age_goal_state.get("pending", {}) if _stone_age_goal_state.get("pending", {}) is Dictionary else {}
	if pending.is_empty() or now_msec - int(pending.get("started_at_msec", now_msec)) < STONE_AGE_CONFIRM_TIMEOUT_MSEC:
		return
	if str(pending.get("action", "")) == Contract.ACTION_MINE:
		var target_id := str(pending.get("target_id", ""))
		if target_id.begins_with("tile:"):
			_blocked_action_targets[target_id] = now_msec + UNSAFE_ROUTE_RETRY_BLOCK_MSEC
	if str(pending.get("action", "")) == Contract.ACTION_CRAFT:
		_block_craft_output(str(pending.get("target_id", "")), now_msec)
	_stone_age_fail_pending(str(pending.get("stage", "")), "authoritative_confirmation_timeout", now_msec)


func _stone_age_note_failure(decision: Dictionary, reason: String, now_msec: int) -> void:
	var decision_goal := str(decision.get("stone_age_goal_id", _stone_age_goal_name()))
	if decision_goal != _stone_age_goal_name():
		return
	var stage := str(decision.get("stone_age_stage", ""))
	if stage.is_empty():
		return
	var pending: Dictionary = _stone_age_goal_state.get("pending", {}) if _stone_age_goal_state.get("pending", {}) is Dictionary else {}
	if pending.is_empty() and reason in ["pursuit_no_safe_waypoint", "pursuit_waypoint_unreachable"] and str(decision.get("action", "")) in [Contract.ACTION_MOVE_NEAR_PLAYER, Contract.ACTION_MOVE_TO]:
		# Movement is not a completed Stone Age step by itself, so we do not keep
		# it pending until an inventory snapshot. But an executor-level route
		# failure is a definitive failed attempt; put a transient pending record
		# through the same bounded retry/abandon path as a rejected craft or mine.
		_stone_age_goal_state["pending"] = {
			"stage": stage,
			"action": str(decision.get("action", "")),
			"target_id": str(decision.get("target_id", "")),
			"started_at_msec": now_msec,
		}
	_stone_age_fail_pending(stage, reason, now_msec)


func _stone_age_fail_pending(stage: String, reason: String, now_msec: int) -> void:
	if stage.is_empty() or _stone_age_goal_state.is_empty() or str(_stone_age_goal_state.get("stage", "")) != stage:
		return
	var pending: Dictionary = _stone_age_goal_state.get("pending", {}) if _stone_age_goal_state.get("pending", {}) is Dictionary else {}
	if pending.is_empty() or str(pending.get("stage", "")) != stage:
		return
	_stone_age_goal_state["pending"] = {}
	var failures := int(_stone_age_goal_state.get("stage_failures", 0)) + 1
	_stone_age_goal_state["stage_failures"] = failures
	var abandoned := failures >= STONE_AGE_MAX_STAGE_FAILURES
	_stone_age_goal_state["status"] = "abandoned" if abandoned else "cooldown"
	_stone_age_goal_state["retry_after_msec"] = now_msec + (STONE_AGE_ABANDON_COOLDOWN_MSEC if abandoned else STONE_AGE_RETRY_COOLDOWN_MSEC)
	structured_log.emit({
		"event": "goal_abandoned" if abandoned else "step_failed",
		"goal": _stone_age_goal_name(),
		"stage": stage,
		"reason": reason,
		"failures": failures,
		"retry_after_msec": _stone_age_goal_state["retry_after_msec"],
		"world_id": world_id,
		"at_msec": now_msec,
	})


## Current world mode plus the two mode-scoped maximums the achievement catalog
## tracks. Values stay 0 outside their mode so a decision provider can read them
## unconditionally and still disambiguate with `world_mode`.
func _mode_progress_from_snapshot() -> Dictionary:
	var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
	var mode := str(generation.get("mode", _session_world_mode)).to_lower()
	var progress := {"world_mode": mode, "one_block_mined": 0, "challenge_best_distance": 0}
	if mode == "one_block":
		var source: Dictionary = _world_snapshot.get("one_block", {}) if _world_snapshot.get("one_block", {}) is Dictionary else {}
		progress["one_block_mined"] = maxi(_live_one_block_mined, maxi(0, int(source.get("mined", 0))))
	elif mode == "challenge_run":
		var challenge: Dictionary = _world_snapshot.get("challenge", {}) if _world_snapshot.get("challenge", {}) is Dictionary else {}
		progress["challenge_best_distance"] = maxi(_live_challenge_best_distance, maxi(0, int(challenge.get("best_distance", 0))))
	return progress


## Session-sync side effects for /root/Achievements. Only supported world modes
## are credited, and only when the snapshot actually carries the mode state, so
## duel/unknown sessions cannot pollute the mode set or the maximums.
func _record_world_state_achievements() -> void:
	var achievements := get_node_or_null("/root/Achievements")
	if achievements == null:
		return
	var progress := _mode_progress_from_snapshot()
	var mode := str(progress.get("world_mode", "")).to_lower()
	if mode not in AchievementRegistryClass.recordable_world_modes():
		return
	if achievements.has_method("record_world_mode"):
		achievements.call("record_world_mode", mode)
	if mode == "one_block":
		var source: Dictionary = _world_snapshot.get("one_block", {}) if _world_snapshot.get("one_block", {}) is Dictionary else {}
		if source.has("mined") and achievements.has_method("record_one_block_progress"):
			achievements.call("record_one_block_progress", int(progress.get("one_block_mined", 0)))
	elif mode == "challenge_run":
		var challenge: Dictionary = _world_snapshot.get("challenge", {}) if _world_snapshot.get("challenge", {}) is Dictionary else {}
		if challenge.has("best_distance") and achievements.has_method("record_challenge_distance"):
			achievements.call("record_challenge_distance", int(progress.get("challenge_best_distance", 0)))


## Only the host-provided biome identity can count as a visit. Player coordinates
## are likewise taken from the authoritative state; procedural depth is not
## inferred in other modes such as Skyblock or One Block.
func _record_authoritative_location_achievements(biome_id: String, player_state: Dictionary) -> void:
	if _session_world_mode == "floating_islands" and bool(player_state.get("on_ground", false)) and player_state.has("x") and player_state.has("y"):
		var generation: Dictionary = _world_snapshot.get("generation", {}) if _world_snapshot.get("generation", {}) is Dictionary else {}
		var row := floori((float(player_state.get("y", 0.0)) + float(player_state.get("h", 28.0)) + 1.5) / float(BlockDefs.TILE))
		var column := floori((float(player_state.get("x", 0.0)) + float(player_state.get("w", 20.0)) * 0.5) / float(BlockDefs.TILE))
		var raw_layout: Array = generation.get("floating_islands", []) if generation.get("floating_islands", []) is Array else []
		for raw_island in raw_layout:
			if not raw_island is Dictionary:
				continue
			var island := raw_island as Dictionary
			if row == int(island.get("y", 2147483647)) and absi(column - int(island.get("x", 0))) <= int(island.get("half_width", 0)) and biome_id == str(island.get("biome", "")):
				_visited_floating_islands["%d:%d" % [int(island.get("x", 0)), row]] = true
	var achievements := get_node_or_null("/root/Achievements")
	if achievements == null:
		return
	var updates := _authoritative_location_achievement_updates(
		biome_id,
		player_state,
		str(_mode_progress_from_snapshot().get("world_mode", "")),
	)
	if updates.has("biome_id") and achievements.has_method("record_biome"):
		achievements.call("record_biome", str(updates["biome_id"]))
	if updates.has("depth") and achievements.has_method("record_depth"):
		achievements.call("record_depth", int(updates["depth"]))


func _authoritative_location_achievement_updates(biome_id: String, player_state: Dictionary, world_mode: String) -> Dictionary:
	var updates: Dictionary = {}
	biome_id = biome_id.strip_edges()
	if not biome_id.is_empty():
		updates["biome_id"] = biome_id
	if world_mode.to_lower() == "procedural" and player_state.has("y"):
		updates["depth"] = floori(float(player_state.get("y", 0.0)) / float(BlockDefs.TILE))
	return updates


func _record_live_challenge_distance(player_state: Dictionary) -> void:
	if str(_mode_progress_from_snapshot().get("world_mode", "")).to_lower() != "challenge_run":
		return
	if not player_state.has("x") or not player_state.has("y"):
		return
	var tile_x := floori((float(player_state.get("x", 0.0)) + float(player_state.get("w", 20.0)) * 0.5) / float(BlockDefs.TILE))
	var distance := maxi(0, tile_x - 1)
	var challenge: Dictionary = _world_snapshot.get("challenge", {}) if _world_snapshot.get("challenge", {}) is Dictionary else {}
	var previous_best := maxi(_live_challenge_best_distance, maxi(0, int(challenge.get("best_distance", 0))))
	if distance <= previous_best:
		return
	_live_challenge_best_distance = maxi(_live_challenge_best_distance, distance)
	challenge["best_distance"] = distance
	_world_snapshot["challenge"] = challenge
	var achievements := get_node_or_null("/root/Achievements")
	if achievements != null and achievements.has_method("record_challenge_distance"):
		achievements.call("record_challenge_distance", distance)


func _is_one_block_source_target(target: Dictionary) -> bool:
	if str(_mode_progress_from_snapshot().get("world_mode", "")).to_lower() != "one_block":
		return false
	if not target.has("x") or not target.has("y"):
		return false
	var source: Dictionary = _world_snapshot.get("one_block", {}) if _world_snapshot.get("one_block", {}) is Dictionary else {}
	return int(target.get("x", -1)) == int(source.get("x", -2)) and int(target.get("y", -1)) == int(source.get("y", -2))


func _record_accepted_one_block_mine(mined_before: int) -> void:
	if str(_mode_progress_from_snapshot().get("world_mode", "")).to_lower() != "one_block":
		return
	var progress := maxi(int(_mode_progress_from_snapshot().get("one_block_mined", 0)), mined_before + 1)
	_live_one_block_mined = maxi(_live_one_block_mined, progress)
	var source: Dictionary = _world_snapshot.get("one_block", {}) if _world_snapshot.get("one_block", {}) is Dictionary else {}
	source["mined"] = maxi(maxi(0, int(source.get("mined", 0))), _live_one_block_mined)
	_world_snapshot["one_block"] = source
	var achievements := get_node_or_null("/root/Achievements")
	if achievements != null and achievements.has_method("record_one_block_progress"):
		achievements.call("record_one_block_progress", _live_one_block_mined)


## Credit a craft exactly once per session. Local optimistic crafts never get a
## craft_recipe action_result, and the host-ack path can still arrive later, so
## both call sites share this dedupe instead of double-recording.
func _record_craft_achievement(output_name: String) -> void:
	output_name = output_name.strip_edges()
	if output_name.is_empty() or _achievements_recorded_crafts.has(output_name):
		return
	var achievements := get_node_or_null("/root/Achievements")
	if achievements == null or not achievements.has_method("record_craft"):
		return
	_achievements_recorded_crafts[output_name] = true
	achievements.call("record_craft", output_name)


## Mirror MultiplayerClient.is_community() so a headless bot locks the shared
## account's achievements on managed community servers. When only the dedicated
## flag is known, unknown classification locks conservatively; non-dedicated
## (P2P / local) sessions stay unlocked. The lock is only ever released by the
## session that took it.
func _sync_achievements_community_lock() -> void:
	if network_client == null:
		return
	var locked := false
	var resolved := false
	if network_client.has_method("is_community"):
		locked = bool(network_client.call("is_community"))
		resolved = true
	elif network_client.has_method("is_official_dedicated"):
		locked = not bool(network_client.call("is_official_dedicated"))
		resolved = true
	elif dedicated_server:
		locked = true
		resolved = true
	if not resolved:
		return
	var achievements := get_node_or_null("/root/Achievements")
	if achievements == null or not achievements.has_method("set_community_locked"):
		return
	if locked:
		achievements.call("set_community_locked", true)
		_achievements_lock_owned = true
	elif _achievements_lock_owned:
		achievements.call("set_community_locked", false)
		_achievements_lock_owned = false


func _clear_achievements_community_lock() -> void:
	if not _achievements_lock_owned:
		return
	_achievements_lock_owned = false
	var achievements := get_node_or_null("/root/Achievements")
	if achievements != null and achievements.has_method("set_community_locked"):
		achievements.call("set_community_locked", false)


func _set_state(next_state: String) -> void:
	if state == next_state:
		return
	state = next_state
	state_changed.emit(state)
