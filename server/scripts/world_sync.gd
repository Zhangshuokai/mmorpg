class_name WorldSync
extends RefCounted
## Replication side of the world: spawn/despawn messages, damage/death/respawn
## notifications and the 20Hz state broadcast.
##
## WB4 replaced the former full-broadcast body: every peer now receives only the
## entities inside its AoI (uniform SpatialGrid + Protocol.AOI_RADIUS), the local
## player is always replicated, an entity that recently left the radius stays
## until a hysteresis margin, and the per-tick state packet is capped by
## BroadcastScheduler at Protocol.PACKET_BUDGET_BYTES.
##
## Positions are read straight from the authoritative EntityState that
## WorldMovement/WorldMobs already produced; this class never integrates
## movement.
##
## Only this class talks to `Net`/`multiplayer`; the state containers stay in
## WorldState.

## A Node in the scene tree, used only to reach `multiplayer` (a RefCounted has
## no NodePath). Set by the facade.
var host: Node
var state: WorldState

var _grid := SpatialGrid.new()
var _scheduler := BroadcastScheduler.new()

## peer_id -> { entity_id -> true }: the entities currently spawned on that
## client. Drives spawn/despawn transitions and the broadcast candidate set.
var _visible: Dictionary = {}

## AoI enter radius; the frozen contract's value.
const AOI_RADIUS := Protocol.AOI_RADIUS
## AoI leave radius: already-visible entities survive to here, which kills
## spawn/despawn thrash when a player walks the boundary.
const AOI_KEEP_RADIUS := Protocol.AOI_RADIUS + Protocol.AOI_GRID_CELL
## Fixed per-packet envelope cost charged before entity bytes (ENet/RPC framing).
const PACKET_ENVELOPE_BYTES := 32

## Opt-in capacity instrumentation (`--aoi-stats`): reports, once a second, the
## largest per-peer payload and visible set seen in that window. Off by default.
var stats_enabled := false
var _stat_max_payload := 0
var _stat_max_visible := 0
var _stat_peers := 0


func setup(p_host: Node, p_state: WorldState) -> void:
	host = p_host
	state = p_state
	stats_enabled = OS.get_cmdline_user_args().has("--aoi-stats")


# --- players ----------------------------------------------------------------

func add_player(peer_id: int, sheet: CharacterSheet) -> void:
	remove_player(peer_id, true)
	var spawn := sheet.pos
	spawn.y = Protocol.SPAWN_POINT.y
	var player := EntityState.create(
		peer_id, Protocol.EntityKind.PLAYER, sheet.char_name, spawn, Protocol.PLAYER_MAX_HP)
	player.hp = clampi(sheet.hp, 1, Protocol.PLAYER_MAX_HP)
	player.class_id = sheet.class_id
	player.yaw = 0.0
	state.entities[peer_id] = player
	state.sessions[peer_id] = sheet
	state.inputs[peer_id] = {"seq": -1, "move": Vector2.ZERO, "yaw": 0.0, "buttons": 0}

	_grid.rebuild(state.entities)

	# The newcomer is told about itself and about everything already in its AoI.
	Net.s2c_enter_world.rpc_id(peer_id, peer_id, player.pos, player.hp)
	var visible: Dictionary = {}
	for id: int in _grid.query_circle(player.pos, AOI_RADIUS):
		Net.s2c_spawn_entity.rpc_id(peer_id, state.entities[id].to_spawn_dict())
		visible[id] = true
	_visible[peer_id] = visible

	# Everybody already close enough is told about the newcomer.
	for peer: int in state.player_peers():
		if peer == peer_id:
			continue
		var other: EntityState = state.entities[peer]
		if _horizontal_distance(other.pos, player.pos) <= AOI_RADIUS:
			if not _visible.has(peer):
				_visible[peer] = {}
			_visible[peer][peer_id] = true
			Net.s2c_spawn_entity.rpc_id(peer, player.to_spawn_dict())
	print("[world] %s (peer %d) entered the world at %s" % [
		player.display_name, peer_id, player.pos])


