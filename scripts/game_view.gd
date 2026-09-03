extends Node2D

const WorldSim = preload("res://gameplay/scripts/world.gd")
const CompactNumberClass = preload("res://gameplay/scripts/compact_number.gd")
const EmojiReactionsClass = preload("res://gameplay/scripts/emoji_reactions.gd")

signal hud_update(coords: String, blocks: String)
signal challenge_milestone_reached(distance: int)
signal craft_state_changed(sim: RefCounted)
signal player_defeated
signal one_block_phase_changed(phase_number: int)
signal remote_player_attacked(player_id: String)
signal multiplayer_action_requested(action: String, payload: Dictionary)
signal bow_shot_created(payload: Dictionary)
signal block_mined(block_name: String)
signal block_placed(block_name: String)
signal harvest_blocked(block_name: String, required_tier: int, active_tier: int)

const VIEW_W := 960
const VIEW_H := 540
const DEFAULT_ZOOM := 2.0
const MIN_ZOOM := 1.0
const DESKTOP_MIN_ZOOM := 0.5
const MAX_ZOOM := 4.0
const LOW_ZOOM_LOD_THRESHOLD := 0.5
const LOW_ZOOM_LOD_TRIGGER_FPS := 42.0
const LOW_ZOOM_LOD_TRIGGER_SECONDS := 3.0
const LOW_ZOOM_LOD_GRACE_SECONDS := 5.0
const LOW_ZOOM_TILE_PIXELS := 16
const LONG_PRESS_TIME := 0.35
const HIGHLIGHT_PAD := 12.0
const HIGHLIGHT_WIDTH := 4.0
const MINING_RATE := 7.0
const NO_TILE := Vector2i(2147483647, 2147483647)
const LIGHT_CACHE_MARGIN := 10
const LIGHT_REBUILD_INTERVAL_FRAMES := 15
const MAX_CAVE_DARKNESS := 0.72
const CAMERA_FOLLOW_SPEED_X := 7.67
const CAMERA_FOLLOW_SPEED_Y_AIR := 7.67
const CAMERA_FOLLOW_SPEED_Y_GROUND := 13.39
const SIMULATION_STEP := 1.0 / 60.0
const MAX_SIMULATION_STEPS_PER_FRAME := 4
const WORLD_RENDER_MARGIN := 6
const SKY_REDRAW_INTERVAL_FRAMES := 6
const SUNLIGHT_REDRAW_INTERVAL_FRAMES := 4
const ATMOSPHERE_REDRAW_INTERVAL_FRAMES := 3
const HEALTH_INDICATOR_HOLD_SECONDS := 2.0
const HEALTH_INDICATOR_FADE_SECONDS := 0.5
const HEALTH_INDICATOR_PIP_SIZE := 4.0
const HEALTH_INDICATOR_PIP_GAP := 2.0
const PLAYER_RENDER_WIDTH := 20.0
const ATTACK_COOLDOWN_MSEC := WorldSim.COMBAT_ATTACK_COOLDOWN_MSEC
const HIT_FLASH_MSEC := 180
const REMOTE_PLAYER_INTERPOLATION_SPEED := 18.0
const REMOTE_PLAYER_TELEPORT_DISTANCE := BlockDefs.TILE * 8.0
const REMOTE_PLAYER_EXTRAPOLATION_SECONDS := 0.15
const REMOTE_PLAYER_INDICATOR_MARGIN := 28.0
const EMOJI_BUBBLE_SECONDS := 3.0
const REMOTE_CREATURE_INTERPOLATION_SPEED := 14.0
const REMOTE_CREATURE_TELEPORT_DISTANCE := 8.0
const TIDEGLASS_REVEAL_GLOW_MSEC := 520
const BOW_FULL_DRAW_SECONDS := 1.0
const BOW_MIN_DRAW_SECONDS := 0.12
const ARROW_MIN_SPEED := 250.0
const ARROW_MAX_SPEED := 560.0
const ARROW_GRAVITY := 310.0
const ARROW_MAX_LIFETIME := 5.0

var sim := WorldSim.new()
var camera_pos := Vector2.ZERO
var zoom := DEFAULT_ZOOM
var anim_frame := 0
var _animation_time := 0.0
var _simulation_accumulator := 0.0

var mining: Dictionary = {}
var mining_active := false
var place_mode := false

var pointer_world := Vector2.ZERO
var pointer_screen := Vector2.ZERO
var pointer_active := false
var pointer_armed := false
var _mouse_down := false
var _mouse_press_time := 0.0
var _mouse_long_press := false
var _last_place_msec := -1000
var keyboard_mine_direction := Vector2i.ZERO
var keyboard_mining_held := false
var keyboard_placing_held := false

var virtual_left := false
var virtual_right := false
var virtual_jump_held := false
var bow_aim_direction := Vector2.RIGHT
var bow_drawing := false
var bow_draw_started_msec := 0
var arrows: Array[Dictionary] = []
var _lighting_dirty := true
var _lighting_texture: ImageTexture
var _world_lod_texture: ImageTexture
var _low_zoom_lod_active := false
var _low_zoom_slow_seconds := 0.0
var _low_zoom_grace_seconds := 0.0
var _low_zoom_last_zoom := DEFAULT_ZOOM
var _lighting_cache_area := Rect2i()
var _lighting_cache: Dictionary = {}
var _lighting_last_build_frame := -1000
var _lighting_sample_area := Rect2i()
var _sampled_combined: Dictionary = {}
var _sampled_daylight: Dictionary = {}
var _sampled_warm: Dictionary = {}
var _sampled_passable: Dictionary = {}
var _last_hud_coords := ""
var _last_hud_blocks := ""
var _sky_background_layer: Node2D
var _sky_background_material: ShaderMaterial
var _sky_layer: Node2D
var _world_layer: Node2D
var _lighting_layer: Node2D
var _sunlight_layer: Node2D
var _atmosphere_layer: Node2D
var _targeting_layer: Node2D
var _weather_layer: Node2D
var _reaction_layer: Node2D
var _world_render_area := Rect2i()
var _lighting_render_area := Rect2i()
var _world_render_dirty := true
var _last_tree_fade_active := false
var _last_creature_light_signature := ""
var _last_sky_redraw_frame := -1000
var _last_sunlight_redraw_frame := -1000
var _last_atmosphere_redraw_frame := -1000
var _sky_background_view_size := Vector2.ZERO
var _last_player_health := WorldSim.MAX_PLAYER_HEALTH
var _health_indicator_time_left := 0.0
var _last_attack_msec := -1000
var _local_hit_flash_expires_msec := 0
var _creature_hit_flash_expires_msec: Dictionary = {}
var _remote_player_hit_flash_expires_msec: Dictionary = {}
var tutorial_highlight_tile := NO_TILE
var multiplayer_guest := false
var remote_players: Dictionary = {}
var local_emoji_reaction: Dictionary = {}
var remote_emoji_reactions: Dictionary = {}
var suppress_inventory_ui_updates := false
var remote_creature_targets: Dictionary = {}
var _tideglass_reveal_glow: Dictionary = {}
var _remote_player_render_positions: Dictionary = {}
var _remote_player_render_revisions: Dictionary = {}
var desktop_web_rendering := false

@onready var camera: Camera2D = $Camera2D


func _ready() -> void:
	texture_filter = TEXTURE_FILTER_NEAREST
	camera.enabled = false
	_create_render_layers()
	set_process(false)
	set_process_unhandled_input(false)
	_bind_sim_signals()


func _create_render_layers() -> void:
	_sky_background_layer = Node2D.new()
	_sky_background_layer.z_index = -22
	_sky_background_material = ShaderMaterial.new()
	var sky_shader := Shader.new()
	sky_shader.code = _sky_shader_code()
	_sky_background_material.shader = sky_shader
	_sky_background_layer.material = _sky_background_material
	# The fullscreen shader is reserved for the rare aurora event. The regular
	# sky is cheaper as cached pixel-art CanvasItem commands on mobile GPUs.
	_sky_background_layer.visible = false
	_sky_background_layer.draw.connect(_draw_sky_background_layer)
	add_child(_sky_background_layer)
	_sky_layer = Node2D.new()
	_sky_layer.z_index = -20
	_sky_layer.draw.connect(_draw_sky_layer)
	add_child(_sky_layer)
	_world_layer = Node2D.new()
	_world_layer.z_index = -10
	_world_layer.draw.connect(_draw_world_layer)
	add_child(_world_layer)
	_lighting_layer = Node2D.new()
	_lighting_layer.z_index = 10
	_lighting_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_lighting_layer.draw.connect(_draw_lighting_layer)
	add_child(_lighting_layer)
	_sunlight_layer = Node2D.new()
	_sunlight_layer.z_index = 11
	_sunlight_layer.draw.connect(_draw_sunlight_layer)
	add_child(_sunlight_layer)
	_atmosphere_layer = Node2D.new()
	_atmosphere_layer.z_index = 12
	_atmosphere_layer.draw.connect(_draw_atmosphere_layer)
	add_child(_atmosphere_layer)
	_targeting_layer = Node2D.new()
	_targeting_layer.z_index = 15
	_targeting_layer.draw.connect(_draw_targeting_layer)
	add_child(_targeting_layer)
	_weather_layer = Node2D.new()
	_weather_layer.z_index = 20
	_weather_layer.draw.connect(_draw_weather_layer)
	add_child(_weather_layer)
	_reaction_layer = Node2D.new()
	_reaction_layer.z_index = 30
	_reaction_layer.draw.connect(_draw_reaction_layer)
	add_child(_reaction_layer)


func _bind_sim_signals() -> void:
	if not sim.inventory_changed.is_connected(_on_inventory_changed):
		sim.inventory_changed.connect(_on_inventory_changed)
	if not sim.block_count_changed.is_connected(_on_block_count_changed):
		sim.block_count_changed.connect(_on_block_count_changed)
	if not sim.lighting_changed.is_connected(_invalidate_lighting):
		sim.lighting_changed.connect(_invalidate_lighting)
	if not sim.static_tiles_changed.is_connected(_invalidate_world_render):
		sim.static_tiles_changed.connect(_invalidate_world_render)
	if not sim.daylight_changed.is_connected(_invalidate_lighting):
		sim.daylight_changed.connect(_invalidate_lighting)
	if not sim.player_defeated.is_connected(_on_player_defeated):
		sim.player_defeated.connect(_on_player_defeated)
	if not sim.one_block_phase_changed.is_connected(_on_one_block_phase_changed):
		sim.one_block_phase_changed.connect(_on_one_block_phase_changed)
	if not sim.challenge_milestone_reached.is_connected(_on_challenge_milestone_reached):
		sim.challenge_milestone_reached.connect(_on_challenge_milestone_reached)
	if not sim.tideglass_bridge_cell_crystallized.is_connected(_on_tideglass_bridge_cell_crystallized):
		sim.tideglass_bridge_cell_crystallized.connect(_on_tideglass_bridge_cell_crystallized)


func _on_player_defeated() -> void:
	player_defeated.emit()


func _on_one_block_phase_changed(phase_number: int) -> void:
	one_block_phase_changed.emit(phase_number)


func _on_challenge_milestone_reached(distance: int) -> void:
	challenge_milestone_reached.emit(distance)


func _on_tideglass_bridge_cell_crystallized(position: Vector2i, step_index: int, total_steps: int) -> void:
	_tideglass_reveal_glow[position] = Time.get_ticks_msec() + TIDEGLASS_REVEAL_GLOW_MSEC
	Sfx.tideglass_crystallize(step_index, total_steps)
	if is_instance_valid(_reaction_layer):
		_reaction_layer.queue_redraw()


func start_new_world(mode: String = WorldSim.WORLD_MODE_SKYBLOCK, access_mode: String = WorldSim.ACCESS_MODE_OFFLINE, keep_inventory_on_death: bool = false) -> bool:
	if mode == WorldSim.WORLD_MODE_PROCEDURAL:
		sim.create_procedural_world()
	elif mode == WorldSim.WORLD_MODE_FLOATING_ISLANDS:
		sim.create_floating_islands_world()
	elif mode == WorldSim.WORLD_MODE_ONE_BLOCK:
		sim.create_one_block_world()
	elif mode == WorldSim.WORLD_MODE_CHALLENGE:
		sim.create_challenge_world()
	else:
		sim.create_island()
	sim.access_mode = access_mode
	sim.multiplayer_join_code = ""
	sim.keep_inventory_on_death = keep_inventory_on_death
	_finish_world_start()
	return true


func continue_world(state: Dictionary) -> bool:
	var capture_zoom := 0.0
	if state.get("capture_demo", {}) is Dictionary:
		capture_zoom = float((state.get("capture_demo", {}) as Dictionary).get("zoom", 0.0))
	if not sim.deserialize_state(state):
		return false
	if capture_zoom > 0.0:
		zoom = clampf(capture_zoom, MIN_ZOOM, MAX_ZOOM)
	_finish_world_start()
	return true


func _finish_world_start() -> void:
	_remote_player_render_positions.clear()
	_remote_player_render_revisions.clear()
	remote_creature_targets.clear()
	_tideglass_reveal_glow.clear()
	arrows.clear()
	bow_drawing = false
	_invalidate_lighting()
	_invalidate_world_render()
	_last_sky_redraw_frame = -1000
	_last_sunlight_redraw_frame = -1000
	_last_atmosphere_redraw_frame = -1000
	_sky_background_view_size = Vector2.ZERO
	_sky_background_layer.queue_redraw()
	var p: Dictionary = sim.player
	var view := _view_size()
	camera_pos = Vector2(
		zoom * (p["x"] + p["w"] * 0.5) - view.x * 0.5,
		zoom * (p["y"] + p["h"] * 0.5) - view.y * 0.5
	)
	_last_player_health = int(p.get("health", WorldSim.MAX_PLAYER_HEALTH))
	_health_indicator_time_left = 0.0
	_on_inventory_changed()
	set_process(true)
	set_process_unhandled_input(true)


func pause_world() -> void:
	set_process(false)
	set_process_unhandled_input(false)
	virtual_left = false
	virtual_right = false
	virtual_jump_held = false
	bow_drawing = false
	cancel_pointer_interaction()
	keyboard_mining_held = false
	keyboard_placing_held = false
	keyboard_mine_direction = Vector2i.ZERO


func resume_world() -> void:
	set_process(true)
	set_process_unhandled_input(true)


func _process(_delta: float) -> void:
	_update_low_zoom_lod(_delta)
	_animation_time += _delta
	anim_frame = int(_animation_time * 60.0)
	_update_remote_player_interpolation(_delta)
	_update_remote_creature_interpolation(_delta)
	_update_arrows(_delta)
	_simulation_accumulator = minf(
		_simulation_accumulator + _delta,
		SIMULATION_STEP * float(MAX_SIMULATION_STEPS_PER_FRAME)
	)
	var simulation_steps := 0
	while not multiplayer_guest and _simulation_accumulator >= SIMULATION_STEP and simulation_steps < MAX_SIMULATION_STEPS_PER_FRAME:
		sim.multiplayer_player_targets = remote_players
		sim.tick_fluids()
		sim.tick_granular()
		sim.tick_trees()
		sim.tick_creatures()
		sim.tick_fire()
		sim.tick_weather()
		sim.tick_world_generation()
		sim.tick_time()
		_simulation_accumulator -= SIMULATION_STEP
		simulation_steps += 1
	var move_left := _move_left_pressed() or virtual_left
	var move_right := _move_right_pressed() or virtual_right
	var jump := _jump_pressed() or virtual_jump_held
	if move_left or move_right or jump:
		_cancel_pointer_for_move()
	elif keyboard_mining_held and keyboard_mine_direction != Vector2i.ZERO:
		mining_active = true
		place_mode = false
	_update_mouse_mining()
	_tick_mining(_delta)
	sim.tick_player_needs(_delta, not multiplayer_guest)
	sim.move_player(move_left, move_right, jump, _delta)
	_sync_creature_lighting()
	_update_health_indicator(_delta)
	_update_camera(_delta)
	_update_render_layers()

	queue_redraw()
	_reaction_layer.queue_redraw()
	# Procedural pixel clouds and directional highlights record thousands of
	# CanvasItem commands. Their coordinates move by less than one pixel between
	# these updates, so rebuilding them every rendered frame wastes most of the
	# frame budget on mid-range Android devices without producing visible motion.
	# These cached environment layers are individually fairly expensive to record.
	# Their 6/4/3-frame cadences used to coincide every 12 animation frames and
	# produce a visible hitch on Android. Rebuild at most one per rendered frame;
	# a due layer deferred by one frame remains due and is picked up next frame.
	if desktop_web_rendering:
		# The mobile sky cadence is 10 Hz. Raise the dominant parallax layer to
		# 30 Hz on desktop, then use the intervening frames for the two subtler
		# overlays. This keeps animation smooth without rebuilding every expensive
		# environment layer in the same frame.
		if anim_frame % 2 == 0:
			_last_sky_redraw_frame = anim_frame
			_sky_layer.queue_redraw()
		elif anim_frame % 4 == 1:
			_last_sunlight_redraw_frame = anim_frame
			_sunlight_layer.queue_redraw()
		else:
			_last_atmosphere_redraw_frame = anim_frame
			_atmosphere_layer.queue_redraw()
	else:
		if _redraw_interval_elapsed(_last_sky_redraw_frame, SKY_REDRAW_INTERVAL_FRAMES):
			_last_sky_redraw_frame = anim_frame
			_sky_layer.queue_redraw()
		elif _redraw_interval_elapsed(_last_sunlight_redraw_frame, SUNLIGHT_REDRAW_INTERVAL_FRAMES):
			_last_sunlight_redraw_frame = anim_frame
			_sunlight_layer.queue_redraw()
		elif _redraw_interval_elapsed(_last_atmosphere_redraw_frame, ATMOSPHERE_REDRAW_INTERVAL_FRAMES):
			_last_atmosphere_redraw_frame = anim_frame
			_atmosphere_layer.queue_redraw()
	var aurora_visible := _update_sky_background_shader() > 0.001
	_sky_background_layer.visible = aurora_visible
	var current_view_size := _view_size()
	if aurora_visible and not current_view_size.is_equal_approx(_sky_background_view_size):
		_sky_background_view_size = current_view_size
		_sky_background_layer.queue_redraw()
	if is_instance_valid(_targeting_layer):
		_targeting_layer.queue_redraw()
	# CanvasItem keeps its previous draw commands until it is redrawn. Queue the
	# layer even after weather changes to clear so the final rain/lightning frame
	# is actually erased instead of remaining frozen on screen.
	_weather_layer.queue_redraw()
	_emit_hud()


