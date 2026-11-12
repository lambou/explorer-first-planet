class_name PlanetGenerator
extends RefCounted
## Runs the layer pipeline. Pure function of the seed (deterministic, thread-safe reads).
## The world is a signed density field sampled on an integer grid:
## density > 0 = solid, < 0 = air, surface at 0 (metres, clamped to +-DMAX).

const R := WorldConfig.PLANET_RADIUS
const S := WorldConfig.CHUNK_SIZE
const P := WorldConfig.PADDED
const DMAX := 3.0
const NO_WATER := -1.0e9
const RIVER_MARK := 0.0007         # added to river water levels: how the mesher tells river from sea (0.0) and cave (+0.002)
const SEA_MARGIN := 0.08            # coast: columns below sea level this close to the shore are sea too

## Is this column covered by the sea (ocean basin, or a flooded coastal depression)?
static func is_sea(land: float, h: float) -> bool:
	return land < 0.0 or (h < 0.0 and land < SEA_MARGIN)

var seed_value: int
var macro_layers: Array[GenLayer] = []
var continents: L01Continents
var climate: L07Climate
var caves: L08Caves
var surface: L09Surface

func _init(p_seed: int) -> void:
	seed_value = p_seed
	continents = L01Continents.new(p_seed)
	macro_layers = [
		continents,
		L02Relief.new(p_seed),
		L03Mountains.new(p_seed),
		L04Islands.new(p_seed),
		L05Canyons.new(p_seed),
		L06Detail.new(p_seed),
	]
	var ground: Array[GenLayer] = []
	ground.assign(macro_layers)
	macro_layers.append(L10Rivers.new(p_seed, ground))
	climate = L07Climate.new(p_seed)
	caves = L08Caves.new(p_seed)
	surface = L09Surface.new(p_seed)

static func fibonacci_dir(i: int, n: int) -> Vector3:
	var y := 1.0 - 2.0 * (i + 0.5) / n
	var r := sqrt(maxf(0.0, 1.0 - y * y))
	var phi := i * 2.399963229728653
	return Vector3(cos(phi) * r, y, sin(phi) * r)

## Geometry layers only (1-6). `step` = cell size in metres (skips features too fine to show).
func sample_height(d: Vector3, col: Column, step: int = 1) -> void:
	for l in macro_layers:
		l.apply(d, col, step)

## Full column including climate (layer 7).
func sample_column(d: Vector3, col: Column, step: int = 1) -> void:
	sample_height(d, col, step)
	climate.apply(d, col, step)

## Density at a grid point. `step` = grid spacing in metres (1 = full detail, 2, 4, 8, 16 = LOD).
## Writes the material into col.material. Values are clamped to +-DMAX*step.
func density_at(x: int, y: int, z: int, col: Column, step: int = 1, with_caves: bool = true) -> float:
	var dm := DMAX * step
	var p := Vector3(x, y, z)
	var r := p.length()
	var rel := r - R
	if rel > WorldConfig.MAX_HEIGHT:
		col.material = BlockTypes.AIR
		col.color = Color.WHITE
		return -dm
	if rel < (float(WorldConfig.CAVE_FLOOR) if step == 1 else -(WorldConfig.MAX_OCEAN_DEPTH + 4.0)):
		col.material = BlockTypes.STONE
		col.color = BlockTypes.COLORS[BlockTypes.STONE]
		return dm
	var d := p / r if r > 0.001 else Vector3.UP
	sample_height(d, col, step)
	var depth := col.height - rel
	var dens := depth
	# caves and sinkholes: full detail only. Without caves (the player is on the surface) only the
	# shallow sinkhole bowls are carved, so deep rock needs no cave noise at all.
	if step == 1 and depth > 0.0 and (with_caves or depth < L08Caves.SINK_BOWL + 4.0 or (depth < L08Caves.COAST_DEPTH + 4.0 and L08Caves.coast_factor(col.land) > 0.05)):
		dens = minf(depth, caves.field(p, d, depth, col, with_caves))
	# climate/material only matters close to the surface; deeper is plain stone
	if depth < 4.0 * step:
		climate.apply(d, col)
		col.material = surface.block_for(col, maxf(depth, 0.0))
		col.color = surface.color_at_depth(col, maxf(depth, 0.0))
	else:
		col.material = BlockTypes.STONE
		col.color = BlockTypes.COLORS[BlockTypes.STONE]
	return clampf(dens, -dm, dm)

