class_name DBService
extends Node
## Thin, main-thread-only wrapper around the `godot-sqlite` GDExtension.
##
## godot-sqlite is NOT thread safe: every call in this class must happen on the
## main thread (auth callbacks, the 20Hz world tick and timers all run there).
## Values are always passed through parameter bindings; identifiers are literal
## constants in this file, so nothing is concatenated from untrusted input.

const DB_PATH := "user://mmorpg_server.db"
## 0 = quiet, 1 = normal, 2 = verbose, 3 = very verbose.
const VERBOSITY := 0

var db: SQLite
var is_open := false


func _ready() -> void:
	open()


func open() -> bool:
	db = SQLite.new()
	db.path = DB_PATH
	# Enable FK enforcement (accounts <- characters).
	db.foreign_keys = true
	db.verbosity_level = VERBOSITY
	if not db.open_db():
		push_error("[db] cannot open %s: %s" % [DB_PATH, db.error_message])
		return false
	_create_schema()
	is_open = true
	print("[db] opened %s" % ProjectSettings.globalize_path(DB_PATH))
	return true


func close() -> void:
	if db != null:
		db.close_db()
	is_open = false


# --- schema -----------------------------------------------------------------

func _table_exists(table_name: String) -> bool:
	if not db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='%s';" % table_name):
		return false
	return db.query_result.size() > 0


func _create_schema() -> void:
	if not _table_exists("accounts"):
		if not db.create_table("accounts", {
			"id": {"data_type": "int", "primary_key": true, "auto_increment": true, "not_null": true},
			"username": {"data_type": "text", "not_null": true, "unique": true},
			"password_hash": {"data_type": "text", "not_null": true},
			"salt": {"data_type": "text", "not_null": true},
			"created_at": {"data_type": "text", "not_null": true, "default": "''"},
		}):
			push_error("[db] create_table(accounts) failed: %s" % db.error_message)
	if not _table_exists("characters"):
		if not db.create_table("characters", {
			"id": {"data_type": "int", "primary_key": true, "auto_increment": true, "not_null": true},
			"account_id": {"data_type": "int", "not_null": true, "foreign_key": "accounts.id"},
			"name": {"data_type": "text", "not_null": true, "unique": true},
			# No SQL defaults for the columns whose values come from Protocol /
			# CharacterSheet (class_id, hp, position, zone): they are always
			# supplied by persistence.create_character, so the shared constants
			# stay the single source of truth and cannot drift from the schema.
			"class_id": {"data_type": "int", "not_null": true},
			"level": {"data_type": "int", "not_null": true, "default": 1},
			"xp": {"data_type": "int", "not_null": true, "default": 0},
			"hp": {"data_type": "int", "not_null": true},
			"pos_x": {"data_type": "real", "not_null": true},
			"pos_y": {"data_type": "real", "not_null": true},
			"pos_z": {"data_type": "real", "not_null": true},
			"zone": {"data_type": "text", "not_null": true},
			"updated_at": {"data_type": "text", "not_null": true, "default": "''"},
		}):
			push_error("[db] create_table(characters) failed: %s" % db.error_message)


# --- generic access ---------------------------------------------------------
# `query_result` is returned by value, so it is safe to keep across queries.

func select(sql: String, params: Array = []) -> Array:
	var ok := false
	if params.is_empty():
		ok = db.query(sql)
	else:
		ok = db.query_with_bindings(sql, params)
	if not ok:
		push_error("[db] query failed: %s | sql=%s" % [db.error_message, sql])
		return []
	return db.query_result


func execute(sql: String, params: Array = []) -> bool:
	var ok := false
	if params.is_empty():
		ok = db.query(sql)
	else:
		ok = db.query_with_bindings(sql, params)
	if not ok:
		push_error("[db] query failed: %s | sql=%s" % [db.error_message, sql])
	return ok


func last_insert_id() -> int:
	return int(db.last_insert_rowid)
