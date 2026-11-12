class_name L08Caves
extends GenLayer
## Layer 8: caves. They follow geology instead of being random holes:
##  - CAVE PROVINCES: caves only form in some regions (a low-frequency mask), in rock: on land and
##    more under mountains, never under the open ocean.
##  - ROOMS: big caverns (tens of metres wide, wider and taller with depth), flattened so they
##    spread along the rock layers, like a real karst cave.
##  - TUNNELS: wide galleries (about 5 m radius) that link the rooms into one network.
##  - DEPTH: sealed near the surface (nothing above 12 m deep, fully open from 30 m).
##  - ENTRANCES: sinkholes, rare funnel-shaped holes in the surface. In cave provinces the shaft
##    goes down to the caves; elsewhere it is only a bowl.
## Everything is a signed field in metres (negative = hollow), so the cave walls are smooth.

const BIG := 1000.0
const SEAL_TOP := 12.0
const SEAL_FULL := 30.0
const SINK_BOWL := 12.0
const SINK_SHAFT := 80.0
const TUNNEL_WIDTH := 0.10
const COAST_DEPTH := 45.0          # sea caves seen from outside are blind alcoves this deep (the rest exists when underground)
const COAST_BAND := 0.07           # |continent value| below this = shoreline band (about 500 m wide)

var region_noise: FastNoiseLite
var room_noise: FastNoiseLite
var tunnel_a: FastNoiseLite
var tunnel_b: FastNoiseLite
var sink_noise: FastNoiseLite

func _init(p_seed: int = 0) -> void:
	super(p_seed)
	layer_index = 8
	layer_name = "caves"
	region_noise = make_noise(1, 2)
	room_noise = make_noise(2, 2)
	tunnel_a = make_noise(3)
	tunnel_b = make_noise(4)
	sink_noise = make_noise(5, 2)

## 0..1: how cave-prone the rock under this direction is (needs the macro layers' column).
func region_mask(d: Vector3, col: Column) -> float:
	var n := fsample(region_noise, d, 3.0) * 0.5 + 0.5
	var m := smoothstep(params.cave_region_lo, params.cave_region_lo + 0.22, n)
	m *= smoothstep(-0.05, 0.10, col.land)                          # not under the open ocean
	m *= lerpf(0.6, 1.0, clampf(col.mountain * 2.0, 0.0, 1.0))      # more under mountains
	return m

## Big rooms. Horizontal scale ~240 m, vertical scale 3x smaller: flat, spreading caverns.
func room_field(d: Vector3, rel: float, depth: float) -> float:
	var q := d * ((WorldConfig.PLANET_RADIUS + rel * 3.0) / 240.0)
	var n := room_noise.get_noise_3d(q.x, q.y, q.z)
	var thr := 0.34 - 0.10 * smoothstep(30.0, 160.0, depth)    # deeper = bigger rooms
	return (thr - n) * 110.0

## Winding galleries (~5 m radius) that connect the rooms.
func tunnel_field(p: Vector3) -> float:
	var f := 1.0 / 90.0
	var a := tunnel_a.get_noise_3d(p.x * f, p.y * f, p.z * f)
	var w := TUNNEL_WIDTH
	if absf(a) > 0.30:
		return (absf(a) - w) * 52.0
	var b := tunnel_b.get_noise_3d(p.x * f, p.y * f, p.z * f)
	return (maxf(absf(a), absf(b)) - w) * 52.0

## Sinkholes: rare funnels in the surface (negative inside). Wide at the rim, a shaft or a bowl.
func sink_field(d: Vector3, depth: float, mask: float, with_caves: bool, col: Column) -> float:
	if col.land < 0.05 or col.height < 8.0:
		return BIG
	var inside := sample(sink_noise, d, 300.0) - params.sink_threshold
	if inside <= 0.0:
		return BIG
	var reach := lerpf(SINK_BOWL, SINK_SHAFT, smoothstep(0.35, 0.6, mask)) if with_caves else SINK_BOWL
	var f := -inside * 170.0
	return f + BIG * smoothstep(reach - 6.0, reach, depth)

## > 0 inside a sinkhole's footprint (a cheap per-direction test used to skip whole blocks).
func sink_inside(d: Vector3, col: Column) -> float:
	if col.land < 0.05 or col.height < 8.0:
		return -1.0
	return sample(sink_noise, d, 300.0) - params.sink_threshold

## Signed field of the hollow space at a point `depth` metres below the surface (positive = rock).
## `col` must hold the macro layers' result for direction d. `mask_in` = region_mask(d, col) when the
## caller already knows it (it only depends on the direction), -1 to compute it here.
## 1 on the shoreline, 0 beyond the coastal band.
static func coast_factor(land: float) -> float:
	return 1.0 - smoothstep(COAST_BAND * 0.45, COAST_BAND, absf(land))

func field(p: Vector3, d: Vector3, depth: float, col: Column, with_caves: bool, mask_in: float = -1.0) -> float:
	var mask := mask_in
	if mask < 0.0:
		mask = region_mask(d, col) if (with_caves or depth < SINK_BOWL + 4.0) else 0.0
	var f := sink_field(d, depth, mask, with_caves, col)
	if with_caves and depth > SEAL_TOP and mask > 0.05:
		var rel := p.length() - WorldConfig.PLANET_RADIUS
		var seal := BIG * (1.0 - smoothstep(SEAL_TOP, SEAL_FULL, depth))
		var gate := BIG * (1.0 - smoothstep(0.15, 0.45, mask))
		f = minf(f, minf(room_field(d, rel, depth), tunnel_field(p)) + seal + gate)
	# SEA CAVES: along the shore the tunnels open right up to the ground and the seabed (entrances
	# above and below the waterline). Seen from outside they are blind alcoves; underground they go on.
	var coast := coast_factor(col.land)
	if coast > 0.05 and depth > 0.0 and (with_caves or depth < COAST_DEPTH):
		var open_top := maxf(0.0, 1.5 - depth) * 4.0
		var gate2 := BIG * (1.0 - smoothstep(0.1, 0.5, coast))
		var cut := 0.0 if with_caves else BIG * smoothstep(COAST_DEPTH - 8.0, COAST_DEPTH, depth)
		f = minf(f, tunnel_field(p) + open_top + gate2 + cut)
	return f
