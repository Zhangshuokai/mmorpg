extends RefCounted
## WB5 (S-N-7) unit module: zone grouping in WorldState and the instance
## lifecycle in ZoneInstance. Deterministic and network-free; discovered
## automatically by tests/run_tests.gd.

func cases() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_test_default_shard(out)
	_test_shard_isolation(out)
	_test_input_guard_preserved(out)
	_test_player_peers_semantics(out)
	_test_instance_lifecycle(out)
	_test_reserved_ranges(out)
	return out


func _add(out: Array[Dictionary], name: String, ok: bool, detail: String = "") -> void:
	out.append({"name": name, "ok": ok, "detail": detail})


func _default_shard() -> Vector3i:
	return Vector3i(Protocol.ZONE_DEFAULT, Protocol.CHANNEL_DEFAULT, 0)


func _player(id: int, name: String) -> EntityState:
	return EntityState.create(id, Protocol.EntityKind.PLAYER, name, Vector3.ZERO, Protocol.PLAYER_MAX_HP)


func _test_default_shard(out: Array[Dictionary]) -> void:
	var state := WorldState.new()
	var p := _player(1, "A")
	state.entities[1] = p
	_add(out, "default_shard_is_world_channel0", state.shard_for(1) == _default_shard(), str(state.shard_for(1)))
	_add(out, "untagged_entities_share_shard", state.same_shard(1, 999), "unknown id also defaults")


func _test_shard_isolation(out: Array[Dictionary]) -> void:
	var state := WorldState.new()
	state.entities[1] = _player(1, "A")
	state.entities[2] = _player(2, "B")
	var mob := EntityState.create(Protocol.MOB_ID_BASE, Protocol.EntityKind.MOB, "Wolf", Vector3.ZERO, Protocol.MOB_MAX_HP)
	state.entities[mob.id] = mob
	_add(out, "same_shard_before_move", state.same_shard(1, 2), "both default")

	var channel_one := Vector3i(Protocol.ZONE_DEFAULT, 1, 0)
	state.set_shard(2, channel_one)
	_add(out, "set_shard_isolates_players", not state.same_shard(1, 2), "%s vs %s" % [state.shard_for(1), state.shard_for(2)])
	_add(out, "peers_in_shard_filters", state.peers_in_shard(_default_shard()) == [1], str(state.peers_in_shard(_default_shard())))
	_add(out, "mobs_stay_in_default_shard", state.same_shard(mob.id, 1), str(state.shard_for(mob.id)))

	var inst_shard := Vector3i(Protocol.ZONE_DEFAULT, Protocol.CHANNEL_DEFAULT, Protocol.INSTANCE_ID_BASE)
	state.set_shard(1, inst_shard)
	_add(out, "instance_shard_differs_from_channel", state.shard_for(1) != channel_one and not state.same_shard(1, 2), str(state.shard_for(1)))

	var shards: Array = state.active_shards()
	_add(out, "active_shards_lists_both", shards.has(channel_one) and shards.has(inst_shard), str(shards))

	state.remove_entity(2, false)
	_add(out, "remove_entity_clears_shard",
		not state.entities.has(2) and not state.shard_of.has(2), "shard_of=%s" % str(state.shard_of))


func _test_input_guard_preserved(out: Array[Dictionary]) -> void:
	var state := WorldState.new()
	state.entities[5] = _player(5, "C")
	state.set_input(5, 0, Vector2(0.0, 1.0), INF, 0)
	_add(out, "set_input_drops_inf_yaw", state.inputs.is_empty(), "inputs=%s" % str(state.inputs))
	state.set_input(5, 1, Vector2(0.0, 1.0), 0.25, 0)
	_add(out, "set_input_accepts_finite", state.inputs.has(5), "inputs=%s" % str(state.inputs))


func _test_player_peers_semantics(out: Array[Dictionary]) -> void:
	# player_peers() must keep returning every player regardless of shard: the
	# broadcast loop iterates it and filters per peer, and movement_test depends
	# on the all-players meaning.
	var state := WorldState.new()
	state.entities[1] = _player(1, "A")
	state.entities[2] = _player(2, "B")
	state.set_shard(2, Vector3i(Protocol.ZONE_DEFAULT, 3, 0))
	var peers: Array = state.player_peers()
	_add(out, "player_peers_returns_all_shards", peers.size() == 2 and peers.has(1) and peers.has(2), str(peers))


func _test_instance_lifecycle(out: Array[Dictionary]) -> void:
	var live: Dictionary = {}
	var a := ZoneInstance.create(Protocol.ZONE_DEFAULT, 7, live)
	_add(out, "instance_id_in_reserved_range",
		a != null and a.instance_id >= Protocol.INSTANCE_ID_BASE \
			and a.instance_id < Protocol.INSTANCE_ID_BASE + Protocol.ZONE_MAX_INSTANCES,
		"id=%d" % (0 if a == null else a.instance_id))
	if a == null:
		return
	live[a.instance_id] = a
	var b := ZoneInstance.create(Protocol.ZONE_DEFAULT, 8, live)
	_add(out, "instance_ids_unique", b != null and b.instance_id != a.instance_id,
		"a=%d b=%d" % [a.instance_id, 0 if b == null else b.instance_id])
	_add(out, "instance_shard_uses_reserved_id",
		a.shard() == Vector3i(Protocol.ZONE_DEFAULT, Protocol.CHANNEL_DEFAULT, a.instance_id),
		str(a.shard()))
	_add(out, "instance_shard_differs_from_public_channel",
		a.shard() != Vector3i(Protocol.ZONE_DEFAULT, Protocol.CHANNEL_DEFAULT, 0), str(a.shard()))

	a.add_member(7)
	_add(out, "instance_membership_add", a.has_member(7) and a.member_count() == 1, "%d members" % a.member_count())
	_add(out, "instance_not_empty_with_member", not a.is_empty(), "")
	a.remove_member(7)
	_add(out, "instance_empty_after_leave", a.is_empty() and not a.has_member(7), "")
	a.add_member(7)
	a.release()
	_add(out, "instance_release_clears_members", a.is_empty(), "%d members" % a.member_count())

	var full: Dictionary = {}
	for i in Protocol.ZONE_MAX_INSTANCES:
		full[Protocol.INSTANCE_ID_BASE + i] = true
	_add(out, "instance_range_capped",
		ZoneInstance.create(Protocol.ZONE_DEFAULT, 9, full) == null, "range full")


func _test_reserved_ranges(out: Array[Dictionary]) -> void:
	# Mob ids and instance ids come from disjoint reserved ranges, so entities in
	# different zones/channels/instances can never collide on an id.
	_add(out, "reserved_ranges_disjoint",
		Protocol.MOB_ID_BASE < Protocol.INSTANCE_ID_BASE, "mob=%d instance=%d" % [Protocol.MOB_ID_BASE, Protocol.INSTANCE_ID_BASE])