## 0 = mixed (must generate), 1 = entirely air, 2 = entirely solid.
func classify_chunk(coord: Vector3i) -> int:
	return classify_node(0, coord)

## Same for an LOD node: lod L covers (16 << L) metres per side.
func classify_node(lod: int, coord: Vector3i) -> int:
	var span := S << lod
	var c := Vector3(coord) * span + Vector3.ONE * (span * 0.5)
	var r := c.length()
	var margin := span * 0.8660254 + 3.0 * (1 << lod)
	if r - margin > R + WorldConfig.MAX_HEIGHT:
		return 1
	# caves only exist at full detail, so coarse nodes are solid right below the ocean floor
	var floor_rel: float = float(WorldConfig.CAVE_FLOOR) if lod == 0 else -(WorldConfig.MAX_OCEAN_DEPTH + 4.0)
	if r + margin < R + floor_rel:
		return 2
	return 0

## Padded (S+2)^3 samples for a node; sample i <-> world position origin + (i-1)*step.
## Returns {dens: PackedFloat32Array, colr: PackedColorArray}.
func fill_chunk(coord: Vector3i, col: Column, lod: int = 0, with_caves: bool = true) -> Dictionary:
	var step := 1 << lod
	var dm := DMAX * step
	var dens := PackedFloat32Array()
	var colr := PackedColorArray()
	dens.resize(P * P * P)
	colr.resize(P * P * P)
	var cls := classify_node(lod, coord)
	if cls == 1 and lod == 0 and absf((Vector3(coord) * S + Vector3.ONE * (S * 0.5)).length() - R) < S * 0.8660254 + 2.0:
		cls = 0                       # air only, but the sea surface may pass through: take the full path
	if cls == 1:
		dens.fill(-dm)
		colr.fill(Color.WHITE)
	elif cls == 2:
		dens.fill(dm)
		colr.fill(BlockTypes.COLORS[BlockTypes.STONE])
	elif lod == 0:
		return _fill_fast(coord, with_caves)
	else:
		var o := coord * (S * step) - Vector3i.ONE * step
		var n := 0
		for k in P:
			for j in P:
				for i in P:
					dens[n] = density_at(o.x + i * step, o.y + j * step, o.z + k * step, col, step, with_caves)
					colr[n] = col.color
					n += 1
	return {"dens": dens, "colr": colr, "wlev": PackedFloat32Array(), "hlat": PackedFloat32Array(), "l0": Vector3i.ZERO}

# ---------- fast path for full-detail chunks ----------
# The macro terrain height only depends on the direction and is smooth, so it is evaluated on a
# coarse world-aligned lattice (every LAT metres) and interpolated: samples that are clearly far
# above or below the ground are filled without touching any noise. The lattice is a pure function
# of world coordinates, so neighbouring chunks agree exactly (no seams).
const LAT := 4
const LN := 7

## [[lattice cell, first sample, end sample], ...] along one axis.
static func _segments(o: int) -> Array:
	var l0 := floori(o / float(LAT))
	var segs: Array = []
	var i := 0
	while i < P:
		var c := floori((o + i) / float(LAT)) - l0
		var j := i
		while j < P and floori((o + j) / float(LAT)) - l0 == c:
			j += 1
		segs.append([c, i, j])
		i = j
	return segs

