class_name EntityView
extends CharacterBody3D
## Client-side visual proxy of a server-replicated entity (player or mob).
##
## Nothing here simulates gameplay: the server owns position, yaw, hp and alive.
## Remote state is interpolated so entities look smooth despite the 20Hz stream.

var entity_id: int = 0
var display_name := ""
var kind: int = Protocol.EntityKind.PLAYER
var hp: int = 0
var max_hp: int = 0
var alive := true
var targeted := false

var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
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
	apply_state(state)
	_refresh()


func apply_state(state: Dictionary) -> void:
	if state.has("pos"):
		var pos: Vector3 = state.get("pos", _target_pos)
		_target_pos = pos
	if state.has("yaw"):
		_target_yaw = float(state.get("yaw", _target_yaw))
	# `state` may be a full spawn payload or a partial hp_update; only override
	# the fields actually present so a partial update can never revive an entity.
	if state.has("hp") or state.has("alive"):
		var net_hp := int(state.get("hp", hp))
		var net_alive := bool(state.get("alive", alive))
		if net_hp != hp or net_alive != alive:
			hp = net_hp
			alive = net_alive
			_refresh()


func set_targeted(value: bool) -> void:
	if targeted == value:
		return
	targeted = value
	_refresh()


func _process(delta: float) -> void:
	var t := clampf(delta * Protocol.INTERP_SPEED, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, t)
	rotation.y = lerp_angle(rotation.y, _target_yaw, t)


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
