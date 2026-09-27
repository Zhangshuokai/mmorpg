extends RefCounted
## Boundary tests for the shared combat formula layer (shared/sim/formulas.gd).
##
## Two families:
##   * the WB0 legacy flat-damage `melee_damage` boundary (unchanged);
##   * the WB2 data-driven pipeline: armor/resistance mitigation caps, hit/crit
##     clamps, the resolve_damage floor and the deterministic roll.

func cases() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_legacy_melee_cases(out)
	_mitigation_cases(out)
	_hit_crit_cases(out)
	_resolve_damage_cases(out)
	_roll_cases(out)
	return out


func _legacy_melee_cases(out: Array[Dictionary]) -> void:
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


func _mitigation_cases(out: Array[Dictionary]) -> void:
	_add(out, "armor_zero_mitigates_nothing",
		is_equal_approx(Formulas.armor_mitigation(0), 0.0), "armor=0")
	_add(out, "armor_k_is_half",
		is_equal_approx(Formulas.armor_mitigation(int(Formulas.ARMOR_K)), 0.5),
		"armor=K -> 50%%")
	_add(out, "armor_negative_treated_as_zero",
		is_equal_approx(Formulas.armor_mitigation(-50), 0.0), "armor=-50")
	_add(out, "armor_huge_is_capped",
		is_equal_approx(Formulas.armor_mitigation(10_000_000), Formulas.MITIGATION_CAP),
		"armor=huge -> cap")
	_add(out, "resistance_k_is_half",
		is_equal_approx(Formulas.resistance_mitigation(int(Formulas.RESIST_K)), 0.5),
		"resistance=K -> 50%%")
	_add(out, "resistance_huge_is_capped",
		is_equal_approx(Formulas.resistance_mitigation(10_000_000), Formulas.MITIGATION_CAP),
		"resistance=huge -> cap")


func _hit_crit_cases(out: Array[Dictionary]) -> void:
	_add(out, "hit_full_when_unopposed",
		is_equal_approx(Formulas.hit_chance(1.0, 0.0), 1.0), "1.0 - 0.0")
	_add(out, "hit_subtracts_dodge",
		is_equal_approx(Formulas.hit_chance(0.9, 0.2), 0.7), "0.9 - 0.2")
	_add(out, "hit_has_a_floor",
		is_equal_approx(Formulas.hit_chance(0.0, 5.0), Formulas.HIT_FLOOR), "clamped to floor")
	_add(out, "crit_clamped_to_unit",
		is_equal_approx(Formulas.crit_chance(1.5), 1.0), "1.5 -> 1.0")
	_add(out, "crit_negative_clamped_to_zero",
		is_equal_approx(Formulas.crit_chance(-0.5), 0.0), "-0.5 -> 0.0")


func _resolve_damage_cases(out: Array[Dictionary]) -> void:
	_add(out, "resolve_undefended_is_base_plus_ap",
		Formulas.resolve_damage(20, 0, 0, 0, false) == 20, "20+0")
	_add(out, "resolve_attack_power_adds",
		Formulas.resolve_damage(20, 10, 0, 0, false) == 30, "20+10")
	_add(out, "resolve_crit_doubles",
		Formulas.resolve_damage(20, 0, 0, 0, true) == 40, "20*2")
	_add(out, "resolve_half_armor_halves",
		Formulas.resolve_damage(20, 0, int(Formulas.ARMOR_K), 0, false) == 10, "50%% armor")
	_add(out, "resolve_never_below_one",
		Formulas.resolve_damage(1, 0, 10_000_000, 10_000_000, false) == 1, "capped mitigation")
	_add(out, "resolve_zero_base_floors_to_one",
		Formulas.resolve_damage(0, 0, 0, 0, false) == 1, "0 base -> 1")


func _roll_cases(out: Array[Dictionary]) -> void:
	var values: Array[float] = []
	for seed in range(64):
		values.append(Formulas.roll(seed))
	var in_range := true
	for v: float in values:
		if v < 0.0 or v >= 1.0:
			in_range = false
	_add(out, "roll_is_unit_interval", in_range, "64 seeds in [0,1)")
	_add(out, "roll_is_deterministic",
		is_equal_approx(Formulas.roll(12345), Formulas.roll(12345)), "same seed")
	# A full-hit attacker never misses, a zero-crit attacker never crits.
	var always_hits := true
	var never_crits := true
	for seed in range(64):
		if not Formulas.is_hit(seed, 1.0, 0.0):
			always_hits = false
		if Formulas.is_crit(seed, 0.0):
			never_crits = false
	_add(out, "is_hit_always_hits_at_full_rating", always_hits, "hit=1.0")
	_add(out, "is_crit_never_crits_at_zero", never_crits, "crit=0.0")


func _add(out: Array[Dictionary], name: String, ok: bool, detail: String = "") -> void:
	out.append({"name": name, "ok": ok, "detail": detail})
