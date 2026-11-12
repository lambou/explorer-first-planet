class_name RockMesher
extends RefCounted
## Bakes all the rocks of ONE chunk into one mesh (one draw call per chunk, one collision trimesh), using the same
## look as the terrain: flat-shaded triangles with vertex colours (alpha = how much sky the rock sees, so rocks in
## shade or in a cave are dimmed like the ground around them) and the terrain material.
## Each rock is a lumpy low-poly blob (an icosphere whose vertices are pushed in or out by a smooth direction noise,
## flattened towards the ground). Vertices are shared by index so the lumps never crack.
## BITES: every blow takes a round bite out of the rock, like digging the ground: a sphere (in the rock's own frame, in
## metres) is subtracted along every ray from the rock's centre. The rock keeps its size and is eaten away where it was
## hit, a bite deepens into a hole, and the same function answers "where is the surface?" for aiming.
## Colour per triangle: the outer layer, patches of the core (ore) showing through, and the freshly broken faces inside
## a bite (the core, or lighter rock).
## Pure maths on arrays: safe on a worker thread.

static var _v1 := PackedVector3Array()          # 80 triangles: pebbles and small rocks
static var _t1 := PackedInt32Array()
static var _v2 := PackedVector3Array()          # 320 triangles: rocks from 1 m up, and small bitten rocks
static var _t2 := PackedInt32Array()
static var _v3 := PackedVector3Array()          # 1280 triangles: big bitten rocks (a bite needs the resolution)
static var _t3 := PackedInt32Array()
static var _ico_ok := _build_ico()

const MIN_CORE := 0.22              # a bitten-through rock keeps a small core nub of this fraction of its size (no thin fins); the last blow removes it

