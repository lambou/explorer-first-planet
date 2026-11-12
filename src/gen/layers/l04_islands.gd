class_name L04Islands
extends GenLayer
## Layer 4: islands and archipelagos rising out of shallow/mid ocean.

const SC := WorldConfig.WORLD_SCALE

var noise: FastNoiseLite

func _init(p_seed: int = 0) -> void:
	super(p_seed)
	layer_index = 4
	layer_name = "islands"
	noise = make_noise(1, 2)

func apply(d: Vector3, col: Column, _step: int = 1) -> void:
	if col.land >= 0.0:
		return
	var n := fsample(noise, d, 9.0)
	var t := smoothstep(0.35, 0.6, n) * (1.0 - smoothstep(0.25, 0.4, -col.land))
	if t > 0.0:
		col.height = lerpf(col.height, SC * (6.0 + 10.0 * n), t)
