class_name RockCatalog
extends RefCounted
## Every kind of rock of one world: the known ones (fixed table) plus a few UNKNOWN ones invented from the seed,
## each with its own name, colour, hardness, density, hosts, depth and traits. Adding a real type later is one
## row in TABLE. Same seed = same catalog on every machine (integer maths only).

const EXOTIC_COUNT := 5

# key, name, family, colour, hardness, density, value, rarity, hosts, min_depth, alt_min, alt_max, underwater_ok
const TABLE := [
	# ---- base rocks: they make up whole regions
	["granite", "Granite", "stone", "a08c88", 3.0, 2.7, 1.0, 1.0, [], 0.0, -10000.0, 10000.0, true],
	["basalt", "Basalt", "stone", "4a4c52", 3.0, 3.0, 1.0, 1.0, [], 0.0, -10000.0, 10000.0, true],
	["limestone", "Limestone", "stone", "cfc7b0", 1.6, 2.5, 1.0, 1.0, [], 0.0, -10000.0, 10000.0, true],
	["sandstone", "Sandstone", "stone", "c99a5f", 1.4, 2.3, 1.0, 1.0, [], 0.0, -10000.0, 10000.0, true],
	["slate", "Slate", "stone", "5d6670", 2.0, 2.8, 1.0, 1.0, [], 0.0, -10000.0, 10000.0, true],
	["marble", "Marble", "stone", "e6e4e0", 2.4, 2.7, 3.0, 1.0, [], 0.0, -10000.0, 10000.0, true],
	["obsidian", "Obsidian", "stone", "17141c", 2.2, 2.4, 2.0, 1.0, [], 0.0, -10000.0, 10000.0, true],
	["quartzite", "Quartzite", "stone", "d9b8b0", 3.6, 2.65, 1.5, 1.0, [], 0.0, -10000.0, 10000.0, true],
	# ---- fuels, metals, salts: veins in their host rocks
	["coal", "Coal", "ore", "1c1c1e", 1.0, 1.3, 2.0, 0.55, ["limestone", "sandstone", "slate"], 0.0, 0.0, 10000.0, false],
	["salt", "Rock salt", "ore", "efeee8", 0.8, 2.2, 1.5, 0.35, ["limestone", "sandstone"], 0.0, -100.0, 400.0, true],
	["sulfur", "Sulfur", "ore", "e6d23a", 0.7, 2.0, 2.5, 0.25, ["basalt", "obsidian"], 0.0, -50.0, 10000.0, false],
	["iron", "Iron ore", "ore", "8a4b32", 3.2, 5.0, 3.0, 0.6, ["granite", "basalt", "slate", "quartzite"], 0.0, -300.0, 10000.0, true],
	["copper", "Copper ore", "ore", "c8703a", 2.6, 8.9, 5.0, 0.4, ["granite", "basalt", "marble"], 0.0, -300.0, 10000.0, true],
	["tin", "Tin ore", "ore", "8d93a0", 2.4, 7.3, 5.0, 0.3, ["granite", "quartzite"], 4.0, -300.0, 10000.0, true],
	["silver", "Silver ore", "ore", "c9ced6", 2.8, 10.5, 12.0, 0.18, ["granite", "marble", "quartzite", "slate"], 10.0, -400.0, 10000.0, true],
	["gold", "Gold ore", "ore", "e0b020", 2.6, 19.3, 40.0, 0.10, ["granite", "quartzite", "marble"], 12.0, -500.0, 10000.0, true],
	["platinum", "Platinum ore", "ore", "dfe3ea", 3.4, 21.4, 70.0, 0.05, ["basalt", "slate"], 30.0, -700.0, 10000.0, true],
	# ---- gems
	["crystal", "Quartz crystal", "gem", "e7f0f4", 3.4, 2.65, 6.0, 0.22, ["granite", "quartzite", "marble", "limestone"], 6.0, -300.0, 10000.0, true],
	["amethyst", "Amethyst", "gem", "8b4fc2", 3.4, 2.65, 14.0, 0.12, ["basalt", "granite"], 10.0, -300.0, 10000.0, true],
	["emerald", "Emerald", "gem", "1f9d55", 3.8, 2.7, 60.0, 0.06, ["marble", "slate", "granite"], 25.0, -500.0, 10000.0, true],
	["ruby", "Ruby", "gem", "c4162f", 4.4, 4.0, 90.0, 0.04, ["marble", "basalt"], 30.0, -600.0, 10000.0, true],
	["sapphire", "Sapphire", "gem", "2745c4", 4.4, 4.0, 90.0, 0.04, ["marble", "basalt", "granite"], 30.0, -600.0, 10000.0, true],
	["diamond", "Diamond", "gem", "d9f4ff", 5.0, 3.5, 250.0, 0.02, ["obsidian", "basalt", "quartzite"], 60.0, -800.0, 10000.0, true],
	# ---- radioactive
	["uranium", "Uranium ore", "radioactive", "6fbf2e", 2.8, 19.0, 120.0, 0.05, ["granite", "quartzite"], 25.0, -400.0, 10000.0, true],
	["thorium", "Thorium ore", "radioactive", "7fa890", 2.8, 11.7, 80.0, 0.05, ["granite", "marble"], 30.0, -400.0, 10000.0, true],
]