func _redraw_interval_elapsed(last_frame: int, interval_frames: int) -> bool:
	return anim_frame - last_frame >= interval_frames


func _update_health_indicator(delta: float) -> void:
	_prune_hit_flashes()
	var current_health := int(sim.player.get("health", WorldSim.MAX_PLAYER_HEALTH))
	if current_health != _last_player_health:
		if current_health < _last_player_health:
			show_local_player_hit()
		_last_player_health = current_health
		_health_indicator_time_left = HEALTH_INDICATOR_HOLD_SECONDS + HEALTH_INDICATOR_FADE_SECONDS
	else:
		_health_indicator_time_left = maxf(0.0, _health_indicator_time_left - delta)


func _input(event: InputEvent) -> void:
	if is_processing() and desktop_web_rendering and event is InputEventKey:
		var key := event as InputEventKey
		var code := key.physical_keycode if key.physical_keycode != 0 else key.keycode
		var direction := _keyboard_mine_direction_for_code(code)
		if direction != Vector2i.ZERO:
			if (keyboard_mining_held or keyboard_placing_held) and not key.echo:
				if key.pressed:
					set_keyboard_mine_direction(direction)
					if keyboard_placing_held:
						try_keyboard_place()
				elif keyboard_mine_direction == direction:
					var fallback := _held_keyboard_mine_direction(code)
					if fallback == Vector2i.ZERO:
						keyboard_mine_direction = Vector2i.ZERO
						stop_mining()
						if is_instance_valid(_targeting_layer):
							_targeting_layer.queue_redraw()
					else:
						set_keyboard_mine_direction(fallback)
			# Arrow keys must never reach GUI focus navigation. WASD remains regular
			# movement input unless F currently turns it into directional mining.
			if code in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN] or keyboard_mining_held or keyboard_placing_held:
				get_viewport().set_input_as_handled()
			return
		if code == KEY_F:
			if not key.echo:
				set_keyboard_mining_pressed(key.pressed)
			get_viewport().set_input_as_handled()
			return
		if code == KEY_Q:
			if not key.echo:
				set_keyboard_placing_pressed(key.pressed)
			get_viewport().set_input_as_handled()
			return


func _unhandled_input(event: InputEvent) -> void:

	if event.is_action_pressed("craft"):
		sim.toggle_craft()
		craft_state_changed.emit(sim)
		return

	for i in BlockDefs.HOTBAR_SIZE:
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			sim.select_hotbar(i)
			craft_state_changed.emit(sim)
			return

	if event is InputEventMouseButton:
		handle_desktop_pointer(event, (event as InputEventMouseButton).position)

	if event is InputEventMouseMotion:
		handle_desktop_pointer(event, (event as InputEventMouseMotion).position)


func handle_desktop_pointer(event: InputEvent, screen_pos: Vector2) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				if mb.ctrl_pressed or mb.meta_pressed:
					adjust_zoom(1.25 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8)
				else:
					var direction := -1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1
					sim.select_hotbar(posmod(sim.active_hotbar_slot + direction, BlockDefs.HOTBAR_SIZE))
					craft_state_changed.emit(sim)
			return true
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				begin_pointer(screen_pos)
				_mouse_down = true
				_mouse_press_time = Time.get_ticks_msec() / 1000.0
				_mouse_long_press = false
				mining_active = false
				mining.clear()
			else:
				if _mouse_down and not _mouse_long_press:
					try_place()
				end_pointer()
				_mouse_down = false
				mining_active = false
				mining.clear()
			return true
		if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			begin_pointer(screen_pos)
			try_place()
			end_pointer()
			return true
	if event is InputEventMouseMotion and pointer_armed:
		_update_pointer(screen_pos)
		return true
	return false


func begin_pointer(screen_pos: Vector2) -> void:
	if _player_is_moving():
		return
	pointer_armed = true
	_update_pointer(screen_pos)


func end_pointer() -> void:
	cancel_pointer_interaction()


func _cancel_pointer_for_move() -> void:
	cancel_pointer_interaction()


func cancel_pointer_interaction() -> void:
	pointer_armed = false
	pointer_active = false
	mining_active = false
	mining.clear()
	_mouse_down = false
	_mouse_long_press = false


func set_pointer_screen(screen_pos: Vector2) -> void:
	if screen_pos.x < 0.0:
		end_pointer()
		return
	if not pointer_armed:
		return
	_update_pointer(screen_pos)


func clear_pointer() -> void:
	end_pointer()


func start_mining() -> void:
	if not pointer_armed or not pointer_active or _player_is_moving():
		cancel_pointer_interaction()
		return
	mining_active = true
	place_mode = false


func stop_mining() -> void:
	mining_active = false
	mining.clear()


func set_keyboard_mine_direction(direction: Vector2i) -> void:
	if not desktop_web_rendering:
		return
	if direction not in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		return
	if keyboard_mine_direction != direction:
		keyboard_mine_direction = direction
		mining.clear()
	if keyboard_mining_held:
		mining_active = true
		place_mode = false
	if is_instance_valid(_targeting_layer):
		_targeting_layer.queue_redraw()


func set_keyboard_mining_pressed(pressed: bool) -> void:
	if not desktop_web_rendering or sim.craft_open:
		pressed = false
	keyboard_mining_held = pressed
	if pressed:
		keyboard_placing_held = false
		keyboard_mine_direction = _held_keyboard_mine_direction()
		if keyboard_mine_direction != Vector2i.ZERO:
			mining_active = true
			place_mode = false
		else:
			stop_mining()
	else:
		keyboard_mine_direction = Vector2i.ZERO
		stop_mining()
	if is_instance_valid(_targeting_layer):
		_targeting_layer.queue_redraw()


func set_keyboard_placing_pressed(pressed: bool) -> void:
	if not desktop_web_rendering or sim.craft_open:
		pressed = false
	keyboard_placing_held = pressed
	if pressed:
		keyboard_mining_held = false
		stop_mining()
		keyboard_mine_direction = _held_keyboard_mine_direction()
		if keyboard_mine_direction != Vector2i.ZERO:
			try_keyboard_place()
	else:
		keyboard_mine_direction = Vector2i.ZERO
	if is_instance_valid(_targeting_layer):
		_targeting_layer.queue_redraw()


func _keyboard_mine_direction_for_code(code: Key) -> Vector2i:
	match code:
		KEY_A, KEY_LEFT:
			return Vector2i.LEFT
		KEY_D, KEY_RIGHT:
			return Vector2i.RIGHT
		KEY_W, KEY_UP:
			return Vector2i.UP
		KEY_S, KEY_DOWN:
			return Vector2i.DOWN
	return Vector2i.ZERO


func _held_keyboard_mine_direction(excluded_code: Key = KEY_NONE) -> Vector2i:
	var bindings := [
		[KEY_A, KEY_LEFT, Vector2i.LEFT],
		[KEY_D, KEY_RIGHT, Vector2i.RIGHT],
		[KEY_W, KEY_UP, Vector2i.UP],
		[KEY_S, KEY_DOWN, Vector2i.DOWN],
	]
	for binding in bindings:
		for index in 2:
			var code: Key = binding[index]
			if code != excluded_code and Input.is_physical_key_pressed(code):
				return binding[2]
	return Vector2i.ZERO


func keyboard_mine_candidate() -> Vector2i:
	if keyboard_mine_direction == Vector2i.ZERO:
		return NO_TILE
	var player_center := Vector2(
		float(sim.player["x"]) + float(sim.player["w"]) * 0.5,
		float(sim.player["y"]) + float(sim.player["h"]) * 0.5,
	)
	var aim := player_center + Vector2(keyboard_mine_direction) * BlockDefs.TILE * 4.5
	var target := sim.raycast_from_player(aim)
	if target.has("mine"):
		return target["mine"]
	return NO_TILE


func keyboard_place_candidate() -> Vector2i:
	if keyboard_mine_direction == Vector2i.ZERO:
		return NO_TILE
	var player_tile := Vector2i(
		floori((float(sim.player["x"]) + float(sim.player["w"]) * 0.5) / BlockDefs.TILE),
		floori((float(sim.player["y"]) + float(sim.player["h"]) * 0.5) / BlockDefs.TILE),
	)
	for distance in range(1, 5):
		var tile := player_tile + keyboard_mine_direction * distance
		if not _tile_in_world(tile):
			break
		if sim.can_place_block(tile.x, tile.y):
			return tile
	return NO_TILE


func try_keyboard_place() -> void:
	if not keyboard_placing_held:
		return
	var tile := keyboard_place_candidate()
	if tile == NO_TILE:
		return
	var now := Time.get_ticks_msec()
	if now - _last_place_msec < 140:
		return
	_last_place_msec = now
	var placed_name := str(sim.selected)
	if multiplayer_guest:
		var valid_request := sim.can_place_block(tile.x, tile.y)
		_optimistically_place_multiplayer_block(tile.x, tile.y, placed_name)
		multiplayer_action_requested.emit("place_block", {"x": tile.x, "y": tile.y, "block_name": placed_name})
		if valid_request:
			block_placed.emit(placed_name)
		return
	if sim.place_block(tile.x, tile.y):
		block_placed.emit(placed_name)


func try_place() -> void:
	try_place_at_screen(pointer_screen)


func try_place_at_screen(screen_pos: Vector2) -> void:
	if try_attack_at_screen(screen_pos):
		return
	var now := Time.get_ticks_msec()
	if now - _last_place_msec < 140:
		return
	_last_place_msec = now
	var tile := _screen_to_tile(screen_pos)
	if not _tile_in_world(tile):
		return
	# Death caches are authoritative world containers in multiplayer. Let the
	# host transfer the cache into the interacting player's inventory so two
	# clients cannot recover the same items and the host never receives them by
	# mistake.
	if multiplayer_guest and sim.is_death_cache_at(tile.x, tile.y):
		multiplayer_action_requested.emit("recover_death_cache", {"x": tile.x, "y": tile.y})
		return
	if multiplayer_guest and sim.is_one_use_cache_at(tile.x, tile.y):
		multiplayer_action_requested.emit("recover_one_use_cache", {"x": tile.x, "y": tile.y})
		return
	if sim.try_open_chest(tile.x, tile.y):
		return
	if sim.try_open_station_inventory(tile.x, tile.y):
		return
	var placed_name := str(sim.selected)
	if multiplayer_guest:
		var valid_request := sim.can_place_block(tile.x, tile.y)
		_optimistically_place_multiplayer_block(tile.x, tile.y, placed_name)
		multiplayer_action_requested.emit("place_block", {"x": tile.x, "y": tile.y, "block_name": placed_name})
		if valid_request:
			block_placed.emit(placed_name)
		return
	if sim.place_block(tile.x, tile.y):
		block_placed.emit(placed_name)


func try_attack_at_screen(screen_pos: Vector2) -> bool:
	var tile := _screen_to_tile(screen_pos)
	if not _tile_in_world(tile):
		return false
	var remote_player_id := remote_player_at_tile(tile.x, tile.y)
	var creature_id := sim.creature_at_tile(tile.x, tile.y)
	if remote_player_id.is_empty() and creature_id.is_empty():
		return false
	if not sim.player_in_combat_range(tile.x, tile.y):
		return true
	var now := Time.get_ticks_msec()
	if now - _last_attack_msec < ATTACK_COOLDOWN_MSEC:
		return true
	_last_attack_msec = now
	if not creature_id.is_empty():
		if multiplayer_guest:
			var creature: Dictionary = sim.creatures.get(creature_id, {}) if sim.creatures.get(creature_id, {}) is Dictionary else {}
			var definition := sim._creature_definition(str(creature.get("block_name", "")))
			var behavior: Dictionary = definition.get("behavior", {}) if definition.get("behavior", {}) is Dictionary else {}
			if str(behavior.get("social_role", "")) == "friendly":
				multiplayer_action_requested.emit("interact_creature", {"creature_id": creature_id})
				return true
		elif sim.try_interact_creature(creature_id):
			Sfx.place("lumenroot")
			return true
	Sfx.attack()
	if not remote_player_id.is_empty():
		show_remote_player_hit(remote_player_id)
		remote_player_attacked.emit(remote_player_id)
		sim.damage_equipped_item("hand")
		return true
	show_creature_hit(creature_id)
	if multiplayer_guest:
		multiplayer_action_requested.emit("attack_creature", {"creature_id": creature_id})
	else:
		sim.hit_creature(creature_id, sim.active_weapon_damage())
	sim.damage_equipped_item("hand")
	return true


func tile_has_attack_target(tile: Vector2i) -> bool:
	return not remote_player_at_tile(tile.x, tile.y).is_empty() or not sim.creature_at_tile(tile.x, tile.y).is_empty()


func show_local_player_hit() -> void:
	_local_hit_flash_expires_msec = Time.get_ticks_msec() + HIT_FLASH_MSEC
	queue_redraw()


func show_creature_hit(creature_id: String) -> void:
	if creature_id.is_empty():
		return
	_creature_hit_flash_expires_msec[creature_id] = Time.get_ticks_msec() + HIT_FLASH_MSEC
	queue_redraw()


func show_remote_player_hit(player_id: String) -> void:
	if player_id.is_empty():
		return
	_remote_player_hit_flash_expires_msec[player_id] = Time.get_ticks_msec() + HIT_FLASH_MSEC
	queue_redraw()


func is_local_player_hit_flashing() -> bool:
	return _hit_flash_active(_local_hit_flash_expires_msec)


func is_creature_hit_flashing(creature_id: String) -> bool:
	return _hit_flash_active(int(_creature_hit_flash_expires_msec.get(creature_id, 0)))


func is_remote_player_hit_flashing(player_id: String) -> bool:
	return _hit_flash_active(int(_remote_player_hit_flash_expires_msec.get(player_id, 0)))


func _hit_flash_active(expires_msec: int) -> bool:
	return expires_msec > Time.get_ticks_msec()


func _prune_hit_flashes() -> void:
	var now := Time.get_ticks_msec()
	for creature_id in _creature_hit_flash_expires_msec.keys():
		if int(_creature_hit_flash_expires_msec[creature_id]) <= now:
			_creature_hit_flash_expires_msec.erase(creature_id)
	for player_id in _remote_player_hit_flash_expires_msec.keys():
		if int(_remote_player_hit_flash_expires_msec[player_id]) <= now:
			_remote_player_hit_flash_expires_msec.erase(player_id)


func _draw_hit_flash(canvas: CanvasItem, rect: Rect2, expires_msec: int) -> void:
	var remaining := expires_msec - Time.get_ticks_msec()
	if remaining <= 0:
		return
	var strength := clampf(float(remaining) / float(HIT_FLASH_MSEC), 0.0, 1.0)
	canvas.draw_rect(rect, Color(1.0, 0.08, 0.08, 0.18 + strength * 0.3))
	canvas.draw_rect(rect, Color(1.0, 0.28, 0.28, 0.65 + strength * 0.3), false, 2.0)


func set_virtual_move(left: bool, right: bool) -> void:
	virtual_left = left
	virtual_right = right


func set_virtual_jump(pressed: bool) -> void:
	virtual_jump_held = pressed


