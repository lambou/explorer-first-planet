class_name FarTerrain
extends Node3D
## Distant terrain: a quadtree of low-poly surface patches on a cube-sphere. Only the shape
## of the ground matters from far away, so there is no volume, no underground and no physics.
## Patches get coarser with distance, are not built behind the horizon, and are skipped
## where the full-detail chunks of VoxelWorld already cover the ground.

const MAX_DEPTH := 8              # finest patch ~31 m wide
const SPLIT := 1.5                # a node splits when the player is closer than SPLIT x its radius
const VIEW_MAX := 14000.0
const HOLE_RADIUS := 56.0
const UPDATE_DIST := 12.0
const MAX_INFLIGHT := 3
const APPLY_PER_FRAME := 6

const HOLE_SHADER := """
shader_type spatial;
uniform vec3 hole_center = vec3(0.0);
uniform float hole_radius = 56.0;
uniform vec3 sky_a = vec3(0.0);
uniform vec3 sky_b = vec3(0.0);
uniform float sky_r = 0.0;
varying vec3 wpos;

float hash31(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x),
				   mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y),
			   mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x),
				   mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
// soft colour variation (no texture): two octaves of value noise, fading out with distance
vec3 variation(vec3 albedo, vec3 wp, vec3 view_pos) {
	float n = vnoise(wp * 0.45) * 0.65 + vnoise(wp * 1.7) * 0.35;
	float fade = 1.0 - smoothstep(40.0, 160.0, length(view_pos));
	return albedo * (1.0 + (n - 0.5) * 0.20 * fade);
}
// below sea level the water has already eaten the light: red goes first, then green; at ~20 m it is nearly black
vec3 seabed(vec3 albedo, vec3 wp) {
	float depth = max(5120.0 - length(wp), 0.0);
	return albedo * exp(-depth * vec3(0.32, 0.14, 0.08));
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	if (distance(wpos, hole_center) < hole_radius) {
		discard;
	}
	if (sky_r > 0.0) {
		vec3 pa = wpos - sky_a;
		vec3 ba = sky_b - sky_a;
		float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
		if (length(pa - ba * h) < sky_r) {
			discard;
		}
	}
	ALBEDO = seabed(variation(COLOR.rgb, wpos, VERTEX), wpos);   // the engine already hands vertex colours over as linear
	ROUGHNESS = 1.0;
}
"""

var gen: PlanetGenerator
var material: ShaderMaterial
var water_material: ShaderMaterial
var nodes: Dictionary = {}        # Vector4i -> MeshInstance3D
var jobs: Dictionary = {}
var _wanted: Dictionary = {}
var _wanted_list: Array = []
var _queue: Array = []
var _done: Array = []
var _ready: Array = []
var _mutex := Mutex.new()
var _last_pos := Vector3.ZERO
var _has_pos := false

func setup(p_gen: PlanetGenerator, water: WaterSystem) -> void:
	gen = p_gen
	var sh := Shader.new()
	sh.code = HOLE_SHADER
	material = ShaderMaterial.new()
	material.shader = sh
	material.set_shader_parameter("hole_radius", 0.0)   # grows as full-detail chunks appear
	water_material = water.create_far_material()
	water_material.set_shader_parameter("hole_radius", 0.0)

## Far patches are invisible inside this bubble around the player: the full-detail chunks cover
## the ground there, and a patch sheet just under the surface would block digging. The bubble only
## grows as chunks get built, so until then the patches are the (instant) ground.
## A cave with an opening: remove the far terrain along the line of sight to the sky, so the sun
## and the sky really come in through the entrance (radius 0 = no tunnel).
func set_sky_cut(from: Vector3, to: Vector3, radius: float) -> void:
	material.set_shader_parameter("sky_a", from)
	material.set_shader_parameter("sky_b", to)
	material.set_shader_parameter("sky_r", radius)

func set_hole(p: Vector3, radius: float) -> void:
	material.set_shader_parameter("hole_center", p)
	material.set_shader_parameter("hole_radius", radius)
	water_material.set_shader_parameter("hole_center", p)
	water_material.set_shader_parameter("hole_radius", radius)

## Quadtree selection for a viewer at p. Returns the leaf nodes to draw.
func collect(p: Vector3) -> Array:
	var out: Array = []
	for face in 6:
		_collect(Vector4i(face, 0, 0, 0), p, out)
	return out

func _collect(key: Vector4i, p: Vector3, out: Array) -> void:
	var rho := CubeSphere.node_radius(key)
	var center := CubeSphere.node_center_dir(key) * float(WorldConfig.PLANET_RADIUS)
	var d := p.distance_to(center)
	if d - rho > VIEW_MAX:
		return
	if _behind_horizon(p, center, rho):
		return
	if key.y < MAX_DEPTH and d - rho < rho * SPLIT:
		for oj in 2:
			for oi in 2:
				_collect(Vector4i(key.x, key.y + 1, key.z * 2 + oi, key.w * 2 + oj), p, out)
	else:
		out.append(key)

