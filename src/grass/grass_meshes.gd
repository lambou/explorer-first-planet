class_name GrassMeshes
extends RefCounted
## The clump meshes, made in code (no Blender here; GrassType.mesh_name can point to authored meshes later).
## A clump = a few tapered blades. Each blade is 3 triangles (a quad and a tip), or 6 for the long ribbons of sea grass.
## Built for the kind's middle height and then scaled per instance, so everything keeps its proportions.
## Vertex data: COLOR.r = how far along the blade (0 root .. 1 tip: the shader bends the tip most), COLOR.g = a random per
## blade, UV = (side 0/1, along 0..1). Normals point mostly up with a little outward lean: soft, cozy shading, no hard facets.

static var _cache := {}

## variant: 0 .. GrassCatalog.VARIANTS-1. Blades of the same variant always come out the same for the same seed.
static func build(t: GrassType, variant: int, world_seed: int) -> ArrayMesh:
	var key := "%s/%d/%d" % [t.key, variant, world_seed]
	if _cache.has(key):
		return _cache[key]
	var h := SeedMix.splitmix64(world_seed ^ (t.id * 7919) ^ (variant * 104729) ^ 0x6A55)
	if t.flower:
		var fm := _flower_mesh(t, variant, h)
		_cache[key] = fm
		return fm
	var hm := t.height_mid()
	var radius := t.clump_radius / hm              # unit space: the clump is 1 tall
	var width := t.blade_width / hm
	var rows: Array = [0.0, 0.5, 1.0]
	if t.underwater:
		rows = [0.0, 0.34, 0.67, 1.0]
	var blades := t.blades + variant                 # the second variant is a little fuller
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	for b in blades:
		var hb := SeedMix.splitmix64(h + b * 31337)
		var a := _u(hb, 1) * TAU
		var r := radius * sqrt(_u(hb, 2))
		var base := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var lean_dir := Vector3(cos(a), 0.0, sin(a)).rotated(Vector3.UP, (_u(hb, 3) - 0.5) * 1.8)
		var lean := (0.12 + 0.38 * _u(hb, 4)) * (1.4 if t.underwater else 1.0)
		var height := 0.75 + 0.25 * _u(hb, 5)
		var w := width * (0.8 + 0.4 * _u(hb, 6))
		var face := _u(hb, 7) * TAU
		var side := Vector3(-sin(face), 0.0, cos(face))
		var wob := (_u(hb, 8) - 0.5) * 0.6 if t.underwater else 0.0
		var ring_pos: Array[Vector3] = []
		for k in rows.size():
			var tt: float = rows[k]
			var p := base + lean_dir * (lean * tt * tt) + Vector3.UP * (height * tt)
			p += side * (sin(tt * 5.0 + a) * wob * tt)
			ring_pos.append(p)
		# vertices of the blade: two per row, one at the tip
		var first := verts.size()
		for k in rows.size():
			var tt: float = rows[k]
			var tip := k == rows.size() - 1
			var half := w * (1.0 - 0.28 * tt) * (0.0 if tip else 1.0)
			var out := (ring_pos[k] - Vector3(0, ring_pos[k].y, 0)).normalized() if ring_pos[k].length() > 0.001 else Vector3.UP
			var n := (Vector3.UP * 0.8 + Vector3(out.x, 0.0, out.z) * 0.35).normalized()
			var c := Color(tt, _u(hb, 9), 1.0, 1.0)
			if tip:
				verts.append(ring_pos[k])
				normals.append(n)
				colors.append(c)
				uvs.append(Vector2(0.5, tt))
			else:
				verts.append(ring_pos[k] - side * half)
				verts.append(ring_pos[k] + side * half)
				for s in 2:
					normals.append(n)
					colors.append(c)
					uvs.append(Vector2(float(s), tt))
	# triangles: for each blade, row quads then the tip triangle (indices follow the vertex order above)
	var indices := PackedInt32Array()
	var per_blade := rows.size() * 2 - 1
	for b in blades:
		var f := b * per_blade
		for k in rows.size() - 2:
			var l0 := f + k * 2
			var r0 := l0 + 1
			var l1 := l0 + 2
			var r1 := l0 + 3
			indices.append_array(PackedInt32Array([l0, r0, l1, r0, r1, l1]))
		var lt := f + (rows.size() - 2) * 2
		indices.append_array(PackedInt32Array([lt, lt + 1, lt + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_cache[key] = m
	return m

## A flower clump: a few thin straight stems, each with a flat five-petal head (UV.y = 1 on the head, so the shader paints it in the
## flower colour; the stem is green). The head faces up and a little to the side, like a daisy in the wind.
static func _flower_mesh(t: GrassType, variant: int, h: int) -> ArrayMesh:
	var hm := t.height_mid()
	var radius := t.clump_radius / hm
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var n := t.blades + variant
	for b in n:
		var hb := SeedMix.splitmix64(h + b * 7717)
		var a := _u(hb, 1) * TAU
		var r := radius * sqrt(_u(hb, 2))
		var base := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var height := 0.7 + 0.3 * _u(hb, 3)
		var lean := Vector3(_u(hb, 4) - 0.5, 0.0, _u(hb, 5) - 0.5) * 0.25
		var top := base + lean + Vector3.UP * height
		var w := 0.010 / hm
		var side := Vector3(1, 0, 0).rotated(Vector3.UP, _u(hb, 6) * TAU)
		# the stem: a thin tapered quad in two halves
		var mid := base + lean * 0.4 + Vector3.UP * (height * 0.5)
		var i0 := verts.size()
		for p in [[base - side * w, 0.0], [base + side * w, 0.0], [mid - side * w * 0.8, 0.45], [mid + side * w * 0.8, 0.45], [top - side * w * 0.6, 0.85], [top + side * w * 0.6, 0.85]]:
			verts.append(p[0])
			normals.append(Vector3.UP)
			uvs.append(Vector2(0.0, p[1]))
		indices.append_array(PackedInt32Array([i0, i0 + 1, i0 + 2, i0 + 1, i0 + 3, i0 + 2, i0 + 2, i0 + 3, i0 + 4, i0 + 3, i0 + 5, i0 + 4]))
		# the head: five petals around the top, a flat star facing up
		var ci := verts.size()
		verts.append(top + Vector3.UP * 0.01)
		normals.append(Vector3.UP)
		uvs.append(Vector2(0.5, 1.0))
		var pr := (0.055 + 0.03 * _u(hb, 7)) / hm * 1.0
		for k in 5:
			var ang := TAU * k / 5.0 + _u(hb, 8) * 1.0
			var pa := top + Vector3(cos(ang), 0.0, sin(ang)) * pr
			var l := Vector3(cos(ang + 0.5), 0.0, sin(ang + 0.5)) * pr * 0.55
			var rr := Vector3(cos(ang - 0.5), 0.0, sin(ang - 0.5)) * pr * 0.55
			var v0 := verts.size()
			verts.append(top + l * 0.4)
			verts.append(pa)
			verts.append(top + rr * 0.4)
			for q in 3:
				normals.append(Vector3.UP)
				uvs.append(Vector2(0.5, 1.0))
			indices.append_array(PackedInt32Array([ci, v0, v0 + 1, ci, v0 + 1, v0 + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m

static func triangle_count(m: ArrayMesh) -> int:
	return (m.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3

static func _u(h: int, n: int) -> float:
	var v := SeedMix.splitmix64(h + n * 0x632BE59B)
	return float((v >> 11) & ((1 << 53) - 1)) / 9007199254740992.0
