class_name GroundYield
extends RefCounted
## What the ground is made of at a point: the generator's own layering (top soil, sub soil, rock below) read at the
## depth of the point. Pure query; it changes nothing.

## The BlockTypes id of the ground at world position `p`.
static func block_at(gen: PlanetGenerator, p: Vector3) -> int:
	var col := Column.new()
	var r := p.length()
	gen.sample_column(p / r, col)
	var depth := maxf(0.0, col.height - (r - WorldConfig.PLANET_RADIUS))      # metres below the natural surface
	return gen.surface.block_for(col, depth)
