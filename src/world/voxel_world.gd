class_name VoxelWorld
extends Node3D
## The terrain you can touch: full-detail 16 m chunks, built on worker threads, only close to
## the player and only where the ground surface is. Solid rock below the surface and caves are
## built only while the player is underground (or digging). Edits are a sparse overlay of
## density samples on top of the seed. Distant terrain is FarTerrain's job.

const S := WorldConfig.CHUNK_SIZE
const P := WorldConfig.PADDED
const DMAX := PlanetGenerator.DMAX
const APPLY_PER_FRAME := 6

const VOL_RADIUS := 48.0          # full-detail chunks within this 3D distance of the player
const ZONE := 2                   # underground: every chunk within this many chunks (a cube) of the player is built
const CAVE_RADIUS := 24.0         # underground (caves, rock) built within this distance when underground
const VIS_DIST := 130.0           # underground: how far the view rays look for walls
const VIS_RAYS := 96
const VIS_TTL_MS := 6000          # a chunk seen by a ray stays wanted this long
const VIS_PERIOD_MS := 450
const UPDATE_DIST := 6.0          # re-evaluate which chunks are needed when the player moved this far

var gen: PlanetGenerator
var material: ShaderMaterial
var water: WaterSystem
var rocks: RockSystem
signal terrain_edited(center: Vector3, radius: float)     # the ground changed here: loose rocks next to it may lose their support
var underground := false          # the player is below the ground surface
var sky_open := 1.0               # 0..1: how much of the sky the player can see (underground only meaningful)
var enclosed := false             # underground and no sky in sight: the outside world does not exist here

var chunks: Dictionary = {}       # Vector3i -> Chunk
var jobs: Dictionary = {}         # Vector3i -> true (in flight)
var edits: Dictionary = {}        # chunk coord -> {Vector3i sample -> Vector2(density, material)}
var edit_rev := 0
var max_inflight := clampi(OS.get_processor_count() * 2, 2, 12)   # keeps every core busy between frames

var _upgrading: Dictionary = {}   # loaded chunks being re-generated with caves
var _wanted: Dictionary = {}
var _queue: Array = []
var _done: Array = []
var _ready: Array = []
var _mutex := Mutex.new()
var _last_pos := Vector3.ZERO
var _has_pos := false
var _col := Column.new()
var _vis_extra: Dictionary = {}   # chunk -> expiry (msec): chunks the view rays hit (underground only)
var _vis_direct: Dictionary = {}  # chunks a ray hit directly (their neighbours are built later)
var _vis_busy := false
var _vis_next := 0
var _vis_results: Array = []
var _force_update := false
var _cam_pos := Vector3.ZERO
var _cam_fwd := Vector3.ZERO

func setup(p_gen: PlanetGenerator) -> void:
	gen = p_gen
	material = TerrainMaterial.create()
	water = WaterSystem.new()
	water.setup(p_gen, WorldConfig.world_seed)
	rocks = RockSystem.new()
	rocks.setup(p_gen, WorldConfig.world_seed)

# ---------- coordinates ----------
static func chunk_of(sp: Vector3i) -> Vector3i:
	return Vector3i(floori(float(sp.x) / S), floori(float(sp.y) / S), floori(float(sp.z) / S))

static func world_to_chunk(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / S), floori(p.y / S), floori(p.z / S))

static func data_index(local: Vector3i) -> int:
	return (local.x + 1) + P * ((local.y + 1) + P * (local.z + 1))

static func _in_padded(l: Vector3i) -> bool:
	return l.x >= -1 and l.y >= -1 and l.z >= -1 and l.x <= S and l.y <= S and l.z <= S

static func box_dist(c: Vector3i, p: Vector3) -> float:
	var lo := Vector3(c) * S
	return p.distance_to(p.clamp(lo, lo + Vector3.ONE * S))