## rocks: Array[RockInst] (world positions); origin: world position of the chunk's corner (the mesh is local to it).
## dens/base: the chunk's padded density (current / natural) for the sky exposure; may be empty (then exposure 1).
static func bake(rocks: Array, catalog: RockCatalog, origin: Vector3, dens: PackedFloat32Array = PackedFloat32Array(), base: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	for r: RockInst in rocks:
		var exposure := 1.0
		if not dens.is_empty():
			var lp := r.pos - origin
			exposure = ChunkMesher.sky_exposure(dens, base if not base.is_empty() else dens, lp + r.normal * (r.size * 0.8 + 0.8), r.normal)
		_add_rock(verts, normals, colors, r, catalog, origin, exposure)
	return {"verts": verts, "normals": normals, "colors": colors, "faces": verts}

## The rock's frame: axes along the ground's normal and its yaw, and the radii of its flattened blob.
static func frame_of(r: RockInst) -> Dictionary:
	var y := r.normal
	var ref := Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.FORWARD
	var x := y.cross(ref).normalized().rotated(y, r.yaw)
	var z := x.cross(y)
	var h := r.shape
	return {"x": x, "y": y, "z": z,
		"sx": r.size * (0.8 + 0.4 * _u(h, 1)), "sy": r.size * (0.55 + 0.30 * _u(h, 2)), "sz": r.size * (0.8 + 0.4 * _u(h, 3))}

## A world point -> the rock's own frame, in metres from its centre (where a bite is stored).
static func to_local(r: RockInst, f: Dictionary, world_point: Vector3) -> Vector3:
	var v := world_point - r.pos
	return Vector3(v.dot(f.x), v.dot(f.y), v.dot(f.z))

static func to_world(r: RockInst, f: Dictionary, q: Vector3) -> Vector3:
	return r.pos + f.x * q.x + f.y * q.y + f.z * q.z

## Distance from the rock's centre to its surface along the unit direction `w` (rock frame, metric): the lumpy
## blob, then every bite subtracted. Same maths as the mesh vertices, so aiming sees exactly what is drawn.
static func surface_radius(r: RockInst, f: Dictionary, w: Vector3) -> float:
	return _bitten(r, blob_radius(r, f, w), w)

## The same without the bites: the whole rock as it was.
static func blob_radius(r: RockInst, f: Dictionary, w: Vector3) -> float:
	var u := Vector3(w.x / f.sx, w.y / f.sy, w.z / f.sz).normalized()
	var amp := r.lump_amplitude()
	var k := 1.0 if amp <= 0.0 else 1.0 + amp * _lump(u, r.shape)
	return Vector3(u.x * f.sx, u.y * f.sy, u.z * f.sz).length() * k

## What fraction of the rock is left (1 = whole, 0 = nothing): the volume under the surface over the volume of
## the unbitten blob, estimated along 40 directions.
static func volume_fraction(r: RockInst) -> float:
	if r.bites.is_empty():
		return 1.0
	var f := frame_of(r)
	var left := 0.0
	var whole := 0.0
	var n := 40
	for i in n:
		var y := 1.0 - 2.0 * (i + 0.5) / n
		var rr := sqrt(maxf(0.0, 1.0 - y * y))
		var phi := i * 2.399963229728653
		var w := Vector3(cos(phi) * rr, y, sin(phi) * rr)
		var l0 := blob_radius(r, f, w)
		var l := _bitten(r, l0, w)
		left += l * l * l
		whole += l0 * l0 * l0
	return left / maxf(whole, 0.0001)

static func _bitten(r: RockInst, l0: float, w: Vector3) -> float:
	var l := l0
	var min_l := MIN_CORE * r.size
	for b: Vector4 in r.bites:
		var c := Vector3(b.x, b.y, b.z)
		var bb := w.dot(c)
		var disc := bb * bb - (c.length_squared() - b.w * b.w)
		if disc <= 0.0:
			continue
		var sq := sqrt(disc)
		var te := bb - sq
		var tx := bb + sq
		if te <= l and tx >= l:                     # the surface here lies inside the bite
			l = maxf(te, min_l)
	return l

## Where a ray meets the rock's CURRENT surface (bites included): {hit, t, point, normal}. Marches inside the
## rock's bounding sphere, then bisects.
static func surface_hit(r: RockInst, origin: Vector3, dir: Vector3, max_t: float) -> Dictionary:
	var f := frame_of(r)
	var bound := r.size * 1.75
	var oc := origin - r.pos
	var b := oc.dot(dir)
	var disc := b * b - (oc.dot(oc) - bound * bound)
	if disc < 0.0:
		return {"hit": false}
	var sq := sqrt(disc)
	var t0 := maxf(-b - sq, 0.0)
	var t1 := minf(-b + sq, max_t)
	var step := maxf(0.05, r.size * 0.07)
	var t := t0
	var prev := t0
	while t <= t1:
		if _inside(r, f, origin + dir * t):
			var lo := prev
			var hi := t
			for i in 7:
				var mid := (lo + hi) * 0.5
				if _inside(r, f, origin + dir * mid):
					hi = mid
				else:
					lo = mid
			var p := origin + dir * hi
			return {"hit": true, "t": hi, "point": p, "normal": _normal_at(r, f, p)}
		prev = t
		t += step
	return {"hit": false}

static func _inside(r: RockInst, f: Dictionary, world_point: Vector3) -> bool:
	var q := to_local(r, f, world_point)
	var l := q.length()
	if l < 0.0001:
		return true
	return l < surface_radius(r, f, q / l)

static func _signed(r: RockInst, f: Dictionary, q: Vector3) -> float:
	var l := q.length()
	if l < 0.0001:
		return -1.0
	return l - surface_radius(r, f, q / l)

static func _normal_at(r: RockInst, f: Dictionary, world_point: Vector3) -> Vector3:
	var q := to_local(r, f, world_point)
	var e := maxf(0.03, r.size * 0.04)
	var g := Vector3(
		_signed(r, f, q + Vector3(e, 0, 0)) - _signed(r, f, q - Vector3(e, 0, 0)),
		_signed(r, f, q + Vector3(0, e, 0)) - _signed(r, f, q - Vector3(0, e, 0)),
		_signed(r, f, q + Vector3(0, 0, e)) - _signed(r, f, q - Vector3(0, 0, e)))
	if g.length() < 1e-6:
		return (world_point - r.pos).normalized()
	g = g.normalized()
	return (f.x * g.x + f.y * g.y + f.z * g.z).normalized()

static func _add_rock(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, r: RockInst, catalog: RockCatalog, origin: Vector3, exposure: float) -> void:
	var f := frame_of(r)
	var pos := r.pos
	var x: Vector3 = f.x
	var y: Vector3 = f.y
	var z: Vector3 = f.z
	var sx: float = f.sx
	var sy: float = f.sy
	var sz: float = f.sz
	var h := r.shape
	var lump := r.lump_amplitude()
	var uv: PackedVector3Array
	var ut: PackedInt32Array
	if not r.bites.is_empty() and r.size >= 0.6:
		uv = _v3
		ut = _t3
	elif r.size >= 1.0 or not r.bites.is_empty():
		uv = _v2
		ut = _t2
	else:
		uv = _v1
		ut = _t1
	# vertices (shared by index: no cracks); each is on its ray from the centre, cut by the bites
	var nv := uv.size()
	var tv := PackedVector3Array()
	tv.resize(nv)
	for i in nv:
		var u := uv[i]
		var k := 1.0 if lump <= 0.0 else 1.0 + lump * _lump(u, h)
		var q0 := Vector3(u.x * sx, u.y * sy, u.z * sz) * k
		var l0 := q0.length()
		var q := q0
		if not r.bites.is_empty() and l0 > 0.0001:
			var w := q0 / l0
			q = w * _bitten(r, l0, w)
		tv[i] = x * q.x + y * q.y + z * q.z + (pos - origin)
	# colours: the outer layer, with patches of the core showing through
	var outer := catalog.by_id(r.layers[0][0])
	var c_outer := outer.varied_color(_u(h, 5))
	var has_core := r.layers.size() > 1
	var core: RockType = catalog.by_id(r.layers[r.layers.size() - 1][0]) if has_core else null
	var core_frac: float = r.layers[r.layers.size() - 1][1] if has_core else 0.0
	var c_core := core.varied_color(_u(h, 6)) if has_core else c_outer
	if has_core and core.traits.has("glow"):
		c_core = c_core.lightened(0.25 * float(core.traits.glow))
	var cover := 0.22 + 0.5 * (core_frac - 0.3) / 0.4          # richer = more ore showing
	var tri_count := ut.size() / 3
	for t in tri_count:
		var a := tv[ut[t * 3]]
		var b := tv[ut[t * 3 + 1]]
		var c := tv[ut[t * 3 + 2]]
		var n := (b - a).cross(c - a)
		if n.length_squared() < 1e-12:
			continue
		n = n.normalized()
		var centre := (a + b + c) / 3.0 - (pos - origin)
		# keep the winding outward (away from the rock's centre)
		if n.dot(centre) < 0.0:
			var tmp := b
			b = c
			c = tmp
			n = -n
		# patches, not speckles: the ore shows where a coarse 3D cell of the rock's own surface says so
		var dir := centre / maxf(r.size, 0.05)
		var cell := Vector3i(floori(dir.x * 1.6 + 7.0), floori(dir.y * 1.6 + 7.0), floori(dir.z * 1.6 + 7.0))
		var col := c_outer
		if has_core and _u(h, 300 + cell.x + cell.y * 31 + cell.z * 977) < cover:
			col = c_core
		else:
			col = c_outer.lerp(c_outer.darkened(0.18), _u(h, 700 + t))       # a little grain between faces
		# inside a bite the rock is freshly broken: the core shows, or lighter rock where there is none
		if not r.bites.is_empty():
			var cl := Vector3(centre.dot(x), centre.dot(y), centre.dot(z))
			for bt: Vector4 in r.bites:
				if cl.distance_to(Vector3(bt.x, bt.y, bt.z)) < bt.w * 1.15:
					col = c_core if has_core else c_outer.lightened(0.38)
					break
		col.a = exposure
		# Godot's front face is CLOCKWISE seen from outside: emit (a, c, b) with the outward normal
		verts.append(a)
		verts.append(c)
		verts.append(b)
		normals.append(n)
		normals.append(n)
		normals.append(n)
		colors.append(col)
		colors.append(col)
		colors.append(col)

## Smooth lumpiness (-1..1) as a function of the direction only (two octaves of value noise), so the outline
## is the same whatever the mesh detail and never spiky.
static func _lump(u: Vector3, h: int) -> float:
	return _vnoise(u * 1.5, h) * 0.75 + _vnoise(u * 3.4 + Vector3(5.1, 2.3, 7.7), h + 17) * 0.25

static func _vnoise(p: Vector3, h: int) -> float:
	var ix := floori(p.x)
	var iy := floori(p.y)
	var iz := floori(p.z)
	var f := Vector3(p.x - ix, p.y - iy, p.z - iz)
	f = f * f * (Vector3.ONE * 3.0 - f * 2.0)
	var c := PackedFloat32Array()
	c.resize(8)
	for k in 8:
		c[k] = _u(h, 5000 + (ix + (k & 1)) * 73 + (iy + ((k >> 1) & 1)) * 179 + (iz + ((k >> 2) & 1)) * 283) * 2.0 - 1.0
	var x00 := lerpf(c[0], c[1], f.x)
	var x10 := lerpf(c[2], c[3], f.x)
	var x01 := lerpf(c[4], c[5], f.x)
	var x11 := lerpf(c[6], c[7], f.x)
	return lerpf(lerpf(x00, x10, f.y), lerpf(x01, x11, f.y), f.z)

static func _u(h: int, n: int) -> float:
	var v := SeedMix.splitmix64(h + n * 0x9E3779B1)
	return float((v >> 11) & ((1 << 53) - 1)) / 9007199254740992.0

## Icospheres: level 1 = 80 triangles, level 2 = 320, level 3 = 1280.
static func _build_ico() -> bool:
	var t := (1.0 + sqrt(5.0)) * 0.5
	var v: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for i in v.size():
		v[i] = v[i].normalized()
	var tris: Array = [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for level in 3:
		var cache := {}
		var next: Array = []
		for tri in tris:
			var m: Array[int] = []
			for e in 3:
				var a: int = tri[e]
				var b: int = tri[(e + 1) % 3]
				var key := mini(a, b) * 10000 + maxi(a, b)
				if not cache.has(key):
					cache[key] = v.size()
					v.append(((v[a] + v[b]) * 0.5).normalized())
				m.append(cache[key])
			next.append([tri[0], m[0], m[2]])
			next.append([tri[1], m[1], m[0]])
			next.append([tri[2], m[2], m[1]])
			next.append([m[0], m[1], m[2]])
		tris = next
		var flat := PackedInt32Array()
		for tri in tris:
			flat.append_array(PackedInt32Array([tri[0], tri[1], tri[2]]))
		match level:
			0:
				_v1 = PackedVector3Array(v)
				_t1 = flat
			1:
				_v2 = PackedVector3Array(v)
				_t2 = flat
			_:
				_v3 = PackedVector3Array(v)
				_t3 = flat
	return true
