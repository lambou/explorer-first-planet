class_name TreeField
extends RefCounted
## Where forests stand and which species. Pure functions of (seed, place, climate, ground), so forests are coherent and need no storage.
##  - FOREST noise (seeded, about 100 m wide): big dense forests, open woodland, clearings and meadows between them.
##  - GROVE noise (about 20 m): clumps inside a forest, so even a dense forest has thinner and thicker places.
##  - PROVINCE noise (seeded, about 150 m): a slow value that each species is attached to (TreeType.center): a region prefers some of the
##    species that the climate allows, so neighbouring forests have different canopies (a pine forest, then a birch grove, then oaks).
##  - the CLIMATE (temperature, moisture), the ground and the altitude score each species (TreeType.niche).

const LAYER := 13

var catalog: TreeCatalog
var world_seed := 0
var _forest: FastNoiseLite
var _grove: FastNoiseLite
var _province: FastNoiseLite

func _init(p_catalog: TreeCatalog, p_seed: int) -> void:
	catalog = p_catalog
	world_seed = p_seed
	_forest = _noise(1, 1.0 / 110.0, 2)
	_grove = _noise(2, 1.0 / 22.0, 1)
	_province = _noise(3, 1.0 / 150.0, 1)

func _noise(salt: int, freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = SeedMix.derive(world_seed, LAYER, salt)
	n.frequency = freq
	if octaves > 1:
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = octaves
	return n

## 0..1: how thick the forest is at a place (before the ground and the slope).
func forest_density(p: Vector3) -> float:
	var f := _forest.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5
	var g := _grove.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5
	var base := smoothstep(0.42, 0.62, f)                 # clearings below, forest above
	return clampf(base * (0.72 + 0.4 * g), 0.0, 1.0)

func province_at(p: Vector3) -> float:
	return _province.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5

## The species for one planting spot and the chance it gets planted, as Vector2(type id or -1, chance 0..1).
## ground: the ground colour; temp / moist: climate; alt: metres above sea level; slope: rise over run; r: a random 0..1.
func choose(ground: Color, temp: float, moist: float, alt: float, p: Vector3, slope: float, r: float) -> Vector2:
	var dens := forest_density(p)
	if dens <= 0.02:
		return Vector2(-1.0, 0.0)
	var green := GrassField.grassiness(ground)
	var sand := ground.r > 0.72 and ground.g > 0.62 and ground.b < 0.62
	var ok := maxf(green, 0.5 if sand else 0.0)
	if ok < 0.2:
		return Vector2(-1.0, 0.0)
	var steep := 1.0 - smoothstep(0.55, 1.0, slope)
	var prov := province_at(p)
	var total := 0.0
	var weights: Array[float] = []
	for t in catalog.types:
		var w := t.niche(temp, moist, alt, sand) * t.rarity
		# a region prefers the species near its province value (never entirely: the others still grow in smaller numbers)
		var d := absf(prov - t.center)
		d = minf(d, 1.0 - d)
		w *= 0.4 + 0.6 * exp(-pow(d / 0.30, 2.0))
		weights.append(w)
		total += w
	if total <= 0.0001:
		return Vector2(-1.0, 0.0)
	var pick := r * total
	var acc := 0.0
	var chosen := 0
	for i in weights.size():
		acc += weights[i]
		if pick <= acc:
			chosen = i
			break
	# how crowded: the more the climate suits the species overall, the denser the forest
	var suit := clampf(total / 1.2, 0.0, 1.0)
	return Vector2(float(chosen), clampf(dens * ok * steep * (0.55 + 0.45 * suit), 0.0, 0.95))
