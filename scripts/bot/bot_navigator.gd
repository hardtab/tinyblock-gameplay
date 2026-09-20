class_name BotNavigator
extends RefCounted

## Short-horizon, deterministic helpers.  The full player physics adapter can
## replace these steps without changing the action contract used by the brain.

const MAX_ROUTE_NODES := 64
const MAX_PHYSICS_ROUTE_NODES := 128


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
) -> Array[Dictionary]:
	var empty: Array[Dictionary] = []
	if not passable.is_valid() or max_nodes <= 0 or not bool(passable.call(origin)):
		return empty
	if origin == target:
		return [{"tile": origin, "kind": "start"}]
	var queue: Array[Vector2i] = [origin]
	var previous: Dictionary = {origin: null}
	var edge_kind: Dictionary = {}
	var head := 0
	while head < queue.size() and queue.size() <= max_nodes:
		var current := queue[head]
		head += 1
		var candidates: Array[Dictionary] = []
		for direction in [Vector2i.RIGHT, Vector2i.LEFT]:
			candidates.append({"tile": current + direction, "kind": "walk"})
			# A one-block step and a two-block gap are both reachable by the
			# controller's jump arc. The actual collision solver remains final.
			candidates.append({"tile": current + direction + Vector2i.UP, "kind": "jump"})
			candidates.append({"tile": current + direction * 2, "kind": "jump"})
			candidates.append({"tile": current + direction * 2 + Vector2i.UP, "kind": "jump"})
			candidates.append({"tile": current + direction + Vector2i.DOWN, "kind": "drop"})
		for direction in [Vector2i.UP, Vector2i.DOWN]:
			if climbable.is_valid() and (bool(climbable.call(current)) or bool(climbable.call(current + direction))):
				candidates.append({"tile": current + direction, "kind": "climb"})
		for candidate in candidates:
			var next: Vector2i = candidate["tile"]
			if previous.has(next) or not bool(passable.call(next)):
				continue
			previous[next] = current
			edge_kind[next] = str(candidate["kind"])
			if next == target:
				return _reconstruct_physics_path(previous, edge_kind, origin, target)
			queue.append(next)
	return empty


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
