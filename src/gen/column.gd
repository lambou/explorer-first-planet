class_name Column
extends RefCounted
## Result of running the macro layers for one direction on the sphere.
## Each layer reads what earlier layers wrote -> controlled, coherent generation.

var continent := 0.0     # L1 raw continental noise
var land := 0.0          # L1 continent - sea threshold (>0 land)
var height := 0.0        # L2.. terrain height relative to sea level (metres)
var mountain := 0.0      # L3 mountain mask 0..1
var latitude := 0.0      # L7 -1 (south) .. +1 (north)
var temperature := 0.5   # L7 0 (freezing) .. 1 (hot)
var moisture := 0.5      # L7 0 (dry) .. 1 (wet)
var material := 0        # material of the last sampled point (BlockTypes id)
var color := Color.WHITE   # ground colour of the last sampled point (smooth, see L09Surface)
var river := 0.0             # L10 0..1 inside a river channel
var river_level := -1.0e9    # L10 water surface of the river (m above sea level), -1e9 = none
