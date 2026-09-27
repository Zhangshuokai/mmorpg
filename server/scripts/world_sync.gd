class_name WorldSync
extends RefCounted
## Replication side of the world: spawn/despawn messages, damage/death/respawn
## notifications and the 20Hz state broadcast. Owned by WB0; WB4 replaces the
## broadcast body with the AoI + priority scheduler inside `broadcast()`.
##
## Only this class talks to `Net`/`multiplayer`; the state containers stay in
## WorldState.

## A Node in the scene tree, used only to reach `multiplayer` (a RefCounted has
## no NodePath). Set by the facade.
var host: Node
var state: WorldState


func setup(p_host: Node, p_state: WorldState) -> void:
	host = p_host
	state = p_state


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

	# The newcomer is told about itself and about everything already present.
	Net.s2c_enter_world.rpc_id(peer_id, peer_id, player.pos, player.hp)
	for other: EntityState in state.entities.values():
		Net.s2c_spawn_entity.rpc_id(peer_id, other.to_spawn_dict())
	# Everybody else is told about the newcomer.
	for peer in state.player_peers():
		if peer != peer_id:
			Net.s2c_spawn_entity.rpc_id(peer, player.to_spawn_dict())
	print("[world] %s (peer %d) entered the world at %s" % [
		player.display_name, peer_id, player.pos])


func remove_player(peer_id: int, announce: bool = true) -> void:
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
	Net.s2c_spawn_entity.rpc(entity.to_spawn_dict())


func respawn_mob(entity: EntityState) -> void:
	entity.alive = true
	entity.hp = Protocol.MOB_MAX_HP
	entity.target_id = 0
	state.respawn_at.erase(entity.id)
	Net.s2c_spawn_entity.rpc(entity.to_spawn_dict())


# --- broadcast --------------------------------------------------------------

func flush_despawns() -> void:
	if state.pending_despawn.is_empty():
		return
	if host.multiplayer.multiplayer_peer == null:
		state.pending_despawn.clear()
		return
	var peers := state.player_peers()
	for id: int in state.pending_despawn:
		# A player removed and re-added before this tick (a repeat select) is live
		# again and its spawn already went out, so a despawn now would erase it on
		# every client. Never despawn a live entity, and never send a peer its own
		# despawn.
		if state.entities.has(id):
			continue
		for peer: int in peers:
			if peer != id:
				Net.s2c_despawn_entity.rpc_id(peer, id)
	state.pending_despawn.clear()


## WB4 replaces this full-broadcast body with an AoI-filtered, budgeted send.
func broadcast(tick: int) -> void:
	if host.multiplayer.multiplayer_peer == null:
		return
	if host.multiplayer.get_peers().is_empty():
		return
	var snapshot: Array = []
	for id: int in state.entities.keys():
		var e: EntityState = state.entities[id]
		snapshot.append(e.to_net_dict())
	Net.s2c_world_state.rpc(tick, snapshot)
