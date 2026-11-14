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
var _tilt := 0.0                        # how far the body leans into the slope under it (0 level .. 1 the slope's own angle, smoothed)
var _slide := 0.0                       # 0 .. 1: sliding down a slope too steep to stand on (smoothed): boots planted, arms out, leaning back
var _swim := 0.0                        # 0 .. 1: swimming (smoothed): lying in the water, arms stroking, legs kicking
var _fly := 0.0                         # 0 .. 1: flying (smoothed): the superhero pose, prone with a fist forward, boots together, cape streaming
var _fly_lean := 0.0                    # the body's pitch in flight (radians, smoothed): upright (straight up) .. prone (level) .. head down (diving)
var _wet := 0.0                         # 0 .. 1: flying under water (smoothed): streamlined, hands together, kicking, no cape, bubbles
var _was_in_w := false
var _cruise := 0.0                      # 0 hovering .. 1 cruising (smoothed): the hover is relaxed, the cruise is the superhero pose
var _fist1 := Vector3.ZERO              # where the right hand is held in the cruise (model space): the tool goes there
var _fly_s := 0.0                       # flight speed over the cruising speed (smoothed)
var _cape: MeshInstance3D
var _cape_mesh: ImmediateMesh
var _acc_trail := 0.0
var _acc_wind := 0.0
var _swim_lean := 0.15                  # the body's pitch in the water (radians, smoothed): upright when floating still, prone when swimming, along the dive
var _mv := 0.0                          # 0 still .. 1 moving (smoothed): strokes, lean and sculling follow it
var _swim_t := 0.0                      # the stroke cycle
var _drop := 0.0                        # how far the body sinks towards ground that lies below the flat-ground soles (steep slopes)
var fx: PlayerFx                        # the dust and spray
var _prev_c := [0.0, 0.0]               # cos of each boot's cycle last frame: a boot lands when it turns from > 0 to <= 0
var _was_swim := false
var _acc_rip := 0.0                     # time since the last ring on the water
var _acc_frip := 0.0
var _ring: MeshInstance3D               # the soft ring on the water round a floating swimmer
var _ring_a := 0.0
var _landed := false
var _acc_slide := 0.0
var _acc_foam := 0.0
var _ground_col := Color(0.55, 0.5, 0.4)
var _col_t := -10.0

func setup(p_ball: BallPlayer, p_rig: ToolRig) -> void:
	ball = p_ball
	rig = p_rig
	process_priority = 10                # after the tool rig: the hand follows where the tool is this frame
	top_level = true
	fx = PlayerFx.new()
	add_child(fx)
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
	_ring = MeshInstance3D.new()                  # a flat ring on the water round the floating body: it looks like it displaces the water
	var rq := QuadMesh.new()
	rq.size = Vector2(1.5, 1.5)
	_ring.mesh = rq
	var rsh := Shader.new()
	rsh.code = "shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform float alpha = 0.5;
void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	float ring = smoothstep(0.62, 0.74, r) * (1.0 - smoothstep(0.78, 0.92, r));
	ALBEDO = vec3(0.93, 0.97, 1.0);
	ALPHA = ring * alpha;
}
"
	var rmat := ShaderMaterial.new()
	rmat.shader = rsh
	_ring.material_override = rmat
	_ring.top_level = true
	_ring.visible = false
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	_cape_mesh = ImmediateMesh.new()
	_cape = MeshInstance3D.new()
	_cape.mesh = _cape_mesh
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.82, 0.13, 0.17)
	cm.roughness = 0.8
	cm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cape.material_override = cm
	_cape.visible = false
	_model.add_child(_cape)
	if rig != null and rig.cam != null:
		facing = rig.cam.view_fwd

