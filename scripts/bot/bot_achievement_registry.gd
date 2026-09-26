class_name BotAchievementRegistry
extends RefCounted

## Single source of truth for achievement IDs and bot strategy policy. This
## mirrors AchievementManager.DEFINITIONS while keeping catalog-only goals
## known but not silently turning them into new bot objectives.

const ADVENTURE_MODES: Array[String] = [
	"skyblock", "floating_islands", "procedural", "one_block", "challenge_run",
]
const SHARED_PROGRESS_MODES: Array[String] = [
	"skyblock", "floating_islands", "procedural", "one_block", "challenge_run", "duel", "pvp",
]
const RECORDABLE_WORLD_MODES: Array[String] = [
	"skyblock", "floating_islands", "procedural", "one_block", "challenge_run",
]
const STONE_AGE_MODES: Array[String] = [
	"skyblock", "floating_islands", "procedural", "one_block",
]
const TOOL_PROGRESSION_MODES: Array[String] = [
	"skyblock", "floating_islands", "procedural", "one_block",
]

## The generic lifecycle state machine tracks these IDs. Stone Age has its own
## richer staged lifecycle in BotSession and is intentionally separate.
const TRACKED_GOAL_IDS: Array[String] = [
	"first_block", "first_craft", "here_will_be_home", "miner", "architect",
	"jeweler", "world_underfoot", "below_surface", "resonance_master",
	"one_block_world", "dont_look_back", "five_lives", "not_alone", "back_for_it",
]

## Each catalog ID has one metadata row for eligibility, actionability, and
## stable strategy priority. Passive/meta entries have no strategy priority;
## priorities are only meaningful among goals eligible in the queried mode.
const GOAL_METADATA: Array[Dictionary] = [
	{"id": "first_block", "modes": SHARED_PROGRESS_MODES, "actionable": false, "strategy_priority": -1},
	{"id": "first_craft", "modes": SHARED_PROGRESS_MODES, "actionable": false, "strategy_priority": -1},
	{"id": "stone_age", "modes": STONE_AGE_MODES, "actionable": true, "strategy_priority": -1},
	{"id": "first_discovery", "modes": [], "actionable": false, "strategy_priority": -1},
	{"id": "here_will_be_home", "modes": SHARED_PROGRESS_MODES, "actionable": false, "strategy_priority": -1},
	{"id": "miner", "modes": SHARED_PROGRESS_MODES, "actionable": false, "strategy_priority": -1},
	{"id": "architect", "modes": SHARED_PROGRESS_MODES, "actionable": false, "strategy_priority": -1},
	{"id": "ideas_collector", "modes": [], "actionable": false, "strategy_priority": -1},
	{"id": "four_kinds", "modes": [], "actionable": false, "strategy_priority": -1},
	{"id": "jeweler", "modes": ["procedural"], "actionable": true, "strategy_priority": 10},
	{"id": "world_underfoot", "modes": ["procedural"], "actionable": true, "strategy_priority": 20},
	{"id": "below_surface", "modes": ["procedural"], "actionable": true, "strategy_priority": 40},
	{"id": "resonance_master", "modes": ["procedural"], "actionable": true, "strategy_priority": 30},
	{"id": "one_block_world", "modes": ["one_block"], "actionable": true, "strategy_priority": 10},
	{"id": "dont_look_back", "modes": ["challenge_run"], "actionable": true, "strategy_priority": 10},
	{"id": "five_lives", "modes": ADVENTURE_MODES, "actionable": false, "strategy_priority": -1},
	{"id": "not_alone", "modes": SHARED_PROGRESS_MODES, "actionable": false, "strategy_priority": -1},
	{"id": "back_for_it", "modes": SHARED_PROGRESS_MODES, "actionable": false, "strategy_priority": -1},
]


static func catalog_goal_ids() -> Array[String]:
	var result: Array[String] = []
	for entry in GOAL_METADATA:
		result.append(str(entry.get("id", "")))
	return result


static func tracked_goal_ids() -> Array[String]:
	return TRACKED_GOAL_IDS.duplicate()


static func actionable_goal_ids() -> Array[String]:
	var result: Array[String] = []
	for entry in GOAL_METADATA:
		if bool(entry.get("actionable", false)):
			result.append(str(entry.get("id", "")))
	return result


static func is_actionable_goal(goal_id: String) -> bool:
	var entry := _metadata_for(goal_id)
	return not entry.is_empty() and bool(entry.get("actionable", false))


static func goal_mode_allowed(goal_id: String, mode: String) -> bool:
	var entry := _metadata_for(goal_id)
	if entry.is_empty():
		return false
	var allowed_modes: Array = entry.get("modes", [])
	return mode.strip_edges().to_lower() in allowed_modes


static func stone_age_progression_modes() -> PackedStringArray:
	return PackedStringArray(STONE_AGE_MODES)


static func tool_progression_modes() -> PackedStringArray:
	return PackedStringArray(TOOL_PROGRESSION_MODES)


static func recordable_world_modes() -> PackedStringArray:
	return PackedStringArray(RECORDABLE_WORLD_MODES)


## The canonical six WorldSim modes. "pvp" is retained above solely as a
## legacy eligibility alias and is deliberately not listed as a world mode.
static func known_world_modes() -> Array[String]:
	return ["skyblock", "floating_islands", "procedural", "one_block", "challenge_run", "duel"]


static func strategy_goal_ids(mode: String) -> Array[String]:
	var normalized_mode := mode.strip_edges().to_lower()
	var prioritized: Array[Dictionary] = []
	for entry in GOAL_METADATA:
		if not bool(entry.get("actionable", false)):
			continue
		var priority := int(entry.get("strategy_priority", -1))
		if priority < 0 or not goal_mode_allowed(str(entry.get("id", "")), normalized_mode):
			continue
		prioritized.append({"id": str(entry.get("id", "")), "priority": priority})
	prioritized.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("priority", 0)) < int(b.get("priority", 0))
	)
	var result: Array[String] = []
	for entry in prioritized:
		result.append(str(entry.get("id", "")))
	return result


static func goal_action_allowed(goal_id: String, mode: String, community_locked: bool) -> bool:
	return not community_locked and is_actionable_goal(goal_id) and goal_mode_allowed(goal_id, mode)


static func _metadata_for(goal_id: String) -> Dictionary:
	for entry in GOAL_METADATA:
		if str(entry.get("id", "")) == goal_id:
			return entry
	return {}
