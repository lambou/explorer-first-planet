extends SceneTree
## Headless tests:  godot --headless --path . -s res://tests/run_tests.gd

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failures += 1
		print("  FAIL ", msg)

func _init() -> void:
	print("== generator ==")
	var g1 := PlanetGenerator.new(42)
	var g2 := PlanetGenerator.new(42)
	var g3 := PlanetGenerator.new(43)
	var c1 := Column.new()
	var c2 := Column.new()
	var c3 := Column.new()
	var same := true
	var differs := false
	var land := 0
	var hmin := 1e9
	var hmax := -1e9
	var n := 20000
	for i in n:
		var d := PlanetGenerator.fibonacci_dir(i, n)
		g1.sample_column(d, c1)
		g2.sample_column(d, c2)
		g3.sample_column(d, c3)
		if c1.height != c2.height:
			same = false
		if c1.height != c3.height:
			differs = true
		if c1.height > 0.0:
			land += 1
		hmin = minf(hmin, c1.height)
		hmax = maxf(hmax, c1.height)
	var ratio := float(land) / n
	print("  land ratio %.3f  height range %.1f .. %.1f" % [ratio, hmin, hmax])
	check(same, "same seed -> identical terrain")
	check(differs, "different seed -> different terrain")
	check(ratio > 0.22 and ratio < 0.40, "land ratio is Earth-like (22-40%)")
	check(hmax <= WorldConfig.MAX_HEIGHT, "height within MAX_HEIGHT")
	check(hmax > 800.0 and hmin < -600.0, "world has real mountains and deep oceans (same shape as the small planet, scaled up)")
	check(hmin >= -WorldConfig.MAX_OCEAN_DEPTH - 3.0, "ocean floor within MAX_OCEAN_DEPTH")

	print("== density / meshing ==")
	check(g1.classify_chunk(Vector3i(0, 0, 0)) == 2, "core chunk is solid")
	check(g1.classify_chunk(Vector3i(0, 500, 0)) == 1, "sky chunk is air")
	var sp := g1.find_spawn()
	var cc := VoxelWorld.world_to_chunk(sp)
	var f := g1.fill_chunk(cc, Column.new(), 0, false)   # surface only: cave walls legitimately face inwards
	var res := ChunkMesher.build(f.dens, f.colr, cc * WorldConfig.CHUNK_SIZE, 1, false)
	print("  spawn %s chunk %s triangles %d" % [sp, cc, res.verts.size() / 3])
	check(res.verts.size() > 0, "surface chunk produces a mesh")
	var good := true
	var bad_n := 0
	for t in range(0, res.verts.size(), 3):
		var a: Vector3 = res.verts[t]
		var b: Vector3 = res.verts[t + 1]
		var c: Vector3 = res.verts[t + 2]
		if (b - a).cross(c - a).dot(res.normals[t]) >= 0.0:
			good = false
		# smooth terrain: outward normal should roughly follow the planet's radial direction
		if res.normals[t].dot((a + Vector3(cc * 16)).normalized()) < -0.2:
			bad_n += 1
	check(good, "triangle winding is clockwise (front faces)")
	check(bad_n * 10 < res.verts.size() / 3, "90%+ of surface normals face away from the planet centre")

	print("== terrain edit ==")
	var w := VoxelWorld.new()
	w.setup(g1)
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				w._ensure_chunk(cc + Vector3i(dx, dy, dz))
	var h := w.raycast(sp, -sp.normalized(), 40.0)
	check(h.hit, "raycast towards the ground hits terrain")
	var pt: Vector3 = h.point
	var before := w.density_at(pt - sp.normalized() * 1.0)
	w.carve(pt, 2.5)
	var after := w.density_at(pt - sp.normalized() * 1.0)
	print("  density before %.2f after %.2f" % [before, after])
	check(before > 0.0 and after < 0.0, "carving digs a hole")
	w.fill(pt, 2.0, BlockTypes.STONE)
	check(w.density_at(pt) > 0.0, "filling restores terrain")

	print("== near chunks (only the ground surface) ==")
	var nw := VoxelWorld.new()
	nw.setup(g1)
	var wanted_surface := 0
	var ccn := VoxelWorld.world_to_chunk(sp)
	for dz in range(-6, 7):
		for dy in range(-6, 7):
			for dx in range(-6, 7):
				var cn := ccn + Vector3i(dx, dy, dz)
				if VoxelWorld.box_dist(cn, sp) <= VoxelWorld.VOL_RADIUS and nw.wants(cn, sp):
					wanted_surface += 1
	nw.underground = true
	var wanted_under := 0
	for dz in range(-6, 7):
		for dy in range(-6, 7):
			for dx in range(-6, 7):
				var cn := ccn + Vector3i(dx, dy, dz)
				if VoxelWorld.box_dist(cn, sp) <= VoxelWorld.VOL_RADIUS and nw.wants(cn, sp):
					wanted_under += 1
	print("  full-detail chunks on the surface: %d   when underground: %d   (full sphere would be ~1100)" % [wanted_surface, wanted_under])
	check(wanted_surface < 200, "on the surface only the thin ground layer is built")
	check(wanted_under >= wanted_surface, "underground adds the rock around the player")

	print("== far terrain (surface patches) ==")
	var ft := FarTerrain.new()
	ft.setup(g1, _test_water(g1))
	var nodes := ft.collect(sp)
	var per_depth := []
	per_depth.resize(FarTerrain.MAX_DEPTH + 1)
	per_depth.fill(0)
	for k: Vector4i in nodes:
		per_depth[k.y] += 1
	print("  patches %d per depth %s" % [nodes.size(), per_depth])
	var clash := false
	for i in nodes.size():
		for j in range(i + 1, nodes.size()):
			var a2: Vector4i = nodes[i]
			var b2: Vector4i = nodes[j]
			if a2.x != b2.x:
				continue
			var lo2 := a2 if a2.y <= b2.y else b2
			var hi2 := b2 if a2.y <= b2.y else a2
			if CubeSphere.ancestor(hi2, lo2.y) == lo2:
				clash = true
	check(not clash, "far patches never overlap")
	check(nodes.size() > 20 and nodes.size() < 700, "far terrain needs a modest number of patches")
	var t0 := Time.get_ticks_msec()
	var patch_ok := true
	var tris := 0
	for k: Vector4i in nodes.slice(0, 60):
		var pr := PatchMesher.build(g1, k)
		tris += pr.verts.size() / 3
		if pr.verts.size() == 0:
			patch_ok = false
	print("  60 patches built in %d ms, %d triangles" % [Time.get_ticks_msec() - t0, tris])
	check(patch_ok, "every patch produces a mesh")
	var out_ok := true
	var pr0 := PatchMesher.build(g1, nodes[0])
	for t in range(0, mini(pr0.verts.size(), 300), 3):
		var cr: Vector3 = (pr0.verts[t + 1] - pr0.verts[t]).cross(pr0.verts[t + 2] - pr0.verts[t])
		if cr.dot(pr0.normals[t]) >= 0.0:
			out_ok = false
	check(out_ok, "patch triangles are clockwise (front faces)")

	print("== sky light per surface ==")
	var f0 := g1.fill_chunk(cc, Column.new(), 0, false)
	var m0 := ChunkMesher.build(f0.dens, f0.colr, cc * 16, 1, false, f0.dens.duplicate())
	var sum0 := 0.0
	var n0 := 0
	for t in range(0, m0.colors.size(), 3):
		sum0 += m0.colors[t].a
		n0 += 1
	var open_avg := sum0 / maxf(n0, 1)
	print("  open ground: average sky exposure %.2f" % open_avg)
	check(open_avg > 0.7, "ground in the open sees most of the sky")
	# dig a shaft and check the bottom is darker than the opening, per surface
	var lw := VoxelWorld.new()
	lw.setup(g1)
	var upn := sp.normalized()
	var top := sp - upn * 3.0
	for d in range(0, 18, 2):
		lw.carve(top - upn * d, 3.0)
	var near_top := 0.0
	var near_bottom := 1.0
	for ck: Vector3i in lw.chunks:
		var shaft_chunk := lw.chunks[ck] as Chunk
		var mm := ChunkMesher.build(shaft_chunk.dens, shaft_chunk.colr, shaft_chunk.coord * 16, 1, false, shaft_chunk.base)
		for t in range(0, mm.verts.size(), 3):
			var wp: Vector3 = mm.verts[t] + Vector3(shaft_chunk.coord * 16)
			var depth := (top - wp).dot(upn)
			if (wp - top).cross(upn).length() > 3.5:
				continue
			if depth > 0.5 and depth < 4.0:
				near_top = maxf(near_top, mm.colors[t].a)
			if depth > 12.0:
				near_bottom = minf(near_bottom, mm.colors[t].a)
	print("  shaft: sky exposure near the opening %.2f, at the bottom %.2f" % [near_top, near_bottom])
	check(near_top > near_bottom + 0.2, "the bottom of a shaft sees less sky than its opening")

	_seed_and_cave_tests()

	print("== chunk building speed and consistency ==")
	var spc := g1.find_spawn()
	var ccc := VoxelWorld.world_to_chunk(spc)
	var t_fill := 0
	var t_mesh := 0
	var n_ch := 0
	var max_dev := 0.0
	for dzz in range(-1, 2):
		for dyy in range(-1, 2):
			for dxx in range(-1, 2):
				var cx := ccc + Vector3i(dxx, dyy, dzz)
				if g1.classify_node_fine(0, cx) != 0:
					continue
				var ta := Time.get_ticks_usec()
				var ff := g1.fill_chunk(cx, Column.new(), 0, false)
				var tb := Time.get_ticks_usec()
				ChunkMesher.build(ff.dens, ff.colr, cx * 16, 1, false, ff.dens.duplicate())
				var tc := Time.get_ticks_usec()
				t_fill += tb - ta
				t_mesh += tc - tb
				n_ch += 1
				var cexact := Column.new()
				var oo := cx * 16 - Vector3i.ONE
				for k in range(0, 18, 4):
					for j in range(0, 18, 4):
						for i in range(0, 18, 4):
							var exact := g1.density_at(oo.x + i, oo.y + j, oo.z + k, cexact, 1, false)
							var fast: float = ff.dens[i + 18 * (j + 18 * k)]
							if absf(exact) < 1.5 and absf(fast) < 1.5:
								max_dev = maxf(max_dev, absf(exact - fast))
	var avg_total := (t_fill + t_mesh) / 1000.0 / maxf(n_ch, 1)
	print("  surface chunk: %.1f ms to fill + %.1f ms to mesh (average of %d)   deviation from the exact terrain %.2f m" % [t_fill / 1000.0 / maxf(n_ch, 1), t_mesh / 1000.0 / maxf(n_ch, 1), n_ch, max_dev])
	check(avg_total < 40.0, "a surface chunk is built in under 40 ms (it was about 90 ms)")
	check(max_dev < 0.8, "the fast terrain stays within 0.8 m of the exact terrain")
	var fa3 := g1.fill_chunk(ccc, Column.new(), 0, false)
	var fb3 := g1.fill_chunk(ccc + Vector3i(1, 0, 0), Column.new(), 0, false)
	var seam_ok := true
	for k in 18:
		for j in 18:
			for ia in range(16, 18):
				if fa3.dens[ia + 18 * (j + 18 * k)] != fb3.dens[(ia - 16) + 18 * (j + 18 * k)]:
					seam_ok = false
	check(seam_ok, "neighbouring chunks agree exactly on their shared samples (no cracks)")

	print("== radar globe ==")
	var rg := PlanetGenerator.new(1337)
	var map := Radar.build_map(rg, 128, 64)
	check(map.get_width() == 128 and map.get_height() == 64, "the world map has the requested size")
	var land_px := 0
	for py in 64:
		for px in 128:
			var c := map.get_pixel(px, py)
			if c.b < c.r + 0.15:
				land_px += 1
	var land_share := float(land_px) / (128 * 64)
	print("  radar map: %.0f%% looks like land (the planet is about 29-30%% land)" % (land_share * 100.0))
	check(land_share > 0.2 and land_share < 0.45, "the radar map shows an Earth-like share of land")
	# orientation: the spawn point is on land, so its map pixel must be land
	var spw := rg.find_spawn()
	var sr := spw.length()
	var sth := fposmod(atan2(spw.x, spw.z), TAU)
	var slat := asin(spw.y / sr)
	var spx := clampi(int(sth / TAU * 128), 0, 127)
	var spy := clampi(int((PI * 0.5 - slat) / PI * 64), 0, 63)
	var sc := map.get_pixel(spx, spy)
	check(sc.b < sc.r + 0.15, "the player's position on the radar map is on land (map orientation is right)")
	check(Radar.lat_lon_text(Vector3(0, 100, 0)).begins_with("90°N"), "latitude text: the north pole is 90°N")

	print("== radar zoom ==")
	var zg := PlanetGenerator.new(1337)
	var zc := zg.find_spawn().normalized()
	var zn := Vector3.UP - zc * zc.dot(Vector3.UP)
	var zup := zn.normalized()
	var zright := (-zc).cross(zup).normalized()
	zup = zright.cross(-zc).normalized()
	var zspan := 0.2
	# the projection used by the shader is the exact inverse of the one that draws the map
	var round_trip := true
	for i in 40:
		var u := -0.9 + 1.8 * fmod(i * 0.37, 1.0)
		var v := -0.9 + 1.8 * fmod(i * 0.61, 1.0)
		if sqrt(u * u + v * v) > 0.95:
			continue
		var dd := Radar.local_dir(zc, zright, zup, zspan, u, v)
		var back := Radar.project(dd, zc, zright, zup, zspan)
		if absf(back.x - u) > 0.001 or absf(back.y - v) > 0.001:
			round_trip = false
	check(round_trip, "radar zoom: map coordinates round-trip through the projection (no distortion / mirroring)")
	var lm := Radar.build_local_map(zg, zc, zright, zup, zspan, 48)
	check(lm.get_width() == 48 and lm.get_height() == 48, "the detailed map has the requested size")
	var cc2 := lm.get_pixel(24, 24)
	check(cc2.b < cc2.r + 0.2, "the centre of the detailed map (where the player stands) is land")
	var tlist := []
	for lvl in 4:
		tlist.append(Radar.visible_half_angle(Radar.ZOOM_DIST[lvl]))
	print("  visible half-angle per zoom level (degrees): %s" % str(tlist.map(func(a): return snappedf(rad_to_deg(a), 0.1))))
	check(tlist[0] > tlist[1] and tlist[1] > tlist[2] and tlist[2] > tlist[3], "each zoom level shows a smaller area than the previous one")

	_water_tests()
	_water_module_tests()
	_river_tests()
	_sky_tests()
	_cave_spawn_tests()

	print("failures: ", failures)
	quit(failures)

