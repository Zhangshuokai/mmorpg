class_name IntentRouter
extends Node
## Inbound intent dispatcher. Maps each `Net` client->server signal to a handler
## registered by name, so later workbenches add their handler in their own file
## instead of editing a central `match`.
##
## Usage (see main.gd):
##     router.register("input_received", _on_input)
##
## The signal set here is frozen by the WB0 contract; adding a new c2s_* means
## adding a Net RPC (three-place lockstep) and an `_on_*` forwarder here.
##
## WB7 (S-E-2) adds the untrusted-input gate: every c2s_* is type/range checked
## and frequency capped BEFORE the registered handler runs. The name->handler
## registry API is unchanged, so services still just `register(...)`.
##
## Validation here is deliberately structural (ranges, finiteness, known bit
## masks). Semantic checks that need domain state (does the ability exist, does
## the player own the character) stay in the owning service; the router is the
## cheap first line that drops malformed and over-rate traffic.

## Per-connection token buckets: (sender, signal) -> rate/second + burst.
## input is sent at the world tick rate (20Hz); the rest are intent bursts.
const RPC_RATES := {
	"input_received": {"rate": 60.0, "burst": 90},
	"use_ability_requested": {"rate": 8.0, "burst": 16},
	"list_characters_requested": {"rate": 2.0, "burst": 5},
	"create_character_requested": {"rate": 1.0, "burst": 3},
	"select_character_requested": {"rate": 1.0, "burst": 5},
	"move_item_requested": {"rate": 10.0, "burst": 30},
	"equip_item_requested": {"rate": 10.0, "burst": 30},
	"unequip_item_requested": {"rate": 10.0, "burst": 30},
	"change_zone_requested": {"rate": 1.0, "burst": 3},
}

## Upper bounds for id-shaped arguments. Kept generous: they reject garbage and
## overflow-sized values while leaving room for WB2/WB5 to add ids without a
## router edit. Unknown-but-plausible ids are rejected by the owning service.
const ABILITY_ID_MAX := 4095
const ENTITY_ID_MAX := 0x7FFFFFFF
const CLASS_ID_MAX := 255
const ZONE_ID_MAX := 255

var _handlers: Dictionary = {}
var _limiter := RateLimitService.new()
## "sender|action" -> last rejection log time, so a flood cannot become a log
## flood while still surfacing each distinct offending RPC once per second.
var _last_reject: Dictionary = {}


func _ready() -> void:
	Net.input_received.connect(_on_input)
	Net.use_ability_requested.connect(_on_use_ability)
	Net.list_characters_requested.connect(_on_list_characters)
	Net.create_character_requested.connect(_on_create_character)
	Net.select_character_requested.connect(_on_select_character)
	Net.move_item_requested.connect(_on_move_item)
	Net.equip_item_requested.connect(_on_equip_item)
	Net.unequip_item_requested.connect(_on_unequip_item)
	Net.change_zone_requested.connect(_on_change_zone)


func register(handler_name: String, handler: Callable) -> void:
	_handlers[handler_name] = handler


func _invoke(handler_name: String, args: Array) -> void:
	var handler: Variant = _handlers.get(handler_name)
	if handler is Callable and (handler as Callable).is_valid():
		(handler as Callable).callv(args)


# --- gate -------------------------------------------------------------------

## Frequency cap for one (sender, signal). Over-rate traffic is dropped here.
func _accept(sender: int, action: String) -> bool:
	var limit: Dictionary = RPC_RATES.get(action, {})
	if limit.is_empty():
		return true
	if _limiter.allow(str(sender), action, float(limit.get("rate", 1.0)), int(limit.get("burst", 1))):
		return true
	if _limiter.log_allowed(str(sender), action):
		_reject(sender, action, "rate limit exceeded")
	return false


func _reject(sender: int, action: String, detail: String) -> void:
	var key := "%d|%s" % [sender, action]
	var now := Time.get_ticks_msec()
	if now - int(_last_reject.get(key, 0)) < 1000:
		return
	_last_reject[key] = now
	if _last_reject.size() > 1024:
		_last_reject.clear()
	push_warning("[router] rejected c2s '%s' from peer %d: %s" % [action, sender, detail])
	print("[router] REJECT %s peer=%d %s" % [action, sender, detail])


