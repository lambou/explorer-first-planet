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

# ---- tuning of the falling body (change these to change how rocks feel) ----
var rock_contacts := true             # falling rocks bump into the rocks that lie around (off = they pass through them: tests use it as the control)
const POINTS := 20                  # contact points on the rock's real outline
const MAX_STEP := 0.6               # a rock never moves more than this (m) in one step: it cannot tunnel through thin ground
const MAX_PUSH := 0.4               # at most this far (m) is a rock pushed out of the ground in one step
const BOUNCE := 0.35                # bounce of a 1 m rock (divided by 1 + size: a boulder hardly bounces)
const BOUNCE_MIN_SPEED := 1.5       # slower impacts do not bounce at all
const FRICTION_MU := 0.7            # grip on the ground
const SPIN_DAMP := 3.0              # spin lost per second while touching the ground
const ROLL_DAMP := 0.8              # speed lost per second while touching the ground
const AIR_SPIN_DAMP := 0.1
const SUPPORT_SKIN := 0.3           # the support test forgives a gap this small (m): generated rocks rest on slopes with a hairline gap the grass hides
const SUPPORT_SAMPLES := 96         # outline points sampled by the support test
const SUPPORT_POINTS := 3           # a rock holds while at least this many of its SUPPORT_SAMPLES outline points touch the ground (3 = it cannot tip)
const SKIN := 0.06                  # contact distance (density units ~ m) inside which a point already touches
const SETTLE_SPEED := 1.5           # below this speed (m/s) the extra settling damping applies
const SETTLE_DAMP := 8.0
const REST_SPIN := 0.6              # rad/s: slower than this (and slow, and not on a steep slope) counts as resting
const MIN_REST_UP := 0.6            # ground normal . up needed to come to rest

var world: VoxelWorld
var debris: RockDebris              # chips on a hard landing (optional)
var _last_us := 0
var _dirty := {}                    # chunks whose rock mesh must be re-baked (rocks landed in them)
var _bodies: Array = []

func active() -> int:
	return _bodies.size()

## Is the rock held? It is when at least SUPPORT_POINTS points of its REAL outline (bites included, the pose it lies in) touch the ground:
## the very test the falling body uses to come to rest, so a rock never falls just because a chip came off its side, and never hangs
## in the air either. The same rule for every rock type, loose or sunk into the floor.
func supported(r: RockInst) -> bool:
	return _touching(r, SUPPORT_SKIN, SUPPORT_POINTS) >= SUPPORT_POINTS

## How many of the rock's outline points touch the ground or another rock (within the skin), for the pose it lies in. Counting stops at `stop_at`
## (the support test only needs SUPPORT_POINTS). The sampling starts at the underside, where a held rock touches, and the ground is asked first: the
## neighbouring rocks are only looked up when the ground does not hold the rock by itself (the common case costs a few lookups).
func _touching(r: RockInst, skin: float = SKIN, stop_at: int = 1000000) -> int:
	var f := RockMesher.frame_of(r)
	var n := 0
	var misses := PackedVector3Array()
	for k in SUPPORT_SAMPLES:                                  # dense: it runs once per blow, not once per frame (a sparse test misses a rock's real contact patch)
		var i := SUPPORT_SAMPLES - 1 - k                       # from the bottom of the rock up
		var y := 1.0 - 2.0 * (i + 0.5) / SUPPORT_SAMPLES
		var rr := sqrt(maxf(0.0, 1.0 - y * y))
		var ph := i * 2.399963229728653
		var w := Vector3(cos(ph) * rr, y, sin(ph) * rr)
		var l := RockMesher.surface_radius(r, f, Vector3(w.dot(f.x), w.dot(f.y), w.dot(f.z)))
		var pt := r.pos + w * l
		if world.density_at(pt) > -skin:
			n += 1
			if n >= stop_at:
				return n
		else:
			misses.append(pt)
	if misses.is_empty():
		return n
	var others := RockContact.nearby(world, r.pos, r.size * 1.75 + 0.5, r)        # a rock lying on another rock is held by it
	if others.is_empty():
		return n
	for pt in misses:
		for c: Dictionary in others:
			if RockContact.depth(c, pt) > -skin:
				n += 1
				break
		if n >= stop_at:
			return n
	return n

## A rock was struck, chipped away or broke: the rocks that lay on it may have lost their support. Only the rocks that touch it are tested.
func check_around(center: Vector3, radius: float, skip: RockInst = null) -> int:
	var started := 0
	for c: Dictionary in RockContact.nearby(world, center, radius, skip):
		var r: RockInst = c.r
		var ch: Chunk = world.chunks.get(VoxelWorld.world_to_chunk(r.pos))
		if ch != null and ch.rocks.has(r) and not supported(r):
			start_fall(r, ch)
			started += 1
	return started

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
		_flush()
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
	var max_r := 0.0
	for i in POINTS:
		var y := 1.0 - 2.0 * (i + 0.5) / POINTS
		var rr := sqrt(maxf(0.0, 1.0 - y * y))
		var ph := i * 2.399963229728653
		var w := Vector3(cos(ph) * rr, y, sin(ph) * rr)
		var l := RockMesher.surface_radius(copy, frame, Vector3(w.dot(frame.x), w.dot(frame.y), w.dot(frame.z)))
		pts.append(w * l)
		mean_r += l / POINTS
		max_r = maxf(max_r, l)
	copy.pos = Vector3.ZERO
	var baked := RockMesher.bake([copy], world.rocks.catalog, Vector3.ZERO)
	var exposure := 1.0                                       # lit like the rock in the ground was (else it flashes pale while it falls)
	var home: Chunk = world.chunks.get(VoxelWorld.world_to_chunk(r.pos))
	if home != null and not home.dens.is_empty():
		exposure = ChunkMesher.sky_exposure(home.dens, home.base if not home.base.is_empty() else home.dens, r.pos - home.position + r.normal * (r.size * 0.8 + 0.8), r.normal)
	var bc: PackedColorArray = baked.colors
	for ci in bc.size():
		bc[ci].a = exposure
	baked.colors = bc
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
		"fx": frame.x, "fy": frame.y, "stuck_t": 0.0, "stuck_p": r.pos, "hit_t": 0.0, "n_hit": 0,
		"reach": maxf(max_r, 0.1), "cands": [], "cands_p": Vector3.INF, "cands_t": -9.0, "parity": 0})

