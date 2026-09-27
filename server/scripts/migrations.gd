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
## The whole chain runs inside one transaction: either every pending step lands
## with its version row, or nothing does (SQLite DDL is transactional). A failure
## therefore leaves the database exactly as it was and the server refuses to
## start, so an operator can fix the data/code and retry with no partial schema.
##
## Reserved sequence ranges (WB0 fixes these so parallel branches never collide):
##   0001        baseline (pre-WB0 schema snapshot, idempotent for existing DBs)
##   0002-0099   WB1 data / persistence / backup
##   0100-0199   WB3 items / inventory
##   0200-0299   WB2 abilities / combat
##   0300-0399   WB5 zones / instances
##   0400+       other / unassigned
## Each workbench adds `m_<seq>_<slug>.gd`-style steps inside its own range and
## appends them to `steps()` below. Never reorder or edit an applied step: the
## list is append-only, and `run()` refuses to start if it is not strictly
## increasing.

const SEQ_RANGES := {
	"0001": "baseline",
	"0002-0099": "WB1 data/persistence/backup",
	"0100-0199": "WB3 items/inventory",
	"0200-0299": "WB2 abilities/combat",
	"0300-0399": "WB5 zones/instances",
	"0400+": "other",
}

var db: DBService
## Drill-only: when set to a migration seq, `run()` makes that step fail so the
## gate can demonstrate "a failed migration refuses startup". Set from Bootstrap
## via the server `--migrate-fail-at <seq>` user arg. Never set in production.
var force_fail_at := -1


## Runs all pending migrations. Returns false if the schema could not be brought
## to the latest version (the caller must refuse to start).
func run(p_db: DBService) -> bool:
	db = p_db
	if db == null or not db.is_open:
		push_error("[migrations] database is not open; refusing to start")
		return false
	if not _steps_strictly_increasing():
		push_error("[migrations] step sequence is not strictly increasing; refusing to start")
		return false

	if not db.begin_transaction():
		push_error("[migrations] cannot begin migration transaction; refusing to start")
		return false
	if not _ensure_version_table():
		db.rollback_transaction()
		return false

	var current := _current_version()
	for step: Dictionary in steps():
		var seq := int(step.get("seq", 0))
		if seq <= current:
			continue
		var slug := String(step.get("slug", "?"))
		if force_fail_at > 0 and seq == force_fail_at:
			push_error("[migrations] %04d_%s forced failure (drill); refusing to start" % [seq, slug])
			db.rollback_transaction()
			return false
		print("[migrations] applying %04d_%s" % [seq, slug])
		var fn: Callable = step.get("fn")
		if not fn.is_valid() or not bool(fn.call()):
			push_error("[migrations] %04d_%s failed; rolling back and refusing to start" % [seq, slug])
			db.rollback_transaction()
			return false
		if not _set_version(seq):
			push_error("[migrations] could not record version %d; refusing to start" % seq)
			db.rollback_transaction()
			return false

	if not db.commit_transaction():
		push_error("[migrations] cannot commit migration transaction; refusing to start")
		db.rollback_transaction()
		return false
	print("[migrations] schema at version %d" % _current_version())
	return true


## Highest seq defined in `steps()`. Used by Bootstrap to decide whether an
## existing database needs a pre-migration backup.
func latest_seq() -> int:
	var latest := 0
	for step: Dictionary in steps():
		latest = maxi(latest, int(step.get("seq", 0)))
	return latest


## Ordered, append-only migration list.
func steps() -> Array:
	return [
		{"seq": 1, "slug": "baseline", "fn": Callable(self, "_m_0001_baseline")},
		{"seq": 2, "slug": "characters_account_index", "fn": Callable(self, "_m_0002_characters_account_index")},
		{"seq": 100, "slug": "wb3_inventory", "fn": Callable(self, "_m_0100_wb3_inventory")},
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


## 0002 (WB1): index for the per-account character list. Additive and idempotent;
## exercises the append-only chain for both a clean DB (0 -> 1 -> 2) and a
## pre-WB0 DB that already has accounts/characters but no schema_version.
func _m_0002_characters_account_index() -> bool:
	var ok := db.execute("CREATE INDEX IF NOT EXISTS idx_characters_account ON characters(account_id);")
	if not ok:
		push_error("[migrations] create index failed: %s" % db.db.error_message)
	return ok


## 0100 (WB3): item/inventory tables (S-G-5). `character_inventory` is the
## per-character anchor whose presence means "this character's starter kit was
## already granted" - so an intentionally emptied inventory is never silently
## re-granted. `inventory_items` and `character_equipment` store the owned stacks;
## (character_id, slot) is unique so a slot can never hold two stacks. Raw DDL is
## used because godot-sqlite's create_table cannot express a composite key.
func _m_0100_wb3_inventory() -> bool:
	var statements: Array[String] = [
		"CREATE TABLE IF NOT EXISTS character_inventory ("
		+ "character_id INTEGER PRIMARY KEY NOT NULL, "
		+ "initialized INTEGER NOT NULL DEFAULT 0, "
		+ "FOREIGN KEY(character_id) REFERENCES characters(id));",
		"CREATE TABLE IF NOT EXISTS inventory_items ("
		+ "id INTEGER PRIMARY KEY AUTOINCREMENT, "
		+ "character_id INTEGER NOT NULL, "
		+ "slot INTEGER NOT NULL, "
		+ "item_id TEXT NOT NULL, "
		+ "stack INTEGER NOT NULL, "
		+ "bound INTEGER NOT NULL DEFAULT 0, "
		+ "UNIQUE(character_id, slot), "
		+ "FOREIGN KEY(character_id) REFERENCES characters(id));",
		"CREATE TABLE IF NOT EXISTS character_equipment ("
		+ "character_id INTEGER NOT NULL, "
		+ "slot INTEGER NOT NULL, "
		+ "item_id TEXT NOT NULL, "
		+ "stack INTEGER NOT NULL, "
		+ "bound INTEGER NOT NULL DEFAULT 0, "
		+ "PRIMARY KEY(character_id, slot), "
		+ "FOREIGN KEY(character_id) REFERENCES characters(id));",
	]
	for sql: String in statements:
		if not db.execute(sql):
			push_error("[migrations] WB3 inventory DDL failed: %s" % db.db.error_message)
			return false
	return true


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


## Append-only guard: a duplicate, out-of-order or empty step is a programming
## error that would silently skip migrations, so it aborts startup instead.
func _steps_strictly_increasing() -> bool:
	var previous := 0
	for step: Dictionary in steps():
		var seq := int(step.get("seq", 0))
		if seq <= previous:
			return false
		previous = seq
	return true
