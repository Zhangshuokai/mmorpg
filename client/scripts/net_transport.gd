class_name NetTransport
extends Node
## ENet connection lifecycle and connection failure reporting (WB0 split;
## WB7 owns the security hardening of the handshake). Owns the peer, not the
## intent payloads (see NetInput) nor the credential payload (see NetAuth).

var host := Protocol.DEFAULT_HOST
var port := Protocol.SERVER_PORT

var _auth: NetAuth


func setup(auth: NetAuth, p_host: String, p_port: int) -> void:
	_auth = auth
	host = p_host
	port = p_port


func connect_to_server(p_host: String, username: String, password: String, register: bool) -> void:
	host = p_host
	_auth.set_credentials(username, password, register)
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
	if not multiplayer.peer_authenticating.is_connected(_auth.on_peer_authenticating):
		multiplayer.peer_authenticating.connect(_auth.on_peer_authenticating)
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


func _on_connection_failed() -> void:
	print("[net] connection failed or rejected by server")
	Net.login_result_received.emit(false, "Login rejected (bad credentials, name taken, or server unreachable).")


func _on_server_disconnected() -> void:
	print("[net] server disconnected")
	Net.login_result_received.emit(false, "Disconnected from server.")