func _seed_and_cave_tests() -> void:
	print("== 64-bit seeds (10^12 worlds) ==")
	check(SeedMix.splitmix64(0) == -2152535657050944081, "SplitMix64 matches the reference implementation (seed 0)")
	check(SeedMix.splitmix64(1337) == -5284787576122990581, "SplitMix64 matches the reference implementation (seed 1337)")
	check(SeedMix.derive(1337, 1, 1) == 1555841046, "derived noise seed matches the reference")
	var seen := {}
	var dup := 0
	for sd in 500000:
		var h := SeedMix.splitmix64(sd * 1000003 + 77)
		if seen.has(h):
			dup += 1
		seen[h] = true
	check(dup == 0, "500,000 seeds give 500,000 different 64-bit mixes (no collisions)")
	seen.clear()
	dup = 0
	for sd in 300000:
		var big := 123456789012 + sd * 7
		var key := Vector3i(SeedMix.derive(big, 1, 1), SeedMix.derive(big, 3, 1), SeedMix.derive(big, 6, 2))
		if seen.has(key):
			dup += 1
		seen[key] = true
	check(dup == 0, "300,000 twelve-digit seeds give different noise-seed combinations (96 bits)")
	check(WorldConfig.parse_seed("123456789012") == 123456789012, "a 12-digit seed is used as is")
	var t1 := WorldConfig.parse_seed("my world")
	check(t1 == WorldConfig.parse_seed("my world") and t1 > 0 and t1 != WorldConfig.parse_seed("my world2"), "text seeds are hashed deterministically")
	var rs := WorldConfig.random_seed()
	check(rs >= 0 and rs < 1000000000000, "random seeds are 12 digits")
	var corr_sum := 0.0
	var pairs := 6
	for pr in pairs:
		var ga := PlanetGenerator.new(999999999999 + pr * 1000)
		var gb := PlanetGenerator.new(1000000000000 + pr * 1000)
		var ca := Column.new()
		var cb := Column.new()
		var sa := 0.0
		var sb := 0.0
		var sab := 0.0
		var saa := 0.0
		var sbb := 0.0
		var np := 150
		for i in np:
			var dd := PlanetGenerator.fibonacci_dir(i * 5, 750)
			ga.sample_column(dd, ca)
			gb.sample_column(dd, cb)
			sa += ca.height
			sb += cb.height
			sab += ca.height * cb.height
			saa += ca.height * ca.height
			sbb += cb.height * cb.height
		var cov := sab / np - (sa / np) * (sb / np)
		corr_sum += absf(cov / sqrt(maxf((saa / np - pow(sa / np, 2)) * (sbb / np - pow(sb / np, 2)), 1e-9)))
	print("  mean |height correlation| between neighbouring huge seeds (6 pairs): %.2f" % (corr_sum / pairs))
	check(corr_sum / pairs < 0.3, "neighbouring seeds give unrelated terrain")
	var ratios_ok := true
	var traits_min := 1.0
	var traits_max := 0.0
	for k in 8:
		var gs := PlanetGenerator.new(424242424242 + k * 977)
		var cc2 := Column.new()
		var land2 := 0
		for i in 3000:
			gs.sample_column(PlanetGenerator.fibonacci_dir(i, 3000), cc2)
			if cc2.height > 0.0:
				land2 += 1
		var r2 := float(land2) / 3000.0
		traits_min = minf(traits_min, r2)
		traits_max = maxf(traits_max, r2)
		if r2 < 0.20 or r2 > 0.42:
			ratios_ok = false
	print("  land share over 8 big seeds: %.2f .. %.2f" % [traits_min, traits_max])
	check(ratios_ok, "every seed gives an Earth-like land share")
	var cf_min := 9.0
	var cf_max := 0.0
	for k in 500:
		var wp := WorldParams.for_seed(k * 31337 + 5)
		cf_min = minf(cf_min, wp.continent_freq)
		cf_max = maxf(cf_max, wp.continent_freq)
	check(cf_max - cf_min > 0.5, "seeds also vary the world's traits (number of continents ...)")

	print("== caves ==")
	var gc := PlanetGenerator.new(555)
	var colc := Column.new()
	var best_d := Vector3.ZERO
	var best_m := -1.0
	for i in 8000:
		var dd2 := PlanetGenerator.fibonacci_dir(i, 8000)
		gc.sample_column(dd2, colc)
		var mk := gc.caves.region_mask(dd2, colc)
		if mk > best_m and colc.land > 0.1:
			best_m = mk
			best_d = dd2
	gc.sample_column(best_d, colc)
	print("  best cave province: mask %.2f height %.0f" % [best_m, colc.height])
	check(best_m > 0.8, "there are cave provinces")
	var up := best_d
	var t1v := up.cross(Vector3.RIGHT).normalized()
	var t2v := up.cross(t1v)
	var base := best_d * (WorldConfig.PLANET_RADIUS + colc.height)
	var G := 32
	var air := PackedByteArray()
	air.resize(G * G * G)
	var n_air := 0
	for k in G:
		for j in G:
			for i in G:
				var pw := base + t1v * ((i - 16) * 5.0) + t2v * ((j - 16) * 5.0) - up * (40.0 + k * 5.0)
				if gc.density_at(roundi(pw.x), roundi(pw.y), roundi(pw.z), colc, 1, true) < 0.0:
					air[i + G * (j + G * k)] = 1
					n_air += 1
	var comp := PackedInt32Array()
	comp.resize(G * G * G)
	var sizes: Array = []
	for start in G * G * G:
		if air[start] == 1 and comp[start] == 0:
			var id := sizes.size() + 1
			var stack: Array = [start]
			comp[start] = id
			var sz := 0
			while not stack.is_empty():
				var cur: int = stack.pop_back()
				sz += 1
				var ci := cur % G
				var cj := (cur / G) % G
				var ck := cur / (G * G)
				for nb in [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]:
					var ni: int = ci + nb[0]
					var nj: int = cj + nb[1]
					var nk: int = ck + nb[2]
					if ni < 0 or nj < 0 or nk < 0 or ni >= G or nj >= G or nk >= G:
						continue
					var idx2 := ni + G * (nj + G * nk)
					if air[idx2] == 1 and comp[idx2] == 0:
						comp[idx2] = id
						stack.append(idx2)
			sizes.append(sz)
	sizes.sort()
	sizes.reverse()
	var biggest: int = sizes[0] if sizes.size() > 0 else 0
	var tiny := 0
	for sz2 in sizes:
		if sz2 < 12:
			tiny += sz2
	var frac := float(n_air) / (G * G * G)
	print("  province: cave share %.1f%%, %d separate caves, biggest holds %.0f%% of the hollow space, tiny pockets %.1f%%, biggest volume %d m3" % [frac * 100.0, sizes.size(), 100.0 * biggest / maxf(n_air, 1), 100.0 * tiny / maxf(n_air, 1), biggest * 125])
	check(frac > 0.04 and frac < 0.30, "a cave province is hollow in a believable share (4-30%)")
	check(biggest >= 0.45 * n_air, "one connected cave system holds most of the hollow space (coherent)")
	check(tiny <= 0.08 * n_air, "almost no tiny pockets: every hole is big enough to enter")
	var shallow_air := 0
	var shallow_n := 0
	var ocean_air := 0
	var ocean_n := 0
	for i in 6000:
		var d3 := PlanetGenerator.fibonacci_dir(i, 6000)
		gc.sample_column(d3, colc)
		var m3 := gc.caves.region_mask(d3, colc)
		if colc.land > 0.1 and m3 > 0.5 and colc.height > 8.0:
			for dep: float in [2.0, 5.0, 8.0]:
				var pw3 := d3 * (WorldConfig.PLANET_RADIUS + colc.height - dep)
				shallow_n += 1
				if gc.density_at(roundi(pw3.x), roundi(pw3.y), roundi(pw3.z), colc, 1, true) < 0.0:
					shallow_air += 1
		if colc.land < -0.2:
			for dep: float in [30.0, 80.0, 150.0]:
				var pw4 := d3 * (WorldConfig.PLANET_RADIUS + colc.height - dep)
				ocean_n += 1
				if gc.density_at(roundi(pw4.x), roundi(pw4.y), roundi(pw4.z), colc, 1, true) < 0.0:
					ocean_air += 1
	print("  hollow within 8 m of the surface (cave provinces): %d of %d samples; under the open ocean: %d of %d" % [shallow_air, shallow_n, ocean_air, ocean_n])
	check(shallow_air <= shallow_n * 0.02, "caves never open just below the surface (only sinkholes do)")
	check(ocean_air == 0, "no caves under the open ocean")
	var sink := 0
	var land_cols := 0
	for i in 40000:
		var d4 := PlanetGenerator.fibonacci_dir(i, 40000)
		gc.sample_column(d4, colc)
		if colc.land > 0.1 and colc.height > 8.0:
			land_cols += 1
			if gc.caves.sink_field(d4, 6.0, 1.0, false, colc) < 0.0:
				sink += 1
	print("  sinkholes: %d of %d land columns" % [sink, land_cols])
	check(sink > 0 and sink < land_cols * 0.05, "sinkholes exist but are rare")