func _fill_fast(coord: Vector3i, with_caves: bool) -> Dictionary:
	var dm := DMAX
	var dens := PackedFloat32Array()
	var colr := PackedColorArray()
	dens.resize(P * P * P)
	colr.resize(P * P * P)
	dens.fill(-dm)
	var o := coord * S - Vector3i.ONE
	var l0x := floori(o.x / float(LAT))
	var l0y := floori(o.y / float(LAT))
	var l0z := floori(o.z / float(LAT))
	var n3 := LN * LN * LN
	var H := PackedFloat32Array()
	var CF := PackedFloat32Array()     # cave / sinkhole field on the lattice (BIG = no hollow)
	var SE := PackedByteArray()        # 1 = the lattice point lies in a sea column
	var RL := PackedFloat32Array()     # river water level at the lattice point (NO_WATER = none)
	var RF := PackedFloat32Array()     # river channel factor 0..1 at the lattice point
	var any_river := false
	var any_sea := false
	var TC := PackedColorArray()
	var SC := PackedColorArray()
	H.resize(n3)
	CF.resize(n3)
	CF.fill(L08Caves.BIG)
	TC.resize(n3)
	SC.resize(n3)
	SE.resize(n3)
	RL.resize(n3)
	RL.fill(NO_WATER)
	RF.resize(n3)
	var col := Column.new()
	var stone: Color = BlockTypes.COLORS[BlockTypes.STONE]
	# --- coarse lattice: height; colours, sinkholes and caves near / below the ground
	for lz in LN:
		for ly in LN:
			for lx in LN:
				var wp := Vector3((l0x + lx) * LAT, (l0y + ly) * LAT, (l0z + lz) * LAT)
				var r := wp.length()
				var d := wp / r if r > 0.001 else Vector3.UP
				sample_height(d, col, 1)
				var li := lx + LN * (ly + LN * lz)
				var hh := col.height
				H[li] = hh
				if is_sea(col.land, hh):
					SE[li] = 1
					any_sea = true
				elif col.river > 0.0:
					RF[li] = col.river
					RL[li] = col.river_level
					any_river = true
				var depth_l := hh - (r - R)
				var coast_c := L08Caves.coast_factor(col.land)
				if absf(depth_l) < 14.0:
					var sink := caves.sink_inside(d, col)
					climate.apply(d, col)
					TC[li] = surface.color_for(col)
					SC[li] = BlockTypes.COLORS[surface.block_for(col, 2.0)]
					if sink > -0.05 and depth_l > 0.0:
						CF[li] = caves.field(wp, d, depth_l, col, with_caves, -1.0)
				if coast_c > 0.05 and depth_l > 0.0 and (with_caves or depth_l < L08Caves.COAST_DEPTH + 4.0) and r - R > WorldConfig.CAVE_FLOOR:
					CF[li] = minf(CF[li], caves.field(wp, d, depth_l, col, with_caves, -1.0))
				if with_caves and depth_l > L08Caves.SEAL_TOP - 8.0 and r - R > WorldConfig.CAVE_FLOOR:
					var m := caves.region_mask(d, col)
					if m > 0.05:
						CF[li] = minf(CF[li], caves.field(wp, d, depth_l, col, true, m))
	# --- blocks (one lattice cell = up to 4x4x4 samples)
	var segx := _segments(o.x)
	var segy := _segments(o.y)
	var segz := _segments(o.z)
	var LL := LN * LN
	for zs in segz:
		for ys in segy:
			for xs in segx:
				var cx: int = xs[0]
				var cy: int = ys[0]
				var cz: int = zs[0]
				var b := cx + LN * (cy + LN * cz)
				var h000 := H[b]
				var h100 := H[b + 1]
				var h010 := H[b + LN]
				var h110 := H[b + LN + 1]
				var h001 := H[b + LL]
				var h101 := H[b + LL + 1]
				var h011 := H[b + LL + LN]
				var h111 := H[b + LL + LN + 1]
				var hmin := minf(minf(minf(h000, h100), minf(h010, h110)), minf(minf(h001, h101), minf(h011, h111)))
				var hmax := maxf(maxf(maxf(h000, h100), maxf(h010, h110)), maxf(maxf(h001, h101), maxf(h011, h111)))
				var x0: int = xs[1]
				var x1: int = xs[2]
				var y0: int = ys[1]
				var y1: int = ys[2]
				var z0: int = zs[1]
				var z1: int = zs[2]
				# radius range of the block
				var rmin := 1e9
				var rmax := 0.0
				for q in 8:
					var qx := float(o.x + (x1 - 1 if (q & 1) else x0))
					var qy := float(o.y + (y1 - 1 if (q & 2) else y0))
					var qz := float(o.z + (z1 - 1 if (q & 4) else z0))
					var rr := sqrt(qx * qx + qy * qy + qz * qz)
					rmin = minf(rmin, rr)
					rmax = maxf(rmax, rr)
				if rmin - R > hmax + dm + 1.0:
					continue                                   # air (already filled)
				var f000 := CF[b]
				var f100 := CF[b + 1]
				var f010 := CF[b + LN]
				var f110 := CF[b + LN + 1]
				var f001 := CF[b + LL]
				var f101 := CF[b + LL + 1]
				var f011 := CF[b + LL + LN]
				var f111 := CF[b + LL + LN + 1]
				var fmin := minf(minf(minf(f000, f100), minf(f010, f110)), minf(minf(f001, f101), minf(f011, f111)))
				var carve := fmin < L08Caves.BIG * 0.5         # a cave or a sinkhole reaches into this block
				if rmax - R < hmin - dm - 1.0 and not carve:
					# deep rock: solid
					for k in range(z0, z1):
						for j in range(y0, y1):
							var rowi := P * (j + P * k)
							for i in range(x0, x1):
								dens[rowi + i] = dm
								colr[rowi + i] = stone
					continue
				# per-sample: trilinear height (and cave field)
				for k in range(z0, z1):
					var fz := (float(o.z + k) - float((l0z + cz) * LAT)) / LAT
					var h00z0 := h000 + (h001 - h000) * fz
					var h10z0 := h100 + (h101 - h100) * fz
					var h01z0 := h010 + (h011 - h010) * fz
					var h11z0 := h110 + (h111 - h110) * fz
					var c00z0 := f000 + (f001 - f000) * fz
					var c10z0 := f100 + (f101 - f100) * fz
					var c01z0 := f010 + (f011 - f010) * fz
					var c11z0 := f110 + (f111 - f110) * fz
					for j in range(y0, y1):
						var fy := (float(o.y + j) - float((l0y + cy) * LAT)) / LAT
						var ha := h00z0 + (h01z0 - h00z0) * fy
						var hb := h10z0 + (h11z0 - h10z0) * fy
						var ca := c00z0 + (c01z0 - c00z0) * fy
						var cb := c10z0 + (c11z0 - c10z0) * fy
						var rowi := P * (j + P * k)
						for i in range(x0, x1):
							var fx := (float(o.x + i) - float((l0x + cx) * LAT)) / LAT
							var wx := float(o.x + i)
							var wy := float(o.y + j)
							var wz := float(o.z + k)
							var rad := sqrt(wx * wx + wy * wy + wz * wz)
							var depth := ha + (hb - ha) * fx - (rad - R)
							var dd := depth
							if carve and depth > 0.0:
								dd = minf(depth, ca + (cb - ca) * fx)
							dens[rowi + i] = clampf(dd, -dm, dm)
							if depth > -0.5:
								if depth >= 4.0:
									colr[rowi + i] = stone
								else:
									# colour of the nearest lattice corner: smooth top colour over dirt/stone below
									var ci := b + (1 if fx > 0.5 else 0) + (LN if fy > 0.5 else 0) + (LL if fz > 0.5 else 0)
									var top := TC[ci]
									var sub := SC[ci]
									if depth < 0.8:
										colr[rowi + i] = top
									elif depth < 2.0:
										var t := (depth - 0.8) / 1.2
										colr[rowi + i] = top.lerp(sub, t * t * (3.0 - 2.0 * t))
									else:
										var u := (depth - 2.0) / 2.0
										colr[rowi + i] = sub.lerp(stone, u * u * (3.0 - 2.0 * u))
	# --- water levels (sea columns: sea level everywhere, rock included: the surface sheet is clipped by terrain)
	var wlev := PackedFloat32Array()
	if any_sea or any_river:
		wlev.resize(P * P * P)
		wlev.fill(NO_WATER)
		for zs in segz:
			for ys in segy:
				for xs in segx:
					var cx0: int = int(xs[0])
					var cy0: int = int(ys[0])
					var cz0: int = int(zs[0])
					var bb: int = cx0 + LN * (cy0 + LN * cz0)
					var cidx := [bb, bb + 1, bb + LN, bb + LN + 1, bb + LL, bb + LL + 1, bb + LL + LN, bb + LL + LN + 1]
					var sea_n := 0
					var riv_n := 0
					var riv_sum := 0.0
					var rf := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
					for q in 8:
						var ci: int = cidx[q]
						if SE[ci] == 1:
							sea_n += 1
						elif RL[ci] > NO_WATER * 0.5:
							riv_n += 1
							riv_sum += RL[ci]
							rf[q] = RF[ci]
					if sea_n == 0 and riv_n == 0:
						continue
					if sea_n > 0:
						for k in range(int(zs[1]), int(zs[2])):
							for j in range(int(ys[1]), int(ys[2])):
								var rw := P * (j + P * k)
								for i in range(int(xs[1]), int(xs[2])):
									wlev[rw + i] = 0.0
						continue
					# river block: the level is the block's mean (snapped: it carries the river marker),
					# the extent follows the channel factor interpolated per sample, so the edge is smooth
					var rlevel := snappedf(riv_sum / riv_n, 0.01) + RIVER_MARK
					for k in range(int(zs[1]), int(zs[2])):
						var fz := (float(o.z + k) - float((l0z + cz0) * LAT)) / LAT
						for j in range(int(ys[1]), int(ys[2])):
							var fy := (float(o.y + j) - float((l0y + cy0) * LAT)) / LAT
							var rw2 := P * (j + P * k)
							for i in range(int(xs[1]), int(xs[2])):
								var fx := (float(o.x + i) - float((l0x + cx0) * LAT)) / LAT
								var c00 := lerpf(rf[0], rf[1], fx)
								var c10 := lerpf(rf[2], rf[3], fx)
								var c01 := lerpf(rf[4], rf[5], fx)
								var c11 := lerpf(rf[6], rf[7], fx)
								var fac := lerpf(lerpf(c00, c10, fy), lerpf(c01, c11, fy), fz)
								if fac > 0.12:
									wlev[rw2 + i] = rlevel
	return {"dens": dens, "colr": colr, "wlev": wlev, "hlat": H, "l0": Vector3i(l0x, l0y, l0z)}

