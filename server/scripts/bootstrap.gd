class_name Bootstrap
extends Node
## Pre-world startup hook (S-D-1, S-D-2, S-O-5). WB0 provides the seam: it runs
## migrations and the static-data validation, and refuses to start on failure.
## WB1 extends it with backups/restore drills and richer table validation.

func run(db: DBService) -> bool:
	var migrations := Migrations.new()
	if not migrations.run(db):
		push_error("[bootstrap] migrations failed; refusing to start")
		return false

	var tables := DataTables.load_all()
	var problems := DataTables.validate(tables)
	if not problems.is_empty():
		for problem: String in problems:
			push_error("[bootstrap] data table: %s" % problem)
		return false
	print("[bootstrap] data tables loaded: %d" % tables.size())
	return true
