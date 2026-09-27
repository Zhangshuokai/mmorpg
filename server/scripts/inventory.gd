class_name InventoryService
extends Node
## Server-authoritative inventory + equipment (S-G-5).
##
## Owns the per-character in-memory mirror and the policy. Every c2s_move_item /
## c2s_equip_item / c2s_unequip_item arrives from IntentRouter with the sender's
## peer id, is resolved to the character that peer is currently playing, decided
## through the shared Inventory rules, persisted and answered with an
## s2c_inventory snapshot. A rejected intent still gets a snapshot carrying
## {"op","ok","reason"} so the client re-syncs to the authoritative state and
## cannot keep a locally guessed one.
##
## All DB access is on the main thread (godot-sqlite is not thread safe): both the
## router handler and `_process` run there.

## Starting kit granted the first time a character's inventory is loaded. Ids must
## exist in shared/data/tables/items.json; unknown ids are skipped with a warning
## so a bad table row cannot abort the grant.
const STARTER_KIT: Array = [
	{"slot": 0, "item_id": "worn_sword", "count": 1},
	{"slot": 1, "item_id": "leather_vest", "count": 1},
	{"slot": 2, "item_id": "iron_helm", "count": 1},
	{"slot": 3, "item_id": "traveler_boots", "count": 1},
	{"slot": 4, "item_id": "cloth_legs", "count": 1},
	{"slot": 5, "item_id": "minor_healing_potion", "count": 5},
]

var world: WorldService
var persistence: PersistenceInventory

## character_id -> Inventory (the live mirror; the DB is the durable copy).
var _cache: Dictionary = {}
## peer_id -> character_id, for the sessions currently in the world.
var _peer_char: Dictionary = {}
## character_id -> snapshot sequence, for diagnostics and ordering.
var _seq: Dictionary = {}
## character_id -> {"op","ok","reason"} of the last processed intent.
var _last: Dictionary = {}


## Pushes the authoritative snapshot to every player that just entered the world.
## Done here (not in session_flow) so WB3 owns its sync without editing the
## session hot file; session_flow only knows about `world.sessions`.
func _process(_delta: float) -> void:
	if world == null:
		return
	for peer: int in world.sessions.keys():
		var sheet: CharacterSheet = world.sessions[peer]
		if sheet == null or int(_peer_char.get(peer, -1)) == sheet.id:
			continue
		_peer_char[peer] = sheet.id
		_last[sheet.id] = {"op": "sync", "ok": true, "reason": ""}
		_send(peer, sheet.id, _inventory_for_char(sheet.id))
	for peer: int in _peer_char.keys():
		if not world.sessions.has(peer):
			_peer_char.erase(peer)


# --- c2s handlers (registered by main.gd's WB3 wiring block) -----------------

func handle_move(sender: int, from_slot: int, to_slot: int) -> void:
	var inv := _inventory_for_peer(sender)
	if inv == null:
		return
	_apply(sender, "move", inv, inv.move(from_slot, to_slot))


func handle_equip(sender: int, inv_slot: int, equip_slot: int) -> void:
	var inv := _inventory_for_peer(sender)
	if inv == null:
		return
	_apply(sender, "equip", inv, inv.equip(inv_slot, equip_slot))


func handle_unequip(sender: int, equip_slot: int, inv_slot: int) -> void:
	var inv := _inventory_for_peer(sender)
	if inv == null:
		return
	_apply(sender, "unequip", inv, inv.unequip(equip_slot, inv_slot))


# --- apply / persist / broadcast ---------------------------------------------

func _apply(sender: int, op: String, inv: Inventory, reason: String) -> void:
	var char_id := int(_peer_char.get(sender, -1))
	if char_id < 0:
		return
	var ok := reason.is_empty()
	if ok and not persistence.persist(char_id, inv):
		# The DB is authoritative: drop the in-memory guess and reload so the next
		# snapshot matches what is actually stored.
		ok = false
		reason = "persist failed"
		inv = persistence.load_inventory(char_id)
		_cache[char_id] = inv
	if not ok:
		print("[inventory] rejected %s for character %d from peer %d: %s" % [op, char_id, sender, reason])
	_last[char_id] = {"op": op, "ok": ok, "reason": reason}
	_send(sender, char_id, inv)


func _send(peer_id: int, char_id: int, inv: Inventory) -> void:
	_seq[char_id] = int(_seq.get(char_id, 0)) + 1
	var snapshot := inv.to_snapshot()
	snapshot["char_id"] = char_id
	snapshot["seq"] = int(_seq[char_id])
	snapshot["last"] = _last.get(char_id, {"op": "sync", "ok": true, "reason": ""})
	Net.s2c_inventory.rpc_id(peer_id, snapshot)


# --- loading -----------------------------------------------------------------

func _inventory_for_peer(peer_id: int) -> Inventory:
	if world == null:
		return null
	var sheet: CharacterSheet = world.sessions.get(peer_id)
	if sheet == null:
		return null
	return _inventory_for_char(sheet.id)


func _inventory_for_char(char_id: int) -> Inventory:
	var cached: Inventory = _cache.get(char_id)
	if cached != null:
		return cached
	var inv: Inventory
	if persistence.exists(char_id):
		inv = persistence.load_inventory(char_id)
	else:
		inv = _starter_inventory()
		if not persistence.create_with(char_id, inv):
			push_error("[inventory] could not initialize character %d" % char_id)
	_cache[char_id] = inv
	return inv


func _starter_inventory() -> Inventory:
	var inv := Inventory.new()
	for entry: Dictionary in STARTER_KIT:
		var item_id := String(entry.get("item_id", ""))
		var def := Item.by_id(item_id)
		if def == null:
			push_warning("[inventory] starter item '%s' is missing from items.json" % item_id)
			continue
		var stack := Inventory.Stack.new()
		stack.item_id = item_id
		stack.count = clampi(int(entry.get("count", 1)), 1, def.max_stack)
		stack.bound = def.bind
		inv.set_slot(int(entry.get("slot", 0)), stack)
	return inv
