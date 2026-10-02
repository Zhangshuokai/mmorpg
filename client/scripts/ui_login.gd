class_name LoginUI
extends CanvasLayer
## Login / registration / character-select UI. Pure view: it only emits intents.

signal login_requested(username: String, password: String, register: bool)
signal create_requested(char_name: String)
signal select_requested(char_id: int)

var _login_panel: PanelContainer
var _char_panel: PanelContainer
var _user_edit: LineEdit
var _pass_edit: LineEdit
var _login_status: Label
var _char_list: ItemList
var _name_edit: LineEdit
var _char_status: Label
var _enter_button: Button


func _ready() -> void:
	var root := CenterContainer.new()
	root.name = "Center"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_login_panel = _build_login_panel()
	root.add_child(_login_panel)
	_char_panel = _build_character_panel()
	root.add_child(_char_panel)

	show_login()


# --- panels -----------------------------------------------------------------

func _build_login_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380.0, 0.0)
	var box := _vbox(panel, 10)

	var title := Label.new()
	title.text = "MMORPG MVP"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Server-authoritative demo"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.modulate = Color(0.75, 0.78, 0.85)
	box.add_child(subtitle)

	_user_edit = LineEdit.new()
	_user_edit.placeholder_text = "username (3-16 chars)"
	_user_edit.max_length = Protocol.USER_MAX
	box.add_child(_labelled("Username", _user_edit))

	_pass_edit = LineEdit.new()
	_pass_edit.placeholder_text = "password (4+ chars)"
	_pass_edit.secret = true
	box.add_child(_labelled("Password", _pass_edit))

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	var login_button := Button.new()
	login_button.text = "Log in"
	login_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	login_button.pressed.connect(_on_login_pressed)
	buttons.add_child(login_button)
	var register_button := Button.new()
	register_button.text = "Register"
	register_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	register_button.pressed.connect(_on_register_pressed)
	buttons.add_child(register_button)
	box.add_child(buttons)

	_login_status = Label.new()
	_login_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_login_status.custom_minimum_size = Vector2(0.0, 36.0)
	_login_status.modulate = Color(0.95, 0.85, 0.5)
	box.add_child(_login_status)

	var hint := Label.new()
	hint.text = "Run the server first:\ngodot --headless --path server -- --server"
	hint.modulate = Color(0.6, 0.63, 0.7)
	box.add_child(hint)
	return panel


func _build_character_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380.0, 0.0)
	var box := _vbox(panel, 10)

	var title := Label.new()
	title.text = "Select character"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_char_list = ItemList.new()
	_char_list.custom_minimum_size = Vector2(0.0, 150.0)
	_char_list.item_activated.connect(_on_enter_pressed)
	box.add_child(_char_list)

	var create_row := HBoxContainer.new()
	create_row.add_theme_constant_override("separation", 8)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "new character name"
	_name_edit.max_length = Protocol.NAME_MAX
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create_row.add_child(_name_edit)
	var create_button := Button.new()
	create_button.text = "Create"
	create_button.pressed.connect(_on_create_pressed)
	create_row.add_child(create_button)
	box.add_child(create_row)

	_enter_button = Button.new()
	_enter_button.text = "Enter world"
	_enter_button.pressed.connect(_on_enter_pressed)
	box.add_child(_enter_button)

	_char_status = Label.new()
	_char_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_char_status.custom_minimum_size = Vector2(0.0, 36.0)
	_char_status.modulate = Color(0.95, 0.85, 0.5)
	box.add_child(_char_status)
	return panel


func _vbox(panel: Control, separation: int) -> VBoxContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	margin.add_child(box)
	return box


func _labelled(text: String, control: Control) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var label := Label.new()
	label.text = text
	label.modulate = Color(0.78, 0.8, 0.86)
	box.add_child(label)
	box.add_child(control)
	return box


# --- view state -------------------------------------------------------------

func show_login() -> void:
	_login_panel.visible = true
	_char_panel.visible = false


func show_characters(list: Array) -> void:
	_login_panel.visible = false
	_char_panel.visible = true
	_char_list.clear()
	for entry: Dictionary in list:
		var index := _char_list.add_item(String(entry.get("name", "?")))
		_char_list.set_item_metadata(index, int(entry.get("id", 0)))
	if _char_list.item_count > 0:
		_char_list.select(0)
		_char_status.text = "Select a character, then press Enter world."
	else:
		_char_status.text = "No characters yet. Type a name and press Create."
	_enter_button.disabled = _char_list.item_count == 0


func hide_all() -> void:
	_login_panel.visible = false
	_char_panel.visible = false


func set_login_status(text: String) -> void:
	_login_status.text = text


func set_char_status(text: String) -> void:
	_char_status.text = text


func password_length() -> int:
	return _pass_edit.text.length()


## Pre-fills the login fields (used by scripts/start_client.ps1 so a launcher can
## hand credentials to the client without a human typing them).
func set_credentials(username: String, password: String) -> void:
	_user_edit.text = username
	_pass_edit.text = password


func selected_character_id() -> int:
	var selected := _char_list.get_selected_items()
	if selected.is_empty():
		return 0
	return int(_char_list.get_item_metadata(selected[0]))


# --- intents ----------------------------------------------------------------

func _on_login_pressed() -> void:
	login_requested.emit(_user_edit.text.strip_edges(), _pass_edit.text, false)


func _on_register_pressed() -> void:
	login_requested.emit(_user_edit.text.strip_edges(), _pass_edit.text, true)


func _on_create_pressed() -> void:
	var char_name := _name_edit.text.strip_edges()
	if char_name.is_empty():
		_char_status.text = "Enter a character name first."
		return
	create_requested.emit(char_name)


func _on_enter_pressed() -> void:
	var char_id := selected_character_id()
	if char_id == 0:
		_char_status.text = "Select a character first."
		return
	select_requested.emit(char_id)
