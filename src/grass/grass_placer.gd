class_name GrassPlacer
extends RefCounted
## Plants the grass of one chunk. Deterministic (seed + chunk), done on the worker thread together with the chunk build.
##
## A jittered grid of planting cells (CELL metres) is laid on the tangent plane of the chunk. Each cell is dropped onto the
## natural ground using the chunk's height lattice (no density search in the common case), checked against the chunk's real
## density (it must touch the surface), and then the field decides: a kind of grass or none (what the ground colour, the
## climate, the patches and the slope allow), or sea grass if the spot is under water. The result per kind is ONE packed buffer
## (transform + custom data per instance) ready to be handed to a MultiMesh.
## Per instance buffer layout (16 floats): 12 for the transform (3x4, row by row), then custom data
##   (ground tint r, g, b, random a): read in the shader as INSTANCE_CUSTOM.

const S := WorldConfig.CHUNK_SIZE
const R := float(WorldConfig.PLANET_RADIUS)
const CELL := 1.15                 # planting cell (metres)
const HALF := 12.0                 # the planting grid covers +-HALF around the chunk centre (the chunk is a cube seen along "up")
const STRIDE := 16
const MIN_HEIGHT := 0.6            # grass is not planted where the natural ground is deeper than this under the surface (caves)

## Returns {type id: {"buf": PackedFloat32Array, "count": int, "aabb": AABB}}. `rocks`: Array[RockInst] of the chunk (kept clear).
static func place(gen: PlanetGenerator, field: GrassField, coord: Vector3i, dens: PackedFloat32Array, colr: PackedColorArray,
		wlev: PackedFloat32Array, hlat: PackedFloat32Array, l0: Vector3i, rocks: Array) -> Dictionary:
	var out := {}
	if dens.is_empty() or hlat.is_empty():
		return out
	var any_air := false
	var any_solid := false
	for i in range(0, dens.size(), 7):
		if dens[i] < 0.0:
			any_air = true
		else:
			any_solid = true
		if any_air and any_solid:
			break
	if not (any_air and any_solid):
		return out
	var origin := Vector3(coord * S)
	var centre := origin + Vector3.ONE * (S * 0.5)
	var up_c := centre.normalized()
	var t1 := up_c.cross(Vector3.UP if absf(up_c.y) < 0.95 else Vector3.RIGHT).normalized()
	var t2 := up_c.cross(t1)
	# climate on a 3x3 grid over the footprint (moisture, temperature), interpolated per planting cell
	var clim := PackedVector2Array()
	var col := Column.new()
	for gv in 3:
		for gu in 3:
			var pg := centre + t1 * (-HALF + gu * HALF) + t2 * (-HALF + gv * HALF)
			gen.sample_column(pg.normalized(), col)
			clim.append(Vector2(col.moisture, col.temperature))
	var base := SeedMix.splitmix64(field.world_seed ^ 0x6A55)
	base = SeedMix.splitmix64(base + coord.x)
	base = SeedMix.splitmix64(base + coord.y * 1000003)
	base = SeedMix.splitmix64(base + coord.z * 998244353)
	var n := int(ceil(2.0 * HALF / CELL))
	var bufs := {}
	var los := {}
	var his := {}
	for iv in n:
		for iu in n:
			var h := SeedMix.splitmix64(base + iu * 7349 + iv * 913)
			var u := -HALF + (iu + _unit(h, 1)) * CELL
			var v := -HALF + (iv + _unit(h, 2)) * CELL
			var p0 := centre + t1 * u + t2 * v
			var d := p0.normalized()
			var p := d * (R + ChunkSampler.lattice_height(hlat, l0, p0))
			var lp := p - origin
			if lp.x < 0.0 or lp.y < 0.0 or lp.z < 0.0 or lp.x >= S or lp.y >= S or lp.z >= S:
				continue
			# the ground must really be here (the lattice is a 4 m approximation, edits and caves change things)
			if not (ChunkSampler.density(dens, lp - d * 0.3) > 0.0 and ChunkSampler.density(dens, lp + d * 0.35) < 0.0):
				var fl := _find_floor(dens, lp, d)
				if fl.x < -1.0e8:
					continue
				lp = fl
				p = origin + lp
				d = p.normalized()
			# rocks keep clear of grass
			var blocked := false
			for rk in rocks:                              # rocks and tree trunks: anything with a position and a size
				if rk.pos.distance_squared_to(p) < (rk.size * 1.15 + 0.2) * (rk.size * 1.15 + 0.2):
					blocked = true
					break
			if blocked:
				continue
			var ci := ChunkSampler.index_at(lp - d * 0.7)
			var ground: Color = colr[ci] if ci < colr.size() else Color(0.4, 0.6, 0.3)
			var alt := p.length() - R
			var slope := _slope(hlat, l0, p, t1, t2)
			# under water?
			var water_depth := -1.0
			if not wlev.is_empty():
				var wl := wlev[ChunkSampler.index_at(lp + d * 0.3)]
				if wl > PlanetGenerator.NO_WATER * 0.5 and wl >= alt + 0.05:
					water_depth = wl - alt
			var tid := -1
			var chance := 0.0
			if water_depth > 0.0:
				chance = field.sea_density(water_depth, ground, p, slope)
				tid = field.catalog.get_type("seagrass").id
			else:
				var fu := clampf((u + HALF) / HALF, 0.0, 1.999)
				var fv := clampf((v + HALF) / HALF, 0.0, 1.999)
				var cu := int(fu)
				var cv := int(fv)
				var a := clim[cu + 3 * cv].lerp(clim[cu + 1 + 3 * cv], fu - cu)
				var b := clim[cu + 3 * (cv + 1)].lerp(clim[cu + 1 + 3 * (cv + 1)], fu - cu)
				var m: Vector2 = a.lerp(b, fv - cv)
				var pick := field.choose(ground, m.x, m.y, p, slope, _unit(h, 3), _shade_at(p, rocks))
				tid = int(pick.x)
				chance = pick.y
			if tid < 0 or _unit(h, 4) > chance:
				continue
			var t := field.catalog.by_id(tid)
			# the instance: upright on the ground, turned at random, a little taller or shorter
			var yaw := _unit(h, 5) * TAU
			var bx := d.cross(Vector3.UP if absf(d.y) < 0.95 else Vector3.RIGHT).normalized().rotated(d, yaw)
			var bz := bx.cross(d)
			var height := lerpf(t.height_min, t.height_max, pow(_unit(h, 6), 1.3))
			var s := height / t.height_mid()
			var sw := s * (0.85 + 0.3 * _unit(h, 7))
			var tint := t.base_color if t.underwater else ground.lerp(t.base_color, 0.35)
			var rnd := _unit(h, 8)
			if not bufs.has(tid):
				bufs[tid] = PackedFloat32Array()
				los[tid] = lp
				his[tid] = lp
			var buf: PackedFloat32Array = bufs[tid]
			buf.append_array(PackedFloat32Array([
				bx.x * sw, d.x * s, bz.x * sw, lp.x,
				bx.y * sw, d.y * s, bz.y * sw, lp.y,
				bx.z * sw, d.z * s, bz.z * sw, lp.z,
				tint.r, tint.g, tint.b, rnd]))
			bufs[tid] = buf
			los[tid] = Vector3(minf(los[tid].x, lp.x), minf(los[tid].y, lp.y), minf(los[tid].z, lp.z))
			his[tid] = Vector3(maxf(his[tid].x, lp.x), maxf(his[tid].y, lp.y), maxf(his[tid].z, lp.z))
	for tid in bufs:
		var buf: PackedFloat32Array = bufs[tid]
		var lo: Vector3 = los[tid] - Vector3(1.0, 1.0, 1.0)
		var hi: Vector3 = his[tid] + Vector3(1.0, 1.0, 1.0) + Vector3.ONE * field.catalog.by_id(tid).height_max
		out[tid] = {"buf": buf, "count": buf.size() / STRIDE, "aabb": AABB(lo, hi - lo)}
	return out

