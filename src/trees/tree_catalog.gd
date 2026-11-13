class_name TreeCatalog
extends RefCounted
## The species of one world: a fixed table (adding one is a row) plus a few INVENTED species from the seed (an odd leaf colour,
## a rare pink or blue crown, its own name), and a per-seed shift of every green. Same seed = same catalog.

const EXOTIC_COUNT := 3

# key, name, family, hmin, hmax, trunk ratio, crown ratio, temp lo, hi, moist lo, hi, coast, bark, leaf shade, leaf light, wood, hardness, sway, rarity
const TABLE := [
	["oak", "Oak", "broadleaf", 10.0, 17.0, 0.034, 0.30, 0.38, 0.78, 0.40, 1.00, false, "6b4a30", "3f8a2c", "8cc650", "Oak wood", 1.6, 0.8, 1.0],
	["maple", "Maple", "broadleaf", 8.0, 14.0, 0.030, 0.28, 0.30, 0.70, 0.45, 1.00, false, "7a5a3c", "4f9a30", "b7d44e", "Maple wood", 1.4, 0.9, 0.8],
	["elm", "Round elm", "round", 7.0, 12.0, 0.030, 0.34, 0.32, 0.85, 0.30, 0.95, false, "5d4330", "3a8030", "7dbd4a", "Elm wood", 1.2, 1.0, 0.9],
	["birch", "Birch", "birch", 8.0, 13.0, 0.020, 0.20, 0.25, 0.62, 0.35, 0.90, false, "e6e2d6", "5aa23a", "c4e060", "Birch wood", 0.9, 1.3, 0.8],
	["pine", "Pine", "pine", 12.0, 21.0, 0.026, 0.17, 0.12, 0.58, 0.22, 0.85, false, "6a4a30", "1f6a5a", "3f9a70", "Pine wood", 1.0, 0.6, 1.1],
	["fir", "Fir", "fir", 14.0, 26.0, 0.024, 0.15, 0.06, 0.45, 0.40, 1.00, false, "5a4030", "1d5a3a", "4a8a52", "Fir wood", 1.0, 0.6, 1.0],
	["palm", "Palm", "palm", 8.0, 13.0, 0.022, 0.30, 0.66, 1.00, 0.30, 1.00, true, "9a7a50", "3f8a30", "9ad050", "Palm wood", 0.6, 1.5, 1.0],
	["acacia", "Acacia", "acacia", 6.0, 10.0, 0.034, 0.46, 0.58, 1.00, 0.12, 0.50, false, "7a5a3a", "6a9a30", "c6cf5a", "Acacia wood", 1.8, 0.8, 0.9],
]

const NAME_A := ["Sil", "Mor", "Tha", "Eld", "Wyl", "Bra", "Lun", "Oth", "Fey", "Nar"]
const NAME_B := ["wen", "ia", "oak", "leaf", "ash", "bough", "wood", "yn"]
const FAMILIES := ["broadleaf", "round", "birch", "pine", "fir", "acacia"]

var world_seed := 0
var types: Array[TreeType] = []
var _by_key := {}

func _init(p_seed: int = 0) -> void:
	world_seed = p_seed
	var hue := (SeedMix.unit(p_seed, 6100) - 0.5) * 0.06
	var sat := 0.92 + 0.16 * SeedMix.unit(p_seed, 6101)
	for row in TABLE:
		var t := TreeType.new()
		t.key = row[0]
		t.name = row[1]
		t.family = row[2]
		t.h_min = row[3]
		t.h_max = row[4]
		t.trunk_ratio = row[5]
		t.canopy_ratio = row[6]
		t.temp_lo = row[7]
		t.temp_hi = row[8]
		t.moist_lo = row[9]
		t.moist_hi = row[10]
		t.coast = row[11]
		t.bark = Color(row[12])
		t.leaf_a = _shift(Color(row[13]), hue, sat)
		t.leaf_b = _shift(Color(row[14]), hue, sat)
		t.wood = row[15]
		t.hardness = row[16]
		t.sway = row[17]
		t.rarity = row[18]
		_add(t)
	for i in EXOTIC_COUNT:
		_add(_exotic(i))
	# where each species sits on the province axis: spread evenly, shuffled by the seed (a region prefers some species over others)
	var n := types.size()
	for i in n:
		types[i].center = fposmod(float(i) / n + SeedMix.unit(p_seed, 6200 + i) * 0.08, 1.0)

func _add(t: TreeType) -> void:
	t.id = types.size()
	types.append(t)
	_by_key[t.key] = t

func get_type(key: String) -> TreeType:
	return _by_key.get(key)

func by_id(i: int) -> TreeType:
	return types[i]

static func _shift(c: Color, hue: float, sat: float) -> Color:
	return Color.from_hsv(fposmod(c.h + hue, 1.0), clampf(c.s * sat, 0.0, 1.0), c.v)

## An invented species: a family from the seed with its own odd crown colour and a name.
func _exotic(i: int) -> TreeType:
	var s := world_seed
	var fam: String = FAMILIES[int(SeedMix.unit(s, 6300 + i * 10) * FAMILIES.size())]
	var base := get_type({"broadleaf": "oak", "round": "elm", "birch": "birch", "pine": "pine", "fir": "fir", "acacia": "acacia"}[fam])
	var t := TreeType.new()
	t.key = "exotic_%d" % i
	t.name = NAME_A[int(SeedMix.unit(s, 6301 + i * 10) * NAME_A.size())] + NAME_B[int(SeedMix.unit(s, 6302 + i * 10) * NAME_B.size())] + " tree"
	t.family = fam
	t.h_min = base.h_min
	t.h_max = base.h_max * 1.1
	t.trunk_ratio = base.trunk_ratio
	t.canopy_ratio = base.canopy_ratio
	t.temp_lo = clampf(base.temp_lo + (SeedMix.unit(s, 6303 + i * 10) - 0.5) * 0.3, 0.0, 0.85)
	t.temp_hi = clampf(t.temp_lo + 0.35 + 0.2 * SeedMix.unit(s, 6304 + i * 10), 0.3, 1.0)
	t.moist_lo = base.moist_lo
	t.moist_hi = base.moist_hi
	t.bark = base.bark.lerp(Color.from_hsv(SeedMix.unit(s, 6305 + i * 10), 0.4, 0.5), 0.35)
	var hue := SeedMix.unit(s, 6306 + i * 10)
	t.leaf_a = Color.from_hsv(hue, 0.55, 0.55)
	t.leaf_b = Color.from_hsv(hue, 0.4, 0.9)
	t.wood = t.name.replace(" tree", "") + " wood"
	t.hardness = 1.0 + 1.5 * SeedMix.unit(s, 6307 + i * 10)
	t.sway = base.sway
	t.rarity = 0.25
	return t
