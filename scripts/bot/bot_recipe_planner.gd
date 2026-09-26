class_name BotRecipePlanner
extends RefCounted

## Deterministic, pure recipe dependency planner.
##
## Contract
## --------
## `recipes` uses the normalized catalog schema the bot already receives:
##
##   {
##     "in":  { "<item>": <count>, ... },   required inputs (must be non-empty)
##     "out": { "<item>": <count>, ... },   produced outputs (>= 1 per entry)
##     "station": "<name>",                 optional station required to craft
##     "station_available": <bool>,         optional; false == station is not
##                                          reachable right now
##   }
##
## Item names are already normalized to block/item names ("planks",
## "palm_planks", "wood", "palm_wood", "wooden_pickaxe", ...), the same strings
## the rule provider sees.  Malformed recipes (missing/empty/zero sides) and
## non-dictionary entries are skipped instead of raising.
##
## `plan(target_output, target_count, inventory, recipes, max_depth)` returns
## exactly one next step, always a Dictionary with a "status":
##
##   {"status": "already_owned", "item": ..., "count": N, "owned": M}
##   {"status": "craft", "output": ..., "recipe": {...}, "craft_count": K,
##    "output_per_craft": P, "have": H, "required": C, "path": [...]}
##   {"status": "gather", "item": ..., "count": N, "reason": ..., "path": [...]}
##   {"status": "need_station", "station": ..., "item": ..., "path": [...]}
##   {"status": "unresolved", "item": ..., "count": N, "reason": ...}
##
## craft/gather/need_station also carry "target" and "target_count".
##
## Guarantees and defaults:
## - Pure and deterministic: no RNG, no node tree, no state kept between calls.
##   Ties between equally good recipes are broken by a canonical recipe
##   signature (sorted key=value pairs), never by dictionary iteration order.
## - Existing inventory is counted before anything else, and recipe output
##   quantities are honoured (one "wood" -> four "planks" satisfies a request
##   for four planks with a single craft).
## - Alternate recipes for the same output are ranked by how much of the
##   required material the whole chain already owns (fewest items still to
##   gather wins), so a family (e.g. palm planks) is picked as a whole and not
##   mixed with another family while a matching recipe is viable.
## - A recipe whose station is missing is never reported as craftable.  The
##   first missing station found while walking down the requirement chain is
##   reported as `need_station` instead.
## - `target_count <= 0` is treated as 1; `max_depth < 0` as 0.
## - `max_depth` bounds how deep prerequisites are expanded.  Once the bound
##   is hit the planner stops expanding and falls back to `gather` for that
##   item with `"reason": "depth_bound"`, so the caller can re-plan after the
##   action.
## - Cycles terminate.  An item that is only reachable through itself comes
##   back as `unresolved` with `"reason": "cycle"` rather than a false craft.
## - `gather` is also the honest fallback when an item has no known recipe
##   ("reason": "no_recipe"); the caller decides whether that is actually
##   obtainable in the world.
## - The planner looks one step ahead only: it never reserves or consumes
##   inventory across returned steps.  Callers re-plan after every action.

const STATUS_ALREADY_OWNED := "already_owned"
const STATUS_CRAFT := "craft"
const STATUS_GATHER := "gather"
const STATUS_NEED_STATION := "need_station"
const STATUS_UNRESOLVED := "unresolved"

const REASON_NO_RECIPE := "no_recipe"
const REASON_DEPTH_BOUND := "depth_bound"
const REASON_CYCLE := "cycle"

# Candidate ranking weights.  Lower total material that still has to be
# gathered always wins; then more matching direct inputs, a higher share of
# already-owned required material, and stock near the leaf of the chain win.
const MISSING_MATERIAL_WEIGHT := 100
const MISSING_MATERIAL_SATURATION := 1000
const MATCHED_INPUT_BONUS := 100
const GATHERED_STOCK_BONUS := 5


static func plan(target_output: String, target_count: int, inventory: Dictionary, recipes: Array, max_depth: int = 8) -> Dictionary:
	var inv := _normalized_inventory(inventory)
	var wanted := maxi(1, target_count)
	var catalog := _normalized_recipes(recipes)
	var result := _analyze(target_output, wanted, inv, catalog, 0, maxi(0, max_depth), [])
	var step: Variant = result.get("step")
	if step != null:
		var plan_step: Dictionary = (step as Dictionary).duplicate(true)
		plan_step["target"] = target_output
		plan_step["target_count"] = wanted
		return plan_step
	if bool(result.get("ok", false)):
		return {
			"status": STATUS_ALREADY_OWNED,
			"item": target_output,
			"count": wanted,
			"owned": int(inv.get(target_output, 0)),
		}
	return {
		"status": STATUS_UNRESOLVED,
		"item": target_output,
		"count": wanted,
		"reason": str(result.get("reason", REASON_NO_RECIPE)),
	}


