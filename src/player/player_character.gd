class_name PlayerCharacter
extends Node3D
## The explorer you see: a round mint-green blob with a leaf sprout, from Blender (assets/character/explorer.glb), made of separate
## parts that float around the body: no legs, no arms, a clear gap between the body and the boots. It is only the look. The physics is the invisible ball (BallPlayer); this node
## follows the ball, stands on the planet's up, faces where it walks and animates from what the ball does:
##   - idle: breathes and blinks, feet planted; WALK and RUN (Shift): the feet step in turns, the body bobs and leans, the hands swing;
##   - FEET FOLLOW THE GROUND: each boot probes the terrain under itself and takes its height and slope, so on a stair or a slope one
##     boot rests on the upper step and the other on the lower one, each tilted to its surface;
##   - JUMP: stretches going up with the feet tucked, then falls with them hanging; LANDING squashes the body;
##   - SWING: the body winds up and leans into the blow, faces the target; the right hand holds the tool (it goes where the tool goes).
## Reads the ball and the tool rig, changes neither.

const MODEL := "res://assets/character/explorer.glb"
const RUN_AT := 4.4                    # m/s: above this the gait is a run
const FULL_SPEED := 6.5                # the speed at which stride, bob and lean are full
const SCALE := BallPlayer.VISUAL_SCALE   # how much bigger than the model he is drawn

var ball: BallPlayer
var rig: ToolRig
var facing := Vector3.FORWARD           # the way the character looks, along the ground
var aim_dir := Vector3.ZERO             # the way the camera faces: he always faces it, at once; zero = he faces his way
var look_pitch := 0.0                   # how far the camera looks up (+) or down (-), radians: his head follows half of it

var _model: Node3D
var _body: Node3D
var _body_rest := Vector3.ZERO           # where the body floats in the model (above the boots: the gap)
var _eyes: Array = []
var _feet: Array = []                   # [left, right]
var _hands: Array = []
var _rest := {}                         # node -> its position in the model (eyes: their scale)
var _phase := 0.0                       # the gait cycle
var _air := 0.0                         # 0 on the ground .. 1 in the air (smoothed)
var _land := 0.0                        # a landing squash that dies away
var _was_air := false
var _lean := 0.0
var _head := 0.0                        # the head pitch (smoothed)
var _speed := 0.0
var _blink := 3.0
var _t := 0.0
var _run := false                       # the gait is a run
var _dirm := Vector2(0, -1)               # the way he moves, in the model's own axes (forward = -z): he may walk sideways or backwards while facing the mouse
var _run_t := 0.0                       # 0 walk .. 1 run (smoothed: the cadence and the stride change gradually)
var _k := 3.4                           # gait cycle radians per metre walked
var _sprout: Node3D
var _leaves: Array = []
var _leaf_rest: Array = []              # each leaf's resting position relative to the sprout
var _leaf_spin := 0.0                   # the rotor's turn, radians: spins up in the air, like a helicopter
var _foot_xz: Array = [Vector2.ZERO, Vector2.ZERO]       # where each boot is (model space, along the ground): where it probes the terrain
var _probe: Array = [{"y": -0.5, "n": Vector3.UP}, {"y": -0.5, "n": Vector3.UP}]   # what the physics probe found under each boot (height, normal)
var _foot_y: Array = [-0.5, -0.5]       # smoothed ground height under each boot (model space; -0.5 = flat ground under the ball)
var _foot_n: Array = [Vector3.UP, Vector3.UP]

func setup(p_ball: BallPlayer, p_rig: ToolRig) -> void:
	ball = p_ball
	rig = p_rig
	process_priority = 10                # after the tool rig: the hand follows where the tool is this frame
	top_level = true
	var scene := load(MODEL) as PackedScene
	if scene == null:
		push_warning("character model missing: %s (run tools/blender/build_character.py, then open the project once to import it)" % MODEL)
		return
	_model = scene.instantiate()
	add_child(_model)
	_model.scale = Vector3.ONE * SCALE
	_model.position = Vector3(0, 0.5 * (SCALE - 1.0), 0)            # scaled about the soles: they stay on the ground (the ball centre is 0.5 m above it)
	_body = _model.find_child("Body", true, false)
	_body_rest = _body.position
	for n in ["EyeL", "EyeR", "ShineL", "ShineR", "Nose", "Sprout"]:
		var f := _model.find_child(n, true, false) as Node3D
		if f != null:
			f.reparent(_body, true)                    # the face and the sprout squash and lean with the body
			if n.begins_with("Eye"):
				_eyes.append(f)
	_sprout = _model.find_child("Sprout", true, false)
	for n in ["LeafL", "LeafR"]:
		var lf := _model.find_child(n, true, false) as Node3D
		if lf != null and _sprout != null:
			lf.reparent(_sprout, true)
			_leaves.append(lf)
			_leaf_rest.append(lf.position)
	_feet = [_model.find_child("FootL", true, false), _model.find_child("FootR", true, false)]
	_hands = [_model.find_child("HandL", true, false), _model.find_child("HandR", true, false)]
	for n: Node3D in _feet + _hands:
		_rest[n] = n.position
	if rig != null and rig.cam != null:
		facing = rig.cam.view_fwd

