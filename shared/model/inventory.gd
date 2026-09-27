class_name Inventory
extends RefCounted
## Authoritative inventory + equipment container (S-G-5).
##
## Pure data plus the move/equip/unequip rules. The server runs these functions
## and persists the result; the client only renders the snapshot. Keeping the
## decisions in the shared model means both ends agree on the rules and the server
## stays the only side that can mutate persisted ownership.
##
## Duplication is structurally impossible: every rule moves *existing* Stack
## references, never constructs a stack, so the total item count is conserved.

## One owned stack: which item, how many, and whether it has bound.
class Stack:
	var item_id: String = ""
	var count: int = 1
	var bound: bool = false

	func to_dict() -> Dictionary:
		return {"item_id": item_id, "count": count, "bound": bound}

	func clone() -> Stack:
		var s := Stack.new()
		s.item_id = item_id
		s.count = count
		s.bound = bound
		return s

	static func from_dict(data: Dictionary) -> Stack:
		var s := Stack.new()
		s.item_id = String(data.get("item_id", ""))
		s.count = int(data.get("count", 0))
		s.bound = bool(data.get("bound", false))
		return s


## Server capacity (Protocol.INVENTORY_SLOTS). A slot index outside this is
## rejected by the server even though the RPC gate allows up to
## Protocol.INVENTORY_SLOTS_MAX - that is exactly the "unauthorized move" case.
var capacity: int = Protocol.INVENTORY_SLOTS
## int inventory slot -> Stack.
var slots: Dictionary = {}
## int equip slot (Protocol.EquipSlot) -> Stack.
var equipment: Dictionary = {}

## Canonical "nothing was rejected" reason. Any other string is the rejection.
const OK := ""


func get_slot(slot: int) -> Stack:
	return slots.get(slot)


func set_slot(slot: int, stack: Stack) -> void:
	if stack == null:
		slots.erase(slot)
	else:
		slots[slot] = stack


func clear_slot(slot: int) -> void:
	slots.erase(slot)


func get_equipment(slot: int) -> Stack:
	return equipment.get(slot)


func set_equipment(slot: int, stack: Stack) -> void:
	if stack == null:
		equipment.erase(slot)
	else:
		equipment[slot] = stack


func clear_equipment(slot: int) -> void:
	equipment.erase(slot)


## Total item count across inventory and equipment. Used to prove that a rejected
## or duplicated operation never changes it.
func total_count() -> int:
	var total := 0
	for slot: int in slots.keys():
		total += maxi(0, (slots[slot] as Stack).count)
	for slot: int in equipment.keys():
		total += maxi(0, (equipment[slot] as Stack).count)
	return total


# --- authoritative rules -----------------------------------------------------

## Moves / merges / swaps inside the inventory. Returns OK or a rejection reason;
## never duplicates a stack.
func move(from_slot: int, to_slot: int) -> String:
	if not _valid_slot(from_slot) or not _valid_slot(to_slot):
		return "slot out of range"
	if from_slot == to_slot:
		return "same slot"
	var src: Stack = get_slot(from_slot)
	if src == null:
		return "source slot is empty"
	var dst: Stack = get_slot(to_slot)
	if dst == null:
		set_slot(to_slot, src)
		clear_slot(from_slot)
		return OK
	if dst.item_id == src.item_id:
		var space := _stack_limit(src.item_id) - dst.count
		if space <= 0:
			return "stack is full"
		var moved := mini(space, src.count)
		dst.count += moved
		src.count -= moved
		if src.count <= 0:
			clear_slot(from_slot)
		return OK
	# Different items: swap. Both references stay accounted for exactly once.
	set_slot(from_slot, dst)
	set_slot(to_slot, src)
	return OK


## Equips the item in `inv_slot` into `equip_slot`. A previously equipped item is
## swapped back into the inventory slot. Bind-on-equip is applied here.
func equip(inv_slot: int, equip_slot: int) -> String:
	if not _valid_slot(inv_slot) or not _valid_equip_slot(equip_slot):
		return "slot out of range"
	var src: Stack = get_slot(inv_slot)
	if src == null:
		return "inventory slot is empty"
	var def := Item.by_id(src.item_id)
	if def == null:
		return "unknown item"
	if not def.is_equippable():
		return "item cannot be equipped"
	if def.equip_slot != equip_slot:
		return "item does not fit that equipment slot"
	var current: Stack = get_equipment(equip_slot)
	set_equipment(equip_slot, src)
	if current == null:
		clear_slot(inv_slot)
	else:
		set_slot(inv_slot, current)
	if def.bind:
		src.bound = true
	return OK


## Moves an equipped item back to an empty inventory slot. A swap is refused so an
## equip destination cannot silently overwrite an unrelated stack.
func unequip(equip_slot: int, inv_slot: int) -> String:
	if not _valid_equip_slot(equip_slot) or not _valid_slot(inv_slot):
		return "slot out of range"
	var src: Stack = get_equipment(equip_slot)
	if src == null:
		return "equipment slot is empty"
	if get_slot(inv_slot) != null:
		return "destination slot is occupied"
	set_slot(inv_slot, src)
	clear_equipment(equip_slot)
	return OK


# --- snapshot (WB3 defines the s2c_inventory payload) ------------------------

## Wire shape, arrays only (no Dictionary int keys) so it serializes identically
## on every platform:
##   {capacity, equipment_slots, items:[{slot,item_id,count,bound}],
##    equipment:[{slot,item_id,count,bound}]}
func to_snapshot() -> Dictionary:
	return {
		"capacity": capacity,
		"equipment_slots": Protocol.EQUIP_SLOT_COUNT,
		"items": _sorted_entries(slots),
		"equipment": _sorted_entries(equipment),
	}


static func from_snapshot(snapshot: Dictionary) -> Inventory:
	var inv := Inventory.new()
	inv.capacity = int(snapshot.get("capacity", Protocol.INVENTORY_SLOTS))
	for entry: Variant in snapshot.get("items", []):
		if typeof(entry) == TYPE_DICTIONARY:
			var data: Dictionary = entry
			inv.set_slot(int(data.get("slot", 0)), Stack.from_dict(data))
	for entry: Variant in snapshot.get("equipment", []):
		if typeof(entry) == TYPE_DICTIONARY:
			var data: Dictionary = entry
			inv.set_equipment(int(data.get("slot", 0)), Stack.from_dict(data))
	return inv


static func _sorted_entries(source: Dictionary) -> Array:
	var out: Array = []
	var keys := source.keys()
	keys.sort()
	for slot: int in keys:
		var stack: Stack = source[slot]
		if stack == null or stack.count <= 0:
			continue
		out.append({
			"slot": slot,
			"item_id": stack.item_id,
			"count": stack.count,
			"bound": stack.bound,
		})
	return out


func _valid_slot(slot: int) -> bool:
	return slot >= 0 and slot < capacity


func _valid_equip_slot(slot: int) -> bool:
	return slot >= 0 and slot < Protocol.EQUIP_SLOT_COUNT


func _stack_limit(item_id: String) -> int:
	var def := Item.by_id(item_id)
	return 1 if def == null else maxi(1, def.max_stack)
