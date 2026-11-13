class_name SaveGame
extends RefCounted
## The saved game on disk: one slot, written atomically (to a temporary file first, then moved over the old one, so a crash in the middle
## of a save never destroys the last good save) and compressed. Only plain data goes in (WorldSnapshot makes it), no objects.
## A small `.info` file beside it says what is in it, so the menu can offer "Continue" without reading the whole world.

const VERSION := 1

static var path := "user://savegame.dat"          # tests point this somewhere else, so they never touch the player's save
static var pending: Dictionary = {}                # a save the menu loaded, waiting for the game to apply it

static func _info_path() -> String:
	return path.get_basename() + ".info"

static func exists() -> bool:
	return FileAccess.file_exists(path) and not info().is_empty()

## {"seed", "saved_at", "playtime"} of the saved game, or {} when there is none (or it is from another version).
static func info() -> Dictionary:
	if not FileAccess.file_exists(_info_path()):
		return {}
	var f := FileAccess.open(_info_path(), FileAccess.READ)
	if f == null:
		return {}
	var d = f.get_var(false)
	if not (d is Dictionary) or d.get("version", 0) != VERSION:
		return {}
	return d

## The whole save, or {} if it cannot be read.
static func read() -> Dictionary:
	if not exists():
		return {}
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return {}
	var d = f.get_var(false)
	return d if (d is Dictionary and d.get("version", 0) == VERSION) else {}

## Write the save (safe to call from a worker thread: it touches nothing but `data`, which the caller no longer changes).
static func write(data: Dictionary) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open_compressed(tmp, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		push_warning("save failed: cannot write %s" % tmp)
		return false
	f.store_var(data, false)
	f.close()
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path)) != OK:
		push_warning("save failed: cannot move %s over %s" % [tmp, path])
		return false
	var fi := FileAccess.open(_info_path(), FileAccess.WRITE)
	if fi != null:
		fi.store_var({"version": VERSION, "seed": data.seed, "saved_at": data.saved_at, "playtime": data.clock.get("playtime", 0.0)}, false)
	return true

static func delete() -> void:
	for p in [path, _info_path(), path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
