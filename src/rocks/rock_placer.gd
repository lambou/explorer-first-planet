class_name RockPlacer
extends RefCounted
## Decides which rocks lie in one chunk. Deterministic: a function of (world seed, chunk coordinate) and the
## chunk's NATURAL density field, so nothing needs to be stored and the same world always has the same rocks.
##
## Per chunk: a few candidate points are drawn inside it, each is dropped onto the floor below it (the first
## solid surface found going down along the local "up" in the density field), which makes land, sea bed and
## cave floors work with the same code. A point is kept when the floor is not too steep. Then the geology
## (RockField) decides what the rock is made of and a size class how big it is.
## Runs on the worker thread together with the chunk build; costs a few dozen density lookups per chunk.

const S := WorldConfig.CHUNK_SIZE
const P := WorldConfig.PADDED
const ATTEMPTS := 9                 # candidate points per chunk at richness 1
const REACH := 5.0                  # how far above / below the candidate the floor is looked for
const MIN_UP := 0.5                 # the floor may not be steeper than this (dot with up)

## `dens`: the chunk's padded natural density (positive = solid). `wlev`: its water levels (empty = no water).
## Returns Array[RockInst] with world positions inside the chunk.
static func place(gen: PlanetGenerator, field: RockField, coord: Vector3i, dens: PackedFloat32Array, wlev: PackedFloat32Array) -> Array:
	var out: Array = []
	if dens.is_empty():
		return out
	# nothing to do in a chunk that is all air or all rock
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
	var up := centre.normalized()
	var richness := field.richness(up)
	var col := Column.new()
	var attempts := roundi(ATTEMPTS * richness)
	var base := _hash(field.world_seed, coord)
	for k in attempts:
		var h := SeedMix.splitmix64(base + k * 7919)
		var lp := Vector3(_unit(h, 1), _unit(h, 2), _unit(h, 3)) * float(S)
		var floor_p := _drop(dens, lp, up)
		if floor_p.x < -1.0e8:
			continue
		var n := _normal(dens, floor_p)
		if n.dot(up) < MIN_UP:
			continue
		# size class: many pebbles, some rocks, few boulders, rare massive ones
		var cls := _unit(h, 4)
		var size: float
		var u := _unit(h, 5)
		if cls < 0.55:
			size = 0.18 + 0.32 * u
		elif cls < 0.88:
			size = 0.5 + 0.7 * u
		elif cls < 0.985:
			size = 1.3 + 1.5 * u
		else:
			size = 3.0 + 3.0 * u
		# a rock is either LOOSE (it rests on the floor: a rigid body that falls when its support is dug away) or FIXED
		# (sunk deep into the floor, bending it: it stays). Big ones and ones on slopes are more often fixed.
		var fixed := size >= 0.4 and (_unit(h, 9) < clampf(0.15 + 0.10 * size, 0.0, 0.8) or n.dot(up) < 0.78)     # a pebble cannot bend the floor
		var wp := origin + floor_p + n * (size * (0.30 if fixed else 0.55))
		var local := wp - origin
		if local.x < 0.0 or local.y < 0.0 or local.z < 0.0 or local.x >= S or local.y >= S or local.z >= S:
			continue                                          # it belongs to the chunk it lies in
		var overlaps := false
		for o: RockInst in out:
			if o.pos.distance_to(wp) < (o.size + size) * 0.9:
				overlaps = true
				break
		if overlaps:
			continue
		# what it is made of
		var d := wp.normalized()
		gen.sample_height(d, col)
		var alt := wp.length() - WorldConfig.PLANET_RADIUS
		var depth := maxf(col.height - alt, 0.0)
		var uw := _water_at(wlev, floor_p, alt)
		var ctx := {"depth": depth, "alt": alt, "underwater": uw}
		var r := _unit(h, 6)
		var inst := RockInst.new()
		inst.layers = field.choose(d, wp, ctx, r)
		# ores are smaller, rich ones a little bigger: the size never exceeds what its rarity allows
		if inst.layers.size() > 1:
			size = minf(size, 0.9 + 1.2 * _unit(h, 7))
		inst.size = size
		inst.pos = wp
		inst.normal = n
		inst.yaw = _unit(h, 8) * TAU
		inst.fixed = fixed
		inst.shape = int(h & 0x7fffffff)
		inst.id = int(SeedMix.splitmix64(h + 31) & 0x7fffffffffffffff)
		out.append(inst)
	return out

