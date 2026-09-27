class_name DBService
extends Node
## Thin, main-thread-only wrapper around the `godot-sqlite` GDExtension.
##
## godot-sqlite is NOT thread safe: every call in this class must happen on the
## main thread (auth callbacks, the 20Hz world tick and timers all run there).
## Values are always passed through parameter bindings; identifiers are literal
## constants in this file, so nothing is concatenated from untrusted input.
##
## WB0 removed schema creation from this class: Migrations (server/scripts/
## migrations.gd, extended by WB1) now owns the schema, and Bootstrap runs it.

const DB_PATH := "user://mmorpg_server.db"
## 0 = quiet, 1 = normal, 2 = verbose, 3 = very verbose.
const VERBOSITY := 0

var db: SQLite
var is_open := false
## Overridable with the server `--db <path>` flag (worktree isolation).
var db_path := DB_PATH


func _ready() -> void:
	open()


func open() -> bool:
	_ensure_parent_dir()
	db = SQLite.new()
	db.path = db_path
	# Enable FK enforcement (accounts <- characters).
	db.foreign_keys = true
	db.verbosity_level = VERBOSITY
	if not db.open_db():
		push_error("[db] cannot open %s: %s" % [db_path, db.error_message])
		return false
	is_open = true
	print("[db] opened %s" % _display_path())
	return true


func close() -> void:
	if db != null:
		db.close_db()
	is_open = false


func _ensure_parent_dir() -> void:
	if db_path.begins_with("user://") or db_path.begins_with("res://"):
		return
	var parent := db_path.get_base_dir()
	if parent.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(parent)


func _display_path() -> String:
	if db_path.begins_with("user://"):
		return ProjectSettings.globalize_path(db_path)
	return db_path


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


## create_table passthrough used by Migrations (schema is no longer created here).
func create_table(table_name: String, columns: Dictionary) -> bool:
	return db.create_table(table_name, columns)
