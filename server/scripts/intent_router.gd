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

var _handlers: Dictionary = {}


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


func _on_input(sender: int, seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	_invoke("input_received", [sender, seq, move, yaw, buttons])


func _on_use_ability(sender: int, ability_id: int, target_id: int) -> void:
	_invoke("use_ability_requested", [sender, ability_id, target_id])


func _on_list_characters(sender: int) -> void:
	_invoke("list_characters_requested", [sender])


func _on_create_character(sender: int, char_name: String, class_id: int) -> void:
	_invoke("create_character_requested", [sender, char_name, class_id])


func _on_select_character(sender: int, char_id: int) -> void:
	_invoke("select_character_requested", [sender, char_id])


func _on_move_item(sender: int, from_slot: int, to_slot: int) -> void:
	_invoke("move_item_requested", [sender, from_slot, to_slot])


func _on_equip_item(sender: int, inv_slot: int, equip_slot: int) -> void:
	_invoke("equip_item_requested", [sender, inv_slot, equip_slot])


func _on_unequip_item(sender: int, equip_slot: int, inv_slot: int) -> void:
	_invoke("unequip_item_requested", [sender, equip_slot, inv_slot])


func _on_change_zone(sender: int, zone_id: int, channel_id: int) -> void:
	_invoke("change_zone_requested", [sender, zone_id, channel_id])