func _process(delta: float) -> void:
	if _model == null or ball == null:
		return
	_t += delta
	visible = ball.visible
	var p := ball.render_pos()
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
	# on a slope he leans into it (the boots then reach the ground under them instead of dangling), more when he slides
	var tilt_want := 0.0
	if ball.grounded and not ball.swimming:
		tilt_want = clampf(ball.slope_deg / 40.0, 0.0, 1.0) * (0.85 if ball.sliding else 0.6)
	_tilt = lerpf(_tilt, tilt_want, 1.0 - exp(-delta * 8.0))
	var body_up := up
	if _tilt > 0.01 and ball.ground_normal.dot(up) < 0.9999:
		body_up = up.slerp(ball.ground_normal, _tilt)
	global_transform = Transform3D(Basis.looking_at(facing, body_up), p)
	if speed > 0.4:                                        # which way the gait goes, relative to where he looks (forward, back or sideways)
		var vl := global_transform.basis.inverse() * vt
		var dm := Vector2(vl.x, vl.z).normalized()
		_dirm = _dirm.lerp(dm, 1.0 - exp(-delta * 12.0))
		if _dirm.length() < 0.05:
			_dirm = dm
		_dirm = _dirm.normalized()

	# air / ground and the landing squash
	var in_air := (not ball.grounded and not ball.swimming) or ball.fly
	_air = lerpf(_air, 1.0 if in_air else 0.0, 1.0 - exp(-delta * 14.0))
	if _was_air and not in_air:
		_land = 1.0
		_landed = true
	_was_air = in_air
	_land = move_toward(_land, 0.0, delta * 4.5)
	_slide = lerpf(_slide, 1.0 if ball.sliding else 0.0, 1.0 - exp(-delta * 10.0))
	var swimming := ball.swimming and not ball.fly                  # flying under water is its own pose (_wet), not the swimmer's
	_wet = lerpf(_wet, 1.0 if (ball.fly and ball.swimming) else 0.0, 1.0 - exp(-delta * 6.0))
	_swim = lerpf(_swim, 1.0 if swimming else 0.0, 1.0 - exp(-delta * 6.0))
	var vlen := v.length()
	_mv = lerpf(_mv, smoothstep(0.3, 1.8, vlen), 1.0 - exp(-delta * 6.0))
	var surfacing := ball.swim_state == BallPlayer.SwimState.SURFACE or ball.swim_state == BallPlayer.SwimState.NONE
	var swim_target := lerpf(0.15, 0.7, _mv)                                  # floating at the surface: upright when still, chest-low when it swims
	if not surfacing:                                                         # diving / deep: hangs head-up when still, lies along the swim when it moves
		var elev := asin(clampf(vv / maxf(vlen, 0.001), -1.0, 1.0))
		swim_target = lerpf(0.5, clampf(1.45 - elev, 0.0, 2.7), _mv)
	_swim_lean = lerpf(_swim_lean, swim_target, 1.0 - exp(-delta * 5.0))
	_swim_t += delta * lerpf(1.2, 3.0 + vlen * 1.2, _mv) * _swim              # a still swimmer treads slowly; the stroke rate follows the speed
	_fly = lerpf(_fly, 1.0 if ball.fly else 0.0, 1.0 - exp(-delta * 7.0))
	_cruise = lerpf(_cruise, smoothstep(2.0, 10.0, v.length()) if ball.fly else 0.0, 1.0 - exp(-delta * 5.0))
	_fly_s = lerpf(_fly_s, clampf(v.length() / BallPlayer.FLY_SPEED, 0.0, 1.3), 1.0 - exp(-delta * 5.0))
	if ball.fly:
		var elev := asin(clampf(vv / maxf(v.length(), 0.001), -1.0, 1.0))     # +: climbing, -: diving
		var lean_target := lerpf(0.2, clampf(1.45 - elev, 0.0, 2.7), smoothstep(0.5, 6.0, v.length()))   # hovering: nearly upright, a fist raised
		lean_target = lerpf(lean_target, maxf(lean_target, 1.15), _wet)          # under water he lies streamlined even when he is almost still
		_fly_lean = lerpf(_fly_lean, lean_target, 1.0 - exp(-delta * 6.0))
	var avg_y := (float(_probe[0].y) + float(_probe[1].y)) * 0.5
	var drop_want := clampf(-0.5 - avg_y, -0.1, 0.45) if (ball.grounded and not swimming and not ball.fly) else 0.0
	_drop = lerpf(_drop, drop_want, 1.0 - exp(-delta * 10.0))
	var hover := _fly * (1.0 - _cruise)
	_model.position.y = 0.5 * (SCALE - 1.0) - _drop + sin(_t * 2.2) * 0.07 * hover          # hovering: floats gently up and down

	var amp := clampf(_speed / FULL_SPEED, 0.0, 1.0)
	_run = _speed > RUN_AT or (ball.running and _speed > 1.2)                  # Shift held: it runs as soon as it moves
	var run := _run
	_run_t = lerpf(_run_t, 1.0 if run else 0.0, 1.0 - exp(-delta * 8.0))
	# the cycle turns with the DISTANCE walked (so the boots never slide on the ground): a run takes longer steps per cycle
	_k = lerpf(3.4, 2.3, _run_t)
	_phase += delta * _speed * _k * (1.0 - _slide)         # sliding: the boots stay planted, no steps
	if swimming:
		_phase += delta * 5.0                      # (the sprout flutters)

	_animate_body(delta, vv, amp, use)
	_animate_feet(delta, vv, amp)
	_animate_hands(delta, amp, run)
	_animate_sprout(delta, vv, amp)
	_animate_cape()
	_blink_eyes(delta)
	_emit_fx(delta, up, vt, swimming)

