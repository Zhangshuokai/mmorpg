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
## migrations.gd, extended by WB1) owns the schema, and Bootstrap runs it.
## WB1 added the durability layer (S-D-2): WAL + synchronous=FULL so a committed
## critical write survives a killed process, a small transaction helper used by
## PersistenceService, and a checkpoint used before file-level backups.

const DB_PATH := "user://mmorpg_server.db"
## 0 = quiet, 1 = normal, 2 = verbose, 3 = very verbose.
const VERBOSITY := 0

var db: SQLite
var is_open := false
var in_transaction := false
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
	_apply_pragmas()
	is_open = true
	print("[db] opened %s (journal=wal, synchronous=full)" % _display_path())
	return true


## Durability/robustness pragmas (S-D-2). WAL keeps readers from blocking the
## writer and leaves a crash-recoverable log; synchronous=FULL fsyncs every
## commit, so a write that returned success is on disk even if the process is
## killed immediately afterwards. Must run outside any transaction.
func _apply_pragmas() -> void:
	db.query("PRAGMA journal_mode=WAL;")
	db.query("PRAGMA synchronous=FULL;")
	db.query("PRAGMA busy_timeout=5000;")
	db.query("PRAGMA foreign_keys=ON;")


func close() -> void:
	if db != null and is_open:
		# Fold the WAL back into the main file so a file-level backup / copy of a
		# cleanly stopped server is a single self-contained .db.
		checkpoint()
		db.close_db()
	is_open = false


func _ensure_parent_dir() -> void:
	if db_path.begins_with("user://") or db_path.begins_with("res://"):
		return
	var parent := db_path.get_base_dir()
	if parent.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(_to_absolute(parent))


## Absolute filesystem path (used by Bootstrap's pre-migration backup and by
## scripts/backup.ps1 to locate the file). A relative `--db` path is resolved the
## same way godot-sqlite resolves it: against the project directory (res://).
func global_path() -> String:
	return _to_absolute(db_path)


func _display_path() -> String:
	return _to_absolute(db_path)


func _to_absolute(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	if path.is_absolute_path():
		return path
	return ProjectSettings.globalize_path("res://" + path)


# --- transactions -----------------------------------------------------------

## Opens a write transaction. Returns true when one is already open (callers must
## not nest; the whole call chain is single-threaded main-thread code).
func begin_transaction(immediate: bool = true) -> bool:
	if in_transaction:
		push_warning("[db] begin_transaction called with a transaction already open")
		return true
	var sql := "BEGIN IMMEDIATE;" if immediate else "BEGIN;"
	if not execute(sql):
		return false
	in_transaction = true
	return true


func commit_transaction() -> bool:
	if not in_transaction:
		return true
	var ok := execute("COMMIT;")
	in_transaction = false
	if not ok:
		execute("ROLLBACK;")
	return ok


func rollback_transaction() -> bool:
	if not in_transaction:
		return true
	in_transaction = false
	return execute("ROLLBACK;")


## Merges the write-ahead log into the main database file. Safe to call at any
## time (a no-op when journal_mode is not WAL); used before file copies/backups.
func checkpoint() -> bool:
	if not is_open:
		return false
	return db.query("PRAGMA wal_checkpoint(TRUNCATE);")


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
