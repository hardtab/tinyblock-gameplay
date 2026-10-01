class_name BotNavigator
extends RefCounted

## Short-horizon, deterministic helpers.  The full player physics adapter can
## replace these steps without changing the action contract used by the brain.

const MAX_ROUTE_NODES := 64
const MAX_PHYSICS_ROUTE_NODES := 128
## Multi-tile descents are only emitted when the caller supplies a transition
## validator that proves the complete corridor and landing are known and safe.
const MAX_VERIFIED_DROP_TILES := 6


static func step_towards(origin: Vector2, target: Vector2, max_distance: float) -> Vector2:
	if max_distance <= 0.0 or origin.distance_to(target) <= max_distance:
		return target
	return origin + origin.direction_to(target) * max_distance


static func step_away_from(origin: Vector2, threat: Vector2, max_distance: float) -> Vector2:
	var direction := threat.direction_to(origin)
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	return origin + direction * maxf(0.0, max_distance)


static func preferred_follow_target(player_position: Vector2, own_position: Vector2, preferred_distance: float = 84.0) -> Vector2:
	var delta := own_position - player_position
	if delta.length() <= preferred_distance:
		return own_position
	return player_position + delta.normalized() * preferred_distance


static func straight_route(origin: Vector2, target: Vector2, step_size: float = 20.0, max_nodes: int = MAX_ROUTE_NODES) -> Array[Vector2]:
	var route: Array[Vector2] = []
	var step := maxf(1.0, step_size)
	var distance := origin.distance_to(target)
	var node_count := mini(maxi(0, max_nodes), ceili(distance / step))
	for index in range(1, node_count + 1):
		route.append(origin.lerp(target, float(index) / float(node_count)))
	if route.is_empty() and origin != target:
		route.append(target)
	return route


static func grid_route(origin: Vector2i, target: Vector2i, passable: Callable, max_nodes: int = MAX_ROUTE_NODES) -> Array[Vector2i]:
	if not passable.is_valid() or max_nodes <= 0:
		return []
	if origin == target:
		return [origin]
	var queue: Array[Vector2i] = [origin]
	var previous: Dictionary = {origin: null}
	var head := 0
	while head < queue.size() and queue.size() <= max_nodes:
		var current := queue[head]
		head += 1
		for direction in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
			var next: Vector2i = current + direction
			if previous.has(next) or not bool(passable.call(next)):
				continue
			previous[next] = current
			if next == target:
				return _reconstruct_path(previous, origin, target)
			queue.append(next)
	return []


## Builds a short-horizon route in the same units as the player controller.
## Nodes are support tiles (the solid tile directly below the player's feet),
## while edge kinds tell the input adapter whether it must walk, jump, drop or
## climb to reach the next node. The callbacks keep this navigator independent
## from WorldSim and let the bot use only the tiles it has actually received.
static func physics_route(
	origin: Vector2i,
	target: Vector2i,
	passable: Callable,
	climbable: Callable = Callable(),
	max_nodes: int = MAX_PHYSICS_ROUTE_NODES,
	transition_allowed: Callable = Callable(),
	first_step_allowed: Callable = Callable(),
	later_step_allowed: Callable = Callable(),
	allow_verified_high_jumps: bool = false,
) -> Array[Dictionary]:
	var empty: Array[Dictionary] = []
	if not passable.is_valid() or max_nodes <= 0 or not bool(passable.call(origin)):
		return empty
	if origin == target:
		return [{"tile": origin, "kind": "start"}]
	var queue: Array[Vector2i] = [origin]
	var previous: Dictionary = {origin: null}
	var edge_kind: Dictionary = {}
	var include_verified_high_jumps := allow_verified_high_jumps and first_step_allowed.is_valid() and later_step_allowed.is_valid()
	var head := 0
	while head < queue.size() and queue.size() <= max_nodes:
		var current := queue[head]
		head += 1
		for candidate in _physics_candidates(current, climbable, transition_allowed.is_valid(), include_verified_high_jumps):
			var next: Vector2i = candidate["tile"]
			if previous.has(next) or not bool(passable.call(next)):
				continue
			if transition_allowed.is_valid() and not bool(transition_allowed.call(current, next, str(candidate["kind"]))):
				continue
			if current == origin and first_step_allowed.is_valid() and not bool(first_step_allowed.call(current, next, str(candidate["kind"]))):
				continue
			if current != origin and later_step_allowed.is_valid() and not bool(later_step_allowed.call(current, next, str(candidate["kind"]))):
				continue
			previous[next] = current
			edge_kind[next] = str(candidate["kind"])
			if next == target:
				return _reconstruct_physics_path(previous, edge_kind, origin, target)
			queue.append(next)
	return empty


