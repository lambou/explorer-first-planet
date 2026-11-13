class_name SlotView
extends Control
## One square of the UI: a stack (item picture + count) or a tool (its Blender picture), with an optional key hint, a
## highlight when selected, and a click signal. Display only; whoever owns it decides what a click means.

signal clicked(button: int)

var def: ItemDef                      # the item shown (or null)
var count := 0
var texture: Texture2D                # a picture instead of the drawn item (tools)
var selected := false
var dim := false                      # shown but not available (greyed)
var hotkey := ""
var show_count := true
var fuel := -1.0                      # 0..1 burn bar along the bottom (torches); -1 = none

func _init(p_size: float = UiTheme.SLOT) -> void:
	custom_minimum_size = Vector2(p_size, p_size)
	mouse_filter = Control.MOUSE_FILTER_STOP

func set_stack(stack: Dictionary) -> void:
	if stack.is_empty():
		def = null
		count = 0
	else:
		def = ItemCatalog.get_def(stack.id)
		count = stack.count
	texture = null
	queue_redraw()

func set_tool(tex: Texture2D, n: int) -> void:
	def = null
	texture = tex
	count = n
	queue_redraw()

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		clicked.emit(e.button_index)
		accept_event()

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, UiTheme.SLOT_BG)
	draw_rect(r, UiTheme.SELECTED if selected else UiTheme.SLOT_EDGE, false, 3.0 if selected else 1.0)
	if texture != null:
		draw_texture_rect(texture, r.grow(-size.x * 0.03), false, Color(1, 1, 1, 0.45 if dim else 1.0))
	elif def != null:
		ItemIcon.draw(self, r.grow(-size.x * 0.12), def)
		if dim:
			draw_rect(r, Color(0, 0, 0, 0.45))
	if fuel >= 0.0:
		var bar := Rect2(4, size.y - 8, size.x - 8, 4)
		draw_rect(bar, Color(0, 0, 0, 0.6))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * fuel, bar.size.y)), UiTheme.WARN if fuel > 0.15 else UiTheme.BAD)
	if hotkey != "":
		UiTheme.text(self, Vector2(4, 13), hotkey, 11, UiTheme.TEXT_DIM)
	if show_count and count > 1:
		UiTheme.text(self, Vector2(0, size.y - 4), str(count), 13, UiTheme.TEXT, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 4)