func set_bow_aim(direction: Vector2, active: bool, fire_on_release: bool = false) -> void:
	if direction.length() >= 0.1:
		bow_aim_direction = direction.normalized()
		sim.player["facing"] = 1 if bow_aim_direction.x >= 0.0 else -1
	if active:
		if not bow_drawing and _can_draw_bow():
			bow_drawing = true
			bow_draw_started_msec = Time.get_ticks_msec()
		return
	var was_drawing := bow_drawing
	bow_drawing = false
	if fire_on_release and was_drawing:
		_fire_bow()


func bow_draw_progress() -> float:
	if not bow_drawing:
		return 0.0
	return clampf(float(Time.get_ticks_msec() - bow_draw_started_msec) / 1000.0 / BOW_FULL_DRAW_SECONDS, 0.0, 1.0)


func _can_draw_bow() -> bool:
	return sim.has_method("is_bow_equipped") and sim.is_bow_equipped() and sim.arrow_count() > 0


func _fire_bow() -> bool:
	var held_seconds := float(Time.get_ticks_msec() - bow_draw_started_msec) / 1000.0
	if held_seconds < BOW_MIN_DRAW_SECONDS or not _can_draw_bow():
		return false
	var charge := clampf(held_seconds / BOW_FULL_DRAW_SECONDS, 0.0, 1.0)
	var direction := bow_aim_direction.normalized()
	if multiplayer_guest:
		multiplayer_action_requested.emit("fire_bow", {
			"direction_x": direction.x,
			"direction_y": direction.y,
			"charge": charge,
		})
		Sfx.attack()
		return true
	return not fire_authoritative_bow(direction, charge).is_empty()


func fire_authoritative_bow(direction: Vector2, charge: float) -> Dictionary:
	if direction.length() < 0.1 or not _can_draw_bow():
		return {}
	if not sim.consume_arrow_and_damage_bow():
		return {}
	direction = direction.normalized()
	charge = clampf(charge, 0.0, 1.0)
	var origin := Vector2(
		float(sim.player.get("x", 0.0)) + float(sim.player.get("w", 20.0)) * 0.5,
		float(sim.player.get("y", 0.0)) + float(sim.player.get("h", 28.0)) * 0.42,
	)
	var damage := 1 if charge < 0.45 else (2 if charge < 0.95 else 3)
	var critical := charge >= 0.99 and randf() < 0.2
	if critical:
		damage = 4
	var shot := {
		"origin_x": origin.x,
		"origin_y": origin.y,
		"direction_x": direction.x,
		"direction_y": direction.y,
		"charge": charge,
		"damage": damage,
		"critical": critical,
	}
	_spawn_arrow(shot, true)
	bow_shot_created.emit(shot)
	Sfx.attack()
	return shot


func show_multiplayer_bow_shot(payload: Dictionary) -> bool:
	var direction := Vector2(float(payload.get("direction_x", 0.0)), float(payload.get("direction_y", 0.0)))
	var origin := Vector2(float(payload.get("origin_x", 0.0)), float(payload.get("origin_y", 0.0)))
	var charge := float(payload.get("charge", 0.0))
	if (
		not is_finite(direction.x)
		or not is_finite(direction.y)
		or not is_finite(origin.x)
		or not is_finite(origin.y)
		or not is_finite(charge)
		or direction.length() < 0.1
	):
		return false
	_spawn_arrow(payload, false)
	return true


func _spawn_arrow(payload: Dictionary, authoritative: bool) -> void:
	var direction := Vector2(float(payload.get("direction_x", 0.0)), float(payload.get("direction_y", 0.0))).normalized()
	var origin := Vector2(float(payload.get("origin_x", 0.0)), float(payload.get("origin_y", 0.0)))
	var charge := clampf(float(payload.get("charge", 0.0)), 0.0, 1.0)
	arrows.append({
		"position": origin + direction * 14.0,
		"velocity": direction * lerpf(ARROW_MIN_SPEED, ARROW_MAX_SPEED, charge),
		"damage": int(payload.get("damage", 1)),
		"critical": bool(payload.get("critical", false)),
		"authoritative": authoritative,
		"age": 0.0,
	})


func _update_arrows(delta: float) -> void:
	for index in range(arrows.size() - 1, -1, -1):
		var arrow: Dictionary = arrows[index]
		arrow["age"] = float(arrow.get("age", 0.0)) + delta
		if float(arrow["age"]) >= ARROW_MAX_LIFETIME:
			arrows.remove_at(index)
			continue
		var velocity: Vector2 = arrow.get("velocity", Vector2.ZERO)
		velocity.y += ARROW_GRAVITY * delta
		var position: Vector2 = arrow.get("position", Vector2.ZERO) + velocity * delta
		arrow["velocity"] = velocity
		arrow["position"] = position
		var authoritative := bool(arrow.get("authoritative", true))
		var tile := Vector2i(floori(position.x / BlockDefs.TILE), floori(position.y / BlockDefs.TILE))
		if not sim.in_bounds(tile.x, tile.y) or sim.get_block(tile.x, tile.y).get("solid", false):
			if authoritative:
				sim.give_to_inventory("arrow", 1)
				sim.inventory_changed.emit()
				sim.state_changed.emit()
			arrows.remove_at(index)
			continue
		var hit_id := ""
		for raw_id in sim.creatures:
			var creature: Dictionary = sim.creatures[raw_id]
			var definition := sim._creature_definition(str(creature.get("block_name", "")))
			if _creature_draw_rect(creature, definition).grow(3.0).has_point(position):
				hit_id = str(raw_id)
				break
		if not hit_id.is_empty():
			if authoritative:
				show_creature_hit(hit_id)
				sim.hit_creature(hit_id, int(arrow.get("damage", 1)))
			arrows.remove_at(index)
			continue
		arrows[index] = arrow


func get_zoom() -> float:
	return zoom


func set_zoom(value: float) -> void:
	var minimum := DESKTOP_MIN_ZOOM if desktop_web_rendering else MIN_ZOOM
	var step := 0.25 if desktop_web_rendering else 0.5
	zoom = clampf(snapped(value, step), minimum, MAX_ZOOM)


func adjust_zoom(factor: float) -> void:
	set_zoom(zoom * factor)


func toggle_place_mode(on: bool) -> void:
	place_mode = on
	if on:
		mining_active = false
		mining.clear()


func _update_pointer(screen_pos: Vector2) -> void:
	pointer_active = true
	pointer_screen = screen_pos
	pointer_world = _screen_to_world(screen_pos)


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	# Input must use the same pixel-snapped camera that was used to render the
	# frame, while camera_pos itself retains its subpixel precision.
	return (screen_pos + _render_camera_pos()) / zoom


func _view_size() -> Vector2:
	var size := get_viewport().get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return Vector2(VIEW_W, VIEW_H)
	return size


func _update_camera(delta: float) -> void:
	var view := _view_size()
	var p: Dictionary = sim.player
	var center_x: float = p["x"] + p["w"] / 2.0
	var center_y: float = p["y"] + p["h"] / 2.0
	var target_x: float = zoom * center_x - view.x / 2.0
	var target_y: float = zoom * center_y - view.y / 2.0
	var safe_delta := minf(maxf(delta, 0.0), 0.1)
	var follow_x := 1.0 - exp(-CAMERA_FOLLOW_SPEED_X * safe_delta)
	var speed_y := CAMERA_FOLLOW_SPEED_Y_GROUND if p.get("on_ground", false) else CAMERA_FOLLOW_SPEED_Y_AIR
	var follow_y := 1.0 - exp(-speed_y * safe_delta)
	camera_pos.x = lerpf(camera_pos.x, target_x, follow_x)
	camera_pos.y = lerpf(camera_pos.y, target_y, follow_y)


func _render_camera_pos() -> Vector2:
	# One logical viewport pixel is several physical pixels on many Android
	# screens. Whole-pixel snapping therefore looks jerky at zoom 1 even when
	# the simulation itself is stable. Preserve coarse pixel snapping up close,
	# but use quarter/half-pixel steps while zoomed out.
	var quantum := 0.25 if zoom <= 1.0 else (0.5 if zoom <= 2.0 else 1.0)
	if desktop_web_rendering:
		# Godot Web exposes backing-canvas coordinates here, not CSS coordinates.
		# Whole render-pixel movement while zoomed out avoids alternating nearest-
		# neighbor phases; a half-pixel remains smooth enough at larger zooms.
		quantum = 1.0 if zoom <= 1.0 else 0.5
	return camera_pos.snapped(Vector2.ONE * quantum)


func _screen_to_tile(screen_pos: Vector2) -> Vector2i:
	var world := _screen_to_world(screen_pos)
	return Vector2i(int(floor(world.x / BlockDefs.TILE)), int(floor(world.y / BlockDefs.TILE)))


func _tile_in_world(tile: Vector2i) -> bool:
	return sim.in_bounds(tile.x, tile.y)


func _finger_tile() -> Vector2i:
	return _screen_to_tile(pointer_screen)


func _get_target() -> Dictionary:
	return sim.raycast_from_player(pointer_world)


func _resolve_mine_tile() -> Vector2i:
	if keyboard_mining_held and keyboard_mine_direction != Vector2i.ZERO:
		return keyboard_mine_candidate()
	var finger := _finger_tile()
	if _tile_in_world(finger):
		var block := sim.get_block(finger.x, finger.y)
		if block["id"] != 0 and sim.player_near(finger.x, finger.y):
			return finger
	var target := _get_target()
	if target.has("mine"):
		return target["mine"]
	return NO_TILE


func _update_mouse_mining() -> void:
	if not _mouse_down or _mouse_long_press:
		return
	var elapsed := Time.get_ticks_msec() / 1000.0 - _mouse_press_time
	if elapsed >= LONG_PRESS_TIME:
		_mouse_long_press = true
		start_mining()


func _tick_mining(delta: float) -> void:
	var keyboard_active := keyboard_mining_held and keyboard_mine_direction != Vector2i.ZERO
	if (
		not mining_active
		or (not keyboard_active and (not pointer_armed or not pointer_active))
		or _player_is_moving()
	):
		stop_mining()
		return

	var mine := _resolve_mine_tile()
	if mine == NO_TILE:
		mining.clear()
		return

	var tx := mine.x
	var ty := mine.y
	var block: Dictionary = sim.plant_block_at(tx, ty)
	if block.is_empty():
		block = sim.get_block(tx, ty)
	if block["id"] == 0 or not sim.player_near(tx, ty):
		mining.clear()
		return
	var harvestable := sim.can_harvest_block(block)
	var need := float(sim.get_block_hardness(block)) * (1.8 if not harvestable else 1.0)
	if mining.is_empty() or mining.get("tx") != tx or mining.get("ty") != ty or bool(mining.get("harvestable", true)) != harvestable:
		mining = {"tx": tx, "ty": ty, "progress": 0.0, "need": need, "last_stage": -1, "harvestable": harvestable}
		if not harvestable:
			harvest_blocked.emit(
				str(block.get("name", "unknown")),
				sim.block_harvest_tier(block),
				sim.active_harvest_tier(),
			)

	mining["progress"] = mining.get("progress", 0.0) + delta * MINING_RATE * sim.active_mining_multiplier()
	var stage := int(float(mining["progress"]) / float(mining["need"]) * 5.0)
	if stage > mining.get("last_stage", -1):
		mining["last_stage"] = stage
		Sfx.mine_hit(block.get("name", ""))

	if mining["progress"] >= mining["need"]:
		if multiplayer_guest:
			multiplayer_action_requested.emit("mine_block", {"x": tx, "y": ty})
			_optimistically_remove_multiplayer_block(tx, ty)
			mining.clear()
			return
		if sim.finish_break(tx, ty):
			var block_name := str(block.get("name", "unknown"))
			Analytics.record_activation_step("block_mined", {"block": block_name})
			block_mined.emit(block_name)
		mining.clear()


func _optimistically_remove_multiplayer_block(tx: int, ty: int) -> void:
	# Plants have separate growth state and need a richer reconciliation message.
	# Regular tiles can disappear immediately and are corrected by the host's
	# targeted action_result if reach or world state changed in transit.
	# The One Block anchor is replaced synchronously by the authoritative host.
	# Keep the current solid tile as a collision bridge until that replacement
	# arrives so a guest standing on it cannot fall during network latency.
	if sim.world_mode == WorldSim.WORLD_MODE_ONE_BLOCK and Vector2i(tx, ty) == sim.one_block_position:
		return
	if sim.plant_block_at(tx, ty).is_empty() and sim.block_id(tx, ty) != 0:
		sim.set_block(tx, ty, 0)


func _optimistically_place_multiplayer_block(tx: int, ty: int, block_name: String) -> bool:
	# Only regular tiles have enough information for a reversible local preview.
	# Plants and creature items remain host-driven because their replicated state
	# contains more than a tile id. The authoritative inventory is not changed;
	# player_inventory and action_result reconcile both accepted and rejected taps.
	if block_name.is_empty() or block_name != sim.selected or not sim.can_place_block(tx, ty):
		return false
	var definition: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	if definition.get("item", false) or definition.get("plant", false) or definition.get("creature_item", false):
		return false
	var level := 0 if definition.get("fluid", false) else -1
	sim.set_block(tx, ty, int(definition.get("id", 0)), level)
	Sfx.place(block_name)
	return true


func remote_player_at_tile(tx: int, ty: int) -> String:
	var tile_rect := Rect2(float(tx * BlockDefs.TILE), float(ty * BlockDefs.TILE), BlockDefs.TILE, BlockDefs.TILE)
	for raw_player_id in remote_players:
		var player_id := str(raw_player_id)
		var remote: Dictionary = remote_players[player_id]
		var render_position := _remote_player_render_position(player_id, remote)
		var rect := Rect2(render_position.x, render_position.y, 20.0, 28.0)
		if tile_rect.intersects(rect):
			return player_id
	return ""


func _emit_hud() -> void:
	var p: Dictionary = sim.player
	var coords := "x: %d, y: %d" % [int(p["x"] / BlockDefs.TILE), int(p["y"] / BlockDefs.TILE)]
	var score := sim.one_block_mined if sim.world_mode == WorldSim.WORLD_MODE_ONE_BLOCK else sim.block_count
	if sim.world_mode == WorldSim.WORLD_MODE_CHALLENGE:
		score = sim.challenge_best_distance
	var blocks := CompactNumberClass.format(score)
	if coords == _last_hud_coords and blocks == _last_hud_blocks:
		return
	_last_hud_coords = coords
	_last_hud_blocks = blocks
	hud_update.emit(coords, blocks)


func _on_inventory_changed() -> void:
	if suppress_inventory_ui_updates:
		return
	craft_state_changed.emit(sim)


func refresh_inventory_ui() -> void:
	_on_inventory_changed()


func _on_block_count_changed(_count: int) -> void:
	pass


func _invalidate_lighting() -> void:
	_lighting_dirty = true


func _invalidate_world_render() -> void:
	_world_render_dirty = true


func _rect_contains_rect(outer: Rect2i, inner: Rect2i) -> bool:
	return (
		outer.size.x > 0 and outer.size.y > 0
		and outer.has_point(inner.position)
		and outer.has_point(inner.end - Vector2i.ONE)
	)


func _update_render_layers() -> void:
	var draw_cam := _render_camera_pos()
	_world_layer.position = -draw_cam
	_world_layer.scale = Vector2(zoom, zoom)
	# Godot floors snapped procedural vertices while panning. Rounding the texture
	# layer instead moves it one pixel to the right during fractional camera phases.
	# Preserve the lighting-specific phase correction to avoid one-pixel shadow drift.
	_lighting_layer.position = Vector2(
		_snap_lighting_axis(-draw_cam.x),
		_snap_lighting_axis(-draw_cam.y)
	)
	_lighting_layer.scale = Vector2(zoom, zoom)
	_sunlight_layer.position = -draw_cam
	_sunlight_layer.scale = Vector2(zoom, zoom)
	_targeting_layer.position = -draw_cam
	_targeting_layer.scale = Vector2(zoom, zoom)
	var visible := _visible_tile_range()
	_sync_tree_fade_render_state()
	if _world_render_dirty or not _rect_contains_rect(_world_render_area, visible):
		_world_render_area = visible.grow(WORLD_RENDER_MARGIN)
		_world_render_dirty = false
		_world_layer.queue_redraw()
	var light_rebuild_due := _lighting_dirty and anim_frame - _lighting_last_build_frame >= _lighting_rebuild_interval_frames()
	if light_rebuild_due or not _rect_contains_rect(_lighting_render_area, visible):
		_lighting_render_area = visible.grow(_lighting_render_margin())
		_lighting_layer.queue_redraw()


