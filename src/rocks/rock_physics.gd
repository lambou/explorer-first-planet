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

# ---- tuning of the falling body (change these to change how rocks feel) ----
const POINTS := 20                  # contact points on the rock's real outline
const MAX_STEP := 0.6               # a rock never moves more than this (m) in one step: it cannot tunnel through thin ground
const MAX_PUSH := 0.4               # at most this far (m) is a rock pushed out of the ground in one step
const BOUNCE := 0.35                # bounce of a 1 m rock (divided by 1 + size: a boulder hardly bounces)
const BOUNCE_MIN_SPEED := 1.5       # slower impacts do not bounce at all
const FRICTION_MU := 0.7            # grip on the ground
const SPIN_DAMP := 3.0              # spin lost per second while touching the ground
const ROLL_DAMP := 0.8              # speed lost per second while touching the ground
const AIR_SPIN_DAMP := 0.1
const REST_SPIN := 0.6              # rad/s: slower than this (and slow, and not on a steep slope) counts as resting
const MIN_REST_UP := 0.6            # ground normal . up needed to come to rest

var world: VoxelWorld
var debris: RockDebris              # chips on a hard landing (optional)
var _last_us := 0
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
		# a bitten rock falls as it is cut: the shape it has now (one blow stale at most, never a wait for a new one)
		copy.cut = r.cut if not r.cut.is_empty() else RockCut.build(copy, world.rocks.catalog)
	# contact points: where the rock's REAL surface lies along POINTS directions (world axes, from the centre, in the pose it starts in)
	var frame := RockMesher.frame_of(copy)
	var pts: Array[Vector3] = []
	var mean_r := 0.0
	for i in POINTS:
		var y := 1.0 - 2.0 * (i + 0.5) / POINTS
		var rr := sqrt(maxf(0.0, 1.0 - y * y))
		var ph := i * 2.399963229728653
		var w := Vector3(cos(ph) * rr, y, sin(ph) * rr)
		var l := RockMesher.surface_radius(copy, frame, Vector3(w.dot(frame.x), w.dot(frame.y), w.dot(frame.z)))
		pts.append(w * l)
		mean_r += l / POINTS
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
	var rho := maxf(mean_r, 0.08)
	_bodies.append({"rock": r, "node": node, "p": r.pos, "v": Vector3.ZERO, "w": Vector3.ZERO, "rot": Basis.IDENTITY, "rest": 0.0, "age": 0.0,
		"pts": pts, "inv_i": 1.0 / (0.4 * rho * rho), "e": BOUNCE / (1.0 + r.size),     # a big rock hardly bounces
		"fx": frame.x, "fy": frame.y, "stuck_t": 0.0, "stuck_p": r.pos, "hit_t": 0.0})

func stats() -> String:
	return "Rock physics  %d falling  %.2f ms" % [_bodies.size(), _last_us / 1000.0]

func _physics_process(delta: float) -> void:
	if _bodies.is_empty():
		_last_us = 0
		return
	var t0 := Time.get_ticks_usec()
	var dt := minf(delta, 1.0 / 30.0)
	var i := 0
	while i < _bodies.size():
		var b: Dictionary = _bodies[i]
		if _step(b, dt):
			_finish(b)
		else:
			i += 1
	_last_us = Time.get_ticks_usec() - t0

