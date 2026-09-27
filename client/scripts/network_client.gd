class_name NetworkClient
extends Node
## Owns the ENet peer and the credential handshake. Every authoritative message
## is delivered through the shared `Net` autoload signals; this class only
## connects, authenticates and sends client intents.

var host := Protocol.DEFAULT_HOST
var port := Protocol.SERVER_PORT

var _credentials := PackedByteArray()


func connect_to_server(p_host: String, username: String, password: String, register: bool) -> void:
	host = p_host
	_credentials = Protocol.auth_payload(username, password, register)
	close()

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		push_error("[net] create_client(%s:%d) failed: %s" % [host, port, error_string(err)])
		Net.login_result_received.emit(false, "Cannot reach %s:%d (%s)" % [host, port, error_string(err)])
		return
	multiplayer.multiplayer_peer = peer

	# The client must also set an auth_callback, otherwise `peer_authenticating`
	# never fires and no credentials could be sent.
	multiplayer.auth_callback = func(_id: int, _data: PackedByteArray) -> void: pass
	if not multiplayer.peer_authenticating.is_connected(_on_peer_authenticating):
		multiplayer.peer_authenticating.connect(_on_peer_authenticating)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)
	print("[net] connecting to %s:%d ..." % [host, port])


func close() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null


func can_send() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


# --- client -> server intents ----------------------------------------------

func send_input(seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	if not can_send():
		return
	Net.c2s_input.rpc_id(1, seq, move, yaw, buttons)


func use_ability(target_id: int) -> void:
	if not can_send():
		return
	Net.c2s_use_ability.rpc_id(1, target_id)


func request_character_list() -> void:
	if not can_send():
		return
	Net.c2s_list_characters.rpc_id(1)


func create_character(char_name: String, class_id: int) -> void:
	if not can_send():
		return
	Net.c2s_create_character.rpc_id(1, char_name, class_id)


func select_character(char_id: int) -> void:
	if not can_send():
		return
	Net.c2s_select_character.rpc_id(1, char_id)


# --- auth handshake ---------------------------------------------------------

func _on_peer_authenticating(peer_id: int) -> void:
	multiplayer.send_auth(1, _credentials)
	multiplayer.complete_auth(peer_id)


func _on_connection_failed() -> void:
	print("[net] connection failed or rejected by server")
	Net.login_result_received.emit(false, "Login rejected (bad credentials, name taken, or server unreachable).")


func _on_server_disconnected() -> void:
	print("[net] server disconnected")
	Net.login_result_received.emit(false, "Disconnected from server.")
