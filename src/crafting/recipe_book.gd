class_name RecipeBook
extends RefCounted
## All the recipes, and what can be made from what is carried. `options` gives one "craft" per concrete choice:
## a brick of each brickable material held, a torch from the wood and fuel held. A craft whose ingredients are not held
## is still listed (greyed in the menu) so the player can see what to look for.
##
## A craft is {"recipe", "name", "inputs": [{"id", "label", "count", "have"}], "out_kind", "out_id", "out_count", "can", "blurb"}.

static var _recipes: Array = []

static func all() -> Array:
	if _recipes.is_empty():
		var brick := Recipe.make("brick", "Brick", [{"tag": "brickable", "count": 4, "label": "Clay or stone"}],
			Recipe.OUT_ITEM, "", 1, "Press raw material into a block that can be stored.")
		brick.brick = true
		_recipes = [
			brick,
			Recipe.make("torch_fuel", "Fuel Torch (15 min)", [{"tag": "wood", "count": 1, "label": "Any wood"}, {"tag": "flammable", "count": 1, "label": "Coal or sulfur"}],
				Recipe.OUT_TOOL, "torch", 2, "A stick wrapped with coal: burns 15 minutes."),
			Recipe.make("torch_bundle", "Bundle Torch (5 min)", [{"tag": "wood", "count": 3, "label": "Any wood"}],
				Recipe.OUT_TOOL, "torch_bundle", 1, "Splinters bound together: no fuel needed, but it burns only 5 minutes."),
		]
		_recipes[1].out_burn = 900.0
		_recipes[2].out_burn = 300.0
	return _recipes

static func options(inv: Inventory) -> Array:
	var out: Array = []
	for r: Recipe in all():
		var first: Dictionary = r.ingredients[0]
		var variants: Array = [""]
		if r.brick and first.has("tag"):
			var held := inv.items_with_tag(first.tag)
			if not held.is_empty():
				variants = held                    # one brick per material held
		for v: String in variants:
			out.append(_resolve(r, inv, v))
	return out

static func _resolve(r: Recipe, inv: Inventory, first_choice: String) -> Dictionary:
	var inputs: Array = []
	var can := true
	for k in r.ingredients.size():
		var ing: Dictionary = r.ingredients[k]
		var id := ""
		if ing.has("item"):
			id = ing.item
		elif k == 0 and first_choice != "":
			id = first_choice
		else:
			var held := inv.items_with_tag(ing.tag)
			if not held.is_empty():
				id = held[0]
		var have := inv.count_of(id) if id != "" else 0
		var label: String = ing.get("label", "")
		var need := int(ing.count)
		if id != "":
			label = ItemCatalog.get_def(id).name
			if r.brick and k == 0:
				need = ItemCatalog.brick_cost(ItemCatalog.get_def(id))      # a brick takes about 6 kg of the material: heavy ores need fewer units
		if have < need:
			can = false
		inputs.append({"id": id, "label": label, "count": need, "have": have})
	var out_id := r.out_id
	var name := r.name
	if r.brick:
		var src: String = inputs[0].id
		if src != "":
			var b := ItemCatalog.brick_of(src)
			out_id = b.id
			name = b.name
	return {"recipe": r, "name": name, "inputs": inputs, "out_kind": r.out_kind, "out_id": out_id,
		"out_count": r.out_count, "out_burn": r.out_burn, "can": can, "blurb": r.blurb}
