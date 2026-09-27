class_name WorldService
extends Node3D
## Authoritative world facade. Runs entirely on the server main thread.
##
## WB0 split the former 366-line implementation into independently ownable
## subsystems; this facade keeps the stable public surface used by
## server/scripts/main.gd and combat.gd, and drives one world tick per
## `_physics_process` call (20Hz):
##
##   WorldState      containers + input validation            (WB0)
##   WorldMovement   player movement (shared Movement maths)  (WB6)
##   WorldMobs       mob spawning/AI/respawn                  (P1 AI later)
##   WorldSync       spawn/despawn/broadcast/damage           (WB4 broadcast)
##   world.gd        map build + tick orchestration           (WB0)
##
## The server never reads a position, yaw, hp or damage value from a client:
## clients only submit inputs (c2s_input) and ability intents (c2s_use_ability).

const MAP_HALF := Protocol.MAP_HALF

var persistence: PersistenceService

## Debug switch (server --no-mobs): when false the world starts with no enemies,
## which lets multiplayer/player-replication be exercised in isolation.
var spawn_mobs_enabled := true

var tick := 0

var _state := WorldState.new()
var _movement := WorldMovement.new()
var _mobs := WorldMobs.new()
var _sync := WorldSync.new()

## Backward-compatible aliases for the exact Dictionary objects held by _state.
## combat.gd mutates `world.cooldowns[...]`, so these must be the same objects,
## not copies (GDScript Dictionaries are reference types).
var entities: Dictionary = _state.entities
var inputs: Dictionary = _state.inputs
var sessions: Dictionary = _state.sessions
var cooldowns: Dictionary = _state.cooldowns
var respawn_at: Dictionary = _state.respawn_at

var _obstacles: Array[AABB] = []
var _built := false


func setup(p_persistence: PersistenceService) -> void:
	persistence = p_persistence
	if _built:
		return
	_build_map()
	_sync.setup(self, _state)
	_movement.setup(_state, _obstacles, MAP_HALF)
	_mobs.setup(_state, _sync, _obstacles, MAP_HALF)
	if spawn_mobs_enabled:
		_mobs.spawn_all()
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


# --- players ----------------------------------------------------------------

func add_player(peer_id: int, sheet: CharacterSheet) -> void:
	_sync.add_player(peer_id, sheet)


func remove_player(peer_id: int, announce: bool = true) -> void:
	_sync.remove_player(peer_id, announce)


func player_peers() -> Array:
	return _state.player_peers()


func set_input(peer_id: int, seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	_state.set_input(peer_id, seq, move, yaw, buttons)


# --- tick -------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not _built:
		return
	tick += 1
	_state.decay_cooldowns(delta)
	for id: int in _movement.step_players(delta):
		_sync.respawn_player(entities[id])
	_mobs.step(delta)
	_sync.flush_despawns()
	_sync.broadcast(tick)


# --- damage -----------------------------------------------------------------

## Applies authoritative damage. `amount` is decided by the server only.
func apply_damage(target_id: int, amount: int, source_id: int = 0) -> int:
	return _sync.apply_damage(target_id, amount, source_id)


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
