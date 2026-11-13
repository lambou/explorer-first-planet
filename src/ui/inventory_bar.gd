class_name InventoryBar
extends Control
## The bar at the bottom centre of the screen: the first row of the inventory (nine slots, keys 1-9) with the weight
## carried above it. Display only: it reads the PlayerKit.

const COLUMNS := 9

var _kit: PlayerKit
var _slots: Array[SlotView] = []
var _meter: WeightMeter

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	_meter = WeightMeter.new(COLUMNS * (UiTheme.SLOT + UiTheme.GAP) - UiTheme.GAP)
	box.add_child(_meter)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", int(UiTheme.GAP))
	box.add_child(row)
	for i in COLUMNS:
		var s := SlotView.new()
		s.hotkey = str(i + 1)
		s.clicked.connect(_on_slot_clicked.bind(i))
		row.add_child(s)
		_slots.append(s)
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 14)

func bind(kit: PlayerKit) -> void:
	_kit = kit
	kit.inventory.changed.connect(refresh)
	kit.bar_slot_changed.connect(refresh)
	refresh()

func refresh() -> void:
	for i in COLUMNS:
		_slots[i].set_stack(_kit.inventory.slots[i])
		_slots[i].selected = (i == _kit.bar_slot)
	_meter.set_load(_kit.inventory.weight(), _kit.inventory.capacity_kg)

func _on_slot_clicked(_button: int, i: int) -> void:
	_kit.select_bar_slot(i)