func _sync_tree_fade_render_state() -> void:
	var tree_fade_active := sim.ignores_trees()
	if tree_fade_active == _last_tree_fade_active:
		return
	_last_tree_fade_active = tree_fade_active
	# The world layer records every visible block into one cached CanvasItem.
	# Re-recording it for every tile crossed while climbing is especially costly
	# in forests, where each leaf tile emits several draw commands. The player is
	# already rendered above the world layer, so one fade snapshot for the whole
	# traversal keeps them readable without rebuilding the forest while moving.
	_world_render_dirty = true


func _snap_lighting_axis(value: float) -> float:
	if zoom <= 1.0:
		return floorf(value + 0.25)
	return floorf(value)


func _lighting_rebuild_interval_frames() -> int:
	if zoom <= 1.0:
		return 60
	if zoom <= 2.0:
		return 30
	return LIGHT_REBUILD_INTERVAL_FRAMES


func _lighting_render_margin() -> int:
	return 4 if zoom <= 1.0 else (3 if zoom <= 2.0 else 2)


func _draw() -> void:
	var draw_cam := _render_camera_pos()
	draw_set_transform(-draw_cam, 0.0, Vector2(zoom, zoom))
	_draw_fluids()
	_draw_plants()
	_draw_creatures()
	_draw_arrows()
	_draw_fire()
	_draw_player()
	_draw_mining_cracks()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_remote_player_indicators()


func _draw_arrows() -> void:
	for arrow: Dictionary in arrows:
		var position: Vector2 = arrow.get("position", Vector2.ZERO)
		var velocity: Vector2 = arrow.get("velocity", Vector2.RIGHT)
		var direction := velocity.normalized()
		var tail := position - direction * 12.0
		draw_line(tail, position, Color("#d5a45d"), 2.0, false)
		var wing := direction.orthogonal() * 3.0
		draw_colored_polygon(PackedVector2Array([position + direction * 4.0, position - direction * 2.0 + wing, position - direction * 2.0 - wing]), Color("#d9dde5"))
		if bool(arrow.get("critical", false)):
			draw_circle(tail, 2.0, Color("#fff2a3"))


func _draw_sky_layer() -> void:
	var biome: Dictionary = sim.active_biome_definition()
	var visual: Dictionary = biome.get("visual", {}) if biome.get("visual", {}) is Dictionary else {}
	var biome_id := str(biome.get("biome_id", "plains"))
	if biome_uses_resonant_deep_background(biome):
		ArtAssets.draw_resonant_deep(_sky_layer, _view_size(), float(anim_frame) / 60.0, camera_pos.x, sim.world_seed, biome_id, Color(str(visual.get("sky_color", "#101f24"))))
		return
	var environment: Dictionary = biome.get("environment", {}) if biome.get("environment", {}) is Dictionary else {}
	var aurora_visible := _aurora_visibility(float(environment.get("temperature", 0.2))) > 0.001
	ArtAssets.draw_sky(_sky_layer, _view_size(), float(anim_frame) / 60.0, camera_pos.x, sim.world_day_phase(), sim.world_daylight_factor(), sim.world_seed, Color(str(visual.get("sky_color", "#67b8e3"))), Color(str(visual.get("daylight_tint", "#fff7df"))), not aurora_visible)


static func biome_uses_resonant_deep_background(biome: Dictionary) -> bool:
	var biome_id := str(biome.get("biome_id", ""))
	if biome_id in WorldSim.RESONANT_DEEP_BIOMES:
		return true
	var placement: Dictionary = biome.get("placement", {}) if biome.get("placement", {}) is Dictionary else {}
	return str(placement.get("layer", "surface")) == WorldSim.RESONANT_LAYER_ID


func _draw_sky_background_layer() -> void:
	_update_sky_background_shader()
	_sky_background_view_size = _view_size()
	_sky_background_layer.draw_rect(Rect2(Vector2.ZERO, _sky_background_view_size), Color.WHITE)


func _update_sky_background_shader() -> float:
	var biome: Dictionary = sim.active_biome_definition()
	var visual: Dictionary = biome.get("visual", {}) if biome.get("visual", {}) is Dictionary else {}
	var environment: Dictionary = biome.get("environment", {}) if biome.get("environment", {}) is Dictionary else {}
	_sky_background_material.set_shader_parameter("time_sec", float(anim_frame) / 60.0)
	_sky_background_material.set_shader_parameter("scroll_x", camera_pos.x)
	_sky_background_material.set_shader_parameter("day_phase", sim.world_day_phase())
	_sky_background_material.set_shader_parameter("daylight", sim.world_daylight_factor())
	_sky_background_material.set_shader_parameter("world_seed", float(posmod(sim.world_seed, 10007)))
	var temperature := float(environment.get("temperature", 0.2))
	var aurora_visibility := _aurora_visibility(temperature)
	_sky_background_material.set_shader_parameter("temperature", temperature)
	_sky_background_material.set_shader_parameter("aurora_visibility", aurora_visibility)
	_sky_background_material.set_shader_parameter("biome_sky", Color(str(visual.get("sky_color", "#67b8e3"))))
	_sky_background_material.set_shader_parameter("daylight_tint", Color(str(visual.get("daylight_tint", "#fff7df"))))
	return aurora_visibility


func _sky_shader_code() -> String:
	return """
shader_type canvas_item;
render_mode unshaded;

uniform float time_sec = 0.0;
uniform float scroll_x = 0.0;
uniform float day_phase = 0.0;
uniform float daylight = 1.0;
uniform float world_seed = 0.0;
uniform float temperature = 0.2;
uniform float aurora_visibility = 0.0;
uniform vec4 biome_sky : source_color = vec4(0.4, 0.72, 0.89, 1.0);
uniform vec4 daylight_tint : source_color = vec4(1.0, 0.97, 0.88, 1.0);

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32 + world_seed * 0.001);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(cell);
	float b = hash21(cell + vec2(1.0, 0.0));
	float c = hash21(cell + vec2(0.0, 1.0));
	float d = hash21(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float day_mix = clamp((daylight - 0.1) / 0.9, 0.0, 1.0);
	float sunset = clamp(1.0 - abs(day_phase - 0.535) / 0.08, 0.0, 1.0);
	float dawn_distance = min(abs(day_phase - 0.982), 1.0 - abs(day_phase - 0.982));
	float dawn = clamp(1.0 - dawn_distance / 0.08, 0.0, 1.0);
	float golden = max(sunset, dawn);

	vec3 night_top = vec3(0.015, 0.025, 0.085);
	vec3 night_bottom = vec3(0.07, 0.13, 0.25);
	vec3 day_top = mix(vec3(0.12, 0.43, 0.78), biome_sky.rgb * 0.72, 0.34);
	vec3 day_middle = mix(vec3(0.35, 0.68, 0.9), biome_sky.rgb, 0.38);
	vec3 day_bottom = mix(vec3(0.72, 0.86, 0.95), daylight_tint.rgb, 0.42);
	day_top = mix(day_top, vec3(0.045, 0.19, 0.52), golden * 0.68);
	day_middle = mix(day_middle, vec3(0.66, 0.22, 0.38), golden * 0.78);
	day_bottom = mix(day_bottom, vec3(1.0, 0.36, 0.08), golden * 0.94);

	float upper_mix = smoothstep(0.0, 0.58, uv.y);
	float lower_mix = smoothstep(0.48, 1.0, uv.y);
	vec3 day_color = mix(day_top, day_middle, upper_mix);
	day_color = mix(day_color, day_bottom, lower_mix);
	vec3 color = mix(mix(night_top, night_bottom, uv.y), day_color, day_mix);

	float horizon = exp(-pow((uv.y - 0.69) * 5.0, 2.0));
	vec3 horizon_color = mix(daylight_tint.rgb, vec3(1.0, 0.38, 0.08), golden);
	color += horizon_color * horizon * (0.035 + golden * 0.2) * day_mix;

	float cold = smoothstep(0.48, 0.9, -temperature);
	float night = 1.0 - smoothstep(0.09, 0.42, daylight);
	float aurora_strength = cold * night * aurora_visibility;
	if (aurora_strength > 0.001) {
		float seed_phase = world_seed * 0.013;
		float drift = time_sec * 0.055;
		float wave_a = sin(uv.x * 8.0 + drift + seed_phase) * 0.055;
		float wave_b = sin(uv.x * 17.0 - drift * 0.7 + seed_phase * 1.7) * 0.022;
		float wave_c = sin(uv.x * 4.3 + drift * 0.35 + seed_phase * 0.4) * 0.038;
		float ridge_a = 0.22 + wave_a + wave_b;
		float ridge_b = 0.31 + wave_c - wave_b * 0.65;
		float curtain_a = exp(-pow((uv.y - ridge_a) / 0.078, 2.0));
		float curtain_b = exp(-pow((uv.y - ridge_b) / 0.105, 2.0));
		float folds = 0.48 + 0.52 * pow(sin(uv.x * 31.0 + seed_phase + value_noise(vec2(uv.x * 7.0 + drift, 2.0)) * 4.0), 2.0);
		float shimmer = 0.78 + 0.22 * sin(time_sec * 0.7 + uv.x * 11.0 + seed_phase);
		float vertical_fade = smoothstep(0.04, 0.14, uv.y) * (1.0 - smoothstep(0.48, 0.64, uv.y));
		float aurora = (curtain_a * folds + curtain_b * (1.0 - folds * 0.42) * 0.62) * shimmer * vertical_fade;
		vec3 green = vec3(0.16, 1.0, 0.62);
		vec3 cyan = vec3(0.13, 0.72, 1.0);
		vec3 violet = vec3(0.55, 0.28, 1.0);
		vec3 aurora_color = mix(green, cyan, smoothstep(0.12, 0.42, uv.y));
		aurora_color = mix(aurora_color, violet, pow(folds, 4.0) * 0.32);
		color += aurora_color * aurora * aurora_strength * 0.52;
		color = mix(color, aurora_color, aurora * aurora_strength * 0.08);
	}

	float vignette = 1.0 - smoothstep(0.46, 0.86, length((uv - vec2(0.5)) * vec2(0.82, 1.0)));
	color *= mix(0.82, 1.0, vignette);
	COLOR = vec4(color, 1.0);
}
"""


func _aurora_visibility(temperature: float) -> float:
	if temperature > -0.55 or sim.weather_type != "clear":
		return 0.0
	var phase := sim.world_day_phase()
	if phase < 0.585 or phase > 0.925:
		return 0.0
	var night_index := int(sim.weather_tick / sim.DAY_LENGTH_TICKS)
	var event_roll := BlockDefs.hash2(sim.world_seed + night_index * 193, night_index * 389 + 71)
	var coldness := clampf((-temperature - 0.55) / 0.45, 0.0, 1.0)
	var chance := lerpf(0.18, 0.42, coldness)
	if event_roll > chance:
		return 0.0
	var start_roll := BlockDefs.hash2(sim.world_seed + night_index * 271, night_index * 149 + 113)
	var duration_roll := BlockDefs.hash2(sim.world_seed + night_index * 337, night_index * 211 + 157)
	var start_phase := lerpf(0.61, 0.73, start_roll)
	var duration := lerpf(0.1, 0.2, duration_roll)
	var end_phase := minf(0.91, start_phase + duration)
	var fade := 0.018
	var fade_in := smoothstep(start_phase, start_phase + fade, phase)
	var fade_out := 1.0 - smoothstep(end_phase - fade, end_phase, phase)
	var pulse := 0.82 + 0.18 * sin(float(anim_frame) / 60.0 * 0.17 + start_roll * TAU)
	return clampf(fade_in * fade_out * pulse, 0.0, 1.0)


func _draw_world_layer() -> void:
	_draw_world(_world_layer, _world_render_area)


func _draw_lighting_layer() -> void:
	_draw_lighting(_lighting_layer, _lighting_render_area)


func _draw_sunlight_layer() -> void:
	if _low_zoom_lod_enabled():
		return
	_draw_directional_sunlight(_sunlight_layer, _visible_tile_range().grow(1))
	_draw_plant_glows(_sunlight_layer)
	_draw_creature_glows(_sunlight_layer)


func _sync_creature_lighting() -> void:
	var parts: Array[String] = []
	var ids: Array = sim.creatures.keys()
	ids.sort()
	for raw_id in ids:
		var creature: Dictionary = sim.creatures[raw_id]
		var emission := sim.creature_light_emission(creature)
		if emission <= 0.0:
			continue
		parts.append("%s:%d:%d:%d" % [str(raw_id), floori(float(creature.get("x", 0.0))), floori(float(creature.get("y", 0.0))), roundi(emission * 100.0)])
	var signature := "|".join(parts)
	if signature == _last_creature_light_signature:
		return
	_last_creature_light_signature = signature
	_lighting_dirty = true


func _draw_creature_glows(canvas: CanvasItem) -> void:
	var tile := float(BlockDefs.TILE)
	for creature: Dictionary in sim.creatures.values():
		var emission := sim.creature_light_emission(creature)
		if emission <= 0.0:
			continue
		var block_name := str(creature.get("block_name", ""))
		var block: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
		var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
		var lighting: Dictionary = definition.get("lighting", {}) if definition.get("lighting", {}) is Dictionary else {}
		var glow_color := Color(str(lighting.get("color", "#ffd067")))
		var radius_scale := clampf(float(lighting.get("radius", 0.75)), 0.4, 1.2)
		var radius := 46.0 * radius_scale / maxf(zoom, 1.0)
		var center := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0))) * tile
		var pulse := 0.86 + 0.14 * sin(float(anim_frame) * 0.055 + float(str(creature.get("id", "")).hash() & 255))
		for ring in range(6, 0, -1):
			var ring_t := float(ring) / 6.0
			var alpha := emission * pulse * (1.0 - ring_t * 0.76) * 0.055
			canvas.draw_circle(center, radius * ring_t, Color(glow_color, alpha))
		canvas.draw_circle(center, radius * 0.13, Color(glow_color.lightened(0.25), emission * pulse * 0.16))


func _draw_plant_glows(canvas: CanvasItem) -> void:
	var visible := _visible_tile_range().grow(2)
	var tile := float(BlockDefs.TILE)
	for plant: Dictionary in sim.plant_growth.values():
		var block: Dictionary = BlockDefs.BLOCKS.get(str(plant.get("block_name", "")), {})
		var emission := sim.block_light_emission(block)
		if emission <= 0.0:
			continue
		var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
		var lighting: Dictionary = definition.get("lighting", {}) if definition.get("lighting", {}) is Dictionary else {}
		var glow_color := Color(str(lighting.get("color", "#65d9bd")))
		var cells: Array = plant.get("cells", []) if plant.get("cells", []) is Array else []
		for raw_cell in cells:
			if raw_cell is not Vector2i or not visible.has_point(raw_cell):
				continue
			var center := (Vector2(raw_cell) + Vector2.ONE * 0.5) * tile
			var growth: Dictionary = definition.get("growth", {}) if definition.get("growth", {}) is Dictionary else {}
			if str(growth.get("form", "")) == "surface_creeper":
				match _plant_surface_anchor(raw_cell):
					"left": center.x = (float(raw_cell.x) + 0.08) * tile
					"right": center.x = (float(raw_cell.x) + 0.92) * tile
					"ceiling": center.y = (float(raw_cell.y) + 0.08) * tile
					"floor": center.y = (float(raw_cell.y) + 0.92) * tile
			var radius := 28.0 / maxf(zoom, 1.0)
			for ring in range(4, 0, -1):
				var ring_t := float(ring) / 4.0
				canvas.draw_circle(center, radius * ring_t, Color(glow_color, emission * (1.0 - ring_t * 0.76) * 0.038))


func _draw_atmosphere_layer() -> void:
	var biome: Dictionary = sim.active_biome_definition()
	var visual: Dictionary = biome.get("visual", {}) if biome.get("visual", {}) is Dictionary else {}
	ArtAssets.draw_atmosphere(
		_atmosphere_layer,
		_view_size(),
		float(anim_frame) / 60.0,
		camera_pos.x,
		sim.world_seed,
		sim.world_day_phase(),
		sim.world_daylight_factor(),
		str(biome.get("biome_id", "plains")),
		Color(str(visual.get("sky_color", "#67b8e3")))
	)


func _draw_targeting_layer() -> void:
	_draw_targeting(_targeting_layer)


func _draw_weather_layer() -> void:
	_draw_weather(_weather_layer)


func _weather_target_screen() -> Vector2:
	var center := Vector2(
		(float(sim.weather_target.x) + 0.5) * BlockDefs.TILE,
		(float(sim.weather_target.y) + 0.5) * BlockDefs.TILE
	)
	return center * zoom - camera_pos


