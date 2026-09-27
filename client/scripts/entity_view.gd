class_name EntityView
extends CharacterBody3D
## Client-side visual proxy of a server-replicated entity (player or mob).
##
## Nothing here simulates gameplay: the server owns position, yaw, hp and alive.
## Remote state is sampled from a short **jitter buffer** of real snapshots
## (S-N-2): the node renders `INTERP_DELAY_SEC` in the past and interpolates
## between the two snapshots that straddle that time, which hides network jitter
## at the cost of a fixed display delay (~3 x send interval, Gaffer's
## snapshot-interpolation recommendation).
##
## The local player is the exception: WorldView drives it from Prediction
## (`local_predicted = true`), so its `_process` never interpolates.

## Display depth of the jitter buffer: ~3 x the server send interval (20Hz).
const INTERP_DELAY_SEC := Protocol.TICK_DT * 3.0
## Hard cap on buffered snapshots (>= 3 x send interval, with headroom).
const BUFFER_MAX := 32
## Discard buffered snapshots older than this (seconds) to bound memory.
const BUFFER_KEEP_SEC := 1.5

var entity_id: int = 0
var display_name := ""
var kind: int = Protocol.EntityKind.PLAYER
var hp: int = 0
var max_hp: int = 0
var alive := true
var targeted := false
## When true this node is the local player and Prediction owns its transform.
var local_predicted := false

var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
## Snapshot history: [{"t": float seconds, "pos": Vector3, "yaw": float}, ...].
var _buffer: Array = []
var _body: MeshInstance3D
var _material: StandardMaterial3D
var _name_tag: Label3D


func _ready() -> void:
	_body = get_node_or_null("Body") as MeshInstance3D
	_name_tag = get_node_or_null("NameTag") as Label3D


func setup(state: Dictionary) -> void:
	entity_id = int(state.get("id", 0))
	display_name = String(state.get("name", ""))
	kind = int(state.get("kind", Protocol.EntityKind.PLAYER))
	max_hp = max(1, int(state.get("max_hp", 1)))
	var pos: Vector3 = state.get("pos", Vector3.ZERO)
	_target_pos = pos
	_target_yaw = float(state.get("yaw", 0.0))
	global_position = pos
	rotation.y = _target_yaw
	_buffer = [{"t": _now(), "pos": pos, "yaw": _target_yaw}]
	apply_state(state)
	_refresh()


## `skip_transform` is set for the local player: hp/alive/target still update,
## but pos/yaw are left to prediction.
func apply_state(state: Dictionary, skip_transform: bool = false) -> void:
	if not skip_transform and state.has("pos"):
		var pos: Vector3 = state.get("pos", _target_pos)
		var yaw := float(state.get("yaw", _target_yaw))
		_target_pos = pos
		_target_yaw = yaw
		_push_snapshot(pos, yaw)
	if state.has("hp") or state.has("alive"):
		var net_hp := int(state.get("hp", hp))
		var net_alive := bool(state.get("alive", alive))
		if net_hp != hp or net_alive != alive:
			hp = net_hp
			alive = net_alive
			_refresh()


## Local-prediction transform setters (WorldView calls these every frame).
func set_predicted_position(pos: Vector3) -> void:
	_target_pos = pos
	global_position = pos


func set_predicted_yaw(yaw: float) -> void:
	_target_yaw = yaw
	rotation.y = yaw


func set_targeted(value: bool) -> void:
	if targeted == value:
		return
	targeted = value
	_refresh()


func _process(_delta: float) -> void:
	if local_predicted:
		return
	var sample := sample_buffer(_buffer, _now() - INTERP_DELAY_SEC)
	if sample.is_empty():
		return
	global_position = sample["pos"]
	rotation.y = sample["yaw"]


func _push_snapshot(pos: Vector3, yaw: float) -> void:
	var now := _now()
	_buffer.append({"t": now, "pos": pos, "yaw": yaw})
	# Drop snapshots we can no longer render (older than the buffer window).
	while _buffer.size() > 1 and now - float(_buffer[0]["t"]) > BUFFER_KEEP_SEC:
		_buffer.pop_front()
	while _buffer.size() > BUFFER_MAX:
		_buffer.pop_front()


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


## Pure snapshot-interpolation sampler (unit-tested by bot_check_movement):
## returns {"pos", "yaw"} at `render_time`, clamped to the ends of the buffer so
## a starved buffer holds the newest known state instead of extrapolating.
static func sample_buffer(buffer: Array, render_time: float) -> Dictionary:
	if buffer.is_empty():
		return {}
	var first: Dictionary = buffer[0]
	if buffer.size() == 1 or render_time <= float(first["t"]):
		return first
	var last: Dictionary = buffer[buffer.size() - 1]
	if render_time >= float(last["t"]):
		return last
	for i in buffer.size() - 1:
		var a: Dictionary = buffer[i]
		var b: Dictionary = buffer[i + 1]
		var ta := float(a["t"])
		var tb := float(b["t"])
		if render_time >= ta and render_time <= tb:
			var span := tb - ta
			var alpha := 0.0 if span <= 0.0 else (render_time - ta) / span
			return {
				"pos": (a["pos"] as Vector3).lerp(b["pos"], alpha),
				"yaw": lerp_angle(float(a["yaw"]), float(b["yaw"]), alpha),
			}
	return last


func _base_color() -> Color:
	if kind == Protocol.EntityKind.MOB:
		return Color(0.72, 0.24, 0.18)
	return Color(0.34, 0.63, 1.0)


func _refresh() -> void:
	visible = alive
	if _name_tag != null:
		_name_tag.text = "%s  %d/%d" % [display_name, hp, max_hp]
	if _body == null:
		return
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.roughness = 0.85
		_body.material_override = _material
	if not alive:
		_material.albedo_color = Color(0.22, 0.22, 0.24)
	elif targeted:
		_material.albedo_color = Color(1.0, 0.86, 0.2)
	else:
		_material.albedo_color = _base_color()
