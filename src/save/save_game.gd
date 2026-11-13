class_name SaveGame
extends RefCounted
## The saved games on disk: one slot per world (user://worlds/<id>.dat), so several players can share the computer. `path` is the current
## world's slot; everything that saves or loads goes through it. Each slot is written atomically (to a temporary file first, then moved over the old one, so a crash in the middle
## of a save never destroys the last good save) and compressed. Only plain data goes in (WorldSnapshot makes it), no objects.
## A small `.info` file beside it says what is in it, so the menu can offer "Continue" without reading the whole world.

const VERSION := 1

const DIR := "user://worlds"
const LEGACY := "user://savegame.dat"                # the single save of earlier versions: moved into worlds/ the first time the list is read

static var path := "user://savegame.dat"          # the current world's slot (tests point this somewhere else, so they never touch the player's saves)
static var world_name := ""                        # the current world's name, written into its .info
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
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
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
		fi.store_var({"version": VERSION, "name": world_name, "seed": data.seed, "saved_at": data.saved_at, "playtime": data.clock.get("playtime", 0.0)}, false)
	return true

## Every saved world, newest first: [{"id", "name", "seed", "saved_at", "playtime"}].
static func list() -> Array:
	_migrate_legacy()
	var out: Array = []
	var d := DirAccess.open(DIR)
	if d == null:
		return out
	for f in d.get_files():
		if not f.ends_with(".info"):
			continue
		var id := f.get_basename()
		var saved_path := DIR + "/" + id + ".dat"
		if not FileAccess.file_exists(saved_path):
			continue
		var fi := FileAccess.open(DIR + "/" + f, FileAccess.READ)
		var inf = fi.get_var(false) if fi != null else null
		if not (inf is Dictionary) or inf.get("version", 0) != VERSION:
			continue
		inf = inf.duplicate()
		inf["id"] = id
		if str(inf.get("name", "")) == "":
			inf["name"] = "World"
		out.append(inf)
	out.sort_custom(func(a, b) -> bool: return str(a.get("saved_at", "")) > str(b.get("saved_at", "")))
	return out

## Make world `id` the current one.
static func select(id: String) -> void:
	path = "%s/%s.dat" % [DIR, id]
	world_name = str(info().get("name", ""))

## Start a new world slot with this name and make it current; returns its id. (It appears in the list at its first save.)
static func create(name_text: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var id := "w%d_%03d" % [int(Time.get_unix_time_from_system()), randi() % 1000]
	path = "%s/%s.dat" % [DIR, id]
	world_name = name_text.strip_edges() if name_text.strip_edges() != "" else "World %d" % (list().size() + 1)
	return id

## Delete world `id` (its three files).
static func delete_world(id: String) -> void:
	var base := "%s/%s" % [DIR, id]
	for p in [base + ".dat", base + ".info", base + ".dat.tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

static func _migrate_legacy() -> void:
	if not FileAccess.file_exists(LEGACY):
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var info_old := LEGACY.get_basename() + ".info"
	var ok := DirAccess.rename_absolute(ProjectSettings.globalize_path(LEGACY), ProjectSettings.globalize_path(DIR + "/world1.dat")) == OK
	if ok and FileAccess.file_exists(info_old):
		var f := FileAccess.open(info_old, FileAccess.READ)
		var d = f.get_var(false) if f != null else null
		f = null
		if d is Dictionary:
			d["name"] = "My world"
			var fo := FileAccess.open(DIR + "/world1.info", FileAccess.WRITE)
			if fo != null:
				fo.store_var(d, false)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(info_old))

static func delete() -> void:
	for p in [path, _info_path(), path + ".tmp"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
