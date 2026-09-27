class_name Formulas
extends RefCounted
## Pure combat formula layer (S-G-2).
##
## All functions are static and deterministic, so the server, the client skill bar
## and the unit tests share exactly one implementation. The *inputs* (attack
## power, armor, crit/hit chance, resistances) come from
## `shared/data/tables/classes.json`; this file only fixes the shape of the maths,
## keeping the tuning knobs as named constants instead of scattering magic
## numbers through `combat.gd`.
##
## The legacy `melee_damage()` flat-subtract helper is kept byte-for-byte so the
## extracted WB0 behaviour and its tests still hold; new combat goes through
## `resolve_damage()`.

## Armor/resistance rating needed for 50% mitigation.
const ARMOR_K := 50.0
const RESIST_K := 50.0
## Mitigation is capped so stacking defense can never reach full immunity.
const MITIGATION_CAP := 0.75
## A critical hit multiplies the resolved raw damage.
const CRIT_MULTIPLIER := 2.0
## Even a poor hit rating lands occasionally, so fights cannot stall forever.
const HIT_FLOOR := 0.05


## Basic melee damage (WB0 legacy path). With (MELEE_DAMAGE, 0) this is exactly
## MELEE_DAMAGE, which keeps the extracted code path behaviour-identical.
static func melee_damage(attacker_attack_power: int, target_armor: int) -> int:
	return maxi(1, attacker_attack_power - target_armor)


# --- mitigation -------------------------------------------------------------

## Fraction of incoming damage removed by `armor`, in [0, MITIGATION_CAP].
static func armor_mitigation(armor: int) -> float:
	var a := maxf(0.0, float(armor))
	return clampf(a / (a + ARMOR_K), 0.0, MITIGATION_CAP)


## Fraction of incoming damage removed by a school `resistance`, in [0, cap].
static func resistance_mitigation(resistance: int) -> float:
	var r := maxf(0.0, float(resistance))
	return clampf(r / (r + RESIST_K), 0.0, MITIGATION_CAP)


# --- hit / crit -------------------------------------------------------------

## Probability that an attack lands, clamped to [HIT_FLOOR, 1].
static func hit_chance(attacker_hit: float, target_dodge: float) -> float:
	return clampf(attacker_hit - target_dodge, HIT_FLOOR, 1.0)


## Probability that a landed attack crits, clamped to [0, 1].
static func crit_chance(attacker_crit: float) -> float:
	return clampf(attacker_crit, 0.0, 1.0)


## Full damage pipeline: base + attack power, optional crit, then armor and
## per-school resistance. Always returns at least 1.
static func resolve_damage(
		base_damage: int, attack_power: int, target_armor: int,
		target_resistance: int, is_crit: bool) -> int:
	var raw := maxi(1, base_damage + attack_power)
	if is_crit:
		raw = int(round(float(raw) * CRIT_MULTIPLIER))
	var after_armor := int(floor(float(raw) * (1.0 - armor_mitigation(target_armor))))
	var after_resistance := int(floor(float(after_armor) * (1.0 - resistance_mitigation(target_resistance))))
	return maxi(1, after_resistance)


# --- deterministic rolls ----------------------------------------------------

## Deterministic [0, 1) value from an integer seed. A hash (not a random stream)
## so the server, tests and any replay of the same seed agree exactly.
static func roll(seed: int) -> float:
	var x := (seed ^ 0x9E3779B9) & 0xFFFFFFFF
	x = ((x ^ (x >> 16)) * 0x85EBCA6B) & 0xFFFFFFFF
	x = ((x ^ (x >> 13)) * 0xC2B2AE35) & 0xFFFFFFFF
	x = (x ^ (x >> 16)) & 0xFFFFFFFF
	return float(x) / 4294967296.0


static func is_hit(seed: int, attacker_hit: float, target_dodge: float) -> bool:
	return roll(seed) < hit_chance(attacker_hit, target_dodge)


static func is_crit(seed: int, attacker_crit: float) -> bool:
	return roll(seed) < crit_chance(attacker_crit)
