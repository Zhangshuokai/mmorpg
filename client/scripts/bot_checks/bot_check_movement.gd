class_name BotCheckMovement
extends BotCheck
## Movement / replication / client-prediction assertions (WB6 owns this domain).
##
## Prediction checks read the live `Prediction` the bot drives through
## `NetInput` (the same code path a real client uses), so no separate harness is
## needed. The jitter-buffer checks are pure and deterministic: they exercise
## `EntityView.sample_buffer` directly.

func evaluate() -> Array:
	var remote_required: bool = bot.require_remote
	var results: Array = [
		{
			"order": 60, "name": "movement", "required": true,
			"ok": bot._moved >= MOVE_EPSILON, "detail": "moved %.2fm" % bot._moved,
		},
		{
			"order": 70, "name": "world_state_ticks", "required": true,
			"ok": bot._ticks > 0, "detail": "%d ticks" % bot._ticks,
		},
		{
			"order": 120, "name": "remote_player_moved", "required": remote_required,
			"ok": bot._remote_travel >= MOVE_EPSILON, "detail": "%.2fm" % bot._remote_travel,
		},
	]
	results.append_array(_prediction_checks())
	results.append_array(_jitter_buffer_checks())
	results.append_array(_guard_checks())
	return results


func _net_input() -> NetInput:
	if bot == null or bot.net == null:
		return null
	return bot.net.input


func _prediction_checks() -> Array:
	var net_input := _net_input()
	var predictor: Prediction = null if net_input == null else net_input.predictor
	# Only gate the run once the bot actually entered the world; otherwise the
	# earlier session checks already explain the failure.
	var required: bool = bot._enter_world
	var applied := 0
	var reconciles := 0
	var moves := 0
	var error_avg := 0.0
	var error_max := 0.0
	var feedback_ms := 0.0
	var snaps := 0
	var acks := 0
	if predictor != null:
		applied = predictor.applied
		reconciles = predictor.reconciles
		moves = predictor.moves
		error_avg = predictor.error_avg()
		error_max = predictor.correction_max
		feedback_ms = float(predictor.feedback_usec_max) / 1000.0
		snaps = predictor.snaps
	if net_input != null:
		acks = net_input.acks_received
	var active := applied > 0 and reconciles > 0 and moves > 0
	return [
		{
			"order": 130, "name": "prediction_active", "required": required,
			"ok": active,
			"detail": "%d inputs / %d reconciles / %d moves" % [applied, reconciles, moves],
		},
		{
			"order": 135, "name": "prediction_ack_received", "required": required,
			# Reconciliation must be driven by the server's input ack, not just by
			# replaying a locally-growing history.
			"ok": acks > 0, "detail": "%d acks" % acks,
		},
		{
			"order": 140, "name": "prediction_feedback", "required": required,
			# Local input is applied synchronously in tick_input (same call), so the
			# measured cost must stay far below the 50ms acceptance bound; no server
			# round trip is involved.
			"ok": active and feedback_ms < 50.0, "detail": "%.2fms local apply" % feedback_ms,
		},
		{
			"order": 150, "name": "prediction_convergence", "required": required,
			# Average per-reconcile correction: how far the prediction was from the
			# server's replay for the same inputs. Acceptance: < 0.5m.
			"ok": active and error_avg < 0.5,
			"detail": "avg %.3fm max %.3fm" % [error_avg, error_max],
		},
		{
			"order": 160, "name": "prediction_snap_count", "required": false,
			"ok": snaps == 0, "detail": "%d hard snaps" % snaps,
		},
	]


## Deterministic jitter-buffer assertions (no network involved).
func _jitter_buffer_checks() -> Array:
	var dt := Protocol.TICK_DT
	var buffer: Array = [
		{"t": 1.0, "pos": Vector3(0.0, 1.0, 0.0), "yaw": 0.0},
		{"t": 1.0 + dt, "pos": Vector3(10.0, 1.0, 0.0), "yaw": 0.0},
		{"t": 1.0 + dt * 2.0, "pos": Vector3(20.0, 1.0, 0.0), "yaw": 0.0},
	]
	var mid := EntityView.sample_buffer(buffer, 1.0 + dt * 0.5)
	var mid_ok := not mid.is_empty() \
			and float(mid["pos"].x) > 0.0 and float(mid["pos"].x) < 10.0
	var clamped := EntityView.sample_buffer(buffer, 1.0 - 5.0)
	var clamp_ok := not clamped.is_empty() \
			and absf(float(clamped["pos"].x) - 0.0) < 0.001
	var delay_ok := absf(EntityView.INTERP_DELAY_SEC - dt * 3.0) < 0.0001
	return [
		{
			"order": 170, "name": "jitter_buffer_interp", "required": true,
			"ok": mid_ok, "detail": "mid x=%.2f" % float(mid.get("pos", Vector3.ZERO).x),
		},
		{
			"order": 180, "name": "jitter_buffer_depth", "required": true,
			"ok": delay_ok, "detail": "%.0fms (~3x send)" % (EntityView.INTERP_DELAY_SEC * 1000.0),
		},
		{
			"order": 190, "name": "jitter_buffer_clamp", "required": true,
			"ok": clamp_ok, "detail": "starved -> holds oldest",
		},
	]


## The client must reject INF/NaN input exactly like the server does, otherwise a
## crafted packet could poison the predicted position (Movement.is_input_finite).
func _guard_checks() -> Array:
	var probe := Prediction.new()
	probe.reset(Vector3.ZERO)
	var before := probe.sim_pos
	var inf_accepted := probe.apply_input(1, Vector2(INF, 0.0), 0.0, Protocol.TICK_DT)
	var nan_accepted := probe.apply_input(2, Vector2(NAN, NAN), NAN, Protocol.TICK_DT)
	var after_invalid := probe.sim_pos
	var finite_accepted := probe.apply_input(3, Vector2(0.0, 1.0), 0.0, Protocol.TICK_DT)
	return [
		{
			"order": 200, "name": "prediction_nonfinite_guard", "required": true,
			"ok": not inf_accepted and not nan_accepted and after_invalid == before,
			"detail": "INF/NaN rejected, position unchanged",
		},
		{
			"order": 210, "name": "prediction_finite_accepted", "required": true,
			"ok": finite_accepted and probe.sim_pos != before,
			"detail": "finite input still applied",
		},
	]