## Enumerates the exact support-tile transitions physics_route expands from
## `current`.  Keeping this in one place lets physics_reachable_tiles prove the
## same route existence without re-deriving (and drifting from) the edge rules.
static func _physics_candidates(
	current: Vector2i,
	climbable: Callable,
	allow_verified_drops: bool = false,
	allow_verified_high_jumps: bool = false,
) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for direction in [Vector2i.RIGHT, Vector2i.LEFT]:
		candidates.append({"tile": current + direction, "kind": "walk"})
		# A one-block step and a two-block gap are both reachable by the
		# controller's jump arc. The actual collision solver remains final.
		candidates.append({"tile": current + direction + Vector2i.UP, "kind": "jump"})
		# A two-row step is only considered when the caller opts in and supplies
		# both first-edge and later-edge collision validators. The validators still
		# prove each concrete arc before the graph accepts the transition.
		if allow_verified_high_jumps:
			candidates.append({"tile": current + direction + Vector2i.UP * 2, "kind": "jump"})
		candidates.append({"tile": current + direction * 2, "kind": "jump"})
		candidates.append({"tile": current + direction * 2 + Vector2i.UP, "kind": "jump"})
		var max_drop_tiles := MAX_VERIFIED_DROP_TILES if allow_verified_drops else 1
		for drop_tiles in range(1, max_drop_tiles + 1):
			candidates.append({"tile": current + direction + Vector2i.DOWN * drop_tiles, "kind": "drop"})
	for direction in [Vector2i.UP, Vector2i.DOWN]:
		if climbable.is_valid() and (bool(climbable.call(current)) or bool(climbable.call(current + direction))):
			candidates.append({"tile": current + direction, "kind": "climb"})
	return candidates


## Bounded reachability set over the same support-tile graph as physics_route.
## Every key is a support tile physics_route can reach from `origin`; `origin`
## is included whenever it is passable. Because this shares the candidate
## neighbours, transition rules, first-edge and later-edge guards, and node cap with
## physics_route, a key's presence is equivalent to a non-empty physics_route
## to that tile, and a tile being absent means no route within the bound exists.
static func physics_reachable_tiles(
	origin: Vector2i,
	passable: Callable,
	climbable: Callable = Callable(),
	max_nodes: int = MAX_PHYSICS_ROUTE_NODES,
	transition_allowed: Callable = Callable(),
	first_step_allowed: Callable = Callable(),
	later_step_allowed: Callable = Callable(),
	allow_verified_high_jumps: bool = false,
) -> Dictionary:
	var reachable: Dictionary = {}
	if not passable.is_valid() or max_nodes <= 0 or not bool(passable.call(origin)):
		return reachable
	reachable[origin] = true
	var queue: Array[Vector2i] = [origin]
	var include_verified_high_jumps := allow_verified_high_jumps and first_step_allowed.is_valid() and later_step_allowed.is_valid()
	var head := 0
	while head < queue.size() and queue.size() <= max_nodes:
		var current := queue[head]
		head += 1
		for candidate in _physics_candidates(current, climbable, transition_allowed.is_valid(), include_verified_high_jumps):
			var next: Vector2i = candidate["tile"]
			if reachable.has(next) or not bool(passable.call(next)):
				continue
			var kind := str(candidate["kind"])
			if transition_allowed.is_valid() and not bool(transition_allowed.call(current, next, kind)):
				continue
			if current == origin and first_step_allowed.is_valid() and not bool(first_step_allowed.call(current, next, kind)):
				continue
			if current != origin and later_step_allowed.is_valid() and not bool(later_step_allowed.call(current, next, kind)):
				continue
			reachable[next] = true
			queue.append(next)
	return reachable