## 0..1: how much of a tree's crown shades this spot (the crowns of the chunk's trees, in the plane of the ground).
static func _shade_at(p: Vector3, blockers: Array) -> float:
	var shade := 0.0
	for b in blockers:
		if not ("canopy_r" in b):
			continue
		var off: Vector3 = p - b.pos
		off -= b.up * off.dot(b.up)
		var d := off.length()
		var rc: float = b.canopy_r
		if d < rc:
			shade = maxf(shade, 1.0 - smoothstep(rc * 0.45, rc, d))
	return shade

static func _unit(h: int, n: int) -> float:
	var v := SeedMix.splitmix64(h + n * 0x632BE59B)
	return float((v >> 11) & ((1 << 53) - 1)) / 9007199254740992.0

## Slope (rise over run, 1 = 45 degrees) from the height lattice around a point.
static func _slope(hlat: PackedFloat32Array, l0: Vector3i, p: Vector3, t1: Vector3, t2: Vector3) -> float:
	var e := 1.2
	var gx := (ChunkSampler.lattice_height(hlat, l0, p + t1 * e) - ChunkSampler.lattice_height(hlat, l0, p - t1 * e)) / (2.0 * e)
	var gz := (ChunkSampler.lattice_height(hlat, l0, p + t2 * e) - ChunkSampler.lattice_height(hlat, l0, p - t2 * e)) / (2.0 * e)
	return sqrt(gx * gx + gz * gz)

## The surface along `up` near a local position, or Vector3(-1e9, ...) if there is none within 1.2 m.
static func _find_floor(dens: PackedFloat32Array, lp: Vector3, up: Vector3) -> Vector3:
	var prev_t := 1.2
	var prev_d := ChunkSampler.density(dens, lp + up * prev_t)
	var t := 0.95
	while t >= -1.2:
		var d := ChunkSampler.density(dens, lp + up * t)
		if prev_d < 0.0 and d >= 0.0:
			var lo := t
			var hi := prev_t
			for i in 4:
				var mid := (lo + hi) * 0.5
				if ChunkSampler.density(dens, lp + up * mid) >= 0.0:
					lo = mid
				else:
					hi = mid
			var f := lp + up * ((lo + hi) * 0.5)
			if f.x >= 0.0 and f.y >= 0.0 and f.z >= 0.0 and f.x < S and f.y < S and f.z < S:
				return f
			return Vector3(-1.0e9, 0.0, 0.0)
		prev_t = t
		prev_d = d
		t -= 0.25
	return Vector3(-1.0e9, 0.0, 0.0)
