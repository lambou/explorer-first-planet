class_name RockSystem
extends RefCounted
## Owner of everything about rocks (like WaterSystem for water): the catalog of rock types of this world, the
## geology, the placement and baking per chunk, and what has been broken or chipped. What a blow yields is reported to the caller
## (see Harvester); nothing is kept here.
## The rest of the game talks to rocks only through this class and the per-chunk data it hands out.
## See docs/ROCKS_PLAN.md for the rules (cheap by design: one baked mesh per chunk, built on the worker thread).

const UNITS_PER_AREA := 3.0       # harvest units of a 1 m rock
const MAX_BITES := 48             # bites kept per rock (blows on the same spot widen one bite)
const LAST_LEFT := 0.2             # the last blow finds a chunky piece (about a fifth of the rock) to remove, never a tiny stump
const MIN_LEFT := 0.08            # a rock with less than this left of it is gone (never a tiny stump)
const TOLERANCE := 0.06           # how much more rock than "blows left" may remain before the bite digs on
const DIG_ON_MIN_CENTRE := 0.35  # a bite that digs on stops when its centre is this close (x size) to the rock's centre
const TOL_LOW := 0.03             # ... and how much less may remain (a bite that takes more is cut back)

var gen: PlanetGenerator
var catalog: RockCatalog
var field: RockField
var deposits: RockDeposits
## The only things stored about rocks: id -> true (broken) or {"layers", "size", "hits"} (chipped: its shell is gone).
var changed := {}
var moved_index := {}             # chunk coord -> ids of rocks that were displaced and now lie there (their state is in `changed`)

func setup(p_gen: PlanetGenerator, world_seed: int) -> void:
	gen = p_gen
	catalog = RockCatalog.new(world_seed)
	field = RockField.new(catalog, world_seed)
	deposits = RockDeposits.new(p_gen, field, world_seed)

## Carve the pockets of the buried deposits into a freshly generated chunk's density (underground chunks only).
func carve_chunk(coord: Vector3i, dens: PackedFloat32Array) -> void:
	var origin := Vector3(coord * WorldConfig.CHUNK_SIZE)
	for dep: RockInst in deposits.overlapping(coord):
		RockDeposits.carve_pocket(dep, origin, dens)

## A copy for worker threads (they must never read the live dictionary while the main thread writes it).
func broken_snapshot() -> Dictionary:
	var snap := changed.duplicate(true)
	snap["@moved"] = moved_index.duplicate(true)
	return snap

## A rock came to rest somewhere else: remember where (the state of the rock itself is stored), and in which chunk.
func relocate(r: RockInst) -> void:
	r.moved = true
	_unindex(r.id)
	changed[r.id] = {"state": r.to_state()}
	var c := VoxelWorld.world_to_chunk(r.pos)
	if not moved_index.has(c):
		moved_index[c] = []
	moved_index[c].append(r.id)

func _unindex(id: int) -> void:
	for c in moved_index:
		(moved_index[c] as Array).erase(id)

## What to remember about a rock the player has touched.
func _entry(r: RockInst) -> Dictionary:
	if r.moved:
		return {"state": r.to_state()}
	return {"layers": r.layers.duplicate(true), "size": r.size, "hits": r.hits, "bites": r.bites.duplicate()}