## Where the right hand rests when it holds nothing but the tool's grip: the tool rests there.
func hand_rest_world() -> Variant:
	if _model == null or _hands.size() < 2:
		return null
	var shift := ball.render_pos() - global_position if ball.fly else Vector3.ZERO      # the character is about to move by this (it updates after the tool)
	return _model.to_global((_rest[_hands[1]] as Vector3).lerp(_fist1, _pose_w())) + shift

## How much the tool is carried forward along the flight (0 = as on the ground), and the way the handle then points: out of the raised fist.
func fly_weight() -> float:
	return smoothstep(0.2, 0.8, _pose_w())

## How far the flight pose (boots together, hands forward) is on: the cruise, or any flight under water.
func _pose_w() -> float:
	return _fly * maxf(_cruise, _wet)

func fly_dir() -> Vector3:
	return _body.global_transform.basis.y if _body != null else Vector3.UP

func _animate_body(delta: float, vv: float, amp: float, use: float) -> void:
	var go := smoothstep(0.15, 0.7, _speed) * (1.0 - _slide) * (1.0 - _swim) * (1.0 - _fly)        # 0 standing .. 1 moving
	var contact := absf(sin(_phase))                              # 1 when a boot is planted out in front or behind, 0 when one passes under the body
	var sy := 1.0 + 0.014 * sin(_t * 2.4)                         # breathing
	sy += go * lerpf(0.05, 0.09, _run_t) * (1.0 - 2.0 * contact) * (1.0 - _air)   # stretches passing over the boot, squashes at each step
	sy += _air * clampf(vv * 0.03, -0.06, 0.12)                   # stretched going up, a little long falling
	sy -= 0.24 * _land                                            # landing squash
	var sx := 1.0 / sqrt(sy)                                      # the volume stays
	var lean := go * lerpf(0.16, 0.42, _run_t) * clampf(0.6 + amp, 0.0, 1.0)
	if use >= 0.0:
		lean = _swing_lean(use)
	lean += -0.32 * _slide                             # sliding: leaning back on his heels
	lean = lerpf(lean, _swim_lean, _swim)               # swimming: upright treading .. chest-low .. along the dive
	lean = lerpf(lean, _fly_lean, _fly)                 # flying: the body lies along the flight path
	_lean = lerpf(_lean, lean, 1.0 - exp(-delta * 16.0))
	var bob := (1.0 - contact) * lerpf(0.07, 0.15, _run_t) * go * (1.0 - _air)      # up over each planted boot, a bounce per step
	_body.scale = Vector3(sx, sy, sx)
	_body.position = _body_rest + Vector3(0, bob + (sy - 1.0) * 0.46 - 0.1 * _swim, 0)
	var roll := sin(_phase) * lerpf(0.07, 0.13, _run_t) * go * (1.0 - _air)        # sways side to side with the steps
	var twist := sin(_phase) * lerpf(0.10, 0.22, _run_t) * go * (1.0 - _air) if use < 0.0 else 0.0     # the body turns with the swinging arms
	# leans into the way he moves (forward, back or sideways), not just the way he looks
	var lean_dir := _dirm if (use < 0.0 and _swim < 0.5 and _fly < 0.5) else Vector2(0, -1)
	_head = lerpf(_head, clampf(look_pitch * 0.5, -0.5, 0.5), 1.0 - exp(-delta * 20.0))      # the face tips up and down with the camera
	var bank := -clampf((global_transform.basis.inverse() * ball.linear_velocity).x / 25.0, -0.5, 0.5) * _fly + sin(_t * 1.6) * 0.05 * _fly * (1.0 - _cruise)      # banks into a sideways turn; hovering: a slow sway
	_body.rotation = Vector3(_lean * lean_dir.y + _head * (1.0 - _fly), twist, roll - _lean * lean_dir.x + bank)

