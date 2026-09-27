class_name SkillService
extends RefCounted
## Data-driven ability registry + per-entity cooldown / GCD / cast state (S-G-1).
##
## Owned by WB2. The rules here are pure server-authoritative state: the client
## only ever sends `c2s_use_ability(ability_id, target_id)`; this class decides
## whether the intent is legal (ability exists and is known by the caster's class,
## off the global cooldown, off the ability cooldown, target type/range valid) and
## only then commits a cooldown, starts a cast or lets the caller resolve it
## instantly.
##
## `CombatService` (server/scripts/combat.gd) is the entry point: it feeds world
## ticks in, gets cast start/complete/interrupt transitions out, and is the only
## place that touches `Net`/`Formulas`. This class never touches RPCs.
##
## Everything is driven by `shared/data/tables/abilities.json` +
## `classes.json`, so adding a skill or a class is a data change, not a code
## change. Protocol only supplies ids/enums (Protocol.TargetType,
## Protocol.AbilityId.MELEE) and the hard bounds the startup validator already
## enforces on the tables.

## Interrupt reasons carried by `s2c_cast_interrupted(caster, ability, reason)`.
## Not part of the frozen wire contract (it is an int payload); kept here so the
## server and the bot agree.
const INTERRUPT_NONE := 0
const INTERRUPT_MOVED := 1
const INTERRUPT_DIED := 2
const INTERRUPT_TARGET_DIED := 3
const INTERRUPT_TARGET_LOST := 4

const ABILITIES_TABLE := "abilities"
const CLASSES_TABLE := "classes"
## Movement intent length above which a cast is considered interrupted.
const MOVE_EPSILON := 0.01

var ready := false
var load_error := ""

## ability_id -> row Dictionary; class_id -> row Dictionary.
var _abilities: Dictionary = {}
var _classes: Dictionary = {}
## entity_id -> { ability_id: remaining_seconds }.
var _cooldowns: Dictionary = {}
## entity_id -> remaining global cooldown seconds.
var _gcd: Dictionary = {}
## entity_id -> { ability_id, target_id, remaining, total }.
var _casts: Dictionary = {}


## Loads (or reloads) the ability and class tables. Idempotent; returns false and
## leaves `load_error` set when the data is missing, in which case combat refuses
## every intent (fail closed).
func load_data() -> bool:
	ready = false
	load_error = ""
	var abilities: Variant = DataTables.load_table(ABILITIES_TABLE)
	var classes: Variant = DataTables.load_table(CLASSES_TABLE)
	if typeof(abilities) != TYPE_DICTIONARY or typeof(classes) != TYPE_DICTIONARY:
		load_error = "%s.json / %s.json missing or invalid" % [ABILITIES_TABLE, CLASSES_TABLE]
		return false
	_abilities.clear()
	for row: Dictionary in (abilities as Dictionary).get("rows", []):
		_abilities[int(row.get("id", -1))] = row
	_classes.clear()
	for row: Dictionary in (classes as Dictionary).get("rows", []):
		_classes[int(row.get("id", -1))] = row
	if _abilities.is_empty() or _classes.is_empty():
		load_error = "ability/class tables are empty"
		return false
	ready = true
	return true


func ensure_loaded() -> bool:
	if ready:
		return true
	return load_data()


# --- registry ---------------------------------------------------------------

func ability(ability_id: int) -> Dictionary:
	return _abilities.get(ability_id, {})


func class_def(class_id: int) -> Dictionary:
	return _classes.get(class_id, {})


## Class row for a live entity (empty for mobs: they have no class table row yet).
func class_row_for(entity: EntityState) -> Dictionary:
	if entity != null and entity.kind == Protocol.EntityKind.PLAYER:
		return class_def(entity.class_id)
	return {}


func knows(ability_id: int, class_id: int) -> bool:
	var row := ability(ability_id)
	if row.is_empty():
		return false
	for known: int in row.get("class_ids", []):
		if known == class_id:
			return true
	return false


