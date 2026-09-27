extends RefCounted
## Boundary tests for the shared pure movement maths (shared/sim/movement.gd).
##
## WB6 reuses these same functions for client prediction, so the clamp / push-out
## / non-finite behaviour is part of the two-end contract and must not drift.

const EPS := 0.0001


func cases() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_test_clamp_bounds(out)
	_test_resolve_obstacles(out)
	_test_non_finite_rejection(out)
	_test_step(out)
	return out


func _add(out: Array[Dictionary], name: String, ok: bool, detail: String = "") -> void:
	out.append({"name": name, "ok": ok, "detail": detail})


# --- map bounds clamp (Movement.clamp_bounds) -------------------------------

func _test_clamp_bounds(out: Array[Dictionary]) -> void:
	var half := Protocol.MAP_HALF
	var limit := half - 1.0

	var far := Movement.clamp_bounds(Vector3(half + 5.0, 1.0, -half - 5.0), half)
	_add(out, "clamp_bounds_clamps_both_axes",
		is_equal_approx(far.x, limit) and is_equal_approx(far.z, -limit), str(far))

	var near := Movement.clamp_bounds(Vector3(limit - 0.5, 1.0, -limit + 0.5), half)
	_add(out, "clamp_bounds_keeps_inside_point",
		is_equal_approx(near.x, limit - 0.5) and is_equal_approx(near.z, -limit + 0.5), str(near))

	var on_edge := Movement.clamp_bounds(Vector3(limit, 1.0, limit), half)
	_add(out, "clamp_bounds_edge_is_inclusive",
		is_equal_approx(on_edge.x, limit) and is_equal_approx(on_edge.z, limit), str(on_edge))

	var vertical := Movement.clamp_bounds(Vector3(1.0, 7.5, 2.0), half)
	_add(out, "clamp_bounds_leaves_y_untouched", is_equal_approx(vertical.y, 7.5), str(vertical))


# --- AABB obstacle push-out (Movement.resolve_obstacles) --------------------

func _test_resolve_obstacles(out: Array[Dictionary]) -> void:
	var radius := Protocol.PLAYER_RADIUS
	var box := AABB(Vector3(0.0, 0.0, 0.0), Vector3(2.0, 2.0, 2.0))
	var obstacles: Array = [box]
	# Grown box spans [-radius, 2+radius] on every horizontal axis.
	var lo := -radius
	var hi := 2.0 + radius
	var skin := 0.001

	var outside := Movement.resolve_obstacles(Vector3(10.0, 1.0, 10.0), obstacles, radius)
	_add(out, "resolve_obstacles_ignores_point_outside",
		is_equal_approx(outside.x, 10.0) and is_equal_approx(outside.z, 10.0), str(outside))

	var left := Movement.resolve_obstacles(Vector3(0.1, 1.0, 1.0), obstacles, radius)
	_add(out, "resolve_obstacles_pushes_left_face",
		is_equal_approx(left.x, lo - skin) and is_equal_approx(left.z, 1.0), str(left))

	var right := Movement.resolve_obstacles(Vector3(1.9, 1.0, 1.0), obstacles, radius)
	_add(out, "resolve_obstacles_pushes_right_face",
		is_equal_approx(right.x, hi + skin) and is_equal_approx(right.z, 1.0), str(right))

	var back := Movement.resolve_obstacles(Vector3(1.0, 1.0, 0.1), obstacles, radius)
	_add(out, "resolve_obstacles_pushes_back_face",
		is_equal_approx(back.z, lo - skin) and is_equal_approx(back.x, 1.0), str(back))

	var front := Movement.resolve_obstacles(Vector3(1.0, 1.0, 1.9), obstacles, radius)
	_add(out, "resolve_obstacles_pushes_front_face",
		is_equal_approx(front.z, hi + skin) and is_equal_approx(front.x, 1.0), str(front))

	var y_kept := Movement.resolve_obstacles(Vector3(0.1, 3.0, 1.0), obstacles, radius)
	_add(out, "resolve_obstacles_leaves_y_untouched", is_equal_approx(y_kept.y, 3.0), str(y_kept))


# --- non-finite input rejection ---------------------------------------------

func _test_non_finite_rejection(out: Array[Dictionary]) -> void:
	_add(out, "is_input_finite_accepts_valid",
		Movement.is_input_finite(Vector2(0.0, 1.0), 0.5), "finite move/yaw")
	_add(out, "is_input_finite_rejects_inf_yaw",
		not Movement.is_input_finite(Vector2(0.0, 1.0), INF), "yaw=INF")
	_add(out, "is_input_finite_rejects_nan_yaw",
		not Movement.is_input_finite(Vector2(0.0, 1.0), NAN), "yaw=NAN")
	_add(out, "is_input_finite_rejects_nan_move",
		not Movement.is_input_finite(Vector2(NAN, 0.0), 0.0), "move=Vector2(NAN,0)")
	_add(out, "is_input_finite_rejects_inf_move",
		not Movement.is_input_finite(Vector2(INF, 0.0), 0.0), "move=Vector2(INF,0)")

	# The production guard is WorldState.set_input (the server) - a crafted INF
	# yaw must never reach the authoritative inputs table.
	var state := WorldState.new()
	state.entities[1] = EntityState.create(1, Protocol.EntityKind.PLAYER, "A", Vector3.ZERO, Protocol.PLAYER_MAX_HP)
	state.set_input(1, 0, Vector2(0.0, 1.0), INF, 0)
	_add(out, "world_state_drops_inf_yaw", state.inputs.is_empty(), "inputs=%s" % str(state.inputs))
	state.set_input(1, 1, Vector2(0.0, 1.0), 0.25, 0)
	_add(out, "world_state_accepts_finite", state.inputs.has(1), "inputs=%s" % str(state.inputs))


# --- deterministic step ------------------------------------------------------

func _test_step(out: Array[Dictionary]) -> void:
	var half := Protocol.MAP_HALF
	var floor_y := Protocol.SPAWN_POINT.y
	var obstacles: Array = []
	var speed := Protocol.MOVE_SPEED
	var dt := Protocol.TICK_DT

	# Forward (move.y = 1) with yaw 0 is -Z in world space.
	var p := Movement.step(Vector3.ZERO, Vector2(0.0, 1.0), 0.0, dt, speed, obstacles, half, floor_y)
	var expected_z := -speed * dt
	_add(out, "step_forward_yaw0_moves_neg_z",
		is_equal_approx(p.x, 0.0) and is_equal_approx(p.z, expected_z) and is_equal_approx(p.y, floor_y),
		str(p))

	# Distance is speed*dt regardless of yaw.
	var q := Movement.step(Vector3(1.0, 1.0, 2.0), Vector2(0.0, 1.0), PI * 0.5, dt, speed, obstacles, half, floor_y)
	var travelled := Vector3(1.0, 1.0, 2.0).distance_to(q)
	_add(out, "step_distance_is_speed_times_dt",
		is_equal_approx(travelled, speed * dt), "%.5f vs %.5f" % [travelled, speed * dt])

	# No intent still re-pins the floor and re-clamps (original behaviour).
	var idle := Movement.step(Vector3(0.0, 9.0, 0.0), Vector2.ZERO, 0.0, dt, speed, obstacles, half, floor_y)
	_add(out, "step_idle_repins_floor", is_equal_approx(idle.y, floor_y), str(idle))

	var beyond := Movement.step(Vector3(half + 10.0, floor_y, 0.0), Vector2.ZERO, 0.0, dt, speed, obstacles, half, floor_y)
	_add(out, "step_idle_reclamps_bounds", is_equal_approx(beyond.x, half - 1.0), str(beyond))
