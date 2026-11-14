class_name BallPlayer
extends RigidBody3D
## The explorer's body: an invisible upright CAPSULE under radial gravity (towards the planet centre). The node's origin is 0.5 m above
## the ground it stands on, as it always was; the capsule reaches from the soles (-0.5) up past the head. It never tips over or rolls: it
## is turned every physics step so that its axis follows the planet's up, and it is steered by velocity (quick to start and stop, a
## little control in the air). What you see is PlayerCharacter, which only follows this body.
## (The class keeps its old name `BallPlayer` because the rest of the game refers to it.)

const GRAVITY := 14.0
const MOVE_FORCE := 18.0       # in water: the swimming push
const GROUND_ACCEL := 30.0     # m/s per second on the ground: a walk is reached in 0.1 s, a run in 0.2 s
const GROUND_BRAKE := 40.0     # ... and standing still again
const AIR_ACCEL := 10.0        # steering in the air
const WALK_SPEED := 3.2        # m/s: a walk
const RUN_SPEED := 6.5         # m/s: hold Shift
const JUMP_IMPULSE := 8.0
const FLY_SPEED := 22.0        # m/s: cruising flight
const FLY_BOOST := 90.0        # m/s: hold Shift while flying
const FLY_ACCEL := 55.0        # m/s per second: a smooth push off ...
const FLY_BRAKE := 45.0        # ... and a smooth stop when the keys are let go

const CAPSULE_RADIUS := 0.6    # wide enough for the round body you see
const CAPSULE_HEIGHT := 1.8    # from the soles (-0.5 under the origin) to 1.3 above it
const CAPSULE_CENTRE := 0.4    # height of the capsule's middle above the origin

var cam: OrbitCamera
var world: VoxelWorld        # for water queries (buoyancy)
var in_water := 0.0           # 0 = dry .. 1 = fully under water
enum SwimState { NONE, SURFACE, DIVE, DEEP }
var swim_state := SwimState.NONE   # in the water: floating at the surface, diving (Ctrl or deeper than 1.2 m), or deep (more than 2.5 m)
var swim_pitch := 0.0              # diving / deep: how far the mouse has steered the swim up (+) or down (-), radians
var water_depth := -1.0e9          # metres of water above his centre (negative = above the water)
const SWIM_SPEED := 2.8            # diving / deep: m/s
const SWIM_FAST := 4.2             # ... with Shift
const SWIM_VERTICAL := 3.0         # Space (up) in m/s
const SWIM_DIVE := 3.5             # Ctrl (down) in m/s
const SWIM_ACCEL := 7.0            # m/s per second
const SWIM_BRAKE := 5.0
const SWIM_DRIFT := 0.4            # neutral buoyancy: he drifts up this slowly when nothing is pressed
var swimming := false         # in the water (with hysteresis: it does not flicker while he floats at the surface, where in_water is about 0.5)
var fly := false
var dbg_boost := false
var _prev_pos := Vector3.ZERO
var _cur_pos := Vector3.ZERO
var dbg_kz := 0.0            # debugging aid (main.gd --flykz): W held (+1) or S (-1) without a keyboard
var fly_pitch := 0.0         # flying: how far the mouse has steered the flight up (+) or down (-), radians
const FLY_MAX_PITCH := 1.48   # almost straight up or down
var grounded := false         # something solid is right under the feet (updated every physics step: the animation reads it)
var running := false          # Shift is held
var spawn_pos := Vector3.ZERO

## Grip on slopes (adjustable: here, in Project Settings "explorer/player/stand_slope_deg" and "explorer/player/scramble_slope_deg",
## or at launch with --slope=STAND,SCRAMBLE). Up to STAND degrees he stands still on a slope and walks or runs up it at full pace along
## the surface; between STAND and SCRAMBLE he can only climb, slowly, and slides back when he lets go; beyond SCRAMBLE he slides.
@export_range(10.0, 85.0, 0.5) var stand_slope_deg := 50.0
@export_range(10.0, 89.0, 0.5) var scramble_slope_deg := 62.0
const SCRAMBLE_SPEED := 0.35   # the share of the walking speed that a scramble keeps
var ground_normal := Vector3.UP   # the surface under the feet (smoothed), once grounded
var slope_deg := 0.0              # its angle from level
var sliding := false              # on the ground, on a slope too steep to stand on or climb: he slides (the animation reads it)
var _floor_n := Vector3.UP