# ---------- which chunks are needed ----------
## Needed: chunks crossing the ground surface (and edited ones). Rock below the surface and
## caves only while the player is underground and close.
## Underground the player moves through a zone: all chunks in the cube around them, so their
## surroundings are always complete (no partly built walls next to them).
func _in_zone(c: Vector3i) -> bool:
	var pc := world_to_chunk(_last_pos)
	return absi(c.x - pc.x) <= ZONE and absi(c.y - pc.y) <= ZONE and absi(c.z - pc.z) <= ZONE

func wants(c: Vector3i, p: Vector3) -> bool:
	if edits.has(c):
		return true
	if underground and _vis_extra.has(c):
		return true
	var cls := gen.classify_node_fine(0, c)
	if cls == 0 or gen.is_water_chunk(c):
		return true
	if cls == 2 and underground and _in_zone(c) and gen.classify_node(0, c) == 0:
		return true
	return false

## The player is below the ground surface (with hysteresis).
func _check_underground(p: Vector3) -> bool:
	var r := p.length()
	if r < 1.0:
		return true
	gen.sample_height(p / r, _col)
	var rel := r - WorldConfig.PLANET_RADIUS
	return rel < _col.height - (1.0 if underground else 3.0)

## Where the camera is and looks: chunks in view are built first (what you see appears first).
func set_view(cam_pos: Vector3, cam_fwd: Vector3) -> void:
	_cam_pos = cam_pos
	var turned := _cam_fwd.dot(cam_fwd) < 0.92
	_cam_fwd = cam_fwd
	if turned and not _queue.is_empty():
		_sort_queue()

## One ray per frame towards the sky (9 directions around straight up). A ray reaches the sky when it
## climbs above the natural ground without meeting terrain. Smoothed; `enclosed` has hysteresis.
var _sky_i := 0
var sky_dir := Vector3.ZERO        # most vertical direction in which the sky is in sight (ZERO = none)
var _sky_dirs := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
var _sky_vals := PackedFloat32Array([1, 1, 1, 1, 1, 1, 1, 1, 1])

func _update_sky_access() -> void:
	if not underground:
		sky_open = 1.0
		enclosed = false
		sky_dir = Vector3.ZERO
		return
	var up := _last_pos.normalized()
	var t1 := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := up.cross(t1)
	var k := _sky_i
	_sky_i = (_sky_i + 1) % 9
	var dir := up
	if k > 0:
		var ring := (k - 1) / 4
		var az := ((k - 1) % 4) * (PI * 0.5) + ring * (PI * 0.25)
		var ang := deg_to_rad(40.0 + 30.0 * ring)
		dir = (up * cos(ang) + (t1 * cos(az) + t2 * sin(az)) * sin(ang)).normalized()
	var origin := _cam_pos if _cam_pos != Vector3.ZERO else _last_pos
	var open := false
	var t := 1.5
	while t < 110.0:
		var p := origin + dir * t
		if density_at(p) > 0.0:
			break
		var r := p.length()
		gen.sample_height(p / r, _col, 4)
		if r - WorldConfig.PLANET_RADIUS > _col.height + 2.0:
			open = true
			break
		t += 2.0
	_sky_vals[k] = 1.0 if open else 0.0
	_sky_dirs[k] = dir if open else Vector3.ZERO
	var best := Vector3.ZERO
	var best_dot := -2.0
	for dv in _sky_dirs:
		if dv != Vector3.ZERO and dv.dot(up) > best_dot:
			best_dot = dv.dot(up)
			best = dv
	sky_dir = best
	var sum := 0.0
	for v in _sky_vals:
		sum += v
	sky_open = lerpf(sky_open, sum / 9.0, 0.35)
	enclosed = sky_open < (0.08 if enclosed else 0.03)

