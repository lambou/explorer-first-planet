class_name UnderwaterRays
extends Node3D
## Sunbeams under the water ("god rays"). Why they exist (physics): sunlight is bent by the wavy surface (Snell's law, n_water = 1.33), the waves act
## as small lenses that focus it into thin sheets of light that run down from the surface, and particles in the water scatter some of it toward the
## eye, which is what makes the sheets visible. They are strongest right under the surface and in the daytime, fade with depth (absorption), look
## brightest when you look toward the sun (forward scattering) and shimmer as the waves move.
## How it is done here (the project uses the Compatibility renderer: no volumetric fog, no post effects): a lattice of long thin strips of light
## hangs from the water surface along the REFRACTED sun direction. Each strip turns about its own axis toward the camera (a cylindrical billboard),
## is drawn additively, soft across its width, faded at its top and by depth, and its brightness runs along it with scrolling noise.
## One mesh, one draw call. Display only. Call update() every frame.

const CELL := 8.0                  # metres between neighbouring strips' cells (the lattice repeats, so it never ends)
const GRID := 7                    # cells each way round the camera
const PER_CELL := 5                # strips per cell
const LENGTH := 40.0               # how far a strip reaches down along the beam
const WATER_N := 1.333

const CODE := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;

uniform vec3 ray_dir = vec3(0.0, -1.0, 0.0);   // world, unit: the way the refracted sunlight runs (down)
uniform vec3 surf_up = vec3(0.0, 1.0, 0.0);
uniform float strength = 0.0;
uniform float length_m = 40.0;
uniform vec3 tint = vec3(0.45, 0.85, 0.95);

varying vec3 wp;
varying vec3 wtop;
varying float vu;
varying float vv;
varying float vseed;

float h21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	vec3 top = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 side = cross(ray_dir, cam - top);
	side = length(side) > 0.001 ? normalize(side) : vec3(1.0, 0.0, 0.0);
	wp = top + side * (UV.x * COLOR.r) + ray_dir * (UV.y * length_m);
	wtop = top;
	vu = UV.x;
	vv = UV.y;
	vseed = COLOR.g;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
}

void fragment() {
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float depth = vv * length_m * max(dot(ray_dir, -surf_up), 0.0);        // metres below the surface along the strip
	float edge = exp(-vu * vu * 3.5);                                        // soft, gaussian across the width (no hard edge)
	float top_in = smoothstep(0.0, 0.05, vv);                                // grows out of the surface
	float depth_f = exp(-depth / 11.0);                                      // absorption: the beams die with depth, brightest at the surface
	float n = vnoise(vec2(vseed * 40.0 + vv * 2.2, TIME * 0.12 + vseed * 10.0));
	float flick = 0.65 + 0.35 * sin(TIME * (0.5 + vseed) + vseed * 20.0);    // the waves moving over them
	vec3 vdir = normalize(wp - cam);
	float cos_s = max(dot(vdir, -ray_dir), 0.0);                             // looking toward the sun: forward scattering is strongest
	float phase = 0.35 + 0.65 * pow(cos_s, 3.0);
	float d = length(wtop - cam);
	float dist_f = (1.0 - smoothstep(16.0, 28.0, d)) * smoothstep(3.0, 11.0, length(wp - cam));
	float bottom_out = 1.0 - smoothstep(0.55, 1.0, vv);                     // and thin out toward the lower end
	float i = strength * edge * edge * top_in * bottom_out * depth_f * (0.25 + 0.75 * n) * flick * phase * dist_f * 1.25;
	ALBEDO = tint * i;
	ALPHA = 1.0;
}
"""

var _mat: ShaderMaterial
var _mi: MeshInstance3D
var _off := Vector2.ZERO           # how far the camera has moved in the local tangent plane (to snap the lattice to its cells)
var _last := Vector3.ZERO
var _ready_pos := false

func _init() -> void:
	top_level = true
	visible = false
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	for gx in GRID:
		for gz in GRID:
			for k in PER_CELL:
				var base := Vector3((gx - GRID / 2 + rng.randf_range(-0.5, 0.5)) * CELL, 0.0, (gz - GRID / 2 + rng.randf_range(-0.5, 0.5)) * CELL)
				var width := rng.randf_range(0.5, 1.8)
				var seed := rng.randf()
				var b := verts.size()
				for c in 4:
					verts.append(base)
					uvs.append(Vector2(-1.0 if (c == 0 or c == 3) else 1.0, 0.0 if c < 2 else 1.0))
					cols.append(Color(width, seed, 0.0, 1.0))
				idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.custom_aabb = AABB(Vector3(-200, -200, -200), Vector3(400, 400, 400))
	var sh := Shader.new()
	sh.code = CODE
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mi = MeshInstance3D.new()
	_mi.mesh = mesh
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mi.extra_cull_margin = 1000.0
	add_child(_mi)
	_build_particles()

## Fine particles floating in the water ("marine snow"): they catch the light, twinkle, and show the water is a volume. Tiny camera-facing quads that
## tile the water round the camera (each wraps round it, so the field never ends); one mesh, one draw call.
const PARTICLES := 600
const PCODE := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;
uniform float strength = 0.0;
uniform float box = 26.0;
uniform vec3 cam_pos = vec3(0.0);
uniform vec3 surf_up = vec3(0.0, 1.0, 0.0);
uniform float cam_depth = 0.0;
varying float vtw;
varying float vfade;
varying vec2 vq;
void vertex() {
	vec3 b = VERTEX;
	vec3 drift = vec3(0.05, -0.04, 0.03) * TIME;
	vec3 rel = b + drift - cam_pos;
	rel = rel - box * floor(rel / box + 0.5);                // wrapped into a box round the camera
	vec3 centre = cam_pos + rel;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 to = normalize(cam - centre);
	vec3 side = normalize(cross(to, surf_up));
	vec3 upv = cross(side, to);
	float size = 0.02 + 0.045 * COLOR.r;
	vec3 wp = centre + (side * UV.x + upv * UV.y) * size;
	float d = length(centre - cam);
	vfade = (1.0 - smoothstep(6.0, box * 0.5, d)) * smoothstep(0.8, 2.0, d);
	vtw = 0.5 + 0.5 * sin(TIME * (1.0 + 3.0 * COLOR.g) + COLOR.g * 40.0);
	vq = UV;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
}
void fragment() {
	float r = length(vq);
	float a = (1.0 - smoothstep(0.3, 1.0, r)) * vfade * vtw * strength;
	ALBEDO = vec3(0.75, 0.95, 1.0) * a;
	ALPHA = 1.0;
}
"""
var _pmat: ShaderMaterial
var _pmi: MeshInstance3D