func _draw_weather(canvas: CanvasItem) -> void:
	if sim.has_method("_weather_disabled_for_player") and sim._weather_disabled_for_player():
		return
	var kind := str(sim.weather_type)
	if kind == "clear":
		return
	var view := _view_size()
	var target := _weather_target_screen()
	if kind == "rain":
		canvas.draw_rect(Rect2(Vector2.ZERO, view), Color(0.08, 0.16, 0.3, 0.2))
		for i in 72:
			var x := fposmod(float(i * 83 + anim_frame * 5), view.x + 40.0) - 20.0
			var y := fposmod(float(i * 47 + anim_frame * 11), view.y + 50.0) - 25.0
			canvas.draw_line(Vector2(x, y), Vector2(x - 5.0, y + 15.0), Color(0.55, 0.82, 1.0, 0.65), 1.5)
		var pulse := 8.0 + sin(float(anim_frame) * 0.12) * 2.0
		canvas.draw_circle(target, pulse, Color(0.25, 0.72, 1.0, 0.18))
		canvas.draw_arc(target, pulse + 3.0, 0.0, TAU, 24, Color(0.55, 0.88, 1.0, 0.8), 2.0)
		return
	if kind == "lightning":
		var urgency := 1.0 - float(sim.weather_ticks_remaining) / float(sim.LIGHTNING_WARNING_TICKS)
		var pulse := 10.0 + sin(float(anim_frame) * 0.22) * 3.0
		canvas.draw_circle(target, pulse, Color(1.0, 0.72, 0.12, 0.12 + urgency * 0.2))
		canvas.draw_arc(target, pulse + 4.0, 0.0, TAU, 24, Color(1.0, 0.82, 0.25, 0.75), 2.5)
		if sim.weather_ticks_remaining <= sim.LIGHTNING_FLASH_TICKS:
			canvas.draw_rect(Rect2(Vector2.ZERO, view), Color(0.9, 0.95, 1.0, 0.24))
			var bolt := PackedVector2Array([
				Vector2(target.x + 18.0, 0.0),
				Vector2(target.x - 8.0, target.y * 0.38),
				Vector2(target.x + 7.0, target.y * 0.63),
				target,
			])
			canvas.draw_polyline(bolt, Color(1.0, 0.95, 0.55), 6.0)
			canvas.draw_polyline(bolt, Color.WHITE, 2.0)


func _solid_tile(tx: int, ty: int) -> bool:
	return sim.get_block(tx, ty).get("solid", false)


func _bevel_mask(tx: int, ty: int) -> int:
	var mask := BlockDefs.BEVEL_ALL
	if _solid_tile(tx - 1, ty):
		mask &= ~BlockDefs.BEVEL_LEFT
	if _solid_tile(tx + 1, ty):
		mask &= ~BlockDefs.BEVEL_RIGHT
	if _solid_tile(tx, ty - 1):
		mask &= ~BlockDefs.BEVEL_TOP
	if _solid_tile(tx, ty + 1):
		mask &= ~BlockDefs.BEVEL_BOTTOM
	return mask


func _draw_block(canvas: CanvasItem, tx: int, ty: int, block: Dictionary) -> void:
	var t := BlockDefs.TILE
	var dest := Rect2(float(tx * t), float(ty * t), float(t), float(t))
	var render_block := block
	if str(block.get("name", "")) == "chest" and sim.is_one_use_cache_at(tx, ty):
		render_block = block.duplicate()
		render_block["name"] = "aged_chest"
	elif str(block.get("name", "")) == "chest" and sim.is_death_cache_at(tx, ty):
		render_block = block.duplicate()
		render_block["name"] = "death_cache"
	var modulate := Color.WHITE
	var fluid_level := 0
	var fluid_falling := false
	var open_above := true
	if block.get("fluid", false):
		fluid_level = sim.get_fluid_level(tx, ty)
		fluid_falling = sim.is_fluid_falling_at(tx, ty)
		open_above = sim.get_block(tx, ty - 1).get("id", 0) != block.get("id", 0)
	elif block.get("name", "") == "obsidian":
		modulate = Color(0.72, 0.62, 0.95)
	if sim.ignores_trees() and sim.is_tree_block(block):
		var px: float = sim.player["x"] + sim.player["w"] * 0.5
		var py: float = sim.player["y"] + sim.player["h"] * 0.5
		var bx: float = float(tx * t) + float(t) * 0.5
		var by: float = float(ty * t) + float(t) * 0.5
		var dist: float = Vector2(px, py).distance_to(Vector2(bx, by))
		if dist < float(t) * 4.0:
			var fade: float = clampf(dist / (float(t) * 4.0), 0.0, 1.0)
			modulate = Color(1, 1, 1, lerpf(0.28, 0.55, fade))
	BlockDefs.draw_block(
		canvas, tx, ty, render_block, modulate, anim_frame,
		fluid_level, fluid_falling, open_above, dest, _bevel_mask(tx, ty)
	)


func _visible_tile_range() -> Rect2i:
	var view := _view_size()
	var pad := 2
	var x0 := int(floor(camera_pos.x / zoom / float(BlockDefs.TILE))) - pad
	var y0 := int(floor(camera_pos.y / zoom / float(BlockDefs.TILE))) - pad
	var x1 := int(ceil((camera_pos.x + view.x) / zoom / float(BlockDefs.TILE))) + pad
	var y1 := int(ceil((camera_pos.y + view.y) / zoom / float(BlockDefs.TILE))) + pad
	return Rect2i(x0, y0, x1 - x0, y1 - y0)


func _ensure_lighting_cache(visible_area: Rect2i) -> void:
	var wanted := visible_area.grow(_lighting_cache_margin())
	var area_changed := wanted != _lighting_cache_area
	var rebuild_due := _lighting_dirty and anim_frame - _lighting_last_build_frame >= _lighting_rebuild_interval_frames()
	if not _lighting_cache.is_empty() and not area_changed and not rebuild_due:
		return
	_lighting_cache_area = wanted
	_lighting_cache = sim.build_light_maps(wanted, visible_area.grow(1))
	_lighting_sample_area = Rect2i()
	_lighting_last_build_frame = anim_frame
	_lighting_dirty = false


func _lighting_cache_margin() -> int:
	if zoom <= 1.0:
		return 4
	if zoom <= 2.0:
		return 6
	return LIGHT_CACHE_MARGIN


func _ensure_lighting_samples(area: Rect2i) -> void:
	var sample_area := area.grow(1)
	if sample_area == _lighting_sample_area:
		return
	_lighting_sample_area = sample_area
	_sampled_combined.clear()
	_sampled_daylight.clear()
	_sampled_warm.clear()
	_sampled_passable.clear()
	var combined: Dictionary = _lighting_cache.get("visual_combined", _lighting_cache.get("combined", {}))
	var daylight: Dictionary = _lighting_cache.get("visual_daylight", _lighting_cache.get("daylight", {}))
	var warm: Dictionary = _lighting_cache.get("visual_warm", _lighting_cache.get("warm", {}))
	for sample_y in range(sample_area.position.y, sample_area.end.y):
		for sample_x in range(sample_area.position.x, sample_area.end.x):
			var sample_pos := Vector2i(sample_x, sample_y)
			_sampled_combined[sample_pos] = _light_at_tile(combined, sample_pos)
			_sampled_daylight[sample_pos] = _light_at_tile(daylight, sample_pos)
			_sampled_warm[sample_pos] = _light_at_tile(warm, sample_pos)
			_sampled_passable[sample_pos] = sim.light_passable(sim.get_block(sample_x, sample_y))


func _light_at_tile(values: Dictionary, pos: Vector2i) -> float:
	if values.has(pos):
		return float(values[pos])
	var block := sim.get_block(pos.x, pos.y)
	if sim.light_passable(block):
		return float(values.get(pos, 0.0))
	var level := float(values.get(pos, 0.0))
	for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		level = maxf(level, float(values.get(pos + offset, 0.0)) - 0.025)
	return maxf(0.0, level)


func _corner_light(values: Dictionary, passable: Dictionary, pos: Vector2i, right: bool, bottom: bool) -> float:
	var current := float(values.get(pos, 0.0))
	var current_passable := bool(passable.get(pos, false))
	if current_passable and current >= 0.98:
		return current
	var corner_x := 1 if right else -1
	var corner_y := 1 if bottom else -1
	var horizontal := pos + Vector2i(corner_x, 0)
	var vertical := pos + Vector2i(0, corner_y)
	var diagonal := pos + Vector2i(corner_x, corner_y)
	# Two opaque side-neighbors seal the diagonal corner. Without this check the
	# vertex average lets a bright diagonal air cell bleed through the zero-width
	# gap and paints an artificial triangular gradient in both air tiles.
	var sealed_diagonal := (
		current_passable
		and not bool(passable.get(horizontal, false))
		and not bool(passable.get(vertical, false))
	)
	var x0 := 0 if right else -1
	var y0 := 0 if bottom else -1
	var total := 0.0
	var count := 0
	for sample_pos: Vector2i in [
		pos + Vector2i(x0, y0), pos + Vector2i(x0 + 1, y0),
		pos + Vector2i(x0, y0 + 1), pos + Vector2i(x0 + 1, y0 + 1),
	]:
		if sealed_diagonal and sample_pos == diagonal:
			continue
		var sample_passable := bool(passable.get(sample_pos, false))
		if current_passable and not sample_passable:
			continue
		if not current_passable and not sample_passable:
			continue
		total += float(values.get(sample_pos, 0.0))
		count += 1
	return total / float(count) if count > 0 else current


func _dark_color(level: float) -> Color:
	var darkness := MAX_CAVE_DARKNESS * pow(1.0 - clampf(level, 0.0, 1.0), 1.35)
	return Color(0.015, 0.025, 0.06, darkness)


func _warm_color(level: float) -> Color:
	return Color(1.0, 0.38, 0.08, clampf(level, 0.0, 1.0) * 0.14)


func _visible_warm_level(warm: float, daylight: float) -> float:
	# Emissive blocks remain visually bright in daylight, but their colored halo is
	# reserved for genuinely dark spaces. This avoids a large orange patch outdoors.
	return clampf(warm, 0.0, 1.0) * pow(1.0 - clampf(daylight, 0.0, 1.0), 1.35)


func _draw_lighting(canvas: CanvasItem, area: Rect2i) -> void:
	if area.size.x <= 0 or area.size.y <= 0:
		return
	_ensure_lighting_cache(area)
	var tile := float(BlockDefs.TILE)
	# Keep lighting texels on the same world-pixel grid as procedural block art.
	# Scaling one texel to a full tile lets Canvas rounding expose a one-pixel
	# bright seam while the camera moves at fractional coordinates.
	var pixels_per_tile := LOW_ZOOM_TILE_PIXELS if _low_zoom_lod_enabled() else BlockDefs.TILE
	var image := Image.create(area.size.x * pixels_per_tile, area.size.y * pixels_per_tile, false, Image.FORMAT_RGBA8)
	var combined: Dictionary = _lighting_cache.get("visual_combined", _lighting_cache.get("combined", {}))
	var daylight: Dictionary = _lighting_cache.get("visual_daylight", _lighting_cache.get("daylight", {}))
	var warm_light: Dictionary = _lighting_cache.get("visual_warm", _lighting_cache.get("warm", {}))
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var pos := Vector2i(x, y)
			var day_level := float(daylight.get(pos, 0.0))
			var dark := _dark_color(float(combined.get(pos, 0.0)))
			var warm := _warm_color(_visible_warm_level(float(warm_light.get(pos, 0.0)), day_level))
			image.fill_rect(
				Rect2i(
					(x - area.position.x) * pixels_per_tile,
					(y - area.position.y) * pixels_per_tile,
					pixels_per_tile,
					pixels_per_tile
				),
				_color_over(dark, warm)
			)
	_lighting_texture = ImageTexture.create_from_image(image)
	canvas.draw_texture_rect(
		_lighting_texture,
		Rect2(Vector2(area.position) * tile, Vector2(area.size) * tile),
		false
	)
	if not _low_zoom_lod_enabled():
		_draw_emissive_bloom(canvas, area, daylight)


func _draw_directional_sunlight(canvas: CanvasItem, area: Rect2i) -> void:
	if sim.active_location_biome_id() in sim.RESONANT_DEEP_BIOMES:
		return
	var daylight := sim.world_daylight_factor()
	var phase := sim.world_day_phase()
	if daylight <= 0.12 or phase > 0.59:
		return
	_ensure_lighting_cache(area)
	var daylight_map: Dictionary = _lighting_cache.get("daylight", {})
	var sun_u := clampf(phase / 0.575, 0.0, 1.0)
	var elevation := sin(sun_u * PI)
	var horizontal := cos(sun_u * PI)
	var horizon_warmth := pow(1.0 - elevation, 1.35)
	var light_color := Color("#e7f3ff").lerp(Color("#ffd064"), horizon_warmth)
	var hot_color := Color.WHITE.lerp(Color("#fff0a1"), horizon_warmth)
	var top_strength := daylight * lerpf(0.13, 0.34, elevation)
	var side_strength := daylight * (0.08 + absf(horizontal) * 0.38) * (0.72 + horizon_warmth * 0.28)
	var tile := float(BlockDefs.TILE)
	var core_edge := maxf(0.75, 1.25 / maxf(zoom, 1.0))
	var soft_edge := maxf(core_edge * 2.5, 2.0 / maxf(zoom, 1.0))
	var light_from_left := horizontal > 0.0
	var side_offset := Vector2i.LEFT if light_from_left else Vector2i.RIGHT
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var block: Dictionary = sim.get_block(x, y)
			if not block.get("solid", false):
				continue
			var origin := Vector2(x, y) * tile
			var top_exposure := _directional_sun_exposure(daylight_map, Vector2i(x, y - 1), daylight)
			if top_exposure > 0.0 and not sim.get_block(x, y - 1).get("solid", false):
				var exposed_top_strength := top_strength * top_exposure
				canvas.draw_rect(Rect2(origin, Vector2(tile, soft_edge)), Color(light_color, exposed_top_strength * 0.34))
				canvas.draw_rect(Rect2(origin, Vector2(tile, core_edge)), Color(hot_color, exposed_top_strength))
				_draw_surface_sparkle(canvas, block, x, y, origin, tile, core_edge, hot_color, exposed_top_strength, elevation)
			var side_pos := Vector2i(x + side_offset.x, y)
			var side_exposure := _directional_sun_exposure(daylight_map, side_pos, daylight)
			if side_exposure > 0.0 and not sim.get_block(side_pos.x, side_pos.y).get("solid", false):
				var soft_x := origin.x if light_from_left else origin.x + tile - soft_edge
				var core_x := origin.x if light_from_left else origin.x + tile - core_edge
				var exposed_side_strength := side_strength * side_exposure
				canvas.draw_rect(Rect2(soft_x, origin.y, soft_edge, tile), Color(light_color, exposed_side_strength * 0.32))
				canvas.draw_rect(Rect2(core_x, origin.y, core_edge, tile), Color(hot_color, exposed_side_strength))


func _directional_sun_exposure(daylight_map: Dictionary, pos: Vector2i, outdoor_daylight: float) -> float:
	if outdoor_daylight <= 0.0:
		return 0.0
	var relative_light := float(daylight_map.get(pos, 0.0)) / outdoor_daylight
	return smoothstep(0.55, 0.9, clampf(relative_light, 0.0, 1.0))


func _draw_surface_sparkle(canvas: CanvasItem, block: Dictionary, tx: int, ty: int, origin: Vector2, tile: float, edge: float, color: Color, strength: float, elevation: float) -> void:
	var name := str(block.get("name", ""))
	if name not in ["sand", "glass", "ice", "obsidian"] or BlockDefs.hash2(tx + 173, ty + 251) < 0.76:
		return
	var sweep := fposmod(sim.world_day_phase() * 7.0 + BlockDefs.hash2(tx + 29, ty + 47), 1.0)
	if sweep > 0.24:
		return
	var center_x := origin.x + tile * (0.18 + BlockDefs.hash2(tx + 61, ty + 83) * 0.64)
	var center := Vector2(center_x, origin.y + edge * 0.5)
	var sparkle_alpha := strength * (0.55 + elevation * 0.35) * (1.0 - sweep / 0.24)
	var arm := maxf(1.5, 3.0 / maxf(zoom, 1.0))
	canvas.draw_line(center - Vector2(arm, 0.0), center + Vector2(arm, 0.0), Color(color, sparkle_alpha), edge)
	canvas.draw_line(center - Vector2(0.0, arm * 0.65), center + Vector2(0.0, arm * 0.65), Color(color, sparkle_alpha * 0.82), edge)


