class_name Item
extends RefCounted
## Static item definition (S-G-5).
##
## Loaded from shared/data/tables/items.json through the WB1 DataTables loader, so
## item numbers stay data and tuning them needs no recompile. Both ends can resolve
## an item id to its kind / equip slot / stack limit / bind rule / stat modifiers;
## only the server decides what a character actually owns.
##
## The table is read once and memoized: callers use `Item.by_id()` freely.

var id: String = ""
var display_name: String = ""
## Protocol.ItemKind value.
var kind: int = Protocol.ItemKind.NONE
var rarity: String = "common"
## Maximum stack size; Protocol.ITEM_STACK_MAX is the hard ceiling enforced by the
## table validation, this is the per-item value.
var max_stack: int = 1
## True when the item binds to the character (on pickup / on equip).
var bind: bool = false
## Protocol.EquipSlot value, or -1 when the item cannot be equipped.
var equip_slot: int = -1
## Protocol.Stat name (String) -> int modifier. Missing stats are treated as 0.
var stats: Dictionary = {}

static var _cache: Dictionary = {}


## item id -> Item for every row in items.json (empty when the table is missing).
static func all() -> Dictionary:
	if _cache.is_empty():
		var table: Variant = DataTables.load_table("items")
		if typeof(table) == TYPE_DICTIONARY:
			for row: Variant in (table as Dictionary).get("rows", []):
				if typeof(row) == TYPE_DICTIONARY:
					var item := _from_row(row)
					if not item.id.is_empty():
						_cache[item.id] = item
	return _cache


## Resolves one item id, or null when it is not a known item.
static func by_id(item_id: String) -> Item:
	return all().get(item_id)


static func _from_row(row: Dictionary) -> Item:
	var item := Item.new()
	item.id = String(row.get("id", ""))
	item.display_name = String(row.get("name", item.id))
	item.kind = int(row.get("kind", Protocol.ItemKind.NONE))
	item.rarity = String(row.get("rarity", "common"))
	item.max_stack = maxi(1, int(row.get("max_stack", 1)))
	item.bind = bool(row.get("bind", false))
	var raw_slot: Variant = row.get("equip_slot", null)
	item.equip_slot = -1 if raw_slot == null else int(raw_slot)
	var raw_stats: Variant = row.get("stats", {})
	if typeof(raw_stats) == TYPE_DICTIONARY:
		item.stats = (raw_stats as Dictionary).duplicate()
	return item


func is_equippable() -> bool:
	return equip_slot >= 0 and (kind == Protocol.ItemKind.WEAPON or kind == Protocol.ItemKind.ARMOR)


func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"kind": kind,
		"rarity": rarity,
		"max_stack": max_stack,
		"bind": bind,
		"equip_slot": equip_slot,
		"stats": stats.duplicate(),
	}
