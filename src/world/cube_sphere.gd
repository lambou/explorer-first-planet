class_name CubeSphere
extends RefCounted
## Maps the 6 faces of a cube onto the sphere. A far-terrain node is a quadtree square on a
## face: key = Vector4i(face, depth, i, j); depth d splits a face into 2^d x 2^d squares.

## Unit direction for face coordinates u, v in [-1, 1].
static func direction(face: int, u: float, v: float) -> Vector3:
	var p: Vector3
	match face:
		0: p = Vector3(1.0, v, u)
		1: p = Vector3(-1.0, v, -u)
		2: p = Vector3(u, 1.0, v)
		3: p = Vector3(u, -1.0, -v)
		4: p = Vector3(u, v, 1.0)
		_: p = Vector3(-u, v, -1.0)
	return p.normalized()

## Face rectangle covered by a node: Rect2(u0, v0, size, size).
static func node_rect(key: Vector4i) -> Rect2:
	var size := 2.0 / float(1 << key.y)
	return Rect2(-1.0 + key.z * size, -1.0 + key.w * size, size, size)

static func node_center_dir(key: Vector4i) -> Vector3:
	var r := node_rect(key)
	return direction(key.x, r.position.x + r.size.x * 0.5, r.position.y + r.size.y * 0.5)

## Radius (metres) of the sphere around the node centre (at sea level) that contains the node.
static func node_radius(key: Vector4i) -> float:
	var r := node_rect(key)
	var big := float(WorldConfig.PLANET_RADIUS)
	var c := node_center_dir(key) * big
	var m := 0.0
	for i in 4:
		var d := direction(key.x, r.position.x + (i & 1) * r.size.x, r.position.y + ((i >> 1) & 1) * r.size.y)
		m = maxf(m, c.distance_to(d * big))
	return m

static func parent(key: Vector4i) -> Vector4i:
	return Vector4i(key.x, key.y - 1, key.z >> 1, key.w >> 1)

## Ancestor of `key` at a shallower depth.
static func ancestor(key: Vector4i, depth: int) -> Vector4i:
	var sh := key.y - depth
	return Vector4i(key.x, depth, key.z >> sh, key.w >> sh)
