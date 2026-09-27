extends RefCounted
## Boundary tests for the shared combat formula layer (shared/sim/formulas.gd).
##
## WB0 keeps flat damage, so today the interesting boundary is the floor: damage
## can never drop below 1, no matter how much armor the target has.

func cases() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_add(out, "melee_damage_base_case",
		Formulas.melee_damage(Protocol.MELEE_DAMAGE, 0) == Protocol.MELEE_DAMAGE,
		"power=%d armor=0" % Protocol.MELEE_DAMAGE)
	_add(out, "melee_damage_armor_reduces",
		Formulas.melee_damage(20, 5) == 15, "20-5")
	_add(out, "melee_damage_armor_equal_floors_to_one",
		Formulas.melee_damage(20, 20) == 1, "20-20 -> 1")
	_add(out, "melee_damage_armor_above_floors_to_one",
		Formulas.melee_damage(20, 999) == 1, "20-999 -> 1")
	_add(out, "melee_damage_zero_power_floors_to_one",
		Formulas.melee_damage(0, 0) == 1, "0-0 -> 1")
	_add(out, "melee_damage_never_below_one",
		Formulas.melee_damage(1, 100) == 1, "1-100 -> 1")
	return out


func _add(out: Array[Dictionary], name: String, ok: bool, detail: String = "") -> void:
	out.append({"name": name, "ok": ok, "detail": detail})
