class_name Crafter
extends RefCounted
## Makes one craft chosen from RecipeBook.options: takes the ingredients, gives the result. All or nothing: a result
## that is too heavy to carry puts everything back.

## Returns {"ok": bool, "msg": text}.
static func craft(c: Dictionary, inv: Inventory, belt: Toolbelt) -> Dictionary:
	if not c.can:
		return {"ok": false, "msg": "Missing ingredients"}
	var taken: Array = []
	for ing: Dictionary in c.inputs:
		inv.remove(ing.id, ing.count)
		taken.append(ing)
	if c.out_kind == Recipe.OUT_TOOL:
		belt.add(c.out_id, c.out_count, c.out_burn)
		return {"ok": true, "msg": "Made %s x%d" % [ToolCatalog.get_def(c.out_id).name, c.out_count]}
	var got := inv.add(c.out_id, c.out_count)
	if got < c.out_count:
		if got > 0:
			inv.remove(c.out_id, got)
		for ing2: Dictionary in taken:
			inv.add(ing2.id, ing2.count)
		return {"ok": false, "msg": "Too heavy to carry"}
	return {"ok": true, "msg": "Made %s x%d" % [ItemCatalog.get_def(c.out_id).name, c.out_count]}
