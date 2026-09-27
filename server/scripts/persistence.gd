class_name PersistenceService
extends Node
## Character persistence. Login/loot/XP are out of MVP scope: only name, class,
## hp and position are persisted.
##
## Every call must run on the main thread (godot-sqlite is not thread safe).

var db: DBService


func characters_for(account_id: int) -> Array:
	return db.select("SELECT * FROM characters WHERE account_id = ? ORDER BY id;", [account_id])


func character_count(account_id: int) -> int:
	var rows := db.select("SELECT COUNT(*) AS n FROM characters WHERE account_id = ?;", [account_id])
	if rows.is_empty():
		return 0
	return int(rows[0].get("n", 0))


func get_character(char_id: int) -> CharacterSheet:
	var rows := db.select("SELECT * FROM characters WHERE id = ?;", [char_id])
	if rows.is_empty():
		return null
	return CharacterSheet.from_row(rows[0])


func name_taken(char_name: String) -> bool:
	var rows := db.select("SELECT id FROM characters WHERE name = ?;", [char_name])
	return not rows.is_empty()


## Returns {"ok": bool, "reason": String, "sheet": CharacterSheet|null}.
func create_character(account_id: int, char_name: String, class_id: int) -> Dictionary:
	if name_taken(char_name):
		return {"ok": false, "reason": "角色名已被占用"}
	var now := _now()
	var ok := db.execute(
		"INSERT INTO characters(account_id, name, class_id, level, xp, hp, pos_x, pos_y, pos_z, zone, updated_at) "
		+ "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
		[
			account_id, char_name, class_id, 1, 0, Protocol.PLAYER_MAX_HP,
			Protocol.SPAWN_POINT.x, Protocol.SPAWN_POINT.y, Protocol.SPAWN_POINT.z, "world", now,
		])
	if not ok:
		return {"ok": false, "reason": "数据库写入失败"}
	var sheet := get_character(db.last_insert_id())
	if sheet == null:
		return {"ok": false, "reason": "创建后读取失败"}
	return {"ok": true, "reason": "", "sheet": sheet}


func save_character(sheet: CharacterSheet) -> void:
	db.execute(
		"UPDATE characters SET hp=?, pos_x=?, pos_y=?, pos_z=?, zone=?, updated_at=? WHERE id=?;",
		[sheet.hp, sheet.pos.x, sheet.pos.y, sheet.pos.z, sheet.zone, _now(), sheet.id])


func _now() -> String:
	return Time.get_datetime_string_from_system(true)
