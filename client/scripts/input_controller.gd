class_name InputController
extends Node
## Local mouse/keyboard input, aim and input upload (WB0 split; WB6 turns the
## local player's display into prediction using the same shared Movement maths).
##
## No InputMap (see AGENTS.md): key codes are read directly.

const MOUSE_SENSITIVITY := 0.0025

var world_view: WorldView
var net: NetworkClient
var rig: CameraRig

var yaw := 0.0
var pitch := -0.25
## False in headless bot mode: the bot drives its own input.
var enabled := true


func setup(p_world_view: WorldView, p_net: NetworkClient, p_rig: CameraRig) -> void:
	world_view = p_world_view
	net = p_net
	rig = p_rig


func handle_unhandled_input(event: InputEvent) -> void:
	if not enabled or not world_view.in_world:
		return
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * MOUSE_SENSITIVITY
		pitch = clampf(pitch - motion.relative.y * MOUSE_SENSITIVITY, -1.2, 0.55)
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				attack_at_mouse()
	elif event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		match key.physical_keycode:
			KEY_ESCAPE:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			KEY_SPACE, KEY_1:
				if world_view.target_id != 0:
					net.use_ability(Protocol.AbilityId.MELEE, world_view.target_id)
			KEY_TAB:
				var nearest := world_view.nearest_mob_id()
				if nearest != 0:
					world_view.set_target(nearest)


## Called every frame by main while the local player is in the world.
func update(delta: float) -> void:
	if not enabled:
		return
	rig.apply_look(yaw, pitch)

	var move := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		move.y += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		move.y -= 1.0
	if Input.is_physical_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		move.x += 1.0

	net.tick_input(delta, move, yaw, 0)


func attack_at_mouse() -> void:
	if rig == null or rig.camera == null:
		return
	var viewport := get_viewport()
	var mouse := viewport.get_mouse_position()
	var from := rig.camera.project_ray_origin(mouse)
	var to := from + rig.camera.project_ray_normal(mouse) * 200.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	var hit := viewport.world_3d.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	# Only entity nodes are targetable: the collider IS the EntityView (the
	# ground/cover bodies are plain StaticBody3D and cast to null).
	var view := hit.get("collider") as EntityView
	if view == null or not view.alive:
		return
	world_view.set_target(view.entity_id)
	net.use_ability(Protocol.AbilityId.MELEE, view.entity_id)
