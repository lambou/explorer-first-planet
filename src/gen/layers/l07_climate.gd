class_name L07Climate
extends GenLayer
## Layer 7: temperature from latitude (cold poles, hot equator) and altitude, plus moisture.
## Pole axis = +Y. Used by the surface layer now; by biomes/water/vegetation later.

var temp_noise: FastNoiseLite
var moist_noise: FastNoiseLite

func _init(p_seed: int = 0) -> void:
	super(p_seed)
	layer_index = 7
	layer_name = "climate"
	temp_noise = make_noise(1, 2)
	moist_noise = make_noise(2, 3)

func apply(d: Vector3, col: Column, _step: int = 1) -> void:
	col.latitude = asin(clampf(d.y, -1.0, 1.0)) / (PI * 0.5)
	var t := 1.0 - pow(absf(col.latitude), 1.4)
	t -= maxf(col.height, 0.0) * 0.006 / WorldConfig.WORLD_SCALE
	t += fsample(temp_noise, d, 3.0) * 0.08
	col.temperature = clampf(t, 0.0, 1.0)
	col.moisture = clampf(fsample(moist_noise, d, 3.5) * 0.5 + 0.5, 0.0, 1.0)
