class_name WorldMovement
extends RefCounted
## Player movement for one world tick (WB0 extraction; shared maths live in
## `Movement`, which WB6 will also reuse for client prediction).
##
## This class only resolves positions. Respawn, damage and broadcasting stay in
## WorldSync/WorldMobs so the three subsystems stay independently ownable.

var state: WorldState
var obstacles: Array[AABB] = []
var half := Protocol.MAP_HALF
var speed := Protocol.MOVE_SPEED
var floor_y := Protocol.SPAWN_POINT.y


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
	return to_respawn
