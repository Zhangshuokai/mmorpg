extends Node
## Dedicated-server entry point: wires services together, opens UDP 7000 and
## services the account/character session flow.
##
## Run with:
##   godot --headless --path server -- --server

const MAX_CHARACTERS_PER_ACCOUNT := 5

var db: DBService
var persistence: PersistenceService
var auth: AuthService
var combat: CombatService

@onready var world: WorldService = $World

var _save_timer: Timer


func _ready() -> void:
	# Protocol.TICK_HZ is the single source of truth for the world tick rate
	# (one _physics_process call == one world tick); the value in project.godot
	# is only the editor default and is overridden here before anything simulates.
	Engine.physics_ticks_per_second = Protocol.TICK_HZ
	print("[server] Godot %s | mode=%s | tick=%dHz | user args=%s" % [
		Engine.get_version_info().get("string", "?"),
		DisplayServer.get_name(),
		Engine.physics_ticks_per_second,
		OS.get_cmdline_user_args(),
	])
	if Engine.physics_ticks_per_second != Protocol.TICK_HZ:
		push_warning("[server] could not apply Protocol.TICK_HZ to the physics tick rate")
	if not _is_server_mode():
		push_warning("[server] started without --server/headless; continuing because this is the server project")

	db = DBService.new()
	db.name = "DB"
	add_child(db)
	if not db.is_open:
		push_error("[server] database unavailable; shutting down")
		get_tree().quit(1)
		return

	persistence = PersistenceService.new()
	persistence.name = "Persistence"
	persistence.db = db
	add_child(persistence)

	auth = AuthService.new()
	auth.name = "Auth"
	auth.db = db
	auth.persistence = persistence
	add_child(auth)

	combat = CombatService.new()
	combat.name = "Combat"
	combat.world = world
	add_child(combat)

	if _user_args_has("--no-mobs"):
		world.spawn_mobs_enabled = false
		print("[server] --no-mobs: enemy spawning disabled (multiplayer debug mode)")
	world.setup(persistence)

	Net.input_received.connect(_on_input)
	Net.use_ability_requested.connect(_on_use_ability)
	Net.list_characters_requested.connect(_on_list_characters)
	Net.create_character_requested.connect(_on_create_character)
	Net.select_character_requested.connect(_on_select_character)

	_save_timer = Timer.new()
	_save_timer.name = "SaveTimer"
	_save_timer.wait_time = Protocol.SAVE_INTERVAL_SEC
	_save_timer.autostart = true
	_save_timer.timeout.connect(_on_save_tick)
	add_child(_save_timer)

	_start_network()


func _is_server_mode() -> bool:
	return DisplayServer.get_name() == "headless" or OS.get_cmdline_user_args().has("--server")


func _user_args_has(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag)


# --- networking -------------------------------------------------------------

func _start_network() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(Protocol.SERVER_PORT, Protocol.MAX_CLIENTS)
	if err != OK:
		push_error("[server] cannot listen on UDP %d: %s" % [Protocol.SERVER_PORT, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	# Credentials arrive here only, never through a gameplay RPC.
	multiplayer.auth_callback = Callable(auth, "handle_auth")
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.peer_authentication_failed.connect(_on_peer_authentication_failed)
	print("[server] listening on UDP %d (max %d clients, tick %dHz)" % [
		Protocol.SERVER_PORT, Protocol.MAX_CLIENTS, Protocol.TICK_HZ])


func _on_peer_connected(peer_id: int) -> void:
	print("[server] peer %d connected as '%s'" % [peer_id, auth.username_for(peer_id)])
	# Authentication already succeeded in auth_callback; tell the client.
	Net.s2c_login_result.rpc_id(peer_id, true, "")


func _on_peer_disconnected(peer_id: int) -> void:
	# Read the username before forget() drops the session record.
	var who := auth.username_for(peer_id)
	print("[server] peer %d ('%s') disconnected" % [peer_id, who])
	world.save_all()
	world.remove_player(peer_id, true)
	auth.forget(peer_id)


func _on_peer_authentication_failed(peer_id: int) -> void:
	print("[server] peer %d failed authentication" % peer_id)
	auth.forget(peer_id)


# --- client intents ---------------------------------------------------------

func _on_input(sender: int, seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	world.set_input(sender, seq, move, yaw, buttons)


func _on_use_ability(sender: int, target_id: int) -> void:
	combat.use_ability(sender, target_id)


func _on_list_characters(sender: int) -> void:
	var account_id := auth.account_for(sender)
	if account_id < 0:
		return
	_send_character_list(sender, account_id)


func _on_create_character(sender: int, char_name: String, class_id: int) -> void:
	var account_id := auth.account_for(sender)
	if account_id < 0:
		return
	var name := char_name.strip_edges()
	if not _valid_char_name(name):
		print("[server] peer %d requested invalid character name '%s'" % [sender, char_name])
		_send_character_list(sender, account_id)
		return
	if persistence.character_count(account_id) >= MAX_CHARACTERS_PER_ACCOUNT:
		print("[server] peer %d exceeded character limit" % sender)
		_send_character_list(sender, account_id)
		return
	if class_id != Protocol.ClassId.WARRIOR:
		class_id = Protocol.ClassId.WARRIOR
	var result := persistence.create_character(account_id, name, class_id)
	if not result.get("ok", false):
		print("[server] create_character for peer %d failed: %s" % [sender, result.get("reason", "?")])
	_send_character_list(sender, account_id)


func _on_select_character(sender: int, char_id: int) -> void:
	var account_id := auth.account_for(sender)
	if account_id < 0:
		return
	var sheet := persistence.get_character(char_id)
	if sheet == null or sheet.account_id != account_id:
		print("[server] peer %d tried to select unowned character %d" % [sender, char_id])
		_send_character_list(sender, account_id)
		return
	world.add_player(sender, sheet)


func _send_character_list(sender: int, account_id: int) -> void:
	var payload: Array = []
	for row: Dictionary in persistence.characters_for(account_id):
		payload.append(CharacterSheet.from_row(row).to_dict())
	Net.s2c_character_list.rpc_id(sender, payload)


## Explicit ASCII allowlist: [A-Za-z0-9_]. A blocklist would still let through
## zero-width, bidi-override and other format characters, which would be stored
## and then rendered verbatim in every other player's name tag (impersonation /
## blank nameplates).
func _valid_char_name(name: String) -> bool:
	var length := name.length()
	if length < Protocol.NAME_MIN or length > Protocol.NAME_MAX:
		return false
	for i in length:
		var code := name.unicode_at(i)
		var is_digit := code >= 48 and code <= 57
		var is_upper := code >= 65 and code <= 90
		var is_lower := code >= 97 and code <= 122
		var is_underscore := code == 95
		if not (is_digit or is_upper or is_lower or is_underscore):
			return false
	return true


# --- lifecycle --------------------------------------------------------------

func _on_save_tick() -> void:
	world.save_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if is_instance_valid(world):
			world.save_all()
		if db != null and is_instance_valid(db) and db.is_open:
			db.close()
