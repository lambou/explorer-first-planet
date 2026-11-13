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
const FLY_SPEED := 250.0

const CAPSULE_RADIUS := 0.6    # wide enough for the round body you see
const CAPSULE_HEIGHT := 1.8    # from the soles (-0.5 under the origin) to 1.3 above it
const CAPSULE_CENTRE := 0.4    # height of the capsule's middle above the origin

var cam: OrbitCamera
var world: VoxelWorld        # for water queries (buoyancy)
var in_water := 0.0           # 0 = dry .. 1 = fully under water
var fly := false
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
	if freeze:
		return
	_keep_out_of_ground()
	var up := global_position.normalized()
	grounded = _on_ground(up)
	running = Input.is_physical_key_pressed(KEY_SHIFT)
	var fwd: Vector3 = cam.view_fwd if cam else Vector3.FORWARD     # W goes where the camera faces
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var right := fwd.cross(up)
	var kx := _axis(KEY_D, KEY_A)
	var kz := _axis(KEY_W, KEY_S)
	var wish := fwd * kz + right * kx
	if fly:
		var v := wish * FLY_SPEED + up * _axis(KEY_SPACE, KEY_CTRL) * FLY_SPEED
		linear_velocity = _fly_clip(v, delta)
		return
	# water: buoyancy lifts him to the surface, water drags, and Space swims upwards
	in_water = 0.0
	if world != null:
		var sub := world.submersion(global_position)
		in_water = clampf((sub + 0.5) / 1.0, 0.0, 1.0)
	linear_damp = lerpf(0.6, 3.2, in_water)
	apply_central_force(-up * GRAVITY * mass * (1.0 - 1.8 * in_water))
	if in_water > 0.0 and Input.is_physical_key_pressed(KEY_SPACE):
		apply_central_force(up * GRAVITY * mass * 1.4 * in_water)
	if in_water > 0.0 and Input.is_physical_key_pressed(KEY_CTRL):
		apply_central_force(-up * GRAVITY * mass * 2.6 * in_water)     # dive
	var vv := linear_velocity.dot(up)
	var vt := linear_velocity - up * vv
	var top := RUN_SPEED if running else WALK_SPEED
	if in_water > 0.5:
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

func toggle_fly() -> void:
	fly = not fly

func respawn() -> void:
	linear_velocity = Vector3.ZERO
	global_position = spawn_pos

static func _axis(pos_key: Key, neg_key: Key) -> float:
	return float(Input.is_physical_key_pressed(pos_key)) - float(Input.is_physical_key_pressed(neg_key))
