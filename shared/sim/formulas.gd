class_name Formulas
extends RefCounted
## Pure combat formula layer (S-G-2).
##
## WB0 keeps the current flat-damage semantics so the server behaves exactly as
## before; WB2 makes the numbers data driven (armor, crit, hit, resistance) and
## these functions become the single place both ends and the unit tests share.

## Basic melee damage. With the WB0 placeholder inputs (attack_power =
## Protocol.MELEE_DAMAGE, target_armor = 0) this is exactly MELEE_DAMAGE, which
## keeps the extracted code path behaviour-identical.
static func melee_damage(attacker_attack_power: int, target_armor: int) -> int:
	return maxi(1, attacker_attack_power - target_armor)
