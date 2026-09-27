class_name Bootstrap
extends Node
## Pre-world startup hook (S-D-1, S-D-2, S-D-3, S-O-5). Runs before the world
## opens and refuses to start on failure:
##
##   1. if an existing DB has pending migrations, copy it aside first (S-O-5);
##   2. run the sequential migration chain (S-D-1) - all-or-nothing;
##   3. load and validate shared/data/tables/*.json (S-D-3).
##
## The DB access happens here on the main thread, like every other godot-sqlite
## call in the project.

## Rolling pre-migration backups kept next to the DB (see _pre_migration_backup).
const KEEP_PREMIGRATION_BACKUPS := 3

## Drill-only user arg parsed by Bootstrap: makes the named migration step fail so
## the gate can show that a failed migration refuses startup. Never used in
## normal operation.
const FAIL_AT_ARG := "--migrate-fail-at"


func run(db: DBService) -> bool:
	if db == null or not db.is_open:
		push_error("[bootstrap] database is not open; refusing to start")
		return false

	var migrations := Migrations.new()
	migrations.force_fail_at = _forced_failure_seq()

	# Back up the pre-upgrade state only when there is something to protect and
	# migrations are actually pending, so healthy restarts stay cheap.
	if _has_existing_schema(db) and _schema_version(db) < migrations.latest_seq():
		_pre_migration_backup(db)

	if not migrations.run(db):
		push_error("[bootstrap] migrations failed; refusing to start")
		return false

	var tables := DataTables.load_all()
	var problems := DataTables.validate(tables)
	if not problems.is_empty():
		for problem: String in problems:
			push_error("[bootstrap] data table: %s" % problem)
		push_error("[bootstrap] static data invalid; refusing to start")
		return false
	print("[bootstrap] data tables loaded: %d (%s)" % [tables.size(), ", ".join(_sorted_keys(tables))])
	return true


# --- pre-migration backup ---------------------------------------------------

func _has_existing_schema(db: DBService) -> bool:
	return not db.select(
		"SELECT name FROM sqlite_master WHERE type='table' AND name='accounts';").is_empty()


func _schema_version(db: DBService) -> int:
	if db.select("SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version';").is_empty():
		return 0
	var rows := db.select("SELECT MAX(version) AS v FROM schema_version;")
	if rows.is_empty():
		return 0
	var value: Variant = rows[0].get("v", null)
	return 0 if value == null else int(value)


## Best-effort copy of the database before an upgrade. Failure is a warning, not
## a startup abort: an un-writable backup location must not take the server down.
func _pre_migration_backup(db: DBService) -> void:
	db.checkpoint()
	var src := db.global_path()
	if not FileAccess.file_exists(src):
		return
	var dir := src.get_base_dir().path_join("backups")
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		push_warning("[bootstrap] cannot create backup dir %s; continuing without backup" % dir)
		return
	var stamp := Time.get_datetime_string_from_system(true)\
		.replace("-", "").replace(":", "").replace("T", "-")
	var dst := dir.path_join("%s.%s.premigrate.db" % [src.get_file(), stamp])
	var err := DirAccess.copy_absolute(src, dst)
	if err != OK:
		push_warning("[bootstrap] pre-migration backup failed (%s); continuing" % error_string(err))
		return
	print("[bootstrap] pre-migration backup -> %s" % dst)
	_prune_backups(dir, src.get_file())


func _prune_backups(dir: String, db_file: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	var prefix := db_file + "."
	var matches: Array[String] = []
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not d.current_is_dir() and name.begins_with(prefix) and name.ends_with(".premigrate.db"):
			matches.append(name)
		name = d.get_next()
	d.list_dir_end()
	matches.sort()
	while matches.size() > KEEP_PREMIGRATION_BACKUPS:
		var oldest := String(matches.pop_front())
		d.remove(oldest)


# --- helpers ----------------------------------------------------------------

func _forced_failure_seq() -> int:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var arg: String = args[i]
		if arg == FAIL_AT_ARG and i + 1 < args.size():
			return int(args[i + 1])
		if arg.begins_with(FAIL_AT_ARG + "="):
			return int(arg.substr(FAIL_AT_ARG.length() + 1))
	return -1


func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
