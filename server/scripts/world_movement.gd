class_name WorldMovement
extends RefCounted
## Player movement for one world tick (WB0 extraction; shared maths live in
## `Movement`, which WB6 also reuses for client prediction).
##
## This class only resolves positions. Respawn, damage and broadcasting stay in
## WorldSync/WorldMobs so the three subsystems stay independently ownable.
##
## WB6 seam: after a player's input is applied we emit `s2c_input_ack(seq)` for
## the seq that was just processed, which is what the client's Prediction uses to
## discard confirmed inputs. Only seq advances are acked, so an idle player costs
## no ack traffic.

var state: WorldState
var obstacles: Array[AABB] = []
var half := Protocol.MAP_HALF
var speed := Protocol.MOVE_SPEED
var floor_y := Protocol.SPAWN_POINT.y

## peer_id -> highest input seq already acked (prediction support, S-N-1).
var _acked: Dictionary = {}


func setup(p_state: WorldState, p_obstacles: Array[AABB], p_half: float) -> void:
	state = p_state
	obstacles = p_obstacles
	half = p_half


## Advances every living player by one tick. Returns the ids of dead players
## whose respawn timer elapsed, so the facade can hand them to WorldSync after
## the movement pass (identical to the original single-pass ordering: a player
## respawned this tick is not moved again until the next tick).
func step_players(delta: float) -> Array[int]:
	var now := Time.get_ticks_msec()
	var to_respawn: Array[int] = []
	for id: int in state.entities.keys():
		var e: EntityState = state.entities[id]
		if e.kind != Protocol.EntityKind.PLAYER:
			continue
		if not e.alive:
			if now >= int(state.respawn_at.get(id, 0)):
				to_respawn.append(id)
			continue
		var inp: Dictionary = state.inputs.get(id, {})
		if inp.is_empty():
			continue
		e.yaw = float(inp.get("yaw", e.yaw))
		var move: Vector2 = inp.get("move", Vector2.ZERO)
		e.pos = Movement.step(e.pos, move, e.yaw, delta, speed, obstacles, half, floor_y)
		_ack(id, int(inp.get("seq", -1)))
	return to_respawn


## Acknowledges the seq we just processed. Sent reliable so a late ack is never
## lost; `unreliable_ordered` input means we ack the latest applied seq, and the
## client replays everything after it.
func _ack(peer_id: int, seq: int) -> void:
	if seq < 0:
		return
	var last := int(_acked.get(peer_id, -1))
	if seq < last:
		# A lower seq on an existing peer means a reused peer id started a fresh
		# input stream (seq restarts at 1); drop the stale high-water mark.
		_acked.erase(peer_id)
		last = -1
	if seq <= last:
		return
	_acked[peer_id] = seq
	if Net.multiplayer == null or Net.multiplayer.multiplayer_peer == null:
		return
	Net.s2c_input_ack.rpc_id(peer_id, seq)
