class_name AimOverlay
extends Control
## The RETICLE: a small ring and dot at the aim, ALWAYS there while the game is played (shooting and throwing will aim with it): white on the
## ground or at nothing, yellow on a rock or tree in reach, RED out of reach (the tool does nothing there). It is drawn from the screen position
## alone and cannot be delayed by any world query. It never takes part in moving the camera. Display only.

var cursor := Vector2.ZERO
var state := 0                       # 0 nothing under the cursor, 1 ground in reach, 2 out of reach, 3 a rock or tree in reach
var shown := true
var centre := Vector2.ZERO
var radius := 0.0                    # the action perimeter (0 = none drawn)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func update_state(p_cursor: Vector2, p_state: int, p_shown: bool, p_centre: Vector2 = Vector2.ZERO, p_radius: float = 0.0) -> void:
	centre = p_centre
	radius = p_radius
	cursor = p_cursor
	state = p_state
	shown = p_shown
	queue_redraw()

func _draw() -> void:
	if not shown:
		return                                       # only while the game holds the mouse; never because of what is (or is not) under it
	if radius > 0.0:
		var n := 48
		for i in range(0, n, 2):
			draw_arc(centre, radius, TAU * i / n, TAU * (i + 1) / n, 4, Color(1, 1, 1, 0.22), 2.0, true)       # the perimeter: past it the mouse turns the camera
	var col := Color(1, 1, 1, 0.95)
	if state == 2:
		col = Color(1.0, 0.3, 0.25, 0.95)            # out of reach
	elif state == 3:
		col = Color(1.0, 0.85, 0.3, 1.0)
	draw_arc(cursor, 11.0, 0.0, TAU, 24, Color(0, 0, 0, 0.45), 4.0, true)
	draw_arc(cursor, 11.0, 0.0, TAU, 24, col, 2.0, true)
	draw_circle(cursor, 2.5, col)
