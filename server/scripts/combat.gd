class_name CombatService
extends Node
## Server-authoritative combat resolution.
##
## The client only sends *which* entity it wants to hit (c2s_use_ability). The
## server decides whether the actor exists, is alive, is off cooldown, whether
## the target is alive and whether it is inside melee range, and it alone
## computes the damage.

var world: WorldService


## Called for c2s_use_ability. `attacker_id` comes from the RPC sender id, never
## from client data.
func use_ability(attacker_id: int, target_id: int) -> void:
	if world == null:
		return
	var reason := _reject_reason(attacker_id, target_id)
	if reason != "":
		print("[combat] rejected ability from %d -> %d: %s" % [attacker_id, target_id, reason])
		return
	world.cooldowns[attacker_id] = Protocol.MELEE_COOLDOWN
	var attacker: EntityState = world.entities[attacker_id]
	attacker.target_id = target_id
	world.apply_damage(target_id, Protocol.MELEE_DAMAGE, attacker_id)


func _reject_reason(attacker_id: int, target_id: int) -> String:
	var attacker: EntityState = world.entities.get(attacker_id)
	if attacker == null:
		return "attacker not in world"
	if attacker.kind != Protocol.EntityKind.PLAYER:
		return "attacker is not a player"
	if not attacker.alive:
		return "attacker is dead"
	if float(world.cooldowns.get(attacker_id, 0.0)) > 0.0:
		return "ability on cooldown"
	if target_id == attacker_id:
		return "cannot target self"
	var target: EntityState = world.entities.get(target_id)
	if target == null:
		return "target does not exist"
	if not target.alive:
		return "target is already dead"
	if attacker.pos.distance_to(target.pos) > Protocol.MELEE_RANGE:
		return "target out of range"
	return ""
