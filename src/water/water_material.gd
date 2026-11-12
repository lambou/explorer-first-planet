class_name WaterMaterial
extends RefCounted
## The water surface shader. Look and behaviour come from a few rules, not from simulation:
##
##  STATES (uniform `agitation`, see WaterState): 0 = glassy calm, a near-mirror of the sky (the lake with the
##    dock); 1 = storm: bigger and faster waves, wide foam, whitecaps, broad rough glitter.
##  DISTANCE: the wave normals are only resolved near the camera (wave_near .. wave_far). Farther away they
##    are removed and their slope variance is moved into the roughness (Bruneton et al.), so open water in the
##    distance is smooth: flat deep blue + Fresnel sky reflection + a soft, broad sun glitter (Cox-Munk slope
##    statistics: mean-square slope ~ 0.003 + 0.0051 * wind), never visible wave shapes.
##  FRESNEL: F0 = 0.02 (SPECULAR 0.25). Looking down you see the body colour / the bottom, near the horizon
##    the sky. Reflection is kept visible by making the surface opaque as the Fresnel term grows.
##  DEPTH: body colour goes turquoise -> blue -> near black with depth (blue-hole photo). Transparency follows
##    Beer-Lambert along the view path, so the sea bed is hidden past ~8-10 m and only the shallow shelf is visible.
##  SHORE: foam bands travel up the beach; their width and speed grow with the state.
##  RIVER water (kind 2): shallow, clear, slightly green-brown, tiny ripples, no foam, bed visible.
##  CAVE water (kind 1): dark and still. Seen from BELOW the surface it is a dim teal mirror.
##
## Per vertex: UV.x = depth below the surface in metres, UV.y = kind (0 sea, 1 cave).
## No textures, no screen/depth reads, no loops: cheap. The far-terrain copy also cuts a hole around the player.

