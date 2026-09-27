class_name DataTables
extends RefCounted
## Static data-table loader + startup validator (S-D-3).
##
## Every workbench owns its own file under `shared/data/tables/*.json`; this
## loader only globs the directory, so no two branches ever edit a shared
## manifest and no merge conflict is possible on table registration. Table values
## stay data, not code: tuning them needs no recompile.
##
## File contract (schema embedded in the file so a new workbench can add a table
## without editing this loader):
##
##   {
##     "table": "<name>",        // must equal the file's basename
##     "version": 1,             // positive integer, bump on breaking shape change
##     "comment": "...",         // optional, free text, ignored by the validator
##     "primary_key": "id",      // optional, only for "rows" tables
##     "fields": { "<field>": <field-spec>, ... },
##     "values": { "<field>": <value>, ... }   // exactly one of:
##     "rows":   [ { "<field>": <value>, ... } ]  // ... these two shapes
##   }
##
## Field spec: {"type": one of number|int|string|bool|array|object|any,
##              "required": bool (default true), "nullable": bool (default false),
##              "min"/"max": number, "length"/"min_length"/"max_length": int,
##              "enum": [...], "items": <field-spec> (array), "fields": {...} (object)}
##
## `validate()` is the startup check: Bootstrap runs it before the world opens
## and refuses to start on any problem. WB2/WB3/WB5 add their own table files in
## the same shape (abilities.json, classes.json, items.json, zones.json, ...) and
## extend `_validate_references()` with cross-table checks when they need them.
##
## The legacy Protocol numeric constants (MOVE_SPEED, MELEE_DAMAGE, MOB_*, ...)
## are frozen and deliberately NOT deleted yet: `world.json`, `player_base.json`
## and `mobs.json` mirror them so a later workbench can switch each consumer over
## to DataTables and then drop the constant in a contract change.

const TABLES_DIR := "res://shared/data/tables"
const SUPPORTED_TYPES: Array[String] = ["number", "int", "string", "bool", "array", "object", "any"]


## Returns {table_name: parsed_variant} for every *.json in the directory.
## Malformed or unreadable files are reported and skipped (never crash startup);
## `validate()` then refuses to start because the table is missing.
static func load_all(dir_path: String = TABLES_DIR) -> Dictionary:
	var out: Dictionary = {}
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("[data] cannot open table directory %s" % dir_path)
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".json"):
			var parsed: Variant = _read_json(dir_path.path_join(name))
			if parsed != null:
				out[name.get_basename()] = parsed
		name = dir.get_next()
	dir.list_dir_end()
	return out


## Loads a single table by name, or null when it is missing/invalid JSON.
static func load_table(table_name: String, dir_path: String = TABLES_DIR) -> Variant:
	return load_all(dir_path).get(table_name, null)


