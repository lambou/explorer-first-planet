class_name Recipe
extends RefCounted
## One way to make something: pure data. An ingredient is either a fixed item {"item": id, "count": n} or anything that
## carries a tag {"tag": "wood", "count": n, "label": "Any wood"}. RecipeBook turns recipes into concrete choices
## from what is carried.

const OUT_ITEM := "item"         # goes into the inventory
const OUT_TOOL := "tool"         # goes onto the tool belt

var id := ""
var name := ""
var ingredients: Array = []
var out_kind := OUT_ITEM
var out_id := ""                 # "" with `brick`: the brick of the first ingredient
var out_count := 1
var out_burn := 0.0                # burnable results: the fuel each piece starts with (seconds); 0 = full
var brick := false               # the result is the brick of whatever material the first ingredient is
var blurb := ""

static func make(p_id: String, p_name: String, p_ingredients: Array, p_out_kind: String, p_out_id: String, p_out_count: int = 1, p_blurb: String = "") -> Recipe:
	var r := Recipe.new()
	r.id = p_id
	r.name = p_name
	r.ingredients = p_ingredients
	r.out_kind = p_out_kind
	r.out_id = p_out_id
	r.out_count = p_out_count
	r.blurb = p_blurb
	return r
