class_name UnderwaterEffect
extends RefCounted
## What the camera sees and what lights the scene when it is under the surface. Cheap tricks only:
##  - VISIBILITY PERIMETER: exponential fog in the colour of the water. Past ~25 m everything dissolves
##    into uniform haze, so the sea bed or a far wall can never be seen from a distance.
##  - LIGHT DIES WITH DEPTH: the sun and sky light are scaled by exp(-depth / 70) and tinted blue-green
##    (red is absorbed first). Below about 200 m it is nearly dark.
##  - WATER COLOUR: the haze goes from teal near the surface to deep blue to black.
## Display only; call once per frame after the normal day/night light values are set.

const VISIBILITY := 24.0           # metres of clear view in bright shallow water
const LIGHT_DEPTH := 70.0          # e-folding depth of the light
const SHALLOW := Color(0.07, 0.38, 0.45)
const DEEP := Color(0.01, 0.07, 0.17)

const BLEND := 0.12                # metres around the surface over which the look changes (no snap, no dead zone)

## depth = metres the CAMERA is below the surface (negative = above). Returns false (touching nothing) when the
## camera is clearly above the surface. Within +-BLEND of the surface the underwater look is blended in
## continuously, so a camera bobbing at the surface never flips the whole picture on and off.
static func apply(env: Environment, sun: DirectionalLight3D, depth: float, daylight: float) -> bool:
	var f := smoothstep(-BLEND, BLEND, depth)
	if f <= 0.0:
		return false
	var d := maxf(depth, 0.0)
	var light := exp(-d / LIGHT_DEPTH)
	var tint := Color(0.35, 0.85, 1.0).lerp(Color(0.1, 0.4, 0.9), 1.0 - light)   # red gone first, then green
	# the water gets a bit more turbid with depth: the view shortens from 24 m to about 14 m
	var vis := lerpf(VISIBILITY, 14.0, 1.0 - light)
	var water_col := SHALLOW.lerp(DEEP, 1.0 - light) * (0.06 + 0.94 * light) * maxf(daylight, 0.1)
	var air_fog_density := env.fog_density
	var air_fog_color := env.fog_light_color
	var air_ambient := env.ambient_light_energy
	var air_sun := sun.light_energy
	env.fog_enabled = true
	env.fog_density = lerpf(air_fog_density, 3.6 / vis, f)   # ~97% hidden at `vis` metres underwater: things dissolve into the water colour
	env.fog_sky_affect = 1.0
	env.fog_aerial_perspective = lerpf(0.4, 0.0, f)
	# nothing of the outside world exists under water: the sky is fully covered by the fog (sky_affect 1) in the
	# water colour. The background MODE is never switched (that forced a sky rebuild = a blink on crossing).
	env.background_color = water_col
	env.fog_light_color = air_fog_color.lerp(water_col, f)
	env.ambient_light_energy = lerpf(air_ambient, air_ambient * light * 0.9, f)
	sun.light_energy = lerpf(air_sun, air_sun * light * light, f)
	sun.light_color = Color.WHITE.lerp(tint, 0.85 * f)
	return true

## Restores what apply() changes beyond the values the caller sets every frame.
static func reset(sun: DirectionalLight3D, env: Environment = null) -> void:
	sun.light_color = Color.WHITE
	if env != null:
		env.fog_aerial_perspective = 0.4
