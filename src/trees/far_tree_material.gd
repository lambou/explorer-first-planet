class_name FarTreeMaterial
extends RefCounted
## The far-tree card shader (see FarTrees). Everything is drawn from the card's UV, no texture:
##  - BILLBOARD: the quad turns around the planet's "up" at its foot so it always faces the camera and stays upright.
##  - SILHOUETTE: the canopy family (custom data alpha) decides the cutout: a round crown on a trunk, a flat umbrella, a pale slim crown, a
##    stepped cone (pine), a ragged narrow cone (fir) or a palm's flat crown on a thin trunk. Outside the shape the pixel is discarded.
##  - COLOUR: the crown colour of the species, darker towards the bottom and the edges, a brown trunk; lit by hand with the game's sun and
##    ambient like the near trees, so day, dusk, night and the underwater dimming apply.
##  - HAND-OVER: cards within ~50 m of the player fade out in a dither (the real trees are there); cards fade in at the far end.
## Shared uniforms: grass_sun / grass_sun_col (GrassMaterial), tree_target = the player (TreeMaterial).

const CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled;

global uniform vec4 grass_sun;
global uniform vec4 grass_sun_col;
global uniform vec4 tree_target;

uniform float near_start = 44.0;
uniform float near_end = 58.0;
uniform float far_start = 380.0;
uniform float far_end = 440.0;

varying vec3 v_leaf;
varying float v_sil;
varying float v_dist;
varying vec2 v_uv;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float w = length(MODEL_MATRIX[0].xyz);
	float h = length(MODEL_MATRIX[1].xyz);
	vec3 up = normalize(origin);
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = cam - origin;
	vec3 right = cross(up, to_cam);
	right = length(right) < 0.0001 ? cross(up, vec3(0.0, 0.0, 1.0)) : normalize(right);
	vec3 wpos = origin + right * VERTEX.x * w + up * VERTEX.y * h;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wpos, 1.0);
	v_leaf = INSTANCE_CUSTOM.rgb;
	v_sil = INSTANCE_CUSTOM.a * 8.0;
	v_dist = length(origin - tree_target.xyz);
	v_uv = UV;
}

float dither(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// the shape of each canopy family: returns 1 inside the tree, 0 outside; 'trunk' is set when the pixel is the trunk
float shape(vec2 uv, float sil, out float trunk) {
	trunk = 0.0;
	float x = uv.x - 0.5;
	float y = uv.y;
	float s = floor(sil);
	// trunk (all but the cones): a slim rectangle up to the crown
	float tw = 0.045;
	float crown_c = 0.66;
	vec2 crown_r = vec2(0.42, 0.30);
	float in_crown = 0.0;
	if (s < 0.5) {            // broadleaf: a round crown with a bumpy outline
		crown_r = vec2(0.44, 0.32);
		float bump = 1.0 + 0.10 * sin(atan(y - crown_c, x) * 5.0);
		in_crown = 1.0 - step(1.0, length(vec2(x / crown_r.x, (y - crown_c) / crown_r.y)) / bump);
	} else if (s < 1.5) {     // round: one fat ball
		crown_c = 0.58;
		crown_r = vec2(0.48, 0.40);
		in_crown = 1.0 - step(1.0, length(vec2(x / crown_r.x, (y - crown_c) / crown_r.y)));
	} else if (s < 2.5) {     // birch: a narrower, taller crown, pale trunk
		crown_c = 0.66;
		crown_r = vec2(0.30, 0.34);
		in_crown = 1.0 - step(1.0, length(vec2(x / crown_r.x, (y - crown_c) / crown_r.y)));
		tw = 0.03;
	} else if (s < 3.5) {     // acacia: a flat umbrella
		crown_c = 0.74;
		crown_r = vec2(0.50, 0.14);
		in_crown = 1.0 - step(1.0, length(vec2(x / crown_r.x, (y - crown_c) / crown_r.y)));
		tw = 0.05;
	} else if (s < 5.5) {     // pine / fir: stepped cones
		float narrow = s < 4.5 ? 1.0 : 0.82;
		float yy = (y - 0.08) / 0.92;
		float steps = s < 4.5 ? 5.0 : 8.0;
		float w = 0.46 * narrow * (1.0 - yy) * (0.74 + 0.26 * fract(yy * steps));
		float inside = step(0.0, yy) * (1.0 - step(w, abs(x)));
		float rag = s < 4.5 ? 0.0 : 0.04 * sin(y * 90.0);
		inside = step(0.0, yy) * (1.0 - step(w + rag, abs(x)));
		// a short bare trunk at the foot
		float tr = (1.0 - step(0.035, abs(x))) * (1.0 - step(0.1, y));
		trunk = tr * (1.0 - inside);
		return max(inside, tr);
	} else {                  // palm: a thin trunk and a flat spiky crown
		crown_c = 0.84;
		crown_r = vec2(0.50, 0.10);
		float spikes = 1.0 + 0.35 * sin(atan(y - crown_c, x) * 7.0);
		in_crown = 1.0 - step(1.0, length(vec2(x / crown_r.x, (y - crown_c) / crown_r.y)) / spikes);
		tw = 0.025;
	}
	float tr2 = (1.0 - step(tw, abs(x))) * (1.0 - step(crown_c, y));
	trunk = tr2 * (1.0 - in_crown);
	return max(in_crown, tr2);
}

void fragment() {
	// hand-over to the real trees near the player, and a soft start at the far end
	float a = smoothstep(near_start, near_end, v_dist) * (1.0 - smoothstep(far_start, far_end, v_dist));
	if (a < dither(FRAGCOORD.xy)) {
		discard;
	}
	float trunk;
	float inside = shape(v_uv, v_sil, trunk);
	if (inside < 0.5) {
		discard;
	}
	vec3 col = v_leaf;
	float y = v_uv.y;
	col *= mix(0.62, 1.12, smoothstep(0.1, 0.95, y));        // darker below, lighter on top
	if (trunk > 0.5) {
		col = v_sil > 1.5 && v_sil < 2.5 ? vec3(0.78, 0.76, 0.70) : vec3(0.36, 0.26, 0.18);
	}
	float light = grass_sun.w + grass_sun_col.g * 0.85;
	ALBEDO = col * light * 1.3;
}
"""

static func create() -> ShaderMaterial:
	TreeMaterial.declare_globals()
	var sh := Shader.new()
	sh.code = CODE
	var m := ShaderMaterial.new()
	m.shader = sh
	return m