## Casts rays through the camera's view on a worker thread and collects the chunks holding the
## first wall each ray meets: those are the underground chunks the player can actually see.
func _start_view_scan() -> void:
	_vis_busy = true
	_vis_next = Time.get_ticks_msec() + VIS_PERIOD_MS
	var up := _cam_pos.normalized()
	var right := _cam_fwd.cross(up)
	if right.length() < 0.01:
		right = _cam_fwd.cross(Vector3.RIGHT)
	right = right.normalized()
	var up2 := right.cross(_cam_fwd).normalized()
	var dirs := PackedVector3Array()
	var cone := cos(deg_to_rad(58.0))
	for i in VIS_RAYS:
		var t := (i + 0.5) / VIS_RAYS
		var ang := acos(1.0 - t * (1.0 - cone))
		var az := i * 2.39996323
		dirs.append((_cam_fwd * cos(ang) + (right * cos(az) + up2 * sin(az)) * sin(ang)).normalized())
	for k in 8:   # a few rays all around: walls to the sides and behind matter when turning
		var az2 := k * TAU / 8.0
		dirs.append((right * cos(az2) + _cam_fwd * sin(az2)).normalized())
	WorkerThreadPool.add_task(_view_scan_task.bind(_cam_pos, dirs), false, "view scan")

func _view_scan_task(origin: Vector3, dirs: PackedVector3Array) -> void:
	var col := Column.new()
	var hits := {}
	for d in dirs:
		var in_air := false
		var prev := origin
		var t := 2.0
		while t < VIS_DIST:
			var p := origin + d * t
			var dn := gen.density_at(roundi(p.x), roundi(p.y), roundi(p.z), col, 1, true)
			if dn < 0.0:
				in_air = true
				prev = p
			elif in_air:
				hits[chunk_of(Vector3i(floori(p.x), floori(p.y), floori(p.z)))] = true
				hits[chunk_of(Vector3i(floori(prev.x), floori(prev.y), floori(prev.z)))] = true
				break
			t += 3.0
	_mutex.lock()
	_vis_results.append(hits.keys())
	_vis_busy = false
	_mutex.unlock()

func _prio(c: Vector3i) -> float:
	if _upgrading.has(c):
		return -1.0
	var to := (Vector3(c) + Vector3.ONE * 0.5) * S - _cam_pos
	var seen := _cam_fwd == Vector3.ZERO or to.length() < 28.0 or to.normalized().dot(_cam_fwd) > 0.1
	var extra := 0.0 if seen else 40.0
	if underground and _vis_extra.has(c) and not _vis_direct.has(c) and box_dist(c, _last_pos) > CAVE_RADIUS:
		extra += 25.0     # a neighbour of a wall the player sees: after the walls themselves
	return box_dist(c, _last_pos) + extra

func _sort_queue() -> void:
	var keyed: Array = []
	for c in _queue:
		keyed.append([_prio(c), c])
	keyed.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	_queue.clear()
	for e in keyed:
		_queue.append(e[1])

## Radius around the player inside which every needed chunk is built (the far terrain stays
## visible as placeholder ground outside of it, so there is never a hole while loading).
func covered_radius() -> float:
	var m := VOL_RADIUS
	for c: Vector3i in _wanted:
		if not chunks.has(c):
			m = minf(m, box_dist(c, _last_pos))
	return maxf(m - 4.0, 0.0)

