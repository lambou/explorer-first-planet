class_name WaterSolver
extends RefCounted
## Decides where water goes inside caves and holes, from how they connect to the sea.
##  - A hollow space (cave, tunnel, dug hole) that touches the sea is flooded through its opening.
##  - If it is open to the air somewhere (a sinkhole, a shaft, a mouth above the waterline) the air
##    can escape, so the water rises to SEA LEVEL inside it (communicating vessels).
##  - If it is sealed (every way to the air is blocked), the air stays trapped and the water only
##    reaches the TOP OF THE ENTRANCE (diving-bell rule). A cave whose ceiling is lower than that is
##    flooded completely; a bigger one keeps a pocket of air above the entrance's top.
## It works on the chunks that are built around the player and runs on a worker thread. Space that
## is not built yet counts as "may be open to the air".
## Water level values written: level + 0.002 (sea water itself is exactly 0.0, see WaterMesher).

const S := WorldConfig.CHUNK_SIZE
const P := WorldConfig.PADDED
const R := float(WorldConfig.PLANET_RADIUS)
const NO_WATER := PlanetGenerator.NO_WATER
const CAVE_MARK := 0.002
const MAX_CELLS := 450000
const MAX_GROUND_CHECKS := 4000

## chunks: coord -> [dens (padded), wlev (padded or empty)]. Returns
## {"out": coord -> new padded wlev array, "spaces": number of hollow spaces that got water}.
## `ground_fn` (optional, for tests): wp -> ground height above sea level.
static func solve(gen: PlanetGenerator, chunks: Dictionary, ground_fn: Callable = Callable()) -> Dictionary:
	var result := {"out": {}, "spaces": 0}
	var has_sea := false
	for c: Vector3i in chunks:
		if not (chunks[c][1] as PackedFloat32Array).is_empty():
			has_sea = true
			break
	if not has_sea:
		return result
	var cmin := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var cmax := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
	for c: Vector3i in chunks:
		cmin = Vector3i(mini(cmin.x, c.x), mini(cmin.y, c.y), mini(cmin.z, c.z))
		cmax = Vector3i(maxi(cmax.x, c.x), maxi(cmax.y, c.y), maxi(cmax.z, c.z))
	var dx := (cmax.x - cmin.x + 1) * S
	var dy := (cmax.y - cmin.y + 1) * S
	var dz := (cmax.z - cmin.z + 1) * S
	var total := dx * dy * dz
	var DXY := dx * dy
	var origin := cmin * S                            # world sample coordinate of grid cell (0, 0, 0)
	var air := PackedByteArray()                      # 1 air, 0 rock, 2 not built
	var sea := PackedByteArray()                      # 1 = the cell is in a sea column
	air.resize(total)
	air.fill(2)
	sea.resize(total)
	for c: Vector3i in chunks:
		var dens: PackedFloat32Array = chunks[c][0]
		var wl: PackedFloat32Array = chunks[c][1]
		var has_wl := not wl.is_empty()
		var gx := (c.x - cmin.x) * S
		var gy := (c.y - cmin.y) * S
		var gz := (c.z - cmin.z) * S
		for k in S:
			for j in S:
				var gi := gx + dx * (gy + j + dy * (gz + k))
				var di := 1 + P * (j + 1 + P * (k + 1))
				for i in S:
					air[gi + i] = 1 if dens[di + i] < 0.0 else 0
					if has_wl and wl[di + i] == 0.0:
						sea[gi + i] = 1
	# ---- opening cells: hollow, not sea, touching sea water (a sea cell that is air below sea level)
	var opening := PackedByteArray()
	opening.resize(total)
	var open_list := PackedInt32Array()
	for z in range(1, dz - 1):
		for y in range(1, dy - 1):
			var row := dx * (y + dy * z)
			for x in range(1, dx - 1):
				var gi := row + x
				if air[gi] != 1 or sea[gi] == 1:
					continue
				var touch := false
				for nb in [gi - 1, gi + 1, gi - dx, gi + dx, gi - DXY, gi + DXY]:
					if air[nb] == 1 and sea[nb] == 1 and _rel(origin, dx, dy, nb) < 0.0:
						touch = true
						break
				if touch:
					opening[gi] = 1
					open_list.append(gi)
	if open_list.is_empty():
		return result
	# ---- flood each connected hollow space
	var comp := PackedByteArray()
	comp.resize(total)
	var wlr := PackedFloat32Array()
	wlr.resize(total)
	wlr.fill(NO_WATER)
	var ground_cache := {}
	var ground_checks := 0
	var col := Column.new()
	var changed_cells := PackedInt32Array()
	for start in open_list:
		if comp[start] != 0:
			continue
		var queue := PackedInt32Array([start])
		comp[start] = 1
		var head := 0
		var vented := false
		var open_top := -1.0e9
		while head < queue.size():
			var gi := queue[head]
			head += 1
			var rel := _rel(origin, dx, dy, gi)
			if opening[gi] == 1:
				open_top = maxf(open_top, rel)
			var x := gi % dx
			var y := (gi / dx) % dy
			var z := gi / DXY
			# is this cell in the open air above the ground? then it is no longer "cave"
			if rel >= 0.0:
				var key := Vector3i(x >> 2, y >> 2, z >> 2)
				var above: bool
				if ground_cache.has(key):
					above = ground_cache[key]
				elif ground_checks >= MAX_GROUND_CHECKS:
					above = true
				else:
					ground_checks += 1
					var wp := Vector3(origin.x + x, origin.y + y, origin.z + z)
					var gh: float
					if ground_fn.is_valid():
						gh = ground_fn.call(wp)
					else:
						gen.sample_height(wp.normalized(), col, 4)
						gh = col.height
					above = rel > gh + 2.0
					ground_cache[key] = above
				if above:
					vented = true
					continue
			if x == 0 or y == 0 or z == 0 or x == dx - 1 or y == dy - 1 or z == dz - 1:
				vented = true          # the space continues outside what is built: it may be open to the air
				continue
			for nb in [gi - 1, gi + 1, gi - dx, gi + dx, gi - DXY, gi + DXY]:
				var a := air[nb]
				if a == 2:
					vented = true
				elif a == 1:
					if sea[nb] == 1:
						if _rel(origin, dx, dy, nb) >= 0.0:
							vented = true            # the open sea surface above the water
					elif comp[nb] == 0:
						comp[nb] = 1
						queue.append(nb)
			if queue.size() > MAX_CELLS:
				vented = true
				break
		var level := 0.0 if vented else minf(0.0, open_top + 0.5)
		var val := level + CAVE_MARK
		# water only fills what is AT or BELOW its level (one sample of margin keeps the surface closed):
		# a shaft or a hollow higher up the mountain stays dry
		for gi in queue:
			if _rel(origin, dx, dy, gi) <= level + 1.0:
				wlr[gi] = val
				changed_cells.append(gi)
		result.spaces += 1
	# ---- extend the level 2 cells into the surrounding rock (invisible, keeps the surface closed)
	var frontier := changed_cells.duplicate()
	for pass_i in 2:
		var next := PackedInt32Array()
		for gi in frontier:
			var v := wlr[gi]
			var x := gi % dx
			var y := (gi / dx) % dy
			var z := gi / DXY
			if x == 0 or y == 0 or z == 0 or x == dx - 1 or y == dy - 1 or z == dz - 1:
				continue
			for nb in [gi - 1, gi + 1, gi - dx, gi + dx, gi - DXY, gi + DXY]:
				if air[nb] == 0 and sea[nb] == 0 and wlr[nb] == NO_WATER and _rel(origin, dx, dy, nb) <= v + 1.0:
					wlr[nb] = v
					next.append(nb)
		changed_cells.append_array(next)
		frontier = next
	# ---- write into the chunks' padded arrays (a cell belongs to up to 8 chunks' padding)
	var out := {}
	for gi in changed_cells:
		var x := gi % dx
		var y := (gi / dx) % dy
		var z := gi / DXY
		var wx := origin.x + x
		var wy := origin.y + y
		var wz := origin.z + z
		var cx := floori(wx / float(S))
		var cy := floori(wy / float(S))
		var cz := floori(wz / float(S))
		var v := wlr[gi]
		for ox in range(-1, 2):
			var lx := wx - (cx + ox) * S
			if lx < -1 or lx > S:
				continue
			for oy in range(-1, 2):
				var ly := wy - (cy + oy) * S
				if ly < -1 or ly > S:
					continue
				for oz in range(-1, 2):
					var lz := wz - (cz + oz) * S
					if lz < -1 or lz > S:
						continue
					var cc := Vector3i(cx + ox, cy + oy, cz + oz)
					if not chunks.has(cc):
						continue
					if not out.has(cc):
						var base: PackedFloat32Array = chunks[cc][1]
						var arr: PackedFloat32Array
						if base.is_empty():
							arr = PackedFloat32Array()
							arr.resize(P * P * P)
							arr.fill(NO_WATER)
						else:
							arr = base.duplicate()
						out[cc] = arr
					var target: PackedFloat32Array = out[cc]
					target[(lx + 1) + P * ((ly + 1) + P * (lz + 1))] = v
	result.out = out
	return result

static func _rel(origin: Vector3i, dx: int, dy: int, gi: int) -> float:
	var x := float(origin.x + gi % dx)
	var y := float(origin.y + (gi / dx) % dy)
	var z := float(origin.z + gi / (dx * dy))
	return sqrt(x * x + y * y + z * z) - R
