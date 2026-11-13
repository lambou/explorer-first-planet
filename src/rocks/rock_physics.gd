class_name RockPhysics
extends Node3D
## Gravity for rocks. A rock is either FIXED (sunk into the floor, bending it: it never moves) or LOOSE (it rests on
## top, or sits in its pocket): a rigid body. Nothing is simulated while a rock is held. The check is event driven:
## when the terrain is edited, only the loose rocks next to the edit test whether solid ground still touches their
## underside. An unsupported rock becomes a FALLING BODY: its mesh leaves the chunk's baked mesh and becomes one small
## node, approximated as a sphere (radial gravity, probes into the density field, a bounce, rolling down slopes), and when
## it comes to rest it is put back into the chunk it lies in; the new place is stored (RockSystem.relocate).
## Cost: a handful of density lookups per nearby rock per edit; a few lookups per falling rock per frame.

const GRAVITY := 16.0
const MAX_BODIES := 24
const REST_SPEED := 0.4
const REST_TIME := 0.35
const MAX_AGE := 14.0
const SUPPORT_FRACTION := 0.28      # share of the underside samples that must touch solid ground
const EMBED_FRACTION := 0.25        # share of the whole surface that must still touch the floor for a fixed rock to stay
const MIN_GROUND_UP := 0.62         # the ground under a loose rock may be at most ~52 degrees steep
const RESTITUTION := 0.25
const FRICTION := 2.2               # velocity lost per second to rolling friction

var world: VoxelWorld
var _bodies: Array = []

func active() -> int:
	return _bodies.size()

## Is the rock held? A FIXED rock is held while it is still really sunk into the floor (solid ground touches enough of its
## whole surface). A LOOSE rock is held when solid ground touches its underside (7 samples on the lower half) AND that
## ground is not too steep: on a steep wall it would slide, so it is not held.
func supported(r: RockInst) -> bool:
	var f := RockMesher.frame_of(r)
	var up := r.pos.normalized()
	var t1 := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized()
	var t2 := up.cross(t1)
	var down := -up
	var dirs: Array[Vector3] = []
	if r.fixed:
		# embedded: samples all around (down, up, and rings at -45, 0 and +45 degrees)
		dirs = [down, up]
		for el in [-0.8, 0.0, 0.8]:
			for i in 4:
				var a := TAU * i / 4.0 + 0.3
				dirs.append((up * sin(el) + (t1 * cos(a) + t2 * sin(a)) * cos(el)).normalized())
	else:
		dirs = [down]
		for ring in [[0.5, 3], [0.9, 3]]:
			var tilt: float = ring[0]
			for i in int(ring[1]):
				var a := TAU * i / float(ring[1]) + tilt
				dirs.append((down * cos(tilt) + (t1 * cos(a) + t2 * sin(a)) * sin(tilt)).normalized())
	var solid := 0
	var first_contact := Vector3.INF
	for w in dirs:
		var wl := Vector3(w.dot(f.x), w.dot(f.y), w.dot(f.z))        # the same direction in the rock's own frame
		var l := RockMesher.surface_radius(r, f, wl)
		var p := r.pos + w * l
		if world.density_at(p) > 0.0:
			solid += 1
			if first_contact == Vector3.INF:
				first_contact = p
	var frac := float(solid) / dirs.size()
	if r.fixed:
		return frac >= EMBED_FRACTION
	if frac < SUPPORT_FRACTION:
		return false
	# the ground under it must be gentle enough to hold a loose rock
	var e := 0.4
	var g := Vector3(world.density_at(first_contact + Vector3(e, 0, 0)) - world.density_at(first_contact - Vector3(e, 0, 0)),
		world.density_at(first_contact + Vector3(0, e, 0)) - world.density_at(first_contact - Vector3(0, e, 0)),
		world.density_at(first_contact + Vector3(0, 0, e)) - world.density_at(first_contact - Vector3(0, 0, e)))
	if g.length() < 0.0001:
		return true
	return (-g).normalized().dot(up) >= MIN_GROUND_UP

## The terrain changed around `center` (radius `radius`): loose rocks that lost their support start to fall.
func after_edit(center: Vector3, radius: float) -> int:
	var started := 0
	for c: Vector3i in world.chunks:
		var ch: Chunk = world.chunks[c]
		if ch.rocks.is_empty() or (ch.position + Vector3.ONE * 8.0).distance_to(center) > radius + 26.0:
			continue
		for r: RockInst in ch.rocks.duplicate():
			if r.pos.distance_to(center) > radius + r.size * 1.6 + 2.0:
				continue
			if not supported(r):
				start_fall(r, ch)
				started += 1
	return started

## A rock was struck: whatever is left of it must still rest on something, or it falls (the same rule for every rock type).
func check_rock(r: RockInst, ch: Chunk) -> bool:
	if ch.rocks.has(r) and not supported(r):
		start_fall(r, ch)
		return true
	return false

