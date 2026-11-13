class_name ToolRig
extends Node3D
## The tool in the ball's "hand", seen in the world. It holds the model from Blender for the selected tool beside the ball,
## and plays the use: the tool goes to the point it works on (the pickaxe winds up and drives its point in, the bucket dips
## into the water), and at the moment of contact it says so (`struck`), so the world changes when the blow lands, not when
## the button went down. Display and timing only: what the blow does is ToolUser's job.

signal struck(target: Dictionary)

const SCALE := ToolCatalog.MODEL_SCALE
const GRIP := 0.64                    # pickaxe: grip to the middle of the head (m), the model's own measure
const WATER_MODEL_Z := 0.22           # bucket: height of the water disc above the bucket's bottom, as modelled in Blender
const DURATION := {ToolDef.MINE: 0.5, ToolDef.SCOOP: 0.85, ToolDef.LIGHT: 0.0}
const IMPACT := 0.5                   # share of the use time at which the blow lands
const WIND_END := 0.36                # share at which the wind-up ends and the blow starts (the character leans with it)

var player: Node3D
var cam: OrbitCamera
var kit: PlayerKit
var busy := false                     # a use is playing
var character: PlayerCharacter        # when set, the tool rests on the side the character faces (not the camera side)
var _model: Node3D
var _tool: ToolDef
var _water: MeshInstance3D
var _fire: TorchFlame                 # the flame of a torch in the hand (its light is the torch's own)
var _u := 0.0                         # progress of the use, 0..1
var _dur := 0.5
var _target := {}
var _struck := false
var _t := 0.0

func setup(p_player: Node3D, p_cam: OrbitCamera, p_kit: PlayerKit) -> void:
	player = p_player
	cam = p_cam
	kit = p_kit
	top_level = true
	kit.belt.selected.connect(func(_id: String) -> void: _equip())
	kit.inventory.changed.connect(_refresh_water)
	_equip()

## Swing the current tool at `target` (a ToolAim target; optional "lift": how far above its point the tool should end up,
## for the bucket to dip into the surface). Does nothing while a use is playing.
func begin_use(target: Dictionary) -> void:
	if busy or _tool == null:
		return
	_dur = DURATION.get(_tool.action, 0.5)
	if _dur <= 0.0:
		return
	_target = target.duplicate()
	_u = 0.0
	_struck = false
	busy = true

## Progress of the use playing (0..1), or -1 when none.
func use_progress() -> float:
	return _u if busy else -1.0

## The point the use is aimed at.
func use_target() -> Vector3:
	return _target.get("point", Vector3.ZERO)

## Where the tool is held (its grip), or null when no tool is shown: the character's hand goes there.
func grip_world() -> Variant:
	if _model == null or not _model.visible:
		return null
	return _model.global_position

func use_time() -> float:
	return _dur

func _equip() -> void:
	if _model != null:
		_model.queue_free()
		_model = null
	_water = null
	_fire = null
	_tool = kit.belt.current()
	busy = false
	if _tool == null:
		return
	var scene := load(_tool.model_path) as PackedScene
	if scene == null:
		push_warning("tool model missing: %s (run tools/blender/build_tools.py, then open the project once to import it)" % _tool.model_path)
		return
	_model = scene.instantiate()
	add_child(_model)
	_water = _model.find_child("Water", true, false) as MeshInstance3D
	_fire = TorchFlame.attach(_model)
	_refresh_water()

## The water in the bucket follows what is carried.
func _refresh_water() -> void:
	if _water == null:
		return
	var fill := kit.bucket_fill()
	_water.visible = fill > 0.02
	var z := 0.03 + 0.24 * fill                                    # height of the surface above the bucket's bottom (model measures)
	var inner := 0.123 + 0.049 * (z - 0.03) / 0.27                 # the bucket widens: the disc must fit the wall at that height
	_water.position.y = z - WATER_MODEL_Z                           # the disc is modelled at WATER_MODEL_Z: this is how far to move it
	_water.scale = Vector3(inner / 0.158, 1.0, inner / 0.158)

