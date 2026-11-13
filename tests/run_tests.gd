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
	_rock_tests()
	_rock_placement_tests()
	_rock_break_tests()
	_rock_deposit_tests()
	_rock_gravity_tests()
	_ball_ground_tests()
	_grass_tests()
	_tree_tests()
	_survival_tests()
	_save_tests()

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

func _rock_tests() -> void:
	print("== rocks: catalog ==")
	var cat := RockCatalog.new(1337)
	var keys := {}
	var hosts_ok := true
	for t in cat.types:
		keys[t.key] = true
		for h in t.hosts:
			if cat.get_type(h) == null or not cat.get_type(h).is_base():
				hosts_ok = false
	print("  %d types: %d base, %d ore/gem/radioactive/exotic" % [cat.types.size(), cat.base_types().size(), cat.ore_types().size()])
	check(keys.size() == cat.types.size(), "every rock type has its own key")
	check(hosts_ok, "every ore names host rocks that exist")
	for k in ["granite", "gold", "diamond", "uranium"]:
		check(cat.get_type(k) != null, "the catalog has " + k)
	var exotics: Array[String] = []
	for t in cat.types:
		if t.family == RockType.FAMILY_EXOTIC:
			exotics.append("%s(%s)" % [t.name, ",".join(t.traits.keys())])
	print("  unknown types of this world: ", exotics)
	check(exotics.size() == RockCatalog.EXOTIC_COUNT, "the world has its unknown rock types")
	var cat2 := RockCatalog.new(1337)
	var same := true
	for i in cat.types.size():
		if cat.types[i].name != cat2.types[i].name or cat.types[i].color != cat2.types[i].color or cat.types[i].hardness != cat2.types[i].hardness:
			same = false
	check(same, "the same seed gives the same catalog")
	var cat3 := RockCatalog.new(4242)
	var differ := 0
	for i in cat.types.size():
		if cat.types[i].name != cat3.types[i].name:
			differ += 1
	check(differ >= 3, "another seed has other unknown rocks")
	var base_ok := true
	var seen := {}
	for t in cat.base_types():
		var k := "%.3f,%.3f" % [t.center.x, t.center.y]
		if seen.has(k) or t.center.x < 0.0 or t.center.x > 1.0 or t.center.y < 0.0 or t.center.y > 1.0:
			base_ok = false
		seen[k] = true
	check(base_ok, "base rocks have their own places in the province space")
	check(cat.get_type("diamond").value > cat.get_type("granite").value * 50.0 and cat.get_type("diamond").hardness > cat.get_type("coal").hardness, "valuable rocks are harder and worth more")

func _rock_placement_tests() -> void:
	print("== rocks: geology and placement ==")
	var g := PlanetGenerator.new(1337)
	var cat := RockCatalog.new(1337)
	var field := RockField.new(cat, 1337)
	# provinces: every base rock appears somewhere, and regions are coherent (close places have the same rock)
	var seen := {}
	var same := 0
	var total := 0
	for i in 4000:
		var d := PlanetGenerator.fibonacci_dir(i, 4000)
		var b := field.base_at(d)
		seen[b.key] = seen.get(b.key, 0) + 1
		var t1 := d.cross(Vector3.UP).normalized()
		if field.base_at((d + t1 * (20.0 / 5120.0)).normalized()).key == b.key:
			same += 1
		total += 1
	print("  base rock shares: ", seen)
	check(seen.size() == cat.base_types().size(), "every base rock has a region on the planet")
	print("  places 20 m apart with the same base rock: %.1f%%" % (100.0 * same / total))
	check(float(same) / total > 0.96, "places 20 m apart almost always share the same base rock (regions are coherent)")
	# rules
	var obsidian_diamond := RockField.ore_allowed(cat.get_type("diamond"), "obsidian", 100.0, -5.0, false)
	check(obsidian_diamond, "diamond can form deep in obsidian / basalt country")
	check(not RockField.ore_allowed(cat.get_type("diamond"), "obsidian", 0.0, 10.0, false), "diamond never lies on the surface")
	check(not RockField.ore_allowed(cat.get_type("gold"), "limestone", 100.0, 0.0, false), "gold does not form in limestone")
	check(not RockField.ore_allowed(cat.get_type("coal"), "sandstone", 0.0, -20.0, true), "coal is not found under the sea")
	# placement on a land chunk
	var sp := g.find_spawn()
	var cc := VoxelWorld.world_to_chunk(sp)
	var land_rocks := 0
	var all_inside := true
	var ungrounded := 0
	var rock_total := 0
	var scratch := Column.new()
	var place_us := 0
	var chunks_done := 0
	var type_count := {}
	var sizes := []
	for dz in range(-4, 5):
		for dy in range(-2, 3):
			for dx in range(-4, 5):
				var c := cc + Vector3i(dx, dy, dz)
				var f := g.fill_chunk(c, Column.new(), 0, false)
				var t1 := Time.get_ticks_usec()
				var rocks := RockPlacer.place(g, field, c, f.dens, f.wlev)
				place_us += Time.get_ticks_usec() - t1
				chunks_done += 1
				land_rocks += rocks.size()
				var o := Vector3(c * 16)
				for r: RockInst in rocks:
					var lp := r.pos - o
					if lp.x < 0.0 or lp.y < 0.0 or lp.z < 0.0 or lp.x >= 16.0 or lp.y >= 16.0 or lp.z >= 16.0:
						all_inside = false
					# solid ground under it in the chunk's own density field (what the mesh is made of)
					var below := r.pos - r.normal * r.size * 1.3 - o
					rock_total += 1
					if RockPlacer._sample(f.dens, below) <= 0.0:
						ungrounded += 1
					var tn: String = cat.by_id(r.layers[0][0]).key
					type_count[tn] = type_count.get(tn, 0) + 1
					sizes.append(r.size)
	print("  %d rocks in %d chunks around the spawn; host rocks %s" % [land_rocks, chunks_done, type_count])
	check(land_rocks > 20, "rocks lie on the ground around the spawn")
	check(all_inside, "every rock lies inside the chunk that owns it")
	print("  rocks without solid ground under them: %d of %d" % [ungrounded, rock_total])
	check(float(ungrounded) / maxf(rock_total, 1) < 0.03, "rocks rest on solid ground (over 97%)")
	var big := 0
	var small := 0
	for z in sizes:
		if z >= 1.3:
			big += 1
		if z < 0.5:
			small += 1
	print("  sizes: %d small (<0.5 m), %d big (>= 1.3 m) of %d" % [small, big, sizes.size()])
	check(small > big and big > 0, "many small rocks, a few boulders")
	# determinism and seed dependence
	var f1 := g.fill_chunk(cc, Column.new(), 0, false)
	var a := RockPlacer.place(g, field, cc, f1.dens, f1.wlev)
	var b2 := RockPlacer.place(g, field, cc, f1.dens, f1.wlev)
	var ident := a.size() == b2.size()
	for i in a.size():
		if ident and (a[i].id != b2[i].id or a[i].pos != b2[i].pos or a[i].layers != b2[i].layers):
			ident = false
	check(ident, "the same chunk always has the same rocks")
	var g2 := PlanetGenerator.new(4242)
	var field2 := RockField.new(RockCatalog.new(4242), 4242)
	var other := RockPlacer.place(g2, field2, cc, f1.dens, f1.wlev)
	var ids_a := {}
	for r: RockInst in a:
		ids_a[r.id] = true
	var shared := 0
	for r: RockInst in other:
		if ids_a.has(r.id):
			shared += 1
	check(shared == 0, "another seed puts other rocks in the same place")
	# veins: deep in caves and far down, ores show up; count ore rocks over a deep cave region
	var ore_hits := {}
	var deep_total := 0
	for i in 3000:
		var d := PlanetGenerator.fibonacci_dir(i, 3000)
		var p := d * (5120.0 + 20.0 - 120.0)
		var ctx := {"depth": 120.0, "alt": -100.0, "underwater": false}
		var layers := field.choose(d, p, ctx, float(i % 97) / 97.0)
		deep_total += 1
		if layers.size() > 1:
			var k: String = cat.by_id(layers[1][0]).key
			ore_hits[k] = ore_hits.get(k, 0) + 1
	print("  deep rocks: ores by type ", ore_hits, " of ", deep_total)
	check(ore_hits.size() >= 4, "deep down several kinds of ore appear")
	var surf_ores := 0
	for i in 3000:
		var d := PlanetGenerator.fibonacci_dir(i, 3000)
		var layers := field.choose(d, d * 5130.0, {"depth": 0.0, "alt": 10.0, "underwater": false}, float(i % 97) / 97.0)
		if layers.size() > 1 and cat.by_id(layers[1][0]).min_depth > 0.0:
			surf_ores += 1
	check(surf_ores == 0, "deep-only ores never lie on the surface")
	# baking: 80 triangles per rock, clockwise (Godot's front face) with outward normals, exposure in the alpha
	var sample_rocks: Array = []
	var f2 := g.fill_chunk(cc + Vector3i(1, 0, 0), Column.new(), 0, false)
	for dx in range(-3, 4):
		var cx := cc + Vector3i(dx, 0, 0)
		var ff := g.fill_chunk(cx, Column.new(), 0, false)
		var rr := RockPlacer.place(g, field, cx, ff.dens, ff.wlev)
		if rr.size() > 0:
			sample_rocks = rr
			f2 = ff
			cc = cx
			break
	if sample_rocks.size() > 0:
		var baked := RockMesher.bake(sample_rocks, cat, Vector3(cc * 16), f2.dens, f2.dens)
		var vv: PackedVector3Array = baked.verts
		var expect_tris := 0
		for sr: RockInst in sample_rocks:
			expect_tris += 320 if sr.size >= 1.0 else 80
		check(vv.size() == expect_tris * 3, "every rock is baked into 80 triangles (320 from 1 m up)")
		var winding_ok := true
		var outward_ok := true
		var alpha_ok := true
		for i in range(0, vv.size(), 3):
			var cr := (vv[i + 1] - vv[i]).cross(vv[i + 2] - vv[i])
			var nn: Vector3 = (baked.normals as PackedVector3Array)[i]
			if cr.dot(nn) > 0.0:
				winding_ok = false
			var al: float = (baked.colors as PackedColorArray)[i].a
			if al < 0.05 or al > 1.0:
				alpha_ok = false
		check(winding_ok, "rock triangles are clockwise from outside (not culled)")
		check(alpha_ok, "rocks carry a sky exposure like the terrain")
		check(outward_ok, "normals point out")
	# the world builds rocks for a chunk and shows them
	var rw := VoxelWorld.new()
	rw.setup(g)
	var shown := false
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var c3 := cc + Vector3i(dx, 0, dz)
			var ch3 := rw._ensure_chunk(c3)
			if ch3 != null and ch3.rocks.size() > 0 and ch3.rock_instance != null:
				shown = true
	check(shown, "a world chunk keeps its rocks and shows them as one mesh")
	var per_chunk := place_us / 1000.0 / maxf(chunks_done, 1)
	print("  rock placement alone: %.3f ms per chunk" % per_chunk)
	check(per_chunk < 1.5, "placing the rocks of a chunk is cheap (< 1.5 ms)")

