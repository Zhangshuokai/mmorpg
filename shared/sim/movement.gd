class_name Movement
extends RefCounted
## Pure, side-effect-free movement resolution shared by both ends.
##
## WB0 extracted this from the old world.gd._step_players / _resolve_obstacles so
## the server tick and the future client prediction replay (WB6) run the exact
## same maths. No Node, no RPC, no engine state beyond what is passed in.
##
## Behaviour note: `step()` reproduces the original server pipeline one-to-one
## (rotate the intent by yaw, advance by speed*dt, force the floor height, push
## out of obstacles, then clamp to the map bounds).

## True when an input packet can be trusted for arithmetic. A crafted INF/NaN
## survives a length check, makes normalized()/rotated() produce NaN and poisons
## the authoritative position permanently (NaN comparisons are always false, so
## neither the bounds clamp nor the obstacle resolve can recover). The server
## rejects such input in WorldState.set_input; the client must apply the same
## guard before predicting.
static func is_input_finite(move: Vector2, yaw: float) -> bool:
	return move.is_finite() and is_finite(yaw)


## Player-style step: `move` is the raw intent (x = strafe, y = forward), rotated
## by `yaw`. Exact port of the original world.gd._step_players body.
static func step(pos: Vector3, move: Vector2, yaw: float, dt: float, speed: float,
		obstacles: Array, half: float, floor_y: float) -> Vector3:
	var dir := Vector3(move.x, 0.0, -move.y)
	if dir.length() > 0.001:
		dir = dir.normalized().rotated(Vector3.UP, yaw)
		return move_world(pos, dir, speed, dt, obstacles, half, floor_y)
	# No intent: the original code still re-applies the floor, obstacle and
	# bounds constraints every tick.
	return constrain(pos, obstacles, half, floor_y)


## World-space step (mob AI): `dir_world` is already a unit direction.
static func move_world(pos: Vector3, dir_world: Vector3, speed: float, dt: float,
		obstacles: Array, half: float, floor_y: float) -> Vector3:
	return constrain(pos + dir_world * speed * dt, obstacles, half, floor_y)


## Floor pin + obstacle push-out + map clamp, in the original order.
static func constrain(pos: Vector3, obstacles: Array, half: float, floor_y: float) -> Vector3:
	pos.y = floor_y
	pos = resolve_obstacles(pos, obstacles)
	return clamp_bounds(pos, half)


static func clamp_bounds(p: Vector3, half: float) -> Vector3:
	p.x = clampf(p.x, -half + 1.0, half - 1.0)
	p.z = clampf(p.z, -half + 1.0, half - 1.0)
	return p


## Pushes `p` out of the closest face of any grown AABB. Identical to the former
## WorldService._resolve_obstacles (including the 0.001 skin so the point leaves
## the box instead of landing exactly on the boundary).
static func resolve_obstacles(p: Vector3, obstacles: Array,
		radius: float = Protocol.PLAYER_RADIUS) -> Vector3:
	for box: AABB in obstacles:
		var grown := box.grow(radius)
		if not grown.has_point(p):
			continue
		var left := p.x - grown.position.x
		var right := grown.end.x - p.x
		var back := p.z - grown.position.z
		var front := grown.end.z - p.z
		var smallest: float = min(min(left, right), min(back, front))
		if smallest == left:
			p.x = grown.position.x - 0.001
		elif smallest == right:
			p.x = grown.end.x + 0.001
		elif smallest == back:
			p.z = grown.position.z - 0.001
		else:
			p.z = grown.end.z + 0.001
	return p