func _ready() -> void:
	mass = 1.0
	gravity_scale = 0.0
	linear_damp = 0.6
	angular_damp = 8.0
	can_sleep = false
	continuous_cd = true
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.0
	pm.friction = 0.0          # the steering decides how fast he starts and stops, not the ground's grip (see _grip)
	stand_slope_deg = float(ProjectSettings.get_setting("explorer/player/stand_slope_deg", stand_slope_deg))
	scramble_slope_deg = float(ProjectSettings.get_setting("explorer/player/scramble_slope_deg", scramble_slope_deg))
	physics_material_override = pm
	var cs := CollisionShape3D.new()
	var sh := CapsuleShape3D.new()
	sh.radius = CAPSULE_RADIUS
	sh.height = CAPSULE_HEIGHT
	cs.shape = sh
	cs.position = Vector3(0, CAPSULE_CENTRE, 0)
	add_child(cs)

## Stand upright on the planet: the capsule's axis follows the up direction here, whatever the physics did to it; the heading is kept.
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var t := state.transform
	var up := t.origin.normalized()
	var z := t.basis.z - up * t.basis.z.dot(up)
	if z.length() < 0.01:
		z = up.cross(Vector3.RIGHT)
	z = z.normalized()
	state.transform = Transform3D(Basis(up.cross(z), up, z), t.origin)
	state.angular_velocity = Vector3.ZERO

func _physics_process(delta: float) -> void:
	_prev_pos = _cur_pos                                  # (for render_pos: where the body was one physics step ago and is now)
	_cur_pos = global_position
	if freeze:
		return
	_keep_out_of_ground()
	var up := global_position.normalized()
	grounded = _on_ground(up)
	running = Input.is_physical_key_pressed(KEY_SHIFT) or dbg_boost
	var fwd: Vector3 = cam.view_fwd if cam else Vector3.FORWARD     # W goes where the camera faces
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var right := fwd.cross(up)
	var kx := _axis(KEY_D, KEY_A)
	var kz := _axis(KEY_W, KEY_S) if dbg_kz == 0.0 else dbg_kz
	var wish := fwd * kz + right * kx
	# the water he is in (flying too: under water he flies slower and the character swims-flies)
	in_water = 0.0
	var sub := -1.0e9
	if world != null:
		sub = world.submersion(global_position)
		in_water = clampf((sub + 0.5) / 1.0, 0.0, 1.0)
	if in_water > 0.3:
		swimming = true
	elif in_water < 0.1:
		swimming = false
	water_depth = sub
	_update_swim_state(sub, Input.is_physical_key_pressed(KEY_CTRL), up)
	if fly:
		_fly_step(delta, up, fwd, right, kx, kz)
		return
	if swim_state == SwimState.DIVE or swim_state == SwimState.DEEP:
		_swim_step(delta, up, fwd, right, kx, kz, sub)
		return
	# water: buoyancy lifts him to the surface, water drags, and Space swims upwards
	linear_damp = lerpf(0.6, 3.2, in_water)
	apply_central_force(-up * GRAVITY * mass * (1.0 - 1.8 * in_water))
	if in_water > 0.0 and Input.is_physical_key_pressed(KEY_SPACE):
		apply_central_force(up * GRAVITY * mass * 1.4 * in_water)
	if in_water > 0.0 and Input.is_physical_key_pressed(KEY_CTRL):
		apply_central_force(-up * GRAVITY * mass * 2.6 * in_water)     # dive
	var vv := linear_velocity.dot(up)
	if in_water > 0.0 and vv > 1.2:
		# rising eases off at the surface (Space, buoyancy, or a swim up from below): he floats there instead of leaping out and bouncing back
		var cap := lerpf(1.2, 9.0, clampf(sub / 2.0, 0.0, 1.0))
		if vv > cap:
			linear_velocity -= up * (vv - cap)
			vv = cap
	var vt := linear_velocity - up * vv
	var top := RUN_SPEED if running else WALK_SPEED
	if swimming:
		if vt.length() > top:
			linear_velocity -= vt * (1.0 - top / vt.length())
		if wish.length() > 0.01:
			apply_central_force(wish.normalized() * MOVE_FORCE * (1.7 if running else 1.0))
	else:
		# on land and in the air: steer the sideways speed towards what the keys ask for (up and down stay with gravity and jumps)
		if grounded and linear_velocity.dot(_floor_n) < 1.5:
			_grip(wish, top, up, delta)
		else:
			var target := wish.normalized() * top if wish.length() > 0.01 else Vector3.ZERO
			vt = vt.move_toward(target, AIR_ACCEL * delta)
			linear_velocity = up * vv + vt
	if Input.is_physical_key_pressed(KEY_SPACE) and in_water < 0.3 and grounded:
		apply_central_impulse(up * JUMP_IMPULSE)