func remove_player(peer_id: int, announce: bool = true) -> void:
	_visible.erase(peer_id)
	_scheduler.drop_peer(peer_id)
	if not state.entities.has(peer_id):
		return
	state.remove_entity(peer_id, announce)


# --- damage / death / respawn ----------------------------------------------

## Applies authoritative damage. `amount` is decided by the server only.
func apply_damage(target_id: int, amount: int, source_id: int = 0) -> int:
	var target: EntityState = state.entities.get(target_id)
	if target == null or not target.alive:
		return -1
	target.hp = max(0, target.hp - amount)
	if target.hp == 0:
		target.alive = false
		_on_death(target)
	Net.s2c_combat_event.rpc(source_id, target_id, amount, target.hp)
	Net.s2c_hp_update.rpc(target_id, target.hp)
	return target.hp


func _on_death(entity: EntityState) -> void:
	if entity.kind == Protocol.EntityKind.MOB:
		state.respawn_at[entity.id] = Time.get_ticks_msec() + int(Protocol.MOB_RESPAWN_SEC * 1000.0)
		print("[world] mob %d died; respawn in %.0fs" % [entity.id, Protocol.MOB_RESPAWN_SEC])
	else:
		state.respawn_at[entity.id] = Time.get_ticks_msec() + int(Protocol.PLAYER_RESPAWN_SEC * 1000.0)
		var sheet: CharacterSheet = state.sessions.get(entity.id)
		if sheet != null:
			sheet.hp = 0
			sheet.pos = entity.pos
		print("[world] player %d died; respawn in %.0fs" % [entity.id, Protocol.PLAYER_RESPAWN_SEC])


func respawn_player(entity: EntityState) -> void:
	entity.alive = true
	entity.hp = Protocol.PLAYER_MAX_HP
	entity.pos = Protocol.SPAWN_POINT
	entity.target_id = 0
	state.respawn_at.erase(entity.id)
	Net.s2c_hp_update.rpc_id(entity.id, entity.hp)
	_send_spawn_to_viewers(entity)


func respawn_mob(entity: EntityState) -> void:
	entity.alive = true
	entity.hp = Protocol.MOB_MAX_HP
	entity.target_id = 0
	state.respawn_at.erase(entity.id)
	_send_spawn_to_viewers(entity)


# --- broadcast --------------------------------------------------------------

func flush_despawns() -> void:
	if state.pending_despawn.is_empty():
		return
	if host.multiplayer.multiplayer_peer == null:
		state.pending_despawn.clear()
		return
	for id: int in state.pending_despawn:
		# A player removed and re-added before this tick (a repeat select) is live
		# again and its spawn already went out, so a despawn now would erase it on
		# every client. Never despawn a live entity, and never send a peer its own
		# despawn (a peer's own id is erased from _visible on removal, so it can no
		# longer be selected below).
		if state.entities.has(id):
			continue
		for peer: int in _visible.keys():
			var visible: Dictionary = _visible[peer]
			if visible.has(id):
				Net.s2c_despawn_entity.rpc_id(peer, id)
				visible.erase(id)
				_scheduler.forget(peer, id)
	state.pending_despawn.clear()


## One AoI-filtered, budgeted state packet per player. Entities skipped by the
## byte budget keep their accumulated priority for the next tick.
func broadcast(tick: int) -> void:
	if host.multiplayer.multiplayer_peer == null:
		return
	if host.multiplayer.get_peers().is_empty():
		return
	_grid.rebuild(state.entities)
	var envelope := PACKET_ENVELOPE_BYTES + var_to_bytes([tick, []]).size()
	var peers := state.player_peers()
	_stat_peers = peers.size()
	for peer: int in peers:
		if not state.entities.has(peer):
			continue
		_update_visibility(peer)
		_send_state(peer, tick, envelope)
	if stats_enabled and tick % Protocol.TICK_HZ == 0 and _stat_peers > 0:
		print("[aoi] tick=%d peers=%d max_visible=%d max_payload_bytes=%d budget=%d" % [
			tick, _stat_peers, _stat_max_visible, _stat_max_payload,
			Protocol.PACKET_BUDGET_BYTES])
		_stat_max_payload = 0
		_stat_max_visible = 0


