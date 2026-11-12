class_name WaterState
extends RefCounted
## How agitated the water is at a place and moment: 0 = glassy calm (a mirror of the sky),
## 1 = storm. It is a slow noise over the planet (calm regions and rough regions) that also drifts in
## time, so the sea changes character as you travel or wait. Pure function of seed, place and time.
## Used by WaterSystem to drive the surface shader; later weather can feed into it (W15).

const NAMES := ["calm", "light ripples", "choppy", "rough", "storm"]

var _noise: FastNoiseLite

func _init(p_seed: int = 0) -> void:
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = SeedMix.derive(p_seed, 77, 1)
	_noise.frequency = 1.0
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 2

## 0..1 at world position `p` and game time `t` (seconds).
func agitation_at(p: Vector3, t: float) -> float:
	var r := p.length()
	if r < 1.0:
		return 0.0
	var d := p / r
	# place: regions about 2-3 km wide; time: a full change takes about 20 minutes
	var n := _noise.get_noise_3d(d.x * 2.2 + t * 0.0007, d.y * 2.2, d.z * 2.2 + t * 0.0005) * 0.5 + 0.5
	return clampf(smoothstep(0.28, 0.78, n), 0.0, 1.0)

static func name_of(agitation: float) -> String:
	return NAMES[clampi(int(agitation * NAMES.size()), 0, NAMES.size() - 1)]
