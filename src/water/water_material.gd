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
uniform float sky_light = 1.0;           // daylight 0..1 (for the view up through the surface)
uniform vec3 ray_up = vec3(0.0, 1.0, 0.0);   // where the sun appears to be seen from under the water (refracted)
uniform vec4 rip[8];                 // ripples made by swimmers and splashes: xyz world position, w strength (WaterRipples)
uniform float rip_age[8];            // seconds since each started

varying vec3 wpos;
varying vec2 info;

uniform float wind = 0.6;            // the wind's direction (radians about the planet's axis): all the wave directions turn with it
uniform float swell_time = 0.0;      // seconds, from the CPU: the swell the swimmer floats on uses the same clock (WaterSystem.swell_at)

// The wave directions are fixed 3D vectors (turned by the wind); on the surface a train is the plane wave of their tangent part. (Keep the numbers
// in sync with WaterMaterial.swell_height, the same swell on the CPU.)
mat3 wind_rot() {
	float cw = cos(wind);
	float sw = sin(wind);
	return mat3(vec3(cw, 0.0, -sw), vec3(0.0, 1.0, 0.0), vec3(sw, 0.0, cw));
}
vec3 tdir(vec3 k, vec3 up) {
	return (k - up * dot(k, up)) / length(k);          // the train's slope direction on the surface (shorter where the train runs up the sky)
}
float swell_h(vec3 p) {
	mat3 wr = wind_rot();
	vec3 k1 = wr * (0.21 * normalize(vec3(0.7, 0.3, 0.65)));
	vec3 k2 = wr * (0.47 * normalize(vec3(-0.5, 0.55, 0.67)));
	float sp = 0.40 + 0.9 * agitation;
	float a = 0.04 + 0.35 * agitation * agitation;
	return a * (sin(dot(p, k1) + swell_time * sp * 0.9) + 0.7 * sin(dot(p, k2) - swell_time * sp * 1.3));
}

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
	// the sea heaves: the vertices ride the swell (not rivers or cave water, and not in the last metres before a shore). The model matrix of a
	// water mesh only translates, so a displacement along the planet's up is the same in model space.
	float sea = 1.0 - step(0.5, UV.y);
	vec3 upv = normalize(wpos);
	float lift = swell_h(wpos) * sea * smoothstep(0.0, 2.0, UV.x);
	VERTEX += upv * lift;
	wpos += upv * lift;
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
	vec2 q = vec2(dot(wpos, vec3(0.6, 0.3, 0.74)), dot(wpos, vec3(-0.5, 0.8, -0.33)));      // two fixed world coordinates: noise and foam bands (not the waves)
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float under = step(length(cam), length(wpos) - 0.02);        // the camera is below this surface

	// ---- wave detail: only near the camera, calm unless the state says otherwise
	float detail = (1.0 - smoothstep(wave_near, wave_far, dist)) * (1.0 - cave) * (1.0 - 0.7 * river);
	float shore_damp = mix(0.35, 1.0, smoothstep(0.0, 2.5, depth));
	float amp = (0.03 + 0.6 * agitation * agitation) * detail * shore_damp;
	float sp = 0.40 + 0.9 * agitation;
	// five wave trains from long swell to ripples, their directions turned by the wind; the short ones only exist with some agitation
	float k3 = 0.30 + agitation;
	mat3 wr = wind_rot();
	vec3 kv1 = wr * (0.21 * normalize(vec3(0.7, 0.3, 0.65)));
	vec3 kv2 = wr * (0.47 * normalize(vec3(-0.5, 0.55, 0.67)));
	vec3 kv3 = wr * (1.2 * normalize(vec3(0.3, -0.6, 0.74)));
	vec3 kv4 = wr * (3.0 * normalize(vec3(-0.8, -0.2, 0.56)));
	vec3 kv5 = wr * (3.4 * normalize(vec3(0.2, 0.9, -0.4)));
	vec3 S = tdir(kv1, up) * cos(dot(wpos, kv1) + swell_time * sp * 0.9) * 0.16
		+ tdir(kv2, up) * cos(dot(wpos, kv2) - swell_time * sp * 1.3) * 0.14
		+ tdir(kv3, up) * cos(dot(wpos, kv3) + TIME * sp * 1.8) * 0.40 * k3
		+ tdir(kv4, up) * cos(dot(wpos, kv4) - TIME * sp * 2.6) * 0.32 * agitation
		+ tdir(kv5, up) * cos(dot(wpos, kv5) + TIME * sp * 2.2) * (0.16 + 0.2 * agitation);
	// ---- ripples from the player: each is an expanding ring (a cosine in the distance behind the front) that fades with age and distance
	vec3 gr = vec3(0.0);
	float rfoam = 0.0;
	for (int i = 0; i < 8; i++) {
		float s = rip[i].w;
		if (s > 0.0) {
			vec3 d3 = wpos - rip[i].xyz;
			float r = length(d3);
			float age = rip_age[i];
			float front = 1.8 * age;
			float behind = smoothstep(front + 0.6, front - 0.4, r);
			float env = exp(-age * 1.4) * exp(-r * 0.30) * behind;
			vec3 dd = (d3 - up * dot(d3, up)) / max(r, 0.05);
			gr += dd * cos((r - front) * 5.0) * env * s;
			rfoam += smoothstep(0.5, 1.2, s) * smoothstep(0.0, 0.15, age) * smoothstep(0.6, 0.0, age) * (1.0 - smoothstep(0.0, 0.45, abs(r - front))) * exp(-r * 0.4);
		}
	}
	float rip_detail = (1.0 - smoothstep(30.0, 90.0, dist)) * (1.0 - cave);
	vec3 nw = normalize(up - S * amp - gr * 0.5 * rip_detail);
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
	foam = clamp(foam + caps * 0.8 + rfoam * 0.8 * rip_detail, 0.0, 1.0);

	vec3 albedo = mix(col, vec3(0.93, 0.97, 1.0), foam * 0.8);
	float alpha = max(alpha_b, fresnel);
	alpha = max(alpha, foam * 0.85);
	// from below: a dim teal mirror (Snell's window effect is left out on purpose)
	albedo = mix(albedo, vec3(0.03, 0.15, 0.22), under);
	alpha = mix(alpha, 0.55, under);
	// Snell's window: seen from below, only a cone of about 97 degrees (49 degrees either side of the vertical) shows the sky, bright; outside it the
	// surface mirrors the dark water. The sun appears as a glare in it, shimmering with the waves.
	vec3 vw = normalize(wpos - cam);
	float upness = dot(vw, up);
	float window = smoothstep(0.60, 0.72, upness) * under;
	vec3 vwr = normalize(vw + (nw - up) * 0.5);
	float sun_up = max(dot(ray_up, up), 0.0);
	float glare = pow(max(dot(vwr, ray_up), 0.0), 90.0) * smoothstep(0.03, 0.3, sun_up) * under;
	vec3 emit = vec3(0.45, 0.85, 1.0) * window * (0.1 + 0.9 * sky_light) * (1.2 + 2.2 * smoothstep(0.35, 0.75, vnoise(q * 0.9 + TIME * 0.2) * 0.6 + vnoise(q * 2.4 - TIME * 0.35) * 0.4)) + vec3(1.0, 0.97, 0.85) * glare * 6.0 * sky_light;
	alpha = max(alpha, window * 0.85);

	ALBEDO = albedo;
	EMISSION = emit;
	ALPHA = clamp(alpha, 0.0, 1.0);
	ROUGHNESS = mix(rough, 0.8, foam);
	SPECULAR = 0.25;
	METALLIC = 0.0;
}
"""

## The height (metres) the sea heaves by at world position `p`: the same two swell trains as swell_h() in the shader (keep the numbers in sync), so the
## swimmer and the camera ride the surface that is drawn. `t` = the swell clock (WaterSystem sends the same value to the shader), `wind` = radians.
static func swell_height(p: Vector3, t: float, agitation: float, wind: float) -> float:
	var rot := Basis(Vector3.UP, wind)                # the same turn about +Y as the shader's wind_rot()
	var k1: Vector3 = rot * (Vector3(0.7, 0.3, 0.65).normalized() * 0.21)
	var k2: Vector3 = rot * (Vector3(-0.5, 0.55, 0.67).normalized() * 0.47)
	var sp := 0.40 + 0.9 * agitation
	var a := 0.04 + 0.35 * agitation * agitation
	return a * (sin(p.dot(k1) + t * sp * 0.9) + 0.7 * sin(p.dot(k2) - t * sp * 1.3))

static func create() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = CODE
	var m := ShaderMaterial.new()
	m.shader = sh
	return m