func _process(delta: float) -> void:
	if _model == null or ball == null:
		return
	_t += delta
	visible = ball.visible
	var p := ball.global_position
	var up := p.normalized()
	var v := ball.linear_velocity
	var vv := v.dot(up)
	var vt := v - up * vv
	var speed := vt.length()
	_speed = lerpf(_speed, speed, 1.0 - exp(-delta * 10.0))
	var use := rig.use_progress() if rig != null else -1.0

	# where to look: at the target while swinging, else exactly where the camera faces (no lag), else the way he walks
	var want := _flat(facing, up, Vector3.FORWARD)
	if use >= 0.0:
		want = _flat(rig.use_target() - p, up, want)
		facing = _flat(_flat(facing, up, want).slerp(want, 1.0 - exp(-delta * 14.0)), up, want)
	elif aim_dir != Vector3.ZERO:
		facing = _flat(aim_dir, up, want)
	else:
		if speed > 0.4:
			want = _flat(vt, up, want)
		facing = _flat(_flat(facing, up, want).slerp(want, 1.0 - exp(-delta * 9.0)), up, want)
	global_transform = Transform3D(Basis.looking_at(facing, up), p)
	if speed > 0.4:                                        # which way the gait goes, relative to where he looks (forward, back or sideways)
		var vl := global_transform.basis.inverse() * vt
		var dm := Vector2(vl.x, vl.z).normalized()
		_dirm = _dirm.lerp(dm, 1.0 - exp(-delta * 12.0))
		if _dirm.length() < 0.05:
			_dirm = dm
		_dirm = _dirm.normalized()

	# air / ground and the landing squash
	var in_air := not ball.grounded and ball.in_water < 0.5
	_air = lerpf(_air, 1.0 if in_air else 0.0, 1.0 - exp(-delta * 14.0))
	if _was_air and not in_air:
		_land = 1.0
	_was_air = in_air
	_land = move_toward(_land, 0.0, delta * 4.5)

	var amp := clampf(_speed / FULL_SPEED, 0.0, 1.0)
	_run = _speed > RUN_AT or (ball.running and _speed > 1.2)                  # Shift held: it runs as soon as it moves
	var run := _run
	_run_t = lerpf(_run_t, 1.0 if run else 0.0, 1.0 - exp(-delta * 8.0))
	# the cycle turns with the DISTANCE walked (so the boots never slide on the ground): a run takes longer steps per cycle
	_k = lerpf(3.4, 2.3, _run_t)
	_phase += delta * _speed * _k
	if ball.in_water > 0.5:
		_phase += delta * 5.0                      # paddling

	_animate_body(delta, vv, amp, use)
	_animate_feet(delta, vv, amp)
	_animate_hands(delta, amp, run)
	_animate_sprout(delta, vv, amp)
	_blink_eyes(delta)

## Where the right hand rests when it holds nothing but the tool's grip: the tool rests there.
func hand_rest_world() -> Variant:
	if _model == null or _hands.size() < 2:
		return null
	return _model.to_global(_rest[_hands[1]])