func _draw_emissive_bloom(canvas: CanvasItem, area: Rect2i, daylight: Dictionary) -> void:
	var tile := float(BlockDefs.TILE)
	var radius := 46.0 / maxf(zoom, 1.0)
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var block: Dictionary = sim.get_block(x, y)
			var emission := sim.block_light_emission(block)
			if emission <= 0.05:
				continue
			if block.get("fluid", false):
				var above: Dictionary = sim.get_block(x, y - 1)
				if above.get("id", 0) == block.get("id", -1) or posmod(x + y, 2) != 0:
					continue
			var day_level := float(daylight.get(Vector2i(x, y), 0.0))
			var darkness := pow(1.0 - clampf(day_level, 0.0, 1.0), 1.15)
			var strength := emission * (0.018 + darkness * 0.11)
			var center := (Vector2(x, y) + Vector2(0.5, 0.5)) * tile
			var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
			var lighting: Dictionary = definition.get("lighting", {}) if definition.get("lighting", {}) is Dictionary else {}
			var fallback_color := "#ff7a27" if block.get("name", "") == "lava" else "#ffd067"
			var glow_color := Color(str(lighting.get("color", fallback_color)))
			for ring in range(6, 0, -1):
				var ring_t := float(ring) / 6.0
				var ring_radius := radius * ring_t
				var ring_alpha := strength * (1.0 - ring_t * 0.72) * 0.34
				canvas.draw_circle(center, ring_radius, Color(glow_color, ring_alpha))
			canvas.draw_circle(center, radius * 0.18, Color(glow_color.lightened(0.28), strength * 0.22))


func _color_over(bottom: Color, top: Color) -> Color:
	var alpha := top.a + bottom.a * (1.0 - top.a)
	if alpha <= 0.0001:
		return Color.TRANSPARENT
	var rgb := (
		Vector3(top.r, top.g, top.b) * top.a
		+ Vector3(bottom.r, bottom.g, bottom.b) * bottom.a * (1.0 - top.a)
	) / alpha
	return Color(rgb.x, rgb.y, rgb.z, alpha)


func _draw_world(canvas: CanvasItem, area: Rect2i) -> void:
	if _low_zoom_lod_enabled():
		_draw_world_lod(canvas, area)
		return
	for y in range(area.position.y, area.position.y + area.size.y):
		for x in range(area.position.x, area.position.x + area.size.x):
			var block := sim.get_block(x, y)
			# Shagot scaffold is intentionally walk-through, but it is still a visible
			# construction block. Filtering the world layer by solidity made completed
			# Shagot buildings invisible while their lighting shadows remained.
			if block.get("solid", false) or str(block.get("name", "")) == "shagot_scaffold":
				_draw_block(canvas, x, y, block)


func _low_zoom_lod_enabled() -> bool:
	return desktop_web_rendering and zoom <= LOW_ZOOM_LOD_THRESHOLD and _low_zoom_lod_active


func _update_low_zoom_lod(delta: float) -> void:
	if not is_equal_approx(_low_zoom_last_zoom, zoom):
		_low_zoom_last_zoom = zoom
		_low_zoom_lod_active = false
		_low_zoom_slow_seconds = 0.0
		_low_zoom_grace_seconds = LOW_ZOOM_LOD_GRACE_SECONDS
		_world_render_dirty = true
		_lighting_dirty = true
		if is_instance_valid(_world_layer):
			_world_layer.queue_redraw()
		if is_instance_valid(_lighting_layer):
			_lighting_layer.queue_redraw()
	if not desktop_web_rendering or zoom > LOW_ZOOM_LOD_THRESHOLD:
		if _low_zoom_lod_active:
			_low_zoom_lod_active = false
			_world_render_dirty = true
			_lighting_dirty = true
			if is_instance_valid(_world_layer):
				_world_layer.queue_redraw()
			if is_instance_valid(_lighting_layer):
				_lighting_layer.queue_redraw()
		_low_zoom_slow_seconds = 0.0
		return
	if _low_zoom_lod_active:
		return
	if _low_zoom_grace_seconds > 0.0:
		_low_zoom_grace_seconds = maxf(0.0, _low_zoom_grace_seconds - delta)
		return
	var reported_fps := float(Engine.get_frames_per_second())
	if reported_fps > 0.0 and reported_fps < LOW_ZOOM_LOD_TRIGGER_FPS:
		_low_zoom_slow_seconds += delta
	else:
		_low_zoom_slow_seconds = maxf(0.0, _low_zoom_slow_seconds - delta * 2.0)
	if _low_zoom_slow_seconds < LOW_ZOOM_LOD_TRIGGER_SECONDS:
		return
	_low_zoom_lod_active = true
	_world_render_dirty = true
	_lighting_dirty = true
	if is_instance_valid(_world_layer):
		_world_layer.queue_redraw()
	if is_instance_valid(_lighting_layer):
		_lighting_layer.queue_redraw()


