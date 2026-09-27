class_name AuthHandshake
extends RefCounted
## v2 challenge-response credential handshake (S-E-1), shared verbatim by both
## ends through the `res://shared` junction.
##
## The plaintext password never leaves the client. Every message travels inside
## SceneMultiplayer's authentication channel (`auth_callback` / `send_auth`), the
## ONLY place credentials may cross the wire; no gameplay @rpc is involved.
##
## Wire format (a small JSON document, capped at MAX_PAYLOAD_BYTES):
##
##   client -> server  { "v":2, "mode":"proof", "protocol":2, "user":<name>, "register":<bool> }
##   server -> client  { "v":2, "mode":"proof", "nonce":<hex>, "salt":<hex> }
##   client -> server  { "v":2, "mode":"proof", "user":<name>, "proof":<hex> }
##
## where, with `verifier = SHA-256(salt || password)`:
##   * login    proof = SHA-256(nonce || verifier)   (fresh nonce => no replay)
##   * register proof = verifier                     (the server generated `salt`
##                                                     in its challenge and stores
##                                                     `salt` + `verifier` as the
##                                                     account row)
##
## COMPATIBILITY: Protocol.PROTOCOL_VERSION is 2 and old v1 clients - which send
## the password in a bare `pass` field - are intentionally not accepted. The
## stored `password_hash` format is unchanged (SHA-256(salt || password)), so
## accounts created before WB7 still log in through the new handshake.
##
## SECURITY BOUNDARY: Godot's high-level multiplayer is unencrypted ENet/UDP. This
## removes the cleartext password from the wire, but a captured registration
## verifier is still password-equivalent ("pass the hash"), and traffic is still
## readable/observable. Public exposure additionally needs transport encryption.

## Protocol version of this handshake (not the same as Protocol.PROTOCOL_VERSION,
## which it must accompany in every client message).
const VERSION := 2
const NONCE_BYTES := 16
const SALT_BYTES := 16
## Hard cap applied before any JSON parsing, so an oversized payload is rejected
## by a cheap length check instead of the parser.
const MAX_PAYLOAD_BYTES := 1024


## SHA-256(salt_hex || password) as lowercase hex. Kept byte-for-byte identical to
## the historical AuthService._hash so old rows keep validating.
static func hash_password(password: String, salt_hex: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(salt_hex.to_utf8_buffer())
	ctx.update(password.to_utf8_buffer())
	return ctx.finish().hex_encode()


## SHA-256(nonce_hex || verifier_hex) as lowercase hex: the login response.
static func make_proof(nonce_hex: String, verifier_hex: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(nonce_hex.to_utf8_buffer())
	ctx.update(verifier_hex.to_utf8_buffer())
	return ctx.finish().hex_encode()


static func random_hex(byte_count: int) -> String:
	return Crypto.new().generate_random_bytes(byte_count).hex_encode()


## First client message: challenge request. Carries no secret at all.
static func hello_payload(username: String, register: bool) -> PackedByteArray:
	return JSON.stringify({
		Protocol.AUTH_VERSION: VERSION,
		Protocol.AUTH_MODE: Protocol.AUTH_MODE_PROOF,
		Protocol.AUTH_PROTOCOL: Protocol.PROTOCOL_VERSION,
		Protocol.AUTH_USER: username,
		Protocol.AUTH_REGISTER: register,
	}).to_utf8_buffer()


## Server challenge: one-time nonce plus the per-account salt (a random salt for an
## unknown account, so the reply does not leak whether the name exists).
static func challenge_payload(nonce_hex: String, salt_hex: String) -> PackedByteArray:
	return JSON.stringify({
		Protocol.AUTH_VERSION: VERSION,
		Protocol.AUTH_MODE: Protocol.AUTH_MODE_PROOF,
		Protocol.AUTH_NONCE: nonce_hex,
		Protocol.AUTH_SALT: salt_hex,
	}).to_utf8_buffer()


## Second client message: the derived proof (or the registration verifier).
static func proof_payload(username: String, proof_hex: String) -> PackedByteArray:
	return JSON.stringify({
		Protocol.AUTH_VERSION: VERSION,
		Protocol.AUTH_MODE: Protocol.AUTH_MODE_PROOF,
		Protocol.AUTH_USER: username,
		Protocol.AUTH_PROOF: proof_hex,
	}).to_utf8_buffer()


## Parses an auth payload. Returns {} for anything malformed, non-object or over
## MAX_PAYLOAD_BYTES so callers reject with a single `is_empty()` check.
static func parse(payload: PackedByteArray) -> Dictionary:
	if payload.size() == 0 or payload.size() > MAX_PAYLOAD_BYTES:
		return {}
	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


## True when `value` is exactly `length` ASCII hex characters.
static func is_hex(value: String, length: int) -> bool:
	if value.length() != length:
		return false
	for i in length:
		var code := value.unicode_at(i)
		var is_digit := code >= 48 and code <= 57
		var is_lower := code >= 97 and code <= 102
		var is_upper := code >= 65 and code <= 70
		if not (is_digit or is_lower or is_upper):
			return false
	return true