## Height band (relative to sea level) in which ground chunks near `pos` can be.
func _local_band(pos: Vector3) -> Vector2:
	var up := pos.normalized()
	var t1 := up.cross(Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := up.cross(t1)
	var lo := 1e9
	var hi := -1e9
	var col := Column.new()
	for k in 9:
		var off := (t1 * (k % 3 - 1) + t2 * (k / 3 - 1)) * VOL_RADIUS
		var q := pos + off
		gen.sample_height(q.normalized(), col)
		lo = minf(lo, col.height)
		hi = maxf(hi, col.height)
	return Vector2(lo, hi)

func update_center(pos: Vector3) -> void:
	var und := _check_underground(pos)
	if _has_pos and pos.distance_to(_last_pos) < UPDATE_DIST and und == underground and not _force_update:
		return
	_force_update = false
	if not und:
		_vis_extra.clear()
		_vis_direct.clear()
	underground = und
	_has_pos = true
	_last_pos = pos
	var cc := world_to_chunk(pos)
	var rr := ceili(VOL_RADIUS / S) + 1
	var band := _local_band(pos)
	var big := float(WorldConfig.PLANET_RADIUS)
	_wanted.clear()
	for dz in range(-rr, rr + 1):
		for dy in range(-rr, rr + 1):
			for dx in range(-rr, rr + 1):
				var c := cc + Vector3i(dx, dy, dz)
				if box_dist(c, pos) > VOL_RADIUS:
					continue
				if not underground and not edits.has(c):
					# cheap pre-test: only chunks near the ground's height band can contain the surface
					var rel := ((Vector3(c) + Vector3.ONE * 0.5) * S).length() - big
					if (rel < band.x - 45.0 or rel > band.y + 45.0) and absf(rel) > 18.0:
						continue
				if wants(c, pos):
					_wanted[c] = true
	# underground: the walls the view rays hit, however far (the cave you can see is the cave you get)
	var now := Time.get_ticks_msec()
	for c: Vector3i in _vis_direct.keys():
		if _vis_direct[c] < now:
			_vis_direct.erase(c)
	for c: Vector3i in _vis_extra.keys():
		if _vis_extra[c] < now:
			_vis_extra.erase(c)
		elif underground and not enclosed:
			_wanted[c] = true
	for c in chunks.keys():
		if not _wanted.has(c):
			chunks[c].queue_free()
			chunks.erase(c)
	_queue.clear()
	for c: Vector3i in _wanted:
		if not chunks.has(c) and not jobs.has(c):
			_queue.append(c)
	# underground: chunks that were built without caves get them now
	if underground:
		for c: Vector3i in chunks:
			var ch := chunks[c] as Chunk
			if not ch.caves and not jobs.has(c) and not _upgrading.has(c) and (_in_zone(c) or _vis_extra.has(c)):
				_upgrading[c] = true
				_queue.append(c)
	_sort_queue()

func _process(_delta: float) -> void:
	_mutex.lock()
	_ready.append_array(_done)
	_done.clear()
	var vis := _vis_results.duplicate()
	_vis_results.clear()
	_mutex.unlock()
	if not vis.is_empty():
		var expiry := Time.get_ticks_msec() + VIS_TTL_MS
		var faces := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
		for hits: Array in vis:
			for c: Vector3i in hits:
				if not _vis_extra.has(c):
					_force_update = true
				_vis_extra[c] = expiry
				_vis_direct[c] = expiry
				# the wall continues into the neighbouring chunks: build those too (later)
				for f: Vector3i in faces:
					if not _vis_extra.has(c + f):
						_force_update = true
						_vis_extra[c + f] = expiry
	if underground and not enclosed and not _vis_busy and _cam_fwd != Vector3.ZERO and Time.get_ticks_msec() >= _vis_next:
		_start_view_scan()
	_update_sky_access()
	var n := 0
	while not _ready.is_empty() and n < APPLY_PER_FRAME:
		var r: Dictionary = _ready.pop_front()
		var c: Vector3i = r.coord
		jobs.erase(c)
		if _upgrading.has(c):
			_upgrading.erase(c)
			var old: Chunk = chunks.get(c)
			if old != null and _wanted.has(c):
				n += 1
				old.dens = r.dens
				old.colr = r.colr
				old.base = r.base
				old.caves = true
				old.skirt = r.skirt
				old.wlev = r.wlev
				old.wbase = r.wlev
				old.hlat = r.hlat
				old.l0 = r.l0
				var um: Dictionary = r.mesh
				if r.rev != edit_rev:
					_overlay(old.dens, old.colr, c, _snapshot_edits(c))
					um = ChunkMesher.build(old.dens, old.colr, c * S, 1, old.skirt, old.base)
				old.apply_mesh(um, material)
				old.apply_water(r.wmesh if r.rev == edit_rev else WaterMesher.build(old.wlev, old.dens, c, old.hlat, old.l0), water.material)
				old.rocks = r.rocks
				old.apply_rocks(r.rmesh, material)
			continue
		if chunks.has(c) or not _wanted.has(c):
			continue
		n += 1
		var ch := Chunk.new()
		ch.coord = c
		ch.skirt = r.skirt
		ch.caves = r.caves
		ch.position = Vector3(c * S)
		ch.dens = r.dens
		ch.colr = r.colr
		ch.base = r.base
		ch.wlev = r.wlev
		ch.wbase = r.wlev
		ch.hlat = r.hlat
		ch.l0 = r.l0
		var mesh: Dictionary = r.mesh
		if r.rev != edit_rev:
			_overlay(ch.dens, ch.colr, c, _snapshot_edits(c))
			mesh = ChunkMesher.build(ch.dens, ch.colr, c * S, 1, ch.skirt, ch.base)
		add_child(ch)
		chunks[c] = ch
		ch.apply_mesh(mesh, material)
		ch.apply_water(r.wmesh if r.rev == edit_rev else WaterMesher.build(ch.wlev, ch.dens, c, ch.hlat, ch.l0), water.material)
		ch.rocks = r.rocks
		ch.apply_rocks(r.rmesh, material)
	water.tick(chunks, _last_pos, _has_pos, edit_rev)
	_pump()

func _pump() -> void:
	while jobs.size() < max_inflight and not _queue.is_empty():
		var c: Vector3i = _queue.pop_front()
		if (chunks.has(c) and not _upgrading.has(c)) or jobs.has(c) or not _wanted.has(c):
			continue
		jobs[c] = true
		var caves := underground and (_in_zone(c) or _vis_extra.has(c))
		WorkerThreadPool.add_task(_job.bind(c, _snapshot_edits(c), edit_rev, not caves, caves, rocks.broken_snapshot()))

func _job(c: Vector3i, snap: Dictionary, rev: int, skirt: bool, caves: bool, broken: Dictionary) -> void:
	var f := gen.fill_chunk(c, Column.new(), 0, caves)
	if caves:
		rocks.carve_chunk(c, f.dens)           # pockets of the buried rocks (natural: part of the base density)
	var base: PackedFloat32Array = f.dens.duplicate()
	_overlay(f.dens, f.colr, c, snap)
	var mesh := ChunkMesher.build(f.dens, f.colr, c * S, 1, skirt, base)
	var wmesh := WaterMesher.build(f.wlev, f.dens, c, f.hlat, f.l0)
	var rk := rocks.build_chunk(c, base, f.wlev, f.dens, broken, caves)
	_mutex.lock()
	_done.append({"coord": c, "dens": f.dens, "colr": f.colr, "base": base, "mesh": mesh, "rev": rev, "skirt": skirt, "caves": caves,
			"wlev": f.wlev, "hlat": f.hlat, "l0": f.l0, "wmesh": wmesh, "rocks": rk.rocks, "rmesh": rk.mesh})
	_mutex.unlock()

func _snapshot_edits(c: Vector3i) -> Dictionary:
	var snap := {}
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var n := c + Vector3i(dx, dy, dz)
				if edits.has(n):
					snap.merge(edits[n])
	return snap

static func _overlay(dens: PackedFloat32Array, colr: PackedColorArray, c: Vector3i, snap: Dictionary) -> void:
	if snap.is_empty():
		return
	var o := c * S
	for sp: Vector3i in snap:
		var l := sp - o
		if not _in_padded(l):
			continue
		var v: Vector2 = snap[sp]
		var i := data_index(l)
		dens[i] = v.x
		if v.y >= 0.0:
			colr[i] = BlockTypes.COLORS[int(v.y)]   # placed material; carving leaves the colour alone

## True when the chunks right around the player (within ~22 m) are built: enough for the ball to
## land and roll; everything farther keeps loading while the player already plays.
func is_area_ready(pos: Vector3) -> bool:
	var cc := world_to_chunk(pos)
	for dz in range(-2, 3):
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var c := cc + Vector3i(dx, dy, dz)
				if box_dist(c, pos) <= 22.0 and wants(c, pos) and not chunks.has(c):
					return false
	return true

# ---------- water (all logic lives in src/water/, see WaterSystem) ----------
func water_level_at(p: Vector3) -> float:
	return water.water_level_at(chunks, p)

func submersion(p: Vector3) -> float:
	return water.submersion(chunks, p)

# ---------- density access / editing ----------
func get_density_i(sp: Vector3i) -> float:
	var cc := chunk_of(sp)
	var ch: Chunk = chunks.get(cc)
	if ch != null:
		return ch.dens[data_index(sp - cc * S)]
	if edits.has(cc) and edits[cc].has(sp):
		return (edits[cc][sp] as Vector2).x
	match gen.classify_node_fine(0, cc):
		1: return -DMAX
		2: return DMAX
	return gen.density_at(sp.x, sp.y, sp.z, Column.new(), 1, false)

## Trilinear density at an arbitrary point.
func density_at(p: Vector3) -> float:
	var b := Vector3i(floori(p.x), floori(p.y), floori(p.z))
	var f := p - Vector3(b)
	var c000 := get_density_i(b)
	var c100 := get_density_i(b + Vector3i(1, 0, 0))
	var c010 := get_density_i(b + Vector3i(0, 1, 0))
	var c110 := get_density_i(b + Vector3i(1, 1, 0))
	var c001 := get_density_i(b + Vector3i(0, 0, 1))
	var c101 := get_density_i(b + Vector3i(1, 0, 1))
	var c011 := get_density_i(b + Vector3i(0, 1, 1))
	var c111 := get_density_i(b + Vector3i(1, 1, 1))
	var x00 := lerpf(c000, c100, f.x)
	var x10 := lerpf(c010, c110, f.x)
	var x01 := lerpf(c001, c101, f.x)
	var x11 := lerpf(c011, c111, f.x)
	return lerpf(lerpf(x00, x10, f.y), lerpf(x01, x11, f.y), f.z)

## Remove terrain in a sphere.
func carve(center: Vector3, radius: float) -> void:
	_edit_sphere(center, radius, true, BlockTypes.AIR)

## Add terrain (material `mat`) in a sphere.
func fill(center: Vector3, radius: float, mat: int) -> void:
	_edit_sphere(center, radius, false, mat)

func _edit_sphere(center: Vector3, radius: float, carving: bool, mat: int) -> void:
	edit_rev += 1
	var lo := Vector3i(floori(center.x - radius - 1.0), floori(center.y - radius - 1.0), floori(center.z - radius - 1.0))
	var hi := Vector3i(ceili(center.x + radius + 1.0), ceili(center.y + radius + 1.0), ceili(center.z + radius + 1.0))
	var touched := {}
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var sp := Vector3i(x, y, z)
				var dist := Vector3(sp).distance_to(center)
				if dist > radius + 1.5:
					continue
				var cur := _current_sample(sp)
				var nd: float
				if carving:
					nd = minf(cur.x, dist - radius)
				else:
					nd = maxf(cur.x, radius - dist)
				nd = clampf(nd, -DMAX, DMAX)
				if is_equal_approx(nd, cur.x):
					continue
				var nm := -1 if carving else (mat if nd > cur.x and nd > 0.0 else -1)
				_store_sample(sp, nd, nm, touched)
	for c in touched:
		(chunks[c] as Chunk).rebuild(material)
		(chunks[c] as Chunk).rebuild_water(water.material)
	terrain_edited.emit(center, radius)

func _current_sample(sp: Vector3i) -> Vector2:
	var cc := chunk_of(sp)
	var ch := _ensure_chunk(cc)
	if ch != null:
		var i := data_index(sp - cc * S)
		return Vector2(ch.dens[i], -1.0)
	return Vector2(get_density_i(sp), -1.0)

func _store_sample(sp: Vector3i, d: float, m: int, touched: Dictionary) -> void:
	var oc := chunk_of(sp)
	if not edits.has(oc):
		edits[oc] = {}
	edits[oc][sp] = Vector2(d, m)
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var c := oc + Vector3i(dx, dy, dz)
				var l := sp - c * S
				if not _in_padded(l):
					continue
				var ch := _ensure_chunk(c)
				if ch == null:
					continue
				var i := data_index(l)
				ch.dens[i] = d
				if m >= 0:
					ch.colr[i] = BlockTypes.COLORS[m]
				touched[c] = true

## Digging reaches chunks that were never needed (rock below the surface): build on demand.
func _ensure_chunk(c: Vector3i) -> Chunk:
	if chunks.has(c):
		return chunks[c]
	if jobs.has(c):
		return null  # in flight: result is re-overlaid with edits when it arrives
	var f := gen.fill_chunk(c, Column.new(), 0, true)
	rocks.carve_chunk(c, f.dens)
	var base: PackedFloat32Array = f.dens.duplicate()
	_overlay(f.dens, f.colr, c, _snapshot_edits(c))
	var ch := Chunk.new()
	ch.coord = c
	ch.position = Vector3(c * S)
	ch.dens = f.dens
	ch.colr = f.colr
	ch.base = base
	ch.wlev = f.wlev
	ch.wbase = f.wlev
	ch.hlat = f.hlat
	ch.l0 = f.l0
	add_child(ch)
	chunks[c] = ch
	_wanted[c] = true
	var rk := rocks.build_chunk(c, base, f.wlev, f.dens, rocks.changed, true)
	ch.rocks = rk.rocks
	ch.apply_rocks(rk.mesh, material)
	return ch

## Re-bake the rocks of one chunk after its rock list changed (a rock fell out, or landed in).
func rebake_rocks(ch: Chunk) -> void:
	ch.apply_rocks(RockMesher.bake(ch.rocks, rocks.catalog, ch.position, ch.dens, ch.base), material)

## A rock came to rest: it joins the chunk it lies in (if that chunk is built; otherwise it is added when it is).
func place_rock(r: RockInst) -> void:
	var ch: Chunk = chunks.get(world_to_chunk(r.pos))
	if ch != null:
		ch.rocks.append(r)
		rebake_rocks(ch)

## The nearest rock on a ray (see RockSystem.ray_rocks): {hit, rock, chunk, t, point}.
func rock_ray(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	return RockSystem.ray_rocks(chunks, origin, dir.normalized(), max_dist)

## One blow on the rock found by rock_ray; the chunk's rock mesh is re-baked (a few hundred triangles).
func hit_rock(res: Dictionary, power: float = 1.0) -> Dictionary:
	var ch: Chunk = res.chunk
	var out := rocks.hit(res.rock, ch.rocks, power, res.point)
	ch.apply_rocks(RockMesher.bake(ch.rocks, rocks.catalog, ch.position, ch.dens, ch.base), material)
	return out

## Ray march against the density field. Returns {hit, point, prev}.
func raycast(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	dir = dir.normalized()
	var step := 0.25
	var t := 0.0
	var prev_t := 0.0
	while t <= max_dist:
		if density_at(origin + dir * t) > 0.0:
			var lo := prev_t
			var hi := t
			for i in 6:
				var mid := (lo + hi) * 0.5
				if density_at(origin + dir * mid) > 0.0:
					hi = mid
				else:
					lo = mid
			return {"hit": true, "point": origin + dir * hi, "prev": origin + dir * lo}
		prev_t = t
		t += step
	return {"hit": false}

func stats() -> String:
	return "chunks %d%s  building %d" % [chunks.size(), (" (underground, enclosed)" if enclosed else " (underground, sky visible)") if underground else "", jobs.size() + _queue.size()]
