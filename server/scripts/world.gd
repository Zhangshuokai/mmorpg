class_name WorldService
extends Node3D
## Authoritative single-zone world: entities, movement, mob AI and 20Hz state
## broadcast. Runs entirely on the server main thread.
##
## The server never reads a position, yaw, hp or damage value from a client:
## clients only submit inputs (c2s_input) and ability intents (c2s_use_ability).

const MAP_HALF := Protocol.MAP_HALF

var persistence: PersistenceService

## All replicated entities: peer_id (players) or MOB_ID_BASE+i (mobs).
var entities: Dictionary = {}
## peer_id -> {"seq": int, "move": Vector2, "yaw": float, "buttons": int}
var inputs: Dictionary = {}
## peer_id -> CharacterSheet (only for players currently in the world)
var sessions: Dictionary = {}
## peer_id -> float seconds of ability cooldown remaining
var cooldowns: Dictionary = {}
## id -> unix msec when the entity respawns
var respawn_at: Dictionary = {}
## mob id -> unix msec of next melee swing
var _mob_next_attack: Dictionary = {}

var tick := 0
var _obstacles: Array[AABB] = []
var _built := false


func setup(p_persistence: PersistenceService) -> void:
	persistence = p_persistence
	if not _built:
		_build_map()
		_spawn_mobs()
		_built = true


# --- map --------------------------------------------------------------------

func _build_map() -> void:
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var ground_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(MAP_HALF * 2.0, MAP_HALF * 2.0)
	ground_mesh.mesh = plane
	ground.add_child(ground_mesh)
	var ground_shape := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(MAP_HALF * 2.0, 0.2, MAP_HALF * 2.0)
	ground_shape.shape = ground_box
	ground_shape.position = Vector3(0.0, -0.1, 0.0)
	ground.add_child(ground_shape)
	add_child(ground)

	for pos in Protocol.COVER_POSITIONS:
		var size := Protocol.COVER_SIZE
		var cover := StaticBody3D.new()
		cover.name = "Cover"
		cover.position = pos + Vector3(0.0, size.y * 0.5, 0.0)
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mesh.mesh = box
		cover.add_child(mesh)
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		cover.add_child(shape)
		add_child(cover)
		_obstacles.append(AABB(cover.position - size * 0.5, size))


func _spawn_mobs() -> void:
	var offsets := [
		Vector3(10.0, 0.0, 10.0),
		Vector3(-12.0, 0.0, -6.0),
		Vector3(8.0, 0.0, -14.0),
	]
	for i in range(Protocol.MOB_COUNT):
		var id := Protocol.MOB_ID_BASE + i
		var pos: Vector3 = Protocol.SPAWN_POINT + offsets[i % offsets.size()]
		pos.y = Protocol.SPAWN_POINT.y
		var mob := EntityState.create(id, Protocol.EntityKind.MOB, "Wolf %d" % (i + 1), pos, Protocol.MOB_MAX_HP)
		entities[id] = mob


# --- players ----------------------------------------------------------------

func add_player(peer_id: int, sheet: CharacterSheet) -> void:
	remove_player(peer_id, true)
	var spawn := sheet.pos
	spawn.y = Protocol.SPAWN_POINT.y
	var player := EntityState.create(
		peer_id, Protocol.EntityKind.PLAYER, sheet.char_name, spawn, Protocol.PLAYER_MAX_HP)
	player.hp = clampi(sheet.hp, 1, Protocol.PLAYER_MAX_HP)
	player.class_id = sheet.class_id
	player.yaw = 0.0
	entities[peer_id] = player
	sessions[peer_id] = sheet
	inputs[peer_id] = {"seq": -1, "move": Vector2.ZERO, "yaw": 0.0, "buttons": 0}

	# The newcomer is told about itself and about everything already present.
	Net.s2c_enter_world.rpc_id(peer_id, peer_id, player.pos, player.hp)
	for other: EntityState in entities.values():
		Net.s2c_spawn_entity.rpc_id(peer_id, other.to_spawn_dict())
	# Everybody else is told about the newcomer.
	for peer in player_peers():
		if peer != peer_id:
			Net.s2c_spawn_entity.rpc_id(peer, player.to_spawn_dict())
	print("[world] %s (peer %d) entered the world at %s" % [player.display_name, peer_id, player.pos])


