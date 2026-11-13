class_name PlacedTorches
extends Node3D
## The torches planted in the world: stuck into the ground or a wall, burning on their own, so the player can keep both
## hands on the pickaxe in the dark. They can be picked up again. A torch whose ground is dug away falls and comes back
## to the player (`dropped`). Owns nothing of the inventory: the caller takes and gives the torch.

signal dropped(id: String, fuel: float)   # a torch lost its ground and fell: give it back (which kind, with the fuel it has left)
signal burnt_out                       # a torch ran out of fuel and went out

const STAKE := 0.24                    # model: the point of the stake is this far below the grip origin
const SINK := 0.08                     # how deep the stake goes into the surface
const PICK_RADIUS := 0.4               # how close to the ray a torch must be to be picked
const CHECK_EVERY := 0.5

var world: VoxelWorld
var _list: Array = []                  # {"node": Node3D, "flame": TorchFlame, "point": Vector3, "normal": Vector3, "fuel": seconds left}
var _t := 0.0
var _check := 0.0

## The way the stake points: out of the surface, tipped up on a wall so it does not hang sideways. Null: not possible (a ceiling).
static func stick_dir(normal: Vector3, up: Vector3) -> Variant:
	var d := normal.dot(up)
	if d < -0.3:
		return null
	if d > 0.85:
		return up
	return (normal + up * 0.6).normalized()

## Where the model's origin goes so that the stake's point sits `SINK` deep in the surface at `point`.
static func origin_for(point: Vector3, dir: Vector3) -> Vector3:
	return point + dir * (STAKE - SINK) * ToolCatalog.MODEL_SCALE

func can_place(point: Vector3, normal: Vector3) -> bool:
	return stick_dir(normal, point.normalized()) != null

## `fuel`: seconds the torch has left to burn. `id`: which torch (each kind has its own model).
func place(point: Vector3, normal: Vector3, fuel: float, id: String = "torch") -> bool:
	var up := point.normalized()
	var dir: Variant = stick_dir(normal, up)
	if dir == null:
		return false
	var scene := load(ToolCatalog.get_def(id).model_path) as PackedScene
	if scene == null:
		return false
	var model := scene.instantiate() as Node3D
	add_child(model)
	var x := up.cross(dir)
	x = x.normalized() if x.length() > 0.01 else Vector3.RIGHT
	model.global_transform = Transform3D(Basis(x, dir, x.cross(dir)).scaled(Vector3.ONE * ToolCatalog.MODEL_SCALE), origin_for(point, dir))
	_list.append({"node": model, "flame": TorchFlame.attach(model, randf() * 10.0), "point": point, "normal": normal, "fuel": fuel, "id": id})
	return true

## The nearest planted torch along a ray, within `reach` metres of `from` (the player): removed from the world. Returns
## {"id": which torch, "fuel": what it had left}, or {} if there was no torch there.
func pick_up(origin: Vector3, dir: Vector3, from: Vector3, reach: float) -> Dictionary:
	var best := -1
	var best_t := INF
	for i in _list.size():
		var e: Dictionary = _list[i]
		if (e.point as Vector3).distance_to(from) > reach + 0.6:
			continue
		var axis := (e.node as Node3D).global_transform.basis.y.normalized()
		for k in 5:                                         # along the whole torch, from the stake to the flame
			var c: Vector3 = e.point + axis * (0.1 + k * 0.25)
			var t := (c - origin).dot(dir)
			if t > 0.0 and (c - (origin + dir * t)).length() <= PICK_RADIUS and t < best_t:
				best_t = t
				best = i
	if best < 0:
		return {}
	var got := {"id": _list[best].id, "fuel": _list[best].fuel}
	_remove(best)
	return got

## The planted torches as plain data (for the save), and back.
func to_data() -> Array:
	var out: Array = []
	for e: Dictionary in _list:
		out.append({"point": e.point, "normal": e.normal, "fuel": e.fuel, "id": e.id})
	return out

func from_data(d: Array) -> void:
	for e: Dictionary in d:
		place(e.point, e.normal, e.fuel, e.get("id", "torch"))      # older saves have no kind: a fuel torch

func count() -> int:
	return _list.size()

func _process(delta: float) -> void:
	_t += delta
	for i in range(_list.size() - 1, -1, -1):
		var e: Dictionary = _list[i]
		e.fuel -= delta
		if e.fuel <= 0.0:
			_remove(i)                                  # burnt down
			burnt_out.emit()
			continue
		(e.flame as TorchFlame).flicker(_t, clampf(e.fuel / ToolCatalog.TORCH_DIM_SECONDS, 0.0, 1.0))
	_check -= delta
	if _check <= 0.0 and world != null:
		_check = CHECK_EVERY
		for i in range(_list.size() - 1, -1, -1):
			# the ground under the stake was dug away: the torch falls
			if world.density_at(_list[i].point - _list[i].normal * 0.15) < -0.4:
				var left: float = _list[i].fuel
				var kind: String = _list[i].id
				_remove(i)
				dropped.emit(kind, left)

func _remove(i: int) -> void:
	(_list[i].node as Node3D).queue_free()
	_list.remove_at(i)
