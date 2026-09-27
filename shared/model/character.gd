class_name CharacterSheet
extends RefCounted
## Persisted character DTO returned by the server in s2c_character_list and used
## when entering the world. No Node inheritance, no logic.

var id: int = 0
var account_id: int = 0
var char_name: String = ""
var class_id: int = Protocol.ClassId.WARRIOR
var level: int = 1
var xp: int = 0
var hp: int = Protocol.PLAYER_MAX_HP
var pos: Vector3 = Protocol.SPAWN_POINT
var zone: String = "world"


func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": char_name,
		"class_id": class_id,
		"level": level,
		"xp": xp,
		"hp": hp,
		"pos": pos,
		"zone": zone,
	}


static func from_row(row: Dictionary) -> CharacterSheet:
	var c := CharacterSheet.new()
	c.id = int(row.get("id", 0))
	c.account_id = int(row.get("account_id", 0))
	c.char_name = String(row.get("name", ""))
	c.class_id = int(row.get("class_id", Protocol.ClassId.WARRIOR))
	c.level = int(row.get("level", 1))
	c.xp = int(row.get("xp", 0))
	c.hp = int(row.get("hp", Protocol.PLAYER_MAX_HP))
	c.pos = Vector3(
		float(row.get("pos_x", Protocol.SPAWN_POINT.x)),
		float(row.get("pos_y", Protocol.SPAWN_POINT.y)),
		float(row.get("pos_z", Protocol.SPAWN_POINT.z)),
	)
	c.zone = String(row.get("zone", "world"))
	return c
