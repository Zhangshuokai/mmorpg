class_name BotCheckZones
extends BotCheck
## WB5 (S-N-7) zone/channel assertions. Inert unless the client is started with
## `--zone-check <channel>` (1..ZONE_MAX_CHANNELS-1), which the two-bot gate uses:
##
##   bot A: --bot-multiplayer --bot-user zone_a --zone-check 1
##   bot B: --bot-multiplayer --bot-user zone_b --zone-check 2
##
## Both enter the world in the default channel, are visible to each other, then
## each moves to its own channel. The checks prove that (a) they saw each other
## in the shared channel, (b) the switch needs no reconnect (same entity id,
## still in world) and is acknowledged, (c) the old channel's entities are
## despawned for the mover, and (d) once in separate channels neither sees the
## other.
##
## With no `--zone-check` the module returns no checks, so every existing bot
## run and its CHECK/RESULT output are untouched.

const ORDER := 300
## Both bots must stay in the shared channel long enough to record each other's
## movement before either leaves; otherwise the first to switch despawns itself
## from the other's view and can starve the WB6 remote-movement assertion.
const SETTLE_MS := 1500
## -2 = not parsed yet, -1 = disabled, >=0 = target channel.
var _channel := -2

var _connected := false
var _requested := false
var _saw_remote := false
var _visible_since_msec := -1
var _zone_changed_seen := false
var _changed_channel := -1
var _changed_zone := -1
var _changed_spawn := Vector3.ZERO
var _self_id_at_switch := 0
var _remote_ids: Array = []


func evaluate() -> Array:
	_parse()
	if _channel < 0:
		return []
	_connect()
	if not bot._enter_world:
		return []

	var players: Dictionary = bot._players
	if not _saw_remote and not players.is_empty():
		_saw_remote = true
		_visible_since_msec = Time.get_ticks_msec()
		# Snapshot the peers seen in the shared channel *now*: the other bot may
		# switch (and despawn itself) before this one reaches its own settle
		# window, and the cleanup assertion still has to cover those ids.
		_remote_ids = players.keys().duplicate()

	# Trigger the switch once, after mutual visibility has settled *and* the
	# remote actually moved (so leaving the channel cannot starve the movement
	# check), while the connection can still send.
	var settled: bool = _visible_since_msec >= 0 \
		and Time.get_ticks_msec() - _visible_since_msec >= SETTLE_MS
	if settled and not _requested and float(bot._remote_travel) >= MOVE_EPSILON \
			and bot.net != null and bot.net.can_send():
		_self_id_at_switch = bot._self_id
		bot.net.change_zone(Protocol.ZONE_DEFAULT, _channel)
		_requested = true

	var channels_ok: bool = _zone_changed_seen and _changed_channel == _channel
	var same_entity: bool = _requested and bool(bot._enter_world) and bot._self_id == _self_id_at_switch
	var cleaned: bool = _requested and not _remote_ids.is_empty() and _all_gone(_remote_ids)
	var isolated: bool = _requested and players.is_empty()

	return [
		{
			"order": ORDER + 10, "name": "zone_remote_visible_before_switch", "required": true,
			"ok": _saw_remote, "detail": "%d remote in shared channel" % _remote_ids.size(),
		},
		{
			"order": ORDER + 20, "name": "zone_switch_acknowledged", "required": true,
			"ok": channels_ok,
			"detail": "zone=%d channel=%d spawn=%s" % [_changed_zone, _changed_channel, str(_changed_spawn)],
		},
		{
			"order": ORDER + 30, "name": "zone_switch_no_reconnect", "required": true,
			"ok": same_entity, "detail": "entity %d still in world" % bot._self_id,
		},
		{
			"order": ORDER + 40, "name": "zone_old_entities_cleaned", "required": true,
			"ok": cleaned, "detail": "despawned %d old-channel peers" % _remote_ids.size(),
		},
		{
			"order": ORDER + 50, "name": "zone_isolated_after_switch", "required": true,
			"ok": isolated, "detail": "%d entities remain in channel %d" % [players.size(), _channel],
		},
	]


func _parse() -> void:
	if _channel != -2:
		return
	_channel = -1
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var arg: String = args[i]
		if arg == "--zone-check" and i + 1 < args.size():
			i += 1
			_channel = int(args[i])
		elif arg.begins_with("--zone-check="):
			_channel = int(arg.substr("--zone-check=".length()))
		i += 1
	# A switch to the default channel is a no-op on the server, so only accept a
	# real target channel; anything out of range disables the module.
	if _channel <= 0 or _channel >= Protocol.ZONE_MAX_CHANNELS:
		_channel = -1


func _connect() -> void:
	if _connected:
		return
	_connected = true
	if not Net.zone_changed.is_connected(_on_zone_changed):
		Net.zone_changed.connect(_on_zone_changed)


func _on_zone_changed(zone_id: int, channel_id: int, spawn: Vector3) -> void:
	_zone_changed_seen = true
	_changed_zone = zone_id
	_changed_channel = channel_id
	_changed_spawn = spawn


func _all_gone(ids: Array) -> bool:
	var players: Dictionary = bot._players
	for id: int in ids:
		if players.has(id):
			return false
	return true
