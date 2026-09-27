extends Node
## Dedicated-server entry point: pure assembly. Opens the configured UDP port,
## wires the services, intent router and session flow, and services lifecycle.
##
## Run with:
##   godot --headless --path server -- --server [--port N] [--db PATH] [--no-mobs]

var db: DBService
var persistence: PersistenceService
var persistence_inventory: PersistenceInventory
var inventory: InventoryService
var auth: AuthService
var combat: CombatService
var router: IntentRouter
var bootstrap: Bootstrap
var session_flow: SessionFlow

## Overridable via --port / --db (worktree isolation: one port + one DB each).
var server_port := Protocol.SERVER_PORT
var db_path := ""

@onready var world: WorldService = $World

var _save_timer: Timer


func _ready() -> void:
	# Protocol.TICK_HZ is the single source of truth for the world tick rate
	# (one _physics_process call == one world tick); the value in project.godot
	# is only the editor default and is overridden here before anything simulates.
	Engine.physics_ticks_per_second = Protocol.TICK_HZ
	_parse_args()
	print("[server] Godot %s | mode=%s | tick=%dHz | port=%d | user args=%s" % [
		Engine.get_version_info().get("string", "?"),
		DisplayServer.get_name(),
		Engine.physics_ticks_per_second,
		server_port,
		OS.get_cmdline_user_args(),
	])
	if Engine.physics_ticks_per_second != Protocol.TICK_HZ:
		push_warning("[server] could not apply Protocol.TICK_HZ to the physics tick rate")
	if not _is_server_mode():
		push_warning("[server] started without --server/headless; continuing because this is the server project")

	db = DBService.new()
	db.name = "DB"
	if not db_path.is_empty():
		db.db_path = db_path
	add_child(db)
	if not db.is_open:
		push_error("[server] database unavailable; shutting down")
		get_tree().quit(1)
		return

	# Migrations + static-data validation before anything reads the schema.
	bootstrap = Bootstrap.new()
	bootstrap.name = "Bootstrap"
	add_child(bootstrap)
	if not bootstrap.run(db):
		get_tree().quit(1)
		return

	persistence = PersistenceService.new()
	persistence.name = "Persistence"
	persistence.db = db
	add_child(persistence)

	# --- WB3 inventory (items / equipment) ---------------------------------
	# WB3 owns server/scripts/inventory.gd + persistence_inventory.gd; this block
	# is the only edit to this shared file. Remove/replace it wholesale if WB3 is
	# reverted.
	persistence_inventory = PersistenceInventory.new()
	persistence_inventory.name = "PersistenceInventory"
	persistence_inventory.db = db
	add_child(persistence_inventory)

	inventory = InventoryService.new()
	inventory.name = "Inventory"
	inventory.world = world
	inventory.persistence = persistence_inventory
	add_child(inventory)
	# --- end WB3 wiring ----------------------------------------------------

	auth = AuthService.new()
	auth.name = "Auth"
	auth.db = db
	auth.persistence = persistence
	add_child(auth)

	combat = CombatService.new()
	combat.name = "Combat"
	combat.world = world
	add_child(combat)

	router = IntentRouter.new()
	router.name = "IntentRouter"
	add_child(router)
	router.register("input_received", _on_input)
	router.register("use_ability_requested", _on_use_ability)
	# WB3: inventory intents -> InventoryService (see the WB3 wiring block above).
	router.register("move_item_requested", Callable(inventory, "handle_move"))
	router.register("equip_item_requested", Callable(inventory, "handle_equip"))
	router.register("unequip_item_requested", Callable(inventory, "handle_unequip"))

	session_flow = SessionFlow.new()
	session_flow.name = "SessionFlow"
	session_flow.auth = auth
	session_flow.persistence = persistence
	session_flow.world = world
	session_flow.router = router
	add_child(session_flow)

	if _user_args_has("--no-mobs"):
		world.spawn_mobs_enabled = false
		print("[server] --no-mobs: enemy spawning disabled (multiplayer debug mode)")
	world.setup(persistence)

	_save_timer = Timer.new()
	_save_timer.name = "SaveTimer"
	_save_timer.wait_time = Protocol.SAVE_INTERVAL_SEC
	_save_timer.autostart = true
	_save_timer.timeout.connect(_on_save_tick)
	add_child(_save_timer)

	_start_network()


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var arg: String = args[i]
		if arg == "--port" and i + 1 < args.size():
			i += 1
			server_port = int(args[i])
		elif arg == "--db" and i + 1 < args.size():
			i += 1
			db_path = args[i]
		elif arg.begins_with("--port="):
			server_port = int(arg.substr("--port=".length()))
		elif arg.begins_with("--db="):
			db_path = arg.substr("--db=".length())
		i += 1


func _is_server_mode() -> bool:
	return DisplayServer.get_name() == "headless" or OS.get_cmdline_user_args().has("--server")


func _user_args_has(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag)


# --- networking -------------------------------------------------------------

func _start_network() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(server_port, Protocol.MAX_CLIENTS)
	if err != OK:
		push_error("[server] cannot listen on UDP %d: %s" % [server_port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	# Credentials arrive here only, never through a gameplay RPC.
	multiplayer.auth_callback = Callable(auth, "handle_auth")
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.peer_authentication_failed.connect(_on_peer_authentication_failed)
	print("[server] listening on UDP %d (max %d clients, tick %dHz)" % [
		server_port, Protocol.MAX_CLIENTS, Protocol.TICK_HZ])


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


# --- client intents (registered with the router) ----------------------------

func _on_input(sender: int, seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	world.set_input(sender, seq, move, yaw, buttons)


func _on_use_ability(sender: int, ability_id: int, target_id: int) -> void:
	combat.use_ability(sender, ability_id, target_id)


# --- lifecycle --------------------------------------------------------------

func _on_save_tick() -> void:
	world.save_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if is_instance_valid(world):
			world.save_all()
		if db != null and is_instance_valid(db) and db.is_open:
			db.close()
