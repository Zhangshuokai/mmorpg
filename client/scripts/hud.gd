class_name HUD
extends CanvasLayer
## Minimal combat HUD: local HP, current target HP and a control hint.

var _self_label: Label
var _self_bar: ProgressBar
var _target_label: Label
var _target_bar: ProgressBar
var _hint: Label
var _panel: PanelContainer


func _ready() -> void:
	_panel = PanelContainer.new()
	_panel.position = Vector2(16.0, 16.0)
	_panel.custom_minimum_size = Vector2(300.0, 0.0)
	add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_panel.add_child(box)

	_self_label = Label.new()
	box.add_child(_self_label)
	_self_bar = ProgressBar.new()
	_self_bar.custom_minimum_size = Vector2(280.0, 18.0)
	_self_bar.show_percentage = false
	box.add_child(_self_bar)

	_target_label = Label.new()
	box.add_child(_target_label)
	_target_bar = ProgressBar.new()
	_target_bar.custom_minimum_size = Vector2(280.0, 14.0)
	_target_bar.show_percentage = false
	box.add_child(_target_bar)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(280.0, 0.0)
	_hint.modulate = Color(0.8, 0.83, 0.9)
	box.add_child(_hint)


func show_hud() -> void:
	_panel.visible = true


func hide_hud() -> void:
	_panel.visible = false


func update_self(display_name: String, hp: int, max_hp: int) -> void:
	_self_label.text = "%s   %d / %d HP" % [display_name, hp, max_hp]
	_self_bar.max_value = max(1, max_hp)
	_self_bar.value = clampi(hp, 0, max_hp)


func update_target(display_name: String, hp: int, max_hp: int) -> void:
	_target_label.text = "Target: %s   %d / %d HP" % [display_name, hp, max_hp]
	_target_label.visible = true
	_target_bar.visible = true
	_target_bar.max_value = max(1, max_hp)
	_target_bar.value = clampi(hp, 0, max_hp)


func clear_target() -> void:
	_target_label.text = "Target: none  (Tab: nearest mob)"
	_target_bar.visible = false


func set_hint(text: String) -> void:
	_hint.text = text
