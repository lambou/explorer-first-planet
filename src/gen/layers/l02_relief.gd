class_name L02Relief
extends GenLayer
## Layer 2: base relief. Continental shelf -> slope -> abyssal plain in the sea,
## coastal plain -> plateau on land. Heights are in world-scale metres.

const SC := WorldConfig.WORLD_SCALE

func _init(p_seed: int = 0) -> void:
	super(p_seed)
	layer_index = 2
	layer_name = "relief"

func apply(_d: Vector3, col: Column, _step: int = 1) -> void:
	var l := col.land
	if l >= 0.0:
		col.height = SC * (14.0 * smoothstep(0.0, 0.3, l) + 12.0 * l)
	else:
		var s := -l
		col.height = -SC * (4.0 * smoothstep(0.0, 0.05, s) + 44.0 * smoothstep(0.05, 0.4, s))
