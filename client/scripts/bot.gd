class_name BotClient
extends Node
## Headless self-test runner. It behaves exactly like a player client (it only
## ever uploads input and intents) and exits with code 0 only if the
## server-authoritative chain works end to end.
##
##   godot --headless --path client -- --bot --host 127.0.0.1 [--bot-user name]
##
## WB0 split the assertions into client/scripts/bot_checks/*.gd (auto-registered
## below). This file only owns the connection phases, timeouts and reporting.

const OVERALL_TIMEOUT_SEC := 90.0
const PLAY_TIMEOUT_SEC := 45.0
const ATTACK_INTERVAL_SEC := 1.05

var net: NetworkClient
var host := Protocol.DEFAULT_HOST
var port := Protocol.SERVER_PORT
var username := ""
var password := "botpass123"
var char_name := ""
## When true the run only passes if another player was seen moving - proves
## mutual visibility between two real clients.
var require_remote := false
## When true the run also waits for a killed mob to respawn (acceptance: the
## death/respawn loop is closed on the server).
var require_respawn := false
## Enemy-free multiplayer debug mode: the bot only walks in its own direction and
## the run asserts the player<->player replication chain (no combat involved).
## Meant to run against a server started with --no-mobs.
var multiplayer_only := false
## When > 0 the bot does not exit as soon as the checks pass; it stays in the
## world roaming for this many seconds (for manual, visible multi-user play).
var run_seconds := 0.0

var _wander_yaw := 0.0
var _wander_timer := 0.0

var _phase := "connect"
var _elapsed := 0.0
var _play_elapsed := 0.0
var _attempts := 0
var _done := false

var _login_ok := false
var _list_received := false
var _create_attempts := 0
var _enter_world := false
var _self_id := 0
var _self_name := ""
var _self_pos := Vector3.ZERO
var _self_hp := 0
var _self_max_hp := Protocol.PLAYER_MAX_HP
var _start_pos := Vector3.ZERO
var _moved := 0.0
var _ticks := 0
var _combat_seen := false
var _kill_seen := false
var _respawn_seen := false
var _damage_dealt := 0
var _damage_taken := 0

var _mobs: Dictionary = {}
var _players: Dictionary = {}
var _remote_start: Dictionary = {}
var _remote_travel := 0.0
var _attack_accum := 0.0

## BotCheck instances, glob-discovered from res://scripts/bot_checks.
var _checks: Array = []


func _ready() -> void:
	if username.is_empty():
		username = "bot_%06d" % (randi() % 1000000)
	if char_name.is_empty():
		char_name = "Bot%d" % (absi(username.hash()) % 100000)
	password = "botpass123"
	# Fan the bots out: a stable per-user heading so no two random users walk the
	# exact same line and remote movement is unambiguous.
	_wander_yaw = float(absi(username.hash()) % 628) / 100.0

	_load_checks()
	print("[bot] mode=%s" % ("multiplayer-only" if multiplayer_only else "combat"))

	Net.login_result_received.connect(_on_login_result)
	Net.character_list_received.connect(_on_character_list)
	Net.world_entered.connect(_on_enter_world)
	Net.entity_spawned.connect(_on_spawn_entity)
	Net.entity_despawned.connect(_on_despawn_entity)
	Net.world_state_received.connect(_on_world_state)
	Net.combat_event_received.connect(_on_combat_event)
	Net.hp_update_received.connect(_on_hp_update)

	print("[bot] username=%s character=%s server=%s:%d" % [username, char_name, host, port])
	_try_login()


