class_name WaterMesher
extends RefCounted
## Builds the surface of the water in one chunk from its water-level samples (`wlev`, metres relative
## to sea level, NO_WATER = none). The surface is where level - height changes sign (Surface Nets,
## same grid as the terrain). Sea water has the level exactly 0.0; cave water has level + 0.002, which
## is how the two kinds are told apart. Water inside rock is invisible (the terrain hides it), so
## the sheet simply continues into the rock around a flooded space.
## Per vertex: UV = (depth below the surface in metres, kind 0 sea / 1 cave), COLOR = flow (unused yet).
## Thread-safe (no scene access).

const S := WorldConfig.CHUNK_SIZE
const P := WorldConfig.PADDED
const N := P - 1
const PP := P * P
const NO_WATER := PlanetGenerator.NO_WATER
const LAT := PlanetGenerator.LAT
const LN := PlanetGenerator.LN
const R := float(WorldConfig.PLANET_RADIUS)

static var DELTA := PackedInt32Array([0, 1, P, P + 1, PP, PP + 1, PP + P, PP + P + 1])

static func has_water(wlev: PackedFloat32Array) -> bool:
	return not wlev.is_empty()

## wlev/dens: padded chunk arrays; hlat/l0: terrain height lattice of the chunk (for ocean depth).
static func build(wlev: PackedFloat32Array, dens: PackedFloat32Array, coord: Vector3i,
		hlat: PackedFloat32Array, l0: Vector3i) -> Dictionary:
	var empty := {"verts": PackedVector3Array()}
	if wlev.is_empty():
		return empty
	var o := coord * S - Vector3i.ONE            # world position of sample index (0, 0, 0)
	# field f = level - height above sea level; > 0 below the surface
	var f := PackedFloat32Array()
	f.resize(P * P * P)
	var any_pos := false
	var any_neg := false
	var n := 0
	for k in P:
		var wz := float(o.z + k)
		for j in P:
			var wy := float(o.y + j)
			for i in P:
				var lv := wlev[n]
				if lv > NO_WATER * 0.5:
					var wx := float(o.x + i)
					var v := lv - (sqrt(wx * wx + wy * wy + wz * wz) - R)
					f[n] = v
					if v > 0.0:
						any_pos = true
					else:
						any_neg = true
				else:
					f[n] = -64.0
					any_neg = true
				n += 1
	if not any_pos or not any_neg:
		return empty

	var cell_vertex := PackedInt32Array()
	cell_vertex.resize(N * N * N)
	cell_vertex.fill(-1)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var mi := PackedInt32Array()
	var mj := PackedInt32Array()
	var mk := PackedInt32Array()
	var dvv := PackedFloat32Array()
	dvv.resize(8)
	var EA := ChunkMesher.EA
	var EB := ChunkMesher.EB
	var ESX := ChunkMesher.ESX
	var ESY := ChunkMesher.ESY
	var ESZ := ChunkMesher.ESZ
	var EAX := ChunkMesher.EAX

	for kk in N:
		for jj in N:
			for ii in N:
				var base := ii + P * (jj + P * kk)
				var any_p := false
				var any_n := false
				for c in 8:
					var v := f[base + DELTA[c]]
					dvv[c] = v
					if v > 0.0:
						any_p = true
					else:
						any_n = true
				if not (any_p and any_n):
					continue
				var sx := 0.0
				var sy := 0.0
				var sz := 0.0
				var cnt := 0
				for e in 12:
					var a := dvv[EA[e]]
					var b := dvv[EB[e]]
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
				var vs := Vector3(sx / cnt + ii - 1, sy / cnt + jj - 1, sz / cnt + kk - 1)
				var wp := Vector3(coord * S) + vs
				var up := wp.normalized()
				# kind: sea water is exactly level 0.0, river levels end in .0007, cave levels in .002
				var kind := 1.0
				for c in 8:
					var lvc := wlev[base + DELTA[c]]
					if lvc == 0.0:
						kind = 0.0
						break
					if lvc > NO_WATER * 0.5 and absf(fposmod(lvc, 0.01) - PlanetGenerator.RIVER_MARK) < 0.0003:
						kind = 2.0
				var depth: float
				if kind == 0.0:
					depth = maxf(0.0, -_lattice_height(hlat, l0, wp))
				else:
					depth = _depth_below(dens, wp, up, o)
				cell_vertex[ii + N * (jj + N * kk)] = verts.size()
				mi.append(ii)
				mj.append(jj)
				mk.append(kk)
				verts.append(vs)
				normals.append(up)
				uvs.append(Vector2(depth, kind))
				cols.append(Color(0.5, 0.5, 0.5, 1.0))

	var indices := PackedInt32Array()
	for q in mi.size():
		var i := mi[q]
		var j := mj[q]
		var k := mk[q]
		if i < 1 or j < 1 or k < 1 or i > S or j > S or k > S:
			continue
		var b0 := i + P * (j + P * k)
		var d0 := f[b0]
		for axis in 3:
			var d1 := f[b0 + (1 if axis == 0 else (P if axis == 1 else PP))]
			if (d0 > 0.0) == (d1 > 0.0):
				continue
			var v0: int
			var v1: int
			var v2: int
			var v3: int
			match axis:
				0:
					v0 = cell_vertex[i + N * (j - 1 + N * (k - 1))]
					v1 = cell_vertex[i + N * (j + N * (k - 1))]
					v2 = cell_vertex[i + N * (j + N * k)]
					v3 = cell_vertex[i + N * (j - 1 + N * k)]
				1:
					v0 = cell_vertex[i - 1 + N * (j + N * (k - 1))]
					v1 = cell_vertex[i + N * (j + N * (k - 1))]
					v2 = cell_vertex[i + N * (j + N * k)]
					v3 = cell_vertex[i - 1 + N * (j + N * k)]
				_:
					v0 = cell_vertex[i - 1 + N * (j - 1 + N * k)]
					v1 = cell_vertex[i + N * (j - 1 + N * k)]
					v2 = cell_vertex[i + N * (j + N * k)]
					v3 = cell_vertex[i - 1 + N * (j + N * k)]
			if v0 < 0 or v1 < 0 or v2 < 0 or v3 < 0:
				continue
			indices.append_array([v0, v1, v2, v0, v2, v3])
	if indices.is_empty():
		return empty
	return {"verts": verts, "normals": normals, "uvs": uvs, "colors": cols, "indices": indices}

