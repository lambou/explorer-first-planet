class_name TreePhysics
extends Node3D
## A felled tree falls. It leaves the chunk's baked mesh and becomes one node that tips over its foot (a pendulum: it starts slowly and
## speeds up, taller trees are slower), thuds on the ground with a burst of leaves, and is put back as a lying trunk (TreeSystem.landed).
## Also: when the ground under a tree's foot is dug away, the tree falls (after_edit). Nothing runs for trees that stand.

signal landed(tree: TreeInst, point: Vector3, colors: Array)

const MAX_BODIES := 8
const MAX_ANGLE := 1.52              # radians: nearly flat

var world: VoxelWorld
var _bodies: Array = []

func active() -> int:
	return _bodies.size()

## The terrain changed around `center`: trees whose foot lost its ground fall away from the edit.
func after_edit(center: Vector3, radius: float) -> int:
	var started := 0
	for c: Vector3i in world.chunks:
		var ch: Chunk = world.chunks[c]
		if ch.trees.is_empty() or (ch.position + Vector3.ONE * 8.0).distance_to(center) > radius + 26.0:
			continue
		for t: TreeInst in ch.trees.duplicate():
			if t.state != TreeInst.STANDING or t.pos.distance_to(center) > radius + 2.0:
				continue
			if _rooted(t):
				continue                                        # still standing on solid ground
			var away := t.pos - center
			away -= t.up * away.dot(t.up)
			if away.length() < 0.01:
				away = t.hit_dir
			start_fall(t, ch, away.normalized())
			started += 1
	return started

## Is the foot still held by the ground? Five points under the trunk's footprint: at least two must be solid (a tree on the edge of a
## hole stays, a tree over a hole falls).
func _rooted(t: TreeInst) -> bool:
	var side := t.up.cross(Vector3.UP if absf(t.up.y) < 0.95 else Vector3.RIGHT).normalized()
	var other := t.up.cross(side)
	var r := maxf(t.trunk_r, 0.25)
	var solid := 0
	for off: Vector3 in [Vector3.ZERO, side * r, -side * r, other * r, -other * r]:
		if world.density_at(t.pos + off - t.up * 0.45) > 0.0:
			solid += 1
	return solid >= 2

func start_fall(t: TreeInst, ch: Chunk, dir: Vector3) -> void:
	if _bodies.size() >= MAX_BODIES:
		_finish(_bodies[0])
	var ty := world.trees.catalog.by_id(t.type_id)
	t.state = TreeInst.FALLING
	world.rebake_trees(ch)
	# the tree alone, at the origin of its own node (the foot)
	var copy := TreeInst.new()
	copy.apply_state(t.to_state())
	copy.state = TreeInst.STANDING
	copy.type_id = t.type_id
	copy.up = t.up
	copy.height = t.height
	copy.trunk_r = t.trunk_r
	copy.canopy_r = t.canopy_r
	copy.yaw = t.yaw
	copy.shape = t.shape
	var baked := TreeMeshes.bake_one(copy, world.trees.catalog)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = baked.verts
	arrays[Mesh.ARRAY_NORMAL] = baked.normals
	arrays[Mesh.ARRAY_COLOR] = baked.colors
	arrays[Mesh.ARRAY_TEX_UV] = baked.uvs
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.material_override = world.trees.material
	var node := Node3D.new()
	node.add_child(mi)
	add_child(node)
	node.global_transform = Transform3D(Basis.IDENTITY, t.pos)
	var axis := t.up.cross(dir).normalized()
	if axis.length() < 0.01:
		axis = t.up.cross(Vector3.RIGHT).normalized()
	_bodies.append({"tree": t, "chunk": ch, "node": node, "dir": dir, "axis": axis, "angle": 0.04, "omega": 0.15,
		"slow": sqrt(12.0 / maxf(t.height, 4.0)), "ty": ty})

func _physics_process(delta: float) -> void:
	var dt := minf(delta, 1.0 / 30.0)
	var i := 0
	while i < _bodies.size():
		var b: Dictionary = _bodies[i]
		b.omega += (3.2 * sin(b.angle) + 0.35) * b.slow * dt * 2.2
		b.angle += b.omega * dt * b.slow * 1.3
		var node: Node3D = b.node
		node.global_transform = Transform3D(Basis(b.axis, b.angle), (b.tree as TreeInst).pos)
		if b.angle >= MAX_ANGLE:
			_finish(b)
		else:
			i += 1

## It lands: the lying trunk goes into the chunk (tip resting on the ground), the crown is gone in a burst of leaves.
func _finish(b: Dictionary) -> void:
	var t: TreeInst = b.tree
	var ch: Chunk = b.chunk
	var dir: Vector3 = b.dir
	var reach := t.height * 0.88
	var tip := t.pos + dir * reach
	var up := t.up
	var axis := dir
	var hit := world.raycast(tip + up * 25.0, -up, 60.0)
	if hit.hit:
		var g: Vector3 = hit.point
		axis = ((g + up * t.trunk_r) - (t.pos + up * t.trunk_r)).normalized()
	world.trees.landed(t, axis)
	var ty := world.trees.catalog.by_id(t.type_id)
	var burst_at := t.pos + axis * (reach * 0.8) + up * 1.0
	(b.node as Node3D).queue_free()
	_bodies.erase(b)
	world.rebake_trees(ch)
	landed.emit(t, burst_at, [ty.leaf_a, ty.leaf_b, ty.leaf_b.lightened(0.15)])