# ---------------------------------------------------------------- water
const WR := 5120.0

## Region of chunks around world x ~ 5104..5135, y -32..31, z -16..15. rock_fn(x,y,z) -> true when rock;
## sea when y < 0 (sea columns hold water at level 0, as the generator does).
func _make_region(rock_fn: Callable) -> Dictionary:
	var chunks := {}
	var P := 18
	for cx in range(318, 321):
		for cy in range(-2, 2):
			for cz in range(-1, 1):
				var dens := PackedFloat32Array()
				var wl := PackedFloat32Array()
				dens.resize(P * P * P)
				wl.resize(P * P * P)
				var n := 0
				for k in P:
					for j in P:
						for i in P:
							var x := cx * 16 - 1 + i
							var y := cy * 16 - 1 + j
							var z := cz * 16 - 1 + k
							dens[n] = 1.0 if rock_fn.call(x, y, z) else -1.0
							wl[n] = 0.0 if y < 0 else PlanetGenerator.NO_WATER
							n += 1
				chunks[Vector3i(cx, cy, cz)] = [dens, wl]
	return chunks

func _cell(chunks_out: Dictionary, base: Dictionary, x: int, y: int, z: int) -> float:
	var c := Vector3i(floori(x / 16.0), floori(y / 16.0), floori(z / 16.0))
	var arr: PackedFloat32Array = chunks_out[c] if chunks_out.has(c) else base[c][1]
	return arr[(x - c.x * 16 + 1) + 18 * ((y - c.y * 16 + 1) + 18 * (z - c.z * 16 + 1))]

