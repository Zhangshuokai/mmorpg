class_name SkillBar
extends CanvasLayer
## Client skill bar (S-G-1). A pure view: one slot per ability from
## `shared/data/tables/abilities.json`, a cosmetic local cooldown sweep, and a
## cast bar driven by the authoritative `s2c_cast_started` / `s2c_cast_interrupted`
## notifications.
##
## Activating a slot only sends a `c2s_use_ability` intent through NetworkClient;
## the server decides accept/reject and owns every number (range, cooldown, GCD,
## damage). The local sweep is display-only and re-syncs from the server's cast
## events.
##
## Wiring note: this file deliberately does not edit the client assembly
## (client/scripts/main.gd is not owned by this workbench). Add it once after the
## client is assembled:
##     var bar := SkillBar.new()
##     add_child(bar)
##     bar.attach(net, world_view)
## Until then it parses and is inert.

const ABILITIES_TABLE := "abilities"
const CLASSES_TABLE := "classes"
const ICON_SIZE := Vector2(56.0, 56.0)
const CAST_BAR_SIZE := Vector2(240.0, 14.0)

var net: NetworkClient
var world_view: WorldView

## ability rows from the data table, sorted by id.
var _abilities: Array = []
## ability_id -> remaining local cooldown seconds (display only).
var _cooldowns: Dictionary = {}
var _gcd := 0.0
var _cast_total := 0.0
var _cast_remaining := 0.0

var _slot_box: HBoxContainer
var _slots: Array = []
var _cast_bar: ProgressBar


## Called by the assembler before (or after) the node is added to the tree.
func attach(p_net: NetworkClient, p_world_view: WorldView) -> void:
	net = p_net
	world_view = p_world_view


func _ready() -> void:
	layer = 2
	_load_abilities()
	_build()
	Net.cast_started.connect(_on_cast_started)
	Net.cast_interrupted.connect(_on_cast_interrupted)


func _process(delta: float) -> void:
	for ability_id: int in _cooldowns.keys():
		_cooldowns[ability_id] = maxf(0.0, float(_cooldowns[ability_id]) - delta)
	_gcd = maxf(0.0, _gcd - delta)
	if _cast_remaining > 0.0:
		_cast_remaining = maxf(0.0, _cast_remaining - delta)
	_update_display()


# --- assembly ---------------------------------------------------------------

func _load_abilities() -> void:
	_abilities.clear()
	var table: Variant = DataTables.load_table(ABILITIES_TABLE)
	if typeof(table) != TYPE_DICTIONARY:
		push_warning("[skillbar] %s.json unavailable" % ABILITIES_TABLE)
		return
	for row: Dictionary in (table as Dictionary).get("rows", []):
		_abilities.append(row)
	_abilities.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("id", 0)) < int(b.get("id", 0)))


func _build() -> void:
	var root := VBoxContainer.new()
	root.name = "SkillBarRoot"
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 6)
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	root.position = Vector2(-150.0, -120.0)

	_cast_bar = ProgressBar.new()
	_cast_bar.custom_minimum_size = CAST_BAR_SIZE
	_cast_bar.show_percentage = false
	_cast_bar.visible = false
	root.add_child(_cast_bar)

	_slot_box = HBoxContainer.new()
	_slot_box.name = "Slots"
	_slot_box.add_theme_constant_override("separation", 4)
	root.add_child(_slot_box)

	for row: Dictionary in _abilities:
		var ability_id := int(row.get("id", 0))
		var button := Button.new()
		button.name = "Ability%d" % ability_id
		button.custom_minimum_size = ICON_SIZE
		button.text = "%d\n%s" % [ability_id, String(row.get("name", "?"))]
		button.tooltip_text = "range %.1f  cd %.1fs  gcd %.1fs" % [
			float(row.get("range", 0.0)), float(row.get("cooldown", 0.0)), float(row.get("gcd", 0.0))]
		button.pressed.connect(_on_slot_pressed.bind(ability_id))
		_slot_box.add_child(button)
		_slots.append({"ability_id": ability_id, "button": button})
	_update_display()


# --- intents (the server is authoritative) ----------------------------------

func _on_slot_pressed(ability_id: int) -> void:
	if world_view == null or world_view.target_id == 0:
		return
	_activate(ability_id)


## Sends the intent and starts the cosmetic sweep. The server may still reject
## it (out of range, on cooldown); rejection simply means no cast event arrives.
func _activate(ability_id: int) -> void:
	if net == null:
		return
	net.use_ability(ability_id, world_view.target_id)


# --- authoritative feedback -------------------------------------------------

func _on_cast_started(caster_id: int, ability_id: int, _target_id: int, duration_sec: float) -> void:
	if not _is_local(caster_id):
		return
	_cast_total = maxf(0.05, duration_sec)
	_cast_remaining = _cast_total
	_cooldowns[ability_id] = maxf(float(_cooldowns.get(ability_id, 0.0)), float(_ability_value(ability_id, "cooldown", 0.0)))
	_gcd = maxf(_gcd, float(_ability_value(ability_id, "gcd", 0.0)))
	_update_display()


func _on_cast_interrupted(caster_id: int, _ability_id: int, _reason: int) -> void:
	if not _is_local(caster_id):
		return
	_cast_remaining = 0.0
	_update_display()


func _is_local(caster_id: int) -> bool:
	return world_view != null and world_view.local_id == caster_id


# --- rendering --------------------------------------------------------------

func _update_display() -> void:
	if _cast_bar != null:
		_cast_bar.visible = _cast_remaining > 0.0
		_cast_bar.max_value = maxf(0.05, _cast_total)
		_cast_bar.value = _cast_total - _cast_remaining
	for slot: Dictionary in _slots:
		var ability_id := int(slot.get("ability_id", 0))
		var button: Button = slot.get("button")
		if button == null:
			continue
		var remaining := maxf(float(_cooldowns.get(ability_id, 0.0)), _gcd)
		button.disabled = remaining > 0.0 or world_view == null or world_view.target_id == 0
		if remaining > 0.0:
			button.text = "%d\n%.1f" % [ability_id, remaining]
		else:
			button.text = "%d\n%s" % [ability_id, String(_ability_value(ability_id, "name", "?"))]


func _ability_value(ability_id: int, key: String, fallback: Variant) -> Variant:
	for row: Dictionary in _abilities:
		if int(row.get("id", 0)) == ability_id:
			return row.get(key, fallback)
	return fallback
