class_name Prediction
extends RefCounted
## Client-side prediction + server reconciliation for the local player (S-N-1).
##
## The client applies its own input immediately using the *shared* Movement maths
## (shared/sim/movement.gd, never a copy), caches the unacked inputs by seq, and on
## every authoritative snapshot discards confirmed inputs, re-bases on the server
## position and replays the rest. Small corrections are smoothed exponentially,
## large ones snap (the plan's "平滑纠偏": 误差小用指数衰减，大偏差快速收敛).
##
## This class is pure: no Node, no RPC, no rendering. NetInput drives it and
## WorldView reads `render_position()` for the local EntityView.
##
## Non-finite guard: `apply_input` refuses INF/NaN exactly like the server's
## WorldState.set_input (via Movement.is_input_finite), so a crafted packet can
## never poison the predicted position.

## Correction larger than this snaps instead of smoothing (metres).
const SNAP_DISTANCE := 2.0
## Exponential decay rate of the smoothing offset (1/sec).
const SMOOTH_RATE := 12.0
## Safety cap on the unacked history, so a dropped connection cannot grow it
## without bound.
const MAX_PENDING := 128

var speed := Protocol.MOVE_SPEED
var half := Protocol.MAP_HALF
var floor_y := Protocol.SPAWN_POINT.y
## Static map AABBs, built from the same Protocol constants the server uses.
var obstacles: Array = []

## Unacked inputs, oldest first: {"seq": int, "move": Vector2, "yaw": float, "dt": float}.
var pending: Array = []
var sim_pos := Vector3.ZERO
## Display-only correction that decays to zero (keeps rendering continuous).
var error_offset := Vector3.ZERO
var last_yaw := 0.0
## True between world_entered and despawn/reset.
var active := false

# --- stats, consumed by the bot checks --------------------------------------
var applied := 0
var moves := 0
var reconciles := 0
var snaps := 0
var correction_max := 0.0
var correction_sum := 0.0
var feedback_usec_max := 0


func _init() -> void:
	# Same grown-AABB geometry the server builds in world.gd._build_map: the cover
	# box is centred on `pos` in x/z (its node sits at pos + half height, so the
	# AABB position is pos - size*0.5 in x/z, with its base at floor height).
	var size := Protocol.COVER_SIZE
	var half_xz := Vector3(size.x * 0.5, 0.0, size.z * 0.5)
	for pos in Protocol.COVER_POSITIONS:
		obstacles.append(AABB(pos - half_xz, size))


## (Re)bases the predictor on an authoritative position (world entry / respawn).
func reset(pos: Vector3) -> void:
	sim_pos = pos
	error_offset = Vector3.ZERO
	pending.clear()
	last_yaw = 0.0
	active = true


func clear() -> void:
	pending.clear()
	sim_pos = Vector3.ZERO
	error_offset = Vector3.ZERO
	active = false


## What the local EntityView should be drawn at.
func render_position() -> Vector3:
	return sim_pos + error_offset


## Applies one local input immediately. Returns false (does nothing) for
## non-finite input or when not active, matching the server-side guard.
func apply_input(seq: int, move: Vector2, yaw: float, dt: float = Protocol.TICK_DT) -> bool:
	if not active or not Movement.is_input_finite(move, yaw):
		return false
	var before := Time.get_ticks_usec()
	sim_pos = Movement.step(sim_pos, move, yaw, dt, speed, obstacles, half, floor_y)
	last_yaw = yaw
	applied += 1
	if move.length() > 0.001:
		moves += 1
	var spent := Time.get_ticks_usec() - before
	if spent > feedback_usec_max:
		feedback_usec_max = spent
	if pending.size() >= MAX_PENDING:
		pending.pop_front()
	pending.append({"seq": seq, "move": move, "yaw": yaw, "dt": dt})
	return true


## Discards inputs the server confirmed (seq <= acked_seq), re-bases on
## `server_pos` and replays every remaining input. The distance between the old
## simulation and the replayed one is the correction: it is smoothed when small
## and snapped when large.
func reconcile(server_pos: Vector3, acked_seq: int) -> void:
	if not active:
		return
	var discard := 0
	while discard < pending.size() and int(pending[discard].get("seq", -1)) <= acked_seq:
		discard += 1
	if discard > 0:
		pending = pending.slice(discard)

	var old_sim := sim_pos
	var old_render := sim_pos + error_offset
	var next := server_pos
	for item: Dictionary in pending:
		next = Movement.step(
			next,
			item.get("move", Vector2.ZERO),
			float(item.get("yaw", 0.0)),
			float(item.get("dt", Protocol.TICK_DT)),
			speed, obstacles, half, floor_y)
	sim_pos = next

	var correction := old_sim.distance_to(next)
	correction_max = maxf(correction_max, correction)
	correction_sum += correction
	reconciles += 1
	if correction > SNAP_DISTANCE:
		snaps += 1
		error_offset = Vector3.ZERO
	else:
		# Absorb the whole correction into the smoothing offset so the render
		# stays continuous, then let `advance` decay it.
		error_offset = old_render - next


## Decays the smoothing offset toward zero. Called every frame.
func advance(delta: float) -> void:
	if error_offset.length_squared() <= 1.0e-12:
		error_offset = Vector3.ZERO
		return
	error_offset = error_offset.lerp(Vector3.ZERO, clampf(delta * SMOOTH_RATE, 0.0, 1.0))


func error_avg() -> float:
	return correction_sum / maxf(1.0, float(reconciles))
