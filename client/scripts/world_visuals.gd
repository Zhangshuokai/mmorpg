class_name WorldVisuals
extends RefCounted
## Builds the cosmetic client-side copy of the static map. Geometry comes from
## `Protocol` so the client and the server always agree on the layout.

static func build(parent: Node3D) -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.25, 0.42, 0.72)
	sky_material.sky_horizon_color = Color(0.62, 0.7, 0.8)
	sky_material.ground_bottom_color = Color(0.16, 0.18, 0.2)
	sky_material.ground_horizon_color = Color(0.28, 0.3, 0.32)
	sky.sky_material = sky_material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.5
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	parent.add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52.0, -35.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	parent.add_child(sun)

	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var ground_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(Protocol.MAP_HALF * 2.0, Protocol.MAP_HALF * 2.0)
	ground_mesh.mesh = plane
	ground_mesh.material_override = _material(Color(0.22, 0.34, 0.2))
	ground.add_child(ground_mesh)
	var ground_shape := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(Protocol.MAP_HALF * 2.0, 0.2, Protocol.MAP_HALF * 2.0)
	ground_shape.shape = ground_box
	ground_shape.position = Vector3(0.0, -0.1, 0.0)
	ground.add_child(ground_shape)
	parent.add_child(ground)

	var index := 0
	for pos in Protocol.COVER_POSITIONS:
		index += 1
		var cover := StaticBody3D.new()
		cover.name = "Cover%d" % index
		cover.position = pos + Vector3(0.0, Protocol.COVER_SIZE.y * 0.5, 0.0)
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Protocol.COVER_SIZE
		mesh.mesh = box
		mesh.material_override = _material(Color(0.46, 0.43, 0.39))
		cover.add_child(mesh)
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = Protocol.COVER_SIZE
		shape.shape = box_shape
		cover.add_child(shape)
		parent.add_child(cover)


static func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.95
	return material
