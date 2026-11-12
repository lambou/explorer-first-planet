class_name WorldParams
extends RefCounted
## The seed also picks a few global traits of the world, so different seeds are different
## kinds of planet (more or fewer continents, more or less mountainous) and not only
## shifted copies of the same one.

var continent_freq := 1.3      # number of continents around the planet (higher = more, smaller)
var land_ratio := 0.29         # share of the surface that is land (Earth: ~29%)
var mountain_lo := 0.45        # mountain range mask: lower = more mountains
var mountain_hi := 0.75
var cave_region_lo := 0.40     # cave provinces: lower = caves nearly everywhere
var sink_threshold := 0.62     # sinkholes: lower = more of them

static func for_seed(seed: int) -> WorldParams:
	var p := WorldParams.new()
	p.continent_freq = lerpf(1.0, 1.7, SeedMix.unit(seed, 101))
	p.land_ratio = lerpf(0.26, 0.33, SeedMix.unit(seed, 102))
	p.mountain_lo = lerpf(0.40, 0.52, SeedMix.unit(seed, 103))
	p.mountain_hi = p.mountain_lo + 0.30
	p.cave_region_lo = lerpf(0.34, 0.46, SeedMix.unit(seed, 104))
	p.sink_threshold = lerpf(0.58, 0.68, SeedMix.unit(seed, 105))
	return p
