extends RefCounted
## Boundary tests for server-authoritative combat validation and the WB2 cast
## bar (server/scripts/combat.gd + skills.gd). The suite runs under the server
## project, where CombatService/WorldService and the data tables are available.
##
## `combat.reject_reason(attacker, ability, target)` is the single place that
## decides whether a c2s_use_ability intent is legal, so its class/GCD/cooldown/
## target/range boundaries are the rules the data-driven skill table feeds.
## Cast timing is exercised through `combat.skills.tick()` directly so the
## assertions stay deterministic and never touch the network.

const MELEE := Protocol.AbilityId.MELEE
const HEROIC_STRIKE := 1
const CHARGE := 13


func cases() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var world := WorldService.new()
	var combat := CombatService.new()
	combat.world = world
	combat.ensure_loaded()

	var attacker := EntityState.create(1, Protocol.EntityKind.PLAYER, "A", Vector3.ZERO, Protocol.PLAYER_MAX_HP)
	var target := EntityState.create(2, Protocol.EntityKind.MOB, "B", Vector3.ZERO, Protocol.MOB_MAX_HP)
	world.entities[1] = attacker
	world.entities[2] = target
	world.inputs[1] = {"seq": -1, "move": Vector2.ZERO, "yaw": 0.0, "buttons": 0}

	_range_cases(out, combat, attacker, target)
	_invalid_target_cases(out, combat, attacker, target)
	_attacker_cases(out, combat, attacker, target)
	_gcd_and_cooldown_cases(out, combat, world, attacker, target)
	_cast_cases(out, combat, world, attacker, target)

	combat.free()
	world.free()
	return out


func _range_cases(out: Array[Dictionary], combat: CombatService, attacker: EntityState, target: EntityState) -> void:
	# distance is compared with `>`, so distance == range is legal.
	target.pos = Vector3(3.0, 0.0, 0.0)
	_add(out, "combat_range_exactly_max_is_allowed",
		combat.reject_reason(1, MELEE, 2) == "", "distance=3.0 (range 3.0)")
	target.pos = Vector3(3.01, 0.0, 0.0)
	_add(out, "combat_range_just_over_is_rejected",
		combat.reject_reason(1, MELEE, 2) == "target out of range", "distance=3.01")
	target.pos = Vector3(2.5, 0.0, 0.0)
	_add(out, "combat_range_inside_is_allowed",
		combat.reject_reason(1, MELEE, 2) == "", "distance=2.5")
	target.pos = Vector3.ZERO


func _invalid_target_cases(out: Array[Dictionary], combat: CombatService, attacker: EntityState, target: EntityState) -> void:
	_add(out, "combat_unknown_ability_is_rejected",
		combat.reject_reason(1, 999, 2) == "unknown ability 999", "ability=999")
	_add(out, "combat_self_target_is_rejected",
		combat.reject_reason(1, MELEE, 1) == "cannot target self", "target=attacker")
	_add(out, "combat_missing_target_is_rejected",
		combat.reject_reason(1, MELEE, 999) == "target does not exist", "target=999")
	target.alive = false
	_add(out, "combat_dead_target_is_rejected",
		combat.reject_reason(1, MELEE, 2) == "target is already dead", "target alive=false")
	target.alive = true


func _attacker_cases(out: Array[Dictionary], combat: CombatService, attacker: EntityState, target: EntityState) -> void:
	_add(out, "combat_missing_attacker_is_rejected",
		combat.reject_reason(42, MELEE, 2) == "attacker not in world", "attacker=42")

	attacker.kind = Protocol.EntityKind.MOB
	_add(out, "combat_mob_attacker_is_rejected",
		combat.reject_reason(1, MELEE, 2) == "attacker is not a player", "kind=MOB")
	attacker.kind = Protocol.EntityKind.PLAYER

	var class_id := attacker.class_id
	attacker.class_id = 99
	_add(out, "combat_unknown_class_does_not_know_ability",
		combat.reject_reason(1, MELEE, 2) == "ability not known by class", "class=99")
	attacker.class_id = class_id

	attacker.alive = false
	_add(out, "combat_dead_attacker_is_rejected",
		combat.reject_reason(1, MELEE, 2) == "attacker is dead", "attacker alive=false")
	attacker.alive = true