## True when the whole node is hidden behind the curve of the planet (mountains considered).
static func _behind_horizon(p: Vector3, center: Vector3, rho: float) -> bool:
	var r := float(WorldConfig.PLANET_RADIUS)
	var pl := p.length()
	if pl < 1.0:
		return false
	var node_ang := rho / r
	var horizon := acos(minf(r / maxf(pl, r), 1.0)) + acos(r / (r + WorldConfig.MAX_HEIGHT))
	return p.angle_to(center) > horizon + node_ang

func update_center(pos: Vector3) -> void:
	if _has_pos and pos.distance_to(_last_pos) < UPDATE_DIST:
		return
	_has_pos = true
	_last_pos = pos
	_wanted_list = collect(pos)
	_wanted.clear()
	for k in _wanted_list:
		_wanted[k] = true
	_queue.clear()
	for k in _wanted_list:
		if not nodes.has(k) and not jobs.has(k):
			_queue.append(k)
	_queue.sort_custom(func(a: Vector4i, b: Vector4i) -> bool:
		return _prio(a) < _prio(b))
	_refresh()

func _prio(k: Vector4i) -> float:
	var rho := CubeSphere.node_radius(k)
	return (_last_pos.distance_to(CubeSphere.node_center_dir(k) * float(WorldConfig.PLANET_RADIUS)) - rho) / rho

## Free nodes nobody needs; keep old ones visible until their replacements are built.
func _refresh() -> void:
	var unloaded := {}
	var unloaded_anc := {}
	for w: Vector4i in _wanted_list:
		if nodes.has(w):
			continue
		unloaded[w] = true
		for dpt in w.y:
			unloaded_anc[CubeSphere.ancestor(w, dpt)] = true
	var cover := {}
	var cover_anc := {}
	for key: Vector4i in nodes.keys():
		if _wanted.has(key):
			continue
		var needed := unloaded_anc.has(key)
		if not needed:
			for dpt in key.y:
				if unloaded.has(CubeSphere.ancestor(key, dpt)):
					needed = true
					break
		if needed:
			cover[key] = true
			for dpt in key.y:
				cover_anc[CubeSphere.ancestor(key, dpt)] = true
		else:
			nodes[key].queue_free()
			nodes.erase(key)
	for key: Vector4i in nodes:
		var vis := true
		if _wanted.has(key):
			if cover_anc.has(key):
				vis = false
			else:
				for dpt in key.y:
					if cover.has(CubeSphere.ancestor(key, dpt)):
						vis = false
						break
		(nodes[key] as MeshInstance3D).visible = vis

func _process(_delta: float) -> void:
	_mutex.lock()
	_ready.append_array(_done)
	_done.clear()
	_mutex.unlock()
	var n := 0
	while not _ready.is_empty() and n < APPLY_PER_FRAME:
		var r: Dictionary = _ready.pop_front()
		var k: Vector4i = r.key
		jobs.erase(k)
		if nodes.has(k) or not _wanted.has(k):
			continue
		n += 1
		var res: Dictionary = r.mesh
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = res.verts
		arrays[Mesh.ARRAY_NORMAL] = res.normals
		arrays[Mesh.ARRAY_COLOR] = res.colors
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.material_override = material
		mi.position = res.origin
		add_child(mi)
		nodes[k] = mi
		var wv: PackedVector3Array = res.wverts
		if not wv.is_empty():
			var warr := []
			warr.resize(Mesh.ARRAY_MAX)
			warr[Mesh.ARRAY_VERTEX] = wv
			warr[Mesh.ARRAY_NORMAL] = res.wnormals
			warr[Mesh.ARRAY_TEX_UV] = res.wuvs
			warr[Mesh.ARRAY_COLOR] = res.wcolors
			warr[Mesh.ARRAY_INDEX] = res.windex
			var wm := ArrayMesh.new()
			wm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, warr)
			var water_mi := MeshInstance3D.new()
			water_mi.mesh = wm
			water_mi.material_override = water_material
			water_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.add_child(water_mi)
		var sv: PackedVector3Array = res.sverts
		if not sv.is_empty():
			var sarr := []
			sarr.resize(Mesh.ARRAY_MAX)
			sarr[Mesh.ARRAY_VERTEX] = sv
			sarr[Mesh.ARRAY_NORMAL] = res.snormals
			sarr[Mesh.ARRAY_COLOR] = res.scolors
			var sm := ArrayMesh.new()
			sm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sarr)
			var skirt_mi := MeshInstance3D.new()
			skirt_mi.mesh = sm
			skirt_mi.material_override = material
			skirt_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.add_child(skirt_mi)
	if n > 0:
		_refresh()
	while jobs.size() < MAX_INFLIGHT and not _queue.is_empty():
		var k: Vector4i = _queue.pop_front()
		if nodes.has(k) or jobs.has(k) or not _wanted.has(k):
			continue
		jobs[k] = true
		WorkerThreadPool.add_task(_job.bind(k), true)

func _job(k: Vector4i) -> void:
	var mesh := PatchMesher.build(gen, k)
	_mutex.lock()
	_done.append({"key": k, "mesh": mesh})
	_mutex.unlock()

func stats() -> String:
	return "far patches %d  building %d" % [nodes.size(), jobs.size() + _queue.size()]
