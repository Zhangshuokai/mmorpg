class_name ZoneService
extends Node
## WB5 (S-N-7) zone routing: the three-layer zone / channel / instance model.
##
## A *zone* is a logical map (Protocol.ZoneId; its layout will come from
## shared/data/tables/zones.json). A *channel* is a public shard of that map and
## an *instance* is a private, membership-scoped shard; both are addressed by the
## same shard key Vector3i(zone, channel, instance) held in WorldState. Entities
## only ever see entities with the same shard key, so players in different
## zones/channels/instances are mutually invisible.
##
## The service owns the *policy* (which shard, instance lifecycle, persistence of
## characters.zone); the replication transition itself lives in WorldSync
## (move_player_shard) next to the rest of the spawn/despawn logic.
##
## Switching zones never reconnects: the same peer id and the same EntityState
## are retagged and re-based, the client is told via s2c_zone_changed and clears
## the old shard, and s2c_spawn_entity repopulates the new one.
##
## Wiring (main.gd): create the node with `world`/`persistence`/`router` set and
## register `on_change_zone` for "change_zone_requested".

## Logical zone id -> persisted characters.zone key.
const ZONE_KEYS := {
	Protocol.ZONE_DEFAULT: Protocol.ZONE_KEY_WORLD,
}

var world: WorldService
var persistence: PersistenceService
var router: IntentRouter

## instance_id -> ZoneInstance for every live instance shard.
var _instances: Dictionary = {}


func _ready() -> void:
	# Drop membership when a peer leaves so an instance can be reaped even if the
	# disconnect races a zone change.
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


# --- zone / channel switching -----------------------------------------------

## Handler for "change_zone_requested" (registered by main.gd). `sender` is the
## authenticated peer id supplied by Net, never client data.
func on_change_zone(sender: int, zone_id: int, channel_id: int) -> void:
	if not _known_zone(zone_id):
		push_warning("[zones] peer %d requested unknown zone %d" % [sender, zone_id])
		return
	if world == null or not world.entities.has(sender):
		return
	var entity: EntityState = world.entities[sender]
	if entity.kind != Protocol.EntityKind.PLAYER:
		return
	var target := Vector3i(zone_id, channel_id, 0)
	if world.shard_for(sender) == target:
		return
	_leave_instance_of(sender)
	_enter_shard(sender, target, zone_id, channel_id)


## Moves one player to `shard` and mirrors it to the client. Reliable ordering is
## load-bearing: s2c_zone_changed must reach the client *before* the new shard's
## spawns, because the client clears the old shard while handling it.
func _enter_shard(sender: int, shard: Vector3i, zone_id: int, channel_id: int) -> bool:
	if world == null or not world.entities.has(sender):
		return false
	var spawn := spawn_point_for(shard)
	Net.s2c_zone_changed.rpc_id(sender, zone_id, channel_id, spawn)
	if not world.move_player_shard(sender, shard, spawn):
		return false
	var sheet: CharacterSheet = world.sessions.get(sender)
	if sheet != null:
		sheet.zone = zone_key(zone_id)
	print("[zones] peer %d -> zone %d channel %d shard %s at %s" % [
		sender, zone_id, channel_id, str(shard), spawn])
	return true


# --- instances --------------------------------------------------------------

## Opens a private instance shard in `zone_id` and optionally moves `owner_peer`
## into it. Returns the instance id, or 0 when the zone is unknown / the range is
## full. Server-side entry point for the later group/dungeon system (S-G-13): the
## frozen c2s_change_zone carries no instance argument.
func open_instance(zone_id: int, owner_peer: int = 0) -> int:
	if not _known_zone(zone_id):
		return 0
	if _instances.size() >= Protocol.ZONE_MAX_INSTANCES:
		push_warning("[zones] instance limit (%d) reached" % Protocol.ZONE_MAX_INSTANCES)
		return 0
	var inst := ZoneInstance.create(zone_id, owner_peer, _instances)
	if inst == null:
		return 0
	_instances[inst.instance_id] = inst
	if owner_peer != 0:
		inst.add_member(owner_peer)
		_enter_shard(owner_peer, inst.shard(), zone_id, Protocol.CHANNEL_DEFAULT)
	print("[zones] opened instance %d in zone %d (owner %d)" % [
		inst.instance_id, zone_id, owner_peer])
	return inst.instance_id


func join_instance(peer_id: int, instance_id: int) -> bool:
	var inst: ZoneInstance = _instances.get(instance_id)
	if inst == null:
		return false
	inst.add_member(peer_id)
	_enter_shard(peer_id, inst.shard(), inst.zone_id, Protocol.CHANNEL_DEFAULT)
	return true


func leave_instance(peer_id: int) -> void:
	var inst := _instance_of(peer_id)
	if inst == null:
		return
	inst.remove_member(peer_id)
	_reap_if_empty(inst)


func instance_count() -> int:
	return _instances.size()


func instance_of(peer_id: int) -> int:
	var inst := _instance_of(peer_id)
	return 0 if inst == null else inst.instance_id


func _instance_of(peer_id: int) -> ZoneInstance:
	for id: int in _instances.keys():
		var inst: ZoneInstance = _instances[id]
		if inst.has_member(peer_id):
			return inst
	return null


func _leave_instance_of(peer_id: int) -> void:
	var inst := _instance_of(peer_id)
	if inst == null:
		return
	inst.remove_member(peer_id)
	_reap_if_empty(inst)


func _reap_if_empty(inst: ZoneInstance) -> void:
	if not inst.is_empty():
		return
	_instances.erase(inst.instance_id)
	inst.release()


func _on_peer_disconnected(peer_id: int) -> void:
	_leave_instance_of(peer_id)


## Defensive sweep: an instance that ended up with no members is released.
func _physics_process(_delta: float) -> void:
	for id: int in _instances.keys():
		_reap_if_empty(_instances[id])


# --- zone data --------------------------------------------------------------

## Spawn point for a shard. The single map of the MVP shares one spawn; per-zone
## layouts (zones.json) arrive with more content.
func spawn_point_for(_shard: Vector3i) -> Vector3:
	return Protocol.SPAWN_POINT


func _known_zone(zone_id: int) -> bool:
	return ZONE_KEYS.has(zone_id)


func zone_key(zone_id: int) -> String:
	return ZONE_KEYS.get(zone_id, Protocol.ZONE_KEY_WORLD)
