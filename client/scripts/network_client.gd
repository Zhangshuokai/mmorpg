class_name NetworkClient
extends Node
## Client network facade. WB0 split the former monolith into
## NetTransport (ENet lifecycle, WB7), NetAuth (handshake, WB7) and
## NetInput (intents + input seq, WB6); this class only assembles them and keeps
## the stable method surface the app/bot use.

var host := Protocol.DEFAULT_HOST
var port := Protocol.SERVER_PORT

var transport: NetTransport
var auth: NetAuth
var input: NetInput


func _ready() -> void:
	auth = NetAuth.new()
	auth.name = "NetAuth"
	add_child(auth)

	transport = NetTransport.new()
	transport.name = "NetTransport"
	add_child(transport)

	input = NetInput.new()
	input.name = "NetInput"
	add_child(input)

	transport.setup(auth, host, port)
	input.setup(transport)


func connect_to_server(p_host: String, username: String, password: String, register: bool) -> void:
	transport.connect_to_server(p_host, username, password, register)


func close() -> void:
	transport.close()


func can_send() -> bool:
	return transport.can_send()


# --- intents ----------------------------------------------------------------

func tick_input(delta: float, move: Vector2, yaw: float, buttons: int) -> void:
	input.tick_input(delta, move, yaw, buttons)


func send_input(seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	input.send_input(seq, move, yaw, buttons)


func use_ability(ability_id: int, target_id: int) -> void:
	input.use_ability(ability_id, target_id)


func request_character_list() -> void:
	input.request_character_list()


func create_character(char_name: String, class_id: int) -> void:
	input.create_character(char_name, class_id)


func select_character(char_id: int) -> void:
	input.select_character(char_id)


func move_item(from_slot: int, to_slot: int) -> void:
	input.move_item(from_slot, to_slot)


func equip_item(inv_slot: int, equip_slot: int) -> void:
	input.equip_item(inv_slot, equip_slot)


func unequip_item(equip_slot: int, inv_slot: int) -> void:
	input.unequip_item(equip_slot, inv_slot)


func change_zone(zone_id: int, channel_id: int) -> void:
	input.change_zone(zone_id, channel_id)