## Startup validation hook. Returns human-readable problems; empty means OK.
static func validate(tables: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	if tables.is_empty():
		problems.append("no data tables found under %s" % TABLES_DIR)
		return problems
	for name: String in tables.keys():
		_validate_table(name, tables[name], problems)
	_validate_references(tables, problems)
	return problems


# --- per-table validation ---------------------------------------------------

static func _validate_table(name: String, table: Variant, problems: Array[String]) -> void:
	if typeof(table) != TYPE_DICTIONARY:
		problems.append("%s: root must be a JSON object" % name)
		return
	var t: Dictionary = table
	if String(t.get("table", "")) != name:
		problems.append("%s: 'table' must equal the file name" % name)

	var version: Variant = t.get("version", null)
	if typeof(version) != TYPE_FLOAT and typeof(version) != TYPE_INT:
		problems.append("%s: 'version' must be a positive integer" % name)
	elif int(version) < 1:
		problems.append("%s: 'version' must be >= 1" % name)

	var fields: Variant = t.get("fields", null)
	if typeof(fields) != TYPE_DICTIONARY or (fields as Dictionary).is_empty():
		problems.append("%s: 'fields' must be a non-empty object" % name)
		return
	var specs: Dictionary = fields
	for field_name: String in specs.keys():
		_validate_field_spec(name, field_name, specs[field_name], problems)

	var values: Variant = t.get("values", null)
	var rows: Variant = t.get("rows", null)
	if values != null and rows != null:
		problems.append("%s: use either 'values' or 'rows', not both" % name)
		return
	if values != null:
		_validate_object(name, "<values>", values, specs, problems)
		return
	if rows == null:
		problems.append("%s: must contain 'values' or 'rows'" % name)
		return
	if typeof(rows) != TYPE_ARRAY:
		problems.append("%s: 'rows' must be an array" % name)
		return

	var primary_key := String(t.get("primary_key", ""))
	var seen: Dictionary = {}
	var row_array: Array = rows
	for i in row_array.size():
		var label := "rows[%d]" % i
		var row: Variant = row_array[i]
		if typeof(row) != TYPE_DICTIONARY:
			problems.append("%s: %s must be an object" % [name, label])
			continue
		_validate_object(name, label, row, specs, problems)
		if not primary_key.is_empty() and (row as Dictionary).has(primary_key):
			var key := str((row as Dictionary)[primary_key])
			if seen.has(key):
				problems.append("%s: %s duplicate %s='%s'" % [name, label, primary_key, key])
			seen[key] = true


static func _validate_field_spec(table: String, field_name: String, spec: Variant, problems: Array[String]) -> void:
	if typeof(spec) != TYPE_DICTIONARY:
		problems.append("%s.%s: field spec must be an object" % [table, field_name])
		return
	var s: Dictionary = spec
	var type_name := String(s.get("type", ""))
	if not SUPPORTED_TYPES.has(type_name):
		problems.append("%s.%s: unsupported type '%s' (expected %s)" % [
			table, field_name, type_name, ", ".join(SUPPORTED_TYPES)])
	if type_name == "array" and not s.has("items"):
		problems.append("%s.%s: array field needs 'items'" % [table, field_name])
	if type_name == "object" and not s.has("fields"):
		problems.append("%s.%s: object field needs 'fields'" % [table, field_name])


static func _validate_object(
		table: String, label: String, value: Variant, specs: Dictionary, problems: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		problems.append("%s: %s must be an object" % [table, label])
		return
	var obj: Dictionary = value
	for field_name: String in specs.keys():
		var spec_value: Variant = specs[field_name]
		if typeof(spec_value) != TYPE_DICTIONARY:
			# _validate_field_spec already reported the malformed spec; do not
			# crash on the typed access below.
			continue
		var spec: Dictionary = spec_value
		if not obj.has(field_name):
			if bool(spec.get("required", true)):
				problems.append("%s: %s missing required field '%s'" % [table, label, field_name])
			continue
		_validate_value(table, "%s.%s" % [label, field_name], obj[field_name], spec, problems)
	for key: String in obj.keys():
		if not specs.has(key) and not key.begins_with("_"):
			problems.append("%s: %s has unknown field '%s'" % [table, label, key])


static func _validate_value(
		table: String, label: String, value: Variant, spec: Dictionary, problems: Array[String]) -> void:
	if value == null:
		if not bool(spec.get("nullable", false)):
			problems.append("%s: %s is null but not nullable" % [table, label])
		return

	var type_name := String(spec.get("type", "any"))
	if spec.has("enum"):
		var allowed: Variant = spec["enum"]
		if typeof(allowed) == TYPE_ARRAY and not (allowed as Array).has(value):
			problems.append("%s: %s='%s' is not in %s" % [table, label, str(value), str(allowed)])

	match type_name:
		"any":
			pass
		"number":
			if not _is_number(value):
				problems.append("%s: %s must be a number" % [table, label])
				return
			_check_range(table, label, float(value), spec, problems)
		"int":
			if not _is_number(value) or float(value) != floor(float(value)):
				problems.append("%s: %s must be an integer" % [table, label])
				return
			_check_range(table, label, float(value), spec, problems)
		"string":
			if typeof(value) != TYPE_STRING:
				problems.append("%s: %s must be a string" % [table, label])
				return
			_check_length(table, label, (value as String).length(), spec, problems)
		"bool":
			if typeof(value) != TYPE_BOOL:
				problems.append("%s: %s must be a boolean" % [table, label])
		"array":
			if typeof(value) != TYPE_ARRAY:
				problems.append("%s: %s must be an array" % [table, label])
				return
			var arr: Array = value
			_check_length(table, label, arr.size(), spec, problems)
			var items: Variant = spec.get("items", {})
			if typeof(items) == TYPE_DICTIONARY:
				for i in arr.size():
					_validate_value(table, "%s[%d]" % [label, i], arr[i], items, problems)
		"object":
			var sub: Variant = spec.get("fields", {})
			if typeof(sub) == TYPE_DICTIONARY:
				_validate_object(table, label, value, sub, problems)
		_:
			pass


## Cross-table reference checks. Empty today (WB1 ships no referencing table);
## WB2/WB3/WB5 append their checks here (e.g. abilities.class_id -> classes.id).
static func _validate_references(_tables: Dictionary, _problems: Array[String]) -> void:
	pass


static func _check_range(table: String, label: String, value: float, spec: Dictionary, problems: Array[String]) -> void:
	if spec.has("min") and value < float(spec["min"]):
		problems.append("%s: %s=%s is below min %s" % [table, label, str(value), str(spec["min"])])
	if spec.has("max") and value > float(spec["max"]):
		problems.append("%s: %s=%s is above max %s" % [table, label, str(value), str(spec["max"])])


static func _check_length(table: String, label: String, size: int, spec: Dictionary, problems: Array[String]) -> void:
	if spec.has("length") and size != int(spec["length"]):
		problems.append("%s: %s must have length %d (got %d)" % [table, label, int(spec["length"]), size])
	if spec.has("min_length") and size < int(spec["min_length"]):
		problems.append("%s: %s is shorter than min_length %d" % [table, label, int(spec["min_length"])])
	if spec.has("max_length") and size > int(spec["max_length"]):
		problems.append("%s: %s is longer than max_length %d" % [table, label, int(spec["max_length"])])


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT


static func _read_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[data] cannot open %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		push_error("[data] invalid JSON in %s" % path)
	return parsed
