extends Node
## Client entry point. Renders authoritative server state and uploads input only.
##
## Run normally:
##   godot --path client
## Run the automated headless self-test:
##   godot --headless --path client -- --bot --host 127.0.0.1

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const MOB_SCENE := preload("res://scenes/mob.tscn")

const MOUSE_SENSITIVITY := 0.0025

var net: NetworkClient
var ui: LoginUI
var hud: HUD
var bot: BotClient
var rig: CameraRig
var world_root: Node3D

## entity id -> EntityView
var entities: Dictionary = {}
var local_view: EntityView = null
var local_id: int = 0
var target_id: int = 0
var in_world := false

var host := Protocol.DEFAULT_HOST
var bot_mode := false
var bot_user := ""
var bot_require_peer := false
var bot_check_respawn := false

var _yaw := 0.0
var _pitch := -0.25
var _seq := 0
var _send_accum := 0.0
var _pending_create := ""
var _pending_select := 0


func _ready() -> void:
	_parse_args()

	world_root = Node3D.new()
	world_root.name = "WorldRoot"
	add_child(world_root)
	WorldVisuals.build(world_root)

	rig = CameraRig.new()
	rig.name = "CameraRig"
	add_child(rig)

	net = NetworkClient.new()
	net.name = "NetworkClient"
	add_child(net)
	_connect_net_signals()

	if bot_mode:
		bot = BotClient.new()
		bot.name = "Bot"
		bot.net = net
		bot.host = host
		bot.username = bot_user
		bot.require_remote = bot_require_peer
		bot.require_respawn = bot_check_respawn
		add_child(bot)
		print("[client] headless bot mode -> %s:%d" % [host, Protocol.SERVER_PORT])
		return

	ui = LoginUI.new()
	ui.name = "LoginUI"
	add_child(ui)
	ui.login_requested.connect(_on_login_requested)
	ui.create_requested.connect(_on_create_requested)
	ui.select_requested.connect(_on_select_requested)

	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.hide_hud()


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var arg := args[i]
		if arg == "--bot":
			bot_mode = true
		elif arg == "--host":
			if i + 1 < args.size():
				i += 1
				host = args[i]
		elif arg == "--bot-user":
			if i + 1 < args.size():
				i += 1
				bot_user = args[i]
		elif arg == "--bot-require-peer":
			bot_require_peer = true
		elif arg == "--bot-check-respawn":
			bot_check_respawn = true
		elif arg.begins_with("--host="):
			host = arg.substr("--host=".length())
		i += 1


# --- Net (shared contract) signal wiring ------------------------------------

func _connect_net_signals() -> void:
	Net.login_result_received.connect(_on_login_result)
	Net.character_list_received.connect(_on_character_list)
	Net.world_entered.connect(_on_enter_world)
	Net.entity_spawned.connect(_on_spawn_entity)
	Net.entity_despawned.connect(_on_despawn_entity)
	Net.world_state_received.connect(_on_world_state)
	Net.combat_event_received.connect(_on_combat_event)
	Net.hp_update_received.connect(_on_hp_update)


func _on_login_result(ok: bool, reason: String) -> void:
	if bot_mode:
		return
	if ok:
		ui.set_login_status("Login OK. Loading characters...")
		net.request_character_list()
	else:
		_return_to_login(reason)


## Full client-side reset after a rejected login or a dropped connection. Without
## this the client stays on a frozen HUD because `ui.hide_all()` was already
## called when entering the world.
func _return_to_login(reason: String) -> void:
	for id: int in entities.keys():
		var view := entities.get(id) as EntityView
		if view != null:
			view.queue_free()
	entities.clear()
	local_view = null
	local_id = 0
	target_id = 0
	in_world = false
	_pending_create = ""
	_pending_select = 0
	if rig != null:
		rig.follow_target = null
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	hud.hide_hud()
	ui.show_login()
	ui.set_login_status(reason)


func _on_character_list(list: Array) -> void:
	if bot_mode:
		return
	# Decide from the incoming payload: the ItemList still holds the *previous*
	# list until show_characters() runs, and show_characters() writes its own
	# status, so the verdict must be computed first and applied last.
	var message := ""
	if not _pending_create.is_empty():
		var created := false
		for entry: Dictionary in list:
			if String(entry.get("name", "")) == _pending_create:
				created = true
				break
		if created:
			message = "Created '%s'." % _pending_create
		else:
			message = "Could not create '%s' (name taken or invalid)." % _pending_create
		_pending_create = ""
	elif _pending_select != 0 and not list.is_empty():
		message = "Character unavailable - pick another one."
		_pending_select = 0
	ui.show_characters(list)
	if not message.is_empty():
		ui.set_char_status(message)