static func _hash(world_seed: int, c: Vector3i) -> int:
	var h := SeedMix.splitmix64(world_seed ^ 0x0A0C5)
	h = SeedMix.splitmix64(h + c.x)
	h = SeedMix.splitmix64(h + c.y * 1000003)
	return SeedMix.splitmix64(h + c.z * 998244353)

static func _unit(h: int, n: int) -> float:
	var v := SeedMix.splitmix64(h + n * 0x632BE59B)
	return float((v >> 11) & ((1 << 53) - 1)) / 9007199254740992.0

## Local position of the floor below candidate `lp` (first transition air -> solid going down), or (-1e9, ...).
static func _drop(dens: PackedFloat32Array, lp: Vector3, up: Vector3) -> Vector3:
	var prev_t := REACH
	var prev_d := _sample(dens, lp + up * prev_t)
	var t := REACH - 0.5
	while t >= -REACH:
		var d := _sample(dens, lp + up * t)
		if prev_d < 0.0 and d >= 0.0:
			# bisect the crossing
			var lo := t
			var hi := prev_t
			for i in 5:
				var mid := (lo + hi) * 0.5
				if _sample(dens, lp + up * mid) >= 0.0:
					lo = mid
				else:
					hi = mid
			return lp + up * ((lo + hi) * 0.5)
		prev_t = t
		prev_d = d
		t -= 0.5
	return Vector3(-1.0e9, 0.0, 0.0)

## Trilinear density at a local position; positions are clamped into the padded block.
static func _sample(dens: PackedFloat32Array, p: Vector3) -> float:
	var x := clampf(p.x, -0.999, S - 0.001)
	var y := clampf(p.y, -0.999, S - 0.001)
	var z := clampf(p.z, -0.999, S - 0.001)
	var ix := floori(x)
	var iy := floori(y)
	var iz := floori(z)
	var fx := x - ix
	var fy := y - iy
	var fz := z - iz
	var b := (ix + 1) + P * ((iy + 1) + P * (iz + 1))
	var c000 := dens[b]
	var c100 := dens[b + 1]
	var c010 := dens[b + P]
	var c110 := dens[b + P + 1]
	var c001 := dens[b + P * P]
	var c101 := dens[b + P * P + 1]
	var c011 := dens[b + P * P + P]
	var c111 := dens[b + P * P + P + 1]
	return lerpf(lerpf(lerpf(c000, c100, fx), lerpf(c010, c110, fx), fy), lerpf(lerpf(c001, c101, fx), lerpf(c011, c111, fx), fy), fz)

## The ground's outward normal at a local position (minus the density gradient).
static func _normal(dens: PackedFloat32Array, p: Vector3) -> Vector3:
	var e := 0.7
	var g := Vector3(
		_sample(dens, p + Vector3(e, 0, 0)) - _sample(dens, p - Vector3(e, 0, 0)),
		_sample(dens, p + Vector3(0, e, 0)) - _sample(dens, p - Vector3(0, e, 0)),
		_sample(dens, p + Vector3(0, 0, e)) - _sample(dens, p - Vector3(0, 0, e)))
	if g.length() < 0.0001:
		return Vector3.UP
	return (-g).normalized()

static func _water_at(wlev: PackedFloat32Array, lp: Vector3, alt: float) -> bool:
	if wlev.is_empty():
		return false
	var ix := clampi(floori(lp.x), -1, S)
	var iy := clampi(floori(lp.y), -1, S)
	var iz := clampi(floori(lp.z), -1, S)
	var w := wlev[(ix + 1) + P * ((iy + 1) + P * (iz + 1))]
	return w > PlanetGenerator.NO_WATER * 0.5 and w >= alt
