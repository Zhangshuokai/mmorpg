class_name PersistenceInventory
extends Node
## Inventory / equipment persistence (S-G-5), all main-thread godot-sqlite access.
##
## Tables (migration 0100, WB3):
##   character_inventory  one row per character; its presence means the starter
##                        kit was granted, so an emptied inventory is never
##                        re-granted.
##   inventory_items      inventory slot rows (UNIQUE(character_id, slot)).
##   character_equipment  equipped slot rows (PRIMARY KEY(character_id, slot)).
##
## Writes replace a character's whole state inside one transaction: 40 rows is
## trivial, and it makes a move/equip/unequip atomic (S-D-2), so a crash cannot
## persist a half-applied swap.

var db: DBService


## True when this character's inventory has been initialized before.
func exists(character_id: int) -> bool:
	return not db.select(
		"SELECT character_id FROM character_inventory WHERE character_id = ?;",
		[character_id]).is_empty()


## Reads the persisted inventory + equipment for a character (empty Inventory
## when the character has none).
func load_inventory(character_id: int) -> Inventory:
	var inv := Inventory.new()
	for row: Dictionary in db.select(
			"SELECT slot, item_id, stack, bound FROM inventory_items WHERE character_id = ?;",
			[character_id]):
		inv.set_slot(int(row.get("slot", 0)), _stack_from_row(row))
	for row: Dictionary in db.select(
			"SELECT slot, item_id, stack, bound FROM character_equipment WHERE character_id = ?;",
			[character_id]):
		inv.set_equipment(int(row.get("slot", 0)), _stack_from_row(row))
	return inv


## First-ever write: records the anchor row and the initial state atomically.
func create_with(character_id: int, inv: Inventory) -> bool:
	if not db.begin_transaction():
		return false
	var ok := db.execute(
		"INSERT INTO character_inventory(character_id, initialized) VALUES(?, 1);",
		[character_id])
	if ok:
		ok = _replace_rows(character_id, inv)
	if ok:
		ok = db.commit_transaction()
	else:
		db.rollback_transaction()
	return ok


## Atomically replaces the persisted state of an existing character.
func persist(character_id: int, inv: Inventory) -> bool:
	if not db.begin_transaction():
		return false
	var ok := _replace_rows(character_id, inv)
	if ok:
		ok = db.commit_transaction()
	else:
		db.rollback_transaction()
	return ok


# --- helpers -----------------------------------------------------------------

## Delete + reinsert inside the caller's transaction. Returns false without
## committing anything on the first failed statement.
func _replace_rows(character_id: int, inv: Inventory) -> bool:
	if not db.execute("DELETE FROM inventory_items WHERE character_id = ?;", [character_id]):
		return false
	if not db.execute("DELETE FROM character_equipment WHERE character_id = ?;", [character_id]):
		return false
	for slot: int in inv.slots.keys():
		var stack: Inventory.Stack = inv.slots[slot]
		if stack == null or stack.count <= 0:
			continue
		if not db.execute(
			"INSERT INTO inventory_items(character_id, slot, item_id, stack, bound) VALUES(?, ?, ?, ?, ?);",
			[character_id, slot, stack.item_id, stack.count, 1 if stack.bound else 0]):
			return false
	for slot: int in inv.equipment.keys():
		var stack: Inventory.Stack = inv.equipment[slot]
		if stack == null or stack.count <= 0:
			continue
		if not db.execute(
			"INSERT INTO character_equipment(character_id, slot, item_id, stack, bound) VALUES(?, ?, ?, ?, ?);",
			[character_id, slot, stack.item_id, stack.count, 1 if stack.bound else 0]):
			return false
	return true


func _stack_from_row(row: Dictionary) -> Inventory.Stack:
	var stack := Inventory.Stack.new()
	stack.item_id = String(row.get("item_id", ""))
	stack.count = int(row.get("stack", 1))
	stack.bound = int(row.get("bound", 0)) != 0
	return stack
