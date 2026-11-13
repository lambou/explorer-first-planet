class_name GrassField
extends RefCounted
## What grows where. Pure functions of (seed, place, climate, the ground colour the surface layer chose), so the meadows are
## coherent and need no storage.
##  - the GROUND decides if grass can grow: the more the ground colour is the grass green (not sand, rock or snow), the denser;
##    a drier / browner ground gives dry grass.
##  - the CLIMATE (moisture, temperature) steers the kind: moist = tall grass, hot and dry = dry grass.
##  - seeded PATCH noises split the meadow into patches of different kinds and densities (a field of tall grass here, short
##    grass there, little tufts scattered through both), so it never looks like one carpet.
##  - UNDER WATER only sea grass grows, in patches, between 0.6 and 24 m deep, not on bare rock.

const GRASS_GREEN := Color(0.365, 0.635, 0.29)     # the surface layer's grass colour (BlockTypes.GRASS)
const LAYER := 12

var catalog: GrassCatalog
var world_seed := 0
var _patch: FastNoiseLite
var _fine: FastNoiseLite
var _sea: FastNoiseLite
var _flo: FastNoiseLite
var _flo2: FastNoiseLite

func _init(p_catalog: GrassCatalog, p_seed: int) -> void:
	catalog = p_catalog
	world_seed = p_seed
	_patch = _noise(1, 1.0 / 16.0)
	_fine = _noise(2, 1.0 / 5.0)
	_sea = _noise(3, 1.0 / 12.0)
	_flo = _noise(4, 1.0 / 10.0)
	_flo2 = _noise(5, 1.0 / 23.0)

func _noise(salt: int, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = SeedMix.derive(world_seed, LAYER, salt)
	n.frequency = freq
	return n

## 0..1: how much the ground colour is grass (1 = the grass green, 0 = sand / rock / snow).
static func grassiness(ground: Color) -> float:
	var dr := ground.r - GRASS_GREEN.r
	var dg := ground.g - GRASS_GREEN.g
	var db := ground.b - GRASS_GREEN.b
	return 1.0 - smoothstep(0.07, 0.30, sqrt(dr * dr + dg * dg + db * db))

## 0..1: how dry / brown the (grassy) ground looks.
static func dryness(ground: Color) -> float:
	var dr := ground.r - GRASS_GREEN.r
	var dg := ground.g - GRASS_GREEN.g
	var db := ground.b - GRASS_GREEN.b
	return smoothstep(0.02, 0.17, sqrt(dr * dr + dg * dg + db * db))

func patch_at(p: Vector3) -> float:
	return _patch.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5

func fine_at(p: Vector3) -> float:
	return _fine.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5

## The kind of grass for one planting spot and the chance it gets planted (0..1), or [-1, 0].
## ground: the ground colour; moisture / temperature 0..1; p: world position; slope: rise over run; r: a random 0..1.
func choose(ground: Color, moisture: float, temperature: float, p: Vector3, slope: float, r: float) -> Vector2:
	var g := grassiness(ground)
	if g < 0.04:
		return Vector2(-1.0, 0.0)
	var steep := 1.0 - smoothstep(0.6, 1.2, slope)
	var n := patch_at(p)
	var n2 := fine_at(p)
	var dry := clampf(dryness(ground) * 0.7 + (1.0 - smoothstep(0.25, 0.5, moisture)) * smoothstep(0.5, 0.8, temperature) * 0.6, 0.0, 1.0)
	# weights of the kinds here
	var w_meadow := 1.0
	var w_tall := smoothstep(0.3, 0.7, moisture) * smoothstep(0.35, 0.7, n) * 1.8
	var w_dry := dry * 2.0
	var w_tuft := 0.35 + 0.5 * smoothstep(0.55, 0.85, n2)
	# flowers: patches of one colour (a seeded colour per patch), a few scattered everywhere
	var fl := _flo.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5
	var w_flower := (0.07 + 1.6 * smoothstep(0.58, 0.8, fl)) * (1.0 - 0.8 * dry)
	var fl_kind := int(clampf((_flo2.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5) * 3.0, 0.0, 2.999))
	var total := w_meadow + w_tall + w_dry + w_tuft + w_flower
	var pick := r * total
	var key := "meadow"
	if pick < w_meadow:
		key = "meadow"
	elif pick < w_meadow + w_tall:
		key = "tall"
	elif pick < w_meadow + w_tall + w_dry:
		key = "dry"
	elif pick < w_meadow + w_tall + w_dry + w_tuft:
		key = "tuft"
	else:
		key = ["daisy", "pinkflower", "bluebell"][fl_kind]
	var t := catalog.get_type(key)
	# patches: where the meadow noise is low the ground is only lightly covered (clearings), where it is high it is lush
	var lush := 0.55 + 0.45 * smoothstep(0.25, 0.7, n)
	return Vector2(float(t.id), clampf(g * steep * lush * t.density, 0.0, 1.0))

## Sea grass: the chance (0..1) it grows at a spot `depth` metres under the surface on a ground of colour `ground`.
func sea_density(depth: float, ground: Color, p: Vector3, slope: float) -> float:
	if depth < 0.6 or depth > 24.0:
		return 0.0
	var rocky := 1.0 - smoothstep(0.05, 0.2, maxf(ground.r, maxf(ground.g, ground.b)) - minf(ground.r, minf(ground.g, ground.b)))
	var patches := smoothstep(0.42, 0.62, _sea.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5)       # meadows of sea grass, bare sand between
	var light := 1.0 - smoothstep(10.0, 24.0, depth)                                          # thinner towards the dark
	return patches * (1.0 - 0.8 * rocky) * light * (1.0 - smoothstep(0.7, 1.3, slope)) * catalog.get_type("seagrass").density
