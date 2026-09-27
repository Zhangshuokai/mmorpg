class_name RateLimitService
extends RefCounted
## Source (client-IP) and per-connection frequency throttling (S-E-2).
##
## This is a SECOND dimension on top of - never a replacement for - the
## per-account failure backoff that stays in AuthService: the account backoff
## protects one username, while this protects the server from a single host that
## keeps guessing usernames or hammering an RPC.
##
## Two independent mechanisms:
##   * `allow()`: token bucket per (key, action), for smooth frequency caps;
##   * `record_failure()` / `is_source_blocked()`: after FAIL_THRESHOLD failures a
##     source is blocked for a cooldown that doubles per extra failure (bounded by
##     BLOCK_MAX_MS), which stops a same-source brute force before the account
##     dimension could even see it.
##
## In-memory and main-thread only: Godot's high-level multiplayer callbacks, the
## world tick and all DB access run on the main thread. Both tables are capped and
## pruned so an attacker cannot grow them without bound (the bucket table fails
## open if it ever hits its cap).

const FAIL_THRESHOLD := 5
const BLOCK_BASE_MS := 15000
const BLOCK_MAX_MS := 300000
const FAILURE_STALE_MS := 600000
const MAX_SOURCE_RECORDS := 1024
const MAX_BUCKETS := 4096
## Log suppression: at most one "rate limited" note per key per second.
const LOG_SUPPRESS_MS := 1000

## "key|action" -> {"tokens": float, "at": unix msec}
var _buckets: Dictionary = {}
## source -> {"count": int, "until": unix msec, "seen": unix msec}
var _failures: Dictionary = {}
var _last_log: Dictionary = {}


## Token bucket check. Returns true while the action is inside its budget; every
## call consumes one token, refilled at `rate_per_sec` up to `burst`.
func allow(key: String, action: String, rate_per_sec: float, burst: int) -> bool:
	var id := "%s|%s" % [key, action]
	var now := Time.get_ticks_msec()
	var bucket: Dictionary = _buckets.get(id, {"tokens": float(burst), "at": now})
	var elapsed := float(now - int(bucket.get("at", now))) / 1000.0
	var tokens := minf(float(burst), float(bucket.get("tokens", burst)) + maxf(0.0, elapsed) * rate_per_sec)
	if tokens < 1.0:
		_buckets[id] = {"tokens": tokens, "at": now}
		_cap_buckets()
		return false
	_buckets[id] = {"tokens": tokens - 1.0, "at": now}
	_cap_buckets()
	return true


## True while `source` is serving a cooldown after repeated failures.
func is_source_blocked(source: String) -> bool:
	var record: Dictionary = _failures.get(source, {})
	return Time.get_ticks_msec() < int(record.get("until", 0))


func record_failure(source: String) -> void:
	var now := Time.get_ticks_msec()
	var record: Dictionary = _failures.get(source, {"count": 0})
	var count := int(record.get("count", 0)) + 1
	var until := 0
	if count >= FAIL_THRESHOLD:
		# Overflow-safe doubling, clamped to the ceiling.
		var steps := mini(count - FAIL_THRESHOLD, 8)
		until = now + mini(BLOCK_BASE_MS << steps, BLOCK_MAX_MS)
	_failures[source] = {"count": count, "until": until, "seen": now}
	if _failures.size() > MAX_SOURCE_RECORDS:
		_prune_failures()


## A successful authentication proves the source is not (currently) an attacker,
## so its failure streak is dropped. Pure brute force never succeeds and keeps
## accumulating until it is blocked.
func clear_failures(source: String) -> void:
	_failures.erase(source)


## True at most once per LOG_SUPPRESS_MS for `key|action`; used by callers to
## avoid turning a rate-limited flood into a log flood.
func log_allowed(key: String, action: String) -> bool:
	var id := "%s|%s" % [key, action]
	var now := Time.get_ticks_msec()
	if now - int(_last_log.get(id, 0)) < LOG_SUPPRESS_MS:
		return false
	_last_log[id] = now
	if _last_log.size() > MAX_BUCKETS:
		_last_log.clear()
	return true


func _cap_buckets() -> void:
	if _buckets.size() > MAX_BUCKETS:
		# Fail open: dropping throttle state is better than unbounded memory.
		_buckets.clear()


func _prune_failures() -> void:
	var now := Time.get_ticks_msec()
	for source: String in _failures.keys():
		var record: Dictionary = _failures[source]
		var blocked_until := int(record.get("until", 0))
		var block_expired := blocked_until > 0 and now >= blocked_until
		var stale := now - int(record.get("seen", now)) > FAILURE_STALE_MS
		if block_expired or stale:
			_failures.erase(source)
	if _failures.size() > MAX_SOURCE_RECORDS:
		# Hard cap: fail open rather than grow without bound.
		_failures.clear()
