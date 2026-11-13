class_name RockCut
extends RefCounted
## The mesh of a rock that has been bitten. Sliding the vertices of a whole sphere into a hollow stretches or bunches its triangles
## (thin fans and slivers), so a rock with bites is RE-MESHED from a density field, the same method the terrain uses:
##   field = the rock's lumpy blob minus the bite spheres, sampled on a small grid scaled to the rock (a bite is about 2.5 cells wide,
##   like the ground's 2.4 m dig on 1 m cells), turned into triangles by Surface Nets: evenly sized, the crater has triangles of its own.
## Flat-shaded and painted like the rest of the rock (outer layer, ore patches, fresh fracture inside the bites).
## Heavy (tens of ms for a big rock), so it is built on a worker thread; the old shape stays until the new one is ready.
## The result is local to the rock: positions relative to RockInst.pos, in world axes.

const TABLE_T := 24                  # latitude steps of the blob table
const TABLE_P := 48                  # longitude steps
const MAX_N := 34                    # cells per axis at most
const SMOOTH := 1.1                  # rounding of the bite rims, in cells
const SHARD := 0.3                   # a loose piece smaller than this share of the biggest piece is dropped (no tiny floating pieces)
const SHARD_MIN := 40                # ... and any loose piece of fewer triangles than this

## {"verts", "normals", "colors"}: triangles clockwise from outside (Godot's front face), colours without the sky exposure (alpha 1).
static func build(r: RockInst, catalog: RockCatalog) -> Dictionary:
	var f := RockMesher.frame_of(r)
	var minw := r.size
	for b: Vector4 in r.bites:
		minw = minf(minw, b.w)
	var reach := r.size * 1.5
	var cell := clampf(minw / 2.5, r.size * 0.06, r.size * 0.3)
	var n := clampi(int(ceil(2.0 * reach / cell)), 10, MAX_N)
	cell = 2.0 * reach / n
	var table := _blob_table(r, f)
	var P := n + 3                                          # samples per axis: n + 1 and a border of air on each side
	var dens := PackedFloat32Array()
	dens.resize(P * P * P)
	var lim := r.size * 1.45
	var low := r.size * 0.3
	var bites := r.bites
	for k in P:
		var z := (k - 1) * cell - reach
		for j in P:
			var y := (j - 1) * cell - reach
			for i in P:
				var x := (i - 1) * cell - reach
				var l := sqrt(x * x + y * y + z * z)
				var d: float
				if i == 0 or j == 0 or k == 0 or i == P - 1 or j == P - 1 or k == P - 1 or l > lim:
					d = -3.0
				elif l < low:
					d = 3.0
				else:
					d = clampf((_lookup(table, Vector3(x, y, z) / l) - l) / cell, -3.0, 3.0)
				if d > -3.0 and not bites.is_empty():
					for b: Vector4 in bites:
						var dx := x - b.x
						var dy := y - b.y
						var dz := z - b.z
						var db := (sqrt(dx * dx + dy * dy + dz * dz) - b.w) / cell
						# a smooth minimum: the rim of a bite is rounded (a sharp rim leaves thin teeth the grid cannot hold)
						var hh := maxf(SMOOTH - absf(d - db), 0.0) / SMOOTH
						d = minf(d, db) - hh * hh * SMOOTH * 0.25
				dens[i + P * (j + P * k)] = d
	var m := _nets(dens, P, cell, reach)
	return _paint(m, r, f, catalog)

# ---------------------------------------------------------------- the blob table

## The blob's radius over the directions of the sphere (latitude x longitude, in the rock's own frame): the noise is evaluated once per
## table entry, not once per grid sample.
static func _blob_table(r: RockInst, f: Dictionary) -> PackedFloat32Array:
	var t := PackedFloat32Array()
	t.resize((TABLE_T + 1) * TABLE_P)
	for a in TABLE_T + 1:
		var th := PI * a / TABLE_T
		for b in TABLE_P:
			var ph := TAU * b / TABLE_P
			var w := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			t[a * TABLE_P + b] = RockMesher.blob_radius(r, f, w)
	return t