## The rocks of one chunk and their baked mesh. Safe on a worker thread.
## base_dens: natural density (rocks lie on the natural ground); dens: current density (for the sky exposure).
func build_chunk(coord: Vector3i, base_dens: PackedFloat32Array, wlev: PackedFloat32Array, dens: PackedFloat32Array, changed_snap: Dictionary, underground: bool = false) -> Dictionary:
	var all := RockPlacer.place(gen, field, coord, base_dens, wlev)
	all.append_array(deposits.markers_for(coord))            # tiny ore pieces on the surface above a deposit
	if underground:
		all.append_array(deposits.owned_by(coord))            # the buried bodies themselves (their pockets are carved in)
	var rocks: Array = []
	for r: RockInst in all:
		if changed_snap.has(r.id):
			var m = changed_snap[r.id]
			if m is Dictionary and m.has("state"):
				continue                                      # it was displaced: it is added where it lies now (below)
			if m is Dictionary:
				r.layers = m.layers
				r.size = m.size
				r.hits = m.hits
				r.bites = m.get("bites", [])
				r.wear = clampf(r.hits / layer_hardness(r), 0.0, 1.0)
			else:
				continue                                  # broken
		rocks.append(r)
	# rocks that fell and now lie in this chunk
	var ids: Array = changed_snap.get("@moved", {}).get(coord, [])
	for id in ids:
		var m2 = changed_snap.get(id)
		if m2 is Dictionary and m2.has("state"):
			rocks.append(RockInst.from_state(m2.state))
	for r: RockInst in rocks:
		if not r.bites.is_empty():
			r.cut = RockCut.build(r, catalog)             # a chunk that holds a bitten rock builds its re-meshed shape here (worker thread)
			r.cut_sig = r.bites.hash()
	var origin := Vector3(coord * WorldConfig.CHUNK_SIZE)
	return {"rocks": rocks, "mesh": RockMesher.bake(rocks, catalog, origin, dens, base_dens)}

# ---------------------------------------------------------------- breaking

## Hits needed for the OUTER layer of a rock (its shell, or the whole rock when it has one layer).
func layer_hardness(r: RockInst) -> float:
	var t := catalog.by_id(r.layers[0][0])
	var core_vol := 0.0
	if r.layers.size() > 1:
		core_vol = pow(float(r.layers[1][1]), 3.0)
	# blows = solidity x volume-ish: size ^ 2.4 (a 5 m boulder takes ~250x a 0.5 m rock), never less than one blow
	return maxf(1.0, t.hardness * (1.0 - core_vol) * pow(r.size, 2.4) * 1.6)

## Harvest units of the outer layer.
func layer_units(r: RockInst) -> int:
	var core_vol := 0.0
	if r.layers.size() > 1:
		core_vol = pow(float(r.layers[1][1]), 3.0)
	return maxi(1, roundi(r.size * r.size * UNITS_PER_AREA * (1.0 - core_vol)))

## One blow on a rock (`power` hits). Returns {"event": "hit" | "shed" | "broken", "type": key of the outer layer,
## "units": harvested (0 unless something came off), "colors": colours of the flying pieces}.
## "shed": the outer shell broke off and the core is left (smaller). "broken": the rock is gone.
## The caller re-bakes the chunk's rock mesh afterwards (rocks is the chunk's live array).
func hit(r: RockInst, rocks: Array, power: float = 1.0, point: Vector3 = Vector3.INF) -> Dictionary:
	r.hits += power
	var t := catalog.by_id(r.layers[0][0])
	var out := {"event": "hit", "type": t.key, "units": 0, "colors": [t.color]}
	var need := layer_hardness(r)
	var done := r.hits >= need
	if not done:
		r.wear = clampf(r.hits / need, 0.0, 1.0)
		if point != Vector3.INF:
			var before := r.bites.duplicate()
			var idx := _add_bite(r, point)
			var merged := before.size() == r.bites.size()
			var full: Vector4 = r.bites[idx]
			var start: Vector4 = before[idx] if merged else Vector4(full.x, full.y, full.z, 0.0)
			# coherence: what is left of the rock follows the blows left.
			var expected := 1.0 - r.wear * (1.0 - LAST_LEFT)         # the blows left decide how much rock is left, but never less than LAST_LEFT before the last blow
			var samples := RockMesher.solid_samples(r)                   # the unbitten rock's points: built once, the loops below only test bites
			var left := RockMesher.volume_fraction(r, samples)
			if left < expected - TOL_LOW:
				# the bite took too much (the blow landed where it cut deep): take only part of it
				var lo := 0.0
				var hi := 1.0
				for k in 6:
					var mid := (lo + hi) * 0.5
					r.bites[idx] = start.lerp(full, mid)
					if RockMesher.volume_fraction(r, samples) < expected - TOL_LOW:
						hi = mid
					else:
						lo = mid
				r.bites[idx] = start.lerp(full, lo)
			var tries := 0
			while tries < 25 and RockMesher.volume_fraction(r, samples) > expected + TOLERANCE:
				# it took too little (nothing much to take there, or a crater already through): it digs on
				var b: Vector4 = r.bites[idx]
				var c := Vector3(b.x, b.y, b.z)
				if c.length() < DIG_ON_MIN_CENTRE * r.size:
					break                                      # a bite never digs on into the core: the measure counts a hollow as solid, so it would leave a thin shell
				c -= c.normalized() * (0.03 * b.w)
				r.bites[idx] = Vector4(c.x, c.y, c.z, minf(maxf(b.w, 0.05) * 1.07, r.size * 2.2))
				tries += 1
			done = RockMesher.volume_fraction(r, samples) < MIN_LEFT         # carved right through: nothing left worth keeping
	if not done:
		changed[r.id] = _entry(r)
		return out
	var units := layer_units(r)
	out.units = units
	if r.layers.size() > 1:
		# the shell comes off: what is left is the core, a smaller rock
		var core_frac: float = r.layers[1][1]
		r.layers = [[r.layers[1][0], 1.0]]
		r.size *= core_frac
		r.hits = 0.0
		r.wear = 0.0
		r.bites = []
		r.cut = {}
		changed[r.id] = _entry(r)
		out.event = "shed"
		out.colors = [t.color, catalog.by_id(r.layers[0][0]).color]
	else:
		changed[r.id] = true
		_unindex(r.id)
		rocks.erase(r)
		out.event = "broken"
	return out

