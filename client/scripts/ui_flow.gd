class_name UIFlow
extends Node
## Login / character-select flow and HUD updates (WB0 split; WB2/WB3 add their
## panels). Pure view logic: it only emits intents through NetInput.

var net: NetworkClient
var ui: LoginUI
var hud: HUD
var world_view: WorldView
var host := Protocol.DEFAULT_HOST
var port := Protocol.SERVER_PORT

var _pending_create := ""
var _pending_select := 0


func on_login_result(ok: bool, reason: String) -> void:
	if ok:
		ui.set_login_status("Login OK. Loading characters...")
		net.request_character_list()
	else:
		return_to_login(reason)


## Full client-side reset after a rejected login or a dropped connection. Without
## this the client stays on a frozen HUD because `ui.hide_all()` was already
## called when entering the world.
func return_to_login(reason: String) -> void:
	world_view.reset()
	_pending_create = ""
	_pending_select = 0
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	hud.hide_hud()
	ui.show_login()
	ui.set_login_status(reason)


func on_character_list(list: Array) -> void:
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


func on_enter_world() -> void:
	_pending_select = 0
	ui.hide_all()
	hud.show_hud()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# --- intents ----------------------------------------------------------------

func login_requested(username: String, password: String, register: bool) -> void:
	# Bounds live in Protocol and are shared with AuthService.
	if username.length() < Protocol.USER_MIN or username.length() > Protocol.USER_MAX \
			or ui.password_length() < Protocol.PASS_MIN:
		ui.set_login_status("Username %d-%d chars, password %d+ chars." % [
			Protocol.USER_MIN, Protocol.USER_MAX, Protocol.PASS_MIN])
		return
	ui.set_login_status("Connecting to %s:%d ..." % [host, port])
	net.connect_to_server(host, username, password, register)


func create_requested(char_name: String) -> void:
	_pending_create = char_name
	ui.set_char_status("Creating '%s' ..." % char_name)
	net.create_character(char_name, Protocol.ClassId.WARRIOR)


func select_requested(char_id: int) -> void:
	_pending_select = char_id
	ui.set_char_status("Entering the world ...")
	net.select_character(char_id)


# --- HUD --------------------------------------------------------------------

func update_hud() -> void:
	if hud == null or world_view.local_view == null:
		return
	var local := world_view.local_view
	hud.update_self(local.display_name, local.hp, local.max_hp)
	var target := world_view.entities.get(world_view.target_id) as EntityView
	if target != null:
		hud.update_target(target.display_name, target.hp, target.max_hp)
		hud.set_hint("WASD move | LMB / Space attack | Tab nearest mob | Esc release mouse | %.1fm from target" % local.global_position.distance_to(target.global_position))
	else:
		hud.clear_target()
		hud.set_hint("WASD move | LMB / Space attack | Tab nearest mob | Esc release mouse")