## A piece that came off a rock (it has no chunk yet): it falls from where it is.
func drop_piece(piece: RockInst) -> void:
	start_fall(piece, null)

func start_fall(r: RockInst, ch: Chunk) -> void:
	if _bodies.size() >= MAX_BODIES:
		_finish(_bodies[0])                                   # too many in flight: the oldest comes to rest where it is
	if ch != null:
		ch.rocks.erase(r)
		world.rebake_rocks(ch)
	var copy := RockInst.from_state(r.to_state())
	if not r.bites.is_empty():
		copy.cut = r.cut if (not r.cut.is_empty() and r.cut_sig == r.bites.hash()) else RockCut.build(copy, world.rocks.catalog)   # a bitten rock falls as it is cut
	copy.pos = Vector3.ZERO
	var baked := RockMesher.bake([copy], world.rocks.catalog, Vector3.ZERO)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = baked.verts
	arrays[Mesh.ARRAY_NORMAL] = baked.normals
	arrays[Mesh.ARRAY_COLOR] = baked.colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = world.material
	var node := Node3D.new()
	node.add_child(mi)
	add_child(node)
	node.global_transform = Transform3D(Basis.IDENTITY, r.pos)
	_bodies.append({"rock": r, "node": node, "p": r.pos, "v": Vector3.ZERO, "rot": Basis.IDENTITY, "rest": 0.0, "age": 0.0,
		"rho": maxf(r.size * 0.8, 0.1), "stuck_t": 0.0, "stuck_p": r.pos})

func _physics_process(delta: float) -> void:
	var dt := minf(delta, 1.0 / 30.0)
	var i := 0
	while i < _bodies.size():
		var b: Dictionary = _bodies[i]
		if _step(b, dt):
			_finish(b)
		else:
			i += 1

## One step of a falling rock. Returns true when it has come to rest.
func _step(b: Dictionary, dt: float) -> bool:
	var p: Vector3 = b.p
	var v: Vector3 = b.v
	var rho: float = b.rho
	b.age += dt
	var up := p.normalized()
	v -= up * GRAVITY * dt
	p += v * dt
	# probes around the sphere: push out of the ground, bounce a little, rub
	up = p.normalized()
	var t1 := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized()
	var t2 := up.cross(t1)
	var grounded := false
	var slope_n := up
	for dir: Vector3 in [-up, t1, -t1, t2, -t2, up]:
		var d := world.density_at(p + dir * rho)
		if d <= 0.0:
			continue
		p -= dir * (d + 0.02)
		var vn := v.dot(dir)
		if vn > 0.0:
			v -= dir * vn * (1.0 + RESTITUTION)
		if dir == -up:
			grounded = true
			# the ground's normal under the rock (minus the density gradient)
			var e := 0.4
			var q := p - up * rho
			var g := Vector3(world.density_at(q + Vector3(e, 0, 0)) - world.density_at(q - Vector3(e, 0, 0)),
				world.density_at(q + Vector3(0, e, 0)) - world.density_at(q - Vector3(0, e, 0)),
				world.density_at(q + Vector3(0, 0, e)) - world.density_at(q - Vector3(0, 0, e)))
			if g.length() > 0.0001:
				slope_n = (-g).normalized()
	if grounded:
		# rolling: friction eats the speed along the ground; the rock turns as it rolls
		var vt := v - slope_n * v.dot(slope_n)
		v -= vt * minf(FRICTION * dt, 1.0)
		var speed := vt.length()
		if speed > 0.05:
			var axis := slope_n.cross(vt).normalized()
			b.rot = Basis(axis, speed * dt / rho) * b.rot
		var flat_enough := slope_n.dot(up) > 0.72
		if v.length() < REST_SPEED and flat_enough:
			b.rest += dt
		else:
			b.rest = 0.0
	else:
		b.rest = 0.0
	# stuck: grounded and hardly moved over the last half second (wedged in a pit, rocking): it has come to rest
	b.stuck_t += dt
	if b.stuck_t >= 0.5:
		if grounded and p.distance_to(b.stuck_p) < 0.15:
			b.rest = REST_TIME
		b.stuck_t = 0.0
		b.stuck_p = p
	b.p = p
	b.v = v
	var node: Node3D = b.node
	node.global_transform = Transform3D(b.rot, p)
	return b.rest >= REST_TIME or b.age >= MAX_AGE

## The rock comes to rest: it goes back into the chunk it lies in, upright, and its new place is stored.
func _finish(b: Dictionary) -> void:
	var r: RockInst = b.rock
	var p: Vector3 = b.p
	var up := p.normalized()
	r.pos = p - up * (0.25 * r.size)                         # a loose rock rests slightly sunk, like the ones placed at generation
	r.normal = up
	r.fixed = false
	world.rocks.relocate(r)
	world.place_rock(r)
	if not r.bites.is_empty():
		world.refresh_cut(r)                                  # it lies in a new orientation: its cut shape is built again
	(b.node as Node3D).queue_free()
	_bodies.erase(b)
