class_name RockContact
extends RefCounted
## Rocks as OBSTACLES for things that fall (other rocks, felled trees). It only answers questions; what a falling thing does about the
## answer is its own physics' business (RockPhysics, TreePhysics).
##   nearby(): the rocks around a point, with their frames (built once per list; a rock does not move while it stands).
##   depth(): how far inside a rock a world point lies (its own surface, bites included: > 0 inside, < 0 outside).
##   normal(): which way the rock's surface faces there.
## Cost: nothing at all when no rock is near (an empty list), a few surface lookups per outline point otherwise.

## Rocks within `radius` of `center` (plus their own size), each as {"r": RockInst, "f": frame or null (made on first use)}. `skip` is left out (the falling rock itself).
## Rocks live in the chunk of their centre, so a handful of chunks around the point are enough.
static func nearby(world: VoxelWorld, center: Vector3, radius: float, skip: RockInst = null) -> Array:
	var out := []
	var c0 := VoxelWorld.world_to_chunk(center)
	var span := ceili((radius + 4.0) / WorldConfig.CHUNK_SIZE)
	for dz in range(-span, span + 1):
		for dy in range(-span, span + 1):
			for dx in range(-span, span + 1):
				var ch: Chunk = world.chunks.get(c0 + Vector3i(dx, dy, dz))
				if ch == null or ch.rocks.is_empty():
					continue
				for r: RockInst in ch.rocks:
					if r != skip and r.pos.distance_to(center) < radius + r.size * 1.75:
						out.append({"r": r, "f": null})                  # the frame is made the first time a point comes near this rock (_frame)
	return out

## How far inside the rock `c` (an entry of nearby()) the world point `p` lies, in metres.
static func depth(c: Dictionary, p: Vector3) -> float:
	var r: RockInst = c.r
	var q := RockMesher.to_local(r, _frame(c), p)
	var l := q.length()
	if l < 0.0001:
		return r.size
	if l > r.size * 1.75:
		return -9.0
	if r.bites.is_empty():
		# The lumps move the surface at most `amp` of its radius in or out of the smooth ellipsoid. A point clearly outside that (the usual
		# case for most of a falling rock's outline) needs no noise at all: only the points near the surface pay for the exact answer.
		var f: Dictionary = c.f
		var e := sqrt((q.x / f.sx) * (q.x / f.sx) + (q.y / f.sy) * (q.y / f.sy) + (q.z / f.sz) * (q.z / f.sz))
		var outer := l / maxf(e, 0.0001) * (1.0 + r.lump_amplitude())
		if l > outer + 0.35:
			return outer - l
	return RockMesher.surface_radius(r, c.f, q / l) - l

## The way the rock's surface faces at (or near) the world point `p`.
static func normal(c: Dictionary, p: Vector3) -> Vector3:
	return RockMesher._normal_at(c.r, _frame(c), p)

## The rock's frame, made on first use and kept in the entry (most listed rocks are never touched, and a frame costs a few hash lookups).
static func _frame(c: Dictionary) -> Dictionary:
	if c.f == null:
		c.f = RockMesher.frame_of(c.r)
	return c.f
