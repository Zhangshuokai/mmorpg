class_name NetAuth
extends Node
## Credential handshake hooks (WB0 seam; WB7 replaces the payload with the
## challenge-response flow). Owns the packed auth payload and the client side of
## `peer_authenticating`.
##
## The client MUST set a non-empty auth_callback and complete_auth here,
## otherwise `peer_authenticating` never fires and no credentials are sent.

var _credentials := PackedByteArray()


func set_credentials(username: String, password: String, register: bool) -> void:
	_credentials = Protocol.auth_payload(username, password, register)


func on_peer_authenticating(peer_id: int) -> void:
	multiplayer.send_auth(1, _credentials)
	multiplayer.complete_auth(peer_id)
