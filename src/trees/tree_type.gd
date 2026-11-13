class_name TreeType
extends RefCounted
## One species of tree: pure data. The catalog makes them, the field decides where they stand, the mesher draws them by FAMILY (the
## canopy shape), the system cuts them. A thousand species would be a thousand rows: the shapes are shared by the families.

const BROADLEAF := "broadleaf"      # thick trunk, big rounded canopy of leaf clusters
const ROUND := "round"              # one dense round crown
const BIRCH := "birch"              # slim pale trunk, light small clusters
const PINE := "pine"                # stacked cones
const FIR := "fir"                  # many thin feathery tiers
const PALM := "palm"                # curved trunk, a crown of drooping fronds
const ACACIA := "acacia"            # flat umbrella crown on a forked trunk

var id := 0
var key := ""
var name := ""
var family := BROADLEAF
var h_min := 9.0                    # metres
var h_max := 15.0
var trunk_ratio := 0.030            # trunk radius / height
var canopy_ratio := 0.30            # crown radius / height
var temp_lo := 0.3                  # where it lives (climate layer values 0..1)
var temp_hi := 0.8
var moist_lo := 0.35
var moist_hi := 1.0
var coast := false                  # likes sand / the shore (palms)
var bark := Color(0.40, 0.29, 0.20)
var leaf_a := Color(0.28, 0.55, 0.20)   # crown colour (shaded side)
var leaf_b := Color(0.55, 0.78, 0.30)   # crown colour (lit side)
var wood := "Oak wood"
var hardness := 1.5                 # blows to fell a 1 m thick trunk (before the size rule)
var sway := 1.0
var rarity := 1.0                   # share of the forest it takes where it can live (1 = normal)
var center := 0.5                   # its place on the province axis (a seeded noise decides which species a region prefers)

func h_mid() -> float:
	return (h_min + h_max) * 0.5

## 0..1: how well the climate and place suit the species (smooth: no hard biome edges).
func niche(temp: float, moist: float, alt: float, ground_sand: bool) -> float:
	var t := smoothstep(temp_lo - 0.08, temp_lo + 0.08, temp) * (1.0 - smoothstep(temp_hi - 0.08, temp_hi + 0.08, temp))
	var m := smoothstep(moist_lo - 0.08, moist_lo + 0.08, moist) * (1.0 - smoothstep(moist_hi - 0.08, moist_hi + 0.08, moist))
	var s := t * m
	if coast:
		s *= (1.0 - smoothstep(10.0, 40.0, alt)) * (1.0 if ground_sand else 0.35)
	return s
