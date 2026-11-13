class_name AimOverlay
extends Control
## Marks what the tool would work on: a small ring and dot at the cursor while it points at something (the ground, a rock, a tree):
## white / yellow within reach, RED out of reach (the tool does nothing there). It is secondary: it never takes part in moving the
## camera, and shows nothing when the cursor points at nothing. Display only.

var cursor := Vector2.ZERO
var state := 0                       # 0 nothing under the cursor, 1 ground in reach, 2 out of reach, 3 a rock or tree in reach
var shown := true

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func update_state(p_cursor: Vector2, p_state: int, p_shown: bool) -> void:
	cursor = p_cursor
	state = p_state
	shown = p_shown
	queue_redraw()

func _draw() -> void:
	if not shown or state == 0:
		return                                       # the cursor points at nothing: only the system cursor
	var col := Color(1, 1, 1, 0.95)
	if state == 2:
		col = Color(1.0, 0.3, 0.25, 0.95)            # out of reach
	elif state == 3:
		col = Color(1.0, 0.85, 0.3, 1.0)
	draw_arc(cursor, 11.0, 0.0, TAU, 24, Color(0, 0, 0, 0.45), 4.0, true)
	draw_arc(cursor, 11.0, 0.0, TAU, 24, col, 2.0, true)
	draw_circle(cursor, 2.5, col)
