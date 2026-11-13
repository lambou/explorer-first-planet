class_name GrassType
extends RefCounted
## One kind of grass: pure data. The catalog makes them, the field decides where they grow, the placer plants them,
## the shader makes them move. Heights are in metres; the clump mesh is built for the middle height and scaled.

var id := 0
var key := ""
var name := ""
var height_min := 0.3
var height_max := 0.5
var blades := 8                    # blades per clump
var clump_radius := 0.14           # metres
var blade_width := 0.022           # metres at the root
var density := 0.9                 # share of the planting cells that get a clump (before the ground and slope rules)
var base_color := Color(0.25, 0.5, 0.15)   # root colour, mixed with the ground colour
var tip_color := Color(0.62, 0.82, 0.30)   # tip colour
var sway := 1.0                    # how much the wind moves it (tall grass moves more)
var underwater := false            # sea grass: grows under water, moves with the current
var flower := false                # a flower: thin stems with a coloured head (tip_color is the petal colour)
var mesh_name := ""                # optional authored mesh ("res://assets/grass/<name>.res"): replaces the procedural clump

func height_mid() -> float:
	return (height_min + height_max) * 0.5
