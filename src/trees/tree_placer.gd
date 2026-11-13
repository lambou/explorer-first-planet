class_name TreePlacer
extends RefCounted
## Plants the trees of one chunk. Deterministic (seed + chunk), done on the worker thread with the chunk build, like the grass: a jittered
## grid of planting cells on the tangent plane, each dropped on the natural ground with the chunk's height lattice, checked against the
## chunk's real density, and the field decides the species (or none). Only trees whose foot lies inside the chunk are kept, so
## every tree belongs to exactly one chunk. A forest is a short spacing and a high chance; a clearing is a low chance.

const S := WorldConfig.CHUNK_SIZE
const R := float(WorldConfig.PLANET_RADIUS)
const CELL := 4.8                  # planting cell (metres): a dense forest has a tree about every 4.8 m (open enough to see the ground and the light)
const HALF := 12.0

static func place(gen: PlanetGenerator, field: TreeField, coord: Vector3i, dens: PackedFloat32Array, colr: PackedColorArray,
		wlev: PackedFloat32Array, hlat: PackedFloat32Array, l0: Vector3i) -> Array:
	var out: Array = []
	if dens.is_empty() or hlat.is_empty():
		return out
	var origin := Vector3(coord * S)
	var centre := origin + Vector3.ONE * (S * 0.5)
	var alt_c := centre.length() - R
	# quick reject: far from the surface (the chunk is deep underground or in the sky)
	var col := Column.new()
	gen.sample_height(centre.normalized(), col)
	if absf(alt_c - col.height) > 26.0 or col.height < 0.5 or col.land < 0.02:
		return out
	var up_c := centre.normalized()
	var t1 := up_c.cross(Vector3.UP if absf(up_c.y) < 0.95 else Vector3.RIGHT).normalized()
	var t2 := up_c.cross(t1)
	# climate on a 3x3 grid over the footprint, interpolated per cell
	var clim := PackedVector2Array()
	for gv in 3:
		for gu in 3:
			var pg := centre + t1 * (-HALF + gu * HALF) + t2 * (-HALF + gv * HALF)
			gen.sample_column(pg.normalized(), col)
			clim.append(Vector2(col.temperature, col.moisture))
	var base := SeedMix.splitmix64(field.world_seed ^ 0x7BEE)
	base = SeedMix.splitmix64(base + coord.x)
	base = SeedMix.splitmix64(base + coord.y * 1000003)
	base = SeedMix.splitmix64(base + coord.z * 998244353)
	var n := int(ceil(2.0 * HALF / CELL))
	for iv in n:
		for iu in n:
			var h := SeedMix.splitmix64(base + iu * 7349 + iv * 913)
			# jitter inside the middle 70% of the cell: trees keep a fair distance from each other
			var u := -HALF + (iu + 0.15 + 0.7 * _unit(h, 1)) * CELL
			var v := -HALF + (iv + 0.15 + 0.7 * _unit(h, 2)) * CELL
			var p0 := centre + t1 * u + t2 * v
			var d := p0.normalized()
			var p := d * (R + ChunkSampler.lattice_height(hlat, l0, p0))
			var lp := p - origin
			if lp.x < 0.0 or lp.y < 0.0 or lp.z < 0.0 or lp.x >= S or lp.y >= S or lp.z >= S:
				continue
			if not (ChunkSampler.density(dens, lp - d * 0.3) > 0.0 and ChunkSampler.density(dens, lp + d * 0.35) < 0.0):
				var fl := GrassPlacer._find_floor(dens, lp, d)
				if fl.x < -1.0e8:
					continue
				lp = fl
				p = origin + lp
				d = p.normalized()
			var alt := p.length() - R
			# not under water
			if not wlev.is_empty():
				var wl := wlev[ChunkSampler.index_at(lp + d * 0.5)]
				if wl > PlanetGenerator.NO_WATER * 0.5 and wl >= alt - 0.2:
					continue
			var ci := ChunkSampler.index_at(lp - d * 0.7)
			var ground: Color = colr[ci] if ci < colr.size() else Color(0.4, 0.6, 0.3)
			var slope := GrassPlacer._slope(hlat, l0, p, t1, t2)
			var fu := clampf((u + HALF) / HALF, 0.0, 1.999)
			var fv := clampf((v + HALF) / HALF, 0.0, 1.999)
			var cu := int(fu)
			var cv := int(fv)
			var a := clim[cu + 3 * cv].lerp(clim[cu + 1 + 3 * cv], fu - cu)
			var b := clim[cu + 3 * (cv + 1)].lerp(clim[cu + 1 + 3 * (cv + 1)], fu - cu)
			var m: Vector2 = a.lerp(b, fv - cv)
			var pick := field.choose(ground, m.x, m.y, alt, p, slope, _unit(h, 3))
			if pick.x < 0.0 or _unit(h, 4) > pick.y:
				continue
			var t := field.catalog.by_id(int(pick.x))
			var tr := TreeInst.new()
			tr.type_id = t.id
			tr.pos = p
			tr.up = d
			tr.height = lerpf(t.h_min, t.h_max, pow(_unit(h, 5), 1.2))
			tr.trunk_r = tr.height * t.trunk_ratio * (0.85 + 0.3 * _unit(h, 6))
			tr.canopy_r = tr.height * t.canopy_ratio * 0.88 * (0.85 + 0.3 * _unit(h, 7))
			tr.yaw = _unit(h, 8) * TAU
			tr.shape = int(h & 0x7fffffff)
			tr.id = int(SeedMix.splitmix64(h + 1234567) & 0x7fffffffffffffff)
			tr.size = tr.trunk_r * 1.2 + 0.25
			out.append(tr)
	return out

static func _unit(h: int, k: int) -> float:
	var v := SeedMix.splitmix64(h + k * 0x632BE59B)
	return float((v >> 11) & ((1 << 53) - 1)) / 9007199254740992.0
