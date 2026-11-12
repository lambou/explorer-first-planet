class_name WorldConfig
extends RefCounted
## Global constants of the planet. 1 voxel = 1 metre; the player ball is 1 m wide.
## The planet is the original design multiplied by WORLD_SCALE: same shape, same mountains,
## same proportions - the player is simply that much smaller, so the ground looks flat
## around them and the mountains are far away. Sea level = PLANET_RADIUS.

const WORLD_SCALE := 20.0

const CHUNK_SIZE := 16
const PAD := 1
const PADDED := CHUNK_SIZE + 2 * PAD

const PLANET_RADIUS := 5120       # 256 * WORLD_SCALE (lap = 32 km, about 24 min at 22 m/s)
const MAX_HEIGHT := 1600          # 80 * WORLD_SCALE: highest possible terrain above sea level
const MAX_OCEAN_DEPTH := 1000     # deepest possible ocean floor below sea level
const CAVE_FLOOR := -260          # below this rel. sea level there are no caves (they follow the ground: see L08Caves)
const LAND_RATIO := 0.29          # Earth-like: ~29% land, ~71% ocean

static var world_seed: int = 1337   # 64-bit: about 1.8e19 possible worlds

## "123456789012" -> that number; any other text -> a 63-bit hash of it.
static func parse_seed(text: String) -> int:
	var t := text.strip_edges()
	if t.is_valid_int():
		return t.to_int()
	return SeedMix.hash_text(t)

## A random 12-digit seed (one of 10^12 worlds).
static func random_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return ((rng.randi() << 20) ^ rng.randi()) % 1000000000000

static func max_depth_to_core() -> int:
	return PLANET_RADIUS
