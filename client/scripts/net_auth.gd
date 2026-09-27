class_name NetAuth
extends Node
## Client side of the v2 challenge-response handshake (WB7, S-E-1).
##
## Replaces the old cleartext payload: the password never leaves this node. Only
## derived values are sent - SHA-256(salt || password) for a new account, or
## SHA-256(nonce || SHA-256(salt || password)) to log in.
##
## Both steps run inside `SceneMultiplayer`'s authentication channel (this file is
## the client's `auth_callback`, see NetTransport); no gameplay @rpc is involved:
##
##   peer_authenticating -> send hello (user + register flag, no secret)
##   on_auth_message     -> receive {nonce, salt}, send the proof, complete_auth
##
## SECURITY BOUNDARY: ENet/UDP is unencrypted; this hides the password from the
## wire but not from an active attacker able to capture a registration verifier.

var _username := ""
var _password := ""
var _register := false
var _trace := false


func _ready() -> void:
	_trace = OS.get_environment("MMORPG_AUTH_TRACE") == "1"


func set_credentials(username: String, password: String, register: bool) -> void:
	_username = username
	_password = password
	_register = register


## Client half of `peer_authenticating`: ask for a challenge. Deliberately does
## NOT complete auth - the server must send its nonce first.
func on_peer_authenticating(peer_id: int) -> void:
	_send(peer_id, AuthHandshake.hello_payload(_username, _register))


## Client `auth_callback`: receives the server's {nonce, salt} challenge and
## answers with the derived proof.
func on_auth_message(peer_id: int, data: PackedByteArray) -> void:
	var challenge := AuthHandshake.parse(data)
	if challenge.is_empty() \
			or not challenge.has(Protocol.AUTH_NONCE) \
			or not challenge.has(Protocol.AUTH_SALT):
		push_error("[net] malformed auth challenge from server; cannot authenticate")
		return
	var salt := String(challenge.get(Protocol.AUTH_SALT, ""))
	var nonce := String(challenge.get(Protocol.AUTH_NONCE, ""))
	var verifier := AuthHandshake.hash_password(_password, salt)
	var proof := verifier if _register else AuthHandshake.make_proof(nonce, verifier)
	_send(peer_id, AuthHandshake.proof_payload(_username, proof))
	# The password is no longer needed at all: drop it from memory.
	_password = ""
	multiplayer.complete_auth(peer_id)


func _send(peer_id: int, payload: PackedByteArray) -> void:
	if _trace:
		# Payload inspection hook: prints exactly the bytes handed to ENet.
		print("[net][auth-trace] out bytes=%d json=%s" % [payload.size(), payload.get_string_from_utf8()])
	var err: int = multiplayer.send_auth(peer_id, payload)
	if err != OK:
		push_error("[net] send_auth failed: %s" % error_string(err))
