class_name NetInput
extends Node
## Client -> server intent senders, the input tick throttle / sequence counter
## and the local prediction driver (WB0 split; WB6 owns the input history cache
## and prediction replay).
##
## The application calls `tick_input(delta, ...)` every frame; this class emits at
## the contract rate (Protocol.TICK_DT), stamps the seq, and applies the same
## input to the local `Prediction` immediately (zero-frame feedback). It also
## consumes `Net.input_ack_received` / `Net.world_state_received` to reconcile:
## the ack tells us which inputs the server confirmed, the world state gives the
## authoritative position to re-base on.
##
## Self-test latency injection: pass `--net-latency <ms>` (client user args) to
## delay the *authoritative* path (acks + snapshots) by that many milliseconds.
## The local path stays immediate, so a run with `--net-latency 150` demonstrates
## S-N-1's acceptance criterion (feedback < 50ms, convergence < 0.5m) without a
## second machine. Default 0 = real behaviour.

var transport: NetTransport

var seq := 0
var local_id := 0
var in_world := false
## Counts `s2c_input_ack` messages received; the bot asserts reconciliation is
## actually ack-driven.
var acks_received := 0
## One-way delay applied to authoritative messages, in seconds (0 = off).
var latency_sec := 0.0

## Local prediction + reconciliation state (read by WorldView and the bot checks).
var predictor: Prediction = Prediction.new()

var _accum := 0.0
var _acked_seq := -1
var _server_pos := Vector3.ZERO
var _have_server_pos := false
## Set when an authoritative pos/ack changes; reconciled once per frame so a
## snapshot and its ack that arrive in the same frame pair up correctly.
var _reconcile_dirty := false
## Deferred authoritative events when latency injection is on:
## {"at": int(usec), "kind": String, "payload": Variant}.
var _deferred: Array = []


func _ready() -> void:
	_parse_args()
	Net.world_entered.connect(_on_world_entered)
	Net.entity_spawned.connect(_on_entity_spawned)
	Net.entity_despawned.connect(_on_entity_despawned)
	Net.world_state_received.connect(_on_world_state_received)
	Net.input_ack_received.connect(_on_input_ack)


func setup(p_transport: NetTransport) -> void:
	transport = p_transport


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var arg: String = args[i]
		if arg == "--net-latency" and i + 1 < args.size():
			i += 1
			latency_sec = maxf(0.0, float(args[i]) / 1000.0)
		elif arg.begins_with("--net-latency="):
			latency_sec = maxf(0.0, float(arg.substr("--net-latency=".length())) / 1000.0)
		i += 1
	if latency_sec > 0.0:
		print("[net] authoritative latency injection: %.0fms" % (latency_sec * 1000.0))


## Frame-driven input: throttled to the tick rate, predicted locally, then sent.
func tick_input(delta: float, move: Vector2, yaw: float, buttons: int) -> void:
	_accum += delta
	if _accum < Protocol.TICK_DT:
		return
	_accum = 0.0
	seq += 1
	# Local feedback happens here, before the packet leaves: same shared maths the
	# server runs, so at LAN latency the two agree to within a step.
	predictor.apply_input(seq, move, yaw, Protocol.TICK_DT)
	send_input(seq, move, yaw, buttons)


## Fraction of the current prediction tick elapsed (0..1), used by WorldView to
## interpolate the local player's displayed transform between ticks.
func tick_alpha() -> float:
	return clampf(_accum / Protocol.TICK_DT, 0.0, 1.0)


func send_input(seq_value: int, move: Vector2, yaw: float, buttons: int) -> bool:
	if not _can_send():
		return false
	Net.c2s_input.rpc_id(1, seq_value, move, yaw, buttons)
	return true


func use_ability(ability_id: int, target_id: int) -> void:
	if not _can_send():
		return
	Net.c2s_use_ability.rpc_id(1, ability_id, target_id)


