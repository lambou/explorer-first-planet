class_name ChunkMesher
extends RefCounted
## Surface Nets mesher: smooth surface from the density field, emitted as flat-shaded
## triangles (low-poly look). Thread-safe (no scene access).
## Output is non-indexed: every 3 vertices = 1 triangle (also used as collision faces).

const S := WorldConfig.CHUNK_SIZE
const P := WorldConfig.PADDED
const N := P - 1                  # cells per axis (17): cell c uses samples c..c+1

const PP := P * P
# edges of a cell: corner pairs, start corner and axis (corner bits: 1 = +x, 2 = +y, 4 = +z)
static var EA := PackedInt32Array([0, 2, 4, 6, 0, 1, 4, 5, 0, 1, 2, 3])
static var EB := PackedInt32Array([1, 3, 5, 7, 2, 3, 6, 7, 4, 5, 6, 7])
static var ESX := PackedFloat32Array([0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1])
static var ESY := PackedFloat32Array([0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1])
static var ESZ := PackedFloat32Array([0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0])
static var EAX := PackedInt32Array([0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2])
static var DELTA := PackedInt32Array([0, 1, P, P + 1, PP, PP + 1, PP + P, PP + P + 1])

## origin = world position (metres) of the node's min corner, cell = metres per cell (LOD),
## skirt = hang a short skirt below open border edges to hide cracks between LOD levels.
## natural = the natural (unedited) density, used to bake how much sky each vertex sees.
static func build(dens: PackedFloat32Array, colr: PackedColorArray, origin: Vector3i, cell: int = 1, skirt: bool = false,
		natural: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var cell_vertex := PackedInt32Array()
	cell_vertex.resize(N * N * N)
	cell_vertex.fill(-1)
	var vpos := PackedVector3Array()
	var vcol := PackedColorArray()
	var mi := PackedInt32Array()      # mixed cells (i, j, k) for the quad pass
	var mj := PackedInt32Array()
	var mk := PackedInt32Array()
	var dv := PackedFloat32Array()
	dv.resize(8)

	# per-row min / max along x: whole rows of cells without a surface are skipped
	var rmin := PackedFloat32Array()
	var rmax := PackedFloat32Array()
	rmin.resize(PP)
	rmax.resize(PP)
	for row in PP:
		var rb := row * P
		var lo := dens[rb]
		var hi := lo
		for i in range(1, P):
			var v := dens[rb + i]
			if v < lo:
				lo = v
			elif v > hi:
				hi = v
		rmin[row] = lo
		rmax[row] = hi

	# 1) one vertex per mixed cell
	for k in N:
		for j in N:
			var r0 := j + P * k
			var lo := minf(minf(rmin[r0], rmin[r0 + 1]), minf(rmin[r0 + P], rmin[r0 + P + 1]))
			var hi := maxf(maxf(rmax[r0], rmax[r0 + 1]), maxf(rmax[r0 + P], rmax[r0 + P + 1]))
			if lo > 0.0 or hi <= 0.0:
				continue
			for i in N:
				var base := i + P * (j + P * k)
				var d0 := dens[base]
				var d1 := dens[base + 1]
				var d2 := dens[base + P]
				var d3 := dens[base + P + 1]
				var d4 := dens[base + PP]
				var d5 := dens[base + PP + 1]
				var d6 := dens[base + PP + P]
				var d7 := dens[base + PP + P + 1]
				var any_pos := d0 > 0.0 or d1 > 0.0 or d2 > 0.0 or d3 > 0.0 or d4 > 0.0 or d5 > 0.0 or d6 > 0.0 or d7 > 0.0
				if not any_pos:
					continue
				if d0 > 0.0 and d1 > 0.0 and d2 > 0.0 and d3 > 0.0 and d4 > 0.0 and d5 > 0.0 and d6 > 0.0 and d7 > 0.0:
					continue
				dv[0] = d0
				dv[1] = d1
				dv[2] = d2
				dv[3] = d3
				dv[4] = d4
				dv[5] = d5
				dv[6] = d6
				dv[7] = d7
				var sx := 0.0
				var sy := 0.0
				var sz := 0.0
				var cnt := 0
				for e in 12:
					var a := dv[EA[e]]
					var b := dv[EB[e]]
					if (a > 0.0) != (b > 0.0):
						var t := a / (a - b)
						sx += ESX[e]
						sy += ESY[e]
						sz += ESZ[e]
						match EAX[e]:
							0: sx += t
							1: sy += t
							_: sz += t
						cnt += 1
				# colour = that of the solid corner closest to the surface (so the natural surface always
				# shows the smooth top colour, and dug walls show the layer they cut through)
				var best := -1
				var best_v := 1e9
				for c in 8:
					var v := dv[c]
					if v > 0.0 and v < best_v:
						best_v = v
						best = c
				var m := base + DELTA[best]
				cell_vertex[i + N * (j + N * k)] = vpos.size()
				mi.append(i)
				mj.append(j)
				mk.append(k)
				# sample coord = index - 1
				var vs := Vector3(sx / cnt + i - 1, sy / cnt + j - 1, sz / cnt + k - 1)
				vpos.append(vs * cell)
				var vc: Color = colr[m]
				vc.a = 1.0
				if not natural.is_empty() and cell == 1:
					var g := Vector3((d1 + d3 + d5 + d7) - (d0 + d2 + d4 + d6),
							(d2 + d3 + d6 + d7) - (d0 + d1 + d4 + d5),
							(d4 + d5 + d6 + d7) - (d0 + d1 + d2 + d3))
					var nrm := (-g).normalized() if g.length_squared() > 1e-9 else Vector3.ZERO
					var up := (Vector3(origin) + vs).normalized()
					vc.a = sky_exposure(dens, natural, vs + nrm * 0.8, up)
				vcol.append(vc)

	# 2) one quad per sign-changing edge starting at an owned sample (index 1..S): only mixed cells
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var edge_count := {}
	for n in mi.size():
		var i := mi[n]
		var j := mj[n]
		var k := mk[n]
		if i < 1 or j < 1 or k < 1 or i > S or j > S or k > S:
			continue
		var b0 := i + P * (j + P * k)
		var d0 := dens[b0]
		for axis in 3:
			var d1 := dens[b0 + (1 if axis == 0 else (P if axis == 1 else PP))]
			if (d0 > 0.0) == (d1 > 0.0):
				continue
			var vi: Array
			match axis:
				0: vi = [cell_vertex[i + N * (j - 1 + N * (k - 1))], cell_vertex[i + N * (j + N * (k - 1))], cell_vertex[i + N * (j + N * k)], cell_vertex[i + N * (j - 1 + N * k)]]
				1: vi = [cell_vertex[i - 1 + N * (j + N * (k - 1))], cell_vertex[i + N * (j + N * (k - 1))], cell_vertex[i + N * (j + N * k)], cell_vertex[i - 1 + N * (j + N * k)]]
				_: vi = [cell_vertex[i - 1 + N * (j - 1 + N * k)], cell_vertex[i + N * (j - 1 + N * k)], cell_vertex[i + N * (j + N * k)], cell_vertex[i - 1 + N * (j + N * k)]]
			if vi[0] < 0 or vi[1] < 0 or vi[2] < 0 or vi[3] < 0:
				continue
			var out := Vector3.ZERO
			out[axis] = 1.0 if d0 > 0.0 else -1.0
			_quad(verts, normals, colors, vpos, vcol, vi, out, origin, edge_count)
	# skirts live in their own arrays: they hide hairline cracks between chunks but must never cast
	# shadows (at a low sun they throw long streaks) nor take part in collision
	var sverts := PackedVector3Array()
	var snormals := PackedVector3Array()
	var scolors := PackedColorArray()
	if skirt:
		_skirts(sverts, snormals, scolors, vpos, vcol, edge_count, origin, cell)
	return {"verts": verts, "normals": normals, "colors": colors, "faces": verts,
			"sverts": sverts, "snormals": snormals, "scolors": scolors}

## How much open sky a point sees, 0.06 (none) .. 1 (open). Looks straight up (radially) through
## the chunk's density samples:
##  - rock overhead in the current terrain (a cave ceiling, a roof) blocks the sky;
##  - a point below the natural ground (a dug shaft) sees the sky through the opening; for a hole of
##    about 6 m radius that fraction is r^2 / (r^2 + depth^2), so it falls off quickly with depth.
## `p` is in sample coordinates; `base` is the natural density, `dens` the edited one.
static func sky_exposure(dens: PackedFloat32Array, base: PackedFloat32Array, p: Vector3, up: Vector3) -> float:
	var z := 18.0            # distance up to the natural ground surface (18 = deeper than we can see)
	var c := -1.0            # distance up to rock overhead in the edited terrain
	var last_rock := false
	var left := false
	for t in range(1, 18):
		var q := p + up * float(t)
		var ii := roundi(q.x) + 1
		var jj := roundi(q.y) + 1
		var kk := roundi(q.z) + 1
		if ii < 0 or jj < 0 or kk < 0 or ii >= P or jj >= P or kk >= P:
			left = true
			if z >= 18.0:
				# left the chunk before reaching the natural ground: open if the last cell was air,
				# otherwise we are still underground - assume the opening is farther up
				z = float(t) + (8.0 if last_rock else 0.0)
			break
		var idx := ii + P * (jj + P * kk)
		last_rock = base[idx] > 0.0
		if z >= 18.0 and not last_rock:
			z = float(t)
		if c < 0.0 and dens[idx] > 0.0:
			c = float(t)
		if c >= 0.0 and z < 18.0:
			break
	var e := 1.0 / (1.0 + (z / 6.0) * (z / 6.0))
	if c > 0.0:
		e = minf(e, 0.06 + 0.35 * c / 17.0)
	return clampf(e, 0.06, 1.0)

static func _skirts(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		vpos: PackedVector3Array, vcol: PackedColorArray, edge_count: Dictionary, origin: Vector3i, cell: int) -> void:
	var drop := cell * 2.0 + 1.0
	for key: int in edge_count:
		if edge_count[key] != 1:
			continue
		var a := floori(key / 1000000.0)
		var b := key % 1000000
		var pa := vpos[a]
		var pb := vpos[b]
		var ua := (Vector3(origin) + pa).normalized()
		var ub := (Vector3(origin) + pb).normalized()
		var pa2 := pa - ua * drop
		var pb2 := pb - ub * drop
		var col := (vcol[a] + vcol[b]) * 0.5 * 0.85
		col.a = (vcol[a].a + vcol[b].a) * 0.5
		var n := (ua + ub).normalized()
		# both windings: visible from either side
		for tri in [[pa, pb, pb2], [pa, pb2, pa2], [pb, pa, pb2], [pb2, pa, pa2]]:
			for v in tri:
				verts.append(v)
				normals.append(n)
				colors.append(col)

## Emit a quad (4 cell-vertex indices in loop order) as two triangles. The whole quad is
## oriented once from its average normal, so neighbouring triangles never disagree.
static func _quad(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		vpos: PackedVector3Array, vcol: PackedColorArray, vi: Array, out: Vector3, origin: Vector3i, edge_count: Dictionary) -> void:
	var idx: Array = [vi[0], vi[1], vi[2], vi[3]]
	var q := (vpos[idx[2]] - vpos[idx[0]]).cross(vpos[idx[3]] - vpos[idx[1]])
	# Godot front faces are clockwise: the cross product must oppose the outward direction.
	if q.dot(out) > 0.0:
		idx = [idx[0], idx[3], idx[2], idx[1]]
	for e in 4:
		var ea: int = idx[e]
		var eb: int = idx[(e + 1) % 4]
		var ek := mini(ea, eb) * 1000000 + maxi(ea, eb)
		edge_count[ek] = edge_count.get(ek, 0) + 1
	# split along the shorter diagonal
	if vpos[idx[0]].distance_squared_to(vpos[idx[2]]) <= vpos[idx[1]].distance_squared_to(vpos[idx[3]]):
		_tri(verts, normals, colors, vpos, vcol, idx[0], idx[1], idx[2], origin)
		_tri(verts, normals, colors, vpos, vcol, idx[0], idx[2], idx[3], origin)
	else:
		_tri(verts, normals, colors, vpos, vcol, idx[0], idx[1], idx[3], origin)
		_tri(verts, normals, colors, vpos, vcol, idx[1], idx[2], idx[3], origin)

static func _tri(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		vpos: PackedVector3Array, vcol: PackedColorArray, a: int, b: int, c: int, origin: Vector3i) -> void:
	var pa := vpos[a]
	var pb := vpos[b]
	var pc := vpos[c]
	var cr := (pb - pa).cross(pc - pa)
	if cr.length_squared() < 1e-12:
		return
	var n := (-cr).normalized()
	verts.append(pa)
	verts.append(pb)
	verts.append(pc)
	normals.append(n)
	normals.append(n)
	normals.append(n)
	# per-vertex colours: the GPU blends them smoothly across the triangle
	colors.append(vcol[a])
	colors.append(vcol[b])
	colors.append(vcol[c])
