class_name Migrations
extends RefCounted
## Sequential schema migrations (S-D-1).
##
## `create_table` only creates when the table is missing, so schema changes
## used to mean "edit _create_schema and delete the DB". This framework installs
## a `schema_version` table, then applies every migration with seq >
## current_version in order, recording each one. A failed migration refuses
## startup.
##
## Reserved sequence ranges (WB0 fixes these so parallel branches never collide):
##   0001        baseline (pre-WB0 schema snapshot, idempotent for existing DBs)
##   0002-0099   WB1 data / persistence / backup
##   0100-0199   WB3 items / inventory
##   0200-0299   WB2 abilities / combat
##   0300-0399   WB5 zones / instances
##   0400+       other / unassigned
## Each workbench adds `m_<seq>_<slug>.gd`-style steps inside its own range and
## appends them to `steps()` below. Never reorder or edit an applied step.

const SEQ_RANGES := {
	"0001": "baseline",
	"0002-0099": "WB1 data/persistence/backup",
	"0100-0199": "WB3 items/inventory",
	"0200-0299": "WB2 abilities/combat",
	"0300-0399": "WB5 zones/instances",
	"0400+": "other",
}

var db: DBService


## Runs all pending migrations. Returns false if the schema could not be brought
## to the latest version (the caller must refuse to start).
func run(p_db: DBService) -> bool:
	db = p_db
	if not _ensure_version_table():
		return false
	var current := _current_version()
	for step: Dictionary in steps():
		var seq := int(step.get("seq", 0))
		if seq <= current:
			continue
		var slug := String(step.get("slug", "?"))
		print("[migrations] applying %04d_%s" % [seq, slug])
		var fn: Callable = step.get("fn")
		if not fn.is_valid() or not bool(fn.call()):
			push_error("[migrations] %04d_%s failed; refusing to start" % [seq, slug])
			return false
		if not _set_version(seq):
			return false
	print("[migrations] schema at version %d" % _current_version())
	return true


## Ordered, append-only migration list.
func steps() -> Array:
	return [
		{"seq": 1, "slug": "baseline", "fn": Callable(self, "_m_0001_baseline")},
	]


# --- migrations -------------------------------------------------------------

## Baseline: the exact schema the pre-WB0 code created. Idempotent, so it also
## upgrades an existing DB that already has accounts/characters but no
## schema_version table.
func _m_0001_baseline() -> bool:
	var ok := true
	if not _table_exists("accounts"):
		if not db.create_table("accounts", {
			"id": {"data_type": "int", "primary_key": true, "auto_increment": true, "not_null": true},
			"username": {"data_type": "text", "not_null": true, "unique": true},
			"password_hash": {"data_type": "text", "not_null": true},
			"salt": {"data_type": "text", "not_null": true},
			"created_at": {"data_type": "text", "not_null": true, "default": "''"},
		}):
			push_error("[migrations] create_table(accounts) failed: %s" % db.db.error_message)
			ok = false
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
			push_error("[migrations] create_table(characters) failed: %s" % db.db.error_message)
			ok = false
	return ok


# --- version bookkeeping ----------------------------------------------------

func _ensure_version_table() -> bool:
	return db.create_table("schema_version", {
		"version": {"data_type": "int", "primary_key": true, "not_null": true},
		"applied_at": {"data_type": "text", "not_null": true, "default": "''"},
	})


func _current_version() -> int:
	var rows := db.select("SELECT MAX(version) AS v FROM schema_version;")
	if rows.is_empty():
		return 0
	var value: Variant = rows[0].get("v", null)
	if value == null:
		return 0
	return int(value)


func _set_version(seq: int) -> bool:
	return db.execute(
		"INSERT INTO schema_version(version, applied_at) VALUES(?, ?);",
		[seq, Time.get_datetime_string_from_system(true)])


func _table_exists(table_name: String) -> bool:
	var rows := db.select("SELECT name FROM sqlite_master WHERE type='table' AND name=?;", [table_name])
	return not rows.is_empty()
