class_name CombatService
extends Node
## Server-authoritative combat entry point (S-G-1, S-G-2).
##
## The client only sends *which* ability it wants to use on *which* entity
## (c2s_use_ability). The server resolves the ability from the data table, checks
## class / GCD / cooldown / target type / range (SkillService), runs the cast bar
## or applies the effect immediately, and alone computes the damage through the
## shared `Formulas` layer. Nothing the client reports is trusted.
##
## This class is the only combat code that touches `Net` and `Formulas`;
## `skills.gd` owns the data + timers. It is a Node so the engine drives its
## `_physics_process` once per world tick (20Hz) without any wiring change.

## Interrupt reasons mirrored from SkillService (kept tiny on purpose: the wire
## payload is just an int).
const INTERRUPT_NONE := SkillService.INTERRUPT_NONE

var world: WorldService
var skills := SkillService.new()


func _ready() -> void:
	skills.load_data()


## Loads the tables on demand for code paths that construct CombatService
## outside the scene tree (unit tests); the server already did it in _ready.
func ensure_loaded() -> void:
	if not skills.ready:
		if not skills.load_data():
			push_error("[combat] skill data unavailable: %s" % skills.load_error)


## Called for c2s_use_ability. `attacker_id` comes from the RPC sender id, never
## from client data.
func use_ability(attacker_id: int, ability_id: int, target_id: int) -> void:
	if world == null:
		return
	ensure_loaded()
	var transition := skills.begin(world, attacker_id, ability_id, target_id)
	match String(transition.get("result", "")):
		"rejected":
			print("[combat] rejected ability %d from %d -> %d: %s" % [
				ability_id, attacker_id, target_id, transition.get("reason", "")])
		"instant":
			_resolve_effect(
				int(transition.get("ability_id", 0)), attacker_id,
				int(transition.get("target_id", 0)))
		"cast_started":
			_emit_cast_started(
				attacker_id, int(transition.get("ability_id", 0)),
				int(transition.get("target_id", 0)), float(transition.get("duration", 0.0)))


## One world tick: age cooldowns/GCD/cast bars, then resolve what ended. The
## facade (world.gd) runs before this node, so the authoritative positions and
## input intents this tick are already current.
func _physics_process(delta: float) -> void:
	if world == null:
		return
	ensure_loaded()
	for event: Dictionary in skills.tick(world, delta):
		match String(event.get("type", "")):
			"completed":
				_resolve_effect(
					int(event.get("ability_id", 0)), int(event.get("caster_id", 0)),
					int(event.get("target_id", 0)))
			"interrupted":
				_emit_cast_interrupted(
					int(event.get("caster_id", 0)), int(event.get("ability_id", 0)),
					int(event.get("reason", 0)))


## Public boundary probe for the router/tests: "" means the intent is legal.
func reject_reason(attacker_id: int, ability_id: int, target_id: int) -> String:
	if world == null:
		return "world unavailable"
	ensure_loaded()
	return skills.reject_reason(world, attacker_id, ability_id, target_id)


# --- effect resolution (server-only numbers) --------------------------------

## Applies an ability's effect. Only ENEMY damage abilities exist today; SELF/ALLY
## support is a later heal/buff system (S-G-3), so anything else is a no-op here.
func _resolve_effect(ability_id: int, caster_id: int, target_id: int) -> void:
	var row := skills.ability(ability_id)
	if row.is_empty():
		return
	if int(row.get("target_type", Protocol.TargetType.ENEMY)) != Protocol.TargetType.ENEMY:
		return
	var caster: EntityState = world.entities.get(caster_id)
	var target: EntityState = world.entities.get(target_id)
	if caster == null or target == null or not target.alive:
		return
	if caster.pos.distance_to(target.pos) > float(row.get("range", 0.0)):
		return

	var class_row := skills.class_row_for(caster)
	var hit_seed := _roll_seed(caster_id, ability_id, target_id, 0)
	var crit_seed := _roll_seed(caster_id, ability_id, target_id, 1)
	if not Formulas.is_hit(hit_seed, float(class_row.get("hit_chance", 1.0)), 0.0):
		return
	var is_crit := Formulas.is_crit(crit_seed, float(class_row.get("crit_chance", 0.0)))
	var school := String(row.get("school", "physical"))
	var damage := Formulas.resolve_damage(
		int(row.get("base_damage", 0)),
		int(class_row.get("attack_power", 0)),
		_target_armor(target),
		_target_resistance(target, school),
		is_crit)
	world.apply_damage(target_id, damage, caster_id)


func _target_armor(target: EntityState) -> int:
	return int(skills.class_row_for(target).get("armor", 0))


func _target_resistance(target: EntityState, school: String) -> int:
	var class_row := skills.class_row_for(target)
	if class_row.is_empty():
		return 0
	var resistances: Dictionary = class_row.get("resistances", {})
	return int(resistances.get(school, 0))


## Deterministic per-(tick, caster, ability, target, salt) seed. The same inputs
## always produce the same hit/crit, so a replay and the unit tests agree.
func _roll_seed(caster_id: int, ability_id: int, target_id: int, salt: int) -> int:
	var tick := 0 if world == null else world.tick
	return (tick * 131 + caster_id * 17 + ability_id * 7 + target_id * 3 + salt) & 0x7FFFFFFF


# --- cast-bar notifications -------------------------------------------------

## RPCs require a live tree + peer; unit tests drive CombatService headless with
## no peer, so the events are simply dropped there (state still advances).
func _can_send() -> bool:
	if not is_inside_tree():
		return false
	var mp := multiplayer
	return mp != null and mp.multiplayer_peer != null


func _emit_cast_started(caster_id: int, ability_id: int, target_id: int, duration_sec: float) -> void:
	if not _can_send():
		return
	Net.s2c_cast_started.rpc(caster_id, ability_id, target_id, duration_sec)


func _emit_cast_interrupted(caster_id: int, ability_id: int, reason: int) -> void:
	if reason == INTERRUPT_NONE or not _can_send():
		return
	Net.s2c_cast_interrupted.rpc(caster_id, ability_id, reason)