func _process(delta: float) -> void:
	_t += delta
	if player == null or _model == null:
		return
	var up := player.global_position.normalized()
	var fwd := _flat(character.facing if character != null else cam.view_fwd, up)
	var right := fwd.cross(up).normalized()
	var rest := _rest(up, fwd, right)
	var pose := rest
	if busy:
		_u += delta / _dur
		pose = _use_pose(rest, up, right)
		if not _struck and _u >= IMPACT:
			_struck = true
			struck.emit(_target)
		if _u >= 1.0:
			busy = false
			pose = rest
	_model.global_transform = Transform3D(_basis(pose.h, right).scaled(Vector3.ONE * SCALE), pose.pos)
	if _fire != null:
		var left := kit.belt.fuel_left(_tool.id)                       # a torch nearly out burns low
		_fire.flicker(_t, 1.0 if left < 0.0 else clampf(left / ToolCatalog.TORCH_DIM_SECONDS, 0.0, 1.0))

func _flat(v: Vector3, up: Vector3) -> Vector3:
	var f := v - up * v.dot(up)
	return f.normalized() if f.length() > 0.001 else Vector3.FORWARD

## The tool at rest: beside the ball, on the right, as it bobs along.
func _rest(up: Vector3, fwd: Vector3, right: Vector3) -> Dictionary:
	var bob := up * sin(_t * 2.2) * 0.025
	var hand: Vector3 = player.global_position + right * 0.62 + up * 0.20 + fwd * 0.05          # where the tool is held: the character's hand
	if character != null:
		var hw: Variant = character.hand_rest_world()
		if hw != null:
			hand = hw
	hand += bob
	match _tool.action:
		ToolDef.SCOOP:
			var sway := sin(_t * 1.7) * 0.07
			return {"pos": hand + right * 0.10, "h": (up + right * sway + fwd * cos(_t * 1.3) * 0.04).normalized()}
		ToolDef.LIGHT:
			return {"pos": hand, "h": (up + right * 0.12).normalized()}
	return {"pos": hand, "h": (up + right * 0.35 - fwd * 0.30).normalized()}

## The tool during a use: keyframes (progress, position of the grip, direction of the handle) between rest and the target.
func _use_pose(rest: Dictionary, up: Vector3, right: Vector3) -> Dictionary:
	var tp: Vector3 = _target.point
	var tn: Vector3 = _target.normal
	var lift: float = _target.get("lift", 0.0)
	var afwd := _flat(tp - player.global_position, up)
	var keys: Array
	if _tool.action == ToolDef.SCOOP:
		var dip := tp + up * (lift + 0.38 * SCALE)                          # the bucket's bottom ends a little under the surface
		var tilt := (up + afwd * 0.30).normalized()
		keys = [
			[0.0, rest.pos, rest.h],
			[0.30, tp + up * (lift + 1.2) - afwd * 0.1, up],
			[0.5, dip, tilt],
			[0.62, dip, tilt],
			[0.82, tp + up * (lift + 1.1), up],
			[1.0, rest.pos, rest.h],
		]
	else:
		var wind_h := (up * 0.85 - afwd * 0.55).normalized()
		var hit_h := (afwd * 0.75 - up * 0.65).normalized()
		var hit_pos := tp + tn * 0.10 - hit_h * GRIP * SCALE                # the head ends on the point
		keys = [
			[0.0, rest.pos, rest.h],
			[WIND_END, tp - afwd * 0.1 + up * 0.35, wind_h],
			[0.5, hit_pos, hit_h],
			[0.6, hit_pos + tn * 0.22, (hit_h + tn * 0.25).normalized()],
			[1.0, rest.pos, rest.h],
		]
	for i in keys.size() - 1:
		var a: Array = keys[i]
		var b: Array = keys[i + 1]
		if _u <= b[0]:
			var k := clampf((_u - a[0]) / (b[0] - a[0]), 0.0, 1.0)
			# the drive into the target is a fall (it speeds up), every other leg eases in and out
			k = k * k if (_tool.action == ToolDef.MINE and i == 1) else smoothstep(0.0, 1.0, k)
			return {"pos": (a[1] as Vector3).lerp(b[1], k), "h": (a[2] as Vector3).slerp(b[2], k)}
	return rest

## The tool's frame: +Y along the handle, its X sideways (to the ball's right).
func _basis(h: Vector3, right: Vector3) -> Basis:
	var x := right - h * right.dot(h)
	x = x.normalized() if x.length() > 0.001 else Vector3.RIGHT
	return Basis(x, h, x.cross(h))
