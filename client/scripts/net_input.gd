class_name NetInput
extends Node
## Client -> server intent senders plus the input tick throttle and sequence
## counter (WB0 split; WB6 owns the input history cache and prediction replay).
##
## The application calls `tick_input(delta, ...)` every frame; this class only
## emits at the contract rate (Protocol.TICK_DT) and stamps the seq, so the
## server's monotonic-seq guard and WB6's ack comparison share one source.

var transport: NetTransport

var seq := 0

var _accum := 0.0


func setup(p_transport: NetTransport) -> void:
	transport = p_transport


## Frame-driven input: throttled to the tick rate, then sent.
func tick_input(delta: float, move: Vector2, yaw: float, buttons: int) -> void:
	_accum += delta
	if _accum < Protocol.TICK_DT:
		return
	_accum = 0.0
	seq += 1
	send_input(seq, move, yaw, buttons)


func send_input(seq_value: int, move: Vector2, yaw: float, buttons: int) -> void:
	if not _can_send():
		return
	Net.c2s_input.rpc_id(1, seq_value, move, yaw, buttons)


func use_ability(ability_id: int, target_id: int) -> void:
	if not _can_send():
		return
	Net.c2s_use_ability.rpc_id(1, ability_id, target_id)


func request_character_list() -> void:
	if not _can_send():
		return
	Net.c2s_list_characters.rpc_id(1)


func create_character(char_name: String, class_id: int) -> void:
	if not _can_send():
		return
	Net.c2s_create_character.rpc_id(1, char_name, class_id)


func select_character(char_id: int) -> void:
	if not _can_send():
		return
	Net.c2s_select_character.rpc_id(1, char_id)


func move_item(from_slot: int, to_slot: int) -> void:
	if not _can_send():
		return
	Net.c2s_move_item.rpc_id(1, from_slot, to_slot)


func equip_item(inv_slot: int, equip_slot: int) -> void:
	if not _can_send():
		return
	Net.c2s_equip_item.rpc_id(1, inv_slot, equip_slot)


func unequip_item(equip_slot: int, inv_slot: int) -> void:
	if not _can_send():
		return
	Net.c2s_unequip_item.rpc_id(1, equip_slot, inv_slot)


func change_zone(zone_id: int, channel_id: int) -> void:
	if not _can_send():
		return
	Net.c2s_change_zone.rpc_id(1, zone_id, channel_id)


func _can_send() -> bool:
	return transport != null and transport.can_send()