func _animate_body(delta: float, vv: float, amp: float, use: float) -> void:
	var go := smoothstep(0.15, 0.7, _speed)                       # 0 standing .. 1 moving
	var contact := absf(sin(_phase))                              # 1 when a boot is planted out in front or behind, 0 when one passes under the body
	var sy := 1.0 + 0.014 * sin(_t * 2.4)                         # breathing
	sy += go * lerpf(0.05, 0.09, _run_t) * (1.0 - 2.0 * contact) * (1.0 - _air)   # stretches passing over the boot, squashes at each step
	sy += _air * clampf(vv * 0.03, -0.06, 0.12)                   # stretched going up, a little long falling
	sy -= 0.24 * _land                                            # landing squash
	var sx := 1.0 / sqrt(sy)                                      # the volume stays
	var lean := go * lerpf(0.16, 0.42, _run_t) * clampf(0.6 + amp, 0.0, 1.0)
	if use >= 0.0:
		lean = _swing_lean(use)
	_lean = lerpf(_lean, lean, 1.0 - exp(-delta * 16.0))
	var bob := (1.0 - contact) * lerpf(0.07, 0.15, _run_t) * go * (1.0 - _air)      # up over each planted boot, a bounce per step
	_body.scale = Vector3(sx, sy, sx)
	_body.position = _body_rest + Vector3(0, bob + (sy - 1.0) * 0.46, 0)
	var roll := sin(_phase) * lerpf(0.07, 0.13, _run_t) * go * (1.0 - _air)        # sways side to side with the steps
	var twist := sin(_phase) * lerpf(0.10, 0.22, _run_t) * go * (1.0 - _air) if use < 0.0 else 0.0     # the body turns with the swinging arms
	# leans into the way he moves (forward, back or sideways), not just the way he looks
	var lean_dir := _dirm if use < 0.0 else Vector2(0, -1)
	_head = lerpf(_head, clampf(look_pitch * 0.5, -0.5, 0.5), 1.0 - exp(-delta * 20.0))      # the face tips up and down with the camera
	_body.rotation = Vector3(_lean * lean_dir.y + _head, twist, roll - _lean * lean_dir.x)

## The body's lean over a swing: back for the wind-up, hard forward at the blow, then up again (u = progress of the use).
func _swing_lean(u: float) -> float:
	if u < ToolRig.WIND_END:
		return lerpf(0.0, -0.22, smoothstep(0.0, ToolRig.WIND_END, u))
	if u < ToolRig.IMPACT:
		return lerpf(-0.22, 0.55, (u - ToolRig.WIND_END) / (ToolRig.IMPACT - ToolRig.WIND_END))
	return lerpf(0.55, 0.0, smoothstep(ToolRig.IMPACT, 1.0, u))

func _animate_feet(delta: float, vv: float, amp: float) -> void:
	var go := smoothstep(0.15, 0.7, _speed)
	# the stride that matches the cycle: the planted boot moves back exactly as fast as the ground goes by (no sliding at any speed)
	var stride := go / (_k * SCALE)
	var lift := go * lerpf(0.17, 0.32, _run_t)                    # a run lifts the knees higher
	var tuck := clampf(vv * 0.05, -0.1, 1.0)
	for i in 2:
		var f: Node3D = _feet[i]
		var rest: Vector3 = _rest[f]
		var ph := _phase + PI * i
		var sw := sin(ph) * stride                                                     # the swing, along the way he moves (forward, back or sideways)
		var step := Vector3(_dirm.x * sw, pow(maxf(0.0, cos(ph)), 0.7) * lift, _dirm.y * sw)   # lifts snappily while it swings
		# in the air the boots tuck up going up and hang down falling, kicking a little
		var air := Vector3((-0.03 if i == 0 else 0.03), 0.07 * tuck + 0.03, 0.05 * tuck - 0.04 * (1.0 - tuck) + sin(_t * 9.0 + i * PI) * 0.02)
		_foot_xz[i] = Vector2(rest.x + step.x, rest.z + step.z)                        # where the terrain is probed for the next frame
		# the ground under THIS boot: its height and slope (smoothed), so on a stair one boot is on the upper step and the other on the lower
		var hit: Dictionary = _probe[i]
		var k := 1.0 - exp(-delta * 22.0)
		_foot_y[i] = lerpf(_foot_y[i], (clampf(hit.y, -1.0, -0.08) - _model.position.y) / SCALE, k)      # the probe answers in the character's space, the boots live in the model's
		_foot_n[i] = (_foot_n[i] as Vector3).lerp(hit.n, k).normalized()
		var on_ground := Vector3(rest.x + step.x, _foot_y[i] + (rest.y + 0.5) + step.y, rest.z + step.z)
		f.position = on_ground.lerp(rest + air, _air)
		var n: Vector3 = _foot_n[i]
		var pitch := clampf(atan2(n.z, n.y), -0.9, 0.9)                                # the toes follow the slope ahead
		var roll := clampf(-atan2(n.x, n.y), -0.9, 0.9)                                # and the boot tilts sideways with it
		var toe := _dirm.y * sin(ph) * 0.55 * go + maxf(0.0, cos(ph)) * 0.25 * go     # toes up at the heel strike, pushing off behind
		f.rotation = Vector3(lerpf(pitch + toe, 0.5 * tuck, _air), 0, lerpf(roll, 0.0, _air))

