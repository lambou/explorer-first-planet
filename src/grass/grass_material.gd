class_name GrassMaterial
extends RefCounted
## The grass shader. Everything that moves lives in the vertex stage, so the CPU does nothing per frame:
##  - WIND: a gust field (value noise scrolling along the wind), a slow sway, a quick flutter; the blade bends more towards its
##    tip (bend = t^2), always along the ground (the wind is projected on the local tangent plane of the planet).
##  - SEA GRASS (`water = 1`): the same blades moved by a slow current, and darkened / blued with depth like the sea bed.
##  - DISTANCE: every clump has a random number; beyond `fade_start` only the share of clumps "worth keeping" stays and the
##    others shrink to nothing: smooth thinning with distance, no pop, no CPU work. The terrain colour carries the far field.
##  - COLOUR: root = the ground colour of the place (so the grass grows out of the ground), tip = the kind's tip colour with
##    a little variation per clump; soft ambient occlusion at the root, a hint of translucency towards the sun.
## Shared uniforms (set once per frame by GrassSystem, see `grass_wind`, `grass_player`, `grass_snow`):
##   grass_wind   = (wind direction xyz, strength 0..1)
##   grass_player = (position xyz, radius): the grass leans away from it (step G2; radius 0 = off)
##   grass_snow   = 0..1 (step G4: the climate layer whitens and shortens the blades; 0 = none)

const CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled;       // lit by hand below, like the ground: thin double-sided blades get black / white faces from the engine lighting

global uniform vec4 grass_wind;
global uniform vec4 grass_player;
global uniform float grass_snow;
global uniform vec4 grass_sun;         // xyz = direction towards the sun, w = ambient light
global uniform vec4 grass_sun_col;     // rgb = sun colour times its energy

uniform vec3 base_col : source_color = vec3(0.25, 0.5, 0.15);
uniform vec3 tip_col : source_color = vec3(0.62, 0.82, 0.30);
uniform float sway = 1.0;
uniform float water = 0.0;
uniform float flower = 0.0;
uniform float fade_start = 26.0;
uniform float fade_end = 62.0;

varying vec3 v_tint;
varying float v_t;
varying float v_rand;
varying float v_gust;
varying vec3 v_wpos;
varying vec3 v_up;