func _on_enter_world(self_id: int, spawn: Vector3, hp: int) -> void:
	if bot_mode:
		return
	local_id = self_id
	in_world = true
	_pending_select = 0
	ui.hide_all()
	hud.show_hud()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if local_view != null:
		local_view.global_position = spawn
		rig.follow_target = local_view


func _on_spawn_entity(state: Dictionary) -> void:
	if bot_mode:
		return
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


func _on_despawn_entity(id: int) -> void:
	if bot_mode:
		return
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


func _on_world_state(_tick: int, list: Array) -> void:
	if bot_mode:
		return
	for entry: Dictionary in list:
		var id := int(entry.get("id", 0))
		var view := entities.get(id) as EntityView
		if view != null:
			view.apply_state(entry)


func _on_combat_event(_id: int, _target_id: int, _damage: int, _target_hp: int) -> void:
	pass


func _on_hp_update(id: int, hp: int) -> void:
	if bot_mode:
		return
	var view := entities.get(id) as EntityView
	if view == null:
		return
	var state := {"hp": hp}
	view.apply_state(state)


# --- UI intents -------------------------------------------------------------

func _on_login_requested(username: String, password: String, register: bool) -> void:
	# Bounds live in Protocol and are shared with AuthService.
	if username.length() < Protocol.USER_MIN or username.length() > Protocol.USER_MAX \
			or ui.password_length() < Protocol.PASS_MIN:
		ui.set_login_status("Username %d-%d chars, password %d+ chars." % [
			Protocol.USER_MIN, Protocol.USER_MAX, Protocol.PASS_MIN])
		return
	ui.set_login_status("Connecting to %s:%d ..." % [host, Protocol.SERVER_PORT])
	net.connect_to_server(host, username, password, register)


func _on_create_requested(char_name: String) -> void:
	_pending_create = char_name
	ui.set_char_status("Creating '%s' ..." % char_name)
	net.create_character(char_name, Protocol.ClassId.WARRIOR)


func _on_select_requested(char_id: int) -> void:
	_pending_select = char_id
	ui.set_char_status("Entering the world ...")
	net.select_character(char_id)


# --- input / per-frame ------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if bot_mode or not in_world:
		return
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * MOUSE_SENSITIVITY
		_pitch = clampf(_pitch - motion.relative.y * MOUSE_SENSITIVITY, -1.2, 0.55)
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				_attack_at_mouse()
	elif event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		match key.physical_keycode:
			KEY_ESCAPE:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			KEY_SPACE, KEY_1:
				if target_id != 0:
					net.use_ability(target_id)
			KEY_TAB:
				_select_nearest_mob()


func _process(delta: float) -> void:
	if bot_mode or not in_world or local_view == null:
		return
	rig.apply_look(_yaw, _pitch)

	var move := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		move.y += 1.0
	if Input.is_physical_key_pressed(KEY_S):
		move.y -= 1.0
	if Input.is_physical_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		move.x += 1.0

	_send_accum += delta
	if _send_accum >= Protocol.TICK_DT:
		_send_accum = 0.0
		_seq += 1
		net.send_input(_seq, move, _yaw, 0)

	_update_hud()


func _attack_at_mouse() -> void:
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
	_set_target(view.entity_id)
	net.use_ability(view.entity_id)


func _select_nearest_mob() -> void:
	if local_view == null:
		return
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
	if best_id != 0:
		_set_target(best_id)


func _set_target(id: int) -> void:
	if target_id == id:
		return
	var previous := entities.get(target_id) as EntityView
	if previous != null:
		previous.set_targeted(false)
	target_id = id
	var current := entities.get(target_id) as EntityView
	if current != null:
		current.set_targeted(true)


func _update_hud() -> void:
	if hud == null or local_view == null:
		return
	hud.update_self(local_view.display_name, local_view.hp, local_view.max_hp)
	var target := entities.get(target_id) as EntityView
	if target != null:
		hud.update_target(target.display_name, target.hp, target.max_hp)
		hud.set_hint("WASD move | LMB / Space attack | Tab nearest mob | Esc release mouse | %.1fm from target" % local_view.global_position.distance_to(target.global_position))
	else:
		hud.clear_target()
		hud.set_hint("WASD move | LMB / Space attack | Tab nearest mob | Esc release mouse")