func _on_input(sender: int, seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	if not _accept(sender, "input_received"):
		return
	# Non-finite input would poison the authoritative position for every client;
	# both axes are also clamped to a unit intent (diagonals are (1,1)).
	if seq < 0 or not move.is_finite() or not is_finite(yaw) \
			or absf(move.x) > 1.0 or absf(move.y) > 1.0 \
			or buttons < 0 or (buttons & ~Protocol.Buttons.ATTACK) != 0:
		_reject(sender, "input_received", "seq=%d move=%s yaw=%s buttons=%d" % [seq, move, yaw, buttons])
		return
	_invoke("input_received", [sender, seq, move, yaw, buttons])


func _on_use_ability(sender: int, ability_id: int, target_id: int) -> void:
	if not _accept(sender, "use_ability_requested"):
		return
	if ability_id < 0 or ability_id > ABILITY_ID_MAX or target_id < 0 or target_id > ENTITY_ID_MAX:
		_reject(sender, "use_ability_requested", "ability=%d target=%d" % [ability_id, target_id])
		return
	_invoke("use_ability_requested", [sender, ability_id, target_id])


func _on_list_characters(sender: int) -> void:
	if not _accept(sender, "list_characters_requested"):
		return
	_invoke("list_characters_requested", [sender])


func _on_create_character(sender: int, char_name: String, class_id: int) -> void:
	if not _accept(sender, "create_character_requested"):
		return
	# The explicit [A-Za-z0-9_] allowlist lives in SessionFlow; here the cheap
	# structural gate is length + no control characters.
	if not _valid_name(char_name) or class_id < 0 or class_id > CLASS_ID_MAX:
		_reject(sender, "create_character_requested", "name_len=%d class=%d" % [char_name.length(), class_id])
		return
	_invoke("create_character_requested", [sender, char_name, class_id])


func _on_select_character(sender: int, char_id: int) -> void:
	if not _accept(sender, "select_character_requested"):
		return
	if char_id <= 0 or char_id > ENTITY_ID_MAX:
		_reject(sender, "select_character_requested", "char_id=%d" % char_id)
		return
	_invoke("select_character_requested", [sender, char_id])


func _on_move_item(sender: int, from_slot: int, to_slot: int) -> void:
	if not _accept(sender, "move_item_requested"):
		return
	if not _valid_slot(from_slot) or not _valid_slot(to_slot):
		_reject(sender, "move_item_requested", "from=%d to=%d" % [from_slot, to_slot])
		return
	_invoke("move_item_requested", [sender, from_slot, to_slot])


func _on_equip_item(sender: int, inv_slot: int, equip_slot: int) -> void:
	if not _accept(sender, "equip_item_requested"):
		return
	if not _valid_slot(inv_slot) or equip_slot < 0 or equip_slot >= Protocol.EQUIP_SLOT_COUNT:
		_reject(sender, "equip_item_requested", "inv=%d equip=%d" % [inv_slot, equip_slot])
		return
	_invoke("equip_item_requested", [sender, inv_slot, equip_slot])


func _on_unequip_item(sender: int, equip_slot: int, inv_slot: int) -> void:
	if not _accept(sender, "unequip_item_requested"):
		return
	if not _valid_slot(inv_slot) or equip_slot < 0 or equip_slot >= Protocol.EQUIP_SLOT_COUNT:
		_reject(sender, "unequip_item_requested", "equip=%d inv=%d" % [equip_slot, inv_slot])
		return
	_invoke("unequip_item_requested", [sender, equip_slot, inv_slot])


func _on_change_zone(sender: int, zone_id: int, channel_id: int) -> void:
	if not _accept(sender, "change_zone_requested"):
		return
	if zone_id <= 0 or zone_id > ZONE_ID_MAX or channel_id < 0 or channel_id >= Protocol.ZONE_MAX_CHANNELS:
		_reject(sender, "change_zone_requested", "zone=%d channel=%d" % [zone_id, channel_id])
		return
	_invoke("change_zone_requested", [sender, zone_id, channel_id])


func _valid_name(name: String) -> bool:
	var length := name.length()
	if length < Protocol.NAME_MIN or length > Protocol.NAME_MAX:
		return false
	for i in length:
		var code := name.unicode_at(i)
		if code < 32 or code == 127:
			return false
	return true


func _valid_slot(slot: int) -> bool:
	return slot >= 0 and slot < Protocol.INVENTORY_SLOTS_MAX
