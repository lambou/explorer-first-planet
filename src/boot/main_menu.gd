class_name MainMenu
extends CanvasLayer
## The first screen: the title, a seed field (empty = the usual world), Start and Quit, and the explorer turning on a little stage.
## Display only: it announces `start_requested(seed_text)`, Boot does the rest.

signal start_requested(seed_text: String)      # a new game
signal continue_requested                       # the saved game

var _stage_model: Node3D
var _seed: LineEdit
var _start: Button
var _armed := false                  # a saved game exists: the first click on New game only asks, the second replaces it
var _t := 0.0

func _init() -> void:
	layer = 50
	var sky := TextureRect.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(0.50, 0.74, 0.95))
	grad.set_color(1, Color(0.80, 0.92, 0.82))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0.5, 0.0)
	gt.fill_to = Vector2(0.5, 1.0)
	sky.texture = gt
	sky.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky.stretch_mode = TextureRect.STRETCH_SCALE
	sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(sky)

	# the explorer on his stage (an own little 3D world, so it never touches the game's)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky.add_child(svc)
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.handle_input_locally = false
	svc.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.80, 0.9)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -30, 0)
	sun.light_energy = 0.9
	vp.add_child(sun)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.35, 5.2)
	cam.fov = 38.0
	vp.add_child(cam)
	var scene := load(PlayerCharacter.MODEL) as PackedScene
	if scene != null:
		_stage_model = scene.instantiate()
		_stage_model.scale = Vector3.ONE * 1.5
		_stage_model.position = Vector3(1.3, -0.45, 0)
		vp.add_child(_stage_model)

	# the menu itself, on the left
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.custom_minimum_size = Vector2(380, 0)
	sky.add_child(col)
	var title := Label.new()
	title.text = "EXPLORER\nUNIVERSE"
	title.add_theme_font_size_override("font_size", 58)
	title.add_theme_color_override("font_color", Color(0.10, 0.17, 0.27))
	title.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.8))
	title.add_theme_constant_override("outline_size", 6)
	col.add_child(title)
	var sub := Label.new()
	sub.text = "Dig, craft, light your first torch.\nSurvive on a round planet."
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", Color(0.15, 0.24, 0.35))
	col.add_child(sub)
	col.add_child(Control.new())
	var has_save := SaveGame.exists()
	var start := _button("New game" if has_save else "Start")
	start.pressed.connect(_on_start)
	_start = start
	if has_save:
		var info := SaveGame.info()
		var cont := _button("Continue")
		cont.tooltip_text = "Saved %s, seed %s" % [info.get("saved_at", "?"), info.get("seed", "?")]
		cont.pressed.connect(func() -> void: continue_requested.emit())
		col.add_child(cont)
		var when := Label.new()
		when.text = "Saved %s   (%d min played)" % [str(info.get("saved_at", "")).replace("T", " "), int(float(info.get("playtime", 0.0)) / 60.0)]
		when.add_theme_font_size_override("font_size", 13)
		when.add_theme_color_override("font_color", Color(0.15, 0.24, 0.35))
		col.add_child(when)
		cont.grab_focus()
	col.add_child(start)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	_seed = LineEdit.new()
	_seed.placeholder_text = "World seed (empty: the usual world)"
	_seed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed.text_submitted.connect(func(_t: String) -> void: _on_start())
	row.add_child(_seed)
	var rnd := Button.new()
	rnd.text = "Random"
	rnd.focus_mode = Control.FOCUS_NONE
	rnd.pressed.connect(func() -> void: _seed.text = str(WorldConfig.random_seed()))
	row.add_child(rnd)
	var quit := _button("Quit")
	quit.pressed.connect(func() -> void: get_tree().quit())
	col.add_child(quit)
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 90)     # placed once it has all its children
	if not has_save:
		start.grab_focus()

static func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 48)
	b.add_theme_font_size_override("font_size", 20)
	return b

func _on_start() -> void:
	if SaveGame.exists() and not _armed:
		_armed = true
		_start.text = "Click again: this replaces your saved game"
		return
	start_requested.emit(_seed.text)

func _process(delta: float) -> void:
	_t += delta
	if _stage_model != null:
		_stage_model.rotation.y = PI - 0.4 + sin(_t * 0.7) * 0.35             # faces the camera (the model looks along -z), a little towards the menu, swaying as if looking around
		_stage_model.position.y = -0.45 + absf(sin(_t * 1.6)) * 0.07           # and bounces a little
