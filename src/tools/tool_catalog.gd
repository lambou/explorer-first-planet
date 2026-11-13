class_name ToolCatalog
extends RefCounted
## Every tool of the game. A new tool is one row here, one model from Blender, and (if it does something new) one action in ToolUser.

const BUCKET_LITRES := 10                    # what the bucket holds
const MODEL_SCALE := 1.4                    # tools are drawn a little bigger than they were built, to suit the (bigger) character
const TORCH_DIM_SECONDS := 45.0              # the last seconds of a torch: the flame sinks and the light with it
const START := ["pickaxe", "bucket"]         # what the explorer begins with

static var _defs: Dictionary = {}

static func _ensure() -> void:
	if not _defs.is_empty():
		return
	for t: ToolDef in [
		ToolDef.make("pickaxe", "Pickaxe", ToolDef.MINE, "Dig the ground, break rocks, chop trees"),
		ToolDef.make("bucket", "Bucket", ToolDef.SCOOP, "Scoop water (holds %d litres)" % BUCKET_LITRES),
		ToolDef.make("torch", "Fuel Torch", ToolDef.LIGHT, "Big torch, burns 15 minutes. [T] plants it where you point, [E] picks it up again"),
		ToolDef.make("torch_bundle", "Bundle Torch", ToolDef.LIGHT, "Small torch, burns 5 minutes. [T] plants it where you point, [E] picks it up again"),
	]:
		if t.id == "torch":
			t.burn_seconds = 900.0                        # the coal-wrapped torch: big, burns 15 minutes
		elif t.id == "torch_bundle":
			t.burn_seconds = 300.0                        # splinters bound together: small, burns 5 minutes
		_defs[t.id] = t

static func get_def(id: String) -> ToolDef:
	_ensure()
	return _defs.get(id)

static func has_tool(id: String) -> bool:
	_ensure()
	return _defs.has(id)
