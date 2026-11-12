class_name L05Canyons
extends GenLayer
## Layer 5: canyons / rift valleys carved into inland terrain along noise zero-lines.

const SC := WorldConfig.WORLD_SCALE
## deepest cut, used by the node classifier as a safety margin
const CUT := 6.0 * SC

var noise: FastNoiseLite

func _init(p_seed: int = 0) -> void:
	super(p_seed)
	layer_index = 5
	layer_name = "canyons"
	noise = make_noise(1, 2)

func apply(d: Vector3, col: Column, step: int = 1) -> void:
	if col.land < 0.1 or step >= 16:
		return
	var c := absf(fsample(noise, d, 5.5))
	var cut := (1.0 - smoothstep(0.0, 0.05, c)) * smoothstep(0.1, 0.3, col.land)
	if cut > 0.0:
		col.height = maxf(col.height - CUT * cut, -6.0 * SC)
