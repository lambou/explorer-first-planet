class_name L10Rivers
extends GenLayer
## Layer 10: rivers, a layer ON TOP of the finished ground. The seed only decides WHERE a river runs (the zero-line
## of a noise field); the water itself obeys the ground:
##   - the water level is the height of the LOWEST bank around the point (ground sampled in a ring just outside the
##     channel) minus a small freeboard, so the water is always held by a bank on every side;
##   - the channel is then cut into the ground down to that level minus the depth;
##   - where holding the water would need a deep gorge (the lowest bank is far below the ground at the
##     centre line) the river simply does not exist: no water on slopes, no hanging sheets.
## Because every point takes its level from its own surroundings, the level follows the terrain down a valley:
## in a basin it forms a calm reach, and where the ground falls away the level steps down (a future waterfall
## or a tiny stream, see docs/WATER_PLAN.md). It runs after the detail layer. Writes col.river (0..1 inside the
## channel) and col.river_level (water surface, metres above sea level).

const WAVELENGTH_FREQ := 11.0       # waves around the unit sphere (river spacing ~3 km)
const HALF_WIDTH := 0.022           # noise units: about 6-7 m each side of the centre line
const DEPTH := 1.3                  # metres of water in the middle
const NO_WATER := -1.0e9
const MAX_ALT_MIN := 35.0          # rivers live on low ground: they thin out from this altitude (m above sea) ...
const MAX_ALT_MAX := 65.0          # ... and are gone above this one (no water on grassy hillsides)
const RING := 14.0                  # metres: the ring of banks sampled around a point (outside the channel)
const FREEBOARD := 0.4              # the lowest bank stands this far above the water
const CUT_MIN := 3.0                # the channel may be cut this deep into the centre ground ...
const CUT_MAX := 8.0                # ... and the river is gone when holding the water needs this much

var noise: FastNoiseLite
var ground_layers: Array[GenLayer] = []    # layers 1-6, used to look at the ground around the channel

func _init(p_seed: int = 0, p_ground: Array[GenLayer] = []) -> void:
	super(p_seed)
	ground_layers = p_ground
	layer_index = 10
	layer_name = "rivers"
	noise = make_noise(1, 2)

func apply(d: Vector3, col: Column, step: int = 1) -> void:
	col.river = 0.0
	col.river_level = NO_WATER
	if col.land < 0.04 or step > 8 or ground_layers.is_empty():
		return
	var c := absf(fsample(noise, d, WAVELENGTH_FREQ))
	var r := 1.0 - smoothstep(0.0, HALF_WIDTH, c)
	r *= 1.0 - smoothstep(MAX_ALT_MIN, MAX_ALT_MAX, col.height)
	if r <= 0.0:
		return
	# the lowest bank around this point
	var t1 := d.cross(Vector3.UP).normalized()
	var t2 := d.cross(t1)
	var lowest := col.height
	var tmp := Column.new()
	for k in 8:
		var a := k * (TAU / 8.0)
		var dir := t1 * cos(a) + t2 * sin(a)
		var q := (d + dir * (RING / WorldConfig.PLANET_RADIUS)).normalized()
		for l in ground_layers:
			l.apply(q, tmp, step)
		lowest = minf(lowest, tmp.height)
	var level := maxf(lowest - FREEBOARD, 0.3)
	# holding the water here would need a gorge: no river
	r *= 1.0 - smoothstep(CUT_MIN, CUT_MAX, col.height - level)
	if r <= 0.0:
		return
	# cut the channel: the floor is `DEPTH` below the water, blended into the ground at the edges
	col.height = lerpf(col.height, minf(col.height, level - DEPTH), smoothstep(0.0, 0.7, r))
	col.river = r
	col.river_level = level
