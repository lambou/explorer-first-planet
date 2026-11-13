class_name BallPlayer
extends RigidBody3D
## The explorer: a bouncing ball under radial gravity (towards planet centre).

const GRAVITY := 14.0
const MOVE_FORCE := 40.0
const JUMP_IMPULSE := 8.0
const FLY_SPEED := 250.0
const MAX_ROLL_SPEED := 22.0   # 32 km lap in ~24 min

var cam: OrbitCamera
var world: VoxelWorld        # for water queries (buoyancy)
var in_water := 0.0           # 0 = dry .. 1 = fully under water
var fly := false
var spawn_pos := Vector3.ZERO

func _ready() -> void:
	mass = 1.0
	gravity_scale = 0.0
	linear_damp = 0.6
	angular_damp = 1.0
	can_sleep = false
	continuous_cd = true
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.35
	pm.friction = 0.9
	physics_material_override = pm
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.5
	cs.shape = sh
	add_child(cs)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 10
	sm.rings = 5
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("ff7a1a")
	mat.roughness = 0.6
	mi.material_override = mat
	add_child(mi)

func _physics_process(_delta: float) -> void:
	if freeze:
		return
	_keep_out_of_ground()
	var up := global_position.normalized()
	var fwd: Vector3 = cam.view_fwd if cam else Vector3.FORWARD     # the top of the screen, even when the camera swung round
	var right := fwd.cross(up)
	var kx := _axis(KEY_D, KEY_A)
	var kz := _axis(KEY_W, KEY_S)
	var wish := fwd * kz + right * kx
	if fly:
		var v := wish * FLY_SPEED + up * _axis(KEY_SPACE, KEY_CTRL) * FLY_SPEED
		linear_velocity = v
		return
	# water: buoyancy lifts the ball to the surface, water drags it, and Space swims upwards
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
	var tangent_v := linear_velocity - up * linear_velocity.dot(up)
	if tangent_v.length() > MAX_ROLL_SPEED:
		linear_velocity -= tangent_v * (1.0 - MAX_ROLL_SPEED / tangent_v.length())
	if wish.length() > 0.01:
		apply_central_force(wish.normalized() * MOVE_FORCE)
	if Input.is_physical_key_pressed(KEY_SPACE) and in_water < 0.3 and _on_ground(up):
		apply_central_impulse(up * JUMP_IMPULSE)

## The ball must never be partly inside the ground. Fourteen points of its surface are tested against the terrain data (the
## physics shape can lag behind an edit or a rebuilt chunk, or be tunnelled by a fast landing); the points that are inside add up
## to a way out, and the ball is moved that way (at most 25 cm per step, so it looks like being pushed up, not a jump) and loses
## its speed into the ground. A ball whose centre is deep in solid ground (BURIED) is left alone: nobody is rescued.
const SURFACE_PROBES: Array[Vector3] = [Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
	Vector3(0.577, 0.577, 0.577), Vector3(-0.577, 0.577, 0.577), Vector3(0.577, -0.577, 0.577), Vector3(-0.577, -0.577, 0.577),
	Vector3(0.577, 0.577, -0.577), Vector3(-0.577, 0.577, -0.577), Vector3(0.577, -0.577, -0.577), Vector3(-0.577, -0.577, -0.577)]
const RADIUS := 0.5
const BURIED := 0.55               # centre deeper than this inside the ground = buried by the player's own digging / filling
const TOLERANCE := 0.12            # how far into the ground (density units, about metres) a surface point may be before it is pushed out

func _keep_out_of_ground() -> void:
	if world == null or fly:
		return
	var c := position                                      # the player is a direct child of the world root (at the origin): same as global
	if world.density_at(c) >= BURIED:
		return                                             # buried (the centre is deep in solid ground): leave it
	var push := Vector3.ZERO
	var deepest := 0.0
	for dir in SURFACE_PROBES:
		var d := world.density_at(c + dir * RADIUS)
		if d > TOLERANCE:
			push -= dir * (d - TOLERANCE)
			deepest = maxf(deepest, d)
	if deepest <= 0.0:
		return
	var way := push.normalized()
	position = c + way * minf(deepest - TOLERANCE + 0.02, 0.25)
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