func remove_player(peer_id: int, announce: bool = true) -> void:
	if not entities.has(peer_id):
		return
	entities.erase(peer_id)
	inputs.erase(peer_id)
	sessions.erase(peer_id)
	cooldowns.erase(peer_id)
	respawn_at.erase(peer_id)
	if announce:
		Net.s2c_despawn_entity.rpc(peer_id)


func player_peers() -> Array:
	var out: Array = []
	for id: int in entities.keys():
		var e: EntityState = entities[id]
		if e.kind == Protocol.EntityKind.PLAYER:
			out.append(id)
	return out


func set_input(peer_id: int, seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	if not entities.has(peer_id):
		return
	# Reject non-finite input. A crafted INF/NaN would survive the length guard
	# below, make normalized()/rotated() produce NaN and permanently poison the
	# authoritative position (NaN comparisons are always false, so neither the
	# bounds clamp nor the obstacle resolve can recover), poisoning the broadcast
	# for every client and the value persisted by save_all().
	if not (move.is_finite() and is_finite(yaw)):
		push_warning("[world] non-finite input from peer %d ignored" % peer_id)
		return
	var current: Dictionary = inputs.get(peer_id, {"seq": -1})
	# Unreliable ordered transport already drops stale packets; the seq guard is
	# a cheap second line of defence.
	if seq >= int(current.get("seq", -1)):
		inputs[peer_id] = {"seq": seq, "move": move, "yaw": yaw, "buttons": buttons}


# --- tick -------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not _built:
		return
	tick += 1
	for id: int in cooldowns.keys():
		cooldowns[id] = max(0.0, float(cooldowns[id]) - delta)
	_step_players(delta)
	_step_mobs(delta)
	_broadcast()


func _step_players(delta: float) -> void:
	var now := Time.get_ticks_msec()
	for id: int in entities.keys():
		var e: EntityState = entities[id]
		if e.kind != Protocol.EntityKind.PLAYER:
			continue
		if not e.alive:
			if now >= int(respawn_at.get(id, 0)):
				_respawn_player(e)
			continue
		var inp: Dictionary = inputs.get(id, {})
		if inp.is_empty():
			continue
		e.yaw = float(inp.get("yaw", e.yaw))
		var move: Vector2 = inp.get("move", Vector2.ZERO)
		var dir := Vector3(move.x, 0.0, -move.y)
		if dir.length() > 0.001:
			dir = dir.normalized().rotated(Vector3.UP, e.yaw)
			e.pos += dir * Protocol.MOVE_SPEED * delta
		e.pos.y = Protocol.SPAWN_POINT.y
		e.pos = _clamp_bounds(_resolve_obstacles(e.pos))


func _step_mobs(delta: float) -> void:
	var now := Time.get_ticks_msec()
	for id: int in entities.keys():
		var e: EntityState = entities[id]
		if e.kind != Protocol.EntityKind.MOB:
			continue
		if not e.alive:
			if now >= int(respawn_at.get(id, 0)):
				_respawn_mob(e)
			continue
		var target := _nearest_living_player(e.pos)
		if target == null:
			continue
		var to := target.pos - e.pos
		to.y = 0.0
		if to.length() > 0.01:
			e.yaw = atan2(-to.x, -to.z)
		if to.length() > Protocol.MOB_ATTACK_RANGE:
			e.pos += to.normalized() * Protocol.MOB_SPEED * delta
			e.pos.y = Protocol.SPAWN_POINT.y
			e.pos = _clamp_bounds(_resolve_obstacles(e.pos))
		elif now >= int(_mob_next_attack.get(id, 0)):
			_mob_next_attack[id] = now + int(Protocol.MOB_ATTACK_COOLDOWN * 1000.0)
			apply_damage(target.id, Protocol.MOB_DAMAGE, id)


func _nearest_living_player(from: Vector3) -> EntityState:
	var best: EntityState = null
	var best_dist := Protocol.MOB_AGGRO_RANGE
	for id: int in entities.keys():
		var e: EntityState = entities[id]
		if e.kind != Protocol.EntityKind.PLAYER or not e.alive:
			continue
		var d := from.distance_to(e.pos)
		if d < best_dist:
			best_dist = d
			best = e
	return best


# --- damage / death / respawn ----------------------------------------------

## Applies authoritative damage. `amount` is decided by the server only.
func apply_damage(target_id: int, amount: int, source_id: int = 0) -> int:
	var target: EntityState = entities.get(target_id)
	if target == null or not target.alive:
		return -1
	target.hp = max(0, target.hp - amount)
	if target.hp == 0:
		target.alive = false
		_on_death(target)
	Net.s2c_combat_event.rpc(source_id, target_id, amount, target.hp)
	Net.s2c_hp_update.rpc(target_id, target.hp)
	return target.hp


func _on_death(entity: EntityState) -> void:
	if entity.kind == Protocol.EntityKind.MOB:
		respawn_at[entity.id] = Time.get_ticks_msec() + int(Protocol.MOB_RESPAWN_SEC * 1000.0)
		print("[world] mob %d died; respawn in %.0fs" % [entity.id, Protocol.MOB_RESPAWN_SEC])
	else:
		respawn_at[entity.id] = Time.get_ticks_msec() + int(Protocol.PLAYER_RESPAWN_SEC * 1000.0)
		var sheet: CharacterSheet = sessions.get(entity.id)
		if sheet != null:
			sheet.hp = 0
			sheet.pos = entity.pos
		print("[world] player %d died; respawn in %.0fs" % [entity.id, Protocol.PLAYER_RESPAWN_SEC])


func _respawn_player(entity: EntityState) -> void:
	entity.alive = true
	entity.hp = Protocol.PLAYER_MAX_HP
	entity.pos = Protocol.SPAWN_POINT
	entity.target_id = 0
	respawn_at.erase(entity.id)
	Net.s2c_hp_update.rpc_id(entity.id, entity.hp)
	Net.s2c_spawn_entity.rpc(entity.to_spawn_dict())


func _respawn_mob(entity: EntityState) -> void:
	entity.alive = true
	entity.hp = Protocol.MOB_MAX_HP
	entity.target_id = 0
	respawn_at.erase(entity.id)
	Net.s2c_spawn_entity.rpc(entity.to_spawn_dict())


# --- persistence ------------------------------------------------------------

func save_all() -> void:
	if persistence == null:
		return
	for id: int in sessions.keys():
		var sheet: CharacterSheet = sessions[id]
		var e: EntityState = entities.get(id)
		if e != null:
			sheet.hp = e.hp
			sheet.pos = e.pos
		persistence.save_character(sheet)


# --- broadcast --------------------------------------------------------------

func _broadcast() -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if multiplayer.get_peers().is_empty():
		return
	var snapshot: Array = []
	for id: int in entities.keys():
		var e: EntityState = entities[id]
		snapshot.append(e.to_net_dict())
	Net.s2c_world_state.rpc(tick, snapshot)


# --- movement helpers -------------------------------------------------------

func _clamp_bounds(p: Vector3) -> Vector3:
	p.x = clampf(p.x, -MAP_HALF + 1.0, MAP_HALF - 1.0)
	p.z = clampf(p.z, -MAP_HALF + 1.0, MAP_HALF - 1.0)
	return p


func _resolve_obstacles(p: Vector3) -> Vector3:
	for box: AABB in _obstacles:
		var grown := box.grow(Protocol.PLAYER_RADIUS)
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