var _bounds_cache: Dictionary = {}
var _water_chunk_cache: Dictionary = {}

## A full-detail chunk that the sea surface passes through (sea level inside it, over a sea column).
## Such chunks are needed even when they hold only air, because the water surface lives in them.
## Main thread only (cached).
func is_water_chunk(c: Vector3i) -> bool:
	if _water_chunk_cache.has(c):
		return _water_chunk_cache[c]
	var lo := Vector3(c) * S
	var res := false
	var rc := (lo + Vector3.ONE * (S * 0.5)).length()
	if absf(rc - R) < S * 0.8660254 + 2.0:
		var col := Column.new()
		for i in 9:
			var p := lo + (Vector3((i & 1) * S, ((i >> 1) & 1) * S, ((i >> 2) & 1) * S) if i < 8 else Vector3.ONE * (S * 0.5))
			var r := p.length()
			if r > 1.0:
				sample_height(p / r, col, 1)
				if is_sea(col.land, col.height):
					res = true
					break
	_water_chunk_cache[c] = res
	return res

## Refined classification (main thread only, cached): samples the real terrain height over
## the node's footprint, so nodes far above or far below the actual ground are skipped
## instead of every node between the highest peak and the deepest trench.
## 0 = mixed, 1 = air, 2 = solid (below ground, ignoring caves: callers decide).
func classify_node_fine(lod: int, coord: Vector3i) -> int:
	var c := classify_node(lod, coord)
	if c != 0:
		return c
	var key := Vector4i(coord.x, coord.y, coord.z, lod)
	if _bounds_cache.has(key):
		return _bounds_cache[key]
	var step := 1 << lod
	var span := S << lod
	var lo := Vector3(coord) * span
	var col := Column.new()
	var hmin := 1e9
	var hmax := -1e9
	var rmin := 1e9
	var rmax := 0.0
	# full-detail chunks: 9 samples (corners + centre) are enough for the coarse test, the finer test follows
	var npts := 9 if lod == 0 else 27
	for i in npts:
		var p: Vector3
		if lod == 0:
			p = lo + (Vector3((i & 1) * span, ((i >> 1) & 1) * span, ((i >> 2) & 1) * span) if i < 8 else Vector3.ONE * (span * 0.5))
		else:
			p = lo + Vector3(i % 3, (i / 3.0) as int % 3, (i / 9.0) as int) * (span * 0.5)
		var r := p.length()
		rmin = minf(rmin, r)
		rmax = maxf(rmax, r)
		if r > 0.001:
			sample_height(p / r, col, step)
			hmin = minf(hmin, col.height)
			hmax = maxf(hmax, col.height)
	var slack := 0.3 * (hmax - hmin) + 60.0 + 4.0 * step
	var slack_down := slack + L05Canyons.CUT
	if lod == 0:
		# full-detail chunks: tight band around the ground (samples are 8 m apart, canyons are wider)
		slack = 0.3 * (hmax - hmin) + 8.0
		slack_down = slack
	var res := 0
	if rmin - R > hmax + slack:
		res = 1
	elif rmax - R < hmin - slack_down:
		res = 2
	if lod == 0 and res == 0:
		res = _refine_full_detail(lo)
	_bounds_cache[key] = res
	return res

