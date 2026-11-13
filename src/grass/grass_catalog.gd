class_name GrassCatalog
extends RefCounted
## The kinds of grass of one world. The table is fixed (adding a kind is one row); the colours get a small shift from
## the seed, so every world has its own palette of greens. Same seed = same catalog everywhere (integer maths only).

const VARIANTS := 2                # clump meshes per kind (each chunk uses one of them)

# key, name, hmin, hmax, blades, clump radius, blade width, density, base colour, tip colour, sway, underwater, flower
# colours follow the cozy references: light, warm, yellow-green meadows with bright tips; flowers are tiny white / pink / blue heads.
const TABLE := [
	["meadow", "Meadow grass", 0.26, 0.50, 9, 0.15, 0.030, 0.90, "6aad38", "c2e468", 1.0, false, false],
	["tall", "Tall grass", 0.60, 1.05, 8, 0.21, 0.036, 0.50, "5a9f32", "b4dd5c", 1.6, false, false],
	["tuft", "Soft tufts", 0.14, 0.26, 10, 0.11, 0.026, 0.35, "74b43e", "d0ec7a", 0.7, false, false],
	["dry", "Dry grass", 0.32, 0.58, 8, 0.17, 0.032, 0.80, "a39246", "ecd98c", 1.2, false, false],
	["seagrass", "Sea grass", 0.60, 1.30, 5, 0.15, 0.050, 0.70, "1f6a4a", "58c58a", 1.4, true, false],
	["daisy", "Daisies", 0.16, 0.30, 4, 0.18, 0.010, 0.90, "5da636", "fbfbf2", 1.1, false, true],
	["pinkflower", "Pink flowers", 0.14, 0.26, 4, 0.18, 0.010, 0.90, "5da636", "f59ac2", 1.1, false, true],
	["bluebell", "Bluebells", 0.18, 0.32, 4, 0.16, 0.010, 0.90, "5da636", "8fa4f2", 1.1, false, true],
	["fern", "Ferns", 0.22, 0.40, 11, 0.20, 0.060, 0.85, "3f8a3a", "86d060", 0.8, false, false],     # the forest floor: wide arching fronds, they like shade
]

var world_seed := 0
var types: Array[GrassType] = []
var _by_key := {}

func _init(p_seed: int = 0) -> void:
	world_seed = p_seed
	# this world's palette: a small hue and saturation shift of every green
	var hue_shift := (SeedMix.unit(p_seed, 5100) - 0.5) * 0.05
	var sat_shift := 0.9 + 0.2 * SeedMix.unit(p_seed, 5101)
	for row in TABLE:
		var t := GrassType.new()
		t.id = types.size()
		t.key = row[0]
		t.name = row[1]
		t.height_min = row[2]
		t.height_max = row[3]
		t.blades = row[4]
		t.clump_radius = row[5]
		t.blade_width = row[6]
		t.density = row[7]
		t.base_color = _shift(Color(row[8]), hue_shift, sat_shift)
		t.tip_color = _shift(Color(row[9]), hue_shift, sat_shift)
		t.sway = row[10]
		t.underwater = row[11]
		t.flower = row[12]
		types.append(t)
		_by_key[t.key] = t

static func _shift(c: Color, hue: float, sat: float) -> Color:
	return Color.from_hsv(fposmod(c.h + hue, 1.0), clampf(c.s * sat, 0.0, 1.0), c.v)

func get_type(key: String) -> GrassType:
	return _by_key.get(key)

func by_id(i: int) -> GrassType:
	return types[i]
