class_name BotCheckInventory
extends BotCheck
## Server-authoritative inventory / equipment assertions (S-G-5, WB3).
##
## The runner (bot.gd, owned by WB8) does not know the s2c_inventory payload, so
## this module subscribes to `Net.inventory_received` itself and drives a
## deterministic intent sequence. It never mutates state locally: it only sends
## c2s intents through the normal client path and asserts on the snapshots the
## server decided to send.
##
## Positive: a stack moves, an item equips and unequips, and the total item count
## is conserved across the whole sequence.
## Negative: moving from an empty slot, moving to a slot outside the character
## capacity and equipping into a mismatched slot are all rejected, and the
## authoritative state is byte-for-byte unchanged afterwards.
##
## `--bot-inv-mutate` (optional client user arg): after the checks pass, leave the
## potion in the last slot instead of restoring it. The relogin gate runs the bot
## once with this flag, restarts the server, then runs it again and compares this
## run's "final" state against the next run's "initial" state - which proves the
## state was persisted rather than re-granted from the starter kit.

## A snapshot that never arrives within this window fails its step with a
## timeout detail instead of hanging the run.
const SNAPSHOT_TIMEOUT_USEC := 3_000_000

const CHECKS: Array = [
	{"order": 300, "name": "inventory_received", "required": true},
	{"order": 305, "name": "inventory_starter_kit", "required": true},
	{"order": 310, "name": "inventory_move", "required": true},
	{"order": 315, "name": "inventory_move_restore", "required": true},
	{"order": 320, "name": "inventory_equip", "required": true},
	{"order": 325, "name": "inventory_unequip", "required": true},
	{"order": 330, "name": "inventory_reject_empty_move", "required": true},
	{"order": 335, "name": "inventory_reject_out_of_range", "required": true},
	{"order": 340, "name": "inventory_reject_wrong_equip_slot", "required": true},
	{"order": 345, "name": "inventory_count_conserved", "required": true},
	{"order": 350, "name": "inventory_mutate", "required": false},
]

var _installed := false
var _mutate := false
var _latest: Dictionary = {}
var _initial: Dictionary = {}
var _snap_count := 0
var _conserved := true
var _conserved_detail := ""

var _plan: Array = []
var _step := -1
var _snap_at_send := 0
var _deadline := 0
var _before_sig := ""
var _results: Dictionary = {}


## Connect while the bot is still being assembled (this runs inside bot._ready,
## before login), so the inventory snapshot sent on world entry is never missed.
func _init() -> void:
	_install()


func evaluate() -> Array:
	_install()
	if _latest.is_empty():
		return _report()
	if _step >= 0 and _step < _plan.size() and _snap_count == _snap_at_send \
			and Time.get_ticks_usec() > _deadline:
		_set_result(String(_plan[_step].get("check", "")), false, "timeout waiting for snapshot")
		_issue_next()
	return _report()


func _install() -> void:
	if _installed:
		return
	_installed = true
	_mutate = OS.get_cmdline_user_args().has("--bot-inv-mutate")
	for spec: Dictionary in CHECKS:
		_results[String(spec["name"])] = {"ok": false, "detail": "pending"}
	Net.inventory_received.connect(_on_inventory)


# --- inbound snapshots -------------------------------------------------------

func _on_inventory(snapshot: Dictionary) -> void:
	_snap_count += 1
	_latest = snapshot
	if _initial.is_empty():
		_initial = snapshot
		var plan_ok := _build_plan(snapshot)
		_set_result("inventory_received", true,
			"seq=%d capacity=%d" % [int(snapshot.get("seq", -1)), int(snapshot.get("capacity", 0))])
		_set_result("inventory_starter_kit", plan_ok,
			"%d starter stack(s)" % _all_entries(snapshot).size())
		_update_conservation(snapshot)
		_print_state("initial", snapshot)
		_issue_next()
		return
	_update_conservation(snapshot)
	if _step >= 0 and _step < _plan.size() and _snap_count > _snap_at_send:
		_resolve(_step, snapshot)
		_issue_next()


# --- sequence driver ---------------------------------------------------------

func _issue_next() -> void:
	_step += 1
	if _step >= _plan.size():
		_print_state("final", _latest)
		return
	var entry: Dictionary = _plan[_step]
	_before_sig = _sig(_latest)
	_snap_at_send = _snap_count
	_deadline = Time.get_ticks_usec() + SNAPSHOT_TIMEOUT_USEC
	_send_intent(entry)


