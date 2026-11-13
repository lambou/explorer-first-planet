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
var grass: Dictionary = {}            # kind of grass id -> {buf, count, aabb} (one packed buffer per kind, see GrassPlacer)
var grass_nodes: Dictionary = {}      # kind id -> its MultiMeshInstance3D
var trees: Array = []                 # the trees standing (or lying cut) in this chunk (TreeInst)
var tree_instance: MeshInstance3D     # all of them baked into one mesh (near: the full trees)
var tree_far: MeshInstance3D          # and the same trees in the cheap far version, shown beyond TREE_NEAR metres
var tree_body: StaticBody3D           # the trunks as one collision shape
var rocks: Array = []                 # the rocks lying in this chunk (RockInst), natural ones minus the broken ones
var rock_instance: MeshInstance3D     # all of them baked into one mesh
var rock_body: StaticBody3D           # and one collision trimesh

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

## Shows the baked rocks of this chunk (one mesh, one collision shape).
func apply_rocks(res: Dictionary, material: Material) -> void:
	var verts: PackedVector3Array = res.verts
	if verts.is_empty():
		if rock_instance:
			rock_instance.queue_free()
			rock_instance = null
		if rock_body:
			rock_body.queue_free()
			rock_body = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = res.normals
	arrays[Mesh.ARRAY_COLOR] = res.colors
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if rock_instance == null:
		rock_instance = MeshInstance3D.new()
		rock_instance.material_override = material
		add_child(rock_instance)
	rock_instance.mesh = m
	if collide:
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(res.faces)
		if rock_body == null:
			rock_body = StaticBody3D.new()
			rock_body.add_child(CollisionShape3D.new())
			add_child(rock_body)
		(rock_body.get_child(0) as CollisionShape3D).shape = shape

## Shows the baked trees of this chunk: one mesh (one draw call) and one collision shape made of the trunks.
const TREE_NEAR := 16.0

func apply_trees(res: Dictionary, material: Material, far_res: Dictionary = {}) -> void:
	if OS.get_environment("TREEOFF") != "":
		return
	var verts: PackedVector3Array = res.verts
	if verts.is_empty():
		if tree_instance:
			tree_instance.queue_free()
			tree_instance = null
		if tree_far:
			tree_far.queue_free()
			tree_far = null
		if tree_body:
			tree_body.queue_free()
			tree_body = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = res.normals
	arrays[Mesh.ARRAY_COLOR] = res.colors
	arrays[Mesh.ARRAY_TEX_UV] = res.uvs
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if tree_instance == null:
		tree_instance = MeshInstance3D.new()
		tree_instance.material_override = material
		tree_instance.visibility_range_end = TREE_NEAR + 3.0           # the full trees only near the camera ...
		if OS.get_environment("TREESHADOW") == "0":
			tree_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(tree_instance)
	tree_instance.mesh = m
	# ... and the cheap far version (a third of the triangles, no shadows) beyond it, with a little overlap so nothing pops
	if not far_res.is_empty() and not (far_res.verts as PackedVector3Array).is_empty():
		var fa := []
		fa.resize(Mesh.ARRAY_MAX)
		fa[Mesh.ARRAY_VERTEX] = far_res.verts
		fa[Mesh.ARRAY_NORMAL] = far_res.normals
		fa[Mesh.ARRAY_COLOR] = far_res.colors
		fa[Mesh.ARRAY_TEX_UV] = far_res.uvs
		var fm := ArrayMesh.new()
		fm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fa)
		if tree_far == null:
			tree_far = MeshInstance3D.new()
			tree_far.material_override = material
			tree_far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			tree_far.visibility_range_begin = TREE_NEAR - 3.0
			tree_far.visibility_range_end = 140.0
			add_child(tree_far)
		tree_far.mesh = fm
	var faces: PackedVector3Array = res.faces
	if collide and not faces.is_empty():
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(faces)
		if tree_body == null:
			tree_body = StaticBody3D.new()
			tree_body.add_child(CollisionShape3D.new())
			add_child(tree_body)
		(tree_body.get_child(0) as CollisionShape3D).shape = shape
	elif tree_body != null:
		tree_body.queue_free()
		tree_body = null

## Shows the grass of this chunk: one MultiMesh per kind (one draw call each), built from the packed buffers.
func apply_grass(system: GrassSystem) -> void:
	if OS.get_environment("GRASSOFF") != "":
		return
	for tid in grass_nodes.keys():
		if not grass.has(tid) or int(grass[tid].count) == 0:
			(grass_nodes[tid] as Node).queue_free()
			grass_nodes.erase(tid)
	for tid in grass:
		var g: Dictionary = grass[tid]
		if int(g.count) == 0:
			continue
		var mmi: MultiMeshInstance3D = grass_nodes.get(tid)
		var mm: MultiMesh
		if mmi == null:
			mm = MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true                  # tint + random per clump (INSTANCE_CUSTOM); must be set before the count
			mm.mesh = system.mesh_for(tid, coord)
			mmi = MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = system.materials[tid]
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.visibility_range_end = 80.0            # far chunks are not drawn at all
			add_child(mmi)
			grass_nodes[tid] = mmi
		else:
			mm = mmi.multimesh
		mm.instance_count = int(g.count)
		mm.buffer = g.buf
		mm.custom_aabb = g.aabb

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