## The body's lean over a swing: back for the wind-up, hard forward at the blow, then up again (u = progress of the use).
func _swing_lean(u: float) -> float:
	if u < ToolRig.WIND_END:
		return lerpf(0.0, -0.22, smoothstep(0.0, ToolRig.WIND_END, u))
	if u < ToolRig.IMPACT:
		return lerpf(-0.22, 0.55, (u - ToolRig.WIND_END) / (ToolRig.IMPACT - ToolRig.WIND_END))
	return lerpf(0.55, 0.0, smoothstep(ToolRig.IMPACT, 1.0, u))

func _animate_feet(delta: float, vv: float, amp: float) -> void:
	var go := smoothstep(0.15, 0.7, _speed) * (1.0 - _slide) * (1.0 - _swim) * (1.0 - _fly)
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
		step += Vector3(_dirm.x, 0.0, _dirm.y) * (0.14 if i == 0 else -0.14) * _slide        # sliding: one boot ahead of the other, both planted
		# in the air the boots tuck up going up and hang down falling, kicking a little
		var air := Vector3((-0.03 if i == 0 else 0.03), 0.07 * tuck + 0.03, 0.05 * tuck - 0.04 * (1.0 - tuck) + sin(_t * 9.0 + i * PI) * 0.02)
		_foot_xz[i] = Vector2(rest.x + step.x, rest.z + step.z)                        # where the terrain is probed for the next frame
		# the ground under THIS boot: its height and slope (smoothed), so on a stair one boot is on the upper step and the other on the lower
		var hit: Dictionary = _probe[i]
		var k := 1.0 - exp(-delta * 22.0)
		_foot_y[i] = lerpf(_foot_y[i], (clampf(hit.y, -1.7, 0.4) - _model.position.y) / SCALE, k)      # the probe answers in the character's space, the boots live in the model's
		_foot_n[i] = (_foot_n[i] as Vector3).lerp(hit.n, k).normalized()
		var on_ground := Vector3(rest.x + step.x, _foot_y[i] + (rest.y + 0.5) + step.y, rest.z + step.z)
		f.position = on_ground.lerp(rest + air, _air)
		var n: Vector3 = _foot_n[i]
		var pitch := clampf(atan2(n.z, n.y), -0.9, 0.9)                                # the toes follow the slope ahead
		var roll := clampf(-atan2(n.x, n.y), -0.9, 0.9)                                # and the boot tilts sideways with it
		var toe := _dirm.y * sin(ph) * 0.55 * go + maxf(0.0, cos(ph)) * 0.25 * go     # toes up at the heel strike, pushing off behind
		f.rotation = Vector3(lerpf(pitch + toe, 0.5 * tuck, _air), 0, lerpf(roll, 0.0, _air))
		if _swim > 0.01:                                                               # swimming: upright, the boots pedal under the body; leaning, they trail behind and kick
			var kick := sin(_swim_t * 2.6 + PI * i)
			var samp := 0.35 + 0.65 * _mv
			var down := Basis(Vector3.RIGHT, _body.rotation.x) * Vector3.DOWN             # the boots hang along the body's own axis, whatever its pitch
			var tail := _body.position + down * 0.66 + Vector3((-0.08 if i == 0 else 0.08), 0.0, 0.0)
			tail += Vector3(0, 0.05 * kick * samp, 0.07 * kick * samp)                      # pedalling / flutter kick
			f.position = f.position.lerp(tail, _swim)
			f.rotation.x = lerpf(f.rotation.x, _body.rotation.x + 0.25 * kick * samp, _swim)
		if _pose_w() > 0.01:                                                           # cruising / flying under water: the boots together, straight behind the body's axis
			var down := Basis(Vector3.RIGHT, _body.rotation.x) * Vector3.DOWN
			var tail := _body.position + down * 0.68 + Vector3((-0.07 if i == 0 else 0.07), 0.0, 0.0)
			tail += Vector3(0, 0.02, 0) * sin(_t * 9.0 + i * PI) * _fly_s
			tail += Vector3(0, 0.09, 0) * sin(_t * 8.0 + i * PI) * _wet                # under water the boots kick in turns (a flutter kick)
			f.position = f.position.lerp(tail, _pose_w())
			f.rotation.x = lerpf(f.rotation.x, _body.rotation.x, _pose_w())
			f.rotation.z = lerpf(f.rotation.z, 0.0, _pose_w())