func _water_tests() -> void:
	print("== water ==")
	var gen := PlanetGenerator.new(1337)
	var NW := PlanetGenerator.NO_WATER
	# scene geometry (rel = x - 5120): land side (y >= 0) rock below +10, sea side seabed at -20.
	# tunnel on the land side, 9 m wide (|z| <= 4), from y = 0 to 30, floor at -10.
	var ground := func(x: int, y: int) -> bool:
		return x < 5130 if y >= 0 else x < 5100
	# A) sealed cave with a small underwater entrance (rel -10..-6) and a tall dome behind (up to +3)
	var rock_a := func(x: int, y: int, z: int) -> bool:
		if not ground.call(x, y):
			return false
		if y >= 0 and y <= 30 and absi(z) <= 4:
			var rel := x - 5120
			if y <= 1:
				return not (rel >= -10 and rel <= -6)      # entrance: only the bottom 5 m are open
			return not (rel >= -10 and rel <= 3)             # dome
		return true
	var ca := _make_region(rock_a)
	var gfn := func(_wp: Vector3) -> float: return 9.5
	var t_a := Time.get_ticks_usec()
	var ra := WaterSolver.solve(gen, ca, gfn)
	print("  solver time, %d chunks: %.1f ms" % [ca.size(), (Time.get_ticks_usec() - t_a) / 1000.0])
	var la := _cell(ra.out, ca, 5114, 15, 0) if ra.out.size() > 0 else NW   # rel -6, in the water below the level -5.5
	print("  A) sealed cave, entrance top at -6: water level in the dome = %.2f (expected -5.5)" % (la - 0.002))
	check(ra.spaces == 1, "the cave that touches the sea is found")
	check(absf((la - 0.002) - (-5.5)) < 0.05, "sealed cave: the water stops at the top of the entrance (air stays trapped above)")
	# B) the same cave but with a sinkhole shaft to the sky: air escapes, water rises to sea level
	var rock_b := func(x: int, y: int, z: int) -> bool:
		if rock_a.call(x, y, z) == false:
			return false
		var dy := y - 20
		if dy * dy + z * z <= 9 and x >= 5123:
			return false                                     # shaft from the dome (+3) up through the ground (+10) to the sky
		return true
	var cb := _make_region(rock_b)
	var rb := WaterSolver.solve(gen, cb, gfn)
	var lb := _cell(rb.out, cb, 5116, 15, 0) if rb.out.size() > 0 else NW
	print("  B) same cave with a shaft to the sky: water level = %.2f (expected 0.0)" % (lb - 0.002))
	check(absf((lb - 0.002) - 0.0) < 0.05, "cave open to the air: the water rises to sea level")
	# the dome reaches +3 and the shaft +10: nothing above sea level + 1 may hold water
	var above_dry := true
	for x in range(5122, 5131):
		if _cell(rb.out, cb, x, 20, 0) > NW * 0.5:
			above_dry = false
	check(above_dry, "water never rises above its level: the dome roof and the shaft stay dry")
	# C) low cave (ceiling at -4, floor at -10) with a full-height entrance: flooded completely
	var rock_c := func(x: int, y: int, z: int) -> bool:
		if not ground.call(x, y):
			return false
		if y >= 0 and y <= 30 and absi(z) <= 4:
			var rel := x - 5120
			return not (rel >= -10 and rel <= -4)
		return true
	var cc := _make_region(rock_c)
	var rc := WaterSolver.solve(gen, cc, gfn)
	var lc := _cell(rc.out, cc, 5112, 15, 0) if rc.out.size() > 0 else NW
	print("  C) low cave, ceiling -4: level = %.2f (above the ceiling -> fully flooded)" % (lc - 0.002))
	check(lc - 0.002 > -4.0 + 0.1 or lc - 0.002 > -3.6, "cave lower than the entrance top is flooded completely")
	# D) a cave that does not touch the sea gets no water
	var rock_d := func(x: int, y: int, z: int) -> bool:
		if not ground.call(x, y):
			return false
		if y >= 4 and y <= 30 and absi(z) <= 4:
			var rel := x - 5120
			return not (rel >= -10 and rel <= 3)
		return true
	var cd := _make_region(rock_d)
	var rd2 := WaterSolver.solve(gen, cd, gfn)
	check(rd2.spaces == 0 and rd2.out.is_empty(), "a cave that is not connected to the sea stays dry")
	# E) surface of the sea: the water mesher puts the sheet at sea level
	var wsum := 0.0
	var wn := 0
	var sheet := 0
	var any_mesh := false
	for c: Vector3i in ca:
		var res := WaterMesher.build(ca[c][1], ca[c][0], c, PackedFloat32Array(), Vector3i.ZERO)
		var vv: PackedVector3Array = res.verts
		if vv.size() > 0:
			any_mesh = true
		for v in vv:
			var wp := Vector3(c * 16) + v
			wsum += wp.length() - WR
			wn += 1
			if absf(wp.length() - WR) < 0.5:
				sheet += 1
	print("  sea surface: %d vertices, %d of them at sea level" % [wn, sheet])
	check(any_mesh and sheet > 200, "the sea surface mesh has a sheet at sea level")
	# F) the real generator: sea chunks have water, inland chunks have none
	var gx := PlanetGenerator.new(1337)
	var colw := Column.new()
	var coast_d := Vector3.ZERO
	var inland_d := Vector3.ZERO
	for i in 40000:
		var dd := PlanetGenerator.fibonacci_dir(i, 40000)
		gx.sample_column(dd, colw)
		if coast_d == Vector3.ZERO and colw.land < -0.004 and colw.land > -0.02 and colw.height < -1.0 and colw.height > -8.0:
			coast_d = dd
		if inland_d == Vector3.ZERO and colw.land > 0.4:
			inland_d = dd
	var fc := gx.fill_chunk(VoxelWorld.world_to_chunk(coast_d * (WR - 1.0)), Column.new(), 0, false)
	var fi := gx.fill_chunk(VoxelWorld.world_to_chunk(inland_d * (WR + 100.0)), Column.new(), 0, false)
	print("  coast chunk has water data: %s, inland chunk: %s" % [not fc.wlev.is_empty(), not fi.wlev.is_empty()])
	check(not fc.wlev.is_empty(), "a chunk on the coast carries sea water")
	check(fi.wlev.is_empty(), "an inland chunk carries no water")
	var wm := WaterMesher.build(fc.wlev, fc.dens, VoxelWorld.world_to_chunk(coast_d * (WR - 1.0)), fc.hlat, fc.l0)
	check((wm.verts as PackedVector3Array).size() > 0, "the coast chunk has a visible water surface")
	# H) digging next to water must not stall the main thread: the solver and the water meshes are built on a worker
	var dw := VoxelWorld.new()
	dw.setup(gx)
	var dc := coast_d * (WR - 1.0)
	var dcc := VoxelWorld.world_to_chunk(dc)
	for dz in range(-3, 4):
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				dw._ensure_chunk(dcc + Vector3i(dx, dy, dz))
	var worst := 0.0
	var applied_runs := 0
	var seen_busy := false
	for edit_i in 4:
		var t_e := Time.get_ticks_usec()
		dw.carve(dc - dc.normalized() * (1.0 + edit_i), 3.0)
		worst = maxf(worst, (Time.get_ticks_usec() - t_e) / 1000.0)
		for frame in 200:
			var t_f := Time.get_ticks_usec()
			dw.water.tick(dw.chunks, dc, true, dw.edit_rev)
			worst = maxf(worst, (Time.get_ticks_usec() - t_f) / 1000.0)
			seen_busy = seen_busy or dw.water._busy
			OS.delay_msec(5)
	print("  dig beside the sea: worst main-thread step = %.1f ms (solver ran: %s)" % [worst, seen_busy])
	check(worst < 40.0, "digging next to water never costs the main thread more than ~40 ms in one step")
	# G) sea caves: coastal tunnels really open at the shore / seabed
	var open_cols := 0
	var coast_cols := 0
	var sc := Column.new()
	for i in 60000:
		var d2 := PlanetGenerator.fibonacci_dir(i, 60000)
		gx.sample_column(d2, sc)
		if absf(sc.land) < 0.025:
			coast_cols += 1
			var pp := d2 * (WR + sc.height - 2.5)
			if gx.density_at(roundi(pp.x), roundi(pp.y), roundi(pp.z), sc, 1, false) < 0.0:
				open_cols += 1
	print("  shoreline columns with a cave mouth 2.5 m below the ground: %d of %d" % [open_cols, coast_cols])
	check(open_cols > 0, "sea caves exist: tunnels open along the shoreline")

