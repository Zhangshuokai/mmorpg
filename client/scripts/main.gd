extends Node
## Client entry point / assembly. Renders authoritative server state and uploads
## input only. WB0 split the former monolith into WorldView (entity table +
## target), InputController (input/seq upload) and UIFlow (login/character flow).
##
## Run normally:
##   godot --path client
## Run the automated headless self-test:
##   godot --headless --path client -- --bot --host 127.0.0.1 [--port N]

var net: NetworkClient
var ui: LoginUI
var hud: HUD
var bot: BotClient
var rig: CameraRig
var world_root: Node3D
var world_view: WorldView
var input_controller: InputController
var ui_flow: UIFlow

var host := Protocol.DEFAULT_HOST
var port := Protocol.SERVER_PORT
var bot_mode := false
var bot_user := ""
var bot_require_peer := false
var bot_check_respawn := false
var bot_multiplayer := false
var bot_seconds := 0.0

## Optional auto-login (set by scripts/start_client.ps1 via --login-* args). With
## --login-char the launcher also creates/selects a character and enters the world.
var login_user := ""
var login_pass := ""
var login_char := ""
var login_register := false
var _auto_char_sent := false
var _auto_char_done := false


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
	net.host = host
	net.port = port
	add_child(net)

	world_view = WorldView.new()
	world_view.name = "WorldView"
	world_view.setup(world_root, rig)
	add_child(world_view)

	input_controller = InputController.new()
	input_controller.name = "InputController"
	input_controller.setup(world_view, net, rig)
	input_controller.enabled = not bot_mode
	add_child(input_controller)

	ui_flow = UIFlow.new()
	ui_flow.name = "UIFlow"
	ui_flow.net = net
	ui_flow.world_view = world_view
	ui_flow.host = host
	ui_flow.port = port
	add_child(ui_flow)

	_connect_net_signals()

	if bot_mode:
		bot = BotClient.new()
		bot.name = "Bot"
		bot.net = net
		bot.host = host
		bot.port = port
		bot.username = bot_user
		bot.require_remote = bot_require_peer or bot_multiplayer
		bot.require_respawn = bot_check_respawn
		bot.multiplayer_only = bot_multiplayer
		bot.run_seconds = bot_seconds
		add_child(bot)
		print("[client] headless bot mode -> %s:%d" % [host, port])
		return

	ui = LoginUI.new()
	ui.name = "LoginUI"
	add_child(ui)
	ui_flow.ui = ui
	ui.login_requested.connect(ui_flow.login_requested)
	ui.create_requested.connect(ui_flow.create_requested)
	ui.select_requested.connect(ui_flow.select_requested)

	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.hide_hud()
	ui_flow.hud = hud

	_apply_auto_login()


func _apply_auto_login() -> void:
	if login_user.is_empty():
		return
	ui.set_credentials(login_user, login_pass)
	if login_pass.is_empty():
		ui.set_login_status("Type the password for '%s'." % login_user)
		return
	ui_flow.login_requested(login_user, login_pass, login_register)


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
		elif arg == "--port":
			if i + 1 < args.size():
				i += 1
				port = int(args[i])
		elif arg == "--bot-user":
			if i + 1 < args.size():
				i += 1
				bot_user = args[i]
		elif arg == "--bot-require-peer":
			bot_require_peer = true
		elif arg == "--bot-check-respawn":
			bot_check_respawn = true
		elif arg == "--bot-multiplayer":
			bot_multiplayer = true
		elif arg == "--bot-seconds":
			if i + 1 < args.size():
				i += 1
				bot_seconds = maxf(0.0, float(args[i]))
		elif arg == "--login-user":
			if i + 1 < args.size():
				i += 1
				login_user = args[i]
		elif arg == "--login-pass":
			if i + 1 < args.size():
				i += 1
				login_pass = args[i]
		elif arg == "--login-char":
			if i + 1 < args.size():
				i += 1
				login_char = args[i]
		elif arg == "--login-register":
			login_register = true
		elif arg.begins_with("--login-user="):
			login_user = arg.substr("--login-user=".length())
		elif arg.begins_with("--login-pass="):
			login_pass = arg.substr("--login-pass=".length())
		elif arg.begins_with("--login-char="):
			login_char = arg.substr("--login-char=".length())
		elif arg.begins_with("--host="):
			host = arg.substr("--host=".length())
		elif arg.begins_with("--port="):
			port = int(arg.substr("--port=".length()))
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
	ui_flow.on_login_result(ok, reason)


func _on_character_list(list: Array) -> void:
	if bot_mode:
		return
	ui_flow.on_character_list(list)
	_maybe_auto_enter(list)


## --login-char support: select the named character, or create it once and select
## it on the following list. Stops at character select when --login-char is absent.
func _maybe_auto_enter(list: Array) -> void:
	if login_char.is_empty():
		return
	var found_id := 0
	for entry: Dictionary in list:
		if String(entry.get("name", "")) == login_char:
			found_id = int(entry.get("id", 0))
			break
	if found_id != 0:
		if not _auto_char_done:
			_auto_char_done = true
			ui_flow.select_requested(found_id)
	elif not _auto_char_sent:
		_auto_char_sent = true
		ui_flow.create_requested(login_char)


func _on_enter_world(self_id: int, spawn: Vector3, hp: int) -> void:
	if bot_mode:
		return
	world_view.enter_world(self_id, spawn, hp)
	ui_flow.on_enter_world()


func _on_spawn_entity(state: Dictionary) -> void:
	if bot_mode:
		return
	world_view.spawn_entity(state)


func _on_despawn_entity(id: int) -> void:
	if bot_mode:
		return
	world_view.despawn_entity(id)


func _on_world_state(tick: int, list: Array) -> void:
	if bot_mode:
		return
	world_view.apply_world_state(tick, list)


func _on_combat_event(_id: int, _target_id: int, _damage: int, _target_hp: int) -> void:
	pass


func _on_hp_update(id: int, hp: int) -> void:
	if bot_mode:
		return
	world_view.apply_hp_update(id, hp)


# --- per-frame --------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	input_controller.handle_unhandled_input(event)


func _process(delta: float) -> void:
	if bot_mode:
		return
	if not world_view.in_world or world_view.local_view == null:
		return
	input_controller.update(delta)
	ui_flow.update_hud()
