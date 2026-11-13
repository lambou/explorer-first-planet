class_name FarTrees
extends Node3D
## The far forest. Beyond the streamed chunks (about 48 m) trees are flat CUTOUT CARDS: one quad each (2 triangles) that always turns to the
## camera and is shaped by a small shader into the silhouette of its canopy family (round crown, flat acacia, cone, fir, palm). The world is cut
## into big SECTORS (128 m cubes); every sector holds one MultiMesh (a single draw call) built on a worker thread from the same seeded forest
## field the near trees use, so forests, clearings and species line up with what you walk into. Cards inside ~50 m of the player vanish in a
## dither (the real trees take over), cards beyond ~440 m are not drawn. Only what is inside the radius exists; sectors that leave it are dropped.
## Cost: a card is 2 triangles, a sector about 40-60 cards; the sector is built once (about 20 ms on the worker) and then costs one draw call.
##
## Per-card data (16 floats): transform rows with width and height as the x and y scale and the foot as the origin, then custom data:
## the crown colour (rgb) and the silhouette id (a).

const SECTOR := 128.0
const RADIUS := 440.0               # sectors inside this distance of the player exist
const KEEP := 520.0                 # and are dropped beyond this
const CELL := 8.0                   # planting cell (a card stands for a bigger tree than a near one, so fewer of them)
const HALF := 93.0
const R := float(WorldConfig.PLANET_RADIUS)
const MAX_JOBS := 2

var gen: PlanetGenerator
var field: TreeField
var material: ShaderMaterial
var sectors := {}                   # Vector3i -> {"node": MultiMeshInstance3D or null, "count": int}
var _jobs := {}
var _done := []
var _mutex := Mutex.new()
var _timer := 0.0
var _quad: ArrayMesh
var enabled := true

func setup(p_gen: PlanetGenerator, p_field: TreeField) -> void:
	gen = p_gen
	field = p_field
	material = FarTreeMaterial.create()
	_quad = _make_quad()

static func _make_quad() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(-0.5, 1, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m

## Call every frame with the player's position: it looks for missing sectors twice a second.
func update(player_pos: Vector3, delta: float) -> void:
	_apply_done()
	_timer -= delta
	if _timer > 0.0 or not enabled:
		return
	_timer = 0.5
	var pc := _sector_of(player_pos)
	var reach := int(ceil(RADIUS / SECTOR)) + 1
	var wanted: Array = []
	for dz in range(-reach, reach + 1):
		for dy in range(-reach, reach + 1):
			for dx in range(-reach, reach + 1):
				var s := pc + Vector3i(dx, dy, dz)
				var centre := (Vector3(s) + Vector3.ONE * 0.5) * SECTOR
				var dist := centre.distance_to(player_pos) - SECTOR * 0.87
				if dist > RADIUS or sectors.has(s) or _jobs.has(s):
					continue
				var rc := centre.length()
				if rc < R - 250.0 or rc > R + 700.0:
					continue
				wanted.append([dist, s])
	wanted.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for w in wanted:
		if _jobs.size() >= MAX_JOBS:
			break
		var s: Vector3i = w[1]
		_jobs[s] = true
		WorkerThreadPool.add_task(_job.bind(s))
	# drop what is far behind
	for s: Vector3i in sectors.keys():
		var centre := (Vector3(s) + Vector3.ONE * 0.5) * SECTOR
		if centre.distance_to(player_pos) - SECTOR * 0.87 > KEEP:
			var e: Dictionary = sectors[s]
			if e.node != null:
				(e.node as Node).queue_free()
			sectors.erase(s)

static func _sector_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / SECTOR), floori(p.y / SECTOR), floori(p.z / SECTOR))

func _job(s: Vector3i) -> void:
	var res := build_sector(gen, field, s)
	_mutex.lock()
	_done.append({"s": s, "res": res})
	_mutex.unlock()

func _apply_done() -> void:
	_mutex.lock()
	var list := _done
	_done = []
	_mutex.unlock()
	for d in list:
		var s: Vector3i = d.s
		_jobs.erase(s)
		var res: Dictionary = d.res
		var node: MultiMeshInstance3D = null
		if res.count > 0:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = _quad
			mm.instance_count = res.count
			mm.buffer = res.buf
			mm.custom_aabb = res.aabb
			node = MultiMeshInstance3D.new()
			node.multimesh = mm
			node.material_override = material
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(node)
		sectors[s] = {"node": node, "count": res.count}

