class_name EntityState
extends RefCounted
## Plain data transfer object broadcast by the server for every replicated entity
## (players and mobs use the same shape). No Node inheritance, no logic.

var id: int = 0
var kind: int = Protocol.EntityKind.PLAYER
var display_name: String = ""
var class_id: int = Protocol.ClassId.WARRIOR
var pos: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var hp: int = 0
var max_hp: int = 0
var alive: bool = true
var target_id: int = 0


static func create(p_id: int, p_kind: int, p_name: String, p_pos: Vector3, p_max_hp: int) -> EntityState:
	var s := EntityState.new()
	s.id = p_id
	s.kind = p_kind
	s.display_name = p_name
	s.pos = p_pos
	s.max_hp = p_max_hp
	s.hp = p_max_hp
	return s


func to_dict() -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"name": display_name,
		"class_id": class_id,
		"pos": pos,
		"yaw": yaw,
		"hp": hp,
		"max_hp": max_hp,
		"alive": alive,
		"target_id": target_id,
	}


## Compact per-tick representation: only what changes at 20Hz.
func to_net_dict() -> Dictionary:
	return {"id": id, "pos": pos, "yaw": yaw, "hp": hp, "alive": alive, "target_id": target_id}


## Compact spawn representation sent once when a client can first see the entity.
func to_spawn_dict() -> Dictionary:
	return to_dict()