func _gcd_and_cooldown_cases(
		out: Array[Dictionary], combat: CombatService, world: WorldService,
		attacker: EntityState, target: EntityState) -> void:
	target.pos = Vector3(1.0, 0.0, 0.0)
	# Committing melee starts its 1.0s cooldown (from abilities.json).
	var began := combat.skills.begin(world, 1, MELEE, 2)
	_add(out, "combat_melee_begins_instant",
		String(began.get("result", "")) == "instant", "result=%s" % began.get("result", "?"))
	_add(out, "combat_active_cooldown_is_rejected",
		combat.reject_reason(1, MELEE, 2) == "ability on cooldown", "cooldown>0")
	# Heroic Strike carries a 1.0s GCD, which gates even off-GCD melee.
	var strike := combat.skills.begin(world, 1, HEROIC_STRIKE, 2)
	_add(out, "combat_heroic_strike_begins_instant",
		String(strike.get("result", "")) == "instant", "result=%s" % strike.get("result", "?"))

	# A full GCD/CDR decay makes melee legal again.
	combat.skills.tick(world, 10.0)
	_add(out, "combat_zero_cooldown_is_allowed",
		combat.reject_reason(1, MELEE, 2) == "", "cooldown=0.0")

	# GCD boundary: ability 1 sets the GCD, so melee is gated by it.
	combat.skills.begin(world, 1, HEROIC_STRIKE, 2)
	_add(out, "combat_gcd_is_rejected",
		combat.reject_reason(1, MELEE, 2) == "ability on global cooldown", "gcd>0")
	combat.skills.tick(world, 10.0)


func _cast_cases(
		out: Array[Dictionary], combat: CombatService, world: WorldService,
		attacker: EntityState, target: EntityState) -> void:
	target.pos = Vector3(2.0, 0.0, 0.0)
	world.inputs[1] = {"seq": -1, "move": Vector2.ZERO, "yaw": 0.0, "buttons": 0}

	var began := combat.skills.begin(world, 1, CHARGE, 2)
	_add(out, "combat_cast_starts",
		String(began.get("result", "")) == "cast_started"
			and not combat.skills.active_cast(1).is_empty(),
		"result=%s" % began.get("result", "?"))

	# Not finished before its cast time elapses.
	var early: Array = combat.skills.tick(world, 1.0)
	_add(out, "combat_cast_not_early",
		early.is_empty() and not combat.skills.active_cast(1).is_empty(), "t=1.0 of 1.5")

	# Standing still, target alive and in range: the cast completes.
	var done: Array = combat.skills.tick(world, 0.6)
	_add(out, "combat_cast_completes",
		done.size() == 1 and String(done[0].get("type", "")) == "completed"
			and int(done[0].get("ability_id", -1)) == CHARGE,
		"events=%s" % str(done))
	_add(out, "combat_cast_cleared_on_completion",
		combat.skills.active_cast(1).is_empty(), "no active cast")

	# Moving during a cast interrupts it.
	combat.skills.begin(world, 1, CHARGE, 2)
	world.inputs[1] = {"seq": 1, "move": Vector2(0.0, 1.0), "yaw": 0.0, "buttons": 0}
	var moved: Array = combat.skills.tick(world, 0.05)
	_add(out, "combat_cast_interrupted_by_movement",
		moved.size() == 1 and String(moved[0].get("type", "")) == "interrupted"
			and int(moved[0].get("reason", -1)) == SkillService.INTERRUPT_MOVED,
		"events=%s" % str(moved))
	world.inputs[1] = {"seq": 2, "move": Vector2.ZERO, "yaw": 0.0, "buttons": 0}

	# A dying target breaks the cast.
	combat.skills.begin(world, 1, CHARGE, 2)
	target.alive = false
	var target_died: Array = combat.skills.tick(world, 0.05)
	_add(out, "combat_cast_interrupted_by_target_death",
		target_died.size() == 1 and int(target_died[0].get("reason", -1)) == SkillService.INTERRUPT_TARGET_DIED,
		"events=%s" % str(target_died))
	target.alive = true

	# A dying caster breaks the cast.
	combat.skills.begin(world, 1, CHARGE, 2)
	attacker.alive = false
	var caster_died: Array = combat.skills.tick(world, 0.05)
	_add(out, "combat_cast_interrupted_by_caster_death",
		caster_died.size() == 1 and int(caster_died[0].get("reason", -1)) == SkillService.INTERRUPT_DIED,
		"events=%s" % str(caster_died))
	attacker.alive = true


func _add(out: Array[Dictionary], name: String, ok: bool, detail: String = "") -> void:
	out.append({"name": name, "ok": ok, "detail": detail})