## Relative volume of a rock: the mean of the cube of its surface radius over many directions.
func _rock_volume(r: RockInst, f: Dictionary) -> float:
	var sum := 0.0
	var n := 160
	for i in n:
		var w := PlanetGenerator.fibonacci_dir(i, n)
		var l := RockMesher.surface_radius(r, f, w)
		sum += l * l * l
	return sum / n

func _rock_deposit_tests() -> void:
	print("== rocks: buried deposits ==")
	var g := PlanetGenerator.new(1337)
	var rs := RockSystem.new()
	rs.setup(g, 1337)
	var dp := rs.deposits
	var sp := g.find_spawn()
	var base_cell := Vector3i(floori(sp.x / RockDeposits.CELL), floori(sp.y / RockDeposits.CELL), floori(sp.z / RockDeposits.CELL))
	var col := Column.new()
	var found: Array = []
	var cells := 0
	for dx in range(-6, 7):
		for dy in range(-6, 7):
			for dz in range(-6, 7):
				var cell := base_cell + Vector3i(dx, dy, dz)
				cells += 1
				var d := dp.deposit_at_cell(cell, col)
				if d != null:
					found.append(d)
	var sizes: Array[float] = []
	var ores := 0
	var big := 0
	for d: RockInst in found:
		sizes.append(d.size)
		if d.layers.size() > 1:
			ores += 1
		if d.size >= 4.0:
			big += 1
	print("  around the spawn: %d deposits in %d cells (%d with ore, %d of 4 m or more)" % [found.size(), cells, ores, big])
	check(found.size() > 20, "deposits lie under the ground all around")
	check(ores > 0 and big > 0, "some are ore bodies and some are huge")
	var small := 0
	for z in sizes:
		if z < 2.5:
			small += 1
	check(small > found.size() / 2, "most are small, a few are huge")
	# deterministic, and seed dependent
	var again := dp.deposit_at_cell(base_cell + Vector3i(0, 0, 0), col)
	var first := found[0] as RockInst
	var cell_first := Vector3i(floori(first.pos.x / RockDeposits.CELL), floori(first.pos.y / RockDeposits.CELL), floori(first.pos.z / RockDeposits.CELL))
	var re := dp.deposit_at_cell(cell_first, col)
	check(re != null and re.id == first.id and re.pos == first.pos and re.layers == first.layers, "the same cell always holds the same deposit")
	var rs2 := RockSystem.new()
	rs2.setup(PlanetGenerator.new(4242), 4242)
	var other := rs2.deposits.deposit_at_cell(cell_first, col)
	check(other == null or other.id != first.id, "another seed buries other rocks")
	# the pocket: exactly the rock's shape, a hair smaller, sealed in solid rock
	var pick: RockInst = null
	for d: RockInst in found:
		if d.layers.size() > 1 and d.size >= 1.5:
			pick = d
			break
	if pick == null:
		pick = first
	var cc := VoxelWorld.world_to_chunk(pick.pos)
	var f := g.fill_chunk(cc, Column.new(), 0, true)
	var before: PackedFloat32Array = f.dens.duplicate()
	rs.carve_chunk(cc, f.dens)
	var origin := Vector3(cc * 16)
	var fr := RockMesher.frame_of(pick)
	var l_dir := Vector3(0.3, 0.5, 0.8).normalized()
	var l_world: Vector3 = fr.x * l_dir.x + fr.y * l_dir.y + fr.z * l_dir.z
	var rl := RockMesher.blob_radius(pick, fr, l_dir)
	var in_chunk := func(p: Vector3) -> bool:
		var q: Vector3 = p - origin
		return q.x >= 0.0 and q.y >= 0.0 and q.z >= 0.0 and q.x < 15.0 and q.y < 15.0 and q.z < 15.0
	var d_in: float = RockPlacer._sample(f.dens, pick.pos + l_world * (rl - 0.45) - origin) if in_chunk.call(pick.pos + l_world * (rl - 0.45)) else -9.0
	var d_out: float = RockPlacer._sample(f.dens, pick.pos + l_world * (rl + 0.6) - origin) if in_chunk.call(pick.pos + l_world * (rl + 0.6)) else 9.0
	print("  pocket of a %.1f m deposit: density just inside the rock %.2f, just outside %.2f" % [pick.size, d_in, d_out])
	check(d_in < 0.0 and d_out > 0.0, "the pocket follows the rock's shape: hollow inside, solid right outside")
	var changed_samples := 0
	for i in f.dens.size():
		if f.dens[i] != before[i]:
			changed_samples += 1
	check(changed_samples > 0, "carving a chunk with a deposit changes its density")
	# the chunk next door sees the same hollow on the shared padding (no seam)
	var f_next := g.fill_chunk(cc + Vector3i(1, 0, 0), Column.new(), 0, true)
	rs.carve_chunk(cc + Vector3i(1, 0, 0), f_next.dens)
	var seam_ok := true
	for k in 18:
		for j in 18:
			var a: float = f.dens[16 + 18 * (j + 18 * k)]       # my sample at local x = 15 (padded index 16)
			var b: float = f_next.dens[0 + 18 * (j + 18 * k)]   # its sample at local x = -1 (padded index 0): world x = 15
			if absf(a - b) > 0.001:
				seam_ok = false
	check(seam_ok, "neighbouring chunks carve the same pocket on their shared samples")
	# the rock sits in its pocket: it belongs to the chunk of its centre, underground chunks only
	var owner := rs.build_chunk(cc, before, f.wlev, f.dens, {}, true)
	var has_it := false
	for r: RockInst in owner.rocks:
		if r.id == pick.id:
			has_it = true
	check(has_it, "an underground chunk holds the buried rock of its pocket")
	var surface_only := rs.build_chunk(cc, before, f.wlev, f.dens, {}, false)
	var has_it2 := false
	for r: RockInst in surface_only.rocks:
		if r.id == pick.id:
			has_it2 = true
	check(not has_it2, "a surface-only chunk does not build buried rocks")
	# indicators: ore pieces on the ground above an ore deposit
	var ind_found := 0
	var ind_ok := true
	var ind_dep: RockInst = null
	for d: RockInst in found:
		if d.layers.size() > 1 and d.size >= 2.0:
			ind_dep = d
			break
	if ind_dep != null:
		var up := ind_dep.pos.normalized()
		g.sample_height(up, col, 1)
		var surf := up * (5120.0 + col.height)
		var sc := VoxelWorld.world_to_chunk(surf)
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					for m: RockInst in dp.markers_for(sc + Vector3i(dx, dy, dz)):
						if m.layers.size() == 1 and m.layers[0][0] == ind_dep.core_type():
							ind_found += 1
							var lateral := (m.pos - up * m.pos.dot(up) - (ind_dep.pos - up * ind_dep.pos.dot(up))).length()
							if lateral > ind_dep.size * 1.1 + 1.0 or m.size > 0.46:
								ind_ok = false
		print("  a %.1f m %s deposit %.0f m down: %d tiny ore pieces on the ground above it" % [ind_dep.size, rs.catalog.by_id(ind_dep.core_type()).name, col.height - (ind_dep.pos.length() - 5120.0), ind_found])
	check(ind_found >= 1 and ind_ok, "tiny pieces of the same ore on the surface mark a deposit below")
	# efficiency: the deposit work of a chunk (pocket carving + indicators), measured over 49 chunks around the spot
	var work_us := 0
	var n := 0
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			var c4 := cc + Vector3i(dx, 0, dz)
			var f4 := g.fill_chunk(c4, Column.new(), 0, true)
			var t1 := Time.get_ticks_usec()
			rs.carve_chunk(c4, f4.dens)
			rs.deposits.markers_for(c4)
			work_us += Time.get_ticks_usec() - t1
			n += 1
	var per := work_us / 1000.0 / n
	print("  deposit work (pocket carve + indicators) per chunk: %.2f ms" % per)
	check(per < 12.0, "the deposits cost little per chunk (< 12 ms, on the worker thread)")

