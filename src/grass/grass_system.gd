class_name GrassSystem
extends RefCounted
## Owner of everything about grass (like RockSystem / WaterSystem): the catalog of kinds of this world, the field (what grows
## where), the shared materials, the wind, the planting of a chunk (worker thread) and the clean-up when the ground is dug.
## See docs/GRASS_PLAN.md for the rules.

var gen: PlanetGenerator
var catalog: GrassCatalog
var field: GrassField
var materials: Array[ShaderMaterial] = []
var wind_dir := Vector3(1, 0, 0)
var wind_strength := 0.5
var _angle0 := 0.0
var forced_wind := -1.0           # debugging aid (--wind=): >= 0 fixes the wind strength

func setup(p_gen: PlanetGenerator, world_seed: int) -> void:
	gen = p_gen
	GrassMaterial.declare_globals()
	catalog = GrassCatalog.new(world_seed)
	field = GrassField.new(catalog, world_seed)
	for t in catalog.types:
		materials.append(GrassMaterial.create(t))
	_angle0 = SeedMix.unit(world_seed, 5200) * TAU

## Plant one chunk (safe on a worker thread). `rocks`: the chunk's rocks, kept clear of grass.
func build_chunk(coord: Vector3i, dens: PackedFloat32Array, colr: PackedColorArray, wlev: PackedFloat32Array,
		hlat: PackedFloat32Array, l0: Vector3i, rocks: Array) -> Dictionary:
	return GrassPlacer.place(gen, field, coord, dens, colr, wlev, hlat, l0, rocks)

## The clump mesh a chunk uses for a kind (every chunk picks one of the variants, so a meadow is not made of copies).
func mesh_for(type_id: int, coord: Vector3i) -> ArrayMesh:
	var variant := (coord.x * 73 + coord.y * 179 + coord.z * 283 + type_id) & (GrassCatalog.VARIANTS - 1)
	return GrassMeshes.build(catalog.by_id(type_id), variant, catalog.world_seed)

## Every frame: the wind (it drifts slowly: its direction turns, its strength comes and goes) and the player position, as
## shared shader values. This is ALL the CPU does per frame for grass.
func update(time_s: float, player_pos: Vector3) -> void:
	var a := _angle0 + time_s * 0.012 + sin(time_s * 0.031) * 0.6
	wind_dir = Vector3(cos(a), 0.25 * sin(a * 1.7), sin(a)).normalized()
	wind_strength = clampf(0.45 + 0.25 * sin(time_s * 0.07) + 0.15 * sin(time_s * 0.19 + 1.3), 0.08, 1.0)
	if forced_wind >= 0.0:
		wind_strength = forced_wind
	RenderingServer.global_shader_parameter_set("grass_wind", Vector4(wind_dir.x, wind_dir.y, wind_dir.z, wind_strength))
	RenderingServer.global_shader_parameter_set("grass_player", Vector4(player_pos.x, player_pos.y, player_pos.z, 1.6))

## The light the grass is shaded with (it is lit by hand in its shader): the sun's direction, colour and energy and the ambient
## light, exactly the values the game just gave its sun and environment (night, dusk and underwater dimming included).
func set_light(sun_dir: Vector3, sun_color: Color, sun_energy: float, ambient: float) -> void:
	RenderingServer.global_shader_parameter_set("grass_sun", Vector4(sun_dir.x, sun_dir.y, sun_dir.z, ambient))
	RenderingServer.global_shader_parameter_set("grass_sun_col", Vector4(sun_color.r * sun_energy, sun_color.g * sun_energy, sun_color.b * sun_energy, 1.0))

## The ground of a chunk changed (digging): drop the clumps whose ground is gone or that were buried. Cheap: two density
## lookups per clump over the stored buffer; nothing is planted again.
func refilter(ch: Chunk) -> void:
	if ch.grass.is_empty():
		return
	for tid in ch.grass:
		var g: Dictionary = ch.grass[tid]
		var buf: PackedFloat32Array = g.buf
		var kept := PackedFloat32Array()
		for i in int(g.count):
			var o: int = i * GrassPlacer.STRIDE
			var lp := Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
			var up := Vector3(buf[o + 1], buf[o + 5], buf[o + 9]).normalized()
			if ChunkSampler.density(ch.dens, lp - up * 0.25) > 0.0 and ChunkSampler.density(ch.dens, lp + up * 0.3) < 0.0:
				kept.append_array(buf.slice(o, o + GrassPlacer.STRIDE))
		g.buf = kept
		g.count = kept.size() / GrassPlacer.STRIDE
	ch.apply_grass(self)
