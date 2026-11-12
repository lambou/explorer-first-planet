class_name Chunk
extends Node3D
## One 16^3 region of the world: density samples + render mesh + collision.

var coord := Vector3i.ZERO
var skirt := false
var collide := true
var caves := true      # carved with caves (only done near the player)
var dens := PackedFloat32Array()
var base := PackedFloat32Array()   # natural density (before player edits)
var colr := PackedColorArray()      # ground colour per sample
var mesh_instance: MeshInstance3D
var body: StaticBody3D
var shape_node: CollisionShape3D
var wlev := PackedFloat32Array()       # water level per sample (metres rel. sea level), empty = no water
var wbase := PackedFloat32Array()      # the natural (sea) water levels, before the cave solver
var hlat := PackedFloat32Array()       # terrain height lattice (ocean depth)
var l0 := Vector3i.ZERO
var water_instance: MeshInstance3D
var skirt_instance: MeshInstance3D   # hairline-crack hiders: no shadows, no collision

func rebuild(material: Material) -> void:
	apply_mesh(ChunkMesher.build(dens, colr, coord * WorldConfig.CHUNK_SIZE, 1, skirt, base), material)

func apply_mesh(res: Dictionary, material: Material) -> void:
	var verts: PackedVector3Array = res.verts
	if verts.is_empty():
		if mesh_instance:
			mesh_instance.queue_free()
			if body:
				body.queue_free()
			skirt_instance = null     # was a child of mesh_instance
			mesh_instance = null
			body = null
			shape_node = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = res.normals
	arrays[Mesh.ARRAY_COLOR] = res.colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var shape: ConcavePolygonShape3D = null
	if collide:
		shape = ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(res.faces)
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.material_override = material
		add_child(mesh_instance)
		if collide:
			body = StaticBody3D.new()
			shape_node = CollisionShape3D.new()
			body.add_child(shape_node)
			add_child(body)
	mesh_instance.mesh = m
	if collide:
		shape_node.shape = shape
	var sv: PackedVector3Array = res.sverts if res.has("sverts") else PackedVector3Array()
	if sv.is_empty():
		if skirt_instance:
			skirt_instance.queue_free()
			skirt_instance = null
	else:
		var sarr := []
		sarr.resize(Mesh.ARRAY_MAX)
		sarr[Mesh.ARRAY_VERTEX] = sv
		sarr[Mesh.ARRAY_NORMAL] = res.snormals
		sarr[Mesh.ARRAY_COLOR] = res.scolors
		var sm := ArrayMesh.new()
		sm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sarr)
		if skirt_instance == null:
			skirt_instance = MeshInstance3D.new()
			skirt_instance.material_override = material
			skirt_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mesh_instance.add_child(skirt_instance)
		skirt_instance.mesh = sm

func rebuild_water(material: Material) -> void:
	if wlev.is_empty() and water_instance == null:
		return
	apply_water(WaterMesher.build(wlev, dens, coord, hlat, l0), material)

## Shows the water surface (no shadows, no collision).
func apply_water(res: Dictionary, material: Material) -> void:
	var verts: PackedVector3Array = res.verts
	if verts.is_empty():
		if water_instance:
			water_instance.queue_free()
			water_instance = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = res.normals
	arrays[Mesh.ARRAY_TEX_UV] = res.uvs
	arrays[Mesh.ARRAY_COLOR] = res.colors
	arrays[Mesh.ARRAY_INDEX] = res.indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if water_instance == null:
		water_instance = MeshInstance3D.new()
		water_instance.material_override = material
		water_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(water_instance)
	water_instance.mesh = m