float h13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}
float vnoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h13(i), h13(i + vec3(1, 0, 0)), f.x), mix(h13(i + vec3(0, 1, 0)), h13(i + vec3(1, 1, 0)), f.x), f.y),
			   mix(mix(h13(i + vec3(0, 0, 1)), h13(i + vec3(1, 0, 1)), f.x), mix(h13(i + vec3(0, 1, 1)), h13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;                 // where this clump stands (its root)
	vec3 up = normalize(origin);                       // the planet's radial direction here
	float t = UV.y;                                    // 0 at the root, 1 at the tip (carried in the UV: the vertex COLOR is multiplied by the
	                                                   // instance colour, which a MultiMesh without colours fills with garbage)
	float rnd = clamp(INSTANCE_CUSTOM.a, 0.0, 1.0);

	// thinning with distance: keep the clumps whose random number is below the share worth keeping
	float dist = length((MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	float keep = 1.0 - smoothstep(fade_start, fade_end, dist);
	float grow = keep >= 0.999 ? 1.0 : clamp((keep - rnd) * 5.0, 0.0, 1.0);     // full size inside the fade distance, then the clumps with the highest random numbers go first
	float snow_short = 1.0 - 0.45 * grass_snow;
	// the grass right around the player is trodden down: the ball is never hidden in it
	float near_player = smoothstep(0.5, 2.2, length(origin - grass_player.xyz));
	snow_short *= mix(0.3, 1.0, grass_player.w > 0.0 ? near_player : 1.0);       // snow bends the blades down and shortens them (the climate layer, G4)

	// the wind, along the ground
	vec3 wdir = grass_wind.xyz - up * dot(up, grass_wind.xyz);
	if (length(wdir) < 0.2) {
		wdir = cross(up, vec3(0.0, 1.0, 0.02));
	}
	wdir = normalize(wdir);
	float strength = grass_wind.w;
	float gust = vnoise3(origin * 0.09 - wdir * (TIME * 1.7));          // a field of gusts running with the wind
	float bend = t * t;
	float slow_sway = sin(TIME * 0.9 + dot(origin, vec3(0.31, 0.17, 0.23)) + rnd * 6.28);
	float flutter = sin(TIME * 4.3 + rnd * 40.0 + t * 3.0) * 0.5 + sin(TIME * 7.1 + rnd * 17.0) * 0.5;
	float amount = strength * (0.25 + 0.9 * gust) * sway;
	vec3 disp = wdir * (amount * bend * 0.22) + wdir * (slow_sway * 0.025 * bend * (0.4 + strength)) + cross(up, wdir) * (flutter * 0.012 * bend * (0.3 + strength));
	disp -= up * (amount * bend * 0.05);                // the blade dips as it bends
	if (water > 0.5) {
		// sea grass: a slow current, mostly side to side, plus a gentle rise and fall
		float cur = sin(TIME * 1.1 + dot(origin, vec3(0.37, 0.21, 0.29)) + t * 2.2) * 0.5 + 0.5;
		disp = wdir * (cur * 0.28 * bend) + cross(up, wdir) * (sin(TIME * 0.8 + rnd * 9.0 + t * 3.0) * 0.12 * bend);
		gust = cur;
	}
	// the player pushes the grass aside (G2): leans away from the ball
	vec3 to_clump = origin - grass_player.xyz;
	float pd = length(to_clump);
	if (grass_player.w > 0.0 && pd < grass_player.w) {
		float k = 1.0 - pd / grass_player.w;
		vec3 away = to_clump - up * dot(up, to_clump);
		disp += normalize(away + vec3(0.0001)) * (k * k * 0.5 * bend);
		disp -= up * (k * 0.25 * bend);
	}
	// the bend was worked out in metres in the world: bring it into the clump's own axes (they are orthogonal, only scaled)
	vec3 ax = normalize(MODEL_MATRIX[0].xyz + vec3(0.00001));
	vec3 ay = normalize(MODEL_MATRIX[1].xyz + vec3(0.00001));
	vec3 az = normalize(MODEL_MATRIX[2].xyz + vec3(0.00001));
	float sc = max(length(MODEL_MATRIX[1].xyz), 0.25);                  // the clump's height scale: metres -> clump units
	vec3 ldisp = vec3(dot(ax, disp), dot(ay, disp), dot(az, disp)) / sc;
	ldisp = clamp(ldisp, vec3(-0.6), vec3(0.6));      // a blade never bends further than this (in clump units)
	VERTEX = (VERTEX * grow * snow_short) + ldisp * grow;

	v_up = up;
	v_tint = clamp(INSTANCE_CUSTOM.rgb, vec3(0.0), vec3(1.0));
	v_t = t;
	v_rand = rnd;
	v_gust = gust;
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = smoothstep(0.0, 1.0, v_t);
	vec3 root = mix(v_tint, base_col, 0.45) * 0.95;
	vec3 tip = tip_col * (0.88 + 0.24 * v_rand);
	tip = mix(tip, vec3(0.95, 0.97, 1.0), grass_snow * smoothstep(0.3, 1.0, v_t));      // snow on the tips (G4)
	vec3 col = mix(root, tip, t);
	if (flower > 0.5) {
		// a flower: green stem, then the head in the flower colour (the head vertices are at UV.y = 1)
		col = v_t > 0.93 ? tip_col * (0.95 + 0.1 * v_rand) : mix(root, tip_col * 0.55 + vec3(0.0, 0.25, 0.0), t * 0.7);
	}
	col *= 1.0 + 0.10 * v_gust * v_t;                   // the gusts lighten the tips a little as they pass
	if (water > 0.5) {
		float depth = max(5120.0 - length(v_wpos), 0.0);
		col *= exp(-depth * vec3(0.30, 0.13, 0.07));    // the sea eats the red first, then the green
	}
	// every blade is lit like the ground it grows from: sun by the angle of the ground, plus the ambient light (both come from the
	// game's own sun and environment each frame, so night, dusk and the underwater dimming apply to the grass too)
	float ndl = max(dot(normalize(v_up), normalize(grass_sun.xyz)), 0.0);
	vec3 light = grass_sun.w + grass_sun_col.rgb * ndl;
	light += grass_sun_col.rgb * 0.18 * smoothstep(0.4, 1.0, v_t) * (1.0 - ndl);      // a little light through the thin tips
	ALBEDO = col * light * 1.55 * mix(0.75, 1.0, t);          // the roots are a bit darker (the blades shade each other)
}
"""

static func create(t: GrassType) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = CODE
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("base_col", t.base_color)
	m.set_shader_parameter("tip_col", t.tip_color)
	m.set_shader_parameter("sway", t.sway)
	m.set_shader_parameter("water", 1.0 if t.underwater else 0.0)
	m.set_shader_parameter("flower", 1.0 if t.flower else 0.0)
	return m

## Declare the shared uniforms (once per process). Safe to call again.
static var _declared := false

static func declare_globals() -> void:
	if _declared:
		return
	_declared = true
	RenderingServer.global_shader_parameter_add("grass_wind", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(1, 0, 0, 0.5))
	RenderingServer.global_shader_parameter_add("grass_player", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0))
	RenderingServer.global_shader_parameter_add("grass_snow", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	RenderingServer.global_shader_parameter_add("grass_sun", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 1, 0, 0.4))
	RenderingServer.global_shader_parameter_add("grass_sun_col", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0.7, 0.7, 0.7, 1))