## What is under each boot: asked of the physics world every physics step (a ray down from above the boot's place).
func _physics_process(_delta: float) -> void:
	if _model == null or ball == null or ball.fly or not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	for i in 2:
		var lp := _model.position + Vector3(_foot_xz[i].x, 0.0, _foot_xz[i].y) * SCALE
		var q := PhysicsRayQueryParameters3D.create(to_global(lp + Vector3(0, 0.7, 0)), to_global(lp + Vector3(0, -1.9, 0)), 1, [ball.get_rid()])
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
	_leaf_spin += delta * 24.0 * _air * lerpf(1.0, 0.25, _fly)                 # the rotor spins up with how airborne he is, and stops once he lands
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
	var go := smoothstep(0.15, 0.7, _speed) * (1.0 - _slide) * (1.0 - _swim) * (1.0 - _fly)
	for i in 2:
		var h: Node3D = _hands[i]
		var side := -1.0 if i == 0 else 1.0
		var arm := sin(_phase + PI * i + PI)                                          # opposite to the boot on its side
		var reach := lerpf(0.22, 0.42, _run_t) * go                                   # how far the arms swing
		var pos: Vector3 = _rest[h]
		pos += Vector3(side * (0.03 + 0.05 * _air * (1.0 - _fly)) + _dirm.x * arm * reach, 0.16 * _air * (1.0 - _fly) + 0.05 * (1.0 + arm) * go * (0.5 + _run_t), _dirm.y * arm * reach)
		pos += Vector3(-_dirm.x, 0, -_dirm.y) * 0.12 * _run_t * go                     # arms trail behind when running
		pos += Vector3(side * -0.06 * _run_t * go, 0.10 * _run_t * go * absf(arm), 0)  # elbows in and up: pumping
		pos += Vector3(side * 0.22, 0.14, 0.0) * _slide                                # sliding: arms out for balance
		if _swim > 0.01:                                                               # swimming: the arms reach forward and pull back in turns
			var a := _swim_t + PI * i
			var samp := 0.35 + 0.65 * _mv
			var stroke: Vector3 = _rest[h] + Vector3(side * 0.10, -0.04 + 0.14 * sin(a) * samp, -0.30 + 0.34 * cos(a) * samp)
			var scull: Vector3 = _rest[h] + Vector3(side * (0.10 + 0.10 * sin(a * 0.5)), -0.08 + 0.04 * cos(a), -0.05 + 0.10 * cos(a * 0.5))   # still: the hands sweep out and in at the waterline
			pos = pos.lerp(stroke.lerp(scull, 1.0 - _mv), _swim)
		if _fly > 0.01:                                                                # cruising: the right fist punches ahead, the left rests at the hip
			var axis := Basis(Vector3.RIGHT, _body.rotation.x)
			var fist_air: Vector3 = Vector3(0.32, 0.80, 0.0) if i == 1 else Vector3(-0.50, -0.10, 0.12)
			var fist_wet: Vector3 = Vector3(0.09 * side, 0.82, 0.0)                    # under water both hands go together out in front, like a diver
			var fist: Vector3 = _body.position + axis * fist_air.lerp(fist_wet, _wet)
			if i == 1:
				_fist1 = fist
			pos = pos.lerp(fist, _pose_w())
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