## For the frame-by-frame debugging aid (main.gd --rockfall).
func debug_bodies() -> Array:
	return _bodies

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
	_flush()
	_last_us = Time.get_ticks_usec() - t0

## One step of a falling rock: a rigid body with the rock's real outline. Gravity pulls to the planet's centre; the outline points that are inside
## the ground give ONE contact (their mean) and the points inside another rock give a second one, each with a normal impulse (bounce), friction and
## the torque that tips and rolls the rock (_contact). Returns true when it has come to rest.
func _step(b: Dictionary, dt: float) -> bool:
	var p: Vector3 = b.p
	var v: Vector3 = b.v
	var w: Vector3 = b.w
	var rot: Basis = b.rot
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
	# the rocks around: a short list, refreshed when the rock has moved on or after a while (rocks do not move while they stand)
	if p.distance_to(b.cands_p) > 1.0 or b.age - b.cands_t > 0.4:
		b.cands = RockContact.nearby(world, p, b.reach + 0.5, b.rock) if rock_contacts else []
		b.cands_p = p
		b.cands_t = b.age
	var cands: Array = b.cands
	var gsum := Vector3.ZERO
	var gn := 0
	var gdeep := 0.0
	var rsum := Vector3.ZERO
	var rn := 0
	var rdeep := -9.0
	var rhit: Dictionary = {}
	var pts: Array = b.pts
	b.parity = 1 - int(b.parity)
	for qi in pts.size():
		var off := rot * (pts[qi] as Vector3)
		var wp := p + off
		var d := world.density_at(wp)
		if d > -SKIN:                                  # within the skin counts as touching: a resting rock keeps its contact every frame (no hopping)
			gsum += off
			gn += 1
			gdeep = maxf(gdeep, d)
		if cands.is_empty() or ((qi + b.parity) & 1) != 0:
			continue                                   # against rocks only half of the points per step, alternating: every point is tested every second step
		for c: Dictionary in cands:
			var orr: RockInst = c.r
			if wp.distance_squared_to(orr.pos) > orr.size * orr.size * 3.1:       # outside the other rock's bounding sphere (1.75 x size)
				continue
			var dr := RockContact.depth(c, wp)
			if dr > -SKIN:
				rsum += off
				rn += 1
				if dr > rdeep:
					rdeep = dr
					rhit = c
	b.n_hit = gn + rn
	var best_up := -1.0
	b.p = p
	b.v = v
	b.w = w
	if gn > 0:
		var rc := gsum / gn
		var cp := p + rc
		var e := 0.4
		var g := Vector3(world.density_at(cp + Vector3(e, 0, 0)) - world.density_at(cp - Vector3(e, 0, 0)),
			world.density_at(cp + Vector3(0, e, 0)) - world.density_at(cp - Vector3(0, e, 0)),
			world.density_at(cp + Vector3(0, 0, e)) - world.density_at(cp - Vector3(0, 0, e)))
		var n := (-g).normalized() if g.length() > 0.0001 else up
		_contact(b, rc, n, gdeep, dt)
		best_up = maxf(best_up, n.dot(up))
	if rn > 0:
		var rc2 := rsum / rn
		var n2 := RockContact.normal(rhit, b.p + rc2)             # the other rock's surface faces away from it
		_contact(b, rc2, n2, rdeep, dt)
		best_up = maxf(best_up, n2.dot(up))
	p = b.p
	v = b.v
	w = b.w
	var grounded := gn + rn > 0
	if grounded:
		if v.length() < REST_SPEED and w.length() < REST_SPIN and best_up > MIN_REST_UP:
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

## One contact of a falling rock (with the ground or with another rock): the rock is pushed out along the surface normal `n`, bounces
## (a heavy rock hardly does), rubs along the surface and is turned by the offset `rc` of the contact from its centre. Works on the body's p, v, w.
func _contact(b: Dictionary, rc: Vector3, n: Vector3, deep: float, dt: float) -> void:
	var p: Vector3 = b.p
	var v: Vector3 = b.v
	var w: Vector3 = b.w
	var inv_i: float = b.inv_i
	if deep > 0.0:
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
			_impact(b.rock, p + rc, n, -vn)
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
	if v.length() < SETTLE_SPEED:                  # a slow rock loses its spin fast: it catches on a face and stops (a real rock is no ball)
		w *= maxf(0.0, 1.0 - SETTLE_DAMP * dt)
	b.p = p
	b.v = v
	b.w = w

func _flush() -> void:
	for ch: Chunk in _dirty:
		world.rebake_rocks(ch)
	_dirty.clear()

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
	var home := world.place_rock(r, false)
	if home != null:
		_dirty[home] = true                                       # re-baked once per chunk at the end of the step, however many rocks landed in it
	if not r.bites.is_empty():
		world.refresh_cut(r)                                  # it lies in a new orientation: its cut shape is built again
	(b.node as Node3D).queue_free()
	_bodies.erase(b)
