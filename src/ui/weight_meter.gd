class_name WeightMeter
extends Control
## "12.5 / 100 kg" on a bar that turns amber and then red as the pack gets full. Display only.

var carried := 0.0
var capacity := 100.0

func _init(p_width: float = 240.0) -> void:
	custom_minimum_size = Vector2(p_width, 18)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_load(p_carried: float, p_capacity: float) -> void:
	carried = p_carried
	capacity = p_capacity
	queue_redraw()

func _draw() -> void:
	var f := clampf(carried / maxf(capacity, 0.001), 0.0, 1.0)
	var col := UiTheme.GOOD if f < 0.7 else (UiTheme.WARN if f < 0.92 else UiTheme.BAD)
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0, 0, 0, 0.55))
	draw_rect(Rect2(r.position, Vector2(r.size.x * f, r.size.y)), col.darkened(0.15))
	draw_rect(r, UiTheme.SLOT_EDGE, false, 1.0)
	UiTheme.text(self, Vector2(0, size.y - 4), "%.1f / %.0f kg" % [carried, capacity], 12, UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER, size.x)
