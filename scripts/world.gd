class_name WorldSim
extends RefCounted

signal inventory_changed
signal block_count_changed(count: int)
signal state_changed
signal time_changed
signal daylight_changed
signal player_defeated
signal death_cache_created(position: Vector2i, item_count: int)
signal death_cache_recovered(position: Vector2i, item_count: int)
signal death_cache_expired(position: Vector2i, item_count: int, age_seconds: int)
signal one_use_cache_recovered(position: Vector2i, trap_kind: String, item_count: int)
signal tideglass_bridge_cell_crystallized(position: Vector2i, step_index: int, total_steps: int)
signal static_tiles_changed
signal lighting_changed
signal one_block_phase_changed(phase_number: int)
signal challenge_milestone_reached(distance: int)
signal tile_changed(x: int, y: int, block_id: int, fluid_level: int, falling: bool)
signal plant_changed(anchor_x: int, anchor_y: int)
signal remote_player_attacked_by_creature(player_id: String, damage: int, knockback_x: float, knockback_y: float)

const SAVE_SCHEMA_VERSION := 1
const CORE_CONTENT_PREFIX := "core."
const STRUCTURE_DECOR_PLANT_IDS: Array[String] = [
	"core.plant.potted_fern",
	"core.plant.meadow_bloom",
	"core.plant.prairie_sprig",
]

const ISLAND_CX := 0
const ISLAND_CY := 8
const SPAWN_RADIUS := 5
const SPAWN_CHANGE_COOLDOWN_SECONDS := 30 * 60
const FALL_RESET_DEPTH := 48
const COORD_LIMIT := 100000
const FLUID_VOID_MARGIN := 32
const STATION_RADIUS := 4
const DEATH_CACHE_SEARCH_RADIUS := 8
const DEATH_CACHE_TTL_SECONDS := 30 * 60
const MAX_PLAYER_HEALTH := 4
const MAX_NOURISHMENT := 100
const COMBAT_REACH := BlockDefs.TILE * 2.0
const COMBAT_ATTACK_COOLDOWN_MSEC := 500
const FLINT_FROM_GRAVEL_CHANCE := 0.10
const STRUCTURE_CHEST_BOW_CHANCE := 0.085
const NOURISHMENT_DRAIN_SECONDS := 12.0
const NOURISHMENT_RECOVERY_THRESHOLD := 60
const NOURISHMENT_RECOVERY_SECONDS := 30.0
const NOURISHMENT_RECOVERY_COST := 6
const STARVATION_DAMAGE_SECONDS := 60.0
const MIN_PREPARED_MEAL_CREATURE_SIZE := 0.65
const CRAFT_SLOT_COUNT := 4

var tiles: Dictionary = {}
var fluid_level: Dictionary = {}
var fluid_falling: Dictionary = {}
var _fluid_void_limit_y := ISLAND_CY + FLUID_VOID_MARGIN
var tree_growth: Dictionary = {}
var plant_growth: Dictionary = {}
var plant_cells: Dictionary = {}
var creatures: Dictionary = {}
var creature_tick: int = 0
var burning_tiles: Dictionary = {}
var containers: Dictionary = {}
var inventory: Dictionary = {}
var inv_order: Array[String] = []
var hotbar_slots: Array[String] = ["", "", "", "", "", ""]
var equipment_slots: Dictionary = {"hand": "", "feet": ""}
var item_durability: Dictionary = {}
var footwear_wear_distance: float = 0.0
var active_hotbar_slot: int = 0
var selected: String = ""
var active_hotbar_slot_awaiting_item := false
var craft_open: bool = false
var open_container_pos := Vector2i(COORD_LIMIT + 1, COORD_LIMIT + 1)
var craft_slots: Array = [null, null, null, null]
var craft_slot_durability: Array[int] = [0, 0, 0, 0]
var craft_pick: String = ""
var known_recipes: Array[Dictionary] = []
var applied_discovery_jobs: Dictionary = {}
var block_count: int = 0
var fluid_tick: int = 0
var _glass_tide_bridge_queue: Array[Vector2i] = []
var _glass_tide_bridge_total := 0
var _glass_tide_bridge_step_ticks := 0
var tree_tick: int = 0
var weather_tick: int = 0
var granular_tick: int = 0
var fire_tick: int = 0
var water_missing_ticks: int = 0
var lava_missing_ticks: int = 0
var weather_type: String = "clear"
var weather_ticks_remaining: int = 0
var weather_target := Vector2i.ZERO
var weather_result: String = ""
var weather_is_recovery: bool = false
var lightning_sfx_played := false
var world_mode: String = "skyblock"
var world_seed: int = 0
var floating_island_layout: Array[Dictionary] = []
var catalog_revision: int = 0
var structure_catalog_revision: int = 0
var structure_definitions: Dictionary = {}
var biome_catalog_revision: int = 0
var biome_definitions: Dictionary = BiomeDefs.all()
var _core_biome_cache_initialized := false
var _core_biome_cache_seed: int = -1
var _core_region_biomes: Dictionary = {}
var _core_positive_frontier: int = 0
var _core_negative_frontier: int = 0
var regional_catalogs: Dictionary = {}
var _pending_chunk_biomes: Dictionary = {}
var world_definition_ids: Dictionary = {}
var generated_chunks: Dictionary = {}
var chunk_tiles: Dictionary = {}
var chunk_tiles_by_id: Dictionary = {}
var block_id_counts: Dictionary = {}
var chunk_tick: int = 0
var default_spawn := Vector2i(ISLAND_CX + 3, ISLAND_CY)
var custom_spawn_set := false
var spawn_change_available_at_unix: int = 0
var world_id: String = ""
var access_mode: String = "offline"
var multiplayer_join_code: String = ""
var keep_inventory_on_death := false
var multiplayer_player_states: Dictionary = {}
# Transient host-only player snapshots used by authoritative creature AI.
var multiplayer_player_targets: Dictionary = {}
var world_time_tick: int = 0
var one_block_position := Vector2i(ISLAND_CX, ISLAND_CY)
var one_block_mined: int = 0
var one_block_phase: int = 0
var challenge_best_distance: int = 0
var challenge_checkpoint_chunk: int = 0
var challenge_next_milestone: int = 100
var _challenge_activated_granular_traps: Dictionary = {}
var _challenge_activated_encounters: Dictionary = {}
var _player_was_in_harmful_fluid := false
var _harmful_fluid_damage_cooldown := 0.0
var _nourishment_drain_elapsed := 0.0
var _nourishment_recovery_elapsed := 0.0
var _starvation_damage_elapsed := 0.0
var _suspend_state_changed := false

const TREE_GROW_EVERY := 70
const TREE_CEILING_SCAN_BLOCKS := 12
const TREE_SIZES: Array[Dictionary] = [
	{"trunk": 2, "leaf_r": 1, "leaf_layers": 2, "soil_r": 1},
	{"trunk": 3, "leaf_r": 2, "leaf_layers": 2, "soil_r": 1},
	{"trunk": 5, "leaf_r": 2, "leaf_layers": 3, "soil_r": 2},
]

const TREE_CLIMB_SPEED := -3.2
const WATER_RECOVERY_TICKS := 60 * 90
const LAVA_RECOVERY_TICKS := 60 * 150
const RAIN_DURATION_TICKS := 60 * 8
const LIGHTNING_WARNING_TICKS := 60 * 3
const LIGHTNING_FLASH_TICKS := 14
const AMBIENT_WEATHER_INTERVAL_TICKS := 60 * 90
const AMBIENT_WEATHER_CHANCE := 0.05
const AMBIENT_WATER_CHANCE := 0.60
const AMBIENT_LAVA_CHANCE := 0.10
const WEATHER_TARGET_RADIUS := 12
const WEATHER_RECOVERY_SEARCH_EVERY := 60 * 5
const WEATHER_SKY_SCAN_HEIGHT := 128
const GRANULAR_TICK_EVERY := 4
const FIRE_TICK_EVERY := 12
const FIRE_BURN_STEPS := 24
const FIRE_SOURCE_IGNITION_CHANCE := 0.22
const FIRE_SPREAD_CHANCE := 0.14
const FIRE_IGNITION_TEMPERATURE := 0.75
const CREATURE_INITIAL_SPAWN_DELAY := 60 * 12
const CREATURE_HOSTILE_SPAWN_EVERY := 60 * 2
const CREATURE_PEACEFUL_SPAWN_EVERY := 60 * 20
const FIREFLY_SPAWN_EVERY := 60 * 8
const FIREFLY_LOCAL_TARGET := 2
const FIREFLY_NIGHT_SPAWN_CHANCE := 0.42
const FIREFLY_CAVE_SPAWN_CHANCE := 0.2
const CREATURE_SPAWN_CHANCE_MULTIPLIER := 2.0
const CREATURE_PREFERRED_ACTIVITY_SPAWN_MULTIPLIER := 1.5
const CREATURE_HOSTILE_SPAWN_MULTIPLIER := 4.0
const CREATURE_MAX_HOSTILE_SPAWN_CHANCE := 0.18
const CREATURE_SPAWN_POLICY_VERSION := 2
const CREATURE_BREED_CHECK_EVERY := 300
const PLANT_BREED_CHECK_EVERY := 300
const CREATURE_MAX_WORLD := 80
const CREATURE_NATURAL_TARGET := 10
const CREATURE_NATURAL_HOSTILE_CAP := 3
const CREATURE_NATURAL_PEACEFUL_CAP := 7
const CREATURE_ACTIVE_RADIUS := 14.0
const CREATURE_MAX_SPAWN_DISTANCE := 30
const CREATURE_LOCAL_CAP_RADIUS := 40.0
const CREATURE_DORMANT_DISTANCE := 48.0
const CREATURE_MAX_NATURAL_STORED := 48
const CREATURE_GRAVITY := 8.0
const CREATURE_MAX_FALL_SPEED := 6.0
const CREATURE_JUMP_SPEED := 5.5
const SHAGOT_IDLE_JUMP_CHANCE := 0.0
const SHAGOT_BUILD_LIMIT := 192
const SHAGOT_LOCAL_POPULATION_CAP := 5
const SHAGOT_MAX_FOLLOWERS_PER_PLAYER := 2
const SHAGOT_ACTIVITY_MIN_TICKS := 60 * 2
const SHAGOT_ACTIVITY_MAX_TICKS := 60 * 5
const SHAGOT_OBSERVE_MIN_TICKS := 30
const SHAGOT_OBSERVE_MAX_TICKS := 90
const SHAGOT_WORK_ACTION_TICKS := 42
const SHAGOT_WORK_SEARCH_RADIUS := 14
const SHAGOT_MINING_REACH := 1.6
const SHAGOT_BUILDING_REACH := 2.1
const GLASS_TIDE_BRIDGE_MAX_CELLS := 48
const GLASS_TIDE_BRIDGE_STEP_TICKS := 6
const CREATURE_PLANT_VISIT_MIN_TICKS := 60 * 2
const CREATURE_PLANT_VISIT_MAX_TICKS := 60 * 5
const CREATURE_PLANT_COOLDOWN_MIN_TICKS := 60 * 30
const CREATURE_PLANT_COOLDOWN_MAX_TICKS := 60 * 90
const CREATURE_PLANT_ARRIVAL_DISTANCE := 0.18
const CREATURE_POI_STUCK_TICKS := 60 * 2
const CREATURE_POI_RETRY_COOLDOWN_MIN_TICKS := 60 * 5
const CREATURE_POI_RETRY_COOLDOWN_MAX_TICKS := 60 * 10
const CREATURE_POI_STUCK_RADIUS := 0.3
const CREATURE_SIGHT_FLEE_MIN_TICKS := 60 * 4
const CREATURE_SIGHT_FLEE_MAX_TICKS := 60 * 7
const CREATURE_FEAR_COOLDOWN_MIN_TICKS := 60 * 4
const CREATURE_FEAR_COOLDOWN_MAX_TICKS := 60 * 8
const CREATURE_PREDATOR_ATTACK_COOLDOWN := 60
const CREATURE_PREY_FLEE_TICKS := 60 * 5
const DAY_LENGTH_TICKS := 60 * 60 * 20
const DAY_END_PHASE := 0.5
const SUNSET_END_PHASE := 0.575
const NIGHT_END_PHASE := 0.925
const NIGHT_DAYLIGHT := 0.12
const WORLD_MODE_SKYBLOCK := "skyblock"
const WORLD_MODE_FLOATING_ISLANDS := "floating_islands"
const WORLD_MODE_PROCEDURAL := "procedural"
const WORLD_MODE_ONE_BLOCK := "one_block"
const WORLD_MODE_CHALLENGE := "challenge_run"
const WORLD_MODE_DUEL := "duel"
const CHALLENGE_BASE_Y := ISLAND_CY
const CHALLENGE_DEEP_FIRST_CHUNK := 32
const CHALLENGE_DEEP_CHAPTER_INTERVAL := 16
const CHALLENGE_DEEP_PATTERN_FIRST := 32
const CHALLENGE_DEEP_PATTERN_COUNT := 3
const ACCESS_MODE_OFFLINE := "offline"
const ACCESS_MODE_PUBLIC := "public"
const ACCESS_MODE_INVITE_CODE := "invite_code"
const LEGACY_FLOATING_ISLAND_LAYOUT: Array[Dictionary] = [
	{"center": Vector2i(0, 8), "half_width": 4, "depth": 4, "biome": "plains", "shape_seed": 1},
	{"center": Vector2i(-24, -2), "half_width": 5, "depth": 5, "biome": "forest", "shape_seed": 2},
	{"center": Vector2i(25, 18), "half_width": 5, "depth": 4, "biome": "desert", "shape_seed": 3},
	{"center": Vector2i(-42, 22), "half_width": 4, "depth": 5, "biome": "tundra", "shape_seed": 4},
	{"center": Vector2i(38, -15), "half_width": 4, "depth": 5, "biome": "ice", "shape_seed": 5},
	{"center": Vector2i(0, 34), "half_width": 5, "depth": 5, "biome": "obsidian", "shape_seed": 6},
]
const ONE_BLOCK_PHASES: Array[Dictionary] = [
	{
		"end": 20,
		"blocks": {"core.grass": 6, "core.dirt": 6, "core.wood": 3, "core.leaves": 2},
		"loot": ["core.grass", "core.dirt", "core.wood", "core.leaves", "core.plant.oak"],
		"gift": {"core.wood": 2, "core.leaves": 2, "core.plant.oak": 1},
		"creatures": ["core.creature.meadow_hopper"],
	},
	{
		"end": 60,
		"blocks": {"core.stone": 7, "core.cobblestone": 5, "core.dirt": 2, "core.charcoal": 1},
		"loot": ["core.stone", "core.cobblestone", "core.charcoal", "core.workbench"],
		"gift": {"core.workbench": 1, "core.cobblestone": 3},
		"creatures": ["core.creature.cave_skitter", "core.creature.cave_spider"],
	},
	{
		"end": 110,
		"blocks": {"core.ice": 6, "core.stone": 3, "core.pine_wood": 3, "core.pine_needles": 2},
		"loot": ["core.ice", "core.pine_wood", "core.pine_needles", "core.plant.pine"],
		"gift": {"core.ice": 3, "core.plant.pine": 1},
		"creatures": ["core.creature.snow_penguin"],
	},
	{
		"end": 170,
		"blocks": {"core.palm_wood": 5, "core.palm_leaves": 4, "core.glass": 2, "core.dirt": 2},
		"loot": ["core.water", "core.sand", "core.glass", "core.palm_wood", "core.plant.palm"],
		"gift": {"core.water": 2, "core.sand": 3, "core.plant.palm": 1},
		"creatures": ["core.creature.pool_drifter", "core.creature.sky_mote"],
	},
	{
		"end": 240,
		"blocks": {"core.wood": 4, "core.leaves": 4, "core.weeping_wood": 3, "core.weeping_leaves": 3, "core.grass": 2},
		"loot": ["core.wood", "core.leaves", "core.plant.weeping_tree", "core.plant.cave_vines"],
		"gift": {"core.weeping_wood": 2, "core.plant.weeping_tree": 1},
		"creatures": ["core.creature.forest_fox", "core.creature.moss_crawler", "core.creature.moss_slug"],
	},
	{
		"end": 320,
		"blocks": {"core.glass": 4, "core.stone": 3, "core.charcoal": 2, "core.palm_wood": 2, "core.cobblestone": 2},
		"loot": ["core.sand", "core.glass", "core.charcoal", "core.palm_wood"],
		"gift": {"core.sand": 4, "core.glass": 2},
		"creatures": ["core.creature.sand_crab"],
	},
	{
		"end": 410,
		"blocks": {"core.obsidian": 4, "core.stone": 5, "core.charcoal": 3, "core.cobblestone": 2},
		"loot": ["core.lava", "core.obsidian", "core.charcoal", "core.stone"],
		"gift": {"core.lava": 2, "core.obsidian": 2},
		"creatures": ["core.creature.ember_walker", "core.creature.dusk_prowler"],
	},
	{
		"end": 510,
		"blocks": {"core.grass": 4, "core.leaves": 4, "core.glass": 3, "core.weeping_leaves": 3, "core.planks": 2},
		"loot": ["core.grass", "core.leaves", "core.glass", "core.plant.meadow_bloom", "core.plant.potted_fern", "core.item.trail_boots"],
		"gift": {"core.item.trail_boots": 1, "core.plant.meadow_bloom": 2, "core.plant.potted_fern": 1},
		"creatures": ["core.creature.watcher_bloom", "core.creature.meadow_hopper"],
	},
	{
		"end": 620,
		"blocks": {"core.stone": 6, "core.obsidian": 4, "core.charcoal": 3, "core.cobblestone": 3},
		"loot": ["core.stone", "core.obsidian", "core.charcoal", "core.gravel"],
		"gift": {"core.obsidian": 3, "core.charcoal": 3},
		"creatures": ["core.creature.dusk_prowler", "core.creature.gloomwing"],
	},
	{
		"end": 750,
		"blocks": {"core.obsidian": 5, "core.glass": 4, "core.stone": 3, "core.ice": 2},
		"loot": ["core.obsidian", "core.glass", "core.ice", "core.item.trail_boots", "core.item.copper_ingot"],
		"gift": {"core.obsidian": 4, "core.glass": 4, "core.item.copper_ingot": 1},
		"creatures": ["core.creature.gloomwing", "core.creature.cinder_eel"],
	},
]
const GENERATOR_VERSION := "1.0"
const CHUNK_WIDTH := 16
const CHUNK_GENERATION_RADIUS := 2
const ACTIVE_SIMULATION_CHUNK_RADIUS := 1
const FLUID_ACTIVE_RADIUS_X := 40
const FLUID_ACTIVE_RADIUS_Y := 32
const PROCEDURAL_BOTTOM_Y := 72
const RESONANT_DEEP_VERSION := 1
const RESONANT_SEAL_TOP_Y := PROCEDURAL_BOTTOM_Y
const RESONANT_DEEP_TOP_Y := 75
const RESONANT_DEEP_BOTTOM_Y := 132
const RESONANT_DEEP_BIOMES: Array[String] = [
	"lumenroot_groves", "chorus_river", "glass_tide_caverns", "magnetic_ruins",
	"inverted_orchard", "bone_choir", "prism_chasm", "shagot_lockworks",
]
const RESONANT_BIOME_SPAN_CHUNKS := 4
const SHAGOT_BIOME_ID := "magnetic_ruins"
const SHAGOT_BIOME_IDS: Array[String] = [SHAGOT_BIOME_ID, "shagot_lockworks"]
const RESONANT_LAYER_ID := "resonant_deep"
const RESONANT_DEEP_WILDLIFE := {
	"lumenroot_groves": "core.creature.rootback_grazer",
	"glass_tide_caverns": "core.creature.glasswing_ray",
	"prism_chasm": "core.creature.prism_skitter",
	"chorus_river": "core.creature.crystal_firefly",
	"inverted_orchard": "core.creature.crystal_firefly",
	"bone_choir": "core.creature.crystal_firefly",
}
const CONTENT_REGION_CHUNKS := 8
const MAX_GENERATED_CONTENT_PER_CHUNK := 3
const CORE_BIOME_PLAINS_CHANCE := 0.18
const CORE_BIOME_FOREST_CHANCE := 0.14
const CORE_BIOME_DESERT_CHANCE := 0.16
const CORE_BIOME_TUNDRA_CHANCE := 0.16
const CORE_BIOME_OBSIDIAN_CHANCE := 0.12
const CORE_BIOME_ICE_CHANCE := 0.11
const CORE_BIOME_CRYSTAL_GROVE_CHANCE := 0.01
const CORE_BIOME_BEACH_CHANCE := 0.12
const CORE_BIOME_IDS := ["plains", "forest", "crystal_grove", "beach", "desert", "tundra", "obsidian", "ice"]
const CORE_BIOME_NO_REPEAT_IDS: Array[String] = ["crystal_grove"]
const CORE_BIOME_BASE_WEIGHTS := {
	"plains": CORE_BIOME_PLAINS_CHANCE,
	"forest": CORE_BIOME_FOREST_CHANCE,
	"desert": CORE_BIOME_DESERT_CHANCE,
	"tundra": CORE_BIOME_TUNDRA_CHANCE,
	"obsidian": CORE_BIOME_OBSIDIAN_CHANCE,
	"ice": CORE_BIOME_ICE_CHANCE,
	"crystal_grove": CORE_BIOME_CRYSTAL_GROVE_CHANCE,
	"beach": CORE_BIOME_BEACH_CHANCE,
}
const CORE_BIOME_TEMPERATURE_AFFINITY_FLOOR := 0.03
const CORE_BIOME_TEMPERATURE_STRENGTH := 2.5
const CORE_BIOME_REGION_WIDTH := 48
const BIOME_TRANSITION_MIN_SIDE_WIDTH := 4
const BIOME_TRANSITION_MAX_SIDE_WIDTH := 8
const BIOME_TRANSITION_VERTICAL_DEPTH := 4
const FOREST_TREE_CHANCE := 0.20
const PLAINS_TREE_CHANCE := 0.04
const BIOME_TREE_CHANCE := {
	"forest": 0.20,
	"plains": 0.04,
	"tundra": 0.06,
	"beach": 0.08,
	"crystal_grove": 0.06,
}
const TUNDRA_ICE_PATCH_CHANCE := 0.45
const OBSIDIAN_OUTCROP_CHANCE := 0.22
const CRYSTAL_GROVE_OUTCROP_CHANCE := 0.62
const BUILTIN_STRUCTURE_CHANCE := 0.40
const RAVINE_STRUCTURE_CHANCE := 0.18
const CAVE_STRUCTURE_CHANCE := 0.52
const CAVE_STRUCTURE_CANDIDATES: Array[String] = [
	"mineshaft", "lava_grotto", "amethyst_geode", "rose_crystal_grotto", "emerald_vault",
	"crystal_bridge", "lantern_ruins", "miner_camp", "underground_shrine", "ore_gallery",
]
const STRUCTURE_MIN_CHUNK_SEPARATION := 2
const STRUCTURE_START_AREA_CHUNK_RADIUS := CHUNK_GENERATION_RADIUS
const STRUCTURE_SPAWN_CLEARANCE_BLOCKS := 2
const STRUCTURE_VEGETATION_PADDING := 2
const STRUCTURE_TREE_SCAN_HEIGHT := 12
const CHEST_SLOT_COUNT := 12
const CHEST_EMPTY_CHANCE := 0.25
const CHEST_BLOCK_LOOT_CHANCE := 0.50
const UNDERGROUND_WATER_CHANCE := 0.07
const UNDERGROUND_WATER_MAX_TILES := 3
const RIFT_CAVE_CHANCE := 0.040
const RIFT_CAVE_MIN_LENGTH := 150
const RIFT_CAVE_MAX_LENGTH := 220
const RIFT_CAVE_ORIGIN_MARGIN_CHUNKS := 6
const RIFT_CAVE_ORIGIN_SCAN_CHUNKS := 20
const RIFT_CAVE_MIN_ORIGIN_SEPARATION_CHUNKS := 20
const RIFT_CAVE_ORDINARY_CAVE_BUFFER := 5
const OBSIDIAN_STRUCTURE_CANDIDATES := [
	"obsidian_gate", "obsidian_spires", "obsidian_gate", "lava_pool", "obsidian_spires",
	"obsidian_gate", "ravine", "obsidian_spires", "lava_pool", "obsidian_gate",
]
const BEACH_STRUCTURE_CANDIDATES: Array[String] = [
	"palm_shelter", "palm_shelter", "palm_shelter", "stone_arch",
	"abandoned_hut", "forest_shelter", "buried_treasure", "ravine",
]
const LIGHT_SKY_SCAN_TILES := 128
const DAYLIGHT_FALLOFF := 0.0275
const EMISSIVE_FALLOFF := 0.085
const SOLID_VISUAL_FALLOFF := 0.08
const CLIMATE_TICK_EVERY := 180
const WATER_FREEZE_TEMPERATURE := -0.1
const ICE_MELT_TEMPERATURE := 0.05
const LOCAL_MELT_TEMPERATURE := 0.6
const ALTITUDE_COOLING_START_TILES := 8
const ALTITUDE_COOLING_PER_TILE := 0.015
const PLAINS_MOUNTAIN_SUMMIT_CHEST_CHANCE := 0.35
const BIOME_DEPOSIT_TEMPERATURE_TOLERANCE := 0.35
const BIOME_DECORATIVE_PLANT_CHANCE: Dictionary = {
	"plains": 0.72,
	"forest": 0.46,
	"riverbank": 0.38,
	"beach": 0.16,
	"tundra": 0.14,
	"ice": 0.0,
	"desert": 0.1,
	"obsidian": 0.0,
	"crystal_grove": 0.58,
}
const CAVE_HANGING_PLANT_CHANCE := 0.42

const SYSTEM_STRUCTURE_INFO: Dictionary = {
	"system.abandoned_hut": {"name": "Abandoned Hut", "description": "A weathered plank shelter with a usable doorway and a broken roof."},
	"system.stone_arch": {"name": "Stone Arch", "description": "An old cobblestone gateway that marks the landscape without blocking the path."},
	"system.forest_shelter": {"name": "Forest Shelter", "description": "A small wooden refuge covered by a leafy roof in forest terrain."},
	"system.desert_obelisk": {"name": "Desert Obelisk", "description": "A tall stone marker with an obsidian core rising above the dunes."},
	"system.ice_shrine": {"name": "Ice Shrine", "description": "A fragile frozen monument built around a dark obsidian center."},
	"system.river_bridge": {"name": "River Bridge", "description": "A wooden crossing that spans flowing water and keeps the route walkable."},
	"system.ravine": {"name": "Ravine", "description": "A deep winding chasm cut through the ground into the stone below."},
	"system.flower_field": {"name": "Flower Field", "description": "A colorful patch of collectible wildflowers growing across an open plain."},
	"system.obsidian_gate": {"name": "Shattered Obsidian Gate", "description": "A broken dark gateway with a wide opening through its center."},
	"system.obsidian_spires": {"name": "Obsidian Spires", "description": "Short volcanic-glass formations that rise from the wastes without sealing the path."},
	"system.lava_pool": {"name": "Lava Pool", "description": "An uncommon pocket of exposed lava contained by a natural obsidian rim."},
	"system.plains_hill": {"name": "Plains Hill", "description": "A low naturally stepped hill whose height changes from world to world."},
	"system.plains_mountain": {"name": "Plains Mountain", "description": "A towering stone landmark with a varied walk-through tunnel and an ancient ice cap."},
	"system.crystal_garden": {"name": "Crystal Garden", "description": "Rose and amethyst formations glowing above lavender-tinted grassland."},
	"system.buried_treasure": {"name": "Buried Treasure", "description": "A rare beach chest half uncovered by wind and waves."},
	"system.palm_shelter": {"name": "Palm Shelter", "description": "An open beach hut woven from palm fronds around a light timber frame."},
	"system.mineshaft": {"name": "Abandoned Mineshaft", "description": "Old timber supports and lanterns reveal a forgotten underground route."},
	"system.lava_grotto": {"name": "Lava Grotto", "description": "A bright contained lava pool warms a deep stone chamber."},
	"system.amethyst_geode": {"name": "Amethyst Geode", "description": "A rare violet crystal chamber glowing beneath the world."},
	"system.rose_crystal_grotto": {"name": "Rose Crystal Grotto", "description": "Pink crystals illuminate a quiet underground room."},
	"system.emerald_vault": {"name": "Emerald Vault", "description": "Green crystal clusters grow among ancient stonework."},
	"system.crystal_bridge": {"name": "Crystal Bridge", "description": "A narrow luminous crossing spans a broken cave floor."},
	"system.lantern_ruins": {"name": "Lantern Ruins", "description": "Collapsed masonry remains lit by long-burning lamps."},
	"system.miner_camp": {"name": "Lost Miner Camp", "description": "A small underground camp with supplies left behind."},
	"system.underground_shrine": {"name": "Moonstone Shrine", "description": "A deep blue mineral altar set into dark obsidian."},
	"system.ore_gallery": {"name": "Ore Gallery", "description": "Copper and moonstone veins line a naturally exposed passage."},
}

var player := {
	"x": 0.0, "y": 0.0, "w": 20.0, "h": 28.0,
	"vx": 0.0, "vy": 0.0, "on_ground": false, "facing": 1, "squash": 0.0,
	"jump_coyote": 0.0,
	"health": MAX_PLAYER_HEALTH,
	"nourishment": MAX_NOURISHMENT,
	"tree_ghost": false,
	"climbing": false,
	"climb_col": -1,
}


func create_island() -> void:
	_suspend_state_changed = true
	world_id = _new_world_id()
	world_mode = WORLD_MODE_SKYBLOCK
	world_seed = randi()
	floating_island_layout.clear()
	one_block_position = Vector2i(ISLAND_CX, ISLAND_CY)
	one_block_mined = 0
	one_block_phase = 0
	challenge_best_distance = 0
	challenge_checkpoint_chunk = 0
	challenge_next_milestone = 100
	keep_inventory_on_death = false
	_challenge_activated_granular_traps.clear()
	_challenge_activated_encounters.clear()
	catalog_revision = _latest_registered_catalog_revision()
	structure_catalog_revision = 0
	structure_definitions.clear()
	biome_catalog_revision = 0
	biome_definitions = BiomeDefs.all()
	regional_catalogs.clear()
	_pending_chunk_biomes.clear()
	world_definition_ids.clear()
	generated_chunks.clear()
	chunk_tiles.clear()
	chunk_tiles_by_id.clear()
	block_id_counts.clear()
	chunk_tick = 0
	block_count = 0
	tiles.clear()
	_fluid_void_limit_y = ISLAND_CY + FLUID_VOID_MARGIN
	fluid_level.clear()
	fluid_falling.clear()
	_glass_tide_bridge_queue.clear()
	_glass_tide_bridge_total = 0
	_glass_tide_bridge_step_ticks = 0
	tree_growth.clear()
	plant_growth.clear()
	plant_cells.clear()
	creatures.clear()
	containers.clear()
	creature_tick = 0
	world_time_tick = 0
	custom_spawn_set = false
	spawn_change_available_at_unix = 0
	_ensure_core_tree_blocks()
	_ensure_core_plants()
	_ensure_core_creatures()
	burning_tiles.clear()
	tree_tick = 0
	weather_tick = 0
	granular_tick = 0
	fire_tick = 0
	water_missing_ticks = 0
	lava_missing_ticks = 0
	weather_type = "clear"
	weather_ticks_remaining = 0
	weather_target = Vector2i.ZERO
	weather_result = ""
	weather_is_recovery = false
	inventory.clear()
	inv_order.clear()
	hotbar_slots = ["", "", "", "", "", ""]
	equipment_slots = {"hand": "", "feet": ""}
	item_durability.clear()
	footwear_wear_distance = 0.0
	active_hotbar_slot = 0
	selected = ""
	active_hotbar_slot_awaiting_item = false
	craft_pick = ""
	craft_slots = [null, null, null, null]
	craft_slot_durability = [0, 0, 0, 0]
	craft_open = false
	open_container_pos = Vector2i(COORD_LIMIT + 1, COORD_LIMIT + 1)
	known_recipes.clear()
	applied_discovery_jobs.clear()

	var cx := ISLAND_CX
	var cy := ISLAND_CY
	var half_w := 4
	var max_depth := 4

	for dx in range(-half_w, half_w + 1):
		var x := cx + dx
		var t: float = float(dx) / float(half_w)
		var depth: int = maxi(1, int(round(float(max_depth) * (1.0 - t * t))))
		for d in range(0, depth + 1):
			var y := cy + d
			var block_id: int
			if d == 0:
				block_id = BlockDefs.BLOCKS.grass.id
			elif d == depth:
				block_id = BlockDefs.BLOCKS.stone.id
			else:
				block_id = BlockDefs.BLOCKS.dirt.id
			set_block(x, y, block_id)

	set_block(cx, cy - 1, BlockDefs.BLOCKS.leaves.id)
	_try_start_tree_growth(cx, cy - 1, "leaves")

	create_fluid_pit(cx - 2, cy, BlockDefs.BLOCKS.water.id)
	create_fluid_pit(cx + 2, cy, BlockDefs.BLOCKS.lava.id)
	default_spawn = Vector2i(cx + 3, cy)
	reset_player()
	_suspend_state_changed = false
	state_changed.emit()


func create_procedural_world(seed: int = 0) -> void:
	create_island()
	_suspend_state_changed = true
	world_mode = WORLD_MODE_PROCEDURAL
	world_seed = seed if seed != 0 else maxi(1, randi())
	catalog_revision = _latest_registered_catalog_revision()
	generated_chunks.clear()
	chunk_tiles.clear()
	chunk_tiles_by_id.clear()
	block_id_counts.clear()
	chunk_tick = 0
	tiles.clear()
	_fluid_void_limit_y = RESONANT_DEEP_BOTTOM_Y + FLUID_VOID_MARGIN
	block_count = 0
	fluid_level.clear()
	fluid_falling.clear()
	tree_growth.clear()
	plant_growth.clear()
	plant_cells.clear()
	creatures.clear()
	creature_tick = 0
	world_time_tick = 0
	default_spawn = Vector2i(0, _terrain_surface_y(0))
	for chunk_x in range(-CHUNK_GENERATION_RADIUS, CHUNK_GENERATION_RADIUS + 1):
		_generate_chunk(chunk_x)
	reset_player()
	_suspend_state_changed = false
	block_count = count_blocks()
	block_count_changed.emit(block_count)
	state_changed.emit()


func create_floating_islands_world(seed: int = 0) -> void:
	create_island()
	_suspend_state_changed = true
	world_mode = WORLD_MODE_FLOATING_ISLANDS
	world_seed = seed if seed != 0 else maxi(1, randi())
	tiles.clear()
	_fluid_void_limit_y = ISLAND_CY + FLUID_VOID_MARGIN
	fluid_level.clear()
	fluid_falling.clear()
	tree_growth.clear()
	plant_growth.clear()
	plant_cells.clear()
	creatures.clear()
	containers.clear()
	burning_tiles.clear()
	generated_chunks.clear()
	chunk_tiles.clear()
	chunk_tiles_by_id.clear()
	block_id_counts.clear()
	block_count = 0
	floating_island_layout = _random_floating_island_layout(world_seed)
	_fluid_void_limit_y = _default_fluid_void_limit()

	for island: Dictionary in floating_island_layout:
		_generate_floating_island(island)
	for island_index in floating_island_layout.size():
		_decorate_floating_island(floating_island_layout[island_index], island_index == 0)

	var spawn_island: Dictionary = floating_island_layout[0]
	var spawn_center: Vector2i = spawn_island["center"]
	default_spawn = Vector2i(spawn_center.x + int(spawn_island["half_width"]) - 1, spawn_center.y)
	reset_player()
	_suspend_state_changed = false
	block_count = count_blocks()
	block_count_changed.emit(block_count)
	static_tiles_changed.emit()
	lighting_changed.emit()
	state_changed.emit()


func create_duel_world(seed: int = 0) -> void:
	create_island()
	_suspend_state_changed = true
	world_mode = WORLD_MODE_DUEL
	world_seed = seed if seed != 0 else maxi(1, randi())
	keep_inventory_on_death = false
	tiles.clear()
	fluid_level.clear()
	fluid_falling.clear()
	tree_growth.clear()
	plant_growth.clear()
	plant_cells.clear()
	creatures.clear()
	containers.clear()
	burning_tiles.clear()
	generated_chunks.clear()
	chunk_tiles.clear()
	chunk_tiles_by_id.clear()
	block_id_counts.clear()
	block_count = 0
	inventory.clear()
	inv_order.clear()
	hotbar_slots = ["", "", "", "", "", ""]
	equipment_slots = {"hand": "", "feet": ""}
	item_durability.clear()
	selected = ""
	multiplayer_player_states.clear()

	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed
	var biome_deck: Array = CORE_BIOME_IDS.duplicate()
	_shuffle_with_rng(biome_deck, rng)
	var shared_shape_seed := rng.randi_range(1, 2_000_000_000)
	var left_center := Vector2i(-18, ISLAND_CY)
	var right_center := Vector2i(18, ISLAND_CY)
	floating_island_layout = [
		{"center": left_center, "half_width": 6, "depth": 6, "biome": str(biome_deck[0]), "shape_seed": shared_shape_seed},
		{"center": right_center, "half_width": 6, "depth": 6, "biome": str(biome_deck[1]), "shape_seed": shared_shape_seed},
	]
	for island: Dictionary in floating_island_layout:
		_generate_floating_island(island)
	var shared_contents := _duel_chest_contents(rng)
	for island: Dictionary in floating_island_layout:
		var center: Vector2i = island["center"]
		var chest_pos := Vector2i(center.x, center.y - 1)
		set_block(chest_pos.x, chest_pos.y, int(BlockDefs.BLOCKS.chest.id))
		containers[chest_pos] = {
			"contents": shared_contents.duplicate(true),
			"durability": {},
			"loot_generated": true,
			"loot_key": "duel:%d" % world_seed,
			"loot_tier": "duel",
		}
	default_spawn = duel_spawn_point(0)
	custom_spawn_set = true
	reset_player()
	custom_spawn_set = false
	player["facing"] = 1
	_fluid_void_limit_y = _default_fluid_void_limit()
	_suspend_state_changed = false
	block_count = count_blocks()
	block_count_changed.emit(block_count)
	static_tiles_changed.emit()
	lighting_changed.emit()
	state_changed.emit()


func duel_spawn_point(player_index: int) -> Vector2i:
	if floating_island_layout.size() < 2:
		return default_spawn
	var island: Dictionary = floating_island_layout[clampi(player_index, 0, 1)]
	var center: Vector2i = island["center"]
	return Vector2i(center.x + (-3 if player_index == 0 else 3), center.y)


func _duel_chest_contents(rng: RandomNumberGenerator) -> Dictionary:
	var pickaxes: Array[String] = ["wooden_pickaxe", "stone_pickaxe", "copper_pickaxe"]
	var weapons: Array[String] = ["stone_axe", "stone_sword", "bow"]
	var footwear: Array[String] = ["trail_boots", "palm_sandals", "ice_boots"]
	var weapon := weapons[rng.randi_range(0, weapons.size() - 1)]
	var contents := {
		pickaxes[rng.randi_range(0, pickaxes.size() - 1)]: 1,
		weapon: 1,
		footwear[rng.randi_range(0, footwear.size() - 1)]: 1,
		"cobblestone": rng.randi_range(12, 24),
		"prepared_meal": rng.randi_range(1, 3),
	}
	if weapon == "bow":
		contents["arrow"] = rng.randi_range(12, 20)
	return contents


func _shuffle_with_rng(values: Array, rng: RandomNumberGenerator) -> void:
	for index in range(values.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var current = values[index]
		values[index] = values[swap_index]
		values[swap_index] = current


func _floating_island_record(center: Vector2i, biome_id: String, rng: RandomNumberGenerator, is_spawn: bool = false) -> Dictionary:
	return {
		"center": center,
		"half_width": rng.randi_range(4 if is_spawn else 3, 6),
		"depth": rng.randi_range(3, 7),
		"biome": biome_id,
		"shape_seed": rng.randi_range(1, 2_000_000_000),
	}


func _floating_island_overlaps(candidate: Dictionary, layout: Array[Dictionary]) -> bool:
	var center: Vector2i = candidate["center"]
	for island: Dictionary in layout:
		var other: Vector2i = island["center"]
		var horizontal_clearance := int(candidate["half_width"]) + int(island["half_width"]) + 7
		var vertical_clearance := maxi(int(candidate["depth"]), int(island["depth"])) + 9
		if absi(center.x - other.x) < horizontal_clearance and absi(center.y - other.y) < vertical_clearance:
			return true
	return false


func _random_floating_island_center(direction: String, origin: Vector2i, rng: RandomNumberGenerator, distance_boost: int = 0) -> Vector2i:
	match direction:
		"left": return origin + Vector2i(-rng.randi_range(20 + distance_boost, 38 + distance_boost), rng.randi_range(-13, 15))
		"right": return origin + Vector2i(rng.randi_range(20 + distance_boost, 38 + distance_boost), rng.randi_range(-13, 15))
		"above": return origin + Vector2i(rng.randi_range(-20, 20), -rng.randi_range(15 + distance_boost, 29 + distance_boost))
		"below": return origin + Vector2i(rng.randi_range(-20, 20), rng.randi_range(17 + distance_boost, 32 + distance_boost))
		"left_above": return origin + Vector2i(-rng.randi_range(22 + distance_boost, 48 + distance_boost), -rng.randi_range(16, 30))
		"right_above": return origin + Vector2i(rng.randi_range(22 + distance_boost, 48 + distance_boost), -rng.randi_range(16, 30))
		"left_below": return origin + Vector2i(-rng.randi_range(22 + distance_boost, 48 + distance_boost), rng.randi_range(18, 34))
		_: return origin + Vector2i(rng.randi_range(22 + distance_boost, 48 + distance_boost), rng.randi_range(18, 34))


func _random_floating_island_layout(seed: int) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var biome_deck: Array = CORE_BIOME_IDS.duplicate()
	_shuffle_with_rng(biome_deck, rng)
	var spawn_center := Vector2i(rng.randi_range(-4, 4), rng.randi_range(5, 11))
	var layout: Array[Dictionary] = [_floating_island_record(spawn_center, str(biome_deck[0]), rng, true)]
	var island_count := maxi(6, CORE_BIOME_IDS.size())
	var directions: Array = ["left", "right", "above", "below"]
	var extras: Array = ["left_above", "right_above", "left_below", "right_below"]
	_shuffle_with_rng(extras, rng)
	directions.append_array(extras)
	for island_index in range(1, island_count):
		var direction := str(directions[island_index - 1])
		var biome_id := str(biome_deck[island_index % biome_deck.size()])
		var candidate: Dictionary = {}
		for attempt in 24:
			var center := _random_floating_island_center(direction, spawn_center, rng, int(attempt / 8) * 8)
			candidate = _floating_island_record(center, biome_id, rng)
			if not _floating_island_overlaps(candidate, layout):
				break
		if _floating_island_overlaps(candidate, layout):
			candidate = _floating_island_record(_random_floating_island_center(direction, spawn_center, rng, 96), biome_id, rng)
		layout.append(candidate)
	return layout


func _floating_tree_components(biome_id: String) -> Array[String]:
	match biome_id:
		"tundra", "ice": return ["core.pine_wood", "core.pine_needles"]
		"desert", "beach": return ["core.palm_wood", "core.palm_leaves"]
		"obsidian": return ["core.weeping_wood", "core.weeping_leaves"]
		_: return ["core.wood", "core.leaves"]


func _decorate_floating_island(island: Dictionary, is_spawn: bool) -> void:
	var center: Vector2i = island["center"]
	var biome_id := str(island["biome"])
	var tree_components := _floating_tree_components(biome_id)
	if is_spawn or biome_id in ["plains", "forest", "tundra", "desert"]:
		_place_floating_tree(center, tree_components[0], tree_components[1], 3)
	if not is_spawn and biome_id == "forest" and int(island["half_width"]) >= 5:
		_place_floating_tree(center + Vector2i(int(island["half_width"]) - 1, 0), tree_components[0], tree_components[1], 2)
	if is_spawn:
		create_fluid_pit(center.x - 2, center.y, BlockDefs.BLOCKS.water.id)
		create_fluid_pit(center.x + 2, center.y, BlockDefs.BLOCKS.lava.id)
	elif biome_id == "ice":
		create_fluid_pit(center.x, center.y, BlockDefs.BLOCKS.water.id)
	elif biome_id == "obsidian":
		create_fluid_pit(center.x, center.y, BlockDefs.BLOCKS.lava.id)


func _generate_floating_island(island: Dictionary) -> void:
	var center: Vector2i = island["center"]
	var half_width := int(island["half_width"])
	var max_depth := int(island["depth"])
	var biome_id := str(island["biome"])
	var surface_name := _biome_terrain_block_name(biome_id, "surface_content_id", "grass")
	var subsurface_name := _biome_terrain_block_name(biome_id, "subsurface_content_id", "dirt")
	var deep_name := _biome_terrain_block_name(biome_id, "deep_content_id", "stone")
	var surface_id := int(BlockDefs.BLOCKS.get(surface_name, BlockDefs.BLOCKS.grass).id)
	var subsurface_id := int(BlockDefs.BLOCKS.get(subsurface_name, BlockDefs.BLOCKS.dirt).id)
	var deep_id := int(BlockDefs.BLOCKS.get(deep_name, BlockDefs.BLOCKS.stone).id)
	var surface_is_granular: bool = bool(BlockDefs.get_block_by_id(surface_id).get("falls_when_unsupported", false))
	var shape_rng := RandomNumberGenerator.new()
	shape_rng.seed = int(island.get("shape_seed", world_seed))
	var column_depths: Dictionary = {}
	for dx in range(-half_width, half_width + 1):
		var taper := float(dx) / float(half_width)
		var base_depth := int(round(float(max_depth) * (1.0 - taper * taper)))
		column_depths[dx] = maxi(1, base_depth + (shape_rng.randi_range(-1, 1) if absi(dx) < half_width else 0))
	for dx in range(-half_width, half_width + 1):
		var depth := int(column_depths[dx])
		for layer in range(depth + 1):
			var id: int
			if surface_is_granular:
				# A one-block rigid shell follows the lower and side contour. The
				# interior stays sandy without being able to pour out diagonally.
				var left_depth := int(column_depths.get(dx - 1, -1))
				var right_depth := int(column_depths.get(dx + 1, -1))
				var is_contour := layer == depth or layer > left_depth or layer > right_depth
				id = deep_id if is_contour else (surface_id if layer == 0 else subsurface_id)
			else:
				id = surface_id if layer == 0 else (deep_id if layer == depth else subsurface_id)
			set_block(center.x + dx, center.y + layer, id)


func _place_floating_tree(base: Vector2i, trunk_content_id: String, foliage_content_id: String, height: int) -> void:
	var trunk_name := _block_name_for_content_id(trunk_content_id)
	var foliage_name := _block_name_for_content_id(foliage_content_id)
	if not BlockDefs.BLOCKS.has(trunk_name) or not BlockDefs.BLOCKS.has(foliage_name):
		return
	var trunk_id := int(BlockDefs.BLOCKS[trunk_name].id)
	var foliage_id := int(BlockDefs.BLOCKS[foliage_name].id)
	for dy in range(1, height + 1):
		set_block(base.x, base.y - dy, trunk_id)
	if foliage_content_id == "core.palm_leaves":
		var crown := Vector2i(base.x, base.y - height - 1)
		for offset: Vector2i in _palm_crown_offsets(3):
			set_block(crown.x + offset.x, crown.y + offset.y, foliage_id)
		return
	for dx in range(-2, 3):
		for dy in range(-1, 2):
			if absi(dx) + absi(dy) > 2:
				continue
			set_block(base.x + dx, base.y - height - 1 + dy, foliage_id)


func _palm_crown_offsets(radius: int) -> Array[Vector2i]:
	var frond_radius := maxi(2, radius)
	var offsets: Array[Vector2i] = [Vector2i.ZERO, Vector2i(0, -1)]
	for side in [-1, 1]:
		# Straight side fronds stay one block thin.
		for distance in range(1, frond_radius + 1):
			offsets.append(Vector2i(side * distance, 0))
		# Separate rising and falling fronds turn the crown into a starburst
		# instead of a solid rectangular arch.
		offsets.append(Vector2i(side, -1))
		offsets.append(Vector2i(side * 2, -2))
		offsets.append(Vector2i(side, 1))
		offsets.append(Vector2i(side * 2, 2))
		if frond_radius > 2:
			offsets.append(Vector2i(side * frond_radius, 2))
	return offsets


func create_one_block_world(seed: int = 0) -> void:
	create_island()
	_suspend_state_changed = true
	world_mode = WORLD_MODE_ONE_BLOCK
	world_seed = seed if seed != 0 else maxi(1, randi())
	one_block_position = Vector2i(ISLAND_CX, ISLAND_CY)
	one_block_mined = 0
	one_block_phase = 0
	tiles.clear()
	_fluid_void_limit_y = ISLAND_CY + FLUID_VOID_MARGIN
	fluid_level.clear()
	fluid_falling.clear()
	tree_growth.clear()
	plant_growth.clear()
	plant_cells.clear()
	creatures.clear()
	containers.clear()
	burning_tiles.clear()
	generated_chunks.clear()
	chunk_tiles.clear()
	chunk_tiles_by_id.clear()
	block_id_counts.clear()
	block_count = 0
	set_block(one_block_position.x, one_block_position.y, int(BlockDefs.BLOCKS.grass.id))
	default_spawn = one_block_position
	reset_player()
	_suspend_state_changed = false
	block_count = count_blocks()
	block_count_changed.emit(block_count)
	static_tiles_changed.emit()
	lighting_changed.emit()
	state_changed.emit()


func create_challenge_world(seed: int = 0) -> void:
	create_island()
	_suspend_state_changed = true
	world_mode = WORLD_MODE_CHALLENGE
	world_seed = seed if seed != 0 else maxi(1, randi())
	tiles.clear()
	fluid_level.clear()
	fluid_falling.clear()
	tree_growth.clear()
	plant_growth.clear()
	plant_cells.clear()
	creatures.clear()
	containers.clear()
	burning_tiles.clear()
	generated_chunks.clear()
	chunk_tiles.clear()
	chunk_tiles_by_id.clear()
	block_id_counts.clear()
	block_count = 0
	challenge_best_distance = 0
	challenge_checkpoint_chunk = 0
	challenge_next_milestone = 100
	_challenge_activated_encounters.clear()
	_fluid_void_limit_y = CHALLENGE_BASE_Y + FLUID_VOID_MARGIN
	for chunk_x in range(0, CHUNK_GENERATION_RADIUS + 1):
		_generate_challenge_chunk(chunk_x)
	default_spawn = Vector2i(1, CHALLENGE_BASE_Y)
	custom_spawn_set = true
	reset_player()
	_suspend_state_changed = false
	block_count = count_blocks()
	block_count_changed.emit(block_count)
	static_tiles_changed.emit()
	lighting_changed.emit()
	state_changed.emit()


func challenge_distance() -> int:
	if world_mode != WORLD_MODE_CHALLENGE:
		return 0
	var tile_x := floori((float(player["x"]) + float(player["w"]) * 0.5) / float(BlockDefs.TILE))
	return maxi(0, tile_x - 1)


func _next_challenge_milestone_after(distance: int) -> int:
	if distance < 100:
		return 100
	if distance < 250:
		return 250
	if distance < 500:
		return 500
	if distance < 1000:
		return 1000
	return (distance / 1000 + 1) * 1000


func _update_challenge_progress() -> void:
	if world_mode != WORLD_MODE_CHALLENGE:
		return
	var distance := challenge_distance()
	if distance > challenge_best_distance:
		challenge_best_distance = distance
	while challenge_best_distance >= challenge_next_milestone:
		var reached := challenge_next_milestone
		challenge_next_milestone = _next_challenge_milestone_after(reached)
		challenge_milestone_reached.emit(reached)
	var tile_x := floori((float(player["x"]) + float(player["w"]) * 0.5) / float(BlockDefs.TILE))
	var checkpoint_chunk := floori(float(tile_x) / float(CHUNK_WIDTH))
	var local_x := posmod(tile_x, CHUNK_WIDTH)
	if checkpoint_chunk > challenge_checkpoint_chunk and local_x <= 3 and bool(player.get("on_ground", false)):
		challenge_checkpoint_chunk = checkpoint_chunk
		default_spawn = Vector2i(checkpoint_chunk * CHUNK_WIDTH + 1, CHALLENGE_BASE_Y)
		custom_spawn_set = true


func _challenge_random(chunk_x: int, channel: String) -> float:
	return _structure_random("challenge:%d:%s" % [chunk_x, channel])


func _challenge_pattern_for_chunk(chunk_x: int) -> int:
	if chunk_x < 0:
		return -1
	if chunk_x == 0:
		return 0
	# Starting at 500 scored blocks, every sixteen-section chapter opens with
	# three authored Resonant Deep encounters. Keeping them consecutive makes the
	# biome transition readable and guarantees that every saved seed exposes the
	# update mechanics instead of leaving them to a low-probability random roll.
	if chunk_x >= CHALLENGE_DEEP_FIRST_CHUNK:
		var deep_phase := posmod(chunk_x - CHALLENGE_DEEP_FIRST_CHUNK, CHALLENGE_DEEP_CHAPTER_INTERVAL)
		if deep_phase < CHALLENGE_DEEP_PATTERN_COUNT:
			return CHALLENGE_DEEP_PATTERN_FIRST + deep_phase
	return _legacy_challenge_pattern_for_chunk(chunk_x)


func _legacy_challenge_pattern_for_chunk(chunk_x: int) -> int:
	if chunk_x < 0:
		return -1
	if chunk_x == 0:
		return 0
	var pattern_count := 5 if chunk_x < 3 else (12 if chunk_x < 8 else 32)
	return int(_challenge_random(chunk_x, "pattern") * float(pattern_count)) % pattern_count


func _challenge_pattern_at_chunk(chunk_x: int) -> int:
	if generated_chunks.has(chunk_x):
		var saved_pattern := int((generated_chunks[chunk_x] as Dictionary).get("challenge_pattern", -1))
		if saved_pattern >= 0:
			return saved_pattern
	return _challenge_pattern_for_chunk(chunk_x)


func _challenge_surface(x: int, y: int, block_name: String, supported: bool = false) -> void:
	_set_generated_block(x, y, block_name)
	if supported:
		_set_generated_block(x, y + 1, "stone")


func _challenge_safe_platform(start_x: int, biome_id: String, chunk_x: int) -> void:
	var surface_name := _biome_terrain_block_name(biome_id, "surface_content_id", "grass")
	# Keep the checkpoint and obstacle-facing edges level, while the exposed ends
	# receive a deterministic one-block rise or dip. Adjacent chunks always meet a
	# level edge, so visual texture never creates an unfair two-block transition.
	var entrance_relief := int(_challenge_random(chunk_x, "entrance-relief") * 3.0) - 1
	var entrance_inner_relief := int(_challenge_random(chunk_x, "entrance-inner-relief") * 3.0) - 1
	var exit_relief := int(_challenge_random(chunk_x, "exit-relief") * 3.0) - 1
	var profile := {
		0: entrance_relief,
		1: 0,
		2: entrance_inner_relief,
		3: 0,
		CHUNK_WIDTH - 2: exit_relief,
		CHUNK_WIDTH - 1: 0,
	}
	for local_x: int in profile:
		_challenge_surface(start_x + local_x, CHALLENGE_BASE_Y + int(profile[local_x]), surface_name, true)


func _place_challenge_supply_chest(pos: Vector2i, block_name: String, amount: int, chunk_x: int) -> bool:
	if not _place_structure_chest(pos, "challenge-supply:%d" % chunk_x):
		return false
	containers[pos] = {
		"contents": {block_name: amount},
		"durability": {},
		"loot_generated": true,
		"loot_key": "challenge-supply:%d" % chunk_x,
		"loot_tier": "challenge_supply",
	}
	return true


func _challenge_encounter_for_pattern(pattern: int) -> Array[Dictionary]:
	match pattern:
		20:
			return [{"content_id": "core.creature.gloomwing", "local_x": 9, "y": CHALLENGE_BASE_Y + 7}]
		21:
			return [
				{"content_id": "core.creature.gloomwing", "local_x": 8, "y": CHALLENGE_BASE_Y + 7},
				{"content_id": "core.creature.gloomwing", "local_x": 10, "y": CHALLENGE_BASE_Y + 7},
			]
		23:
			return [
				{"content_id": "core.creature.cave_skitter", "local_x": 7, "y": CHALLENGE_BASE_Y - 1},
				{"content_id": "core.creature.cave_spider", "local_x": 11, "y": CHALLENGE_BASE_Y - 1},
			]
		24:
			return [{"content_id": "core.creature.gloomwing", "local_x": 9, "y": CHALLENGE_BASE_Y - 3}]
		25:
			return [{"content_id": "core.creature.gloomwing", "local_x": 8, "y": CHALLENGE_BASE_Y - 4}]
		26:
			return [
				{"content_id": "core.creature.cave_skitter", "local_x": 6, "y": CHALLENGE_BASE_Y - 1},
				{"content_id": "core.creature.gloomwing", "local_x": 10, "y": CHALLENGE_BASE_Y - 4},
			]
		29:
			return [
				{"content_id": "core.creature.dusk_prowler", "local_x": 7, "y": CHALLENGE_BASE_Y + 4},
				{"content_id": "core.creature.cave_skitter", "local_x": 10, "y": CHALLENGE_BASE_Y + 4},
			]
		31:
			return [
				{"content_id": "core.creature.gloomwing", "local_x": 7, "y": CHALLENGE_BASE_Y - 4},
				{"content_id": "core.creature.gloomwing", "local_x": 9, "y": CHALLENGE_BASE_Y - 4},
				{"content_id": "core.creature.gloomwing", "local_x": 10, "y": CHALLENGE_BASE_Y - 3},
				{"content_id": "core.creature.gloomwing", "local_x": 7, "y": CHALLENGE_BASE_Y - 2},
				{"content_id": "core.creature.gloomwing", "local_x": 8, "y": CHALLENGE_BASE_Y - 1},
				{"content_id": "core.creature.gloomwing", "local_x": 10, "y": CHALLENGE_BASE_Y - 1},
			]
		33:
			return [{
				"content_id": "core.creature.shagot_wanderer",
				"local_x": 8,
				"y": CHALLENGE_BASE_Y - 1,
				"state": {"carried_materials": 4, "work_cooldown": 20},
			}]
		34:
			return [
				{"content_id": "core.creature.shagot_raider", "local_x": 8, "y": CHALLENGE_BASE_Y - 1},
				{"content_id": "core.creature.shagot_raider", "local_x": 11, "y": CHALLENGE_BASE_Y - 1},
			]
	return []


func _generate_challenge_chunk(chunk_x: int) -> void:
	if generated_chunks.has(chunk_x):
		return
	if chunk_x < 0:
		generated_chunks[chunk_x] = {
			"catalog_revision": catalog_revision,
			"structure_catalog_revision": structure_catalog_revision,
			"selected_content_ids": [],
			"selected_structure_ids": [],
			"placed_structures": [],
			"builtin_structure": false,
			"builtin_structure_id": "",
			"biome_id": "plains",
			"biome_catalog_revision": biome_catalog_revision,
		}
		return
	var start_x := chunk_x * CHUNK_WIDTH
	var difficulty := maxi(0, chunk_x)
	# The deck expands with distance: a gentle five-pattern introduction, then
	# construction and climbing, and finally the full thirty-two-pattern course.
	var pattern := _challenge_pattern_for_chunk(chunk_x)
	var biome_id: String = [
		"plains", "forest", "plains", "desert", "obsidian",
		"plains", "obsidian", "forest", "tundra", "plains",
		"plains", "obsidian", "plains", "plains", "riverbank",
		"obsidian", "plains", "ice", "forest", "obsidian",
		"desert", "obsidian", "desert", "cavern", "cavern",
		"cavern", "cavern", "volcanic", "volcanic", "cavern",
		"volcanic", "cavern", "glass_tide_caverns", "magnetic_ruins",
		"shagot_lockworks",
	][pattern]
	_challenge_safe_platform(start_x, biome_id, chunk_x)
	# A reward chest appears only after a meaningful run of sections. It uses the
	# normal seeded chest-loot system, so opening and saving behave exactly like
	# structure chests in the other world modes.
	var supply_pattern := pattern in [5, 6, 22, 28, 32]
	if supply_pattern:
		var supply_block := "packed_ice" if pattern == 32 else ("sand" if pattern == 22 else ("ice" if pattern == 5 else "cobblestone"))
		var supply_amount := 1 if pattern == 32 else (10 if pattern == 22 else (6 if pattern == 28 else 3))
		_place_challenge_supply_chest(
			Vector2i(start_x + 3, CHALLENGE_BASE_Y - 1),
			supply_block,
			supply_amount,
			chunk_x,
		)
	elif chunk_x > 0 and chunk_x % 5 == 0:
		_place_structure_chest(Vector2i(start_x + 3, CHALLENGE_BASE_Y - 1), "challenge:%d" % chunk_x)
	var left := start_x + 4
	var right := start_x + CHUNK_WIDTH - 3
	match pattern:
		0:
			# Short, readable hops introduce the course without an unfair first jump.
			var gap_phase := int(_challenge_random(chunk_x, "hop-phase") * 3.0)
			for x in range(left, right + 1):
				if (x - left + gap_phase) % 3 != 1:
					_challenge_surface(x, CHALLENGE_BASE_Y, "cobblestone")
		1:
			# Alternating heights require timing but never exceed a one-block step.
			var height_phase := int(_challenge_random(chunk_x, "height-phase") * 6.0)
			for x in range(left, right + 1):
				var offset := posmod(x - left + height_phase, 6)
				var y := CHALLENGE_BASE_Y - (1 if offset in [2, 3] else 0)
				if offset != 4 or difficulty < 3:
					_challenge_surface(x, y, "wood")
		2:
			# Ordinary ice slowly melts in this warm section, turning a simple bridge
			# into a race when the player hesitates or revisits it.
			var melt_gap_phase := int(_challenge_random(chunk_x, "melt-gap") * 5.0)
			for x in range(left, right + 1):
				if difficulty < 4 or (x - left + melt_gap_phase) % 5 != 3:
					_challenge_surface(x, CHALLENGE_BASE_Y, "ice")
		3:
			for x in range(left, right + 1):
				var gap_stride := 4 if difficulty < 5 else 3
				var gap_phase := int(_challenge_random(chunk_x, "sandstone-gap") * float(gap_stride))
				if (x - left + gap_phase) % gap_stride != gap_stride - 1:
					_challenge_surface(x, CHALLENGE_BASE_Y, "sandstone")
		4:
			var tooth_phase := int(_challenge_random(chunk_x, "obsidian-teeth") * 5.0)
			for x in range(left, right + 1):
				var offset := posmod(x - left + tooth_phase, 5)
				if offset not in ([2] if difficulty < 4 else [2, 3]):
					_challenge_surface(x, CHALLENGE_BASE_Y - (1 if offset == 4 else 0), "obsidian")
		5:
			# Eight empty cells are wider than a normal jump. The supplied ice is enough
			# for spaced stepping stones, but the player freely chooses their positions
			# and can spend any additional inventory while the warm biome melts the route.
			_challenge_surface(left, CHALLENGE_BASE_Y, "cobblestone")
			_challenge_surface(right, CHALLENGE_BASE_Y, "cobblestone")
		6:
			# A contained eight-cell lava pool cannot be jumped. The supplied cobblestone
			# can form spaced stepping stones, while extra inventory remains fully usable.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y + 1, "obsidian")
			_challenge_surface(left, CHALLENGE_BASE_Y, "obsidian")
			_challenge_surface(right, CHALLENGE_BASE_Y, "obsidian")
			for x in range(left + 1, right):
				_set_generated_block(x, CHALLENGE_BASE_Y, "lava", 0)
		7:
			# Climb a mature trunk, cross its crown, then descend on the far trunk.
			_challenge_surface(left, CHALLENGE_BASE_Y, "wood")
			for y in range(CHALLENGE_BASE_Y - 4, CHALLENGE_BASE_Y):
				_challenge_surface(left + 1, y, "wood")
			for x in range(left + 1, right - 1):
				_challenge_surface(x, CHALLENGE_BASE_Y - 5, "leaves")
			for y in range(CHALLENGE_BASE_Y - 4, CHALLENGE_BASE_Y):
				_challenge_surface(right - 1, y, "wood")
			_challenge_surface(right - 1, CHALLENGE_BASE_Y, "wood")
			_challenge_surface(right, CHALLENGE_BASE_Y, "wood")
		8:
			# Three offset tree crowns form a vertical canopy-jumping route.
			_challenge_surface(left, CHALLENGE_BASE_Y, "pine_wood")
			for y in range(CHALLENGE_BASE_Y - 3, CHALLENGE_BASE_Y):
				_challenge_surface(left + 1, y, "pine_wood")
			for x in range(left + 1, left + 4):
				_challenge_surface(x, CHALLENGE_BASE_Y - 4, "pine_needles")
			for y in range(CHALLENGE_BASE_Y - 2, CHALLENGE_BASE_Y):
				_challenge_surface(left + 5, y, "wood")
			for x in range(left + 5, left + 7):
				_challenge_surface(x, CHALLENGE_BASE_Y - 3, "leaves")
			_challenge_surface(right - 1, CHALLENGE_BASE_Y - 1, "wood")
			for x in range(right - 2, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y - 2, "leaves")
		9:
			# A fragile ice staircase rises two blocks and drops back to the checkpoint.
			var reverse := _challenge_random(chunk_x, "ice-stair-direction") < 0.5
			for x in range(left, right + 1):
				var offset := x - left
				if reverse:
					offset = right - x
				var height := mini(mini(offset, right - left - offset), 2)
				if offset % 4 != 2:
					_challenge_surface(x, CHALLENGE_BASE_Y - height, "ice")
		10:
			# Sparse single-width ice floes disappear one by one in the warm biome.
			for offset in [0, 1, 3, 5, 6, 8, 9]:
				var height := 1 if offset in [3, 6] else 0
				_challenge_surface(left + offset, CHALLENGE_BASE_Y - height, "ice")
		11:
			# Taller obsidian teeth keep the hard visual language but change the rhythm.
			for offset in range(0, right - left + 1):
				if offset % 4 == 2:
					continue
				var height := 2 if offset % 4 == 3 else (1 if offset % 4 == 1 else 0)
				_challenge_surface(left + offset, CHALLENGE_BASE_Y - height, "obsidian")
		12:
			# Sand initially looks solid, but its ice supports melt near the player and
			# granular physics drops the route away behind them.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y, "sand")
				_challenge_surface(x, CHALLENGE_BASE_Y + 1, "ice")
		13:
			# Packed ice preserves the runway while ordinary ice gaps melt; obsidian
			# hurdles force jumps without giving up slippery momentum.
			for x in range(left, right + 1):
				var offset := x - left
				_challenge_surface(x, CHALLENGE_BASE_Y, "ice" if offset in [2, 6] else "packed_ice")
				if offset in [3, 7]:
					_challenge_surface(x, CHALLENGE_BASE_Y - 1, "obsidian")
		14:
			# A deep contained water lane replaces precision jumps with swimming control.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y + 2, "stone")
				_set_generated_block(x, CHALLENGE_BASE_Y + 1, "water", 0)
				_set_generated_block(x, CHALLENGE_BASE_Y, "water", 0)
			_challenge_surface(left, CHALLENGE_BASE_Y, "stone")
			_challenge_surface(right, CHALLENGE_BASE_Y, "stone")
		15:
			# Lava stepping stones are jumpable without supplies but punish poor timing.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y + 1, "obsidian")
				_set_generated_block(x, CHALLENGE_BASE_Y, "lava", 0)
			for offset in [0, 2, 5, 8, 9]:
				_challenge_surface(left + offset, CHALLENGE_BASE_Y, "obsidian")
		16:
			# Climb a pine onto a melting ice canopy and escape down the second trunk.
			_challenge_surface(left, CHALLENGE_BASE_Y, "pine_needles")
			for y in range(CHALLENGE_BASE_Y - 3, CHALLENGE_BASE_Y):
				_challenge_surface(left + 1, y, "pine_wood")
			for x in range(left + 1, right - 1):
				_challenge_surface(x, CHALLENGE_BASE_Y - 4, "ice")
			for y in range(CHALLENGE_BASE_Y - 3, CHALLENGE_BASE_Y):
				_challenge_surface(right - 1, y, "pine_wood")
			_challenge_surface(right - 1, CHALLENGE_BASE_Y, "pine_needles")
			_challenge_surface(right, CHALLENGE_BASE_Y, "pine_needles")
		17:
			# Suspended wooden beams produce a quick ascending and descending sequence.
			for offset in range(0, right - left + 1):
				if offset % 2 == 1:
					continue
				var height := mini(mini(int(offset / 2), int((right - left - offset) / 2)), 2)
				_challenge_surface(left + offset, CHALLENGE_BASE_Y - height, "wood")
		18:
			# Two climbable towers require switching sides in mid-air.
			_challenge_surface(left, CHALLENGE_BASE_Y, "wood")
			_challenge_surface(left + 1, CHALLENGE_BASE_Y, "wood")
			for y in range(CHALLENGE_BASE_Y - 4, CHALLENGE_BASE_Y):
				_challenge_surface(left + 2, y, "wood")
			for x in range(left + 1, left + 4):
				_challenge_surface(x, CHALLENGE_BASE_Y - 5, "leaves")
			for y in range(CHALLENGE_BASE_Y - 3, CHALLENGE_BASE_Y):
				_challenge_surface(right - 2, y, "pine_wood")
			for x in range(right - 3, right):
				_challenge_surface(x, CHALLENGE_BASE_Y - 4, "pine_needles")
			_challenge_surface(right, CHALLENGE_BASE_Y, "wood")
		19:
			# Precision finale: isolated obsidian blocks alternate height and spacing.
			for offset in [0, 2, 4, 7, 9]:
				var height := 1 if offset in [2, 7] else (2 if offset == 4 else 0)
				_challenge_surface(left + offset, CHALLENGE_BASE_Y - height, "obsidian")
		20, 21:
			# A glass-sided granular hopper supports the running surface. Its single
			# center outlet starts draining only when the player reaches this section.
			var granular_name := "sand" if pattern == 20 else "gravel"
			for row in range(0, 5):
				for x in range(left + row, right - row + 1):
					_challenge_surface(x, CHALLENGE_BASE_Y + row, granular_name)
				if row > 0:
					_challenge_surface(left + row - 1, CHALLENGE_BASE_Y + row, "glass")
					_challenge_surface(right - row + 1, CHALLENGE_BASE_Y + row, "glass")
			# One side of the two-block tip is permanent glass. A single ice plug seals
			# the outlet until nearby climate simulation melts it into source water.
			_challenge_surface(left + 4, CHALLENGE_BASE_Y + 5, "glass")
			_challenge_surface(left + 5, CHALLENGE_BASE_Y + 5, "ice")
			# The chute below the plug stays open. A floor or lava reservoir would catch
			# falling grains and eventually turn the timed obstacle into a solid plug.
		22:
			# The entire ten-cell span is empty. The entrance chest contains exactly
			# ten falling sand blocks: each can briefly carry the player, but granular
			# physics pulls it into the abyss and prevents a permanent flat bridge.
			pass
		23:
			# A low, solid cave tunnel introduces hostile ground creatures without an
			# environmental hazard competing for the player's attention.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y, "stone")
				_challenge_surface(x, CHALLENGE_BASE_Y - 6, "stone")
			for x in [left + 2, left + 6]:
				_challenge_surface(x, CHALLENGE_BASE_Y - 5, "stone")
		24:
			# A roofed lava gallery alternates obsidian stepping stones over a contained
			# pool while a Gloomwing pressures the player from the open air above it.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y + 1, "obsidian")
				_set_generated_block(x, CHALLENGE_BASE_Y, "lava", 0)
				_challenge_surface(x, CHALLENGE_BASE_Y - 7, "stone")
			for offset in [0, 2, 5, 8, 9]:
				_challenge_surface(left + offset, CHALLENGE_BASE_Y, "obsidian")
		25:
			# Jagged cave islands cross a true abyss. The high ceiling leaves enough
			# room to read both the jumps and the attacking flying creature.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y - 7, "stone")
			for offset in [0, 1, 3, 5, 7, 9]:
				var height := 1 if offset in [3, 7] else 0
				_challenge_surface(left + offset, CHALLENGE_BASE_Y - height, "cobblestone")
		26:
			# Mixed combat cave: uneven stone ground, a shallow central gap, stalactites,
			# and both a crawler and a flier demand attention on different axes.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y - 7, "stone")
				var offset := x - left
				if offset not in [4, 5]:
					_challenge_surface(x, CHALLENGE_BASE_Y - (1 if offset in [2, 7] else 0), "stone")
			for x in [left + 1, left + 6, left + 9]:
				_challenge_surface(x, CHALLENGE_BASE_Y - 6, "stone")
		27:
			# A full wooden bridge spans a sealed volcanic channel. The lava is inserted
			# only when the runner enters, so normal fire simulation becomes a fair timer
			# instead of consuming the obstacle while it is still off-screen.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y, "wood")
				_challenge_surface(x, CHALLENGE_BASE_Y + 2, "obsidian")
			_challenge_surface(left, CHALLENGE_BASE_Y + 1, "obsidian")
			_challenge_surface(right, CHALLENGE_BASE_Y + 1, "obsidian")
		28:
			# A ten-cell construction abyss sits below three volcanic ceiling nozzles.
			# Their lava is activated on entry, forcing simultaneous building and forward
			# movement instead of letting the off-screen fluid solve the timer early.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y - 8, "stone")
			for local_x in [6, 9, 12]:
				_challenge_surface(start_x + local_x - 1, CHALLENGE_BASE_Y - 7, "obsidian")
				_challenge_surface(start_x + local_x + 1, CHALLENGE_BASE_Y - 7, "obsidian")
		29:
			# Sparse top ledges cross a deep monster pit. Falling puts the player beside
			# two activated attackers. Obsidian walls prevent escaping by tree climbing.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y + 5, "stone")
			for y in range(CHALLENGE_BASE_Y, CHALLENGE_BASE_Y + 5):
				_challenge_surface(left, y, "obsidian")
				_challenge_surface(right, y, "obsidian")
			for x in [left + 3, left + 6]:
				_challenge_surface(x, CHALLENGE_BASE_Y, "cobblestone")
		30:
			# A complete wooden bridge keeps the route initially safe while three dormant
			# ceiling nozzles hang fourteen cells above it. The center chest is a deliberate temptation:
			# stopping for its existing crystal pickaxe gives the falling lava time to
			# ignite the bridge behind and ahead of the runner.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y, "wood")
				_challenge_surface(x, CHALLENGE_BASE_Y - 15, "stone")
			for local_x in [6, 9, 12]:
				_challenge_surface(start_x + local_x - 1, CHALLENGE_BASE_Y - 14, "obsidian")
				_challenge_surface(start_x + local_x + 1, CHALLENGE_BASE_Y - 14, "obsidian")
			_place_challenge_supply_chest(
				Vector2i(start_x + 9, CHALLENGE_BASE_Y - 1),
				"crystal_pickaxe",
				1,
				chunk_x,
			)
		31:
			# A stone-roofed cage sits directly on the route. Each stone side wall ends
			# in a one-block sand gate resting on ordinary melting ice above open air.
			# A single sand block cannot slump sideways because the stone route supports
			# both diagonals; once its ice melts, normal granular physics drops it and
			# opens a one-tile exit large enough for the six aggressive fliers.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y, "stone")
			for x in range(start_x + 6, start_x + 12):
				_challenge_surface(x, CHALLENGE_BASE_Y - 6, "stone")
			for local_x in [6, 11]:
				for y in range(CHALLENGE_BASE_Y - 5, CHALLENGE_BASE_Y - 1):
					_challenge_surface(start_x + local_x, y, "stone")
				_challenge_surface(start_x + local_x, CHALLENGE_BASE_Y - 1, "sand")
				_challenge_surface(start_x + local_x, CHALLENGE_BASE_Y, "ice")
		32:
			# One Packed Ice block crystallizes the exposed surface of the connected
			# Glass-Tide pool into a Tideglass bridge. The left pedestal provides a
			# legal placement anchor without putting the seed in the player's path.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y + 2, "glass_tide_silt")
			_challenge_surface(left, CHALLENGE_BASE_Y + 1, "glass_tide_silt")
			_challenge_surface(right, CHALLENGE_BASE_Y, "resonance_bricks")
			_challenge_surface(right, CHALLENGE_BASE_Y + 1, "resonance_bricks")
			for x in range(left + 1, right):
				_set_generated_block(x, CHALLENGE_BASE_Y, "glass_tide", 0)
				_set_generated_block(x, CHALLENGE_BASE_Y + 1, "glass_tide", 0)
		33:
			# The worksite is a breather section: the route is always traversable,
			# while an authored Wanderer visibly mines Lodestone and expands its
			# walk-through Scaffold around the runner.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y, "resonance_bricks")
			for local_x in [7, 11, 12]:
				_challenge_surface(start_x + local_x, CHALLENGE_BASE_Y - 1, "magnetic_stone")
		34:
			# Scaffold partitions look sealed but are traversable. Two Raiders turn
			# recognition of that material into the fastest escape through Lockworks.
			for x in range(left, right + 1):
				_challenge_surface(x, CHALLENGE_BASE_Y, "resonance_bricks")
			for local_x in [7, 10, 12]:
				for y in range(CHALLENGE_BASE_Y - 4, CHALLENGE_BASE_Y):
					_challenge_surface(start_x + local_x, y, "shagot_scaffold")
	generated_chunks[chunk_x] = {
		"catalog_revision": catalog_revision,
		"structure_catalog_revision": structure_catalog_revision,
		"selected_content_ids": [],
		"selected_structure_ids": [],
		"placed_structures": [],
		"builtin_structure": false,
		"builtin_structure_id": "",
		"biome_id": biome_id,
		"biome_catalog_revision": biome_catalog_revision,
		"challenge_pattern": pattern,
		"challenge_encounter": _challenge_encounter_for_pattern(pattern),
		"challenge_encounter_activated": false,
	}


func _one_block_phase_index_for_mined(mined: int) -> int:
	for index in ONE_BLOCK_PHASES.size():
		if mined < int(ONE_BLOCK_PHASES[index].get("end", 0)):
			return index
	return ONE_BLOCK_PHASES.size()


func one_block_phase_number() -> int:
	return one_block_phase + 1


func one_block_phase_end() -> int:
	if one_block_phase >= ONE_BLOCK_PHASES.size():
		return one_block_mined
	return int(ONE_BLOCK_PHASES[one_block_phase].get("end", one_block_mined))


func _one_block_random(channel: String) -> float:
	return _structure_random("one-block:%d:%s" % [one_block_mined, channel])


func _one_block_name_for_content_id(content_id: String) -> String:
	var block_name := BlockDefs.name_for_content_id(content_id)
	return block_name if not block_name.is_empty() and BlockDefs.BLOCKS.has(block_name) else ""


func _one_block_source_phase() -> int:
	if one_block_phase < ONE_BLOCK_PHASES.size():
		if one_block_phase > 0 and _one_block_random("previous-phase") < 0.14:
			return int(_one_block_random("previous-phase-index") * float(one_block_phase)) % one_block_phase
		return one_block_phase
	return int(_one_block_random("after-phase-index") * float(ONE_BLOCK_PHASES.size())) % ONE_BLOCK_PHASES.size()


func _one_block_generated_afterphase_name() -> String:
	if one_block_phase < ONE_BLOCK_PHASES.size() or _one_block_random("generated-block") >= 0.12:
		return ""
	var candidates: Array[String] = []
	for raw_content_id in world_definition_ids.keys():
		var block_name := _one_block_name_for_content_id(str(raw_content_id))
		var block: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
		if block.get("solid", false) and not block.get("fluid", false) and not block.get("container", false) and not block.get("falls_when_unsupported", false):
			candidates.append(block_name)
	candidates.sort()
	if candidates.is_empty():
		return ""
	return candidates[int(_one_block_random("generated-block-index") * float(candidates.size())) % candidates.size()]


func _one_block_next_block_name() -> String:
	var generated_name := _one_block_generated_afterphase_name()
	if not generated_name.is_empty():
		return generated_name
	var phase_data: Dictionary = ONE_BLOCK_PHASES[_one_block_source_phase()]
	var weights: Dictionary = phase_data.get("blocks", {}) if phase_data.get("blocks", {}) is Dictionary else {}
	var total_weight := 0
	for raw_weight in weights.values():
		total_weight += maxi(0, int(raw_weight))
	if total_weight <= 0:
		return "stone"
	var roll := int(_one_block_random("block") * float(total_weight))
	for raw_content_id in weights:
		roll -= maxi(0, int(weights[raw_content_id]))
		if roll < 0:
			var block_name := _one_block_name_for_content_id(str(raw_content_id))
			if not block_name.is_empty():
				return block_name
	return "stone"


func _one_block_chest_contents(phase_index: int, gift: bool) -> Dictionary:
	var source_index := mini(phase_index, ONE_BLOCK_PHASES.size() - 1)
	var phase_data: Dictionary = ONE_BLOCK_PHASES[source_index]
	var contents: Dictionary = {}
	if gift:
		var gift_table: Dictionary = phase_data.get("gift", {}) if phase_data.get("gift", {}) is Dictionary else {}
		for raw_content_id in gift_table:
			var block_name := _one_block_name_for_content_id(str(raw_content_id))
			if not block_name.is_empty():
				contents[block_name] = maxi(1, int(gift_table[raw_content_id]))
		return contents
	var loot: Array = phase_data.get("loot", []) if phase_data.get("loot", []) is Array else []
	if loot.is_empty():
		return contents
	var rolls := 1 + int(_one_block_random("chest-rolls") * 3.0)
	for roll_index in rolls:
		var loot_index := int(_one_block_random("chest-kind:%d" % roll_index) * float(loot.size())) % loot.size()
		var block_name := _one_block_name_for_content_id(str(loot[loot_index]))
		if block_name.is_empty():
			continue
		var amount := 1 + int(_one_block_random("chest-count:%d" % roll_index) * 3.0)
		if BlockDefs.BLOCKS[block_name].get("item", false) or BlockDefs.BLOCKS[block_name].get("plant", false) or BlockDefs.BLOCKS[block_name].get("fluid", false):
			amount = 1
		contents[block_name] = int(contents.get(block_name, 0)) + amount
	return contents


func _one_block_try_spawn_creature(phase_index: int) -> void:
	var source_index := mini(phase_index, ONE_BLOCK_PHASES.size() - 1)
	var creature_ids: Array = ONE_BLOCK_PHASES[source_index].get("creatures", []) if ONE_BLOCK_PHASES[source_index].get("creatures", []) is Array else []
	if creature_ids.is_empty():
		return
	var creature_index := int(_one_block_random("creature-kind") * float(creature_ids.size())) % creature_ids.size()
	var creature_name := _one_block_name_for_content_id(str(creature_ids[creature_index]))
	if creature_name.is_empty():
		return
	spawn_creature(creature_name, Vector2(one_block_position) + Vector2(0.5, -0.5))


func _spawn_next_one_block(force_gift: bool = false) -> void:
	if world_mode != WORLD_MODE_ONE_BLOCK or block_id(one_block_position.x, one_block_position.y) != 0:
		return
	var event_roll := _one_block_random("event")
	var chest_event := force_gift or (one_block_mined > 10 and event_roll < 0.06)
	if chest_event:
		set_block(one_block_position.x, one_block_position.y, int(BlockDefs.BLOCKS.chest.id))
		containers[one_block_position] = {
			"contents": _one_block_chest_contents(one_block_phase, force_gift),
			"durability": {},
			"loot_generated": true,
			"loot_key": "one-block:%d" % one_block_mined,
			"loot_tier": "gift" if force_gift else "phase",
		}
		return
	var block_name := _one_block_next_block_name()
	set_block(one_block_position.x, one_block_position.y, int(BlockDefs.BLOCKS.get(block_name, BlockDefs.BLOCKS.stone).id))
	if one_block_mined > 10 and event_roll >= 0.06 and event_roll < 0.10:
		_one_block_try_spawn_creature(one_block_phase)


func _advance_one_block() -> void:
	one_block_mined += 1
	var next_phase := _one_block_phase_index_for_mined(one_block_mined)
	var phase_changed := next_phase != one_block_phase
	one_block_phase = next_phase
	_spawn_next_one_block(phase_changed)
	if phase_changed:
		one_block_phase_changed.emit(one_block_phase_number())
	state_changed.emit()


func _ensure_one_block() -> void:
	if world_mode == WORLD_MODE_ONE_BLOCK and block_id(one_block_position.x, one_block_position.y) == 0:
		_spawn_next_one_block(false)


func ingest_catalog(definitions: Array, revision: int) -> int:
	var registered := 0
	for raw_definition in definitions:
		if not raw_definition is Dictionary:
			continue
		var definition := raw_definition as Dictionary
		if BlockDefs.register_generated_block(definition) == "":
			continue
		_remember_world_definition(definition)
		registered += 1
		catalog_revision = maxi(catalog_revision, int(definition.get("catalog_revision", 0)))
	catalog_revision = maxi(catalog_revision, revision)
	if registered > 0:
		state_changed.emit()
	return registered


func _remember_world_definition(definition: Dictionary) -> void:
	var content_id := str(definition.get("content_id", ""))
	if not content_id.is_empty() and not content_id.begins_with("core."):
		world_definition_ids[content_id] = true


func ingest_structure_catalog(definitions: Array, revision: int) -> int:
	var registered := 0
	for raw_definition in definitions:
		if not raw_definition is Dictionary:
			continue
		var definition := raw_definition as Dictionary
		var structure_id := str(definition.get("structure_id", ""))
		var size: Dictionary = definition.get("size", {}) if definition.get("size", {}) is Dictionary else {}
		var blocks: Array = definition.get("blocks", []) if definition.get("blocks", []) is Array else []
		var width := int(size.get("width", 0))
		var height := int(size.get("height", 0))
		var raw_placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
		var layer := str(raw_placement.get("layer", "surface"))
		if layer not in ["surface", RESONANT_LAYER_ID] or structure_id.is_empty() or width < 3 or width > 12 or height < 2 or height > 10 or blocks.size() < 3 or blocks.size() > 96:
			continue
		var valid := true
		var occupied: Dictionary = {}
		for raw_block in blocks:
			if not raw_block is Dictionary:
				valid = false
				break
			var block := raw_block as Dictionary
			var x := int(block.get("x", -1))
			var y := int(block.get("y", -1))
			var content_id := str(block.get("content_id", ""))
			var key := Vector2i(x, y)
			var block_name := BlockDefs.name_for_content_id(content_id)
			var block_entry: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
			if x < 0 or x >= width or y < 0 or y >= height or content_id.is_empty() or occupied.has(key) or not block_entry.get("solid", false) or block_entry.get("container", false):
				valid = false
				break
			occupied[key] = true
		var block_cells := occupied.duplicate()
		var chests: Array = definition.get("chests", []) if definition.get("chests", []) is Array else []
		var plants: Array = definition.get("plants", []) if definition.get("plants", []) is Array else []
		var sanitized_chests: Array[Dictionary] = []
		for raw_chest in chests:
			if sanitized_chests.size() >= 1:
				break
			if not raw_chest is Dictionary:
				continue
			var chest: Dictionary = raw_chest
			var pos := Vector2i(int(chest.get("x", -1)), int(chest.get("y", -1)))
			if pos.x < 0 or pos.x >= width or pos.y < 0 or pos.y >= height or occupied.has(pos) or (pos.y < height - 1 and not block_cells.has(pos + Vector2i.DOWN)):
				continue
			occupied[pos] = true
			sanitized_chests.append({"x": pos.x, "y": pos.y})
		var sanitized_plants: Array[Dictionary] = []
		for raw_plant in plants:
			if sanitized_plants.size() >= 3:
				break
			if not raw_plant is Dictionary:
				continue
			var plant: Dictionary = raw_plant
			var pos := Vector2i(int(plant.get("x", -1)), int(plant.get("y", -1)))
			var plant_content_id := str(plant.get("content_id", ""))
			var plant_name := BlockDefs.name_for_content_id(plant_content_id)
			var plant_definition := _plant_definition(plant_name)
			var form := str(plant_definition.get("growth", {}).get("form", ""))
			if pos.x < 0 or pos.x >= width or pos.y < 0 or pos.y >= height or occupied.has(pos) or plant_content_id not in STRUCTURE_DECOR_PLANT_IDS or form not in ["decorative", "potted"] or (pos.y < height - 1 and not block_cells.has(pos + Vector2i.DOWN)):
				continue
			var clearance_top := pos.y - 1 if plant_content_id == "core.plant.potted_fern" else 0
			var clear := true
			for y in range(maxi(0, clearance_top), pos.y):
				if occupied.has(Vector2i(pos.x, y)):
					clear = false
					break
			if not clear:
				continue
			occupied[pos] = true
			sanitized_plants.append({"x": pos.x, "y": pos.y, "content_id": plant_content_id})
		if not valid:
			continue
		var sanitized_definition := definition.duplicate(true)
		var sanitized_placement: Dictionary = raw_placement.duplicate(true)
		sanitized_placement["layer"] = layer
		sanitized_definition["placement"] = sanitized_placement
		sanitized_definition["chests"] = sanitized_chests
		sanitized_definition["plants"] = sanitized_plants
		structure_definitions[structure_id] = sanitized_definition
		structure_catalog_revision = maxi(structure_catalog_revision, int(definition.get("catalog_revision", 0)))
		registered += 1
	structure_catalog_revision = maxi(structure_catalog_revision, revision)
	return registered


func player_catalog_region() -> int:
	var player_tile_x := floori(float(player["x"]) / float(BlockDefs.TILE))
	var chunk_x := floori(float(player_tile_x) / float(CHUNK_WIDTH))
	return floori(float(chunk_x) / float(CONTENT_REGION_CHUNKS))


func catalog_region_biomes(region_x: int) -> Array[String]:
	var biomes: Array[String] = []
	var first_chunk := region_x * CONTENT_REGION_CHUNKS
	for chunk_x in range(first_chunk, first_chunk + CONTENT_REGION_CHUNKS):
		var biome := _biome_at(chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2)
		if not biomes.has(biome):
			biomes.append(biome)
	biomes.sort()
	return biomes


func ingest_biome_catalog(definitions: Array, revision: int) -> int:
	var registered := 0
	for raw_definition in definitions:
		if not raw_definition is Dictionary:
			continue
		var definition := raw_definition as Dictionary
		var biome_id := str(definition.get("biome_id", ""))
		var terrain: Dictionary = definition.get("terrain", {}) if definition.get("terrain", {}) is Dictionary else {}
		var ecology: Dictionary = definition.get("ecology", {}) if definition.get("ecology", {}) is Dictionary else {}
		var placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
		var layer := str(placement.get("layer", "surface"))
		var content_ids: Array[String] = [
			str(terrain.get("surface_content_id", "")),
			str(terrain.get("subsurface_content_id", "")),
			str(terrain.get("deep_content_id", "")),
		]
		if terrain.get("fluid_content_id") != null:
			content_ids.append(str(terrain.get("fluid_content_id", "")))
		for raw_id in (ecology.get("plant_content_ids", []) as Array):
			content_ids.append(str(raw_id))
		for raw_id in (ecology.get("creature_content_ids", []) as Array):
			content_ids.append(str(raw_id))
		var valid := (
			biome_id.begins_with("gen.biome.")
			and str(definition.get("kind", "")) == "biome"
			and str(definition.get("schema_version", "")) == "1.0"
			and int(definition.get("catalog_revision", 0)) > 0
			and float(placement.get("introduction_chance", 0.0)) > 0.0
			and int(placement.get("maximum_chunks_per_region", 0)) > 0
			and layer in ["surface", RESONANT_LAYER_ID]
		)
		for content_id in content_ids:
			if content_id.is_empty() or (not content_id.begins_with(CORE_CONTENT_PREFIX) and not BlockDefs.generated_definitions.has(content_id)):
				valid = false
				break
		if not valid:
			continue
		var sanitized_definition := definition.duplicate(true)
		var sanitized_placement: Dictionary = placement.duplicate(true)
		sanitized_placement["layer"] = layer
		sanitized_definition["placement"] = sanitized_placement
		biome_definitions[biome_id] = sanitized_definition
		biome_catalog_revision = maxi(biome_catalog_revision, int(definition.get("catalog_revision", 0)))
		registered += 1
	biome_catalog_revision = maxi(biome_catalog_revision, revision)
	return registered


func has_regional_catalog(region_x: int) -> bool:
	return regional_catalogs.has(region_x)


func ingest_regional_catalog(
	region_x: int,
	definitions: Array,
	structures: Array,
	content_ids: Array,
	structure_ids: Array,
	biomes: Array,
	biome_ids: Array,
	content_revision: int,
	structures_revision: int,
	biomes_revision: int
) -> int:
	var registered := ingest_catalog(definitions, content_revision)
	registered += ingest_structure_catalog(structures, structures_revision)
	registered += ingest_biome_catalog(biomes, biomes_revision)
	var available_content: Array[String] = []
	for raw_content_id in content_ids:
		var content_id := str(raw_content_id)
		if not content_id.is_empty() and BlockDefs.generated_definitions.has(content_id):
			available_content.append(content_id)
	var available_structures: Array[String] = []
	for raw_structure_id in structure_ids:
		var structure_id := str(raw_structure_id)
		if not structure_id.is_empty() and structure_definitions.has(structure_id):
			available_structures.append(structure_id)
	var available_biomes: Array[String] = []
	for raw_biome_id in biome_ids:
		var biome_id := str(raw_biome_id)
		if biome_id.begins_with("gen.biome.") and biome_definitions.has(biome_id):
			available_biomes.append(biome_id)
	regional_catalogs[region_x] = {
		"content_ids": available_content,
		"structure_ids": available_structures,
		"biome_ids": available_biomes,
		"content_revision": maxi(0, content_revision),
		"structure_revision": maxi(0, structures_revision),
		"biome_revision": maxi(0, biomes_revision),
	}
	static_tiles_changed.emit()
	lighting_changed.emit()
	state_changed.emit()
	return registered


func _latest_registered_catalog_revision() -> int:
	var revision := 0
	for raw_definition in BlockDefs.generated_definitions.values():
		if raw_definition is Dictionary:
			revision = maxi(revision, int((raw_definition as Dictionary).get("catalog_revision", 0)))
	return revision


func _core_tree_block_definition(content_id: String, name: String, description: String, pattern: String, palette: Array, tags: Array, hardness: float, flammability: float) -> Dictionary:
	return {
		"content_id": content_id, "definition_hash": "system", "schema_version": "1.3", "ruleset_version": "system", "kind": "block", "catalog_revision": 0,
		"display": {"name": {"en": name}, "description": {"en": description}},
		"visual": {"pattern": pattern, "palette": palette},
		"material": {"phase": "solid", "hardness": hardness, "viscosity": 0.0, "elasticity": 0.08, "flammability": flammability, "temperature": 0.0},
		"surface": {"movement_speed_multiplier": 0.82 if "foliage" in tags else 1.0, "friction": 0.78, "bounce": 0.05},
		"physics": {"falls_when_unsupported": false, "settles_diagonally": false},
		"origin": {"type": "natural", "categories": ["flora"]},
		"tags": ["organic", "plant", "natural"] + tags,
		"components": {"solid": true}, "mechanics": [], "balance": {"hardness": hardness * 24.0}, "provenance": {"type": "system"},
	}


func _ensure_core_tree_blocks() -> void:
	for definition in [
		_core_tree_block_definition("core.palm_wood", "Palm Wood", "Warm fibrous trunk wood marked by pale horizontal bands.", "stripes", ["#a96935", "#d69a51", "#744222", "#edbd70"], ["wood", "trunk", "palm"], 0.42, 0.82),
		_core_tree_block_definition("core.palm_leaves", "Palm Fronds", "Broad sunlit fronds from the crown of a palm.", "organic", ["#4f8f32", "#86c44a", "#2e641f", "#b5dc62"], ["leaves", "foliage", "palm"], 0.14, 0.95),
		_core_tree_block_definition("core.pine_wood", "Pine Wood", "Reddish resinous timber with dense layered rings.", "layers", ["#754326", "#a96735", "#4c2c1b", "#cf8b49"], ["wood", "trunk", "pine"], 0.5, 0.88),
		_core_tree_block_definition("core.pine_needles", "Pine Needles", "Dense blue-green evergreen needles.", "scales", ["#214f3c", "#39785a", "#143329", "#65a478"], ["leaves", "foliage", "needles", "pine"], 0.18, 0.82),
		_core_tree_block_definition("core.weeping_wood", "Weeping Wood", "Cool gray-brown wood traced by winding grain.", "veins", ["#665548", "#8b7764", "#40372f", "#aa9580"], ["wood", "trunk", "weeping"], 0.44, 0.86),
		_core_tree_block_definition("core.weeping_leaves", "Weeping Leaves", "Long soft foliage that hangs in cool green curtains.", "organic", ["#28715a", "#4fa27a", "#17493b", "#7cc79c"], ["leaves", "foliage", "weeping"], 0.13, 0.96),
	]:
		BlockDefs.register_generated_block(definition)


func _core_plant_definition(content_id: String, name: String, description: String, form: String, canopy: String, palette: Array, substrate_tags: Array, tags: Array) -> Dictionary:
	var hanging := form == "hanging"
	return {
		"content_id": content_id, "kind": "plant", "schema_version": "1.0", "catalog_revision": 0,
		"display": {"name": {"en": name}, "description": {"en": description}},
		"visual": {"pattern": "organic", "palette": palette, "stem_shape": "segmented", "canopy_shape": canopy},
		"planting": {
			"allowed_substrate_tags": substrate_tags,
			"anchor_faces": ["ceiling"] if hanging else ["floor"],
			"required_medium": "air", "required_fluid": "none", "fluid_relation": "none", "requires_open_to_sky": not hanging,
		},
		"growth": {
			"form": form,
			"stage_count": 4 if hanging else 1,
			"ticks_per_stage": [180, 220, 260] if hanging else [],
			"maximum_length_blocks": 4 if hanging else 1,
			"spread_chance": 0.0,
		},
		"hybridization": {"group": "native_flora", "active_nearby_seconds": 600, "cooldown_seconds": 1800, "hybrid_chance": 0.03, "accepts_creature_traits": true},
		"harvest": {"yield_min": 1, "yield_max": 1, "regrows": false},
		"tags": ["plant", "living", "native"] + tags,
		"mechanics": ["grows"] if hanging else [],
	}


func _core_tree_definition(content_id: String, name: String, description: String, shape: String, substrate_tags: Array, tags: Array) -> Dictionary:
	var definition := _core_plant_definition(content_id, name, description, "tree", "broad", ["#4f7f32", "#8fc64a", "#6b4423"], substrate_tags, ["tree", shape] + tags)
	var sapling_visuals := {
		"oak": {"pattern": "organic", "palette": ["#3d7f3d", "#78b84c", "#6b4423"]},
		"palm": {"pattern": "cells", "palette": ["#5f9638", "#a8cf52", "#bd7a3d"]},
		"pine": {"pattern": "crystals", "palette": ["#214f3c", "#4c8a62", "#754326"]},
		"weeping": {"pattern": "veins", "palette": ["#28715a", "#66ad83", "#665548"]},
	}
	definition["visual"].merge(sapling_visuals.get(shape, sapling_visuals["oak"]), true)
	definition["growth"] = {"form": "tree", "stage_count": 2, "ticks_per_stage": [120], "maximum_length_blocks": 8, "spread_chance": 0.0}
	var components_by_shape: Dictionary = {
		"oak": ["core.wood", "core.leaves"],
		"palm": ["core.palm_wood", "core.palm_leaves"],
		"pine": ["core.pine_wood", "core.pine_needles"],
		"weeping": ["core.weeping_wood", "core.weeping_leaves"],
	}
	var components: Array = components_by_shape.get(shape, ["core.wood", "core.leaves"])
	definition["tree_components"] = {"trunk_content_id": components[0], "foliage_content_id": components[1], "shape": shape}
	definition["propagation"] = {"source_content_ids": [components[0], components[1]]}
	definition["hybridization"]["group"] = "system_trees"
	definition["mechanics"] = ["grows", "tree_growth"]
	return definition


func _ensure_core_plants() -> void:
	var potted_fern := _core_plant_definition("core.plant.potted_fern", "Potted Fern", "A hardy fern kept in a warm clay pot for decorating shelters and ruins.", "potted", "tall_planter", ["#347747", "#7fbd58", "#c56d3b"], [], ["decorative", "potted", "indoor", "fern"])
	potted_fern["planting"]["requires_open_to_sky"] = false
	potted_fern["growth"] = {"form": "potted", "stage_count": 2, "ticks_per_stage": [180], "maximum_length_blocks": 2, "spread_chance": 0.0}
	potted_fern["mechanics"] = ["grows"]
	var cave_vines := _core_plant_definition("core.plant.cave_vines", "Cave Vines", "Cool bioluminescent strands that hang from cavern ceilings.", "hanging", "hanging_vines", ["#1d7048", "#71d66b", "#58d9cf"], ["stone"], ["cave_plant", "vine", "dark", "bioluminescent"])
	cave_vines["lighting"] = {"emission": 0.52, "color": "#66d9b2"}
	var luminous_moss := _core_plant_definition("core.plant.luminous_moss", "Luminous Moss", "Soft blue-green moss that grows on damp cavern walls and gently lights the stone around it.", "surface_creeper", "tuft", ["#24594a", "#55c990", "#7de7d5"], ["stone"], ["cave_plant", "moss", "wall", "bioluminescent"])
	luminous_moss["planting"]["anchor_faces"] = ["wall_left", "wall_right"]
	luminous_moss["planting"]["requires_open_to_sky"] = false
	luminous_moss["lighting"] = {"emission": 0.4, "color": "#65d9bd"}
	for definition in [
		_core_plant_definition("core.plant.meadow_bloom", "Meadow Bloom", "A bright wildflower that dots sunny plains with color.", "decorative", "single_bloom", ["#368047", "#76bd4f", "#ef5d72"], ["soil"], ["flower", "meadow", "bright"]),
		_core_plant_definition("core.plant.prairie_sprig", "Prairie Sprig", "A small branching plant that grows between open grassland paths.", "decorative", "branch_bloom", ["#397a42", "#8bc64e", "#f1b84b"], ["soil"], ["flower", "meadow", "prairie"]),
		cave_vines,
		luminous_moss,
		potted_fern,
		_core_tree_definition("core.plant.oak", "Oak", "A sturdy broad-crowned tree common to plains and forests.", "oak", ["grass", "dirt"], ["temperate", "broadleaf"]),
		_core_tree_definition("core.plant.palm", "Palm", "A tall bare-trunked tree crowned with wide tropical fronds.", "palm", ["sand", "soil"], ["tropical", "coastal"]),
		_core_tree_definition("core.plant.pine", "Pine", "A cold-tolerant evergreen with a narrow layered crown.", "pine", ["grass", "dirt"], ["cold", "evergreen"]),
		_core_tree_definition("core.plant.weeping_tree", "Weeping Tree", "A moisture-loving tree whose long foliage hangs toward the ground.", "weeping", ["soil", "grass", "dirt", "sand"], ["wetland", "river"]),
	]:
		BlockDefs.register_generated_block(definition)


func _core_creature_definition(content_id: String, name: String, description: String, locomotion: String, medium: String, aquatic_mode: String, temperament: String, favorite_tags: Array, maximum_light: float, palette: Array, body_shape: String, light_preference: String = "neutral", activity_period: String = "all_day", spawn_rarity: float = -1.0, maximum_nearby: int = -1, eye_color: String = "#151515", extra_tags: Array = [], size: float = 0.78, eye_count: int = 2, morphology_override: Dictionary = {}) -> Dictionary:
	var aggressive := temperament == "aggressive"
	var resolved_rarity := spawn_rarity if spawn_rarity > 0.0 else (0.012 if aggressive else 0.065)
	var resolved_maximum := maximum_nearby if maximum_nearby > 0 else (1 if aggressive else 4)
	var morphology := morphology_override.duplicate(true) if not morphology_override.is_empty() else BlockDefs.legacy_creature_morphology(body_shape)
	return {
		"content_id": content_id, "kind": "creature", "schema_version": "1.0", "catalog_revision": 0,
		"display": {"name": {"en": name}, "description": {"en": description}},
		"visual": {"palette": palette, "pattern": _system_creature_pattern(content_id), "morphology": morphology, "eye_count": clampi(eye_count, 1, 4), "eye_color": eye_color},
		"locomotion": {
			"type": locomotion, "medium": medium, "aquatic_mode": aquatic_mode,
			"speed": 0.0 if locomotion == "stationary" else (0.72 if locomotion != "flying" else 0.9),
			"gravity": locomotion in ["walking", "crawling"],
			"can_jump": locomotion == "walking",
			"jump_power": 0.8 if locomotion == "walking" else 0.0,
		},
		"habitat": {"favorite_plant_tags": favorite_tags, "attraction_radius_blocks": 7, "maximum_light": maximum_light, "light_preference": light_preference},
		"behavior": {"temperament": temperament, "attack_trigger": "always" if aggressive else ("provoked" if temperament == "defensive" else "never"), "flee_trigger": "on_sight" if temperament == "fearful" else ("on_hit" if temperament == "passive" else "never"), "awareness_blocks": 7},
		"predation": {"enabled": aggressive, "prey_tags": ["passive", "fearful"], "detection_radius": 8, "hunt_cooldown_seconds": [60, 180], "prefers_player": false},
		"stats": {"health": 3 if not aggressive else 4, "damage": 1 if aggressive or temperament == "defensive" else 0, "size": size},
		"spawning": {"rarity": resolved_rarity, "maximum_nearby": resolved_maximum, "minimum_player_distance_blocks": 12, "activity_period": "night" if aggressive else activity_period},
		"breeding": {"group": "native_small", "active_nearby_seconds": 600, "cooldown_seconds": 1800, "requires_favorite_plant": not favorite_tags.is_empty(), "hybrid_chance": 0.03},
		"tags": ["creature", "native", medium, locomotion, temperament] + extra_tags, "mechanics": ["predation"] if aggressive else [],
	}


func _system_creature_pattern(content_id: String) -> String:
	var patterns := {
		"core.creature.meadow_hopper": "spots", "core.creature.forest_fox": "patches",
		"core.creature.sky_mote": "gradient", "core.creature.firefly": "glowing", "core.creature.crystal_firefly": "glowing", "core.creature.moss_crawler": "mottled",
		"core.creature.moss_slug": "stripes", "core.creature.pool_drifter": "stripes",
		"core.creature.sand_crab": "spots", "core.creature.snow_penguin": "patches",
		"core.creature.ember_walker": "mottled", "core.creature.cave_skitter": "solid",
		"core.creature.cave_spider": "patches", "core.creature.watcher_bloom": "gradient",
		"core.creature.dusk_prowler": "stripes", "core.creature.gloomwing": "mottled",
		"core.creature.cinder_eel": "gradient",
		"core.creature.prism_moth": "glowing", "core.creature.geode_crawler": "crystals",
		"core.creature.rootback_grazer": "leafy", "core.creature.glasswing_ray": "gradient",
		"core.creature.prism_skitter": "crystals",
	}
	return str(patterns.get(content_id, "mottled"))


func _ensure_core_creatures() -> void:
	for definition in [
		_core_creature_definition("core.creature.meadow_hopper", "Meadow Hopper", "A gentle long-eared meadow quadruped that bounds away after being hurt.", "walking", "air", "none", "passive", ["grass", "plant"], 1.0, ["#8b6b3f", "#c8e85b", "#4f3928"], "round", "bright", "day", 0.065, 4, "#151515", ["hopper", "long_eared", "fur"], 0.72, 2, {"body_plan":"quadruped", "body_shape":"compact", "head_shape":"muzzle", "limbs":{"type":"legs", "count":4, "length":0.78}, "ears":"long", "tail":"short", "covering":"fur", "features":["chest_patch"], "proportions":{"head":0.82, "body":0.95}}),
		_core_creature_definition("core.creature.forest_fox", "Forest Fox", "A quick orange forest wanderer that avoids danger and follows berry-like plants.", "walking", "air", "none", "fearful", ["berry", "flower", "forest_plant"], 1.0, ["#ed742f", "#f7ead2", "#6d3d24"], "fox", "bright", "day", 0.045, 2, "#17141c", ["forest", "fox"], 0.82),
		_core_creature_definition("core.creature.sky_mote", "Sky Mote", "A shy flying creature that drifts through bright open air and flees on sight.", "flying", "air", "none", "fearful", ["flower", "plant"], 1.0, ["#6f86d6", "#e8f4ff"], "winged", "bright", "day"),
		_core_creature_definition("core.creature.firefly", "Firefly", "A tiny bioluminescent flier that wanders through caverns and rises over the surface after sunset.", "flying", "air", "none", "passive", ["cave_plant", "moss", "flower"], 1.0, ["#253b32", "#d9ff69", "#74ef9d"], "winged", "neutral", "night", 0.05, 4, "#f5ffae", ["firefly", "bioluminescent", "night_surface"], 0.46, 1),
		_core_creature_definition("core.creature.crystal_firefly", "Crystal Firefly", "A jewel-winged firefly that gathers above Chorus Brine and flashes in answer to nearby crystals.", "flying", "air", "none", "passive", ["crystal", "river", "root"], 1.0, ["#2c2452", "#74f5df", "#d6b5ff"], "winged", "neutral", "all_day", 0.09, 5, "#f0ffff", ["firefly", "bioluminescent", "crystal", "deep", "chorus"], 0.5, 1),
		_core_creature_definition("core.creature.moss_crawler", "Moss Crawler", "A dark-loving crawler drawn to moss that fights back when attacked.", "crawling", "air", "none", "defensive", ["moss", "plant"], 0.55, ["#395a3a", "#8ac45b"], "crawler", "dark", "night"),
		_core_creature_definition("core.creature.moss_slug", "Moss Slug", "A slow harmless slug that comes out in damp shade and seeks mossy plants.", "crawling", "air", "none", "passive", ["moss", "fungus", "plant"], 0.65, ["#c87932", "#75a84c", "#513827"], "slug", "dark", "night", 0.045, 3, "#151515", ["slug", "damp"], 0.68),
		_core_creature_definition("core.creature.pool_drifter", "Pool Drifter", "A timid blue fish that swims freely through water and flees when danger appears.", "swimming", "water", "free", "fearful", ["water", "kelp", "plant"], 1.0, ["#287db5", "#6179aa", "#8ee8e1"], "fish", "bright", "all_day"),
		_core_creature_definition("core.creature.sand_crab", "Sand Crab", "A small beach crab that scuttles over sand and defends itself with bright claws.", "crawling", "air", "none", "defensive", ["water", "kelp", "beach_plant"], 1.0, ["#e96f2d", "#ffad55", "#8c3f28"], "crab", "bright", "day", 0.055, 3, "#19151a", ["crab", "beach"], 0.68),
		_core_creature_definition("core.creature.snow_penguin", "Snow Penguin", "A friendly cold-weather waddler that stays near ice and open water.", "walking", "air", "none", "passive", ["ice", "water", "cold_plant"], 1.0, ["#1e293b", "#f5f7f5", "#f49b31"], "penguin", "bright", "day", 0.05, 3, "#151515", ["penguin", "cold"], 0.72),
		_core_creature_definition("core.creature.ember_walker", "Ember Walker", "A heatproof creature that walks along lava bottoms and defends itself when attacked.", "walking", "lava", "bottom", "defensive", ["lava", "ember", "plant"], 1.0, ["#6e1d18", "#ff9b2f"], "crawler", "bright", "night"),
		_core_creature_definition("core.creature.cave_skitter", "Cave Skitter", "A black red-eyed cave crawler that prefers deep darkness and fights back when attacked.", "crawling", "air", "none", "defensive", ["moss", "fungus", "cave_plant"], 0.3, ["#101015", "#292632"], "crawler", "dark", "night", 0.025, 2, "#ff3045", ["cave_only"]),
		_core_creature_definition("core.creature.cave_spider", "Cave Spider", "A shy eight-legged hunter that hides among cave vines and defends itself when disturbed.", "crawling", "air", "none", "defensive", ["cave_plant", "vine", "moss"], 0.38, ["#24202b", "#65506f", "#b45363"], "crawler", "dark", "night", 0.035, 2, "#e8d8ff", ["spider", "cave_only"], 0.72, 4, {"body_plan":"crawler", "body_shape":"wide", "head_shape":"round", "limbs":{"type":"legs", "count":8, "length":0.72}, "ears":"none", "tail":"none", "covering":"fur", "features":["claws"], "proportions":{"head":0.72, "body":1.08}}),
		_core_creature_definition("core.creature.watcher_bloom", "Watcher Bloom", "A rooted flower-creature that watches sunny clearings and snaps back when disturbed.", "stationary", "air", "none", "defensive", ["flower", "meadow", "plant"], 1.0, ["#2f7d43", "#f2647c", "#ffd86b"], "round", "bright", "day", 0.035, 2, "#17141c", ["plant_creature", "flower"], 0.82, 2, {"body_plan":"plantlike", "body_shape":"compact", "head_shape":"round", "limbs":{"type":"tentacles", "count":3, "length":0.55}, "ears":"none", "tail":"none", "covering":"smooth", "features":["petals", "vines", "thorns"], "proportions":{"head":0.86, "body":0.9}}),
		_core_creature_definition("core.creature.dusk_prowler", "Dusk Prowler", "A solitary night hunter that stalks open ground and attacks players on sight.", "walking", "air", "none", "aggressive", [], 0.65, ["#241b38", "#7555a8"], "long", "dark", "night", 0.012, 1, "#ff4a5f"),
		_core_creature_definition("core.creature.gloomwing", "Gloomwing", "A rare dark-loving flier that hunts above forests and caverns after sunset.", "flying", "air", "none", "aggressive", [], 0.55, ["#171a2b", "#52618c"], "winged", "dark", "night", 0.009, 1, "#ff365e"),
		_core_creature_definition("core.creature.cinder_eel", "Cinder Eel", "A fierce lava swimmer that emerges at night and attacks anything nearby.", "swimming", "lava", "free", "aggressive", ["lava", "ember"], 1.0, ["#651a17", "#ff6b21"], "long", "bright", "night", 0.008, 1, "#ffe45c"),
		_core_creature_definition("core.creature.prism_moth", "Prism Moth", "A shy luminous moth that drifts between crystals in the Crystal Grove after dusk.", "flying", "air", "none", "fearful", ["flower", "crystal"], 1.0, ["#704a9d", "#ee9cd4", "#d7c2ff"], "winged", "neutral", "night", 0.038, 3, "#fff0b8", ["moth", "bioluminescent", "crystal_grove"], 0.58, 2),
		_core_creature_definition("core.creature.geode_crawler", "Geode Crawler", "A cave crawler with a hard crystal shell that glows softly and defends itself when disturbed.", "crawling", "air", "none", "defensive", ["moss", "crystal", "cave_plant"], 0.48, ["#382747", "#8d57b5", "#8af0c3"], "crawler", "dark", "night", 0.022, 2, "#dfffea", ["cave_only", "crystal", "armored"], 0.82, 4),
		_core_creature_definition("core.creature.rootback_grazer", "Rootback Grazer", "A low, leaf-backed animal that grazes the living Lumenroot floor and keeps away from strangers.", "walking", "air", "none", "fearful", ["root", "plant", "moss"], 1.0, ["#294c3b", "#78b96a", "#c9e889"], "round", "neutral", "all_day", 0.08, 4, "#e8f5c8", ["deep", "lumenroot", "herbivore", "quadruped"], 0.76, 2, {"body_plan":"quadruped", "body_shape":"low", "head_shape":"muzzle", "limbs":{"type":"legs", "count":4, "length":0.58}, "ears":"round", "tail":"short", "covering":"scales", "features":["leafy_back"], "proportions":{"head":0.72, "body":1.08}}),
		_core_creature_definition("core.creature.glasswing_ray", "Glasswing Ray", "A harmless ray-like cavern flier that glides over Glass-Tide pools on translucent fins.", "flying", "air", "none", "passive", ["water", "crystal"], 1.0, ["#346d85", "#7ad1d8", "#d5fbf4"], "winged", "neutral", "all_day", 0.075, 4, "#17384a", ["deep", "glass_tide", "ray", "translucent"], 0.84, 2, {"body_plan":"winged", "body_shape":"wide", "head_shape":"flat", "limbs":{"type":"fins", "count":2, "length":1.05}, "ears":"none", "tail":"long", "covering":"smooth", "features":["translucent_fins"], "proportions":{"head":0.62, "body":1.12}}),
		_core_creature_definition("core.creature.prism_skitter", "Prism Skitter", "A many-legged crystal animal that scatters ambient light while defending its nesting ledges.", "crawling", "air", "none", "defensive", ["crystal"], 1.0, ["#35234d", "#9a62c8", "#73d9c8"], "crawler", "neutral", "all_day", 0.07, 3, "#f4e8ff", ["deep", "prism", "crystal", "armored"], 0.72, 4, {"body_plan":"crawler", "body_shape":"wide", "head_shape":"angular", "limbs":{"type":"legs", "count":6, "length":0.68}, "ears":"none", "tail":"short", "covering":"scales", "features":["crystal_spines"], "proportions":{"head":0.68, "body":1.1}}),
		_core_creature_definition("core.creature.shagot_wanderer", "Shagot Wanderer", "A sapient deep dweller that usually ignores visitors while walking, gathering, and building small structures.", "walking", "air", "none", "neutral", [], 0.72, ["#7b6759", "#83b8a5", "#2e2930"], "round", "dark", "all_day", 0.055, 4, "#d8e7d7", ["shagot", "sapient", "builder", "deep", "neutral"], 0.92, 2, {"body_plan":"biped", "body_shape":"compact", "head_shape":"round", "limbs":{"type":"legs", "count":2, "length":0.92}, "ears":"round", "tail":"none", "covering":"smooth", "features":["arms", "tool_belt"], "proportions":{"head":0.86, "body":0.82}}),
		_core_creature_definition("core.creature.shagot_guide", "Shagot Guide", "A friendly Shagot that approaches lost visitors and shares a light-bearing Lumenroot.", "walking", "air", "none", "friendly", [], 0.82, ["#806c5e", "#9ee3bd", "#4b3854"], "round", "dark", "all_day", 0.022, 2, "#eaffda", ["shagot", "sapient", "builder", "deep", "friendly"], 0.92, 2, {"body_plan":"biped", "body_shape":"compact", "head_shape":"round", "limbs":{"type":"legs", "count":2, "length":0.92}, "ears":"round", "tail":"none", "covering":"smooth", "features":["arms", "satchel"], "proportions":{"head":0.86, "body":0.82}}),
		_core_creature_definition("core.creature.shagot_raider", "Shagot Raider", "A hostile Shagot that protects parts of the ruins and attacks intruders on sight.", "walking", "air", "none", "aggressive", [], 0.72, ["#604b48", "#d66f62", "#26222a"], "round", "dark", "all_day", 0.016, 2, "#ffb09d", ["shagot", "sapient", "builder", "deep", "hostile"], 0.96, 2, {"body_plan":"biped", "body_shape":"compact", "head_shape":"round", "limbs":{"type":"legs", "count":2, "length":0.94}, "ears":"round", "tail":"none", "covering":"smooth", "features":["arms", "tool_belt"], "proportions":{"head":0.84, "body":0.86}}),
	]:
		match str(definition.get("content_id", "")):
			"core.creature.firefly": definition["lighting"] = {"emission": 0.36, "color": "#d8ff72", "radius": 0.75}
			"core.creature.crystal_firefly": definition["lighting"] = {"emission": 0.66, "color": "#7ffbe8", "radius": 0.72}
			"core.creature.ember_walker": definition["lighting"] = {"emission": 0.76, "color": "#ff8a32", "radius": 0.78}
			"core.creature.cinder_eel": definition["lighting"] = {"emission": 0.8, "color": "#ff6b24", "radius": 0.82}
			"core.creature.prism_moth": definition["lighting"] = {"emission": 0.58, "color": "#ef9fd8", "radius": 0.8}
			"core.creature.geode_crawler": definition["lighting"] = {"emission": 0.42, "color": "#a87ad0", "radius": 0.68}
			"core.creature.rootback_grazer": definition["breeding"] = {"group": "rootback", "enabled": false}
			"core.creature.glasswing_ray": definition["breeding"] = {"group": "glasswing", "enabled": false}
			"core.creature.prism_skitter": definition["breeding"] = {"group": "prism_skitter", "enabled": false}
			"core.creature.shagot_wanderer":
				definition["behavior"] = {"temperament": "neutral", "social_role": "neutral", "attack_trigger": "never", "flee_trigger": "never", "awareness_blocks": 7}
				definition["locomotion"]["jump_power"] = 1.45
				definition["habitat"] = {"favorite_plant_tags": [], "attraction_radius_blocks": 7, "maximum_light": 1.0, "light_preference": "neutral"}
				definition["breeding"] = {"group": "shagot", "enabled": false}
			"core.creature.shagot_guide":
				definition["behavior"] = {"temperament": "friendly", "social_role": "friendly", "attack_trigger": "never", "flee_trigger": "never", "awareness_blocks": 9, "follow_distance": 5.5}
				definition["locomotion"]["jump_power"] = 1.55
				definition["habitat"] = {"favorite_plant_tags": [], "attraction_radius_blocks": 7, "maximum_light": 1.0, "light_preference": "neutral"}
				definition["breeding"] = {"group": "shagot", "enabled": false}
			"core.creature.shagot_raider":
				definition["behavior"]["social_role"] = "hostile"
				definition["locomotion"]["jump_power"] = 1.5
				definition["habitat"] = {"favorite_plant_tags": [], "attraction_radius_blocks": 7, "maximum_light": 1.0, "light_preference": "neutral"}
				definition["spawning"]["activity_period"] = "all_day"
				definition["breeding"] = {"group": "shagot", "enabled": false}
		BlockDefs.register_generated_block(definition)


func tick_world_generation() -> void:
	chunk_tick += 1
	var player_tile_x := floori(float(player["x"]) / float(BlockDefs.TILE))
	var center_chunk := floori(float(player_tile_x) / float(CHUNK_WIDTH))
	if world_mode == WORLD_MODE_CHALLENGE and not generated_chunks.has(center_chunk):
		_generate_challenge_chunk(center_chunk)
	elif world_mode != WORLD_MODE_PROCEDURAL and not generated_chunks.has(center_chunk):
		_assign_biome_only_chunk(center_chunk)
	if chunk_tick % 15 != 0:
		return
	var missing_chunks: Array[int] = []
	for chunk_x in range(center_chunk - CHUNK_GENERATION_RADIUS, center_chunk + CHUNK_GENERATION_RADIUS + 1):
		if not generated_chunks.has(chunk_x):
			missing_chunks.append(chunk_x)
	if missing_chunks.is_empty():
		return
	missing_chunks.sort_custom(func(a: int, b: int): return absi(a - center_chunk) < absi(b - center_chunk))
	if world_mode == WORLD_MODE_CHALLENGE:
		_suspend_state_changed = true
		_generate_challenge_chunk(missing_chunks[0])
		_suspend_state_changed = false
		block_count_changed.emit(block_count)
		static_tiles_changed.emit()
		lighting_changed.emit()
		state_changed.emit()
		return
	if world_mode != WORLD_MODE_PROCEDURAL:
		_assign_biome_only_chunk(missing_chunks[0])
		return
	_suspend_state_changed = true
	_generate_chunk(missing_chunks[0])
	_suspend_state_changed = false
	block_count_changed.emit(block_count)
	static_tiles_changed.emit()
	lighting_changed.emit()
	state_changed.emit()


func has_generated_chunk(chunk_x: int) -> bool:
	return generated_chunks.has(chunk_x)


func ensure_generated_chunk(chunk_x: int) -> bool:
	if absi(chunk_x) > COORD_LIMIT / CHUNK_WIDTH:
		return false
	if generated_chunks.has(chunk_x):
		return true
	_suspend_state_changed = true
	if world_mode == WORLD_MODE_PROCEDURAL:
		_generate_chunk(chunk_x)
	elif world_mode == WORLD_MODE_CHALLENGE:
		_generate_challenge_chunk(chunk_x)
	else:
		_assign_biome_only_chunk(chunk_x)
	_suspend_state_changed = false
	block_count_changed.emit(block_count)
	static_tiles_changed.emit()
	lighting_changed.emit()
	state_changed.emit()
	return generated_chunks.has(chunk_x)


func _assign_biome_only_chunk(chunk_x: int) -> void:
	if generated_chunks.has(chunk_x):
		return
	var player_tile_x := floori(float(player["x"]) / float(BlockDefs.TILE))
	var previous_biome := _biome_at(player_tile_x)
	var selected_biome_id := _select_biome_for_chunk(chunk_x)
	var resonant_biome_id := ""
	var selected_resonant_structure_ids: Array[String] = []
	if _world_supports_resonant_deep():
		resonant_biome_id = _resonant_biome_for_chunk(chunk_x)
		selected_resonant_structure_ids = _generate_resonant_deep(chunk_x)
	generated_chunks[chunk_x] = {
		"catalog_revision": catalog_revision,
		"structure_catalog_revision": structure_catalog_revision,
		"selected_content_ids": [],
		"selected_structure_ids": [],
		"placed_structures": [],
		"builtin_structure": false,
		"builtin_structure_id": "",
		"biome_id": selected_biome_id,
		"biome_catalog_revision": biome_catalog_revision,
		"resonant_deep_version": RESONANT_DEEP_VERSION if _world_supports_resonant_deep() else 0,
		"resonant_biome_id": resonant_biome_id,
		"selected_resonant_structure_ids": selected_resonant_structure_ids,
	}
	if _biome_at(player_tile_x) != previous_biome:
		daylight_changed.emit()
		lighting_changed.emit()
	state_changed.emit()


func _generate_chunk(chunk_x: int) -> void:
	if generated_chunks.has(chunk_x):
		return
	var selected_biome_id := _select_biome_for_chunk(chunk_x)
	_pending_chunk_biomes[chunk_x] = selected_biome_id
	var start_x := chunk_x * CHUNK_WIDTH
	var rift_cave_protection := _rift_cave_protection_for_chunk(chunk_x)
	# Terrain pass.
	for x in range(start_x, start_x + CHUNK_WIDTH):
		var biome := _biome_at(x)
		var surface := _terrain_surface_y(x)
		for y in range(surface, PROCEDURAL_BOTTOM_Y + 1):
			if y > surface + 5 and y < PROCEDURAL_BOTTOM_Y - 2 and _is_cave(x, y) and not rift_cave_protection.has(Vector2i(x, y)):
				continue
			var terrain_biome := _terrain_biome_for_position(x, y, biome)
			var block_name := _biome_terrain_block_name(terrain_biome, "deep_content_id", "stone")
			if y == surface:
				block_name = _biome_terrain_block_name(terrain_biome, "surface_content_id", "grass")
			elif y <= surface + 3:
				block_name = _biome_terrain_block_name(terrain_biome, "subsurface_content_id", "dirt")
			_set_generated_block(x, y, block_name)
	# Pregeneration carver pass. Neighboring carver origins are evaluated to avoid chunk seams.
	_carve_caves(chunk_x, rift_cave_protection)
	_generate_underground_water(chunk_x)
	_seed_cave_hanging_plants(chunk_x)
	_generate_tundra_ice_patch(chunk_x, selected_biome_id)
	_generate_obsidian_outcrop(chunk_x, selected_biome_id)
	_generate_crystal_grove_outcrop(chunk_x, selected_biome_id)
	# Biome fluids and natural feature pass.
	for x in range(start_x, start_x + CHUNK_WIDTH):
		var biome := _biome_at(x)
		var base_surface := _surface_y(x)
		var surface := _terrain_surface_y(x)
		# A chunk can straddle a diagonal biome transition. Natural flora must
		# follow the visible surface material, not the chunk-center biome, or oak
		# trees can otherwise appear on the desert side of the boundary.
		var surface_biome := _terrain_biome_for_position(x, surface, biome)
		if biome == "riverbank":
			for water_y in range(base_surface + 1, surface):
				_set_generated_block(x, water_y, "water", 0)
		elif float(BIOME_TREE_CHANCE.get(surface_biome, 0.0)) > 0.0 and _structure_random("tree:%d" % x) < float(BIOME_TREE_CHANCE.get(surface_biome, 0.0)):
			_generate_tree(x, surface, _natural_tree_for_biome(chunk_x, surface_biome, x))
		elif biome.begins_with("gen.biome.") and _world_random("biome-fluid:%s:%d" % [biome, x]) < 0.035:
			var fluid_name := _biome_terrain_block_name(biome, "fluid_content_id", "")
			if not fluid_name.is_empty() and block_id(x, surface - 1) == 0:
				_set_generated_block(x, surface - 1, fluid_name, 0)
	_seed_biome_plant(chunk_x, selected_biome_id)
	_generate_underground_ore_deposits(chunk_x)
	# Long rifts are the final natural terrain pass. This keeps later deposits,
	# outcrops and surface vegetation from accidentally sealing their centerline,
	# branch junctions or daylight mouth.
	_carve_rift_caves(chunk_x)
	var chunk_has_rift := _chunk_has_rift_cave(chunk_x)
	var before_cave_structure := _chunk_tile_snapshot(chunk_x)
	var cave_structure_id := "" if chunk_has_rift else _generate_cave_structure(chunk_x)
	var cave_structure_bounds: Dictionary = {}
	if not cave_structure_id.is_empty():
		cave_structure_bounds = _structure_bounds_from_changes(chunk_x, before_cave_structure, cave_structure_id)
	# Structure pass remains probabilistic and separate from natural deposits.
	var before_structure := _chunk_tile_snapshot(chunk_x)
	var builtin_structure_id := ""
	if not chunk_has_rift and _should_generate_builtin_structure(chunk_x):
		builtin_structure_id = _generate_builtin_structure(chunk_x)
	var builtin_structure := not builtin_structure_id.is_empty()
	var selected_structure_ids: Array[String] = []
	if not chunk_has_rift:
		selected_structure_ids = _place_catalog_structure(chunk_x, builtin_structure)
	var placed_structures: Array[Dictionary] = []
	if not cave_structure_bounds.is_empty():
		placed_structures.append(cave_structure_bounds)
	var placed_structure_id := builtin_structure_id
	if placed_structure_id.is_empty() and not selected_structure_ids.is_empty():
		placed_structure_id = str(selected_structure_ids[0])
	if not placed_structure_id.is_empty():
		var placed_bounds := _structure_bounds_from_changes(chunk_x, before_structure, placed_structure_id)
		if not placed_bounds.is_empty():
			placed_structures.append(placed_bounds)
	var selected := _place_catalog_content(chunk_x)
	_prune_invalid_generated_plants(start_x - 1, start_x + CHUNK_WIDTH)
	var resonant_biome_id := _resonant_biome_for_chunk(chunk_x)
	var selected_resonant_structure_ids := _generate_resonant_deep(chunk_x)
	generated_chunks[chunk_x] = {
		"catalog_revision": catalog_revision,
		"structure_catalog_revision": structure_catalog_revision,
		"selected_content_ids": selected,
		"selected_structure_ids": selected_structure_ids,
		"placed_structures": placed_structures,
		"builtin_structure": builtin_structure,
		"builtin_structure_id": builtin_structure_id,
		"cave_structure_id": cave_structure_id,
		"biome_id": selected_biome_id,
		"biome_catalog_revision": biome_catalog_revision,
		"resonant_deep_version": RESONANT_DEEP_VERSION,
		"resonant_biome_id": resonant_biome_id,
		"selected_resonant_structure_ids": selected_resonant_structure_ids,
	}
	_pending_chunk_biomes.erase(chunk_x)


func _world_supports_resonant_deep() -> bool:
	return world_mode == WORLD_MODE_PROCEDURAL


func _base_resonant_biome_for_chunk(chunk_x: int) -> String:
	var region_index := floori(float(chunk_x) / float(RESONANT_BIOME_SPAN_CHUNKS))
	return RESONANT_DEEP_BIOMES[posmod(region_index, RESONANT_DEEP_BIOMES.size())]


func _is_shagot_biome(biome_id: String) -> bool:
	return biome_id in SHAGOT_BIOME_IDS


func _resonant_biome_for_chunk(chunk_x: int) -> String:
	var deep_region_index := floori(float(chunk_x) / float(RESONANT_BIOME_SPAN_CHUNKS))
	var first_chunk := deep_region_index * RESONANT_BIOME_SPAN_CHUNKS
	var fallback := _base_resonant_biome_for_chunk(chunk_x)
	# Two deliberately spaced Shagot settlements occupy exactly two of every
	# eight Deep regions. Catalog content can diversify only the other 75%.
	if _is_shagot_biome(fallback):
		return fallback
	for candidate_chunk in range(first_chunk, first_chunk + RESONANT_BIOME_SPAN_CHUNKS):
		if not generated_chunks.has(candidate_chunk):
			continue
		var saved: Dictionary = generated_chunks[candidate_chunk]
		if saved.has("resonant_biome_id"):
			var saved_id := str(saved.get("resonant_biome_id", ""))
			return saved_id if not saved_id.is_empty() else fallback
		# An explored chunk from an older save has no Deep selection field. Keep
		# its original built-in terrain instead of retroactively changing it.
		return fallback
	var catalog_region := floori(float(first_chunk) / float(CONTENT_REGION_CHUNKS))
	var manifest: Dictionary = regional_catalogs.get(catalog_region, {})
	var ranked: Array[Dictionary] = []
	for raw_biome_id in (manifest.get("biome_ids", []) as Array):
		var biome_id := str(raw_biome_id)
		if not biome_definitions.has(biome_id):
			continue
		var definition: Dictionary = biome_definitions[biome_id]
		var placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
		if str(placement.get("layer", "surface")) != RESONANT_LAYER_ID:
			continue
		ranked.append({"id": biome_id, "score": _world_random("deep-biome-choice:%s:%d" % [biome_id, deep_region_index])})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary): return float(a["score"]) < float(b["score"]))
	for entry: Dictionary in ranked:
		var biome_id := str(entry["id"])
		var definition: Dictionary = biome_definitions[biome_id]
		var placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
		if absi(first_chunk - _spawn_chunk_x()) < int(placement.get("minimum_chunk_distance", 0)):
			continue
		if float(entry["score"]) >= clampf(float(placement.get("introduction_chance", 0.08)), 0.0, 1.0):
			continue
		var allowed_regions := clampi(int(placement.get("maximum_chunks_per_region", 1)), 1, 2)
		var region_slot := posmod(deep_region_index, maxi(1, CONTENT_REGION_CHUNKS / RESONANT_BIOME_SPAN_CHUNKS))
		var slots: Array[Dictionary] = []
		for slot in maxi(1, CONTENT_REGION_CHUNKS / RESONANT_BIOME_SPAN_CHUNKS):
			slots.append({"slot": slot, "score": _world_random("deep-biome-rank:%s:%d:%d" % [biome_id, catalog_region, slot])})
		slots.sort_custom(func(a: Dictionary, b: Dictionary): return float(a["score"]) < float(b["score"]))
		if not slots.slice(0, allowed_regions).any(func(item: Dictionary): return int(item["slot"]) == region_slot):
			continue
		return biome_id
	return fallback


func _resonant_floor_y(x: int) -> int:
	# A pair of long waves creates broad shelves. Adjacent columns differ by at
	# most one tile, so the chamber remains a continuous walkable settlement.
	var phase := float(posmod(world_seed, 997)) * 0.013
	return 122 + roundi(sin(float(x) * 0.075 + phase) * 1.7 + sin(float(x) * 0.021 - phase) * 0.8)


func _resonant_ceiling_y(x: int) -> int:
	var phase := float(posmod(world_seed, 619)) * 0.017
	return 80 + roundi(sin(float(x) * 0.061 - phase) * 2.2 + sin(float(x) * 0.019 + phase) * 1.2)


func _generate_lumenroot_grove_landmark(start_x: int) -> void:
	var center := start_x + CHUNK_WIDTH / 2
	var variant := posmod(floori(float(start_x) / float(CHUNK_WIDTH)), RESONANT_BIOME_SPAN_CHUNKS)
	var crown_y := _resonant_floor_y(center) - 7 - (variant % 2)
	# Suspended living crowns are natural formations, not Shagot architecture.
	# Their lowest roots stay above head height and keep the floor uninterrupted.
	var crown_radius := 4 + variant
	for offset_x in range(-crown_radius, crown_radius + 1):
		var crown_offset := floori(pow(absf(float(offset_x)) / maxf(3.0, float(crown_radius - 1)), 1.5))
		_set_generated_block(center + offset_x, crown_y + crown_offset, "lumenroot")
	for root_x in [center - crown_radius + 1, center - 2, center + 2, center + crown_radius - 1]:
		var root_top := crown_y + floori(float(absi(root_x - center)) / 3.0) + 1
		for root_y in range(root_top, root_top + 2 + posmod(root_x, 3)):
			_set_generated_block(root_x, root_y, "lumenroot")
	_set_generated_block(center, crown_y + 1, "crystal_lantern")


func _generate_glass_tide_landmark(start_x: int) -> void:
	var center := start_x + CHUNK_WIDTH / 2
	var variant := posmod(floori(float(start_x) / float(CHUNK_WIDTH)), RESONANT_BIOME_SPAN_CHUNKS)
	var basin_y := _resonant_floor_y(center) - 5 - (variant % 3)
	var basin_radius := 3 + (variant % 3)
	# Naturally floating shelves hold crystalline pools. They form a distinct
	# silhouette without borrowing Shagot bricks or scaffolds.
	for basin_x in range(center - basin_radius, center + basin_radius + 1):
		_set_generated_block(basin_x, basin_y, "glass_tide_silt")
	for wall_x in [center - basin_radius, center + basin_radius]:
		_set_generated_block(wall_x, basin_y - 1, "glass_tide_silt")
		_set_generated_block(wall_x, basin_y - 2, "moonstone_ore")
	for liquid_x in range(center - basin_radius + 1, center + basin_radius):
		_set_generated_block(liquid_x, basin_y - 1, "glass_tide", 0)
	for shard_x in [center - 3, center, center + 3]:
		_set_generated_block(shard_x, basin_y + 1, "moonstone_ore")


func _generate_prism_chasm_landmark(start_x: int) -> void:
	var center := start_x + CHUNK_WIDTH / 2
	var base_y := _resonant_floor_y(center)
	var variant := posmod(floori(float(start_x) / float(CHUNK_WIDTH)), RESONANT_BIOME_SPAN_CHUNKS)
	var crystal_names: Array[String] = ["amethyst_crystal", "rose_crystal", "emerald_crystal"]
	# Basalt fans with sparse luminous crystal tips make the chasm unmistakable
	# without turning every decorative block into another propagated light source.
	for side: int in [-1, 1]:
		for step in 2 + variant % 3:
			var crystal_x: int = center + side * (5 + step)
			for crystal_y in range(base_y - 1 - step, base_y):
				_set_generated_block(crystal_x, crystal_y, "prismatic_basalt")
			_set_generated_block(crystal_x, base_y - 2 - step, crystal_names[posmod(step + (1 if side > 0 else 0), crystal_names.size())])
	var bridge_y := base_y - 7 - variant
	for offset_x in range(-6, 7):
		_set_generated_block(center + offset_x, bridge_y + (1 if absi(offset_x) > 4 else 0), "prismatic_basalt")
	for accent_x in [-5, 0, 5]:
		_set_generated_block(center + accent_x, bridge_y - 1, crystal_names[posmod(accent_x, crystal_names.size())])


func _generate_chorus_river_landmark(start_x: int) -> void:
	var center := start_x + CHUNK_WIDTH / 2
	var variant := posmod(floori(float(start_x) / float(CHUNK_WIDTH)), RESONANT_BIOME_SPAN_CHUNKS)
	# A continuous bank-to-bank channel. The source end alternates by chunk so
	# visible eddies form where neighbouring currents meet.
	for x in range(start_x, start_x + CHUNK_WIDTH):
		var floor_y := _resonant_floor_y(x)
		_set_generated_block(x, floor_y, "glass_tide_silt")
		_set_generated_block(x, floor_y - 1, "chorus_brine", posmod(x - start_x if variant % 2 == 0 else start_x + CHUNK_WIDTH - 1 - x, 7))
	for crystal_x in [start_x + 2, center, start_x + CHUNK_WIDTH - 3]:
		var bank_y := _resonant_floor_y(crystal_x)
		_set_generated_block(crystal_x, bank_y - 2, "chorus_crystal")
		if crystal_x != center:
			_set_generated_block(crystal_x, bank_y - 3, "chorus_crystal")


func _generate_inverted_orchard_landmark(start_x: int) -> void:
	var center := start_x + CHUNK_WIDTH / 2
	var variant := posmod(floori(float(start_x) / float(CHUNK_WIDTH)), RESONANT_BIOME_SPAN_CHUNKS)
	# Trunks hang from the roof and branch into crowns well above the walkable
	# floor. Sparse crystal fruit provides landmarks without a dense light grid.
	for trunk_x in [center - 5, center, center + 5]:
		var ceiling_y := _resonant_ceiling_y(trunk_x)
		var crown_y := _resonant_floor_y(trunk_x) - 8 - posmod(trunk_x + variant, 3)
		for y in range(ceiling_y, crown_y):
			_set_generated_block(trunk_x, y, "inverted_root")
		for crown_depth in 2:
			for offset_x in range(-3 + crown_depth, 4 - crown_depth):
				_set_generated_block(trunk_x + offset_x, crown_y + crown_depth + (1 if absi(offset_x) == 3 else 0), "inverted_root")
		_set_generated_block(trunk_x + (-2 if variant % 2 == 0 else 2), crown_y + 2, "chorus_crystal")


func _generate_bone_choir_landmark(start_x: int) -> void:
	var center := start_x + CHUNK_WIDTH / 2
	var floor_y := _resonant_floor_y(center)
	var arch_top := floor_y - 8
	# Alternating fossil ribs form readable arches. Vents in the aisle act as
	# launch pads, so the biome changes traversal rather than only its palette.
	for side: int in [-1, 1]:
		var rib_x := center + side * 5
		for y in range(arch_top + 2, _resonant_floor_y(rib_x)):
			_set_generated_block(rib_x, y, "choir_bone")
		for step in 4:
			_set_generated_block(rib_x - side * step, arch_top + step / 2, "choir_bone")
	for vent_x in [center - 2, center + 2]:
		_set_generated_block(vent_x, _resonant_floor_y(vent_x), "choir_vent")
	_set_generated_block(center, arch_top - 1, "chorus_crystal")


func _generate_shagot_lockworks_landmark(start_x: int) -> void:
	var center := start_x + CHUNK_WIDTH / 2
	var floor_y := _resonant_floor_y(center)
	var deck_y := floor_y - 4
	# An inhabited sluice: pass-through scaffold gates divide a small Brine
	# channel while Tideglass decks remain climbable solid platforms.
	for x in range(center - 6, center + 7):
		_set_generated_block(x, deck_y, "tideglass")
	for gate_x in [center - 5, center, center + 5]:
		for y in range(deck_y + 1, _resonant_floor_y(gate_x)):
			_set_generated_block(gate_x, y, "shagot_scaffold")
	for river_x in range(center - 4, center + 5):
		_set_generated_block(river_x, _resonant_floor_y(river_x) - 1, "chorus_brine", posmod(river_x - center + 4, 7))
	for crystal_x in [center - 6, center + 6]:
		_set_generated_block(crystal_x, deck_y - 1, "chorus_crystal")


func _generate_shagot_foundation_partitions(center: int) -> void:
	# Every enclave building reads as an inhabited ground floor instead of a roof
	# floating over an empty cavern. Scaffolds are visible room dividers but remain
	# non-solid, so players and Shagots can walk through them like surface-hut wood.
	for partition_x in [center - 5, center, center + 5]:
		var floor_y := _resonant_floor_y(partition_x)
		for y in range(floor_y - 3, floor_y):
			_set_generated_block(partition_x, y, "shagot_scaffold")


func _generate_magnetic_ruins_landmark(start_x: int) -> void:
	var center := start_x + CHUNK_WIDTH / 2
	var variant := posmod(floori(float(start_x) / float(CHUNK_WIDTH)), RESONANT_BIOME_SPAN_CHUNKS)
	var roof_y := _resonant_floor_y(center) - 7
	match variant:
		0: # Open workshop
			for roof_x in range(center - 6, center + 7):
				_set_generated_block(roof_x, roof_y, "resonance_bricks")
			for post_x in [center - 6, center - 2, center + 2, center + 6]:
				for y in range(roof_y + 1, _resonant_floor_y(post_x)):
					_set_generated_block(post_x, y, "shagot_scaffold")
			for lamp_x in [center - 4, center, center + 4]:
				_set_generated_block(lamp_x, roof_y + 1, "crystal_lantern")
		1: # Stepped dwelling canopy
			for offset_x in range(-6, 7):
				_set_generated_block(center + offset_x, roof_y + floori(float(absi(offset_x)) / 3.0), "resonance_bricks")
			for post_x in [center - 5, center, center + 5]:
				for y in range(roof_y + 3, _resonant_floor_y(post_x)):
					_set_generated_block(post_x, y, "shagot_scaffold")
			_set_generated_block(center, roof_y + 1, "crystal_lantern")
		2: # Watch tower with two platforms
			for post_x in [center - 3, center + 3]:
				for y in range(roof_y - 2, _resonant_floor_y(post_x)):
					_set_generated_block(post_x, y, "shagot_scaffold")
			for platform_y in [roof_y - 2, roof_y + 3]:
				for platform_x in range(center - 5, center + 6):
					_set_generated_block(platform_x, platform_y, "resonance_bricks")
			_set_generated_block(center, roof_y - 1, "crystal_lantern")
		3: # Mine gate and material yard
			for post_x in [center - 5, center + 5]:
				for y in range(roof_y + 1, _resonant_floor_y(post_x)):
					_set_generated_block(post_x, y, "shagot_scaffold")
			for arch_x in range(center - 5, center + 6):
				_set_generated_block(arch_x, roof_y, "resonance_bricks")
			for brace_x in [center - 3, center, center + 3]:
				for y in range(roof_y + 2, _resonant_floor_y(brace_x)):
					_set_generated_block(brace_x, y, "shagot_scaffold")
			_set_generated_block(center, roof_y + 1, "crystal_lantern")
	for ore_x in [center - 5, center - 1, center + 3, center + 5]:
		_set_generated_block(ore_x, _resonant_floor_y(ore_x) - 1, "magnetic_stone")
	# Ground-floor dividers win over decorative ore outcrops at shared cells.
	_generate_shagot_foundation_partitions(center)


func _generate_resonant_landmark(start_x: int, biome_id: String) -> void:
	match biome_id:
		"lumenroot_groves": _generate_lumenroot_grove_landmark(start_x)
		"chorus_river": _generate_chorus_river_landmark(start_x)
		"glass_tide_caverns": _generate_glass_tide_landmark(start_x)
		"prism_chasm": _generate_prism_chasm_landmark(start_x)
		"magnetic_ruins": _generate_magnetic_ruins_landmark(start_x)
		"inverted_orchard": _generate_inverted_orchard_landmark(start_x)
		"bone_choir": _generate_bone_choir_landmark(start_x)
		"shagot_lockworks": _generate_shagot_lockworks_landmark(start_x)


func _place_resonant_catalog_structure(chunk_x: int, biome_id: String) -> Array[String]:
	var selected: Array[String] = []
	var catalog_region := floori(float(chunk_x) / float(CONTENT_REGION_CHUNKS))
	var manifest: Dictionary = regional_catalogs.get(catalog_region, {})
	var definitions: Array[Dictionary] = []
	for raw_structure_id in (manifest.get("structure_ids", []) as Array):
		var structure_id := str(raw_structure_id)
		if not structure_definitions.has(structure_id):
			continue
		var definition: Dictionary = structure_definitions[structure_id]
		var placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
		if str(placement.get("layer", "surface")) == RESONANT_LAYER_ID:
			definitions.append(definition)
	definitions.sort_custom(func(a: Dictionary, b: Dictionary): return str(a.get("structure_id", "")) < str(b.get("structure_id", "")))
	for definition: Dictionary in definitions:
		var structure_id := str(definition.get("structure_id", ""))
		var placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
		var allowed_biomes: Array = placement.get("biomes", []) if placement.get("biomes", []) is Array else []
		if not allowed_biomes.is_empty() and biome_id not in allowed_biomes:
			continue
		if _structure_random("deep-catalog:%s:%d" % [structure_id, chunk_x]) >= clampf(float(placement.get("spawn_chance", 0.0)), 0.0, 1.0):
			continue
		var existing_in_region := 0
		for raw_chunk_x in generated_chunks:
			if floori(float(int(raw_chunk_x)) / float(CONTENT_REGION_CHUNKS)) != catalog_region:
				continue
			if structure_id in ((generated_chunks[raw_chunk_x] as Dictionary).get("selected_resonant_structure_ids", []) as Array):
				existing_in_region += 1
		if existing_in_region >= int(placement.get("maximum_per_region", 1)):
			continue
		if _generate_catalog_structure(chunk_x, definition, true):
			selected.append(structure_id)
			break
	return selected


func _generate_resonant_deep(chunk_x: int) -> Array[String]:
	if not _world_supports_resonant_deep():
		return []
	var biome_id := _resonant_biome_for_chunk(chunk_x)
	var start_x := chunk_x * CHUNK_WIDTH
	var deep_stone_name: String = str({
		"lumenroot_groves": "magnetic_stone",
		"chorus_river": "prismatic_basalt",
		"glass_tide_caverns": "glass_tide_silt",
		"prism_chasm": "prismatic_basalt",
		"magnetic_ruins": "magnetic_stone",
		"inverted_orchard": "prismatic_basalt",
		"bone_choir": "choir_bone",
		"shagot_lockworks": "magnetic_stone",
	}.get(biome_id, "magnetic_stone"))
	var floor_name: String = str({
		"lumenroot_groves": "lumenroot",
		"chorus_river": "glass_tide_silt",
		"glass_tide_caverns": "glass_tide_silt",
		"prism_chasm": "prismatic_basalt",
		"magnetic_ruins": "resonance_bricks",
		"inverted_orchard": "inverted_root",
		"bone_choir": "prismatic_basalt",
		"shagot_lockworks": "resonance_bricks",
	}.get(biome_id, "lumenroot"))
	if biome_id.begins_with("gen.biome."):
		deep_stone_name = _biome_terrain_block_name(biome_id, "deep_content_id", "magnetic_stone")
		floor_name = _biome_terrain_block_name(biome_id, "surface_content_id", deep_stone_name)
	for x in range(start_x, start_x + CHUNK_WIDTH):
		for seal_y in range(RESONANT_SEAL_TOP_Y, RESONANT_DEEP_TOP_Y):
			if block_id(x, seal_y) == 0 or seal_y >= PROCEDURAL_BOTTOM_Y:
				_set_generated_block(x, seal_y, "aegisite_seal")
		var ceiling_y := _resonant_ceiling_y(x)
		var floor_y := _resonant_floor_y(x)
		for y in range(RESONANT_DEEP_TOP_Y, RESONANT_DEEP_BOTTOM_Y + 1):
			var is_room := y >= ceiling_y and y < floor_y
			if is_room:
				if block_id(x, y) != 0:
					_erase_generated_tile(Vector2i(x, y))
				continue
			_set_generated_block(x, y, deep_stone_name)
		# Every region has a continuous, walkable floor but no longer shares the
		# same green surface, so biome changes read immediately at ground level.
		_set_generated_block(x, floor_y, floor_name)
		# Sparse exposed outcrops give Shagots something visible to mine without
		# splitting the floor into impassable ravines.
		if _is_shagot_biome(biome_id) and posmod(x + posmod(world_seed, 11), 13) == 4:
			_set_generated_block(x, floor_y - 1, "magnetic_stone")
		# Biome-specific stalactites break up the ceiling without repeating one
		# Lumenroot motif across the entire Deep.
		if posmod(x + 3, 9) == 0:
			var root_length := 1 + posmod(x + chunk_x, 3)
			for root_offset in root_length:
				var hanging_name: String = str({
					"lumenroot_groves": "lumenroot",
					"glass_tide_caverns": "glass_tide_silt",
					"prism_chasm": "prismatic_basalt",
					"magnetic_ruins": "resonance_bricks",
					"chorus_river": "chorus_crystal",
					"inverted_orchard": "inverted_root",
					"bone_choir": "choir_bone",
					"shagot_lockworks": "shagot_scaffold",
				}.get(biome_id, deep_stone_name))
				_set_generated_block(x, ceiling_y + root_offset, hanging_name)
		if _is_shagot_biome(biome_id) and posmod(x + posmod(world_seed, 7), 12) == 2:
			_set_generated_block(x, ceiling_y + 1, "crystal_lantern" if posmod(chunk_x, 2) == 0 else "lantern")
		if _is_shagot_biome(biome_id) and posmod(x, 15) in [1, 2, 3]:
			_set_generated_block(x, ceiling_y + 2, "resonance_bricks")
	var selected_structures := _place_resonant_catalog_structure(chunk_x, biome_id)
	if selected_structures.is_empty():
		_generate_resonant_landmark(start_x, biome_id)
	return selected_structures


func _chunk_tile_snapshot(chunk_x: int) -> Dictionary:
	var snapshot: Dictionary = {}
	for raw_pos in (chunk_tiles.get(chunk_x, {}) as Dictionary).keys():
		if raw_pos is Vector2i:
			var pos := raw_pos as Vector2i
			snapshot[pos] = block_id(pos.x, pos.y)
	return snapshot


func _structure_bounds_from_changes(chunk_x: int, before: Dictionary, structure_id: String) -> Dictionary:
	var after := _chunk_tile_snapshot(chunk_x)
	var positions: Dictionary = {}
	for raw_pos in before:
		positions[raw_pos] = true
	for raw_pos in after:
		positions[raw_pos] = true
	var changed: Array[Vector2i] = []
	for raw_pos in positions:
		if raw_pos is Vector2i and int(before.get(raw_pos, 0)) != int(after.get(raw_pos, 0)):
			changed.append(raw_pos as Vector2i)
	if changed.is_empty():
		return {}
	var left := changed[0].x
	var right := changed[0].x
	var top := changed[0].y
	var bottom := changed[0].y
	for pos: Vector2i in changed:
		left = mini(left, pos.x)
		right = maxi(right, pos.x)
		top = mini(top, pos.y)
		bottom = maxi(bottom, pos.y)
	return {"id": structure_id, "left": left, "right": right, "top": top, "bottom": bottom}


func _surface_y(x: int) -> int:
	var phase := float(posmod(world_seed, 100000)) * 0.00013
	return 8 + int(round(sin(float(x) * 0.11 + phase) * 2.0 + sin(float(x) * 0.037 + phase * 1.7) * 3.0))


func _terrain_surface_y(x: int) -> int:
	return _surface_y(x) + _river_depth_at(x)


func _river_depth_at(x: int) -> int:
	if absi(x) < 32:
		return 0
	var region := floori(float(x) / 96.0)
	if _world_random("river:%d" % region) >= 0.14:
		return 0
	var center := region * 96 + 48
	return maxi(0, 4 - floori(float(absi(x - center)) / 4.0))


func _generate_tundra_ice_patch(chunk_x: int, biome_id: String, force: bool = false) -> bool:
	if biome_id != "tundra":
		return false
	if not force and _structure_random("tundra-ice-patch:%d" % chunk_x) >= TUNDRA_ICE_PATCH_CHANCE:
		return false
	var width := 3 + int(_structure_random("tundra-ice-width:%d" % chunk_x) * 4.0)
	var start_x := chunk_x * CHUNK_WIDTH
	var room := CHUNK_WIDTH - width - 2
	var left := start_x + 1 + int(_structure_random("tundra-ice-position:%d" % chunk_x) * float(room + 1))
	var placed := 0
	for x in range(left, left + width):
		var surface_y := _terrain_surface_y(x)
		var surface_name := str(get_block(x, surface_y).get("name", ""))
		if surface_name not in ["dirt", "grass", "ice"]:
			continue
		if surface_name != "ice":
			_set_generated_block(x, surface_y, "ice")
		placed += 1
	return placed >= 3


func _generate_obsidian_outcrop(chunk_x: int, biome_id: String, force: bool = false) -> bool:
	if biome_id != "obsidian":
		return false
	if not force and _structure_random("obsidian-outcrop:%d" % chunk_x) >= OBSIDIAN_OUTCROP_CHANCE:
		return false
	var width := 2 + int(_structure_random("obsidian-outcrop-width:%d" % chunk_x) * 3.0)
	var start_x := chunk_x * CHUNK_WIDTH
	var room := CHUNK_WIDTH - width - 2
	var left := start_x + 1 + int(_structure_random("obsidian-outcrop-position:%d" % chunk_x) * float(room + 1))
	var placed := 0
	for x in range(left, left + width):
		var surface_y := _terrain_surface_y(x)
		var surface_name := str(get_block(x, surface_y).get("name", ""))
		if surface_name not in ["cobblestone", "stone", "obsidian"]:
			continue
		if surface_name != "obsidian":
			_set_generated_block(x, surface_y, "obsidian")
		placed += 1
	return placed >= 2


func _generate_crystal_grove_outcrop(chunk_x: int, biome_id: String, force: bool = false) -> bool:
	if biome_id != "crystal_grove":
		return false
	if not force and _structure_random("crystal-grove-outcrop:%d" % chunk_x) >= CRYSTAL_GROVE_OUTCROP_CHANCE:
		return false
	var start_x := chunk_x * CHUNK_WIDTH
	var center_x := start_x + 3 + int(_structure_random("crystal-grove-position:%d" % chunk_x) * float(CHUNK_WIDTH - 6))
	var crystal_name := "rose_crystal" if _structure_random("crystal-grove-color:%d" % chunk_x) < 0.55 else "amethyst_crystal"
	var ground_y := _terrain_surface_y(center_x)
	var placed := 0
	for entry: Dictionary in [
		{"dx": -1, "height": 1},
		{"dx": 0, "height": 3},
		{"dx": 1, "height": 2},
	]:
		var x := center_x + int(entry["dx"])
		var local_ground := _terrain_surface_y(x)
		if absi(local_ground - ground_y) > 2:
			continue
		for offset in range(int(entry["height"])):
			var y := local_ground - 1 - offset
			if block_id(x, y) != 0:
				break
			_set_generated_block(x, y, crystal_name)
			placed += 1
	return placed >= 3


func _core_biome_temperature(biome_id: String) -> float:
	var definition: Dictionary = BiomeDefs.SYSTEM.get(biome_id, BiomeDefs.SYSTEM.plains)
	var environment: Dictionary = definition.get("environment", {})
	return float(environment.get("temperature", 0.0))


func _core_biome_temperature_affinity(candidate_id: String, neighbor_id: String) -> float:
	if neighbor_id.is_empty():
		return 1.0
	var difference := absf(_core_biome_temperature(candidate_id) - _core_biome_temperature(neighbor_id))
	return CORE_BIOME_TEMPERATURE_AFFINITY_FLOOR + (1.0 - CORE_BIOME_TEMPERATURE_AFFINITY_FLOOR) * exp(-CORE_BIOME_TEMPERATURE_STRENGTH * difference)


func _select_core_biome_for_region(region: int, neighbor_id: String = "") -> String:
	var weighted: Array[Dictionary] = []
	var total := 0.0
	for biome_id: String in CORE_BIOME_IDS:
		var weight := float(CORE_BIOME_BASE_WEIGHTS[biome_id]) * _core_biome_temperature_affinity(biome_id, neighbor_id)
		# Crystal Grove is a special discovery biome rather than a long climate
		# belt. Never extend it into the immediately adjacent 48-block region.
		if biome_id == neighbor_id and biome_id in CORE_BIOME_NO_REPEAT_IDS:
			weight = 0.0
		weighted.append({"id": biome_id, "weight": weight})
		total += weight
	var target := _structure_random("biome:%d" % region) * total
	var cumulative := 0.0
	for entry: Dictionary in weighted:
		cumulative += float(entry["weight"])
		if target < cumulative:
			return str(entry["id"])
	return "ice"


func _reset_core_biome_cache_if_needed() -> void:
	if _core_biome_cache_initialized and _core_biome_cache_seed == world_seed:
		return
	_core_biome_cache_initialized = true
	_core_biome_cache_seed = world_seed
	_core_region_biomes.clear()
	_core_region_biomes[0] = _select_core_biome_for_region(0)
	_core_positive_frontier = 0
	_core_negative_frontier = 0


func _core_biome_for_region(region: int) -> String:
	_reset_core_biome_cache_if_needed()
	if _core_region_biomes.has(region):
		return str(_core_region_biomes[region])
	if region > _core_positive_frontier:
		for current in range(_core_positive_frontier + 1, region + 1):
			_core_region_biomes[current] = _select_core_biome_for_region(current, str(_core_region_biomes[current - 1]))
		_core_positive_frontier = region
	elif region < _core_negative_frontier:
		for current in range(_core_negative_frontier - 1, region - 1, -1):
			_core_region_biomes[current] = _select_core_biome_for_region(current, str(_core_region_biomes[current + 1]))
		_core_negative_frontier = region
	return str(_core_region_biomes[region])


func _biome_transition_side_width(boundary_x: int, side: String) -> int:
	var span := BIOME_TRANSITION_MAX_SIDE_WIDTH - BIOME_TRANSITION_MIN_SIDE_WIDTH + 1
	return BIOME_TRANSITION_MIN_SIDE_WIDTH + int(_structure_random("biome-transition-%s:%d" % [side, boundary_x]) * float(span))


func _core_biome_transition_at(x: int) -> Dictionary:
	var region := floori(float(x) / float(CORE_BIOME_REGION_WIDTH))
	for boundary_x in [region * CORE_BIOME_REGION_WIDTH, (region + 1) * CORE_BIOME_REGION_WIDTH]:
		var right_region := floori(float(boundary_x) / float(CORE_BIOME_REGION_WIDTH))
		var left_biome := _core_biome_for_region(right_region - 1)
		var right_biome := _core_biome_for_region(right_region)
		if left_biome == right_biome:
			continue
		var left_temperature := _core_biome_temperature(left_biome)
		var right_temperature := _core_biome_temperature(right_biome)
		if is_equal_approx(left_temperature, right_temperature):
			continue
		var left_width := _biome_transition_side_width(boundary_x, "left")
		var right_width := _biome_transition_side_width(boundary_x, "right")
		if x < boundary_x - left_width or x >= boundary_x + right_width:
			continue
		var physical_progress := float(x - (boundary_x - left_width)) / float(left_width + right_width)
		var warmer_on_right := right_temperature > left_temperature
		return {
			"boundary_x": boundary_x,
			"left_width": left_width,
			"right_width": right_width,
			"warmer_biome": right_biome if warmer_on_right else left_biome,
			"colder_biome": left_biome if warmer_on_right else right_biome,
			"warm_progress": physical_progress if warmer_on_right else 1.0 - physical_progress,
		}
	return {}


func _terrain_biome_for_position(x: int, y: int, base_biome: String) -> String:
	if base_biome not in CORE_BIOME_IDS:
		return base_biome
	var transition := _core_biome_transition_at(x)
	if transition.is_empty():
		return base_biome
	var warmer_biome := str(transition["warmer_biome"])
	var colder_biome := str(transition["colder_biome"])
	if base_biome not in [warmer_biome, colder_biome]:
		return base_biome
	var surface_y := _terrain_surface_y(x)
	# Core biome profiles differ most in their surface and three subsurface
	# layers. Crossing that visible stratum makes the diagonal readable instead
	# of hiding it inside the shared deep-stone layer.
	var diagonal_y := lerpf(float(surface_y), float(surface_y + BIOME_TRANSITION_VERTICAL_DEPTH), clampf(float(transition["warm_progress"]), 0.0, 1.0))
	return warmer_biome if float(y) < diagonal_y else colder_biome


func _core_biome_at(x: int) -> String:
	if _river_depth_at(x) > 0:
		return "riverbank"
	return _core_biome_for_region(floori(float(x) / float(CORE_BIOME_REGION_WIDTH)))


func _biome_at(x: int) -> String:
	if world_seed <= 0:
		return "plains"
	var chunk_x := floori(float(x) / float(CHUNK_WIDTH))
	if generated_chunks.has(chunk_x):
		var saved_id := str((generated_chunks[chunk_x] as Dictionary).get("biome_id", ""))
		if not saved_id.is_empty():
			return saved_id
	if _pending_chunk_biomes.has(chunk_x):
		return str(_pending_chunk_biomes[chunk_x])
	return _world_biome_fallback_at(x)


func _world_biome_fallback_at(x: int) -> String:
	# Keep the starting island familiar in empty-world modes without changing the
	# seeded core-biome sequence used by procedural terrain and neighboring zones.
	if world_mode != WORLD_MODE_PROCEDURAL and floori(float(x) / float(CORE_BIOME_REGION_WIDTH)) == 0:
		return "plains"
	return _core_biome_at(x)


func _floating_island_biome_at(pos: Vector2i) -> String:
	var nearest_biome := ""
	var nearest_score := INF
	var layout: Array[Dictionary] = floating_island_layout if not floating_island_layout.is_empty() else LEGACY_FLOATING_ISLAND_LAYOUT
	for island: Dictionary in layout:
		var center: Vector2i = island["center"]
		var half_width := int(island["half_width"])
		var horizontal := absf(float(pos.x - center.x)) / float(half_width + 7)
		var vertical := absf(float(pos.y - center.y)) / float(int(island["depth"]) + 9)
		var score := horizontal * horizontal + vertical * vertical
		if score <= 1.0 and score < nearest_score:
			nearest_score = score
			nearest_biome = str(island["biome"])
	return nearest_biome


func _select_biome_for_chunk(chunk_x: int) -> String:
	var fallback := _world_biome_fallback_at(chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2)
	var region := floori(float(chunk_x) / float(CONTENT_REGION_CHUNKS))
	var manifest: Dictionary = regional_catalogs.get(region, {})
	var biome_ids: Array = manifest.get("biome_ids", []) if manifest.get("biome_ids", []) is Array else []
	var ranked: Array[Dictionary] = []
	for raw_biome_id in biome_ids:
		var biome_id := str(raw_biome_id)
		if not biome_definitions.has(biome_id):
			continue
		var definition: Dictionary = biome_definitions[biome_id]
		var placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
		if str(placement.get("layer", "surface")) != "surface":
			continue
		ranked.append({"id": biome_id, "score": _world_random("biome-choice:%s:%d" % [biome_id, chunk_x])})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary): return float(a["score"]) < float(b["score"]))
	for entry: Dictionary in ranked:
		var biome_id := str(entry["id"])
		var definition: Dictionary = biome_definitions[biome_id]
		var placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
		if absi(chunk_x - _spawn_chunk_x()) < int(placement.get("minimum_chunk_distance", 3)):
			continue
		var chance := clampf(float(placement.get("introduction_chance", 0.02)), 0.0, 0.12)
		if float(entry["score"]) >= chance:
			continue
		if not _content_allowed_in_region("biome:%s" % biome_id, chunk_x, int(placement.get("maximum_chunks_per_region", 1))):
			continue
		return biome_id
	return fallback


func _biome_definition(biome_id: String) -> Dictionary:
	return biome_definitions.get(biome_id, BiomeDefs.SYSTEM.get("plains", {}))


func _biome_terrain_block_name(biome_id: String, field: String, fallback: String) -> String:
	var definition := _biome_definition(biome_id)
	var terrain: Dictionary = definition.get("terrain", {}) if definition.get("terrain", {}) is Dictionary else {}
	var content_id := str(terrain.get(field, ""))
	if content_id.is_empty():
		return fallback
	var block_name := BlockDefs.name_for_content_id(content_id)
	return block_name if not block_name.is_empty() else fallback


func _seed_biome_plant(chunk_x: int, biome_id: String) -> void:
	var definition := _biome_definition(biome_id)
	var ecology: Dictionary = definition.get("ecology", {}) if definition.get("ecology", {}) is Dictionary else {}
	var plant_ids: Array[String] = []
	for raw_id in (ecology.get("plant_content_ids", []) as Array):
		var content_id := str(raw_id)
		var block_name := BlockDefs.name_for_content_id(content_id)
		var plant_definition := _plant_definition(block_name)
		var growth: Dictionary = plant_definition.get("growth", {}) if plant_definition.get("growth", {}) is Dictionary else {}
		if str(growth.get("form", "")) not in ["hanging", "tree"] and not content_id.is_empty():
			plant_ids.append(content_id)
	for content_id in _regional_plant_ids(chunk_x, ["vertical_up", "vertical_down", "bidirectional_vertical", "surface_creeper", "decorative"], biome_id):
		if not plant_ids.has(content_id):
			plant_ids.append(content_id)
	var chance := float(BIOME_DECORATIVE_PLANT_CHANCE.get(biome_id, 0.3 if biome_id.begins_with("gen.biome.") else 0.22))
	if plant_ids.is_empty() or _world_random("biome-plant:%s:%d" % [biome_id, chunk_x]) >= chance:
		return
	var start_x := chunk_x * CHUNK_WIDTH
	var attempts := 3 if biome_id == "plains" else (2 if biome_id in ["forest", "riverbank"] else 1)
	for attempt in attempts:
		var index := int(_world_random("biome-plant-kind:%s:%d:%d" % [biome_id, chunk_x, attempt]) * float(plant_ids.size())) % plant_ids.size()
		var content_id := plant_ids[index]
		var block_name := BlockDefs.name_for_content_id(content_id)
		if block_name.is_empty():
			continue
		var x := start_x + 2 + int(_world_random("biome-plant-pos:%s:%d:%d" % [biome_id, chunk_x, attempt]) * float(CHUNK_WIDTH - 4))
		var plant_definition := _plant_definition(block_name)
		var pos := _natural_plant_position(x, plant_definition)
		if pos.y != COORD_LIMIT:
			_place_generated_plant(pos, block_name, plant_definition, true)


func _natural_plant_position(x: int, definition: Dictionary) -> Vector2i:
	if definition.is_empty():
		return Vector2i(x, COORD_LIMIT)
	var surface := _terrain_surface_y(x)
	var positions: Array[Vector2i] = [Vector2i(x, surface - 1)]
	# Generated aquatic, root, and creeping flora may need a nearby fluid or a
	# below-surface anchor. Site validation remains the final authority.
	for y in range(surface - 4, mini(PROCEDURAL_BOTTOM_Y, surface + 10)):
		var pos := Vector2i(x, y)
		if not positions.has(pos):
			positions.append(pos)
	for pos in positions:
		if _plant_site_valid(pos, definition):
			return pos
	return Vector2i(x, COORD_LIMIT)


func _definition_matches_biome_climate(definition: Dictionary, biome_id: String) -> bool:
	var biome := _biome_definition(biome_id)
	var environment: Dictionary = biome.get("environment", {}) if biome.get("environment", {}) is Dictionary else {}
	var temperature := float(environment.get("temperature", 0.0))
	var tags: Array[String] = []
	for raw_tag in (definition.get("tags", []) as Array):
		tags.append(str(raw_tag).to_lower())
	var cold_tags := ["ice", "cold", "frozen", "frost", "snow"]
	var hot_tags := ["lava", "hot", "fire", "volcanic", "ember"]
	if tags.any(func(tag: String): return tag in cold_tags) and temperature > WATER_FREEZE_TEMPERATURE:
		return false
	if tags.any(func(tag: String): return tag in hot_tags) and temperature < LOCAL_MELT_TEMPERATURE:
		return false
	return true


func _generated_living_content_allowed(content_id: String, definition: Dictionary, biome_id: String, explicit_ids: Array) -> bool:
	if content_id in explicit_ids:
		return true
	# The Resonant Deep is a sealed ecology. Generated catalog wildlife that
	# merely matches its climate must not leak in from the surface world. An AI
	# Deep biome can introduce creatures only by naming them in its own ecology.
	var biome_definition := _biome_definition(biome_id)
	var placement: Dictionary = biome_definition.get("placement", {}) if biome_definition.get("placement", {}) is Dictionary else {}
	if biome_id in RESONANT_DEEP_BIOMES or str(placement.get("layer", "surface")) == RESONANT_LAYER_ID:
		return false
	if content_id.begins_with(CORE_CONTENT_PREFIX) or not world_definition_ids.has(content_id):
		return false
	return _definition_matches_biome_climate(definition, biome_id)


func _regional_plant_ids(chunk_x: int, forms: Array[String], biome_id: String) -> Array[String]:
	var region := floori(float(chunk_x) / float(CONTENT_REGION_CHUNKS))
	var manifest: Dictionary = regional_catalogs.get(region, {})
	var result: Array[String] = []
	var candidate_ids: Array = (manifest.get("content_ids", []) as Array).duplicate()
	for raw_content_id in world_definition_ids.keys():
		if raw_content_id not in candidate_ids:
			candidate_ids.append(raw_content_id)
	var biome := _biome_definition(biome_id)
	var ecology: Dictionary = biome.get("ecology", {}) if biome.get("ecology", {}) is Dictionary else {}
	var explicit_ids: Array = ecology.get("plant_content_ids", []) if ecology.get("plant_content_ids", []) is Array else []
	for raw_content_id in candidate_ids:
		var content_id := str(raw_content_id)
		var definition: Dictionary = BlockDefs.generated_definitions.get(content_id, {})
		if str(definition.get("kind", "")) != "plant":
			continue
		var growth: Dictionary = definition.get("growth", {}) if definition.get("growth", {}) is Dictionary else {}
		if str(growth.get("form", "")) in forms and _generated_living_content_allowed(content_id, definition, biome_id, explicit_ids):
			result.append(content_id)
	result.sort()
	return result


func _seed_cave_hanging_plants(chunk_x: int) -> void:
	if _world_random("cave-plant:%d" % chunk_x) >= CAVE_HANGING_PLANT_CHANCE:
		return
	var cave_definition := _biome_definition("cavern")
	var ecology: Dictionary = cave_definition.get("ecology", {}) if cave_definition.get("ecology", {}) is Dictionary else {}
	var plant_ids: Array[String] = []
	for raw_id in (ecology.get("plant_content_ids", []) as Array):
		var content_id := str(raw_id)
		if not content_id.is_empty():
			plant_ids.append(content_id)
	for content_id in _regional_plant_ids(chunk_x, ["hanging"], "cavern"):
		var block_name := BlockDefs.name_for_content_id(content_id)
		var plant_definition := _plant_definition(block_name)
		var visual: Dictionary = plant_definition.get("visual", {}) if plant_definition.get("visual", {}) is Dictionary else {}
		if str(visual.get("canopy_shape", "")) == "hanging_vines" and not plant_ids.has(content_id):
			plant_ids.append(content_id)
	if plant_ids.is_empty():
		return
	var start_x := chunk_x * CHUNK_WIDTH
	for attempt in 2:
		var content_index := int(_world_random("cave-plant-kind:%d:%d" % [chunk_x, attempt]) * float(plant_ids.size())) % plant_ids.size()
		var block_name := BlockDefs.name_for_content_id(plant_ids[content_index])
		var plant_definition := _plant_definition(block_name)
		if plant_definition.is_empty():
			continue
		var x := start_x + 1 + int(_world_random("cave-plant-x:%d:%d" % [chunk_x, attempt]) * float(CHUNK_WIDTH - 2))
		var cave_top := _terrain_surface_y(x) + 6
		var span := maxi(1, PROCEDURAL_BOTTOM_Y - cave_top - 2)
		var first_offset := int(_world_random("cave-plant-y:%d:%d" % [chunk_x, attempt]) * float(span))
		for offset in span:
			var y := cave_top + (first_offset + offset) % span
			var pos := Vector2i(x, y)
			if _ecology_biome_at(pos) == "cavern" and _plant_site_valid(pos, plant_definition):
				_place_generated_plant(pos, block_name, plant_definition, true)
				break


func _is_cave(x: int, y: int) -> bool:
	var phase := float(posmod(world_seed, 10000)) * 0.001
	var field := sin(float(x) * 0.23 + phase) + sin(float(y) * 0.31 - phase * 0.7) + sin(float(x + y) * 0.13 + phase * 1.9)
	return field > 1.82


func _carve_caves(chunk_x: int, rift_cave_protection: Dictionary = {}) -> void:
	var start_x := chunk_x * CHUNK_WIDTH
	var end_x := start_x + CHUNK_WIDTH
	for origin_chunk in range(chunk_x - 1, chunk_x + 2):
		if _world_random("carver-skip:%d" % origin_chunk) < 0.48:
			continue
		var origin_x := origin_chunk * CHUNK_WIDTH + int(_world_random("carver-x:%d" % origin_chunk) * CHUNK_WIDTH)
		var origin_y := 20 + int(_world_random("carver-y:%d" % origin_chunk) * 34.0)
		var length := 20 + int(_world_random("carver-length:%d" % origin_chunk) * 24.0)
		var radius := 2 + int(_world_random("carver-radius:%d" % origin_chunk) * 3.0)
		for step in length:
			var direction := -1 if _world_random("carver-direction:%d" % origin_chunk) < 0.5 else 1
			var x := origin_x + step * direction
			if x < start_x - radius or x >= end_x + radius:
				continue
			var center_y := origin_y + int(round(sin(float(step) * 0.22 + float(origin_chunk)) * 5.0))
			for dx in range(-radius, radius + 1):
				for dy in range(-radius, radius + 1):
					if dx * dx + dy * dy > radius * radius:
						continue
					var carve_pos := Vector2i(x + dx, center_y + dy)
					if carve_pos.x >= start_x and carve_pos.x < end_x and carve_pos.y > _terrain_surface_y(carve_pos.x) + 4 and carve_pos.y < PROCEDURAL_BOTTOM_Y - 2 and not rift_cave_protection.has(carve_pos):
						_erase_generated_tile(carve_pos)


func _rift_cave_spec(origin_chunk: int) -> Dictionary:
	# Keep the first procedural region readable for new players. Farther out, a rift
	# is rare enough to stay memorable but common enough to discover naturally.
	if absi(origin_chunk) < RIFT_CAVE_ORIGIN_MARGIN_CHUNKS:
		return {}
	var chance_roll := _structure_random("rift-cave-chance:%d" % origin_chunk)
	if chance_roll >= RIFT_CAVE_CHANCE:
		return {}
	# Long rifts need breathing room. Among nearby eligible origins only the
	# lowest deterministic roll survives, preventing two caves or trap columns
	# from crossing and sealing each other's route.
	for neighbor_chunk in range(origin_chunk - RIFT_CAVE_MIN_ORIGIN_SEPARATION_CHUNKS, origin_chunk + RIFT_CAVE_MIN_ORIGIN_SEPARATION_CHUNKS + 1):
		if neighbor_chunk == origin_chunk or absi(neighbor_chunk) < RIFT_CAVE_ORIGIN_MARGIN_CHUNKS:
			continue
		var neighbor_roll := _structure_random("rift-cave-chance:%d" % neighbor_chunk)
		if neighbor_roll < RIFT_CAVE_CHANCE and neighbor_roll < chance_roll:
			return {}
	var direction := -1 if _structure_random("rift-cave-direction:%d" % origin_chunk) < 0.5 else 1
	var origin_x := origin_chunk * CHUNK_WIDTH + int(_structure_random("rift-cave-x:%d" % origin_chunk) * float(CHUNK_WIDTH))
	var length := RIFT_CAVE_MIN_LENGTH + int(_structure_random("rift-cave-length:%d" % origin_chunk) * float(RIFT_CAVE_MAX_LENGTH - RIFT_CAVE_MIN_LENGTH + 1))
	var surface_y := _terrain_surface_y(origin_x)
	var hazard_roll := _structure_random("rift-cave-hazard:%d" % origin_chunk)
	var hazard := "water" if hazard_roll < 0.48 else ("lava" if hazard_roll < 0.68 else "")
	var trap_roll := _structure_random("rift-cave-trap:%d" % origin_chunk)
	var trap_kind := "sand"
	if trap_roll >= 0.22 and trap_roll < 0.42:
		trap_kind = "water"
	elif trap_roll >= 0.42 and trap_roll < 0.60:
		trap_kind = "lava"
	elif trap_roll >= 0.60 and trap_roll < 0.82:
		trap_kind = "sand_water"
	elif trap_roll >= 0.82:
		trap_kind = "sand_lava"
	return {
		"origin_chunk": origin_chunk,
		"origin_x": origin_x,
		"surface_y": surface_y,
		"direction": direction,
		"length": length,
		"hazard": hazard,
		"trap_kind": trap_kind,
	}


func _rift_cave_half_height(step: int, length: int) -> int:
	var progress := float(step) / float(maxi(1, length - 1))
	if progress < 0.10:
		return 5
	if progress < 0.28:
		return 4
	if progress < 0.55:
		return 3
	if progress < 0.82:
		return 2
	return 1


func _rift_cave_center_y(spec: Dictionary, step: int) -> int:
	var length := maxi(1, int(spec.get("length", RIFT_CAVE_MIN_LENGTH)))
	var progress := float(step) / float(maxi(1, length - 1))
	var origin_x := int(spec.get("origin_x", 0))
	var direction := int(spec.get("direction", 1))
	var x := origin_x + step * direction
	var mouth_blend := clampf(float(step) / 14.0, 0.0, 1.0)
	var descent := 1.0 + 31.0 * smoothstep(0.0, 0.72, progress)
	var phase := float(int(spec.get("origin_chunk", 0))) * 0.73
	var wave := (sin(float(step) * 0.105 + phase) * 4.5 + sin(float(step) * 0.037 - phase * 0.6) * 5.0) * mouth_blend
	var center_y := int(round(float(int(spec.get("surface_y", _terrain_surface_y(origin_x)))) + descent + wave))
	# Only the mouth is allowed to touch daylight. After fourteen columns, keep at
	# least six solid layers above the winding passage.
	var local_min_depth := _terrain_surface_y(x) - 1 + int(round(7.0 * mouth_blend))
	var half_height := _rift_cave_half_height(step, length)
	return clampi(maxi(center_y, local_min_depth), _terrain_surface_y(x) - 1, PROCEDURAL_BOTTOM_Y - 3 - half_height)


func _rift_cave_branches(spec: Dictionary) -> Array[Dictionary]:
	var branches: Array[Dictionary] = []
	var origin_chunk := int(spec.get("origin_chunk", 0))
	var main_length := int(spec.get("length", RIFT_CAVE_MIN_LENGTH))
	var count := 2 + int(_structure_random("rift-cave-branch-count:%d" % origin_chunk) * 2.0)
	for index in count:
		var base_fraction := 0.24 + float(index) * (0.50 / float(maxi(1, count - 1)))
		var jitter := (_structure_random("rift-cave-branch-anchor:%d:%d" % [origin_chunk, index]) - 0.5) * 0.10
		var anchor_step := clampi(int(round((base_fraction + jitter) * float(main_length))), 18, main_length - 24)
		var branch_direction := int(spec.get("direction", 1))
		if _structure_random("rift-cave-branch-direction:%d:%d" % [origin_chunk, index]) < 0.34:
			branch_direction *= -1
		var branch_length := 38 + int(_structure_random("rift-cave-branch-length:%d:%d" % [origin_chunk, index]) * 35.0)
		var vertical_sign := -1 if _structure_random("rift-cave-branch-vertical:%d:%d" % [origin_chunk, index]) < 0.5 else 1
		branches.append({
			"index": index,
			"anchor_step": anchor_step,
			"origin_x": int(spec["origin_x"]) + anchor_step * int(spec["direction"]),
			"origin_y": _rift_cave_center_y(spec, anchor_step),
			"direction": branch_direction,
			"vertical_sign": vertical_sign,
			"length": branch_length,
		})
	return branches


func _rift_branch_center_y(branch: Dictionary, step: int) -> int:
	var x := int(branch["origin_x"]) + step * int(branch["direction"])
	var length := maxi(1, int(branch["length"]))
	var progress := float(step) / float(maxi(1, length - 1))
	var divergence := sin(progress * PI) * 9.0 * float(int(branch["vertical_sign"]))
	var bend := sin(float(step) * 0.19 + float(int(branch["index"]))) * 2.5
	var center_y := int(round(float(int(branch["origin_y"])) + divergence + bend))
	return clampi(center_y, _terrain_surface_y(x) + 6, PROCEDURAL_BOTTOM_Y - 5)


func _rift_branch_half_height(step: int, length: int) -> int:
	var progress := float(step) / float(maxi(1, length - 1))
	return 2 if progress < 0.42 else (1 if progress < 0.84 else 0)


func _rift_cave_protection_for_chunk(chunk_x: int) -> Dictionary:
	var protected: Dictionary = {}
	var start_x := chunk_x * CHUNK_WIDTH
	var end_x := start_x + CHUNK_WIDTH
	for origin_chunk in range(chunk_x - RIFT_CAVE_ORIGIN_SCAN_CHUNKS, chunk_x + RIFT_CAVE_ORIGIN_SCAN_CHUNKS + 1):
		var spec := _rift_cave_spec(origin_chunk)
		if spec.is_empty():
			continue
		var origin_x := int(spec["origin_x"])
		var direction := int(spec["direction"])
		var length := int(spec["length"])
		for step in length:
			var x := origin_x + step * direction
			if x < start_x or x >= end_x:
				continue
			var center_y := _rift_cave_center_y(spec, step)
			var radius := _rift_cave_half_height(step, length) + RIFT_CAVE_ORDINARY_CAVE_BUFFER
			for y in range(center_y - radius, center_y + radius + 1):
				protected[Vector2i(x, y)] = true
		for branch: Dictionary in _rift_cave_branches(spec):
			var branch_length := int(branch["length"])
			for branch_step in branch_length:
				var branch_x := int(branch["origin_x"]) + branch_step * int(branch["direction"])
				if branch_x < start_x or branch_x >= end_x:
					continue
				var branch_y := _rift_branch_center_y(branch, branch_step)
				var branch_radius := _rift_branch_half_height(branch_step, branch_length) + RIFT_CAVE_ORDINARY_CAVE_BUFFER
				for y in range(branch_y - branch_radius, branch_y + branch_radius + 1):
					protected[Vector2i(branch_x, y)] = true
	return protected


func _place_rift_trap_cache(spec: Dictionary, chunk_x: int) -> void:
	var length := int(spec["length"])
	var trap_step := clampi(int(round(float(length) * 0.70)), 24, length - 12)
	var x := int(spec["origin_x"]) + trap_step * int(spec["direction"])
	if floori(float(x) / float(CHUNK_WIDTH)) != chunk_x:
		return
	var center_y := _rift_cave_center_y(spec, trap_step)
	var half_height := _rift_cave_half_height(trap_step, length)
	var chest_pos := Vector2i(x, center_y - half_height)
	if chest_pos.y <= _terrain_surface_y(x) + 5 or chest_pos.y >= PROCEDURAL_BOTTOM_Y - 5:
		return
	_set_generated_block(chest_pos.x, chest_pos.y, "chest")
	var trap_kind := str(spec.get("trap_kind", "sand"))
	containers[chest_pos] = {
		"contents": {"crystal_lantern": 1, "cobblestone": 2},
		"durability": {},
		"loot_generated": true,
		"loot_key": "",
		"loot_tier": "trap_cache",
		"one_use_cache": true,
		"aged": true,
		"trap_kind": trap_kind,
		"trap_armed": true,
		"trap_sand_count": 5 + int(_structure_random("rift-cave-trap-sand:%d" % int(spec["origin_chunk"])) * 4.0),
		"trap_gravel_count": 1 + int(_structure_random("rift-cave-trap-gravel:%d" % int(spec["origin_chunk"])) * 3.0),
	}


func _carve_rift_caves(chunk_x: int) -> void:
	var start_x := chunk_x * CHUNK_WIDTH
	var end_x := start_x + CHUNK_WIDTH
	# Twenty chunks cover the longest possible rift and its reverse branches. Evaluating
	# the same deterministic origin set for every target chunk removes visit-order
	# dependence and guarantees open seams.
	for origin_chunk in range(chunk_x - RIFT_CAVE_ORIGIN_SCAN_CHUNKS, chunk_x + RIFT_CAVE_ORIGIN_SCAN_CHUNKS + 1):
		var spec := _rift_cave_spec(origin_chunk)
		if spec.is_empty():
			continue
		var origin_x := int(spec["origin_x"])
		var direction := int(spec["direction"])
		var length := int(spec["length"])
		for step in length:
			var x := origin_x + step * direction
			if x < start_x or x >= end_x:
				continue
			var center_y := _rift_cave_center_y(spec, step)
			var half_height := _rift_cave_half_height(step, length)
			for y in range(center_y - half_height, center_y + half_height + 1):
				var carve_min_y := _terrain_surface_y(x) - 3 if step < 14 else _terrain_surface_y(x) + 4
				if y >= carve_min_y and y < PROCEDURAL_BOTTOM_Y - 2:
					_erase_generated_tile(Vector2i(x, y))
		var branches := _rift_cave_branches(spec)
		for branch: Dictionary in branches:
			var branch_length := int(branch["length"])
			for branch_step in branch_length:
				var branch_x := int(branch["origin_x"]) + branch_step * int(branch["direction"])
				if branch_x < start_x or branch_x >= end_x:
					continue
				var branch_y := _rift_branch_center_y(branch, branch_step)
				var branch_half_height := _rift_branch_half_height(branch_step, branch_length)
				for y in range(branch_y - branch_half_height, branch_y + branch_half_height + 1):
					if y > _terrain_surface_y(branch_x) + 4 and y < PROCEDURAL_BOTTOM_Y - 2:
						_erase_generated_tile(Vector2i(branch_x, y))
		# Natural pools sit in deeper bends, far from the daylight mouth.
		var hazard := str(spec.get("hazard", ""))
		if not hazard.is_empty():
			var pool_start := int(round(float(length) * 0.52))
			for pool_step in range(pool_start, pool_start + (6 if hazard == "water" else 3)):
				var pool_x := origin_x + pool_step * direction
				if pool_x < start_x or pool_x >= end_x:
					continue
				var pool_center_y := _rift_cave_center_y(spec, pool_step)
				var pool_y := pool_center_y + _rift_cave_half_height(pool_step, length)
				_set_generated_block(pool_x, pool_y, hazard, 0)
		_place_rift_trap_cache(spec, chunk_x)


func _chunk_has_rift_cave(chunk_x: int) -> bool:
	var start_x := chunk_x * CHUNK_WIDTH
	var end_x := start_x + CHUNK_WIDTH - 1
	for origin_chunk in range(chunk_x - RIFT_CAVE_ORIGIN_SCAN_CHUNKS, chunk_x + RIFT_CAVE_ORIGIN_SCAN_CHUNKS + 1):
		var spec := _rift_cave_spec(origin_chunk)
		if spec.is_empty():
			continue
		var first_x := int(spec["origin_x"])
		var last_x := first_x + (int(spec["length"]) - 1) * int(spec["direction"])
		if maxi(mini(first_x, last_x), start_x) <= mini(maxi(first_x, last_x), end_x):
			return true
		for branch: Dictionary in _rift_cave_branches(spec):
			var branch_first_x := int(branch["origin_x"])
			var branch_last_x := branch_first_x + (int(branch["length"]) - 1) * int(branch["direction"])
			if maxi(mini(branch_first_x, branch_last_x), start_x) <= mini(maxi(branch_first_x, branch_last_x), end_x):
				return true
	return false


func _generate_underground_water(chunk_x: int) -> bool:
	if _structure_random("groundwater:chance:%d" % chunk_x) >= UNDERGROUND_WATER_CHANCE:
		return false
	var buried_first := _structure_random("groundwater:kind:%d" % chunk_x) < 0.45
	if buried_first:
		return _generate_buried_water_pocket(chunk_x) or _generate_cave_water_spring(chunk_x)
	return _generate_cave_water_spring(chunk_x) or _generate_buried_water_pocket(chunk_x)


func _generate_cave_water_spring(chunk_x: int) -> bool:
	var start_x := chunk_x * CHUNK_WIDTH
	var candidates: Array[Vector2i] = []
	for x in range(start_x + 1, start_x + CHUNK_WIDTH - 1):
		var surface := _terrain_surface_y(x)
		for y in range(surface + 6, PROCEDURAL_BOTTOM_Y - 2):
			if block_id(x, y) == 0 and get_block(x, y + 1).get("solid", false) and not _open_to_sky(x, y, surface - 2):
				candidates.append(Vector2i(x, y))
	if candidates.is_empty():
		return false
	var pick := int(_structure_random("groundwater:cave-position:%d" % chunk_x) * float(candidates.size())) % candidates.size()
	var source: Vector2i = candidates[pick]
	_set_generated_block(source.x, source.y, "water", 0)
	var placed := 1
	for direction in [-1, 1]:
		if placed >= UNDERGROUND_WATER_MAX_TILES:
			break
		var neighbor := source + Vector2i(direction, 0)
		if block_id(neighbor.x, neighbor.y) == 0 and get_block(neighbor.x, neighbor.y + 1).get("solid", false) and not _open_to_sky(neighbor.x, neighbor.y, _terrain_surface_y(neighbor.x) - 2):
			_set_generated_block(neighbor.x, neighbor.y, "water", mini(7, placed * 2))
			placed += 1
	return true


func _generate_buried_water_pocket(chunk_x: int) -> bool:
	var start_x := chunk_x * CHUNK_WIDTH
	for attempt in 12:
		var x := start_x + 2 + int(_structure_random("groundwater:buried-x:%d:%d" % [chunk_x, attempt]) * float(CHUNK_WIDTH - 5))
		var surface := _terrain_surface_y(x)
		var depth_room := maxi(1, PROCEDURAL_BOTTOM_Y - surface - 16)
		var y := surface + 7 + int(_structure_random("groundwater:buried-y:%d:%d" % [chunk_x, attempt]) * float(depth_room))
		if y >= PROCEDURAL_BOTTOM_Y - 3:
			continue
		var width := 1 + int(_structure_random("groundwater:buried-width:%d:%d" % [chunk_x, attempt]) * 3.0)
		var enclosed := true
		for check_y in range(y - 1, y + 2):
			for check_x in range(x - 1, x + width + 1):
				if check_y == y and check_x >= x and check_x < x + width:
					continue
				if block_id(check_x, check_y) == 0:
					enclosed = false
					break
			if not enclosed:
				break
		if not enclosed:
			continue
		for offset in width:
			_set_generated_block(x + offset, y, "water", 0 if offset == 0 else mini(7, offset * 2))
		return true
	return false


func _generate_underground_ore_deposits(chunk_x: int) -> int:
	var start_x := chunk_x * CHUNK_WIDTH
	var exposed_stone: Array[Vector2i] = []
	for x in range(start_x + 1, start_x + CHUNK_WIDTH - 1):
		for y in range(_terrain_surface_y(x) + 7, PROCEDURAL_BOTTOM_Y - 2):
			var block_name := str(get_block(x, y).get("name", ""))
			if block_name not in ["stone", "cobblestone", "obsidian"]:
				continue
			for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				if block_id(x + direction.x, y + direction.y) == 0:
					exposed_stone.append(Vector2i(x, y))
					break
	if exposed_stone.is_empty():
		return 0
	var placed := 0
	var cluster_count := 1 + int(_structure_random("ore-cluster-count:%d" % chunk_x) * 3.0)
	for cluster_index in cluster_count:
		var pick := int(_structure_random("ore-position:%d:%d" % [chunk_x, cluster_index]) * float(exposed_stone.size())) % exposed_stone.size()
		var origin: Vector2i = exposed_stone[pick]
		var ore_roll := _structure_random("ore-kind:%d:%d" % [chunk_x, cluster_index])
		var ore_name := "copper_ore" if ore_roll < 0.55 else ("moonstone_ore" if ore_roll < 0.82 else "emerald_crystal")
		var offsets: Array[Vector2i] = [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
		var size := 1 + int(_structure_random("ore-size:%d:%d" % [chunk_x, cluster_index]) * 4.0)
		for offset_index in range(size):
			var pos := origin + offsets[offset_index]
			if str(get_block(pos.x, pos.y).get("name", "")) not in ["stone", "cobblestone", "obsidian"]:
				continue
			_set_generated_block(pos.x, pos.y, ore_name)
			placed += 1
	return placed


func _cave_structure_site(chunk_x: int) -> Dictionary:
	var start_x := chunk_x * CHUNK_WIDTH
	var candidates: Array[Vector2i] = []
	for x in range(start_x + 5, start_x + CHUNK_WIDTH - 5):
		for y in range(_terrain_surface_y(x) + 9, PROCEDURAL_BOTTOM_Y - 8):
			if block_id(x, y) == 0 and get_block(x, y + 1).get("solid", false) and not _open_to_sky(x, y, _terrain_surface_y(x) - 2):
				candidates.append(Vector2i(x, y))
	if candidates.is_empty():
		return {}
	var pick := int(_structure_random("cave-structure-site:%d" % chunk_x) * float(candidates.size())) % candidates.size()
	var anchor: Vector2i = candidates[pick]
	var left := clampi(anchor.x - 5, start_x + 1, start_x + CHUNK_WIDTH - 12)
	var floor_y := clampi(anchor.y + 1, _terrain_surface_y(anchor.x) + 10, PROCEDURAL_BOTTOM_Y - 3)
	return {"left": left, "right": left + 10, "top": floor_y - 7, "floor_y": floor_y}


func _prepare_cave_structure_chamber(site: Dictionary) -> void:
	var left := int(site["left"])
	var right := int(site["right"])
	var top := int(site["top"])
	var floor_y := int(site["floor_y"])
	for x in range(left, right + 1):
		_set_generated_block(x, top, "stone")
		_set_generated_block(x, floor_y, "cobblestone")
		for y in range(top + 1, floor_y):
			_erase_generated_tile(Vector2i(x, y))
	for y in range(top + 1, floor_y):
		_set_generated_block(left, y, "stone")
		_set_generated_block(right, y, "stone")
	# Two-block-high broken entrances preserve the connection to the cave that
	# selected this chamber and keep every landmark traversable from either side.
	for y in range(floor_y - 2, floor_y):
		_erase_generated_tile(Vector2i(left, y))
		_erase_generated_tile(Vector2i(right, y))


func _decorate_cave_structure(kind: String, site: Dictionary, chunk_x: int) -> void:
	var left := int(site["left"])
	var right := int(site["right"])
	var center := left + 5
	var top := int(site["top"])
	var floor_y := int(site["floor_y"])
	match kind:
		"mineshaft":
			for support_x in [left + 2, center, right - 2]:
				# Tree-component collision deliberately ghosts when the player pushes
				# into it, so full timber posts read clearly without blocking the route.
				for y in range(top + 1, floor_y):
					_set_generated_block(support_x, y, "wood")
				for x in range(support_x - 1, support_x + 2):
					_set_generated_block(x, top + 1, "planks")
			_set_generated_block(center - 1, top + 2, "lantern")
		"lava_grotto":
			for x in range(center - 2, center + 3):
				_set_generated_block(x, floor_y + 1, "obsidian")
				_set_generated_block(x, floor_y, "lava", 0)
			_set_generated_block(center - 3, floor_y - 1, "obsidian")
			_set_generated_block(center + 3, floor_y - 1, "obsidian")
		"amethyst_geode", "rose_crystal_grotto":
			var crystal_name := "amethyst_crystal" if kind == "amethyst_geode" else "rose_crystal"
			for entry: Dictionary in [{"x": left + 2, "h": 2}, {"x": center, "h": 4}, {"x": right - 2, "h": 3}]:
				for offset in range(int(entry["h"])):
					_set_generated_block(int(entry["x"]), floor_y - 1 - offset, crystal_name)
			for x in [left + 3, center + 2, right - 1]:
				_set_generated_block(x, top + 1, crystal_name)
		"emerald_vault":
			for y in range(top + 2, mini(top + 5, floor_y - 2)):
				_set_generated_block(left + 2, y, "stone_bricks")
				_set_generated_block(right - 2, y, "stone_bricks")
			for x in range(left + 2, right - 1):
				_set_generated_block(x, top + 2, "stone_bricks")
			for pos in [Vector2i(center - 1, floor_y - 1), Vector2i(center, floor_y - 1), Vector2i(center, floor_y - 2), Vector2i(center + 1, floor_y - 1)]:
				_set_generated_block(pos.x, pos.y, "emerald_crystal")
		"crystal_bridge":
			for x in range(center - 3, center + 4):
				_erase_generated_tile(Vector2i(x, floor_y))
				_erase_generated_tile(Vector2i(x, floor_y + 1))
				_set_generated_block(x, floor_y, "amethyst_crystal" if posmod(x, 2) == 0 else "rose_crystal")
			_set_generated_block(left + 1, top + 2, "lantern")
			_set_generated_block(right - 1, top + 2, "lantern")
		"lantern_ruins":
			for x in [left + 2, center, right - 2]:
				_set_generated_block(x, floor_y - 1, "stone_bricks")
				_set_generated_block(x, floor_y - 2, "stone_bricks")
				_set_generated_block(x, floor_y - 3, "lantern")
		"miner_camp":
			for x in range(left + 2, center + 2):
				_set_generated_block(x, floor_y, "planks")
			_set_generated_block(left + 2, floor_y - 1, "lantern")
			_place_structure_chest(Vector2i(center, floor_y - 1), "miner_camp:%d" % chunk_x)
		"underground_shrine":
			for y in range(floor_y - 4, floor_y):
				_set_generated_block(center, y, "obsidian")
			_set_generated_block(center, floor_y - 3, "moonstone_ore")
			_set_generated_block(center - 1, floor_y - 2, "amethyst_crystal")
			_set_generated_block(center + 1, floor_y - 2, "amethyst_crystal")
			_place_structure_chest(Vector2i(left + 2, floor_y - 1), "underground_shrine:%d" % chunk_x)
		"ore_gallery":
			for pos in [Vector2i(left + 1, top + 2), Vector2i(left + 2, top + 1), Vector2i(right - 1, top + 3), Vector2i(right - 2, top + 2)]:
				_set_generated_block(pos.x, pos.y, "copper_ore")
			for pos in [Vector2i(center - 1, floor_y - 1), Vector2i(center, floor_y - 1), Vector2i(center + 1, floor_y - 1)]:
				_set_generated_block(pos.x, pos.y, "moonstone_ore")
			_set_generated_block(center, top + 1, "lantern")


func _generate_cave_structure(chunk_x: int, force: bool = false) -> String:
	var score := _structure_random("cave-structure:%d" % chunk_x)
	if not force:
		if score >= CAVE_STRUCTURE_CHANCE:
			return ""
		for neighbor in [chunk_x - 1, chunk_x + 1]:
			var neighbor_score := _structure_random("cave-structure:%d" % neighbor)
			if neighbor_score < CAVE_STRUCTURE_CHANCE and neighbor_score < score:
				return ""
	var site := _cave_structure_site(chunk_x)
	if site.is_empty():
		return ""
	var index := int(_structure_random("cave-structure-kind:%d" % chunk_x) * float(CAVE_STRUCTURE_CANDIDATES.size())) % CAVE_STRUCTURE_CANDIDATES.size()
	var kind := CAVE_STRUCTURE_CANDIDATES[index]
	_prepare_cave_structure_chamber(site)
	_decorate_cave_structure(kind, site, chunk_x)
	return "system.%s" % kind


func _world_random(key: String) -> float:
	return float(posmod(("%d:%s" % [world_seed, key]).hash(), 1000003)) / 1000003.0


func _structure_random(key: String) -> float:
	# Neighboring string suffixes are correlated by String.hash(). Apply two
	# inexpensive avalanche rounds so structure chances behave independently
	# across adjacent chunks without changing terrain generation in old worlds.
	var mixed := (int(key.hash()) ^ world_seed) & 0x7fffffff
	mixed = ((mixed ^ (mixed >> 16)) * 0x45d9f3b) & 0x7fffffff
	mixed = ((mixed ^ (mixed >> 16)) * 0x45d9f3b) & 0x7fffffff
	mixed = (mixed ^ (mixed >> 16)) & 0x7fffffff
	return float(mixed) / 2147483648.0


func _set_generated_block(x: int, y: int, block_name: String, level: int = -1) -> void:
	if not BlockDefs.BLOCKS.has(block_name):
		return
	var pos := Vector2i(x, y)
	var id := int(BlockDefs.BLOCKS[block_name]["id"])
	var old_id := block_id(x, y)
	if old_id != id and BlockDefs.get_block_by_id(old_id).get("container", false):
		containers.erase(pos)
	if not tiles.has(pos):
		block_count += 1
	if old_id != id:
		_decrement_block_id(old_id)
		_increment_block_id(id)
	if old_id != 0 and old_id != id:
		_unindex_tile(pos, old_id)
	tiles[pos] = id
	_index_tile(pos, id)
	if bool(BlockDefs.BLOCKS[block_name].get("fluid", false)):
		fluid_level[pos] = level if level >= 0 else 0
		fluid_falling[pos] = false
	else:
		fluid_level.erase(pos)
		fluid_falling.erase(pos)


func _erase_generated_tile(pos: Vector2i) -> void:
	if not tiles.has(pos):
		return
	var old_id := block_id(pos.x, pos.y)
	if BlockDefs.get_block_by_id(old_id).get("container", false):
		containers.erase(pos)
	tiles.erase(pos)
	fluid_level.erase(pos)
	fluid_falling.erase(pos)
	_unindex_tile(pos, old_id)
	block_count = maxi(0, block_count - 1)
	_decrement_block_id(old_id)


func _chunk_x_for_tile(tile_x: int) -> int:
	return floori(float(tile_x) / float(CHUNK_WIDTH))


func _index_tile(pos: Vector2i, id: int = -1) -> void:
	var chunk_x := _chunk_x_for_tile(pos.x)
	if not chunk_tiles.has(chunk_x):
		chunk_tiles[chunk_x] = {}
	(chunk_tiles[chunk_x] as Dictionary)[pos] = true
	var block_id_value := block_id(pos.x, pos.y) if id < 0 else id
	if block_id_value == 0:
		return
	if not chunk_tiles_by_id.has(chunk_x):
		chunk_tiles_by_id[chunk_x] = {}
	var by_id := chunk_tiles_by_id[chunk_x] as Dictionary
	if not by_id.has(block_id_value):
		by_id[block_id_value] = {}
	(by_id[block_id_value] as Dictionary)[pos] = true


func _unindex_tile(pos: Vector2i, id: int = -1) -> void:
	var chunk_x := _chunk_x_for_tile(pos.x)
	if chunk_tiles.has(chunk_x):
		(chunk_tiles[chunk_x] as Dictionary).erase(pos)
		if (chunk_tiles[chunk_x] as Dictionary).is_empty():
			chunk_tiles.erase(chunk_x)
	var block_id_value := block_id(pos.x, pos.y) if id < 0 else id
	if block_id_value == 0 or not chunk_tiles_by_id.has(chunk_x):
		return
	var by_id := chunk_tiles_by_id[chunk_x] as Dictionary
	if by_id.has(block_id_value):
		(by_id[block_id_value] as Dictionary).erase(pos)
		if (by_id[block_id_value] as Dictionary).is_empty():
			by_id.erase(block_id_value)
	if by_id.is_empty():
		chunk_tiles_by_id.erase(chunk_x)


func _rebuild_chunk_tile_index() -> void:
	chunk_tiles.clear()
	chunk_tiles_by_id.clear()
	block_id_counts.clear()
	for pos: Vector2i in tiles.keys():
		var id := int(tiles[pos])
		_index_tile(pos, id)
		_increment_block_id(id)


func _increment_block_id(id: int) -> void:
	if id == 0:
		return
	block_id_counts[id] = int(block_id_counts.get(id, 0)) + 1


func _decrement_block_id(id: int) -> void:
	if id == 0 or not block_id_counts.has(id):
		return
	var next := int(block_id_counts[id]) - 1
	if next <= 0:
		block_id_counts.erase(id)
	else:
		block_id_counts[id] = next


func _active_tile_positions() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var seen: Dictionary = {}
	for raw_center in _active_chunk_centers().keys():
		var center := int(raw_center)
		for chunk_x in range(center - ACTIVE_SIMULATION_CHUNK_RADIUS, center + ACTIVE_SIMULATION_CHUNK_RADIUS + 1):
			if not chunk_tiles.has(chunk_x):
				continue
			for pos: Vector2i in (chunk_tiles[chunk_x] as Dictionary).keys():
				if seen.has(pos):
					continue
				seen[pos] = true
				out.append(pos)
	return out


func _active_positions_for_block_id(id: int) -> Array[Vector2i]:
	return _positions_for_block_id_in_chunk_radius(id, ACTIVE_SIMULATION_CHUNK_RADIUS)


func _positions_for_block_id_in_chunk_radius(id: int, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var seen: Dictionary = {}
	for raw_center in _active_chunk_centers():
		var center := int(raw_center)
		for chunk_x in range(center - radius, center + radius + 1):
			if not chunk_tiles_by_id.has(chunk_x):
				continue
			var by_id := chunk_tiles_by_id[chunk_x] as Dictionary
			if not by_id.has(id):
				continue
			for pos: Vector2i in (by_id[id] as Dictionary).keys():
				if not seen.has(pos):
					seen[pos] = true
					out.append(pos)
	return out


func _active_chunk_centers() -> Dictionary:
	var centers := {_active_chunk_center(): true}
	for raw_player_id in multiplayer_player_targets:
		if not multiplayer_player_targets[raw_player_id] is Dictionary:
			continue
		var remote := multiplayer_player_targets[raw_player_id] as Dictionary
		var tile_x := floori(float(remote.get("x", 0.0)) / float(BlockDefs.TILE))
		centers[floori(float(tile_x) / float(CHUNK_WIDTH))] = true
	return centers


func _system_tree_for_biome(biome_id: String, x: int) -> String:
	var weighted: Array[String] = []
	match biome_id:
		"forest": weighted = ["core.plant.oak", "core.plant.oak", "core.plant.oak", "core.plant.weeping_tree"]
		"plains": weighted = ["core.plant.oak", "core.plant.oak", "core.plant.oak", "core.plant.weeping_tree"]
		"crystal_grove": weighted = ["core.plant.weeping_tree", "core.plant.weeping_tree", "core.plant.oak"]
		"tundra": weighted = ["core.plant.pine"]
		"beach": weighted = ["core.plant.palm"]
		_: weighted = ["core.plant.oak"]
	var index := int(_world_random("tree-species:%s:%d" % [biome_id, x]) * float(weighted.size())) % weighted.size()
	return weighted[index]


func _natural_tree_for_biome(chunk_x: int, biome_id: String, x: int) -> String:
	var core_tree := _system_tree_for_biome(biome_id, x)
	# Beach has a deliberately strong visual identity. Climate-compatible UGC
	# trees may still populate generated biomes, but the system beach must always
	# grow native palms instead of broad oak-like crowns on sand.
	if biome_id == "beach":
		return core_tree
	var candidates: Array[String] = [core_tree, core_tree, core_tree]
	for content_id in _regional_plant_ids(chunk_x, ["tree"], biome_id):
		candidates.append(content_id)
	var index := int(_world_random("tree-species-catalog:%s:%d" % [biome_id, x]) * float(candidates.size())) % candidates.size()
	return candidates[index]


func _generate_tree(x: int, surface: int, tree_content_id: String = "core.plant.oak") -> void:
	var pos := Vector2i(x, surface - 1)
	if block_id(pos.x, pos.y) != 0 or plant_cells.has(pos):
		return
	# Keep both growing and already mature trees apart so their crowns do not
	# merge into a wall. Naturally generated trees complete their growth below,
	# so mature tree blocks must participate in this spacing check as well.
	for nearby_x in range(x - 3, x + 4):
		for nearby_y in range(surface - 10, surface):
			if is_tree_block(get_block(nearby_x, nearby_y)):
				return
	for existing_key in tree_growth.keys():
		var existing := existing_key as Vector2i
		if absi(existing.x - x) < 4:
			return
	for existing_key in plant_growth.keys():
		var existing := existing_key as Vector2i
		var existing_definition := _plant_definition(str((plant_growth[existing] as Dictionary).get("block_name", "")))
		if str((existing_definition.get("growth", {}) as Dictionary).get("form", "")) == "tree" and absi(existing.x - x) < 4:
			return
	var block_name := BlockDefs.name_for_content_id(tree_content_id)
	var definition := _plant_definition(block_name)
	if block_name.is_empty() or definition.is_empty() or not _plant_site_valid(pos, definition):
		return
	plant_growth[pos] = {"block_name": block_name, "stage": 1, "ticks": 0, "cells": [pos], "active_nearby_ticks": 0, "breeding_cooldown": 0, "parents": [], "traits": {}}
	plant_cells[pos] = pos
	# World generation happens off-screen. Reuse the ordinary component-tree
	# pipeline, but exhaust all of its stages immediately so newly explored
	# terrain contains a finished tree rather than a field of saplings.
	var size_roll := _structure_random("tree-size:%s:%d" % [tree_content_id, x])
	var mature_size := 0 if size_roll < 0.4 else (1 if size_roll < 0.78 else 2)
	if not _start_component_tree(pos, plant_growth[pos], definition, mature_size):
		return
	(tree_growth[pos] as Dictionary)["natural_generation"] = true
	while tree_growth.has(pos):
		_advance_tree(pos)


func _spawn_chunk_x() -> int:
	return floori(float(default_spawn.x) / float(CHUNK_WIDTH))


func _structure_footprint_overlaps_spawn(left: int, right: int) -> bool:
	return default_spawn.x >= left - STRUCTURE_SPAWN_CLEARANCE_BLOCKS and default_spawn.x <= right + STRUCTURE_SPAWN_CLEARANCE_BLOCKS


func _builtin_structure_overlaps_spawn(chunk_x: int) -> bool:
	var left := chunk_x * CHUNK_WIDTH + 2
	return _structure_footprint_overlaps_spawn(left, left + CHUNK_WIDTH - 5)


func _generated_structure_near(chunk_x: int, distance: int = STRUCTURE_MIN_CHUNK_SEPARATION) -> bool:
	for raw_chunk_x in generated_chunks:
		var existing_chunk_x := int(raw_chunk_x)
		var both_in_start_area := (
			absi(existing_chunk_x - _spawn_chunk_x()) <= STRUCTURE_START_AREA_CHUNK_RADIUS
			and absi(chunk_x - _spawn_chunk_x()) <= STRUCTURE_START_AREA_CHUNK_RADIUS
		)
		if not both_in_start_area and absi(existing_chunk_x - chunk_x) > distance:
			continue
		var chunk_data: Dictionary = generated_chunks[raw_chunk_x]
		if bool(chunk_data.get("builtin_structure", false)) or not (chunk_data.get("selected_structure_ids", []) as Array).is_empty():
			return true
	return false


func _should_generate_builtin_structure(chunk_x: int) -> bool:
	if _builtin_structure_overlaps_spawn(chunk_x) or _generated_structure_near(chunk_x):
		return false
	var score := _structure_random("builtin:%d" % chunk_x)
	if score >= BUILTIN_STRUCTURE_CHANCE:
		return false
	# Resolve neighboring candidates deterministically, independent of chunk
	# generation order. Only the lowest score inside the spacing window wins.
	for neighbor in range(chunk_x - STRUCTURE_MIN_CHUNK_SEPARATION, chunk_x + STRUCTURE_MIN_CHUNK_SEPARATION + 1):
		if neighbor == chunk_x or _builtin_structure_overlaps_spawn(neighbor):
			continue
		var neighbor_score := _structure_random("builtin:%d" % neighbor)
		if neighbor_score < BUILTIN_STRUCTURE_CHANCE and neighbor_score < score:
			return false
	return true


func _erase_generated_tree_component(start: Vector2i) -> void:
	if not is_tree_block(get_block(start.x, start.y)):
		return
	var pending: Array[Vector2i] = [start]
	var visited: Dictionary = {}
	while not pending.is_empty():
		var pos: Vector2i = pending.pop_back()
		if visited.has(pos) or not is_tree_block(get_block(pos.x, pos.y)):
			continue
		visited[pos] = true
		_erase_generated_tile(pos)
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if dx != 0 or dy != 0:
					pending.append(pos + Vector2i(dx, dy))
	for raw_anchor in tree_growth.keys():
		if visited.has(raw_anchor):
			tree_growth.erase(raw_anchor)


func _clear_structure_vegetation(left: int, right: int, ground_y: int, height: int, padding: int = STRUCTURE_VEGETATION_PADDING) -> void:
	var clear_left := left - padding
	var clear_right := right + padding
	var scan_height := maxi(height + padding, STRUCTURE_TREE_SCAN_HEIGHT)
	var clear_top := ground_y - scan_height
	# Remove the entire connected tree rather than just the intersecting blocks;
	# otherwise structures leave floating crowns or chopped trunks at their edges.
	for x in range(clear_left, clear_right + 1):
		for y in range(clear_top, ground_y):
			if is_tree_block(get_block(x, y)):
				_erase_generated_tree_component(Vector2i(x, y))
	var anchors_to_remove: Dictionary = {}
	for raw_cell in plant_cells.keys():
		var cell := raw_cell as Vector2i
		if cell.x >= clear_left and cell.x <= clear_right and cell.y >= clear_top and cell.y < ground_y:
			anchors_to_remove[plant_cells[cell]] = true
	for raw_anchor in anchors_to_remove.keys():
		var anchor := raw_anchor as Vector2i
		var data: Dictionary = plant_growth.get(anchor, {})
		for raw_cell in (data.get("cells", []) as Array):
			if raw_cell is Vector2i:
				plant_cells.erase(raw_cell)
		plant_growth.erase(anchor)
		tree_growth.erase(anchor)


func _place_structure_chest(pos: Vector2i, loot_key: String) -> bool:
	if not in_bounds(pos.x, pos.y) or block_id(pos.x, pos.y) != 0:
		return false
	if not get_block(pos.x, pos.y + 1).get("solid", false):
		return false
	_set_generated_block(pos.x, pos.y, "chest")
	containers[pos] = {"contents": {}, "durability": {}, "loot_generated": false, "loot_key": loot_key, "loot_tier": "pending"}
	return true


func _place_structure_plant(pos: Vector2i, content_id: String, mature: bool = true) -> bool:
	var block_name := BlockDefs.name_for_content_id(content_id)
	var definition := _plant_definition(block_name)
	if block_name.is_empty() or definition.is_empty() or not _plant_site_valid(pos, definition):
		return false
	return _place_generated_plant(pos, block_name, definition, mature)


func _structure_door_block_name(biome_id: String) -> String:
	match biome_id:
		"tundra", "ice": return BlockDefs.name_for_content_id("core.pine_wood")
		"desert", "beach": return BlockDefs.name_for_content_id("core.palm_wood")
		"obsidian", "crystal_grove": return BlockDefs.name_for_content_id("core.weeping_wood")
		_: return "wood"


func _place_structure_door(pos: Vector2i, biome_id: String) -> bool:
	var block_name := _structure_door_block_name(biome_id)
	if block_name.is_empty() or not BlockDefs.BLOCKS.has(block_name):
		return false
	_set_generated_block(pos.x, pos.y, block_name)
	# Tree components are intentionally reused for pass-through doors. Structure
	# generation must never turn that single decorative block into a living tree.
	tree_growth.erase(pos)
	plant_growth.erase(pos)
	plant_cells.erase(pos)
	return true


func _generate_abandoned_hut(chunk_x: int) -> bool:
	var start_x := chunk_x * CHUNK_WIDTH
	var left := start_x + 5
	var right := left + 5
	if _structure_footprint_overlaps_spawn(left, right):
		return false
	if _biome_at(left) == "riverbank" or _biome_at(right) == "riverbank":
		return false
	var floor_y := _terrain_surface_y(left)
	var ceiling_y := floor_y
	for x in range(left, right + 1):
		floor_y = maxi(floor_y, _terrain_surface_y(x))
		ceiling_y = mini(ceiling_y, _terrain_surface_y(x))
	if floor_y - ceiling_y > 2:
		return false
	_clear_structure_vegetation(left, right, floor_y, 5)
	for x in range(left, right + 1):
		_set_generated_block(x, floor_y, "planks")
	for x in range(left, right + 1):
		for y in range(floor_y - 4, floor_y):
			_erase_generated_tile(Vector2i(x, y))
	for y in range(floor_y - 3, floor_y):
		_set_generated_block(left, y, "planks")
		_set_generated_block(right, y, "planks")
	for x in range(left - 1, right + 2):
		_set_generated_block(x, floor_y - 4, "planks")
	# A trunk component behaves like the existing pass-through trees, but the
	# structure-door helper guarantees that it never starts growing.
	_place_structure_door(Vector2i(left, floor_y - 1), _biome_at(left))
	_erase_generated_tile(Vector2i(right - 1, floor_y - 4))
	_place_structure_chest(Vector2i(right - 1, floor_y - 1), "abandoned_hut:%d" % chunk_x)
	_place_structure_plant(Vector2i(left + 1, floor_y - 1), "core.plant.potted_fern")
	return true


func _structure_site(chunk_x: int, width: int, height: int, max_slope: int = 2) -> Dictionary:
	var start_x := chunk_x * CHUNK_WIDTH
	var left := start_x + floori(float(CHUNK_WIDTH - width) / 2.0)
	var right := left + width - 1
	if _structure_footprint_overlaps_spawn(left, right):
		return {}
	var surfaces: Array[int] = []
	for x in range(left, right + 1):
		surfaces.append(_terrain_surface_y(x))
	var ground_y: int = int(surfaces.max())
	if ground_y - int(surfaces.min()) > max_slope:
		return {}
	var biome := _biome_at(left + floori(float(width) / 2.0))
	var surface_block := _biome_terrain_block_name(biome, "surface_content_id", "grass")
	var fill_block := _biome_terrain_block_name(biome, "subsurface_content_id", "dirt")
	_clear_structure_vegetation(left, right, ground_y, height)
	for index in surfaces.size():
		var x := left + index
		for y in range(ground_y - height, ground_y):
			_erase_generated_tile(Vector2i(x, y))
		for y in range(int(surfaces[index]), ground_y):
			_set_generated_block(x, y, fill_block)
		_set_generated_block(x, ground_y, surface_block)
	return {"left": left, "right": right, "ground_y": ground_y}


func _generate_stone_arch(chunk_x: int) -> bool:
	var site := _structure_site(chunk_x, 7, 5)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var right := int(site["right"])
	var ground_y := int(site["ground_y"])
	for y in range(ground_y - 3, ground_y):
		_set_generated_block(left, y, "cobblestone")
		_set_generated_block(right, y, "cobblestone")
	for x in range(left, right + 1):
		_set_generated_block(x, ground_y - 4, "cobblestone")
	_set_generated_block(left + 1, ground_y - 3, "stone")
	_set_generated_block(right - 1, ground_y - 3, "stone")
	return true


func _generate_forest_shelter(chunk_x: int) -> bool:
	var site := _structure_site(chunk_x, 7, 5)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var right := int(site["right"])
	var ground_y := int(site["ground_y"])
	for y in range(ground_y - 3, ground_y):
		_set_generated_block(left, y, "wood")
		_set_generated_block(right, y, "wood")
	for x in range(left, right + 1):
		_set_generated_block(x, ground_y - 4, "leaves")
	for x in range(left + 1, right):
		_set_generated_block(x, ground_y - 3, "planks")
	_place_structure_door(Vector2i(left + 3, ground_y - 3), _biome_at(left + 3))
	_place_structure_chest(Vector2i(left + 1, ground_y - 1), "forest_shelter:%d" % chunk_x)
	_place_structure_plant(Vector2i(right - 1, ground_y - 1), "core.plant.potted_fern")
	return true


func _generate_flower_field(chunk_x: int) -> bool:
	var center_x := chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2
	if _biome_at(center_x) != "plains":
		return false
	var site := _structure_site(chunk_x, 10, 2, 1)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var ground_y := int(site["ground_y"])
	for raw_anchor in plant_growth.keys():
		var anchor := raw_anchor as Vector2i
		if anchor.x < left or anchor.x >= left + 10 or absi(anchor.y - (ground_y - 1)) > 3:
			continue
		var old_data: Dictionary = plant_growth.get(anchor, {})
		for raw_cell in (old_data.get("cells", []) as Array):
			if raw_cell is Vector2i:
				plant_cells.erase(raw_cell)
		plant_growth.erase(anchor)
	var flower_ids: Array[String] = ["core.plant.meadow_bloom", "core.plant.prairie_sprig"]
	var placed := 0
	for offset in range(10):
		# Deterministic gaps keep the field organic and leave a walkable path.
		if _structure_random("flower-gap:%d:%d" % [chunk_x, offset]) < 0.22:
			continue
		var content_index := int(_structure_random("flower-kind:%d:%d" % [chunk_x, offset]) * float(flower_ids.size())) % flower_ids.size()
		var block_name := BlockDefs.name_for_content_id(flower_ids[content_index])
		var definition := _plant_definition(block_name)
		var pos := Vector2i(left + offset, ground_y - 1)
		if block_name.is_empty() or definition.is_empty() or not _plant_site_valid(pos, definition):
			continue
		plant_growth[pos] = {"block_name": block_name, "stage": 1, "ticks": 0, "cells": [pos], "active_nearby_ticks": 0, "breeding_cooldown": 0, "parents": [], "traits": {}}
		plant_cells[pos] = pos
		placed += 1
	return placed >= 5


func _generate_plains_hill(chunk_x: int) -> bool:
	var center_x := chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2
	if _biome_at(center_x) not in ["plains", "crystal_grove"]:
		return false
	var site := _structure_site(chunk_x, 13, 9, 3)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var ground_y := int(site["ground_y"])
	var peak_height := 4 + int(_structure_random("plains-hill-height:%d" % chunk_x) * 4.0)
	# Keep the summit off-center and disturb each shoulder independently. The
	# resulting outline remains walkable but no longer reads as a perfect pyramid.
	var peak_local_x := 5 if _structure_random("plains-hill-peak-side:%d" % chunk_x) < 0.5 else 7
	for x in range(left, left + 13):
		var local_x := x - left
		var distance := absi(local_x - peak_local_x)
		var height := maxi(0, peak_height - distance)
		if height > 0 and local_x != peak_local_x:
			var shoulder_noise := int(_structure_random("plains-hill-shoulder:%d:%d" % [chunk_x, local_x]) * 3.0) - 1
			height = clampi(height + shoulder_noise, 0, peak_height - 1)
		for offset in range(1, height + 1):
			var block_name := "grass" if offset == height else ("dirt" if height - offset <= 2 else "stone")
			_set_generated_block(x, ground_y - offset, block_name)
	return true


func _generate_plains_mountain(chunk_x: int) -> bool:
	var center_x := chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2
	if _biome_at(center_x) != "plains":
		return false
	var site := _structure_site(chunk_x, 15, 74, 3)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var ground_y := int(site["ground_y"])
	# Hills are four-to-seven blocks tall. A real mountain deliberately reaches
	# roughly ten times that height and occupies almost the whole chunk.
	var peak_height := 44 + int(_structure_random("plains-mountain-height:%d" % chunk_x) * 27.0)
	var peak_local_x := 6 if _structure_random("plains-mountain-peak-side:%d" % chunk_x) < 0.5 else 8
	var peak_x := left + peak_local_x
	var left_exponent := 1.55 + _structure_random("plains-mountain-left-slope:%d" % chunk_x) * 0.5
	var right_exponent := 1.55 + _structure_random("plains-mountain-right-slope:%d" % chunk_x) * 0.5
	for x in range(left, left + 15):
		var local_x := x - left
		var distance := absi(local_x - peak_local_x)
		var side_span := float(peak_local_x if local_x < peak_local_x else 14 - peak_local_x)
		var normalized_distance := clampf(float(distance) / side_span, 0.0, 1.0)
		var slope_exponent := left_exponent if local_x < peak_local_x else right_exponent
		# Ease in from both feet of the mountain. The previous inverse-power curve
		# put roughly one fifth of the entire peak in the second column, producing
		# an abrupt wall at ground level. Independent slopes and small ridge noise
		# keep the profile organic without bringing that wall back.
		var base_height := float(peak_height) * pow(1.0 - normalized_distance, slope_exponent)
		var noise_limit := mini(3, floori(base_height * 0.08))
		var ridge_noise := roundi((_structure_random("plains-mountain-ridge:%d:%d" % [chunk_x, local_x]) * 2.0 - 1.0) * float(noise_limit))
		var height := maxi(1, roundi(base_height) + ridge_noise)
		if local_x == peak_local_x:
			height = peak_height
		var ice_depth := 0
		if height >= roundi(float(peak_height) * 0.58):
			ice_depth = clampi(2 + roundi((1.0 - normalized_distance) * 5.0), 2, 7)
		for offset in range(1, height + 1):
			var depth_from_surface := height - offset
			var block_name := "stone"
			if depth_from_surface < ice_depth:
				block_name = "ice"
			elif ice_depth == 0 and depth_from_surface == 0:
				block_name = "grass"
			elif ice_depth == 0 and depth_from_surface <= 2:
				block_name = "dirt"
			_set_generated_block(x, ground_y - offset, block_name)
	_carve_plains_mountain_tunnel(left, ground_y, chunk_x)
	if _structure_random("plains-mountain-chest:%d" % chunk_x) < PLAINS_MOUNTAIN_SUMMIT_CHEST_CHANCE:
		_place_structure_chest(Vector2i(peak_x, ground_y - peak_height - 1), "plains-mountain:%d" % chunk_x)
	return true


func _carve_plains_mountain_tunnel(left: int, ground_y: int, chunk_x: int) -> void:
	var style := int(_structure_random("plains-mountain-tunnel-style:%d" % chunk_x) * 3.0) % 3
	for x in range(left, left + 15):
		var local_x := x - left
		var clearance := 3
		match style:
			0:
				# A broad natural arch, tallest in the center.
				clearance += maxi(0, 2 - floori(float(absi(local_x - 7)) / 3.0))
			1:
				# Two irregular chambers linked by a lower passage.
				if local_x in [3, 4, 5, 9, 10, 11]:
					clearance += 2
			2:
				# A deterministic jagged ceiling exposes a different silhouette per world.
				clearance += int(_structure_random("plains-mountain-tunnel-roof:%d:%d" % [chunk_x, local_x]) * 3.0)
		for offset in range(1, clearance + 1):
			_erase_generated_tile(Vector2i(x, ground_y - offset))
	# Every style keeps a three-block-high unobstructed route. Decorative supports
	# reuse pass-through wood, while lights and crystals stay above that route.
	if style == 0:
		_set_generated_block(left + 7, ground_y - 5, "lantern")
	elif style == 1:
		for support_x in [left + 4, left + 10]:
			_set_generated_block(support_x, ground_y - 1, "wood")
			_set_generated_block(support_x, ground_y - 2, "wood")
		_set_generated_block(left + 7, ground_y - 4, "lantern")
	else:
		_set_generated_block(left + 4, ground_y - 4, "copper_ore")
		_set_generated_block(left + 10, ground_y - 4, "amethyst_crystal")
	_add_plains_mountain_supports(left, ground_y)


func _add_plains_mountain_supports(left: int, ground_y: int) -> void:
	# A continuous crossbeam makes the excavated base read as a supported tunnel
	# and blocks enough daylight to give the passage a naturally dark interior.
	for x in range(left + 2, left + 13):
		_set_generated_block(x, ground_y - 3, "wood")
	# Each post grows upward only until it meets the surviving stone mass. These
	# are structure blocks, not plant anchors, so they never grow into trees; the
	# existing tree-ghost movement keeps every beam passable.
	for support_x in [left + 2, left + 5, left + 9, left + 12]:
		for y in range(ground_y - 1, ground_y - 4, -1):
			_set_generated_block(support_x, y, "wood")
		var ceiling_y := ground_y - 81
		for y in range(ground_y - 4, ground_y - 81, -1):
			if block_id(support_x, y) != 0:
				ceiling_y = y
				break
		if ceiling_y == ground_y - 81:
			continue
		for y in range(ground_y - 4, ceiling_y, -1):
			_set_generated_block(support_x, y, "wood")


func _generate_crystal_garden(chunk_x: int) -> bool:
	var center_x := chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2
	if _biome_at(center_x) != "crystal_grove":
		return false
	var site := _structure_site(chunk_x, 9, 6, 2)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var ground_y := int(site["ground_y"])
	var formations: Array[Dictionary] = [
		{"x": left + 1, "height": 2, "block": "rose_crystal"},
		{"x": left + 4, "height": 5, "block": "amethyst_crystal"},
		{"x": left + 7, "height": 3, "block": "rose_crystal"},
	]
	for formation: Dictionary in formations:
		for offset in range(int(formation["height"])):
			_set_generated_block(int(formation["x"]), ground_y - 1 - offset, str(formation["block"]))
	_set_generated_block(left + 3, ground_y - 1, "emerald_crystal")
	_set_generated_block(left + 5, ground_y - 1, "emerald_crystal")
	return true


func _generate_buried_treasure(chunk_x: int) -> bool:
	var center_x := chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2
	if _biome_at(center_x) != "beach":
		return false
	var site := _structure_site(chunk_x, 7, 3, 4)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var ground_y := int(site["ground_y"])
	var chest_pos := Vector2i(left + 3, ground_y - 1)
	_set_generated_block(left + 2, ground_y - 1, "sand")
	_set_generated_block(left + 4, ground_y - 1, "sand")
	_set_generated_block(left + 1, ground_y, "sandstone")
	_set_generated_block(left + 5, ground_y, "sandstone")
	# Flattening a sloped beach can fill this recessed cell with sand. Expose it
	# deliberately so the treasure remains visible and immediately interactive.
	_erase_generated_tile(chest_pos)
	return _place_structure_chest(chest_pos, "buried_treasure:%d" % chunk_x)


func _generate_palm_shelter(chunk_x: int) -> bool:
	var center_x := chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2
	if _biome_at(center_x) != "beach":
		return false
	var site := _structure_site(chunk_x, 9, 6, 2)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var right := int(site["right"])
	var center := left + 4
	var ground_y := int(site["ground_y"])
	var palm_wood := BlockDefs.name_for_content_id("core.palm_wood")
	var palm_leaves := BlockDefs.name_for_content_id("core.palm_leaves")
	if palm_wood.is_empty() or palm_leaves.is_empty():
		return false
	# Two light supports, a ridge pole, and overlapping sloped fronds make the
	# silhouette read as a hand-built tropical lean-to instead of another tree.
	for support_x in [left + 1, right - 1]:
		for y in range(ground_y - 2, ground_y):
			_set_generated_block(support_x, y, palm_wood)
	_set_generated_block(center, ground_y - 4, palm_wood)
	for x in range(left, right + 1):
		var roof_y := ground_y - 4 + floori(float(absi(x - center) + 1) / 2.0)
		_set_generated_block(x, roof_y, palm_leaves)
		if x in [left, left + 1, right - 1, right]:
			_set_generated_block(x, roof_y + 1, palm_leaves)
	_place_structure_door(Vector2i(center, ground_y - 1), "beach")
	_set_generated_block(left + 2, ground_y - 1, "lantern")
	return true


func _generate_desert_obelisk(chunk_x: int) -> bool:
	var site := _structure_site(chunk_x, 7, 7, 3)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var center := left + 3
	var ground_y := int(site["ground_y"])
	var chest_pos := Vector2i(left + 1, ground_y - 1)
	var plant_pos := Vector2i(left + 5, ground_y - 1)
	for x in range(left, left + 7):
		if x == chest_pos.x or x == plant_pos.x:
			continue
		_set_generated_block(x, ground_y - 1, "cobblestone")
	for y in range(ground_y - 5, ground_y - 1):
		_set_generated_block(center, y, "stone")
	_set_generated_block(center, ground_y - 3, "obsidian")
	_set_generated_block(center - 1, ground_y - 2, "stone")
	_set_generated_block(center + 1, ground_y - 2, "stone")
	_set_generated_block(center, ground_y - 6, "stone")
	_place_structure_chest(chest_pos, "desert_obelisk:%d" % chunk_x)
	_place_structure_plant(plant_pos, "core.plant.potted_fern")
	return true


func _generate_ice_shrine(chunk_x: int) -> bool:
	var site := _structure_site(chunk_x, 7, 6)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var right := int(site["right"])
	var center := left + 3
	var ground_y := int(site["ground_y"])
	for y in range(ground_y - 3, ground_y):
		_set_generated_block(left, y, "ice")
		_set_generated_block(right, y, "ice")
	_set_generated_block(left + 1, ground_y - 4, "ice")
	_set_generated_block(right - 1, ground_y - 4, "ice")
	_set_generated_block(center - 1, ground_y - 5, "ice")
	_set_generated_block(center + 1, ground_y - 5, "ice")
	_set_generated_block(center, ground_y - 4, "obsidian")
	_place_structure_door(Vector2i(center, ground_y - 1), "ice")
	_place_structure_chest(Vector2i(right - 1, ground_y - 1), "ice_shrine:%d" % chunk_x)
	_place_structure_plant(Vector2i(left + 1, ground_y - 1), "core.plant.potted_fern")
	return true


func _generate_obsidian_gate(chunk_x: int) -> bool:
	var site := _structure_site(chunk_x, 9, 7, 3)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var right := int(site["right"])
	var ground_y := int(site["ground_y"])
	for y in range(ground_y - 5, ground_y):
		_set_generated_block(left + 1, y, "obsidian")
		_set_generated_block(right - 1, y, "obsidian")
	for x in range(left + 1, left + 4):
		_set_generated_block(x, ground_y - 6, "obsidian")
	for x in range(right - 3, right):
		_set_generated_block(x, ground_y - 6, "obsidian")
	_set_generated_block(left + 2, ground_y - 5, "cobblestone")
	_set_generated_block(right - 2, ground_y - 4, "cobblestone")
	_place_structure_chest(Vector2i(left + 4, ground_y - 1), "obsidian_gate:%d" % chunk_x)
	return true


func _generate_obsidian_spires(chunk_x: int) -> bool:
	var site := _structure_site(chunk_x, 9, 5, 3)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var right := int(site["right"])
	var ground_y := int(site["ground_y"])
	var spires := [
		{"x": left + 1, "height": 3},
		{"x": left + 3, "height": 1},
		{"x": right - 3, "height": 2},
		{"x": right - 1, "height": 4},
	]
	for spire: Dictionary in spires:
		for offset in range(int(spire["height"])):
			_set_generated_block(int(spire["x"]), ground_y - 1 - offset, "obsidian")
	return true


func _generate_lava_pool(chunk_x: int) -> bool:
	var site := _structure_site(chunk_x, 9, 3, 3)
	if site.is_empty():
		return false
	var left := int(site["left"])
	var ground_y := int(site["ground_y"])
	# A three-tile opening is dangerous but still jumpable in the side-view world.
	for x in range(left + 3, left + 6):
		_set_generated_block(x, ground_y + 1, "obsidian")
		_set_generated_block(x, ground_y, "lava", 0)
	_set_generated_block(left + 2, ground_y, "obsidian")
	_set_generated_block(left + 6, ground_y, "obsidian")
	return true


func _generate_river_bridge(chunk_x: int) -> bool:
	var start_x := chunk_x * CHUNK_WIDTH
	var left := start_x + 2
	var right := start_x + CHUNK_WIDTH - 3
	var center := start_x + CHUNK_WIDTH / 2
	if _river_depth_at(center) <= 0 or _structure_footprint_overlaps_spawn(left, right):
		return false
	var bridge_y := _surface_y(center)
	_clear_structure_vegetation(left, right, bridge_y, 4)
	for x in range(left, right + 1):
		_set_generated_block(x, bridge_y, "planks")
		for y in range(bridge_y - 3, bridge_y):
			_erase_generated_tile(Vector2i(x, y))
	for support_x in [left + 1, right - 1]:
		for y in range(bridge_y + 1, _terrain_surface_y(support_x)):
			_set_generated_block(support_x, y, "wood")
	return true


func _erase_ravine_cell(pos: Vector2i) -> void:
	if plant_cells.has(pos):
		var anchor: Vector2i = plant_cells[pos]
		var plant_data: Dictionary = plant_growth.get(anchor, {})
		for raw_cell in (plant_data.get("cells", []) as Array):
			if raw_cell is Vector2i:
				plant_cells.erase(raw_cell)
		plant_growth.erase(anchor)
	tree_growth.erase(pos)
	_erase_generated_tile(pos)


func _generate_ravine(chunk_x: int, force: bool = false) -> bool:
	if absi(chunk_x - _spawn_chunk_x()) <= STRUCTURE_START_AREA_CHUNK_RADIUS:
		return false
	if not force and _structure_random("ravine-rarity:%d" % chunk_x) >= RAVINE_STRUCTURE_CHANCE:
		return false
	var start_x := chunk_x * CHUNK_WIDTH
	var center_x := start_x + CHUNK_WIDTH / 2
	var top_half_width := 3
	var left := center_x - top_half_width
	var right := center_x + top_half_width
	if _structure_footprint_overlaps_spawn(left, right):
		return false
	var top_y := COORD_LIMIT
	for x in range(left, right + 1):
		top_y = mini(top_y, _terrain_surface_y(x) - 1)
	var depth := 32 + int(_structure_random("ravine-depth:%d" % chunk_x) * 14.0)
	var bottom_y := mini(PROCEDURAL_BOTTOM_Y - 3, top_y + depth)
	if bottom_y - top_y < 24:
		return false
	_clear_structure_vegetation(left, right, top_y + 1, STRUCTURE_TREE_SCAN_HEIGHT, 1)
	for y in range(top_y, bottom_y + 1):
		var progress := float(y - top_y) / float(maxi(1, bottom_y - top_y))
		var wall_wobble := sin(float(y + world_seed % 97) * 0.47) + sin(float(y) * 0.19)
		var half_width := clampi(2 + roundi(progress * 1.5 + wall_wobble * 0.45), 2, 4)
		var horizontal_shift := roundi(sin(float(y + chunk_x * 11) * 0.16) * 1.2)
		for x in range(center_x + horizontal_shift - half_width, center_x + horizontal_shift + half_width + 1):
			if x <= start_x + 1 or x >= start_x + CHUNK_WIDTH - 2:
				continue
			if y < _terrain_surface_y(x) - 1:
				continue
			_erase_ravine_cell(Vector2i(x, y))
	return true


func _generate_builtin_structure(chunk_x: int) -> String:
	var center_x := chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2
	var biome := _biome_at(center_x)
	var candidates: Array[String] = []
	match biome:
		"plains": candidates = ["flower_field", "plains_hill", "abandoned_hut", "stone_arch", "plains_hill", "forest_shelter", "ravine", "plains_mountain"]
		"forest": candidates = ["forest_shelter", "abandoned_hut", "stone_arch", "ravine"]
		"crystal_grove": candidates = ["crystal_garden", "crystal_garden", "plains_hill", "stone_arch", "ravine"]
		"desert": candidates = ["desert_obelisk", "stone_arch", "abandoned_hut", "ravine"]
		"tundra": candidates = ["ice_shrine", "stone_arch", "abandoned_hut", "ravine"]
		"ice": candidates = ["ice_shrine", "ice_shrine", "stone_arch", "ravine"]
		"obsidian": candidates.append_array(OBSIDIAN_STRUCTURE_CANDIDATES)
		"riverbank": candidates = ["river_bridge"]
		"beach": candidates = BEACH_STRUCTURE_CANDIDATES.duplicate()
		_:
			var environment: Dictionary = _biome_definition(biome).get("environment", {})
			var temperature := float(environment.get("temperature", 0.0))
			if temperature <= WATER_FREEZE_TEMPERATURE:
				candidates = ["ice_shrine", "stone_arch", "abandoned_hut", "ravine"]
			elif temperature >= 0.65:
				candidates = ["desert_obelisk", "stone_arch", "abandoned_hut", "ravine"]
			else:
				candidates = ["abandoned_hut", "stone_arch", "forest_shelter", "ravine"]
	if candidates.is_empty():
		return ""
	var start_index := int(_structure_random("system-kind:%d" % chunk_x) * float(candidates.size())) % candidates.size()
	for offset in candidates.size():
		var structure_id := candidates[(start_index + offset) % candidates.size()]
		var generated := false
		match structure_id:
			"abandoned_hut": generated = _generate_abandoned_hut(chunk_x)
			"stone_arch": generated = _generate_stone_arch(chunk_x)
			"forest_shelter": generated = _generate_forest_shelter(chunk_x)
			"desert_obelisk": generated = _generate_desert_obelisk(chunk_x)
			"ice_shrine": generated = _generate_ice_shrine(chunk_x)
			"obsidian_gate": generated = _generate_obsidian_gate(chunk_x)
			"obsidian_spires": generated = _generate_obsidian_spires(chunk_x)
			"lava_pool": generated = _generate_lava_pool(chunk_x)
			"river_bridge": generated = _generate_river_bridge(chunk_x)
			"ravine": generated = _generate_ravine(chunk_x)
			"flower_field": generated = _generate_flower_field(chunk_x)
			"plains_hill": generated = _generate_plains_hill(chunk_x)
			"plains_mountain": generated = _generate_plains_mountain(chunk_x)
			"crystal_garden": generated = _generate_crystal_garden(chunk_x)
			"buried_treasure": generated = _generate_buried_treasure(chunk_x)
			"palm_shelter": generated = _generate_palm_shelter(chunk_x)
		if generated:
			return "system.%s" % structure_id
	return ""


func _place_catalog_structure(chunk_x: int, builtin_structure: bool = false) -> Array[String]:
	var selected: Array[String] = []
	if builtin_structure or _generated_structure_near(chunk_x):
		return selected
	var region := floori(float(chunk_x) / float(CONTENT_REGION_CHUNKS))
	var manifest: Dictionary = regional_catalogs.get(region, {})
	var definitions: Array = []
	for raw_structure_id in (manifest.get("structure_ids", []) as Array):
		var structure_id := str(raw_structure_id)
		if structure_definitions.has(structure_id):
			definitions.append(structure_definitions[structure_id])
	definitions.sort_custom(func(a: Dictionary, b: Dictionary): return str(a.get("structure_id", "")) < str(b.get("structure_id", "")))
	var biome := _biome_at(chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2)
	for raw_definition in definitions:
		if not raw_definition is Dictionary:
			continue
		var definition := raw_definition as Dictionary
		var structure_id := str(definition.get("structure_id", ""))
		var definition_revision := int(definition.get("catalog_revision", 0))
		var placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
		if str(placement.get("layer", "surface")) != "surface":
			continue
		var allowed_biomes: Array = placement.get("biomes", []) if placement.get("biomes", []) is Array else []
		if structure_id.is_empty() or definition_revision <= 0 or definition_revision > structure_catalog_revision or biome not in allowed_biomes:
			continue
		if absi(chunk_x - _spawn_chunk_x()) < int(placement.get("minimum_chunk_distance", 0)):
			continue
		if _structure_random("catalog:%s:%d" % [structure_id, chunk_x]) >= float(placement.get("spawn_chance", 0.0)):
			continue
		var existing_in_region := 0
		for raw_chunk_x in generated_chunks:
			if floori(float(int(raw_chunk_x)) / float(CONTENT_REGION_CHUNKS)) != region:
				continue
			var chunk_data: Dictionary = generated_chunks[raw_chunk_x]
			if structure_id in (chunk_data.get("selected_structure_ids", []) as Array):
				existing_in_region += 1
		if existing_in_region >= int(placement.get("maximum_per_region", 1)):
			continue
		if _generate_catalog_structure(chunk_x, definition):
			selected.append(structure_id)
			break
	return selected


func _generate_catalog_structure(chunk_x: int, definition: Dictionary, resonant_deep: bool = false) -> bool:
	var size: Dictionary = definition.get("size", {})
	var width := int(size.get("width", 0))
	var height := int(size.get("height", 0))
	var start_x := chunk_x * CHUNK_WIDTH
	var room := maxi(1, CHUNK_WIDTH - width - 1)
	var left := start_x + 1 + int(_structure_random("position:%s:%d" % [str(definition.get("structure_id", "")), chunk_x]) * float(room))
	if not resonant_deep and _structure_footprint_overlaps_spawn(left, left + width - 1):
		return false
	var surfaces: Array[int] = []
	for x in range(left, left + width):
		surfaces.append(_resonant_floor_y(x) if resonant_deep else _terrain_surface_y(x))
	var ground_y: int = int(surfaces.max())
	var placement: Dictionary = definition.get("placement", {}) if definition.get("placement", {}) is Dictionary else {}
	if bool(placement.get("requires_flat_ground", false)) and ground_y - int(surfaces.min()) > 1:
		return false
	var top_y: int = ground_y - height
	var pending: Array[Dictionary] = []
	var pending_chests: Array[Vector2i] = []
	var pending_plants: Array[Dictionary] = []
	for raw_block in (definition.get("blocks", []) as Array):
		var block := raw_block as Dictionary
		var block_name := BlockDefs.name_for_content_id(str(block.get("content_id", "")))
		if block_name.is_empty() or not BlockDefs.BLOCKS.has(block_name):
			return false
		var pos := Vector2i(left + int(block.get("x", 0)), top_y + int(block.get("y", 0)))
		pending.append({"pos": pos, "block_name": block_name})
	for raw_chest in (definition.get("chests", []) as Array):
		var chest := raw_chest as Dictionary
		pending_chests.append(Vector2i(left + int(chest.get("x", 0)), top_y + int(chest.get("y", 0))))
	for raw_plant in (definition.get("plants", []) as Array):
		var plant := raw_plant as Dictionary
		pending_plants.append({
			"pos": Vector2i(left + int(plant.get("x", 0)), top_y + int(plant.get("y", 0))),
			"content_id": str(plant.get("content_id", "")),
		})
	for entry: Dictionary in pending:
		var pos: Vector2i = entry["pos"]
		var occupied := get_block(pos.x, pos.y)
		if occupied.get("id", 0) != 0 and not is_tree_block(occupied):
			return false
	if not resonant_deep:
		_clear_structure_vegetation(left, left + width - 1, ground_y, height)
	for entry: Dictionary in pending:
		var pos: Vector2i = entry["pos"]
		if block_id(pos.x, pos.y) != 0:
			return false
	for entry: Dictionary in pending:
		var pos: Vector2i = entry["pos"]
		_set_generated_block(pos.x, pos.y, str(entry["block_name"]))
	var structure_id := str(definition.get("structure_id", "catalog"))
	for index in pending_chests.size():
		_place_structure_chest(pending_chests[index], "catalog:%s:%d:%d" % [structure_id, chunk_x, index])
	for entry: Dictionary in pending_plants:
		var pos: Vector2i = entry["pos"]
		_place_structure_plant(pos, str(entry["content_id"]))
	return true


func _active_chunk_center() -> int:
	var player_tile_x := floori(float(player["x"]) / float(BlockDefs.TILE))
	return floori(float(player_tile_x) / float(CHUNK_WIDTH))


func _is_in_active_simulation(pos: Vector2i) -> bool:
	var chunk_x := floori(float(pos.x) / float(CHUNK_WIDTH))
	for raw_center in _active_chunk_centers().keys():
		if absi(chunk_x - int(raw_center)) <= ACTIVE_SIMULATION_CHUNK_RADIUS:
			return true
	return false


func _place_catalog_content(chunk_x: int) -> Array[String]:
	var selected: Array[String] = []
	var region := floori(float(chunk_x) / float(CONTENT_REGION_CHUNKS))
	var manifest: Dictionary = regional_catalogs.get(region, {})
	var definitions: Array = []
	for raw_content_id in (manifest.get("content_ids", []) as Array):
		var content_id := str(raw_content_id)
		if BlockDefs.generated_definitions.has(content_id):
			definitions.append(BlockDefs.generated_definitions[content_id])
	definitions.sort_custom(func(a: Dictionary, b: Dictionary): return str(a.get("content_id", "")) < str(b.get("content_id", "")))
	var biome := _biome_at(chunk_x * CHUNK_WIDTH + CHUNK_WIDTH / 2)
	for raw_definition in definitions:
		if selected.size() >= MAX_GENERATED_CONTENT_PER_CHUNK or not raw_definition is Dictionary:
			break
		var definition := raw_definition as Dictionary
		var content_id := str(definition.get("content_id", ""))
		var definition_revision := int(definition.get("catalog_revision", 0))
		var generation: Dictionary = definition.get("world_generation", {}) if definition.get("world_generation", {}) is Dictionary else {}
		var integration: Dictionary = generation.get("discovery_integration", {}) if generation.get("discovery_integration", {}) is Dictionary else {}
		if str(integration.get("layer", "surface")) != "surface":
			continue
		if content_id.is_empty() or definition_revision <= 0 or definition_revision > catalog_revision or str(generation.get("mode", "disabled")) != "natural":
			continue
		if absi(chunk_x) < int(integration.get("minimum_chunk_distance", 3)):
			continue
		if not _natural_block_allowed_in_biome(definition, biome):
			continue
		var chance := clampf(float(integration.get("introduction_chance", 0.05)), 0.0, 1.0)
		if _world_random("introduce:%s:%d" % [content_id, chunk_x]) >= chance:
			continue
		if not _content_allowed_in_region(content_id, chunk_x, int(integration.get("maximum_chunks_per_region", 2))):
			continue
		var block_name := BlockDefs.name_for_content_id(content_id)
		if block_name == "" or not _place_content_cluster(block_name, definition, chunk_x, biome):
			continue
		selected.append(content_id)
	return selected


func _natural_block_allowed_in_biome(definition: Dictionary, biome_id: String) -> bool:
	var generation: Dictionary = definition.get("world_generation", {}) if definition.get("world_generation", {}) is Dictionary else {}
	var allowed_biomes: Array = (generation.get("biomes", {}) as Dictionary).get("allowed", []) if generation.get("biomes", {}) is Dictionary else []
	if allowed_biomes.is_empty() or biome_id in allowed_biomes:
		return true
	var biome := _biome_definition(biome_id)
	var source_ids: Array = biome.get("source_content_ids", []) if biome.get("source_content_ids", []) is Array else []
	if str(definition.get("content_id", "")) in source_ids:
		return true
	var environment: Dictionary = biome.get("environment", {}) if biome.get("environment", {}) is Dictionary else {}
	var temperature := float(environment.get("temperature", 0.0))
	for raw_allowed_biome in allowed_biomes:
		var allowed_id := str(raw_allowed_biome)
		if not BiomeDefs.SYSTEM.has(allowed_id):
			continue
		var allowed_environment: Dictionary = (BiomeDefs.SYSTEM[allowed_id] as Dictionary).get("environment", {})
		if absf(temperature - float(allowed_environment.get("temperature", 0.0))) <= BIOME_DEPOSIT_TEMPERATURE_TOLERANCE:
			return true
	return false


func _content_allowed_in_region(content_id: String, chunk_x: int, maximum: int) -> bool:
	if maximum <= 0:
		return false
	var region := floori(float(chunk_x) / float(CONTENT_REGION_CHUNKS))
	var first_chunk := region * CONTENT_REGION_CHUNKS
	var ranked: Array[Dictionary] = []
	for candidate in range(first_chunk, first_chunk + CONTENT_REGION_CHUNKS):
		ranked.append({"chunk": candidate, "score": _world_random("rank:%s:%d" % [content_id, candidate])})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary): return float(a["score"]) < float(b["score"]))
	for index in mini(maximum, ranked.size()):
		if int(ranked[index]["chunk"]) == chunk_x:
			return true
	return false


func _place_content_cluster(block_name: String, definition: Dictionary, chunk_x: int, biome: String) -> bool:
	var generation: Dictionary = definition.get("world_generation", {})
	var placement: Dictionary = generation.get("placement", {})
	var environment: Dictionary = generation.get("environment", {})
	var content_id := str(definition.get("content_id", ""))
	var zones: Array = (generation.get("depth", {}) as Dictionary).get("zones", ["deep"])
	var zone := str(zones[int(_world_random("zone:%s:%d" % [content_id, chunk_x]) * zones.size()) % zones.size()])
	var start_x := chunk_x * CHUNK_WIDTH
	var center_x := start_x + int(_world_random("center-x:%s:%d" % [content_id, chunk_x]) * CHUNK_WIDTH)
	var surface := _terrain_surface_y(center_x)
	var y_range := _zone_y_range(zone, surface)
	var center_y := y_range.x + int(_world_random("center-y:%s:%d" % [content_id, chunk_x]) * maxi(1, y_range.y - y_range.x + 1))
	var raw_size: Array = placement.get("cluster_size", [1, 1])
	var min_size := clampi(int(raw_size[0]) if raw_size.size() > 0 else 1, 1, 32)
	var max_size := clampi(int(raw_size[1]) if raw_size.size() > 1 else min_size, min_size, 32)
	var count := min_size + int(_world_random("size:%s:%d" % [content_id, chunk_x]) * float(max_size - min_size + 1))
	var rarity := clampf(float(generation.get("rarity", 0.1)), 0.0, 1.0)
	count = clampi(int(round(float(count) * (0.5 + rarity))), 1, max_size)
	var shape := str(placement.get("cluster_shape", "pocket"))
	var placed := 0
	var cursor := Vector2i(center_x, center_y)
	for index in count * 4:
		var candidate := cursor
		if shape == "patch":
			candidate = Vector2i(center_x + index - count / 2, center_y + int(_world_random("patch:%s:%d:%d" % [content_id, chunk_x, index]) * 2.0))
		elif shape == "pocket":
			candidate = Vector2i(center_x + int(_world_random("pocket-x:%s:%d:%d" % [content_id, chunk_x, index]) * 5.0) - 2, center_y + int(_world_random("pocket-y:%s:%d:%d" % [content_id, chunk_x, index]) * 5.0) - 2)
		elif index > 0:
			cursor += [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN][int(_world_random("vein:%s:%d:%d" % [content_id, chunk_x, index]) * 4.0) % 4]
			candidate = cursor
		if candidate.x < start_x or candidate.x >= start_x + CHUNK_WIDTH or not _can_replace_for_generation(candidate, placement, environment):
			continue
		_set_generated_block(candidate.x, candidate.y, block_name, 0 if bool(BlockDefs.BLOCKS[block_name].get("fluid", false)) else -1)
		placed += 1
		if placed >= count:
			break
	return placed > 0


func _zone_y_range(zone: String, surface: int) -> Vector2i:
	match zone:
		"surface": return Vector2i(surface, surface + 2)
		"shallow": return Vector2i(surface + 3, mini(PROCEDURAL_BOTTOM_Y - 3, surface + 14))
		"cavern": return Vector2i(surface + 8, PROCEDURAL_BOTTOM_Y - 10)
		"underworld": return Vector2i(PROCEDURAL_BOTTOM_Y - 12, PROCEDURAL_BOTTOM_Y - 3)
		_: return Vector2i(surface + 14, PROCEDURAL_BOTTOM_Y - 8)


func _can_replace_for_generation(pos: Vector2i, placement: Dictionary, environment: Dictionary) -> bool:
	var existing_name := str(get_block(pos.x, pos.y).get("name", "air"))
	var existing_tags := _semantic_tags(existing_name)
	var replacement_tags: Array = placement.get("replaces_tags", [])
	var host_tags: Array = environment.get("requires_host_tags", [])
	if not replacement_tags.is_empty() and not _arrays_intersect(existing_tags, replacement_tags):
		return false
	if not host_tags.is_empty() and not _arrays_intersect(existing_tags, host_tags):
		return false
	if bool(environment.get("must_be_open_to_sky", false)) and not _open_to_sky(pos.x, pos.y, -16):
		return false
	var required_neighbors: Array = environment.get("requires_any_neighbor_tags", [])
	if not required_neighbors.is_empty() and not _neighbor_has_any_tag(pos, required_neighbors):
		return false
	var forbidden_neighbors: Array = environment.get("forbids_neighbor_tags", [])
	if not forbidden_neighbors.is_empty() and _neighbor_has_any_tag(pos, forbidden_neighbors):
		return false
	return true


func _neighbor_has_any_tag(pos: Vector2i, tags: Array) -> bool:
	for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		if _arrays_intersect(_semantic_tags(str(get_block(pos.x + offset.x, pos.y + offset.y).get("name", "air"))), tags):
			return true
	return false


func _arrays_intersect(a: Array, b: Array) -> bool:
	for value in a:
		if value in b:
			return true
	return false


func _semantic_tags(block_name: String) -> Array:
	var tags: Array = [block_name]
	match block_name:
		"stone", "cobblestone", "gravel": tags.append_array(["stone", "mineral"])
		"dirt", "grass": tags.append_array(["soil", "natural"])
		"sand": tags.append_array(["sediment", "soil"])
		"glass": tags.append_array(["glass", "brittle", "transparent", "crafted"])
		"charcoal": tags.append_array(["charcoal", "carbon", "burnt", "fuel", "crafted"])
		"water": tags.append_array(["water", "liquid"])
		"lava": tags.append_array(["lava", "liquid", "hot"])
		"wood", "leaves": tags.append_array(["organic", "plant"])
	var block: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	for tag in definition.get("tags", []):
		if str(tag) not in tags:
			tags.append(str(tag))
	return tags


func _new_world_id() -> String:
	return "world_%s" % Crypto.new().generate_random_bytes(16).hex_encode()


func _content_id_for_block_name(block_name: String) -> String:
	return BlockDefs.content_id_for_name(block_name)


func _block_name_for_content_id(content_id: String) -> String:
	return BlockDefs.name_for_content_id(content_id)


func _serialize_floating_island_layout() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for island: Dictionary in floating_island_layout:
		var center: Vector2i = island.get("center", Vector2i.ZERO)
		entries.append({
			"x": center.x,
			"y": center.y,
			"half_width": int(island.get("half_width", 4)),
			"depth": int(island.get("depth", 4)),
			"biome": str(island.get("biome", "plains")),
			"shape_seed": int(island.get("shape_seed", 1)),
		})
	return entries


func _deserialize_floating_island_layout(raw_layout: Variant) -> Array[Dictionary]:
	var layout: Array[Dictionary] = []
	if not raw_layout is Array:
		return layout
	for raw_island in raw_layout:
		if not raw_island is Dictionary:
			continue
		var island := raw_island as Dictionary
		var x := int(island.get("x", COORD_LIMIT + 1))
		var y := int(island.get("y", COORD_LIMIT + 1))
		var biome_id := str(island.get("biome", ""))
		if not in_bounds(x, y) or biome_id.is_empty():
			continue
		layout.append({
			"center": Vector2i(x, y),
			"half_width": clampi(int(island.get("half_width", 4)), 3, 8),
			"depth": clampi(int(island.get("depth", 4)), 2, 10),
			"biome": biome_id,
			"shape_seed": maxi(1, int(island.get("shape_seed", 1))),
		})
	return layout


func serialize_chunk_state(chunk_x: int) -> Dictionary:
	if not generated_chunks.has(chunk_x):
		return {}
	var tile_entries: Array[Dictionary] = []
	var fluid_entries: Array[Dictionary] = []
	var positions: Array = (chunk_tiles.get(chunk_x, {}) as Dictionary).keys()
	positions.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	var used_content_ids: Dictionary = {}
	for pos: Vector2i in positions:
		var block_name := BlockDefs.get_block_name(int(tiles.get(pos, 0)))
		if block_name == "air":
			continue
		var content_id := _content_id_for_block_name(block_name)
		used_content_ids[content_id] = true
		tile_entries.append({"x": pos.x, "y": pos.y, "content_id": content_id})
		if fluid_level.has(pos):
			fluid_entries.append({
				"x": pos.x,
				"y": pos.y,
				"level": int(fluid_level[pos]),
				"falling": bool(fluid_falling.get(pos, false)),
			})
	var tree_entries: Array[Dictionary] = []
	for pos: Vector2i in tree_growth.keys():
		if _chunk_x_for_tile(pos.x) == chunk_x:
			tree_entries.append({"x": pos.x, "y": pos.y, "data": (tree_growth[pos] as Dictionary).duplicate(true)})
	var plant_entries: Array[Dictionary] = []
	for anchor: Vector2i in plant_growth.keys():
		var source: Dictionary = plant_growth[anchor]
		var intersects := _chunk_x_for_tile(anchor.x) == chunk_x
		var cells: Array[Dictionary] = []
		for cell: Vector2i in source.get("cells", []):
			cells.append({"x": cell.x, "y": cell.y})
			intersects = intersects or _chunk_x_for_tile(cell.x) == chunk_x
		if intersects:
			var data := source.duplicate(true)
			data["cells"] = cells
			plant_entries.append({"x": anchor.x, "y": anchor.y, "data": data})
	var container_entries: Array[Dictionary] = []
	for pos: Vector2i in containers.keys():
		if _chunk_x_for_tile(pos.x) != chunk_x:
			continue
		var source: Dictionary = containers[pos]
		container_entries.append({"x": pos.x, "y": pos.y, "data": source.duplicate(true)})
	var definitions: Array[Dictionary] = []
	for raw_content_id in used_content_ids.keys():
		var content_id := str(raw_content_id)
		if BlockDefs.generated_definitions.has(content_id):
			definitions.append((BlockDefs.generated_definitions[content_id] as Dictionary).duplicate(true))
	var chunk_data: Dictionary = generated_chunks[chunk_x]
	var biome_id := str(chunk_data.get("biome_id", ""))
	var streamed_biomes: Array[Dictionary] = []
	if biome_id.begins_with("gen.biome.") and biome_definitions.get(biome_id) is Dictionary:
		streamed_biomes.append((biome_definitions[biome_id] as Dictionary).duplicate(true))
	var resonant_biome_id := str(chunk_data.get("resonant_biome_id", ""))
	if resonant_biome_id.begins_with("gen.biome.") and resonant_biome_id != biome_id and biome_definitions.get(resonant_biome_id) is Dictionary:
		streamed_biomes.append((biome_definitions[resonant_biome_id] as Dictionary).duplicate(true))
	return {
		"chunk_x": chunk_x,
		"chunk": chunk_data.duplicate(true),
		"tiles": tile_entries,
		"fluids": fluid_entries,
		"tree_growth": tree_entries,
		"plant_growth": plant_entries,
		"containers": container_entries,
		"generated_definitions": definitions,
		"biome_definitions": streamed_biomes,
	}


func apply_chunk_state(state: Dictionary) -> bool:
	var chunk_x := int(state.get("chunk_x", COORD_LIMIT + 1))
	if absi(chunk_x) > COORD_LIMIT / CHUNK_WIDTH or not state.get("chunk", null) is Dictionary:
		return false
	var raw_tiles = state.get("tiles", null)
	var raw_fluids = state.get("fluids", null)
	if not raw_tiles is Array or not raw_fluids is Array:
		return false
	for raw_definition in state.get("generated_definitions", []):
		if raw_definition is Dictionary and BlockDefs.register_generated_block(raw_definition) != "":
			_remember_world_definition(raw_definition)
	ingest_biome_catalog(state.get("biome_definitions", []), biome_catalog_revision)
	var incoming_tiles: Array[Dictionary] = []
	for raw_entry in raw_tiles:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var x := int(entry.get("x", COORD_LIMIT + 1))
		var y := int(entry.get("y", COORD_LIMIT + 1))
		var block_name := _block_name_for_content_id(str(entry.get("content_id", "")))
		if not in_bounds(x, y) or _chunk_x_for_tile(x) != chunk_x or block_name.is_empty() or block_name == "air":
			return false
		incoming_tiles.append({"x": x, "y": y, "block_name": block_name})
	var incoming_fluids: Dictionary = {}
	for raw_entry in raw_fluids:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var pos := Vector2i(int(entry.get("x", COORD_LIMIT + 1)), int(entry.get("y", COORD_LIMIT + 1)))
		if not in_bounds(pos.x, pos.y) or _chunk_x_for_tile(pos.x) != chunk_x:
			return false
		incoming_fluids[pos] = {"level": clampi(int(entry.get("level", 0)), 0, BlockDefs.MAX_FLUID_LEVEL - 1), "falling": bool(entry.get("falling", false))}
	_suspend_state_changed = true
	for pos: Vector2i in (chunk_tiles.get(chunk_x, {}) as Dictionary).keys():
		_erase_generated_tile(pos)
	for raw_anchor in plant_growth.keys():
		var anchor := raw_anchor as Vector2i
		var data: Dictionary = plant_growth[anchor]
		var intersects := _chunk_x_for_tile(anchor.x) == chunk_x
		for raw_cell in data.get("cells", []):
			var cell := raw_cell as Vector2i
			intersects = intersects or _chunk_x_for_tile(cell.x) == chunk_x
		if intersects:
			for raw_cell in data.get("cells", []):
				plant_cells.erase(raw_cell)
			plant_growth.erase(anchor)
	for pos: Vector2i in containers.keys():
		if _chunk_x_for_tile(pos.x) == chunk_x:
			containers.erase(pos)
	for entry: Dictionary in incoming_tiles:
		var pos := Vector2i(int(entry["x"]), int(entry["y"]))
		var fluid: Dictionary = incoming_fluids.get(pos, {})
		_set_generated_block(pos.x, pos.y, str(entry["block_name"]), int(fluid.get("level", -1)))
		if not fluid.is_empty():
			fluid_falling[pos] = bool(fluid.get("falling", false))
	for raw_entry in state.get("tree_growth", []):
		if raw_entry is Dictionary:
			var pos := Vector2i(int(raw_entry.get("x", 0)), int(raw_entry.get("y", 0)))
			if in_bounds(pos.x, pos.y) and raw_entry.get("data") is Dictionary:
				tree_growth[pos] = (raw_entry.get("data") as Dictionary).duplicate(true)
	for raw_entry in state.get("plant_growth", []):
		if not raw_entry is Dictionary or not raw_entry.get("data") is Dictionary:
			continue
		var anchor := Vector2i(int(raw_entry.get("x", 0)), int(raw_entry.get("y", 0)))
		var data := (raw_entry.get("data") as Dictionary).duplicate(true)
		var cells: Array[Vector2i] = []
		for raw_cell in data.get("cells", []):
			if raw_cell is Dictionary:
				var cell := Vector2i(int(raw_cell.get("x", 0)), int(raw_cell.get("y", 0)))
				if in_bounds(cell.x, cell.y):
					cells.append(cell)
					plant_cells[cell] = anchor
		data["cells"] = cells
		plant_growth[anchor] = data
	for raw_entry in state.get("containers", []):
		if raw_entry is Dictionary and raw_entry.get("data") is Dictionary:
			var pos := Vector2i(int(raw_entry.get("x", 0)), int(raw_entry.get("y", 0)))
			if in_bounds(pos.x, pos.y) and _chunk_x_for_tile(pos.x) == chunk_x:
				containers[pos] = (raw_entry.get("data") as Dictionary).duplicate(true)
	generated_chunks[chunk_x] = (state.get("chunk") as Dictionary).duplicate(true)
	_suspend_state_changed = false
	block_count_changed.emit(block_count)
	static_tiles_changed.emit()
	lighting_changed.emit()
	state_changed.emit()
	return true


func serialize_state(stable_order: bool = true) -> Dictionary:
	var tile_entries: Array[Dictionary] = []
	var positions: Array = tiles.keys()
	if stable_order:
		positions.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	for pos: Vector2i in positions:
		var block_name := BlockDefs.get_block_name(int(tiles[pos]))
		if block_name == "air":
			continue
		tile_entries.append({
			"x": pos.x,
			"y": pos.y,
			"content_id": _content_id_for_block_name(block_name),
		})

	var fluid_entries: Array[Dictionary] = []
	for pos: Vector2i in positions:
		if not fluid_level.has(pos):
			continue
		fluid_entries.append({
			"x": pos.x,
			"y": pos.y,
			"level": int(fluid_level[pos]),
			"falling": bool(fluid_falling.get(pos, false)),
		})

	var growth_entries: Array[Dictionary] = []
	var growth_positions: Array = tree_growth.keys()
	if stable_order:
		growth_positions.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	for pos: Vector2i in growth_positions:
		growth_entries.append({
			"x": pos.x,
			"y": pos.y,
			"data": (tree_growth[pos] as Dictionary).duplicate(true),
		})
	var plant_entries: Array[Dictionary] = []
	for anchor: Vector2i in plant_growth.keys():
		var plant_data: Dictionary = (plant_growth[anchor] as Dictionary).duplicate(true)
		var saved_cells: Array[Dictionary] = []
		for cell: Vector2i in plant_data.get("cells", []):
			saved_cells.append({"x": cell.x, "y": cell.y})
		plant_data["cells"] = saved_cells
		plant_entries.append({"x": anchor.x, "y": anchor.y, "data": plant_data})
	var creature_entries: Array[Dictionary] = []
	for creature_id: String in creatures.keys():
		var saved_creature: Dictionary = (creatures[creature_id] as Dictionary).duplicate(true)
		saved_creature["id"] = creature_id
		creature_entries.append(saved_creature)

	var burning_entries: Array[Dictionary] = []
	var burning_positions: Array = burning_tiles.keys()
	if stable_order:
		burning_positions.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	for pos: Vector2i in burning_positions:
		burning_entries.append({"x": pos.x, "y": pos.y, "steps": int(burning_tiles[pos])})
	var container_entries: Array[Dictionary] = []
	var container_positions: Array = containers.keys()
	if stable_order:
		container_positions.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	for pos: Vector2i in container_positions:
		if not get_block(pos.x, pos.y).get("container", false):
			continue
		var data: Dictionary = containers[pos]
		var saved_contents: Dictionary = {}
		var saved_container_durability: Dictionary = {}
		for block_name: String in (data.get("contents", {}) as Dictionary):
			saved_contents[_content_id_for_block_name(block_name)] = int((data.get("contents", {}) as Dictionary)[block_name])
			var durability_values: Array = (data.get("durability", {}) as Dictionary).get(block_name, []) if data.get("durability", {}) is Dictionary else []
			if not durability_values.is_empty():
				saved_container_durability[_content_id_for_block_name(block_name)] = durability_values.duplicate()
		var saved_cache_hotbar: Array[String] = []
		for block_name: String in (data.get("saved_hotbar", []) as Array):
			saved_cache_hotbar.append(_content_id_for_block_name(block_name) if not block_name.is_empty() else "")
		var saved_cache_equipment: Dictionary = {}
		if data.get("saved_equipment", {}) is Dictionary:
			for slot_name: String in (data.get("saved_equipment", {}) as Dictionary):
				var block_name := str((data.get("saved_equipment", {}) as Dictionary)[slot_name])
				saved_cache_equipment[slot_name] = _content_id_for_block_name(block_name) if not block_name.is_empty() else ""
		container_entries.append({
			"x": pos.x, "y": pos.y,
			"contents": saved_contents,
			"durability": saved_container_durability,
			"loot_generated": bool(data.get("loot_generated", true)),
			"loot_key": str(data.get("loot_key", "")),
			"loot_tier": str(data.get("loot_tier", "pending")),
			"one_use_cache": bool(data.get("one_use_cache", false)),
			"aged": bool(data.get("aged", false)),
			"trap_kind": str(data.get("trap_kind", "")),
			"trap_armed": bool(data.get("trap_armed", false)),
			"trap_sand_count": maxi(0, int(data.get("trap_sand_count", 0))),
			"trap_gravel_count": maxi(0, int(data.get("trap_gravel_count", 0))),
			"death_cache": bool(data.get("death_cache", false)),
			"cache_id": str(data.get("cache_id", "")),
			"owner_player_id": str(data.get("owner_player_id", "")),
			"created_at_unix": maxi(0, int(data.get("created_at_unix", 0))),
			"saved_hotbar": saved_cache_hotbar,
			"saved_equipment": saved_cache_equipment,
		})

	var saved_inventory: Dictionary = {}
	var saved_item_durability: Dictionary = {}
	for block_name: String in inventory:
		saved_inventory[_content_id_for_block_name(block_name)] = int(inventory[block_name])
		if item_durability.get(block_name, []) is Array and not (item_durability.get(block_name, []) as Array).is_empty():
			saved_item_durability[_content_id_for_block_name(block_name)] = (item_durability[block_name] as Array).duplicate()
	var saved_order: Array[String] = []
	for block_name: String in inv_order:
		saved_order.append(_content_id_for_block_name(block_name))
	var saved_hotbar: Array[String] = []
	for block_name: String in hotbar_slots:
		saved_hotbar.append(_content_id_for_block_name(block_name) if block_name != "" else "")
	var saved_equipment: Dictionary = {}
	for slot_name: String in equipment_slots:
		var block_name := str(equipment_slots[slot_name])
		saved_equipment[slot_name] = _content_id_for_block_name(block_name) if not block_name.is_empty() else ""
	var saved_craft_slots: Array = []
	for block_name in craft_slots:
		saved_craft_slots.append(_content_id_for_block_name(str(block_name)) if block_name != null else null)
	var saved_known_recipes: Array[Dictionary] = []
	for recipe: Dictionary in known_recipes:
		var saved_inputs: Dictionary = {}
		var saved_outputs: Dictionary = {}
		for block_name: String in recipe["in"]:
			saved_inputs[_content_id_for_block_name(block_name)] = int(recipe["in"][block_name])
		for block_name: String in recipe["out"]:
			saved_outputs[_content_id_for_block_name(block_name)] = int(recipe["out"][block_name])
		saved_known_recipes.append({"in": saved_inputs, "out": saved_outputs, "generated": true})
	var saved_chunks: Array[Dictionary] = []
	var chunk_indexes: Array = generated_chunks.keys()
	if stable_order:
		chunk_indexes.sort()
	for chunk_x in chunk_indexes:
		var chunk_data: Dictionary = generated_chunks[chunk_x]
		var saved_chunk := {
			"x": int(chunk_x),
			"catalog_revision": int(chunk_data.get("catalog_revision", 0)),
			"structure_catalog_revision": int(chunk_data.get("structure_catalog_revision", 0)),
			"selected_content_ids": (chunk_data.get("selected_content_ids", []) as Array).duplicate(),
			"selected_structure_ids": (chunk_data.get("selected_structure_ids", []) as Array).duplicate(),
			"placed_structures": (chunk_data.get("placed_structures", []) as Array).duplicate(true),
			"builtin_structure": bool(chunk_data.get("builtin_structure", false)),
			"builtin_structure_id": str(chunk_data.get("builtin_structure_id", "")),
			"cave_structure_id": str(chunk_data.get("cave_structure_id", "")),
			"biome_id": str(chunk_data.get("biome_id", "")),
			"biome_catalog_revision": int(chunk_data.get("biome_catalog_revision", 0)),
			"resonant_deep_version": int(chunk_data.get("resonant_deep_version", 0)),
			"resonant_biome_id": str(chunk_data.get("resonant_biome_id", "")),
			"selected_resonant_structure_ids": (chunk_data.get("selected_resonant_structure_ids", []) as Array).duplicate(),
		}
		if chunk_data.has("challenge_pattern"):
			saved_chunk["challenge_pattern"] = int(chunk_data["challenge_pattern"])
		saved_chunks.append(saved_chunk)
	var saved_regional_catalogs: Array[Dictionary] = []
	var region_indexes: Array = regional_catalogs.keys()
	if stable_order:
		region_indexes.sort()
	for region_x in region_indexes:
		var manifest: Dictionary = regional_catalogs[region_x]
		saved_regional_catalogs.append({
			"region_x": int(region_x),
			"content_ids": (manifest.get("content_ids", []) as Array).duplicate(),
			"structure_ids": (manifest.get("structure_ids", []) as Array).duplicate(),
			"biome_ids": (manifest.get("biome_ids", []) as Array).duplicate(),
			"content_revision": int(manifest.get("content_revision", 0)),
			"structure_revision": int(manifest.get("structure_revision", 0)),
			"biome_revision": int(manifest.get("biome_revision", 0)),
		})
	var saved_structure_definitions: Array[Dictionary] = []
	for raw_definition in structure_definitions.values():
		if raw_definition is Dictionary:
			saved_structure_definitions.append((raw_definition as Dictionary).duplicate(true))
	var saved_biome_definitions: Array[Dictionary] = []
	for raw_biome_id in biome_definitions:
		var biome_id := str(raw_biome_id)
		if biome_id.begins_with("gen.biome.") and biome_definitions[biome_id] is Dictionary:
			saved_biome_definitions.append((biome_definitions[biome_id] as Dictionary).duplicate(true))
	var saved_generated_definitions: Array[Dictionary] = []
	for raw_content_id in world_definition_ids.keys():
		var content_id := str(raw_content_id)
		if BlockDefs.generated_definitions.has(content_id):
			saved_generated_definitions.append((BlockDefs.generated_definitions[content_id] as Dictionary).duplicate(true))

	return {
		"schema_version": SAVE_SCHEMA_VERSION,
		"world_id": world_id,
		"multiplayer": {
			"access_mode": access_mode,
			"join_code": multiplayer_join_code,
			"player_states": multiplayer_player_states.duplicate(true),
		},
		"rules": {
			"keep_inventory_on_death": keep_inventory_on_death,
		},
		"generation": {
			"mode": world_mode,
			"seed": world_seed,
			"generator_version": GENERATOR_VERSION,
			"catalog_revision": catalog_revision,
			"structure_catalog_revision": structure_catalog_revision,
			"biome_catalog_revision": biome_catalog_revision,
			"chunks": saved_chunks,
			"regional_catalogs": saved_regional_catalogs,
			"structure_definitions": saved_structure_definitions,
			"biome_definitions": saved_biome_definitions,
			"floating_islands": _serialize_floating_island_layout(),
		},
		"tiles": tile_entries,
		"fluids": fluid_entries,
		"tree_growth": growth_entries,
		"plant_growth": plant_entries,
		"creatures": creature_entries,
		"creature_spawn_policy_version": CREATURE_SPAWN_POLICY_VERSION,
		"burning_tiles": burning_entries,
		"containers": container_entries,
		"inventory": saved_inventory,
		"item_durability": saved_item_durability,
		"footwear_wear_distance": footwear_wear_distance,
		"inventory_order": saved_order,
		"hotbar_slots": saved_hotbar,
		"equipment_slots": saved_equipment,
		"active_hotbar_slot": active_hotbar_slot,
		"selected_content_id": _content_id_for_block_name(selected) if selected != "" else "",
		"craft_slots": saved_craft_slots,
		"craft_slot_durability": craft_slot_durability.duplicate(),
		"known_recipes": saved_known_recipes,
		"applied_discovery_jobs": applied_discovery_jobs.duplicate(true),
		"player": player.duplicate(true),
		"default_spawn": {"x": default_spawn.x, "y": default_spawn.y},
		"spawn_change": {
			"custom": custom_spawn_set,
			"available_at_unix": spawn_change_available_at_unix,
		},
		"one_block": {
			"x": one_block_position.x,
			"y": one_block_position.y,
			"mined": one_block_mined,
			"phase": one_block_phase,
		},
		"challenge": {
			"best_distance": challenge_best_distance,
			"checkpoint_chunk": challenge_checkpoint_chunk,
			"next_milestone": challenge_next_milestone,
			"activated_encounters": _challenge_activated_encounters.keys(),
		},
		"fluid_void_limit_y": _fluid_void_limit_y,
		"fluid_tick": fluid_tick,
		"tree_tick": tree_tick,
		"creature_tick": creature_tick,
		"world_time_tick": world_time_tick,
		"granular_tick": granular_tick,
		"fire_tick": fire_tick,
		"weather": {
			"tick": weather_tick,
			"water_missing_ticks": water_missing_ticks,
			"lava_missing_ticks": lava_missing_ticks,
			"type": weather_type,
			"ticks_remaining": weather_ticks_remaining,
			"target": {"x": weather_target.x, "y": weather_target.y},
			"result": weather_result,
			"is_recovery": weather_is_recovery,
			"lightning_sfx_played": lightning_sfx_played,
		},
		"generated_definitions": saved_generated_definitions,
	}


func repair_serialized_state(state: Dictionary) -> Dictionary:
	_ensure_core_tree_blocks()
	_ensure_core_plants()
	_ensure_core_creatures()
	if int(state.get("schema_version", -1)) != SAVE_SCHEMA_VERSION:
		return {}
	if str(state.get("world_id", "")).is_empty() or not state.get("tiles", null) is Array:
		return {}
	var repaired := state.duplicate(true)
	var rules: Dictionary = repaired.get("rules", {}) if repaired.get("rules", {}) is Dictionary else {}
	rules["keep_inventory_on_death"] = bool(rules.get("keep_inventory_on_death", true))
	repaired["rules"] = rules
	var generation: Dictionary = repaired.get("generation", {}) if repaired.get("generation", {}) is Dictionary else {}
	generation["mode"] = str(generation.get("mode", WORLD_MODE_SKYBLOCK)) if str(generation.get("mode", WORLD_MODE_SKYBLOCK)) in [WORLD_MODE_SKYBLOCK, WORLD_MODE_FLOATING_ISLANDS, WORLD_MODE_PROCEDURAL, WORLD_MODE_ONE_BLOCK, WORLD_MODE_CHALLENGE, WORLD_MODE_DUEL] else WORLD_MODE_SKYBLOCK
	generation["seed"] = int(generation.get("seed", 0))
	for key in ["catalog_revision", "structure_catalog_revision", "biome_catalog_revision"]:
		generation[key] = maxi(0, int(generation.get(key, 0)))
	for key in ["chunks", "regional_catalogs", "structure_definitions", "biome_definitions", "floating_islands"]:
		if not generation.get(key, null) is Array:
			generation[key] = []
	repaired["generation"] = generation
	var one_block_data: Dictionary = repaired.get("one_block", {}) if repaired.get("one_block", {}) is Dictionary else {}
	one_block_data["x"] = clampi(int(one_block_data.get("x", ISLAND_CX)), -COORD_LIMIT, COORD_LIMIT)
	one_block_data["y"] = clampi(int(one_block_data.get("y", ISLAND_CY)), -COORD_LIMIT, COORD_LIMIT)
	one_block_data["mined"] = maxi(0, int(one_block_data.get("mined", 0)))
	one_block_data["phase"] = _one_block_phase_index_for_mined(int(one_block_data["mined"]))
	repaired["one_block"] = one_block_data
	var challenge_data: Dictionary = repaired.get("challenge", {}) if repaired.get("challenge", {}) is Dictionary else {}
	challenge_data["best_distance"] = maxi(0, int(challenge_data.get("best_distance", 0)))
	challenge_data["checkpoint_chunk"] = maxi(0, int(challenge_data.get("checkpoint_chunk", 0)))
	challenge_data["next_milestone"] = maxi(100, int(challenge_data.get("next_milestone", 100)))
	if not challenge_data.get("activated_encounters", null) is Array:
		challenge_data["activated_encounters"] = []
	repaired["challenge"] = challenge_data

	var valid_definitions: Array[Dictionary] = []
	var raw_definitions = repaired.get("generated_definitions", [])
	if raw_definitions is Array:
		for raw_definition in raw_definitions:
			if raw_definition is Dictionary and BlockDefs.register_generated_block(raw_definition) != "":
				valid_definitions.append((raw_definition as Dictionary).duplicate(true))
	repaired["generated_definitions"] = valid_definitions

	var repaired_tiles: Array[Dictionary] = []
	var repaired_tile_names: Dictionary = {}
	for raw_entry in repaired["tiles"]:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		var x := int(entry.get("x", COORD_LIMIT + 1))
		var y := int(entry.get("y", COORD_LIMIT + 1))
		if not in_bounds(x, y):
			continue
		var content_id := str(entry.get("content_id", ""))
		var block_name := _block_name_for_content_id(content_id)
		if block_name.is_empty() or block_name == "air":
			content_id = "core.stone"
			block_name = "stone"
		var pos := Vector2i(x, y)
		repaired_tile_names[pos] = block_name
		repaired_tiles.append({"x": x, "y": y, "content_id": content_id})
	repaired["tiles"] = repaired_tiles

	var repaired_fluids: Array[Dictionary] = []
	var raw_fluids = repaired.get("fluids", [])
	if raw_fluids is Array:
		for raw_entry in raw_fluids:
			if not raw_entry is Dictionary:
				continue
			var entry := raw_entry as Dictionary
			var pos := Vector2i(int(entry.get("x", COORD_LIMIT + 1)), int(entry.get("y", COORD_LIMIT + 1)))
			var block_name := str(repaired_tile_names.get(pos, ""))
			if not in_bounds(pos.x, pos.y) or block_name.is_empty() or not BlockDefs.BLOCKS.get(block_name, {}).get("fluid", false):
				continue
			repaired_fluids.append({"x": pos.x, "y": pos.y, "level": clampi(int(entry.get("level", 0)), 0, BlockDefs.MAX_FLUID_LEVEL - 1), "falling": bool(entry.get("falling", false))})
	repaired["fluids"] = repaired_fluids

	var repaired_growth: Array[Dictionary] = []
	var raw_growth = repaired.get("tree_growth", [])
	if raw_growth is Array:
		for raw_entry in raw_growth:
			if not raw_entry is Dictionary:
				continue
			var entry := raw_entry as Dictionary
			var pos := Vector2i(int(entry.get("x", COORD_LIMIT + 1)), int(entry.get("y", COORD_LIMIT + 1)))
			if in_bounds(pos.x, pos.y) and entry.get("data", null) is Dictionary:
				repaired_growth.append(entry.duplicate(true))
	repaired["tree_growth"] = repaired_growth

	var repaired_plants: Array[Dictionary] = []
	var raw_plants = repaired.get("plant_growth", [])
	if raw_plants is Array:
		for raw_entry in raw_plants:
			if not raw_entry is Dictionary:
				continue
			var entry := raw_entry as Dictionary
			var anchor := Vector2i(int(entry.get("x", COORD_LIMIT + 1)), int(entry.get("y", COORD_LIMIT + 1)))
			if not in_bounds(anchor.x, anchor.y) or not entry.get("data", null) is Dictionary:
				continue
			var data := (entry.get("data", {}) as Dictionary).duplicate(true)
			var cells: Array[Dictionary] = []
			var raw_cells = data.get("cells", [])
			if raw_cells is Array:
				for raw_cell in raw_cells:
					if not raw_cell is Dictionary:
						continue
					var cell := Vector2i(int(raw_cell.get("x", COORD_LIMIT + 1)), int(raw_cell.get("y", COORD_LIMIT + 1)))
					if in_bounds(cell.x, cell.y):
						cells.append({"x": cell.x, "y": cell.y})
			if cells.is_empty():
				cells.append({"x": anchor.x, "y": anchor.y})
			data["cells"] = cells
			repaired_plants.append({"x": anchor.x, "y": anchor.y, "data": data})
	repaired["plant_growth"] = repaired_plants

	for key in ["creatures", "burning_tiles", "containers"]:
		var cleaned: Array[Dictionary] = []
		var raw_entries = repaired.get(key, [])
		if raw_entries is Array:
			for raw_entry in raw_entries:
				if raw_entry is Dictionary:
					var cleaned_entry := (raw_entry as Dictionary).duplicate(true)
					if key == "containers" and not cleaned_entry.get("contents", null) is Dictionary:
						cleaned_entry["contents"] = {}
					cleaned.append(cleaned_entry)
		repaired[key] = cleaned

	var repaired_inventory: Dictionary = {}
	var raw_inventory = repaired.get("inventory", {})
	if raw_inventory is Dictionary:
		for raw_content_id in raw_inventory:
			var content_id := str(raw_content_id)
			var amount := int((raw_inventory as Dictionary)[raw_content_id])
			if amount > 0 and not _block_name_for_content_id(content_id).is_empty():
				repaired_inventory[content_id] = amount
	repaired["inventory"] = repaired_inventory
	for key in ["inventory_order", "hotbar_slots"]:
		if not repaired.get(key, null) is Array:
			repaired[key] = []
	if not repaired.get("equipment_slots", null) is Dictionary:
		repaired["equipment_slots"] = {}
	var repaired_craft_slots: Array = []
	var raw_craft_slots = repaired.get("craft_slots", [])
	if raw_craft_slots is Array:
		for raw_content_id in raw_craft_slots:
			if raw_content_id == null:
				repaired_craft_slots.append(null)
			else:
				var content_id := str(raw_content_id)
				repaired_craft_slots.append(content_id if not _block_name_for_content_id(content_id).is_empty() else null)
	repaired["craft_slots"] = repaired_craft_slots
	var repaired_craft_durability: Array[int] = [0, 0, 0, 0]
	var raw_craft_durability = repaired.get("craft_slot_durability", [])
	if raw_craft_durability is Array:
		for index in mini(repaired_craft_durability.size(), raw_craft_durability.size()):
			repaired_craft_durability[index] = clampi(int(raw_craft_durability[index]), 0, 2000)
	repaired["craft_slot_durability"] = repaired_craft_durability

	var repaired_recipes: Array[Dictionary] = []
	var raw_recipes = repaired.get("known_recipes", [])
	if raw_recipes is Array:
		for raw_recipe in raw_recipes:
			if not raw_recipe is Dictionary:
				continue
			var recipe := raw_recipe as Dictionary
			if not recipe.get("in", null) is Dictionary or not recipe.get("out", null) is Dictionary:
				continue
			var inputs: Dictionary = {}
			var outputs: Dictionary = {}
			for raw_content_id in (recipe.get("in", {}) as Dictionary):
				var content_id := str(raw_content_id)
				var amount := int((recipe.get("in", {}) as Dictionary)[raw_content_id])
				if amount > 0 and not _block_name_for_content_id(content_id).is_empty():
					inputs[content_id] = amount
			for raw_content_id in (recipe.get("out", {}) as Dictionary):
				var content_id := str(raw_content_id)
				var amount := int((recipe.get("out", {}) as Dictionary)[raw_content_id])
				if amount > 0 and not _block_name_for_content_id(content_id).is_empty():
					outputs[content_id] = amount
			if not inputs.is_empty() and not outputs.is_empty():
				repaired_recipes.append({"in": inputs, "out": outputs, "generated": true})
	repaired["known_recipes"] = repaired_recipes
	if not repaired.get("applied_discovery_jobs", null) is Dictionary:
		repaired["applied_discovery_jobs"] = {}

	var spawn_data: Dictionary = repaired.get("default_spawn", {}) if repaired.get("default_spawn", {}) is Dictionary else {}
	spawn_data["x"] = int(spawn_data.get("x", ISLAND_CX + 3))
	spawn_data["y"] = int(spawn_data.get("y", ISLAND_CY))
	repaired["default_spawn"] = spawn_data
	var repaired_player := player.duplicate(true)
	repaired_player["x"] = float(spawn_data["x"] * BlockDefs.TILE) + (BlockDefs.TILE - float(repaired_player["w"])) * 0.5
	repaired_player["y"] = float(spawn_data["y"] * BlockDefs.TILE) - float(repaired_player["h"])
	var raw_player = repaired.get("player", {})
	if raw_player is Dictionary:
		for key in (raw_player as Dictionary):
			repaired_player[key] = (raw_player as Dictionary)[key]
	for key in ["x", "y", "w", "h"]:
		if typeof(repaired_player.get(key)) not in [TYPE_INT, TYPE_FLOAT]:
			repaired_player[key] = player[key]
	repaired["player"] = repaired_player
	if not repaired.get("spawn_change", null) is Dictionary:
		repaired["spawn_change"] = {}
	if not repaired.get("weather", null) is Dictionary:
		repaired["weather"] = {}
	return repaired


func _load_container_hotbar(raw_hotbar: Variant, contents: Dictionary) -> Array[String]:
	var loaded: Array[String] = ["", "", "", "", "", ""]
	if not raw_hotbar is Array:
		return loaded
	for index in mini(loaded.size(), (raw_hotbar as Array).size()):
		var block_name := _block_name_for_content_id(str((raw_hotbar as Array)[index]))
		if contents.get(block_name, 0) > 0 and equipment_slot_for_item(block_name).is_empty():
			loaded[index] = block_name
	return loaded


func _load_container_equipment(raw_equipment: Variant, contents: Dictionary) -> Dictionary:
	var loaded := {"hand": "", "feet": ""}
	if not raw_equipment is Dictionary:
		return loaded
	for slot_name: String in ["hand", "feet"]:
		var block_name := _block_name_for_content_id(str((raw_equipment as Dictionary).get(slot_name, "")))
		if contents.get(block_name, 0) > 0 and equipment_slot_for_item(block_name) == slot_name:
			loaded[slot_name] = block_name
	return loaded


func deserialize_state(state: Dictionary) -> bool:
	# A dedicated server commonly starts by restoring an existing world without
	# creating a new one first. Register non-default tree components before plant
	# definitions so saved palm, pine, and weeping saplings can resolve their trunk
	# and foliage content IDs and continue growing after a cold restart.
	_ensure_core_tree_blocks()
	_ensure_core_plants()
	_ensure_core_creatures()
	_glass_tide_bridge_queue.clear()
	_glass_tide_bridge_total = 0
	_glass_tide_bridge_step_ticks = 0
	if int(state.get("schema_version", -1)) != SAVE_SCHEMA_VERSION:
		return false
	if not state.get("tiles", null) is Array or not state.get("inventory", null) is Dictionary:
		return false
	var loaded_world_id := str(state.get("world_id", ""))
	if loaded_world_id.is_empty():
		return false
	var multiplayer_data: Dictionary = state.get("multiplayer", {}) if state.get("multiplayer", {}) is Dictionary else {}
	var loaded_access_mode := str(multiplayer_data.get("access_mode", ACCESS_MODE_OFFLINE))
	if loaded_access_mode not in [ACCESS_MODE_OFFLINE, ACCESS_MODE_PUBLIC, ACCESS_MODE_INVITE_CODE]:
		loaded_access_mode = ACCESS_MODE_OFFLINE
	var loaded_join_code := str(multiplayer_data.get("join_code", ""))
	var loaded_multiplayer_player_states: Dictionary = multiplayer_data.get("player_states", {}).duplicate(true) if multiplayer_data.get("player_states", {}) is Dictionary else {}
	var raw_generated = state.get("generated_definitions", [])
	if not raw_generated is Array:
		return false
	var reference_state: Dictionary = state.duplicate(true)
	reference_state.erase("generated_definitions")
	var serialized_references: String = JSON.stringify(reference_state)
	world_definition_ids.clear()
	for definition in raw_generated:
		if not definition is Dictionary or BlockDefs.register_generated_block(definition) == "":
			return false
		var content_id: String = str((definition as Dictionary).get("content_id", ""))
		if not content_id.is_empty() and serialized_references.contains(content_id):
			_remember_world_definition(definition)

	var loaded_tiles: Dictionary = {}
	var loaded_levels: Dictionary = {}
	var loaded_falling: Dictionary = {}
	for raw_entry in state["tiles"]:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var x := int(entry.get("x", COORD_LIMIT + 1))
		var y := int(entry.get("y", COORD_LIMIT + 1))
		var block_name := _block_name_for_content_id(str(entry.get("content_id", "")))
		if not in_bounds(x, y) or block_name == "" or block_name == "air":
			return false
		loaded_tiles[Vector2i(x, y)] = int(BlockDefs.BLOCKS[block_name]["id"])

	var raw_fluids = state.get("fluids", [])
	if not raw_fluids is Array:
		return false
	for raw_entry in raw_fluids:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var pos := Vector2i(int(entry.get("x", COORD_LIMIT + 1)), int(entry.get("y", COORD_LIMIT + 1)))
		if not loaded_tiles.has(pos) or not is_fluid_id(int(loaded_tiles[pos])):
			return false
		loaded_levels[pos] = clampi(int(entry.get("level", 0)), 0, BlockDefs.MAX_FLUID_LEVEL - 1)
		loaded_falling[pos] = bool(entry.get("falling", false))

	var loaded_growth: Dictionary = {}
	var raw_growth = state.get("tree_growth", [])
	if not raw_growth is Array:
		return false
	for raw_entry in raw_growth:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var pos := Vector2i(int(entry.get("x", COORD_LIMIT + 1)), int(entry.get("y", COORD_LIMIT + 1)))
		var data = entry.get("data", null)
		if not in_bounds(pos.x, pos.y) or not data is Dictionary:
			return false
		loaded_growth[pos] = (data as Dictionary).duplicate(true)

	var loaded_plant_growth: Dictionary = {}
	var loaded_plant_cells: Dictionary = {}
	var raw_plants = state.get("plant_growth", [])
	if not raw_plants is Array:
		return false
	for raw_entry in raw_plants:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var anchor := Vector2i(int(entry.get("x", COORD_LIMIT + 1)), int(entry.get("y", COORD_LIMIT + 1)))
		var raw_data = entry.get("data", null)
		if not in_bounds(anchor.x, anchor.y) or not raw_data is Dictionary:
			return false
		var data := (raw_data as Dictionary).duplicate(true)
		var loaded_cells: Array[Vector2i] = []
		for raw_cell in data.get("cells", []):
			if not raw_cell is Dictionary:
				continue
			var cell := Vector2i(int(raw_cell.get("x", COORD_LIMIT + 1)), int(raw_cell.get("y", COORD_LIMIT + 1)))
			if in_bounds(cell.x, cell.y):
				loaded_cells.append(cell)
				loaded_plant_cells[cell] = anchor
		data["cells"] = loaded_cells
		loaded_plant_growth[anchor] = data

	var loaded_creatures: Dictionary = {}
	var raw_creatures = state.get("creatures", [])
	if not raw_creatures is Array:
		return false
	for raw_creature in raw_creatures:
		if not raw_creature is Dictionary:
			continue
		var creature := (raw_creature as Dictionary).duplicate(true)
		var creature_id := str(creature.get("id", ""))
		var block_name := _block_name_for_content_id(str(creature.get("content_id", "")))
		if creature_id.is_empty() or block_name.is_empty() or not BlockDefs.BLOCKS[block_name].get("creature_item", false):
			continue
		creature["block_name"] = block_name
		loaded_creatures[creature_id] = creature

	var loaded_burning: Dictionary = {}
	var raw_burning = state.get("burning_tiles", [])
	if not raw_burning is Array:
		return false
	for raw_entry in raw_burning:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var pos := Vector2i(int(entry.get("x", COORD_LIMIT + 1)), int(entry.get("y", COORD_LIMIT + 1)))
		var steps := int(entry.get("steps", 0))
		if not in_bounds(pos.x, pos.y) or not loaded_tiles.has(pos) or steps <= 0:
			continue
		var block := BlockDefs.get_block_by_id(int(loaded_tiles[pos]))
		if float(block.get("flammability", 0.0)) > 0.0:
			loaded_burning[pos] = mini(steps, FIRE_BURN_STEPS * 2)

	var loaded_containers: Dictionary = {}
	var raw_containers = state.get("containers", [])
	if not raw_containers is Array:
		return false
	for raw_entry in raw_containers:
		if not raw_entry is Dictionary:
			return false
		var entry := raw_entry as Dictionary
		var pos := Vector2i(int(entry.get("x", COORD_LIMIT + 1)), int(entry.get("y", COORD_LIMIT + 1)))
		if not in_bounds(pos.x, pos.y) or not loaded_tiles.has(pos) or not BlockDefs.get_block_by_id(int(loaded_tiles[pos])).get("container", false):
			continue
		var loaded_contents: Dictionary = {}
		var raw_contents = entry.get("contents", {})
		if not raw_contents is Dictionary:
			return false
		for content_id: String in raw_contents:
			var block_name := _block_name_for_content_id(content_id)
			var amount := int(raw_contents[content_id])
			if block_name.is_empty() or amount <= 0:
				continue
			loaded_contents[block_name] = amount
		var loaded_container_durability: Dictionary = {}
		var raw_container_durability = entry.get("durability", {})
		if raw_container_durability is Dictionary:
			for content_id: String in raw_container_durability:
				var block_name := _block_name_for_content_id(content_id)
				var raw_values = (raw_container_durability as Dictionary)[content_id]
				var maximum := item_max_durability(block_name)
				if not loaded_contents.has(block_name) or maximum <= 0 or not raw_values is Array:
					continue
				var values: Array[int] = []
				for raw_value in raw_values:
					if values.size() >= int(loaded_contents[block_name]):
						break
					values.append(clampi(int(raw_value), 1, maximum))
				if not values.is_empty():
					loaded_container_durability[block_name] = values
			loaded_containers[pos] = {
			"contents": loaded_contents,
			"durability": loaded_container_durability,
			"loot_generated": bool(entry.get("loot_generated", true)),
			"loot_key": str(entry.get("loot_key", "")),
			"loot_tier": str(entry.get("loot_tier", "pending")),
				"one_use_cache": bool(entry.get("one_use_cache", false)),
				"aged": bool(entry.get("aged", false)),
				"trap_kind": str(entry.get("trap_kind", "")),
				"trap_armed": bool(entry.get("trap_armed", false)),
				"trap_sand_count": maxi(0, int(entry.get("trap_sand_count", 0))),
				"trap_gravel_count": maxi(0, int(entry.get("trap_gravel_count", 0))),
				"death_cache": bool(entry.get("death_cache", false)),
				"cache_id": str(entry.get("cache_id", "")),
				"owner_player_id": str(entry.get("owner_player_id", "")),
				"created_at_unix": maxi(0, int(entry.get("created_at_unix", 0))),
				"saved_hotbar": _load_container_hotbar(entry.get("saved_hotbar", []), loaded_contents),
				"saved_equipment": _load_container_equipment(entry.get("saved_equipment", {}), loaded_contents),
			}

	var loaded_inventory: Dictionary = {}
	for content_id: String in state["inventory"]:
		var block_name := _block_name_for_content_id(content_id)
		var amount := int(state["inventory"][content_id])
		if block_name == "" or block_name == "air" or amount < 0:
			return false
		if amount > 0:
			loaded_inventory[block_name] = amount
	var loaded_item_durability: Dictionary = {}
	var raw_item_durability = state.get("item_durability", {})
	if raw_item_durability is Dictionary:
		for content_id: String in raw_item_durability:
			var block_name := _block_name_for_content_id(content_id)
			var raw_values = (raw_item_durability as Dictionary)[content_id]
			var maximum := item_max_durability(block_name)
			if not loaded_inventory.has(block_name) or maximum <= 0 or not raw_values is Array:
				continue
			var values: Array[int] = []
			for raw_value in raw_values:
				if values.size() >= int(loaded_inventory[block_name]):
					break
				values.append(clampi(int(raw_value), 1, maximum))
			while values.size() < int(loaded_inventory[block_name]):
				values.append(maximum)
			loaded_item_durability[block_name] = values
	for block_name: String in loaded_inventory:
		var maximum := item_max_durability(block_name)
		if maximum > 0 and not loaded_item_durability.has(block_name):
			var values: Array[int] = []
			for _item in int(loaded_inventory[block_name]):
				values.append(maximum)
			loaded_item_durability[block_name] = values
	var loaded_order: Array[String] = []
	var raw_order = state.get("inventory_order", [])
	if not raw_order is Array:
		return false
	for content_id in raw_order:
		var block_name := _block_name_for_content_id(str(content_id))
		if block_name != "" and loaded_inventory.has(block_name) and not loaded_order.has(block_name):
			loaded_order.append(block_name)
	for block_name: String in loaded_inventory:
		if not loaded_order.has(block_name):
			loaded_order.append(block_name)
	var loaded_hotbar: Array[String] = ["", "", "", "", "", ""]
	var raw_hotbar = state.get("hotbar_slots", [])
	if not raw_hotbar is Array:
		return false
	for i in mini(BlockDefs.HOTBAR_SIZE, raw_hotbar.size()):
		var hotbar_name := _block_name_for_content_id(str(raw_hotbar[i]))
		if hotbar_name != "" and loaded_inventory.has(hotbar_name) and not loaded_hotbar.has(hotbar_name):
			loaded_hotbar[i] = hotbar_name
	if raw_hotbar.is_empty():
		for i in mini(BlockDefs.HOTBAR_SIZE, loaded_order.size()):
			loaded_hotbar[i] = loaded_order[i]
	var loaded_equipment: Dictionary = {"hand": "", "feet": ""}
	var raw_equipment = state.get("equipment_slots", {})
	if not raw_equipment is Dictionary:
		return false
	for slot_name in ["hand", "feet"]:
		var equipment_name := _block_name_for_content_id(str((raw_equipment as Dictionary).get(slot_name, "")))
		if not equipment_name.is_empty() and loaded_inventory.has(equipment_name) and equipment_slot_for_item(equipment_name) == slot_name:
			loaded_equipment[slot_name] = equipment_name
	# Old saves only knew the hotbar. Migrate their first tool and boots into the
	# independent slots so existing players immediately retain both bonuses.
	for hotbar_name: String in loaded_hotbar:
		var slot_name := equipment_slot_for_item(hotbar_name)
		if not slot_name.is_empty() and str(loaded_equipment[slot_name]).is_empty():
			loaded_equipment[slot_name] = hotbar_name
	for equipped_name: String in loaded_equipment.values():
		if equipped_name.is_empty():
			continue
		for index in loaded_hotbar.size():
			if loaded_hotbar[index] == equipped_name:
				loaded_hotbar[index] = ""
	var loaded_craft_slots: Array = [null, null, null, null]
	var raw_craft_slots = state.get("craft_slots", [])
	if not raw_craft_slots is Array:
		return false
	for i in mini(loaded_craft_slots.size(), raw_craft_slots.size()):
		if raw_craft_slots[i] == null:
			continue
		var craft_name := _block_name_for_content_id(str(raw_craft_slots[i]))
		if craft_name == "":
			return false
		loaded_craft_slots[i] = craft_name
	var loaded_craft_durability: Array[int] = [0, 0, 0, 0]
	var raw_craft_durability = state.get("craft_slot_durability", [])
	if raw_craft_durability is Array:
		for index in mini(loaded_craft_durability.size(), raw_craft_durability.size()):
			var craft_name := str(loaded_craft_slots[index]) if loaded_craft_slots[index] != null else ""
			var maximum := item_max_durability(craft_name)
			if maximum > 0:
				loaded_craft_durability[index] = clampi(int(raw_craft_durability[index]), 1, maximum)
	for index in loaded_craft_slots.size():
		var craft_name := str(loaded_craft_slots[index]) if loaded_craft_slots[index] != null else ""
		if item_max_durability(craft_name) > 0 and loaded_craft_durability[index] <= 0:
			loaded_craft_durability[index] = item_max_durability(craft_name)
	var loaded_known_recipes: Array[Dictionary] = []
	var raw_known_recipes = state.get("known_recipes", [])
	if not raw_known_recipes is Array:
		return false
	for raw_recipe in raw_known_recipes:
		if not raw_recipe is Dictionary:
			return false
		var loaded_inputs: Dictionary = {}
		var loaded_outputs: Dictionary = {}
		for content_id in (raw_recipe as Dictionary).get("in", {}):
			var input_name := _block_name_for_content_id(str(content_id))
			var input_count := int((raw_recipe as Dictionary)["in"][content_id])
			if input_name == "" or input_count <= 0:
				return false
			loaded_inputs[input_name] = input_count
		for content_id in (raw_recipe as Dictionary).get("out", {}):
			var output_name := _block_name_for_content_id(str(content_id))
			var output_count := int((raw_recipe as Dictionary)["out"][content_id])
			if output_name == "" or output_count <= 0:
				return false
			loaded_outputs[output_name] = output_count
		if loaded_inputs.is_empty() or loaded_outputs.is_empty():
			return false
		loaded_known_recipes.append({"in": loaded_inputs, "out": loaded_outputs, "generated": true})
	var loaded_applied_jobs: Dictionary = {}
	var raw_applied_jobs = state.get("applied_discovery_jobs", {})
	if not raw_applied_jobs is Dictionary:
		return false
	for raw_job_id in (raw_applied_jobs as Dictionary):
		var job_id := str(raw_job_id)
		var content_id := str((raw_applied_jobs as Dictionary)[raw_job_id])
		if not job_id.is_empty() and not content_id.is_empty():
			loaded_applied_jobs[job_id] = content_id

	var loaded_player = state.get("player", null)
	var spawn_data = state.get("default_spawn", null)
	var spawn_change_data: Dictionary = state.get("spawn_change", {}) if state.get("spawn_change", {}) is Dictionary else {}
	if not loaded_player is Dictionary or not spawn_data is Dictionary:
		return false
	for required_key in ["x", "y", "w", "h"]:
		if not (loaded_player as Dictionary).has(required_key):
			return false
	var selected_name := _block_name_for_content_id(str(state.get("selected_content_id", "")))
	if selected_name != "" and not loaded_inventory.has(selected_name):
		selected_name = ""
	if selected_name in loaded_equipment.values():
		selected_name = ""
	var weather_data: Dictionary = state.get("weather", {}) if state.get("weather", {}) is Dictionary else {}
	var weather_target_data: Dictionary = weather_data.get("target", {}) if weather_data.get("target", {}) is Dictionary else {}
	var loaded_weather_type := str(weather_data.get("type", "clear"))
	if loaded_weather_type not in ["clear", "rain", "lightning"]:
		loaded_weather_type = "clear"
	var generation_data: Dictionary = state.get("generation", {}) if state.get("generation", {}) is Dictionary else {}
	var rules_data: Dictionary = state.get("rules", {}) if state.get("rules", {}) is Dictionary else {}
	var loaded_keep_inventory := bool(rules_data.get("keep_inventory_on_death", true))
	var loaded_world_mode := str(generation_data.get("mode", WORLD_MODE_SKYBLOCK))
	if loaded_world_mode not in [WORLD_MODE_SKYBLOCK, WORLD_MODE_FLOATING_ISLANDS, WORLD_MODE_PROCEDURAL, WORLD_MODE_ONE_BLOCK, WORLD_MODE_CHALLENGE, WORLD_MODE_DUEL]:
		loaded_world_mode = WORLD_MODE_SKYBLOCK
	var loaded_floating_island_layout := _deserialize_floating_island_layout(generation_data.get("floating_islands", []))
	if loaded_world_mode in [WORLD_MODE_FLOATING_ISLANDS, WORLD_MODE_DUEL] and loaded_floating_island_layout.is_empty():
		loaded_floating_island_layout = LEGACY_FLOATING_ISLAND_LAYOUT.duplicate(true)
	var one_block_data: Dictionary = state.get("one_block", {}) if state.get("one_block", {}) is Dictionary else {}
	var loaded_one_block_position := Vector2i(
		clampi(int(one_block_data.get("x", ISLAND_CX)), -COORD_LIMIT, COORD_LIMIT),
		clampi(int(one_block_data.get("y", ISLAND_CY)), -COORD_LIMIT, COORD_LIMIT)
	)
	var loaded_one_block_mined := maxi(0, int(one_block_data.get("mined", 0)))
	var challenge_data: Dictionary = state.get("challenge", {}) if state.get("challenge", {}) is Dictionary else {}
	var loaded_challenge_best := maxi(0, int(challenge_data.get("best_distance", 0)))
	var loaded_challenge_checkpoint := maxi(0, int(challenge_data.get("checkpoint_chunk", 0)))
	var loaded_challenge_encounters: Dictionary = {}
	var raw_activated_encounters = challenge_data.get("activated_encounters", [])
	if raw_activated_encounters is Array:
		for raw_chunk_x in raw_activated_encounters:
			var encounter_chunk_x := int(raw_chunk_x)
			if encounter_chunk_x >= 0 and encounter_chunk_x <= COORD_LIMIT / CHUNK_WIDTH:
				loaded_challenge_encounters[encounter_chunk_x] = true
	var loaded_chunks: Dictionary = {}
	var raw_chunks = generation_data.get("chunks", [])
	if raw_chunks is Array:
		for raw_chunk in raw_chunks:
			if not raw_chunk is Dictionary:
				continue
			var chunk_x := int((raw_chunk as Dictionary).get("x", COORD_LIMIT + 1))
			if absi(chunk_x) > COORD_LIMIT / CHUNK_WIDTH:
				continue
			var loaded_placed_structures: Array[Dictionary] = []
			var raw_placed_structures = (raw_chunk as Dictionary).get("placed_structures", [])
			if raw_placed_structures is Array:
				for raw_placed in raw_placed_structures:
					if not raw_placed is Dictionary:
						continue
					var placed := raw_placed as Dictionary
					var structure_id := str(placed.get("id", ""))
					var left := clampi(int(placed.get("left", 0)), -COORD_LIMIT, COORD_LIMIT)
					var right := clampi(int(placed.get("right", 0)), -COORD_LIMIT, COORD_LIMIT)
					var top := clampi(int(placed.get("top", 0)), -COORD_LIMIT, COORD_LIMIT)
					var bottom := clampi(int(placed.get("bottom", 0)), -COORD_LIMIT, COORD_LIMIT)
					if not structure_id.is_empty() and left <= right and top <= bottom:
						loaded_placed_structures.append({"id": structure_id, "left": left, "right": right, "top": top, "bottom": bottom})
			var loaded_chunk := {
				"catalog_revision": maxi(0, int((raw_chunk as Dictionary).get("catalog_revision", 0))),
				"structure_catalog_revision": maxi(0, int((raw_chunk as Dictionary).get("structure_catalog_revision", 0))),
				"selected_content_ids": ((raw_chunk as Dictionary).get("selected_content_ids", []) as Array).duplicate() if (raw_chunk as Dictionary).get("selected_content_ids", []) is Array else [],
				"selected_structure_ids": ((raw_chunk as Dictionary).get("selected_structure_ids", []) as Array).duplicate() if (raw_chunk as Dictionary).get("selected_structure_ids", []) is Array else [],
				"placed_structures": loaded_placed_structures,
				"builtin_structure": bool((raw_chunk as Dictionary).get("builtin_structure", false)),
				"builtin_structure_id": str((raw_chunk as Dictionary).get("builtin_structure_id", "")),
				"cave_structure_id": str((raw_chunk as Dictionary).get("cave_structure_id", "")),
				"biome_id": str((raw_chunk as Dictionary).get("biome_id", "")),
				"biome_catalog_revision": maxi(0, int((raw_chunk as Dictionary).get("biome_catalog_revision", 0))),
				"resonant_deep_version": maxi(0, int((raw_chunk as Dictionary).get("resonant_deep_version", 0))),
				"resonant_biome_id": str((raw_chunk as Dictionary).get("resonant_biome_id", "")),
				"selected_resonant_structure_ids": ((raw_chunk as Dictionary).get("selected_resonant_structure_ids", []) as Array).duplicate() if (raw_chunk as Dictionary).get("selected_resonant_structure_ids", []) is Array else [],
			}
			if (raw_chunk as Dictionary).has("challenge_pattern"):
				loaded_chunk["challenge_pattern"] = int((raw_chunk as Dictionary)["challenge_pattern"])
			loaded_chunks[chunk_x] = loaded_chunk
	var loaded_regional_catalogs: Dictionary = {}
	var raw_regional_catalogs = generation_data.get("regional_catalogs", [])
	if raw_regional_catalogs is Array:
		for raw_manifest in raw_regional_catalogs:
			if not raw_manifest is Dictionary:
				continue
			var manifest := raw_manifest as Dictionary
			var region_x := int(manifest.get("region_x", COORD_LIMIT + 1))
			if absi(region_x) > COORD_LIMIT / (CHUNK_WIDTH * CONTENT_REGION_CHUNKS):
				continue
			loaded_regional_catalogs[region_x] = {
				"content_ids": (manifest.get("content_ids", []) as Array).duplicate() if manifest.get("content_ids", []) is Array else [],
				"structure_ids": (manifest.get("structure_ids", []) as Array).duplicate() if manifest.get("structure_ids", []) is Array else [],
				"biome_ids": (manifest.get("biome_ids", []) as Array).duplicate() if manifest.get("biome_ids", []) is Array else [],
				"content_revision": maxi(0, int(manifest.get("content_revision", 0))),
				"structure_revision": maxi(0, int(manifest.get("structure_revision", 0))),
				"biome_revision": maxi(0, int(manifest.get("biome_revision", 0))),
			}
	var loaded_structure_definitions: Array = generation_data.get("structure_definitions", []) if generation_data.get("structure_definitions", []) is Array else []
	var loaded_biome_definitions: Array = generation_data.get("biome_definitions", []) if generation_data.get("biome_definitions", []) is Array else []

	_suspend_state_changed = true
	world_id = loaded_world_id
	access_mode = loaded_access_mode
	multiplayer_join_code = loaded_join_code
	multiplayer_player_states = loaded_multiplayer_player_states
	world_mode = loaded_world_mode
	keep_inventory_on_death = loaded_keep_inventory
	world_seed = int(generation_data.get("seed", 0))
	floating_island_layout = loaded_floating_island_layout
	one_block_position = loaded_one_block_position
	one_block_mined = loaded_one_block_mined
	one_block_phase = _one_block_phase_index_for_mined(one_block_mined)
	challenge_best_distance = loaded_challenge_best
	challenge_checkpoint_chunk = loaded_challenge_checkpoint
	_challenge_activated_encounters = loaded_challenge_encounters
	challenge_next_milestone = maxi(
		_next_challenge_milestone_after(challenge_best_distance),
		int(challenge_data.get("next_milestone", 100))
	)
	catalog_revision = maxi(_latest_registered_catalog_revision(), int(generation_data.get("catalog_revision", 0)))
	structure_catalog_revision = 0
	structure_definitions.clear()
	ingest_structure_catalog(loaded_structure_definitions, int(generation_data.get("structure_catalog_revision", 0)))
	biome_catalog_revision = 0
	biome_definitions = BiomeDefs.all()
	ingest_biome_catalog(loaded_biome_definitions, int(generation_data.get("biome_catalog_revision", 0)))
	regional_catalogs = loaded_regional_catalogs
	generated_chunks = loaded_chunks
	if world_mode == WORLD_MODE_CHALLENGE:
		# Saves written before Deep challenge chapters did not persist the authored
		# pattern id. Preserve their already-generated tiles by pairing them with the
		# legacy deterministic deck; newly generated chunks use the expanded deck.
		for chunk_x: int in generated_chunks.keys():
			var chunk_data := generated_chunks[chunk_x] as Dictionary
			if int(chunk_data.get("challenge_pattern", -1)) < 0:
				chunk_data["challenge_pattern"] = _legacy_challenge_pattern_for_chunk(chunk_x)
	chunk_tick = 0
	tiles = loaded_tiles
	var default_fluid_void_limit := _default_fluid_void_limit()
	_fluid_void_limit_y = clampi(
		int(state.get("fluid_void_limit_y", default_fluid_void_limit)),
		default_fluid_void_limit,
		COORD_LIMIT
	)
	for raw_pos in loaded_tiles.keys():
		var fluid_pos := raw_pos as Vector2i
		if fluid_pos.y < _fluid_void_limit_y or not is_fluid_id(int(loaded_tiles[fluid_pos])):
			continue
		tiles.erase(fluid_pos)
		loaded_levels.erase(fluid_pos)
		loaded_falling.erase(fluid_pos)
	_rebuild_chunk_tile_index()
	fluid_level = loaded_levels
	fluid_falling = loaded_falling
	tree_growth = loaded_growth
	plant_growth = loaded_plant_growth
	plant_cells = loaded_plant_cells
	creatures = loaded_creatures
	containers = loaded_containers
	if int(state.get("creature_spawn_policy_version", 1)) < CREATURE_SPAWN_POLICY_VERSION:
		for creature_id: String in creatures.keys():
			var legacy_creature: Dictionary = creatures[creature_id]
			if bool(legacy_creature.get("natural", false)) and (legacy_creature.get("parents", []) as Array).is_empty():
				creatures.erase(creature_id)
	burning_tiles = loaded_burning
	inventory = loaded_inventory
	item_durability = loaded_item_durability
	footwear_wear_distance = maxf(0.0, float(state.get("footwear_wear_distance", 0.0)))
	inv_order = loaded_order
	hotbar_slots = loaded_hotbar
	equipment_slots = loaded_equipment
	active_hotbar_slot = clampi(int(state.get("active_hotbar_slot", 0)), 0, BlockDefs.HOTBAR_SIZE - 1)
	selected = selected_name
	craft_open = false
	open_container_pos = Vector2i(COORD_LIMIT + 1, COORD_LIMIT + 1)
	craft_slots = loaded_craft_slots
	craft_slot_durability = loaded_craft_durability
	known_recipes = loaded_known_recipes
	applied_discovery_jobs = loaded_applied_jobs
	craft_pick = ""
	player = (loaded_player as Dictionary).duplicate(true)
	if not player.has("health"):
		player["health"] = MAX_PLAYER_HEALTH
	player["health"] = clampi(int(player["health"]), 0, MAX_PLAYER_HEALTH)
	if not player.has("nourishment"):
		player["nourishment"] = MAX_NOURISHMENT
	player["nourishment"] = clampi(int(player["nourishment"]), 0, MAX_NOURISHMENT)
	if not player.has("climb_col"):
		player["climb_col"] = -1
	default_spawn = Vector2i(int((spawn_data as Dictionary).get("x", ISLAND_CX + 3)), int((spawn_data as Dictionary).get("y", ISLAND_CY)))
	custom_spawn_set = bool(spawn_change_data.get("custom", false))
	spawn_change_available_at_unix = maxi(0, int(spawn_change_data.get("available_at_unix", 0)))
	fluid_tick = maxi(0, int(state.get("fluid_tick", 0)))
	tree_tick = maxi(0, int(state.get("tree_tick", 0)))
	creature_tick = maxi(0, int(state.get("creature_tick", 0)))
	world_time_tick = posmod(int(state.get("world_time_tick", 0)), DAY_LENGTH_TICKS)
	granular_tick = maxi(0, int(state.get("granular_tick", 0)))
	fire_tick = maxi(0, int(state.get("fire_tick", 0)))
	weather_tick = maxi(0, int(weather_data.get("tick", 0)))
	water_missing_ticks = maxi(0, int(weather_data.get("water_missing_ticks", 0)))
	lava_missing_ticks = maxi(0, int(weather_data.get("lava_missing_ticks", 0)))
	weather_type = loaded_weather_type
	weather_ticks_remaining = maxi(0, int(weather_data.get("ticks_remaining", 0)))
	weather_target = Vector2i(int(weather_target_data.get("x", 0)), int(weather_target_data.get("y", 0)))
	weather_result = str(weather_data.get("result", ""))
	if weather_result not in ["", "water", "lava"]:
		weather_result = ""
	weather_is_recovery = bool(weather_data.get("is_recovery", false))
	lightning_sfx_played = bool(weather_data.get("lightning_sfx_played", false))
	if weather_ticks_remaining == 0:
		weather_type = "clear"
		weather_result = ""
		weather_is_recovery = false
		lightning_sfx_played = false
	_ensure_one_block()
	block_count = count_blocks()
	_suspend_state_changed = false
	block_count_changed.emit(block_count)
	inventory_changed.emit()
	state_changed.emit()
	return true


func _is_spawn_stand(tx: int, stand_ty: int) -> bool:
	var stand := get_block(tx, stand_ty)
	if not stand.get("solid", false) or stand.get("fluid", false):
		return false
	for by in range(stand_ty - 2, stand_ty):
		var above := get_block(tx, by)
		if above.get("solid", false) or above.get("fluid", false):
			return false
	return true


func _collect_spawn_candidates() -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	for dx in range(-SPAWN_RADIUS, SPAWN_RADIUS + 1):
		for dy in range(-2, SPAWN_RADIUS + 1):
			var tx := default_spawn.x + dx
			var stand_ty := default_spawn.y + dy
			if not _is_spawn_stand(tx, stand_ty):
				continue
			if absi(tx - default_spawn.x) + absi(stand_ty - default_spawn.y) > SPAWN_RADIUS + 2:
				continue
			found.append(Vector2i(tx, stand_ty))
	return found


func spawn_cooldown_remaining(now_unix: int = -1) -> int:
	var now := int(Time.get_unix_time_from_system()) if now_unix < 0 else now_unix
	return maxi(0, spawn_change_available_at_unix - now)


func spawn_cooldown_progress(now_unix: int = -1) -> float:
	return clampf(1.0 - float(spawn_cooldown_remaining(now_unix)) / float(SPAWN_CHANGE_COOLDOWN_SECONDS), 0.0, 1.0)


func _current_spawn_stand() -> Vector2i:
	return Vector2i(
		floori((float(player["x"]) + float(player["w"]) * 0.5) / float(BlockDefs.TILE)),
		floori((float(player["y"]) + float(player["h"]) + 1.0) / float(BlockDefs.TILE))
	)


func try_set_spawn(now_unix: int = -1) -> Dictionary:
	return _try_set_spawn(now_unix, false)


func try_set_spawn_after_reward(now_unix: int = -1) -> Dictionary:
	return _try_set_spawn(now_unix, true)


func _try_set_spawn(now_unix: int, bypass_cooldown: bool) -> Dictionary:
	var now := int(Time.get_unix_time_from_system()) if now_unix < 0 else now_unix
	var remaining := spawn_cooldown_remaining(now)
	if remaining > 0 and not bypass_cooldown:
		return {"ok": false, "reason": "cooldown", "remaining": remaining}
	var stand := _current_spawn_stand()
	if not bool(player.get("on_ground", false)) or bool(player.get("climbing", false)) or not _is_spawn_stand(stand.x, stand.y):
		return {"ok": false, "reason": "unsafe", "remaining": 0}
	default_spawn = stand
	custom_spawn_set = true
	spawn_change_available_at_unix = now + SPAWN_CHANGE_COOLDOWN_SECONDS
	state_changed.emit()
	return {"ok": true, "reason": "set", "remaining": SPAWN_CHANGE_COOLDOWN_SECONDS}


func reset_player() -> void:
	var candidates := _collect_spawn_candidates()
	var stand := default_spawn
	if custom_spawn_set and _is_spawn_stand(stand.x, stand.y):
		pass
	elif not candidates.is_empty():
		stand = candidates[randi() % candidates.size()]
	elif not _is_spawn_stand(stand.x, stand.y):
		for dx in range(-8, 9):
			if _is_spawn_stand(ISLAND_CX + dx, ISLAND_CY):
				stand = Vector2i(ISLAND_CX + dx, ISLAND_CY)
				break
	player["x"] = float(stand.x * BlockDefs.TILE) + (BlockDefs.TILE - player["w"]) * 0.5
	player["y"] = float(stand.y * BlockDefs.TILE) - player["h"]
	player["vy"] = 0.0
	player["vx"] = 0.0
	player["on_ground"] = true
	player["jump_coyote"] = 0.0
	player["tree_ghost"] = false
	player["climbing"] = false
	player["climb_col"] = -1
	player["health"] = MAX_PLAYER_HEALTH
	player["nourishment"] = maxi(50, int(player.get("nourishment", MAX_NOURISHMENT)))
	_nourishment_drain_elapsed = 0.0
	_nourishment_recovery_elapsed = 0.0
	_starvation_damage_elapsed = 0.0
	_player_was_in_harmful_fluid = false
	_harmful_fluid_damage_cooldown = 0.0


func _death_cache_tile_is_safe(pos: Vector2i) -> bool:
	if not in_bounds(pos.x, pos.y) or not in_bounds(pos.x, pos.y + 1):
		return false
	if int(get_block(pos.x, pos.y).get("id", 0)) != 0 or not plant_block_at(pos.x, pos.y).is_empty():
		return false
	var support := get_block(pos.x, pos.y + 1)
	return bool(support.get("solid", false)) and not bool(support.get("fluid", false))


func _find_death_cache_position() -> Vector2i:
	var origin := Vector2i(
		floori((float(player.get("x", 0.0)) + float(player.get("w", 20.0)) * 0.5) / float(BlockDefs.TILE)),
		floori((float(player.get("y", 0.0)) + float(player.get("h", 28.0)) * 0.5) / float(BlockDefs.TILE)),
	)
	var fallbacks: Array[Vector2i] = [origin, Vector2i(default_spawn.x, default_spawn.y - 1)]
	for center: Vector2i in fallbacks:
		for radius in range(0, DEATH_CACHE_SEARCH_RADIUS + 1):
			for dy in range(-radius, radius + 1):
				for dx in range(-radius, radius + 1):
					if radius > 0 and absi(dx) != radius and absi(dy) != radius:
						continue
					var candidate := center + Vector2i(dx, dy)
					if _death_cache_tile_is_safe(candidate):
						return candidate
	return Vector2i(COORD_LIMIT + 1, COORD_LIMIT + 1)


func create_death_cache(owner_player_id: String = "") -> Dictionary:
	for i in craft_slots.size():
		return_craft_slot(i)
	var item_count := 0
	for value: Variant in inventory.values():
		item_count += maxi(0, int(value))
	if item_count <= 0:
		return {"created": false, "item_count": 0}
	var pos := _find_death_cache_position()
	if not in_bounds(pos.x, pos.y):
		# Never turn a failed cache placement into item loss. This can only happen
		# in malformed or almost-empty worlds; keeping the inventory is the safest
		# recovery path and lets the next death try again.
		return {"created": false, "item_count": item_count, "reason": "no_safe_tile"}
	var cache := {
		"contents": inventory.duplicate(true),
		"durability": item_durability.duplicate(true),
		"loot_generated": true,
		"loot_key": "",
		"loot_tier": "death_cache",
		"death_cache": true,
		"cache_id": "cache_%s" % Crypto.new().generate_random_bytes(8).hex_encode(),
		"owner_player_id": owner_player_id,
		"created_at_unix": int(Time.get_unix_time_from_system()),
		"saved_hotbar": hotbar_slots.duplicate(),
		"saved_equipment": equipment_slots.duplicate(true),
	}
	clear_inventory()
	set_block(pos.x, pos.y, int(BlockDefs.BLOCKS["chest"]["id"]))
	containers[pos] = cache
	death_cache_created.emit(pos, item_count)
	state_changed.emit()
	return {"created": true, "position": pos, "item_count": item_count, "cache_id": cache["cache_id"]}


func _death_cache_item_count(cache: Dictionary) -> int:
	var item_count := 0
	var contents: Variant = cache.get("contents", {})
	if contents is Dictionary:
		for value: Variant in (contents as Dictionary).values():
			item_count += maxi(0, int(value))
	return item_count


func death_cache_remaining_seconds(pos: Vector2i, now_unix: int = -1) -> int:
	var cache: Variant = containers.get(pos, null)
	if not cache is Dictionary or not bool((cache as Dictionary).get("death_cache", false)):
		return 0
	var now := now_unix if now_unix >= 0 else int(Time.get_unix_time_from_system())
	var created_at := int((cache as Dictionary).get("created_at_unix", 0))
	if created_at <= 0:
		return DEATH_CACHE_TTL_SECONDS
	return maxi(0, DEATH_CACHE_TTL_SECONDS - maxi(0, now - created_at))


func expire_death_caches(now_unix: int = -1) -> int:
	var now := now_unix if now_unix >= 0 else int(Time.get_unix_time_from_system())
	var expired: Array[Vector2i] = []
	for pos: Vector2i in containers.keys():
		var cache: Dictionary = containers[pos]
		if not bool(cache.get("death_cache", false)):
			continue
		var created_at := int(cache.get("created_at_unix", 0))
		# Legacy caches did not have a timestamp. Give them a full recovery window
		# instead of deleting items immediately after upgrading the game.
		if created_at <= 0:
			cache["created_at_unix"] = now
			containers[pos] = cache
			continue
		if now - created_at >= DEATH_CACHE_TTL_SECONDS:
			expired.append(pos)
	for pos: Vector2i in expired:
		var cache: Dictionary = containers.get(pos, {})
		var item_count := _death_cache_item_count(cache)
		var age_seconds := maxi(0, now - int(cache.get("created_at_unix", now)))
		if get_block(pos.x, pos.y).get("container", false):
			set_block(pos.x, pos.y, 0)
		else:
			containers.erase(pos)
		death_cache_expired.emit(pos, item_count, age_seconds)
	if not expired.is_empty():
		state_changed.emit()
	return expired.size()


func recover_death_cache(pos: Vector2i, recovering_player_id: String = "") -> bool:
	if not containers.has(pos):
		return false
	var cache: Dictionary = containers[pos]
	if not bool(cache.get("death_cache", false)):
		return false
	if death_cache_remaining_seconds(pos) <= 0:
		expire_death_caches()
		return false
	var contents: Dictionary = cache.get("contents", {}) if cache.get("contents", {}) is Dictionary else {}
	var durability: Dictionary = cache.get("durability", {}) if cache.get("durability", {}) is Dictionary else {}
	var item_count := 0
	for block_name: String in contents:
		var amount := maxi(0, int(contents[block_name]))
		if amount <= 0:
			continue
		var values: Array = durability.get(block_name, []) if durability.get(block_name, []) is Array else []
		give_to_inventory(block_name, amount, values)
		item_count += amount
	var owner_player_id := str(cache.get("owner_player_id", ""))
	var restore_owner_layout := owner_player_id.is_empty() or recovering_player_id.is_empty() or owner_player_id == recovering_player_id
	var saved_equipment: Dictionary = cache.get("saved_equipment", {}) if restore_owner_layout and cache.get("saved_equipment", {}) is Dictionary else {}
	for slot_name: String in ["hand", "feet"]:
		var block_name := str(saved_equipment.get(slot_name, ""))
		if inventory.get(block_name, 0) > 0 and equipment_slot_for_item(block_name) == slot_name:
			equipment_slots[slot_name] = block_name
	var saved_hotbar: Array = cache.get("saved_hotbar", []) if restore_owner_layout and cache.get("saved_hotbar", []) is Array else []
	var restored_hotbar: Array[String] = ["", "", "", "", "", ""]
	var assigned: Dictionary = {}
	for index in mini(restored_hotbar.size(), saved_hotbar.size()):
		var block_name := str(saved_hotbar[index])
		if inventory.get(block_name, 0) > 0 and equipment_slot_for_item(block_name).is_empty() and not assigned.has(block_name):
			restored_hotbar[index] = block_name
			assigned[block_name] = true
	for block_name: String in inv_order:
		if inventory.get(block_name, 0) <= 0 or not equipment_slot_for_item(block_name).is_empty() or assigned.has(block_name):
			continue
		for index in restored_hotbar.size():
			if restored_hotbar[index].is_empty():
				restored_hotbar[index] = block_name
				assigned[block_name] = true
				break
	hotbar_slots = restored_hotbar
	_reselect_after_remove()
	containers.erase(pos)
	set_block(pos.x, pos.y, 0)
	death_cache_recovered.emit(pos, item_count)
	inventory_changed.emit()
	state_changed.emit()
	return true


func respawn_player_after_defeat(owner_player_id: String = "") -> Dictionary:
	var result := {"created": false, "item_count": 0}
	if not keep_inventory_on_death:
		if Analytics.release_flag_bool("death_cache_enabled", true):
			result = create_death_cache(owner_player_id)
		else:
			result["item_count"] = clear_inventory()
			result["reason"] = "death_cache_disabled"
	reset_player()
	return result


func restore_multiplayer_player_position(state: Dictionary) -> bool:
	if not state.has("x") or not state.has("y"):
		return false
	var limit := float(COORD_LIMIT * BlockDefs.TILE)
	var requested := Vector2(
		clampf(float(state.get("x", player["x"])), -limit, limit),
		clampf(float(state.get("y", player["y"])), -limit, limit),
	)
	var candidates: Array[Vector2] = [requested]
	for radius in range(1, 5):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dy) != radius:
					continue
				candidates.append(requested + Vector2(dx, dy) * BlockDefs.TILE)
	for candidate: Vector2 in candidates:
		if collides(candidate.x, candidate.y, float(player["w"]), float(player["h"])) != null:
			continue
		player["x"] = candidate.x
		player["y"] = candidate.y
		player["facing"] = -1 if int(state.get("facing", 1)) < 0 else 1
		player["vx"] = 0.0
		player["vy"] = 0.0
		player["on_ground"] = bool(state.get("on_ground", false)) and candidate.is_equal_approx(requested)
		player["health"] = clampi(int(state.get("health", MAX_PLAYER_HEALTH)), 1, MAX_PLAYER_HEALTH)
		player["nourishment"] = clampi(int(state.get("nourishment", player.get("nourishment", MAX_NOURISHMENT))), 0, MAX_NOURISHMENT)
		player["jump_coyote"] = 0.0
		player["tree_ghost"] = false
		player["climbing"] = false
		player["climb_col"] = -1
		_player_was_in_harmful_fluid = false
		_harmful_fluid_damage_cooldown = 0.0
		return true
	return false


func revive_player_in_place() -> void:
	player["health"] = MAX_PLAYER_HEALTH
	player["nourishment"] = maxi(50, int(player.get("nourishment", MAX_NOURISHMENT)))
	player["vx"] = 0.0
	player["vy"] = 0.0
	_player_was_in_harmful_fluid = false
	_harmful_fluid_damage_cooldown = 0.0
	for creature_id: String in creatures:
		var creature: Dictionary = creatures[creature_id]
		if _creature_distance_to_player(creature) <= CREATURE_ACTIVE_RADIUS:
			creature["attack_cooldown"] = maxi(180, int(creature.get("attack_cooldown", 0)))
	state_changed.emit()


func create_fluid_pit(x: int, surface_y: int, fluid_id: int) -> void:
	set_block(x, surface_y, fluid_id, 0)


func _resource_in_inventory_or_craft(block_name: String) -> bool:
	if int(inventory.get(block_name, 0)) > 0:
		return true
	for slot in craft_slots:
		if slot != null and str(slot) == block_name:
			return true
	return false


func has_recoverable_resource(block_name: String) -> bool:
	if _resource_in_inventory_or_craft(block_name):
		return true
	if not BlockDefs.BLOCKS.has(block_name):
		return false
	var wanted_id := int(BlockDefs.BLOCKS[block_name]["id"])
	return int(block_id_counts.get(wanted_id, 0)) > 0


func _open_to_sky(x: int, y: int, top_y: int) -> bool:
	for check_y in range(y - 1, top_y - 1, -1):
		if block_id(x, check_y) != 0:
			return false
	return true


func _weather_player_tile() -> Vector2i:
	return Vector2i(
		floori((float(player["x"]) + float(player["w"]) * 0.5) / BlockDefs.TILE),
		floori((float(player["y"]) + float(player["h"]) * 0.5) / BlockDefs.TILE)
	)


func _weather_disabled_for_player() -> bool:
	return _world_supports_resonant_deep() and _weather_player_tile().y >= RESONANT_DEEP_TOP_Y


func _weather_target_near_player(pos: Vector2i) -> bool:
	return Vector2(pos - _weather_player_tile()).length() <= float(WEATHER_TARGET_RADIUS)


func _find_rain_target(randomize: bool = false) -> Variant:
	var center := _weather_player_tile()
	var sky_scan_top := center.y - WEATHER_SKY_SCAN_HEIGHT
	var bounds := Rect2i(center - Vector2i.ONE * WEATHER_TARGET_RADIUS, Vector2i.ONE * (WEATHER_TARGET_RADIUS * 2 + 1))
	var candidates: Array[Dictionary] = []
	for y in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x):
			var pos := Vector2i(x, y)
			if not _weather_target_near_player(pos) or block_id(x, y) != 0 or not has_solid_floor_in(x, y) or not _open_to_sky(x, y, sky_scan_top):
				continue
			var walls := int(get_block(x - 1, y).get("solid", false)) + int(get_block(x + 1, y).get("solid", false))
			var distance := Vector2(pos - center).length()
			candidates.append({"pos": pos, "walls": walls, "distance": distance})
	if candidates.is_empty():
		return null
	if randomize:
		return candidates.pick_random()["pos"]
	candidates.sort_custom(func(a: Dictionary, b: Dictionary):
		if int(a["walls"]) != int(b["walls"]):
			return int(a["walls"]) > int(b["walls"])
		return int(a["distance"]) < int(b["distance"])
	)
	return candidates[0]["pos"]


func _find_lightning_target(randomize: bool = false) -> Variant:
	var center := _weather_player_tile()
	var sky_scan_top := center.y - WEATHER_SKY_SCAN_HEIGHT
	var candidates: Array[Vector2i] = []
	for y in range(center.y - WEATHER_TARGET_RADIUS, center.y + WEATHER_TARGET_RADIUS + 1):
		for x in range(center.x - WEATHER_TARGET_RADIUS, center.x + WEATHER_TARGET_RADIUS + 1):
			var pos := Vector2i(x, y)
			if _weather_target_near_player(pos) and get_block(x, y).get("name", "") == "stone" and _open_to_sky(x, y, sky_scan_top):
				candidates.append(pos)
	if candidates.is_empty():
		return null
	if randomize:
		return candidates.pick_random()
	candidates.sort_custom(func(a: Vector2i, b: Vector2i):
		var da := Vector2(a - center).length_squared()
		var db := Vector2(b - center).length_squared()
		return da < db
	)
	return candidates[0]


func _clear_weather() -> void:
	weather_type = "clear"
	weather_ticks_remaining = 0
	weather_target = Vector2i.ZERO
	weather_result = ""
	weather_is_recovery = false
	lightning_sfx_played = false
	state_changed.emit()


func _start_weather(kind: String, target: Vector2i, result: String, recovery: bool) -> void:
	if _weather_disabled_for_player():
		_clear_weather()
		return
	weather_type = kind
	weather_ticks_remaining = RAIN_DURATION_TICKS if kind == "rain" else LIGHTNING_WARNING_TICKS
	weather_target = target
	weather_result = result
	weather_is_recovery = recovery
	lightning_sfx_played = false
	state_changed.emit()


func _try_start_ambient_weather(event_roll: float, result_roll: float) -> bool:
	if _weather_disabled_for_player():
		return false
	var biome := active_biome_definition()
	var environment: Dictionary = biome.get("environment", {}) if biome.get("environment", {}) is Dictionary else {}
	var rain_multiplier := clampf(float(environment.get("rain_multiplier", 1.0)), 0.0, 3.0)
	if event_roll >= AMBIENT_WEATHER_CHANCE * rain_multiplier:
		return false
	var water_unlocked := world_mode != WORLD_MODE_ONE_BLOCK or one_block_phase >= 3
	var lava_unlocked := world_mode != WORLD_MODE_ONE_BLOCK or one_block_phase >= 6
	if result_roll < AMBIENT_LAVA_CHANCE and lava_unlocked:
		var lightning_target = _find_lightning_target(true)
		if lightning_target != null:
			_start_weather("lightning", lightning_target, "lava", false)
			return true
		var cosmetic_target = _find_rain_target(true)
		if cosmetic_target != null:
			_start_weather("rain", cosmetic_target, "", false)
			return true
		return false
	var rain_target = _find_rain_target(true)
	if rain_target == null:
		return false
	var result := "water" if water_unlocked and result_roll < AMBIENT_LAVA_CHANCE + AMBIENT_WATER_CHANCE else ""
	_start_weather("rain", rain_target, result, false)
	return true


func _weather_recovery_search_due(missing_ticks: int, threshold: int) -> bool:
	if missing_ticks < threshold:
		return false
	return missing_ticks == threshold or missing_ticks % WEATHER_RECOVERY_SEARCH_EVERY == 0


func tick_weather() -> void:
	weather_tick += 1
	# Weather belongs to the surface sky. Clear any in-flight effect immediately
	# when the player descends so old saves and multiplayer snapshots cannot show
	# rain, lightning, or thunder inside the sealed Resonant Deep.
	if _weather_disabled_for_player():
		water_missing_ticks = 0
		lava_missing_ticks = 0
		if weather_type != "clear":
			_clear_weather()
		return
	if world_mode == WORLD_MODE_CHALLENGE:
		water_missing_ticks = 0
		lava_missing_ticks = 0
		return
	# One Block deliberately gates fluids behind its Ocean and Volcanic phases.
	# Treat them as unavailable-but-not-missing before those milestones so the
	# general Skyblock recovery weather cannot bypass phase progression.
	var water_unlocked := world_mode != WORLD_MODE_ONE_BLOCK or one_block_phase >= 3
	var lava_unlocked := world_mode != WORLD_MODE_ONE_BLOCK or one_block_phase >= 6
	var has_water := not water_unlocked or has_recoverable_resource("water")
	var has_lava := not lava_unlocked or has_recoverable_resource("lava")
	water_missing_ticks = 0 if has_water else water_missing_ticks + 1
	lava_missing_ticks = 0 if has_lava else lava_missing_ticks + 1

	if weather_type == "rain":
		if weather_is_recovery and has_water:
			_clear_weather()
			return
		weather_ticks_remaining -= 1
		if weather_ticks_remaining <= 0:
			var created_water := false
			if not _weather_target_near_player(weather_target) or block_id(weather_target.x, weather_target.y) != 0 or not has_solid_floor_in(weather_target.x, weather_target.y):
				var nearby_rain_target = _find_rain_target(true)
				if nearby_rain_target != null:
					weather_target = nearby_rain_target
			if weather_result == "water" and _weather_target_near_player(weather_target) and block_id(weather_target.x, weather_target.y) == 0 and has_solid_floor_in(weather_target.x, weather_target.y):
				set_block(weather_target.x, weather_target.y, BlockDefs.BLOCKS.water.id, 0)
				created_water = true
			if created_water:
				water_missing_ticks = 0
			_clear_weather()
		return

	if weather_type == "lightning":
		if weather_is_recovery and has_lava:
			_clear_weather()
			return
		weather_ticks_remaining -= 1
		if weather_ticks_remaining <= LIGHTNING_FLASH_TICKS and not lightning_sfx_played:
			lightning_sfx_played = true
			Sfx.lightning()
		if weather_ticks_remaining <= 0:
			var created_lava := false
			if not _weather_target_near_player(weather_target) or get_block(weather_target.x, weather_target.y).get("name", "") != "stone":
				var nearby_lightning_target = _find_lightning_target(true)
				if nearby_lightning_target != null:
					weather_target = nearby_lightning_target
			if weather_result == "lava" and _weather_target_near_player(weather_target) and get_block(weather_target.x, weather_target.y).get("name", "") == "stone":
				set_block(weather_target.x, weather_target.y, BlockDefs.BLOCKS.lava.id, 0)
				created_lava = true
			if created_lava:
				lava_missing_ticks = 0
			_clear_weather()
		return

	if _weather_recovery_search_due(water_missing_ticks, WATER_RECOVERY_TICKS):
		var rain_target = _find_rain_target()
		if rain_target != null:
			_start_weather("rain", rain_target, "water", true)
			return
	if _weather_recovery_search_due(lava_missing_ticks, LAVA_RECOVERY_TICKS):
		var lightning_target = _find_lightning_target()
		if lightning_target != null:
			_start_weather("lightning", lightning_target, "lava", true)
			return
	if weather_tick % AMBIENT_WEATHER_INTERVAL_TICKS == 0:
		if _try_start_ambient_weather(randf(), randf()):
			return
	if weather_tick % 60 == 0 and (not has_water or not has_lava):
		state_changed.emit()


func count_blocks() -> int:
	var n := 0
	for key: Vector2i in tiles.keys():
		if int(tiles[key]) != 0:
			n += 1
	return n


func block_id(x: int, y: int) -> int:
	return int(tiles.get(Vector2i(x, y), 0))


func get_fluid_level(x: int, y: int) -> int:
	return int(fluid_level.get(Vector2i(x, y), -1))


func is_fluid_falling_at(x: int, y: int) -> bool:
	return bool(fluid_falling.get(Vector2i(x, y), false))


func get_block(x: int, y: int) -> Dictionary:
	if not in_bounds(x, y):
		return BlockDefs.BLOCKS["air"]
	return BlockDefs.get_block_by_id(block_id(x, y))


func light_transmission(block: Dictionary) -> float:
	if int(block.get("id", 0)) == 0 or bool(block.get("fluid", false)):
		return 1.0
	if str(block.get("name", "")) == "leaves":
		return 0.82
	if str(block.get("name", "")) == "glass" or int(block.get("id", -1)) == int(BlockDefs.BLOCKS.glass.id):
		return 0.94
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	for tag in tags:
		var normalized := str(tag).to_lower()
		if normalized == "transparent":
			return 0.94
		if normalized in ["translucent", "leaves", "foliage"]:
			return 0.78
	return 0.0


func light_passable(block: Dictionary) -> bool:
	return light_transmission(block) > 0.0


func block_light_emission(block: Dictionary) -> float:
	if str(block.get("name", "")) == "lava":
		return 1.0
	var emission := 0.0
	var temperature := float(block.get("temperature", 0.0))
	if temperature >= 0.6:
		emission = maxf(emission, remap(temperature, 0.6, 1.0, 0.72, 0.96))
	if str(block.get("pattern", "")) == "runes":
		emission = maxf(emission, 0.86)
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var lighting: Dictionary = definition.get("lighting", {}) if definition.get("lighting", {}) is Dictionary else {}
	if lighting.has("emission"):
		return clampf(float(lighting.get("emission", 0.0)), 0.0, 1.0)
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	for tag in tags:
		if str(tag).to_lower() in ["glowing", "luminous", "bioluminescent", "light_source"]:
			emission = maxf(emission, 0.9)
	return clampf(emission, 0.0, 1.0)


func creature_light_emission(creature: Dictionary) -> float:
	var definition := _creature_definition(str(creature.get("block_name", "")))
	var lighting: Dictionary = definition.get("lighting", {}) if definition.get("lighting", {}) is Dictionary else {}
	var emission := clampf(float(lighting.get("emission", 0.0)), 0.0, 1.0)
	if emission <= 0.0:
		return 0.0
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	if "night_surface" in tags and not world_is_night():
		var pos := Vector2i(floori(float(creature.get("x", 0.0))), floori(float(creature.get("y", 0.0))))
		if _open_to_sky(pos.x, pos.y, -16):
			return 0.0
	return emission


func has_emissive_creatures() -> bool:
	for creature: Dictionary in creatures.values():
		if creature_light_emission(creature) > 0.0:
			return true
	return false


func is_flammable(block: Dictionary) -> bool:
	return float(block.get("flammability", 0.0)) > 0.0


func ignite_tile(pos: Vector2i) -> bool:
	if is_one_use_cache_at(pos.x, pos.y):
		return false
	var block := get_block(pos.x, pos.y)
	var flammability := clampf(float(block.get("flammability", 0.0)), 0.0, 1.0)
	if flammability <= 0.0:
		return false
	if burning_tiles.has(pos):
		return true
	var lifetime := roundi(lerpf(float(FIRE_BURN_STEPS) * 1.25, float(FIRE_BURN_STEPS) * 0.75, flammability))
	burning_tiles[pos] = maxi(6, lifetime)
	return true


func apply_authoritative_fire_state(x: int, y: int, steps: int) -> void:
	if not in_bounds(x, y):
		return
	var pos := Vector2i(x, y)
	var normalized_steps := maxi(0, steps)
	if normalized_steps > 0 and (block_id(x, y) == 0 or not is_flammable(get_block(x, y)) or is_one_use_cache_at(x, y)):
		normalized_steps = 0
	var previous_steps := int(burning_tiles.get(pos, 0))
	if previous_steps == normalized_steps:
		return
	if normalized_steps > 0:
		burning_tiles[pos] = normalized_steps
	else:
		burning_tiles.erase(pos)
	lighting_changed.emit()
	state_changed.emit()


func _try_ignite_tile(pos: Vector2i, roll: float, chance_scale: float) -> bool:
	# A block extinguished earlier in the same fire tick can still be visited by a
	# later burning neighbor. Reject ignition at the source so iteration order and
	# random spread cannot immediately relight a water-cooled block.
	if _touches_water(pos) or is_one_use_cache_at(pos.x, pos.y):
		return false
	var flammability := clampf(float(get_block(pos.x, pos.y).get("flammability", 0.0)), 0.0, 1.0)
	if flammability <= 0.0 or roll >= flammability * chance_scale:
		return false
	return ignite_tile(pos)


func _touches_water(pos: Vector2i) -> bool:
	var water_id := int(BlockDefs.BLOCKS.water.id)
	for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		if block_id(pos.x + offset.x, pos.y + offset.y) == water_id:
			return true
	return false


func tick_fire() -> void:
	fire_tick += 1
	if fire_tick % FIRE_TICK_EVERY != 0:
		return
	var burning_before: Dictionary = burning_tiles.duplicate()
	var changed := false
	var static_changed := false
	var previous_suspend := _suspend_state_changed
	_suspend_state_changed = true
	for source_pos: Vector2i in _active_tile_positions():
		var source := get_block(source_pos.x, source_pos.y)
		if float(source.get("temperature", 0.0)) < FIRE_IGNITION_TEMPERATURE:
			continue
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			changed = _try_ignite_tile(source_pos + offset, randf(), FIRE_SOURCE_IGNITION_CHANCE) or changed
	var burning_snapshot: Array = burning_tiles.keys()
	for raw_pos in burning_snapshot:
		var pos := raw_pos as Vector2i
		if not _is_in_active_simulation(pos):
			continue
		if not tiles.has(pos) or not is_flammable(get_block(pos.x, pos.y)) or _touches_water(pos) or is_one_use_cache_at(pos.x, pos.y):
			burning_tiles.erase(pos)
			changed = true
			continue
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			changed = _try_ignite_tile(pos + offset, randf(), FIRE_SPREAD_CHANCE) or changed
		var steps_left := int(burning_tiles.get(pos, 1)) - 1
		if steps_left <= 0:
			burning_tiles.erase(pos)
			tree_growth.erase(pos)
			set_block(pos.x, pos.y, 0)
			static_changed = true
		else:
			burning_tiles[pos] = steps_left
		changed = true
	_suspend_state_changed = previous_suspend
	if changed and not _suspend_state_changed:
		if static_changed:
			static_tiles_changed.emit()
		lighting_changed.emit()
		state_changed.emit()
		# Fire runs as one suspended batch, so set_block() cannot emit its normal
		# multiplayer delta while a block burns away. Emit the final tile and fire
		# state for every ignition/extinguish transition after the batch completes.
		var fire_transition_positions: Dictionary = {}
		for raw_pos in burning_before.keys():
			var before_pos := raw_pos as Vector2i
			if not burning_tiles.has(before_pos):
				fire_transition_positions[before_pos] = true
		for raw_pos in burning_tiles.keys():
			var after_pos := raw_pos as Vector2i
			if not burning_before.has(after_pos):
				fire_transition_positions[after_pos] = true
		var ordered_positions: Array = fire_transition_positions.keys()
		ordered_positions.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
		for raw_pos in ordered_positions:
			var transition_pos := raw_pos as Vector2i
			tile_changed.emit(
				transition_pos.x,
				transition_pos.y,
				block_id(transition_pos.x, transition_pos.y),
				get_fluid_level(transition_pos.x, transition_pos.y),
				is_fluid_falling_at(transition_pos.x, transition_pos.y),
			)


func _propagate_tile_light(area: Rect2i, values: Dictionary, queue: Array[Vector2i], falloff: float) -> void:
	var head := 0
	while head < queue.size():
		var pos: Vector2i = queue[head]
		head += 1
		var base_next := float(values.get(pos, 0.0)) - falloff
		if base_next <= 0.01:
			continue
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor: Vector2i = pos + offset
			if not area.has_point(neighbor):
				continue
			var transmission := light_transmission(get_block(neighbor.x, neighbor.y))
			if transmission <= 0.0:
				continue
			var next_value := base_next * transmission
			if next_value <= float(values.get(neighbor, 0.0)) + 0.001:
				continue
			values[neighbor] = next_value
			queue.append(neighbor)


func _build_solid_visual_light(area: Rect2i, source: Dictionary) -> Dictionary:
	var visual := source.duplicate()
	var queue: Array[Vector2i] = []
	for raw_pos in source:
		queue.append(raw_pos as Vector2i)
	var head := 0
	while head < queue.size():
		var pos: Vector2i = queue[head]
		head += 1
		var next_value := float(visual.get(pos, 0.0)) - SOLID_VISUAL_FALLOFF
		if next_value <= 0.01:
			continue
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor := pos + offset
			if not area.has_point(neighbor) or light_passable(get_block(neighbor.x, neighbor.y)):
				continue
			if next_value <= float(visual.get(neighbor, 0.0)) + 0.001:
				continue
			visual[neighbor] = next_value
			queue.append(neighbor)
	return visual


func _propagate_packed_light(
	area: Rect2i,
	values: PackedFloat32Array,
	transmission: PackedFloat32Array,
	queue: PackedInt32Array,
	falloff: float
) -> void:
	var width := area.size.x
	var height := area.size.y
	var head := 0
	while head < queue.size():
		var index := queue[head]
		head += 1
		var next_base := values[index] - falloff
		if next_base <= 0.01:
			continue
		var local_x := index % width
		var local_y := floori(float(index) / float(width))
		var neighbors := PackedInt32Array()
		if local_x > 0:
			neighbors.append(index - 1)
		if local_x + 1 < width:
			neighbors.append(index + 1)
		if local_y > 0:
			neighbors.append(index - width)
		if local_y + 1 < height:
			neighbors.append(index + width)
		for neighbor in neighbors:
			var next_value := next_base * transmission[neighbor]
			if next_value <= values[neighbor] + 0.001:
				continue
			values[neighbor] = next_value
			queue.append(neighbor)


func _build_packed_solid_light(
	area: Rect2i,
	visual_area: Rect2i,
	source: PackedFloat32Array,
	transmission: PackedFloat32Array
) -> PackedFloat32Array:
	var width := area.size.x
	var height := area.size.y
	var visual := source.duplicate()
	var queue := PackedInt32Array()
	for index in source.size():
		if source[index] > 0.0:
			queue.append(index)
	var head := 0
	while head < queue.size():
		var index := queue[head]
		head += 1
		var next_value := visual[index] - SOLID_VISUAL_FALLOFF
		if next_value <= 0.01:
			continue
		var local_x := index % width
		var local_y := floori(float(index) / float(width))
		var neighbors := PackedInt32Array()
		if local_x > 0:
			neighbors.append(index - 1)
		if local_x + 1 < width:
			neighbors.append(index + 1)
		if local_y > 0:
			neighbors.append(index - width)
		if local_y + 1 < height:
			neighbors.append(index + width)
		for neighbor in neighbors:
			var neighbor_x := neighbor % width
			var neighbor_y := floori(float(neighbor) / float(width))
			var world_pos := area.position + Vector2i(neighbor_x, neighbor_y)
			if not visual_area.has_point(world_pos) or transmission[neighbor] > 0.0:
				continue
			if next_value <= visual[neighbor] + 0.001:
				continue
			visual[neighbor] = next_value
			queue.append(neighbor)
	return visual


func _packed_light_to_dictionary(
	area: Rect2i,
	values: PackedFloat32Array,
	restrict_to: Rect2i = Rect2i()
) -> Dictionary:
	var out: Dictionary = {}
	var width := area.size.x
	var restricted := restrict_to.size.x > 0 and restrict_to.size.y > 0
	for index in values.size():
		var value := values[index]
		if value <= 0.0:
			continue
		var pos := area.position + Vector2i(index % width, floori(float(index) / float(width)))
		if restricted and not restrict_to.has_point(pos):
			continue
		out[pos] = value
	return out


func build_light_maps(area: Rect2i, visual_area: Rect2i = Rect2i()) -> Dictionary:
	if visual_area.size.x <= 0 or visual_area.size.y <= 0:
		visual_area = area
	var width := area.size.x
	var height := area.size.y
	var cell_count := width * height
	var transmission := PackedFloat32Array()
	var daylight := PackedFloat32Array()
	var warm := PackedFloat32Array()
	transmission.resize(cell_count)
	daylight.resize(cell_count)
	warm.resize(cell_count)
	var daylight_queue := PackedInt32Array()
	var warm_queue := PackedInt32Array()
	var daylight_factor := world_daylight_factor()
	for local_x in width:
		var world_x := area.position.x + local_x
		var sky_level := daylight_factor if _open_to_sky(world_x, area.position.y, area.position.y - LIGHT_SKY_SCAN_TILES) else 0.0
		for local_y in height:
			var world_y := area.position.y + local_y
			var pos := Vector2i(world_x, world_y)
			var index := local_y * width + local_x
			var block := get_block(world_x, world_y)
			var cell_transmission := light_transmission(block)
			transmission[index] = cell_transmission
			# The Deep uses one constant ambient field instead of turning every
			# Lumenroot floor tile into a propagated light source.
			if _world_supports_resonant_deep() and world_y >= RESONANT_DEEP_TOP_Y and world_y <= RESONANT_DEEP_BOTTOM_Y:
				warm[index] = 0.38
			if sky_level > 0.0 and cell_transmission > 0.0:
				sky_level *= cell_transmission
				if sky_level > 0.01:
					daylight[index] = sky_level
					daylight_queue.append(index)
			else:
				sky_level = 0.0
			var emission := block_light_emission(block)
			if burning_tiles.has(pos):
				emission = maxf(emission, 0.9)
			if emission > warm[index]:
				warm[index] = emission
				warm_queue.append(index)
	for plant: Dictionary in plant_growth.values():
		var plant_block: Dictionary = BlockDefs.BLOCKS.get(str(plant.get("block_name", "")), {})
		var plant_emission := block_light_emission(plant_block)
		if plant_emission <= 0.0:
			continue
		var plant_cells_list: Array = plant.get("cells", []) if plant.get("cells", []) is Array else []
		for raw_cell in plant_cells_list:
			if raw_cell is not Vector2i or not area.has_point(raw_cell):
				continue
			var plant_local := (raw_cell as Vector2i) - area.position
			var plant_index := plant_local.y * width + plant_local.x
			if plant_emission > warm[plant_index]:
				warm[plant_index] = plant_emission
				warm_queue.append(plant_index)
	for creature: Dictionary in creatures.values():
		var creature_emission := creature_light_emission(creature)
		if creature_emission <= 0.0:
			continue
		var creature_pos := Vector2i(floori(float(creature.get("x", 0.0))), floori(float(creature.get("y", 0.0))))
		if not area.has_point(creature_pos):
			continue
		var creature_local := creature_pos - area.position
		var creature_index := creature_local.y * width + creature_local.x
		if creature_emission > warm[creature_index]:
			warm[creature_index] = creature_emission
			warm_queue.append(creature_index)
	_propagate_packed_light(area, daylight, transmission, daylight_queue, DAYLIGHT_FALLOFF)
	_propagate_packed_light(area, warm, transmission, warm_queue, EMISSIVE_FALLOFF)
	var combined := daylight.duplicate()
	for index in cell_count:
		combined[index] = maxf(combined[index], warm[index])
	var visual_daylight := _build_packed_solid_light(area, visual_area, daylight, transmission)
	var visual_warm := _build_packed_solid_light(area, visual_area, warm, transmission)
	var visual_combined := visual_daylight.duplicate()
	for index in cell_count:
		visual_combined[index] = maxf(visual_combined[index], visual_warm[index])
	return {
		"daylight": _packed_light_to_dictionary(area, daylight),
		"warm": _packed_light_to_dictionary(area, warm),
		"combined": _packed_light_to_dictionary(area, combined),
		"visual_daylight": _packed_light_to_dictionary(area, visual_daylight, visual_area),
		"visual_warm": _packed_light_to_dictionary(area, visual_warm, visual_area),
		"visual_combined": _packed_light_to_dictionary(area, visual_combined, visual_area),
	}


func set_block(x: int, y: int, id: int, level: int = -1, falling: bool = false) -> bool:
	if not in_bounds(x, y):
		return false
	var key := Vector2i(x, y)
	var had_block := tiles.has(key)
	var old_id := block_id(x, y)
	var old_level := int(fluid_level.get(key, -1))
	var old_falling := bool(fluid_falling.get(key, false))
	var old_block := BlockDefs.get_block_by_id(old_id)
	var new_block := BlockDefs.get_block_by_id(id)
	var block_identity_changed := old_id != id
	if block_identity_changed and old_block.get("container", false):
		containers.erase(key)
	if block_identity_changed and new_block.get("container", false):
		containers[key] = {"contents": {}, "durability": {}, "loot_generated": true, "loot_key": ""}
	var static_visual_changed := block_identity_changed and (bool(old_block.get("solid", false)) or bool(new_block.get("solid", false)))
	if id == 0 or old_id != id:
		burning_tiles.erase(key)
	var previous_count := block_count
	if id == 0:
		if had_block:
			tiles.erase(key)
			_unindex_tile(key, old_id)
			block_count = maxi(0, block_count - 1)
			_decrement_block_id(old_id)
		fluid_level.erase(key)
		fluid_falling.erase(key)
	else:
		if had_block and old_id != id:
			_unindex_tile(key, old_id)
		tiles[key] = id
		_index_tile(key, id)
		if not had_block:
			block_count += 1
		if old_id != id:
			_decrement_block_id(old_id)
			_increment_block_id(id)
		var block := BlockDefs.get_block_by_id(id)
		if block.get("fluid", false):
			fluid_level[key] = level if level >= 0 else 0
			fluid_falling[key] = falling
		else:
			fluid_level.erase(key)
			fluid_falling.erase(key)
	if block_count != previous_count:
		block_count_changed.emit(block_count)
	if not _suspend_state_changed:
		if static_visual_changed:
			static_tiles_changed.emit()
		if block_identity_changed:
			lighting_changed.emit()
		state_changed.emit()
		var new_level := int(fluid_level.get(key, -1))
		var new_falling := bool(fluid_falling.get(key, false))
		if old_id != id or old_level != new_level or old_falling != new_falling:
			tile_changed.emit(x, y, id, new_level, new_falling)
	return true


func in_bounds(x: int, y: int) -> bool:
	return absi(x) <= COORD_LIMIT and absi(y) <= COORD_LIMIT


func _default_fluid_void_limit() -> int:
	if _world_supports_resonant_deep():
		return RESONANT_DEEP_BOTTOM_Y + FLUID_VOID_MARGIN
	if world_mode in [WORLD_MODE_FLOATING_ISLANDS, WORLD_MODE_DUEL]:
		var deepest_island := ISLAND_CY
		for island: Dictionary in floating_island_layout:
			var center: Vector2i = island.get("center", Vector2i.ZERO)
			deepest_island = maxi(deepest_island, center.y + int(island.get("depth", 4)))
		return deepest_island + FLUID_VOID_MARGIN
	return ISLAND_CY + FLUID_VOID_MARGIN


func is_fluid_id(id: int) -> bool:
	return bool(BlockDefs.get_block_by_id(id).get("fluid", false))


func cell_is_air(x: int, y: int) -> bool:
	return in_bounds(x, y) and block_id(x, y) == 0


func has_floor_in(x: int, y: int) -> bool:
	return has_solid_floor_in(x, y)


func has_solid_floor_in(x: int, y: int) -> bool:
	if not in_bounds(x, y):
		return false
	var below: int = block_id(x, y + 1)
	return below != 0 and not is_fluid_id(below)


func has_air_below_in(x: int, y: int) -> bool:
	return in_bounds(x, y + 1) and block_id(x, y + 1) == 0


func drop_distance_in(x: int, y: int) -> int:
	if has_air_below_in(x, y):
		return 0
	var best := BlockDefs.DROP_SEARCH + 1
	for tx in range(x - BlockDefs.DROP_SEARCH, x + BlockDefs.DROP_SEARCH + 1):
		var dist := absi(tx - x)
		if dist > BlockDefs.DROP_SEARCH:
			continue
		if has_air_below_in(tx, y):
			best = mini(best, dist)
	return best


func can_spread_sideways_in(from_x: int, y: int, to_x: int) -> bool:
	if not cell_is_air(to_x, y):
		return false
	if not has_solid_floor_in(from_x, y):
		return false
	if has_air_below_in(from_x, y):
		return false
	if has_solid_floor_in(to_x, y):
		return true
	return drop_distance_in(to_x, y) < drop_distance_in(from_x, y)


func _fluid_positions(fluid_id: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var areas := _fluid_simulation_areas()
	var chunk_radius := ceili(float(FLUID_ACTIVE_RADIUS_X) / float(CHUNK_WIDTH)) + 1
	for pos: Vector2i in _positions_for_block_id_in_chunk_radius(fluid_id, chunk_radius):
		if _fluid_position_is_active(pos, areas):
			out.append(pos)
	return out


func _fluid_simulation_areas() -> Array[Rect2i]:
	var areas: Array[Rect2i] = []
	var targets: Array[Dictionary] = [player]
	for raw_player_id in multiplayer_player_targets:
		if multiplayer_player_targets[raw_player_id] is Dictionary:
			targets.append(multiplayer_player_targets[raw_player_id] as Dictionary)
	for target: Dictionary in targets:
		var player_tile := Vector2i(
			floori((float(target.get("x", 0.0)) + float(target.get("w", 20.0)) * 0.5) / float(BlockDefs.TILE)),
			floori((float(target.get("y", 0.0)) + float(target.get("h", 28.0)) * 0.5) / float(BlockDefs.TILE))
		)
		areas.append(Rect2i(
			player_tile - Vector2i(FLUID_ACTIVE_RADIUS_X, FLUID_ACTIVE_RADIUS_Y),
			Vector2i(FLUID_ACTIVE_RADIUS_X * 2 + 1, FLUID_ACTIVE_RADIUS_Y * 2 + 1)
		))
	return areas


func _fluid_position_is_active(pos: Vector2i, areas: Array[Rect2i] = []) -> bool:
	var resolved_areas := areas if not areas.is_empty() else _fluid_simulation_areas()
	for area: Rect2i in resolved_areas:
		if area.has_point(pos):
			return true
	return false


func _fluid_position_is_on_active_top(pos: Vector2i, areas: Array[Rect2i] = []) -> bool:
	var resolved_areas := areas if not areas.is_empty() else _fluid_simulation_areas()
	for area: Rect2i in resolved_areas:
		if pos.y == area.position.y and pos.x >= area.position.x and pos.x < area.end.x:
			return true
	return false


func mix_fluids(_x: int, _y: int, fluid_id: int, other_id: int, other_level: int) -> int:
	var water_id: int = BlockDefs.BLOCKS.water.id
	var lava_id: int = BlockDefs.BLOCKS.lava.id
	if fluid_id == water_id and other_id == lava_id:
		return BlockDefs.BLOCKS.obsidian.id if other_level == 0 else BlockDefs.BLOCKS.cobblestone.id
	if fluid_id == lava_id and other_id == water_id:
		if other_level == 0:
			return BlockDefs.BLOCKS.cobblestone.id
		return BlockDefs.BLOCKS.stone.id
	return -1


func apply_fluid_spread(x: int, y: int, fluid_id: int, level: int, falling: bool) -> void:
	if not in_bounds(x, y) or y >= _fluid_void_limit_y:
		return
	var current: int = block_id(x, y)
	if current == 0:
		set_block(x, y, fluid_id, level, falling)
		return
	if current == fluid_id:
		var key := Vector2i(x, y)
		var cur_level: int = get_fluid_level(x, y)
		if cur_level < 0 or level < cur_level or (level == cur_level and falling and not is_fluid_falling_at(x, y)):
			_set_fluid_state(key, level, falling)
		return
	if is_fluid_id(current):
		var stone_id := mix_fluids(x, y, fluid_id, current, get_fluid_level(x, y))
		if stone_id >= 0:
			set_block(x, y, stone_id)


func reconcile_fluid(fluid_id: int, decay: int, connected: Dictionary = {}) -> void:
	var use_connected := not connected.is_empty()
	for pos in _fluid_positions(fluid_id):
		var x: int = pos.x
		var y: int = pos.y
		if use_connected and not connected.has(pos):
			continue
		if get_fluid_level(x, y) == 0:
			continue
		if block_id(x, y - 1) == fluid_id:
			_set_fluid_state(pos, 1, has_air_below_in(x, y))
			continue
		var min_neighbor := 999999
		for nx in [x - 1, x + 1]:
			if block_id(nx, y) != fluid_id:
				continue
			if is_fluid_falling_at(nx, y):
				continue
			min_neighbor = mini(min_neighbor, get_fluid_level(nx, y))
		if min_neighbor == 999999:
			set_block(x, y, 0)
			continue
		var expected := min_neighbor + decay
		if expected >= BlockDefs.MAX_FLUID_LEVEL:
			set_block(x, y, 0)
			continue
		_set_fluid_state(pos, expected, has_air_below_in(x, y))


func form_water_sources() -> void:
	var water_id: int = BlockDefs.BLOCKS.water.id
	for pos in _fluid_positions(water_id):
		if get_fluid_level(pos.x, pos.y) == 0:
			continue
		var sources := 0
		if block_id(pos.x - 1, pos.y) == water_id and get_fluid_level(pos.x - 1, pos.y) == 0:
			sources += 1
		if block_id(pos.x + 1, pos.y) == water_id and get_fluid_level(pos.x + 1, pos.y) == 0:
			sources += 1
		if sources >= 2:
			_set_fluid_state(pos, 0, false)


func water_connected_to_source() -> Dictionary:
	var water_id: int = BlockDefs.BLOCKS.water.id
	var connected: Dictionary = {}
	var queue: Array[Vector2i] = []
	var areas := _fluid_simulation_areas()

	for pos in _fluid_positions(water_id):
		# A falling stream entering through the top of the active window remains
		# connected to its off-screen source without simulating the whole column.
		if get_fluid_level(pos.x, pos.y) == 0 or (_fluid_position_is_on_active_top(pos, areas) and is_fluid_falling_at(pos.x, pos.y)):
			queue.append(pos)
			connected[pos] = true

	var head := 0
	while head < queue.size():
		var pos: Vector2i = queue[head]
		head += 1
		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var next: Vector2i = pos + offset
			if not in_bounds(next.x, next.y):
				continue
			if connected.has(next):
				continue
			if block_id(next.x, next.y) != water_id:
				continue
			connected[next] = true
			queue.append(next)

	return connected


func drain_unsourced_water(decay: int) -> void:
	var water_id: int = BlockDefs.BLOCKS.water.id
	var connected := water_connected_to_source()

	for pos in _fluid_positions(water_id):
		if connected.has(pos):
			continue
		var level: int = get_fluid_level(pos.x, pos.y)
		if level <= 0:
			set_block(pos.x, pos.y, 0)
			continue
		var next_level := level + decay
		if next_level >= BlockDefs.MAX_FLUID_LEVEL:
			set_block(pos.x, pos.y, 0)
		else:
			_set_fluid_state(pos, next_level, false)


func _set_fluid_state(pos: Vector2i, level: int, falling: bool) -> void:
	var id := block_id(pos.x, pos.y)
	if not is_fluid_id(id):
		return
	var old_level := int(fluid_level.get(pos, -1))
	var old_falling := bool(fluid_falling.get(pos, false))
	if old_level == level and old_falling == falling:
		return
	fluid_level[pos] = level
	fluid_falling[pos] = falling
	if not _suspend_state_changed:
		state_changed.emit()
		tile_changed.emit(pos.x, pos.y, id, level, falling)


func simulate_fluid(fluid_id: int) -> void:
	var block := BlockDefs.get_block_by_id(fluid_id)
	if fluid_tick % int(block.get("tick_rate", 5)) != 0:
		return
	var decay: int = block.get("decay", 1)
	var pending: Dictionary = {}
	var water_id: int = BlockDefs.BLOCKS.water.id
	var water_connected: Dictionary = {}
	if fluid_id == water_id:
		water_connected = water_connected_to_source()

	var queue := func(x: int, y: int, level: int, falling: bool) -> void:
		var key := "%d,%d" % [x, y]
		if not pending.has(key):
			pending[key] = {"x": x, "y": y, "level": level, "falling": falling}
			return
		var prev: Dictionary = pending[key]
		if level < prev["level"] or (level == prev["level"] and falling and not prev["falling"]):
			pending[key] = {"x": x, "y": y, "level": level, "falling": falling}

	var positions := _fluid_positions(fluid_id)
	positions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y > b.y or (a.y == b.y and a.x < b.x))

	for pos in positions:
		var x: int = pos.x
		var y: int = pos.y
		if y >= _fluid_void_limit_y:
			set_block(x, y, 0)
			continue
		if fluid_id == water_id and not water_connected.has(pos):
			continue
		var level: int = get_fluid_level(x, y)
		var falling: bool = is_fluid_falling_at(x, y)
		if has_air_below_in(x, y):
			queue.call(x, y + 1, 1, true)
			continue
		if falling:
			continue
		if not has_solid_floor_in(x, y):
			continue
		var spread_level := 1 if level == 0 else level + decay
		if spread_level >= BlockDefs.MAX_FLUID_LEVEL:
			continue
		for dx in [-1, 1]:
			var nx: int = x + dx
			if not in_bounds(nx, y):
				continue
			if block_id(nx, y) != 0:
				continue
			if not can_spread_sideways_in(x, y, nx):
				continue
			var side_falling: bool = not has_solid_floor_in(nx, y)
			queue.call(nx, y, spread_level, side_falling)

	for spread: Dictionary in pending.values():
		apply_fluid_spread(spread["x"], spread["y"], fluid_id, spread["level"], spread["falling"])

	if fluid_id == water_id:
		water_connected = water_connected_to_source()

	reconcile_fluid(fluid_id, decay, water_connected if fluid_id == water_id else {})
	if fluid_id == water_id:
		form_water_sources()
		drain_unsourced_water(decay)


func _glass_tide_surface_cell(pos: Vector2i) -> bool:
	return (
		block_id(pos.x, pos.y) == int(BlockDefs.BLOCKS.glass_tide.id)
		and block_id(pos.x, pos.y - 1) == 0
	)


func crystallize_glass_tide_bridges() -> int:
	if not _glass_tide_bridge_queue.is_empty():
		return 0
	var glass_tide_id := int(BlockDefs.BLOCKS.glass_tide.id)
	var packed_ice_id := int(BlockDefs.BLOCKS.packed_ice.id)
	var seeds: Array[Vector2i] = []
	for pos in _fluid_positions(glass_tide_id):
		if not _glass_tide_surface_cell(pos):
			continue
		for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			if block_id(pos.x + offset.x, pos.y + offset.y) == packed_ice_id:
				seeds.append(pos)
				break
	if seeds.is_empty():
		return 0
	seeds.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x or (a.x == b.x and a.y < b.y))
	# Packed Ice is an intentional seed. The crystallization then walks across the
	# exposed surface of one connected pool, creating a usable horizontal bridge
	# without solidifying the liquid below it.
	var queue := seeds.duplicate()
	var visited: Dictionary = {}
	var bridge_cells: Array[Vector2i] = []
	var head := 0
	while head < queue.size() and bridge_cells.size() < GLASS_TIDE_BRIDGE_MAX_CELLS:
		var pos: Vector2i = queue[head]
		head += 1
		if visited.has(pos) or not _glass_tide_surface_cell(pos):
			continue
		visited[pos] = true
		bridge_cells.append(pos)
		for offset in [Vector2i.LEFT, Vector2i.RIGHT]:
			var next_pos: Vector2i = pos + offset
			if not visited.has(next_pos) and _glass_tide_surface_cell(next_pos):
				queue.append(next_pos)
	_glass_tide_bridge_queue = bridge_cells
	_glass_tide_bridge_total = bridge_cells.size()
	_glass_tide_bridge_step_ticks = 0
	return bridge_cells.size()


func _advance_glass_tide_bridge_crystallization() -> int:
	if _glass_tide_bridge_queue.is_empty():
		return 0
	_glass_tide_bridge_step_ticks += 1
	if _glass_tide_bridge_step_ticks < GLASS_TIDE_BRIDGE_STEP_TICKS:
		return 0
	_glass_tide_bridge_step_ticks = 0
	while not _glass_tide_bridge_queue.is_empty():
		var pos: Vector2i = _glass_tide_bridge_queue.pop_front()
		if not _glass_tide_surface_cell(pos):
			continue
		var step_index := _glass_tide_bridge_total - _glass_tide_bridge_queue.size() - 1
		set_block(pos.x, pos.y, int(BlockDefs.BLOCKS.tideglass.id))
		tideglass_bridge_cell_crystallized.emit(pos, step_index, _glass_tide_bridge_total)
		if _glass_tide_bridge_queue.is_empty():
			_glass_tide_bridge_total = 0
		return 1
	_glass_tide_bridge_total = 0
	return 0


func melt_heated_tideglass() -> int:
	var tideglass_id := int(BlockDefs.BLOCKS.tideglass.id)
	var areas := _fluid_simulation_areas()
	var chunk_radius := ceili(float(FLUID_ACTIVE_RADIUS_X) / float(CHUNK_WIDTH)) + 1
	var melt_cells: Array[Vector2i] = []
	for pos: Vector2i in _positions_for_block_id_in_chunk_radius(tideglass_id, chunk_radius):
		if not _fluid_position_is_active(pos, areas):
			continue
		for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor := get_block(pos.x + offset.x, pos.y + offset.y)
			if float(neighbor.get("temperature", 0.0)) >= 0.8:
				melt_cells.append(pos)
				break
	for pos in melt_cells:
		set_block(pos.x, pos.y, int(BlockDefs.BLOCKS.glass_tide.id), 0)
	return melt_cells.size()


func tick_fluids() -> void:
	fluid_tick += 1
	var fluid_ids: Dictionary = {}
	# The set of block IDs is tiny compared with the thousands of tiles in active
	# chunks. Positions are collected only when that fluid's own tick is due.
	for raw_id in block_id_counts.keys():
		var id := int(raw_id)
		if is_fluid_id(id):
			fluid_ids[id] = true
	var ordered_ids := fluid_ids.keys()
	ordered_ids.sort()
	for id in ordered_ids:
		simulate_fluid(int(id))
	crystallize_glass_tide_bridges()
	_advance_glass_tide_bridge_crystallization()
	melt_heated_tideglass()
	# Contact hardening cannot change between fluid updates, so avoid another active
	# chunk traversal on every rendered frame.
	if fluid_tick % 4 == 0:
		harden_water_touching_lava()
	if fluid_tick % CLIMATE_TICK_EVERY == 0:
		_tick_biome_temperature()


func _tile_biome_temperature(pos: Vector2i) -> float:
	var definition := _biome_definition(_ecology_biome_at(pos))
	var environment: Dictionary = definition.get("environment", {}) if definition.get("environment", {}) is Dictionary else {}
	var base_temperature := float(environment.get("temperature", 0.0))
	var altitude := maxi(0, _terrain_surface_y(pos.x) - pos.y - ALTITUDE_COOLING_START_TILES)
	return clampf(base_temperature - float(altitude) * ALTITUDE_COOLING_PER_TILE, -1.0, 1.0)


func _has_local_heat(pos: Vector2i) -> bool:
	for offset in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		if float(get_block(pos.x + offset.x, pos.y + offset.y).get("temperature", 0.0)) >= LOCAL_MELT_TEMPERATURE:
			return true
	return false


func _challenge_granular_plug_positions(chunk_x: int) -> Array[Vector2i]:
	var start_x := chunk_x * CHUNK_WIDTH
	match _challenge_pattern_at_chunk(chunk_x):
		20, 21:
			return [Vector2i(start_x + 9, CHALLENGE_BASE_Y + 5)]
		31:
			return [
				Vector2i(start_x + 6, CHALLENGE_BASE_Y),
				Vector2i(start_x + 11, CHALLENGE_BASE_Y),
			]
	return []


func _is_challenge_granular_plug(pos: Vector2i) -> bool:
	if world_mode != WORLD_MODE_CHALLENGE:
		return false
	var chunk_x := floori(float(pos.x) / float(CHUNK_WIDTH))
	return pos in _challenge_granular_plug_positions(chunk_x)


func _temperature_candidate(block_name: String, should_freeze: bool) -> Variant:
	if not BlockDefs.BLOCKS.has(block_name):
		return null
	var positions := _active_positions_for_block_id(int(BlockDefs.BLOCKS[block_name]["id"]))
	var eligible: Array[Vector2i] = []
	var areas := _fluid_simulation_areas()
	for pos: Vector2i in positions:
		# Melted hopper water is the opened timer. Keep it from refreezing inside
		# geometry that ecology classifies as a cold cavern.
		if block_name == "water" and should_freeze and _is_challenge_granular_plug(pos):
			continue
		# The ice plug is the timer for granular hopper challenges. Do not let an
		# off-screen chunk consume it before the player reaches the checkpoint. Once
		# approached, allow this exact plug to melt even if it is just beyond the
		# regular fluid simulation rectangle at the entrance to the obstacle.
		var is_hopper_plug := false
		if block_name == "ice" and world_mode == WORLD_MODE_CHALLENGE:
			is_hopper_plug = _is_challenge_granular_plug(pos)
			if is_hopper_plug and not _challenge_granular_trap_active(pos):
				continue
		if not _fluid_position_is_active(pos, areas) and not is_hopper_plug:
			continue
		# This plug is an explicit proximity timer rather than ordinary biome ice.
		# Deep hopper geometry can be classified as cavern terrain, so applying the
		# cavern temperature here would leave the authored obstacle sealed forever.
		if is_hopper_plug:
			eligible.append(pos)
			continue
		var temperature := _tile_biome_temperature(pos)
		if should_freeze:
			if temperature <= WATER_FREEZE_TEMPERATURE and not _has_local_heat(pos):
				eligible.append(pos)
		elif temperature >= ICE_MELT_TEMPERATURE or _has_local_heat(pos):
			eligible.append(pos)
	if eligible.is_empty():
		return null
	var cycle := floori(float(fluid_tick) / float(CLIMATE_TICK_EVERY))
	eligible.sort_custom(func(a: Vector2i, b: Vector2i):
		return _world_random("climate:%d:%d:%d" % [a.x, a.y, cycle]) < _world_random("climate:%d:%d:%d" % [b.x, b.y, cycle])
	)
	return eligible[0]


func _tick_biome_temperature() -> void:
	var freeze_candidate = _temperature_candidate("water", true)
	var melt_candidate = _temperature_candidate("ice", false)
	var changed_positions: Array[Vector2i] = []
	_suspend_state_changed = true
	if freeze_candidate is Vector2i:
		_set_generated_block(freeze_candidate.x, freeze_candidate.y, "ice")
		changed_positions.append(freeze_candidate)
	if melt_candidate is Vector2i:
		_set_generated_block(melt_candidate.x, melt_candidate.y, "water", 0)
		changed_positions.append(melt_candidate)
	_suspend_state_changed = false
	if not changed_positions.is_empty():
		static_tiles_changed.emit()
		lighting_changed.emit()
		state_changed.emit()
		# Climate changes are applied atomically while regular world signals are
		# suspended. Replicate their final state after the batch so multiplayer
		# guests see water freeze and ice melt without requiring a new snapshot.
		for pos: Vector2i in changed_positions:
			tile_changed.emit(
				pos.x,
				pos.y,
				block_id(pos.x, pos.y),
				get_fluid_level(pos.x, pos.y),
				bool(fluid_falling.get(pos, false)),
			)


func _granular_target_has_player(pos: Vector2i) -> bool:
	var bx := float(pos.x * BlockDefs.TILE)
	var by := float(pos.y * BlockDefs.TILE)
	if rect_overlap(
		float(player["x"]), float(player["y"]), float(player["w"]), float(player["h"]),
		bx, by, BlockDefs.TILE, BlockDefs.TILE
	):
		return true
	for raw_player_id in multiplayer_player_targets:
		if not multiplayer_player_targets[raw_player_id] is Dictionary:
			continue
		var remote := multiplayer_player_targets[raw_player_id] as Dictionary
		if rect_overlap(
			float(remote.get("x", 0.0)), float(remote.get("y", 0.0)),
			float(remote.get("w", 20.0)), float(remote.get("h", 28.0)),
			bx, by, BlockDefs.TILE, BlockDefs.TILE
		):
			return true
	return false


func _granular_target_clear(pos: Vector2i) -> bool:
	return in_bounds(pos.x, pos.y) and block_id(pos.x, pos.y) == 0 and not _granular_target_has_player(pos)


func _granular_target_is_water(pos: Vector2i) -> bool:
	return in_bounds(pos.x, pos.y) and get_block(pos.x, pos.y).get("name", "") == "water" and not _granular_target_has_player(pos)


func _granular_exit_below_water(first_water: Vector2i) -> Variant:
	var cursor := first_water
	var last_water := first_water
	for _depth in 32:
		if _granular_target_is_water(cursor):
			last_water = cursor
			cursor.y += 1
			continue
		if _granular_target_clear(cursor):
			return cursor
		# A closed pool has no air below it. Settle into its lowest water cell so
		# the grain reaches the solid bottom without pushing water above itself.
		return last_water if _granular_target_is_water(last_water) else null
	return null


func _repair_challenge_hopper_water(chunk_x: int) -> void:
	# The earlier swap implementation could carry the melted source upward through
	# the funnel and duplicate it. Pattern hoppers never author water above the plug,
	# so removing it here safely repairs already-saved affected sections.
	var start_x := chunk_x * CHUNK_WIDTH
	var pattern := _challenge_pattern_at_chunk(chunk_x)
	if pattern in [20, 21]:
		for x in range(start_x + 4, start_x + 14):
			for y in range(CHALLENGE_BASE_Y, CHALLENGE_BASE_Y + 5):
				if get_block(x, y).get("name", "") == "water":
					set_block(x, y, 0)
	elif pattern == 31:
		for local_x in [6, 11]:
			var gate_pos := Vector2i(start_x + local_x, CHALLENGE_BASE_Y - 1)
			if get_block(gate_pos.x, gate_pos.y).get("name", "") == "water":
				set_block(gate_pos.x, gate_pos.y, 0)
	for plug: Vector2i in _challenge_granular_plug_positions(chunk_x):
		if get_block(plug.x, plug.y).get("name", "") == "water" and get_fluid_level(plug.x, plug.y) != 0:
			set_block(plug.x, plug.y, int(BlockDefs.BLOCKS.water.id), 0)
func _challenge_granular_trap_active(pos: Vector2i) -> bool:
	if world_mode != WORLD_MODE_CHALLENGE:
		return true
	var chunk_x := floori(float(pos.x) / float(CHUNK_WIDTH))
	var pattern := _challenge_pattern_at_chunk(chunk_x)
	if pattern not in [20, 21, 31]:
		return true
	var local_x := posmod(pos.x, CHUNK_WIDTH)
	var authored_trap_cell := (
		pattern in [20, 21]
		and local_x >= 4 and local_x <= 13
		and pos.y >= CHALLENGE_BASE_Y and pos.y <= CHALLENGE_BASE_Y + 6
	) or (
		pattern == 31
		and local_x in [6, 11]
		and pos.y >= CHALLENGE_BASE_Y - 1 and pos.y <= CHALLENGE_BASE_Y + 1
	)
	if not authored_trap_cell:
		return true
	if _challenge_activated_granular_traps.has(chunk_x):
		_repair_challenge_hopper_water(chunk_x)
		return true
	var player_tile_x := floori((float(player["x"]) + float(player["w"]) * 0.5) / float(BlockDefs.TILE))
	if absi(player_tile_x - chunk_x * CHUNK_WIDTH) <= 5:
		_challenge_activated_granular_traps[chunk_x] = true
		_repair_challenge_hopper_water(chunk_x)
		return true
	return false


func tick_granular() -> void:
	granular_tick += 1
	if granular_tick % GRANULAR_TICK_EVERY != 0:
		return
	var has_granular := false
	for raw_id in block_id_counts.keys():
		if BlockDefs.get_block_by_id(int(raw_id)).get("falls_when_unsupported", false):
			has_granular = true
			break
	if not has_granular:
		return
	var positions: Array[Vector2i] = []
	for raw_id in block_id_counts.keys():
		var id := int(raw_id)
		if BlockDefs.get_block_by_id(id).get("falls_when_unsupported", false):
			positions.append_array(_active_positions_for_block_id(id))
	positions.sort_custom(func(a: Vector2i, b: Vector2i):
		if a.y != b.y:
			return a.y > b.y
		return a.x < b.x
	)
	var changed_positions: Dictionary = {}
	for pos: Vector2i in positions:
		var id := block_id(pos.x, pos.y)
		if id == 0:
			continue
		var block := BlockDefs.get_block_by_id(id)
		if not block.get("falls_when_unsupported", false):
			continue
		if not _challenge_granular_trap_active(pos):
			continue
		var below := Vector2i(pos.x, pos.y + 1)
		var below_block := get_block(below.x, below.y)
		if below_block.get("fluid", false) and float(below_block.get("temperature", 0.0)) >= 0.8:
			set_block(pos.x, pos.y, 0)
			changed_positions[pos] = true
			continue
		var target := Vector2i(pos.x, pos.y + 1)
		if below_block.get("name", "") == "water":
			var water_exit = _granular_exit_below_water(below)
			if not water_exit is Vector2i:
				continue
			target = water_exit as Vector2i
		if not _granular_target_clear(target) and not _granular_target_is_water(target):
			if not block.get("settles_diagonally", false):
				continue
			var directions := [-1, 1] if posmod(granular_tick / GRANULAR_TICK_EVERY + pos.x, 2) == 0 else [1, -1]
			var found := false
			for dx: int in directions:
				var side := Vector2i(pos.x + dx, pos.y)
				var diagonal := Vector2i(pos.x + dx, pos.y + 1)
				var side_passable := _granular_target_clear(side) or _granular_target_is_water(side)
				var diagonal_target: Variant = diagonal
				if _granular_target_is_water(diagonal):
					diagonal_target = _granular_exit_below_water(diagonal)
				var diagonal_available := diagonal_target is Vector2i and (
					_granular_target_clear(diagonal_target as Vector2i)
					or _granular_target_is_water(diagonal_target as Vector2i)
				)
				if side_passable and diagonal_available:
					target = diagonal_target as Vector2i
					found = true
					break
			if not found:
				continue
		if _granular_target_is_water(target):
			set_block(pos.x, pos.y, 0)
			set_block(target.x, target.y, id)
			changed_positions[pos] = true
			changed_positions[target] = true
			continue
		tiles.erase(pos)
		_unindex_tile(pos, id)
		tiles[target] = id
		_index_tile(target, id)
		if burning_tiles.has(pos):
			burning_tiles[target] = burning_tiles[pos]
			burning_tiles.erase(pos)
		changed_positions[pos] = true
		changed_positions[target] = true
	if not changed_positions.is_empty():
		static_tiles_changed.emit()
		lighting_changed.emit()
		state_changed.emit()
		if not _suspend_state_changed:
			for changed_pos: Vector2i in changed_positions:
				var changed_id := block_id(changed_pos.x, changed_pos.y)
				tile_changed.emit(changed_pos.x, changed_pos.y, changed_id, -1, false)


func tick_trees() -> void:
	tree_tick += 1
	_tick_plants()
	if tree_tick % PLANT_BREED_CHECK_EVERY == 0:
		_try_breed_plants()
	if tree_tick % TREE_GROW_EVERY != 0:
		return
	var keys: Array = tree_growth.keys()
	for key in keys:
		var pos := key as Vector2i
		if _is_in_active_simulation(pos):
			_advance_tree(pos)


func _plant_definition(block_name: String) -> Dictionary:
	var block: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	return block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}


func _plant_medium_at(pos: Vector2i) -> String:
	var name := str(get_block(pos.x, pos.y).get("name", "air"))
	return name if name == "water" or name == "lava" else "air"


func _plant_anchor_offsets(face: String) -> Array[Vector2i]:
	match face:
		"ceiling": return [Vector2i.UP]
		"wall_left": return [Vector2i.LEFT]
		"wall_right": return [Vector2i.RIGHT]
		_: return [Vector2i.DOWN]


func _plant_has_required_fluid(pos: Vector2i, planting: Dictionary) -> bool:
	var required := str(planting.get("required_fluid", "none"))
	var relation := str(planting.get("fluid_relation", "none"))
	if required == "none":
		return true
	var immersed := str(get_block(pos.x, pos.y).get("name", "air")) == required
	var adjacent := false
	for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		if str(get_block(pos.x + offset.x, pos.y + offset.y).get("name", "air")) == required:
			adjacent = true
			break
	match relation:
		"immersed": return immersed
		"adjacent": return adjacent
		"adjacent_or_immersed": return immersed or adjacent
		_: return false


func _plant_environment_valid(pos: Vector2i, definition: Dictionary) -> bool:
	if not in_bounds(pos.x, pos.y):
		return false
	var planting: Dictionary = definition.get("planting", {}) if definition.get("planting", {}) is Dictionary else {}
	var required_medium := str(planting.get("required_medium", "air"))
	var occupied_block := get_block(pos.x, pos.y)
	if required_medium == "air" and bool(occupied_block.get("solid", false)):
		return false
	if _plant_medium_at(pos) != required_medium:
		return false
	if not _plant_has_required_fluid(pos, planting):
		return false
	if bool(planting.get("requires_open_to_sky", false)) and not _open_to_sky(pos.x, pos.y, -16):
		return false
	var allowed_tags: Array = planting.get("allowed_substrate_tags", []) if planting.get("allowed_substrate_tags", []) is Array else []
	for raw_face in planting.get("anchor_faces", ["floor"]):
		for offset in _plant_anchor_offsets(str(raw_face)):
			var support := get_block(pos.x + offset.x, pos.y + offset.y)
			if not support.get("solid", false):
				continue
			if allowed_tags.is_empty() or _arrays_intersect(_semantic_tags(str(support.get("name", "air"))), allowed_tags):
				return true
	return allowed_tags.is_empty() and required_medium in ["water", "lava"]


func _plant_site_valid(pos: Vector2i, definition: Dictionary) -> bool:
	return not plant_cells.has(pos) and _plant_environment_valid(pos, definition)


func can_plant_at(block_name: String, tx: int, ty: int, require_player_reach: bool = true) -> bool:
	if require_player_reach and not player_near(tx, ty):
		return false
	if inventory.get(block_name, 0) <= 0:
		return false
	var block: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	if not bool(block.get("plant", false)):
		return false
	var definition := _plant_definition(block_name)
	return not definition.is_empty() and _plant_site_valid(Vector2i(tx, ty), definition)


func is_planting_item(block_name: String) -> bool:
	return bool(BlockDefs.BLOCKS.get(block_name, {}).get("plant", false)) or not _tree_definition_for_propagation_block(block_name).is_empty()


func can_plant_item_at(block_name: String, tx: int, ty: int, require_player_reach: bool = true) -> bool:
	if bool(BlockDefs.BLOCKS.get(block_name, {}).get("plant", false)):
		return can_plant_at(block_name, tx, ty, require_player_reach)
	if require_player_reach and not player_near(tx, ty):
		return false
	if inventory.get(block_name, 0) <= 0 or not in_bounds(tx, ty):
		return false
	var definition := _tree_definition_for_propagation_block(block_name)
	if definition.is_empty() or int(get_block(tx, ty).get("id", 0)) != 0 or plant_cells.has(Vector2i(tx, ty)):
		return false
	var bx := tx * BlockDefs.TILE
	var by := ty * BlockDefs.TILE
	if rect_overlap(player["x"], player["y"], player["w"], player["h"], bx, by, BlockDefs.TILE, BlockDefs.TILE):
		return false
	var support := get_block(tx, ty + 1)
	var planting: Dictionary = definition.get("planting", {}) if definition.get("planting", {}) is Dictionary else {}
	var allowed_tags: Array = planting.get("allowed_substrate_tags", []) if planting.get("allowed_substrate_tags", []) is Array else []
	return bool(support.get("solid", false)) and (allowed_tags.is_empty() or _arrays_intersect(_semantic_tags(str(support.get("name", "air"))), allowed_tags))


func _surface_creeper_cell_supported(pos: Vector2i) -> bool:
	for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		if get_block(pos.x + offset.x, pos.y + offset.y).get("solid", false):
			return true
	return false


func _plant_instance_environment_valid(anchor: Vector2i, data: Dictionary, definition: Dictionary) -> bool:
	if not _plant_environment_valid(anchor, definition):
		return false
	var growth: Dictionary = definition.get("growth", {}) if definition.get("growth", {}) is Dictionary else {}
	if str(growth.get("form", "vertical_up")) != "surface_creeper":
		return true
	for raw_cell in (data.get("cells", []) as Array):
		if raw_cell is Vector2i and not _surface_creeper_cell_supported(raw_cell):
			return false
	return true


func _prune_invalid_generated_plants(min_x: int, max_x: int) -> void:
	for raw_anchor in plant_growth.keys():
		var anchor := raw_anchor as Vector2i
		if anchor.x < min_x or anchor.x > max_x:
			continue
		var data: Dictionary = plant_growth.get(anchor, {})
		var definition := _plant_definition(str(data.get("block_name", "")))
		if not definition.is_empty() and _plant_instance_environment_valid(anchor, data, definition):
			continue
		for raw_cell in (data.get("cells", []) as Array):
			if raw_cell is Vector2i:
				plant_cells.erase(raw_cell)
		plant_growth.erase(anchor)
		tree_growth.erase(anchor)


func _plant_growth_cell_valid(pos: Vector2i, definition: Dictionary, form: String) -> bool:
	if not in_bounds(pos.x, pos.y) or plant_cells.has(pos):
		return false
	if form == "vertical_down":
		return get_block(pos.x, pos.y).get("solid", false)
	var planting: Dictionary = definition.get("planting", {})
	if _plant_medium_at(pos) != str(planting.get("required_medium", "air")):
		return false
	if form == "surface_creeper":
		return _surface_creeper_cell_supported(pos)
	return true


func _next_plant_cell(anchor: Vector2i, data: Dictionary, definition: Dictionary) -> Vector2i:
	var growth: Dictionary = definition.get("growth", {})
	var form := str(growth.get("form", "vertical_up"))
	var cells: Array = data.get("cells", [])
	var traits: Dictionary = data.get("traits", {}) if data.get("traits", {}) is Dictionary else {}
	var length_multiplier := clampf(float(traits.get("maximum_length_multiplier", 1.0)), 0.75, 1.25)
	var length := mini(roundi(float(growth.get("maximum_length_blocks", 4)) * length_multiplier), int(data.get("stage", 1)))
	match form:
		"vertical_down": return anchor + Vector2i(0, length)
		"hanging": return anchor + Vector2i(0, length)
		"bidirectional_vertical":
			var distance := ceili(float(length) / 2.0)
			return anchor + Vector2i(0, -distance if length % 2 == 1 else distance)
		"surface_creeper":
			var current: Vector2i = cells.back() if not cells.is_empty() else anchor
			var seed := posmod(anchor.x * 37 + anchor.y * 71 + length * 13, 4)
			var offsets: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
			for index in 4:
				var candidate := current + offsets[(seed + index) % 4]
				if _plant_growth_cell_valid(candidate, definition, form):
					return candidate
			return current
		_: return anchor + Vector2i(0, -length)


func _place_generated_plant(pos: Vector2i, block_name: String, definition: Dictionary, mature: bool) -> bool:
	if plant_cells.has(pos) or definition.is_empty() or not _plant_site_valid(pos, definition):
		return false
	var data := {"block_name": block_name, "stage": 1, "ticks": 0, "cells": [pos], "active_nearby_ticks": 0, "breeding_cooldown": 0, "parents": [], "traits": {}}
	plant_growth[pos] = data
	plant_cells[pos] = pos
	if not mature:
		return true
	var growth: Dictionary = definition.get("growth", {}) if definition.get("growth", {}) is Dictionary else {}
	var form := str(growth.get("form", "vertical_up"))
	if form == "tree":
		return true
	var stage_count := int(growth.get("stage_count", 1))
	while int(data["stage"]) < stage_count:
		var candidate := _next_plant_cell(pos, data, definition)
		if not _plant_growth_cell_valid(candidate, definition, form):
			break
		data["stage"] = int(data["stage"]) + 1
		if candidate not in (data["cells"] as Array):
			(data["cells"] as Array).append(candidate)
			plant_cells[candidate] = pos
	return true


func _tick_plants() -> void:
	var changed := false
	var changed_anchors: Dictionary = {}
	for anchor: Vector2i in plant_growth.keys():
		if not _is_in_active_simulation(anchor):
			continue
		var data: Dictionary = plant_growth[anchor]
		data["breeding_cooldown"] = maxi(0, int(data.get("breeding_cooldown", 0)) - 1)
		var nearest_player: Dictionary = _nearest_player_target(Vector2(anchor))
		var player_plant_distance := Vector2(anchor).distance_to(nearest_player.get("position", _player_creature_position()))
		data["active_nearby_ticks"] = maxi(0, int(data.get("active_nearby_ticks", 0)) + (1 if player_plant_distance <= CREATURE_ACTIVE_RADIUS else -2))
		var definition := _plant_definition(str(data.get("block_name", "")))
		if definition.is_empty():
			continue
		if not _plant_instance_environment_valid(anchor, data, definition):
			for raw_cell in (data.get("cells", []) as Array):
				if raw_cell is Vector2i:
					plant_cells.erase(raw_cell)
			plant_growth.erase(anchor)
			changed = true
			plant_changed.emit(anchor.x, anchor.y)
			continue
		var growth: Dictionary = definition.get("growth", {})
		var form := str(growth.get("form", "vertical_up"))
		if form == "decorative":
			continue
		if form == "tree":
			data["ticks"] = int(data.get("ticks", 0)) + 1
			var tree_durations: Array = growth.get("ticks_per_stage", [120])
			var tree_required_ticks := int(tree_durations[0]) if not tree_durations.is_empty() else 120
			if int(data["ticks"]) >= tree_required_ticks and _start_component_tree(anchor, data, definition):
				changed = true
			continue
		var stage := int(data.get("stage", 1))
		var stage_count := int(growth.get("stage_count", 2))
		if stage >= stage_count:
			continue
		data["ticks"] = int(data.get("ticks", 0)) + 1
		var durations: Array = growth.get("ticks_per_stage", [120])
		var required_ticks := int(durations[mini(stage - 1, durations.size() - 1)]) if not durations.is_empty() else 120
		if int(data["ticks"]) < required_ticks:
			continue
		var candidate := _next_plant_cell(anchor, data, definition)
		if not _plant_growth_cell_valid(candidate, definition, str(growth.get("form", "vertical_up"))):
			data["ticks"] = required_ticks
			continue
		data["ticks"] = 0
		data["stage"] = stage + 1
		if candidate not in data["cells"]:
			(data["cells"] as Array).append(candidate)
			plant_cells[candidate] = anchor
			changed = true
			changed_anchors[anchor] = true
	if changed:
		lighting_changed.emit()
		state_changed.emit()
		for raw_anchor in changed_anchors.keys():
			var changed_anchor := raw_anchor as Vector2i
			plant_changed.emit(changed_anchor.x, changed_anchor.y)


func _tree_component_semantic_words(block_name: String, tags: Array, definition: Dictionary) -> Array:
	var words: Array = tags.duplicate()
	var display: Dictionary = definition.get("display", {}) if definition.get("display", {}) is Dictionary else {}
	var fragments: Array = [block_name]
	for field in ["name", "description"]:
		var localized: Dictionary = display.get(field, {}) if display.get(field, {}) is Dictionary else {}
		fragments.append_array(localized.values())
	for fragment in fragments:
		var normalized := str(fragment).to_lower()
		for separator in [".", "_", "-", ",", ":", ";", "/", "(", ")"]:
			normalized = normalized.replace(separator, " ")
		for word in normalized.split(" ", false):
			if word not in words:
				words.append(word)
	return words


func _tree_component_block_names(definition: Dictionary) -> Dictionary:
	var components: Dictionary = definition.get("tree_components", {}) if definition.get("tree_components", {}) is Dictionary else {}
	var trunk_name := BlockDefs.name_for_content_id(str(components.get("trunk_content_id", "")))
	var foliage_name := BlockDefs.name_for_content_id(str(components.get("foliage_content_id", "")))
	if trunk_name.is_empty() or foliage_name.is_empty() or trunk_name == foliage_name:
		return {}
	var trunk: Dictionary = BlockDefs.BLOCKS.get(trunk_name, {})
	var foliage: Dictionary = BlockDefs.BLOCKS.get(foliage_name, {})
	if not trunk.get("solid", false) or not foliage.get("solid", false):
		return {}
	var trunk_tags := _semantic_tags(trunk_name)
	var foliage_tags := _semantic_tags(foliage_name)
	if not _arrays_intersect(trunk_tags, ["wood", "trunk", "log", "bark"]) or _arrays_intersect(trunk_tags, ["crafted", "planks", "item"]):
		return {}
	if not _arrays_intersect(foliage_tags, ["leaves", "leaf", "foliage"]) or _arrays_intersect(foliage_tags, ["crafted", "item"]):
		return {}
	var forbidden_tree_tokens := ["alloy", "brick", "charcoal", "copper", "crystal", "gem", "glass", "ice", "lava", "metal", "mineral", "ore", "rock", "sand", "stone"]
	var trunk_definition: Dictionary = trunk.get("definition", {}) if trunk.get("definition", {}) is Dictionary else {}
	var foliage_definition: Dictionary = foliage.get("definition", {}) if foliage.get("definition", {}) is Dictionary else {}
	var trunk_words := _tree_component_semantic_words(trunk_name, trunk_tags, trunk_definition)
	var foliage_words := _tree_component_semantic_words(foliage_name, foliage_tags, foliage_definition)
	if _arrays_intersect(trunk_words, forbidden_tree_tokens) or _arrays_intersect(foliage_words, forbidden_tree_tokens):
		return {}
	return {"trunk": trunk_name, "foliage": foliage_name}


func _start_component_tree(anchor: Vector2i, data: Dictionary, definition: Dictionary, size_override: int = -1) -> bool:
	var names := _tree_component_block_names(definition)
	if names.is_empty() or not _plant_environment_valid(anchor, definition):
		return false
	for cell: Vector2i in data.get("cells", []):
		plant_cells.erase(cell)
	plant_growth.erase(anchor)
	var trunk_name := str(names["trunk"])
	var foliage_name := str(names["foliage"])
	set_block(anchor.x, anchor.y, int(BlockDefs.BLOCKS[trunk_name]["id"]))
	tree_growth[anchor] = {
		"step": 0,
		"size": size_override if size_override >= 0 else _pick_tree_size(),
		"ceiling": _growth_ceiling(anchor.x, anchor.y),
		"trunk_block_name": trunk_name,
		"foliage_block_name": foliage_name,
		"tree_shape": str((definition.get("tree_components", {}) as Dictionary).get("shape", "oak")),
	}
	plant_changed.emit(anchor.x, anchor.y)
	return true


func place_plant(tx: int, ty: int, block_name: String) -> bool:
	var pos := Vector2i(tx, ty)
	var definition := _plant_definition(block_name)
	if definition.is_empty() or not _plant_site_valid(pos, definition):
		return false
	plant_growth[pos] = {"block_name": block_name, "stage": 1, "ticks": 0, "cells": [pos], "active_nearby_ticks": 0, "breeding_cooldown": 0, "parents": [], "traits": {}}
	plant_cells[pos] = pos
	take_from_inventory(block_name)
	Sfx.place(block_name)
	inventory_changed.emit()
	if block_light_emission(BlockDefs.BLOCKS.get(block_name, {})) > 0.0:
		lighting_changed.emit()
	state_changed.emit()
	plant_changed.emit(pos.x, pos.y)
	return true


func multiplayer_plant_state(anchor: Vector2i) -> Dictionary:
	var data: Dictionary = plant_growth.get(anchor, {}) if plant_growth.get(anchor, {}) is Dictionary else {}
	if data.is_empty():
		return {"anchor_x": anchor.x, "anchor_y": anchor.y, "exists": false}
	var cells: Array[Dictionary] = []
	for raw_cell in (data.get("cells", []) as Array):
		if raw_cell is Vector2i:
			var cell := raw_cell as Vector2i
			cells.append({"x": cell.x, "y": cell.y})
	return {
		"anchor_x": anchor.x,
		"anchor_y": anchor.y,
		"exists": true,
		"block_name": str(data.get("block_name", "")),
		"stage": int(data.get("stage", 1)),
		"ticks": int(data.get("ticks", 0)),
		"active_nearby_ticks": int(data.get("active_nearby_ticks", 0)),
		"breeding_cooldown": int(data.get("breeding_cooldown", 0)),
		"parents": (data.get("parents", []) as Array).duplicate(true),
		"traits": (data.get("traits", {}) as Dictionary).duplicate(true),
		"cells": cells,
	}


func _erase_authoritative_plant(anchor: Vector2i) -> void:
	var existing: Dictionary = plant_growth.get(anchor, {}) if plant_growth.get(anchor, {}) is Dictionary else {}
	for raw_cell in (existing.get("cells", []) as Array):
		if raw_cell is Vector2i and plant_cells.get(raw_cell) == anchor:
			plant_cells.erase(raw_cell)
	plant_growth.erase(anchor)


func apply_authoritative_plant_state(payload: Dictionary) -> bool:
	var anchor := Vector2i(
		int(payload.get("anchor_x", COORD_LIMIT + 1)),
		int(payload.get("anchor_y", COORD_LIMIT + 1)),
	)
	if not in_bounds(anchor.x, anchor.y):
		return false
	_erase_authoritative_plant(anchor)
	if not bool(payload.get("exists", false)):
		lighting_changed.emit()
		state_changed.emit()
		return true
	var block_name := str(payload.get("block_name", ""))
	if not bool(BlockDefs.BLOCKS.get(block_name, {}).get("plant", false)):
		return false
	var cells: Array[Vector2i] = []
	for raw_cell in (payload.get("cells", []) as Array):
		if not raw_cell is Dictionary:
			continue
		var cell := Vector2i(int(raw_cell.get("x", COORD_LIMIT + 1)), int(raw_cell.get("y", COORD_LIMIT + 1)))
		if in_bounds(cell.x, cell.y):
			cells.append(cell)
	if cells.is_empty() or anchor not in cells:
		cells.push_front(anchor)
	for cell in cells:
		if plant_cells.has(cell):
			_erase_authoritative_plant(plant_cells[cell] as Vector2i)
	plant_growth[anchor] = {
		"block_name": block_name,
		"stage": maxi(1, int(payload.get("stage", 1))),
		"ticks": maxi(0, int(payload.get("ticks", 0))),
		"active_nearby_ticks": maxi(0, int(payload.get("active_nearby_ticks", 0))),
		"breeding_cooldown": maxi(0, int(payload.get("breeding_cooldown", 0))),
		"parents": (payload.get("parents", []) as Array).duplicate(true),
		"traits": (payload.get("traits", {}) as Dictionary).duplicate(true),
		"cells": cells,
	}
	for cell in cells:
		plant_cells[cell] = anchor
	lighting_changed.emit()
	state_changed.emit()
	return true


func plant_block_at(tx: int, ty: int) -> Dictionary:
	var pos := Vector2i(tx, ty)
	if not plant_cells.has(pos):
		return {}
	var anchor: Vector2i = plant_cells[pos]
	if pos != anchor and get_block(tx, ty).get("solid", false):
		return {}
	var data: Dictionary = plant_growth.get(anchor, {})
	return BlockDefs.BLOCKS.get(str(data.get("block_name", "")), {})


func remove_plant_at(tx: int, ty: int, harvest: bool = true) -> bool:
	var pos := Vector2i(tx, ty)
	if not plant_cells.has(pos):
		return false
	var anchor: Vector2i = plant_cells[pos]
	var data: Dictionary = plant_growth.get(anchor, {})
	var removed_block: Dictionary = BlockDefs.BLOCKS.get(str(data.get("block_name", "")), {})
	for cell: Vector2i in data.get("cells", []):
		plant_cells.erase(cell)
	plant_growth.erase(anchor)
	if harvest:
		give_to_inventory(str(data.get("block_name", "")), 1)
		inventory_changed.emit()
	if block_light_emission(removed_block) > 0.0:
		lighting_changed.emit()
	state_changed.emit()
	plant_changed.emit(anchor.x, anchor.y)
	return true


func _plant_is_mature(data: Dictionary, definition: Dictionary) -> bool:
	return int(data.get("stage", 1)) >= int((definition.get("growth", {}) as Dictionary).get("stage_count", 1))


func _nearest_creature_for_plant(anchor: Vector2i, radius: float = 5.0) -> Dictionary:
	var nearest: Dictionary = {}
	var nearest_distance := radius + 1.0
	for creature: Dictionary in creatures.values():
		var distance := Vector2(anchor).distance_to(Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0))))
		if distance < nearest_distance:
			nearest = creature
			nearest_distance = distance
	return nearest


func _plant_hybrid_site(center: Vector2i, definition: Dictionary) -> Variant:
	var offsets: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i(-2, 0), Vector2i(2, 0), Vector2i(-1, -1), Vector2i(1, -1)]
	offsets.shuffle()
	for offset: Vector2i in offsets:
		var candidate := center + offset
		if _plant_site_valid(candidate, definition):
			return candidate
	return null


func _mixed_plant_traits(first_definition: Dictionary, second_definition: Dictionary, anchor: Vector2i, accepts_creature_traits: bool = true) -> Dictionary:
	var first_visual: Dictionary = first_definition.get("visual", {})
	var second_visual: Dictionary = second_definition.get("visual", {})
	var first_palette: Array = first_visual.get("palette", [])
	var second_palette: Array = second_visual.get("palette", [])
	var palette: Array = []
	if not first_palette.is_empty():
		palette.append(first_palette[0])
	if not second_palette.is_empty():
		palette.append(second_palette[mini(1, second_palette.size() - 1)])
	var traits := {
		"palette": palette,
		"pattern": first_visual.get("pattern", "organic") if randf() < 0.5 else second_visual.get("pattern", "organic"),
		"stem_shape": first_visual.get("stem_shape", "segmented") if randf() < 0.5 else second_visual.get("stem_shape", "segmented"),
		"canopy_shape": first_visual.get("canopy_shape", "tuft") if randf() < 0.5 else second_visual.get("canopy_shape", "tuft"),
		"maximum_length_multiplier": randf_range(0.9, 1.1),
	}
	var donor := _nearest_creature_for_plant(anchor) if accepts_creature_traits else {}
	if not donor.is_empty():
		var donor_definition := _creature_definition(str(donor.get("block_name", "")))
		var donor_palette: Array = donor.get("palette", [])
		if donor_palette.is_empty():
			donor_palette = (donor_definition.get("visual", {}) as Dictionary).get("palette", [])
		if not donor_palette.is_empty():
			palette.append(donor_palette[0])
			traits["palette"] = palette.slice(0, 4)
		traits["light_preference"] = str((donor_definition.get("habitat", {}) as Dictionary).get("light_preference", "neutral"))
		traits["cross_kingdom_donor"] = str(donor.get("content_id", ""))
	return traits


func _try_breed_plants() -> void:
	var anchors: Array = plant_growth.keys()
	for i in anchors.size():
		var first_anchor: Vector2i = anchors[i]
		var first: Dictionary = plant_growth[first_anchor]
		var first_definition := _plant_definition(str(first.get("block_name", "")))
		var first_hybridization: Dictionary = first_definition.get("hybridization", {})
		var required_ticks := int(first_hybridization.get("active_nearby_seconds", 600)) * 60
		if int(first.get("breeding_cooldown", 0)) > 0 or int(first.get("active_nearby_ticks", 0)) < required_ticks or not _plant_is_mature(first, first_definition):
			continue
		for j in range(i + 1, anchors.size()):
			var second_anchor: Vector2i = anchors[j]
			if Vector2(first_anchor).distance_to(Vector2(second_anchor)) > 5.0:
				continue
			var second: Dictionary = plant_growth[second_anchor]
			var second_definition := _plant_definition(str(second.get("block_name", "")))
			var second_hybridization: Dictionary = second_definition.get("hybridization", {})
			if str(first_hybridization.get("group", "flora")) != str(second_hybridization.get("group", "flora")):
				continue
			if int(second.get("breeding_cooldown", 0)) > 0 or int(second.get("active_nearby_ticks", 0)) < int(second_hybridization.get("active_nearby_seconds", 600)) * 60 or not _plant_is_mature(second, second_definition):
				continue
			var child_name := str(first.get("block_name", "")) if randf() < 0.5 else str(second.get("block_name", ""))
			var child_definition := _plant_definition(child_name)
			var child_anchor: Variant = _plant_hybrid_site(Vector2i(roundi((first_anchor.x + second_anchor.x) * 0.5), roundi((first_anchor.y + second_anchor.y) * 0.5)), child_definition)
			if child_anchor == null:
				continue
			var chance := maxf(float(first_hybridization.get("hybrid_chance", 0.03)), float(second_hybridization.get("hybrid_chance", 0.03)))
			var traits: Dictionary = {}
			if randf() < chance:
				var accepts_creature_traits := bool(first_hybridization.get("accepts_creature_traits", true)) or bool(second_hybridization.get("accepts_creature_traits", true))
				traits = _mixed_plant_traits(first_definition, second_definition, child_anchor as Vector2i, accepts_creature_traits)
			var pos := child_anchor as Vector2i
			plant_growth[pos] = {"block_name": child_name, "stage": 1, "ticks": 0, "cells": [pos], "active_nearby_ticks": 0, "breeding_cooldown": 0, "parents": [BlockDefs.content_id_for_name(str(first.get("block_name", ""))), BlockDefs.content_id_for_name(str(second.get("block_name", "")))], "traits": traits}
			plant_cells[pos] = pos
			first["breeding_cooldown"] = int(first_hybridization.get("cooldown_seconds", 1800)) * 60
			second["breeding_cooldown"] = int(second_hybridization.get("cooldown_seconds", 1800)) * 60
			first["active_nearby_ticks"] = 0
			second["active_nearby_ticks"] = 0
			state_changed.emit()
			plant_changed.emit(pos.x, pos.y)
			return


func _creature_definition(block_name: String) -> Dictionary:
	var block: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	return definition if str(definition.get("kind", "")) == "creature" else {}


func _new_creature_id() -> String:
	return "creature_%s" % Crypto.new().generate_random_bytes(10).hex_encode()


func spawn_creature(block_name: String, pos: Vector2, natural: bool = false, parents: Array = [], palette: Array = [], traits: Dictionary = {}) -> String:
	var definition := _creature_definition(block_name)
	if definition.is_empty() or creatures.size() >= CREATURE_MAX_WORLD:
		return ""
	var safe_pos: Variant = _nearest_safe_creature_position(pos, definition, 6)
	if safe_pos == null:
		return ""
	pos = safe_pos as Vector2
	var id := _new_creature_id()
	var stats: Dictionary = definition.get("stats", {})
	creatures[id] = {
		"id": id, "block_name": block_name, "content_id": BlockDefs.content_id_for_name(block_name),
		"x": pos.x, "y": pos.y, "vx": 0.0, "vy": 0.0, "facing": 1,
		"health": int(stats.get("health", 3)) + int(traits.get("health_bonus", 0)), "provoked_ticks": 0, "flee_ticks": 0,
		"attack_cooldown": 0, "active_nearby_ticks": 0, "breeding_cooldown": 0,
		"plant_interest_ticks": 0, "plant_interest_cooldown": 0, "fear_cooldown": 0,
		"hunt_target_id": "", "hunt_cooldown": 0, "flee_source_id": "", "dead": false,
		"spawned_at_tick": creature_tick,
		"vertical_wander_ticks": randi_range(90, 240), "vertical_wander_target_y": pos.y,
		"avoidance_ticks": 0, "avoidance_x": 0.0, "avoidance_y": 0.0,
		"work_cooldown": randi_range(20, 70), "work_action": "", "work_action_ticks": 0,
		"carried_materials": 4 if "shagot" in (definition.get("tags", []) as Array) else 0, "built_blocks": 0,
		"shagot_activity": "", "shagot_activity_ticks": 0, "shagot_follow_player_id": "",
		"shagot_task_kind": "", "shagot_task_stage": "", "shagot_task_target_x": 0, "shagot_task_target_y": 0,
		"shagot_work_stand_x": 0.0, "shagot_work_stand_y": 0.0,
		"shagot_wander_target_x": pos.x, "shagot_wander_ticks": 0,
		"voice_cooldown": randi_range(60 * 3, 60 * 8),
		"natural": natural, "parents": parents.duplicate(), "palette": palette.duplicate(), "traits": traits.duplicate(true),
	}
	state_changed.emit()
	return id


func spawn_creature_from_item(tx: int, ty: int, block_name: String) -> bool:
	if not player_near(tx, ty) or inventory.get(block_name, 0) <= 0:
		return false
	var definition := _creature_definition(block_name)
	if definition.is_empty() or not _creature_position_matches(Vector2(tx + 0.5, ty + 0.5), definition):
		return false
	if spawn_creature(block_name, Vector2(tx + 0.5, ty + 0.5)) == "":
		return false
	take_from_inventory(block_name)
	inventory_changed.emit()
	return true


func _creature_position_matches(pos: Vector2, definition: Dictionary) -> bool:
	var locomotion: Dictionary = definition.get("locomotion", {})
	var medium := str(locomotion.get("medium", "air"))
	var size := clampf(float((definition.get("stats", {}) as Dictionary).get("size", 0.8)), 0.45, 1.4)
	var half_width := size * 0.42
	var half_height := size * 0.28
	for y in range(floori(pos.y - half_height), floori(pos.y + half_height) + 1):
		for x in range(floori(pos.x - half_width), floori(pos.x + half_width) + 1):
			var occupied := get_block(x, y)
			if medium == "air" and occupied.get("id", 0) != 0 and not _creature_can_pass_through_block(definition, occupied):
				return false
			if medium != "air" and str(occupied.get("name", "")) != medium:
				return false
	var cell := Vector2i(floori(pos.x), floori(pos.y))
	var block := get_block(cell.x, cell.y)
	if medium == "air":
		if block.get("id", 0) != 0 and not _creature_can_pass_through_block(definition, block):
			return false
		if str(locomotion.get("type", "walking")) == "stationary":
			return bool(get_block(cell.x, cell.y + 1).get("solid", false))
		return true
	if str(block.get("name", "")) != medium:
		return false
	var mode := str(locomotion.get("aquatic_mode", "free"))
	if mode == "surface":
		return str(get_block(cell.x, cell.y - 1).get("name", "")) != medium
	if mode == "bottom":
		return get_block(cell.x, cell.y + 1).get("solid", false)
	return true


func _creature_has_exit(pos: Vector2, definition: Dictionary) -> bool:
	var locomotion_type := str((definition.get("locomotion", {}) as Dictionary).get("type", "walking"))
	if locomotion_type != "flying":
		return true
	for offset: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		if _creature_position_matches(pos + offset * 0.72, definition):
			return true
	return false


func _nearest_safe_creature_position(origin: Vector2, definition: Dictionary, radius: int) -> Variant:
	if _creature_position_matches(origin, definition) and _creature_has_exit(origin, definition):
		return origin
	var center := Vector2i(floori(origin.x), floori(origin.y))
	for distance in range(1, radius + 1):
		for y in range(center.y - distance, center.y + distance + 1):
			for x in range(center.x - distance, center.x + distance + 1):
				if absi(x - center.x) != distance and absi(y - center.y) != distance:
					continue
				var candidate := Vector2(x + 0.5, y + 0.5)
				if _creature_position_matches(candidate, definition) and _creature_has_exit(candidate, definition):
					return candidate
	return null


func _find_ground_spawn(x: int, center_y: int, light_preference: String = "neutral") -> Vector2i:
	for y in range(center_y - 12, center_y + 20):
		if get_block(x, y).get("id", 0) == 0 and get_block(x, y + 1).get("solid", false) and _light_preference_matches(Vector2(x + 0.5, y + 0.5), light_preference):
			return Vector2i(x, y)
	return Vector2i(0, COORD_LIMIT)


func _light_preference_matches(pos: Vector2, preference: String) -> bool:
	if preference == "neutral":
		return true
	var light_level := _creature_light_level_at(Vector2i(floori(pos.x), floori(pos.y)))
	return light_level < 0.5 if preference == "dark" else light_level >= 0.5


func _creature_light_level_at(pos: Vector2i) -> float:
	if _open_to_sky(pos.x, pos.y, -16):
		return world_daylight_factor()
	var level := 0.38 if _world_supports_resonant_deep() and pos.y >= RESONANT_DEEP_TOP_Y and pos.y <= RESONANT_DEEP_BOTTOM_Y else 0.0
	for y in range(pos.y - 5, pos.y + 6):
		for x in range(pos.x - 5, pos.x + 6):
			var emission := block_light_emission(get_block(x, y))
			if emission <= 0.0:
				continue
			var distance := absi(x - pos.x) + absi(y - pos.y)
			level = maxf(level, emission - float(distance) * EMISSIVE_FALLOFF)
	return clampf(level, 0.0, 1.0)


func _creature_light_desired(creature: Dictionary, definition: Dictionary) -> Vector2:
	var habitat: Dictionary = definition.get("habitat", {})
	if str((definition.get("locomotion", {}) as Dictionary).get("type", "walking")) == "stationary":
		return Vector2.ZERO
	var preference := str(habitat.get("light_preference", "neutral"))
	if preference == "neutral":
		return Vector2.ZERO
	var current := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	if _light_preference_matches(current, preference):
		return Vector2.ZERO
	var locomotion: Dictionary = definition.get("locomotion", {})
	var free_movement := str(locomotion.get("type", "walking")) in ["flying", "swimming"]
	var directions: Array[Vector2] = [Vector2.LEFT, Vector2.RIGHT]
	if free_movement:
		directions.append(Vector2.UP)
		directions.append(Vector2.DOWN)
	for distance in range(1, 5):
		for direction: Vector2 in directions:
			var candidate := current + direction * float(distance)
			if _creature_position_matches(candidate, definition) and _light_preference_matches(candidate, preference):
				return direction
	return Vector2.ZERO


func _spawn_position_for(definition: Dictionary) -> Vector2i:
	var player_tile := Vector2i(floori((float(player["x"]) + float(player["w"]) * 0.5) / BlockDefs.TILE), floori((float(player["y"]) + float(player["h"]) * 0.5) / BlockDefs.TILE))
	var locomotion: Dictionary = definition.get("locomotion", {})
	var medium := str(locomotion.get("medium", "air"))
	var habitat: Dictionary = definition.get("habitat", {})
	var light_preference := str(habitat.get("light_preference", "neutral"))
	var spawning: Dictionary = definition.get("spawning", {}) if definition.get("spawning", {}) is Dictionary else {}
	# Read the old camera-named field so already-discovered catalog creatures remain compatible.
	var minimum_distance := clampi(int(spawning.get("minimum_player_distance_blocks", spawning.get("minimum_camera_distance_blocks", 12))), 8, CREATURE_MAX_SPAWN_DISTANCE)
	for attempt in 32:
		var side := -1 if randf() < 0.5 else 1
		var distance := randi_range(minimum_distance, CREATURE_MAX_SPAWN_DISTANCE)
		var x := player_tile.x + side * distance
		var candidate := Vector2i(x, player_tile.y + randi_range(-8, 10))
		if medium == "air" and str(locomotion.get("type", "walking")) in ["walking", "crawling", "stationary"]:
			candidate = _find_ground_spawn(x, player_tile.y, light_preference)
		elif medium != "air":
			var medium_id := int(BlockDefs.BLOCKS[medium].id)
			var positions := _positions_for_block_id_in_chunk_radius(medium_id, CHUNK_GENERATION_RADIUS)
			if positions.is_empty():
				continue
			candidate = positions[randi() % positions.size()]
		if candidate.y == COORD_LIMIT or not _creature_position_matches(Vector2(candidate) + Vector2.ONE * 0.5, definition) or not _creature_has_exit(Vector2(candidate) + Vector2.ONE * 0.5, definition):
			continue
		if not _light_preference_matches(Vector2(candidate) + Vector2.ONE * 0.5, light_preference):
			continue
		if "cave_only" in (definition.get("tags", []) as Array) and _open_to_sky(candidate.x, candidate.y, -16):
			continue
		if "night_surface" in (definition.get("tags", []) as Array) and not world_is_night() and _open_to_sky(candidate.x, candidate.y, -16):
			continue
		if _creature_light_level_at(candidate) > float(habitat.get("maximum_light", 1.0)):
			continue
		var player_distance := Vector2(candidate - player_tile).length()
		if player_distance < float(minimum_distance) or player_distance > float(CREATURE_MAX_SPAWN_DISTANCE):
			continue
		return candidate
	return Vector2i(0, COORD_LIMIT)


func _player_creature_position() -> Vector2:
	return Vector2(
		(float(player["x"]) + float(player["w"]) * 0.5) / BlockDefs.TILE,
		(float(player["y"]) + float(player["h"]) * 0.5) / BlockDefs.TILE
	)


func _creature_distance_to_player(creature: Dictionary) -> float:
	return _player_creature_position().distance_to(Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0))))


func _nearest_player_target(position: Vector2) -> Dictionary:
	var nearest := {
		"player_id": "",
		"position": _player_creature_position(),
	}
	var nearest_distance := position.distance_to(nearest.position)
	for raw_player_id in multiplayer_player_targets:
		if not multiplayer_player_targets[raw_player_id] is Dictionary:
			continue
		var candidate := multiplayer_player_targets[raw_player_id] as Dictionary
		if int(candidate.get("health", 3)) <= 0:
			continue
		var candidate_position := Vector2(
			(float(candidate.get("x", 0.0)) + float(candidate.get("w", 20.0)) * 0.5) / BlockDefs.TILE,
			(float(candidate.get("y", 0.0)) + float(candidate.get("h", 28.0)) * 0.5) / BlockDefs.TILE
		)
		var distance := position.distance_to(candidate_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = {"player_id": str(raw_player_id), "position": candidate_position}
	return nearest


func _creature_distance_to_nearest_player(creature: Dictionary) -> float:
	var position := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var target := _nearest_player_target(position)
	return position.distance_to(target.position)


func _creature_count_for(block_name: String, local_only: bool = false) -> int:
	var count := 0
	for creature: Dictionary in creatures.values():
		if (
			str(creature.get("block_name", "")) == block_name
			and (not local_only or _creature_distance_to_player(creature) <= CREATURE_LOCAL_CAP_RADIUS)
		):
			count += 1
	return count


func _creature_spawn_group(definition: Dictionary) -> String:
	var behavior: Dictionary = definition.get("behavior", {}) if definition.get("behavior", {}) is Dictionary else {}
	return "hostile" if str(behavior.get("temperament", "passive")) == "aggressive" else "peaceful"


func _natural_creature_count(group: String = "all") -> int:
	var count := 0
	for creature: Dictionary in creatures.values():
		if not bool(creature.get("natural", false)):
			continue
		if group != "all":
			var definition := _creature_definition(str(creature.get("block_name", "")))
			if _creature_spawn_group(definition) != group:
				continue
		count += 1
	return count


func _local_natural_creature_count(group: String = "all") -> int:
	var count := 0
	for creature: Dictionary in creatures.values():
		if not bool(creature.get("natural", false)) or _creature_distance_to_player(creature) > CREATURE_LOCAL_CAP_RADIUS:
			continue
		if group != "all":
			var definition := _creature_definition(str(creature.get("block_name", "")))
			if _creature_spawn_group(definition) != group:
				continue
		count += 1
	return count


func _local_shagot_count() -> int:
	var count := 0
	for creature: Dictionary in creatures.values():
		if bool(creature.get("dead", false)) or _creature_distance_to_player(creature) > CREATURE_LOCAL_CAP_RADIUS:
			continue
		var definition := _creature_definition(str(creature.get("block_name", "")))
		if "shagot" in (definition.get("tags", []) as Array):
			count += 1
	return count


func _prune_excess_local_shagots() -> void:
	var local_shagots: Array[Dictionary] = []
	var protected_count := 0
	for creature_id: String in creatures.keys():
		var creature: Dictionary = creatures[creature_id]
		if bool(creature.get("dead", false)) or _creature_distance_to_player(creature) > CREATURE_LOCAL_CAP_RADIUS:
			continue
		var definition := _creature_definition(str(creature.get("block_name", "")))
		if "shagot" not in (definition.get("tags", []) as Array):
			continue
		if not bool(creature.get("natural", false)):
			protected_count += 1
			continue
		local_shagots.append({
			"id": creature_id,
			"distance": _creature_distance_to_player(creature),
			"following": str(creature.get("shagot_activity", "")) == "follow",
		})
	var natural_limit := maxi(0, SHAGOT_LOCAL_POPULATION_CAP - protected_count)
	if local_shagots.size() <= natural_limit:
		return
	# Remove surplus followers first, then the Shagots furthest from the player.
	# Player-placed creatures are never included in this cleanup.
	local_shagots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a["following"]) != bool(b["following"]):
			return bool(a["following"])
		return float(a["distance"]) > float(b["distance"])
	)
	for index in local_shagots.size() - natural_limit:
		creatures.erase(str(local_shagots[index]["id"]))


func _natural_spawn_chance(definition: Dictionary) -> float:
	var spawning: Dictionary = definition.get("spawning", {}) if definition.get("spawning", {}) is Dictionary else {}
	var behavior: Dictionary = definition.get("behavior", {}) if definition.get("behavior", {}) is Dictionary else {}
	var activity_period := str(spawning.get("activity_period", "all_day"))
	var aggressive := str(behavior.get("temperament", "passive")) == "aggressive"
	if aggressive and "shagot" not in (definition.get("tags", []) as Array):
		activity_period = "night"
	if activity_period not in ["day", "night", "all_day"]:
		activity_period = "all_day"
	var preferred_now := (
		(activity_period == "night" and world_is_night())
		or (activity_period == "day" and not world_is_night())
	)
	var activity_multiplier := CREATURE_PREFERRED_ACTIVITY_SPAWN_MULTIPLIER if preferred_now else 1.0
	var category_multiplier := CREATURE_HOSTILE_SPAWN_MULTIPLIER if aggressive else 1.0
	var chance := float(spawning.get("rarity", 0.04)) * CREATURE_SPAWN_CHANCE_MULTIPLIER * activity_multiplier * category_multiplier
	return clampf(chance, 0.0, CREATURE_MAX_HOSTILE_SPAWN_CHANCE if aggressive else 1.0)


func _try_spawn_creatures(group: String = "all") -> void:
	if creatures.size() >= CREATURE_MAX_WORLD or _local_natural_creature_count() >= CREATURE_NATURAL_TARGET:
		return
	if group == "hostile" and _local_natural_creature_count("hostile") >= CREATURE_NATURAL_HOSTILE_CAP:
		return
	if group == "peaceful" and _local_natural_creature_count("peaceful") >= CREATURE_NATURAL_PEACEFUL_CAP:
		return
	var seen_names: Dictionary = {}
	var candidates: Array[String] = []
	for block_name: String in BlockDefs.BLOCKS.keys():
		var block: Dictionary = BlockDefs.BLOCKS[block_name]
		var definition := _creature_definition(block_name)
		if (
			block.get("creature_item", false)
			and not seen_names.has(block_name)
			and (group == "all" or _creature_spawn_group(definition) == group)
		):
			seen_names[block_name] = true
			candidates.append(block_name)
	candidates.shuffle()
	var viable: Array[Dictionary] = []
	for block_name in candidates:
		var definition := _creature_definition(block_name)
		var content_id := BlockDefs.content_id_for_name(block_name)
		# Fireflies have a dedicated ambience pass with its own strict local cap.
		# Letting the generic peaceful pass spawn them as well made the cap depend
		# on random ordering and occasionally overcrowded the same night habitat.
		if content_id == "core.creature.firefly":
			continue
		if "shagot" in (definition.get("tags", []) as Array) and _local_shagot_count() >= SHAGOT_LOCAL_POPULATION_CAP:
			continue
		var spawning: Dictionary = definition.get("spawning", {})
		if _creature_count_for(block_name, true) >= int(spawning.get("maximum_nearby", 3)):
			continue
		var pos := _spawn_position_for(definition)
		if pos.y == COORD_LIMIT:
			continue
		var biome_id := _ecology_biome_at(pos)
		var biome := _biome_definition(biome_id)
		var ecology: Dictionary = biome.get("ecology", {}) if biome.get("ecology", {}) is Dictionary else {}
		var allowed_creatures: Array = ecology.get("creature_content_ids", []) if ecology.get("creature_content_ids", []) is Array else []
		if not _generated_living_content_allowed(content_id, definition, biome_id, allowed_creatures):
			continue
		viable.append({"block_name": block_name, "definition": definition, "position": pos})
	viable.shuffle()
	for option: Dictionary in viable:
		if randf() > _natural_spawn_chance(option["definition"]):
			continue
		if not spawn_creature(str(option["block_name"]), Vector2(option["position"]) + Vector2.ONE * 0.5, true).is_empty():
			return


func _try_spawn_ambient_firefly() -> void:
	if creatures.size() >= CREATURE_MAX_WORLD:
		return
	var block_name := str(BlockDefs.block_name_by_content_id.get("core.creature.firefly", ""))
	if block_name.is_empty() or _creature_count_for(block_name, true) >= FIREFLY_LOCAL_TARGET:
		return
	var definition := _creature_definition(block_name)
	var pos := _spawn_position_for(definition)
	if pos.y == COORD_LIMIT:
		return
	var biome_id := _ecology_biome_at(pos)
	var biome := _biome_definition(biome_id)
	var ecology: Dictionary = biome.get("ecology", {}) if biome.get("ecology", {}) is Dictionary else {}
	var allowed_creatures: Array = ecology.get("creature_content_ids", []) if ecology.get("creature_content_ids", []) is Array else []
	if not _generated_living_content_allowed("core.creature.firefly", definition, biome_id, allowed_creatures):
		return
	var outdoors := _open_to_sky(pos.x, pos.y, -16)
	if outdoors and not world_is_night():
		return
	var chance := FIREFLY_NIGHT_SPAWN_CHANCE if outdoors else FIREFLY_CAVE_SPAWN_CHANCE
	if randf() > chance:
		return
	spawn_creature(block_name, Vector2(pos) + Vector2.ONE * 0.5, true)


func _remove_distant_natural_hostiles() -> void:
	for creature_id: String in creatures.keys():
		var creature: Dictionary = creatures[creature_id]
		if not bool(creature.get("natural", false)) or _creature_distance_to_player(creature) <= CREATURE_DORMANT_DISTANCE:
			continue
		var definition := _creature_definition(str(creature.get("block_name", "")))
		if _creature_spawn_group(definition) == "hostile":
			creatures.erase(creature_id)


func _prune_distant_natural_creatures() -> void:
	var excess := _natural_creature_count() - CREATURE_MAX_NATURAL_STORED
	if excess <= 0:
		return
	var distant: Array[Dictionary] = []
	for creature_id: String in creatures.keys():
		var creature: Dictionary = creatures[creature_id]
		if bool(creature.get("natural", false)) and _creature_distance_to_player(creature) > CREATURE_DORMANT_DISTANCE:
			distant.append({"id": creature_id, "distance": _creature_distance_to_player(creature)})
	distant.sort_custom(func(a: Dictionary, b: Dictionary): return float(a["distance"]) > float(b["distance"]))
	for entry: Dictionary in distant:
		if excess <= 0:
			break
		creatures.erase(str(entry["id"]))
		excess -= 1


func _ecology_biome_at(pos: Vector2i) -> String:
	if _world_supports_resonant_deep() and pos.y >= RESONANT_DEEP_TOP_Y:
		return _resonant_biome_for_chunk(floori(float(pos.x) / float(CHUNK_WIDTH)))
	if world_mode in [WORLD_MODE_FLOATING_ISLANDS, WORLD_MODE_DUEL]:
		var floating_biome := _floating_island_biome_at(pos)
		if not floating_biome.is_empty():
			return floating_biome
	if pos.y > _terrain_surface_y(pos.x) + 4 and not _open_to_sky(pos.x, pos.y, -16):
		for offset in [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			if str(get_block(pos.x + offset.x, pos.y + offset.y).get("name", "")) == "lava":
				return "volcanic"
		return "cavern"
	return _biome_at(pos.x)


func _favorite_plant_position(creature: Dictionary, definition: Dictionary) -> Variant:
	var habitat: Dictionary = definition.get("habitat", {})
	var traits: Dictionary = creature.get("traits", {}) if creature.get("traits", {}) is Dictionary else {}
	var favorite: Array = traits.get("favorite_plant_tags", habitat.get("favorite_plant_tags", []))
	if favorite.is_empty():
		return null
	var origin := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var radius := float(habitat.get("attraction_radius_blocks", 6))
	var nearest: Variant = null
	var nearest_dist := radius + 1.0
	for anchor: Vector2i in plant_growth.keys():
		var plant_data: Dictionary = plant_growth[anchor]
		var plant_definition := _plant_definition(str(plant_data.get("block_name", "")))
		var growth: Dictionary = plant_definition.get("growth", {}) if plant_definition.get("growth", {}) is Dictionary else {}
		var plant_form := str(growth.get("form", ""))
		var plant_tags: Array = plant_definition.get("tags", []) if plant_definition.get("tags", []) is Array else []
		# Structure decor is intentionally non-blocking and should not become a
		# point of interest that makes creatures stop in doorways or narrow rooms.
		if plant_form in ["decorative", "potted"] or _arrays_intersect(plant_tags, ["decorative", "potted"]):
			continue
		if not _arrays_intersect(plant_definition.get("tags", []), favorite):
			continue
		var dist := origin.distance_to(Vector2(anchor) + Vector2.ONE * 0.5)
		if dist < nearest_dist:
			nearest = Vector2(anchor) + Vector2.ONE * 0.5
			nearest_dist = dist
	return nearest


func _favorite_plant_interest_target(creature: Dictionary, definition: Dictionary) -> Variant:
	if int(creature.get("plant_interest_cooldown", 0)) > 0:
		return null
	var plant_position: Variant = _favorite_plant_position(creature, definition)
	if not plant_position is Vector2:
		return null
	var origin := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var plant_center := plant_position as Vector2
	var locomotion: Dictionary = definition.get("locomotion", {}) if definition.get("locomotion", {}) is Dictionary else {}
	var locomotion_type := str(locomotion.get("type", "walking"))
	if locomotion_type == "stationary":
		return null
	var candidates: Array[Vector2] = []
	if locomotion_type in ["walking", "crawling"]:
		# Flowers are non-blocking decor, so targeting their center makes a ground
		# creature overlap the sprite and oscillate around it forever. Visit a free
		# point beside the plant instead.
		candidates = [plant_center + Vector2(-0.9, 0.0), plant_center + Vector2(0.9, 0.0)]
	else:
		candidates = [
			plant_center + Vector2(0.0, -0.75),
			plant_center + Vector2(-0.75, 0.0),
			plant_center + Vector2(0.75, 0.0),
		]
	candidates.sort_custom(func(a: Vector2, b: Vector2): return origin.distance_squared_to(a) < origin.distance_squared_to(b))
	for candidate: Vector2 in candidates:
		if _creature_position_matches(candidate, definition):
			return candidate
	return null


func _reset_creature_point_interest_progress(creature: Dictionary) -> void:
	creature["point_interest_stuck_ticks"] = 0
	creature.erase("point_interest_checkpoint_x")
	creature.erase("point_interest_checkpoint_y")


func _creature_point_interest_is_stuck(creature: Dictionary, position: Vector2) -> bool:
	if not creature.has("point_interest_checkpoint_x"):
		creature["point_interest_checkpoint_x"] = position.x
		creature["point_interest_checkpoint_y"] = position.y
		creature["point_interest_stuck_ticks"] = 0
		return false
	var stuck_ticks := int(creature.get("point_interest_stuck_ticks", 0)) + 1
	creature["point_interest_stuck_ticks"] = stuck_ticks
	if stuck_ticks < CREATURE_POI_STUCK_TICKS:
		return false
	var checkpoint := Vector2(
		float(creature.get("point_interest_checkpoint_x", position.x)),
		float(creature.get("point_interest_checkpoint_y", position.y))
	)
	if position.distance_to(checkpoint) < CREATURE_POI_STUCK_RADIUS:
		return true
	creature["point_interest_checkpoint_x"] = position.x
	creature["point_interest_checkpoint_y"] = position.y
	creature["point_interest_stuck_ticks"] = 0
	return false


func _ground_creature_position_matches(pos: Vector2, definition: Dictionary) -> bool:
	var locomotion: Dictionary = definition.get("locomotion", {})
	var locomotion_type := str(locomotion.get("type", "walking"))
	if str(locomotion.get("medium", "air")) != "air" or locomotion_type not in ["walking", "crawling"]:
		return _creature_position_matches(pos, definition)
	var size := clampf(float((definition.get("stats", {}) as Dictionary).get("size", 0.8)), 0.45, 1.4)
	var half_width := size * 0.42
	var half_height := size * 0.28
	for y in range(floori(pos.y - half_height), floori(pos.y + half_height) + 1):
		for x in range(floori(pos.x - half_width), floori(pos.x + half_width) + 1):
			var occupied := get_block(x, y)
			if bool(occupied.get("solid", false)) and not _creature_can_pass_through_block(definition, occupied):
				return false
	return true


func _move_ground_creature(creature: Dictionary, definition: Dictionary, desired_x: float) -> void:
	var traits: Dictionary = creature.get("traits", {}) if creature.get("traits", {}) is Dictionary else {}
	var speed := float((definition.get("locomotion", {}) as Dictionary).get("speed", 0.7)) * float(traits.get("speed_multiplier", 1.0)) / 60.0
	var wants_to_move := absf(desired_x) > 0.05
	var direction := signf(desired_x) if wants_to_move else 0.0
	var current := Vector2(float(creature["x"]), float(creature["y"]))
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	var idle_jump_chance := SHAGOT_IDLE_JUMP_CHANCE if "shagot" in tags else 0.00025
	# A zero steering vector means hold position. Previously it reused `facing` as
	# movement input, so a worker standing at its task walked past the target,
	# turned around and oscillated every few frames.
	if not wants_to_move:
		if _creature_can_jump(definition) and _creature_is_grounded(creature, definition) and randf() < idle_jump_chance:
			var idle_locomotion: Dictionary = definition.get("locomotion", {})
			creature["vy"] = -CREATURE_JUMP_SPEED * clampf(float(idle_locomotion.get("jump_power", 0.8)), 0.2, 1.5)
		return
	var next := current + Vector2(direction * speed, 0)
	if "deep" in tags and current.y >= RESONANT_DEEP_TOP_Y and _ecology_biome_at(Vector2i(floori(next.x), floori(next.y))) != _ecology_biome_at(Vector2i(floori(current.x), floori(current.y))):
		creature["facing"] = -1 if direction >= 0.0 else 1
		return
	# Ground creatures avoid voluntarily stepping off dry land even though their
	# physical collision permits sinking and moving after water is placed on them.
	if _creature_is_grounded(creature, definition) and _creature_has_fluid_support(next, definition, direction):
		creature["facing"] = -1 if direction >= 0.0 else 1
		return
	if _ground_creature_position_matches(next, definition):
		creature["x"] = next.x
		creature["facing"] = 1 if direction >= 0 else -1
	elif _creature_can_jump(definition) and _creature_is_grounded(creature, definition):
		var locomotion: Dictionary = definition.get("locomotion", {})
		creature["vy"] = -CREATURE_JUMP_SPEED * clampf(float(locomotion.get("jump_power", 0.8)), 0.2, 1.5)
		creature["facing"] = 1 if direction >= 0 else -1
	elif _creature_can_jump(definition) and float(creature.get("vy", 0.0)) < 0.0:
		creature["facing"] = 1 if direction >= 0 else -1
	else:
		creature["facing"] = -int(creature.get("facing", 1))


func _creature_has_fluid_support(pos: Vector2, definition: Dictionary, direction: float) -> bool:
	var locomotion: Dictionary = definition.get("locomotion", {})
	if str(locomotion.get("medium", "air")) != "air" or str(locomotion.get("type", "walking")) not in ["walking", "crawling"]:
		return false
	var size := clampf(float((definition.get("stats", {}) as Dictionary).get("size", 0.8)), 0.45, 1.4)
	var half_width := size * 0.42
	var half_height := size * 0.28
	var leading_x := floori(pos.x + signf(direction) * half_width)
	var support_y := floori(pos.y + half_height + 0.04)
	return bool(get_block(leading_x, support_y).get("fluid", false))


func _creature_uses_gravity(definition: Dictionary) -> bool:
	var locomotion: Dictionary = definition.get("locomotion", {})
	var locomotion_type := str(locomotion.get("type", "walking"))
	return str(locomotion.get("medium", "air")) == "air" and bool(locomotion.get("gravity", locomotion_type in ["walking", "crawling"]))


func _creature_can_jump(definition: Dictionary) -> bool:
	var locomotion: Dictionary = definition.get("locomotion", {})
	return _creature_uses_gravity(definition) and bool(locomotion.get("can_jump", str(locomotion.get("type", "walking")) == "walking")) and float(locomotion.get("jump_power", 0.8)) > 0.0


func _creature_is_grounded(creature: Dictionary, definition: Dictionary) -> bool:
	var current := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	return not _ground_creature_position_matches(current + Vector2(0.0, 0.04), definition)


func _apply_creature_gravity(creature: Dictionary, definition: Dictionary) -> void:
	if not _creature_uses_gravity(definition):
		creature["vy"] = 0.0
		return
	var velocity_y := minf(CREATURE_MAX_FALL_SPEED, float(creature.get("vy", 0.0)) + CREATURE_GRAVITY / 60.0)
	var current := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var next := current + Vector2(0.0, velocity_y / 60.0)
	if _ground_creature_position_matches(next, definition):
		creature["y"] = next.y
		creature["vy"] = velocity_y
	else:
		creature["vy"] = 0.0


func _move_free_creature(creature: Dictionary, definition: Dictionary, desired: Vector2) -> void:
	var locomotion: Dictionary = definition.get("locomotion", {})
	var traits: Dictionary = creature.get("traits", {}) if creature.get("traits", {}) is Dictionary else {}
	var speed := float(locomotion.get("speed", 0.8)) * float(traits.get("speed_multiplier", 1.0)) / 60.0
	if desired.length() < 0.05:
		desired = Vector2(float(creature.get("facing", 1)), sin(float(creature_tick + str(creature.get("id", "")).hash()) * 0.015))
	var current := Vector2(float(creature["x"]), float(creature["y"]))
	var next := current + desired.normalized() * speed
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	if "deep" in tags and current.y >= RESONANT_DEEP_TOP_Y and _ecology_biome_at(Vector2i(floori(next.x), floori(next.y))) != _ecology_biome_at(Vector2i(floori(current.x), floori(current.y))):
		creature["facing"] = -int(creature.get("facing", 1))
		return
	if _creature_position_matches(next, definition):
		creature["x"] = next.x
		creature["y"] = next.y
		if absf(desired.x) > 0.05:
			creature["facing"] = 1 if desired.x >= 0 else -1
	else:
		var avoidance := _free_creature_avoidance_direction(Vector2(float(creature["x"]), float(creature["y"])), definition, desired)
		if avoidance.length() > 0.05:
			creature["avoidance_x"] = avoidance.x
			creature["avoidance_y"] = avoidance.y
			creature["avoidance_ticks"] = randi_range(45, 90)
			var escape_next := Vector2(float(creature["x"]), float(creature["y"])) + avoidance * speed
			if _creature_position_matches(escape_next, definition):
				creature["x"] = escape_next.x
				creature["y"] = escape_next.y
			if absf(avoidance.x) > 0.05:
				creature["facing"] = 1 if avoidance.x >= 0.0 else -1
		else:
			creature["facing"] = -int(creature.get("facing", 1))


func _free_creature_avoidance_direction(current: Vector2, definition: Dictionary, blocked: Vector2) -> Vector2:
	var direction := blocked.normalized() if blocked.length() > 0.05 else Vector2.RIGHT
	var candidates: Array[Vector2] = [
		Vector2(-direction.x, direction.y).normalized(),
		Vector2(-direction.x, -direction.y).normalized(),
		Vector2(0.0, -1.0),
		Vector2(0.0, 1.0),
		-direction,
	]
	for candidate: Vector2 in candidates:
		if candidate.length() <= 0.05:
			continue
		if _creature_position_matches(current + candidate * 0.45, definition):
			return candidate
	return Vector2.ZERO


func _creature_wander_desired(creature: Dictionary, definition: Dictionary) -> Vector2:
	var locomotion: Dictionary = definition.get("locomotion", {})
	var locomotion_type := str(locomotion.get("type", "walking"))
	var aquatic_mode := str(locomotion.get("aquatic_mode", "none"))
	if locomotion_type != "flying" and not (locomotion_type == "swimming" and aquatic_mode == "free"):
		return Vector2(float(creature.get("facing", 1)), 0.0)
	var ticks := int(creature.get("vertical_wander_ticks", 0)) - 1
	creature["vertical_wander_ticks"] = ticks
	if ticks <= 0:
		var roll := randf()
		var vertical_step := -1.0 if roll < 0.35 else (1.0 if roll < 0.70 else 0.0)
		creature["vertical_wander_target_y"] = float(creature.get("y", 0.0)) + vertical_step
		creature["vertical_wander_ticks"] = randi_range(120, 300)
	var delta_y := float(creature.get("vertical_wander_target_y", creature.get("y", 0.0))) - float(creature.get("y", 0.0))
	if absf(delta_y) < 0.06:
		delta_y = 0.0
	return Vector2(float(creature.get("facing", 1)) * 0.72, clampf(delta_y, -1.0, 1.0) * 0.82)


func _predation_profile(definition: Dictionary) -> Dictionary:
	var configured: Dictionary = definition.get("predation", {}) if definition.get("predation", {}) is Dictionary else {}
	if not configured.is_empty():
		return configured
	var behavior: Dictionary = definition.get("behavior", {}) if definition.get("behavior", {}) is Dictionary else {}
	if str(behavior.get("temperament", "passive")) != "aggressive":
		return {"enabled": false}
	return {"enabled": true, "prey_tags": ["passive", "fearful"], "detection_radius": 8, "hunt_cooldown_seconds": [60, 180], "prefers_player": false}


func _predator_can_hunt(predator_definition: Dictionary, prey_definition: Dictionary) -> bool:
	var prey_behavior: Dictionary = prey_definition.get("behavior", {}) if prey_definition.get("behavior", {}) is Dictionary else {}
	var prey_temperament := str(prey_behavior.get("temperament", "passive"))
	if prey_temperament == "aggressive":
		return false
	var predator_locomotion: Dictionary = predator_definition.get("locomotion", {}) if predator_definition.get("locomotion", {}) is Dictionary else {}
	var prey_locomotion: Dictionary = prey_definition.get("locomotion", {}) if prey_definition.get("locomotion", {}) is Dictionary else {}
	if str(predator_locomotion.get("medium", "air")) != str(prey_locomotion.get("medium", "air")):
		return false
	var predator_type := str(predator_locomotion.get("type", "walking"))
	var prey_type := str(prey_locomotion.get("type", "walking"))
	if predator_type in ["walking", "crawling", "stationary"] and prey_type == "flying":
		return false
	var profile := _predation_profile(predator_definition)
	var prey_tags: Array = profile.get("prey_tags", []) if profile.get("prey_tags", []) is Array else []
	if prey_tags.is_empty():
		return true
	var definition_tags: Array = prey_definition.get("tags", []) if prey_definition.get("tags", []) is Array else []
	return prey_temperament in prey_tags or _arrays_intersect(definition_tags, prey_tags)


func _predation_target_id(predator: Dictionary, predator_definition: Dictionary) -> String:
	var profile := _predation_profile(predator_definition)
	if not bool(profile.get("enabled", false)) or int(predator.get("hunt_cooldown", 0)) > 0:
		return ""
	var predator_id := str(predator.get("id", ""))
	var predator_position := Vector2(float(predator.get("x", 0.0)), float(predator.get("y", 0.0)))
	var detection_radius := clampf(float(profile.get("detection_radius", 8)), 2.0, 16.0)
	var current_target_id := str(predator.get("hunt_target_id", ""))
	if creatures.has(current_target_id):
		var current_target: Dictionary = creatures[current_target_id]
		var current_definition := _creature_definition(str(current_target.get("block_name", "")))
		var current_distance := predator_position.distance_to(Vector2(float(current_target.get("x", 0.0)), float(current_target.get("y", 0.0))))
		if not bool(current_target.get("dead", false)) and current_distance <= detection_radius * 1.5 and _predator_can_hunt(predator_definition, current_definition):
			return current_target_id
	predator["hunt_target_id"] = ""
	var nearest_id := ""
	var nearest_distance := detection_radius + 1.0
	for candidate_id: String in creatures.keys():
		if candidate_id == predator_id:
			continue
		var candidate: Dictionary = creatures[candidate_id]
		if bool(candidate.get("dead", false)):
			continue
		var candidate_definition := _creature_definition(str(candidate.get("block_name", "")))
		if candidate_definition.is_empty() or not _predator_can_hunt(predator_definition, candidate_definition):
			continue
		var distance := predator_position.distance_to(Vector2(float(candidate.get("x", 0.0)), float(candidate.get("y", 0.0))))
		if distance <= detection_radius and distance < nearest_distance:
			nearest_id = candidate_id
			nearest_distance = distance
	predator["hunt_target_id"] = nearest_id
	return nearest_id


func _predator_attack(predator: Dictionary, predator_definition: Dictionary, prey_id: String) -> void:
	if int(predator.get("attack_cooldown", 0)) > 0 or not creatures.has(prey_id):
		return
	var prey: Dictionary = creatures[prey_id]
	if bool(prey.get("dead", false)):
		return
	var damage := maxi(1, int((predator_definition.get("stats", {}) as Dictionary).get("damage", 1)))
	prey["health"] = int(prey.get("health", 1)) - damage
	prey["flee_ticks"] = maxi(int(prey.get("flee_ticks", 0)), CREATURE_PREY_FLEE_TICKS)
	prey["flee_source_id"] = str(predator.get("id", ""))
	predator["attack_cooldown"] = CREATURE_PREDATOR_ATTACK_COOLDOWN
	if int(prey["health"]) > 0:
		return
	prey["dead"] = true
	predator["hunt_target_id"] = ""
	var profile := _predation_profile(predator_definition)
	var cooldown_range: Array = profile.get("hunt_cooldown_seconds", [60, 180]) if profile.get("hunt_cooldown_seconds", [60, 180]) is Array else [60, 180]
	var minimum_seconds := clampi(int(cooldown_range[0]) if cooldown_range.size() > 0 else 60, 30, 600)
	var maximum_seconds := clampi(int(cooldown_range[1]) if cooldown_range.size() > 1 else minimum_seconds, minimum_seconds, 900)
	predator["hunt_cooldown"] = randi_range(minimum_seconds, maximum_seconds) * 60


func _damage_player_from_creature(creature: Dictionary, definition: Dictionary, target_player_id: String, target_position: Vector2) -> void:
	if int(creature.get("attack_cooldown", 0)) > 0:
		return
	var damage := int((definition.get("stats", {}) as Dictionary).get("damage", 0))
	if damage <= 0:
		return
	var knockback_x := -3.5 if float(creature["x"]) > target_position.x else 3.5
	if not target_player_id.is_empty():
		remote_player_attacked_by_creature.emit(target_player_id, damage, knockback_x, -3.0)
		creature["attack_cooldown"] = 90
		return
	player["health"] = maxi(0, int(player.get("health", MAX_PLAYER_HEALTH)) - damage)
	player["vx"] = knockback_x
	player["vy"] = -3.0
	creature["attack_cooldown"] = 90
	Sfx.hurt()
	if int(player["health"]) <= 0:
		player_defeated.emit()


func _creature_touches_harmful_fluid(creature: Dictionary, definition: Dictionary) -> bool:
	var locomotion: Dictionary = definition.get("locomotion", {}) if definition.get("locomotion", {}) is Dictionary else {}
	var native_medium := str(locomotion.get("medium", "air"))
	var position := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var size := clampf(float((definition.get("stats", {}) as Dictionary).get("size", 0.8)), 0.45, 1.4)
	var half_width := size * 0.42
	var half_height := size * 0.28
	for y in range(floori(position.y - half_height), floori(position.y + half_height) + 1):
		for x in range(floori(position.x - half_width), floori(position.x + half_width) + 1):
			var fluid_name := str(get_block(x, y).get("name", ""))
			if (fluid_name == "lava" and native_medium != "lava") or (fluid_name == "water" and native_medium == "lava"):
				return true
	return false


func _creature_overlaps_solid(creature: Dictionary, definition: Dictionary) -> bool:
	var position := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var size := clampf(float((definition.get("stats", {}) as Dictionary).get("size", 0.8)), 0.45, 1.4)
	var half_width := size * 0.42
	var half_height := size * 0.28
	for y in range(floori(position.y - half_height), floori(position.y + half_height) + 1):
		for x in range(floori(position.x - half_width), floori(position.x + half_width) + 1):
			var occupied := get_block(x, y)
			# A block that this creature is explicitly allowed to traverse is not an
			# entombment condition. Without this exception, Shagots crossing trees or
			# their own partitions were rescued every tick and appeared frozen.
			if bool(occupied.get("solid", false)) and not _creature_can_pass_through_block(definition, occupied):
				return true
	return false


func _tick_creature(creature: Dictionary) -> void:
	if bool(creature.get("dead", false)):
		return
	var definition := _creature_definition(str(creature.get("block_name", "")))
	if definition.is_empty():
		return
	var definition_tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	var current_position := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	if "shagot" in definition_tags:
		var expected_floor_y := _resonant_floor_y(floori(current_position.x))
		# A removed floor used to let workers fall beyond the dormant radius. They
		# then kept reserving a settlement cell forever while no longer being ticked.
		if current_position.y > float(expected_floor_y) + 6.0:
			var recovered: Variant = _shagot_safe_ground_position(floori(current_position.x), definition)
			if recovered is Vector2:
				current_position = recovered as Vector2
				creature["x"] = current_position.x
				creature["y"] = current_position.y
				creature["vy"] = 0.0
				_clear_shagot_task(creature)
			else:
				creature["dead"] = true
				return
	# Check incompatible fluids before habitat rescue. Otherwise lava can teleport
	# ordinary creatures to safety, and water can do the same for lava natives.
	if _creature_touches_harmful_fluid(creature, definition):
		creature["health"] = 0
		creature["dead"] = true
		state_changed.emit()
		return
	var player_target := _nearest_player_target(current_position)
	var player_pos: Vector2 = player_target.position
	var target_player_id := str(player_target.player_id)
	if current_position.distance_to(player_pos) > CREATURE_DORMANT_DISTANCE:
		return
	var position_matches_habitat := _creature_position_matches(current_position, definition)
	var locomotion: Dictionary = definition.get("locomotion", {}) if definition.get("locomotion", {}) is Dictionary else {}
	var unsupported_stationary := (
		str(locomotion.get("type", "walking")) == "stationary"
		and str(locomotion.get("medium", "air")) == "air"
		and not position_matches_habitat
	)
	# Habitat mismatch alone is not entombment: water flowing through an air
	# creature (or draining around an aquatic one) must not teleport it. Rescue is
	# reserved for solid overlap and for flyers trapped in their proper medium.
	var needs_rescue := unsupported_stationary or _creature_overlaps_solid(creature, definition) or (position_matches_habitat and not _creature_has_exit(current_position, definition))
	if needs_rescue:
		var rescued: Variant = _nearest_safe_creature_position(current_position, definition, 8)
		if rescued != null:
			creature["x"] = (rescued as Vector2).x
			creature["y"] = (rescued as Vector2).y
		else:
			return
	creature["attack_cooldown"] = maxi(0, int(creature.get("attack_cooldown", 0)) - 1)
	creature["provoked_ticks"] = maxi(0, int(creature.get("provoked_ticks", 0)) - 1)
	var previous_flee_ticks := int(creature.get("flee_ticks", 0))
	creature["flee_ticks"] = maxi(0, previous_flee_ticks - 1)
	if previous_flee_ticks > 0 and int(creature["flee_ticks"]) == 0:
		creature["fear_cooldown"] = randi_range(CREATURE_FEAR_COOLDOWN_MIN_TICKS, CREATURE_FEAR_COOLDOWN_MAX_TICKS)
	creature["breeding_cooldown"] = maxi(0, int(creature.get("breeding_cooldown", 0)) - 1)
	creature["plant_interest_cooldown"] = maxi(0, int(creature.get("plant_interest_cooldown", 0)) - 1)
	creature["fear_cooldown"] = maxi(0, int(creature.get("fear_cooldown", 0)) - 1)
	creature["hunt_cooldown"] = maxi(0, int(creature.get("hunt_cooldown", 0)) - 1)
	creature["work_cooldown"] = maxi(0, int(creature.get("work_cooldown", 0)) - 1)
	creature["work_action_ticks"] = maxi(0, int(creature.get("work_action_ticks", 0)) - 1)
	creature["voice_cooldown"] = maxi(0, int(creature.get("voice_cooldown", 0)) - 1)
	if int(creature.get("work_action_ticks", 0)) == 0:
		creature["work_action"] = ""
	creature["gift_cooldown"] = maxi(0, int(creature.get("gift_cooldown", 0)) - 1)
	var position := Vector2(float(creature["x"]), float(creature["y"]))
	var to_player := player_pos - position
	var nearby := to_player.length() <= CREATURE_ACTIVE_RADIUS
	creature["active_nearby_ticks"] = int(creature.get("active_nearby_ticks", 0)) + (1 if nearby else -2)
	creature["active_nearby_ticks"] = maxi(0, int(creature["active_nearby_ticks"]))
	var behavior: Dictionary = definition.get("behavior", {})
	var creature_tags: Array = definition_tags
	var social_role := str(behavior.get("social_role", ""))
	var aware := to_player.length() <= float(behavior.get("awareness_blocks", 6))
	var sight_fear := str(behavior.get("flee_trigger", "never")) == "on_sight" and aware and int(creature.get("fear_cooldown", 0)) == 0
	if sight_fear and int(creature.get("flee_ticks", 0)) <= 60 * 2:
		creature["flee_ticks"] = randi_range(CREATURE_SIGHT_FLEE_MIN_TICKS, CREATURE_SIGHT_FLEE_MAX_TICKS)
	var fleeing := sight_fear or int(creature.get("flee_ticks", 0)) > 0
	var attacking := (str(behavior.get("attack_trigger", "never")) == "always" and aware) or (str(behavior.get("attack_trigger", "never")) == "provoked" and int(creature.get("provoked_ticks", 0)) > 0)
	var shagot_activity := ""
	if "shagot" in creature_tags and not attacking and not fleeing:
		var activity_ticks := maxi(0, int(creature.get("shagot_activity_ticks", 0)) - 1)
		creature["shagot_activity_ticks"] = activity_ticks
		shagot_activity = str(creature.get("shagot_activity", ""))
		var has_persistent_task := not str(creature.get("shagot_task_kind", "")).is_empty()
		var following_wrong_player := shagot_activity == "follow" and str(creature.get("shagot_follow_player_id", "")) != target_player_id
		var following_too_far := shagot_activity == "follow" and to_player.length() > float(behavior.get("follow_distance", 5.5)) * 1.6
		if has_persistent_task:
			shagot_activity = "work"
			creature["shagot_activity"] = "work"
			creature["shagot_activity_ticks"] = maxi(60, activity_ticks)
		elif activity_ticks <= 0 or shagot_activity.is_empty() or following_wrong_player or following_too_far:
			shagot_activity = _choose_shagot_activity(creature, social_role, target_player_id, to_player.length())
	var prey_id := _predation_target_id(creature, definition)
	var hunting_prey := false
	var to_prey := Vector2.ZERO
	if not prey_id.is_empty() and creatures.has(prey_id):
		var prey: Dictionary = creatures[prey_id]
		to_prey = Vector2(float(prey.get("x", 0.0)), float(prey.get("y", 0.0))) - position
		var predation := _predation_profile(definition)
		hunting_prey = not attacking or not bool(predation.get("prefers_player", false)) or to_prey.length() < to_player.length()
	var desired := Vector2.ZERO
	var observing_plant := false
	var avoidance_ticks := maxi(0, int(creature.get("avoidance_ticks", 0)) - 1)
	creature["avoidance_ticks"] = avoidance_ticks
	if avoidance_ticks > 0:
		desired = Vector2(float(creature.get("avoidance_x", 0.0)), float(creature.get("avoidance_y", 0.0)))
	elif fleeing:
		creature["plant_interest_ticks"] = 0
		_reset_creature_point_interest_progress(creature)
		creature["plant_interest_cooldown"] = maxi(
			int(creature.get("plant_interest_cooldown", 0)),
			int(creature.get("flee_ticks", 0)) + CREATURE_FEAR_COOLDOWN_MAX_TICKS
		)
		var flee_source_id := str(creature.get("flee_source_id", ""))
		if not flee_source_id.is_empty() and creatures.has(flee_source_id) and not bool((creatures[flee_source_id] as Dictionary).get("dead", false)):
			var flee_source: Dictionary = creatures[flee_source_id]
			desired = position - Vector2(float(flee_source.get("x", 0.0)), float(flee_source.get("y", 0.0)))
		else:
			creature["flee_source_id"] = ""
			desired = -to_player
	elif hunting_prey:
		creature["plant_interest_ticks"] = 0
		_reset_creature_point_interest_progress(creature)
		desired = to_prey
	elif attacking:
		creature["plant_interest_ticks"] = 0
		_reset_creature_point_interest_progress(creature)
		desired = to_player
	elif shagot_activity == "work":
		desired = _tick_shagot_planner(creature, position)
	elif shagot_activity == "follow" and to_player.length() > 2.2 and to_player.length() <= float(behavior.get("follow_distance", 5.5)) * 1.6:
		desired = to_player
	elif shagot_activity == "observe":
		observing_plant = true
	elif shagot_activity == "wander":
		desired = _shagot_wander_desired(creature, position)
	else:
		var light_decision_ticks := maxi(0, int(creature.get("light_decision_ticks", 0)) - 1)
		creature["light_decision_ticks"] = light_decision_ticks
		if light_decision_ticks <= 0:
			var light_desired := _creature_light_desired(creature, definition)
			creature["light_desired_x"] = light_desired.x
			creature["light_desired_y"] = light_desired.y
			creature["light_decision_ticks"] = 24 + posmod(str(creature.get("id", "")).hash(), 25)
		desired = Vector2(
			float(creature.get("light_desired_x", 0.0)),
			float(creature.get("light_desired_y", 0.0))
		)
		if desired.length() < 0.05:
			var visit_ticks := int(creature.get("plant_interest_ticks", 0))
			if visit_ticks > 0 and not _creature_has_favorite_plant(creature, definition):
				visit_ticks = 0
				creature["plant_interest_ticks"] = 0
			if visit_ticks > 0:
				_reset_creature_point_interest_progress(creature)
				visit_ticks -= 1
				creature["plant_interest_ticks"] = visit_ticks
				observing_plant = true
				if visit_ticks == 0:
					creature["plant_interest_cooldown"] = randi_range(CREATURE_PLANT_COOLDOWN_MIN_TICKS, CREATURE_PLANT_COOLDOWN_MAX_TICKS)
			else:
				var interest_target: Variant = _favorite_plant_interest_target(creature, definition)
				if interest_target is Vector2:
					var target := interest_target as Vector2
					var to_interest := target - position
					if to_interest.length() <= CREATURE_PLANT_ARRIVAL_DISTANCE:
						_reset_creature_point_interest_progress(creature)
						creature["plant_interest_ticks"] = randi_range(CREATURE_PLANT_VISIT_MIN_TICKS, CREATURE_PLANT_VISIT_MAX_TICKS)
						observing_plant = true
					elif _creature_point_interest_is_stuck(creature, position):
						creature["plant_interest_cooldown"] = randi_range(CREATURE_POI_RETRY_COOLDOWN_MIN_TICKS, CREATURE_POI_RETRY_COOLDOWN_MAX_TICKS)
						_reset_creature_point_interest_progress(creature)
					else:
						desired = to_interest
				else:
					_reset_creature_point_interest_progress(creature)
	if "shagot" in creature_tags and desired.length() > 0.05:
		desired += _shagot_separation(creature)
	var locomotion_type := str((definition.get("locomotion", {}) as Dictionary).get("type", "walking"))
	if locomotion_type == "stationary":
		pass
	elif locomotion_type in ["flying", "swimming"]:
		if desired.length() < 0.05:
			desired = _creature_wander_desired(creature, definition)
		_move_free_creature(creature, definition, desired)
	else:
		_apply_creature_gravity(creature, definition)
		# Observation pauses horizontal movement, but never physics. In particular,
		# a Shagot whose supporting block was mined must fall immediately instead of
		# appearing suspended until its next activity decision.
		if not observing_plant:
			# Ordinary wildlife still wanders explicitly. Shagots use their activity
			# planner, where a zero vector intentionally means wait beside a player or
			# hold the exact work position until the strike completes.
			if desired.length() < 0.05 and "shagot" not in creature_tags:
				desired = _creature_wander_desired(creature, definition)
			_move_ground_creature(creature, definition, desired.x)
	if hunting_prey and creatures.has(prey_id):
		var prey_after_move: Dictionary = creatures[prey_id]
		var prey_position := Vector2(float(prey_after_move.get("x", 0.0)), float(prey_after_move.get("y", 0.0)))
		var predator_position := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
		if predator_position.distance_to(prey_position) < 1.0:
			_predator_attack(creature, definition, prey_id)
	if attacking and not hunting_prey and to_player.length() < 1.15:
		_damage_player_from_creature(creature, definition, target_player_id, player_pos)
	if "shagot" in creature_tags and not attacking and not fleeing:
		if nearby and int(creature.get("voice_cooldown", 0)) <= 0:
			Sfx.shagot_voice(social_role)
			creature["voice_cooldown"] = randi_range(60 * 7, 60 * 15)


func _shagot_follower_count(player_id: String, excluded_creature_id: String = "") -> int:
	var count := 0
	for other: Dictionary in creatures.values():
		if str(other.get("id", "")) == excluded_creature_id or bool(other.get("dead", false)):
			continue
		if str(other.get("shagot_activity", "")) != "follow" or int(other.get("shagot_activity_ticks", 0)) <= 0:
			continue
		if str(other.get("shagot_follow_player_id", "")) == player_id:
			count += 1
	return count


func _choose_shagot_activity(creature: Dictionary, social_role: String, player_id: String, player_distance: float, decision_roll: float = -1.0) -> String:
	var roll := randf() if decision_roll < 0.0 else clampf(decision_roll, 0.0, 0.9999)
	var follow_distance := 8.8 if social_role == "friendly" else 6.5
	var follow_chance := 0.22 if social_role == "friendly" else 0.06
	var can_follow := (
		player_distance > 2.2
		and player_distance <= follow_distance
		and _shagot_follower_count(player_id, str(creature.get("id", ""))) < SHAGOT_MAX_FOLLOWERS_PER_PLAYER
	)
	if not can_follow:
		follow_chance = 0.0
	var activity := "work"
	if can_follow and roll < follow_chance:
		activity = "follow"
	# A Shagot carrying material has already committed to the settlement's current
	# construction phase. Sending it on a random walk before it has delivered that
	# material reads as indecision and makes visible progress unnecessarily rare.
	elif int(creature.get("carried_materials", 0)) > 0:
		activity = "work"
	elif roll < follow_chance + 0.68:
		activity = "work"
	elif roll < follow_chance + 0.84:
		activity = "wander"
	else:
		activity = "observe"
	creature["shagot_activity"] = activity
	creature["shagot_activity_ticks"] = _shagot_activity_duration_ticks(activity)
	creature["shagot_follow_player_id"] = player_id if activity == "follow" else ""
	return activity


func _shagot_activity_duration_ticks(activity: String) -> int:
	# Looking around is readable in under two seconds. Longer stationary windows
	# made otherwise healthy Shagots look frozen, especially at a distance.
	if activity == "observe":
		return randi_range(SHAGOT_OBSERVE_MIN_TICKS, SHAGOT_OBSERVE_MAX_TICKS)
	return randi_range(SHAGOT_ACTIVITY_MIN_TICKS, SHAGOT_ACTIVITY_MAX_TICKS)


func _shagot_separation(creature: Dictionary) -> Vector2:
	var position := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var separation := Vector2.ZERO
	for other: Dictionary in creatures.values():
		if str(other.get("id", "")) == str(creature.get("id", "")) or bool(other.get("dead", false)):
			continue
		var other_definition := _creature_definition(str(other.get("block_name", "")))
		if "shagot" not in (other_definition.get("tags", []) as Array):
			continue
		var offset := position - Vector2(float(other.get("x", 0.0)), float(other.get("y", 0.0)))
		var distance := offset.length()
		if distance >= 1.35:
			continue
		if distance < 0.01:
			var direction := -1.0 if posmod(str(creature.get("id", "")).hash(), 2) == 0 else 1.0
			separation.x += direction
		else:
			separation += offset.normalized() * (1.35 - distance)
	return separation * 1.4


func _shagot_resource_kind(pos: Vector2i) -> String:
	var block := get_block(pos.x, pos.y)
	var block_name := str(block.get("name", ""))
	var floor_y := _shagot_floor_y(pos.x)
	if pos.y >= floor_y or block_id(pos.x, pos.y - 1) != 0:
		return ""
	if not bool(block.get("solid", false)) or bool(block.get("fluid", false)) or bool(block.get("item", false)) or bool(block.get("container", false)):
		return ""
	# Workers may quarry any exposed natural solid, but never dismantle the seal,
	# lights, recognized crafted construction, or their own settlement. The continuous
	# Lumenroot floor is excluded above by the floor check.
	if block_name in ["aegisite_seal", "resonance_bricks", "shagot_scaffold", "crystal_lantern", "chest"]:
		return ""
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	for protected_tag in ["crafted", "structure", "building", "furniture", "container", "light_source", "plant", "living"]:
		if protected_tag in tags:
			return ""
	return "mine"


func _shagot_floor_y(x: int) -> int:
	# Authored Challenge Run Shagot chapters live on the horizontal course rather
	# than in the procedural world's lower layer. Their planner still needs one
	# stable floor reference for mining, construction and navigation.
	if world_mode == WORLD_MODE_CHALLENGE and _is_shagot_biome(_biome_at(x)):
		return CHALLENGE_BASE_Y
	return _resonant_floor_y(x)


func _shagot_safe_ground_position(origin_x: int, definition: Dictionary, radius: int = 12) -> Variant:
	for distance in range(radius + 1):
		var offsets: Array = [0] if distance == 0 else [-distance, distance]
		for raw_offset_x in offsets:
			var candidate_x := origin_x + int(raw_offset_x)
			var expected_floor_y := _shagot_floor_y(candidate_x)
			var ground_spawn := _find_ground_spawn(candidate_x, expected_floor_y - 1)
			if ground_spawn.y == COORD_LIMIT:
				continue
			if not _is_shagot_biome(_ecology_biome_at(ground_spawn)):
				continue
			var candidate := Vector2(ground_spawn) + Vector2.ONE * 0.5
			if _ground_creature_position_matches(candidate, definition):
				return candidate
	return null


func _nearby_shagot_resource(creature: Dictionary, radius: int = 7) -> Variant:
	var origin := Vector2i(floori(float(creature.get("x", 0.0))), floori(float(creature.get("y", 0.0))))
	var best: Variant = null
	# Radius limits horizontal reach; a walking Shagot's center sits roughly
	# three tiles above the floor, so vertical distance must not invalidate it.
	var best_distance := radius * 2 + 5
	for offset_x in range(-radius, radius + 1):
		if offset_x == 0:
			continue
		for offset_y in range(-2, 5):
			var candidate := origin + Vector2i(offset_x, offset_y)
			if _shagot_resource_kind(candidate).is_empty():
				continue
			var distance := absi(offset_x) + absi(offset_y)
			if distance < best_distance:
				best = candidate
				best_distance = distance
	return best


func _shagot_task_target(creature: Dictionary) -> Vector2i:
	return Vector2i(
		int(creature.get("shagot_task_target_x", 0)),
		int(creature.get("shagot_task_target_y", 0)),
	)


func _clear_shagot_task(creature: Dictionary) -> void:
	creature["shagot_task_kind"] = ""
	creature["shagot_task_stage"] = ""
	creature["work_action"] = ""
	creature["work_action_ticks"] = 0
	creature.erase("work_target_x")
	creature.erase("work_target_y")


func _shagot_target_reserved(target: Vector2i, excluded_creature_id: String = "") -> bool:
	for other: Dictionary in creatures.values():
		if bool(other.get("dead", false)) or str(other.get("id", "")) == excluded_creature_id:
			continue
		if str(other.get("shagot_task_kind", "")).is_empty():
			continue
		if _shagot_task_target(other) != target or not _shagot_task_is_valid(other):
			continue
		var other_position := Vector2(float(other.get("x", 0.0)), float(other.get("y", 0.0)))
		var other_stand := Vector2(float(other.get("shagot_work_stand_x", other_position.x)), float(other.get("shagot_work_stand_y", other_position.y)))
		# A worker stranded below the settlement cannot own a reservation. This
		# releases old-save targets immediately, before the stranded worker is ticked.
		if absf(other_position.y - other_stand.y) > 6.0:
			continue
		return true
	return false


func _shagot_settlement_blueprint_phases(creature: Dictionary) -> Array:
	var creature_x := floori(float(creature.get("x", 0.0)))
	var chunk_x := floori(float(creature_x) / float(CHUNK_WIDTH))
	if world_mode == WORLD_MODE_CHALLENGE:
		var start_x := chunk_x * CHUNK_WIDTH
		return [
			[Vector2i(start_x + 6, CHALLENGE_BASE_Y - 1), Vector2i(start_x + 10, CHALLENGE_BASE_Y - 1)],
			[Vector2i(start_x + 6, CHALLENGE_BASE_Y - 2), Vector2i(start_x + 10, CHALLENGE_BASE_Y - 2)],
			[
				Vector2i(start_x + 6, CHALLENGE_BASE_Y - 3),
				Vector2i(start_x + 7, CHALLENGE_BASE_Y - 3),
				Vector2i(start_x + 8, CHALLENGE_BASE_Y - 3),
				Vector2i(start_x + 9, CHALLENGE_BASE_Y - 3),
				Vector2i(start_x + 10, CHALLENGE_BASE_Y - 3),
			],
		]
	var region_index := floori(float(chunk_x) / float(RESONANT_BIOME_SPAN_CHUNKS))
	var region_start_x := region_index * RESONANT_BIOME_SPAN_CHUNKS * CHUNK_WIDTH
	var center_x := region_start_x + RESONANT_BIOME_SPAN_CHUNKS * CHUNK_WIDTH / 2
	var phases: Array = []
	# The Enclave is a real settlement project rather than one short fixture.
	# Each structure is completed from the floor upward before the next begins,
	# keeping every action readable and preventing floating roofs. Scaffold is
	# intentionally walk-through, so the new ground-floor partitions never trap
	# the player or the workers.
	for structure in [
		{"posts": [-7, -3, 3, 7], "left": -7, "right": 7, "height": 3},
		{"posts": [-28, -24, -20, -16], "left": -28, "right": -16, "height": 3},
		{"posts": [16, 20, 24, 28], "left": 16, "right": 28, "height": 3},
	]:
		var lower_posts: Array[Vector2i] = []
		var upper_posts: Array[Vector2i] = []
		var roof: Array[Vector2i] = []
		for relative_x: int in structure.posts:
			var post_x: int = center_x + relative_x
			var floor_y := _shagot_floor_y(post_x)
			lower_posts.append(Vector2i(post_x, floor_y - 1))
			upper_posts.append(Vector2i(post_x, floor_y - 2))
		for relative_x: int in range(int(structure.left), int(structure.right) + 1):
			var roof_x := center_x + relative_x
			roof.append(Vector2i(roof_x, _shagot_floor_y(roof_x) - int(structure.height)))
		phases.append(lower_posts)
		phases.append(upper_posts)
		phases.append(roof)
	# Two taller watch-and-lift frames make the settlement keep evolving after
	# its three halls are usable. Their narrow open bases remain traversable.
	for tower in [
		{"posts": [-14, -10], "left": -15, "right": -9},
		{"posts": [10, 14], "left": 9, "right": 15},
	]:
		for level in range(1, 5):
			var tower_level: Array[Vector2i] = []
			for relative_x: int in tower.posts:
				var post_x: int = center_x + relative_x
				tower_level.append(Vector2i(post_x, _shagot_floor_y(post_x) - level))
			phases.append(tower_level)
		var platform: Array[Vector2i] = []
		for relative_x: int in range(int(tower.left), int(tower.right) + 1):
			var platform_x := center_x + relative_x
			platform.append(Vector2i(platform_x, _shagot_floor_y(platform_x) - 5))
		phases.append(platform)
	return phases


func _shagot_settlement_blueprint_sites(creature: Dictionary) -> Array[Vector2i]:
	var sites: Array[Vector2i] = []
	for raw_phase in _shagot_settlement_blueprint_phases(creature):
		for target: Vector2i in (raw_phase as Array):
			sites.append(target)
	return sites


func _shagot_work_reach(kind: String) -> float:
	return SHAGOT_MINING_REACH if kind == "mine" else SHAGOT_BUILDING_REACH


func _shagot_target_in_reach(creature: Dictionary, target: Vector2i, kind: String) -> bool:
	var position := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var target_center := Vector2(target) + Vector2.ONE * 0.5
	return position.distance_to(target_center) <= _shagot_work_reach(kind)


func _shagot_work_stand_position(creature: Dictionary, target: Vector2i, kind: String = "build") -> Variant:
	var definition := _creature_definition(str(creature.get("block_name", "")))
	var current := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	var best: Variant = null
	var best_distance := INF
	for offset_x in [-1, 1, 0]:
		var stand_x: int = target.x + int(offset_x)
		var stand := Vector2(float(stand_x) + 0.5, float(_shagot_floor_y(stand_x)) - 0.5)
		# Work must happen within visible arm's reach. The old +/- two-cell stand
		# positions combined with unrestricted height let miners strike blocks several
		# tiles away. A zero horizontal offset is useful only for an overhead target.
		var target_center := Vector2(target) + Vector2.ONE * 0.5
		if stand.distance_to(target_center) > _shagot_work_reach(kind):
			continue
		if offset_x == 0 and absf(stand.y - target_center.y) < 0.5:
			continue
		if not _is_shagot_biome(_ecology_biome_at(Vector2i(stand_x, floori(stand.y)))):
			continue
		if not _ground_creature_position_matches(stand, definition):
			continue
		var support := get_block(stand_x, _shagot_floor_y(stand_x))
		if not bool(support.get("solid", false)) or bool(support.get("fluid", false)):
			continue
		var distance := current.distance_to(stand)
		if distance < best_distance:
			best = stand
			best_distance = distance
	return best


func _shagot_available_build_site(creature: Dictionary) -> Variant:
	var current := Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0)))
	for raw_phase in _shagot_settlement_blueprint_phases(creature):
		var phase: Array = raw_phase as Array
		var phase_incomplete := false
		var phase_has_active_reservation := false
		var best: Variant = null
		var best_distance := INF
		for target: Vector2i in phase:
			if block_id(target.x, target.y) != 0:
				continue
			phase_incomplete = true
			if _shagot_target_reserved(target, str(creature.get("id", ""))):
				phase_has_active_reservation = true
				continue
			var stand: Variant = _shagot_work_stand_position(creature, target, "build")
			if not stand is Vector2:
				continue
			var distance := current.distance_to(stand as Vector2)
			if distance < best_distance:
				best = {"target": target, "stand": stand}
				best_distance = distance
		# Workers share the current construction phase. If all its cells are
		# reserved, additional builders wait instead of jumping ahead to the roof.
		if phase_incomplete:
			if best is Dictionary or phase_has_active_reservation:
				return best
			# A permanently unreachable legacy cell must not block every later hall.
			# With no live reservation, advance to the next independently supported phase.
			continue
	return null


func _shagot_available_resource(creature: Dictionary, radius: int = SHAGOT_WORK_SEARCH_RADIUS) -> Variant:
	var origin := Vector2i(floori(float(creature.get("x", 0.0))), floori(float(creature.get("y", 0.0))))
	var best: Variant = null
	var best_distance := radius * 3
	for offset_x in range(-radius, radius + 1):
		if offset_x == 0:
			continue
		for offset_y in range(-3, 6):
			var target := origin + Vector2i(offset_x, offset_y)
			if _shagot_resource_kind(target).is_empty() or _shagot_target_reserved(target, str(creature.get("id", ""))):
				continue
			var stand: Variant = _shagot_work_stand_position(creature, target, "mine")
			if not stand is Vector2:
				continue
			var distance := absi(offset_x) + absi(offset_y)
			if distance < best_distance:
				best = {"target": target, "stand": stand}
				best_distance = distance
	return best


func _assign_shagot_task(creature: Dictionary) -> bool:
	if not _is_shagot_biome(_ecology_biome_at(Vector2i(floori(float(creature.get("x", 0.0))), floori(float(creature.get("y", 0.0)))))):
		return false
	var task: Variant = null
	var kind := ""
	if int(creature.get("carried_materials", 0)) > 0 and int(creature.get("built_blocks", 0)) < SHAGOT_BUILD_LIMIT:
		task = _shagot_available_build_site(creature)
		kind = "build"
	# Mining is a supply job, not a default loop. Once a worker carries material it
	# waits for a free construction cell instead of filling its inventory while the
	# other builders finish the current phase.
	if not task is Dictionary and int(creature.get("carried_materials", 0)) == 0:
		task = _shagot_available_resource(creature)
		kind = "mine"
	if not task is Dictionary:
		return false
	var target: Vector2i = (task as Dictionary)["target"]
	var stand: Vector2 = (task as Dictionary)["stand"]
	creature["shagot_task_kind"] = kind
	creature["shagot_task_stage"] = "travel"
	creature["shagot_task_target_x"] = target.x
	creature["shagot_task_target_y"] = target.y
	creature["shagot_work_stand_x"] = stand.x
	creature["shagot_work_stand_y"] = stand.y
	return true


func _shagot_task_is_valid(creature: Dictionary) -> bool:
	var kind := str(creature.get("shagot_task_kind", ""))
	var target := _shagot_task_target(creature)
	if kind == "mine":
		return not _shagot_resource_kind(target).is_empty()
	if kind == "build":
		if str(creature.get("shagot_task_stage", "")) == "act":
			return str(get_block(target.x, target.y).get("name", "")) == "shagot_scaffold"
		return block_id(target.x, target.y) == 0 and int(creature.get("carried_materials", 0)) > 0
	return false


func _start_shagot_task_action(creature: Dictionary) -> void:
	var target := _shagot_task_target(creature)
	var kind := str(creature.get("shagot_task_kind", ""))
	if not _shagot_task_is_valid(creature) or not _shagot_target_in_reach(creature, target, kind):
		_clear_shagot_task(creature)
		return
	creature["facing"] = 1 if float(target.x) + 0.5 >= float(creature.get("x", 0.0)) else -1
	if kind == "build":
		# Put the material in the world before the hammer animation. Swinging at an
		# empty future cell looked exactly like mining air, even when the task later
		# completed correctly.
		set_block(target.x, target.y, int(BlockDefs.BLOCKS.shagot_scaffold.id))
		static_tiles_changed.emit()
		creature["carried_materials"] = int(creature.get("carried_materials", 0)) - 1
		creature["built_blocks"] = int(creature.get("built_blocks", 0)) + 1
	creature["shagot_task_stage"] = "act"
	creature["work_action"] = "mining" if kind == "mine" else "building"
	creature["work_action_ticks"] = SHAGOT_WORK_ACTION_TICKS
	creature["work_target_x"] = target.x
	creature["work_target_y"] = target.y


func _complete_shagot_task(creature: Dictionary) -> void:
	if not _shagot_task_is_valid(creature):
		_clear_shagot_task(creature)
		return
	var target := _shagot_task_target(creature)
	var kind := str(creature.get("shagot_task_kind", ""))
	var completed_action := ""
	if kind == "mine":
		set_block(target.x, target.y, 0)
		creature["carried_materials"] = int(creature.get("carried_materials", 0)) + 1
		completed_action = "mining"
	else:
		completed_action = "building"
	Sfx.shagot_work(completed_action)
	creature["work_cooldown"] = randi_range(18, 36)
	_clear_shagot_task(creature)


func _tick_shagot_planner(creature: Dictionary, position: Vector2) -> Vector2:
	if int(creature.get("work_cooldown", 0)) > 0 and str(creature.get("shagot_task_kind", "")).is_empty():
		# The cooldown is a readable breather after a completed strike, not a new
		# navigation decision. Walking toward a cached wander target here made workers
		# reverse direction as soon as the next building task was assigned.
		return Vector2.ZERO
	if str(creature.get("shagot_task_kind", "")).is_empty() and not _assign_shagot_task(creature):
		# With no reachable building or gathering job, use one stable wander target.
		# Unlike the old cooldown bug this is a real fallback activity, not a random
		# detour inserted between two steps of an available job.
		return _shagot_wander_desired(creature, position)
	if not _shagot_task_is_valid(creature):
		_clear_shagot_task(creature)
		# Another worker may have completed our target during this tick. Re-plan
		# immediately so the Shagot does not take a one-tick step toward an unrelated
		# wander target and then turn back.
		if _assign_shagot_task(creature):
			return _tick_shagot_planner(creature, position)
		return _shagot_wander_desired(creature, position)
	var stand := Vector2(
		float(creature.get("shagot_work_stand_x", position.x)),
		float(creature.get("shagot_work_stand_y", position.y)),
	)
	# Ground locomotion only steers horizontally; gravity determines the exact
	# resting height on steps and resource outcrops. Requiring 2D proximity made a
	# worker that was already beside its target chase an unreachable Y coordinate,
	# repeatedly walking past the cell and turning around without ever striking.
	if absf(position.x - stand.x) > 0.42:
		creature["shagot_task_stage"] = "travel"
		creature["work_action"] = ""
		creature["work_action_ticks"] = 0
		return stand - position
	if str(creature.get("shagot_task_stage", "")) != "act":
		_start_shagot_task_action(creature)
		return Vector2.ZERO
	if int(creature.get("work_action_ticks", 0)) <= 0:
		_complete_shagot_task(creature)
	return Vector2.ZERO


func _shagot_wander_desired(creature: Dictionary, position: Vector2) -> Vector2:
	var ticks := maxi(0, int(creature.get("shagot_wander_ticks", 0)) - 1)
	var target_x := float(creature.get("shagot_wander_target_x", position.x))
	if ticks <= 0 or absf(target_x - position.x) < 0.45:
		var direction := -1.0 if randf() < 0.5 else 1.0
		var distance := float(randi_range(3, 8))
		var candidate_x := position.x + direction * distance
		for _attempt in 6:
			if _is_shagot_biome(_ecology_biome_at(Vector2i(floori(candidate_x), floori(position.y)))):
				break
			distance -= 1.0
			candidate_x = position.x + direction * distance
		target_x = candidate_x
		ticks = randi_range(60 * 3, 60 * 6)
		creature["shagot_wander_target_x"] = target_x
	creature["shagot_wander_ticks"] = ticks
	return Vector2(target_x - position.x, 0.0)


# Kept as a focused hook for simulations and tests; live AI calls the planner
# every tick through _tick_creature.
func _tick_shagot_work(creature: Dictionary) -> void:
	_tick_shagot_planner(creature, Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0))))


func try_interact_creature(creature_id: String) -> bool:
	if not creatures.has(creature_id):
		return false
	var creature: Dictionary = creatures[creature_id]
	var definition := _creature_definition(str(creature.get("block_name", "")))
	var behavior: Dictionary = definition.get("behavior", {}) if definition.get("behavior", {}) is Dictionary else {}
	if str(behavior.get("social_role", "")) != "friendly":
		return false
	var pos := Vector2i(floori(float(creature.get("x", 0.0))), floori(float(creature.get("y", 0.0))))
	if not player_in_combat_range(pos.x, pos.y):
		return false
	if int(creature.get("gift_cooldown", 0)) <= 0:
		give_to_inventory("lumenroot", 1)
		creature["gift_cooldown"] = 60 * 60 * 10
		inventory_changed.emit()
		state_changed.emit()
	return true


func _creature_has_favorite_plant(creature: Dictionary, definition: Dictionary) -> bool:
	return _favorite_plant_position(creature, definition) is Vector2


func _mixed_creature_morphology(first_definition: Dictionary, second_definition: Dictionary) -> Dictionary:
	var first := BlockDefs.creature_morphology(first_definition)
	var second := BlockDefs.creature_morphology(second_definition)
	if first.is_empty():
		return second.duplicate(true)
	if second.is_empty():
		return first.duplicate(true)
	var first_limbs: Dictionary = first.get("limbs", {})
	var second_limbs: Dictionary = second.get("limbs", {})
	var selected_limbs: Dictionary = (first_limbs if randf() < 0.5 else second_limbs).duplicate(true)
	selected_limbs["length"] = clampf((float(first_limbs.get("length", 0.5)) + float(second_limbs.get("length", 0.5))) * 0.5 * randf_range(0.92, 1.08), 0.2, 1.4)
	var first_proportions: Dictionary = first.get("proportions", {})
	var second_proportions: Dictionary = second.get("proportions", {})
	var features: Array = []
	for feature in (first.get("features", []) as Array) + (second.get("features", []) as Array):
		if feature not in features and (features.size() < 2 or randf() < 0.55):
			features.append(feature)
		if features.size() >= 4:
			break
	return {
		"body_plan": first.get("body_plan", "blob") if randf() < 0.5 else second.get("body_plan", "blob"),
		"body_shape": first.get("body_shape", "round") if randf() < 0.5 else second.get("body_shape", "round"),
		"head_shape": first.get("head_shape", "round") if randf() < 0.5 else second.get("head_shape", "round"),
		"limbs": selected_limbs,
		"ears": first.get("ears", "none") if randf() < 0.5 else second.get("ears", "none"),
		"tail": first.get("tail", "none") if randf() < 0.5 else second.get("tail", "none"),
		"covering": first.get("covering", "smooth") if randf() < 0.5 else second.get("covering", "smooth"),
		"features": features,
		"proportions": {
			"head": clampf((float(first_proportions.get("head", 0.9)) + float(second_proportions.get("head", 0.9))) * 0.5 * randf_range(0.95, 1.05), 0.6, 1.4),
			"body": clampf((float(first_proportions.get("body", 1.0)) + float(second_proportions.get("body", 1.0))) * 0.5 * randf_range(0.95, 1.05), 0.6, 1.4),
		},
	}


func _inherit_nearby_plant_trait(position: Vector2, palette: Array, traits: Dictionary) -> void:
	var nearest_anchor: Variant = null
	var nearest_distance := 6.0
	for anchor: Vector2i in plant_growth.keys():
		var distance := position.distance_to(Vector2(anchor) + Vector2.ONE * 0.5)
		if distance < nearest_distance:
			nearest_anchor = anchor
			nearest_distance = distance
	if nearest_anchor == null:
		return
	var plant_data: Dictionary = plant_growth[nearest_anchor as Vector2i]
	var plant_definition := _plant_definition(str(plant_data.get("block_name", "")))
	var plant_visual: Dictionary = plant_definition.get("visual", {})
	var plant_traits: Dictionary = plant_data.get("traits", {}) if plant_data.get("traits", {}) is Dictionary else {}
	var plant_palette: Array = plant_traits.get("palette", plant_visual.get("palette", []))
	if not plant_palette.is_empty():
		palette.append(plant_palette[mini(1, plant_palette.size() - 1)])
		while palette.size() > 5:
			palette.pop_back()
	var morphology: Dictionary = traits.get("morphology", {}) if traits.get("morphology", {}) is Dictionary else {}
	if not morphology.is_empty():
		var features: Array = morphology.get("features", []) if morphology.get("features", []) is Array else []
		var form := str((plant_definition.get("growth", {}) as Dictionary).get("form", "vertical_up"))
		var plant_feature := "vines" if form in ["hanging", "surface_creeper"] else "petals"
		if plant_feature not in features and features.size() < 4:
			features.append(plant_feature)
		morphology["features"] = features
		traits["morphology"] = morphology
	traits["cross_kingdom_donor"] = BlockDefs.content_id_for_name(str(plant_data.get("block_name", "")))


func _try_breed_creatures() -> void:
	if creatures.size() >= CREATURE_MAX_WORLD:
		return
	var ids: Array = []
	for creature_id: String in creatures.keys():
		if _creature_distance_to_player(creatures[creature_id]) <= CREATURE_ACTIVE_RADIUS:
			ids.append(creature_id)
	for i in ids.size():
		var first: Dictionary = creatures[ids[i]]
		var first_def := _creature_definition(str(first.get("block_name", "")))
		var first_breeding: Dictionary = first_def.get("breeding", {})
		if not bool(first_breeding.get("enabled", true)):
			continue
		var required_ticks := int(first_breeding.get("active_nearby_seconds", 1800)) * 60
		if int(first.get("breeding_cooldown", 0)) > 0 or int(first.get("active_nearby_ticks", 0)) < required_ticks:
			continue
		if bool(first_breeding.get("requires_favorite_plant", true)) and not _creature_has_favorite_plant(first, first_def):
			continue
		for j in range(i + 1, ids.size()):
			var second: Dictionary = creatures[ids[j]]
			var second_def := _creature_definition(str(second.get("block_name", "")))
			var second_breeding: Dictionary = second_def.get("breeding", {})
			if not bool(second_breeding.get("enabled", true)):
				continue
			if str(first_breeding.get("group", "")) != str(second_breeding.get("group", "")) or int(second.get("breeding_cooldown", 0)) > 0 or int(second.get("active_nearby_ticks", 0)) < int(second_breeding.get("active_nearby_seconds", 1800)) * 60:
				continue
			var first_pos := Vector2(float(first["x"]), float(first["y"]))
			var second_pos := Vector2(float(second["x"]), float(second["y"]))
			if first_pos.distance_to(second_pos) > 3.0:
				continue
			var child_name := str(first.get("block_name", "")) if randf() < 0.5 else str(second.get("block_name", ""))
			var hybrid_chance := maxf(float(first_breeding.get("hybrid_chance", 0.03)), float(second_breeding.get("hybrid_chance", 0.03)))
			var palette: Array = []
			var traits: Dictionary = {}
			if str(first.get("content_id", "")) != str(second.get("content_id", "")) and randf() < hybrid_chance:
				var first_palette: Array = (first_def.get("visual", {}) as Dictionary).get("palette", [])
				var second_palette: Array = (second_def.get("visual", {}) as Dictionary).get("palette", [])
				if not first_palette.is_empty() and not second_palette.is_empty():
					palette = [first_palette[0], second_palette[mini(1, second_palette.size() - 1)]]
				var first_speed := float((first_def.get("locomotion", {}) as Dictionary).get("speed", 0.8))
				var second_speed := float((second_def.get("locomotion", {}) as Dictionary).get("speed", 0.8))
				var chosen_speed := float((_creature_definition(child_name).get("locomotion", {}) as Dictionary).get("speed", 0.8))
				traits["speed_multiplier"] = clampf(((first_speed + second_speed) * 0.5) / maxf(0.1, chosen_speed) * randf_range(0.94, 1.06), 0.75, 1.25)
				traits["health_bonus"] = 1 if randf() < 0.12 else 0
				traits["morphology"] = _mixed_creature_morphology(first_def, second_def)
				var first_pattern := str((first_def.get("visual", {}) as Dictionary).get("pattern", "mottled"))
				var second_pattern := str((second_def.get("visual", {}) as Dictionary).get("pattern", "mottled"))
				traits["color_pattern"] = first_pattern if randf() < 0.5 else second_pattern
				var inherited_tags: Array = []
				for tag in (first_def.get("habitat", {}) as Dictionary).get("favorite_plant_tags", []) + (second_def.get("habitat", {}) as Dictionary).get("favorite_plant_tags", []):
					if tag not in inherited_tags:
						inherited_tags.append(tag)
				traits["favorite_plant_tags"] = inherited_tags.slice(0, 8)
			if randf() < hybrid_chance:
				if not traits.has("morphology"):
					traits["morphology"] = BlockDefs.creature_morphology(_creature_definition(child_name)).duplicate(true)
				_inherit_nearby_plant_trait((first_pos + second_pos) * 0.5, palette, traits)
			spawn_creature(child_name, (first_pos + second_pos) * 0.5, false, [first.get("content_id", ""), second.get("content_id", "")], palette, traits)
			first["breeding_cooldown"] = int(first_breeding.get("cooldown_seconds", 1800)) * 60
			second["breeding_cooldown"] = int(second_breeding.get("cooldown_seconds", 1800)) * 60
			first["active_nearby_ticks"] = 0
			second["active_nearby_ticks"] = 0
			return


func _activate_nearby_challenge_encounter() -> void:
	if world_mode != WORLD_MODE_CHALLENGE:
		return
	var player_tile_x := floori((float(player["x"]) + float(player["w"]) * 0.5) / float(BlockDefs.TILE))
	var player_chunk := floori(float(player_tile_x) / float(CHUNK_WIDTH))
	# Authored encounter creatures are persistent while relevant, then discarded
	# once the runner is safely past them so an endless course cannot leak entities.
	for creature_id: String in creatures.keys():
		var creature: Dictionary = creatures[creature_id]
		if not creature.has("challenge_encounter_chunk"):
			continue
		if int(creature["challenge_encounter_chunk"]) < player_chunk - 2:
			creatures.erase(creature_id)
	if player_chunk < 0 or _challenge_activated_encounters.has(player_chunk):
		return
	if not generated_chunks.has(player_chunk):
		return
	var pattern := _challenge_pattern_at_chunk(player_chunk)
	var start_x := player_chunk * CHUNK_WIDTH
	var encounter := _challenge_encounter_for_pattern(pattern)
	if encounter.is_empty() and pattern not in [27, 28, 30]:
		return
	if pattern in [20, 21]:
		# Keep the buried nest dormant until the ice plug melts. Releasing the fliers
		# with the first falling grains adds danger without putting a solid floor or
		# lava in the chute, both of which would eventually jam the hopper.
		var hopper_plug := Vector2i(start_x + 9, CHALLENGE_BASE_Y + 5)
		if get_block(hopper_plug.x, hopper_plug.y).get("name", "") == "ice":
			return
	_challenge_activated_encounters[player_chunk] = true
	if pattern == 27:
		# The bridge and containment already exist in the generated chunk. Activating
		# only the lava preserves the surprise while preventing premature burning.
		for local_x in range(5, CHUNK_WIDTH - 3):
			set_block(start_x + local_x, CHALLENGE_BASE_Y + 1, int(BlockDefs.BLOCKS.lava.id), 0)
		return
	if pattern == 28:
		for local_x in [6, 9, 12]:
			set_block(start_x + local_x, CHALLENGE_BASE_Y - 7, int(BlockDefs.BLOCKS.lava.id), 0, true)
		return
	if pattern == 30:
		for local_x in [6, 9, 12]:
			set_block(start_x + local_x, CHALLENGE_BASE_Y - 14, int(BlockDefs.BLOCKS.lava.id), 0, true)
		return
	for spec: Dictionary in encounter:
		var block_name := BlockDefs.name_for_content_id(str(spec.get("content_id", "")))
		if block_name.is_empty():
			continue
		var creature_id := spawn_creature(
			block_name,
			Vector2(float(start_x + int(spec.get("local_x", 8))) + 0.5, float(spec.get("y", CHALLENGE_BASE_Y - 1)) + 0.5),
		)
		if not creature_id.is_empty():
			var creature := creatures[creature_id] as Dictionary
			creature["challenge_encounter_chunk"] = player_chunk
			var initial_state: Dictionary = spec.get("state", {}) if spec.get("state", {}) is Dictionary else {}
			for key: String in initial_state.keys():
				creature[key] = initial_state[key]
			var definition := _creature_definition(block_name)
			if str((definition.get("behavior", {}) as Dictionary).get("temperament", "passive")) == "defensive":
				creature["provoked_ticks"] = 60 * 30


func _ensure_resonant_deep_population() -> void:
	# Challenge Run owns a bounded, deterministic encounter lifecycle. Letting the
	# ambient Deep population manager run here would add untracked Guides and
	# Raiders beside the authored Worksite and Lockworks encounters.
	if world_mode == WORLD_MODE_CHALLENGE:
		return
	var player_tile := _player_center_tile()
	var biome_id := _ecology_biome_at(player_tile)
	if not _is_shagot_biome(biome_id):
		_ensure_resonant_deep_wildlife(player_tile, biome_id)
		return
	var player_chunk := floori(float(player_tile.x) / float(CHUNK_WIDTH))
	var region_index := floori(float(player_chunk) / float(RESONANT_BIOME_SPAN_CHUNKS))
	var region_start_x := region_index * RESONANT_BIOME_SPAN_CHUNKS * CHUNK_WIDTH
	var region_center_x := region_start_x + RESONANT_BIOME_SPAN_CHUNKS * CHUNK_WIDTH / 2
	var role_specs: Array[Dictionary] = [
		{"content_id": "core.creature.shagot_wanderer", "minimum": 1, "offsets": [-12]},
		{"content_id": "core.creature.shagot_guide", "minimum": 1, "offsets": [17]},
		{"content_id": "core.creature.shagot_raider", "minimum": 1, "offsets": [-21]},
	]
	for spec: Dictionary in role_specs:
		var content_id := str(spec.get("content_id", ""))
		var nearby := 0
		for creature: Dictionary in creatures.values():
			if str(creature.get("content_id", "")) != content_id:
				continue
			# Existing saves may contain pre-update Shagots with no material and no
			# completed work. Seed only those untouched workers; established builds
			# keep their exact state and never receive an infinite refill.
			if int(creature.get("built_blocks", 0)) == 0 and int(creature.get("carried_materials", 0)) == 0:
				creature["carried_materials"] = 4
			if Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0))).distance_to(Vector2(player_tile)) <= 42.0:
				nearby += 1
		var missing := maxi(0, int(spec.get("minimum", 0)) - nearby)
		if missing <= 0:
			continue
		var block_name := BlockDefs.name_for_content_id(content_id)
		if block_name.is_empty():
			continue
		var definition := _creature_definition(block_name)
		var offsets: Array = spec.get("offsets", []) if spec.get("offsets", []) is Array else []
		for index in mini(missing, offsets.size()):
			var spawn_x := region_center_x + int(offsets[index])
			var safe_position: Variant = _shagot_safe_ground_position(spawn_x, definition)
			if not safe_position is Vector2:
				continue
			var creature_id := spawn_creature(block_name, safe_position as Vector2, true)
			if not creature_id.is_empty():
				# They begin working almost immediately, rather than looking like
				# inert decorative NPCs during the player's first visit.
				(creatures[creature_id] as Dictionary)["work_cooldown"] = randi_range(20, 70)


func _ensure_resonant_deep_wildlife(player_tile: Vector2i, biome_id: String) -> void:
	if player_tile.y < RESONANT_DEEP_TOP_Y:
		return
	var biome := _biome_definition(biome_id)
	var ecology: Dictionary = biome.get("ecology", {}) if biome.get("ecology", {}) is Dictionary else {}
	var available_ids: Array = ecology.get("creature_content_ids", []) if ecology.get("creature_content_ids", []) is Array else []
	if available_ids.is_empty():
		return
	var player_chunk := floori(float(player_tile.x) / float(CHUNK_WIDTH))
	var region_index := floori(float(player_chunk) / float(RESONANT_BIOME_SPAN_CHUNKS))
	var region_start_x := region_index * RESONANT_BIOME_SPAN_CHUNKS * CHUNK_WIDTH
	var region_center_x := region_start_x + RESONANT_BIOME_SPAN_CHUNKS * CHUNK_WIDTH / 2
	var content_id := str(RESONANT_DEEP_WILDLIFE.get(biome_id, available_ids[0]))
	if content_id not in available_ids:
		content_id = str(available_ids[0])
	var block_name := BlockDefs.name_for_content_id(content_id)
	if block_name.is_empty():
		return
	var nearby := 0
	for creature: Dictionary in creatures.values():
		if str(creature.get("content_id", "")) == content_id and Vector2(float(creature.get("x", 0.0)), float(creature.get("y", 0.0))).distance_to(Vector2(player_tile)) <= 42.0:
			nearby += 1
	var definition := _creature_definition(block_name)
	var locomotion_type := str((definition.get("locomotion", {}) as Dictionary).get("type", "walking"))
	var offsets := [-15, 13]
	for index in maxi(0, 2 - nearby):
		var spawn_x := region_center_x + int(offsets[index])
		var spawn_y := _resonant_floor_y(spawn_x) - 1
		if locomotion_type == "flying":
			spawn_y -= 4 + index
		var safe_position: Variant = _nearest_safe_creature_position(Vector2(spawn_x + 0.5, spawn_y + 0.5), definition, 7)
		if safe_position is Vector2:
			spawn_creature(block_name, safe_position as Vector2, true)


func tick_creatures() -> void:
	creature_tick += 1
	_activate_nearby_challenge_encounter()
	if creature_tick % 60 == 1:
		_prune_excess_local_shagots()
		_ensure_resonant_deep_population()
	if creature_tick >= CREATURE_INITIAL_SPAWN_DELAY:
		var spawn_tick := creature_tick - CREATURE_INITIAL_SPAWN_DELAY
		if spawn_tick % FIREFLY_SPAWN_EVERY == 0:
			_try_spawn_ambient_firefly()
		if spawn_tick % CREATURE_HOSTILE_SPAWN_EVERY == 0:
			_remove_distant_natural_hostiles()
			_try_spawn_creatures("hostile")
		if spawn_tick % CREATURE_PEACEFUL_SPAWN_EVERY == 0:
			_prune_distant_natural_creatures()
			_try_spawn_creatures("peaceful")
	for creature: Dictionary in creatures.values():
		_tick_creature(creature)
	for creature_id: String in creatures.keys():
		if bool((creatures[creature_id] as Dictionary).get("dead", false)):
			creatures.erase(creature_id)
	if creature_tick % CREATURE_BREED_CHECK_EVERY == 0:
		_try_breed_creatures()


func tick_time() -> void:
	_ensure_one_block()
	var previous_tick := world_time_tick
	world_time_tick = (world_time_tick + 1) % DAY_LENGTH_TICKS
	if world_time_tick % 60 == 0:
		expire_death_caches()
	# Persistence can observe time frequently without forcing the expensive cave
	# lighting layer to rebuild at the same cadence.
	if world_time_tick % 300 == 0:
		time_changed.emit()
	if _crossed_daylight_render_step(previous_tick, world_time_tick):
		daylight_changed.emit()


func tick_player_needs(delta: float, allow_health_changes: bool = true) -> void:
	if delta <= 0.0 or int(player.get("health", MAX_PLAYER_HEALTH)) <= 0:
		return
	_nourishment_drain_elapsed += delta
	while _nourishment_drain_elapsed >= NOURISHMENT_DRAIN_SECONDS:
		_nourishment_drain_elapsed -= NOURISHMENT_DRAIN_SECONDS
		player["nourishment"] = maxi(0, int(player.get("nourishment", MAX_NOURISHMENT)) - 1)

	var nourishment := int(player.get("nourishment", MAX_NOURISHMENT))
	if allow_health_changes and nourishment >= NOURISHMENT_RECOVERY_THRESHOLD and int(player.get("health", MAX_PLAYER_HEALTH)) < MAX_PLAYER_HEALTH:
		_nourishment_recovery_elapsed += delta
		if _nourishment_recovery_elapsed >= NOURISHMENT_RECOVERY_SECONDS:
			_nourishment_recovery_elapsed = 0.0
			player["health"] = mini(MAX_PLAYER_HEALTH, int(player["health"]) + 1)
			player["nourishment"] = maxi(0, nourishment - NOURISHMENT_RECOVERY_COST)
			state_changed.emit()
	else:
		_nourishment_recovery_elapsed = 0.0

	if allow_health_changes and int(player.get("nourishment", MAX_NOURISHMENT)) <= 0:
		_starvation_damage_elapsed += delta
		if _starvation_damage_elapsed >= STARVATION_DAMAGE_SECONDS:
			_starvation_damage_elapsed = 0.0
			player["health"] = maxi(0, int(player.get("health", MAX_PLAYER_HEALTH)) - 1)
			Sfx.hurt()
			state_changed.emit()
			if int(player["health"]) <= 0:
				player_defeated.emit()
	else:
		_starvation_damage_elapsed = 0.0


func item_nourishment(block_name: String) -> int:
	var block: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return maxi(0, int(effects.get("nourishment", 0)))


func consume_food(block_name: String) -> bool:
	var nourishment := item_nourishment(block_name)
	if nourishment <= 0 or inventory.get(block_name, 0) <= 0:
		return false
	if int(player.get("nourishment", MAX_NOURISHMENT)) >= MAX_NOURISHMENT:
		return false
	if not take_from_inventory(block_name):
		return false
	player["nourishment"] = mini(MAX_NOURISHMENT, int(player.get("nourishment", MAX_NOURISHMENT)) + nourishment)
	_nourishment_recovery_elapsed = 0.0
	inventory_changed.emit()
	state_changed.emit()
	return true


func advance_remote_world_time(ticks: int) -> void:
	if ticks <= 0:
		return
	var previous_tick := world_time_tick
	world_time_tick = posmod(world_time_tick + ticks, DAY_LENGTH_TICKS)
	if _crossed_daylight_render_step(previous_tick, world_time_tick):
		daylight_changed.emit()


func synchronize_world_time(authoritative_tick: int) -> void:
	var target := posmod(authoritative_tick, DAY_LENGTH_TICKS)
	var difference := posmod(target - world_time_tick + DAY_LENGTH_TICKS / 2, DAY_LENGTH_TICKS) - DAY_LENGTH_TICKS / 2
	if difference == 0:
		return
	var previous_tick := world_time_tick
	if absi(difference) > 180:
		world_time_tick = target
		daylight_changed.emit()
		return
	var correction := roundi(float(difference) * 0.35)
	if correction == 0:
		correction = signi(difference)
	world_time_tick = posmod(world_time_tick + correction, DAY_LENGTH_TICKS)
	if correction > 0 and _crossed_daylight_render_step(previous_tick, world_time_tick):
		daylight_changed.emit()


func _crossed_daylight_render_step(previous_tick: int, current_tick: int) -> bool:
	# Pixel-art terrain uses a handful of daylight steps. Rebuilding thousands of
	# interpolated shadow vertices every five seconds caused a visible cadence of
	# stalls on Android, while the continuously drawn sky already carries the
	# smooth day/night transition.
	var render_steps: Array[int] = [
		roundi(float(DAY_LENGTH_TICKS) * lerpf(DAY_END_PHASE, SUNSET_END_PHASE, 0.5)),
		roundi(float(DAY_LENGTH_TICKS) * SUNSET_END_PHASE),
		roundi(float(DAY_LENGTH_TICKS) * NIGHT_END_PHASE),
		roundi(float(DAY_LENGTH_TICKS) * lerpf(NIGHT_END_PHASE, 1.0, 0.5)),
		0,
	]
	for step_tick in render_steps:
		if previous_tick < current_tick:
			if step_tick > previous_tick and step_tick <= current_tick:
				return true
		elif step_tick > previous_tick or step_tick <= current_tick:
			return true
	return false


func world_day_phase() -> float:
	return float(world_time_tick) / float(DAY_LENGTH_TICKS)


func world_is_night() -> bool:
	var phase := world_day_phase()
	return phase > DAY_END_PHASE and phase <= NIGHT_END_PHASE


func world_daylight_factor() -> float:
	var phase := world_day_phase()
	var base := 1.0
	if phase <= DAY_END_PHASE:
		base = 1.0
	if phase < SUNSET_END_PHASE:
		base = lerpf(1.0, NIGHT_DAYLIGHT, smoothstep(DAY_END_PHASE, SUNSET_END_PHASE, phase))
	elif phase <= NIGHT_END_PHASE:
		base = NIGHT_DAYLIGHT
	elif phase > NIGHT_END_PHASE:
		base = lerpf(NIGHT_DAYLIGHT, 1.0, smoothstep(NIGHT_END_PHASE, 1.0, phase))
	var environment: Dictionary = active_biome_definition().get("environment", {})
	return clampf(base * float(environment.get("daylight_multiplier", 1.0)), NIGHT_DAYLIGHT * 0.45, 1.0)


func active_biome_definition() -> Dictionary:
	return _biome_definition(_ecology_biome_at(_player_center_tile()))


func active_location_biome_id() -> String:
	var pos := _player_center_tile()
	return _ecology_biome_at(pos)


func _player_center_tile() -> Vector2i:
	return Vector2i(
		floori((float(player.get("x", 0.0)) + float(player.get("w", 0.0)) * 0.5) / float(BlockDefs.TILE)),
		floori((float(player.get("y", 0.0)) + float(player.get("h", 0.0)) * 0.5) / float(BlockDefs.TILE))
	)


func _structure_id_at(pos: Vector2i) -> String:
	var chunk_x := floori(float(pos.x) / float(CHUNK_WIDTH))
	if not generated_chunks.has(chunk_x):
		return ""
	var chunk_data: Dictionary = generated_chunks[chunk_x]
	var placed_structures: Array = chunk_data.get("placed_structures", []) if chunk_data.get("placed_structures", []) is Array else []
	for raw_placed in placed_structures:
		if not raw_placed is Dictionary:
			continue
		var placed := raw_placed as Dictionary
		var bounds := Rect2i(
			Vector2i(int(placed.get("left", 0)) - 1, int(placed.get("top", 0)) - 1),
			Vector2i(int(placed.get("right", 0)) - int(placed.get("left", 0)) + 3, int(placed.get("bottom", 0)) - int(placed.get("top", 0)) + 3)
		)
		if bounds.has_point(pos):
			return str(placed.get("id", ""))
	if pos.y >= RESONANT_DEEP_TOP_Y:
		var deep_ids: Array = chunk_data.get("selected_resonant_structure_ids", []) if chunk_data.get("selected_resonant_structure_ids", []) is Array else []
		if not deep_ids.is_empty():
			return str(deep_ids[0])
	# Older saves know the owning chunk and structure ID, but not its exact bounds.
	# Keep their landmark titles useful while avoiding announcements deep underground.
	if placed_structures.is_empty() and absi(pos.y - _terrain_surface_y(pos.x)) <= 12:
		var builtin_id := str(chunk_data.get("builtin_structure_id", ""))
		if not builtin_id.is_empty():
			return builtin_id
		var selected_ids: Array = chunk_data.get("selected_structure_ids", []) if chunk_data.get("selected_structure_ids", []) is Array else []
		if not selected_ids.is_empty():
			return str(selected_ids[0])
	return ""


func _structure_definition_for_id(structure_id: String) -> Dictionary:
	if structure_definitions.has(structure_id):
		return (structure_definitions[structure_id] as Dictionary).duplicate(true)
	if SYSTEM_STRUCTURE_INFO.has(structure_id):
		var definition: Dictionary = (SYSTEM_STRUCTURE_INFO[structure_id] as Dictionary).duplicate(true)
		definition["structure_id"] = structure_id
		definition["kind"] = "structure"
		return definition
	return {}


func player_location_context() -> Dictionary:
	var biome_id := active_location_biome_id()
	var structure_id := _structure_id_at(_player_center_tile())
	return {
		"biome_id": biome_id,
		"biome": _biome_definition(biome_id).duplicate(true),
		"structure_id": structure_id,
		"structure": _structure_definition_for_id(structure_id),
	}


func creature_at_tile(tx: int, ty: int) -> String:
	for creature_id: String in creatures.keys():
		var creature: Dictionary = creatures[creature_id]
		if floori(float(creature.get("x", 0.0))) == tx and floori(float(creature.get("y", 0.0))) == ty:
			return creature_id
	return ""


func hit_creature(creature_id: String, damage: int = 1) -> bool:
	if not creatures.has(creature_id):
		return false
	var creature: Dictionary = creatures[creature_id]
	var definition := _creature_definition(str(creature.get("block_name", "")))
	creature["health"] = int(creature.get("health", 1)) - maxi(1, damage)
	creature["provoked_ticks"] = 60 * 12
	if str((definition.get("behavior", {}) as Dictionary).get("flee_trigger", "never")) == "on_hit":
		creature["flee_ticks"] = 60 * 10
	if int(creature["health"]) <= 0:
		var block_name := str(creature.get("block_name", ""))
		creatures.erase(creature_id)
		if "sapient" not in (definition.get("tags", []) as Array):
			give_to_inventory(block_name, 1)
			var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
			var visual: Dictionary = definition.get("visual", {}) if definition.get("visual", {}) is Dictionary else {}
			var locomotion: Dictionary = definition.get("locomotion", {}) if definition.get("locomotion", {}) is Dictionary else {}
			if "spider" in tags or "skitter" in block_name:
				var string_count := randi_range(0, 2)
				if string_count > 0:
					give_to_inventory("string", string_count)
			if "bird" in tags or "penguin" in block_name or str(visual.get("shape", "")) == "winged" or str(locomotion.get("type", "")) == "flying":
				var feather_count := randi_range(0, 2)
				if feather_count > 0:
					give_to_inventory("feather", feather_count)
			inventory_changed.emit()
	state_changed.emit()
	return true


func _is_soil(block: Dictionary) -> bool:
	var name: String = block.get("name", "")
	return name == "grass" or name == "dirt"


func _can_grow_into(x: int, y: int, want_id: int) -> bool:
	if not in_bounds(x, y):
		return false
	var block := get_block(x, y)
	if block["id"] == 0:
		return true
	var name: String = block.get("name", "")
	if want_id == BlockDefs.BLOCKS.wood.id and name == "leaves":
		return true
	return false


func _growth_ceiling(tx: int, from_y: int) -> int:
	var y: int = from_y - 1
	var scan_limit := from_y - TREE_CEILING_SCAN_BLOCKS
	while y >= scan_limit and in_bounds(tx, y):
		var block := get_block(tx, y)
		var name: String = block.get("name", "")
		if block["id"] == 0 or name == "wood" or name == "leaves":
			y -= 1
			continue
		return y
	return scan_limit


func _plant_block(x: int, y: int, id: int, ceiling_y: int = -2147483648) -> void:
	if y < ceiling_y:
		return
	if _can_grow_into(x, y, id):
		set_block(x, y, id)


func _ensure_soil_around(base_x: int, ground_y: int, radius: int) -> void:
	var dirt_id: int = BlockDefs.BLOCKS.dirt.id
	for dx in range(-radius, radius + 1):
		var x: int = base_x + dx
		if not in_bounds(x, ground_y):
			continue
		var cell := get_block(x, ground_y)
		if _is_soil(cell):
			continue
		if cell["id"] != 0:
			continue
		set_block(x, ground_y, dirt_id)
		var under := get_block(x, ground_y + 1)
		if under["id"] == 0:
			set_block(x, ground_y + 1, dirt_id)


func _pick_tree_size() -> int:
	var roll := randf()
	if roll < 0.4:
		return 0
	if roll < 0.78:
		return 1
	return 2


func _tree_definition_for_propagation_block(block_name: String) -> Dictionary:
	var content_id := BlockDefs.content_id_for_name(block_name)
	if content_id.is_empty():
		return {}
	for candidate_name: String in BlockDefs.BLOCKS:
		var definition := _plant_definition(candidate_name)
		if str((definition.get("growth", {}) as Dictionary).get("form", "")) != "tree":
			continue
		var propagation: Dictionary = definition.get("propagation", {}) if definition.get("propagation", {}) is Dictionary else {}
		var sources: Array = propagation.get("source_content_ids", []) if propagation.get("source_content_ids", []) is Array else []
		if content_id in sources:
			return definition
	return {}


func _try_start_tree_growth(tx: int, ty: int, block_name: String) -> void:
	var definition := _tree_definition_for_propagation_block(block_name)
	if definition.is_empty():
		return
	var support := get_block(tx, ty + 1)
	var planting: Dictionary = definition.get("planting", {}) if definition.get("planting", {}) is Dictionary else {}
	var allowed_tags: Array = planting.get("allowed_substrate_tags", []) if planting.get("allowed_substrate_tags", []) is Array else []
	if not support.get("solid", false) or (not allowed_tags.is_empty() and not _arrays_intersect(_semantic_tags(str(support.get("name", "air"))), allowed_tags)):
		return
	var names := _tree_component_block_names(definition)
	if names.is_empty():
		return
	var key := Vector2i(tx, ty)
	if tree_growth.has(key):
		return
	tree_growth[key] = {
		"step": 0,
		"size": _pick_tree_size(),
		"ceiling": _growth_ceiling(tx, ty),
		"trunk_block_name": str(names["trunk"]),
		"foliage_block_name": str(names["foliage"]),
		"tree_shape": str((definition.get("tree_components", {}) as Dictionary).get("shape", "oak")),
	}


func _advance_tree(key: Vector2i) -> void:
	if not tree_growth.has(key):
		return
	var data: Dictionary = tree_growth[key]
	var base := get_block(key.x, key.y)
	var base_name: String = base.get("name", "")
	var trunk_name := str(data.get("trunk_block_name", "wood"))
	var foliage_name := str(data.get("foliage_block_name", "leaves"))
	if base_name != trunk_name and base_name != foliage_name:
		tree_growth.erase(key)
		return

	if not data.has("ceiling"):
		data["ceiling"] = _growth_ceiling(key.x, key.y)

	var profile: Dictionary = TREE_SIZES[int(data["size"])]
	var tree_shape := str(data.get("tree_shape", "oak"))
	var ceiling_y: int = int(data["ceiling"])
	var trunk_h: int = mini(int(profile["trunk"]), maxi(1, key.y - ceiling_y))
	if tree_shape == "palm":
		trunk_h = mini(int(profile["trunk"]) + 2, maxi(1, key.y - ceiling_y))
	var top_y: int = key.y - (trunk_h - 1)
	var leaf_layers: int = mini(int(profile["leaf_layers"]), maxi(0, top_y - ceiling_y))
	if tree_shape == "palm": leaf_layers = mini(1, maxi(0, top_y - ceiling_y))
	elif tree_shape in ["pine", "weeping"]: leaf_layers = mini(3, maxi(0, top_y - ceiling_y))
	var leaf_r: int = int(profile["leaf_r"])
	var soil_r: int = int(profile["soil_r"])
	var step: int = int(data["step"]) + 1
	data["step"] = step

	_ensure_soil_around(key.x, key.y + 1, soil_r)

	if not BlockDefs.BLOCKS.has(trunk_name) or not BlockDefs.BLOCKS.has(foliage_name):
		tree_growth.erase(key)
		return
	var wood_id: int = int(BlockDefs.BLOCKS[trunk_name].id)
	var leaves_id: int = int(BlockDefs.BLOCKS[foliage_name].id)

	if step <= trunk_h:
		var wy: int = key.y - (step - 1)
		if wy < ceiling_y:
			tree_growth.erase(key)
			return
		if step == 1:
			set_block(key.x, key.y, wood_id)
		else:
			_plant_block(key.x, wy, wood_id, ceiling_y)
		if step == trunk_h and leaf_layers <= 0:
			tree_growth.erase(key)
		return

	var leaf_step: int = step - trunk_h
	if leaf_step > leaf_layers:
		tree_growth.erase(key)
		return

	var ly: int = top_y - leaf_step
	if ly < ceiling_y:
		tree_growth.erase(key)
		return
	var radius: int = leaf_r if leaf_step < leaf_layers else maxi(1, leaf_r - 1)
	if tree_shape == "pine":
		radius = maxi(1, leaf_r - (leaf_step - 1))
	elif tree_shape == "palm":
		radius = leaf_r + 1
	if tree_shape == "palm":
		for offset: Vector2i in _palm_crown_offsets(radius):
			_plant_block(key.x + offset.x, ly + offset.y, leaves_id, ceiling_y)
	else:
		for dx in range(-radius, radius + 1):
			for dy in range(-1, 2):
				if absi(dx) + absi(dy) > radius + 1:
					continue
				var trim_edge := (
					_structure_random("tree-edge:%d:%d:%d:%d" % [key.x, ly, dx, dy]) < 0.4
					if bool(data.get("natural_generation", false))
					else randf() < 0.4
				)
				if absi(dx) == radius and dy != 0 and trim_edge:
					continue
				_plant_block(key.x + dx, ly + dy, leaves_id, ceiling_y)
	if tree_shape == "weeping":
		for side in [-leaf_r, leaf_r]:
			_plant_block(key.x + side, ly + 1, leaves_id, ceiling_y)
			_plant_block(key.x + side, ly + 2, leaves_id, ceiling_y)
	if leaf_step == leaf_layers:
		_plant_block(key.x, top_y - leaf_layers - 1, leaves_id, ceiling_y)
		tree_growth.erase(key)


func harden_water_touching_lava() -> void:
	var water_id: int = BlockDefs.BLOCKS.water.id
	var lava_id: int = BlockDefs.BLOCKS.lava.id
	var stone_id: int = BlockDefs.BLOCKS.stone.id
	var flowing_lava_to_harden: Array[Vector2i] = []
	for lava_pos: Vector2i in _fluid_positions(lava_id):
		if get_fluid_level(lava_pos.x, lava_pos.y) <= 0:
			continue
		for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var neighbor: Vector2i = lava_pos + offset
			if in_bounds(neighbor.x, neighbor.y) and block_id(neighbor.x, neighbor.y) == water_id:
				flowing_lava_to_harden.append(lava_pos)
				break
	for lava_pos: Vector2i in flowing_lava_to_harden:
		set_block(lava_pos.x, lava_pos.y, stone_id)

	# Preserve the existing inverse reaction for flowing water touching a lava
	# source. Flowing lava has already hardened above, so water wins that contact.
	for pos in _fluid_positions(water_id):
		if get_fluid_level(pos.x, pos.y) == 0:
			continue
		var touches_lava := false
		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var nx: int = pos.x + offset.x
			var ny: int = pos.y + offset.y
			if in_bounds(nx, ny) and block_id(nx, ny) == lava_id:
				touches_lava = true
				break
		if touches_lava:
			set_block(pos.x, pos.y, stone_id)


func get_fluid_at_player() -> Dictionary:
	var cx := floori((float(player["x"]) + float(player["w"]) / 2.0) / float(BlockDefs.TILE))
	var cy := floori((float(player["y"]) + float(player["h"]) / 2.0) / float(BlockDefs.TILE))
	return get_block(cx, cy)


func get_fluid_flow_x_at_player() -> float:
	var cx := floori((float(player["x"]) + float(player["w"]) / 2.0) / float(BlockDefs.TILE))
	var cy := floori((float(player["y"]) + float(player["h"]) / 2.0) / float(BlockDefs.TILE))
	if not in_bounds(cx, cy):
		return 0.0
	var block := get_block(cx, cy)
	if not block.get("fluid", false):
		return 0.0
	if is_fluid_falling_at(cx, cy):
		return 0.0
	var level: int = get_fluid_level(cx, cy)
	if level == 0:
		return 0.0
	var best_source := level
	var flow := 0.0
	for dx in [-1, 1]:
		var nx: int = cx + dx
		if not in_bounds(nx, cy):
			continue
		if block_id(nx, cy) == block["id"] and not is_fluid_falling_at(nx, cy):
			var nlevel: int = get_fluid_level(nx, cy)
			if nlevel < best_source:
				best_source = nlevel
				flow = float(-dx)
			continue
		if block_id(nx, cy) != 0:
			continue
		if drop_distance_in(nx, cy) < drop_distance_in(cx, cy):
			if best_source >= level:
				flow = float(dx)
	return flow


func rect_overlap(ax: float, ay: float, aw: float, ah: float, bx: float, by: float, bw: float, bh: float) -> bool:
	return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


func is_tree_block(block: Dictionary) -> bool:
	var name: String = str(block.get("name", ""))
	var content_id := str(block.get("content_id", BlockDefs.content_id_for_name(name)))
	return name == "wood" or name == "leaves" or BlockDefs.tree_component_content_ids.has(content_id)


func is_shagot_passage_block(block: Dictionary) -> bool:
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	return str(block.get("name", "")) == "shagot_scaffold" or "passage" in tags


func is_tree_traversal_block(block: Dictionary) -> bool:
	return is_tree_block(block) or is_shagot_passage_block(block)


func _creature_can_pass_through_block(definition: Dictionary, block: Dictionary) -> bool:
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	return "shagot" in tags and is_tree_traversal_block(block)


func ignores_trees() -> bool:
	return bool(player.get("tree_ghost", false)) or bool(player.get("climbing", false))


func _block_solid_for_player(tx: int, ty: int, ignore_trees: bool = false) -> bool:
	var block := get_block(tx, ty)
	if not block.get("solid", false):
		return false
	# Shagot-built partitions use exactly the tree traversal model: they remain
	# solid until the player enters them from supported ground, then become a
	# climbable passage until the player leaves their footprint.
	if ignore_trees and is_tree_traversal_block(block):
		return false
	return true


func collides(px: float, py: float, pw: float, ph: float, skip_trees: Variant = null) -> Variant:
	var ignore_trees: bool = ignores_trees() if skip_trees == null else bool(skip_trees)
	var left := int(floor(px / BlockDefs.TILE))
	var right := int(floor((px + pw - 0.001) / BlockDefs.TILE))
	var top := int(floor(py / BlockDefs.TILE))
	var bottom := int(floor((py + ph - 0.001) / BlockDefs.TILE))
	var best: Variant = null
	var best_area := -1.0
	for ty in range(top, bottom + 1):
		for tx in range(left, right + 1):
			if not _block_solid_for_player(tx, ty, ignore_trees):
				continue
			var bx := float(tx * BlockDefs.TILE)
			var by := float(ty * BlockDefs.TILE)
			var overlap_w: float = minf(px + pw, bx + BlockDefs.TILE) - maxf(px, bx)
			var overlap_h: float = minf(py + ph, by + BlockDefs.TILE) - maxf(py, by)
			if overlap_w <= 0.0 or overlap_h <= 0.0:
				continue
			var area: float = overlap_w * overlap_h
			if area > best_area:
				best_area = area
				best = {"tx": tx, "ty": ty, "bx": bx, "by": by, "ow": overlap_w, "oh": overlap_h}
	return best


func find_ground_support(px: float, py: float, pw: float, ph: float) -> Variant:
	const SNAP := 1.5
	var feet := py + ph
	var foot_left := px + 3.0
	var foot_right := px + pw - 3.0
	var row := int(floor((feet + SNAP) / BlockDefs.TILE))
	var top: float = float(row * BlockDefs.TILE)
	if feet < top - 0.05 or feet > top + SNAP:
		return null
	var left := int(floor(foot_left / BlockDefs.TILE))
	var right := int(floor((foot_right - 0.001) / BlockDefs.TILE))
	var skip_trees := ignores_trees()
	for tx in range(left, right + 1):
		if not _block_solid_for_player(tx, row, skip_trees):
			continue
		var bx := float(tx * BlockDefs.TILE)
		if foot_right <= bx or foot_left >= bx + BlockDefs.TILE:
			continue
		return {"tx": tx, "ty": row, "bx": bx, "by": top}
	return null


func surface_physics(support: Variant) -> Dictionary:
	if support == null:
		return {"movement_speed_multiplier": 1.0, "friction": 1.0, "bounce": 0.0}
	var block := get_block(int(support["tx"]), int(support["ty"]))
	return {
		"movement_speed_multiplier": clampf(float(block.get("movement_speed_multiplier", 1.0)), 0.35, 1.75),
		"friction": clampf(float(block.get("friction", 1.0)), 0.0, 1.0),
		"bounce": clampf(float(block.get("bounce", 0.0)), 0.0, 1.0),
	}


func _player_overlaps_tree() -> bool:
	var x: float = player["x"]
	var y: float = player["y"]
	var left := int(floor(x / BlockDefs.TILE))
	var right := int(floor((x + player["w"] - 0.001) / BlockDefs.TILE))
	var top := int(floor(y / BlockDefs.TILE))
	var bottom := int(floor((y + player["h"] - 0.001) / BlockDefs.TILE))
	for ty in range(top, bottom + 1):
		for tx in range(left, right + 1):
			if is_tree_traversal_block(get_block(tx, ty)):
				return true
	return false


func _plant_cell_is_climbable(tx: int, ty: int) -> bool:
	var cell := Vector2i(tx, ty)
	if not plant_cells.has(cell):
		return false
	var anchor: Vector2i = plant_cells[cell]
	var data: Dictionary = plant_growth.get(anchor, {})
	var definition := _plant_definition(str(data.get("block_name", "")))
	var growth: Dictionary = definition.get("growth", {}) if definition.get("growth", {}) is Dictionary else {}
	return str(growth.get("form", "")) in ["hanging", "vertical_up", "vertical_down", "bidirectional_vertical"]


func _is_climb_hold(tx: int, ty: int) -> bool:
	return is_tree_traversal_block(get_block(tx, ty)) or _plant_cell_is_climbable(tx, ty)


func _player_overlaps_climbable_plant() -> bool:
	var left := int(floor(float(player["x"]) / BlockDefs.TILE))
	var right := int(floor((float(player["x"]) + float(player["w"]) - 0.001) / BlockDefs.TILE))
	var top := int(floor(float(player["y"]) / BlockDefs.TILE))
	var bottom := int(floor((float(player["y"]) + float(player["h"]) - 0.001) / BlockDefs.TILE))
	for ty in range(top, bottom + 1):
		for tx in range(left, right + 1):
			if _plant_cell_is_climbable(tx, ty):
				return true
	return false


func _player_overlaps_climb_hold() -> bool:
	return _player_overlaps_tree() or _player_overlaps_climbable_plant()


func _side_tree_hit(dir: float) -> Variant:
	if dir == 0.0:
		return null
	var probe: float = 3.0
	var nx: float = player["x"] + (probe if dir > 0.0 else -probe)
	var hit: Variant = collides(nx, player["y"], player["w"], player["h"], false)
	if hit == null:
		return null
	if not is_tree_traversal_block(get_block(hit["tx"], hit["ty"])):
		return null
	return hit


func _nearest_climb_col() -> int:
	var cx := int((player["x"] + player["w"] * 0.5) / BlockDefs.TILE)
	var best := cx
	var best_dist := 999
	# A tree can be grabbed while touching its side, but never from one or two
	# empty cells away. Plants require the same narrow body-contact envelope.
	var grab_margin := 3.0
	var left := int(floor((float(player["x"]) - grab_margin) / BlockDefs.TILE))
	var right := int(floor((float(player["x"]) + float(player["w"]) + grab_margin - 0.001) / BlockDefs.TILE))
	var top := int(floor(float(player["y"]) / BlockDefs.TILE))
	var bottom := int(floor((float(player["y"]) + float(player["h"]) - 0.001) / BlockDefs.TILE))
	for tx in range(left, right + 1):
		for ty in range(top, bottom + 1):
			if _is_climb_hold(tx, ty):
				var dist: int = absi(tx - cx)
				if dist < best_dist:
					best_dist = dist
					best = tx
				break
	return best


func _has_climb_hold(col: int) -> bool:
	var top := int(floor(player["y"] / BlockDefs.TILE))
	var bottom := int(floor((player["y"] + player["h"] - 0.001) / BlockDefs.TILE))
	for ty in range(top, bottom + 1):
		if _is_climb_hold(col, ty):
			return true
	return false


func _player_has_climb_contact(col: int) -> bool:
	var grab_margin := 3.0
	var col_left := float(col * BlockDefs.TILE)
	var col_right := col_left + BlockDefs.TILE
	var player_left := float(player["x"]) - grab_margin
	var player_right := float(player["x"]) + float(player["w"]) + grab_margin
	return player_right > col_left and player_left < col_right and _has_climb_hold(col)


func _update_tree_state(jump: bool, grounded: bool) -> void:
	if not player["tree_ghost"]:
		if grounded and player["vx"] != 0.0:
			var hit: Variant = _side_tree_hit(player["vx"])
			if hit != null:
				player["tree_ghost"] = true
		# Non-solid vines and stalks can be grabbed from inside their cell. Trees
		# still require the collision path above; a nearby trunk must not enable
		# climbing through an empty column of air.
		if jump and _player_overlaps_climbable_plant():
			player["tree_ghost"] = true
	elif not player["climbing"] and not _player_overlaps_climb_hold() and _side_tree_hit(player["vx"]) == null and not _player_has_climb_contact(_nearest_climb_col()):
		player["tree_ghost"] = false

	if player["climbing"]:
		var locked_col := int(player.get("climb_col", -1))
		if locked_col < 0:
			locked_col = _nearest_climb_col()
			player["climb_col"] = locked_col
		if not jump or not _player_has_climb_contact(locked_col):
			player["climbing"] = false
			player["climb_col"] = -1
			player["vx"] = 0.0
			player["vy"] = 0.0
	elif player["tree_ghost"] and jump and _player_has_climb_contact(_nearest_climb_col()):
		player["climb_col"] = _nearest_climb_col()
		player["climbing"] = true
		player["vx"] = 0.0
		player["on_ground"] = false
		player["jump_coyote"] = 0.0


func _resolve_x(nx: float) -> float:
	var hit: Variant = collides(nx, player["y"], player["w"], player["h"])
	if hit == null:
		return nx
	if player["vx"] > 0.0:
		return hit["bx"] - player["w"]
	if player["vx"] < 0.0:
		return hit["bx"] + BlockDefs.TILE
	var mid: float = player["x"] + player["w"] * 0.5
	if mid < hit["bx"] + BlockDefs.TILE * 0.5:
		return hit["bx"] - player["w"]
	return hit["bx"] + BlockDefs.TILE


func _resolve_y(ny: float) -> Dictionary:
	var hit: Variant = collides(player["x"], ny, player["w"], player["h"])
	if hit == null:
		return {"y": ny, "grounded": false, "ceiling": false}

	var prev_feet: float = player["y"] + player["h"]
	var from_above: bool = prev_feet <= hit["by"] + 1.5
	var from_below: bool = player["y"] >= hit["by"] + BlockDefs.TILE - 1.5

	if from_above and player["vy"] >= 0.0:
		return {"y": hit["by"] - player["h"], "grounded": true, "ceiling": false}
	if from_below and player["vy"] <= 0.0:
		return {"y": hit["by"] + BlockDefs.TILE, "grounded": false, "ceiling": true}

	var mid: float = player["x"] + player["w"] * 0.5
	if mid < hit["bx"] + BlockDefs.TILE * 0.5:
		player["x"] = hit["bx"] - player["w"]
	else:
		player["x"] = hit["bx"] + BlockDefs.TILE

	hit = collides(player["x"], ny, player["w"], player["h"])
	if hit == null:
		return {"y": ny, "grounded": false, "ceiling": false}
	if player["vy"] > 0.0:
		return {"y": hit["by"] - player["h"], "grounded": true, "ceiling": false}
	if player["vy"] < 0.0:
		return {"y": hit["by"] + BlockDefs.TILE, "grounded": false, "ceiling": true}
	return {"y": player["y"], "grounded": false, "ceiling": false}


func _ease_to_ground(target_y: float, step: float) -> void:
	var diff: float = target_y - player["y"]
	if absf(diff) < 0.35:
		player["y"] = target_y
		return
	var max_step := 5.0 * step
	player["y"] += clampf(diff, -max_step, max_step)
	if absf(target_y - player["y"]) < 0.35:
		player["y"] = target_y


func _damage_player_from_harmful_fluid() -> void:
	if int(player.get("health", MAX_PLAYER_HEALTH)) <= 0:
		return
	player["health"] = maxi(0, int(player.get("health", MAX_PLAYER_HEALTH)) - 1)
	Sfx.hurt()
	if int(player["health"]) <= 0:
		player_defeated.emit()


func _player_touches_harmful_fluid() -> bool:
	var left := floori(float(player["x"]) / float(BlockDefs.TILE))
	var right := floori((float(player["x"]) + float(player["w"]) - 0.001) / float(BlockDefs.TILE))
	var top := floori(float(player["y"]) / float(BlockDefs.TILE))
	var bottom := floori((float(player["y"]) + float(player["h"]) - 0.001) / float(BlockDefs.TILE))
	for ty in range(top, bottom + 1):
		for tx in range(left, right + 1):
			var block := get_block(tx, ty)
			if block.get("fluid", false) and float(block.get("temperature", 1.0 if block.get("name", "") == "lava" else 0.0)) >= 0.8:
				return true
	return false


func _update_harmful_fluid_contact(in_harmful_fluid: bool) -> void:
	if in_harmful_fluid and (not _player_was_in_harmful_fluid or _harmful_fluid_damage_cooldown <= 0.0):
		_damage_player_from_harmful_fluid()
		_harmful_fluid_damage_cooldown = 20.0 / 60.0
	_player_was_in_harmful_fluid = in_harmful_fluid


func move_player(move_left: bool, move_right: bool, jump: bool, delta: float = 1.0 / 60.0) -> void:
	var movement_origin_x := float(player["x"])
	var jumped_this_step := false
	var step := delta * 60.0
	player["squash"] = maxf(0.0, float(player["squash"]) - step * 0.22)
	var fluid := get_fluid_at_player()
	var in_water: bool = fluid.get("name", "") == "water"
	var in_lava: bool = fluid.get("name", "") == "lava"
	var in_fluid: bool = bool(fluid.get("fluid", false))
	var fluid_viscosity := clampf(float(fluid.get("viscosity", 0.08 if in_water else (0.92 if in_lava else 0.3))), 0.0, 1.0)
	var support: Variant = find_ground_support(player["x"], player["y"], player["w"], player["h"])
	var surface := surface_physics(support)
	var surface_speed := float(surface["movement_speed_multiplier"]) if not in_fluid else 1.0
	var fluid_speed_multiplier := lerpf(0.62, 0.32, fluid_viscosity)
	var move_speed := BlockDefs.MOVE * (fluid_speed_multiplier if in_fluid else surface_speed) * active_movement_multiplier()
	var gravity := BlockDefs.GRAVITY * (lerpf(0.32, 0.55, fluid_viscosity) if in_fluid else 1.0)
	var jump_power := BlockDefs.JUMP
	if in_fluid:
		jump_power = BlockDefs.JUMP * lerpf(0.56, 0.44, fluid_viscosity)
	jump_power *= active_jump_multiplier()
	var max_fall := lerpf(6.5, 4.5, fluid_viscosity) if in_fluid else 12.0

	var target_vx := 0.0
	if move_left:
		target_vx = -move_speed
		player["facing"] = -1
	if move_right:
		target_vx = move_speed
		player["facing"] = 1
	if in_fluid:
		player["vx"] = target_vx
		var flow_x: float = get_fluid_flow_x_at_player()
		var current: float = float(fluid.get("current_strength", lerpf(0.2, 0.1, fluid_viscosity)))
		player["vx"] += flow_x * current
	elif support != null:
		player["vx"] = lerpf(float(player["vx"]), target_vx, clampf(float(surface["friction"]) * step, 0.0, 1.0))
	else:
		player["vx"] = target_vx

	var was_on_ground: bool = player["on_ground"]
	var grounded: bool = support != null and player["vy"] >= -0.05
	_update_tree_state(jump, was_on_ground or grounded)

	var can_jump: bool = (
		not player["climbing"]
		and (was_on_ground or grounded or player["jump_coyote"] > 0.0 or in_fluid)
		and player["vy"] >= -0.05
	)

	if player["climbing"]:
		# Keep the horizontal position from which the player grabbed the tree.
		# Centering on the trunk made approaching from the left look like a
		# persistent push to the right while climbing.
		player["vx"] = 0.0
		player["vy"] = TREE_CLIMB_SPEED * active_movement_multiplier()
		player["on_ground"] = false
		grounded = false
	elif jump and can_jump:
		jumped_this_step = true
		player["vy"] = jump_power
		player["on_ground"] = false
		player["jump_coyote"] = 0.0
		grounded = false
		Sfx.jump()

	if player["climbing"]:
		pass
	elif grounded:
		player["vy"] = 0.0
	else:
		player["vy"] += gravity * step
		if player["vy"] > max_fall:
			player["vy"] = max_fall

	_harmful_fluid_damage_cooldown = maxf(0.0, _harmful_fluid_damage_cooldown - delta)
	_update_harmful_fluid_contact(_player_touches_harmful_fluid())

	var speed: float = maxf(absf(player["vx"]), absf(player["vy"])) * step
	var substeps: int = maxi(1, int(ceil(speed / 6.0)))
	var sub: float = step / float(substeps)
	if not player["climbing"]:
		player["on_ground"] = false

	for _i in substeps:
		if player["vx"] != 0.0 and not player["climbing"]:
			player["x"] = _resolve_x(player["x"] + player["vx"] * sub)
			var stuck: Variant = collides(player["x"], player["y"], player["w"], player["h"])
			if stuck != null:
				player["x"] = _resolve_x(player["x"])

		var next_y: float = player["y"] + player["vy"] * sub
		var y_hit := _resolve_y(next_y)
		if y_hit["grounded"]:
			var impact_vy: float = float(player["vy"])
			if player["vy"] > 4.0:
				Sfx.land()
				player["squash"] = 1.0
			player["y"] = y_hit["y"]
			var landed_surface := surface_physics(find_ground_support(player["x"], player["y"], player["w"], player["h"]))
			var rebound := float(landed_surface["bounce"])
			if rebound > 0.0 and impact_vy > 1.0:
				player["vy"] = -maxf(impact_vy * rebound, absf(BlockDefs.JUMP) * rebound * 0.6)
				player["on_ground"] = false
			else:
				player["vy"] = 0.0
				player["on_ground"] = true
			player["climbing"] = false
		elif y_hit["ceiling"]:
			player["y"] = y_hit["y"]
			player["vy"] = 0.0
			player["climbing"] = false
		else:
			player["y"] = y_hit["y"]

	# Movement can enter lava after the pre-step contact check. Apply the entry
	# event in this same frame so a quick jump out cannot skip the damage window.
	_update_harmful_fluid_contact(_player_touches_harmful_fluid())

	if player["on_ground"]:
		support = find_ground_support(player["x"], player["y"], player["w"], player["h"])
		if support:
			player["y"] = support["by"] - player["h"]
	elif player["vy"] == 0.0 and not player["climbing"]:
		support = find_ground_support(player["x"], player["y"], player["w"], player["h"])
		if support:
			_ease_to_ground(support["by"] - player["h"], step)
			player["on_ground"] = true

	var fall_reset_tile_y := RESONANT_DEEP_BOTTOM_Y + FALL_RESET_DEPTH if _world_supports_resonant_deep() else ISLAND_CY + FALL_RESET_DEPTH
	if player["y"] > float(fall_reset_tile_y * BlockDefs.TILE):
		Sfx.hurt()
		if world_mode == WORLD_MODE_DUEL:
			if int(player.get("health", MAX_PLAYER_HEALTH)) > 0:
				player["health"] = 0
				player_defeated.emit()
		else:
			reset_player()

	if player["on_ground"]:
		player["jump_coyote"] = 8.0
	else:
		player["jump_coyote"] = maxf(0.0, player["jump_coyote"] - step)

	if player["tree_ghost"] and not player["climbing"] and not _player_overlaps_climb_hold() and _side_tree_hit(player["vx"]) == null and not _player_has_climb_contact(_nearest_climb_col()):
		player["tree_ghost"] = false
	elif player["climbing"]:
		player["tree_ghost"] = true
	_wear_equipped_footwear(minf(absf(float(player["x"]) - movement_origin_x) / float(BlockDefs.TILE), 1.0), jumped_this_step)
	_update_challenge_progress()


const REACH := BlockDefs.TILE * 4.5


func player_near(tx: int, ty: int) -> bool:
	var px: float = player["x"] + player["w"] / 2.0
	var py: float = player["y"] + player["h"] / 2.0
	var bx := tx * BlockDefs.TILE + BlockDefs.TILE / 2.0
	var by := ty * BlockDefs.TILE + BlockDefs.TILE / 2.0
	return Vector2(px, py).distance_to(Vector2(bx, by)) < REACH


func player_in_combat_range(tx: int, ty: int) -> bool:
	var px: float = player["x"] + player["w"] / 2.0
	var py: float = player["y"] + player["h"] / 2.0
	var bx := tx * BlockDefs.TILE + BlockDefs.TILE / 2.0
	var by := ty * BlockDefs.TILE + BlockDefs.TILE / 2.0
	return Vector2(px, py).distance_to(Vector2(bx, by)) < COMBAT_REACH


func raycast_from_player(aim_world: Vector2) -> Dictionary:
	var px: float = player["x"] + player["w"] / 2.0
	var py: float = player["y"] + player["h"] / 2.0
	var origin := Vector2(px, py)
	var delta := aim_world - origin
	var dist := delta.length()
	if dist < 4.0:
		return {}
	var dir := delta / dist
	var max_dist := minf(dist, REACH)
	var step := BlockDefs.TILE * 0.25
	var prev_tile := Vector2i(-999999, -999999)
	var last_air := Vector2i.ZERO
	var has_last_air := false
	var t := 0.0

	while t <= max_dist:
		var pos := origin + dir * t
		var tile := Vector2i(int(floor(pos.x / BlockDefs.TILE)), int(floor(pos.y / BlockDefs.TILE)))
		if tile != prev_tile and in_bounds(tile.x, tile.y):
			var block := get_block(tile.x, tile.y)
			if not plant_block_at(tile.x, tile.y).is_empty():
				return {"mine": tile, "place": last_air} if has_last_air else {"mine": tile}
			if block.get("solid", false) or block.get("fluid", false):
				var result := {"mine": tile}
				if has_last_air:
					result["place"] = last_air
				return result
			if block["id"] == 0:
				last_air = tile
				has_last_air = true
			prev_tile = tile
		t += step

	if has_last_air and player_near(last_air.x, last_air.y):
		return {"place": last_air}
	return {}


func can_place_block(tx: int, ty: int) -> bool:
	var block := get_block(tx, ty)
	if not player_near(tx, ty):
		return false
	if not BlockDefs.BLOCKS.has(selected):
		return false
	if inventory.get(selected, 0) <= 0:
		return false

	var type: Dictionary = BlockDefs.BLOCKS[selected]
	if type.get("item", false):
		return false
	if type.get("creature_item", false):
		return _creature_position_matches(Vector2(tx + 0.5, ty + 0.5), _creature_definition(selected))
	if type.get("plant", false):
		return can_plant_at(selected, tx, ty)
	var can_replace_fluid: bool = not type.get("fluid", false) and block.get("fluid", false)
	if block["id"] != 0 and not can_replace_fluid:
		return false

	var bx := tx * BlockDefs.TILE
	var by := ty * BlockDefs.TILE
	if not type.get("fluid", false):
		if rect_overlap(player["x"], player["y"], player["w"], player["h"], bx, by, BlockDefs.TILE, BlockDefs.TILE):
			return false
	return true


func get_block_hardness(block: Dictionary) -> int:
	return block.get("hardness", 15)


func equipment_slot_for_item(block_name: String) -> String:
	if block_name.is_empty() or not BlockDefs.BLOCKS.has(block_name):
		return ""
	var entry: Dictionary = BlockDefs.BLOCKS[block_name]
	if not entry.get("item", false):
		return ""
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	match str(definition.get("category", "")):
		"mobility_tool": return "feet"
		"mining_tool", "weapon", "hybrid": return "hand"
		_: return ""


func item_max_durability(block_name: String) -> int:
	var entry: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	if not entry.get("item", false) or equipment_slot_for_item(block_name).is_empty():
		return 0
	var durability: Dictionary = definition.get("durability", {}) if definition.get("durability", {}) is Dictionary else {}
	if int(durability.get("max_uses", 0)) > 0:
		return clampi(int(durability.get("max_uses", 1)), 1, 2000)
	match str(definition.get("rarity", "common")):
		"uncommon": return 144
		"rare": return 224
		"epic": return 320
		"legendary": return 480
		_: return 96


func item_durability_remaining(block_name: String) -> int:
	var maximum := item_max_durability(block_name)
	if maximum <= 0:
		return 0
	var values: Array = item_durability.get(block_name, []) if item_durability.get(block_name, []) is Array else []
	return clampi(int(values[0]), 0, maximum) if not values.is_empty() else maximum


func _normalize_item_durability(block_name: String) -> void:
	var maximum := item_max_durability(block_name)
	if maximum <= 0:
		item_durability.erase(block_name)
		return
	var wanted := maxi(0, int(inventory.get(block_name, 0)))
	var values: Array = item_durability.get(block_name, []) if item_durability.get(block_name, []) is Array else []
	var normalized: Array[int] = []
	for raw_value in values:
		if normalized.size() >= wanted:
			break
		normalized.append(clampi(int(raw_value), 1, maximum))
	while normalized.size() < wanted:
		normalized.append(maximum)
	if normalized.is_empty():
		item_durability.erase(block_name)
	else:
		item_durability[block_name] = normalized


func damage_equipped_item(slot_name: String, amount: int = 1) -> bool:
	var block_name := equipped_item_name(slot_name)
	var maximum := item_max_durability(block_name)
	if block_name.is_empty() or maximum <= 0 or amount <= 0:
		return false
	_normalize_item_durability(block_name)
	var values: Array = item_durability.get(block_name, [])
	if values.is_empty():
		return false
	var remaining_damage := amount
	var broke := false
	while remaining_damage > 0 and not values.is_empty():
		var current := int(values[0])
		if remaining_damage < current:
			values[0] = current - remaining_damage
			remaining_damage = 0
		else:
			remaining_damage -= current
			values.pop_front()
			inventory[block_name] = int(inventory.get(block_name, 0)) - 1
			broke = true
	if int(inventory.get(block_name, 0)) <= 0:
		inventory.erase(block_name)
		inv_order.erase(block_name)
		item_durability.erase(block_name)
		for index in hotbar_slots.size():
			if hotbar_slots[index] == block_name:
				hotbar_slots[index] = ""
		_clear_equipment_reference(block_name)
		if craft_pick == block_name:
			craft_pick = ""
		if selected == block_name:
			_reselect_after_remove()
	else:
		item_durability[block_name] = values
	if broke:
		Sfx.tool_break()
	inventory_changed.emit()
	state_changed.emit()
	return broke


func _footwear_distance_per_use(block_name: String) -> float:
	var entry: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	var durability: Dictionary = definition.get("durability", {}) if definition.get("durability", {}) is Dictionary else {}
	return clampf(float(durability.get("distance_per_use", 8.0)), 1.0, 64.0)


func _wear_equipped_footwear(distance_blocks: float, jumped: bool) -> void:
	var block_name := equipped_item_name("feet")
	if block_name.is_empty():
		return
	footwear_wear_distance += maxf(0.0, distance_blocks)
	var wear := 1 if jumped else 0
	var distance_per_use := _footwear_distance_per_use(block_name)
	while footwear_wear_distance >= distance_per_use:
		footwear_wear_distance -= distance_per_use
		wear += 1
	if wear > 0:
		damage_equipped_item("feet", wear)


func equipped_item_name(slot_name: String) -> String:
	var block_name := str(equipment_slots.get(slot_name, ""))
	return block_name if inventory.get(block_name, 0) > 0 else ""


func equipped_item_definition(slot_name: String) -> Dictionary:
	var block_name := equipped_item_name(slot_name)
	if block_name.is_empty() or not BlockDefs.BLOCKS.has(block_name):
		return {}
	var entry: Dictionary = BlockDefs.BLOCKS[block_name]
	if not entry.get("item", false):
		return {}
	return entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}


func active_item_definition() -> Dictionary:
	return equipped_item_definition("hand")


func active_mining_multiplier() -> float:
	var definition := equipped_item_definition("hand")
	if definition.is_empty():
		return 1.0
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return clampf(float(effects.get("mining_speed_multiplier", 1.0)), 1.0, 12.0)


func active_harvest_tier() -> int:
	return item_harvest_tier(equipped_item_name("hand"))


func item_harvest_tier(block_name: String) -> int:
	var entry: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	if definition.is_empty() or str(definition.get("category", "")) != "mining_tool":
		return 0
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return clampi(int(effects.get("harvest_tier", 0)), 0, 6)


func block_harvest_tier(block: Dictionary) -> int:
	if block.is_empty() or bool(block.get("item", false)) or bool(block.get("plant", false)) or bool(block.get("fluid", false)):
		return 0
	if block.has("harvest_tier"):
		return clampi(int(block.get("harvest_tier", 0)), 0, 6)
	var definition: Dictionary = block.get("definition", {}) if block.get("definition", {}) is Dictionary else {}
	var tags: Array = definition.get("tags", []) if definition.get("tags", []) is Array else []
	if "obsidian" in tags:
		return 4
	if "rare" in tags and ("ore" in tags or "crystal" in tags or "mineral" in tags):
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


func can_harvest_block(block: Dictionary) -> bool:
	if not Analytics.release_flag_bool("harvest_tiers_enabled", true):
		return true
	return active_harvest_tier() >= block_harvest_tier(block)


func active_weapon_damage() -> int:
	var definition := equipped_item_definition("hand")
	if definition.is_empty():
		return 1
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return clampi(int(effects.get("creature_damage", 1)), 1, 5)


func is_bow_equipped() -> bool:
	return equipped_item_name("hand") == "bow"


func arrow_count() -> int:
	return maxi(0, int(inventory.get("arrow", 0)))


func consume_arrow_and_damage_bow() -> bool:
	if not is_bow_equipped() or arrow_count() <= 0:
		return false
	if not take_from_inventory("arrow"):
		return false
	damage_equipped_item("hand")
	return true


func active_movement_multiplier() -> float:
	var definition := equipped_item_definition("feet")
	if definition.is_empty():
		return 1.0
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return clampf(float(effects.get("movement_speed_multiplier", 1.0)), 1.0, 1.6)


func active_jump_multiplier() -> float:
	var definition := equipped_item_definition("feet")
	if definition.is_empty():
		return 1.0
	var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
	return clampf(float(effects.get("jump_power_multiplier", 1.0)), 1.0, 1.4)


func _common_chest_gear_pool() -> Array[String]:
	var candidates: Array[String] = []
	var stone_definition: Dictionary = BlockDefs.BLOCKS.get("stone_pickaxe", {}).get("definition", {})
	var boots_definition: Dictionary = BlockDefs.BLOCKS.get("trail_boots", {}).get("definition", {})
	var stone_effects: Dictionary = stone_definition.get("effects", {})
	var boots_effects: Dictionary = boots_definition.get("effects", {})
	var effect_caps := {
		"mining_speed_multiplier": maxf(float(stone_effects.get("mining_speed_multiplier", 1.0)), float(boots_effects.get("mining_speed_multiplier", 1.0))),
		"creature_damage": maxi(int(stone_effects.get("creature_damage", 1)), int(boots_effects.get("creature_damage", 1))),
		"movement_speed_multiplier": maxf(float(stone_effects.get("movement_speed_multiplier", 1.0)), float(boots_effects.get("movement_speed_multiplier", 1.0))),
		"jump_power_multiplier": maxf(float(stone_effects.get("jump_power_multiplier", 1.0)), float(boots_effects.get("jump_power_multiplier", 1.0))),
	}
	for raw_name in BlockDefs.BLOCKS.keys():
		var block_name := str(raw_name)
		var entry: Dictionary = BlockDefs.BLOCKS[block_name]
		var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
		if not entry.get("item", false) or str(definition.get("kind", "")) != "item":
			continue
		var content_id := str(definition.get("content_id", BlockDefs.content_id_for_name(block_name)))
		if not content_id.begins_with(CORE_CONTENT_PREFIX) and not world_definition_ids.has(content_id):
			continue
		var effects: Dictionary = definition.get("effects", {}) if definition.get("effects", {}) is Dictionary else {}
		# Structure chests may use generated/LLM equipment, but never anything
		# stronger than the basic stone pickaxe and trail boots on any axis.
		if float(effects.get("mining_speed_multiplier", 1.0)) > float(effect_caps["mining_speed_multiplier"]):
			continue
		if int(effects.get("creature_damage", 1)) > int(effect_caps["creature_damage"]):
			continue
		if float(effects.get("movement_speed_multiplier", 1.0)) > float(effect_caps["movement_speed_multiplier"]):
			continue
		if float(effects.get("jump_power_multiplier", 1.0)) > float(effect_caps["jump_power_multiplier"]):
			continue
		candidates.append(block_name)
	# A stable order keeps unopened chest loot deterministic for a given catalog
	# and world seed, regardless of dictionary insertion order.
	candidates.sort_custom(func(a: String, b: String) -> bool:
		return BlockDefs.content_id_for_name(a) < BlockDefs.content_id_for_name(b)
	)
	return candidates


func _generate_chest_loot(pos: Vector2i) -> void:
	if not containers.has(pos):
		return
	var data: Dictionary = containers[pos]
	if bool(data.get("loot_generated", true)):
		return
	var loot_key := str(data.get("loot_key", "%d:%d" % [pos.x, pos.y]))
	var tier_roll := _structure_random("chest-tier:%s" % loot_key)
	var tier := "empty"
	var contents: Dictionary = {}
	if tier_roll >= CHEST_EMPTY_CHANCE and tier_roll < CHEST_EMPTY_CHANCE + CHEST_BLOCK_LOOT_CHANCE:
		tier = "blocks"
		var pool: Array[String] = ["leaves", "sand", "gravel", "dirt", "cobblestone", "wood", "planks", "charcoal", "ice"]
		var stack_count := 1 + int(_structure_random("chest-stack-count:%s" % loot_key) * 3.0)
		for stack_index in stack_count:
			var item_index := int(_structure_random("chest-block-kind:%s:%d" % [loot_key, stack_index]) * float(pool.size())) % pool.size()
			var block_name := pool[item_index]
			var amount := 1 + int(_structure_random("chest-block-count:%s:%d" % [loot_key, stack_index]) * 4.0)
			contents[block_name] = int(contents.get(block_name, 0)) + amount
	elif tier_roll >= CHEST_EMPTY_CHANCE + CHEST_BLOCK_LOOT_CHANCE:
		tier = "common_gear"
		var gear_pool := _common_chest_gear_pool()
		if not gear_pool.is_empty():
			var gear_index := int(_structure_random("chest-gear:%s" % loot_key) * float(gear_pool.size())) % gear_pool.size()
			contents[gear_pool[gear_index]] = 1
	var durability: Dictionary = {}
	# Preserve the single-item common-gear chest contract: 8.5% of gear rolls
	# become a damaged bow instead of adding a second item.
	if tier == "common_gear" and _structure_random("chest-bow:%s" % loot_key) < STRUCTURE_CHEST_BOW_CHANCE:
		contents.clear()
		contents["bow"] = 1
		var bow_max := item_max_durability("bow")
		var bow_remaining := 1 + int(_structure_random("chest-bow-durability:%s" % loot_key) * float(maxi(1, bow_max / 4)))
		durability["bow"] = [clampi(bow_remaining, 1, bow_max)]
	data["contents"] = contents
	data["durability"] = durability
	data["loot_generated"] = true
	data["loot_tier"] = tier
	containers[pos] = data


func container_is_open() -> bool:
	return containers.has(open_container_pos) and get_block(open_container_pos.x, open_container_pos.y).get("container", false)


func is_death_cache_at(tx: int, ty: int) -> bool:
	var data: Variant = containers.get(Vector2i(tx, ty), null)
	return data is Dictionary and bool((data as Dictionary).get("death_cache", false))


func is_one_use_cache_at(tx: int, ty: int) -> bool:
	var data: Variant = containers.get(Vector2i(tx, ty), null)
	return data is Dictionary and bool((data as Dictionary).get("one_use_cache", false))


func recover_one_use_cache(pos: Vector2i) -> bool:
	if not containers.has(pos) or not get_block(pos.x, pos.y).get("container", false):
		return false
	var cache: Dictionary = containers[pos]
	if not bool(cache.get("one_use_cache", false)):
		return false
	_generate_chest_loot(pos)
	cache = containers[pos]
	var contents: Dictionary = cache.get("contents", {}) if cache.get("contents", {}) is Dictionary else {}
	var durability: Dictionary = cache.get("durability", {}) if cache.get("durability", {}) is Dictionary else {}
	var item_count := 0
	for block_name: String in contents:
		var amount := maxi(0, int(contents[block_name]))
		if amount <= 0:
			continue
		var values: Array = durability.get(block_name, []) if durability.get(block_name, []) is Array else []
		give_to_inventory(block_name, amount, values)
		item_count += amount
	var trap_kind := str(cache.get("trap_kind", ""))
	var trap_armed := bool(cache.get("trap_armed", false))
	containers.erase(pos)
	set_block(pos.x, pos.y, 0)
	if trap_armed:
		_release_one_use_cache_trap(pos, cache)
	if open_container_pos == pos:
		open_container_pos = Vector2i(COORD_LIMIT + 1, COORD_LIMIT + 1)
		craft_open = false
	one_use_cache_recovered.emit(pos, trap_kind, item_count)
	inventory_changed.emit()
	state_changed.emit()
	return true


func _release_one_use_cache_trap(pos: Vector2i, cache: Dictionary) -> void:
	# Armed caches keep their payload implicit until recovery. Sand cannot slide
	# around the chest and fluids cannot reveal themselves before the decision.
	var trap_kind := str(cache.get("trap_kind", ""))
	var includes_sand := trap_kind in ["sand", "sand_water", "sand_lava"]
	var fluid_name := "water" if trap_kind in ["water", "sand_water"] else ("lava" if trap_kind in ["lava", "sand_lava"] else "")
	var stored_sand_count := maxi(0, int(cache.get("trap_sand_count", 0)))
	var sand_count := stored_sand_count if stored_sand_count > 0 else (4 if includes_sand else 0)
	var gravel_count := maxi(0, int(cache.get("trap_gravel_count", 0)))
	var granular_count := 0
	if includes_sand:
		for _gravel in gravel_count:
			set_block(pos.x, pos.y - granular_count, int(BlockDefs.BLOCKS.gravel.id))
			granular_count += 1
		for _sand in sand_count:
			set_block(pos.x, pos.y - granular_count, int(BlockDefs.BLOCKS.sand.id))
			granular_count += 1
	if not fluid_name.is_empty():
		var fluid_y := pos.y - granular_count if includes_sand else pos.y
		set_block(pos.x, fluid_y, int(BlockDefs.BLOCKS[fluid_name].id), 0, true)


func container_contents() -> Dictionary:
	if not container_is_open():
		return {}
	_generate_chest_loot(open_container_pos)
	return ((containers[open_container_pos] as Dictionary).get("contents", {}) as Dictionary).duplicate(true)


func try_open_chest(tx: int, ty: int) -> bool:
	var pos := Vector2i(tx, ty)
	if not player_near(tx, ty) or not get_block(tx, ty).get("container", false):
		return false
	if containers.has(pos) and bool((containers[pos] as Dictionary).get("death_cache", false)):
		Sfx.chest_open()
		return recover_death_cache(pos)
	if containers.has(pos) and bool((containers[pos] as Dictionary).get("one_use_cache", false)):
		Sfx.chest_open()
		return recover_one_use_cache(pos)
	if not containers.has(pos):
		containers[pos] = {"contents": {}, "durability": {}, "loot_generated": true, "loot_key": ""}
	for i in craft_slots.size():
		return_craft_slot(i)
	craft_pick = ""
	open_container_pos = pos
	_generate_chest_loot(pos)
	craft_open = true
	Sfx.chest_open()
	inventory_changed.emit()
	state_changed.emit()
	return true


func try_open_station_inventory(tx: int, ty: int) -> bool:
	if not player_near(tx, ty):
		return false
	var station := str(get_block(tx, ty).get("station", ""))
	if station not in ["workbench", "furnace"]:
		return false
	# Station recipes are already resolved from nearby world blocks. Opening the
	# regular crafting inventory here keeps one consistent UI while immediately
	# exposing the recipes unlocked by the tapped station.
	open_container_pos = Vector2i(COORD_LIMIT + 1, COORD_LIMIT + 1)
	craft_open = true
	inventory_changed.emit()
	return true


func close_container() -> void:
	open_container_pos = Vector2i(COORD_LIMIT + 1, COORD_LIMIT + 1)
	craft_pick = ""
	craft_open = false
	inventory_changed.emit()


func take_container_stack(block_name: String, requested_amount: int = -1) -> bool:
	if not container_is_open():
		return false
	var data: Dictionary = containers[open_container_pos]
	var contents: Dictionary = data.get("contents", {})
	var available := int(contents.get(block_name, 0))
	if available <= 0:
		return false
	var amount := available if requested_amount < 0 else mini(available, maxi(1, requested_amount))
	var remaining := available - amount
	if remaining <= 0:
		contents.erase(block_name)
	else:
		contents[block_name] = remaining
	var stored_durability: Dictionary = data.get("durability", {}) if data.get("durability", {}) is Dictionary else {}
	var chest_values: Array = stored_durability.get(block_name, []) if stored_durability.get(block_name, []) is Array else []
	var transferred_durability: Array[int] = []
	for _item in amount:
		if not chest_values.is_empty():
			transferred_durability.append(int(chest_values.pop_back()))
	if chest_values.is_empty():
		stored_durability.erase(block_name)
	else:
		stored_durability[block_name] = chest_values
	data["contents"] = contents
	data["durability"] = stored_durability
	containers[open_container_pos] = data
	give_to_inventory(block_name, amount, transferred_durability)
	inventory_changed.emit()
	state_changed.emit()
	return true


func store_inventory_stack(block_name: String, requested_amount: int = -1) -> bool:
	if not container_is_open():
		return false
	var available := int(inventory.get(block_name, 0))
	if available <= 0:
		return false
	var data: Dictionary = containers[open_container_pos]
	var contents: Dictionary = data.get("contents", {})
	if not contents.has(block_name) and contents.size() >= CHEST_SLOT_COUNT:
		return false
	var amount := available if requested_amount < 0 else mini(available, maxi(1, requested_amount))
	var stored_durability: Dictionary = data.get("durability", {}) if data.get("durability", {}) is Dictionary else {}
	var chest_values: Array = stored_durability.get(block_name, []) if stored_durability.get(block_name, []) is Array else []
	for _item in amount:
		var inventory_values: Array = item_durability.get(block_name, []) if item_durability.get(block_name, []) is Array else []
		if not inventory_values.is_empty():
			chest_values.append(int(inventory_values.back()))
		take_from_inventory(block_name)
	if not chest_values.is_empty():
		stored_durability[block_name] = chest_values
	contents[block_name] = int(contents.get(block_name, 0)) + amount
	data["contents"] = contents
	data["durability"] = stored_durability
	containers[open_container_pos] = data
	inventory_changed.emit()
	state_changed.emit()
	return true


func finish_break(tx: int, ty: int) -> bool:
	if not plant_block_at(tx, ty).is_empty() and remove_plant_at(tx, ty):
		Sfx.break_block("leaves")
		damage_equipped_item("hand")
		return true
	var block := get_block(tx, ty)
	if block["id"] == 0:
		return false
	var harvestable := can_harvest_block(block)
	var name: String = block.get("name", "air")
	var advances_one_block := world_mode == WORLD_MODE_ONE_BLOCK and Vector2i(tx, ty) == one_block_position
	Sfx.break_block(name)
	var container_pos := Vector2i(tx, ty)
	if block.get("container", false) and containers.has(container_pos):
		if bool((containers[container_pos] as Dictionary).get("death_cache", false)):
			return recover_death_cache(container_pos)
		if bool((containers[container_pos] as Dictionary).get("one_use_cache", false)):
			return recover_one_use_cache(container_pos)
		_generate_chest_loot(container_pos)
		var container_data: Dictionary = containers[container_pos]
		var stored: Dictionary = container_data.get("contents", {})
		var stored_durability: Dictionary = container_data.get("durability", {}) if container_data.get("durability", {}) is Dictionary else {}
		for stored_name: String in stored:
			var durability_values: Array = stored_durability.get(stored_name, []) if stored_durability.get(stored_name, []) is Array else []
			give_to_inventory(stored_name, int(stored[stored_name]), durability_values)
		containers.erase(container_pos)
		if open_container_pos == container_pos:
			open_container_pos = Vector2i(COORD_LIMIT + 1, COORD_LIMIT + 1)
			craft_open = false
	var is_fluid_source: bool = block.get("fluid", false) and get_fluid_level(tx, ty) == 0
	set_block(tx, ty, 0)
	tree_growth.erase(Vector2i(tx, ty))
	if block.get("fluid", false) and not is_fluid_source:
		inventory_changed.emit()
		return true
	if name != "air" and harvestable:
		# Like Minecraft, natural stone becomes cobblestone when harvested. This
		# creates a readable wood -> stone -> furnace progression without adding a
		# second crafting UI or recipe shape system.
		var drop_name := "cobblestone" if name == "stone" else name
		if name == "gravel" and randf() < FLINT_FROM_GRAVEL_CHANCE:
			drop_name = "flint"
		give_to_inventory(drop_name, 1)
		var forage_tags := _semantic_tags(name)
		if "leaves" in forage_tags and "needles" not in forage_tags and randf() < 0.28:
			give_to_inventory("wild_berries", 1)
	if advances_one_block:
		_advance_one_block()
	damage_equipped_item("hand")
	inventory_changed.emit()
	return true


func place_block(tx: int, ty: int) -> bool:
	var block := get_block(tx, ty)
	if not player_near(tx, ty):
		return false
	if not BlockDefs.BLOCKS.has(selected):
		return false
	if inventory.get(selected, 0) <= 0:
		return false

	var type: Dictionary = BlockDefs.BLOCKS[selected]
	if type.get("item", false):
		return false
	if type.get("creature_item", false):
		return spawn_creature_from_item(tx, ty, selected)
	if type.get("plant", false):
		return place_plant(tx, ty, selected)
	var can_replace_fluid: bool = not type.get("fluid", false) and block.get("fluid", false)
	if block["id"] != 0 and not can_replace_fluid:
		return false

	var bx := tx * BlockDefs.TILE
	var by := ty * BlockDefs.TILE
	if not type.get("fluid", false):
		if rect_overlap(player["x"], player["y"], player["w"], player["h"], bx, by, BlockDefs.TILE, BlockDefs.TILE):
			return false
	if plant_cells.has(Vector2i(tx, ty)):
		remove_plant_at(tx, ty, false)

	if type.get("fluid", false):
		var mixed := -1
		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var nx: int = tx + offset.x
			var ny: int = ty + offset.y
			if not in_bounds(nx, ny):
				continue
			var neighbor_id: int = block_id(nx, ny)
			if not is_fluid_id(neighbor_id):
				continue
			mixed = mix_fluids(tx, ty, type["id"], neighbor_id, get_fluid_level(nx, ny))
			if mixed >= 0:
				break
		if mixed >= 0:
			set_block(tx, ty, mixed)
			Sfx.mix_stone()
		else:
			set_block(tx, ty, type["id"], 0)
			Sfx.place(selected)
	else:
		_fluid_void_limit_y = maxi(_fluid_void_limit_y, ty + FLUID_VOID_MARGIN)
		set_block(tx, ty, type["id"])
		Sfx.place(selected)
		_try_start_tree_growth(tx, ty, selected)

	take_from_inventory(selected)
	inventory_changed.emit()
	return true


func get_craft_counts() -> Dictionary:
	_ensure_craft_slot_state()
	var counts := {}
	for slot in craft_slots:
		if slot == null:
			continue
		counts[slot] = counts.get(slot, 0) + 1
	return counts


func _ensure_craft_slot_state() -> void:
	if craft_slots.size() != CRAFT_SLOT_COUNT:
		var normalized_slots: Array = [null, null, null, null]
		for index in mini(normalized_slots.size(), craft_slots.size()):
			normalized_slots[index] = craft_slots[index]
		craft_slots = normalized_slots
	if craft_slot_durability.size() != CRAFT_SLOT_COUNT:
		var normalized_durability: Array[int] = [0, 0, 0, 0]
		for index in mini(normalized_durability.size(), craft_slot_durability.size()):
			normalized_durability[index] = maxi(0, int(craft_slot_durability[index]))
		craft_slot_durability = normalized_durability


func recipe_matches(counts: Dictionary, recipe: Dictionary) -> bool:
	var total := 0
	for name: String in recipe["in"]:
		if counts.get(name, 0) != recipe["in"][name]:
			return false
		total += recipe["in"][name]
	var grid_total := 0
	for v in counts.values():
		grid_total += v
	return grid_total == total


func find_recipe() -> Dictionary:
	var recipe := find_matching_recipe()
	return recipe if not recipe.is_empty() and recipe_station_available(recipe) else {}


func find_matching_recipe() -> Dictionary:
	var counts := get_craft_counts()
	for recipe in get_all_recipes():
		if recipe_matches(counts, recipe):
			return recipe
	return {}


func _resolve_content_recipe(content_recipe: Dictionary) -> Dictionary:
	var resolved_inputs: Dictionary = {}
	var resolved_outputs: Dictionary = {}
	for content_id: String in (content_recipe.get("in", {}) as Dictionary):
		var block_name := _block_name_for_content_id(content_id)
		if block_name.is_empty():
			return {}
		resolved_inputs[block_name] = int((content_recipe["in"] as Dictionary)[content_id])
	for content_id: String in (content_recipe.get("out", {}) as Dictionary):
		var block_name := _block_name_for_content_id(content_id)
		if block_name.is_empty():
			return {}
		resolved_outputs[block_name] = int((content_recipe["out"] as Dictionary)[content_id])
	var resolved := {"in": resolved_inputs, "out": resolved_outputs, "system": true}
	var station := str(content_recipe.get("station", ""))
	if not station.is_empty():
		resolved["station"] = station
	return resolved


func nearby_station(station: String) -> bool:
	if station.is_empty():
		return true
	var center := Vector2i(
		floori((float(player.get("x", 0.0)) + float(player.get("w", 20.0)) * 0.5) / float(BlockDefs.TILE)),
		floori((float(player.get("y", 0.0)) + float(player.get("h", 28.0)) * 0.5) / float(BlockDefs.TILE)),
	)
	for y in range(center.y - STATION_RADIUS, center.y + STATION_RADIUS + 1):
		for x in range(center.x - STATION_RADIUS, center.x + STATION_RADIUS + 1):
			if not in_bounds(x, y):
				continue
			if str(get_block(x, y).get("station", "")) == station:
				return true
	return false


func recipe_station_available(recipe: Dictionary) -> bool:
	return nearby_station(str(recipe.get("station", "")))


func get_all_recipes() -> Array[Dictionary]:
	var recipes: Array[Dictionary] = []
	for recipe: Dictionary in BlockDefs.RECIPES:
		recipes.append(recipe)
	for content_recipe: Dictionary in BlockDefs.CONTENT_RECIPES:
		var resolved := _resolve_content_recipe(content_recipe)
		if not resolved.is_empty():
			recipes.append(resolved)
	# Creature collectibles keep their identity until the player deliberately
	# chooses to prepare one. Creatures large enough to provide a real meal get
	# the same abstract furnace conversion instead of species-specific meat items;
	# tiny ambient wildlife such as fireflies remains collectible but not edible.
	for block_name: String in BlockDefs.BLOCKS:
		if creature_can_be_prepared_as_meal(block_name):
			recipes.append({
				"in": {block_name: 1},
				"out": {"prepared_meal": 1},
				"station": "furnace",
				"system": true,
			})
	for recipe: Dictionary in known_recipes:
		recipes.append(recipe)
	return recipes


func creature_can_be_prepared_as_meal(block_name: String) -> bool:
	var entry: Dictionary = BlockDefs.BLOCKS.get(block_name, {})
	if not bool(entry.get("creature_item", false)):
		return false
	var definition: Dictionary = entry.get("definition", {}) if entry.get("definition", {}) is Dictionary else {}
	if "sapient" in (definition.get("tags", []) as Array):
		return false
	var stats: Dictionary = definition.get("stats", {}) if definition.get("stats", {}) is Dictionary else {}
	return float(stats.get("size", 0.0)) >= MIN_PREPARED_MEAL_CREATURE_SIZE


func get_contextual_recipes() -> Array[Dictionary]:
	var table_counts := get_craft_counts()
	var has_table_inputs := not table_counts.is_empty()
	var relevant: Array[Dictionary] = []
	for recipe: Dictionary in get_all_recipes():
		var total_required := 0
		var compatible := true
		for block_name: String in recipe["in"]:
			var required := int(recipe["in"][block_name])
			total_required += required
		if not compatible or total_required > craft_slots.size():
			continue
		if has_table_inputs:
			for placed_name: String in table_counts:
				if int(recipe["in"].get(placed_name, 0)) < int(table_counts[placed_name]):
					compatible = false
					break
		else:
			compatible = false
			for block_name: String in recipe["in"]:
				if int(inventory.get(block_name, 0)) > 0:
					compatible = true
					break
		if compatible:
			relevant.append(recipe)
	return relevant


func can_fill_craft_from_recipe(recipe: Dictionary) -> bool:
	if not recipe.has("in") or not recipe["in"] is Dictionary:
		return false
	if not recipe_station_available(recipe):
		return false
	var available := inventory.duplicate()
	for block_name: String in get_craft_counts():
		available[block_name] = int(available.get(block_name, 0)) + int(get_craft_counts()[block_name])
	var total_required := 0
	for block_name: String in recipe["in"]:
		var required := int(recipe["in"][block_name])
		total_required += required
		if required <= 0 or int(available.get(block_name, 0)) < required:
			return false
	if total_required > craft_slots.size():
		return false
	return true


func fill_craft_from_recipe(recipe: Dictionary) -> bool:
	if not can_fill_craft_from_recipe(recipe):
		return false
	for i in craft_slots.size():
		return_craft_slot(i)
	var slot_index := 0
	for block_name: String in recipe["in"]:
		for _i in int(recipe["in"][block_name]):
			var durability := _inventory_durability_for_removal(block_name)
			if not take_from_inventory(block_name):
				return false
			craft_slots[slot_index] = block_name
			craft_slot_durability[slot_index] = durability
			slot_index += 1
	craft_pick = ""
	inventory_changed.emit()
	state_changed.emit()
	return true


func _remember_generated_recipe(inputs: Dictionary, output_name: String) -> void:
	for recipe: Dictionary in known_recipes:
		if recipe_matches(inputs, recipe):
			return
	known_recipes.append({
		"in": inputs.duplicate(true),
		"out": {output_name: 1},
		"generated": true,
	})


func get_hotbar() -> Array[String]:
	return hotbar_slots.duplicate()


func _reselect_after_remove() -> void:
	var bar := get_hotbar()
	if active_hotbar_slot < 0 or active_hotbar_slot >= bar.size():
		selected = ""
		active_hotbar_slot_awaiting_item = false
		return
	var active_name := str(bar[active_hotbar_slot])
	selected = active_name if not active_name.is_empty() and inventory.get(active_name, 0) > 0 else ""
	active_hotbar_slot_awaiting_item = selected.is_empty()


func _clear_equipment_reference(block_name: String) -> void:
	for slot_name in ["hand", "feet"]:
		if str(equipment_slots.get(slot_name, "")) == block_name:
			equipment_slots[slot_name] = ""


func _remove_hotbar_reference(block_name: String) -> void:
	for index in hotbar_slots.size():
		if hotbar_slots[index] == block_name:
			hotbar_slots[index] = ""
	if selected == block_name:
		_reselect_after_remove()


func equip_item(block_name: String) -> bool:
	if inventory.get(block_name, 0) <= 0:
		return false
	var slot_name := equipment_slot_for_item(block_name)
	if slot_name.is_empty():
		return false
	equipment_slots[slot_name] = block_name
	_remove_hotbar_reference(block_name)
	inventory_changed.emit()
	state_changed.emit()
	return true


func unequip_slot(slot_name: String) -> bool:
	if slot_name not in ["hand", "feet"] or str(equipment_slots.get(slot_name, "")).is_empty():
		return false
	equipment_slots[slot_name] = ""
	inventory_changed.emit()
	state_changed.emit()
	return true


func _inventory_durability_for_removal(name: String) -> int:
	_normalize_item_durability(name)
	var values: Array = item_durability.get(name, []) if item_durability.get(name, []) is Array else []
	return int(values.back()) if not values.is_empty() else 0


func take_from_inventory(name: String) -> bool:
	if inventory.get(name, 0) <= 0:
		return false
	var durability_values: Array = item_durability.get(name, []) if item_durability.get(name, []) is Array else []
	if not durability_values.is_empty():
		durability_values.pop_back()
		if durability_values.is_empty():
			item_durability.erase(name)
		else:
			item_durability[name] = durability_values
	inventory[name] -= 1
	if inventory[name] <= 0:
		inventory.erase(name)
		inv_order.erase(name)
		for i in hotbar_slots.size():
			if hotbar_slots[i] == name:
				hotbar_slots[i] = ""
		_clear_equipment_reference(name)
		if craft_pick == name:
			craft_pick = ""
		if selected == name:
			_reselect_after_remove()
	return true


func destroy_inventory_stack(name: String) -> int:
	var removed := int(inventory.get(name, 0))
	if removed <= 0:
		return 0
	inventory.erase(name)
	inv_order.erase(name)
	item_durability.erase(name)
	for i in hotbar_slots.size():
		if hotbar_slots[i] == name:
			hotbar_slots[i] = ""
	_clear_equipment_reference(name)
	if craft_pick == name:
		craft_pick = ""
	if selected == name:
		_reselect_after_remove()
	inventory_changed.emit()
	state_changed.emit()
	return removed


func clear_inventory() -> int:
	var removed := 0
	for count: Variant in inventory.values():
		removed += maxi(0, int(count))
	if removed <= 0:
		return 0
	inventory.clear()
	inv_order.clear()
	item_durability.clear()
	footwear_wear_distance = 0.0
	for i in hotbar_slots.size():
		hotbar_slots[i] = ""
	equipment_slots = {"hand": "", "feet": ""}
	craft_pick = ""
	selected = ""
	active_hotbar_slot_awaiting_item = false
	inventory_changed.emit()
	state_changed.emit()
	return removed


func give_to_inventory(name: String, count: int = 1, durability_values: Array = []) -> void:
	if count <= 0 or not BlockDefs.BLOCKS.has(name) or name == "air":
		return
	if inventory.get(name, 0) <= 0:
		inv_order.append(name)
		inventory[name] = count
		if not hotbar_slots.has(name):
			var target_slot := -1
			if (
				active_hotbar_slot_awaiting_item
				and active_hotbar_slot >= 0
				and active_hotbar_slot < hotbar_slots.size()
				and hotbar_slots[active_hotbar_slot].is_empty()
			):
				target_slot = active_hotbar_slot
			else:
				for i in hotbar_slots.size():
					if hotbar_slots[i].is_empty():
						target_slot = i
						break
			if target_slot >= 0:
				hotbar_slots[target_slot] = name
				if target_slot == active_hotbar_slot:
					selected = name
					active_hotbar_slot_awaiting_item = false
	else:
		inventory[name] += count
	var maximum := item_max_durability(name)
	if maximum > 0:
		var existing: Array = item_durability.get(name, []) if item_durability.get(name, []) is Array else []
		for index in count:
			var durability := int(durability_values[index]) if index < durability_values.size() else maximum
			existing.append(clampi(durability, 1, maximum))
		item_durability[name] = existing


func give_generated_definition(definition: Dictionary, count: int = 1) -> String:
	var block_name := BlockDefs.register_generated_block(definition)
	if block_name == "":
		return ""
	_remember_world_definition(definition)
	catalog_revision = maxi(catalog_revision, int(definition.get("catalog_revision", 0)))
	give_to_inventory(block_name, count)
	inventory_changed.emit()
	state_changed.emit()
	return block_name


func assign_hotbar(index: int, name: String) -> bool:
	if index < 0 or index >= BlockDefs.HOTBAR_SIZE or inventory.get(name, 0) <= 0:
		return false
	if not equipment_slot_for_item(name).is_empty():
		return equip_item(name)
	for i in hotbar_slots.size():
		if hotbar_slots[i] == name:
			hotbar_slots[i] = ""
	hotbar_slots[index] = name
	active_hotbar_slot = index
	selected = name
	active_hotbar_slot_awaiting_item = false
	inventory_changed.emit()
	state_changed.emit()
	return true


func return_craft_slot(i: int) -> void:
	_ensure_craft_slot_state()
	if i < 0 or i >= CRAFT_SLOT_COUNT:
		return
	var name = craft_slots[i]
	if name == null:
		return
	var durability := int(craft_slot_durability[i])
	give_to_inventory(name, 1, [durability] if durability > 0 else [])
	craft_slots[i] = null
	craft_slot_durability[i] = 0


func place_craft_slot(i: int, name: String) -> bool:
	_ensure_craft_slot_state()
	if i < 0 or i >= CRAFT_SLOT_COUNT:
		return false
	var durability := _inventory_durability_for_removal(name)
	if not take_from_inventory(name):
		return false
	if craft_slots[i] != null:
		var previous_durability := int(craft_slot_durability[i])
		give_to_inventory(craft_slots[i], 1, [previous_durability] if previous_durability > 0 else [])
	craft_slots[i] = name
	craft_slot_durability[i] = durability
	return true


func craft_output() -> Dictionary:
	_ensure_craft_slot_state()
	var recipe := find_recipe()
	if recipe.is_empty():
		return {}
	for i in craft_slots.size():
		craft_slots[i] = null
		craft_slot_durability[i] = 0
	for name: String in recipe["out"]:
		give_to_inventory(name, recipe["out"][name])
	var out_keys: Array = recipe["out"].keys()
	if out_keys.size() > 0:
		Sfx.place(out_keys[0])
	inventory_changed.emit()
	state_changed.emit()
	if out_keys.is_empty():
		return {}
	var output_name := str(out_keys[0])
	return {"item": output_name, "count": int(recipe["out"].get(output_name, 1))}


func craft_generated_output(definition: Dictionary, discovery_job_id: String = "") -> String:
	_ensure_craft_slot_state()
	if not discovery_job_id.is_empty() and applied_discovery_jobs.has(discovery_job_id):
		return BlockDefs.name_for_content_id(str(applied_discovery_jobs[discovery_job_id]))
	var input_counts := get_craft_counts()
	if input_counts.is_empty():
		return ""
	var block_name := BlockDefs.register_generated_block(definition)
	if block_name == "":
		return ""
	_remember_world_definition(definition)
	catalog_revision = maxi(catalog_revision, int(definition.get("catalog_revision", 0)))
	for i in craft_slots.size():
		craft_slots[i] = null
		craft_slot_durability[i] = 0
	_remember_generated_recipe(input_counts, block_name)
	if not discovery_job_id.is_empty():
		applied_discovery_jobs[discovery_job_id] = str(definition.get("content_id", ""))
	give_to_inventory(block_name, 1)
	Sfx.place(block_name)
	inventory_changed.emit()
	state_changed.emit()
	return block_name


func toggle_craft() -> void:
	if container_is_open():
		close_container()
		return
	craft_open = not craft_open
	if not craft_open:
		for i in craft_slots.size():
			return_craft_slot(i)
		craft_pick = ""
		open_container_pos = Vector2i(COORD_LIMIT + 1, COORD_LIMIT + 1)
	inventory_changed.emit()


func select_hotbar(index: int) -> void:
	var bar := get_hotbar()
	if index >= 0 and index < bar.size():
		active_hotbar_slot = index
		selected = bar[index] if inventory.get(bar[index], 0) > 0 else ""
		active_hotbar_slot_awaiting_item = selected.is_empty()
		craft_pick = ""
		inventory_changed.emit()
		state_changed.emit()