## What is under each boot: asked of the physics world every physics step (a ray down from above the boot's place).
func _physics_process(_delta: float) -> void:
	if _model == null or ball == null or ball.fly or not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	for i in 2:
		var lp := _model.position + Vector3(_foot_xz[i].x, 0.0, _foot_xz[i].y) * SCALE
		var q := PhysicsRayQueryParameters3D.create(to_global(lp + Vector3(0, 0.35, 0)), to_global(lp + Vector3(0, -1.3, 0)), 1, [ball.get_rid()])
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			_probe[i] = {"y": -0.5, "n": Vector3.UP}
		else:
			_probe[i] = {"y": to_local(hit.position).y, "n": (global_transform.basis.inverse() * hit.normal).normalized()}

## The sprout trails behind when he moves and flutters in the air; the leaves spin into a little helicopter rotor as he jumps.
func _animate_sprout(delta: float, vv: float, amp: float) -> void:
	if _sprout == null:
		return
	var go := smoothstep(0.15, 0.7, _speed)
	# trails behind when he moves, bounces with every step, streams up when he falls
	var bounce := cos(_phase * 2.0) * 0.22 * go
	_sprout.rotation = Vector3(0.30 * amp * (1.0 + _run_t) + bounce - _air * clampf(vv * 0.03, -0.5, 0.3) + sin(_t * 2.6) * 0.04, 0, sin(_t * 1.9) * 0.06 + sin(_phase) * 0.12 * go)
	_leaf_spin += delta * 24.0 * _air                 # the rotor spins up with how airborne he is, and stops once he lands
	for k in _leaves.size():
		var lf: Node3D = _leaves[k]
		var rest: Vector3 = _leaf_rest[k]
		var radius := Vector2(rest.x, rest.z).length()
		var base_angle := atan2(rest.z, rest.x)
		var angle := base_angle + _leaf_spin
		var spin_pos := Vector3(radius * cos(angle), rest.y, radius * sin(angle))
		var flutter := (1.0 if k == 0 else -1.0) * sin(_t * 11.0 + k) * 0.14 * (amp + 0.15 + go * _run_t)
		lf.position = rest.lerp(spin_pos, _air)
		lf.rotation = Vector3(0, -angle * _air, lerpf(flutter, 0.0, _air))

func _animate_hands(delta: float, amp: float, run: bool) -> void:
	var go := smoothstep(0.15, 0.7, _speed)
	for i in 2:
		var h: Node3D = _hands[i]
		var side := -1.0 if i == 0 else 1.0
		var arm := sin(_phase + PI * i + PI)                                          # opposite to the boot on its side
		var reach := lerpf(0.22, 0.42, _run_t) * go                                   # how far the arms swing
		var pos: Vector3 = _rest[h]
		pos += Vector3(side * (0.03 + 0.05 * _air) + _dirm.x * arm * reach, 0.16 * _air + 0.05 * (1.0 + arm) * go * (0.5 + _run_t), _dirm.y * arm * reach)
		pos += Vector3(-_dirm.x, 0, -_dirm.y) * 0.12 * _run_t * go                     # arms trail behind when running
		pos += Vector3(side * -0.06 * _run_t * go, 0.10 * _run_t * go * absf(arm), 0)  # elbows in and up: pumping
		if i == 1 and rig != null:
			var grip: Variant = rig.grip_world()                                       # the right hand holds the tool
			if grip != null:
				h.position = h.position.lerp(_model.to_local(grip), 1.0 - exp(-delta * 30.0))
				continue
		h.position = h.position.lerp(pos, 1.0 - exp(-delta * 22.0))

func _blink_eyes(delta: float) -> void:
	_blink -= delta
	var closed := 0.0
	if _blink < 0.0:
		closed = 1.0 - absf(_blink + 0.07) / 0.07
		if _blink < -0.14:
			_blink = randf_range(2.5, 5.5)
			closed = 0.0
	for e: Node3D in _eyes:
		e.scale = Vector3(1.0, 1.0 - 0.85 * clampf(closed, 0.0, 1.0), 1.0)

static func _flat(v: Vector3, up: Vector3, fallback: Vector3) -> Vector3:
	var f := v - up * v.dot(up)
	return f.normalized() if f.length() > 0.001 else fallback
