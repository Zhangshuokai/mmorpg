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
## Current shard (WB5): zone + channel/instance the replicated entity table is
## scoped to. Updated by the server's s2c_zone_changed.
var local_zone := Protocol.ZONE_DEFAULT
var local_channel := Protocol.CHANNEL_DEFAULT

## The local player's node is driven by prediction (WB6), not by interpolating
## the authoritative stream; discovered lazily because setup() runs before this
## node is parented (see client/scripts/main.gd assembly order).
var _net: NetworkClient


func setup(p_world_root: Node3D, p_rig: CameraRig) -> void:
	world_root = p_world_root
	rig = p_rig


func _ready() -> void:
	_net = get_parent().get_node_or_null("NetworkClient") as NetworkClient
	if not Net.zone_changed.is_connected(on_zone_changed):
		Net.zone_changed.connect(on_zone_changed)


## Local prediction is applied at input time; mirror it onto the EntityView every
## frame for a smooth, zero-latency local character.
func _process(_delta: float) -> void:
	if local_view == null or _net == null or _net.input == null:
		return
	var predictor: Prediction = _net.input.predictor
	if predictor == null or not predictor.active:
		return
	local_view.set_predicted_position(predictor.render_position(_net.input.tick_alpha()))
	local_view.set_predicted_yaw(predictor.last_yaw)


func enter_world(self_id: int, spawn: Vector3, _hp: int) -> void:
	local_id = self_id
	in_world = true
	if local_view != null:
		local_view.global_position = spawn
		rig.follow_target = local_view


## WB5 (S-N-7): the server moved this client to another zone/channel/instance
## without reconnecting. Drop every entity of the old shard immediately (the
## server also sends despawns, but clearing here guarantees no stale entity
## survives a dropped packet while keeping the local player and its prediction
## alive), then re-base the local player on the new shard's spawn. The server
## follows up with s2c_spawn_entity for the new shard.
func on_zone_changed(zone_id: int, channel_id: int, spawn: Vector3) -> void:
	local_zone = zone_id
	local_channel = channel_id
	var stale: Array = []
	for id: int in entities.keys():
		if id != local_id:
			stale.append(id)
	for id: int in stale:
		var view := entities.get(id) as EntityView
		if view != null:
			view.queue_free()
		entities.erase(id)
	if target_id != local_id:
		target_id = 0
	if local_view != null and is_instance_valid(local_view):
		local_view.set_predicted_position(spawn)
		local_view.set_predicted_yaw(0.0)
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
		view.local_predicted = true
		if _net != null and _net.input != null:
			view.set_predicted_position(_net.input.predictor.render_position())
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
		if view == null:
			continue
		# The local player's transform is owned by NetInput's prediction; the
		# authoritative snapshot still drives hp/alive/target but never its pos.
		view.apply_state(entry, id == local_id)


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
	local_zone = Protocol.ZONE_DEFAULT
	local_channel = Protocol.CHANNEL_DEFAULT
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