## Terrain height (metres above sea level) from the chunk's 4 m height lattice, trilinear.
static func _lattice_height(hlat: PackedFloat32Array, l0: Vector3i, wp: Vector3) -> float:
	if hlat.is_empty():
		return -20.0
	var fx := wp.x / LAT - l0.x
	var fy := wp.y / LAT - l0.y
	var fz := wp.z / LAT - l0.z
	var ix := clampi(floori(fx), 0, LN - 2)
	var iy := clampi(floori(fy), 0, LN - 2)
	var iz := clampi(floori(fz), 0, LN - 2)
	var tx := clampf(fx - ix, 0.0, 1.0)
	var ty := clampf(fy - iy, 0.0, 1.0)
	var tz := clampf(fz - iz, 0.0, 1.0)
	var b := ix + LN * (iy + LN * iz)
	var LL := LN * LN
	var c00 := lerpf(hlat[b], hlat[b + 1], tx)
	var c10 := lerpf(hlat[b + LN], hlat[b + LN + 1], tx)
	var c01 := lerpf(hlat[b + LL], hlat[b + LL + 1], tx)
	var c11 := lerpf(hlat[b + LL + LN], hlat[b + LL + LN + 1], tx)
	return lerpf(lerpf(c00, c10, ty), lerpf(c01, c11, ty), tz)

## Metres down (radially) from a water surface point to the rock below, up to 8 m.
static func _depth_below(dens: PackedFloat32Array, wp: Vector3, up: Vector3, o: Vector3i) -> float:
	for t in range(1, 9):
		var q := wp - up * float(t)
		var ii := roundi(q.x) - o.x
		var jj := roundi(q.y) - o.y
		var kk := roundi(q.z) - o.z
		if ii < 0 or jj < 0 or kk < 0 or ii >= P or jj >= P or kk >= P:
			return float(t)
		if dens[ii + P * (jj + P * kk)] > 0.0:
			return float(t) - 0.5
	return 8.0
