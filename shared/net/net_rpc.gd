extends Node
## The ONLY place in this repository where `@rpc` is declared.
##
## Both `client/project.godot` and `server/project.godot` register this script as
## an autoload named exactly `Net`, so the NodePath is always `/root/Net` on both
## ends and every signature (name, argument types, rpc config) matches byte for
## byte. Godot binds RPCs by NodePath + signature; any divergence produces
## errors that point at *unrelated* RPCs.
##
## This node contains no gameplay logic: it only re-emits signals. Server logic
## lives in server/scripts/, client logic in client/scripts/.
##
## Every client -> server signal carries the authenticated `sender` peer id taken
## from `multiplayer.get_remote_sender_id()`. Server code must use that value and
## never a client-supplied id.

# --- client -> server (inputs and intents only) -----------------------------
signal input_received(sender: int, seq: int, move: Vector2, yaw: float, buttons: int)
signal use_ability_requested(sender: int, target_id: int)
signal list_characters_requested(sender: int)
signal create_character_requested(sender: int, char_name: String, class_id: int)
signal select_character_requested(sender: int, char_id: int)

# --- server -> client (authoritative state) ---------------------------------
signal login_result_received(ok: bool, reason: String)
signal character_list_received(characters: Array)
signal world_entered(self_id: int, spawn: Vector3, hp: int)
signal entity_spawned(state: Dictionary)
signal entity_despawned(id: int)
signal world_state_received(tick: int, entities: Array)
signal combat_event_received(id: int, target_id: int, damage: int, target_hp: int)
signal hp_update_received(id: int, hp: int)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func c2s_input(seq: int, move: Vector2, yaw: float, buttons: int) -> void:
	input_received.emit(multiplayer.get_remote_sender_id(), seq, move, yaw, buttons)


@rpc("any_peer", "call_remote", "reliable")
func c2s_use_ability(target_id: int) -> void:
	use_ability_requested.emit(multiplayer.get_remote_sender_id(), target_id)


@rpc("any_peer", "call_remote", "reliable")
func c2s_list_characters() -> void:
	list_characters_requested.emit(multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "reliable")
func c2s_create_character(char_name: String, class_id: int) -> void:
	create_character_requested.emit(multiplayer.get_remote_sender_id(), char_name, class_id)


@rpc("any_peer", "call_remote", "reliable")
func c2s_select_character(char_id: int) -> void:
	select_character_requested.emit(multiplayer.get_remote_sender_id(), char_id)


@rpc("authority", "call_remote", "reliable")
func s2c_login_result(ok: bool, reason: String) -> void:
	login_result_received.emit(ok, reason)


@rpc("authority", "call_remote", "reliable")
func s2c_character_list(characters: Array) -> void:
	character_list_received.emit(characters)


@rpc("authority", "call_remote", "reliable")
func s2c_enter_world(self_id: int, spawn: Vector3, hp: int) -> void:
	world_entered.emit(self_id, spawn, hp)


@rpc("authority", "call_remote", "reliable")
func s2c_spawn_entity(state: Dictionary) -> void:
	entity_spawned.emit(state)


@rpc("authority", "call_remote", "reliable")
func s2c_despawn_entity(id: int) -> void:
	entity_despawned.emit(id)


@rpc("authority", "call_remote", "unreliable_ordered")
func s2c_world_state(tick: int, entities: Array) -> void:
	world_state_received.emit(tick, entities)


@rpc("authority", "call_remote", "reliable")
func s2c_combat_event(id: int, target_id: int, damage: int, target_hp: int) -> void:
	combat_event_received.emit(id, target_id, damage, target_hp)


@rpc("authority", "call_remote", "reliable")
func s2c_hp_update(id: int, hp: int) -> void:
	hp_update_received.emit(id, hp)