func _test_water(g: PlanetGenerator) -> WaterSystem:
	var w := WaterSystem.new()
	w.setup(g, 1337)
	return w

func _water_module_tests() -> void:
	print("== water module (state, underwater, queries) ==")
	var ws := WaterState.new(1337)
	var mn := 1.0
	var mx := 0.0
	for i in 400:
		var a := ws.agitation_at(PlanetGenerator.fibonacci_dir(i, 400) * 5120.0, 0.0)
		mn = minf(mn, a)
		mx = maxf(mx, a)
	print("  agitation over the planet: %.2f .. %.2f" % [mn, mx])
	check(mn < 0.15 and mx > 0.85, "the sea has both calm and stormy regions")
	var p0 := Vector3(0, 5120, 0)
	var a0 := ws.agitation_at(p0, 0.0)
	var a1 := ws.agitation_at(p0, 600.0)
	check(ws.agitation_at(p0, 0.0) == a0 and absf(a1 - a0) < 0.6, "the state is deterministic and changes slowly with time")
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	var results := []
	for depth in [2.0, 30.0, 100.0, 250.0]:
		env.ambient_light_energy = 1.0
		sun.light_energy = 1.0
		UnderwaterEffect.apply(env, sun, depth, 1.0)
		results.append([sun.light_energy, env.fog_density])
	print("  sun energy by depth 2/30/100/250 m: %s" % str(results.map(func(r): return snappedf(r[0], 0.001))))
	check(results[0][0] > results[1][0] and results[1][0] > results[2][0] and results[2][0] > results[3][0], "light dims with depth")
	check(results[3][0] < 0.02, "below ~200 m even the sun does not reach")
	check(1.0 / results[0][1] < 30.0 and 1.0 / results[3][1] < 16.0, "visibility under water is limited (about 20 m, less in the deep)")
	check(not UnderwaterEffect.apply(env, sun, -3.0, 1.0), "above the surface the underwater effect does nothing")
	# queries without a built chunk: open sea answered from the terrain
	var g := PlanetGenerator.new(1337)
	var wsys := WaterSystem.new()
	wsys.setup(g, 1337)
	var col := Column.new()
	var sea_d := Vector3.ZERO
	var land_d := Vector3.ZERO
	for i in 20000:
		var d := PlanetGenerator.fibonacci_dir(i, 20000)
		g.sample_column(d, col)
		if sea_d == Vector3.ZERO and col.land < -0.3:
			sea_d = d
		if land_d == Vector3.ZERO and col.land > 0.3:
			land_d = d
	var none := {}
	check(absf(wsys.submersion(none, sea_d * (5120.0 - 30.0)) - 30.0) < 0.01, "30 m under the open sea: submersion 30 m")
	check(wsys.submersion(none, sea_d * (5120.0 + 5.0)) < 0.0, "above the sea: not submerged")
	check(wsys.submersion(none, land_d * (5120.0 + 200.0)) < -1.0e8, "over land: no water")

