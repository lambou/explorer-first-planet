class_name ItemDef
extends RefCounted
## One kind of carried thing: pure data (no nodes, no world). The catalog (ItemCatalog) keeps them; the harvest
## layer makes the ones that depend on the world (a rock type, a wood); the inventory only counts them.

const RESOURCE := "resource"     # raw material: clay, sand, a rock type, a wood
const BRICK := "brick"           # a raw material pressed into a storable block
const LIQUID := "liquid"         # carried in the bucket

var id := ""                     # "clay", "rock:granite", "wood:Oak wood", "brick:clay"
var name := ""
var kind := RESOURCE
var unit_kg := 1.0               # weight of one unit
var max_stack := 64
var color := Color.GRAY
var shape := "lump"              # how the icon is drawn (see ItemIcon): lump, gem, pile, log, brick, drop
var tags := PackedStringArray()  # what recipes ask for: "wood", "brickable", "flammable" ...
var dry := 1.0                   # bricks only: the share of the weight kept when a brick is pressed from this material
var material_id := ""            # bricks only: the raw material it is made of
var blurb := ""

static func make(p_id: String, p_name: String, p_kind: String, p_kg: float, p_color: Color, p_shape: String, p_tags: Array = []) -> ItemDef:
	var d := ItemDef.new()
	d.id = p_id
	d.name = p_name
	d.kind = p_kind
	d.unit_kg = p_kg
	d.color = p_color
	d.shape = p_shape
	d.tags = PackedStringArray(p_tags)
	return d

func has_tag(t: String) -> bool:
	return tags.has(t)