func _send_intent(entry: Dictionary) -> void:
	if bot == null or bot.net == null:
		return
	match String(entry.get("op", "")):
		"move":
			bot.net.move_item(int(entry.get("from", 0)), int(entry.get("to", 0)))
		"equip":
			bot.net.equip_item(int(entry.get("inv", 0)), int(entry.get("equip", 0)))
		"unequip":
			bot.net.unequip_item(int(entry.get("equip", 0)), int(entry.get("inv", 0)))


func _resolve(index: int, snapshot: Dictionary) -> void:
	var entry: Dictionary = _plan[index]
	var check := String(entry.get("check", ""))
	var last: Dictionary = snapshot.get("last", {})
	var accepted := bool(last.get("ok", false))
	var expect_ok := String(entry.get("expect", "ok")) == "ok"
	if expect_ok and not accepted:
		_set_result(check, false, "server rejected: %s" % String(last.get("reason", "?")))
		return
	if not expect_ok:
		var unchanged := _sig(snapshot) == _before_sig
		_set_result(check, (not accepted) and unchanged,
			"accepted=%s unchanged=%s" % [str(accepted), str(unchanged)])
		return
	var verdict := _verify_ok(entry, snapshot)
	_set_result(check, bool(verdict.get("ok", false)), String(verdict.get("detail", "")))


func _verify_ok(entry: Dictionary, snapshot: Dictionary) -> Dictionary:
	var item_id := String(entry.get("item_id", ""))
	match String(entry.get("verify", "")):
		"moved":
			var dst: Variant = _entry_at(snapshot, "items", int(entry.get("to", -1)))
			var src: Variant = _entry_at(snapshot, "items", int(entry.get("from", -1)))
			var ok := dst != null and String(dst.get("item_id", "")) == item_id and src == null
			if ok and entry.has("count"):
				ok = int(dst.get("count", -1)) == int(entry["count"])
			return {"ok": ok, "detail": "%s -> slot %d" % [item_id, int(entry.get("to", -1))]}
		"equipped":
			var eq: Variant = _entry_at(snapshot, "equipment", int(entry.get("equip", -1)))
			var inv: Variant = _entry_at(snapshot, "items", int(entry.get("inv", -1)))
			var ok := eq != null and String(eq.get("item_id", "")) == item_id and inv == null
			return {"ok": ok, "detail": "equip slot %d" % int(entry.get("equip", -1))}
		"unequipped":
			var back: Variant = _entry_at(snapshot, "items", int(entry.get("inv", -1)))
			var gone: Variant = _entry_at(snapshot, "equipment", int(entry.get("equip", -1)))
			var ok := back != null and String(back.get("item_id", "")) == item_id and gone == null
			return {"ok": ok, "detail": "back to slot %d" % int(entry.get("inv", -1))}
		"mutated":
			var left: Variant = _entry_at(snapshot, "items", int(entry.get("to", -1)))
			var ok := left != null and String(left.get("item_id", "")) == item_id
			return {"ok": ok, "detail": "left in slot %d" % int(entry.get("to", -1))}
	return {"ok": false, "detail": "no verifier"}


# --- plan --------------------------------------------------------------------

