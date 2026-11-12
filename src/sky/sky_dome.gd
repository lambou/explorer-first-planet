class_name SkyDome
extends RefCounted
## The sky: atmosphere, sun glow, stars and clouds, all drawn by one cheap sky shader (no textures).
## It is a SPHERE-planet sky: "up" is the planet's radial direction at the camera, passed in every frame.
##  - ATMOSPHERE: blue zenith to pale horizon (Rayleigh-like gradient). At dusk/dawn the horizon towards the
##    sun turns orange, the zenith purple; at night everything goes deep blue-black.
##  - SUN: a soft glow around the sun (the hard disc is a separate mesh in main.gd).
##  - STARS: only when the sun is well below the horizon.
##  - CLOUDS: noise projected on a flat layer above the viewer (perspective compresses them towards the
##    horizon), slowly drifting, lit from the sun side (thicker parts toward the sun are darker),
##    warm at sunset, fading into the haze at the horizon.
## Display only: it never touches the world. The ambient light the world receives comes from this sky too.

const CODE := """
shader_type sky;

uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);   // unit vector towards the sun
uniform vec3 up_dir = vec3(0.0, 1.0, 0.0);    // planet radial direction at the viewer
uniform float cover = 0.55;                   // 0 clear .. 1 overcast
uniform float horizon = 0.0;                  // sine of the elevation of the TRUE horizon (negative when high up)

// hash without sin(): sin of large numbers is imprecise on some GPUs and shows up as hard-edged blocks
float h21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec2(17.3, 9.1);
		a *= 0.5;
	}
	return s;
}

void sky() {
	vec3 e = normalize(EYEDIR);
	float h_raw = dot(e, up_dir);                   // elevation of this direction above eye level (sine)
	float h = (h_raw - horizon) / (1.0 - horizon);  // ... above the TRUE horizon: the sphere's edge dips below eye level with altitude
	float sh = dot(sun_dir, up_dir) - horizon;      // sun elevation above the true horizon
	float sd = max(dot(e, sun_dir), 0.0);
	float dayf = smoothstep(-0.15, 0.3, sh);
	float tw = exp(-pow(sh / 0.28, 2.0));           // twilight strength: 1 with the sun on the horizon

	vec3 zen = mix(vec3(0.006, 0.010, 0.032), vec3(0.14, 0.36, 0.80), dayf);
	vec3 hor = mix(vec3(0.020, 0.030, 0.070), vec3(0.64, 0.77, 0.92), dayf);
	vec3 warm = vec3(1.0, 0.46, 0.20);
	hor = mix(hor, warm, tw * (0.2 + 0.7 * pow(sd, 3.0)));
	zen = mix(zen, vec3(0.22, 0.18, 0.42), tw * 0.3);
	vec3 col = mix(hor, zen, pow(clamp(h, 0.0, 1.0), 0.45));

	// sun glow (forward scattering)
	float glow = pow(sd, 90.0) * 0.8 + pow(sd, 8.0) * 0.16;
	col += mix(vec3(1.0, 0.9, 0.7), warm, tw) * glow * smoothstep(-0.25, 0.05, sh);

	// stars, only at night
	if (h > 0.0) {
		vec3 sp = e * 260.0;
		float st = h21(floor(sp.xy) + floor(sp.z) * 7.0);
		float star = step(0.9965, st) * (1.0 - smoothstep(0.05, 0.4, dayf)) * smoothstep(0.0, 0.2, h);
		col += vec3(0.8, 0.85, 1.0) * star * 0.9;
	}

	// below the horizon: the haze darkens (the ground hides it anyway)
	col = mix(col, hor * 0.45, smoothstep(0.0, -0.3, h));

	// clouds on a flat layer above the viewer
	if (h > 0.0) {
		vec3 a = abs(up_dir.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 t1 = normalize(cross(up_dir, a));
		vec3 t2 = cross(up_dir, t1);
		vec2 uv = vec2(dot(e, t1), dot(e, t2)) / (max(h_raw, 0.0) + 0.25) * 0.85 + vec2(TIME * 0.006, TIME * 0.0022);
		float n = fbm(uv * 1.3);
		float dens = smoothstep(1.0 - cover, 1.0 - cover + 0.22, n);
		dens *= smoothstep(0.02, 0.22, h_raw);         // the cloud layer lies above the viewer: none below eye level, melting into the haze towards it
		vec2 sun_uv = vec2(dot(sun_dir, t1), dot(sun_dir, t2));
		float n2 = fbm((uv + sun_uv * 0.05) * 1.3);  // thickness towards the sun
		float lit = clamp(0.55 + (n - n2) * 3.0, 0.0, 1.0);
		vec3 ccol = mix(vec3(0.50, 0.56, 0.68), vec3(1.0, 0.99, 0.96), lit) * (0.10 + 0.90 * dayf);
		ccol = mix(ccol, warm * (0.55 + 0.6 * lit), tw * 0.55 * (0.35 + 0.65 * pow(sd, 2.0)));
		col = mix(col, ccol, dens * 0.93);
	}
	COLOR = col;
}
"""

