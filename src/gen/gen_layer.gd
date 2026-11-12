class_name GenLayer
extends RefCounted
## Base class of a generation layer. Layers run macro -> micro.
## Macro layers use a frequency on the unit sphere (so they scale with the planet) and
## heights multiplied by WORLD_SCALE; micro layers use absolute metres (human scale).
## `step` = metres per cell of the node being generated: a layer whose features are
## smaller than 2 cells is skipped (it cannot be seen anyway).

var layer_index := 0
var layer_name := "layer"
var world_seed := 0
var params: WorldParams

func _init(p_seed: int = 0) -> void:
	world_seed = p_seed
	params = WorldParams.for_seed(p_seed)

func make_noise(salt: int, octaves: int = 1) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = SeedMix.derive(world_seed, layer_index, salt)
	n.frequency = 1.0
	if octaves > 1:
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = octaves
	else:
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
	return n

## Noise sample for a feature that scales with the planet: `freq` waves around the unit sphere.
static func fsample(n: FastNoiseLite, d: Vector3, freq: float) -> float:
	return n.get_noise_3d(d.x * freq, d.y * freq, d.z * freq)

## Noise sample of direction d (unit vector) for a feature of an absolute wavelength in metres.
static func sample(n: FastNoiseLite, d: Vector3, wavelength: float) -> float:
	var q := d * (WorldConfig.PLANET_RADIUS / wavelength)
	return n.get_noise_3d(q.x, q.y, q.z)

## d is a unit direction from the planet centre.
func apply(_d: Vector3, _col: Column, _step: int = 1) -> void:
	pass
