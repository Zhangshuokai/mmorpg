class_name WorldView
extends Node
## Client-side replicated entity table and target selection (WB0 split from
## main.gd; WB6/WB5 extend it with prediction display and zone switching).
##
## This class never simulates gameplay: it maps authoritative spawn/state
## messages onto EntityView nodes and owns the local player + current target.

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const MOB_SCENE := preload("res://scenes/mob.tscn")

var world_root: Node3D
var rig: CameraRig

## entity id -> EntityView
var entities: Dictionary = {}
var local_view: EntityView = null
var local_id: int = 0
var target_id: int = 0
var in_world := false


func setup(p_world_root: Node3D, p_rig: CameraRig) -> void:
	world_root = p_world_root
	rig = p_rig


func enter_world(self_id: int, spawn: Vector3, _hp: int) -> void:
	local_id = self_id
	in_world = true
	if local_view != null:
		local_view.global_position = spawn
		rig.follow_target = local_view


func spawn_entity(state: Dictionary) -> void:
	var id := int(state.get("id", 0))
	var existing := entities.get(id) as EntityView
	if existing != null:
		existing.apply_state(state)
		return
	var kind := int(state.get("kind", Protocol.EntityKind.PLAYER))
	var scene: PackedScene = PLAYER_SCENE if kind == Protocol.EntityKind.PLAYER else MOB_SCENE
	var view := scene.instantiate() as EntityView
	world_root.add_child(view)
	view.setup(state)
	entities[id] = view
	if id == local_id and kind == Protocol.EntityKind.PLAYER:
		local_view = view
		rig.follow_target = view


func despawn_entity(id: int) -> void:
	var view := entities.get(id) as EntityView
	if view == null:
		return
	entities.erase(id)
	if id == target_id:
		target_id = 0
	if view == local_view:
		local_view = null
		in_world = false
		rig.follow_target = null
	view.queue_free()


func apply_world_state(_tick: int, list: Array) -> void:
	for entry: Dictionary in list:
		var id := int(entry.get("id", 0))
		var view := entities.get(id) as EntityView
		if view != null:
			view.apply_state(entry)


func apply_hp_update(id: int, hp: int) -> void:
	var view := entities.get(id) as EntityView
	if view == null:
		return
	view.apply_state({"hp": hp})


## Full client-side entity reset after a rejected login or a dropped connection.
func reset() -> void:
	for id: int in entities.keys():
		var view := entities.get(id) as EntityView
		if view != null:
			view.queue_free()
	entities.clear()
	local_view = null
	local_id = 0
	target_id = 0
	in_world = false
	if rig != null:
		rig.follow_target = null


func set_target(id: int) -> void:
	if target_id == id:
		return
	var previous := entities.get(target_id) as EntityView
	if previous != null:
		previous.set_targeted(false)
	target_id = id
	var current := entities.get(target_id) as EntityView
	if current != null:
		current.set_targeted(true)


func nearest_mob_id() -> int:
	if local_view == null:
		return 0
	var best_id := 0
	var best_dist := 1.0e9
	for id: int in entities.keys():
		var view := entities.get(id) as EntityView
		if view == null or view.kind != Protocol.EntityKind.MOB or not view.alive:
			continue
		var distance := local_view.global_position.distance_to(view.global_position)
		if distance < best_dist:
			best_dist = distance
			best_id = id
	return best_id