## Bounded reachability search that also records the first edge on the shortest
## discovered route to each support tile. Callers that need to rank many
## reachable destinations can validate their first movement without rerunning
## a complete physics_route search for every destination.
static func physics_reachable_first_steps(
	origin: Vector2i,
	passable: Callable,
	climbable: Callable = Callable(),
	max_nodes: int = MAX_PHYSICS_ROUTE_NODES,
	transition_allowed: Callable = Callable(),
	first_step_allowed: Callable = Callable(),
	later_step_allowed: Callable = Callable(),
	allow_verified_high_jumps: bool = false,
) -> Dictionary:
	var first_steps: Dictionary = {}
	if not passable.is_valid() or max_nodes <= 0 or not bool(passable.call(origin)):
		return first_steps
	first_steps[origin] = {"tile": origin, "kind": "start", "steps": 0}
	var queue: Array[Vector2i] = [origin]
	var include_verified_high_jumps := allow_verified_high_jumps and first_step_allowed.is_valid() and later_step_allowed.is_valid()
	var head := 0
	while head < queue.size() and queue.size() <= max_nodes:
		var current := queue[head]
		head += 1
		for candidate in _physics_candidates(current, climbable, transition_allowed.is_valid(), include_verified_high_jumps):
			var next: Vector2i = candidate["tile"]
			if first_steps.has(next) or not bool(passable.call(next)):
				continue
			var kind := str(candidate["kind"])
			if transition_allowed.is_valid() and not bool(transition_allowed.call(current, next, kind)):
				continue
			if current == origin:
				if first_step_allowed.is_valid() and not bool(first_step_allowed.call(current, next, kind)):
					continue
				first_steps[next] = {"tile": next, "kind": kind, "steps": 1}
			else:
				if later_step_allowed.is_valid() and not bool(later_step_allowed.call(current, next, kind)):
					continue
				var first_edge: Dictionary = (first_steps[current] as Dictionary).duplicate()
				first_edge["steps"] = int(first_edge.get("steps", 0)) + 1
				first_steps[next] = first_edge
			queue.append(next)
	return first_steps


## Exploration must not treat a safe landing as a safe destination when the
## directed physics graph has no route back. A verified six-tile drop, for
## example, may be survivable but cannot be reversed by a one-tile jump. Build
## the reverse edges of the bounded reachable graph once, then keep only its
## component that can return to origin. The same transition and hypothetical
## jump guards validate each return edge.
static func physics_roundtrip_first_steps(
	origin: Vector2i,
	passable: Callable,
	climbable: Callable = Callable(),
	max_nodes: int = MAX_PHYSICS_ROUTE_NODES,
	transition_allowed: Callable = Callable(),
	first_step_allowed: Callable = Callable(),
	later_step_allowed: Callable = Callable(),
	allow_verified_high_jumps: bool = false,
) -> Dictionary:
	var forward := physics_reachable_first_steps(
		origin, passable, climbable, max_nodes,
		transition_allowed, first_step_allowed, later_step_allowed, allow_verified_high_jumps,
	)
	if forward.is_empty():
		return {}
	var include_verified_high_jumps := allow_verified_high_jumps and first_step_allowed.is_valid() and later_step_allowed.is_valid()
	var predecessors: Dictionary = {}
	for raw_tile in forward.keys():
		var current: Vector2i = raw_tile
		for candidate in _physics_candidates(current, climbable, transition_allowed.is_valid(), include_verified_high_jumps):
			var neighbor: Vector2i = candidate["tile"]
			if not forward.has(neighbor):
				continue
			var kind := str(candidate["kind"])
			if transition_allowed.is_valid() and not bool(transition_allowed.call(current, neighbor, kind)):
				continue
			if later_step_allowed.is_valid() and not bool(later_step_allowed.call(current, neighbor, kind)):
				continue
			if not predecessors.has(neighbor):
				predecessors[neighbor] = []
			(predecessors[neighbor] as Array).append(current)
	var roundtrip: Dictionary = {origin: forward[origin]}
	var queue: Array[Vector2i] = [origin]
	var head := 0
	while head < queue.size():
		var current := queue[head]
		head += 1
		for raw_previous in predecessors.get(current, []):
			var previous: Vector2i = raw_previous
			if roundtrip.has(previous):
				continue
			roundtrip[previous] = forward[previous]
			queue.append(previous)
	return roundtrip


static func _reconstruct_path(previous: Dictionary, origin: Vector2i, target: Vector2i) -> Array[Vector2i]:
	var reverse: Array[Vector2i] = []
	var current := target
	while current != origin:
		reverse.append(current)
		if not previous.has(current) or previous[current] == null:
			return []
		current = previous[current]
	reverse.append(origin)
	reverse.reverse()
	return reverse


static func _reconstruct_physics_path(previous: Dictionary, edge_kind: Dictionary, origin: Vector2i, target: Vector2i) -> Array[Dictionary]:
	var reverse: Array[Dictionary] = []
	var current := target
	while current != origin:
		reverse.append({"tile": current, "kind": str(edge_kind.get(current, "walk"))})
		if not previous.has(current) or previous[current] == null:
			return []
		current = previous[current]
	reverse.append({"tile": origin, "kind": "start"})
	reverse.reverse()
	return reverse