static func _lookup(t: PackedFloat32Array, w: Vector3) -> float:
	var th := acos(clampf(w.y, -1.0, 1.0)) / PI * TABLE_T
	var ph := fposmod(atan2(w.z, w.x), TAU) / TAU * TABLE_P
	var a := mini(int(th), TABLE_T - 1)
	var b := int(ph)
	var fa := th - a
	var fb := ph - b
	var b1 := (b + 1) % TABLE_P
	return lerpf(lerpf(t[a * TABLE_P + b], t[a * TABLE_P + b1], fb), lerpf(t[(a + 1) * TABLE_P + b], t[(a + 1) * TABLE_P + b1], fb), fa)

# ---------------------------------------------------------------- Surface Nets (any grid size)

## One vertex per mixed cell (the mean of its edge crossings), one quad per sign-changing edge. Returns triangles in rock metres.
static func _nets(dens: PackedFloat32Array, P: int, cell: float, reach: float) -> Dictionary:
	var N := P - 1
	var PP := P * P
	var vert_index := PackedInt32Array()
	vert_index.resize(N * N * N)
	vert_index.fill(-1)
	var vpos := PackedVector3Array()
	var ea := [0, 2, 4, 6, 0, 1, 4, 5, 0, 1, 2, 3]
	var eb := [1, 3, 5, 7, 2, 3, 6, 7, 4, 5, 6, 7]
	var corner := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1)]
	var delta := [0, 1, P, P + 1, PP, PP + 1, PP + P, PP + P + 1]
	var dv := PackedFloat32Array()
	dv.resize(8)
	for k in N:
		for j in N:
			for i in N:
				var base := i + P * (j + P * k)
				var any_pos := false
				var any_neg := false
				for c in 8:
					var v := dens[base + delta[c]]
					dv[c] = v
					if v > 0.0:
						any_pos = true
					else:
						any_neg = true
				if not (any_pos and any_neg):
					continue
				var sum := Vector3.ZERO
				var cnt := 0
				for e in 12:
					var a := dv[ea[e]]
					var b := dv[eb[e]]
					if (a > 0.0) != (b > 0.0):
						var t := a / (a - b)
						sum += (corner[ea[e]] as Vector3).lerp(corner[eb[e]], t)
						cnt += 1
				vert_index[i + N * (j + N * k)] = vpos.size()
				vpos.append((sum / cnt + Vector3(i - 1, j - 1, k - 1)) * cell - Vector3.ONE * reach)
	var tris := PackedInt32Array()
	for k in range(1, N):
		for j in range(1, N):
			for i in range(1, N):
				var b0 := i + P * (j + P * k)
				var d0 := dens[b0]
				for axis in 3:
					var d1 := dens[b0 + (1 if axis == 0 else (P if axis == 1 else PP))]
					if (d0 > 0.0) == (d1 > 0.0):
						continue
					var vi: Array
					match axis:
						0: vi = [vert_index[i + N * (j - 1 + N * (k - 1))], vert_index[i + N * (j + N * (k - 1))], vert_index[i + N * (j + N * k)], vert_index[i + N * (j - 1 + N * k)]]
						1: vi = [vert_index[i - 1 + N * (j + N * (k - 1))], vert_index[i + N * (j + N * (k - 1))], vert_index[i + N * (j + N * k)], vert_index[i - 1 + N * (j + N * k)]]
						_: vi = [vert_index[i - 1 + N * (j - 1 + N * k)], vert_index[i + N * (j - 1 + N * k)], vert_index[i + N * (j + N * k)], vert_index[i - 1 + N * (j + N * k)]]
					if vi[0] < 0 or vi[1] < 0 or vi[2] < 0 or vi[3] < 0:
						continue
					var out := Vector3.ZERO
					out[axis] = 1.0 if d0 > 0.0 else -1.0
					var p0: Vector3 = vpos[vi[0]]
					var p1: Vector3 = vpos[vi[1]]
					var p2: Vector3 = vpos[vi[2]]
					var p3: Vector3 = vpos[vi[3]]
					# the shorter diagonal makes the better triangles
					if p0.distance_squared_to(p2) <= p1.distance_squared_to(p3):
						_emit(tris, vpos, vi[0], vi[1], vi[2], out)
						_emit(tris, vpos, vi[0], vi[2], vi[3], out)
					else:
						_emit(tris, vpos, vi[0], vi[1], vi[3], out)
						_emit(tris, vpos, vi[1], vi[2], vi[3], out)
	# loose pieces: connected groups of triangles (by shared vertices); the tiny ones (shards) are dropped
	var parent := PackedInt32Array()
	parent.resize(vpos.size())
	for v in vpos.size():
		parent[v] = v
	for t in tris.size() / 3:
		var ra := _find(parent, tris[t * 3])
		var rb := _find(parent, tris[t * 3 + 1])
		var rc := _find(parent, tris[t * 3 + 2])
		parent[rb] = ra
		parent[_find(parent, rc)] = ra
	var count := {}
	var biggest := 0
	for t in tris.size() / 3:
		var root := _find(parent, tris[t * 3])
		count[root] = count.get(root, 0) + 1
		biggest = maxi(biggest, count[root])
	var verts := PackedVector3Array()
	for t in tris.size() / 3:
		var comp: int = count[_find(parent, tris[t * 3])]
		if float(comp) < SHARD * biggest or (comp < SHARD_MIN and comp < biggest):
			continue
		verts.append(vpos[tris[t * 3]])
		verts.append(vpos[tris[t * 3 + 1]])
		verts.append(vpos[tris[t * 3 + 2]])
	return {"verts": verts, "cell": cell}

