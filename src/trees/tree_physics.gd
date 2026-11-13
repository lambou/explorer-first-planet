class_name TreePhysics
extends Node3D
## A felled tree falls. It leaves the chunk's baked mesh and becomes one node that tips over its foot (a pendulum: it starts slowly and
## speeds up, taller trees are slower), thuds on the ground with a burst of leaves, and is put back as a lying trunk (TreeSystem.landed).
## Also: when the ground under a tree's foot is dug away, the tree falls (after_edit). Nothing runs for trees that stand.

signal landed(tree: TreeInst, point: Vector3, colors: Array)

const MAX_BODIES := 8
var rock_contacts := true             # a falling tree stops against the rocks in its way (off = it goes through them: tests use it as the control)
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
		var settled := false
		for t: TreeInst in ch.trees.duplicate():
			if t.state == TreeInst.FALLEN:
				if _near_trunk(t, center, radius + 1.5) and _settle_fallen(t):
					settled = true
				continue
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
		if settled:
			world.rebake_trees(ch)
	return started

func _near_trunk(t: TreeInst, center: Vector3, dist: float) -> bool:
	var a := t.pos + t.shift
	var ab := t.axis * t.remaining
	var k := clampf((center - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return (a + ab * k).distance_to(center) <= dist

## Underside samples of a lying trunk (distance along it) that touch solid ground, for a foot at `foot` and direction `axis`.
func _contacts(t: TreeInst, foot: Vector3, axis: Vector3) -> Array:
	var out := []
	var rocks := RockContact.nearby(world, foot + axis * (t.remaining * 0.5), t.remaining * 0.5 + 1.0)      # a trunk can lie on a rock
	var n := maxi(2, ceili(t.remaining / 0.6))
	for i in n + 1:
		var s := t.remaining * i / float(n)
		var pt := foot + axis * s - t.up * 0.15
		var held := world.density_at(pt) > 0.0
		if not held:
			for c: Dictionary in rocks:
				if RockContact.depth(c, pt) > 0.0:
					held = true
					break
		if held:
			out.append(s)
	return out

## A lying trunk whose ground was dug away sinks until it rests again: straight down while nothing holds it, then, if only one end
## touches, it tips about that end until the other end finds ground too. Returns true if it moved.
func _settle_fallen(t: TreeInst) -> bool:
	var foot := t.pos + t.shift
	var axis := t.axis
	if _contacts(t, foot, axis).size() >= 2:
		return false                                            # held in two places (a log bridging a hole stays)
	var found := false
	for i in 50:
		if not _contacts(t, foot, axis).is_empty():
			found = true
			break
		foot -= t.up * 0.2
	if not found:
		return false                                            # nothing below within reach: leave it
	var c := _contacts(t, foot, axis)
	if c.size() == 1:
		var pivot_s: float = c[0]
		var pivot := foot + axis * pivot_s
		var sgn := -1.0 if pivot_s > t.remaining * 0.5 else 1.0
		var rot := axis.cross(-t.up)
		if rot.length() > 0.01:
			rot = rot.normalized()
			for i in 25:
				var ang := sgn * 0.04
				axis = axis.rotated(rot, ang).normalized()
				foot = pivot + (foot - pivot).rotated(rot, ang)
				var far := false
				for s: float in _contacts(t, foot, axis):
					if absf(s - pivot_s) > 0.9:
						far = true
				if far:
					break
	t.axis = axis
	t.shift = foot - t.pos
	world.trees.changed[t.id] = t.to_state()
	return true

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
		"slow": sqrt(12.0 / maxf(t.height, 4.0)), "ty": ty, "lean": false,
		"rocks": RockContact.nearby(world, t.pos, t.height + 1.0) if rock_contacts else []})      # rocks do not move while the tree falls: listed once

func _physics_process(delta: float) -> void:
	var dt := minf(delta, 1.0 / 30.0)
	var i := 0
	while i < _bodies.size():
		var b: Dictionary = _bodies[i]
		b.omega += (3.2 * sin(b.angle) + 0.35) * b.slow * dt * 2.2
		var before: float = b.angle
		b.angle += b.omega * dt * b.slow * 1.3
		if not (b.rocks as Array).is_empty() and _hits_rock(b):
			b.angle = before                                    # the trunk met a rock: it stops against it and lies leaning on it
			b.lean = true
		var node: Node3D = b.node
		node.global_transform = Transform3D(Basis(b.axis, b.angle), (b.tree as TreeInst).pos)
		if b.lean or b.angle >= MAX_ANGLE:
			_finish(b)
		else:
			i += 1

## Does the trunk, tipped to its current angle, run into a rock? The trunk is tested every 0.5 m (it tapers towards the tip) against the rocks
## listed when the tree started to fall. Cost: a few distance checks per step, a surface lookup only where a rock really is near the trunk.
func _hits_rock(b: Dictionary) -> bool:
	var t: TreeInst = b.tree
	var dir_t: Vector3 = Basis(b.axis, b.angle) * t.up
	var reach := t.height * 0.88
	var s := 1.0
	while s <= reach:
		var pt := t.pos + dir_t * s
		var rad := maxf(t.trunk_r * (1.0 - 0.55 * s / reach), 0.12)
		for c: Dictionary in b.rocks:
			var rk: RockInst = c.r
			var lim := rk.size * 1.75 + rad
			if pt.distance_squared_to(rk.pos) > lim * lim:
				continue
			if RockContact.depth(c, pt) > -rad * 0.5:
				return true
		s += 0.5
	return false

## It lands: the lying trunk goes into the chunk (tip resting on the ground), the crown is gone in a burst of leaves.
func _finish(b: Dictionary) -> void:
	var t: TreeInst = b.tree
	var ch: Chunk = b.chunk
	var dir: Vector3 = b.dir
	var reach := t.height * 0.88
	var tip := t.pos + dir * reach
	var up := t.up
	var axis := dir
	if b.lean:
		axis = (Basis(b.axis, b.angle) * t.up).normalized()       # it lies as it stopped: against the rock
	else:
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
