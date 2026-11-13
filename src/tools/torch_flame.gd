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
var power := 1.0                      # the strength of this torch's light: the model's FlamePoint scale (a big torch lights more)

static func attach(model: Node3D, p_phase: float = 0.0) -> TorchFlame:
	var tf := TorchFlame.new()
	tf.phase = p_phase
	for n in ["Flame", "FlameCore"]:
		var f := model.find_child(n, true, false) as MeshInstance3D
		if f != null:
			tf.flames.append(f)
			f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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

## `intensity` 0..1: a torch nearly out burns low (flame and light sink).
func flicker(t: float, intensity: float = 1.0) -> void:
	t += phase
	var f := 0.86 + 0.14 * sin(t * 17.0) * sin(t * 5.3 + 1.0) + 0.04 * sin(t * 41.0)
	if light != null:
		light.light_energy = ENERGY * power * f * intensity
	for fl: MeshInstance3D in flames:
		var k := lerpf(0.35, 1.0, intensity)
		fl.scale = Vector3(k * (1.0 + 0.06 * sin(t * 23.0)), k * (1.0 + 0.12 * f - 0.1), k * (1.0 + 0.06 * cos(t * 19.0)))
