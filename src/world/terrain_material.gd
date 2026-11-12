class_name TerrainMaterial
extends RefCounted
## Vertex colours are the albedo, blended smoothly across each triangle; the vertex alpha is how
## much open sky that point sees (baked at meshing time, dims only the sky/ambient light: sunlight
## comes from real shadow maps). A tiny procedural colour variation (pure maths, no texture
## memory, fades with distance) keeps large areas from looking flat.

const CODE := """
shader_type spatial;
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
	ALBEDO = seabed(variation(COLOR.rgb, wpos, VERTEX), wpos);   // the engine already hands vertex colours over as linear
	ROUGHNESS = 1.0;
	AO = COLOR.a;
	AO_LIGHT_AFFECT = 0.0;
}
"""

static func create() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = CODE
	var m := ShaderMaterial.new()
	m.shader = sh
	return m
