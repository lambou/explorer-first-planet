class_name L03Mountains
extends GenLayer
## Layer 3: mountain ranges (ridged noise), only inland, placed by a range mask.

const SC := WorldConfig.WORLD_SCALE

var mask_noise: FastNoiseLite
var ridge_noise: FastNoiseLite

func _init(p_seed: int = 0) -> void:
	super(p_seed)
	layer_index = 3
	layer_name = "mountains"
	mask_noise = make_noise(1, 3)
	ridge_noise = make_noise(2, 3)

func apply(d: Vector3, col: Column, _step: int = 1) -> void:
	var m := fsample(mask_noise, d, 2.5) * 0.5 + 0.5
	m = smoothstep(params.mountain_lo, params.mountain_hi, m) * smoothstep(0.05, 0.2, col.land)
	col.mountain = m
	if m <= 0.0:
		return
	var r := 1.0 - absf(fsample(ridge_noise, d, 7.0))
	col.height += m * r * r * 46.0 * SC
