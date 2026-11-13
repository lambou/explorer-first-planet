class_name LoadingScreen
extends CanvasLayer
## The screen shown while the world builds around the explorer: a progress bar, what is being done, and a tip.
## Display only: whoever loads reports the progress (0..1); `finish()` fades it away.

const TIPS := [
	"Dig the ground: soil gives clay, deeper you find the rock of the region.",
	"You carry at most 100 kg. Press four clay into a brick to store it.",
	"Press Tab or I for the inventory and crafting. Your first goal: a torch.",
	"The mouse turns the camera. The cross in the middle is where your tool works. Esc gives the mouse back.",
	"W walks where the camera faces, and he always faces it. Hold Shift to run.",
	"T plants a torch where you point, E picks it up. Torches burn down.",
	"Coal makes a torch burn 15 minutes, bundled wood only 5.",
	"A tree between you and the camera fades away: nothing hides you.",
]

var _bar: ProgressBar
var _status: Label
var _tip: Label
var _shown := 0.0

func _init() -> void:
	layer = 100
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.08, 0.13)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.name = "Bg"
	add_child(bg)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size = Vector2(520, 0)
	bg.add_child(box)
	var title := Label.new()
	title.text = "EXPLORER UNIVERSE"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", UiTheme.TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 16)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.31, 0.80, 0.52)
	fill.set_corner_radius_all(8)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(1, 1, 1, 0.10)
	back.set_corner_radius_all(8)
	_bar.add_theme_stylebox_override("fill", fill)
	_bar.add_theme_stylebox_override("background", back)
	box.add_child(_bar)
	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", UiTheme.TEXT_DIM)
	box.add_child(_status)
	_tip = Label.new()
	_tip.text = TIPS[randi() % TIPS.size()]
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip.add_theme_font_size_override("font_size", 14)
	_tip.add_theme_color_override("font_color", UiTheme.TEXT)
	box.add_child(_tip)
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	set_progress(0.0)

## `p`: 0..1 of the ground around the explorer that is built.
func set_progress(p: float) -> void:
	_shown = maxf(_shown, clampf(p, 0.0, 1.0))                # never moves backwards
	_bar.value = _shown
	var stage := "Shaping the planet..."
	if _shown > 0.35:
		stage = "Growing the forests..."
	if _shown > 0.7:
		stage = "Laying the ground under your feet..."
	if _shown >= 0.999:
		stage = "Ready"
	_status.text = "%s  %d%%" % [stage, int(_shown * 100.0)]

func finish() -> void:
	var bg := get_node("Bg") as Control
	var tw := create_tween()
	tw.tween_property(bg, "modulate:a", 0.0, 0.5)
	tw.tween_callback(queue_free)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
