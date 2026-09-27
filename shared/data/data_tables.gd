class_name DataTables
extends RefCounted
## Static data-table loader (S-D-3).
##
## Every workbench owns its own file under `shared/data/tables/*.json`; this
## loader only globs the directory, so no two branches ever edit a shared
## manifest and no merge conflict is possible on table registration. Table values
## stay data, not code, so tuning them needs no recompile.
##
## `validate()` is the startup-check seam: WB1 fills it in and runs it from
## Bootstrap before the world opens, refusing to start on a malformed table.

const TABLES_DIR := "res://shared/data/tables"


## Returns {table_name: parsed_variant} for every *.json in the directory.
## Malformed or unreadable files are reported and skipped (never crash startup).
static func load_all(dir_path: String = TABLES_DIR) -> Dictionary:
	var out: Dictionary = {}
	var dir := DirAccess.open(dir_path)
	if dir == null:
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


## Startup validation hook. Returns human-readable problems; empty means OK.
## WB1 replaces the body with real field/reference checks.
static func validate(_tables: Dictionary) -> Array[String]:
	return []


static func _read_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[data] cannot open %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		push_error("[data] invalid JSON in %s" % path)
	return parsed