## The cards of one sector (safe on a worker thread, deterministic).
## Returns {"buf": PackedFloat32Array, "count": int, "aabb": AABB}.
static func build_sector(p_gen: PlanetGenerator, p_field: TreeField, s: Vector3i) -> Dictionary:
	var empty := {"buf": PackedFloat32Array(), "count": 0, "aabb": AABB()}
	var centre := (Vector3(s) + Vector3.ONE * 0.5) * SECTOR
	var col := Column.new()
	var dc := centre.normalized()
	p_gen.sample_height(dc, col)
	var sp := dc * (R + col.height)
	if absf(centre.length() - (R + col.height)) > SECTOR * 0.9 or col.height < 0.5:
		return empty
	var up := dc
	var t1 := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized()
	var t2 := up.cross(t1)
	var base := SeedMix.splitmix64(p_field.world_seed ^ 0xFA77)
	base = SeedMix.splitmix64(base + s.x)
	base = SeedMix.splitmix64(base + s.y * 1000003)
	base = SeedMix.splitmix64(base + s.z * 998244353)
	var n := int(ceil(2.0 * HALF / CELL))
	var buf := PackedFloat32Array()
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	var cat := p_field.catalog
	for iv in n:
		for iu in n:
			var h := SeedMix.splitmix64(base + iu * 7349 + iv * 913)
			var u := -HALF + (iu + 0.15 + 0.7 * _unit(h, 1)) * CELL
			var v := -HALF + (iv + 0.15 + 0.7 * _unit(h, 2)) * CELL
			var p0 := sp + t1 * u + t2 * v
			var d := p0.normalized()
			# a quick forest test first: no forest here, no ground lookup
			if p_field.forest_density(p0) < 0.12:
				continue
			p_gen.sample_column(d, col)
			if col.land < 0.02 or col.height < 1.0 or PlanetGenerator.is_sea(col.land, col.height):
				continue
			var foot := d * (R + col.height)
			if _sector_of(foot) != s:
				continue                                           # every tree belongs to exactly one sector
			var ground := p_gen.surface.color_for(col)
			var pick := p_field.choose(ground, col.temperature, col.moisture, col.height, foot, 0.2, _unit(h, 3))
			if pick.x < 0.0 or _unit(h, 4) > pick.y:
				continue
			var ty := cat.by_id(int(pick.x))
			var height := lerpf(ty.h_min, ty.h_max, pow(_unit(h, 5), 1.2)) * 1.05
			var width := height * ty.canopy_ratio * 2.3
			if ty.family == TreeType.PINE or ty.family == TreeType.FIR:
				width = height * ty.canopy_ratio * 2.1
			var leaf := ty.leaf_a.lerp(ty.leaf_b, 0.3 + 0.3 * _unit(h, 6))
			buf.append_array(PackedFloat32Array([
				width, 0.0, 0.0, foot.x,
				0.0, height, 0.0, foot.y,
				0.0, 0.0, 1.0, foot.z,
				leaf.r, leaf.g, leaf.b, (float(silhouette_of(ty.family)) + 0.5) / 8.0]))
			lo = Vector3(minf(lo.x, foot.x), minf(lo.y, foot.y), minf(lo.z, foot.z))
			hi = Vector3(maxf(hi.x, foot.x), maxf(hi.y, foot.y), maxf(hi.z, foot.z))
	var count := buf.size() / 16
	if count == 0:
		return empty
	var pad := Vector3.ONE * 30.0
	return {"buf": buf, "count": count, "aabb": AABB(lo - pad, hi - lo + pad * 2.0)}

## The silhouette the far shader draws for a canopy family.
static func silhouette_of(family: String) -> int:
	match family:
		TreeType.BROADLEAF: return 0
		TreeType.ROUND: return 1
		TreeType.BIRCH: return 2
		TreeType.ACACIA: return 3
		TreeType.PINE: return 4
		TreeType.FIR: return 5
		TreeType.PALM: return 6
	return 0

static func _unit(h: int, k: int) -> float:
	var v := SeedMix.splitmix64(h + k * 0x632BE59B)
	return float((v >> 11) & ((1 << 53) - 1)) / 9007199254740992.0
