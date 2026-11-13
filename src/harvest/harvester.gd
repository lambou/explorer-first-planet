class_name Harvester
extends RefCounted
## The bridge between the world and the inventory: turns what a blow yields (a rock type, a wood, the ground under a
## dig) into items and puts them in the inventory, as much as the player can carry. The world systems report; this decides
## what the report is worth. Items that depend on the world (a rock type, a wood) are registered here the first time they come up.
##
## What is carried is heavy: weights per unit are set here (rock by its density, wood by its hardness, ground by its kind).

signal gathered(item_id: String, added: int, wanted: int)      # added < wanted: the rest was too heavy to carry

const DIG_UNITS := 2                  # units of ground one dig yields
const ROCK_KG_BASE := 0.6             # a unit of rock weighs this + density x ROCK_KG_PER_DENSITY (granite 1.5 kg, gold 7.4 kg)
const ROCK_KG_PER_DENSITY := 0.35
const WOOD_KG_BASE := 0.6             # a unit of wood weighs this + hardness x WOOD_KG_PER_HARDNESS
const WOOD_KG_PER_HARDNESS := 0.4

var inventory: Inventory
var gen: PlanetGenerator
var rocks: RockSystem
var trees: TreeSystem

func _init(p_inventory: Inventory) -> void:
	inventory = p_inventory

func bind_world(p_gen: PlanetGenerator, p_rocks: RockSystem, p_trees: TreeSystem) -> void:
	gen = p_gen
	rocks = p_rocks
	trees = p_trees

## Units into the inventory (as many as fit). Returns how many went in.
func collect(item_id: String, n: int) -> int:
	if n <= 0:
		return 0
	var added := inventory.add(item_id, n)
	gathered.emit(item_id, added, n)
	return added

## A blow on a rock reported {"type": rock key, "units": n}.
func from_rock(res: Dictionary) -> int:
	if res.units <= 0:
		return 0
	return collect(rock_item(res.type).id, res.units)

## A blow on a trunk reported {"type": species key, "units": n}.
func from_tree(res: Dictionary) -> int:
	if res.units <= 0:
		return 0
	return collect(wood_item(res.type).id, res.units)

## One dig at `point`: what the ground there is made of. Soil gives clay, sand and gravel give themselves,
## snow gives snow, and rock below the soil gives the rock of that region. Returns the item id.
func from_ground(point: Vector3) -> String:
	var id := "clay"
	match GroundYield.block_at(gen, point):
		BlockTypes.SAND: id = "sand"
		BlockTypes.GRAVEL: id = "gravel"
		BlockTypes.SNOW: id = "snow"
		BlockTypes.STONE: id = rock_item(rocks.field.base_at(point.normalized()).key).id
	collect(id, DIG_UNITS)
	return id

func rock_item(key: String) -> ItemDef:
	var id := "rock:" + key
	if ItemCatalog.has_item(id):
		return ItemCatalog.get_def(id)
	var t := rocks.catalog.get_type(key)
	var tags: Array = ["rock", t.family]
	if t.family == RockType.FAMILY_STONE or t.family == RockType.FAMILY_ORE or t.family == RockType.FAMILY_EXOTIC:
		tags.append("brickable")
	if float(t.traits.get("flammable", 0.0)) >= 0.5:
		tags.append("flammable")
	var d := ItemDef.make(id, t.name, ItemDef.RESOURCE, ROCK_KG_BASE + ROCK_KG_PER_DENSITY * t.density, t.color,
		"gem" if t.family == RockType.FAMILY_GEM else "lump", tags)
	d.blurb = "%s, %s." % [t.name, t.family]
	ItemCatalog.register(d)
	return d

func wood_item(key: String) -> ItemDef:
	var ty := trees.catalog.get_type(key)
	var id := "wood:" + ty.wood
	if ItemCatalog.has_item(id):
		return ItemCatalog.get_def(id)
	var d := ItemDef.make(id, ty.wood, ItemDef.RESOURCE, WOOD_KG_BASE + WOOD_KG_PER_HARDNESS * ty.hardness, ty.bark, "log", ["wood"])
	d.blurb = "Cut logs. Good for tools and torches."
	ItemCatalog.register(d)
	return d
