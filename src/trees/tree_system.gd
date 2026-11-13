class_name TreeSystem
extends RefCounted
## Owner of everything about trees (like RockSystem and GrassSystem): the species of this world, the forest field, the planting and baking
## of a chunk (worker thread), the picking of a trunk under the mouse, and the felling and chopping. See docs/FLORA_PLAN.md.
##
## Cutting a tree works like breaking a rock:
##   - every blow cuts a NOTCH into the trunk where it was aimed (it deepens with every blow) and throws chips;
##   - blows needed = solidity of the wood x trunk thickness squared: a sapling falls in 3 blows, a thick old trunk takes many more;
##   - the last blow makes the tree FALL (TreePhysics): it tips over its foot, away from the player, and lies on the ground as a trunk;
##   - a fallen trunk is harvested log by log: every blow chops a length off its tip and gives wood, the last blow takes the last piece.
## Only exceptions are stored (changed: id -> damage, fallen state, or true = gone).

var gen: PlanetGenerator
var catalog: TreeCatalog
var field: TreeField
var material: ShaderMaterial
var changed := {}

func setup(p_gen: PlanetGenerator, world_seed: int) -> void:
	gen = p_gen
	TreeMaterial.declare_globals()
	catalog = TreeCatalog.new(world_seed)
	field = TreeField.new(catalog, world_seed)
	material = TreeMaterial.create(null)

func changed_snapshot() -> Dictionary:
	return changed.duplicate(true)

## The trees of one chunk and their baked mesh. Safe on a worker thread.
func build_chunk(coord: Vector3i, dens: PackedFloat32Array, colr: PackedColorArray, wlev: PackedFloat32Array, hlat: PackedFloat32Array,
		l0: Vector3i, changed_snap: Dictionary) -> Dictionary:
	var all := TreePlacer.place(gen, field, coord, dens, colr, wlev, hlat, l0)
	var trees: Array = []
	for t: TreeInst in all:
		if changed_snap.has(t.id):
			var m = changed_snap[t.id]
			if m is Dictionary:
				t.apply_state(m)
			else:
				continue                                           # gone
		trees.append(t)
	var origin := Vector3(coord * WorldConfig.CHUNK_SIZE)
	return {"trees": trees, "mesh": TreeMeshes.bake(trees, catalog, origin, 0), "far": TreeMeshes.bake(trees, catalog, origin, 1)}

# ---------------------------------------------------------------- numbers

## Blows to fell a standing tree.
func blows_to_fell(t: TreeInst) -> float:
	return maxf(3.0, catalog.by_id(t.type_id).hardness * pow(t.trunk_r * 2.0, 2.0) * 9.0)

## Blows to chop a fallen trunk completely: about one per metre, more for a thick trunk.
func blows_to_chop(t: TreeInst) -> float:
	return clampf(ceilf(t.length * (0.6 + t.trunk_r * 2.4)), 3.0, 40.0)

func units_per_log(t: TreeInst, cut: float) -> int:
	return maxi(1, roundi(60.0 * t.trunk_r * t.trunk_r * cut) + 1)

func wood_name(t: TreeInst) -> String:
	return catalog.by_id(t.type_id).wood

# ---------------------------------------------------------------- picking