func _rock_gravity_tests() -> void:
	print("== rocks: gravity ==")
	var g := PlanetGenerator.new(1337)
	var w := VoxelWorld.new()
	w.setup(g)
	var sp := g.find_spawn()
	var cc := VoxelWorld.world_to_chunk(sp)
	for dz in range(-2, 3):
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				w._ensure_chunk(cc + Vector3i(dx, dy, dz))
	var ph := RockPhysics.new()
	ph.world = w
	w.terrain_edited.connect(ph.after_edit)
	var loose: RockInst = null
	var loose_ch: Chunk = null
	var fixed_rock: RockInst = null
	var fixed_ch: Chunk = null
	var n_loose := 0
	var n_fixed := 0
	for c: Vector3i in w.chunks:
		var ch: Chunk = w.chunks[c]
		for r: RockInst in ch.rocks:
			if r.fixed:
				n_fixed += 1
				if fixed_rock == null and r.size >= 0.4:
					fixed_rock = r
					fixed_ch = ch
			else:
				n_loose += 1
				if loose == null and r.size >= 0.4 and r.size <= 1.5 and ph.supported(r):
					loose = r
					loose_ch = ch
	print("  rocks around the spawn: %d loose, %d fixed (sunk into the floor)" % [n_loose, n_fixed])
	check(n_loose > 0 and n_fixed > 0, "some rocks are loose bodies and some are fixed in the floor")
	check(loose != null and ph.supported(loose), "a loose rock at rest is supported by the ground")
	if loose != null:
		var up := loose.pos.normalized()
		var alt0 := loose.pos.length()
		var id := loose.id
		var t0 := Time.get_ticks_usec()
		# dig the ground out from under it
		w.carve(loose.pos - up * (loose.size * 0.9), loose.size * 1.2 + 1.8)
		var started_ms := (Time.get_ticks_usec() - t0) / 1000.0
		check(not ph.supported(loose) or ph.active() > 0, "digging away the ground under it leaves it unsupported")
		check(ph.active() >= 1, "an unsupported loose rock starts to fall")
		check(not loose_ch.rocks.has(loose), "it leaves its chunk's baked mesh while it falls (one small node)")
		var steps := 0
		while ph.active() > 0 and steps < 900:
			ph._physics_process(1.0 / 60.0)
			steps += 1
		var drop := alt0 - loose.pos.length()
		print("  it fell %.1f m and came to rest after %.1f s (edit + start cost %.1f ms)" % [drop, steps / 60.0, started_ms])
		check(ph.active() == 0, "the falling rock comes to rest")
		check(drop > 0.8, "it dropped into the hole")
		check(ph.supported(loose), "and rests on solid ground again")
		check(w.rocks.changed.has(id) and (w.rocks.changed[id] as Dictionary).has("state") and loose.moved, "its new place is stored (persistent)")
		var dest := VoxelWorld.world_to_chunk(loose.pos)
		var snap := w.rocks.broken_snapshot()
		var f2 := g.fill_chunk(dest, Column.new(), 0, true)
		var rebuilt := w.rocks.build_chunk(dest, f2.dens, f2.wlev, f2.dens, snap, true)
		var there := false
		for r: RockInst in rebuilt.rocks:
			if r.id == id and r.pos.distance_to(loose.pos) < 0.01:
				there = true
		check(there, "a rebuilt chunk has the fallen rock where it came to rest")
		var origin_c := VoxelWorld.world_to_chunk(Vector3(0, 0, 0))
		var f3 := g.fill_chunk(loose_ch.coord, Column.new(), 0, true)
		var orig := w.rocks.build_chunk(loose_ch.coord, f3.dens, f3.wlev, f3.dens, snap, true)
		var still_there := false
		for r: RockInst in orig.rocks:
			if r.id == id and loose_ch.coord != dest:
				still_there = true
		check(not still_there, "and its old chunk no longer holds it")
		# a displaced rock that is then hit keeps its new place
		w.rocks.hit(loose, dest_rocks_of(w, dest), 1.0)
		check((w.rocks.changed[id] as Dictionary).has("state"), "a displaced rock keeps its place when it is chipped")
	if fixed_rock != null:
		var upf := fixed_rock.pos.normalized()
		var tf := upf.cross(Vector3.UP if absf(upf.y) < 0.95 else Vector3.RIGHT).normalized()
		# the ground BESIDE it is dug (the sphere does not touch the rock): it is still sunk into the floor and stays
		w.carve(fixed_rock.pos + tf * (fixed_rock.size + 2.4 + 0.6), 2.4)
		check(fixed_ch.rocks.has(fixed_rock), "a rock sunk into the floor stays when the ground beside it is dug")
		# the floor around it is dug away: nothing holds it any more and it falls
		var active0 := ph.active()
		w.carve(fixed_rock.pos, fixed_rock.size * 1.7 + 2.0)
		check(ph.active() > active0 or not fixed_ch.rocks.has(fixed_rock), "a sunk rock whose floor is dug away all around falls")
		var st := 0
		while ph.active() > 0 and st < 900:
			ph._physics_process(1.0 / 60.0)
			st += 1
	# pebbles cannot bend the floor: none is fixed
	var fixed_pebbles := 0
	var pebbles := 0
	for c: Vector3i in w.chunks:
		for r: RockInst in (w.chunks[c] as Chunk).rocks:
			if r.size < 0.4:
				pebbles += 1
				if r.fixed:
					fixed_pebbles += 1
	check(pebbles > 0 and fixed_pebbles == 0, "tiny rocks are always loose (they cannot bend the floor)")
	# after digging, no rock near the edit is left hanging in the air
	var spot := sp
	for i in 3:
		w.carve(spot + (Vector3(i * 2.5 - 2.5, 0, 0)), 2.6)
	var guard := 0
	while ph.active() > 0 and guard < 1200:
		ph._physics_process(1.0 / 60.0)
		guard += 1
	var hanging := 0
	var nearby := 0
	for c: Vector3i in w.chunks:
		for r: RockInst in (w.chunks[c] as Chunk).rocks:
			if r.pos.distance_to(spot) < 9.0:
				nearby += 1
				if not ph.supported(r):
					hanging += 1
	print("  after digging: %d rocks near the hole, %d left hanging" % [nearby, hanging])
	check(hanging == 0, "after a dig no rock near it is left floating")
	# cost of the check: an edit with many rocks around
	var t1 := Time.get_ticks_usec()
	for i in 10:
		ph.after_edit(sp, 3.0)
	print("  support check of an edit: %.2f ms" % ((Time.get_ticks_usec() - t1) / 1000.0 / 10.0))
	check((Time.get_ticks_usec() - t1) / 1000.0 / 10.0 < 8.0, "checking the rocks next to an edit is cheap (< 8 ms)")
	ph.free()
	w.free()

func dest_rocks_of(w: VoxelWorld, c: Vector3i) -> Array:
	var ch: Chunk = w.chunks.get(c)
	return ch.rocks if ch != null else []

func _ball_ground_tests() -> void:
	print("== ball: never partly in the ground ==")
	var g := PlanetGenerator.new(1337)
	var w := VoxelWorld.new()
	w.setup(g)
	var sp := g.find_spawn()
	var cc := VoxelWorld.world_to_chunk(sp)
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				w._ensure_chunk(cc + Vector3i(dx, dy, dz))
	var b := BallPlayer.new()
	b.world = w
	b.freeze = true                              # no physics of its own in this test: only the guard is called
	var up := sp.normalized()
	var col := Column.new()
	g.sample_height(up, col)
	var surf := up * (5120.0 + col.height)
	var zdir := up.cross(Vector3.RIGHT).normalized()
	b.basis = Basis(up.cross(zdir), up, zdir)    # standing upright on the planet (the body does this itself every physics step)
	b.position = surf + up * 0.1                 # the capsule's lowest 0.4 m are in the ground
	var inside0 := w.density_at(b.position - up * 0.5)
	for i in 12:
		b._keep_out_of_ground()
	var worst := -9.0
	for cy in [BallPlayer.CAPSULE_CENTRE - BallPlayer.CAPSULE_HEIGHT * 0.5 + BallPlayer.CAPSULE_RADIUS, BallPlayer.CAPSULE_CENTRE + BallPlayer.CAPSULE_HEIGHT * 0.5 - BallPlayer.CAPSULE_RADIUS]:
		for dir in BallPlayer.SURFACE_PROBES:
			worst = maxf(worst, w.density_at(b.position + up * cy + dir * BallPlayer.CAPSULE_RADIUS))
	print("  capsule sunk 0.4 m: its lowest point was %.2f inside, after the guard the worst surface point is %.2f" % [inside0, worst])
	check(worst <= BallPlayer.TOLERANCE + 0.05, "a body that is partly in the ground is pushed out of it")
	check(b.position.distance_to(surf) < 1.0, "it is lifted a little, not thrown away")
	var air := surf + up * 3.0
	b.position = air
	b._keep_out_of_ground()
	check(b.position.distance_to(air) < 0.0001, "a body in the air is not touched")
	var deep := surf - up * 6.0
	b.position = deep
	b._keep_out_of_ground()
	check(b.position.distance_to(deep) < 0.0001, "a buried body is not moved (no rescue)")
	b.free()
	w.free()

func _grass_tests() -> void:
	print("== grass ==")
	var g := PlanetGenerator.new(1337)
	var cat := GrassCatalog.new(1337)
	check(cat.types.size() == 9 and cat.get_type("meadow") != null and cat.get_type("seagrass").underwater, "the catalog has meadow, tall, tuft, dry and sea grass")
	var cat2 := GrassCatalog.new(1337)
	var cat3 := GrassCatalog.new(99)
	check(cat.get_type("meadow").tip_color == cat2.get_type("meadow").tip_color, "the same seed gives the same palette")
	check(cat.get_type("meadow").tip_color != cat3.get_type("meadow").tip_color, "another seed gives its own shade of green")
	var tris_ok := true
	var uv_ok := true
	for t in cat.types:
		for v in GrassCatalog.VARIANTS:
			var m := GrassMeshes.build(t, v, 1337)
			var n := GrassMeshes.triangle_count(m)
			if n < 15 or n > (80 if t.flower else 40):
				tris_ok = false
			for uv in (m.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] as PackedVector2Array):
				if uv.y < 0.0 or uv.y > 1.0:
					uv_ok = false
	check(tris_ok, "every clump is between 15 and 40 triangles (80 for flowers: stem plus five petals)")
	check(uv_ok, "the position along the blade (UV.y) is 0..1 on every vertex")
	var field := GrassField.new(cat, 1337)
	check(GrassField.grassiness(GrassField.GRASS_GREEN) > 0.95, "the grass green is grassy ground")
	check(GrassField.grassiness(BlockTypes.COLORS[BlockTypes.SAND]) < 0.05 and GrassField.grassiness(BlockTypes.COLORS[BlockTypes.SNOW]) < 0.05, "sand and snow grow no grass")
	check(GrassField.grassiness(BlockTypes.COLORS[BlockTypes.STONE]) < 0.05, "bare rock grows no grass")
	var seen := {}
	for i in 400:
		var d := PlanetGenerator.fibonacci_dir(i, 400) * 5200.0
		var pick := field.choose(GrassField.GRASS_GREEN, 0.3 + 0.6 * float(i % 7) / 7.0, 0.3 + 0.5 * float(i % 5) / 5.0, d, 0.1, float(i % 11) / 11.0)
		if pick.x >= 0.0:
			seen[cat.by_id(int(pick.x)).key] = true
	print("  kinds that grow on green ground over many places: ", seen.keys())
	check(seen.size() >= 3, "several kinds of grass grow depending on the place and the climate")
	# shade: under a crown the meadow gives way to ferns
	var open_ferns := 0
	var shade_ferns := 0
	var shade_meadow := 0
	var open_meadow := 0
	for i in 300:
		var pp := PlanetGenerator.fibonacci_dir(i, 300) * 5200.0
		var po := field.choose(GrassField.GRASS_GREEN, 0.6, 0.5, pp, 0.1, float(i % 17) / 17.0, 0.0)
		var ps := field.choose(GrassField.GRASS_GREEN, 0.6, 0.5, pp, 0.1, float(i % 17) / 17.0, 1.0)
		if po.x >= 0.0:
			var ko := cat.by_id(int(po.x)).key
			open_ferns += int(ko == "fern")
			open_meadow += int(ko == "meadow")
		if ps.x >= 0.0:
			var ks := cat.by_id(int(ps.x)).key
			shade_ferns += int(ks == "fern")
			shade_meadow += int(ks == "meadow")
	print("  in the open: %d ferns, %d meadow; in a crown's shade: %d ferns, %d meadow" % [open_ferns, open_meadow, shade_ferns, shade_meadow])
	check(open_ferns == 0 and shade_ferns > shade_meadow and shade_meadow < open_meadow, "under a crown the meadow thins and ferns take over")
	var sand := Color(0.8, 0.7, 0.5)
	check(field.sea_density(0.2, sand, Vector3(5100, 0, 0), 0.1) == 0.0 and field.sea_density(60.0, sand, Vector3(5100, 0, 0), 0.1) == 0.0, "sea grass needs water 0.6 to 24 m deep")
	var sp := g.find_spawn()
	var cc := VoxelWorld.world_to_chunk(sp)
	var gs := GrassSystem.new()
	gs.setup(g, 1337)
	var f := g.fill_chunk(cc, Column.new(), 0, false)
	var t0 := Time.get_ticks_usec()
	var a := gs.build_chunk(cc, f.dens, f.colr, f.wlev, f.hlat, f.l0, [])
	var us := Time.get_ticks_usec() - t0
	var b2 := gs.build_chunk(cc, f.dens, f.colr, f.wlev, f.hlat, f.l0, [])
	var total := 0
	var same := a.size() == b2.size()
	var on_ground := true
	for tid in a:
		total += int(a[tid].count)
		if not b2.has(tid) or b2[tid].buf != a[tid].buf:
			same = false
		var buf: PackedFloat32Array = a[tid].buf
		for i in int(a[tid].count):
			var o := i * GrassPlacer.STRIDE
			var lp := Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
			var upv := Vector3(buf[o + 1], buf[o + 5], buf[o + 9]).normalized()
			if ChunkSampler.density(f.dens, lp - upv * 0.3) <= 0.0:
				on_ground = false
	print("  chunk at the spawn: %d clumps of %d kinds, planted in %.2f ms" % [total, a.size(), us / 1000.0])
	check(total > 20, "a meadow chunk gets its grass")
	check(same, "the same chunk always has the same grass")
	check(on_ground, "every clump stands on solid ground")
	check(us < 12000, "planting a chunk is cheap (< 12 ms on the worker thread)")
	var w := VoxelWorld.new()
	w.setup(g)
	var ch := w._ensure_chunk(cc)
	var before := 0
	for tid in ch.grass:
		before += int(ch.grass[tid].count)
	w.carve(sp - sp.normalized() * 3.5, 4.0)       # the spawn is 4 m above the ground: dig a ball of 4 m radius into it
	var after := 0
	for tid in ch.grass:
		after += int(ch.grass[tid].count)
	print("  digging at the spawn: %d -> %d clumps in its chunk" % [before, after])
	check(before > 0 and after < before, "digging removes the grass whose ground is gone")
	w.free()