func _draw_world_lod(canvas: CanvasItem, area: Rect2i) -> void:
	if area.size.x <= 0 or area.size.y <= 0:
		return
	var pixels := LOW_ZOOM_TILE_PIXELS
	var image := Image.create(area.size.x * pixels, area.size.y * pixels, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var block: Dictionary = sim.get_block(x, y)
			if not block.get("solid", false) and str(block.get("name", "")) != "shagot_scaffold":
				continue
			var local := Vector2i((x - area.position.x) * pixels, (y - area.position.y) * pixels)
			var rect := Rect2i(local, Vector2i.ONE * pixels)
			if sim.is_one_use_cache_at(x, y):
				var body_top := maxi(2, int(round(float(pixels) * 0.22)))
				image.fill_rect(Rect2i(local + Vector2i(0, body_top), Vector2i(pixels, pixels - body_top)), Color("#79502d"))
				image.fill_rect(Rect2i(local + Vector2i(0, body_top), Vector2i(pixels, maxi(1, pixels / 6))), Color("#a8753f"))
				image.fill_rect(Rect2i(local + Vector2i(0, pixels - 2), Vector2i(pixels, 2)), Color("#3a2618"))
				image.fill_rect(Rect2i(local + Vector2i(maxi(1, pixels / 5), pixels / 2), Vector2i(maxi(2, pixels / 3), 1)), Color("#2a1b12"))
				continue
			if sim.is_death_cache_at(x, y):
				var body_top := maxi(2, int(round(float(pixels) * 0.22)))
				image.fill_rect(Rect2i(local + Vector2i(0, body_top), Vector2i(pixels, pixels - body_top)), Color("#315b6c"))
				image.fill_rect(Rect2i(local + Vector2i(0, body_top), Vector2i(pixels, maxi(1, pixels / 6))), Color("#83d5e5"))
				image.fill_rect(Rect2i(local + Vector2i(0, pixels - 2), Vector2i(pixels, 2)), Color("#142f3b"))
				var lock_size := maxi(2, pixels / 5)
				image.fill_rect(Rect2i(local + Vector2i((pixels - lock_size) / 2, pixels / 2 - lock_size / 2), Vector2i.ONE * lock_size), Color("#9cecff"))
				continue
			var base := BlockDefs.preview_color(block)
			var mid := Color.from_string(str(block.get("mid", base.to_html())), base)
			var dark_fallback := base.darkened(0.18)
			var light_fallback := base.lightened(0.16)
			var dark := Color.from_string(str(block.get("dark", dark_fallback.to_html())), dark_fallback)
			var light := Color.from_string(str(block.get("light", light_fallback.to_html())), light_fallback)
			if str(block.get("name", "")) == "grass":
				var dirt: Dictionary = BlockDefs.BLOCKS.dirt
				image.fill_rect(rect, Color(str(dirt.get("mid", "#83502c"))))
				image.fill_rect(Rect2i(local, Vector2i(pixels, 2)), Color(str(block.get("top", "#89b331"))))
				image.fill_rect(Rect2i(local + Vector2i(0, 2), Vector2i(pixels, 1)), dark)
			else:
				image.fill_rect(rect, mid)
				if not sim.get_block(x, y - 1).get("solid", false):
					image.fill_rect(Rect2i(local, Vector2i(pixels, 1)), light)
				image.fill_rect(Rect2i(local + Vector2i(0, pixels - 1), Vector2i(pixels, 1)), dark)
			# At 0.5x one cached texel maps to one screen pixel. Keep enough of the
			# procedural grain to avoid the flat, visibly lower-detail 8px fallback.
			for detail_index in 10:
				var detail_x := 1 + int(BlockDefs.hash2(x * 17 + detail_index * 11, y * 29 + 7) * float(pixels - 2))
				var detail_y := 2 + int(BlockDefs.hash2(x * 31 + 11, y * 13 + detail_index * 17) * float(pixels - 3))
				var detail_color := light if detail_index % 4 == 0 else (dark if detail_index % 3 == 0 else base)
				image.set_pixel(local.x + detail_x, mini(local.y + detail_y, local.y + pixels - 2), detail_color)
	_world_lod_texture = ImageTexture.create_from_image(image)
	canvas.draw_texture_rect(
		_world_lod_texture,
		Rect2(Vector2(area.position * BlockDefs.TILE), Vector2(area.size * BlockDefs.TILE)),
		false,
	)


func _draw_fluids() -> void:
	var area := _visible_tile_range()
	for raw_id in sim.block_id_counts.keys():
		var id := int(raw_id)
		var block := BlockDefs.get_block_by_id(id)
		if not block.get("fluid", false):
			continue
		for pos: Vector2i in sim._active_positions_for_block_id(id):
			if area.has_point(pos):
				_draw_block(self, pos.x, pos.y, block)


func _draw_plants() -> void:
	var area := _visible_tile_range()
	for anchor: Vector2i in sim.plant_growth.keys():
		var data: Dictionary = sim.plant_growth[anchor]
		var block: Dictionary = BlockDefs.BLOCKS.get(str(data.get("block_name", "")), {})
		var cells: Array = data.get("cells", [])
		for index in cells.size():
			var pos: Vector2i = cells[index]
			# Roots exist in the simulation but remain hidden by intact soil/stone.
			if index > 0 and sim.get_block(pos.x, pos.y).get("solid", false):
				continue
			if area.has_point(pos):
				var connection_mask := BlockDefs.plant_connection_mask(cells, pos)
				var traits: Dictionary = (data.get("traits", {}) as Dictionary).duplicate(true) if data.get("traits", {}) is Dictionary else {}
				var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
				var growth: Dictionary = definition.get("growth", {}) if definition.get("growth", {}) is Dictionary else {}
				if str(growth.get("form", "")) == "surface_creeper":
					traits["surface_anchor"] = _plant_surface_anchor(pos)
				BlockDefs.draw_plant_cell(self, Rect2(Vector2(pos * BlockDefs.TILE), Vector2.ONE * BlockDefs.TILE), block, int(data.get("stage", 1)), index, connection_mask, true, traits)


func _plant_surface_anchor(pos: Vector2i) -> String:
	for candidate: Dictionary in [
		{"name": "left", "offset": Vector2i.LEFT},
		{"name": "right", "offset": Vector2i.RIGHT},
		{"name": "ceiling", "offset": Vector2i.UP},
		{"name": "floor", "offset": Vector2i.DOWN},
	]:
		var offset: Vector2i = candidate["offset"]
		if sim.get_block(pos.x + offset.x, pos.y + offset.y).get("solid", false):
			return str(candidate["name"])
	return "left"


func _draw_creatures() -> void:
	var area := _visible_tile_range()
	for raw_creature_id in sim.creatures:
		var creature_id := str(raw_creature_id)
		var creature: Dictionary = sim.creatures[raw_creature_id]
		var pos := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
		if not area.has_point(Vector2i(floori(pos.x), floori(pos.y))):
			continue
		var block: Dictionary = BlockDefs.BLOCKS.get(str(creature.get("block_name", "")), {})
		var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
		var dest := _creature_draw_rect(creature, definition)
		var traits: Dictionary = creature.get("traits", {}) if creature.get("traits", {}) is Dictionary else {}
		var hybrid_morphology: Dictionary = traits.get("morphology", {}) if traits.get("morphology", {}) is Dictionary else {}
		BlockDefs.draw_creature(self, dest, definition, int(creature.get("facing", 1)), creature.get("palette", []), hybrid_morphology, str(traits.get("color_pattern", "")))
		_draw_shagot_cargo(creature, definition, dest)
		_draw_shagot_work_action(creature, definition, dest)
		_draw_hit_flash(self, dest.grow(1.0), int(_creature_hit_flash_expires_msec.get(creature_id, 0)))
		var breeding: Dictionary = definition.get("breeding", {})
		if int(creature.get("active_nearby_ticks", 0)) >= int(breeding.get("active_nearby_seconds", 1800)) * 60 and int(creature.get("breeding_cooldown", 0)) == 0:
			draw_string(ThemeDB.fallback_font, dest.position + Vector2(dest.size.x * 0.5 - 5, -3), "♥", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#ff78a8"))


func _draw_shagot_work_action(creature: Dictionary, definition: Dictionary, dest: Rect2) -> void:
	if (
		int(creature.get("work_action_ticks", 0)) <= 0
		or "shagot" not in (definition.get("tags", []) as Array)
		or not creature.has("work_target_x")
		or not creature.has("work_target_y")
	):
		return
	var target := Vector2i(int(creature.get("work_target_x", 0)), int(creature.get("work_target_y", 0)))
	var action := str(creature.get("work_action", ""))
	if action == "mining" and sim._shagot_resource_kind(target).is_empty():
		return
	if action == "building" and str(sim.get_block(target.x, target.y).get("name", "")) != "shagot_scaffold":
		return
	var target_center := Vector2(
		(float(target.x) + 0.5) * BlockDefs.TILE,
		(float(target.y) + 0.5) * BlockDefs.TILE,
	)
	var direction_vector := (target_center - dest.get_center()).normalized()
	if direction_vector.length() < 0.1:
		direction_vector = Vector2(float(creature.get("facing", 1)), 0.0)
	var direction := 1.0 if direction_vector.x >= 0.0 else -1.0
	var action_ticks := int(creature.get("work_action_ticks", 0))
	var progress := 1.0 - float(action_ticks) / float(WorldSim.SHAGOT_WORK_ACTION_TICKS)
	var strike := sin(progress * PI * 4.0) * 0.38
	var hand := dest.get_center() + Vector2(direction * dest.size.x * 0.32, dest.size.y * 0.04)
	var tool_direction := direction_vector.rotated(strike * direction)
	var handle_end := hand + tool_direction * 14.0
	draw_line(hand, handle_end, Color("#6d4930"), 2.5, false)
	if action == "mining":
		var head_axis := tool_direction.orthogonal() * 5.5
		draw_line(handle_end - head_axis, handle_end + head_axis, Color("#8ff3d5"), 3.5, false)
	else:
		draw_rect(Rect2(handle_end - Vector2(4.0, 3.0), Vector2(8.0, 6.0)), Color("#8ff3d5"))
	# Impact sparks exist only during the final strike. Keeping them visible for
	# the whole action made unfinished blueprint cells look like random airborne
	# dots, especially while a worker was walking below a future roof segment.
	if action_ticks <= 6:
		var impact_alpha := 1.0 - float(action_ticks - 1) / 6.0
		for spark_index in 3:
			var spark_phase := progress * 8.0 + float(spark_index) * 1.7
			var spark_offset := Vector2(cos(spark_phase), sin(spark_phase)) * (3.0 + float(spark_index) * 1.5)
			draw_circle(target_center + spark_offset, 1.4, Color("#cafff3", 0.85 * impact_alpha))


func _draw_shagot_cargo(creature: Dictionary, definition: Dictionary, dest: Rect2) -> void:
	if int(creature.get("carried_materials", 0)) <= 0 or "shagot" not in (definition.get("tags", []) as Array):
		return
	var direction := 1.0 if int(creature.get("facing", 1)) >= 0 else -1.0
	var bob := sin(float(anim_frame) * 0.08 + float(str(creature.get("id", "")).hash())) * 1.2
	var cargo_center := dest.get_center() + Vector2(-direction * dest.size.x * 0.42, -dest.size.y * 0.16 + bob)
	draw_rect(Rect2(cargo_center - Vector2(4.5, 4.5), Vector2(9.0, 9.0)), Color("#496474"))
	draw_line(cargo_center - Vector2(3.0, 2.0), cargo_center + Vector2(3.0, 2.0), Color("#8ff3d5"), 1.5)


func _creature_draw_rect(creature: Dictionary, definition: Dictionary) -> Rect2:
	var pos := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var size := clampf(float((definition.get("stats", {}) as Dictionary).get("size", 0.8)), 0.45, 1.4)
	var pixel_size := Vector2.ONE * BlockDefs.TILE * size
	var origin := pos * BlockDefs.TILE - pixel_size * 0.5
	var locomotion: Dictionary = definition.get("locomotion", {}) if definition.get("locomotion", {}) is Dictionary else {}
	if str(locomotion.get("type", "walking")) == "stationary":
		# Rooted plant-creatures occupy an air cell, but visually grow from the
		# supporting block. Align their feet/roots with that cell's lower edge
		# instead of leaving a size-dependent gap around its center.
		origin.y = (floorf(pos.y) + 1.0) * BlockDefs.TILE - pixel_size.y
	return Rect2(origin, pixel_size)


func _draw_fire() -> void:
	var area := _visible_tile_range()
	for raw_pos in sim.burning_tiles.keys():
		var pos := raw_pos as Vector2i
		if not area.has_point(pos):
			continue
		var origin := Vector2(float(pos.x * BlockDefs.TILE), float(pos.y * BlockDefs.TILE))
		var sway := sin(float(anim_frame) * 0.22 + float(pos.x * 3 + pos.y)) * 2.0
		var flame_base := origin + Vector2(16.0, 29.0)
		draw_colored_polygon(PackedVector2Array([
			flame_base + Vector2(-11.0, 0.0),
			flame_base + Vector2(-7.0 + sway, -18.0),
			flame_base + Vector2(-1.0, -10.0),
			flame_base + Vector2(3.0 + sway, -29.0),
			flame_base + Vector2(9.0, -12.0),
			flame_base + Vector2(11.0, 0.0),
		]), Color(1.0, 0.24, 0.02, 0.88))
		draw_colored_polygon(PackedVector2Array([
			flame_base + Vector2(-6.0, 0.0),
			flame_base + Vector2(-2.0 + sway * 0.5, -14.0),
			flame_base + Vector2(2.0, -7.0),
			flame_base + Vector2(6.0, 0.0),
		]), Color(1.0, 0.82, 0.12, 0.95))
func _draw_player() -> void:
	var px: float = sim.player["x"]
	var py: float = sim.player["y"]
	var facing: int = sim.player["facing"]
	var squash: float = float(sim.player.get("squash", 0.0))
	var scale_y: float = 1.0 - squash * 0.12
	var body_h: float = sim.player["h"] * scale_y
	var foot_y: float = py + sim.player["h"]
	var y: float = foot_y - body_h
	draw_rect(Rect2(px + 1, py + sim.player["h"] - 3, 18, 5), Color(0, 0, 0, 0.16))
	var shirt := PlayerProfile.color("shirt")
	var shirt_dark := PlayerProfile.color("shirt_dark")
	var accent := PlayerProfile.color("accent")
	var pants := PlayerProfile.color("pants")
	var skin_color := PlayerProfile.color("skin")
	var hair := PlayerProfile.color("hair")
	draw_rect(Rect2(px + 2, y + 18.0 * scale_y, 16, 10.0 * scale_y), pants)
	draw_rect(Rect2(px + 3, y + 10.0 * scale_y, 14, 10.0 * scale_y), shirt)
	draw_rect(Rect2(px + 2, y + 9.0 * scale_y, 16, 2.0 * scale_y), accent)
	draw_rect(Rect2(px + 4, y + 13.0 * scale_y, 10, 2.0 * scale_y), shirt_dark)
	draw_rect(Rect2(px + 7, y + 13.0 * scale_y, 3, 2.0 * scale_y), accent)
	draw_rect(Rect2(px + 5, y + 2.0 * scale_y, 10, 10.0 * scale_y), skin_color)
	draw_rect(Rect2(px + 4, y, 12, 4.0 * scale_y), hair)
	var eye_x: float = px + (10.0 if facing > 0 else 6.0)
	draw_rect(Rect2(eye_x, y + 5.0 * scale_y, 2, 2), Color("#1a1a1a"))
	draw_rect(Rect2(px + 1, y + 12.0 * scale_y, 4, 8.0 * scale_y), shirt_dark)
	draw_rect(Rect2(px + 15, y + 12.0 * scale_y, 4, 8.0 * scale_y), shirt_dark)
	_draw_selected_equipment(px, y, scale_y, facing)
	_draw_hit_flash(self, Rect2(px, y, 20.0, body_h), _local_hit_flash_expires_msec)
	if _health_indicator_time_left > 0.0:
		var indicator_alpha := clampf(_health_indicator_time_left / HEALTH_INDICATOR_FADE_SECONDS, 0.0, 1.0)
		var indicator_x := health_indicator_left(px)
		for heart in WorldSim.MAX_PLAYER_HEALTH:
			var color := Color("#ef4b5a") if heart < int(sim.player.get("health", WorldSim.MAX_PLAYER_HEALTH)) else Color(0.2, 0.2, 0.24, 0.55)
			color.a *= indicator_alpha
			draw_rect(Rect2(indicator_x + heart * (HEALTH_INDICATOR_PIP_SIZE + HEALTH_INDICATOR_PIP_GAP), y - 7, HEALTH_INDICATOR_PIP_SIZE, HEALTH_INDICATOR_PIP_SIZE), color)
	_draw_remote_players()


func _draw_remote_players() -> void:
	for raw_player_id in remote_players:
		var player_id := str(raw_player_id)
		var remote: Dictionary = remote_players[player_id]
		var render_position := _remote_player_render_position(player_id, remote)
		var px := render_position.x
		var py := render_position.y
		var facing := int(remote.get("facing", 1))
		var hue := fposmod(float(player_id.hash()) / 997.0, 1.0)
		var fallback_shirt := Color.from_hsv(hue, 0.58, 0.82)
		var shirt := _remote_skin_color(remote, "shirt", fallback_shirt)
		var dark := _remote_skin_color(remote, "shirt_dark", shirt.darkened(0.28))
		var accent := _remote_skin_color(remote, "accent", shirt.lightened(0.28))
		var pants := _remote_skin_color(remote, "pants", dark.darkened(0.24))
		var skin_color := _remote_skin_color(remote, "skin", PlayerProfile.color("skin"))
		var hair := _remote_skin_color(remote, "hair", PlayerProfile.color("hair"))
		draw_rect(Rect2(px + 1, py + 25, 18, 5), Color(0, 0, 0, 0.16))
		draw_rect(Rect2(px + 2, py + 18, 16, 10), pants)
		draw_rect(Rect2(px + 3, py + 10, 14, 10), shirt)
		draw_rect(Rect2(px + 2, py + 9, 16, 2), accent)
		draw_rect(Rect2(px + 4, py + 13, 10, 2), dark)
		draw_rect(Rect2(px + 7, py + 13, 3, 2), accent)
		draw_rect(Rect2(px + 5, py + 2, 10, 10), skin_color)
		draw_rect(Rect2(px + 4, py, 12, 4), hair)
		var eye_x := px + (10.0 if facing > 0 else 6.0)
		draw_rect(Rect2(eye_x, py + 5, 2, 2), Color("#1a1a1a"))
		draw_rect(Rect2(px + 1, py + 12, 4, 8), dark)
		draw_rect(Rect2(px + 15, py + 12, 4, 8), dark)
		_draw_equipment(
			px,
			py,
			1.0,
			facing,
			remote.get("equipment_slots", {}) if remote.get("equipment_slots", {}) is Dictionary else {},
		)
		_draw_hit_flash(self, Rect2(px, py, 20.0, 28.0), int(_remote_player_hit_flash_expires_msec.get(player_id, 0)))
		var indicator_x := health_indicator_left(px)
		for heart in WorldSim.MAX_PLAYER_HEALTH:
			var color := Color("#ef4b5a") if heart < int(remote.get("health", WorldSim.MAX_PLAYER_HEALTH)) else Color(0.2, 0.2, 0.24, 0.55)
			draw_rect(Rect2(indicator_x + heart * (HEALTH_INDICATOR_PIP_SIZE + HEALTH_INDICATOR_PIP_GAP), py - 7, HEALTH_INDICATOR_PIP_SIZE, HEALTH_INDICATOR_PIP_SIZE), color)


static func health_indicator_left(player_x: float) -> float:
	var indicator_width := (
		WorldSim.MAX_PLAYER_HEALTH * HEALTH_INDICATOR_PIP_SIZE
		+ (WorldSim.MAX_PLAYER_HEALTH - 1) * HEALTH_INDICATOR_PIP_GAP
	)
	return player_x + (PLAYER_RENDER_WIDTH - indicator_width) * 0.5


func show_emoji_reaction(player_id: String, emoji: String, local_player_id: String) -> void:
	var reaction := {
		"emoji": emoji,
		"expires_msec": Time.get_ticks_msec() + int(EMOJI_BUBBLE_SECONDS * 1000.0),
	}
	if player_id == local_player_id:
		local_emoji_reaction = reaction
	else:
		remote_emoji_reactions[player_id] = reaction
	_reaction_layer.queue_redraw()


func clear_emoji_reactions() -> void:
	local_emoji_reaction.clear()
	remote_emoji_reactions.clear()
	if is_instance_valid(_reaction_layer):
		_reaction_layer.queue_redraw()


func _draw_reaction_layer() -> void:
	var draw_cam := _render_camera_pos()
	_reaction_layer.draw_set_transform(-draw_cam, 0.0, Vector2(zoom, zoom))
	_draw_tideglass_reveal_glow(_reaction_layer)
	_draw_emoji_bubble(
		_reaction_layer,
		Vector2(float(sim.player.get("x", 0.0)) + 10.0, float(sim.player.get("y", 0.0)) - 18.0),
		local_emoji_reaction,
	)
	for raw_player_id in remote_players:
		var player_id := str(raw_player_id)
		var remote: Dictionary = remote_players[player_id]
		var render_position := _remote_player_render_position(player_id, remote)
		_draw_emoji_bubble(
			_reaction_layer,
			render_position + Vector2(10.0, -18.0),
			remote_emoji_reactions.get(player_id, {}),
		)


func _draw_tideglass_reveal_glow(canvas: Node2D) -> void:
	var now := Time.get_ticks_msec()
	var expired: Array[Vector2i] = []
	for raw_pos in _tideglass_reveal_glow:
		var pos := raw_pos as Vector2i
		var expires := int(_tideglass_reveal_glow[pos])
		if expires <= now:
			expired.append(pos)
			continue
		var strength := clampf(float(expires - now) / float(TIDEGLASS_REVEAL_GLOW_MSEC), 0.0, 1.0)
		var center := Vector2(float(pos.x * BlockDefs.TILE) + float(BlockDefs.TILE) * 0.5, float(pos.y * BlockDefs.TILE) + float(BlockDefs.TILE) * 0.5)
		var pulse := 1.0 + sin(float(now) * 0.025) * 0.08
		canvas.draw_circle(center, float(BlockDefs.TILE) * 0.82 * pulse, Color(0.54, 1.0, 0.96, strength * 0.22))
		canvas.draw_arc(center, float(BlockDefs.TILE) * 0.57 * pulse, 0.0, TAU, 20, Color(0.82, 1.0, 0.98, strength * 0.78), 2.2)
		for angle_index in 4:
			var angle := float(angle_index) * PI * 0.5 + float(now % 700) / 700.0
			var sparkle := center + Vector2(cos(angle), sin(angle)) * float(BlockDefs.TILE) * 0.68
			canvas.draw_circle(sparkle, 1.8 + strength * 1.8, Color(0.9, 1.0, 1.0, strength * 0.9))
	for pos: Vector2i in expired:
		_tideglass_reveal_glow.erase(pos)


func _draw_emoji_bubble(canvas: Node2D, anchor: Vector2, reaction: Variant) -> void:
	if not reaction is Dictionary:
		return
	var data := reaction as Dictionary
	if Time.get_ticks_msec() >= int(data.get("expires_msec", 0)):
		return
	var emoji := str(data.get("emoji", ""))
	if emoji.is_empty():
		return
	var texture := EmojiReactionsClass.texture_for(emoji)
	if texture == null:
		return
	var bubble_size := Vector2(32.0, 32.0)
	var rect := Rect2(anchor - Vector2(bubble_size.x * 0.5, bubble_size.y), bubble_size)
	canvas.draw_circle(rect.position + Vector2(bubble_size.x * 0.5, bubble_size.y), 4.0, Color(1, 1, 1, 0.96))
	canvas.draw_style_box(_emoji_bubble_style(), rect)
	canvas.draw_texture_rect(texture, rect.grow(-4.0), false)


func _emoji_bubble_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.13, 0.94)
	style.border_color = Color(1.0, 1.0, 1.0, 0.82)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	return style


func _remote_skin_color(remote: Dictionary, key: String, fallback: Color) -> Color:
	var skin: Dictionary = remote.get("skin", {}) if remote.get("skin", {}) is Dictionary else {}
	var value := str(skin.get(key, ""))
	return Color.from_string(value, fallback) if Color.html_is_valid(value) else fallback


func _draw_remote_player_indicators() -> void:
	var view := _view_size()
	var center := view * 0.5
	var visible_rect := Rect2(Vector2.ZERO, view)
	var draw_cam := _render_camera_pos()
	for raw_player_id in remote_players:
		var player_id := str(raw_player_id)
		var remote: Dictionary = remote_players[player_id]
		var world_center := _remote_player_render_position(player_id, remote) + Vector2(10.0, 14.0)
		var screen_position := world_center * zoom - draw_cam
		if visible_rect.has_point(screen_position):
			continue
		var direction := (screen_position - center).normalized()
		if direction.is_zero_approx():
			continue
		var position := edge_indicator_position(screen_position, view, REMOTE_PLAYER_INDICATOR_MARGIN)
		var tangent := Vector2(-direction.y, direction.x)
		var fallback := Color.from_hsv(fposmod(float(player_id.hash()) / 997.0, 1.0), 0.58, 0.82)
		var color := _remote_skin_color(remote, "shirt", fallback)
		var points := PackedVector2Array([
			position + direction * 10.0,
			position - direction * 7.0 + tangent * 7.0,
			position - direction * 7.0 - tangent * 7.0,
		])
		var shadow := PackedVector2Array()
		for point in points:
			shadow.append(point + Vector2(2.0, 2.0))
		draw_colored_polygon(shadow, Color(0.0, 0.0, 0.0, 0.52))
		draw_colored_polygon(points, color)
		draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[0]]), color.lightened(0.28), 1.5, true)


static func edge_indicator_position(target: Vector2, view_size: Vector2, margin: float = REMOTE_PLAYER_INDICATOR_MARGIN) -> Vector2:
	var center := view_size * 0.5
	var delta := target - center
	if delta.is_zero_approx():
		return center
	var half := Vector2(maxf(1.0, center.x - margin), maxf(1.0, center.y - margin))
	var scale_x := half.x / absf(delta.x) if not is_zero_approx(delta.x) else INF
	var scale_y := half.y / absf(delta.y) if not is_zero_approx(delta.y) else INF
	return center + delta * minf(scale_x, scale_y)


func _update_remote_player_interpolation(delta: float) -> void:
	for raw_player_id in _remote_player_render_positions.keys():
		var existing_id := str(raw_player_id)
		if not remote_players.has(existing_id):
			_remote_player_render_positions.erase(existing_id)
			_remote_player_render_revisions.erase(existing_id)
	var blend := 1.0 - exp(-REMOTE_PLAYER_INTERPOLATION_SPEED * delta)
	for raw_player_id in remote_players:
		var player_id := str(raw_player_id)
		var remote: Dictionary = remote_players[player_id]
		var target := Vector2(float(remote.get("x", 0.0)), float(remote.get("y", 0.0)))
		var snapshot_age := clampf(
			float(Time.get_ticks_msec() - int(remote.get("_received_msec", Time.get_ticks_msec()))) / 1000.0,
			0.0,
			REMOTE_PLAYER_EXTRAPOLATION_SECONDS,
		)
		var simulation_steps := snapshot_age * 60.0
		target.x += float(remote.get("vx", 0.0)) * simulation_steps
		if not bool(remote.get("on_ground", false)):
			target.y += (
				float(remote.get("vy", 0.0)) * simulation_steps
				+ 0.5 * BlockDefs.GRAVITY * simulation_steps * simulation_steps
			)
		var revision := int(remote.get("respawn_revision", 0))
		var current: Vector2 = _remote_player_render_positions.get(player_id, target)
		var previous_revision := int(_remote_player_render_revisions.get(player_id, revision))
		if not _remote_player_render_positions.has(player_id) or revision != previous_revision or current.distance_to(target) >= REMOTE_PLAYER_TELEPORT_DISTANCE:
			current = target
		else:
			current = current.lerp(target, blend)
		_remote_player_render_positions[player_id] = current
		_remote_player_render_revisions[player_id] = revision


func _remote_player_render_position(player_id: String, remote: Dictionary) -> Vector2:
	return _remote_player_render_positions.get(
		player_id,
		Vector2(float(remote.get("x", 0.0)), float(remote.get("y", 0.0))),
	)


func _update_remote_creature_interpolation(delta: float) -> void:
	if not multiplayer_guest:
		remote_creature_targets.clear()
		return
	var blend := 1.0 - exp(-REMOTE_CREATURE_INTERPOLATION_SPEED * delta)
	for raw_creature_id in remote_creature_targets:
		var creature_id := str(raw_creature_id)
		if not sim.creatures.has(creature_id):
			continue
		var creature: Dictionary = sim.creatures[creature_id]
		var current := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
		var target: Vector2 = remote_creature_targets[creature_id]
		var next := target if current.distance_to(target) >= REMOTE_CREATURE_TELEPORT_DISTANCE else current.lerp(target, blend)
		creature["x"] = next.x
		creature["y"] = next.y


func _equipment_item_definition(slot_name: String) -> Dictionary:
	var block_name := sim.equipped_item_name(slot_name)
	return _equipment_item_definition_for_name(block_name, slot_name)