const TRAITS_FIXED := {
	"obsidian": {"brittle": 0.8},
	"coal": {"flammable": 0.9},
	"sulfur": {"flammable": 0.5},
	"iron": {"magnetic": 0.6},
	"crystal": {"glow": 0.15},
	"diamond": {"glow": 0.35, "brittle": 0.2},
	"uranium": {"radioactive": 0.9, "glow": 0.6},
	"thorium": {"radioactive": 0.6},
	"salt": {"brittle": 0.5},
}

const SYL_A := ["Vel", "Kry", "Zor", "Aur", "Nyx", "Thal", "Ore", "Xan", "Ith", "Bor", "Cael", "Dru", "Eld", "Fyr", "Ghal", "Hy"]
const SYL_B := ["an", "or", "ul", "ith", "ax", "eon", "ur", "il", "om", "ar", "yn", "esh"]
const SYL_C := ["ite", "ium", "ine", "ox", "ite", "ium", "lite", "gen"]
const EXOTIC_TRAITS := ["radioactive", "magnetic", "brittle", "glow", "flammable", "heavy", "light"]

var world_seed := 0
var types: Array[RockType] = []
var _by_key := {}

func _init(p_seed: int = 0) -> void:
	world_seed = p_seed
	for row in TABLE:
		var t := RockType.new()
		t.id = types.size()
		t.key = row[0]
		t.name = row[1]
		t.family = row[2]
		t.color = Color(row[3])
		t.hardness = row[4]
		t.density = row[5]
		t.value = row[6]
		t.rarity = row[7]
		t.hosts = PackedStringArray(row[8])
		t.min_depth = row[9]
		t.alt_min = row[10]
		t.alt_max = row[11]
		t.underwater_ok = row[12]
		t.traits = TRAITS_FIXED.get(t.key, {})
		_add(t)
	_place_base_rocks()
	for i in EXOTIC_COUNT:
		_add(_make_exotic(i))

func _add(t: RockType) -> void:
	t.id = types.size()
	types.append(t)
	_by_key[t.key] = t

func get_type(key: String) -> RockType:
	return _by_key.get(key)

func by_id(i: int) -> RockType:
	return types[i]

func base_types() -> Array[RockType]:
	var out: Array[RockType] = []
	for t in types:
		if t.is_base():
			out.append(t)
	return out

func ore_types() -> Array[RockType]:
	var out: Array[RockType] = []
	for t in types:
		if not t.is_base():
			out.append(t)
	return out

## Each seed lays the base rocks out differently in the (2D) province space: where granite country lies, where
## limestone country lies, ... is part of the world's identity. Spread evenly (a jittered grid), then shuffled by seed.
func _place_base_rocks() -> void:
	var bases := base_types()
	var n := bases.size()
	var order: Array[int] = []
	for i in n:
		order.append(i)
	for i in range(n - 1, 0, -1):                       # seeded shuffle
		var j := int(SeedMix.unit(world_seed, 9000 + i) * float(i + 1))
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	var cols := 4
	for k in n:
		var t := bases[order[k]]
		var gx := float(k % cols) + 0.5
		var gy := float(k / cols) + 0.5
		t.center = Vector2(
			(gx + (SeedMix.unit(world_seed, 9100 + k) - 0.5) * 0.5) / float(cols),
			(gy + (SeedMix.unit(world_seed, 9200 + k) - 0.5) * 0.5) / float(ceili(float(n) / cols)))

## An unknown rock invented from the seed: name, colour, properties, where it can form.
func _make_exotic(i: int) -> RockType:
	var s := world_seed
	var t := RockType.new()
	t.key = "exotic_%d" % i
	t.family = RockType.FAMILY_EXOTIC
	var a := int(SeedMix.unit(s, 100 + i * 10) * SYL_A.size())
	var b := int(SeedMix.unit(s, 101 + i * 10) * SYL_B.size())
	var c := int(SeedMix.unit(s, 102 + i * 10) * SYL_C.size())
	t.name = SYL_A[a] + SYL_B[b] + SYL_C[c]
	t.color = Color.from_hsv(SeedMix.unit(s, 103 + i * 10), 0.45 + 0.5 * SeedMix.unit(s, 104 + i * 10), 0.45 + 0.5 * SeedMix.unit(s, 105 + i * 10))
	t.hardness = 1.5 + 4.0 * SeedMix.unit(s, 106 + i * 10)
	t.density = 1.5 + 18.0 * pow(SeedMix.unit(s, 107 + i * 10), 1.5)
	t.value = 60.0 + 300.0 * SeedMix.unit(s, 108 + i * 10)
	t.rarity = 0.03 + 0.05 * SeedMix.unit(s, 109 + i * 10)
	var bases := base_types()
	var host_a := bases[int(SeedMix.unit(s, 110 + i * 10) * bases.size())]
	var host_b := bases[int(SeedMix.unit(s, 111 + i * 10) * bases.size())]
	t.hosts = PackedStringArray([host_a.key, host_b.key])
	t.min_depth = 15.0 + 90.0 * SeedMix.unit(s, 112 + i * 10)
	t.alt_min = -800.0
	var tr: String = EXOTIC_TRAITS[int(SeedMix.unit(s, 113 + i * 10) * EXOTIC_TRAITS.size())]
	t.traits = {tr: 0.4 + 0.6 * SeedMix.unit(s, 114 + i * 10)}
	if SeedMix.unit(s, 115 + i * 10) > 0.5:
		var tr2: String = EXOTIC_TRAITS[int(SeedMix.unit(s, 116 + i * 10) * EXOTIC_TRAITS.size())]
		t.traits[tr2] = 0.3 + 0.7 * SeedMix.unit(s, 117 + i * 10)
	return t
