class_name MainMenu
extends CanvasLayer
## The first screen: the title, the saved worlds (play or delete one), a new-world form (name, seed: empty = the usual world), Quit, and the explorer turning on a little stage.
## Display only: it announces `start_requested(seed_text)`, Boot does the rest.

signal start_requested(world_name: String, seed_text: String)      # a new world
signal continue_requested(world_id: String)                          # a saved world

var _stage_model: Node3D
var _seed: LineEdit
var _name: LineEdit
var _col: VBoxContainer
var _worlds_box: VBoxContainer
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
	_col = col
	_build_worlds()                   # (places the column once it has all its children)

## The world list and the new-world form (rebuilt when a world is deleted).
func _build_worlds() -> void:
	if _worlds_box != null:
		_worlds_box.queue_free()
	_worlds_box = VBoxContainer.new()
	_worlds_box.add_theme_constant_override("separation", 10)
	_col.add_child(_worlds_box)
	_col.move_child(_worlds_box, 3)
	var worlds := SaveGame.list()
	if not worlds.is_empty():
		var head := Label.new()
		head.text = "Worlds"
		head.add_theme_font_size_override("font_size", 16)
		head.add_theme_color_override("font_color", Color(0.15, 0.24, 0.35))
		_worlds_box.add_child(head)
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(0, mini(worlds.size(), 4) * 62)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_worlds_box.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 8)
		scroll.add_child(list)
		for w in worlds:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			list.add_child(row)
			var play := _button("%s
%s  ·  %d min" % [w.name, str(w.get("saved_at", "")).replace("T", " ").substr(0, 16), int(float(w.get("playtime", 0.0)) / 60.0)])
			play.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			play.add_theme_font_size_override("font_size", 15)
			play.tooltip_text = "Seed %s" % str(w.get("seed", "?"))
			play.pressed.connect(func() -> void: continue_requested.emit(w.id))
			row.add_child(play)
			var del := _button("Delete")
			del.add_theme_font_size_override("font_size", 14)
			del.pressed.connect(func() -> void:
				if del.text == "Delete":
					del.text = "Sure?"
				else:
					SaveGame.delete_world(w.id)
					_build_worlds())
			row.add_child(del)
			if row.get_index() == 0:
				play.grab_focus.call_deferred()
	var new_head := Label.new()
	new_head.text = "New world"
	new_head.add_theme_font_size_override("font_size", 16)
	new_head.add_theme_color_override("font_color", Color(0.15, 0.24, 0.35))
	_worlds_box.add_child(new_head)
	_name = LineEdit.new()
	_name.placeholder_text = "World name (e.g. your name)"
	_name.text_submitted.connect(func(_t: String) -> void: _on_start())
	_worlds_box.add_child(_name)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	_worlds_box.add_child(srow)
	_seed = LineEdit.new()
	_seed.placeholder_text = "World seed (empty: the usual world)"
	_seed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed.text_submitted.connect(func(_t: String) -> void: _on_start())
	srow.add_child(_seed)
	var rnd := Button.new()
	rnd.text = "Random"
	rnd.focus_mode = Control.FOCUS_NONE
	rnd.pressed.connect(func() -> void: _seed.text = str(WorldConfig.random_seed()))
	srow.add_child(rnd)
	var start := _button("Create world")
	start.pressed.connect(_on_start)
	_worlds_box.add_child(start)
	if worlds.is_empty():
		start.grab_focus.call_deferred()
	var quit := _button("Quit")
	quit.pressed.connect(func() -> void: get_tree().quit())
	_worlds_box.add_child(quit)
	_col.set_anchors_and_offsets_preset.call_deferred(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 90)

static func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 48)
	b.add_theme_font_size_override("font_size", 20)
	return b

func _on_start() -> void:
	start_requested.emit(_name.text, _seed.text)

func _process(delta: float) -> void:
	_t += delta
	if _stage_model != null:
		_stage_model.rotation.y = PI - 0.4 + sin(_t * 0.7) * 0.35             # faces the camera (the model looks along -z), a little towards the menu, swaying as if looking around
		_stage_model.position.y = -0.45 + absf(sin(_t * 1.6)) * 0.07           # and bounces a little
