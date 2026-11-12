class_name L01Continents
extends GenLayer
## Layer 1: continents vs oceans. The sea threshold is calibrated from the seed so that
## exactly LAND_RATIO of the surface is land (Earth-like ratio).

var noise: FastNoiseLite
var threshold := 0.0

func _init(p_seed: int = 0) -> void:
	super(p_seed)
	layer_index = 1
	layer_name = "continents"
	noise = make_noise(1, 4)
	_calibrate()

func _raw(d: Vector3) -> float:
	return fsample(noise, d, params.continent_freq)

func _calibrate() -> void:
	var n := 6000
	var vals := PackedFloat32Array()
	vals.resize(n)
	for i in n:
		vals[i] = _raw(PlanetGenerator.fibonacci_dir(i, n))
	vals.sort()
	threshold = vals[int(n * (1.0 - params.land_ratio))]

func apply(d: Vector3, col: Column, _step: int = 1) -> void:
	col.continent = _raw(d)
	col.land = col.continent - threshold
