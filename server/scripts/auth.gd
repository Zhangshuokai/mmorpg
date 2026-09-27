class_name AuthService
extends Node
## Account authentication and registration.
##
## Credentials arrive ONLY in the auth payload of `SceneMultiplayer.auth_callback`
## (never through a gameplay @rpc). Since WB7 (S-E-1) the handshake is the shared
## v2 challenge-response protocol in `AuthHandshake`:
##
##   1. client sends a hello (user/register, no secret);
##   2. the server replies with a one-time nonce + the account salt;
##   3. the client answers with SHA-256(nonce || SHA-256(salt || password))
##      (login) or with the salted verifier itself (register).
##
## The plaintext password never crosses the wire and a captured login response
## cannot be replayed because the nonce is fresh per attempt.
##
## Two throttling dimensions run here:
##   * per-account failure backoff (unchanged since the MVP), and
##   * per-source (client IP) frequency caps + failure blocking in RateLimitService,
##     so one host cannot sweep usernames or hammer the handshake.
##
## COMPATIBILITY: only Protocol.PROTOCOL_VERSION == 2 clients are accepted; an old
## v1 client sending a bare `pass` field is rejected with a clear log. The stored
## `password_hash` format is unchanged, so pre-WB7 accounts still log in.
##
## SECURITY BOUNDARY: ENet/UDP is still unencrypted. Challenge-response removes the
## cleartext password but not "pass the hash" of a captured registration verifier
## nor traffic analysis; public exposure still needs transport encryption.

## Brute-force friction: the first few failures are free (so a legitimate
## "try login, else register" client flow still works), then the account is
## locked out with linearly growing backoff. Counters expire and the table is
## hard-capped so a flood of invented usernames cannot grow it without bound.
const FAILURE_THRESHOLD := 3
const BACKOFF_MS := 2000
const STALE_MS := 300000
const MAX_TRACKED_FAILURES := 512

## Per-source (client IP) caps for the two handshake stages.
const AUTH_RATE_PER_SEC := 5.0
const AUTH_RATE_BURST := 15
const PROOF_RATE_PER_SEC := 5.0
const PROOF_RATE_BURST := 15

var db: DBService
var persistence: PersistenceService

## peer_id -> account_id, for peers that completed authentication.
var sessions: Dictionary = {}
## peer_id -> username, for logging.
var names: Dictionary = {}
## lowercased username -> {"count": int, "until": unix msec} (account dimension).
var _failures: Dictionary = {}
## peer_id -> in-flight challenge; cleared on success, rejection or forget().
var _pending: Dictionary = {}

## Source/connection dimension (client IP), additional to the account dimension.
var rate_limit := RateLimitService.new()

## Raw auth payload dump, gated behind MMORPG_AUTH_TRACE=1 for the WB7 evidence
## run. The v2 payloads contain only hashes / public nonces-salt, never a password.
var _trace := false


func _ready() -> void:
	_trace = OS.get_environment("MMORPG_AUTH_TRACE") == "1"
	# The challenge adds one round trip; the engine default (3s) is tight on a
	# slow link, so allow a little more room without opening a long idle window.
	multiplayer.auth_timeout = 5.0


# --- SceneMultiplayer auth_callback ----------------------------------------

func handle_auth(peer_id: int, payload: PackedByteArray) -> void:
	_trace_payload(peer_id, payload, "in")
	var data := AuthHandshake.parse(payload)
	if data.is_empty():
		_reject(peer_id, "malformed or oversized auth payload", true)
		return
	if int(data.get(Protocol.AUTH_VERSION, 0)) != AuthHandshake.VERSION \
			or String(data.get(Protocol.AUTH_MODE, "")) != Protocol.AUTH_MODE_PROOF:
		_reject(peer_id, "unsupported auth version/mode (v1 cleartext no longer accepted)", true)
		return
	if _pending.has(peer_id):
		_finish_proof(peer_id, data)
	else:
		_begin_challenge(peer_id, data)


