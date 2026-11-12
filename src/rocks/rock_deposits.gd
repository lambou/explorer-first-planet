class_name RockDeposits
extends RefCounted
## Buried rocks. Under the ground lie bodies of rock (often ore) of every size up to huge, each in a POCKET of exactly its
## shape, so digging never fights them: the hollow is carved into the density field while a chunk is generated, the rock
## sits in it, digging around reveals it, and it falls like any loose rock when its support is gone.
##
## Where: a coarse world grid (CELL metres, seeded). A cell may hold one deposit, at 6-150 m under the natural surface,
## as a smooth ellipsoid in any orientation (power-law size: many small, a few huge). Everything is a function of
## (seed, cell), so nothing is stored.
## INDICATORS: tiny pieces of the deposit's ore lie on the surface above it (more of them, a little bigger, for a bigger
## deposit): a pebble of gold on the grass means a big body of gold below.
## Cost: a few hash lookups per chunk; the carve only looks at the samples inside the deposit's bounding sphere, and
## everything well inside the hollow is set without evaluating the shape.

const CELL := 40.0
const CHANCE := 0.30
const MIN_DEPTH := 6.0
const MAX_DEPTH := 150.0
const POCKET_GAP := 0.12           # the hollow is this much smaller than the rock: the rock hides the wall, no flicker
const ORE_BOOST := 4.0             # buried bodies are more often ore than the loose rocks on the surface
const S := WorldConfig.CHUNK_SIZE
const P := WorldConfig.PADDED
const R := float(WorldConfig.PLANET_RADIUS)

var gen: PlanetGenerator
var field: RockField
var world_seed := 0

func _init(p_gen: PlanetGenerator, p_field: RockField, p_seed: int) -> void:
	gen = p_gen
	field = p_field
	world_seed = p_seed

static func _unit(h: int, n: int) -> float:
	var v := SeedMix.splitmix64(h + n * 0x632BE59B)
	return float((v >> 11) & ((1 << 53) - 1)) / 9007199254740992.0

func _cell_hash(cell: Vector3i) -> int:
	var h := SeedMix.splitmix64(world_seed ^ 0xDE9051)
	h = SeedMix.splitmix64(h + cell.x)
	h = SeedMix.splitmix64(h + cell.y * 1000003)
	return SeedMix.splitmix64(h + cell.z * 998244353)

## Where the deposit of a cell would be (cheap: no terrain lookups), or Vector3.INF when the cell holds none.
func cell_site(cell: Vector3i) -> Vector3:
	var h := _cell_hash(cell)
	if _unit(h, 1) > CHANCE:
		return Vector3.INF
	return (Vector3(cell) + Vector3(_unit(h, 2), _unit(h, 3), _unit(h, 4))) * CELL

## The deposit of a cell, or null. Deterministic.
func deposit_at_cell(cell: Vector3i, col: Column) -> RockInst:
	var pos := cell_site(cell)
	if pos == Vector3.INF:
		return null
	var h := _cell_hash(cell)
	var r := pos.length()
	if r < R - 600.0 or r > R + WorldConfig.MAX_HEIGHT:
		return null
	var d := pos / r
	gen.sample_height(d, col, 1)
	var depth := col.height - (r - R)
	if depth < MIN_DEPTH or depth > MAX_DEPTH or r - R < float(WorldConfig.CAVE_FLOOR) + 20.0:
		return null
	# size: many small, a few huge; never so big that it breaks through the surface
	var size := 1.2 + 9.0 * pow(_unit(h, 5), 3.5)
	size = minf(size, depth / 1.8)
	if size < 0.8:
		return null
	var inst := RockInst.new()
	inst.deposit = true
	inst.pos = pos
	inst.size = size
	var nz := _unit(h, 6) * 2.0 - 1.0
	var a := _unit(h, 7) * TAU
	var rr := sqrt(maxf(0.0, 1.0 - nz * nz))
	inst.normal = Vector3(rr * cos(a), nz, rr * sin(a))          # any orientation
	inst.yaw = _unit(h, 8) * TAU
	inst.shape = int(h & 0x7fffffff)
	inst.id = int(SeedMix.splitmix64(h + 99) & 0x7fffffffffffffff)
	var ctx := {"depth": depth, "alt": r - R, "underwater": col.height < 0.0}
	inst.layers = field.choose(d, pos, ctx, _unit(h, 9), ORE_BOOST)
	inst.fixed = false
	return inst

## Deposits whose bounding sphere touches the padded box of a chunk (they must be carved into its density).
func overlapping(coord: Vector3i) -> Array:
	var out: Array = []
	var origin := Vector3(coord * S)
	var lo := origin - Vector3.ONE * 16.0
	var hi := origin + Vector3.ONE * (S + 16.0)
	var col := Column.new()
	for cx in range(floori(lo.x / CELL), floori(hi.x / CELL) + 1):
		for cy in range(floori(lo.y / CELL), floori(hi.y / CELL) + 1):
			for cz in range(floori(lo.z / CELL), floori(hi.z / CELL) + 1):
				var cell := Vector3i(cx, cy, cz)
				var site := cell_site(cell)
				if site == Vector3.INF or site.x < lo.x or site.y < lo.y or site.z < lo.z or site.x > hi.x or site.y > hi.y or site.z > hi.z:
					continue
				var inst := deposit_at_cell(cell, col)
				if inst == null:
					continue
				var c := inst.pos
				var rad := inst.size * 1.3 + 1.5
				var dx := maxf(maxf(origin.x - 1.0 - c.x, c.x - (origin.x + S + 1.0)), 0.0)
				var dy := maxf(maxf(origin.y - 1.0 - c.y, c.y - (origin.y + S + 1.0)), 0.0)
				var dz := maxf(maxf(origin.z - 1.0 - c.z, c.z - (origin.z + S + 1.0)), 0.0)
				if dx * dx + dy * dy + dz * dz <= rad * rad:
					out.append(inst)
	return out