## Second, finer test for a full-detail chunk that the coarse test could not rule out:
## 5x5x5 height samples (4 m apart) bound the ground tightly, so only chunks that really
## contain the surface remain (no rock below it, no air above it).
func _refine_full_detail(lo: Vector3) -> int:
	var col := Column.new()
	var hmin := 1e9
	var hmax := -1e9
	var rmin := 1e9
	var rmax := 0.0
	for i in 64:
		var p := lo + Vector3(i % 4, (i / 4.0) as int % 4, (i / 16.0) as int) * (S / 3.0)
		var r := p.length()
		rmin = minf(rmin, r)
		rmax = maxf(rmax, r)
		if r > 0.001:
			sample_height(p / r, col, 1)
			hmin = minf(hmin, col.height)
			hmax = maxf(hmax, col.height)
	var slack := 0.15 * (hmax - hmin) + 4.0
	if rmin - R > hmax + slack:
		return 1
	if rmax - R < hmin - slack:
		return 2
	return 0

## A spot on the FLOOR of a real cave room (hollow all around, solid ground below, headroom above), as a position
## for the ball. Searches outward from `from_dir` (a direction on the planet; ZERO = anywhere), so asking from
## where the player stands finds the nearest cave. `open_sky`: only caves with a shaft to the sky (the floor of a
## sinkhole), where daylight reaches; false = a closed room (pitch dark). Returns Vector3.ZERO when none is found.
func find_cave_spawn(from_dir: Vector3 = Vector3.ZERO, open_sky: bool = false) -> Vector3:
	var n := 6000
	var order: Array = []
	for i in n:
		order.append([fibonacci_dir(i, n).angle_to(from_dir) if from_dir != Vector3.ZERO else float(i), i])
	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var col := Column.new()
	var scratch := Column.new()
	for e in order:
		var d := fibonacci_dir(e[1], n)
		sample_height(d, col)
		if col.land < 0.08 or col.height < (20.0 if open_sky else 45.0):
			continue
		if open_sky:
			if caves.sink_inside(d, col) <= 0.0:
				continue                              # the shaft to the sky is a sinkhole
		elif caves.region_mask(d, col) < 0.6:
			continue
		var top := col.height
		var depth := 6.0 if open_sky else 36.0
		while depth < top + float(-WorldConfig.CAVE_FLOOR) - 30.0 and depth < 320.0:
			var p := d * (R + top - depth)
			if _cave_air(p, scratch) and _cave_room(p, d, scratch, 3.0 if open_sky else 4.0) and (not open_sky or _sky_shaft(p, d, depth, scratch)):
				# walk down to the floor, then stand the ball on it
				var k := 1
				while k <= 12 and _cave_air(p - d * float(k), scratch):
					k += 1
				if k <= 12:
					return p - d * (float(k) - 0.5) + d * 1.5
			depth += 3.0
	return Vector3.ZERO