static func create() -> Sky:
	var sh := Shader.new()
	sh.code = CODE
	var m := ShaderMaterial.new()
	m.shader = sh
	var sky := Sky.new()
	sky.sky_material = m
	# the sky changes every frame (sun, up, clouds): re-render it. The background is drawn from this cube map in the
	# compatibility renderer, so it needs a real resolution (32 looked blocky)
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	return sky

## The spin angle of the sun (the `sun_angle` of main.gd: the sun direction is (cos d cos a, sin d, cos d sin a)) that puts
## it at elevation sine `elevation` (0.18 = about 10 degrees) as seen from a place with local up `up`, on a day when the
## sun's declination is `declination` (radians). `rising`: the sun is on its way up (morning), not down (evening).
## Returns the angle in radians. If the sun never gets that high there (polar night) it takes the highest it reaches.
static func sun_angle_for_elevation(up: Vector3, declination: float, elevation: float, rising: bool = true) -> float:
	var rho := Vector2(up.x, up.z).length()
	var phi := atan2(up.z, up.x)
	if rho < 0.0001:
		return 0.0
	# elevation(a) = cos(decl) * rho * cos(a - phi) + sin(decl) * up.y
	var c := (elevation - sin(declination) * up.y) / (cos(declination) * rho)
	var off := acos(clampf(c, -1.0, 1.0))
	return phi - off if rising else phi + off

## Sine of the elevation of the geometric horizon seen from distance `radius` from the planet's centre: the
## sea's edge lies BELOW eye level by acos(R / r) when you are above sea level (13.6 deg at +147 m here).
static func horizon_sine(radius: float) -> float:
	var R := float(WorldConfig.PLANET_RADIUS)
	if radius <= R:
		return 0.0
	return -sqrt(maxf(0.0, 1.0 - (R / radius) * (R / radius)))

## The haze colour at the horizon (what far terrain and the fog should fade into), same maths as the shader
## but averaged over directions: blue by day, warm at dusk, dark at night.
static func horizon_color(sun_dir: Vector3, up: Vector3, radius: float = 0.0) -> Color:
	var sh := sun_dir.dot(up) - horizon_sine(radius)
	var dayf := smoothstep(-0.15, 0.3, sh)
	var tw := exp(-pow(sh / 0.28, 2.0))
	var c := Color(0.020, 0.030, 0.070).lerp(Color(0.64, 0.77, 0.92), dayf)
	return c.lerp(Color(1.0, 0.46, 0.20), tw * 0.4)

## Call every frame. `sun_dir`: unit vector towards the sun, `up`: planet radial direction at the camera,
## `radius`: distance of the camera from the planet's centre (sets where the true horizon is).
static func update(sky: Sky, sun_dir: Vector3, up: Vector3, cover: float = 0.55, radius: float = 0.0) -> void:
	var m := sky.sky_material as ShaderMaterial
	m.set_shader_parameter("horizon", horizon_sine(radius))
	m.set_shader_parameter("sun_dir", sun_dir)
	m.set_shader_parameter("up_dir", up)
	m.set_shader_parameter("cover", cover)
