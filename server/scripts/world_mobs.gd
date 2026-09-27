class_name WorldMobs
extends RefCounted
## Mob population: spawning, the simple chase AI, melee swings and respawn
## (WB0 extraction; the richer aggro/patrol AI is a later P1 system).

var state: WorldState
var sync: WorldSync
var obstacles: Array[AABB] = []
var half := Protocol.MAP_HALF


func setup(p_state: WorldState, p_sync: WorldSync, p_obstacles: Array[AABB], p_half: float) -> void:
	state = p_state
	sync = p_sync
	obstacles = p_obstacles
	half = p_half


func spawn_all() -> void:
	var offsets := [
		Vector3(10.0, 0.0, 10.0),
		Vector3(-12.0, 0.0, -6.0),
		Vector3(8.0, 0.0, -14.0),
	]
	for i in range(Protocol.MOB_COUNT):
		var id := Protocol.MOB_ID_BASE + i
		var pos: Vector3 = Protocol.SPAWN_POINT + offsets[i % offsets.size()]
		pos.y = Protocol.SPAWN_POINT.y
		var mob := EntityState.create(
			id, Protocol.EntityKind.MOB, "Wolf %d" % (i + 1), pos, Protocol.MOB_MAX_HP)
		state.entities[id] = mob


func step(delta: float) -> void:
	var now := Time.get_ticks_msec()
	for id: int in state.entities.keys():
		var e: EntityState = state.entities[id]
		if e.kind != Protocol.EntityKind.MOB:
			continue
		if not e.alive:
			if now >= int(state.respawn_at.get(id, 0)):
				sync.respawn_mob(e)
			continue
		var target := nearest_living_player(e.pos)
		if target == null:
			continue
		var to := target.pos - e.pos
		to.y = 0.0
		if to.length() > 0.01:
			e.yaw = atan2(-to.x, -to.z)
		if to.length() > Protocol.MOB_ATTACK_RANGE:
			e.pos = Movement.move_world(
				e.pos, to.normalized(), Protocol.MOB_SPEED, delta, obstacles, half,
				Protocol.SPAWN_POINT.y)
		elif now >= int(state.mob_next_attack.get(id, 0)):
			state.mob_next_attack[id] = now + int(Protocol.MOB_ATTACK_COOLDOWN * 1000.0)
			sync.apply_damage(target.id, Protocol.MOB_DAMAGE, id)


func nearest_living_player(from: Vector3) -> EntityState:
	var best: EntityState = null
	var best_dist := Protocol.MOB_AGGRO_RANGE
	for id: int in state.entities.keys():
		var e: EntityState = state.entities[id]
		if e.kind != Protocol.EntityKind.PLAYER or not e.alive:
			continue
		var d := from.distance_to(e.pos)
		if d < best_dist:
			best_dist = d
			best = e
	return best