## Radius of the bite one blow takes. Chosen so that the blows a rock needs add up to the rock: the bigger or the harder
## the rock, the more (smaller) bites it takes, and the last blow finds only a remnant to remove.
func bite_radius(r: RockInst) -> float:
	return clampf(0.9 * r.size / pow(maxf(layer_hardness(r), 1.0), 1.0 / 3.0), 0.1, r.size * 1.5)

## A blow takes a round bite out of the rock at the point it hit, like digging the ground. A blow on an existing bite
## widens and sinks it.
func _add_bite(r: RockInst, point: Vector3) -> int:
	var f := RockMesher.frame_of(r)
	var p := RockMesher.to_local(r, f, point)
	var n := p.normalized() if p.length() > 0.001 else Vector3.UP
	var rho := bite_radius(r)
	var c := p - n * (0.45 * rho)
	for i in r.bites.size():
		var b: Vector4 = r.bites[i]
		if Vector3(b.x, b.y, b.z).distance_to(c) < 0.7 * maxf(rho, b.w):
			# the same spot: the crater sinks by a quarter of a bite and widens to still cover what it had taken
			var shift := 0.25 * rho
			var nw := minf(maxf(pow(b.w * b.w * b.w + rho * rho * rho, 1.0 / 3.0), b.w + shift), r.size * 2.2)
			var nc := Vector3(b.x, b.y, b.z)
			if nw >= b.w + shift:                     # a capped (full-size) bite cannot move: it would un-carve its edge
				nc -= n * shift
			r.bites[i] = Vector4(nc.x, nc.y, nc.z, nw)
			return i
	if r.bites.size() >= MAX_BITES:
		r.bites.remove_at(0)
	r.bites.append(Vector4(c.x, c.y, c.z, rho))
	return r.bites.size() - 1

# ---------------------------------------------------------------- picking

## The nearest rock hit by a ray, on its real surface (bites included). Returns {hit, rock, chunk, t, point, normal}.
static func ray_rocks(chunks: Dictionary, origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var best := {"hit": false}
	var best_t := max_dist
	for c: Vector3i in chunks:
		var ch: Chunk = chunks[c]
		if ch.rocks.is_empty():
			continue
		if (ch.position + Vector3.ONE * 8.0).distance_to(origin) > max_dist + 14.0:
			continue
		for r: RockInst in ch.rocks:
			var oc := origin - r.pos
			var bound := r.size * 1.75
			var b := oc.dot(dir)
			if b * b - (oc.dot(oc) - bound * bound) < 0.0:
				continue
			var sh := RockMesher.surface_hit(r, origin, dir, best_t)
			if sh.hit and sh.t < best_t:
				best_t = sh.t
				best = {"hit": true, "rock": r, "chunk": ch, "t": sh.t, "point": sh.point, "normal": sh.normal}
	return best
