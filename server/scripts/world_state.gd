class_name WorldState
extends RefCounted
## Authoritative per-tick world state containers (owned by WB0; WB5 will later
## group them per zone).
##
## This class holds data and the input-validation guard only. No RPCs, no
## rendering, no AI: the facade (world.gd) and the subsystems (WorldMovement,
## WorldMobs, WorldSync) operate on these dictionaries.

## id (peer_id for players, Protocol.MOB_ID_BASE+i for mobs) -> EntityState.
var entities: Dictionary = {}
## peer_id -> {"seq": int, "move": Vector2, "yaw": float, "buttons": int}.
var inputs: Dictionary = {}
## peer_id -> CharacterSheet, only for players currently in the world.
var sessions: Dictionary = {}
## peer_id -> float seconds of ability cooldown remaining.
var cooldowns: Dictionary = {}
## id -> unix msec when the entity respawns.
var respawn_at: Dictionary = {}
## mob id -> unix msec of the next melee swing.
var mob_next_attack: Dictionary = {}
## Entity ids whose despawn still has to be broadcast, flushed on the next tick.
##
## Sending them inline from the peer_disconnected callback races ENet's teardown:
## a peer that lost its channels in the same frame makes every send fail with
## "Unable to send packet on channel 0, max channels: 0". The deferral to the
## next tick is load-bearing - WorldSync.flush_despawns preserves it.
var pending_despawn: Array[int] = []


func decay_cooldowns(delta: float) -> void:
	for id: int in cooldowns.keys():
		cooldowns[id] = max(0.0, float(cooldowns[id]) - delta)


## Validates and stores the latest client input for a player.
##
## Rejects non-finite input. A crafted INF/NaN would survive a length guard,
## make normalized()/rotated() produce NaN and permanently poison the
## authoritative position (NaN comparisons are always false, so neither the
## bounds clamp nor the obstacle resolve can recover), poisoning the broadcast
## for every client and the value persisted by save.
func set_input(peer_id: int, seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	if not entities.has(peer_id):
		return
	if not Movement.is_input_finite(move, yaw):
		push_warning("[world] non-finite input from peer %d ignored" % peer_id)
		return
	var current: Dictionary = inputs.get(peer_id, {"seq": -1})
	# Unreliable ordered transport already drops stale packets; the seq guard is
	# a cheap second line of defence.
	if seq >= int(current.get("seq", -1)):
		inputs[peer_id] = {"seq": seq, "move": move, "yaw": yaw, "buttons": buttons}


## Drops every container entry for `peer_id`. `announce` queues a despawn for the
## next tick (see pending_despawn).
func remove_entity(peer_id: int, announce: bool) -> void:
	entities.erase(peer_id)
	inputs.erase(peer_id)
	sessions.erase(peer_id)
	cooldowns.erase(peer_id)
	respawn_at.erase(peer_id)
	if announce:
		pending_despawn.append(peer_id)


func player_peers() -> Array:
	var out: Array = []
	for id: int in entities.keys():
		var e: EntityState = entities[id]
		if e.kind == Protocol.EntityKind.PLAYER:
			out.append(id)
	return out
