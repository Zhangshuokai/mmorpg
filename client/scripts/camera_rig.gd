class_name CameraRig
extends Node3D
## Third-person camera rig. Yaw/pitch come from local mouse input (aiming is a
## cosmetic local concern); the rig simply follows the interpolated local player.

var yaw := 0.0
var pitch := -0.25
var follow_target: Node3D = null

var spring: SpringArm3D
var camera: Camera3D


func _ready() -> void:
	# WorldView writes the local player's transform in its own _process; the rig
	# must run *after* that, or it follows last frame's position and leaves the
	# local character visibly ghosting/oscillating on screen while remotes look fine.
	process_priority = 1
	spring = SpringArm3D.new()
	spring.name = "SpringArm"
	spring.position = Vector3(0.0, 1.6, 0.0)
	spring.spring_length = 5.0
	spring.margin = 0.2
	add_child(spring)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 70.0
	camera.current = true
	spring.add_child(camera)


func apply_look(p_yaw: float, p_pitch: float) -> void:
	yaw = p_yaw
	pitch = p_pitch
	rotation.y = yaw
	if spring != null:
		spring.rotation.x = clampf(pitch, -1.2, 0.55)


func _process(_delta: float) -> void:
	if follow_target != null and is_instance_valid(follow_target):
		global_position = follow_target.global_position
