class_name InventoryUI
extends CanvasLayer
## Inventory / equipment panel (S-G-5, WB3).
##
## Self-wiring view: it subscribes to `Net.inventory_received` and renders the
## authoritative snapshot the server sends. It never decides ownership - no client
## authority - it only shows what the server said.
##
## Integration (one additive line in client/scripts/main.gd, owned by the
## integrator because WB3 does not own that file):
##     var inventory_ui := InventoryUI.new()
##     inventory_ui.net = net
##     add_child(inventory_ui)
##
## Toggle with the I key.

const COLUMNS := 8

var net: NetworkClient

var _panel: PanelContainer
var _slots: GridContainer
var _equipment: VBoxContainer
var _status: Label
var _slot_labels: Array[Label] = []
var _equip_labels: Dictionary = {}


func _ready() -> void:
	_build()
	Net.inventory_received.connect(_on_inventory_received)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).physical_keycode == KEY_I:
		_panel.visible = not _panel.visible
		get_viewport().set_input_as_handled()


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.name = "InventoryPanel"
	_panel.position = Vector2(360.0, 16.0)
	_panel.custom_minimum_size = Vector2(340.0, 0.0)
	_panel.visible = false
	add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_panel.add_child(box)

	var title := Label.new()
	title.text = "Inventory  (I to close)"
	box.add_child(title)

	_slots = GridContainer.new()
	_slots.columns = COLUMNS
	_slots.add_theme_constant_override("h_separation", 3)
	_slots.add_theme_constant_override("v_separation", 3)
	box.add_child(_slots)

	for slot in Protocol.INVENTORY_SLOTS:
		var label := Label.new()
		label.custom_minimum_size = Vector2(38.0, 22.0)
		label.modulate = Color(0.82, 0.85, 0.92)
		_slot_labels.append(label)
		_slots.add_child(label)

	var equip_title := Label.new()
	equip_title.text = "Equipped"
	box.add_child(equip_title)

	_equipment = VBoxContainer.new()
	_equipment.add_theme_constant_override("separation", 2)
	box.add_child(_equipment)

	var slot_names := [
		"MAIN_HAND", "OFF_HAND", "HEAD", "CHEST", "LEGS", "FEET",
	]
	for equip_slot in Protocol.EQUIP_SLOT_COUNT:
		var label := Label.new()
		label.text = "%s: -" % slot_names[equip_slot]
		_equip_labels[equip_slot] = label
		_equipment.add_child(label)

	_status = Label.new()
	_status.text = "waiting for server snapshot..."
	_status.modulate = Color(0.8, 0.75, 0.5)
	box.add_child(_status)


## Renders one authoritative snapshot. The panel stays hidden until the player
## opens it, but the data is kept current either way.
func _on_inventory_received(snapshot: Dictionary) -> void:
	var inventory := Inventory.from_snapshot(snapshot)
	for slot in _slot_labels.size():
		var stack: Inventory.Stack = inventory.get_slot(slot)
		_slot_labels[slot].text = _slot_text(slot, stack)
	for equip_slot: int in _equip_labels.keys():
		var label: Label = _equip_labels[equip_slot]
		var stack: Inventory.Stack = inventory.get_equipment(equip_slot)
		label.text = "%s: %s" % [label.text.get_slice(":", 0), "-" if stack == null else stack.item_id]
	var last: Dictionary = snapshot.get("last", {})
	_status.text = "%d/%d slots  seq=%d  last=%s %s" % [
		inventory.slots.size(), inventory.capacity, int(snapshot.get("seq", 0)),
		String(last.get("op", "?")), "ok" if bool(last.get("ok", true)) else String(last.get("reason", ""))]


func _slot_text(slot: int, stack: Inventory.Stack) -> String:
	if stack == null:
		return "%d" % slot
	var name := stack.item_id
	var def := Item.by_id(stack.item_id)
	if def != null:
		name = def.display_name
	return "%d\n%s%s" % [slot, name, "" if stack.count <= 1 else " x%d" % stack.count]