## Discovers every BotCheck module so a workbench can add assertions by dropping
## a file into res://scripts/bot_checks without touching this runner.
func _load_checks() -> void:
	_checks.clear()
	var dir := DirAccess.open("res://scripts/bot_checks")
	if dir == null:
		push_warning("[bot] bot_checks directory missing; no assertions loaded")
		return
	var paths: Array[String] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".gd") \
				and file_name != "bot_check.gd":
			paths.append("res://scripts/bot_checks/".path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	for path in paths:
		var script: GDScript = load(path)
		if script == null:
			continue
		var check: Variant = script.new()
		if check is BotCheck:
			(check as BotCheck).bot = self
			_checks.append(check)


func _try_login() -> void:
	_attempts += 1
	# First attempt logs in (proves bad credentials are rejected), the second
	# registers a fresh account.
	var register := _attempts > 1
	print("[bot] auth attempt %d (register=%s)" % [_attempts, register])
	net.connect_to_server(host, username, password, register)


# --- inbound ----------------------------------------------------------------

func _on_login_result(ok: bool, reason: String) -> void:
	if _done or _login_ok:
		return
	if ok:
		_login_ok = true
		_phase = "characters"
		_log("login authenticated")
		net.request_character_list()
		return
	_log("auth rejected (%s)" % reason)
	if _attempts == 1:
		_try_login()
	else:
		_fail("authentication failed twice")


func _on_character_list(list: Array) -> void:
	if _done:
		return
	_list_received = true
	_log("character list: %d entries" % list.size())
	for entry: Dictionary in list:
		if String(entry.get("name", "")) == char_name:
			var id := int(entry.get("id", 0))
			_log("selecting existing character %d" % id)
			_phase = "enter"
			net.select_character(id)
			return
	if _create_attempts >= 2:
		_fail("character could not be created")
		return
	_create_attempts += 1
	_log("creating character '%s'" % char_name)
	_phase = "enter"
	net.create_character(char_name, Protocol.ClassId.WARRIOR)


func _on_enter_world(self_id: int, spawn: Vector3, hp: int) -> void:
	if _done:
		return
	_self_id = self_id
	_self_pos = spawn
	_start_pos = spawn
	_self_hp = hp
	_enter_world = true
	_phase = "play"
	_log("entered world as entity %d at %s" % [self_id, str(spawn)])


func _on_spawn_entity(state: Dictionary) -> void:
	var id := int(state.get("id", 0))
	if id == _self_id:
		_self_name = String(state.get("name", ""))
		_self_max_hp = int(state.get("max_hp", _self_max_hp))
		return
	if int(state.get("kind", Protocol.EntityKind.PLAYER)) == Protocol.EntityKind.MOB:
		if _mobs.has(id) and not bool(_mobs[id].get("alive", true)):
			_respawn_seen = true
			_log("mob %d respawned" % id)
		_mobs[id] = state
		_log("mob %d spawned at %s" % [id, str(state.get("pos", Vector3.ZERO))])
	else:
		var pos: Vector3 = state.get("pos", Vector3.ZERO)
		_players[id] = pos
		_remote_start[id] = pos
		_log("player entity %d spawned at %s" % [id, str(pos)])


func _on_despawn_entity(id: int) -> void:
	_mobs.erase(id)
	_players.erase(id)
	_remote_start.erase(id)


func _on_world_state(_tick: int, list: Array) -> void:
	_ticks += 1
	for entry: Dictionary in list:
		var id := int(entry.get("id", 0))
		if id == _self_id:
			var pos: Vector3 = entry.get("pos", _self_pos)
			_self_pos = pos
			_self_hp = int(entry.get("hp", _self_hp))
			_moved = _start_pos.distance_to(_self_pos)
		elif _mobs.has(id):
			if not bool(_mobs[id].get("alive", true)) and bool(entry.get("alive", true)):
				_respawn_seen = true
				_log("mob %d alive again" % id)
			_mobs[id] = entry
		elif _players.has(id):
			var remote_pos: Vector3 = entry.get("pos", _players[id])
			_players[id] = remote_pos
			var origin: Vector3 = _remote_start.get(id, remote_pos)
			_remote_travel = maxf(_remote_travel, origin.distance_to(remote_pos))


func _on_combat_event(id: int, target_id: int, damage: int, target_hp: int) -> void:
	if id == _self_id:
		_combat_seen = true
		_damage_dealt += damage
		if target_hp <= 0:
			_kill_seen = true
			_log("killed entity %d (dealt %d total damage)" % [target_id, _damage_dealt])
	if target_id == _self_id:
		_damage_taken += damage


func _on_hp_update(id: int, hp: int) -> void:
	if _mobs.has(id) and hp <= 0:
		_kill_seen = true
	if id == _self_id:
		_self_hp = hp


# --- main loop --------------------------------------------------------------

func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	var overall := OVERALL_TIMEOUT_SEC if run_seconds <= 0.0 else run_seconds + 60.0
	if _elapsed > overall:
		_fail("overall timeout in phase '%s'" % _phase)
		return
	if _phase != "play":
		return

	_play_elapsed += delta
	if run_seconds > 0.0:
		if _play_elapsed >= run_seconds:
			_finish()
			return
	elif _play_elapsed > PLAY_TIMEOUT_SEC:
		_fail("play phase timeout")
		return

	var target_id := 0
	var move := Vector2.ZERO
	var yaw := 0.0
	var distance := 0.0
	if multiplayer_only:
		# No enemies exist: roam so the server keeps this player moving. Re-steer
		# periodically so it neither wedges against the map edge or a cover nor
		# walks in lockstep with the other users.
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = 4.0 + float(randi() % 400) / 100.0
			_wander_yaw = randf() * TAU
		move = Vector2(0.0, 1.0)
		yaw = _wander_yaw
	else:
		target_id = _nearest_living_mob()
		if target_id != 0:
			var mob: Dictionary = _mobs[target_id]
			var mob_pos: Vector3 = mob.get("pos", Vector3.ZERO)
			var to_mob := mob_pos - _self_pos
			to_mob.y = 0.0
			distance = to_mob.length()
			if distance > 0.01:
				yaw = atan2(-to_mob.x, -to_mob.z)
			if distance > Protocol.MELEE_RANGE * 0.75:
				move = Vector2(0.0, 1.0)

	net.tick_input(delta, move, yaw, 0)

	_attack_accum += delta
	if not multiplayer_only and target_id != 0 and distance <= Protocol.MELEE_RANGE and _attack_accum >= ATTACK_INTERVAL_SEC:
		_attack_accum = 0.0
		net.use_ability(Protocol.AbilityId.MELEE, target_id)

	if run_seconds <= 0.0 and _all_checks_pass():
		_finish()


func _nearest_living_mob() -> int:
	var best_id := 0
	var best_dist := 1.0e9
	for id: int in _mobs.keys():
		var entry: Dictionary = _mobs[id]
		if not bool(entry.get("alive", true)):
			continue
		var pos: Vector3 = entry.get("pos", Vector3.ZERO)
		var distance := _self_pos.distance_to(pos)
		if distance < best_dist:
			best_dist = distance
			best_id = id
	return best_id


## A run passes only when every `required` assertion holds. `optional` ones are
## reported but never fail the run.
func _all_checks_pass() -> bool:
	for result: Dictionary in _evaluate_all():
		if bool(result.get("required", false)) and not bool(result.get("ok", false)):
			return false
	return true


func _evaluate_all() -> Array:
	var results: Array = []
	for check: BotCheck in _checks:
		results.append_array(check.evaluate())
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("order", 0)) < int(b.get("order", 0)))
	return results


# --- reporting --------------------------------------------------------------

func _report() -> void:
	for result: Dictionary in _evaluate_all():
		var name := String(result.get("name", "?"))
		var ok := bool(result.get("ok", false))
		var required := bool(result.get("required", false))
		var detail := String(result.get("detail", ""))
		var line := "[bot] CHECK %s=" % name
		if required:
			line += "OK" if ok else "FAIL"
		else:
			line += "OK" if ok else "N/A"
		if not detail.is_empty():
			line += " (%s)" % detail
		print(line)


func _finish() -> void:
	_done = true
	_report()
	print("[bot] RESULT PASS")
	get_tree().quit(0)


func _fail(reason: String) -> void:
	_done = true
	_report()
	print("[bot] RESULT FAIL: %s" % reason)
	get_tree().quit(1)


func _log(message: String) -> void:
	print("[bot] %s" % message)
