class_name WaterSystem
extends RefCounted
## Owner of everything about water. The rest of the game talks to water only through this class
## (plus UnderwaterEffect for the camera): it holds the surface materials, decides the water state
## (calm .. storm), schedules the cave-flooding solver on a worker thread and answers questions such
## as "is this point under water?". It never changes the terrain.
##
## Near the player (built chunks) it keeps real water surfaces; far away only the cheap far-terrain
## sheets exist, and both use the same shader, which fades wave detail with distance.

const S := WorldConfig.CHUNK_SIZE
const P := WorldConfig.PADDED
const REGION := 3                  # chunks around the player the solver looks at
const SOLVE_PERIOD_MS := 600
const DEBOUNCE_MS := 350           # wait this long after the last edit before solving
const APPLY_PER_FRAME := 2         # water meshes swapped in per frame

var gen: PlanetGenerator
var state: WaterState
var material: ShaderMaterial       # surface of the water in built chunks
var ripples := WaterRipples.new()      # rings made by swimmers and splashes
var wind := 0.6                    # the wind's direction (radians), drifts slowly; all the wave directions turn with it
var swell_time := 0.0              # the clock of the swell (shared with the shader)
var agitation := 0.3               # current state at the player's place, 0 calm .. 1 storm
## Flooding of caves and dug holes by the solver (only space at or below the water level gets water).
var cave_flooding := true
var forced_agitation := -1.0       # >= 0: use this state everywhere (debugging, cutscenes, weather later)

var _materials: Array[ShaderMaterial] = []     # every surface material that gets the state uniforms
var _mutex := Mutex.new()
var _busy := false
var _sig := -1
var _next := 0
var _result: Dictionary = {}
var _pending: Dictionary = {}
var _pending_keys: Array = []
var _last_rev := 0
var _edit_ms := 0
var _touched: Dictionary = {}
var _scratch := Column.new()      # main thread only

func setup(p_gen: PlanetGenerator, world_seed: int) -> void:
	gen = p_gen
	state = WaterState.new(world_seed)
	material = WaterMaterial.create()
	_materials = [material]

## Far terrain registers its own (hole-cutting) material so it receives the same state.
func create_far_material() -> ShaderMaterial:
	var m := WaterMaterial.create()
	_materials.append(m)
	return m

## Call every frame: updates the water state for where the player is.
func update_state(player_pos: Vector3, time_s: float) -> void:
	var target := state.agitation_at(player_pos, time_s) if forced_agitation < 0.0 else forced_agitation
	agitation = lerpf(agitation, target, 0.02 if forced_agitation < 0.0 else 0.3)
	for m in _materials:
		m.set_shader_parameter("agitation", agitation)
	swell_time = fposmod(Time.get_ticks_msec() / 1000.0, 10000.0)
	wind = 0.6 + 0.5 * sin(time_s * 0.011) + 0.3 * sin(time_s * 0.0037)
	for m in _materials:
		m.set_shader_parameter("swell_time", swell_time)
		m.set_shader_parameter("wind", wind)
	ripples.upload(_materials, Time.get_ticks_msec() / 1000.0)

## The sun for the underwater look of the surface (Snell's window and the glare seen from below): `sun_dir` = the way the sunlight travels,
## `daylight` 0..1, `up` = the planet's radial direction at the camera.
func set_sun(sun_dir: Vector3, daylight: float, up: Vector3) -> void:
	var ray_up := -UnderwaterRays.refract_sun(sun_dir, up)           # where the sun appears to be, seen from under the water
	for m in _materials:
		m.set_shader_parameter("sky_light", daylight)
		m.set_shader_parameter("ray_up", ray_up)

## A disturbance of the surface at `p` (world position): a ring spreads from it. strength about 0.2 (a bob) .. 1 (a splash) .. 2.5 (a hard fall).
func add_ripple(p: Vector3, strength: float) -> void:
	ripples.add(p, strength, Time.get_ticks_msec() / 1000.0)

func state_name() -> String:
	return WaterState.name_of(agitation)

# ---------------------------------------------------------------- cave / hole flooding