func _cave_spawn_tests() -> void:
	print("== cave spawn ==")
	var g := PlanetGenerator.new(1337)
	var t0 := Time.get_ticks_msec()
	var sp := g.find_cave_spawn()
	var ms := Time.get_ticks_msec() - t0
	print("  anywhere: %s in %d ms" % [sp, ms])
	check(sp != Vector3.ZERO, "a cave spawn exists on the planet")
	var col := Column.new()
	var scratch := Column.new()
	var d := sp.normalized()
	g.sample_height(d, col)
	var depth := col.height - (sp.length() - WorldConfig.PLANET_RADIUS)
	print("  %.0f m below the surface" % depth)
	check(depth > 30.0, "the spawn is deep underground, not in a surface hollow")
	check(g.density_at(roundi(sp.x), roundi(sp.y), roundi(sp.z), scratch, 1, true) < 0.0, "the ball starts in open space")
	var floor_found := false
	for k in range(1, 5):
		var q := sp - d * float(k)
		if g.density_at(roundi(q.x), roundi(q.y), roundi(q.z), scratch, 1, true) > 0.0:
			floor_found = true
	check(floor_found, "solid floor right below the ball")
	var t1 := Time.get_ticks_msec()
	var lit := g.find_cave_spawn(Vector3.ZERO, true)
	print("  open to the sky: %s in %d ms" % [lit, Time.get_ticks_msec() - t1])
	check(lit != Vector3.ZERO, "a cave open to the sky (sinkhole floor) exists")
	if lit != Vector3.ZERO:
		var ld := lit.normalized()
		var open := true
		var hh := 2.0
		var surf := Column.new()
		g.sample_height(ld, surf)
		while hh < surf.height - (lit.length() - WorldConfig.PLANET_RADIUS) + 3.0:
			var q := lit + ld * hh
			if g.density_at(roundi(q.x), roundi(q.y), roundi(q.z), scratch, 1, true) >= 0.0:
				open = false
			hh += 2.0
		check(open, "the open cave really has a free shaft up to the sky")
	# nearest-first: asking from the spawn's own place gives the same cave back
	var near := g.find_cave_spawn(d)
	check(near.distance_to(sp) < 400.0, "searching from a cave finds one close by")
	# a different seed gives a different cave world
	var other := PlanetGenerator.new(4242).find_cave_spawn()
	check(other != Vector3.ZERO and other.distance_to(sp) > 10.0, "another seed has its own caves")