## Applies AoI enter/leave transitions for one peer and updates its visible set.
func _update_visibility(peer_id: int) -> void:
	var viewer: EntityState = state.entities[peer_id]
	var visible: Dictionary = _visible.get(peer_id, {})
	visible[peer_id] = true

	var in_range: Dictionary = {}
	for id: int in _grid.query_circle(viewer.pos, AOI_RADIUS):
		if state.entities.has(id):
			in_range[id] = true

	# Leaving the AoI (past the keep hysteresis) -> despawn.
	for id: int in visible.keys():
		if id == peer_id or in_range.has(id):
			continue
		if _within_keep(viewer.pos, id):
			continue
		if state.entities.has(id):
			Net.s2c_despawn_entity.rpc_id(peer_id, id)
		visible.erase(id)
		_scheduler.forget(peer_id, id)

	# Entering the AoI -> one full spawn so the client can build the view.
	for id: int in in_range.keys():
		if visible.has(id):
			continue
		Net.s2c_spawn_entity.rpc_id(peer_id, state.entities[id].to_spawn_dict())
		visible[id] = true

	_visible[peer_id] = visible


## Serializes the peer's visible set, hands it to the scheduler and sends the
## selected subset. The local player is mandatory, so a peer always gets its own
## authoritative position.
func _send_state(peer_id: int, tick: int, envelope: int) -> void:
	var viewer: EntityState = state.entities[peer_id]
	var visible: Dictionary = _visible.get(peer_id, {})
	visible[peer_id] = true

	var items: Array = []
	for id: int in visible.keys():
		var e: EntityState = state.entities.get(id)
		if e == null:
			continue
		var payload: Dictionary = e.to_net_dict()
		items.append({
			"id": id,
			"size": var_to_bytes(payload).size(),
			"weight": _priority_weight(viewer.pos, e),
			"payload": payload,
		})

	var selected := _scheduler.select(peer_id, items, envelope, [peer_id])
	var chosen: Dictionary = {}
	for id: int in selected:
		chosen[id] = true
	var snapshot: Array = []
	for item: Dictionary in items:
		if chosen.has(int(item["id"])):
			snapshot.append(item["payload"])
	snapshot.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"]))
	if stats_enabled:
		_stat_max_payload = maxi(_stat_max_payload, var_to_bytes([tick, snapshot]).size())
		_stat_max_visible = maxi(_stat_max_visible, visible.size())
	Net.s2c_world_state.rpc_id(peer_id, tick, snapshot)


func _send_spawn_to_viewers(entity: EntityState) -> void:
	for peer: int in state.player_peers():
		var visible: Dictionary = _visible.get(peer, {})
		if visible.has(entity.id):
			Net.s2c_spawn_entity.rpc_id(peer, entity.to_spawn_dict())


## Closer entities outrank distant ones; skipped entities win over time through
## the accumulator regardless of weight.
func _priority_weight(viewer_pos: Vector3, e: EntityState) -> float:
	var d := _horizontal_distance(viewer_pos, e.pos)
	var closeness := clampf(1.0 - d / AOI_RADIUS, 0.0, 1.0)
	return Protocol.BROADCAST_PRIORITY_BASE * (1.0 + closeness)


func _within_keep(viewer_pos: Vector3, id: int) -> bool:
	var e: EntityState = state.entities.get(id)
	if e == null:
		return false
	return _horizontal_distance(viewer_pos, e.pos) <= AOI_KEEP_RADIUS


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return sqrt(dx * dx + dz * dz)
