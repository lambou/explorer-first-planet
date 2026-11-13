class_name TreeMaterial
extends RefCounted
## The tree shader (trunks and crowns share it; the baked vertex colour carries the paint, its alpha the wind weight):
##  - WIND: the same shared wind as the grass; each vertex sways by its weight (0 at the foot, 1 at the top) with a gust field and a slow
##    per-tree phase (UV.x), so a forest ripples instead of moving as one.
##  - LIGHT: lit by hand with the game's sun and ambient (like the grass), half-lambert so the shading is soft and cozy; night, dusk and the
##    underwater dimming reach the trees through the same values.
##  - FADE: trees that block the view of the player fade out AS A WHOLE in a dither (no sorting, no transparency cost): TreeFade decides which
##    trees, the shader recognises each by its id (UV.x, the same number in every vertex of a tree). Whatever is right at the camera fades too.
## Shared uniforms: grass_wind / grass_sun / grass_sun_col (GrassMaterial), tree_cam = camera position, tree_fade_* = the fading trees (TreeFade).

const CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled;

global uniform vec4 grass_wind;
global uniform vec4 grass_sun;
global uniform vec4 grass_sun_col;
global uniform vec4 tree_cam;
global uniform vec4 tree_fade_ids_a;
global uniform vec4 tree_fade_ids_b;
global uniform vec4 tree_fade_lv_a;
global uniform vec4 tree_fade_lv_b;

uniform float sway = 1.0;
uniform float leaf_light = 1.0;

varying vec3 v_col;
varying vec3 v_n;
varying vec3 v_pos;
varying float v_id;

void vertex() {
	v_id = UV.x;                                   // which tree this vertex belongs to
	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 up = normalize(wpos);
	vec3 wdir = grass_wind.xyz - up * dot(up, grass_wind.xyz);
	if (length(wdir) < 0.2) {
		wdir = cross(up, vec3(0.0, 1.0, 0.02));
	}
	wdir = normalize(wdir);
	float w = clamp(COLOR.a, 0.0, 1.0);
	float rnd = UV.x;
	// gusts: two cheap travelling waves (a noise lookup per vertex of a forest costs too much)
	vec3 side_w = cross(up, wdir);
	float gust = 0.5 + 0.28 * sin(dot(wpos, wdir) * 0.06 - TIME * 1.2) + 0.22 * sin(dot(wpos, side_w) * 0.09 + TIME * 0.6 + dot(wpos, wdir) * 0.03);
	float amount = grass_wind.w * (0.2 + 0.9 * gust) * sway;
	float slow = sin(TIME * 0.7 + rnd * 6.28 + dot(wpos, vec3(0.05, 0.03, 0.04)));
	float flutter = sin(TIME * 2.6 + rnd * 20.0 + dot(wpos, vec3(0.9, 0.7, 0.8))) * 0.5;
	vec3 disp = wdir * (amount * 0.35 + slow * 0.05 * (0.4 + grass_wind.w)) * w * w * 2.0
		+ cross(up, wdir) * (flutter * 0.04 * w * (0.3 + grass_wind.w));
	VERTEX += disp * mat3(MODEL_MATRIX);          // chunks only move (no rotation): the world displacement is the local one
	v_col = COLOR.rgb;
	v_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// interleaved gradient noise: a cheap, even dither (no array, no branches)
float dither(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void fragment() {
	// a tree that blocks the view fades whole (its id is in the list TreeFade publishes); anything right at the camera fades too
	float alpha = 1.0;
	vec4 da = abs(vec4(v_id) - tree_fade_ids_a);
	vec4 db = abs(vec4(v_id) - tree_fade_ids_b);
	if (da.x < 0.000002) { alpha = tree_fade_lv_a.x; }
	if (da.y < 0.000002) { alpha = tree_fade_lv_a.y; }
	if (da.z < 0.000002) { alpha = tree_fade_lv_a.z; }
	if (da.w < 0.000002) { alpha = tree_fade_lv_a.w; }
	if (db.x < 0.000002) { alpha = tree_fade_lv_b.x; }
	if (db.y < 0.000002) { alpha = tree_fade_lv_b.y; }
	if (db.z < 0.000002) { alpha = tree_fade_lv_b.z; }
	if (db.w < 0.000002) { alpha = tree_fade_lv_b.w; }
	float near2 = dot(v_pos - tree_cam.xyz, v_pos - tree_cam.xyz);
	if (near2 < 5.76) {
		alpha = min(alpha, smoothstep(0.5, 2.4, sqrt(near2)));
	}
	if (alpha < 0.999 && alpha < dither(FRAGCOORD.xy)) {
		discard;
	}
	vec3 n = normalize(v_n);
	if (!FRONT_FACING) {
		n = -n;
	}
	float ndl = dot(n, normalize(grass_sun.xyz)) * 0.5 + 0.5;            // half lambert: soft
	vec3 light = grass_sun.w + grass_sun_col.rgb * ndl * 0.95;
	ALBEDO = v_col * light * 1.35;
}
"""

static var _declared := false

static func create(t: TreeType) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = CODE
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("sway", t.sway if t != null else 1.0)
	return m

## Declare the shared uniforms (once per process; GrassMaterial declares the wind and sun ones).
static func declare_globals() -> void:
	GrassMaterial.declare_globals()
	if _declared:
		return
	_declared = true
	RenderingServer.global_shader_parameter_add("tree_cam", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0))
	RenderingServer.global_shader_parameter_add("tree_target", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0))
	for n in ["tree_fade_ids_a", "tree_fade_ids_b"]:
		RenderingServer.global_shader_parameter_add(n, RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0))
	for n in ["tree_fade_lv_a", "tree_fade_lv_b"]:
		RenderingServer.global_shader_parameter_add(n, RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(1, 1, 1, 1))
