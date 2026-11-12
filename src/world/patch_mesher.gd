class_name PatchMesher
extends RefCounted
## Builds a low-poly surface patch of the far terrain: only the shape of the ground
## (one height per grid vertex, no volume, no underground). Thread-safe.

const N_FINE := 12                # cells per side for the nearest patches
const N_COARSE := 8               # for distant ones (they are small on screen)
const LOWER := 1.5                # patches sit slightly below the full-detail chunks near the player

## Output arrays are relative to `origin` (a point of the node centre at sea level), so the
## mesh node must be placed at `origin`.
static func build(gen: PlanetGenerator, key: Vector4i, skirt: bool = true) -> Dictionary:
	var n := N_FINE if key.y >= 7 else N_COARSE
	var rect := CubeSphere.node_rect(key)
	var big := float(WorldConfig.PLANET_RADIUS)
	var origin := CubeSphere.node_center_dir(key) * big
	var cell_m := CubeSphere.node_radius(key) * 1.4142 / n   # approx. metres per cell
	var step := maxi(1, int(cell_m))
	var col := Column.new()
	var pos := PackedVector3Array()
	var colors := PackedColorArray()
	pos.resize((n + 1) * (n + 1))
	colors.resize((n + 1) * (n + 1))
	var hts := PackedFloat32Array()
	var seas := PackedByteArray()
	var dirs := PackedVector3Array()
	hts.resize((n + 1) * (n + 1))
	seas.resize((n + 1) * (n + 1))
	dirs.resize((n + 1) * (n + 1))
	for b in n + 1:
		for a in n + 1:
			var d := CubeSphere.direction(key.x, rect.position.x + rect.size.x * a / n, rect.position.y + rect.size.y * b / n)
			gen.sample_column(d, col, step)
			pos[a + (n + 1) * b] = d * (big + col.height - LOWER) - origin
			colors[a + (n + 1) * b] = gen.surface.color_for(col)
			hts[a + (n + 1) * b] = col.height
			seas[a + (n + 1) * b] = 1 if PlanetGenerator.is_sea(col.land, col.height) else 0
			dirs[a + (n + 1) * b] = d

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var cols := PackedColorArray()
	for b in n:
		for a in n:
			var i0 := a + (n + 1) * b
			var idx := [i0, i0 + 1, i0 + 1 + (n + 1), i0 + (n + 1)]
			var out := ((pos[idx[0]] + pos[idx[2]]) * 0.5 + origin).normalized()
			var q := (pos[idx[2]] - pos[idx[0]]).cross(pos[idx[3]] - pos[idx[1]])
			if q.dot(out) > 0.0:   # Godot front faces are clockwise
				idx = [idx[0], idx[3], idx[2], idx[1]]
			if pos[idx[0]].distance_squared_to(pos[idx[2]]) <= pos[idx[1]].distance_squared_to(pos[idx[3]]):
				_tri(verts, normals, cols, pos, colors, idx[0], idx[1], idx[2])
				_tri(verts, normals, cols, pos, colors, idx[0], idx[2], idx[3])
			else:
				_tri(verts, normals, cols, pos, colors, idx[0], idx[1], idx[3])
				_tri(verts, normals, cols, pos, colors, idx[1], idx[2], idx[3])
	# skirts (flaps hiding cracks between detail levels) go in their own arrays: they must never cast
	# shadows (a wall a few metres tall throws a long thin shadow line at a low sun)
	var sverts := PackedVector3Array()
	var snormals := PackedVector3Array()
	var scols := PackedColorArray()
	if skirt:
		var drop := cell_m * 1.5 + 3.0
		var border: Array = []
		for k in n:
			border.append([k, k + 1, 0, 0, 0])                     # edge along b = 0
			border.append([k + (n + 1) * n, k + 1 + (n + 1) * n, 0, 0, 0])
			border.append([k * (n + 1), (k + 1) * (n + 1), 0, 0, 0])
			border.append([n + k * (n + 1), n + (k + 1) * (n + 1), 0, 0, 0])
		for e in border:
			var pa: Vector3 = pos[e[0]]
			var pb: Vector3 = pos[e[1]]
			var ua := (pa + origin).normalized()
			var ub := (pb + origin).normalized()
			var pa2 := pa - ua * drop
			var pb2 := pb - ub * drop
			var c := (colors[e[0]] + colors[e[1]]) * 0.5 * 0.85
			c.a = 1.0
			var sn := (ua + ub).normalized()
			for tri in [[pa, pb, pb2], [pa, pb2, pa2], [pb, pa, pb2], [pb2, pa, pa2]]:
				for v in tri:
					sverts.append(v)
					snormals.append(sn)
					scols.append(c)
	# water: a flat sheet at sea level over every cell that has sea and ground below sea level
	var wverts := PackedVector3Array()
	var wnormals := PackedVector3Array()
	var wuvs := PackedVector2Array()
	var wcols := PackedColorArray()
	var windex := PackedInt32Array()
	var wmap := {}
	for b in n:
		for a in n:
			var i0 := a + (n + 1) * b
			var cs := [i0, i0 + 1, i0 + 1 + (n + 1), i0 + (n + 1)]
			var has_sea := false
			var has_deep := false
			for ci: int in cs:
				if seas[ci] == 1:
					has_sea = true
				if hts[ci] < 0.0:
					has_deep = true
			if not (has_sea and has_deep):
				continue
			var vi := []
			for ci: int in cs:
				if not wmap.has(ci):
					wmap[ci] = wverts.size()
					wverts.append(dirs[ci] * big - origin)
					wnormals.append(dirs[ci])
					wuvs.append(Vector2(maxf(0.0, -hts[ci]), 0.0))
					wcols.append(Color(0.5, 0.5, 0.5, 1.0))
				vi.append(wmap[ci])
			windex.append_array([vi[0], vi[1], vi[2], vi[0], vi[2], vi[3]])
	return {"verts": verts, "normals": normals, "colors": cols, "origin": origin,
			"wverts": wverts, "wnormals": wnormals, "wuvs": wuvs, "wcolors": wcols, "windex": windex,
			"sverts": sverts, "snormals": snormals, "scolors": scols}

static func _tri(verts: PackedVector3Array, normals: PackedVector3Array, cols: PackedColorArray,
		pos: PackedVector3Array, colors: PackedColorArray, a: int, b: int, c: int) -> void:
	var cr := (pos[b] - pos[a]).cross(pos[c] - pos[a])
	if cr.length_squared() < 1e-9:
		return
	var n := (-cr).normalized()
	verts.append(pos[a])
	verts.append(pos[b])
	verts.append(pos[c])
	for i in 3:
		normals.append(n)
	# per-vertex colours: the GPU blends them smoothly across the triangle
	cols.append(colors[a])
	cols.append(colors[b])
	cols.append(colors[c])