## The body must never be partly inside the ground. Points on the surface of the capsule (14 on each of its two end spheres) are tested
## against the terrain data (the physics shape can lag behind an edit or a rebuilt chunk, or be tunnelled by a fast landing); the points
## that are inside add up to a way out, and he is moved that way (at most 25 cm per step, so it looks like being pushed up, not a jump)
## and loses his speed into the ground. A body whose lower centre is deep in solid ground (BURIED) is left alone: nobody is rescued.
const SURFACE_PROBES: Array[Vector3] = [Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
	Vector3(0.577, 0.577, 0.577), Vector3(-0.577, 0.577, 0.577), Vector3(0.577, -0.577, 0.577), Vector3(-0.577, -0.577, 0.577),
	Vector3(0.577, 0.577, -0.577), Vector3(-0.577, 0.577, -0.577), Vector3(0.577, -0.577, -0.577), Vector3(-0.577, -0.577, -0.577)]
const RADIUS := 0.5                # the old ball's radius: the origin is this far above the ground (the soles are at -RADIUS)
const VISUAL_SCALE := 1.5          # the character you see is this much bigger than the model (the soles stay on the ground)
const BURIED := 0.55               # centre deeper than this inside the ground = buried by the player's own digging / filling
const TOLERANCE := 0.12            # how far into the ground (density units, about metres) a surface point may be before it is pushed out

func _keep_out_of_ground() -> void:
	if world == null or fly:
		return
	var b := basis                                         # the player is a direct child of the world root (at the origin): local = global
	var low := position + b.y * (CAPSULE_CENTRE - CAPSULE_HEIGHT * 0.5 + CAPSULE_RADIUS)      # centre of the lower end sphere
	var high := position + b.y * (CAPSULE_CENTRE + CAPSULE_HEIGHT * 0.5 - CAPSULE_RADIUS)     # ... and of the upper one
	if world.density_at(low) >= BURIED:
		return                                             # buried (deep in solid ground): leave it
	var push := Vector3.ZERO
	var deepest := 0.0
	for c: Vector3 in [low, high]:
		for dir in SURFACE_PROBES:
			var d := world.density_at(c + dir * CAPSULE_RADIUS)
			if d > TOLERANCE:
				push -= dir * (d - TOLERANCE)
				deepest = maxf(deepest, d)
	if deepest <= 0.0:
		return
	var way := push.normalized()
	position += way * minf(deepest - TOLERANCE + 0.02, 0.25)
	var into := linear_velocity.dot(-way)
	if into > 0.0:
		linear_velocity += way * into                      # no more speed into the ground

## Walking on the ground, level or sloped. The movement follows the SURFACE (the keys' direction laid into the slope plane, same speed),
## and where he may stand, gravity's pull down the slope is cancelled, so he stays where he stops. Steeper than that he slides.
func _grip(wish: Vector3, top: float, up: Vector3, delta: float) -> void:
	var n := _floor_n
	var cosa := clampf(n.dot(up), 0.0, 1.0)
	slope_deg = rad_to_deg(acos(cosa))
	var hyst := -2.0 if sliding else 2.0                                  # a little hysteresis: no flicker at a limit
	var downhill := (-up + n * n.dot(up)).normalized() if cosa < 0.999 else Vector3.ZERO     # the way a ball would roll
	var want := wish.normalized() if wish.length() > 0.01 else Vector3.ZERO
	var uphill_push := 0.0 if downhill == Vector3.ZERO else maxf(0.0, -want.dot(downhill))
	var gt := -up * GRAVITY * mass
	gt -= n * gt.dot(n)                                                    # gravity's share along the surface
	var mode := 0                                                          # 0 stand/walk, 1 scramble, 2 slide
	if slope_deg > stand_slope_deg + hyst:
		mode = 1 if (slope_deg <= scramble_slope_deg + hyst and uphill_push > 0.3) else 2
	sliding = mode == 2
	var vn := minf(linear_velocity.dot(n), 0.0)
	var along := linear_velocity - n * linear_velocity.dot(n)              # the speed along the surface
	if mode == 2:
		# nothing to hold on to: gravity takes him down; a little steering across the slope only
		var across := want - downhill * want.dot(downhill)
		along += across * AIR_ACCEL * 0.3 * delta
		linear_velocity = along + n * vn
		return
	apply_central_force(-gt)                                               # held: nothing pulls him down the slope
	var goal := Vector3.ZERO
	if want != Vector3.ZERO:
		var flat := want - n * want.dot(n)
		if flat.length() > 0.001:
			goal = flat.normalized() * top * (SCRAMBLE_SPEED if mode == 1 else 1.0)
	along = along.move_toward(goal, (GROUND_ACCEL if want != Vector3.ZERO else GROUND_BRAKE) * delta)
	linear_velocity = along + n * vn

