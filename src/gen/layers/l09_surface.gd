class_name L09Surface
extends GenLayer
## Layer 9 (voxel stage): which block sits at a given depth below the surface,
## chosen from the climate/height written by earlier layers.

const SNOW_LINE := 60.0 * WorldConfig.WORLD_SCALE

func _init(p_seed: int = 0) -> void:
	super(p_seed)
	layer_index = 9
	layer_name = "surface"

func block_for(col: Column, depth: float) -> int:
	var h := col.height
	var top: int
	if h < -1.0:
		top = BlockTypes.SAND if h > -40.0 else BlockTypes.GRAVEL
	elif h < 3.0:
		top = BlockTypes.SAND
	elif h > SNOW_LINE or col.temperature < 0.2:
		top = BlockTypes.SNOW
	elif col.moisture < 0.32 and col.temperature > 0.55:
		top = BlockTypes.SAND
	else:
		top = BlockTypes.GRASS
	if depth < 1.0:
		return top
	if depth < 4.0:
		match top:
			BlockTypes.SAND: return BlockTypes.SAND
			BlockTypes.GRAVEL: return BlockTypes.GRAVEL
			BlockTypes.SNOW: return BlockTypes.STONE if h > SNOW_LINE else BlockTypes.DIRT
			_: return BlockTypes.DIRT
	return BlockTypes.STONE

## Smooth ground colour from the continuous climate/height values (no hard biome edges).
## Used for the far terrain; chunks blend their per-sample materials across triangles.
func color_for(col: Column) -> Color:
	var h := col.height
	var sand: Color = BlockTypes.COLORS[BlockTypes.SAND]
	var grass: Color = BlockTypes.COLORS[BlockTypes.GRASS]
	var dirt: Color = BlockTypes.COLORS[BlockTypes.DIRT]
	var stone: Color = BlockTypes.COLORS[BlockTypes.STONE]
	var gravel: Color = BlockTypes.COLORS[BlockTypes.GRAVEL]
	var snow: Color = BlockTypes.COLORS[BlockTypes.SNOW]
	if h < 0.0:
		# sea floor: sand near the coast, gravel in the deep
		return sand.lerp(gravel, smoothstep(20.0, 160.0, -h))
	var c := grass.lerp(dirt, 0.25 * (1.0 - smoothstep(0.3, 0.7, col.moisture)))
	# dry + hot = desert
	var desert := (1.0 - smoothstep(0.22, 0.42, col.moisture)) * smoothstep(0.45, 0.65, col.temperature)
	c = c.lerp(sand, desert)
	# beach
	c = c.lerp(sand, 1.0 - smoothstep(1.0, 9.0, h))
	# bare rock then snow with altitude, snow also in the cold
	c = c.lerp(stone, smoothstep(SNOW_LINE * 0.45, SNOW_LINE * 0.85, h))
	var snowy := maxf(smoothstep(SNOW_LINE * 0.75, SNOW_LINE * 1.05, h), 1.0 - smoothstep(0.12, 0.26, col.temperature))
	return c.lerp(snow, snowy)

## Colour at a given depth below the surface: the smooth ground colour on top, blending
## into dirt/stone below (so a dug wall reveals the layers), never a hard per-sample switch.
func color_at_depth(col: Column, depth: float) -> Color:
	var top := color_for(col)
	if depth >= 4.0:
		return BlockTypes.COLORS[BlockTypes.STONE]
	var sub: Color = BlockTypes.COLORS[block_for(col, 2.0)]
	if depth >= 2.0:
		return sub.lerp(BlockTypes.COLORS[BlockTypes.STONE], smoothstep(2.0, 4.0, depth))
	return top.lerp(sub, smoothstep(0.8, 2.0, depth))
