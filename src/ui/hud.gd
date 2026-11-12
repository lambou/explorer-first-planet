class_name Hud
extends CanvasLayer
## Info panel (coordinates, altitude vs sea level, limits). Display only: no game logic.

var _label: Label
var radar: Radar

func _ready() -> void:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", sb)
	panel.position = Vector2(12, 12)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	panel.add_child(_label)
	add_child(panel)
	radar = Radar.new()
	add_child(radar)
	var cross := Label.new()
	cross.text = "+"
	cross.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	add_child(cross)

func set_text(t: String) -> void:
	_label.text = t