## Recursive demand analysis.  Returns
## `{"ok": bool, "step": Variant, "leaves": Dictionary, "reason": String}`.
## `ok` means "this requirement can eventually be met"; `step` is the single
## next action to take (null when the inventory already covers it).
static func _analyze(item: String, count: int, inv: Dictionary, recipes: Array, depth: int, max_depth: int, stack: Array) -> Dictionary:
	var have := int(inv.get(item, 0))
	if have >= count:
		return {"ok": true, "step": null, "leaves": {}, "reason": ""}
	if item in stack:
		return {"ok": false, "step": null, "leaves": {}, "reason": REASON_CYCLE}

	var missing := count - have
	var path: Array = stack.duplicate()
	path.append(item)

	if depth >= max_depth:
		return _leaf_result(item, missing, REASON_DEPTH_BOUND, path)

	var candidates := _recipes_for(item, recipes)
	if candidates.is_empty():
		return _leaf_result(item, missing, REASON_NO_RECIPE, path)

	var best_step: Variant = null
	var best_leaves := {}
	var best_score := -1
	var best_signature := ""
	var blocked_station := ""
	var saw_cycle := false

	for recipe in candidates:
		var outputs: Dictionary = recipe.get("out", {})
		var per_craft := int(outputs.get(item, 0))
		if per_craft <= 0:
			continue
		var inputs: Dictionary = recipe.get("in", {})

		# A recipe that eats the very item it produces cannot make progress
		# toward a larger count; treat it as a conversion cycle instead of
		# reporting a craft that would loop forever.
		if int(inputs.get(item, 0)) >= per_craft:
			saw_cycle = true
			continue

		# A missing station can never be worked around by collecting material,
		# so the recipe is skipped and only remembered as a blocked reason.
		if _station_missing(recipe):
			if blocked_station.is_empty():
				blocked_station = str(recipe.get("station", ""))
			continue

		var craft_count := int(ceil(float(missing) / float(per_craft)))
		var scratch := inv.duplicate()
		var viable := true
		var pending: Variant = null
		var leaves := {}
		var nested_blocked := ""

		for input_name in _sorted_names(inputs):
			var need := int(inputs[input_name]) * craft_count
			var sub := _analyze(input_name, need, scratch, recipes, depth + 1, max_depth, path)
			if not bool(sub.get("ok", false)):
				var sub_step: Variant = sub.get("step")
				if sub_step != null and str((sub_step as Dictionary).get("status", "")) == STATUS_NEED_STATION:
					nested_blocked = str((sub_step as Dictionary).get("station", ""))
				elif str(sub.get("reason", "")) == REASON_CYCLE:
					saw_cycle = true
				viable = false
				break
			_merge_counts(leaves, sub.get("leaves", {}))
			# The first unresolved input is the next action.  Resolved inputs
			# are subtracted so a resource shared by two inputs is not
			# double-counted inside a single evaluation.
			if sub.get("step") == null:
				scratch[input_name] = int(scratch.get(input_name, 0)) - need
			else:
				scratch[input_name] = 0
				if pending == null:
					pending = sub.get("step")

		if not viable:
			if not nested_blocked.is_empty() and blocked_station.is_empty():
				blocked_station = nested_blocked
			continue

		var score := _candidate_score(recipe, inv, craft_count, leaves)
		var signature := _signature(recipe)
		var better := score > best_score or (score == best_score and (best_signature.is_empty() or signature < best_signature))
		if not better:
			continue
		best_score = score
		best_signature = signature
		best_leaves = leaves
		if pending != null:
			best_step = pending
		else:
			best_step = _craft_step(item, recipe, craft_count, per_craft, have, count, path)

	if best_step != null:
		return {"ok": true, "step": best_step, "leaves": best_leaves, "reason": ""}
	if not blocked_station.is_empty():
		return {
			"ok": false,
			"step": {
				"status": STATUS_NEED_STATION,
				"station": blocked_station,
				"item": item,
				"path": path,
			},
			"leaves": {},
			"reason": STATUS_NEED_STATION,
		}
	return {"ok": false, "step": null, "leaves": {}, "reason": REASON_CYCLE if saw_cycle else REASON_NO_RECIPE}


static func _leaf_result(item: String, missing: int, reason: String, path: Array) -> Dictionary:
	return {
		"ok": true,
		"step": {
			"status": STATUS_GATHER,
			"item": item,
			"count": missing,
			"reason": reason,
			"path": path,
		},
		"leaves": {item: missing},
		"reason": reason,
	}


