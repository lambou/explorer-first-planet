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

func _ready() -> void:
	mass = 1.0
	gravity_scale = 0.0
	linear_damp = 0.6
	angular_damp = 8.0
	can_sleep = false
	continuous_cd = true
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.0
	pm.friction = 0.0          # the steering decides how fast he starts and stops, not the ground's grip
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
		linear_velocity = v
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
		var target := wish.normalized() * top if wish.length() > 0.01 else Vector3.ZERO
		var rate := AIR_ACCEL
		if grounded:
			rate = GROUND_ACCEL if wish.length() > 0.01 else GROUND_BRAKE
		vt = vt.move_toward(target, rate * delta)
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

func _on_ground(up: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(global_position, global_position - up * 0.75, 1, [get_rid()])
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()

func toggle_fly() -> void:
	fly = not fly

func respawn() -> void:
	linear_velocity = Vector3.ZERO
	global_position = spawn_pos

static func _axis(pos_key: Key, neg_key: Key) -> float:
	return float(Input.is_physical_key_pressed(pos_key)) - float(Input.is_physical_key_pressed(neg_key))
