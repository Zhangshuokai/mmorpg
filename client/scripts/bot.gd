class_name BotClient
extends Node
## Headless self-test for the whole loop. It behaves exactly like a player client
## (it only ever uploads input and intents) and exits with code 0 only if the
## server-authoritative chain works end to end.
##
##   godot --headless --path client -- --bot --host 127.0.0.1 [--bot-user name]

const OVERALL_TIMEOUT_SEC := 90.0
const PLAY_TIMEOUT_SEC := 45.0
const ATTACK_INTERVAL_SEC := 1.05
const MOVE_EPSILON := 1.0

var net: NetworkClient
var host := Protocol.DEFAULT_HOST
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
var _seq := 0
var _send_accum := 0.0
var _attack_accum := 0.0


func _ready() -> void:
	if username.is_empty():
		username = "bot_%06d" % (randi() % 1000000)
	if char_name.is_empty():
		char_name = "Bot%d" % (absi(username.hash()) % 100000)
	password = "botpass123"
	# Fan the bots out: a stable per-user heading so no two random users walk the
	# exact same line and remote movement is unambiguous.
	_wander_yaw = float(absi(username.hash()) % 628) / 100.0

	print("[bot] mode=%s" % ("multiplayer-only" if multiplayer_only else "combat"))

	Net.login_result_received.connect(_on_login_result)
	Net.character_list_received.connect(_on_character_list)
	Net.world_entered.connect(_on_enter_world)
	Net.entity_spawned.connect(_on_spawn_entity)
	Net.entity_despawned.connect(_on_despawn_entity)
	Net.world_state_received.connect(_on_world_state)
	Net.combat_event_received.connect(_on_combat_event)
	Net.hp_update_received.connect(_on_hp_update)

	print("[bot] username=%s character=%s server=%s:%d" % [username, char_name, host, Protocol.SERVER_PORT])
	_try_login()


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

	_send_accum += delta
	if _send_accum >= Protocol.TICK_DT:
		_send_accum = 0.0
		_seq += 1
		net.send_input(_seq, move, yaw, 0)

	_attack_accum += delta
	if not multiplayer_only and target_id != 0 and distance <= Protocol.MELEE_RANGE and _attack_accum >= ATTACK_INTERVAL_SEC:
		_attack_accum = 0.0
		net.use_ability(target_id)

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


func _all_checks_pass() -> bool:
	var remote_ok := (not require_remote) or _remote_travel >= MOVE_EPSILON
	var respawn_ok := (not require_respawn) or _respawn_seen
	var self_ok := _self_hp > 0 and _self_max_hp == Protocol.PLAYER_MAX_HP
	if multiplayer_only:
		return _login_ok and _list_received and _enter_world \
			and _moved >= MOVE_EPSILON and _ticks > 0 and remote_ok and self_ok
	return _login_ok and _list_received and _enter_world \
		and _moved >= MOVE_EPSILON and _combat_seen and _kill_seen \
		and remote_ok and respawn_ok and self_ok


# --- reporting --------------------------------------------------------------

func _check(name: String, ok: bool, detail: String = "") -> void:
	var line := "[bot] CHECK %s=%s" % [name, "OK" if ok else "FAIL"]
	if not detail.is_empty():
		line += " (%s)" % detail
	print(line)


func _check_optional(name: String, ok: bool, detail: String = "") -> void:
	var line := "[bot] CHECK %s=%s" % [name, "OK" if ok else "N/A"]
	if not detail.is_empty():
		line += " (%s)" % detail
	print(line)


func _report() -> void:
	_check("login", _login_ok)
	_check("character_list", _list_received)
	_check("enter_world", _enter_world, "entity=%d" % _self_id)
	_check("local_hp", _self_hp > 0 and _self_max_hp == Protocol.PLAYER_MAX_HP, "%d/%d" % [_self_hp, _self_max_hp])
	_check_optional("local_name", not _self_name.is_empty(), _self_name)
	_check("movement", _moved >= MOVE_EPSILON, "moved %.2fm" % _moved)
	_check("world_state_ticks", _ticks > 0, "%d ticks" % _ticks)
	if multiplayer_only:
		_check_optional("combat_event", _combat_seen, "dealt %d damage" % _damage_dealt)
		_check_optional("mob_kill", _kill_seen)
	else:
		_check("combat_event", _combat_seen, "dealt %d damage" % _damage_dealt)
		_check("mob_kill", _kill_seen)
	if require_respawn:
		_check("mob_respawn", _respawn_seen)
	else:
		_check_optional("mob_respawn", _respawn_seen)
	_check_optional("took_damage", _damage_taken > 0, "%d damage taken" % _damage_taken)
	if require_remote:
		_check("remote_player_moved", _remote_travel >= MOVE_EPSILON, "%.2fm" % _remote_travel)
	else:
		_check_optional("remote_player_moved", _remote_travel >= MOVE_EPSILON, "%.2fm" % _remote_travel)


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
