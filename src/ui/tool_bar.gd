class_name ToolBar
extends Control
## The tools, in a column at the top right of the screen: each with its picture from Blender, the one in hand
## highlighted. [Q] takes the next tool; a click selects one while the mouse is free. Display only: it reads the Toolbelt.

var _belt: Toolbelt
var _column: VBoxContainer
var _name: Label
var _views: Array[SlotView] = []

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_column = VBoxContainer.new()
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_theme_constant_override("separation", int(UiTheme.GAP))
	add_child(_column)
	_name = Label.new()
	_name.add_theme_font_size_override("font_size", 12)
	_name.add_theme_color_override("font_color", UiTheme.TEXT)
	_name.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_name.add_theme_constant_override("outline_size", 4)
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE

func bind(belt: Toolbelt) -> void:
	_belt = belt
	belt.changed.connect(refresh)
	refresh()

func refresh() -> void:
	for v in _views:
		_column.remove_child(v)
		v.queue_free()
	_views.clear()
	if _name.get_parent() == _column:
		_column.remove_child(_name)
	for i in _belt.tools.size():
		var def := ToolCatalog.get_def(_belt.tools[i])
		var v := SlotView.new(UiTheme.SLOT + 6)
		v.set_tool(load(def.icon_path) as Texture2D, _belt.count_of(def.id))
		v.selected = (i == _belt.index)
		v.size_flags_horizontal = Control.SIZE_SHRINK_END
		v.tooltip_text = "%s\n%s" % [def.name, def.hint]
		v.clicked.connect(_on_clicked.bind(i))
		_column.add_child(v)
		_views.append(v)
	var cur := _belt.current()
	_name.text = ("%s  [Q]" % cur.name) if cur != null else ""
	_column.add_child(_name)
	_column.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 14)
	_column.grow_horizontal = Control.GROW_DIRECTION_BEGIN

## The fuel left in a torch changes every moment: only its bar is redrawn, the column is not rebuilt.
func _process(_delta: float) -> void:
	if _belt == null:
		return
	for i in _views.size():
		var def := ToolCatalog.get_def(_belt.tools[i])
		if def.burn_seconds > 0.0 and not _belt.fuel[def.id].is_empty():
			var left: float = _belt.fuel[def.id][0]
			_views[i].fuel = clampf(left / def.burn_seconds, 0.0, 1.0)
			_views[i].queue_redraw()
	var cur := _belt.current()
	if cur != null:
		var l := _belt.fuel_left(cur.id)
		_name.text = ("%s  %d:%02d  [Q]" % [cur.name, int(l) / 60, int(l) % 60]) if l >= 0.0 else ("%s  [Q]" % cur.name)

func _on_clicked(_button: int, i: int) -> void:
	_belt.select(i)