## One step of a falling rock: a rigid body with the rock's real outline. Gravity pulls to the planet's centre; the contact points of the
## outline that are inside the ground give ONE contact (their mean) with a normal impulse (bounce), friction and the torque that tips
## and rolls the rock. Returns true when it has come to rest.
func _step(b: Dictionary, dt: float) -> bool:
	var p: Vector3 = b.p
	var v: Vector3 = b.v
	var w: Vector3 = b.w
	var rot: Basis = b.rot
	var inv_i: float = b.inv_i
	b.age += dt
	b.hit_t -= dt
	var up := p.normalized()
	v -= up * GRAVITY * dt
	if v.length() * dt > MAX_STEP:
		v = v.normalized() * (MAX_STEP / dt)
	p += v * dt
	var wl := w.length()
	if wl > 0.0001:
		rot = (Basis(w / wl, minf(wl * dt, 0.5)) * rot).orthonormalized()
	up = p.normalized()
	var csum := Vector3.ZERO
	var n_hit := 0
	var deep := 0.0
	for q: Vector3 in b.pts:
		var off := rot * q
		var d := world.density_at(p + off)
		if d > 0.0:
			csum += off
			n_hit += 1
			deep = maxf(deep, d)
	var grounded := n_hit > 0
	var n := up
	if grounded:
		var rc := csum / n_hit
		var cp := p + rc
		var e := 0.4
		var g := Vector3(world.density_at(cp + Vector3(e, 0, 0)) - world.density_at(cp - Vector3(e, 0, 0)),
			world.density_at(cp + Vector3(0, e, 0)) - world.density_at(cp - Vector3(0, e, 0)),
			world.density_at(cp + Vector3(0, 0, e)) - world.density_at(cp - Vector3(0, 0, e)))
		if g.length() > 0.0001:
			n = (-g).normalized()
		p += n * minf(deep + 0.01, MAX_PUSH)
		var vrel := v + w.cross(rc)
		var vn := vrel.dot(n)
		var j := 0.0
		if vn < 0.0:
			var k := 1.0 + rc.cross(n).length_squared() * inv_i
			var bounce: float = b.e if -vn > BOUNCE_MIN_SPEED else 0.0
			j = -(1.0 + bounce) * vn / k
			v += n * j
			w += rc.cross(n * j) * inv_i
			if -vn > 3.0 and b.hit_t <= 0.0:
				b.hit_t = 0.25
				_impact(b.rock, cp, n, -vn)
		vrel = v + w.cross(rc)
		var vt := vrel - n * vrel.dot(n)
		var vtl := vt.length()
		if vtl > 0.0001:
			var tdir := vt / vtl
			var kt := 1.0 + rc.cross(tdir).length_squared() * inv_i
			var jt := minf(vtl / kt, FRICTION_MU * maxf(j, GRAVITY * dt))
			v -= tdir * jt
			w -= rc.cross(tdir * jt) * inv_i
		w *= maxf(0.0, 1.0 - SPIN_DAMP * dt)
		v *= maxf(0.0, 1.0 - ROLL_DAMP * dt)
		if v.length() < REST_SPEED and w.length() < REST_SPIN and n.dot(up) > MIN_REST_UP:
			b.rest += dt
		else:
			b.rest = 0.0
	else:
		w *= maxf(0.0, 1.0 - AIR_SPIN_DAMP * dt)
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
	b.w = w
	b.rot = rot
	(b.node as Node3D).global_transform = Transform3D(rot, p)
	return b.rest >= REST_TIME or b.age >= MAX_AGE

## A hard landing: chips fly, more of them for a bigger rock and a faster hit.
func _impact(r: RockInst, point: Vector3, n: Vector3, speed: float) -> void:
	if debris == null:
		return
	var col := world.rocks.catalog.by_id(r.layers[0][0]).color
	debris.burst(point, n, [col, col.darkened(0.2)], int(clampf(speed, 3.0, 12.0) * (0.6 + r.size)), 0.07 + 0.05 * r.size)

## The rock comes to rest: it goes back into the chunk it lies in, in the pose it came to rest in, and its place is stored.
## A rock's pose is its up axis (`normal`) and its yaw, which can describe any orientation, so a rock that lies on its side keeps lying so.
func _finish(b: Dictionary) -> void:
	var r: RockInst = b.rock
	var p: Vector3 = b.p
	var rot: Basis = b.rot
	var up := p.normalized()
	r.pos = p - up * (0.05 * r.size)                         # a loose rock rests very slightly sunk
	var y := (rot * (b.fy as Vector3)).normalized()
	var x := (rot * (b.fx as Vector3))
	x = (x - y * x.dot(y)).normalized()
	var ref := Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.FORWARD
	r.normal = y
	r.yaw = y.cross(ref).normalized().signed_angle_to(x, y)
	r.fixed = false
	world.rocks.relocate(r)
	world.place_rock(r)
	if not r.bites.is_empty():
		world.refresh_cut(r)                                  # it lies in a new orientation: its cut shape is built again
	(b.node as Node3D).queue_free()
	_bodies.erase(b)