# --- state accessors (used by tests + bot observability) ---------------------

func cooldown_remaining(entity_id: int, ability_id: int) -> float:
	var per: Dictionary = _cooldowns.get(entity_id, {})
	return float(per.get(ability_id, 0.0))


func gcd_remaining(entity_id: int) -> float:
	return float(_gcd.get(entity_id, 0.0))


func active_cast(entity_id: int) -> Dictionary:
	return _casts.get(entity_id, {})


# --- validation -------------------------------------------------------------

## "" means the intent is legal. Pure: never mutates state, so the router/tests
## can ask "would this work" without committing a cooldown.
func reject_reason(world: WorldService, attacker_id: int, ability_id: int, target_id: int) -> String:
	if not ensure_loaded():
		return "skills unavailable: %s" % load_error
	var row := ability(ability_id)
	if row.is_empty():
		return "unknown ability %d" % ability_id
	var attacker: EntityState = world.entities.get(attacker_id)
	if attacker == null:
		return "attacker not in world"
	if attacker.kind != Protocol.EntityKind.PLAYER:
		return "attacker is not a player"
	if not attacker.alive:
		return "attacker is dead"
	if not knows(ability_id, attacker.class_id):
		return "ability not known by class"
	if gcd_remaining(attacker_id) > 0.0:
		return "ability on global cooldown"
	if cooldown_remaining(attacker_id, ability_id) > 0.0:
		return "ability on cooldown"
	var resolved := _resolve_target(world, attacker_id, row, target_id)
	var error := String(resolved.get("error", ""))
	if error != "":
		return error
	var target: EntityState = world.entities.get(int(resolved.get("id", 0)))
	if target != null and attacker.pos.distance_to(target.pos) > float(row.get("range", 0.0)):
		return "target out of range"
	return ""


## Commits a legal intent and returns the transition:
##   {"result": "rejected",     "reason": String}
##   {"result": "instant",      "ability_id", "target_id"}
##   {"result": "cast_started", "ability_id", "target_id", "duration"}
func begin(world: WorldService, attacker_id: int, ability_id: int, target_id: int) -> Dictionary:
	var reason := reject_reason(world, attacker_id, ability_id, target_id)
	if reason != "":
		return {"result": "rejected", "reason": reason}
	var row := ability(ability_id)
	var resolved := _resolve_target(world, attacker_id, row, target_id)
	var resolved_id := int(resolved.get("id", 0))
	var attacker: EntityState = world.entities[attacker_id]
	attacker.target_id = resolved_id

	_start_cooldown(attacker_id, ability_id, float(row.get("cooldown", 0.0)))
	var gcd := float(row.get("gcd", 0.0))
	if gcd > 0.0:
		_gcd[attacker_id] = maxf(gcd_remaining(attacker_id), gcd)

	var cast_time := float(row.get("cast_time", 0.0))
	if cast_time > 0.0:
		_casts[attacker_id] = {
			"ability_id": ability_id,
			"target_id": resolved_id,
			"remaining": cast_time,
			"total": cast_time,
		}
		return {
			"result": "cast_started", "ability_id": ability_id,
			"target_id": resolved_id, "duration": cast_time,
		}
	return {"result": "instant", "ability_id": ability_id, "target_id": resolved_id}


# --- per-tick simulation ----------------------------------------------------

## Advances cooldowns/GCD and cast bars by `delta`, dropping finished or
## interrupted casts. Returns the cast transitions for this tick:
##   {"type": "completed",   "caster_id", "ability_id", "target_id"}
##   {"type": "interrupted", "caster_id", "ability_id", "reason"}
func tick(world: WorldService, delta: float) -> Array:
	var events: Array = []
	if not ready:
		return events
	_decay(delta)
	_prune(world)
	for entity_id: int in _casts.keys().duplicate():
		var cast: Dictionary = _casts[entity_id]
		var reason := _interrupt_reason(world, entity_id, cast)
		if reason != INTERRUPT_NONE:
			_casts.erase(entity_id)
			events.append({
				"type": "interrupted", "caster_id": entity_id,
				"ability_id": int(cast.get("ability_id", 0)), "reason": reason,
			})
			continue
		cast["remaining"] = float(cast.get("remaining", 0.0)) - delta
		if float(cast["remaining"]) <= 0.0:
			_casts.erase(entity_id)
			events.append({
				"type": "completed", "caster_id": entity_id,
				"ability_id": int(cast.get("ability_id", 0)),
				"target_id": int(cast.get("target_id", 0)),
			})
	return events


