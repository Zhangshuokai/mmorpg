class_name NetTransport
extends Node
## ENet connection lifecycle and connection failure reporting (WB0 split; WB7
## owns the security hardening of the handshake). Owns the peer, not the intent
## payloads (see NetInput) nor the credential payload (see NetAuth).

var host := Protocol.DEFAULT_HOST
var port := Protocol.SERVER_PORT

var _auth: NetAuth
## Set once the peer completes the auth handshake (`connected_to_server`). An
## auth rejection never gets here (the server drops the peer mid-handshake), so
## this distinguishes a bad-credential rejection from a real mid-session drop.
var _authenticated := false


func setup(auth: NetAuth, p_host: String, p_port: int) -> void:
	_auth = auth
	host = p_host
	port = p_port
	# A successful login_result also proves auth completed, independent of the
	# `connected_to_server` timing, so a later drop is never mistaken for a
	# rejected login.
	if not Net.login_result_received.is_connected(_on_login_result):
		Net.login_result_received.connect(_on_login_result)


func connect_to_server(p_host: String, username: String, password: String, register: bool) -> void:
	host = p_host
	_auth.set_credentials(username, password, register)
	_authenticated = false
	close()

	# The client must install a non-empty auth_callback before the ENet connection
	# succeeds: SceneMultiplayer only emits `peer_authenticating` (and therefore
	# only starts the challenge-response exchange) when one is set, and the same
	# callback delivers the server's {nonce, salt} challenge.
	multiplayer.auth_callback = Callable(_auth, "on_auth_message")

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		push_error("[net] create_client(%s:%d) failed: %s" % [host, port, error_string(err)])
		Net.login_result_received.emit(false, "Cannot reach %s:%d (%s)" % [host, port, error_string(err)])
		return
	multiplayer.multiplayer_peer = peer

	if not multiplayer.peer_authenticating.is_connected(_auth.on_peer_authenticating):
		multiplayer.peer_authenticating.connect(_auth.on_peer_authenticating)
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
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


func _on_connected_to_server() -> void:
	_authenticated = true


func _on_login_result(ok: bool, _reason: String) -> void:
	if ok:
		_authenticated = true


func _on_connection_failed() -> void:
	print("[net] connection failed: no server at %s:%d" % [host, port])
	Net.login_result_received.emit(false, "Cannot reach server %s:%d - is it running? (check host/port)" % [host, port])


func _on_server_disconnected() -> void:
	var was_authenticated := _authenticated
	_authenticated = false
	if was_authenticated:
		print("[net] server disconnected")
		Net.login_result_received.emit(false, "Disconnected from server.")
	else:
		print("[net] authentication rejected (server closed the connection during login)")
		Net.login_result_received.emit(false, "Login rejected: wrong username/password, or the name is already taken.")
