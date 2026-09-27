class_name BotCheckCombat
extends BotCheck
## Combat assertions (WB2 owns this domain).
##
## The first block covers the original kill/respawn chain. The second block adds
## the S-G-1 boundary probes: the bot fires four table-defined probe abilities
## (ids 10-13 in shared/data/tables/abilities.json) and asserts the server's
## authoritative verdict, observable through the cast-bar signals:
##
##   * cooldown      -> one accepted cast, the immediate second use is rejected
##   * out of range  -> a 0.5m ability never starts against a distant target
##   * invalid target-> a self-targeted enemy ability never starts
##   * interrupt     -> a 1.5s cast started while the bot is still moving is
##                      interrupted by the server (s2c_cast_interrupted)
##
## The probes run while the bot is approaching its first mob, so the movement
## interrupt is deterministic. They never alter the kill loop: every probe is
## rejected, interrupted, or on a separate cooldown, so the melee kill timing is
## unchanged.

const ABILITY_COOLDOWN_PROBE := 10
const ABILITY_RANGE_PROBE := 11
const ABILITY_INVALID_PROBE := 12
const ABILITY_INTERRUPT_PROBE := 13

## Probe schedule, seconds after the first enemy becomes visible. The interrupt
## probe fires first because the bot is guaranteed to still be moving toward its
## first mob, which is exactly what the server uses to break the cast.
const PROBE_INTERRUPT_AT := 0.0
const PROBE_COOLDOWN_AT := 0.30
const PROBE_COOLDOWN_SECOND_AT := 0.45
const PROBE_RANGE_AT := 0.70
const PROBE_INVALID_AT := 0.90

var _probe_origin_msce := -1
var _sent: Dictionary = {}
## ability_id -> accepted cast count observed via s2c_cast_started.
var _cast_started: Dictionary = {}
## ability_id -> interrupted count observed via s2c_cast_interrupted.
var _cast_interrupted: Dictionary = {}


func _init() -> void:
	# Net is an autoload, so it is live before the bot instantiates its checks.
	Net.cast_started.connect(_on_cast_started)
	Net.cast_interrupted.connect(_on_cast_interrupted)


func evaluate() -> Array:
	_tick_probes()
	var multiplayer_only: bool = bot.multiplayer_only
	var respawn_required: bool = bot.require_respawn
	var required: bool = not multiplayer_only
	return [
		# --- original kill / respawn chain ----------------------------------
		{
			"order": 80, "name": "combat_event", "required": required,
			"ok": bot._combat_seen, "detail": "dealt %d damage" % bot._damage_dealt,
		},
		{
			"order": 90, "name": "mob_kill", "required": required,
			"ok": bot._kill_seen, "detail": "",
		},
		{
			"order": 100, "name": "mob_respawn", "required": respawn_required,
			"ok": bot._respawn_seen, "detail": "",
		},
		{
			"order": 110, "name": "took_damage", "required": false,
			"ok": bot._damage_taken > 0, "detail": "%d damage taken" % bot._damage_taken,
		},
		# --- S-G-1 ability boundaries ---------------------------------------
		{
			"order": 120, "name": "ability_cooldown_reject", "required": required,
			# Two rapid uses: exactly one may start, the second is on cooldown.
			"ok": _sent.has("cooldown2") and _count(_cast_started, ABILITY_COOLDOWN_PROBE) == 1,
			"detail": "%d accepted / 2 sent" % _count(_cast_started, ABILITY_COOLDOWN_PROBE),
		},
		{
			"order": 130, "name": "ability_range_reject", "required": required,
			# A 0.5m reach ability cannot start against a target metres away.
			"ok": _sent.has("range") and _count(_cast_started, ABILITY_RANGE_PROBE) == 0,
			"detail": "%d cast starts (expected 0)" % _count(_cast_started, ABILITY_RANGE_PROBE),
		},
		{
			"order": 140, "name": "ability_invalid_target_reject", "required": required,
			# An ENEMY ability aimed at the caster must be refused.
			"ok": _sent.has("invalid") and _count(_cast_started, ABILITY_INVALID_PROBE) == 0,
			"detail": "%d cast starts (expected 0)" % _count(_cast_started, ABILITY_INVALID_PROBE),
		},
		{
			"order": 150, "name": "ability_cast_started", "required": required,
			"ok": _count(_cast_started, ABILITY_INTERRUPT_PROBE) >= 1,
			"detail": "%d cast signal(s)" % _count(_cast_started, ABILITY_INTERRUPT_PROBE),
		},
		{
			"order": 160, "name": "ability_cast_interrupted", "required": required,
			# The cast began while moving, so the server must interrupt it.
			"ok": _count(_cast_interrupted, ABILITY_INTERRUPT_PROBE) >= 1,
			"detail": "%d interrupt signal(s)" % _count(_cast_interrupted, ABILITY_INTERRUPT_PROBE),
		},
	]


# --- probes -----------------------------------------------------------------

## Per-frame driver (evaluate() is called every frame while the bot is playing).
func _tick_probes() -> void:
	if bot == null or bot._done or bot._phase != "play" or bot.multiplayer_only:
		return
	if bot._self_id == 0:
		return
	var target: int = bot._nearest_living_mob()
	if target == 0:
		return
	var now := Time.get_ticks_msec()
	if _probe_origin_msce < 0:
		_probe_origin_msce = now
	var elapsed := float(now - _probe_origin_msce) / 1000.0

	if elapsed >= PROBE_INTERRUPT_AT and _send_once("interrupt"):
		bot.net.use_ability(ABILITY_INTERRUPT_PROBE, target)
	if elapsed >= PROBE_COOLDOWN_AT and _send_once("cooldown"):
		bot.net.use_ability(ABILITY_COOLDOWN_PROBE, target)
	if elapsed >= PROBE_COOLDOWN_SECOND_AT and _send_once("cooldown2"):
		bot.net.use_ability(ABILITY_COOLDOWN_PROBE, target)
	if elapsed >= PROBE_RANGE_AT and _send_once("range"):
		bot.net.use_ability(ABILITY_RANGE_PROBE, target)
	if elapsed >= PROBE_INVALID_AT and _send_once("invalid"):
		bot.net.use_ability(ABILITY_INVALID_PROBE, bot._self_id)


func _send_once(key: String) -> bool:
	if _sent.has(key):
		return false
	_sent[key] = true
	return true


# --- signals ----------------------------------------------------------------

func _on_cast_started(_caster_id: int, ability_id: int, _target_id: int, _duration_sec: float) -> void:
	_cast_started[ability_id] = _count(_cast_started, ability_id) + 1


func _on_cast_interrupted(_caster_id: int, ability_id: int, _reason: int) -> void:
	_cast_interrupted[ability_id] = _count(_cast_interrupted, ability_id) + 1


func _count(counts: Dictionary, ability_id: int) -> int:
	return int(counts.get(ability_id, 0))