## Call every frame. `chunks`: coord -> Chunk, `center`: the player's position. Water in caves and holes is
## worked out from how they connect to the sea (WaterSolver): re-solved on a worker thread when chunks appear
## or the terrain is edited, but only once digging has paused (DEBOUNCE_MS), at most every 0.6 s. The worker
## also builds the new water meshes, and only for chunks whose water really changed; the main thread just
## swaps in APPLY_PER_FRAME of them per frame, so digging next to water never stalls a frame.
func tick(chunks: Dictionary, center: Vector3, has_center: bool, edit_rev: int) -> void:
	if edit_rev != _last_rev:
		_last_rev = edit_rev
		_edit_ms = Time.get_ticks_msec()
	_mutex.lock()
	var res := _result
	_result = {}
	_mutex.unlock()
	if not res.is_empty():
		if res.rev == edit_rev:
			_pending = res.final
			_pending_keys = _pending.keys()
			_touched = res.touched
		else:
			_sig = -1                                   # the terrain changed while solving: solve again
	_apply_pending(chunks)
	if not cave_flooding or _busy or has_center == false:
		return
	var now := Time.get_ticks_msec()
	if now < _next or now - _edit_ms < DEBOUNCE_MS:
		return
	var sig := chunks.size() * 7919 + edit_rev * 31
	if sig == _sig:
		return
	var pc := VoxelWorld.world_to_chunk(center)
	var snap := {}
	var any_sea := false
	for c: Vector3i in chunks:
		if absi(c.x - pc.x) <= REGION and absi(c.y - pc.y) <= REGION and absi(c.z - pc.z) <= REGION:
			var ch := chunks[c] as Chunk
			snap[c] = [ch.dens, ch.wbase, ch.wlev, ch.hlat, ch.l0]
			if not ch.wbase.is_empty():
				any_sea = true
	_sig = sig
	_next = now + SOLVE_PERIOD_MS
	if not any_sea and _touched.is_empty():
		return
	_busy = true
	WorkerThreadPool.add_task(_task.bind(snap, _touched.duplicate(), edit_rev), false, "water")

func _task(snap: Dictionary, touched: Dictionary, rev: int) -> void:
	var sol := WaterSolver.solve(gen, snap)
	var out: Dictionary = sol.out
	var final := {}                                      # coord -> {"wlev", "mesh"} for chunks whose water changes
	for c: Vector3i in snap:
		var cur: PackedFloat32Array = snap[c][2]
		var want: PackedFloat32Array
		if out.has(c):
			want = out[c]
		elif touched.has(c):
			want = snap[c][1]                            # flooded by an earlier solution, not any more: natural water
		else:
			continue
		if want == cur:
			continue
		final[c] = {"wlev": want, "mesh": WaterMesher.build(want, snap[c][0], c, snap[c][3], snap[c][4])}
	var now := {}
	for c: Vector3i in out:
		now[c] = true
	_mutex.lock()
	_result = {"final": final, "touched": now, "rev": rev}
	_busy = false
	_mutex.unlock()

func _apply_pending(chunks: Dictionary) -> void:
	var n := 0
	while n < APPLY_PER_FRAME and not _pending_keys.is_empty():
		var c: Vector3i = _pending_keys.pop_back()
		var ch: Chunk = chunks.get(c)
		var f: Dictionary = _pending.get(c, {})
		_pending.erase(c)
		if ch == null or f.is_empty():
			continue
		ch.wlev = f.wlev
		ch.apply_water(f.mesh, material)
		n += 1

# ---------------------------------------------------------------- queries

## Water level (metres relative to sea level) at a point, or NO_WATER. Built chunks are authoritative
## (they know about flooded caves); where no chunk is built (open water between the surface and the sea
## bed, which is never meshed) the open sea is answered from the terrain itself.
func water_level_at(chunks: Dictionary, p: Vector3) -> float:
	var sp := Vector3i(floori(p.x), floori(p.y), floori(p.z))
	var cc := VoxelWorld.chunk_of(sp)
	var ch: Chunk = chunks.get(cc)
	if ch != null:
		if ch.wlev.is_empty():
			return PlanetGenerator.NO_WATER
		var w := ch.wlev[VoxelWorld.data_index(sp - cc * S)]
		return w if w > PlanetGenerator.NO_WATER * 0.5 else PlanetGenerator.NO_WATER
	var r := p.length()
	if r < 1.0 or r > WorldConfig.PLANET_RADIUS:
		return PlanetGenerator.NO_WATER
	gen.sample_height(p / r, _scratch, 1)
	if PlanetGenerator.is_sea(_scratch.land, _scratch.height) and r - WorldConfig.PLANET_RADIUS > _scratch.height:
		return 0.0
	return PlanetGenerator.NO_WATER

## Metres of water above this point (negative = above the water), or -1e9 where there is no water.
func submersion(chunks: Dictionary, p: Vector3) -> float:
	var w := water_level_at(chunks, p)
	if w == PlanetGenerator.NO_WATER:
		return -1.0e9
	if w == 0.0:                                         # the sea heaves with the swell that is drawn (rivers and cave water do not)
		w += WaterMaterial.swell_height(p, swell_time, agitation, wind)
	return w - (p.length() - WorldConfig.PLANET_RADIUS)
