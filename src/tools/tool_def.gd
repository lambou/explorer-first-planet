class_name ToolDef
extends RefCounted
## One tool the player can hold: pure data. The model and the icon come from Blender (tools/blender/build_tools.py);
## `action` says what the tool does when used (ToolUser does it, ToolRig animates it).

const MINE := "mine"             # dig the ground, break rocks, chop trees
const SCOOP := "scoop"           # take water
const LIGHT := "light"           # burns: lights the way, nothing to strike

var id := ""
var name := ""
var action := MINE
var model_path := ""
var icon_path := ""
var hint := ""
var burn_seconds := 0.0           # burnable tools (torches): the most fuel one piece holds; 0 = lasts forever

static func make(p_id: String, p_name: String, p_action: String, p_hint: String) -> ToolDef:
	var t := ToolDef.new()
	t.id = p_id
	t.name = p_name
	t.action = p_action
	t.hint = p_hint
	t.model_path = "res://assets/tools/%s.glb" % p_id
	t.icon_path = "res://assets/icons/%s.png" % p_id
	return t