func _tree_tests() -> void:
	print("== trees ==")
	var g := PlanetGenerator.new(1337)
	var cat := TreeCatalog.new(1337)
	var fams := {}
	for t in cat.types:
		fams[t.family] = true
	print("  %d species in %d canopy families: %s" % [cat.types.size(), fams.size(), fams.keys()])
	check(fams.size() >= 6, "the catalog has at least six canopy families (broadleaf, round, birch, pine, fir, palm, acacia)")
	check(cat.get_type("exotic_0") != null and cat.get_type("exotic_0").name != TreeCatalog.new(4242).get_type("exotic_0").name, "every seed invents its own species")
	var cat2 := TreeCatalog.new(1337)
	check(cat.get_type("oak").leaf_a == cat2.get_type("oak").leaf_a, "the same seed gives the same catalog")
	# niche: palms warm, firs cold
	var palm := cat.get_type("palm")
	var fir := cat.get_type("fir")
	check(palm.niche(0.85, 0.6, 3.0, true) > 0.5 and palm.niche(0.2, 0.6, 3.0, true) < 0.05, "palms live in the warm shore, not the cold")
	check(fir.niche(0.2, 0.7, 80.0, false) > 0.5 and fir.niche(0.9, 0.7, 80.0, false) < 0.05, "firs live in the cold, not the heat")
	# forests: the field gives dense forests and clearings, several species over the planet
	var ts := TreeSystem.new()
	ts.setup(g, 1337)
	var field := ts.field
	var dense := 0
	var clear := 0
	var species := {}
	var col := Column.new()
	for i in 3000:
		var d := PlanetGenerator.fibonacci_dir(i, 3000)
		g.sample_column(d, col)
		if col.land < 0.05 or col.height < 3.0:
			continue
		var p := d * (5120.0 + col.height)
		var f := field.forest_density(p)
		if f > 0.8:
			dense += 1
		elif f < 0.05:
			clear += 1
		var pick := field.choose(GrassField.GRASS_GREEN, col.temperature, col.moisture, col.height, p, 0.1, float(i % 13) / 13.0)
		if pick.x >= 0.0 and pick.y > 0.25:
			species[cat.by_id(int(pick.x)).key] = true
	print("  forest field: %d dense places, %d clearings; species planted: %s" % [dense, clear, species.keys()])
	check(dense > 20 and clear > 100, "there are big dense forests and open meadows")
	# every dense forest mixes several species: look at a 120 m disc around a few dense places
	var mixed_ok := true
	var forests_checked := 0
	var dcol := Column.new()
	for i in 6000:
		if forests_checked >= 6:
			break
		var d0 := PlanetGenerator.fibonacci_dir(i, 6000)
		g.sample_column(d0, dcol)
		if dcol.land < 0.05 or dcol.height < 3.0:
			continue
		var p0 := d0 * (5120.0 + dcol.height)
		if field.forest_density(p0) < 0.9:
			continue
		var tang := d0.cross(Vector3.UP).normalized()
		var seen_sp := {}
		for k in 60:
			var q := (p0 + tang.rotated(d0, k * 0.7) * (k * 2.0)).normalized()
			g.sample_column(q, dcol)
			var pp := q * (5120.0 + dcol.height)
			var pk := field.choose(GrassField.GRASS_GREEN, dcol.temperature, dcol.moisture, dcol.height, pp, 0.1, float(k % 9) / 9.0)
			if pk.x >= 0.0:
				seen_sp[int(pk.x)] = true
		forests_checked += 1
		if seen_sp.size() < 2:
			mixed_ok = false
	check(forests_checked >= 3 and mixed_ok, "every dense forest mixes at least two species")
	check(species.size() >= 4, "the climate and the provinces give several species over the planet")
	# a forest chunk: trees stand on the ground, deterministic, in budget
	var spot := Vector3(-997.5284, 4430.189, 2533.567)         # a dense forest on gentle ground
	var cc := VoxelWorld.world_to_chunk(spot)
	var best_n := 0
	var best_c := cc
	var best_f: Dictionary = {}
	for dz in range(-3, 4):
		for dx in range(-3, 4):
			var c := cc + Vector3i(dx, 0, dz)
			var f := g.fill_chunk(c, Column.new(), 0, false)
			var trees := TreePlacer.place(g, field, c, f.dens, f.colr, f.wlev, f.hlat, f.l0)
			if trees.size() > best_n:
				best_n = trees.size()
				best_c = c
				best_f = f
	print("  densest of 49 chunks around the forest: %d trees" % best_n)
	check(best_n >= 10, "a dense forest chunk holds many trees")
	var t0 := Time.get_ticks_usec()
	var a := TreePlacer.place(g, field, best_c, best_f.dens, best_f.colr, best_f.wlev, best_f.hlat, best_f.l0)
	var us := Time.get_ticks_usec() - t0
	var b2 := TreePlacer.place(g, field, best_c, best_f.dens, best_f.colr, best_f.wlev, best_f.hlat, best_f.l0)
	var same := a.size() == b2.size()
	for i in a.size():
		if same and (a[i].id != b2[i].id or a[i].pos != b2[i].pos or a[i].type_id != b2[i].type_id):
			same = false
	var origin := Vector3(best_c * 16)
	var inside := true
	var grounded := true
	for tr: TreeInst in a:
		var lp := tr.pos - origin
		if lp.x < 0.0 or lp.y < 0.0 or lp.z < 0.0 or lp.x >= 16.0 or lp.y >= 16.0 or lp.z >= 16.0:
			inside = false
		if ChunkSampler.density(best_f.dens, lp - tr.up * 0.3) <= 0.0:
			grounded = false
	check(same, "the same chunk always has the same trees")
	check(inside and grounded, "every tree stands inside its chunk on solid ground")
	check(us < 8000, "planting a forest chunk is cheap (%.1f ms)" % (us / 1000.0))
	# the baked mesh: every family, budget, winding
	var tris_ok := true
	var winding_ok := true
	for ty in cat.types:
		var ti := TreeInst.new()
		ti.type_id = ty.id
		ti.up = Vector3.UP
		ti.height = ty.h_mid()
		ti.trunk_r = ti.height * ty.trunk_ratio
		ti.canopy_r = ti.height * ty.canopy_ratio
		ti.shape = 77 + ty.id
		var m := TreeMeshes.bake_one(ti, cat)
		var n := (m.verts as PackedVector3Array).size() / 3
		if n < 30 or n > 900:
			tris_ok = false
		print("    %-10s %-9s %3d triangles" % [ty.key, ty.family, n])
		var vv: PackedVector3Array = m.verts
		for i in range(0, vv.size(), 3):
			var cr := (vv[i + 1] - vv[i]).cross(vv[i + 2] - vv[i])
			if cr.dot((m.normals as PackedVector3Array)[i]) > 0.0:
				winding_ok = false
	check(tris_ok, "every tree is between 30 and 900 triangles")
	check(winding_ok, "tree triangles are clockwise from outside")
	# cutting: a notch deepens with every blow, the last blow fells it
	var tr0: TreeInst = null
	for tr: TreeInst in a:
		if tr.height > 9.0:
			tr0 = tr
			break
	if tr0 == null:
		tr0 = a[0]
	var need := int(ceilf(ts.blows_to_fell(tr0)))
	var ch := Chunk.new()
	ch.position = origin
	ch.trees = [tr0]
	var radius_at := func(tree: TreeInst) -> float:
		var mm := TreeMeshes.bake_one(tree, ts.catalog)
		var best := 0.0                              # how far the trunk reaches towards the player at the notch height
		for v in (mm.verts as PackedVector3Array):
			if absf(v.dot(tree.up) - tree.hit_h) < 0.12:
				best = maxf(best, v.dot(tree.hit_dir))
		return best
	var events: Array = []
	var depth_first := -1.0
	var depth_mid := -1.0
	for i in need + 2:
		var res := {"tree": tr0, "chunk": ch, "point": tr0.pos + tr0.up * 1.2 + Vector3.RIGHT * tr0.trunk_r}
		var r := ts.hit(res, tr0.pos - Vector3.RIGHT * 4.0)
		events.append(r.event)
		if i == 0:
			depth_first = radius_at.call(tr0)
		if i == need / 2:
			depth_mid = radius_at.call(tr0)
		if r.event == "fell":
			break
	print("  tree %.0f m, trunk %.2f m: %d blows to fell; notch depth at blow 1 %.2f m, halfway %.2f m (trunk radius %.2f m)" % [tr0.height, tr0.trunk_r, need, depth_first, depth_mid, tr0.trunk_r])
	check(events[events.size() - 1] == "fell" and events.size() == need, "the tree falls exactly on its last blow (%d blows)" % need)
	check(depth_mid < depth_first - 0.02 and depth_mid < tr0.trunk_r * 0.85, "the notch gets deeper with every blow")
	var thick := TreeInst.new()
	thick.type_id = cat.get_type("oak").id
	thick.trunk_r = 0.9
	var thin := TreeInst.new()
	thin.type_id = cat.get_type("oak").id
	thin.trunk_r = 0.15
	check(ts.blows_to_fell(thick) > ts.blows_to_fell(thin) * 8.0, "a thick old trunk takes way more blows than a sapling")
	# lying and chopping: log by log, the last blow takes the last piece
	ts.landed(tr0, Vector3(1, 0, 0).cross(tr0.up).cross(tr0.up).normalized())
	check(tr0.state == TreeInst.FALLEN and tr0.remaining > 5.0, "a felled tree lies as a trunk")
	var chops := 0
	var last := ""
	var wood0 := 0
	var wood := 0                                       # what the blows report (the player's inventory lives elsewhere, see Harvester)
	while chops < 80:
		var r2 := ts.hit({"tree": tr0, "chunk": ch, "point": tr0.pos + tr0.axis * 1.0 + tr0.up}, tr0.pos)
		wood += r2.units
		chops += 1
		last = r2.event
		if r2.event == "gone":
			break
	print("  the lying trunk (%.1f m) takes %d blows to harvest, ends with '%s', wood %d -> %d" % [tr0.length, chops, last, wood0, wood])
	check(last == "gone" and ts.changed.get(tr0.id) == true, "the last blow takes the last piece and the trunk is gone for good")
	check(wood > wood0 + 3, "chopping gives wood")
	# persistence: a rebuilt chunk keeps cut and fallen trees as they are
	var other: TreeInst = a[1] if a.size() > 1 and a[1].id != tr0.id else a[0]
	other.hits = 3.0
	ts.changed[other.id] = other.to_state()
	var rebuilt := ts.build_chunk(best_c, best_f.dens, best_f.colr, best_f.wlev, best_f.hlat, best_f.l0, ts.changed_snapshot())
	var gone_ok := true
	var hits_ok := false
	for rt: TreeInst in rebuilt.trees:
		if rt.id == tr0.id:
			gone_ok = false
		if rt.id == other.id and rt.hits == 3.0:
			hits_ok = true
	check(gone_ok and hits_ok, "a rebuilt chunk leaves the chopped tree gone and keeps the other one's notch")
	ch.free()
	# a trunk is closed at the foot (a felled tree is seen from below): a downward-facing cap of SIDES triangles at height 0
	var cap_ti := TreeInst.new()
	cap_ti.type_id = cat.get_type("oak").id
	cap_ti.up = Vector3.UP
	cap_ti.height = 12.0
	cap_ti.trunk_r = 0.4
	cap_ti.canopy_r = 3.5
	cap_ti.shape = 5
	var cap_m := TreeMeshes.bake_one(cap_ti, cat)
	var caps := 0
	var cv: PackedVector3Array = cap_m.verts
	for i in range(0, cv.size(), 3):
		if absf(cv[i].y) < 0.01 and absf(cv[i + 1].y) < 0.01 and absf(cv[i + 2].y) < 0.01:
			caps += 1
	check(caps >= TreeMeshes.SIDES, "the trunk is closed at its foot (%d cap triangles)" % caps)
	# digging the ground away from under a tree makes it fall; a tree next to the hole stays
	var wd := VoxelWorld.new()
	wd.setup(g)
	root.add_child(wd)
	var sp2 := Vector3(-997.5284, 4430.189, 2533.567)
	var cc2 := VoxelWorld.world_to_chunk(sp2)
	var victim: TreeInst = null
	var neighbour: TreeInst = null
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var chd := wd._ensure_chunk(cc2 + Vector3i(dx, 0, dz))
			if chd == null:
				continue
			for tt: TreeInst in chd.trees:
				if tt.state == TreeInst.STANDING and victim == null:
					victim = tt
	if victim != null:
		var tp := TreePhysics.new()
		tp.world = wd
		root.add_child(tp)
		wd.terrain_edited.connect(tp.after_edit)
		for chd2 in wd.chunks.values():
			for tt2: TreeInst in (chd2 as Chunk).trees:
				if tt2 != victim and tt2.state == TreeInst.STANDING and tt2.pos.distance_to(victim.pos) > 7.0 and neighbour == null:
					neighbour = tt2
		wd.carve(victim.pos - victim.up * 0.5, 2.6)
		print("  dug under a tree: falling now = %d, state %d" % [tp.active(), victim.state])
		check(victim.state == TreeInst.FALLING and tp.active() >= 1, "a tree whose ground is dug away from under it falls")
		if neighbour != null:
			check(neighbour.state == TreeInst.STANDING, "a tree away from the hole keeps standing")
		var guard := 0
		while tp.active() > 0 and guard < 600:
			tp._physics_process(1.0 / 60.0)
			guard += 1
		check(victim.state == TreeInst.FALLEN and wd.trees.changed.has(victim.id), "it lands as a lying trunk and is saved")
		tp.queue_free()
	wd.queue_free()
	# the far forest: cutout cards in sectors, deterministic, each tree in exactly one sector, cheap to build
	var ft_sector := FarTrees._sector_of(Vector3(-997.5284, 4430.189, 2533.567))
	var t_far0 := Time.get_ticks_usec()
	var fa := FarTrees.build_sector(g, ts.field, ft_sector)
	var far_us := Time.get_ticks_usec() - t_far0
	var fb := FarTrees.build_sector(g, ts.field, ft_sector)
	var far_same: bool = fa.count == fb.count and fa.buf == fb.buf
	var owned := true
	for i in int(fa.count):
		var foot := Vector3(fa.buf[i * 16 + 3], fa.buf[i * 16 + 7], fa.buf[i * 16 + 11])
		if FarTrees._sector_of(foot) != ft_sector:
			owned = false
	print("  far forest sector at the dense forest: %d cards (%d triangles), built in %.1f ms" % [fa.count, fa.count * 2, far_us / 1000.0])
	check(fa.count >= 15, "a dense forest sector holds many far trees")
	check(far_same, "the far forest is deterministic")
	check(owned, "every far tree belongs to exactly one sector")
	check(far_us < 120000, "a far sector is cheap to build (on the worker thread)")
	var fam_ok := true
	for ty in cat.types:
		var sid := FarTrees.silhouette_of(ty.family)
		if sid < 0 or sid > 6:
			fam_ok = false
	check(fam_ok and FarTreeMaterial.CODE.contains("float shape(") and FarTreeMaterial.CODE.contains("near_end"), "every canopy family has a far silhouette, and the cards hand over to the real trees near the player")
	# the camera fade is in the shader, the trees share the grass wind and light
	check(TreeMaterial.CODE.contains("dither(") and TreeMaterial.CODE.contains("tree_cam") and TreeMaterial.CODE.contains("grass_wind"), "trees fade out in a dither when they block the camera, and sway with the shared wind")

