extends RefCounted
## Boundary tests for server-authoritative combat validation
## (server/scripts/combat.gd). The suite runs under the server project so
## CombatService/WorldService are available.
##
## `_reject_reason` is the single place that decides whether a c2s_use_ability
## intent is legal, so its range and cooldown boundaries are exactly the rules
## WB2 will replace with the data-driven skill table. A subclass exposes the
## private check without reaching across scripts.

class CombatProbe extends CombatService:
	func reason(attacker_id: int, target_id: int) -> String:
		return _reject_reason(attacker_id, target_id)


func cases() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var world := WorldService.new()
	var combat := CombatProbe.new()
	combat.world = world

	var attacker := EntityState.create(1, Protocol.EntityKind.PLAYER, "A", Vector3.ZERO, Protocol.PLAYER_MAX_HP)
	var target := EntityState.create(2, Protocol.EntityKind.PLAYER, "B", Vector3.ZERO, Protocol.PLAYER_MAX_HP)
	world.entities[1] = attacker
	world.entities[2] = target

	# --- range boundary (distance is compared with `>`, so == range is legal) --
	target.pos = Vector3(Protocol.MELEE_RANGE, 0.0, 0.0)
	_add(out, "combat_range_exactly_max_is_allowed",
		combat.reason(1, 2) == "", "distance=%.3f" % attacker.pos.distance_to(target.pos))

	target.pos = Vector3(Protocol.MELEE_RANGE + 0.01, 0.0, 0.0)
	_add(out, "combat_range_just_over_is_rejected",
		combat.reason(1, 2) == "target out of range", "distance=%.3f" % attacker.pos.distance_to(target.pos))

	target.pos = Vector3(Protocol.MELEE_RANGE - 0.5, 0.0, 0.0)
	_add(out, "combat_range_inside_is_allowed", combat.reason(1, 2) == "", "inside range")

	# --- cooldown boundary (> 0 rejects, 0 allows) ----------------------------
	target.pos = Vector3(1.0, 0.0, 0.0)
	world.cooldowns[1] = 0.5
	_add(out, "combat_active_cooldown_is_rejected",
		combat.reason(1, 2) == "ability on cooldown", "cooldown=0.5")
	world.cooldowns[1] = 0.0
	_add(out, "combat_zero_cooldown_is_allowed",
		combat.reason(1, 2) == "", "cooldown=0.0")

	# --- invalid target / attacker --------------------------------------------
	_add(out, "combat_self_target_is_rejected",
		combat.reason(1, 1) == "cannot target self", "target=attacker")
	_add(out, "combat_missing_target_is_rejected",
		combat.reason(1, 999) == "target does not exist", "target=999")

	target.alive = false
	_add(out, "combat_dead_target_is_rejected",
		combat.reason(1, 2) == "target is already dead", "target alive=false")
	target.alive = true

	_add(out, "combat_missing_attacker_is_rejected",
		combat.reason(42, 2) == "attacker not in world", "attacker=42")

	attacker.kind = Protocol.EntityKind.MOB
	_add(out, "combat_mob_attacker_is_rejected",
		combat.reason(1, 2) == "attacker is not a player", "kind=MOB")
	attacker.kind = Protocol.EntityKind.PLAYER

	attacker.alive = false
	_add(out, "combat_dead_attacker_is_rejected",
		combat.reason(1, 2) == "attacker is dead", "attacker alive=false")
	attacker.alive = true

	combat.free()
	world.free()
	return out


func _add(out: Array[Dictionary], name: String, ok: bool, detail: String = "") -> void:
	out.append({"name": name, "ok": ok, "detail": detail})