## Deposits whose CENTRE lies in this chunk: their rock is part of this chunk's rocks.
func owned_by(coord: Vector3i) -> Array:
	var out: Array = []
	var origin := Vector3(coord * S)
	for inst: RockInst in overlapping(coord):
		var l := inst.pos - origin
		if l.x >= 0.0 and l.y >= 0.0 and l.z >= 0.0 and l.x < S and l.y < S and l.z < S:
			out.append(inst)
	return out

## Carve the pocket of a deposit into a chunk's padded density (hollow = negative). `origin`: the chunk's corner.
static func carve_pocket(r: RockInst, origin: Vector3, dens: PackedFloat32Array) -> void:
	var f := RockMesher.frame_of(r)
	var bound := r.size * 1.3
	var inner := minf(minf(f.sx, f.sy), f.sz) * 0.9 - POCKET_GAP - 0.2        # surely inside: no shape evaluation needed
	var rel := r.pos - origin
	var i0 := clampi(floori(rel.x - bound), -1, S)
	var i1 := clampi(ceili(rel.x + bound), -1, S)
	var j0 := clampi(floori(rel.y - bound), -1, S)
	var j1 := clampi(ceili(rel.y + bound), -1, S)
	var k0 := clampi(floori(rel.z - bound), -1, S)
	var k1 := clampi(ceili(rel.z + bound), -1, S)
	for k in range(k0, k1 + 1):
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var q := RockMesher.to_local(r, f, origin + Vector3(i, j, k))
				var l := q.length()
				if l > bound:
					continue
				var v: float
				if l < inner:
					v = -3.0
				else:
					v = clampf(l - (RockMesher.blob_radius(r, f, q / l) - POCKET_GAP), -3.0, 3.0)
				var idx := (i + 1) + P * ((j + 1) + P * (k + 1))
				if v < dens[idx]:
					dens[idx] = v

## Surface indicators of the deposits under a chunk: tiny pieces of the ore on the ground, owned by this chunk.
func markers_for(coord: Vector3i) -> Array:
	var out: Array = []
	var origin := Vector3(coord * S)
	var centre := origin + Vector3.ONE * (S * 0.5)
	var up := centre.normalized()
	var col := Column.new()
	# only chunks that touch the surface carry markers
	gen.sample_height(up, col, 1)
	var alt := centre.length() - R
	if absf(alt - col.height) > 22.0:
		return out
	# deposits whose vertical projection lies near this chunk: the column from just above it down to MAX_DEPTH
	var a := centre + up * 12.0
	var b := centre - up * (MAX_DEPTH + 10.0)
	var lo := Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z)) - Vector3.ONE * 30.0
	var hi := Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z)) + Vector3.ONE * 30.0
	var t1 := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized()
	var t2 := up.cross(t1)
	var scratch := Column.new()
	for cx in range(floori(lo.x / CELL), floori(hi.x / CELL) + 1):
		for cy in range(floori(lo.y / CELL), floori(hi.y / CELL) + 1):
			for cz in range(floori(lo.z / CELL), floori(hi.z / CELL) + 1):
				var cell := Vector3i(cx, cy, cz)
				var site := cell_site(cell)
				if site == Vector3.INF:
					continue
				# cheap filter before touching the terrain: close to the column's axis?
				var rel := site - centre
				var along := rel.dot(up)
				var lateral := (rel - up * along).length()
				if lateral > 28.0 or along > 30.0 or along < -(MAX_DEPTH + 30.0):
					continue
				var dep := deposit_at_cell(cell, scratch)
				if dep == null or dep.layers.size() < 2:
					continue                                  # plain rock bodies give no indicator
				_markers_of(dep, coord, origin, out, scratch)
	return out

func _markers_of(dep: RockInst, coord: Vector3i, origin: Vector3, out: Array, col: Column) -> void:
	var up := dep.pos.normalized()
	var t1 := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized()
	var t2 := up.cross(t1)
	var core := dep.core_type()
	var n := clampi(1 + int(dep.size * 0.9), 1, 6)
	for k in n:
		var hk := SeedMix.splitmix64(dep.id + k * 7919)
		var ang := _unit(hk, 1) * TAU
		var dist := dep.size * (0.15 + 0.85 * _unit(hk, 2))
		var p0 := dep.pos + (t1 * cos(ang) + t2 * sin(ang)) * dist
		var d := p0.normalized()
		gen.sample_height(d, col, 1)
		var psize := minf(0.10 + 0.055 * sqrt(dep.size) * (0.6 + 0.8 * _unit(hk, 3)), 0.45)
		var surface := d * (R + col.height)
		var inst := RockInst.new()
		inst.pos = surface + d * (psize * 0.5)
		inst.normal = d
		inst.size = psize
		inst.yaw = _unit(hk, 4) * TAU
		inst.shape = int(hk & 0x7fffffff)
		inst.layers = [[core, 1.0]]
		inst.id = int(SeedMix.splitmix64(hk + 5) & 0x7fffffffffffffff)
		inst.fixed = false
		var l := inst.pos - origin
		if l.x >= 0.0 and l.y >= 0.0 and l.z >= 0.0 and l.x < S and l.y < S and l.z < S:
			out.append(inst)