func _sky_tests() -> void:
	print("== sky ==")
	var sky := SkyDome.create()
	var m := sky.sky_material as ShaderMaterial
	check(m != null and m.shader != null and m.shader.code.contains("shader_type sky"), "the sky is a custom sky shader (atmosphere + clouds), not the default gradient")
	SkyDome.update(sky, Vector3(0, 1, 0), Vector3(1, 0, 0), 0.4)
	check(m.get_shader_parameter("sun_dir") == Vector3(0, 1, 0) and m.get_shader_parameter("up_dir") == Vector3(1, 0, 0), "the sky receives the sun direction and the local up")
	check(m.shader.code.contains("clouds") and m.shader.code.contains("stars"), "the sky has clouds and stars")
	check(Radar.SHADER.contains("twilight") and Radar.SHADER.contains("night_col"), "the radar globe shows day, night and the sunrise/sunset line")
	check(absf(SkyDome.horizon_sine(5120.0)) < 1e-6, "at sea level the horizon is at eye level")
	var dip := rad_to_deg(asin(-SkyDome.horizon_sine(5120.0 + 147.0)))
	print("  horizon dip at +147 m: %.1f degrees (expected ~13.6)" % dip)
	check(absf(dip - 13.6) < 0.3, "from +147 m the true horizon lies about 13.6 degrees below eye level")
	var noon := SkyDome.horizon_color(Vector3(0, 1, 0), Vector3(0, 1, 0))
	var night := SkyDome.horizon_color(Vector3(0, -1, 0), Vector3(0, 1, 0))
	check(noon.b > night.b + 0.3 and noon.get_luminance() > night.get_luminance() * 5.0, "the haze colour follows the sun: bright blue by day, dark at night")