func request_character_list() -> void:
	if not _can_send():
		return
	Net.c2s_list_characters.rpc_id(1)


func create_character(char_name: String, class_id: int) -> void:
	if not _can_send():
		return
	Net.c2s_create_character.rpc_id(1, char_name, class_id)


func select_character(char_id: int) -> void:
	if not _can_send():
		return
	Net.c2s_select_character.rpc_id(1, char_id)


func move_item(from_slot: int, to_slot: int) -> void:
	if not _can_send():
		return
	Net.c2s_move_item.rpc_id(1, from_slot, to_slot)


func equip_item(inv_slot: int, equip_slot: int) -> void:
	if not _can_send():
		return
	Net.c2s_equip_item.rpc_id(1, inv_slot, equip_slot)


func unequip_item(equip_slot: int, inv_slot: int) -> void:
	if not _can_send():
		return
	Net.c2s_unequip_item.rpc_id(1, equip_slot, inv_slot)


func change_zone(zone_id: int, channel_id: int) -> void:
	if not _can_send():
		return
	Net.c2s_change_zone.rpc_id(1, zone_id, channel_id)


func _can_send() -> bool:
	return transport != null and transport.can_send()


# --- authoritative input -----------------------------------------------------

func _on_world_entered(self_id: int, spawn: Vector3, _hp: int) -> void:
	local_id = self_id
	in_world = true
	_acked_seq = -1
	_server_pos = spawn
	_have_server_pos = true
	_deferred.clear()
	predictor.reset(spawn)


func _on_entity_despawned(id: int) -> void:
	if id != local_id or local_id == 0:
		return
	local_id = 0
	in_world = false
	_acked_seq = -1
	_have_server_pos = false
	_deferred.clear()
	predictor.clear()


## The server teleports the local player on respawn (and re-sends its spawn on
## (re)entry): re-base the predictor there and drop the stale input history, which
## the server ignored while the player was dead.
func _on_entity_spawned(state: Dictionary) -> void:
	if not in_world or local_id == 0 or int(state.get("id", 0)) != local_id:
		return
	if not state.has("pos"):
		return
	var pos: Vector3 = state.get("pos", _server_pos)
	_server_pos = pos
	_have_server_pos = true
	_acked_seq = -1
	_reconcile_dirty = false
	predictor.reset(pos)


func _on_world_state_received(_tick: int, list: Array) -> void:
	if not in_world or local_id == 0:
		return
	for entry: Dictionary in list:
		if int(entry.get("id", 0)) == local_id:
			_defer("pos", entry.get("pos", _server_pos))
			return


func _on_input_ack(ack_seq: int) -> void:
	if not in_world:
		return
	acks_received += 1
	_defer("ack", ack_seq)


func _defer(kind: String, payload: Variant) -> void:
	if latency_sec <= 0.0:
		_apply_event(kind, payload)
	else:
		_deferred.append({
			"at": Time.get_ticks_usec() + int(latency_sec * 1_000_000.0),
			"kind": kind,
			"payload": payload,
		})


func _process(delta: float) -> void:
	if not _deferred.is_empty():
		var now := Time.get_ticks_usec()
		var remaining: Array = []
		for event: Dictionary in _deferred:
			if now >= int(event.get("at", 0)):
				_apply_event(String(event.get("kind", "")), event.get("payload"))
			else:
				remaining.append(event)
		_deferred = remaining
	# Reconcile at most once per frame, after every authoritative event for this
	# frame has been applied (pos + ack pair up), then decay the smoothing offset.
	if _reconcile_dirty:
		_reconcile_dirty = false
		if _have_server_pos:
			predictor.reconcile(_server_pos, _acked_seq, tick_alpha())
	predictor.advance(delta)


func _apply_event(kind: String, payload: Variant) -> void:
	match kind:
		"pos":
			_server_pos = payload
			_have_server_pos = true
		"ack":
			_acked_seq = maxi(_acked_seq, int(payload))
	_reconcile_dirty = true