# --- internals --------------------------------------------------------------

func _start_cooldown(entity_id: int, ability_id: int, seconds: float) -> void:
	if seconds <= 0.0:
		return
	var per: Dictionary = _cooldowns.get(entity_id, {})
	per[ability_id] = maxf(float(per.get(ability_id, 0.0)), seconds)
	_cooldowns[entity_id] = per


func _decay(delta: float) -> void:
	for entity_id: int in _gcd.keys():
		_gcd[entity_id] = maxf(0.0, float(_gcd[entity_id]) - delta)
	for entity_id: int in _cooldowns.keys():
		var per: Dictionary = _cooldowns[entity_id]
		for ability_id: int in per.keys():
			per[ability_id] = maxf(0.0, float(per[ability_id]) - delta)


## Forgets state for entities that left the world (disconnect), so the maps do
## not grow without bound over a long uptime.
func _prune(world: WorldService) -> void:
	for entity_id: int in _casts.keys().duplicate():
		if not world.entities.has(entity_id):
			_casts.erase(entity_id)
	for entity_id: int in _cooldowns.keys().duplicate():
		if not world.entities.has(entity_id):
			_cooldowns.erase(entity_id)
	for entity_id: int in _gcd.keys().duplicate():
		if not world.entities.has(entity_id):
			_gcd.erase(entity_id)


## Maps the frozen Protocol.TargetType onto a concrete entity id.
## Returns {"id": int, "error": String}; SELF resolves to the caster.
func _resolve_target(
		world: WorldService, attacker_id: int, ability: Dictionary, target_id: int) -> Dictionary:
	var target_type := int(ability.get("target_type", Protocol.TargetType.ENEMY))
	match target_type:
		Protocol.TargetType.SELF:
			if target_id != 0 and target_id != attacker_id:
				return {"id": 0, "error": "self ability requires self target"}
			return {"id": attacker_id, "error": ""}
		Protocol.TargetType.ENEMY, Protocol.TargetType.ALLY:
			if target_id == attacker_id:
				return {"id": 0, "error": "cannot target self"}
			if not world.entities.has(target_id):
				return {"id": 0, "error": "target does not exist"}
			var target: EntityState = world.entities[target_id]
			if not target.alive:
				return {"id": 0, "error": "target is already dead"}
			if target_type == Protocol.TargetType.ALLY:
				var attacker: EntityState = world.entities[attacker_id]
				if target.kind != attacker.kind:
					return {"id": 0, "error": "target is not an ally"}
			return {"id": target_id, "error": ""}
		_:
			return {"id": 0, "error": "unsupported target type"}


func _interrupt_reason(world: WorldService, entity_id: int, cast: Dictionary) -> int:
	var caster: EntityState = world.entities.get(entity_id)
	if caster == null or not caster.alive:
		return INTERRUPT_DIED
	var input: Dictionary = world.inputs.get(entity_id, {})
	var move: Vector2 = input.get("move", Vector2.ZERO)
	if move.length() > MOVE_EPSILON:
		return INTERRUPT_MOVED
	var target: EntityState = world.entities.get(int(cast.get("target_id", 0)))
	if target == null:
		return INTERRUPT_TARGET_LOST
	if not target.alive:
		return INTERRUPT_TARGET_DIED
	var row := ability(int(cast.get("ability_id", 0)))
	if caster.pos.distance_to(target.pos) > float(row.get("range", 0.0)):
		return INTERRUPT_TARGET_LOST
	return INTERRUPT_NONE