## The cape: a small red sheet hung from the shoulders that streams back along the flight path and ripples. Only drawn while flying.
func _animate_cape() -> void:
	if _cape == null:
		return
	_cape.visible = _fly * (1.0 - _wet) > 0.02                      # no cape under water
	if not _cape.visible:
		return
	var vl := global_transform.basis.inverse() * ball.linear_velocity
	var vdir := vl.normalized() if vl.length() > 0.5 else Vector3.ZERO
	var s := minf(_fly_s, 1.0)
	var dir := (-vdir * s * 1.2 + Vector3(0, -1.0, 0.15) * (1.1 - 0.8 * s)).normalized()
	var axis := Basis(Vector3.RIGHT, _body.rotation.x)
	var length := 0.9 * _fly * (1.0 - _wet) * (1.0 + 0.5 * minf(_fly_s, 1.3))
	const ROWS := 6
	const COLS := 4
	var grid: Array = []
	for j in ROWS:
		var t := float(j) / (ROWS - 1)
		for i in COLS:
			var u := lerpf(-1.0, 1.0, float(i) / (COLS - 1))
			var base := _body.position + axis * Vector3(u * 0.24, 0.20, 0.36 - 0.03 * u * u)
			var wave := Vector3(sin(_t * 12.0 - t * 6.0 + u * 2.0) * 0.5, sin(_t * 15.0 - t * 5.0) * 0.8, cos(_t * 10.0 - t * 5.0) * 0.4)
			grid.append(base + Vector3.RIGHT * u * 0.28 * t + dir * length * t + wave * 0.07 * t * (0.3 + s))
	_cape_mesh.clear_surfaces()
	_cape_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in ROWS - 1:
		for i in COLS - 1:
			var a: Vector3 = grid[j * COLS + i]
			var b: Vector3 = grid[j * COLS + i + 1]
			var c: Vector3 = grid[(j + 1) * COLS + i]
			var d: Vector3 = grid[(j + 1) * COLS + i + 1]
			for tri: Array in [[a, c, b], [b, c, d]]:
				var n: Vector3 = ((tri[1] - tri[0]) as Vector3).cross(tri[2] - tri[0]).normalized()
				for pt: Vector3 in tri:
					_cape_mesh.surface_set_normal(n)
					_cape_mesh.surface_add_vertex(pt)
	_cape_mesh.surface_end()