## First client message: validate the request, issue nonce + salt. Does NOT
## complete auth - the peer stays unauthenticated until a valid proof arrives.
func _begin_challenge(peer_id: int, data: Dictionary) -> void:
	var source := _source_key(peer_id)
	if rate_limit.is_source_blocked(source):
		_reject(peer_id, "source temporarily blocked after repeated auth failures", false)
		return
	if not rate_limit.allow("auth:" + source, "challenge", AUTH_RATE_PER_SEC, AUTH_RATE_BURST):
		_reject(peer_id, "auth challenge rate limit exceeded for this source", true)
		return
	if int(data.get(Protocol.AUTH_PROTOCOL, -1)) != Protocol.PROTOCOL_VERSION:
		_reject(peer_id, "protocol version mismatch", true)
		return

	var username := String(data.get(Protocol.AUTH_USER, "")).strip_edges()
	if username.length() < Protocol.USER_MIN or username.length() > Protocol.USER_MAX:
		_reject(peer_id, "username length out of range", true)
		return
	var register := bool(data.get(Protocol.AUTH_REGISTER, false))

	var salt := ""
	if register:
		salt = AuthHandshake.random_hex(AuthHandshake.SALT_BYTES)
	else:
		var rows := db.select("SELECT salt FROM accounts WHERE username = ?;", [username])
		if rows.is_empty():
			# Unknown account: still issue a challenge with a random salt so the
			# reply is indistinguishable from a real one (no username enumeration).
			salt = AuthHandshake.random_hex(AuthHandshake.SALT_BYTES)
		else:
			salt = String(rows[0].get("salt", ""))

	var nonce := AuthHandshake.random_hex(AuthHandshake.NONCE_BYTES)
	_pending[peer_id] = {
		"user": username,
		"register": register,
		"salt": salt,
		"nonce": nonce,
	}
	var challenge := AuthHandshake.challenge_payload(nonce, salt)
	_trace_payload(peer_id, challenge, "out")
	var err: int = multiplayer.send_auth(peer_id, challenge)
	if err != OK:
		_pending.erase(peer_id)
		push_error("[auth] send_auth(challenge) to peer %d failed: %s" % [peer_id, error_string(err)])
		multiplayer.disconnect_peer(peer_id)
		return
	print("[auth] peer %d challenged (user='%s', register=%s)" % [peer_id, username, register])


## Second client message: verify the proof (or store the registration verifier).
func _finish_proof(peer_id: int, data: Dictionary) -> void:
	var pending: Dictionary = _pending[peer_id]
	var source := _source_key(peer_id)
	var username := String(pending.get("user", ""))
	var register := bool(pending.get("register", false))
	var salt := String(pending.get("salt", ""))

	if rate_limit.is_source_blocked(source):
		_reject(peer_id, "source temporarily blocked after repeated auth failures", false)
		return
	if not rate_limit.allow("auth:" + source, "proof", PROOF_RATE_PER_SEC, PROOF_RATE_BURST):
		_reject(peer_id, "proof rate limit exceeded for this source", true)
		return
	if _is_locked(username):
		_reject(peer_id, "account temporarily locked after repeated failures", false)
		return

	var proof := String(data.get(Protocol.AUTH_PROOF, ""))
	if not AuthHandshake.is_hex(proof, 64):
		_reject(peer_id, "malformed proof", true)
		return

	var account_id := -1
	if register:
		account_id = _store_account(username, salt, proof)
		if account_id < 0:
			_record_failure(username)
			rate_limit.record_failure(source)
			_reject(peer_id, "registration failed (account or name already taken)", false)
			return
	else:
		var rows := db.select("SELECT id, password_hash FROM accounts WHERE username = ?;", [username])
		var expected := ""
		if not rows.is_empty():
			expected = AuthHandshake.make_proof(String(pending.get("nonce", "")), String(rows[0].get("password_hash", "")))
			if _equals_constant_time(expected, proof):
				account_id = int(rows[0].get("id", -1))
		if account_id < 0:
			_record_failure(username)
			rate_limit.record_failure(source)
			_reject(peer_id, "bad credentials", false)
			return

	_pending.erase(peer_id)
	_clear_failures(username)
	rate_limit.clear_failures(source)
	sessions[peer_id] = account_id
	names[peer_id] = username
	# Authentication accepted: only now does MultiplayerAPI mark the peer as
	# connected (peer_connected fires).
	var err: int = multiplayer.complete_auth(peer_id)
	if err != OK:
		push_error("[auth] complete_auth(%d) failed: %s" % [peer_id, error_string(err)])
		sessions.erase(peer_id)
		names.erase(peer_id)
		multiplayer.disconnect_peer(peer_id)
		return
	print("[auth] peer %d authenticated as '%s' (account %d, register=%s)" % [peer_id, username, account_id, register])


