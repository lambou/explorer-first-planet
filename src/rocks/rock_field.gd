class_name RockField
extends RefCounted
## The geology of one world: which rock lies where. Pure functions of (seed, place), so it is coherent (regions,
## veins) and needs no storage.
##  - PROVINCES: two slow noises over the planet make a 2D "province" coordinate; each base rock owns a spot in
##    that space (RockCatalog), the nearest one is the rock of the place. Granite country, limestone country...
##  - RICHNESS: a slow noise scales how many rocks lie around (barren plains, rocky badlands).
##  - VEINS: every ore has its own 3D noise; where it is high the ore can be the core of a rock. The odds follow the
##    ore's rarity and its rules (host rocks, depth, altitude, sea).
## A rock is a list of LAYERS from the outside in: [[type id, outer radius fraction], ...] (host shell, ore core).

const LAYER := 11

var catalog: RockCatalog
var world_seed := 0
var _prov_a: FastNoiseLite
var _prov_b: FastNoiseLite
var _rich: FastNoiseLite
var _veins := {}                   # type id -> FastNoiseLite

func _init(p_catalog: RockCatalog, p_seed: int) -> void:
	catalog = p_catalog
	world_seed = p_seed
	_prov_a = _noise(1, 2)
	_prov_b = _noise(2, 2)
	_rich = _noise(3, 2)
	for t in catalog.ore_types():
		var n := _noise(100 + t.id, 1)
		n.frequency = t.vein_freq
		_veins[t.id] = n

func _noise(salt: int, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = SeedMix.derive(world_seed, LAYER, salt)
	n.frequency = 1.0
	if octaves > 1:
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = octaves
	else:
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
	return n

## Province coordinate (0..1, 0..1) of a direction on the planet.
func province(d: Vector3) -> Vector2:
	var a := _prov_a.get_noise_3d(d.x * 1.3, d.y * 1.3, d.z * 1.3) * 0.5 + 0.5
	var b := _prov_b.get_noise_3d(d.x * 2.1, d.y * 2.1, d.z * 2.1) * 0.5 + 0.5
	# noise values crowd around the middle: stretch them so every province gets its share
	return Vector2(clampf((a - 0.5) * 1.9 + 0.5, 0.0, 1.0), clampf((b - 0.5) * 1.9 + 0.5, 0.0, 1.0))

## The base rock of the place (nearest province centre).
func base_at(d: Vector3) -> RockType:
	var pv := province(d)
	var best: RockType = null
	var best_d := 1e9
	for t in catalog.base_types():
		var dd := pv.distance_squared_to(t.center)
		if dd < best_d:
			best_d = dd
			best = t
	return best

## 0.3 (barren) .. 1.8 (rocky): scales how many rocks lie around here.
func richness(d: Vector3) -> float:
	var n := _rich.get_noise_3d(d.x * 9.0, d.y * 9.0, d.z * 9.0) * 0.5 + 0.5
	return lerpf(0.3, 1.8, smoothstep(0.2, 0.8, n))

## 0..1: how strongly the vein of an ore runs through this point.
func vein_strength(t: RockType, p: Vector3) -> float:
	var n: FastNoiseLite = _veins[t.id]
	return smoothstep(0.52, 0.72, n.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5)

## Can this ore form here at all? (host rock, depth below the natural surface, altitude, sea)
static func ore_allowed(t: RockType, host_key: String, depth: float, alt: float, underwater: bool) -> bool:
	if not t.hosts.is_empty() and not t.hosts.has(host_key):
		return false
	if depth < t.min_depth or alt < t.alt_min or alt > t.alt_max:
		return false
	if underwater and not t.underwater_ok:
		return false
	return true

## The layers of the rock lying at world position `p` (direction `d`). `r` is a hash value in [0,1) that picks
## among the possibilities, so the same rock always gets the same answer.
## ctx: {"depth": metres below the natural surface (0 on the surface, big in a cave),
##       "alt": metres above sea level, "underwater": bool}
func choose(d: Vector3, p: Vector3, ctx: Dictionary, r: float, boost: float = 1.0) -> Array:
	var host := base_at(d)
	var depth: float = ctx.depth
	var alt: float = ctx.alt
	var uw: bool = ctx.underwater
	# the odds of each ore here; they add up (a point rarely qualifies for more than one)
	var total := 0.0
	var odds: Array = []
	for t in catalog.ore_types():
		if not ore_allowed(t, host.key, depth, alt, uw):
			continue
		var vs := vein_strength(t, p)
		if vs <= 0.0:
			continue
		var o := t.rarity * vs * 1.6 * boost
		odds.append([t, o, vs])
		total += o
	if total > 0.0 and r < total:
		var acc := 0.0
		for e in odds:
			acc += e[1]
			if r < acc:
				var t: RockType = e[0]
				var core: float = 0.30 + 0.40 * float(e[2])            # richer vein = bigger core
				return [[host.id, 1.0], [t.id, core]]
	return [[host.id, 1.0]]