func _equipment_item_definition_for_name(block_name: String, slot_name: String) -> Dictionary:
	if block_name.is_empty() or not BlockDefs.BLOCKS.has(block_name):
		return {}
	var block: Dictionary = BlockDefs.BLOCKS[block_name]
	if not bool(block.get("item", false)):
		return {}
	var definition: Variant = block.get("definition", {})
	if not definition is Dictionary:
		return {}
	var category := str((definition as Dictionary).get("category", ""))
	var expected_slot := "feet" if category == "mobility_tool" else ("hand" if category in ["mining_tool", "weapon", "hybrid"] else "")
	return definition if expected_slot == slot_name else {}


func _selected_item_definition() -> Dictionary:
	var hand := _equipment_item_definition("hand")
	return hand if not hand.is_empty() else _equipment_item_definition("feet")


func _equipment_item_shape(slot_name: String) -> String:
	return _equipment_shape_from_definition(_equipment_item_definition(slot_name))


func _selected_item_shape() -> String:
	var hand_shape := _equipment_item_shape("hand")
	return hand_shape if not hand_shape.is_empty() else _equipment_item_shape("feet")


func _equipment_item_colors(slot_name: String) -> Array[Color]:
	return _equipment_colors_from_definition(_equipment_item_definition(slot_name))


func _draw_selected_equipment(px: float, y: float, scale_y: float, facing: int) -> void:
	_draw_equipment(px, y, scale_y, facing, {
		"hand": sim.equipped_item_name("hand"),
		"feet": sim.equipped_item_name("feet"),
	})


func _draw_equipment(px: float, y: float, scale_y: float, facing: int, equipment_slots: Dictionary) -> void:
	var feet_definition := _equipment_item_definition_for_name(str(equipment_slots.get("feet", "")), "feet")
	var feet_shape := _equipment_shape_from_definition(feet_definition)
	var feet_colors := _equipment_colors_from_definition(feet_definition)
	if feet_shape == "boots":
		# Keep the footwear attached to both feet while the body squashes on landing.
		var boot_y := y + 23.0 * scale_y
		draw_rect(Rect2(px + 2, boot_y, 7, 5.0 * scale_y), feet_colors[0])
		draw_rect(Rect2(px + 11, boot_y, 7, 5.0 * scale_y), feet_colors[0])
		draw_rect(Rect2(px + 1, boot_y + 3.0 * scale_y, 9, 2.0 * scale_y), feet_colors[1])
		draw_rect(Rect2(px + 10, boot_y + 3.0 * scale_y, 9, 2.0 * scale_y), feet_colors[1])
		draw_rect(Rect2(px + 4, boot_y + scale_y, 2, 2.0 * scale_y), feet_colors[2])
		draw_rect(Rect2(px + 13, boot_y + scale_y, 2, 2.0 * scale_y), feet_colors[2])
	var hand_definition := _equipment_item_definition_for_name(str(equipment_slots.get("hand", "")), "hand")
	var hand_shape := _equipment_shape_from_definition(hand_definition)
	if hand_shape not in ["pickaxe", "hammer", "blade", "bow"]:
		return
	var hand_colors := _equipment_colors_from_definition(hand_definition)
	# The held tool mirrors around the character so it always stays in the front hand.
	var direction := 1.0 if facing >= 0 else -1.0
	var hand := Vector2(px + (18.0 if direction > 0.0 else 2.0), y + 18.0 * scale_y)
	if hand_shape == "bow":
		var bow_center := hand + Vector2(direction * 7.0, -4.0 * scale_y)
		var bow_top := bow_center + Vector2(-direction * 2.0, -11.0 * scale_y)
		var bow_front := bow_center + Vector2(direction * 5.0, 0.0)
		var bow_bottom := bow_center + Vector2(-direction * 2.0, 11.0 * scale_y)
		draw_polyline(PackedVector2Array([bow_top, bow_front, bow_bottom]), hand_colors[0], 3.0, false)
		draw_line(bow_top, bow_center, hand_colors[1], 1.5, false)
		draw_line(bow_center, bow_bottom, hand_colors[1], 1.5, false)
		draw_rect(Rect2(hand - Vector2.ONE, Vector2(3, 3)), hand_colors[2])
		return
	var handle_end := hand + Vector2(direction * 8.0, -14.0 * scale_y)
	draw_line(hand, handle_end, hand_colors[0], 3.0, false)
	var head_center := handle_end + Vector2(0.0, -1.0 * scale_y)
	if hand_shape == "blade":
		var blade_tip := head_center + Vector2(direction * 4.0, -7.0 * scale_y)
		draw_line(handle_end, blade_tip, hand_colors[1], 5.0, false)
		draw_line(blade_tip, blade_tip + Vector2(-direction * 2.0, 3.0 * scale_y), hand_colors[2], 2.0, false)
	elif hand_shape == "hammer":
		draw_rect(Rect2(head_center - Vector2(5.0, 3.0 * scale_y), Vector2(10.0, 6.0 * scale_y)), hand_colors[1])
	else:
		draw_line(
			head_center - Vector2(direction * 5.0, 2.0 * scale_y),
			head_center + Vector2(direction * 6.0, 2.0 * scale_y),
			hand_colors[1],
			4.0,
			false
		)
	draw_rect(Rect2(hand - Vector2.ONE, Vector2(3, 3)), hand_colors[2])


func _equipment_shape_from_definition(definition: Dictionary) -> String:
	var visual: Variant = definition.get("visual", {})
	return str((visual as Dictionary).get("shape", "")) if visual is Dictionary else ""


func _equipment_colors_from_definition(definition: Dictionary) -> Array[Color]:
	var fallback: Array[Color] = [Color("#5b4630"), Color("#d7b45a"), Color("#f0d98a")]
	var visual: Variant = definition.get("visual", {})
	if not visual is Dictionary:
		return fallback
	var palette: Variant = (visual as Dictionary).get("palette", [])
	if not palette is Array:
		return fallback
	var colors: Array[Color] = []
	for index in 3:
		var html := str((palette as Array)[index]) if index < (palette as Array).size() else ""
		colors.append(Color(html) if Color.html_is_valid(html) else fallback[index])
	return colors


func _draw_mining_cracks() -> void:
	if mining.is_empty():
		return
	var tx: int = mining["tx"]
	var ty: int = mining["ty"]
	var t := float(mining["progress"]) / float(mining["need"])
	var bx := tx * BlockDefs.TILE
	var by := ty * BlockDefs.TILE
	var crack_color := Color(0, 0, 0, 0.35 + t * 0.45)
	var count := maxi(1, int(ceil(t * 6.0)))
	for i in count:
		var ox := 4 + i * 4
		draw_line(Vector2(bx + ox, by + 6), Vector2(bx + 16, by + 20), crack_color, 2.0)
	draw_rect(Rect2(bx + 1, by + 1, BlockDefs.TILE - 2, maxi(2, int((BlockDefs.TILE - 2) * (1.0 - t)))), Color(1, 1, 1, 0.08 + t * 0.12))


func _player_is_moving() -> bool:
	return (
		_move_left_pressed()
		or _move_right_pressed()
		or virtual_left
		or virtual_right
	)


func _move_left_pressed() -> bool:
	if desktop_web_rendering:
		return not keyboard_mining_held and not keyboard_placing_held and (
			Input.is_physical_key_pressed(KEY_A)
			or Input.is_physical_key_pressed(KEY_LEFT)
		)
	return Input.is_action_pressed("move_left")


func _move_right_pressed() -> bool:
	if desktop_web_rendering:
		return not keyboard_mining_held and not keyboard_placing_held and (
			Input.is_physical_key_pressed(KEY_D)
			or Input.is_physical_key_pressed(KEY_RIGHT)
		)
	return Input.is_action_pressed("move_right")


func _jump_pressed() -> bool:
	if desktop_web_rendering:
		return not keyboard_mining_held and not keyboard_placing_held and (
			Input.is_physical_key_pressed(KEY_W)
			or Input.is_physical_key_pressed(KEY_UP)
			or Input.is_physical_key_pressed(KEY_SPACE)
		)
	return Input.is_action_pressed("jump")


func _draw_targeting(canvas: CanvasItem) -> void:
	if bow_drawing:
		var origin := Vector2(
			float(sim.player.get("x", 0.0)) + float(sim.player.get("w", 20.0)) * 0.5,
			float(sim.player.get("y", 0.0)) + float(sim.player.get("h", 28.0)) * 0.42,
		)
		var charge := bow_draw_progress()
		var finish := origin + bow_aim_direction * lerpf(58.0, 94.0, charge)
		var color := Color(1.0, 0.72 + charge * 0.24, 0.28, 0.55 + charge * 0.4)
		canvas.draw_dashed_line(origin, finish, color, 1.5, 6.0)
		canvas.draw_arc(finish, 5.0 + charge * 2.0, 0.0, TAU, 20, color, 2.0)
	if tutorial_highlight_tile != NO_TILE:
		var tutorial_alpha := 0.62 + sin(Time.get_ticks_msec() / 260.0) * 0.18
		_draw_tile_highlight(
			canvas,
			tutorial_highlight_tile.x,
			tutorial_highlight_tile.y,
			Color(1, 1, 1, tutorial_alpha)
		)
	if desktop_web_rendering and keyboard_mining_held and keyboard_mine_direction != Vector2i.ZERO:
		var keyboard_target := keyboard_mine_candidate()
		if keyboard_target != NO_TILE:
			_draw_tile_highlight(
				canvas,
				keyboard_target.x,
				keyboard_target.y,
				Color("#ff6666"),
			)
	if not pointer_active or _player_is_moving() or not pointer_armed:
		return

	var finger := _finger_tile()
	if not _tile_in_world(finger):
		return
	# A short tap on a combat target is an attack, not mining or placement.
	# Suppress the invalid-placement/mining frame while that tap is held.
	if tile_has_attack_target(finger):
		return

	if sim.can_place_block(finger.x, finger.y) and BlockDefs.BLOCKS.has(sim.selected):
		var px := finger.x * BlockDefs.TILE
		var py := finger.y * BlockDefs.TILE
		var ghost_block: Dictionary = BlockDefs.BLOCKS[sim.selected].duplicate()
		ghost_block["name"] = sim.selected
		BlockDefs.draw_block(
			canvas, finger.x, finger.y, ghost_block, Color(1, 1, 1, 0.58), anim_frame,
			0, false, true, Rect2(px, py, BlockDefs.TILE, BlockDefs.TILE), BlockDefs.BEVEL_ALL
		)
		_draw_dashed_rect(canvas, Rect2(px + 1, py + 1, BlockDefs.TILE - 2, BlockDefs.TILE - 2), Color.WHITE, 2.0)
		var center := Vector2(px + BlockDefs.TILE * 0.5, py + BlockDefs.TILE * 0.5)
		canvas.draw_line(center + Vector2(-5, 0), center + Vector2(5, 0), Color.WHITE, 2.0)
		canvas.draw_line(center + Vector2(0, -5), center + Vector2(0, 5), Color.WHITE, 2.0)
	elif not BlockDefs.BLOCKS.get(sim.selected, {}).get("item", false) and not sim.can_place_block(finger.x, finger.y):
		_draw_dashed_rect(canvas, Rect2(finger.x * BlockDefs.TILE + 1, finger.y * BlockDefs.TILE + 1, BlockDefs.TILE - 2, BlockDefs.TILE - 2), Color("#ff6666"), 2.0)

	if mining_active:
		var mine := _resolve_mine_tile()
		if mine != NO_TILE:
			_draw_tile_highlight(canvas, mine.x, mine.y, Color("#ff6666"))


func _draw_dashed_rect(canvas: CanvasItem, rect: Rect2, color: Color, width: float) -> void:
	var corners := [
		[rect.position, rect.position + Vector2(rect.size.x, 0)],
		[rect.position + Vector2(rect.size.x, 0), rect.position + rect.size],
		[rect.position + rect.size, rect.position + Vector2(0, rect.size.y)],
		[rect.position + Vector2(0, rect.size.y), rect.position],
	]
	for edge in corners:
		_draw_dashed_line(canvas, edge[0], edge[1], color, width)


func _draw_dashed_line(canvas: CanvasItem, from: Vector2, to: Vector2, color: Color, width: float) -> void:
	var delta := to - from
	var length := delta.length()
	if length < 1.0:
		return
	var dir := delta / length
	var step := 6.0
	var gap := 4.0
	var t := 0.0
	while t < length:
		var end_t := minf(t + step, length)
		canvas.draw_line(from + dir * t, from + dir * end_t, color, width)
		t += step + gap


func _draw_tile_highlight(canvas: CanvasItem, tx: int, ty: int, color: Color) -> void:
	var px := tx * BlockDefs.TILE - HIGHLIGHT_PAD
	var py := ty * BlockDefs.TILE - HIGHLIGHT_PAD
	var size := BlockDefs.TILE + HIGHLIGHT_PAD * 2.0
	canvas.draw_rect(Rect2(px, py, size, size), Color(color, 0.18))
	canvas.draw_rect(Rect2(px, py, size, size), color, false, HIGHLIGHT_WIDTH)


func set_tutorial_highlight(tile: Vector2i) -> void:
	tutorial_highlight_tile = tile
	if _targeting_layer != null:
		_targeting_layer.queue_redraw()


func tutorial_tile_viewport_rect(tile: Vector2i) -> Rect2:
	if tile == NO_TILE or _targeting_layer == null:
		return Rect2()
	var transform := _targeting_layer.get_global_transform_with_canvas()
	var start := transform * Vector2(tile.x * BlockDefs.TILE, tile.y * BlockDefs.TILE)
	var finish := transform * Vector2((tile.x + 1) * BlockDefs.TILE, (tile.y + 1) * BlockDefs.TILE)
	return Rect2(start, finish - start).abs()


func tutorial_mine_candidate() -> Vector2i:
	if sim.world_mode == WorldSim.WORLD_MODE_ONE_BLOCK and sim.player_near(sim.one_block_position.x, sim.one_block_position.y):
		return sim.one_block_position
	var recipe_inputs: Dictionary = {}
	for recipe: Dictionary in sim.get_all_recipes():
		for block_name: String in recipe.get("in", {}):
			recipe_inputs[block_name] = true
	var center := Vector2i(
		floori((float(sim.player.get("x", 0.0)) + float(sim.player.get("w", 20.0)) * 0.5) / BlockDefs.TILE),
		floori((float(sim.player.get("y", 0.0)) + float(sim.player.get("h", 30.0)) * 0.5) / BlockDefs.TILE)
	)
	var best := NO_TILE
	var best_score := -INF
	for radius in range(0, 6):
		for x in range(center.x - radius, center.x + radius + 1):
			for y in range(center.y - radius, center.y + radius + 1):
				if maxi(absi(x - center.x), absi(y - center.y)) != radius or not sim.player_near(x, y):
					continue
				var block: Dictionary = sim.plant_block_at(x, y)
				if block.is_empty():
					block = sim.get_block(x, y)
				if int(block.get("id", 0)) == 0 or bool(block.get("fluid", false)) or bool(block.get("container", false)):
					continue
				var name := str(block.get("name", ""))
				var hardness := float(sim.get_block_hardness(block))
				var distance := Vector2(x - center.x, y - center.y).length()
				var score := (120.0 if recipe_inputs.has(name) else 0.0) - hardness * 1.4 - distance * 8.0
				if score > best_score:
					best_score = score
					best = Vector2i(x, y)
	return best


func tutorial_place_candidate() -> Vector2i:
	var center := Vector2i(
		floori((float(sim.player.get("x", 0.0)) + float(sim.player.get("w", 20.0)) * 0.5) / BlockDefs.TILE),
		floori((float(sim.player.get("y", 0.0)) + float(sim.player.get("h", 30.0)) * 0.5) / BlockDefs.TILE)
	)
	for radius in range(1, 5):
		for x in range(center.x - radius, center.x + radius + 1):
			for y in range(center.y - radius, center.y + radius + 1):
				if maxi(absi(x - center.x), absi(y - center.y)) != radius:
					continue
				if sim.can_place_block(x, y):
					return Vector2i(x, y)
	return NO_TILE


func tutorial_plant_candidate(block_name: String) -> Vector2i:
	var center := Vector2i(
		floori((float(sim.player.get("x", 0.0)) + float(sim.player.get("w", 20.0)) * 0.5) / BlockDefs.TILE),
		floori((float(sim.player.get("y", 0.0)) + float(sim.player.get("h", 30.0)) * 0.5) / BlockDefs.TILE)
	)
	for radius in range(1, 5):
		for x in range(center.x - radius, center.x + radius + 1):
			for y in range(center.y - radius, center.y + radius + 1):
				if maxi(absi(x - center.x), absi(y - center.y)) != radius:
					continue
				if sim.can_plant_item_at(block_name, x, y):
					return Vector2i(x, y)
	return NO_TILE