func account_for(peer_id: int) -> int:
	return int(sessions.get(peer_id, -1))


func username_for(peer_id: int) -> String:
	return String(names.get(peer_id, ""))


func forget(peer_id: int) -> void:
	sessions.erase(peer_id)
	names.erase(peer_id)
	_pending.erase(peer_id)


# --- rejection ---------------------------------------------------------------

## `count_as_failure` feeds the source dimension; account-dimension failures are
## recorded at the point where the username is known.
func _reject(peer_id: int, reason: String, count_as_failure: bool) -> void:
	_pending.erase(peer_id)
	if count_as_failure:
		rate_limit.record_failure(_source_key(peer_id))
	print("[auth] rejected peer %d: %s" % [peer_id, reason])
	multiplayer.disconnect_peer(peer_id)


## Client identity for source-level limiting. Prefers the real ENet remote
## address; falls back to the connection id if the peer is not an ENet peer.
func _source_key(peer_id: int) -> String:
	var peer := multiplayer.multiplayer_peer
	if peer is ENetMultiplayerPeer:
		var enet_peer := (peer as ENetMultiplayerPeer).get_peer(peer_id)
		if enet_peer != null:
			return enet_peer.get_remote_address()
	return "peer:%d" % peer_id


func _trace_payload(peer_id: int, payload: PackedByteArray, direction: String) -> void:
	if not _trace:
		return
	print("[auth-trace] %s peer=%d bytes=%d json=%s" % [
		direction, peer_id, payload.size(), payload.get_string_from_utf8()])


## Length-checked, branch-light comparison. Both operands are 64-char hex at the
## call site; this avoids an early-exit on the first differing character.
func _equals_constant_time(a: String, b: String) -> bool:
	if a.length() != b.length():
		return false
	var diff := 0
	for i in a.length():
		diff |= a.unicode_at(i) ^ b.unicode_at(i)
	return diff == 0


# --- account-dimension brute-force throttling --------------------------------

func _is_locked(username: String) -> bool:
	var record: Dictionary = _failures.get(_failure_key(username), {})
	return Time.get_ticks_msec() < int(record.get("until", 0))


func _record_failure(username: String) -> void:
	var key := _failure_key(username)
	var record: Dictionary = _failures.get(key, {"count": 0})
	var count := int(record.get("count", 0)) + 1
	var until := 0
	if count >= FAILURE_THRESHOLD:
		until = Time.get_ticks_msec() + BACKOFF_MS * (count - FAILURE_THRESHOLD + 1)
	_failures[key] = {"count": count, "until": until, "seen": Time.get_ticks_msec()}
	if _failures.size() > MAX_TRACKED_FAILURES:
		_prune_failures()


func _clear_failures(username: String) -> void:
	_failures.erase(_failure_key(username))


func _prune_failures() -> void:
	var now := Time.get_ticks_msec()
	for key: String in _failures.keys():
		var record: Dictionary = _failures[key]
		var locked_until := int(record.get("until", 0))
		var lock_expired := locked_until > 0 and now >= locked_until
		var stale := now - int(record.get("seen", now)) > STALE_MS
		if lock_expired or stale:
			_failures.erase(key)
	if _failures.size() > MAX_TRACKED_FAILURES:
		# Hard cap: fail open on throttling rather than grow without bound.
		_failures.clear()


func _failure_key(username: String) -> String:
	return username.to_lower()


# --- account storage --------------------------------------------------------

## Registration stores the client-provided salted verifier (the server generated
## `salt` in the challenge, so it is not client-chosen) - never a plaintext or
## nonce-bound value, because this is what future logins compute against.
func _store_account(username: String, salt_hex: String, verifier_hex: String) -> int:
	if not AuthHandshake.is_hex(salt_hex, AuthHandshake.SALT_BYTES * 2) \
			or not AuthHandshake.is_hex(verifier_hex, 64):
		return -1
	var existing := db.select("SELECT id FROM accounts WHERE username = ?;", [username])
	if not existing.is_empty():
		return -1
	var ok := db.execute(
		"INSERT INTO accounts(username, password_hash, salt, created_at) VALUES(?, ?, ?, ?);",
		[username, verifier_hex, salt_hex, Time.get_datetime_string_from_system(true)])
	if not ok:
		return -1
	var account_id := db.last_insert_id()
	print("[auth] registered account '%s' (id %d)" % [username, account_id])
	return account_id
