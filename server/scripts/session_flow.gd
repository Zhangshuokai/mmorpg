class_name SessionFlow
extends Node
## Account/character session flow: login result, character list/create/select
## (WB0). Registered with IntentRouter so main.gd stays pure assembly; WB2/WB3
## add their own panels without editing this file's router wiring.

const MAX_CHARACTERS_PER_ACCOUNT := 5

var auth: AuthService
var persistence: PersistenceService
var world: WorldService
var router: IntentRouter


func _ready() -> void:
	if router == null:
		push_error("[session] no IntentRouter assigned; intents will be dropped")
		return
	router.register("list_characters_requested", _on_list_characters)
	router.register("create_character_requested", _on_create_character)
	router.register("select_character_requested", _on_select_character)


func _on_list_characters(sender: int) -> void:
	var account_id := auth.account_for(sender)
	if account_id < 0:
		return
	_send_character_list(sender, account_id)


func _on_create_character(sender: int, char_name: String, class_id: int) -> void:
	var account_id := auth.account_for(sender)
	if account_id < 0:
		return
	var name := char_name.strip_edges()
	if not _valid_char_name(name):
		print("[server] peer %d requested invalid character name '%s'" % [sender, char_name])
		_send_character_list(sender, account_id)
		return
	if persistence.character_count(account_id) >= MAX_CHARACTERS_PER_ACCOUNT:
		print("[server] peer %d exceeded character limit" % sender)
		_send_character_list(sender, account_id)
		return
	if class_id != Protocol.ClassId.WARRIOR:
		class_id = Protocol.ClassId.WARRIOR
	var result := persistence.create_character(account_id, name, class_id)
	if not result.get("ok", false):
		print("[server] create_character for peer %d failed: %s" % [sender, result.get("reason", "?")])
	_send_character_list(sender, account_id)


func _on_select_character(sender: int, char_id: int) -> void:
	var account_id := auth.account_for(sender)
	if account_id < 0:
		return
	var sheet := persistence.get_character(char_id)
	if sheet == null or sheet.account_id != account_id:
		print("[server] peer %d tried to select unowned character %d" % [sender, char_id])
		_send_character_list(sender, account_id)
		return
	world.add_player(sender, sheet)


func _send_character_list(sender: int, account_id: int) -> void:
	var payload: Array = []
	for row: Dictionary in persistence.characters_for(account_id):
		payload.append(CharacterSheet.from_row(row).to_dict())
	Net.s2c_character_list.rpc_id(sender, payload)


## Explicit ASCII allowlist: [A-Za-z0-9_]. A blocklist would still let through
## zero-width, bidi-override and other format characters, which would be stored
## and then rendered verbatim in every other player's name tag (impersonation /
## blank nameplates).
func _valid_char_name(name: String) -> bool:
	var length := name.length()
	if length < Protocol.NAME_MIN or length > Protocol.NAME_MAX:
		return false
	for i in length:
		var code := name.unicode_at(i)
		var is_digit := code >= 48 and code <= 57
		var is_upper := code >= 65 and code <= 90
		var is_lower := code >= 97 and code <= 122
		var is_underscore := code == 95
		if not (is_digit or is_upper or is_lower or is_underscore):
			return false
	return true
