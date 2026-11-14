class_name WorldSnapshot
extends RefCounted
## Turns the live game into plain data (a Dictionary SaveGame can write) and puts it back. What is saved is exactly what play changes:
##   - the terrain edits (digging, filling), the rocks that were chipped, broken or moved, the trees that were cut or felled;
##   - the explorer: where he stands, what he carries, his tools (with the fuel left in each torch), the torches he planted;
##   - the time of day and of the year, and how long he has played.
## Everything else (terrain, rocks, trees, grass, water) is made again from the seed, so a save stays small.

var _edits_cache := {}               # the terrain edits are the big part: copied only when they changed, the copy is shared by saves
var _edits_rev := -1

func capture(world: VoxelWorld, player: BallPlayer, kit: PlayerKit, torches: PlacedTorches, clock: Dictionary) -> Dictionary:
	if world.edit_rev != _edits_rev or _edits_rev < 0:
		_edits_cache = world.edits.duplicate(true)
		_edits_rev = world.edit_rev
	return {
		"version": SaveGame.VERSION,
		"seed": WorldConfig.world_seed,
		"saved_at": Time.get_datetime_string_from_system(false, true),
		"edits": _edits_cache,
		"rocks_changed": world.rocks.changed.duplicate(true),
		"rocks_moved": world.rocks.moved_index.duplicate(true),
		"trees_changed": world.trees.changed.duplicate(true),
		"player": {"pos": player.position, "spawn": player.spawn_pos, "fly": player.fly, "fly_pitch": player.fly_pitch},   # (a direct child of the world root: local = global)
		"items": ItemCatalog.dynamic_data(),
		"inventory": kit.inventory.to_data(),
		"belt": kit.belt.to_data(),
		"bar_slot": kit.bar_slot,
		"torches": torches.to_data(),
		"clock": clock,
	}

## The world's part, put back before any chunk is built (the chunks read these when they are made).
static func restore_world(data: Dictionary, world: VoxelWorld) -> void:
	world.edits = data.edits
	world.rocks.changed = data.rocks_changed
	world.rocks.moved_index = data.rocks_moved
	world.trees.changed = data.trees_changed

## The explorer's part. Returns the clock ({"sun_angle", "season", "playtime"}).
static func restore_player(data: Dictionary, player: BallPlayer, kit: PlayerKit, torches: PlacedTorches) -> Dictionary:
	ItemCatalog.restore_dynamic(data.items)               # the rocks and woods he carries must exist before the inventory refers to them
	player.position = data.player.pos
	player.spawn_pos = data.player.spawn
	player.fly = bool(data.player.get("fly", false))                 # saved while flying: he is flying again, not falling
	player.fly_pitch = float(data.player.get("fly_pitch", 0.0))
	player.linear_velocity = Vector3.ZERO
	kit.inventory.from_data(data.inventory)
	kit.belt.from_data(data.belt)
	kit.bar_slot = data.bar_slot
	kit.bar_slot_changed.emit()
	torches.from_data(data.torches)
	return data.clock