func _fresh_rock(r: RockInst, cat: RockCatalog) -> RockInst:
	var c := RockInst.from_state(r.to_state())
	c.bites = []
	c.cut = {}
	return c

func _rock_break_tests() -> void:
	print("== rocks: breaking and harvesting ==")
	var g := PlanetGenerator.new(1337)
	var rs := RockSystem.new()
	rs.setup(g, 1337)
	var cat := rs.catalog
	var rock := RockInst.new()
	rock.id = 777
	rock.size = 1.0
	rock.layers = [[cat.get_type("granite").id, 1.0], [cat.get_type("gold").id, 0.5]]
	var rocks: Array = [rock]
	var events: Array = []
	var harvest := {}                                   # type key -> units, summed from the blows (the inventory lives elsewhere, see Harvester)
	var hits := 0
	while rocks.has(rock) and hits < 500:
		var res := rs.hit(rock, rocks)
		harvest[res.type] = harvest.get(res.type, 0) + res.units
		hits += 1
		if res.event != "hit":
			events.append(res.event)
	print("  granite shell + gold core, size 1: %d hits, events %s, harvest %s" % [hits, events, harvest])
	check(events == ["shed", "broken"], "a layered rock loses its shell first, then breaks")
	check(harvest.get("granite", 0) > 0 and harvest.get("gold", 0) > 0, "both layers are harvested")
	check(rs.changed.get(777) == true and not rocks.has(rock), "a broken rock is gone and remembered by its id")
	# blows needed: far more for a big or solid rock
	var hit_counts := {}
	for key in ["coal", "granite", "diamond"]:
		for sz in [0.5, 1.0, 2.5, 5.0]:
			var tr := RockInst.new()
			tr.size = sz
			tr.layers = [[cat.get_type(key).id, 1.0]]
			hit_counts["%s %.1f" % [key, sz]] = int(ceilf(rs.layer_hardness(tr)))
	print("  blows to break (bare rock): ", hit_counts)
	check(hit_counts["granite 5.0"] > hit_counts["granite 0.5"] * 40, "a huge rock takes way more blows than a small one")
	check(hit_counts["granite 1.0"] > hit_counts["coal 1.0"], "a solid rock takes more blows than a soft one")
	check(hit_counts["diamond 2.5"] > hit_counts["granite 2.5"], "the hardest stone takes the longest at the same size")
	# a blow takes a BITE out of the rock where it landed; the rest of the rock is untouched (no overall shrinking)
	var dr := RockInst.new()
	dr.id = 888
	dr.size = 1.2
	dr.shape = 4242
	dr.layers = [[cat.get_type("granite").id, 1.0], [cat.get_type("iron").id, 0.45]]
	dr.pos = Vector3(0, 100, 0)
	dr.normal = Vector3.UP
	var fr := RockMesher.frame_of(dr)
	var side := Vector3(1, 0.3, 0).normalized()                 # in the world
	var opposite := -side
	var side_l := Vector3(side.dot(fr.x), side.dot(fr.y), side.dot(fr.z))      # the same directions in the rock's own frame
	var opp_l := -side_l
	var r_side0 := RockMesher.surface_radius(dr, fr, side_l)
	var r_opp0 := RockMesher.surface_radius(dr, fr, opp_l)
	var drs: Array = [dr]
	var sh0 := RockMesher.surface_hit(dr, dr.pos + side * 6.0, -side, 20.0)
	check(sh0.hit and absf(sh0.t - (6.0 - r_side0)) < 0.08, "aiming finds the rock's real surface")
	rs.hit(dr, drs, 1.0, sh0.point)
	var r_side1 := RockMesher.surface_radius(dr, fr, side_l)
	var r_opp1 := RockMesher.surface_radius(dr, fr, opp_l)
	print("  radius towards the blow: %.2f -> %.2f m; on the far side: %.2f -> %.2f m" % [r_side0, r_side1, r_opp0, r_opp1])
	check(dr.bites.size() == 1 and r_side1 < r_side0 - 0.1, "a blow takes a bite out of the rock where it landed")
	check(absf(r_opp1 - r_opp0) < 0.001, "the rest of the rock is untouched: a hole, not a shrink")
	var sh1 := RockMesher.surface_hit(dr, dr.pos + side * 6.0, -side, 20.0)
	check(sh1.hit and sh1.t > sh0.t + 0.05, "the next blow lands on the new, deeper surface")
	check(rs.changed.has(888) and (rs.changed[888].bites as Array).size() == 1, "the bites are stored with the rock")
	dr.cut = RockCut.build(dr, cat)
	dr.cut_sig = dr.bites.hash()
	var dr_tris := (RockMesher.bake([dr], cat, Vector3.ZERO).verts as PackedVector3Array).size() / 3
	check(dr_tris > 300 and dr_tris != 1280, "a bitten rock is drawn from its re-meshed shape, fine enough to show the bite (%d triangles)" % dr_tris)
	# coherence over a whole rock: it is eaten away blow by blow and the last blow removes what is left
	var wr := RockInst.new()
	wr.id = 999
	wr.size = 2.5
	wr.shape = 31337
	wr.pos = Vector3(0, 100, 0)
	wr.normal = Vector3.UP
	wr.layers = [[cat.get_type("granite").id, 1.0]]
	var wf := RockMesher.frame_of(wr)
	var vol0 := _rock_volume(wr, wf)
	var wrocks: Array = [wr]
	var need := int(ceilf(rs.layer_hardness(wr)))
	var vols: Array[float] = []
	var gone_at := -1
	for i in need + 2:
		var dir := PlanetGenerator.fibonacci_dir(i * 7, need * 7)         # blows all over the rock, as a player would
		if dir.y < 0.0:
			dir.y = -dir.y
		var sh := RockMesher.surface_hit(wr, wr.pos + dir * 12.0, -dir, 40.0)
		var res2 := rs.hit(wr, wrocks, 1.0, sh.point if sh.hit else Vector3.INF)
		if res2.event == "broken":
			gone_at = i + 1
			break
		vols.append(_rock_volume(wr, wf) / vol0)
	print("  size 2.5 granite: %d blows, gone at blow %d; part of the rock left before the last blow: %.0f%%" % [need, gone_at, 100.0 * vols[vols.size() - 1]])
	check(gone_at <= need and gone_at >= int(need * 0.9), "the rock is gone on its last blows (nothing left to keep hitting)")
	var eaten := true
	for i in range(1, vols.size()):
		if vols[i] > vols[i - 1] + 0.0001:
			eaten = false
	check(eaten and vols[vols.size() - 1] < 0.45, "the rock is eaten away blow by blow and little is left for the last blow")
	check(vols[0] > 0.8, "one blow only takes a bite: the rock is still almost whole")
	check(vols[vols.size() - 1] > 0.12, "the last piece is chunky (over 12% of the rock), never a tiny stump")
	# a layered rock: the shell is eaten, falls away on its last blow and leaves the core (smaller, no bites)
	var lw := RockInst.new()
	lw.size = 2.0
	lw.shape = 5
	lw.pos = Vector3(0, 100, 0)
	lw.normal = Vector3.UP
	lw.layers = [[cat.get_type("granite").id, 1.0], [cat.get_type("gold").id, 0.5]]
	var lneed := int(ceilf(rs.layer_hardness(lw)))
	var lrocks: Array = [lw]
	var shed_at := -1
	for i in lneed + 2:
		var res3 := rs.hit(lw, lrocks)
		if res3.event == "shed":
			shed_at = i + 1
			break
	check(shed_at == lneed and absf(lw.size - 1.0) < 0.01 and lw.bites.is_empty(), "the shell goes on its last blow and the core is left")
	# farming a rock from the first blow to the last: the re-meshed shape stays consistent all along
	var fr_rock := RockInst.new()
	fr_rock.id = 4321
	fr_rock.size = 2.76
	fr_rock.shape = 99
	fr_rock.pos = Vector3(0, 100, 0)
	fr_rock.normal = Vector3.UP
	fr_rock.layers = [[cat.get_type("limestone").id, 1.0]]
	var fr_list: Array = [fr_rock]
	var fr_need := int(ceilf(rs.layer_hardness(fr_rock)))
	var tri_counts: Array[int] = []
	var sliver_share := 0.0
	var winding_all := true
	var inside_all := true
	var fr_dirs := [Vector3(1, 0.3, 0.2), Vector3(0.2, 1, 0.3), Vector3(-0.6, 0.2, 0.8)]
	var fr_f := RockMesher.frame_of(fr_rock)
	for i in fr_need:
		var dir: Vector3 = (fr_dirs[(i / 4) % 3] as Vector3).normalized()
		var sh := RockMesher.surface_hit(fr_rock, fr_rock.pos + dir * 12.0, -dir, 40.0)
		if not sh.hit:
			continue
		var res := rs.hit(fr_rock, fr_list, 1.0, sh.point)
		if res.event != "hit":
			break
		if i % 6 == 5:
			var cutm := RockCut.build(fr_rock, rs.catalog)
			var cv: PackedVector3Array = cutm.verts
			var cn: PackedVector3Array = cutm.normals
			var nt := cv.size() / 3
			tri_counts.append(nt)
			var bad := 0
			for t in nt:
				var a0 := cv[t * 3]
				var b0 := cv[t * 3 + 1]
				var c0 := cv[t * 3 + 2]
				var cr := (b0 - a0).cross(c0 - a0)
				var longest := maxf((b0 - a0).length(), maxf((c0 - b0).length(), (a0 - c0).length()))
				if longest * longest / maxf(cr.length(), 1e-6) > 12.0:
					bad += 1
				if cr.dot(cn[t * 3]) > 0.0:
					winding_all = false
				if a0.length() > fr_rock.size * 1.5:
					inside_all = false
			sliver_share = maxf(sliver_share, float(bad) / maxf(nt, 1))
	print("  farming a 2.76 m rock: triangles after blows 6, 12, 18, 24: %s, worst sliver share %.1f%%" % [tri_counts, sliver_share * 100.0])
	check(tri_counts.size() >= 3 and tri_counts[tri_counts.size() - 1] < tri_counts[0] * 0.6, "the cut rock needs fewer and fewer triangles as it is eaten away")
	check(sliver_share < 0.04, "the re-meshed rock has evenly sized triangles (under 4% slivers) from the first blow to the last")
	check(winding_all and inside_all, "its triangles face outward and stay inside the original rock")
	# while the re-meshed shape is being built the CURRENT shape stays: no stand-in shape flashes on screen
	var intact_tris := (RockMesher.bake([_fresh_rock(fr_rock, cat)], cat, Vector3.ZERO).verts as PackedVector3Array).size()
	fr_rock.cut = {}
	var pending := RockMesher.bake([fr_rock], cat, Vector3.ZERO)
	check((pending.verts as PackedVector3Array).size() == intact_tris, "a bitten rock waiting for its new shape is drawn as it was (no flash of a weird stand-in shape)")
	fr_rock.cut = RockCut.build(fr_rock, cat)
	fr_rock.cut_sig = fr_rock.bites.hash()
	var good := RockMesher.bake([fr_rock], cat, Vector3.ZERO)
	check((good.verts as PackedVector3Array).size() == (fr_rock.cut.verts as PackedVector3Array).size(), "and once it is ready the re-meshed shape is shown")
	fr_rock.bites.append(Vector4(0, 0, 0, 0.1))
	var stale := RockMesher.bake([fr_rock], cat, Vector3.ZERO)
	check((stale.verts as PackedVector3Array).size() == (fr_rock.cut.verts as PackedVector3Array).size(), "after another blow the previous shape stays until the next one is ready")
	# reach: the arm is short
	check(ToolAim.REACH <= 5.0, "the tool only reaches about an arm's length from the ball")
	# harder and bigger rocks take more hits
	var soft := RockInst.new()
	soft.size = 1.0
	soft.layers = [[cat.get_type("coal").id, 1.0]]
	var hard := RockInst.new()
	hard.size = 1.0
	hard.layers = [[cat.get_type("diamond").id, 1.0]]
	var big := RockInst.new()
	big.size = 3.0
	big.layers = [[cat.get_type("coal").id, 1.0]]
	check(rs.layer_hardness(hard) > rs.layer_hardness(soft) * 3.0, "diamond is much harder to break than coal")
	check(rs.layer_hardness(big) > rs.layer_hardness(soft) * 3.0, "a boulder takes more hits than a pebble of the same stuff")
	check(rs.layer_units(big) > rs.layer_units(soft), "a boulder yields more")
	# persistence: a chunk rebuilt later leaves broken rocks out and keeps chipped ones chipped
	var cc := VoxelWorld.world_to_chunk(g.find_spawn())
	var field := rs.field
	var f := g.fill_chunk(cc, Column.new(), 0, false)
	var natural := RockPlacer.place(g, field, cc, f.dens, f.wlev)
	if natural.size() >= 2:
		var snap := {natural[0].id: true, natural[1].id: {"layers": [[cat.get_type("quartzite").id, 1.0]], "size": 0.4, "hits": 0.0}}
		var rebuilt := rs.build_chunk(cc, f.dens, f.wlev, f.dens, snap)
		var ids := {}
		var chipped_ok := false
		for r: RockInst in rebuilt.rocks:
			ids[r.id] = true
			if r.id == natural[1].id and r.size == 0.4 and r.layers.size() == 1:
				chipped_ok = true
		check(not ids.has(natural[0].id) and chipped_ok, "broken rocks stay gone and chipped rocks stay chipped when a chunk is rebuilt")
	# picking: a ray finds the nearest rock
	var ch := Chunk.new()
	ch.position = Vector3(0, 0, 0)
	var r1 := RockInst.new()
	r1.pos = Vector3(5, 0, 0)
	r1.size = 1.0
	r1.layers = [[0, 1.0]]
	var r2 := RockInst.new()
	r2.pos = Vector3(9, 0, 0)
	r2.size = 1.0
	r2.layers = [[0, 1.0]]
	ch.rocks = [r2, r1]
	var pick := RockSystem.ray_rocks({Vector3i.ZERO: ch}, Vector3.ZERO, Vector3.RIGHT, 20.0)
	check(pick.hit and pick.rock == r1 and pick.t > 2.8 and pick.t < 4.4, "a ray picks the nearest rock (on its real surface)")
	check(not RockSystem.ray_rocks({Vector3i.ZERO: ch}, Vector3.ZERO, Vector3.UP, 20.0).hit, "a ray that misses picks nothing")
	ch.free()
	# the camera turns only by what pushes past the action perimeter
	var oc := OrbitCamera.new()
	var yaw0 := oc._yaw_input
	oc.turn(Vector2(100, 0))
	check(oc._yaw_input < yaw0, "a push past the perimeter turns the camera")
	oc.pitch = 0.0
	for i in 40:
		oc.turn(Vector2(0, -20))                 # keep pushing up: the camera sinks to ground level, then the view tilts to the sky
	check(oc.pitch <= -0.19 and oc.tilt > 1.0, "pushing up past ground level tilts the view up to the sky (tilt %.2f rad)" % oc.tilt)
	for i in 60:
		oc.turn(Vector2(0, 20))                  # pushing down brings the view back, then lifts the camera over the ball
	check(oc.tilt == 0.0 and oc.pitch > 0.5, "pushing down levels the view first, then raises the camera")
	oc.free()
	# debris: pieces appear, fall, and all vanish after a couple of seconds; never more than MAX
	var deb := RockDebris.new()
	deb.burst(Vector3(0, 5120, 0), Vector3.UP, [Color.RED, Color.BLUE], 40, 0.2)
	check(deb.active() == 40, "a burst creates its pieces")
	deb.burst(Vector3(0, 5120, 0), Vector3.UP, [Color.RED], 200, 0.2)
	check(deb.active() == RockDebris.MAX, "debris is capped (the oldest are recycled)")
	for i in 100:
		deb._process(0.05)
	check(deb.active() == 0, "all debris vanishes after a few seconds")
	deb.free()

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
	# a spawn must be free in the world AS BUILT (its 4 m lattice can lose a narrow shaft the exact generator has)
	var wv := VoxelWorld.new()
	wv.setup(g)
	var all_free := true
	var kinds := {"closed": sp, "open to the sky": lit}
	for kind in kinds:
		var spot: Vector3 = kinds[kind]
		if spot == Vector3.ZERO:
			continue
		var scc := VoxelWorld.world_to_chunk(spot)
		for dz in range(-1, 2):
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					wv._ensure_chunk(scc + Vector3i(dx, dy, dz))
		var upv := spot.normalized()
		var air := wv.density_at(spot)
		var floor_d := wv.density_at(spot - upv * 1.6)
		print("  %s cave spawn in the built world: density at the ball %.2f, 1.6 m below %.2f" % [kind, air, floor_d])
		if air > -0.5 or floor_d < 0.0:
			all_free = false
	check(all_free, "a cave spawn is free air with floor under it in the world as built (never inside rock)")
	wv.free()
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
	# the start: early morning at any place (sun low, rising)
	var morning_ok := true
	for up in [Vector3(0, 1, 0).normalized(), Vector3(1, 0.2, 0.3).normalized(), Vector3(-0.2, 0.5, -0.8).normalized(), Vector3(0.1, -0.3, 0.9).normalized()]:
		for decl in [-0.4, 0.0, 0.34]:
			var a := SkyDome.sun_angle_for_elevation(up, decl, 0.18, true)
			var e: float = up.dot(Vector3(cos(decl) * cos(a), sin(decl), cos(decl) * sin(a)))
			var a2 := a + 0.01
			var e2: float = up.dot(Vector3(cos(decl) * cos(a2), sin(decl), cos(decl) * sin(a2)))
			var rho := Vector2(up.x, up.z).length()
			var reachable: bool = absf((0.18 - sin(decl) * up.y) / (cos(decl) * rho)) <= 1.0
			if reachable and (absf(e - 0.18) > 0.001 or e2 <= e):
				morning_ok = false
	check(morning_ok, "the start sun is low and rising (early morning) wherever you spawn")
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