## Flight effects: a glowing trail from the boots, white wind streaks rushing past (more and longer the faster he goes), gold when boosting.
func _emit_fly_fx(delta: float, up: Vector3) -> void:
	var v := ball.linear_velocity
	var spd := v.length()
	# crossing the surface (in or out) throws a splash, and low over the water he leaves a wake of foam
	var sub := ball.world.submersion(ball.global_position)
	var in_w := sub > -1.0e8 and sub > 0.0
	if in_w != _was_in_w and sub > -1.0e8:
		fx.splash(ball.global_position + up * sub, v * 0.12, up, int(12.0 + spd * 0.5), 0.14)
		(ball.world.water as WaterSystem).add_ripple(ball.global_position + up * sub, clampf(1.0 + spd / 20.0, 1.0, 2.5))
	_was_in_w = in_w
	if sub > -1.0e8 and absf(sub) < 1.5 and spd > 4.0:
		_acc_frip += delta
		if _acc_frip > 0.2:
			_acc_frip = 0.0
			(ball.world.water as WaterSystem).add_ripple(ball.global_position + up * sub, 0.5)
		_acc_foam += delta * 20.0
		while _acc_foam >= 1.0:
			_acc_foam -= 1.0
			fx.foam(ball.global_position + up * sub - v.normalized() * 0.4, up, 0.34)
	if _wet > 0.5:
		_acc_trail += delta * (14.0 + spd * 0.8)                              # under water: bubbles from the boots and the hands, no glow and no wind
		while _acc_trail >= 1.0:
			_acc_trail -= 1.0
			var src: Node3D = (_feet + _hands)[randi() % 4]
			fx.bubble(src.global_position, -v * 0.1, 0.05 + randf() * 0.05)
		return
	if spd < 3.0:
		return
	var dir := v / spd
	var boost := clampf((spd - BallPlayer.FLY_SPEED) / (BallPlayer.FLY_BOOST - BallPlayer.FLY_SPEED), 0.0, 1.0)
	var glow := Color(0.65, 0.9, 1.0, 0.6).lerp(Color(1.0, 0.8, 0.35, 0.75), boost)
	_acc_trail += delta * (30.0 + 40.0 * boost)
	while _acc_trail >= 1.0:
		_acc_trail -= 1.0
		for i in 2:
			fx.glow((_feet[i] as Node3D).global_position, -dir * 1.5, 0.20 + 0.18 * boost, glow)
	_acc_wind += delta * clampf(spd * 1.4, 0.0, 90.0)
	var p := ball.global_position
	var side := dir.cross(up)
	if side.length() < 0.01:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized()
	var other := dir.cross(side).normalized()
	while _acc_wind >= 1.0:
		_acc_wind -= 1.0
		var ang := randf() * TAU
		var rad := randf_range(1.2, 3.5)
		var at := p + dir * randf_range(-2.0, 6.0) + (side * cos(ang) + other * sin(ang)) * rad
		fx.streak(at, dir, 2.0 + spd * 0.12, 0.05, Color(1, 1, 1, 0.45))

