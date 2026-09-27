class_name ZoneInstance
extends RefCounted
## WB5 (S-N-7) third zone layer: a private instance (dungeon) of a zone.
##
## An instance is isolated exactly like a channel, but ephemeral and membership
## scoped: it is addressed by the shard key
## Vector3i(zone_id, Protocol.CHANNEL_DEFAULT, instance_id), so the same
## zone-aware replication and old-shard cleanup that separates channels also
## keeps an instance private.
##
## Lifecycle (owned by ZoneService):
##   allocate -> members join -> members leave -> empty -> released.
## Ids come from the reserved Protocol.INSTANCE_ID_BASE range [base, base +
## ZONE_MAX_INSTANCES), which sits above both the random peer ids and the mob
## range, so instance shards can never collide with a player or mob id.
##
## There is deliberately no client entry point here: the frozen contract's
## c2s_change_zone carries no instance argument, so instance entry belongs to the
## later group/dungeon system (S-G-13). ZoneService exposes the server-side API.

## Instance id in the reserved range (0 = invalid/unallocated).
var instance_id: int = 0
## Logical zone this instance copies.
var zone_id: int = Protocol.ZONE_DEFAULT
## Creator/owner peer that keeps the instance alive while listed.
var owner_peer: int = 0
## peer_id -> true for every player currently inside the instance.
var members: Dictionary = {}
## Unix msec; informational (logging / future idle reaping).
var created_at_msec: int = 0


## Allocates an instance in `zone_id` for `owner_peer`. Returns null when the id
## space is exhausted. `existing_ids` maps instance_id -> ZoneInstance for the
## active instances so allocation never reuses a live id.
static func create(p_zone_id: int, p_owner_peer: int, existing_ids: Dictionary) -> ZoneInstance:
	var id := _allocate_id(existing_ids)
	if id == 0:
		return null
	var inst := ZoneInstance.new()
	inst.instance_id = id
	inst.zone_id = p_zone_id
	inst.owner_peer = p_owner_peer
	inst.created_at_msec = Time.get_ticks_msec()
	return inst


## Lowest free id in the reserved range, or 0 when the range is full.
static func _allocate_id(existing_ids: Dictionary) -> int:
	for i in Protocol.ZONE_MAX_INSTANCES:
		var candidate := Protocol.INSTANCE_ID_BASE + i
		if not existing_ids.has(candidate):
			return candidate
	return 0


## Shard key players inside this instance are tagged with.
func shard() -> Vector3i:
	return Vector3i(zone_id, Protocol.CHANNEL_DEFAULT, instance_id)


func add_member(peer_id: int) -> void:
	members[peer_id] = true


func remove_member(peer_id: int) -> void:
	members.erase(peer_id)


func has_member(peer_id: int) -> bool:
	return members.has(peer_id)


func member_count() -> int:
	return members.size()


## An owner-less or member-less instance is disposable.
func is_empty() -> bool:
	return members.is_empty()


## Drops the membership table so a released instance can never be re-entered.
func release() -> void:
	members.clear()
