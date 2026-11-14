class_name Hud
extends CanvasLayer
## The screen: the info panel (coordinates, altitude vs sea level, limits), the radar, the aim overlay and the survival
## UI (tool bar top right, inventory bar bottom centre, the inventory screen, short messages). It shows the PlayerKit
## and turns the UI's own keys into changes of it; it never touches the world.
##   [Tab] / [I] inventory screen   [Q] next tool   [1]-[9] inventory bar slot   [F3] fold / unfold the info panel

signal menu_toggled(open: bool)

var enabled := true                    # false while the loading screen is up: the keys do nothing yet
var _label: Label
var _fold: Button
var _panel: PanelContainer
var radar: Radar
var aim_overlay: AimOverlay
var tool_bar: ToolBar
var inventory_bar: InventoryBar
var menu: InventoryMenu
var toasts: ToastFeed
var gear: GearWheel
var hints: KeyHints
var _kit: PlayerKit

func _ready() -> void:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", sb)
	panel.position = Vector2(12, 12)
	_panel = panel
	var col := VBoxContainer.new()
	panel.add_child(col)
	_fold = Button.new()                                  # the info panel is big: it folds away to one line
	_fold.flat = true
	_fold.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_fold.focus_mode = Control.FOCUS_NONE
	_fold.add_theme_font_size_override("font_size", 13)
	_fold.pressed.connect(toggle_info)
	col.add_child(_fold)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	col.add_child(_label)
	add_child(panel)
	_label.visible = false                                # folded at the start: it hides the view
	_update_fold()
	radar = Radar.new()
	add_child(radar)
	aim_overlay = AimOverlay.new()
	add_child(aim_overlay)
	tool_bar = ToolBar.new()
	add_child(tool_bar)
	inventory_bar = InventoryBar.new()
	add_child(inventory_bar)
	toasts = ToastFeed.new()
	add_child(toasts)
	menu = InventoryMenu.new()
	add_child(menu)
	menu.message.connect(toasts.push)
	menu.closed.connect(func() -> void: set_menu_open(false))
	hints = KeyHints.new()
	add_child(hints)
	gear = GearWheel.new()
	add_child(gear)

## Show this kit. Call once, after the Hud is in the tree.
func bind(kit: PlayerKit) -> void:
	_kit = kit
	tool_bar.bind(kit.belt)
	inventory_bar.bind(kit)
	menu.bind(kit)
	gear.bind(kit.belt)
	gear.picked.connect(func(i: int) -> void: kit.belt.select(i))
	kit.harvester.gathered.connect(_on_gathered)
	kit.torch_burnt_out.connect(func() -> void: toasts.push("Your torch burnt out", UiTheme.WARN))
	kit.belt.selected.connect(func(id: String) -> void: toasts.push(ToolCatalog.get_def(id).name))
	toasts.push("Keys are listed at the bottom left   [F3] info")

## The key caps at the bottom left: only what can be done now (no torch in the bag, no [T]).
func _process(_delta: float) -> void:
	if _kit == null:
		return
	var keys: Array = []
	if not menu_open():
		keys.append(["E", "Gear (hold)"])
		keys.append(["Q", "Next tool"])
		keys.append(["Tab", "Inventory / craft"])
		if _kit.belt.torch_to_plant() != "":
			keys.append(["T", "Plant torch"])
		keys.append(["Esc", "Free mouse"])
	hints.set_keys(keys)

func toggle_info() -> void:
	_label.visible = not _label.visible
	_update_fold()

func _update_fold() -> void:
	_fold.text = ("v Info   [F3]" if _label.visible else "> Info   [F3]")
	_panel.size = Vector2.ZERO                            # shrink to the content

func set_text(t: String) -> void:
	_label.text = t

func say(text: String, color: Color = UiTheme.TEXT) -> void:
	toasts.push(text, color)

func menu_open() -> bool:
	return menu.visible or gear.visible

func set_menu_open(open: bool) -> void:
	if open == menu.visible:
		return
	if open:
		menu.open()
	else:
		menu.close()
	menu_toggled.emit(open)

func _on_gathered(item_id: String, added: int, wanted: int) -> void:
	var d := ItemCatalog.get_def(item_id)
	if added <= 0:
		toasts.push("Too heavy to carry more %s  (%.1f / %.0f kg)" % [d.name.to_lower(), _kit.inventory.weight(), _kit.inventory.capacity_kg], UiTheme.BAD)
	elif added < wanted:
		toasts.push("+%d %s  (the rest is too heavy)" % [added, d.name], UiTheme.WARN)
	else:
		toasts.push("+%d %s" % [added, d.name], UiTheme.GOOD)

## `_input`, not `_unhandled_input`: the UI's own focus handling (Tab walks the buttons) must never swallow these keys.
func _input(event: InputEvent) -> void:
	if enabled and _kit != null and event is InputEventKey and event.physical_keycode == KEY_E and not event.echo:
		if event.pressed and not menu.visible and not gear.visible:
			gear.open()                                     # hold [E]: the gear wheel, release on a tool to equip it
		elif not event.pressed and gear.visible:
			gear.close(true)
		return
	if not enabled or _kit == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_F3:
			toggle_info()
		KEY_TAB, KEY_I:
			if not gear.visible:
				set_menu_open(not menu.visible)
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			if gear.visible:
				gear.close(false)
				get_viewport().set_input_as_handled()
			elif menu.visible:
				set_menu_open(false)
				get_viewport().set_input_as_handled()
		KEY_Q:
			_kit.belt.cycle(1)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
			_kit.select_bar_slot(event.physical_keycode - KEY_1)
			var stack: Dictionary = _kit.inventory.slots[_kit.bar_slot]
			if not stack.is_empty():
				toasts.push(ItemCatalog.get_def(stack.id).name)