func _build_particles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 98765
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for i in PARTICLES:
		var b := Vector3(rng.randf_range(-13.0, 13.0), rng.randf_range(-13.0, 13.0), rng.randf_range(-13.0, 13.0)) + Vector3(2000.0, 0.0, 0.0) * 0.0
		var r := rng.randf()
		var g := rng.randf()
		var base := verts.size()
		for c in 4:
			verts.append(b)
			uvs.append(Vector2(-1.0 if (c == 0 or c == 3) else 1.0, -1.0 if c < 2 else 1.0))
			cols.append(Color(r, g, 0.0, 1.0))
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.custom_aabb = AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))
	var sh := Shader.new()
	sh.code = PCODE
	_pmat = ShaderMaterial.new()
	_pmat.shader = sh
	_pmi = MeshInstance3D.new()
	_pmi.mesh = mesh
	_pmi.material_override = _pmat
	_pmi.top_level = true
	_pmi.global_transform = Transform3D.IDENTITY
	_pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pmi.extra_cull_margin = 1.0e5
	add_child(_pmi)

## Snell's law: the way sunlight (travelling along `sun_dir`) runs once it has entered the water through a surface whose normal is `up`.
static func refract_sun(sun_dir: Vector3, up: Vector3) -> Vector3:
	var inc := sun_dir.normalized()
	var eta := 1.0 / WATER_N
	var cosi := inc.dot(up)                                                    # (negative: the light comes down)
	var k := 1.0 - eta * eta * (1.0 - cosi * cosi)
	if k > 0.0:
		return (inc * eta - up * (eta * cosi + sqrt(k))).normalized()
	return inc

## cam_pos: the camera; up: the planet's radial direction there; sun_dir: the way the sunlight travels (from the sun into the scene);
## cam_depth: metres of water above the camera (negative = above the water); daylight 0..1.
func update(cam_pos: Vector3, up: Vector3, sun_dir: Vector3, cam_depth: float, daylight: float) -> void:
	var sun_up := -sun_dir.dot(up)                                         # how high the sun stands over the local horizon (1 = overhead)
	var day := smoothstep(0.03, 0.4, sun_up) * clampf(daylight, 0.0, 1.0)      # a low sun still makes (long, slanted) beams, a sun below the horizon none
	var under := smoothstep(0.1, 0.6, cam_depth) * exp(-maxf(cam_depth, 0.0) / 25.0) * (1.0 - smoothstep(40.0, 70.0, cam_depth))
	var strength := day * under
	# the particles are lit by the sun too but are seen at any depth and a little at dusk
	var psun := (0.25 + 0.75 * day) * clampf(daylight, 0.0, 1.0) * smoothstep(0.1, 0.6, cam_depth) * exp(-maxf(cam_depth, 0.0) / 40.0)
	_pmi.visible = psun > 0.01
	if _pmi.visible:
		_pmat.set_shader_parameter("strength", psun * 1.3)
		_pmat.set_shader_parameter("cam_pos", cam_pos)
		_pmat.set_shader_parameter("surf_up", up)
	visible = true
	_mi.visible = strength > 0.01
	if not _mi.visible:
		_ready_pos = false
		return
	var t1 := up.cross(Vector3.RIGHT)
	if t1.length() < 0.01:
		t1 = up.cross(Vector3.FORWARD)
	t1 = t1.normalized()
	var t2 := t1.cross(up)
	if _ready_pos:
		var d := cam_pos - _last
		_off += Vector2(d.dot(t1), d.dot(t2))
	_ready_pos = true
	_last = cam_pos
	var cell := Vector2(floorf(_off.x / CELL) * CELL, floorf(_off.y / CELL) * CELL)
	var frac := _off - cell
	var surface := cam_pos + up * cam_depth
	global_transform = Transform3D(Basis(t1, up, t2), surface - t1 * frac.x - t2 * frac.y)
	var ray := refract_sun(sun_dir, up)
	_mat.set_shader_parameter("ray_dir", ray.normalized())
	_mat.set_shader_parameter("surf_up", up)
	_mat.set_shader_parameter("strength", strength)
	_mat.set_shader_parameter("length_m", LENGTH)
