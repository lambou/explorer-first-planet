class_name SeedMix
extends RefCounted
## 64-bit seed mixing (SplitMix64). Every noise generator of every layer gets its own
## independent seed derived from the world seed, so ~2^64 different worlds are possible
## (we need 10^12 = 2^40). Integer maths only: identical on every platform.

# SplitMix64 constants as signed 64-bit integers
const GAMMA := -7046029254386353131    # 0x9E3779B97F4A7C15
const M1 := -4658895280553007687       # 0xBF58476D1CE4E5B9
const M2 := -7723592293110705685       # 0x94D049BB133111EB

## Logical (not arithmetic) shift right.
static func _lsr(x: int, n: int) -> int:
	return (x >> n) & ((1 << (64 - n)) - 1)

static func splitmix64(x: int) -> int:
	var z := x + GAMMA
	z = (z ^ _lsr(z, 30)) * M1
	z = (z ^ _lsr(z, 27)) * M2
	return z ^ _lsr(z, 31)

## 31-bit seed for one noise generator (what FastNoiseLite accepts safely).
static func derive(world_seed: int, layer: int, salt: int) -> int:
	var h := splitmix64(splitmix64(splitmix64(world_seed) + layer) + salt)
	return h & 0x7fffffff

## Deterministic float in [0, 1) from the seed and an index (for world parameters).
static func unit(world_seed: int, index: int) -> float:
	var h := splitmix64(splitmix64(world_seed) ^ splitmix64(index + 0x1234567))
	return float(_lsr(h, 11)) / 9007199254740992.0

## Any text becomes a 63-bit seed.
static func hash_text(text: String) -> int:
	var h := splitmix64(0x5EED)
	for b in text.to_utf8_buffer():
		h = splitmix64(h + b + 1)
	return h & 0x7fffffffffffffff
