class_name TreeFade
extends RefCounted
## Trees that block the view of the player fade out AS A WHOLE (trunk and crown together), not as a hole around the line of sight.
## Every frame the trees near the line from the camera to the player are tested as what they are (a trunk, a crown, a lying log); the
## blocking ones get a fade level that eases towards see-through (and back to solid when they stop blocking). The shader recognises a tree by
## its own id (the random number baked into every vertex of it, TreeMeshes.fade_id) and dithers all of it by that level, so no sorting and no
## transparency cost. Up to SLOTS trees fade at once, the most see-through first.

const SLOTS := 8
const SEE_THROUGH := 0.12            # how much of a blocking tree is left
const SPEED := 9.0                   # how fast it fades, per second
const CROWN_MARGIN := 0.35           # a crown fades when the view line passes this close to it
const TRUNK_MARGIN := 0.40
const SEARCH := 24.0                 # chunks farther than this from the view line are skipped

var _level := {}                     # tree fade id -> current level (1 = solid)

## `target`: the point of the player that must stay in view.
func update(chunks: Dictionary, cam_pos: Vector3, target: Vector3, delta: float) -> void:
	var blocking := {}
	var half := WorldConfig.CHUNK_SIZE * 0.5
	for c: Vector3i in chunks:
		var ch: Chunk = chunks[c]
		if ch.trees.is_empty():
			continue
		var centre := ch.position + Vector3.ONE * half
		if Geometry3D.get_closest_point_to_segment(centre, cam_pos, target).distance_to(centre) > SEARCH:
			continue
		for t: TreeInst in ch.trees:
			if _blocks(t, cam_pos, target):
				blocking[TreeMeshes.fade_id(t)] = true
	# ease every known tree towards its goal; forget the ones that are solid again
	for id in blocking:
		if not _level.has(id):
			_level[id] = 1.0
	var k := 1.0 - exp(-delta * SPEED)
	for id in _level.keys():
		_level[id] = lerpf(_level[id], SEE_THROUGH if blocking.has(id) else 1.0, k)
		if _level[id] > 0.985 and not blocking.has(id):
			_level.erase(id)
	_publish()

func _blocks(t: TreeInst, a: Vector3, b: Vector3) -> bool:
	if t.state == TreeInst.FALLEN:
		return _seg_dist(a, b, t.pos + t.shift, t.pos + t.shift + t.axis * t.remaining) < t.trunk_r + 0.3
	if t.state != TreeInst.STANDING:
		return false
	var top := t.pos + t.up * (t.height * 0.7)
	if _seg_dist(a, b, t.pos, top) < t.trunk_r + TRUNK_MARGIN:
		return true
	var crown := t.pos + t.up * (t.height * 0.72)
	return Geometry3D.get_closest_point_to_segment(crown, a, b).distance_to(crown) < t.canopy_r + CROWN_MARGIN

static func _seg_dist(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> float:
	var p := Geometry3D.get_closest_points_between_segments(a, b, c, d)
	return p[0].distance_to(p[1])

## The ids and levels of the fading trees go to the tree shader (global uniforms: two vec4 of ids, two of levels).
func _publish() -> void:
	var ids: Array = _level.keys()
	ids.sort_custom(func(x: float, y: float) -> bool: return _level[x] < _level[y])
	var id_v := [Vector4.ZERO, Vector4.ZERO]
	var lv_v := [Vector4.ONE, Vector4.ONE]
	for i in mini(ids.size(), SLOTS):
		var v: Vector4 = id_v[i / 4]
		var l: Vector4 = lv_v[i / 4]
		v[i % 4] = ids[i]
		l[i % 4] = _level[ids[i]]
		id_v[i / 4] = v
		lv_v[i / 4] = l
	RenderingServer.global_shader_parameter_set("tree_fade_ids_a", id_v[0])
	RenderingServer.global_shader_parameter_set("tree_fade_ids_b", id_v[1])
	RenderingServer.global_shader_parameter_set("tree_fade_lv_a", lv_v[0])
	RenderingServer.global_shader_parameter_set("tree_fade_lv_b", lv_v[1])