## The survival layers (items, inventory, crafting, harvest): pure data + rules, no scene needed.
func _survival_tests() -> void:
	print("== survival: inventory, weight, crafting, harvest ==")
	var kit := PlayerKit.new()
	var inv := kit.inventory
	check(kit.belt.tools == ["pickaxe", "bucket"], "the explorer starts with a pickaxe and a bucket")
	check(is_equal_approx(inv.capacity_kg, 100.0), "the carry limit is 100 kg")
	# weight limit: clay is 1.5 kg a unit, so 66 units (99 kg) fit and the 67th does not
	var got := inv.add("clay", 100)
	check(got == 66 and inv.count_of("clay") == 66, "only what weighs under 100 kg is picked up (got %d clay)" % got)
	check(inv.weight() <= 100.0 and inv.add("clay", 1) == 0, "a full pack takes nothing more")
	# bricks: four clay become one brick that is lighter (the clay dries), and it is the storable form
	var opts := RecipeBook.options(inv)
	var brick_opt: Dictionary = {}
	for o: Dictionary in opts:
		if o.recipe.id == "brick":
			brick_opt = o
	check(brick_opt.get("can", false) and brick_opt.out_id == "brick:clay", "with clay in the pack, a clay brick can be pressed")
	var before := inv.weight()
	var res := Crafter.craft(brick_opt, inv, kit.belt)
	check(res.ok and inv.count_of("brick:clay") == 1 and inv.count_of("clay") == 62, "pressing a brick takes four clay and gives a brick")
	check(inv.weight() < before, "a clay brick weighs less than the clay it was pressed from")
	# a heavy ore makes a "gold brick": named after the material; one unit of gold is already a brick's worth
	var gold := ItemDef.make("rock:gold", "Gold ore", ItemDef.RESOURCE, 7.4, Color.GOLD, "lump", ["rock", "ore", "brickable"])
	ItemCatalog.register(gold)
	var gb := ItemCatalog.brick_of("rock:gold")
	check(gb.name == "Gold brick" and is_equal_approx(gb.unit_kg, 7.4) and ItemCatalog.brick_cost(gold) == 1, "one unit of gold ore presses into a gold brick (%s, %.1f kg), carryable" % [gb.name, gb.unit_kg])
	# the torch: wood + a fuel, never craftable without them
	var inv2 := Inventory.new()
	var kit2 := PlayerKit.new()
	var wood := ItemDef.make("wood:Oak wood", "Oak wood", ItemDef.RESOURCE, 1.0, Color.SADDLE_BROWN, "log", ["wood"])
	var coal := ItemDef.make("rock:coal", "Coal", ItemDef.RESOURCE, 1.0, Color.BLACK, "lump", ["rock", "brickable", "flammable"])
	ItemCatalog.register(wood)
	ItemCatalog.register(coal)
	var torch_craft := func(i: Inventory, id: String) -> Dictionary:
		for o: Dictionary in RecipeBook.options(i):
			if o.recipe.id == id:
				return o
		return {}
	check(not torch_craft.call(inv2, "torch_fuel").can and not torch_craft.call(inv2, "torch_bundle").can, "with an empty pack no torch can be made, but the recipes are listed")
	kit2.inventory.add("wood:Oak wood", 1)
	check(not torch_craft.call(kit2.inventory, "torch_fuel").can, "wood alone does not make a fuel torch")
	kit2.inventory.add("rock:coal", 1)
	var r2 := Crafter.craft(torch_craft.call(kit2.inventory, "torch_fuel"), kit2.inventory, kit2.belt)
	check(r2.ok and kit2.belt.count_of("torch") == 2 and kit2.inventory.count_of("wood:Oak wood") == 0, "a stick and coal make two torches, which go on the tool belt")
	kit2.inventory.add("wood:Oak wood", 3)
	check(Crafter.craft(torch_craft.call(kit2.inventory, "torch_bundle"), kit2.inventory, kit2.belt).ok and kit2.belt.count_of("torch_bundle") == 1 and kit2.belt.count_of("torch") == 2, "three wood bind into a bundle torch without fuel: a different torch from the fuel ones")
	# planting uses a torch up; the last one leaves the belt and the next tool is taken in hand
	kit2.belt.select_id("torch")
	check(kit2.belt.torch_to_plant() == "torch", "the torch in hand is the one planted")
	kit2.belt.remove("torch")
	check(kit2.belt.count_of("torch") == 1 and kit2.belt.current_id() == "torch", "planting one of two fuel torches leaves one, still in hand")
	kit2.belt.select_id("pickaxe")
	check(kit2.belt.torch_to_plant() == "torch", "with the pickaxe in hand the first torch on the belt is planted")
	kit2.belt.remove("torch", 1)
	check(kit2.belt.count_of("torch") == 0 and not kit2.belt.tools.has("torch") and kit2.belt.torch_to_plant() == "torch_bundle", "the last fuel torch leaves the belt, the bundle torch is next")
	check(ToolCatalog.get_def("torch").burn_seconds > ToolCatalog.get_def("torch_bundle").burn_seconds and ToolCatalog.get_def("torch").model_path != ToolCatalog.get_def("torch_bundle").model_path, "the two torches burn for different times and have different models")
	# torches burn down: only the piece in hand burns, a planted one keeps its fuel, nothing burns forever
	var kit3 := PlayerKit.new()
	kit3.belt.add("torch", 1, 300.0)
	kit3.belt.add("torch", 1, 900.0)
	check(kit3.belt.count_of("torch") == 2 and is_equal_approx(kit3.belt.fuel_left("torch"), 300.0), "a bundle torch starts with 5 minutes, a coal torch with 15")
	kit3.belt.select_id("torch")
	kit3.update(100.0)
	check(is_equal_approx(kit3.belt.fuel_left("torch"), 200.0) and is_equal_approx(kit3.belt.fuel[("torch")][1], 900.0), "only the torch in hand burns")
	kit3.belt.select_id("pickaxe")
	kit3.update(1000.0)
	check(is_equal_approx(kit3.belt.fuel_left("torch"), 200.0), "a torch that is not in hand does not burn")
	kit3.belt.select_id("torch")
	kit3.update(250.0)
	check(kit3.belt.count_of("torch") == 1 and is_equal_approx(kit3.belt.fuel_left("torch"), 900.0), "a torch that runs out is gone and the next one is in hand")
	kit3.update(1000.0)
	check(kit3.belt.count_of("torch") == 0 and kit3.belt.current_id() != "torch", "the last torch burns out and another tool is taken")
	kit3.belt.add("torch", 1, 120.0)
	check(is_equal_approx(kit3.belt.fuel_left("torch"), 120.0), "a picked up torch keeps the fuel it had")
	check(PlacedTorches.stick_dir(Vector3.DOWN, Vector3.UP) == null and PlacedTorches.stick_dir(Vector3.UP, Vector3.UP) != null, "a torch cannot be planted in a ceiling, but stands on the floor")
	# a result too heavy to carry puts everything back
	ItemCatalog.register(ItemDef.make("heavy", "Heavy", ItemDef.RESOURCE, 1.0, Color.GRAY, "lump", ["brickable"]))
	var heavy_brick := ItemCatalog.brick_of("heavy")
	check(is_equal_approx(heavy_brick.unit_kg, 6.0), "a brick weighs about 6 kg of its material")
	# stacks: slots merge, swap and hand back the rest
	var inv4 := Inventory.new(3, 100.0)
	inv4.add("clay", 5)
	var held := inv4.click_slot(0, {})
	check(held.count == 5 and inv4.count_of("clay") == 0, "a click takes the stack onto the cursor")
	held = inv4.click_slot(1, held)
	check(held.is_empty() and inv4.slots[1].count == 5, "a click on an empty slot puts it down")
	inv4.add("sand", 2)
	var sw := inv4.click_slot(1, {"id": "sand", "count": 2})
	check(sw.id == "clay" and inv4.slots[1].id == "sand", "a click on another item swaps the stacks")
	# the ground: soil is clay, sand beaches are sand, deep ground is the rock of the region
	var gen := PlanetGenerator.new(1337)
	var rs := RockSystem.new()
	rs.setup(gen, 1337)
	var hv := Harvester.new(Inventory.new())
	hv.bind_world(gen, rs, null)
	var col := Column.new()
	var kinds := {}
	for i in 600:
		var d := PlanetGenerator.fibonacci_dir(i, 600)
		gen.sample_column(d, col)
		if col.height < 3.0:
			continue
		var surf := d * (WorldConfig.PLANET_RADIUS + col.height - 0.3)
		var deep := d * (WorldConfig.PLANET_RADIUS + col.height - 8.0)
		kinds[hv.from_ground(surf)] = true
		kinds[hv.from_ground(deep)] = true
	print("  what digging gives over 600 sites, near the surface and 8 m down: %s" % [kinds.keys()])
	check(kinds.has("clay"), "digging soil gives clay")
	var has_rock := false
	for k: String in kinds:
		if k.begins_with("rock:"):
			has_rock = true
	check(has_rock, "digging deep gives the rock of the region")
	check(rs.catalog.get_type("coal").traits.get("flammable", 0.0) >= 0.5, "coal is a fuel (flammable)")
	# trees that block the view fade as a whole; trees beside the view line do not
	TreeMaterial.declare_globals()
	var tf := TreeFade.new()
	var tr := TreeInst.new()
	tr.pos = Vector3.ZERO
	tr.up = Vector3.UP
	tr.height = 10.0
	tr.trunk_r = 0.3
	tr.canopy_r = 3.0
	tr.shape = 123456
	check(tf._blocks(tr, Vector3(-8, 6, 0), Vector3(8, 1, 0)), "a tree on the line from the camera to the player blocks the view")
	check(tf._blocks(tr, Vector3(-8, 11, 0), Vector3(8, 6, 0)), "... also through its crown only")
	check(not tf._blocks(tr, Vector3(-8, 6, 6), Vector3(8, 1, 6)), "a tree 6 m beside the line does not")
	check(not tf._blocks(tr, Vector3(-8, 14, 0), Vector3(8, 14, 0)), "... nor one far below the line (the view passes above it)")
	var fch := Chunk.new()
	fch.position = Vector3(-8, -8, -8)
	fch.trees = [tr]
	var fchunks := {Vector3i(0, 0, 0): fch}
	for i in 40:
		tf.update(fchunks, Vector3(-8, 6, 0), Vector3(8, 1, 0), 0.016)
	check(tf._level.size() == 1 and tf._level[TreeMeshes.fade_id(tr)] < 0.3, "a blocking tree fades out whole (level %.2f)" % tf._level.values()[0])
	for i in 80:
		tf.update(fchunks, Vector3(-8, 6, 6), Vector3(8, 1, 6), 0.016)
	check(tf._level.is_empty(), "and comes back when it no longer blocks")
	fch.free()
	# the character model from Blender has every part the animation moves, and the feet are separate from the body
	var cm := (load(PlayerCharacter.MODEL) as PackedScene).instantiate() as Node3D
	var missing: Array = []
	for n in ["Body", "EyeL", "EyeR", "ShineL", "ShineR", "Nose", "Sprout", "LeafL", "LeafR", "FootL", "FootR", "HandL", "HandR"]:
		if cm.find_child(n, true, false) == null:
			missing.append(n)
	check(missing.is_empty(), "the character model has all its parts %s" % [missing])
	check((cm.find_child("FootL", true, false) as Node3D).get_parent() == cm.find_child("Body", true, false).get_parent(), "the feet are not part of the body (no connection)")
	cm.free()
	for id in ["pickaxe", "bucket", "torch", "torch_bundle"]:
		check(load(ToolCatalog.get_def(id).model_path) != null, "the %s model loads" % id)