## Is something solid under the feet, and what is it like? A ray from the lower sphere's centre straight down: a flat floor is hit at the
## sphere's radius, a slope further away (radius / cos of the slope), so the distance is judged against the slope it found: steep ground counts.
func _on_ground(up: Vector3) -> bool:
	var low := global_position + up * (CAPSULE_CENTRE - CAPSULE_HEIGHT * 0.5 + CAPSULE_RADIUS)
	var q := PhysicsRayQueryParameters3D.create(low, low - up * 2.2, 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		sliding = false
		slope_deg = 0.0
		return false
	var n: Vector3 = hit.normal
	if n.dot(up) < 0.05:
		sliding = false
		return false                                         # an overhang or a wall: nothing to stand on
	var d: float = low.distance_to(hit.position)
	var reach := CAPSULE_RADIUS / maxf(n.dot(up), 0.25) + 0.15
	if d > reach:
		sliding = false
		return false
	_floor_n = _floor_n.slerp(n, 0.5).normalized() if _floor_n.dot(n) > 0.0 else n
	ground_normal = _floor_n
	slope_deg = rad_to_deg(acos(clampf(_floor_n.dot(up), 0.0, 1.0)))
	return true

## Flying never carries the body into solid ground. The step it is about to make is walked in 0.4 m strides against the terrain DATA: at FLY_SPEED a
## step is 4 m, more than the physics shape of the ground is thick (the ball would go through the floor) and more than the chunks round him can be
## built in time. It stops short of the ground, so he can turn and fly away, and never ends up inside it.
const FLY_STRIDE := 0.4
const FLY_MARGIN := 0.7            # stays this far (m) from the ground: the capsule's radius and a little more

func _fly_clip(v: Vector3, delta: float) -> Vector3:
	if world == null or v.length() < 0.01:
		return v
	var dir := v.normalized()
	var dist := v.length() * delta + FLY_MARGIN
	var mid := position + position.normalized() * CAPSULE_CENTRE         # (the player is a direct child of the world root: local = global)
	var free := 0.0
	var t := FLY_STRIDE
	while t <= dist:
		if world.density_at(mid + dir * t) > 0.0:
			return dir * (maxf(free - FLY_MARGIN, 0.0) / delta)
		free = t
		t += FLY_STRIDE
	return v

## FLYING NAVIGATION (separate from the ground's): the mouse steers, the keys only push along what it steers.
##   - mouse sideways = turns the heading (as on the ground); the aim cursor pushed against the TOP of the dashed circle = climb, against the
##     BOTTOM = dive (fly_pitch, main.gd feeds it);
##   - W / S go forward / back along that full 3D direction, A / D strafe level, Shift boosts; no keys = hover in place;
##   - Space and Ctrl do nothing in the air.
func _fly_step(delta: float, up: Vector3, fwd: Vector3, right: Vector3, kx: float, kz: float) -> void:
	linear_damp = 0.0
	var top := (FLY_BOOST if running else FLY_SPEED) * lerpf(1.0, 0.5, in_water)       # under water the flight is half as fast
	var ahead := fwd.rotated(right, fly_pitch)
	var want := ahead * kz + right * kx
	var goal := want.normalized() * top if want.length() > 0.01 else Vector3.ZERO
	var v := linear_velocity.move_toward(goal, (FLY_ACCEL if goal != Vector3.ZERO else FLY_BRAKE) * delta)
	linear_velocity = _fly_clip(v, delta)

## The mouse's vertical push while flying or diving (pixels, + = down on the screen): up climbs / rises.
func steer_pitch(push_y: float) -> void:
	if fly:
		fly_pitch = clampf(fly_pitch - push_y * 0.003, -FLY_MAX_PITCH, FLY_MAX_PITCH)
	else:
		swim_pitch = clampf(swim_pitch - push_y * 0.003, -FLY_MAX_PITCH, FLY_MAX_PITCH)

## True while the mouse should steer the pitch (flight, or a dive): main.gd asks.
func steers_pitch() -> bool:
	return fly or swim_state == SwimState.DIVE or swim_state == SwimState.DEEP

## SWIMMING NAVIGATION under the surface (dive / deep), separate from the surface float, the ground and the flight:
##   W / S swim along the full 3D view direction (the mouse steers its pitch, like flight), A / D strafe level, Shift is faster,
##   Space swims up, Ctrl down; nothing pressed = neutral buoyancy (he hangs there and drifts up very slowly); near the surface a gentle
##   lift brings him back to floating.
func _swim_step(delta: float, up: Vector3, fwd: Vector3, right: Vector3, kx: float, kz: float, sub: float) -> void:
	linear_damp = 0.0
	var spd := SWIM_FAST if running else SWIM_SPEED
	var ahead := fwd.rotated(right, swim_pitch)
	var want := ahead * kz + right * kx
	var goal := want.normalized() * spd if want.length() > 0.01 else Vector3.ZERO
	var space := Input.is_physical_key_pressed(KEY_SPACE)
	var ctrl := Input.is_physical_key_pressed(KEY_CTRL)
	if space:
		goal += up * SWIM_VERTICAL
	if ctrl:
		goal -= up * SWIM_DIVE
	if not ctrl and not space and want.length() < 0.01:
		goal += up * SWIM_DRIFT
	if not ctrl and sub < 1.5:
		goal += up * clampf(1.5 - sub, 0.0, 1.5) * 1.4                       # near the surface the water lifts him to floating level
	var rate := SWIM_ACCEL if goal != Vector3.ZERO else SWIM_BRAKE
	linear_velocity = linear_velocity.move_toward(goal, rate * delta)

## The swim state from how deep he is and whether Ctrl is held (with hysteresis, so it never flickers at a limit).
func _update_swim_state(sub: float, ctrl: bool, up: Vector3) -> void:
	var old := swim_state
	if not swimming or fly:
		swim_state = SwimState.NONE
	else:
		match swim_state:
			SwimState.NONE, SwimState.SURFACE:
				swim_state = SwimState.DIVE if (ctrl or sub >= 1.2) else SwimState.SURFACE
			SwimState.DIVE:
				if sub >= 2.5:
					swim_state = SwimState.DEEP
				elif sub < 0.6 and not ctrl:
					swim_state = SwimState.SURFACE
			SwimState.DEEP:
				if sub < 2.0:
					swim_state = SwimState.DIVE
	if swim_state != old and (swim_state == SwimState.NONE or swim_state == SwimState.SURFACE):
		swim_pitch = 0.0

## Where the body is drawn. Physics runs at 60 steps a second and the picture at whatever the frame rate is (and it hitches while terrain is built):
## walking is slow enough not to show it, but flying at 22 to 90 m/s moves the body 0.4 to 1.5 m per step, so the character and the camera
## would stutter. In flight they read this position, blended between the last two physics steps by how far into the next step the frame is.
func render_pos() -> Vector3:
	if not fly:
		return global_position
	return _prev_pos.lerp(_cur_pos, Engine.get_physics_interpolation_fraction())

func toggle_fly() -> void:
	fly = not fly
	_prev_pos = global_position
	_cur_pos = global_position
	fly_pitch = 0.0
	if not fly:
		linear_velocity = linear_velocity.limit_length(6.0)      # leaving flight (even by mistake) never throws him away

func respawn() -> void:
	linear_velocity = Vector3.ZERO
	global_position = spawn_pos

static func _axis(pos_key: Key, neg_key: Key) -> float:
	return float(Input.is_physical_key_pressed(pos_key)) - float(Input.is_physical_key_pressed(neg_key))