func _river_tests() -> void:
	print("== rivers ==")
	var g := PlanetGenerator.new(1337)
	var col := Column.new()
	var n_land := 0
	var n_river := 0
	var samples: Array = []
	for i in 200000:
		var d := PlanetGenerator.fibonacci_dir(i, 200000)
		g.sample_column(d, col)
		if col.land > 0.04:
			n_land += 1
			if col.river > 0.5:
				n_river += 1
				if samples.size() < 400:
					samples.append([col.land, col.river_level, col.height, col.river, d])
	var share := float(n_river) / maxf(n_land, 1)
	print("  river share of land columns: %.1f%%" % (share * 100.0))
	check(share > 0.0001 and share < 0.15, "rivers exist but cover only a small part of the land")
	# held by banks: on both sides of the channel the ground stands at least as high as the water, so the water
	# never hangs on a slope (the bank test: ground 11 and 18 m to each side)
	var held := 0
	var tested := 0
	var below := 0
	for a in samples:
		if a[3] > 0.95 and a[2] > a[1] + 0.2:
			below += 1
		var dd0: Vector3 = a[4]
		var tt := dd0.cross(Vector3.UP).normalized()
		var ok_banks := true
		for off: float in [-18.0, -11.0, 11.0, 18.0]:
			g.sample_height((dd0 + tt * off / 5120.0).normalized(), col, 1)
			if col.river < 0.3 and col.height < a[1] - 1.0:
				ok_banks = false
		tested += 1
		if ok_banks:
			held += 1
	print("  rivers checked: %d, held by banks on both sides: %d" % [tested, held])
	check(tested > 0 and float(held) / maxf(tested, 1) > 0.9, "river water is held by banks: the ground beside it is not lower than the water")
	check(below == 0, "the water surface is never below the ground in the channel")
	# the chunk meshes: a river chunk has a water mesh of kind 2
	var found := false
	var dd := Vector3.ZERO
	for i in 60000:
		var d2 := PlanetGenerator.fibonacci_dir(i, 60000)
		g.sample_column(d2, col)
		if col.river > 0.95 and col.land > 0.05 and col.land < 0.2:
			dd = d2
			break
	var pos := dd * (5120.0 + col.height + 0.5)
	var cc := VoxelWorld.world_to_chunk(pos)
	var f := g.fill_chunk(cc, Column.new(), 0, false)
	var wm := WaterMesher.build(f.wlev, f.dens, cc, f.hlat, f.l0)
	var uvs: PackedVector2Array = wm.uvs if wm.has("uvs") else PackedVector2Array()
	var kinds := 0
	for u in uvs:
		if u.y == 2.0:
			kinds += 1
	print("  river chunk: %d water vertices, %d of river kind" % [uvs.size(), kinds])
	check(kinds > 0, "a river chunk gets a river-water surface")