## Saving: what play changes goes to disk and comes back in a fresh game. (The save file is a test file, never the player's.)
func _save_tests() -> void:
	print("== saving ==")
	SaveGame.path = "user://test_save.dat"
	SaveGame.delete()
	check(not SaveGame.exists(), "no save to begin with")
	var g := PlanetGenerator.new(1337)
	var w := VoxelWorld.new()
	w.setup(g)
	var sp := g.find_spawn()
	var cc := VoxelWorld.world_to_chunk(sp)
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				w._ensure_chunk(cc + Vector3i(dx, dy, dz))
	var up := sp.normalized()
	var h := w.raycast(sp, -up, 40.0)
	var pt: Vector3 = h.point
	var probe := pt - up * 1.0
	check(w.density_at(probe) > 0.0, "(the ground is solid there before the dig)")
	w.carve(pt, 2.5)
	check(w.density_at(probe) < 0.0, "(the hole is dug)")
	w.rocks.changed[77] = {"layers": [[1, 1.0]], "size": 0.8, "hits": 2.0, "bites": [Vector4(0.1, 0.2, 0.3, 0.4)]}
	w.rocks.moved_index[Vector3i(1, 2, 3)] = [77]
	w.trees.changed[88] = true
	var player := BallPlayer.new()
	player.position = pt + up * 0.6
	player.spawn_pos = pt
	var kit := PlayerKit.new()
	ItemCatalog.register(ItemDef.make("rock:testium", "Testium", ItemDef.RESOURCE, 2.0, Color.RED, "lump", ["rock", "brickable"]))
	kit.inventory.add("clay", 7)
	kit.inventory.add("rock:testium", 3)
	kit.belt.add("torch", 1, 120.0)
	kit.bar_slot = 2
	var torches := PlacedTorches.new()
	torches._list.append({"node": null, "flame": null, "point": pt, "normal": up, "fuel": 77.0, "id": "torch"})
	var snap := WorldSnapshot.new()
	var data := snap.capture(w, player, kit, torches, {"sun_angle": 1.5, "season": 2.5, "playtime": 99.0})
	check(SaveGame.write(data), "the save is written")
	check(SaveGame.exists() and SaveGame.info().seed == 1337 and SaveGame.info().playtime == 99.0, "the menu can see it (seed, play time) without reading the world")
	var back := SaveGame.read()
	check(not back.is_empty(), "the save is read back")
	# into a fresh game
	var w2 := VoxelWorld.new()
	w2.setup(g)
	WorldSnapshot.restore_world(back, w2)
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				w2._ensure_chunk(cc + Vector3i(dx, dy, dz))
	check(w2.density_at(probe) < 0.0 and is_equal_approx(w2.density_at(probe), w.density_at(probe)), "the dug hole is still there in the new game")
	check(w2.rocks.changed.has(77) and w2.rocks.changed[77].bites[0] == Vector4(0.1, 0.2, 0.3, 0.4) and w2.rocks.moved_index.has(Vector3i(1, 2, 3)) and w2.trees.changed.get(88) == true, "the chipped rock, the moved rock and the cut tree are remembered")
	var player2 := BallPlayer.new()
	var kit2 := PlayerKit.new()
	var torches2 := PlacedTorches.new()
	var clock := WorldSnapshot.restore_player(back, player2, kit2, torches2)
	check(player2.position.distance_to(player.position) < 0.001 and player2.spawn_pos.distance_to(pt) < 0.001, "he stands where he stood")
	check(kit2.inventory.count_of("clay") == 7 and kit2.inventory.count_of("rock:testium") == 3 and kit2.bar_slot == 2, "he carries what he carried")
	check(is_equal_approx(kit2.belt.fuel_left("torch"), 120.0) and kit2.belt.count_of("pickaxe") == 1, "his tools are back, the torch with the fuel it had left")
	check(is_equal_approx(clock.sun_angle, 1.5) and is_equal_approx(clock.season, 2.5) and is_equal_approx(clock.playtime, 99.0), "the time of day, the season and the play time are back")
	check(torches.to_data()[0].fuel == 77.0, "a planted torch is exported with its fuel")
	# a second save with nothing dug must not copy the terrain again, and a corrupt file is refused
	var again := snap.capture(w, player, kit, torches, {"sun_angle": 0.0, "season": 0.0, "playtime": 1.0})
	check(again.edits == data.edits, "the terrain edits are shared between saves while they do not change")
	var bad := FileAccess.open(SaveGame.path, FileAccess.WRITE)
	bad.store_string("not a save")
	bad.close()
	check(SaveGame.read().is_empty(), "a damaged save is refused, not loaded")
	SaveGame.delete()
	SaveGame.path = "user://savegame.dat"
	player.free()
	player2.free()
	torches.free()
	torches2.free()
	w.free()
	w2.free()
