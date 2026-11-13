class_name TorchFlame
extends RefCounted
## The fire of a torch model from Blender: finds its flame meshes and the "FlamePoint" empty, hangs a real light there and
## flickers both. Shared by the torch in the hand (ToolRig) and the torches planted in the world (PlacedTorches).
## The light is the flame's own: a few metres wide, falling off with distance. It belongs to the torch, never to the ball.

const ENERGY := 1.5
const RANGE := 11.0

var flames: Array = []
var light: OmniLight3D
var phase := 0.0                      # so two torches never flicker in step
var timer: Label3D                    # the time this torch has left, floating over its flame
var _shown := -1                       # the whole seconds the label shows now (it is rewritten only when they change)
var power := 1.0                      # the strength of this torch's light: the model's FlamePoint scale (a big torch lights more)

static func attach(model: Node3D, p_phase: float = 0.0) -> TorchFlame:
	var tf := TorchFlame.new()
	tf.phase = p_phase
	for n in ["Flame", "FlameCore"]:
		var f := model.find_child(n, true, false) as MeshInstance3D
		if f != null:
			tf.flames.append(f)
			f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tip := 0.0
	for fl: MeshInstance3D in tf.flames:
		tip = maxf(tip, fl.position.y + fl.get_aabb().end.y)          # the top of the flame, in the model's own measures
	tf.timer = Label3D.new()
	tf.timer.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tf.timer.shaded = false
	tf.timer.double_sided = true
	tf.timer.pixel_size = 0.0022
	tf.timer.font_size = 56
	tf.timer.outline_size = 14
	tf.timer.modulate = Color(1.0, 0.92, 0.7)
	tf.timer.outline_modulate = Color(0.1, 0.06, 0.03)
	tf.timer.position = Vector3(0.0, tip + 0.13, 0.0)
	tf.timer.visible = false                                          # shown once the torch is given its time (flicker with `left`)
	model.add_child(tf.timer)
	var anchor := model.find_child("FlamePoint", true, false)
	if anchor != null:
		tf.power = anchor.scale.x
		tf.light = OmniLight3D.new()
		tf.light.light_color = Color(1.0, 0.55, 0.24)
		tf.light.light_energy = ENERGY * tf.power
		tf.light.omni_range = RANGE * tf.power
		tf.light.omni_attenuation = 1.3
		anchor.add_child(tf.light)
	return tf

## "4:32": the time left, rounded up to the second.
static func clock(seconds: float) -> String:
	var s := ceili(maxf(seconds, 0.0))
	return "%d:%02d" % [s / 60, s % 60]

## `intensity` 0..1: a torch nearly out burns low (flame and light sink). `left`: seconds of fuel left (-1: do not show a timer).
func flicker(t: float, intensity: float = 1.0, left: float = -1.0) -> void:
	if timer != null and left >= 0.0:
		var s := ceili(left)
		if s != _shown:
			_shown = s
			timer.text = clock(left)
			timer.visible = true
			timer.modulate = Color(1.0, 0.92, 0.7) if left > ToolCatalog.TORCH_DIM_SECONDS else Color(1.0, 0.45, 0.3)     # red in its last seconds
	t += phase
	var f := 0.86 + 0.14 * sin(t * 17.0) * sin(t * 5.3 + 1.0) + 0.04 * sin(t * 41.0)
	if light != null:
		light.light_energy = ENERGY * power * f * intensity
	for fl: MeshInstance3D in flames:
		var k := lerpf(0.35, 1.0, intensity)
		fl.scale = Vector3(k * (1.0 + 0.06 * sin(t * 23.0)), k * (1.0 + 0.12 * f - 0.1), k * (1.0 + 0.06 * cos(t * 19.0)))
