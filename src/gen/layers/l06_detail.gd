class_name L06Detail
extends GenLayer
## Layer 6: hills (scaled with the planet) and human-scale micro relief (absolute metres).
## Each scale is skipped when the cell size is too coarse to show it (cheap far terrain).

const SC := WorldConfig.WORLD_SCALE

var noises: Array[FastNoiseLite] = []

func _init(p_seed: int = 0) -> void:
	super(p_seed)
	layer_index = 6
	layer_name = "detail"
	for i in 4:
		noises.append(make_noise(i + 1))

func apply(d: Vector3, col: Column, step: int = 1) -> void:
	var k := 1.0 if col.land >= 0.0 else 0.5
	var r := float(WorldConfig.PLANET_RADIUS)
	var h := 0.0
	# hills: original relief detail x world scale (wavelengths ~130 m and ~46 m)
	if step * 2 <= r / 40.0:
		h += fsample(noises[0], d, 40.0) * 1.6 * SC
	if step * 2 <= r / 110.0:
		h += fsample(noises[1], d, 110.0) * 0.6 * SC
	# micro relief at the player's scale (absolute metres)
	if step * 2 <= 45.0:
		h += sample(noises[2], d, 45.0) * 1.5
	if step * 2 <= 9.0:
		h += sample(noises[3], d, 9.0) * 0.5
	col.height += k * h
