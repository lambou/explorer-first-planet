class_name InventoryMenu
extends Control
## The full inventory screen ([Tab] / [I]): every slot (click to pick a stack up, click again to put it down or swap) and
## the crafting list beside it. Shows the PlayerKit and asks Crafter to craft; keeps nothing of its own except the stack
## on the cursor, which is handed back when the screen closes.

signal message(text: String, color: Color)
signal closed                          # the X was pressed: whoever owns the screen closes it

var _kit: PlayerKit
var _grid: GridContainer
var _slots: Array[SlotView] = []
var _meter: WeightMeter
var _crafts: VBoxContainer
var _info: Label
var _cursor: SlotView
var _held := {}                      # the stack on the cursor

func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP                 # nothing behind the screen is clickable while it is open
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.42)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(16))
	add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	panel.add_child(row)

	# left: what is carried
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	row.add_child(left)
	var head := HBoxContainer.new()
	left.add_child(head)
	var t := _title("Inventory   (Tab / I / Esc to close)")
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var x := Button.new()                                        # the close icon
	x.text = "X"
	x.tooltip_text = "Close"
	x.focus_mode = Control.FOCUS_NONE
	x.custom_minimum_size = Vector2(32, 28)
	x.pressed.connect(func() -> void: closed.emit())
	head.add_child(x)
	_grid = GridContainer.new()
	_grid.columns = InventoryBar.COLUMNS
	_grid.add_theme_constant_override("h_separation", int(UiTheme.GAP))
	_grid.add_theme_constant_override("v_separation", int(UiTheme.GAP))
	left.add_child(_grid)
	for i in Inventory.SLOTS:
		var s := SlotView.new()
		s.clicked.connect(_on_slot_clicked.bind(i))
		s.mouse_entered.connect(_on_hover.bind(i))
		s.mouse_exited.connect(func() -> void: _info.text = "")
		_grid.add_child(s)
		_slots.append(s)
	_meter = WeightMeter.new(InventoryBar.COLUMNS * (UiTheme.SLOT + UiTheme.GAP) - UiTheme.GAP)
	left.add_child(_meter)
	_info = Label.new()
	_info.custom_minimum_size = Vector2(0, 40)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_theme_font_size_override("font_size", 13)
	_info.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	left.add_child(_info)

	# right: what can be made
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(300, 0)
	right.add_theme_constant_override("separation", 8)
	row.add_child(right)
	right.add_child(_title("Crafting"))
	_crafts = VBoxContainer.new()
	_crafts.add_theme_constant_override("separation", 6)
	right.add_child(_crafts)

	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	_cursor = SlotView.new()
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.z_index = 10
	add_child(_cursor)

func bind(kit: PlayerKit) -> void:
	_kit = kit
	kit.inventory.changed.connect(func() -> void:
		if visible:
			refresh())

func open() -> void:
	visible = true
	refresh()

## Closing hands the cursor stack back to the inventory.
func close() -> void:
	if not _held.is_empty():
		var back := _kit.inventory.add(_held.id, _held.count)
		if back < _held.count:
			message.emit("Too heavy: %s left behind" % ItemCatalog.get_def(_held.id).name, UiTheme.BAD)
		_held = {}
	visible = false

func refresh() -> void:
	for i in _slots.size():
		_slots[i].set_stack(_kit.inventory.slots[i])
		_slots[i].selected = (i == _kit.bar_slot)
	_meter.set_load(_kit.inventory.weight(), _kit.inventory.capacity_kg)
	_cursor.set_stack(_held)
	_cursor.visible = not _held.is_empty()
	_rebuild_crafts()

func _process(_delta: float) -> void:
	if visible and _cursor.visible:
		_cursor.global_position = get_global_mouse_position() - _cursor.size * 0.5

func _on_slot_clicked(button: int, i: int) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	_held = _kit.inventory.click_slot(i, _held)            # emits `changed`, which refreshes the screen
	refresh()

func _on_hover(i: int) -> void:
	var s: Dictionary = _kit.inventory.slots[i]
	if s.is_empty():
		_info.text = ""
		return
	var d := ItemCatalog.get_def(s.id)
	_info.text = "%s x%d  -  %.1f kg (%.2f kg each)\n%s" % [d.name, s.count, s.count * d.unit_kg, d.unit_kg, d.blurb]

func _rebuild_crafts() -> void:
	for c in _crafts.get_children():
		_crafts.remove_child(c)
		c.queue_free()
	for craft: Dictionary in RecipeBook.options(_kit.inventory):
		_crafts.add_child(_craft_row(craft))

func _craft_row(craft: Dictionary) -> Control:
	var box := PanelContainer.new()
	var sb := UiTheme.panel_style(8)
	sb.bg_color = Color(0.13, 0.14, 0.17, 0.9) if craft.can else Color(0.10, 0.10, 0.12, 0.7)
	box.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var icon := SlotView.new(44)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if craft.out_kind == Recipe.OUT_TOOL:
		icon.set_tool(load(ToolCatalog.get_def(craft.out_id).icon_path) as Texture2D, craft.out_count)
	elif craft.out_id != "":
		icon.set_stack({"id": craft.out_id, "count": craft.out_count})
	else:
		icon.set_stack({})
	icon.dim = not craft.can
	row.add_child(icon)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)
	var head := Label.new()
	head.text = "%s%s" % [craft.name, (" x%d" % craft.out_count) if craft.out_count > 1 else ""]
	head.add_theme_font_size_override("font_size", 15)
	head.add_theme_color_override("font_color", UiTheme.TEXT if craft.can else UiTheme.TEXT_DIM)
	text.add_child(head)
	for ing: Dictionary in craft.inputs:
		var l := Label.new()
		l.text = "%d x %s   (%d)" % [ing.count, ing.label, ing.have]
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", UiTheme.GOOD if ing.have >= ing.count else UiTheme.BAD)
		text.add_child(l)
	var b := Button.new()
	b.text = "Craft"
	b.disabled = not craft.can
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(_on_craft.bind(craft))
	row.add_child(b)
	return box

func _on_craft(craft: Dictionary) -> void:
	var res := Crafter.craft(craft, _kit.inventory, _kit.belt)
	message.emit(res.msg, UiTheme.GOOD if res.ok else UiTheme.BAD)
	refresh()

static func _title(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", UiTheme.TEXT)
	return l
