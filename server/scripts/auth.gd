class_name AuthService
extends Node
## Account authentication and registration.
##
## Credentials arrive in the auth payload of `SceneMultiplayer.auth_callback`
## (never through a gameplay @rpc). Passwords are stored as
## SHA-256(salt || password) with a fresh 16-byte random salt per account.
## The plain password never touches disk or logs.
##
## NOTE: Godot's high-level multiplayer runs on unencrypted ENet/UDP, so the
## password crosses the wire in cleartext. This MVP is LAN/trusted-network only;
## see AGENTS.md ("安全边界") before exposing the server publicly.

## Brute-force friction: the first few failures are free (so a legitimate
## "try login, else register" client flow still works), then the account is
## locked out with linearly growing backoff. Counters expire and the table is
## hard-capped so a flood of invented usernames cannot grow it without bound.
const FAILURE_THRESHOLD := 3
const BACKOFF_MS := 2000
const STALE_MS := 300000
const MAX_TRACKED_FAILURES := 512

var db: DBService
var persistence: PersistenceService

## peer_id -> account_id, for peers that completed authentication.
var sessions: Dictionary = {}
## peer_id -> username, for logging.
var names: Dictionary = {}
## lowercased username -> {"count": int, "until": unix msec}
var _failures: Dictionary = {}


# --- SceneMultiplayer auth_callback ----------------------------------------

func handle_auth(peer_id: int, payload: PackedByteArray) -> void:
	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		_reject(peer_id, "malformed auth payload")
		return
	var data: Dictionary = parsed

	if int(data.get(Protocol.AUTH_PROTOCOL, -1)) != Protocol.PROTOCOL_VERSION:
		_reject(peer_id, "protocol version mismatch")
		return

	var username := String(data.get(Protocol.AUTH_USER, "")).strip_edges()
	var password := String(data.get(Protocol.AUTH_PASS, ""))
	var register := bool(data.get(Protocol.AUTH_REGISTER, false))

	if username.length() < Protocol.USER_MIN or username.length() > Protocol.USER_MAX:
		_reject(peer_id, "username length out of range")
		return
	if password.length() < Protocol.PASS_MIN:
		_reject(peer_id, "password too short")
		return
	if _is_locked(username):
		_reject(peer_id, "account temporarily locked after repeated failures")
		return

	var account_id := -1
	if register:
		account_id = _register(username, password)
		if account_id < 0:
			_record_failure(username)
			_reject(peer_id, "registration failed (account or name already taken)")
			return
	else:
		account_id = _login(username, password)
		if account_id < 0:
			_record_failure(username)
			_reject(peer_id, "bad credentials")
			return

	_clear_failures(username)
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
	print("[auth] peer %d authenticated as '%s' (account %d)" % [peer_id, username, account_id])


func account_for(peer_id: int) -> int:
	return int(sessions.get(peer_id, -1))


func username_for(peer_id: int) -> String:
	return String(names.get(peer_id, ""))


func forget(peer_id: int) -> void:
	sessions.erase(peer_id)
	names.erase(peer_id)


func _reject(peer_id: int, reason: String) -> void:
	print("[auth] rejected peer %d: %s" % [peer_id, reason])
	multiplayer.disconnect_peer(peer_id)


# --- brute-force throttling -------------------------------------------------

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

func _register(username: String, password: String) -> int:
	var existing := db.select("SELECT id FROM accounts WHERE username = ?;", [username])
	if not existing.is_empty():
		return -1
	var salt := Crypto.new().generate_random_bytes(16).hex_encode()
	var hash := _hash(password, salt)
	var ok := db.execute(
		"INSERT INTO accounts(username, password_hash, salt, created_at) VALUES(?, ?, ?, ?);",
		[username, hash, salt, Time.get_datetime_string_from_system(true)])
	if not ok:
		return -1
	var account_id := db.last_insert_id()
	print("[auth] registered account '%s' (id %d)" % [username, account_id])
	return account_id


func _login(username: String, password: String) -> int:
	var rows := db.select("SELECT id, password_hash, salt FROM accounts WHERE username = ?;", [username])
	if rows.is_empty():
		return -1
	var row: Dictionary = rows[0]
	var expected := String(row.get("password_hash", ""))
	var actual := _hash(password, String(row.get("salt", "")))
	if expected.is_empty() or actual != expected:
		return -1
	return int(row.get("id", -1))


func _hash(password: String, salt_hex: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(salt_hex.to_utf8_buffer())
	ctx.update(password.to_utf8_buffer())
	return ctx.finish().hex_encode()