## The nearest trunk on a ray (cylinders: standing trunks up to the crown, fallen ones along their axis).
## Returns {hit, tree, chunk, t, point, normal, a, d, r} (a, d, r: the axis of the trunk, for the target patch).
static func ray_trees(chunks: Dictionary, origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var best := {"hit": false}
	var best_t := max_dist
	for c: Vector3i in chunks:
		var ch: Chunk = chunks[c]
		if ch.trees.is_empty():
			continue
		if (ch.position + Vector3.ONE * 8.0).distance_to(origin) > max_dist + 16.0:
			continue
		for t: TreeInst in ch.trees:
			if t.state == TreeInst.FALLING:
				continue
			var a := t.pos
			var d := t.up
			var len := minf(t.height * 0.5, 6.0)
			var r := t.trunk_r * 1.25
			if t.state == TreeInst.FALLEN:
				d = t.axis
				len = t.remaining
				a = t.pos + t.shift + t.up * t.trunk_r * 0.9
			var hit := _ray_cylinder(origin, dir, a, d, len, r, best_t)
			if hit.x >= 0.0:
				best_t = hit.x
				var p := origin + dir * hit.x
				var on_axis := a + d * clampf((p - a).dot(d), 0.0, len)
				var nrm := (p - on_axis).normalized()
				best = {"hit": true, "tree": t, "chunk": ch, "t": hit.x, "point": p, "normal": nrm, "a": a, "d": d, "len": len, "r": r}
	return best

## Ray against a finite cylinder (axis from a along d, length len, radius r). Returns Vector2(t, 0) or (-1, 0).
static func _ray_cylinder(o: Vector3, dir: Vector3, a: Vector3, d: Vector3, len: float, r: float, max_t: float) -> Vector2:
	var oc := o - a
	var dd := dir.dot(d)
	var od := oc.dot(d)
	var A := 1.0 - dd * dd
	var B := 2.0 * (oc.dot(dir) - od * dd)
	var C := oc.dot(oc) - od * od - r * r
	if A < 1e-8:
		return Vector2(-1.0, 0.0)
	var disc := B * B - 4.0 * A * C
	if disc < 0.0:
		return Vector2(-1.0, 0.0)
	var sq := sqrt(disc)
	for tt in [(-B - sq) / (2.0 * A), (-B + sq) / (2.0 * A)]:
		if tt >= 0.0 and tt < max_t:
			var along: float = od + tt * dd
			if along >= 0.0 and along <= len:
				return Vector2(tt, 0.0)
	return Vector2(-1.0, 0.0)

# ---------------------------------------------------------------- cutting

## One blow on a trunk found by ray_trees. `from`: where the player stands (the tree falls away from there).
## Returns {"event": "hit" | "fell" | "chop" | "gone", "wood": name, "type": species key, "units": int, "dir": fall direction, "colors": chip colours}.
func hit(res: Dictionary, from: Vector3) -> Dictionary:
	var t: TreeInst = res.tree
	var ty := catalog.by_id(t.type_id)
	var out := {"event": "hit", "wood": ty.wood, "type": ty.key, "units": 0, "dir": Vector3.ZERO, "colors": [ty.bark, Color(0.86, 0.72, 0.5)]}
	if t.state == TreeInst.FALLEN:
		var cut := maxf(0.8, t.length / blows_to_chop(t))
		var take := minf(cut, t.remaining)
		t.remaining -= take
		var units := units_per_log(t, take)
		out.units = units
		if t.remaining < 0.45:
			changed[t.id] = true
			out.event = "gone"
		else:
			changed[t.id] = t.to_state()
			out.event = "chop"
		return out
	t.hits += 1.0
	var p: Vector3 = res.point
	var h := clampf((p - t.pos).dot(t.up), 0.4, 2.2)
	if t.hits <= 1.0 or absf(h - t.hit_h) < 0.9:
		t.hit_h = h if t.hits <= 1.0 else lerpf(t.hit_h, h, 0.3)
	var hd := (p - t.pos) - t.up * (p - t.pos).dot(t.up)
	if hd.length() > 0.001:
		t.hit_dir = hd.normalized() if t.hits <= 1.0 else (t.hit_dir + hd.normalized() * 0.3).normalized()
	if t.hits >= blows_to_fell(t):
		var away := (t.pos - from)
		away -= t.up * away.dot(t.up)
		out.event = "fell"
		out.dir = away.normalized() if away.length() > 0.01 else t.hit_dir
		return out
	changed[t.id] = t.to_state()
	return out

## The tree has landed: it lies on the ground along `axis` (from its foot) and is saved so.
func landed(t: TreeInst, axis: Vector3) -> void:
	t.state = TreeInst.FALLEN
	t.axis = axis
	t.shift = Vector3.ZERO
	t.length = t.height * 0.88
	t.remaining = t.length
	t.hits = 0.0
	changed[t.id] = t.to_state()