static func _find(parent: PackedInt32Array, v: int) -> int:
	while parent[v] != v:
		parent[v] = parent[parent[v]]
		v = parent[v]
	return v

## A triangle (vertex ids) with its front (clockwise) side towards `out`.
static func _emit(tris: PackedInt32Array, vpos: PackedVector3Array, a: int, b: int, c: int, out: Vector3) -> void:
	var n := (vpos[b] - vpos[a]).cross(vpos[c] - vpos[a])
	if n.length_squared() < 1e-12:
		return
	tris.append(a)
	if n.dot(out) > 0.0:
		tris.append(c)
		tris.append(b)
	else:
		tris.append(b)
		tris.append(c)

# ---------------------------------------------------------------- painting

## Flat normals and colours (outer layer with grain, ore patches, fresh fracture inside the bites), in world axes relative to the rock.
static func _paint(m: Dictionary, r: RockInst, f: Dictionary, catalog: RockCatalog) -> Dictionary:
	var vv: PackedVector3Array = m.verts
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var h := r.shape
	var outer := catalog.by_id(r.layers[0][0])
	var c_outer := outer.varied_color(RockMesher._u(h, 5))
	var has_core := r.layers.size() > 1
	var core: RockType = catalog.by_id(r.layers[r.layers.size() - 1][0]) if has_core else null
	var core_frac: float = r.layers[r.layers.size() - 1][1] if has_core else 0.0
	var c_core := core.varied_color(RockMesher._u(h, 6)) if has_core else c_outer
	if has_core and core.traits.has("glow"):
		c_core = c_core.lightened(0.25 * float(core.traits.glow))
	var cover := 0.22 + 0.5 * (core_frac - 0.3) / 0.4
	var tol: float = float(m.cell) * 0.9
	var x: Vector3 = f.x
	var y: Vector3 = f.y
	var z: Vector3 = f.z
	for t in vv.size() / 3:
		var a := vv[t * 3]
		var b := vv[t * 3 + 1]
		var c := vv[t * 3 + 2]
		var cl := (a + b + c) / 3.0                          # centroid in the rock's own frame
		var n_local := -(b - a).cross(c - a).normalized()          # the triangles are clockwise from outside: their cross product points IN
		var dir := cl / maxf(r.size, 0.05)
		var cell := Vector3i(floori(dir.x * 1.6 + 7.0), floori(dir.y * 1.6 + 7.0), floori(dir.z * 1.6 + 7.0))
		var col := c_outer
		if has_core and RockMesher._u(h, 300 + cell.x + cell.y * 31 + cell.z * 977) < cover:
			col = c_core
		else:
			col = c_outer.lerp(c_outer.darkened(0.18), RockMesher._u(h, 700 + t))
		# fresh fracture only where the surface lies ON a bite's sphere (the crater floor); the untouched rock outside keeps its own colour
		for bt: Vector4 in r.bites:
			if absf(cl.distance_to(Vector3(bt.x, bt.y, bt.z)) - bt.w) < tol:
				col = c_core if has_core else c_outer.lightened(0.38)
				break
		var nw := (x * n_local.x + y * n_local.y + z * n_local.z).normalized()
		for q in 3:
			var p := vv[t * 3 + q]
			verts.append(x * p.x + y * p.y + z * p.z)
			normals.append(nw)
			colors.append(col)
	return {"verts": verts, "normals": normals, "colors": colors}