func _cave_air(p: Vector3, scratch: Column) -> bool:
	return density_at(roundi(p.x), roundi(p.y), roundi(p.z), scratch, 1, true) < 0.0

## Open to the sky: straight up from `p` every sample is hollow until the surface (`depth` metres above).
func _sky_shaft(p: Vector3, d: Vector3, depth: float, scratch: Column) -> bool:
	var h := 2.0
	while h <= depth + 4.0:
		if not _cave_air(p + d * h, scratch):
			return false
		h += 2.0
	return true

## Enough room around a hollow point for the ball and the camera: hollow `side` m to each side and 3 m up.
func _cave_room(p: Vector3, d: Vector3, scratch: Column, side: float = 4.0) -> bool:
	var t1 := d.cross(Vector3.UP).normalized()
	var t2 := d.cross(t1)
	for off: Vector3 in [t1 * side, -t1 * side, t2 * side, -t2 * side, d * 3.0]:
		if not _cave_air(p + off, scratch):
			return false
	return true

func find_spawn() -> Vector3:
	var col := Column.new()
	var best := Vector3.ZERO
	var best_score := -1e9
	for i in 6000:
		var d := fibonacci_dir(i, 6000)
		sample_column(d, col)
		if col.land > 0.08 and col.height >= 40.0 and col.height <= 200.0 and absf(d.y) < 0.5:
			return d * (R + col.height + 4.0)
		var score := col.height if col.land > 0.0 else -1000.0
		if score > best_score:
			best_score = score
			best = d * (R + col.height + 4.0)
	return best
