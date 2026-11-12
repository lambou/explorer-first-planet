class_name AimOverlay
extends Control
## Draws the mouse tool on screen: the faint ACTION PERIMETER (inside it the mouse moves the tool freely; pushing
## the mouse past its edge turns the camera) and the cursor (a ring and a dot). Display only.

var centre := Vector2.ZERO
var radius := 200.0
var cursor := Vector2.ZERO
var state := 0                       # 0 nothing under the tool, 1 in reach, 2 out of reach, 3 a rock in reach
var pushing := false                 # the mouse is at the perimeter and turning the camera
var shown := true

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func update_state(p_centre: Vector2, p_radius: float, p_cursor: Vector2, p_state: int, p_pushing: bool, p_shown: bool) -> void:
	centre = p_centre
	radius = p_radius
	cursor = p_cursor
	state = p_state
	pushing = p_pushing
	shown = p_shown
	queue_redraw()

func _draw() -> void:
	if not shown:
		return
	# the perimeter: a dashed circle, brighter while the mouse pushes against it
	var a := 0.55 if pushing else 0.22
	var n := 48
	for i in n:
		if i % 2 == 0:
			var a0 := TAU * i / n
			var a1 := TAU * (i + 1) / n
			draw_arc(centre, radius, a0, a1, 4, Color(1, 1, 1, a), 2.0, true)
	var col := Color(1, 1, 1, 0.95)
	match state:
		2: col = Color(1.0, 0.3, 0.25, 0.95)
		3: col = Color(1.0, 0.85, 0.3, 1.0)
	draw_arc(cursor, 11.0, 0.0, TAU, 24, Color(0, 0, 0, 0.45), 4.0, true)
	draw_arc(cursor, 11.0, 0.0, TAU, 24, col, 2.0, true)
	draw_circle(cursor, 2.5, col)