static func _craft_step(item: String, recipe: Dictionary, craft_count: int, per_craft: int, have: int, required: int, path: Array) -> Dictionary:
	var step := {
		"status": STATUS_CRAFT,
		"output": item,
		"recipe": recipe.duplicate(true),
		"craft_count": craft_count,
		"output_per_craft": per_craft,
		"have": have,
		"required": required,
		"path": path.duplicate(),
	}
	var station := str(recipe.get("station", ""))
	if not station.is_empty():
		step["station"] = station
	return step


## How well a viable candidate matches what the bot already owns.  The primary
## term is how much material the whole chain would still have to gather, so a
## family whose raw wood is already in inventory beats a family that is not.
## Deterministic integer arithmetic only.
static func _candidate_score(recipe: Dictionary, inv: Dictionary, craft_count: int, leaves: Dictionary) -> int:
	var inputs: Dictionary = recipe.get("in", {})
	var leaf_missing := 0
	for leaf_name in leaves:
		leaf_missing += int(leaves[leaf_name])
	var remaining := MISSING_MATERIAL_SATURATION - mini(MISSING_MATERIAL_SATURATION, leaf_missing * 10)
	var score := remaining * MISSING_MATERIAL_WEIGHT
	var total := 0
	var covered := 0
	var matched := 0
	for name in _sorted_names(inputs):
		var need := int(inputs[name]) * craft_count
		var have := int(inv.get(name, 0))
		total += need
		covered += mini(have, need)
		if have > 0:
			matched += 1
	score += matched * MATCHED_INPUT_BONUS
	score += (covered * 100) / maxi(1, total)
	for leaf_name in leaves:
		if int(inv.get(str(leaf_name), 0)) > 0:
			score += GATHERED_STOCK_BONUS
	return score


static func _station_missing(recipe: Dictionary) -> bool:
	return recipe.has("station_available") and not bool(recipe.get("station_available", false))


static func _recipes_for(item: String, recipes: Array) -> Array:
	var result: Array = []
	for recipe in recipes:
		var outputs: Dictionary = recipe.get("out", {})
		if outputs.has(item) and int(outputs[item]) > 0:
			result.append(recipe)
	return result


static func _signature(recipe: Dictionary) -> String:
	var inputs: Dictionary = recipe.get("in", {})
	var outputs: Dictionary = recipe.get("out", {})
	var in_parts: Array = []
	for name in _sorted_names(inputs):
		in_parts.append("%s=%d" % [name, int(inputs[name])])
	var out_parts: Array = []
	for name in _sorted_names(outputs):
		out_parts.append("%s=%d" % [name, int(outputs[name])])
	return "%s>%s@%s" % [",".join(in_parts), ",".join(out_parts), str(recipe.get("station", ""))]


static func _merge_counts(target: Dictionary, source: Variant) -> void:
	if not source is Dictionary:
		return
	for raw_name in source:
		var name := str(raw_name)
		target[name] = int(target.get(name, 0)) + int((source as Dictionary)[raw_name])


static func _sorted_names(values: Dictionary) -> Array:
	var names: Array = []
	for raw_name in values:
		names.append(str(raw_name))
	names.sort()
	return names


static func _normalized_inventory(inventory: Dictionary) -> Dictionary:
	var result := {}
	for raw_name in inventory:
		var count := int(inventory[raw_name])
		if count > 0:
			result[str(raw_name)] = count
	return result


static func _normalized_recipes(recipes: Array) -> Array:
	var result: Array = []
	for raw_recipe in recipes:
		if not raw_recipe is Dictionary:
			continue
		var recipe := raw_recipe as Dictionary
		var raw_inputs: Variant = recipe.get("in")
		var raw_outputs: Variant = recipe.get("out")
		if not raw_inputs is Dictionary or not raw_outputs is Dictionary:
			continue
		var inputs := _normalized_counts(raw_inputs as Dictionary)
		var outputs := _normalized_counts(raw_outputs as Dictionary)
		if inputs.is_empty() or outputs.is_empty():
			continue
		var entry := {"in": inputs, "out": outputs}
		var station := str(recipe.get("station", ""))
		if not station.is_empty():
			entry["station"] = station
			entry["station_available"] = bool(recipe.get("station_available", true))
		result.append(entry)
	return result


static func _normalized_counts(values: Dictionary) -> Dictionary:
	var result := {}
	for raw_name in values:
		var count := int(values[raw_name])
		if count > 0:
			result[str(raw_name)] = count
	return result
