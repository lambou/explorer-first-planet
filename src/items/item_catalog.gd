class_name ItemCatalog
extends RefCounted
## The registry of every kind of item. The fixed ones (clay, sand, water ...) are here; the ones that depend on the world
## (a rock type, a wood) are registered by whoever meets them first (see Harvester), and bricks are made on demand from
## their raw material. Nothing here knows rocks, trees or the inventory.

const BRICK_KG := 6.0            # about this much raw material goes into a brick: four clay, four granite, one unit of gold (never more than can be carried)

static var _defs: Dictionary = {}
static var _built := false

static func _ensure() -> void:
	if _built:
		return
	_built = true
	var clay := ItemDef.make("clay", "Clay", ItemDef.RESOURCE, 1.5, Color("b0694a"), "lump", ["brickable", "clay"])
	clay.dry = 0.75                                              # a clay brick loses water as it is pressed and dried
	clay.blurb = "Wet clay from the ground. Press four into a brick."
	register(clay)
	register(ItemDef.make("sand", "Sand", ItemDef.RESOURCE, 1.4, Color("e0cf8a"), "pile", ["sand"]))
	register(ItemDef.make("gravel", "Gravel", ItemDef.RESOURCE, 1.6, Color("9a958d"), "pile", ["gravel"]))
	register(ItemDef.make("snow", "Snow", ItemDef.RESOURCE, 0.5, Color("f2f6fa"), "pile", ["snow"]))
	var water := ItemDef.make("water", "Water", ItemDef.LIQUID, 1.0, Color("3f8fd2"), "drop", ["water"])
	water.max_stack = 10                                         # what the bucket holds (litres)
	water.blurb = "Carried in the bucket: one litre weighs one kilogram."
	register(water)

static func register(def: ItemDef) -> void:
	_defs[def.id] = def

static func has_item(id: String) -> bool:
	_ensure()
	return _defs.has(id)

static func get_def(id: String) -> ItemDef:
	_ensure()
	return _defs.get(id)

## The items made while playing (a rock type, a wood, a brick of them): the save keeps them, since only the world knows how to make them.
static func dynamic_data() -> Array:
	_ensure()
	var out: Array = []
	for id: String in _defs:
		if id.contains(":"):
			var d: ItemDef = _defs[id]
			out.append({"id": d.id, "name": d.name, "kind": d.kind, "unit_kg": d.unit_kg, "max_stack": d.max_stack, "color": d.color, "shape": d.shape,
				"tags": Array(d.tags), "dry": d.dry, "material_id": d.material_id, "blurb": d.blurb})
	return out

static func restore_dynamic(list: Array) -> void:
	_ensure()
	for e: Dictionary in list:
		var d := ItemDef.make(e.id, e.name, e.kind, e.unit_kg, e.color, e.shape, e.tags)
		d.max_stack = e.max_stack
		d.dry = e.dry
		d.material_id = e.material_id
		d.blurb = e.blurb
		register(d)

## Units of a raw material pressed into one brick: enough to weigh about BRICK_KG, at least one.
static func brick_cost(raw: ItemDef) -> int:
	return maxi(1, ceili(BRICK_KG / maxf(raw.unit_kg, 0.01) - 0.001))

## The brick pressed from a raw material (made and registered the first time it is asked for).
static func brick_of(raw_id: String) -> ItemDef:
	_ensure()
	var id := "brick:" + raw_id
	if _defs.has(id):
		return _defs[id]
	var raw: ItemDef = _defs.get(raw_id)
	if raw == null:
		return null
	var b := ItemDef.make(id, raw.name.replace(" ore", "") + " brick", ItemDef.BRICK, raw.unit_kg * brick_cost(raw) * raw.dry, raw.color.darkened(0.12), "brick", ["brick"])
	b.max_stack = 32
	b.material_id = raw_id
	b.blurb = "Pressed %s: compact, stackable, made to be stored." % raw.name.to_lower()
	register(b)
	return b