const CODE := """
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx;

uniform vec3 hole_center = vec3(0.0);
uniform float hole_radius = 0.0;
uniform float agitation = 0.3;       // 0 glassy calm .. 1 storm
uniform float wave_near = 35.0;      // waves fully resolved inside this distance (m)
uniform float wave_far = 150.0;      // and gone beyond it

varying vec3 wpos;
varying vec2 info;

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
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	info = UV;
}

void fragment() {
	if (hole_radius > 0.0 && distance(wpos, hole_center) < hole_radius) {
		discard;
	}
	float river = step(1.5, info.y);
	float depth = mix(info.x, min(info.x, 2.0), river);   // a river is shallow: its colour never goes deep blue
	float cave = step(0.5, info.y) * (1.0 - river);
	float dist = length(VERTEX);
	vec3 up = normalize(wpos);
	vec3 t1 = normalize(cross(up, vec3(0.0, 1.0, 0.001)));
	vec3 t2 = cross(up, t1);
	vec2 q = vec2(dot(wpos, t1), dot(wpos, t2));
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float under = step(length(cam), length(wpos) - 0.02);        // the camera is below this surface

	// ---- wave detail: only near the camera, calm unless the state says otherwise
	float detail = (1.0 - smoothstep(wave_near, wave_far, dist)) * (1.0 - cave) * (1.0 - 0.7 * river);
	float shore_damp = mix(0.35, 1.0, smoothstep(0.0, 2.5, depth));
	float amp = (0.012 + 0.6 * agitation * agitation) * detail * shore_damp;
	float sp = 0.30 + 0.9 * agitation;
	// four wave trains from long swell to ripples: the short ones only exist with some agitation
	float k3 = 0.30 + agitation;
	vec2 g = vec2(
		cos(q.x * 0.21 + TIME * sp * 0.9) * 0.16 + cos((q.x + q.y) * 0.47 - TIME * sp * 1.3) * 0.14
			+ cos(q.x * 1.10 + q.y * 0.60 + TIME * sp * 1.8) * 0.40 * k3 + cos(q.x * 2.30 - q.y * 1.70 - TIME * sp * 2.6) * 0.32 * agitation,
		cos(q.y * 0.29 - TIME * sp * 0.7) * 0.15 + cos((q.y - q.x) * 0.53 + TIME * sp * 1.1) * 0.13
			+ cos(q.y * 1.00 - q.x * 0.80 - TIME * sp * 1.6) * 0.40 * k3 + cos(q.y * 2.10 + q.x * 1.90 + TIME * sp * 2.3) * 0.32 * agitation);
	vec3 nw = normalize(up - (t1 * g.x + t2 * g.y) * amp);
	vec3 nview = (VIEW_MATRIX * vec4(mix(nw, -nw, under), 0.0)).xyz;
	NORMAL = normalize(nview);
	float cos_t = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);

	// ---- roughness: whatever slope detail was filtered away goes into the roughness
	float sigma = sqrt(0.0004 + 0.011 * agitation);
	float a_far = 1.6 * sigma;
	float a_near = 0.012 + 0.22 * sigma;
	float alpha_r = mix(a_far, a_near, detail);
	alpha_r = mix(alpha_r, 0.02, cave);
	float rough = clamp(sqrt(alpha_r), 0.05, 0.62);

	// ---- body colour by depth, absorption: turquoise -> blue -> almost black
	vec3 c0 = vec3(0.22, 0.72, 0.68);
	vec3 c1 = vec3(0.04, 0.26, 0.42);
	vec3 c2 = vec3(0.012, 0.09, 0.20);
	vec3 col = mix(c0, c1, smoothstep(0.0, 10.0, depth));
	col = mix(col, c2, smoothstep(10.0, 70.0, depth));
	col *= 1.0 - 0.18 * agitation;
	col = mix(col, vec3(0.03, 0.12, 0.17), cave);
	// river: shallow, clear, slightly green-brown (silt); the bed shows through
	col = mix(col, vec3(0.20, 0.42, 0.30), river);

	// ---- transparency (Beer-Lambert along the view path): the bottom shows only in shallow water
	float path = depth / max(cos_t, 0.25);
	float alpha_b = 1.0 - exp(-path * 0.32);
	alpha_b = mix(alpha_b, 0.88, cave);
	alpha_b = mix(alpha_b, 1.0 - exp(-path * 0.55), river);
	float fresnel = 0.02 + 0.98 * pow(1.0 - cos_t, 5.0);

	// ---- shore foam + whitecaps (stronger with the state, fading with distance)
	float width = 0.5 + 1.8 * agitation;
	float shore = (1.0 - smoothstep(0.0, width, depth)) * (1.0 - cave) * (1.0 - river);
	float wave = 0.5 + 0.5 * sin(depth * 5.5 - TIME * (1.2 + 1.6 * agitation) + sin(q.x * 0.9) * 0.8);
	float foam = shore * smoothstep(0.78 - 0.28 * agitation, 0.96, wave) * (1.0 - 0.5 * smoothstep(60.0, 300.0, dist));
	float caps = smoothstep(0.76, 0.95, vnoise(q * 0.35 + TIME * 0.25)) * smoothstep(0.5, 1.0, agitation) * detail * smoothstep(3.0, 12.0, depth);
	foam = clamp(foam + caps * 0.8, 0.0, 1.0);

	vec3 albedo = mix(col, vec3(0.93, 0.97, 1.0), foam * 0.8);
	float alpha = max(alpha_b, fresnel);
	alpha = max(alpha, foam * 0.85);
	// from below: a dim teal mirror (Snell's window effect is left out on purpose)
	albedo = mix(albedo, vec3(0.08, 0.40, 0.50), under);
	alpha = mix(alpha, 0.55, under);

	ALBEDO = albedo;
	ALPHA = clamp(alpha, 0.0, 1.0);
	ROUGHNESS = mix(rough, 0.8, foam);
	SPECULAR = 0.25;
	METALLIC = 0.0;
}
"""

static func create() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = CODE
	var m := ShaderMaterial.new()
	m.shader = sh
	return m