## Builds the sequence from the actual starter state (slots are discovered, not
## hardcoded), so a relogin run whose potion sits in a mutated slot still works.
func _build_plan(snapshot: Dictionary) -> bool:
	_plan.clear()
	var capacity := int(snapshot.get("capacity", Protocol.INVENTORY_SLOTS))
	var occupied: Dictionary = {}
	for entry: Variant in snapshot.get("items", []):
		if typeof(entry) == TYPE_DICTIONARY:
			occupied[int((entry as Dictionary).get("slot", -1))] = true
	var empties: Array = []
	for slot in range(capacity):
		if not occupied.has(slot):
			empties.append(slot)
	var potion: Variant = _entry_by_item(snapshot, "items", "minor_healing_potion")
	var sword: Variant = _entry_by_item(snapshot, "items", "worn_sword")
	if potion == null or sword == null or empties.size() < 2:
		return false
	var potion_slot := int(potion.get("slot", 0))
	var potion_count := int(potion.get("count", 1))
	var sword_slot := int(sword.get("slot", 0))
	var def := Item.by_id("worn_sword")
	var equip_slot := 0 if def == null else def.equip_slot
	var wrong_equip_slot := (equip_slot + 1) % Protocol.EQUIP_SLOT_COUNT
	var free_a := int(empties[0])
	var free_b := int(empties[1])
	_plan = [
		{"op": "move", "from": potion_slot, "to": free_a, "check": "inventory_move",
			"expect": "ok", "verify": "moved", "item_id": "minor_healing_potion", "count": potion_count},
		{"op": "move", "from": free_a, "to": potion_slot, "check": "inventory_move_restore",
			"expect": "ok", "verify": "moved", "item_id": "minor_healing_potion", "count": potion_count},
		{"op": "equip", "inv": sword_slot, "equip": equip_slot, "check": "inventory_equip",
			"expect": "ok", "verify": "equipped", "item_id": "worn_sword"},
		{"op": "unequip", "equip": equip_slot, "inv": sword_slot, "check": "inventory_unequip",
			"expect": "ok", "verify": "unequipped", "item_id": "worn_sword"},
		{"op": "move", "from": free_a, "to": free_b, "check": "inventory_reject_empty_move",
			"expect": "reject"},
		{"op": "move", "from": potion_slot, "to": capacity, "check": "inventory_reject_out_of_range",
			"expect": "reject"},
		{"op": "equip", "inv": sword_slot, "equip": wrong_equip_slot,
			"check": "inventory_reject_wrong_equip_slot", "expect": "reject"},
	]
	if _mutate:
		_plan.append({"op": "move", "from": potion_slot, "to": capacity - 1,
			"check": "inventory_mutate", "expect": "ok", "verify": "mutated",
			"item_id": "minor_healing_potion"})
	return true


func _update_conservation(snapshot: Dictionary) -> void:
	if _initial.is_empty():
		return
	var expected := _total(_initial)
	var actual := _total(snapshot)
	if actual != expected:
		_conserved = false
		_conserved_detail = "expected %d, saw %d" % [expected, actual]
	_set_result("inventory_count_conserved", _conserved,
		_conserved_detail if not _conserved else "%d item(s) throughout" % actual)


# --- reporting / helpers -----------------------------------------------------

func _report() -> Array:
	var out: Array = []
	for spec: Dictionary in CHECKS:
		var name := String(spec["name"])
		var entry: Dictionary = _results.get(name, {"ok": false, "detail": "pending"})
		out.append({
			"order": int(spec["order"]),
			"name": name,
			"required": bool(spec["required"]),
			"ok": bool(entry.get("ok", false)),
			"detail": String(entry.get("detail", "")),
		})
	return out


func _set_result(name: String, ok: bool, detail: String) -> void:
	if name.is_empty():
		return
	_results[name] = {"ok": ok, "detail": detail}


## One stable line per state change; the relogin gate compares a run's "final"
## line with the next run's "initial" line.
func _print_state(tag: String, snapshot: Dictionary) -> void:
	print("[bot] inventory %s seq=%d %s" % [tag, int(snapshot.get("seq", -1)), _sig(snapshot)])


func _sig(snapshot: Dictionary) -> String:
	return "I[%s] E[%s]" % [_entries_sig(snapshot.get("items", [])), _entries_sig(snapshot.get("equipment", []))]


func _entries_sig(entries: Array) -> String:
	var parts: Array[String] = []
	for entry: Variant in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var data: Dictionary = entry
		parts.append("%d:%s:%d:%s" % [
			int(data.get("slot", -1)), String(data.get("item_id", "")),
			int(data.get("count", 0)), str(bool(data.get("bound", false)))])
	parts.sort()
	return ",".join(parts)


func _all_entries(snapshot: Dictionary) -> Array:
	var out: Array = []
	out.append_array(snapshot.get("items", []))
	out.append_array(snapshot.get("equipment", []))
	return out


func _entry_at(snapshot: Dictionary, key: String, slot: int) -> Variant:
	for entry: Variant in snapshot.get(key, []):
		if typeof(entry) == TYPE_DICTIONARY and int((entry as Dictionary).get("slot", -1)) == slot:
			return entry
	return null


func _entry_by_item(snapshot: Dictionary, key: String, item_id: String) -> Variant:
	for entry: Variant in snapshot.get(key, []):
		if typeof(entry) == TYPE_DICTIONARY and String((entry as Dictionary).get("item_id", "")) == item_id:
			return entry
	return null


func _total(snapshot: Dictionary) -> int:
	var total := 0
	for entry: Variant in _all_entries(snapshot):
		if typeof(entry) == TYPE_DICTIONARY:
			total += int((entry as Dictionary).get("count", 0))
	return total
