extends SceneTree
## GDScript unit-test runner (S-T-1, owned by WB8).
##
##   & $env:GODOT --headless --path server --script tests/run_tests.gd
##
## Godot loads this file by absolute path, so `tests/` can live at the repo root
## (next to `shared/`) instead of inside one of the two projects. It is run under
## the *server* project because the suite also exercises server-side boundary
## logic (CombatService), and the server project registers every shared class_name
## as well.
##
## Discovery: every sibling file matching `*_test.gd` is a test module. A module
## is a plain `extends RefCounted` script exposing
##     func cases() -> Array[Dictionary]
## where each entry is {"name": String, "ok": bool, "detail": String}. That
## mirrors the bot's BotCheck contract: a new workbench adds a file, it never has
## to edit this runner. Exit code is 0 only when every case passes.
##
## Execution happens in `_initialize()` (not `_init()`): the autoload singletons
## (e.g. `Net`) are only registered once the MainLoop is initialised, and the
## server combat module pulls in scripts that reference the `Net` autoload.

func _initialize() -> void:
	var dir := _tests_dir()
	var modules := _discover(dir)
	print("[unit] %d module(s) in %s" % [modules.size(), dir])

	var total := 0
	var failed := 0
	for path: String in modules:
		var module_name := path.get_file().get_basename()
		var results := _run_module(path)
		if results.is_empty():
			failed += 1
			print("[unit]   FAIL %s (could not load module or no cases)" % module_name)
			continue
		for entry: Dictionary in results:
			total += 1
			var name := String(entry.get("name", "?"))
			var ok := bool(entry.get("ok", false))
			var detail := String(entry.get("detail", ""))
			if ok:
				print("[unit]   PASS %s.%s" % [module_name, name])
			else:
				failed += 1
				print("[unit]   FAIL %s.%s (%s)" % [module_name, name, detail])

	print("[unit] %d case(s), %d passed, %d failed" % [total, total - failed, failed])
	if failed == 0:
		print("[unit] RESULT PASS")
		quit(0)
	else:
		print("[unit] RESULT FAIL")
		quit(1)


## Directory of this script. When loaded via `--script <abs path>` Godot reports
## the absolute path as resource_path, which keeps discovery independent of the
## project working directory.
func _tests_dir() -> String:
	var self_script: Script = get_script()
	return self_script.resource_path.get_base_dir()


func _discover(dir: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir)
	if d == null:
		push_error("[unit] cannot open test directory %s" % dir)
		return out
	d.list_dir_begin()
	var file_name := d.get_next()
	while file_name != "":
		if not d.current_is_dir() and file_name.ends_with("_test.gd"):
			out.append(dir.path_join(file_name))
		file_name = d.get_next()
	d.list_dir_end()
	out.sort()
	return out


## Loads one module and returns its raw case array, or an empty array when the
## module is missing/broken (the caller reports that as a failure).
func _run_module(path: String) -> Array:
	var script: Script = load(path)
	if script == null:
		push_error("[unit] failed to load %s" % path)
		return []
	var module: Object = script.new()
	if module == null or not module.has_method("cases"):
		push_error("[unit] %s is not a test module (missing cases())" % path)
		return []
	var results: Array = module.call("cases")
	return results
