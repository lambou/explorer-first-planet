class_name ToastFeed
extends Control
## Short messages above the inventory bar ("+2 Clay", "Too heavy to carry"): they stack, last a few seconds, fade out.

const LIFE := 3.2
const MAX_LINES := 4

var _box: VBoxContainer
var _lines: Array = []               # [Label, time left]

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_box = VBoxContainer.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.alignment = BoxContainer.ALIGNMENT_END
	add_child(_box)
	_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 108)

func push(text: String, color: Color = UiTheme.TEXT) -> void:
	if text == "":
		return
	if not _lines.is_empty() and (_lines[-1][0] as Label).text == text:
		_lines[-1][1] = LIFE                                   # the same message again: keep it, do not stack copies
		return
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 5)
	_box.add_child(l)
	_lines.append([l, LIFE])
	while _lines.size() > MAX_LINES:
		_drop(0)

func _process(delta: float) -> void:
	for i in range(_lines.size() - 1, -1, -1):
		_lines[i][1] -= delta
		(_lines[i][0] as Label).modulate.a = clampf(_lines[i][1] / 0.8, 0.0, 1.0)
		if _lines[i][1] <= 0.0:
			_drop(i)

func _drop(i: int) -> void:
	(_lines[i][0] as Label).queue_free()
	_lines.remove_at(i)