## Dust where a boot lands, behind a run, along a slide; spray and foam on the water. All of it is display (PlayerFx).
func _emit_fx(delta: float, up: Vector3, vt: Vector3, swimming: bool) -> void:
	if fx == null or ball.world == null:
		return
	var p := ball.global_position
	var back := -vt.normalized() if vt.length() > 0.3 else Vector3.ZERO
	var on_land := ball.grounded and not swimming
	var go := smoothstep(0.15, 0.7, _speed)
	if on_land:
		if _t - _col_t > 0.4:
			_col_t = _t
			_ground_col = _sample_ground(p - up * 0.5)
		for i in 2:
			var c := cos(_phase + PI * i)
			var foot := (_feet[i] as Node3D).global_position
			if _prev_c[i] > 0.0 and c <= 0.0 and go > 0.35 and not ball.sliding and not ball.fly:
				var n := 1 + (2 if _run_t > 0.5 else 0)
				fx.dust(foot, back * _speed * 0.35, up, _ground_col, n, 0.20 + 0.12 * _run_t)
			_prev_c[i] = c
		if ball.sliding and _speed > 1.0:
			_acc_slide += delta * 28.0 * clampf(_speed / 5.0, 0.3, 1.5)
			while _acc_slide >= 1.0:
				_acc_slide -= 1.0
				var sfoot := (_feet[randi() % 2] as Node3D).global_position
				fx.dust(sfoot, back * 0.8, up, _ground_col, 1, 0.34)
		if _landed:
			for i in 2:
				fx.dust((_feet[i] as Node3D).global_position, Vector3.ZERO, up, _ground_col, 4, 0.32)
	_landed = false
	if ball.fly:
		_emit_fly_fx(delta, up)
	if swimming:
		var sub := ball.world.submersion(p)
		if sub > -1.0e8:
			var surface := p + up * sub
			var water: WaterSystem = ball.world.water
			var spd3 := ball.linear_velocity.length()
			if not _was_swim:
				fx.splash(surface, Vector3.ZERO, up, 16, 0.12)                     # in with a splash
				water.add_ripple(surface, clampf(1.0 + spd3 / 15.0, 1.0, 2.5))     # ... and a ring spreads
			_acc_rip += delta
			if sub < 1.5:
				var iv := 0.25 if spd3 > 0.5 else 1.3
				if _acc_rip > iv:
					_acc_rip = 0.0
					if spd3 > 0.5:                                                  # a wake: two rings either side of the body, a V behind him
						var sd := global_transform.basis.x * 0.5
						var st := (0.9 + spd3 * 0.15) * (1.0 if ball.swim_state == BallPlayer.SwimState.SURFACE else 0.5)
						water.add_ripple(surface + sd, st)
						water.add_ripple(surface - sd, st)
					else:
						water.add_ripple(surface, 0.55)                             # floating still: a slow ring now and then (the bob)
			if sub < 0.8:                                                           # (only while he is at the surface: foam puffs over a deep diver were a stray blob)
				_acc_foam += delta * (0.6 + _speed * 1.2)
				while _acc_foam >= 1.0:
					_acc_foam -= 1.0
					if _speed > 0.8:
						fx.splash(surface + back * 0.3, back * 0.6, up, 2, 0.09)       # the strokes throw drops
	if _was_swim and not swimming and not ball.fly:
		var sub2 := ball.world.submersion(p)
		if sub2 > -1.0e8:
			(ball.world.water as WaterSystem).add_ripple(p + up * sub2, 0.6)         # out of the water: a ring
	_was_swim = swimming
	_update_ring(delta, p, up)

## The soft ring on the water round a floating swimmer.
func _update_ring(delta: float, p: Vector3, up: Vector3) -> void:
	var show := ball.swim_state == BallPlayer.SwimState.SURFACE and not ball.fly
	_ring_a = lerpf(_ring_a, 1.0 if show else 0.0, 1.0 - exp(-delta * 6.0))
	_ring.visible = _ring_a > 0.02
	if not _ring.visible:
		return
	var sub := ball.world.submersion(p)
	if sub < -1.0e8:
		_ring.visible = false
		return
	var x := up.cross(Vector3.RIGHT)
	if x.length() < 0.01:
		x = up.cross(Vector3.FORWARD)
	x = x.normalized()
	var y := up.cross(x)
	var sc := 1.0 + 0.06 * sin(_t * 2.2)
	_ring.global_transform = Transform3D(Basis(x * sc, y * sc, up), p + up * (sub + 0.03))
	(_ring.material_override as ShaderMaterial).set_shader_parameter("alpha", 0.30 * _ring_a * (1.0 - 0.6 * _mv))

## The ground colour under a point (the surface colour of the terrain there), for the dust.
func _sample_ground(p: Vector3) -> Color:
	var gen: PlanetGenerator = ball.world.gen
	if gen == null:
		return _ground_col
	var col := Column.new()
	gen.sample_column(p.normalized(), col)
	var alt := p.length() - WorldConfig.PLANET_RADIUS
	return gen.surface.color_for(col) if alt > col.height - 3.0 else BlockTypes.COLORS[BlockTypes.STONE]
