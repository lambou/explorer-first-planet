class_name TreeMeshes
extends RefCounted
## Bakes all the trees of ONE chunk into one mesh (one draw call; the trunks also give one collision shape), flat-shaded low poly like
## the rocks. Every family draws its own canopy:
##   broadleaf: a trunk and 4-6 clusters of leaves   round: one dense crown   birch: pale slim trunk, small light clusters
##   pine: stacked cones   fir: many thin ragged drooping tiers   palm: a curved trunk and drooping fronds   acacia: a flat umbrella crown
## A standing tree with blows has a NOTCH cut into its trunk (fresh pale wood), a fallen tree is just its trunk lying along its axis, shorter
## with every log chopped off its tip.
## Vertex data: COLOR = albedo with alpha = how much the wind moves the vertex (0 at the foot, 1 at the top), UV.x = a random per tree
## (so trees do not all sway together). Pure maths on arrays: safe on a worker thread.

const SIDES := 7

static var _ico0_v := PackedVector3Array()          # a plain icosahedron: 12 vertices, 20 triangles (the side clusters of a crown)
static var _ico0_t := PackedInt32Array()
static var _ico0_ok := _build_ico0()

static func _build_ico0() -> bool:
	var t := (1.0 + sqrt(5.0)) * 0.5
	var v: Array[Vector3] = [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
		Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for i in v.size():
		v[i] = v[i].normalized()
	_ico0_v = PackedVector3Array(v)
	_ico0_t = PackedInt32Array([0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1])
	return true

## lod 0 = the full tree, lod 1 = the far version (about a third of the triangles: one crown cluster, fewer tiers and fronds, a plain trunk).
static func bake(trees: Array, catalog: TreeCatalog, origin: Vector3, lod: int = 0) -> Dictionary:
	var m := {"verts": PackedVector3Array(), "normals": PackedVector3Array(), "colors": PackedColorArray(), "uvs": PackedVector2Array(),
		"faces": PackedVector3Array(), "lod": lod}
	for t: TreeInst in trees:
		if t.state == TreeInst.FALLING:
			continue
		# a standing tree sinks 30 cm into the ground: its flared foot never hangs in the air on a slope
		var sink := t.up * 0.3 if t.state == TreeInst.STANDING else Vector3.ZERO
		_add_tree(m, t, catalog.by_id(t.type_id), t.pos - origin - sink)
	return m

## One tree baked alone, at the origin (for the falling animation).
static func bake_one(t: TreeInst, catalog: TreeCatalog) -> Dictionary:
	var m := {"verts": PackedVector3Array(), "normals": PackedVector3Array(), "colors": PackedColorArray(), "uvs": PackedVector2Array(),
		"faces": PackedVector3Array()}
	_add_tree(m, t, catalog.by_id(t.type_id), Vector3.ZERO)
	return m

static func _add_tree(m: Dictionary, t: TreeInst, ty: TreeType, base: Vector3) -> void:
	var h := t.shape
	var up := t.up
	var ax := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized().rotated(up, t.yaw)
	var az := ax.cross(up)
	var rnd := _u(h, 99)
	if t.state == TreeInst.FALLEN:
		_trunk(m, t, ty, base, t.axis, t.remaining, t.trunk_r, 0.55, rnd, false)
		return
	var H := t.height
	var fam := ty.family
	var top_t := 0.72                                   # how far up the trunk goes (share of the height): into the heart of the crown
	match fam:
		TreeType.PINE, TreeType.FIR: top_t = 0.97
		TreeType.PALM: top_t = 1.0
		TreeType.ACACIA: top_t = 0.68
		TreeType.BIRCH: top_t = 0.74
		TreeType.ROUND: top_t = 0.64
	var lean := Vector3.ZERO
	if fam == TreeType.PALM:
		lean = (ax * cos(h % 628 / 100.0) + az * sin(h % 628 / 100.0)) * (H * 0.13)
	_trunk_standing(m, t, ty, base, up, ax, az, H * top_t, lean, rnd)
	var crown := base + lean + up * (H * top_t)
	match fam:
		TreeType.BROADLEAF: _blobs(m, t, ty, base, up, ax, az, 5, 0.58, 0.86, 0.66, 0.9, 0.85, rnd)
		TreeType.ROUND: _blobs(m, t, ty, base, up, ax, az, 3, 0.52, 0.84, 0.85, 1.0, 0.95, rnd)
		TreeType.BIRCH: _blobs(m, t, ty, base, up, ax, az, 4, 0.58, 0.82, 0.8, 1.0, 0.95, rnd)
		TreeType.ACACIA: _blobs(m, t, ty, base, up, ax, az, 2, 0.66, 0.80, 0.95, 1.0, 0.42, rnd)
		TreeType.PINE: _tiers(m, t, ty, base, up, ax, az, 5, 8, 0.0, 0.2, rnd)
		TreeType.FIR: _tiers(m, t, ty, base, up, ax, az, 9, 10, 0.22, 0.16, rnd)
		TreeType.PALM: _fronds(m, t, ty, crown, up, ax, az, rnd)

# ---------------------------------------------------------------- the trunk

## A standing trunk: a tapered prism of rings, optionally leaning (palm), with the NOTCH of the blows cut into one side.
static func _trunk_standing(m: Dictionary, t: TreeInst, ty: TreeType, base: Vector3, up: Vector3, ax: Vector3, az: Vector3,
		top: float, lean: Vector3, rnd: float) -> void:
	var heights: Array[float] = []
	var far: bool = m.get("lod", 0) > 0
	var n := 2 if far else 5
	for i in n + 1:
		heights.append(top * i / n)
	var notch := t.hits > 0.0 and not far
	var depth := 0.0
	if notch:
		depth = clampf(0.15 + 0.7 * t.hits / maxf(_need(ty, t), 1.0), 0.0, 0.88)
		var hh := clampf(t.hit_h, 0.4, top - 0.5)
		heights.append(hh - 0.3)
		heights.append(hh)
		heights.append(hh + 0.3)
		heights.sort()
	var hit_angle := atan2(t.hit_dir.dot(az), t.hit_dir.dot(ax))
	var bark := ty.bark
	var rings: Array = []                                # [point, radius multipliers per side, colour]
	for hk in heights:
		var f := clampf(hk / maxf(top, 0.01), 0.0, 1.0)
		var r0 := t.trunk_r * lerpf(1.0, 0.45, f)
		if ty.family == TreeType.PALM:
			r0 = t.trunk_r * lerpf(1.0, 0.7, f)
		var flare := 1.0 + 0.5 * maxf(0.0, 1.0 - hk / 0.9)             # the foot is wider
		var centre := base + up * hk + lean * (f * f)
		var radii := PackedFloat32Array()
		var cols := PackedColorArray()
		for i in SIDES:
			var a := TAU * i / SIDES
			var cut := 0.0
			if notch:
				var bump := maxf(0.0, 1.0 - absf(hk - clampf(t.hit_h, 0.4, top - 0.5)) / 0.32)
				var face := pow(maxf(0.0, cos(a - hit_angle)), 2.0)
				cut = depth * bump * face
			radii.append(r0 * flare * (1.0 - cut))
			var c := bark.lerp(bark.darkened(0.25), f * 0.4)
			if ty.family == TreeType.BIRCH:
				c = ty.bark if (int(hk * 3.0) % 2 == 0) else ty.bark.darkened(0.55)
			if cut > 0.12:
				c = Color(0.86, 0.72, 0.5)                              # fresh wood in the notch
			cols.append(c)
		rings.append([centre, radii, cols, f])
	for k in rings.size() - 1:
		var r_a: Array = rings[k]
		var r_b: Array = rings[k + 1]
		for i in SIDES:
			var j := (i + 1) % SIDES
			var a0 := TAU * i / SIDES
			var a1 := TAU * j / SIDES
			var p00: Vector3 = r_a[0] + (ax * cos(a0) + az * sin(a0)) * r_a[1][i]
			var p01: Vector3 = r_a[0] + (ax * cos(a1) + az * sin(a1)) * r_a[1][j]
			var p10: Vector3 = r_b[0] + (ax * cos(a0) + az * sin(a0)) * r_b[1][i]
			var p11: Vector3 = r_b[0] + (ax * cos(a1) + az * sin(a1)) * r_b[1][j]
			var col: Color = r_a[2][i]
			var inside: Vector3 = (r_a[0] + r_b[0]) * 0.5
			var wa: float = float(r_a[3]) * float(r_a[3]) * 0.2
			var wb: float = float(r_b[3]) * float(r_b[3]) * 0.2
			_tri(m, p00, p01, p10, inside, col, [wa, wa, wb], rnd, true)
			_tri(m, p01, p11, p10, inside, col, [wa, wb, wb], rnd, true)
	# close both ends: a felled tree is seen from below, and a hollow tube looks empty
	for end in 2:
		var ring_e: Array = rings[0] if end == 0 else rings[rings.size() - 1]
		var centre_e: Vector3 = ring_e[0]
		var away: Vector3 = (centre_e - up * 1.0) if end == 0 else (centre_e + up * 1.0)
		var col_e: Color = ty.bark.darkened(0.2) if end == 0 else ty.bark
		for i in SIDES:
			var j := (i + 1) % SIDES
			var a0 := TAU * i / SIDES
			var a1 := TAU * j / SIDES
			var q0: Vector3 = centre_e + (ax * cos(a0) + az * sin(a0)) * ring_e[1][i]
			var q1: Vector3 = centre_e + (ax * cos(a1) + az * sin(a1)) * ring_e[1][j]
			_tri(m, centre_e, q0, q1, centre_e - (away - centre_e), col_e, [0.0, 0.0, 0.0], rnd, true)

## A lying trunk of `length` along `axis` from the foot, with both ends closed (the cut end shows fresh wood).
static func _trunk(m: Dictionary, t: TreeInst, ty: TreeType, base: Vector3, axis: Vector3, length: float, r: float, taper: float,
		rnd: float, _unused: bool) -> void:
	var up := axis.cross(Vector3.UP if absf(axis.y) < 0.95 else Vector3.RIGHT).normalized()
	var side := axis.cross(up)
	var lift := r * 0.9                                    # lies on its side on the ground
	var n := maxi(2, int(length / 2.0))
	var prev_ring: Array = []
	for k in n + 1:
		var f := float(k) / n
		var along := length * f
		var tf := along / maxf(t.length, 0.1)             # taper follows the whole original trunk
		var rr := r * lerpf(1.0, 0.45, clampf(tf, 0.0, 1.0)) * (1.0 + 0.4 * maxf(0.0, 1.0 - along / 0.9))
		var centre := base + axis * along + t.up * lift
		var ring: Array = []
		for i in SIDES:
			var a := TAU * i / SIDES
			ring.append(centre + (up * cos(a) + side * sin(a)) * rr)
		if k > 0:
			for i in SIDES:
				var j := (i + 1) % SIDES
				var inside: Vector3 = (centre + prev_ring[SIDES]) * 0.5
				var c := ty.bark.lerp(ty.bark.darkened(0.2), f * 0.4)
				_tri(m, prev_ring[i], prev_ring[j], ring[i], inside, c, [0.0, 0.0, 0.0], rnd, true)
				_tri(m, prev_ring[j], ring[j], ring[i], inside, c, [0.0, 0.0, 0.0], rnd, true)
		if k == 0:
			for i in SIDES:
				var j0 := (i + 1) % SIDES
				_tri(m, centre, ring[i], ring[j0], centre + axis, ty.bark.darkened(0.2), [0.0, 0.0, 0.0], rnd, true)
		if k == n:
			# the cut end: pale wood
			for i in SIDES:
				var j := (i + 1) % SIDES
				_tri(m, centre, ring[i], ring[j], centre - axis, Color(0.86, 0.72, 0.5), [0.0, 0.0, 0.0], rnd, true)
		prev_ring = ring
		prev_ring.append(centre)

# ---------------------------------------------------------------- crowns

static func _need(ty: TreeType, t: TreeInst) -> float:
	return maxf(3.0, ty.hardness * pow(t.trunk_r * 2.0, 2.0) * 9.0)

static func _lump(u: Vector3, h: int) -> float:
	return RockMesher._lump(u, h)

## Clusters of leaves: low-poly blobs (an icosphere each) with a bumpy outline, darker below and lighter on top.
static func _blobs(m: Dictionary, t: TreeInst, ty: TreeType, base: Vector3, up: Vector3, ax: Vector3, az: Vector3, count: int,
		y0: float, y1: float, size0: float, size1: float, flat: float, rnd: float) -> void:
	var H := t.height
	var far: bool = m.get("lod", 0) > 0
	if far:
		count = 1                                        # far away: one cluster is enough (and a bit bigger to keep the silhouette)
		size1 *= 1.25
	for b in count:
		# the main cluster of the crown is the finer shape (80 triangles); the side clusters are plain icosahedra (20)
		var uv: PackedVector3Array = RockMesher._v1 if (b == 0 and not far) else _ico0_v
		var ut: PackedInt32Array = RockMesher._t1 if (b == 0 and not far) else _ico0_t
		var hb := SeedMix.splitmix64(t.shape + b * 7717)
		var a := _u(hb, 1) * TAU
		var spread := t.canopy_r * (0.0 if count == 1 else (0.35 + 0.45 * _u(hb, 2)))
		if b == 0:
			spread = 0.0
		var hy := lerpf(y0, y1, float(b) / maxf(count - 1, 1.0) if b > 0 else 1.0)
		var centre := base + up * (H * hy) + (ax * cos(a) + az * sin(a)) * spread
		var radius := t.canopy_r * lerpf(size0, size1, _u(hb, 3)) * (1.0 if b == 0 else 0.8)
		var tint := ty.leaf_a.lerp(ty.leaf_b, 0.15 + 0.2 * _u(hb, 4))
		var nv := uv.size()
		var pts := PackedVector3Array()
		pts.resize(nv)
		for i in nv:
			var u := uv[i]
			var k := 1.0 + 0.16 * _lump(u, hb)
			pts[i] = centre + (ax * u.x + az * u.z) * radius * k + up * (u.y * radius * flat * k)
		for tri in ut.size() / 3:
			var a0 := pts[ut[tri * 3]]
			var b0 := pts[ut[tri * 3 + 1]]
			var c0 := pts[ut[tri * 3 + 2]]
			var ny := (((a0 + b0 + c0) / 3.0) - centre).dot(up) / maxf(radius * flat, 0.01)
			var col := ty.leaf_a.lerp(ty.leaf_b, clampf(0.5 + 0.55 * ny, 0.0, 1.0)).lerp(tint, 0.3)
			col = col.lerp(col.darkened(0.12), _u(hb, 100 + tri) * 0.5)
			var w := clampf(pow((((a0 + b0 + c0) / 3.0 - base).dot(up)) / H, 1.4), 0.0, 1.0)
			_tri(m, a0, b0, c0, centre, col, [w, w, w], rnd, false)

## Stacked cones (pine) or thin ragged drooping tiers (fir).
static func _tiers(m: Dictionary, t: TreeInst, ty: TreeType, base: Vector3, up: Vector3, ax: Vector3, az: Vector3, count: int, sides: int,
		ragged: float, start: float, rnd: float) -> void:
	var H := t.height
	var far: bool = m.get("lod", 0) > 0
	if far:
		count = maxi(3, count / 2)
		sides = 6
	var y_start := H * (start if start > 0.0 else 0.2)
	var span := H - y_start
	for i in count:
		var f := float(i) / count
		var y := y_start + span * f
		var th := span / count * (1.55 if ragged == 0.0 else 1.25)
		var r := t.canopy_r * (1.0 - 0.85 * f) * (1.0 if ragged == 0.0 else 1.1)
		var apex := base + up * (y + th)
		var edge: Array[Vector3] = []
		for k in sides:
			var a := TAU * k / sides + f * 0.8
			var jag := 1.0 - (ragged * 0.55 if k % 2 == 0 else 0.0)
			var droop := th * 0.12 * (1.0 if ragged > 0.0 else 0.0) * (1.0 if k % 2 == 0 else 0.0)
			edge.append(base + up * (y - droop) + (ax * cos(a) + az * sin(a)) * r * jag)
		var col_lo := ty.leaf_a.lerp(ty.leaf_b, f * 0.55)
		var col_hi := ty.leaf_a.lerp(ty.leaf_b, 0.4 + f * 0.6)
		for k in sides:
			var k2 := (k + 1) % sides
			var col := col_lo.lerp(col_hi, 0.55).lerp(col_lo, _u(t.shape, k + i * 13) * 0.5)
			var wy := clampf(pow((y + th * 0.5) / H, 1.4), 0.0, 1.0)
			_tri(m, edge[k], edge[k2], apex, base + up * (y + th * 0.3), col, [wy * 0.8, wy * 0.8, clampf(pow((y + th) / H, 1.4), 0.0, 1.0)], rnd, false)
			# the underside (dark), so the lowest tiers read from below too (the upper ones are never seen from below)
			if i < 3 and not far:
				_tri(m, edge[k], edge[k2], base + up * (y - th * 0.1), base + up * (y + th * 0.3), col_lo.darkened(0.3), [wy * 0.8, wy * 0.8, wy * 0.6], rnd, false)

## A palm's crown: drooping ribbon fronds around the top of the trunk.
static func _fronds(m: Dictionary, t: TreeInst, ty: TreeType, crown: Vector3, up: Vector3, ax: Vector3, az: Vector3, rnd: float) -> void:
	var far: bool = m.get("lod", 0) > 0
	var n := 5 if far else 8
	var L := t.canopy_r * 1.6
	for i in n:
		var hb := SeedMix.splitmix64(t.shape + i * 3571)
		var a := TAU * i / n + _u(hb, 1) * 0.4
		var dir := ax * cos(a) + az * sin(a)
		var len := L * (0.85 + 0.3 * _u(hb, 2))
		var w := L * 0.13
		var side := up.cross(dir).normalized()
		var segs := 3 if far else 5
		var prev_l := crown
		var prev_r := crown
		for k in range(1, segs + 1):
			var f := float(k) / segs
			var p := crown + dir * (len * f) + up * (len * (0.42 * sin(f * 2.2) - 0.30 * f * f))
			var wk := w * sin(minf(f * 2.6, PI * 0.5)) * (1.0 - 0.55 * f)
			var pl := p - side * wk
			var pr := p + side * wk
			var col := ty.leaf_a.lerp(ty.leaf_b, 0.3 + 0.6 * f).lerp(ty.leaf_a, _u(hb, 3) * 0.3)
			var ref := p - up * 1.0
			_tri(m, prev_l, prev_r, pl, ref, col, [0.9, 0.9, 1.0], rnd, false)
			_tri(m, prev_r, pr, pl, ref, col, [0.9, 1.0, 1.0], rnd, false)
			prev_l = pl
			prev_r = pr

# ---------------------------------------------------------------- one triangle

## A flat-shaded triangle with its normal pointing away from `inside` (a point inside the shape), clockwise from outside like the
## rocks. `w`: the wind weight of its three vertices. `trunk`: also goes into the collision shape.
static func _tri(m: Dictionary, a: Vector3, b: Vector3, c: Vector3, inside: Vector3, col: Color, w: Array, rnd: float, trunk: bool) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-10:
		return
	n = n.normalized()
	var centre := (a + b + c) / 3.0 - inside
	var ww: Array = w
	if n.dot(centre) < 0.0:
		var tmp := b
		b = c
		c = tmp
		n = -n
		ww = [w[0], w[2], w[1]]
	var verts: PackedVector3Array = m.verts
	var normals: PackedVector3Array = m.normals
	var colors: PackedColorArray = m.colors
	var uvs: PackedVector2Array = m.uvs
	verts.append(a)
	verts.append(c)
	verts.append(b)
	var ws := [ww[0], ww[2], ww[1]]
	for k in 3:
		normals.append(n)
		colors.append(Color(col.r, col.g, col.b, ws[k]))
		uvs.append(Vector2(rnd, 0.0))
	m.verts = verts
	m.normals = normals
	m.colors = colors
	m.uvs = uvs
	if trunk:
		var f: PackedVector3Array = m.faces
		f.append(a)
		f.append(c)
		f.append(b)
		m.faces = f

static func _u(h: int, n: int) -> float:
	var v := SeedMix.splitmix64(h + n * 0x632BE59B)
	return float((v >> 11) & ((1 << 53) - 1)) / 9007199254740992.0
