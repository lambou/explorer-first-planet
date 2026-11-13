class_name ToolUser
extends RefCounted
## What a tool DOES at what it points at: the world changes (dig, break, chop, scoop) and the harvest goes to the
## inventory. Not drawing (ToolRig animates the tool), not input (main decides when), not aiming (ToolAim picks the target).
## `target` is a ToolAim target: {kind: "ground" | "rock" | "tree" | "none", point, normal, in_reach, ...}.

var world: VoxelWorld
var gen: PlanetGenerator
var debris: RockDebris
var physics: RockPhysics
var tree_fall: TreePhysics
var kit: PlayerKit
var torches: PlacedTorches

## Can this tool do anything at this target? {"ok": bool, "msg": what to tell the player when not}.
func check(tool: ToolDef, target: Dictionary) -> Dictionary:
	if target.kind == "none":
		return {"ok": false, "msg": ""}
	if not target.in_reach:
		return {"ok": false, "msg": "Out of reach"}
	if tool.action == ToolDef.LIGHT and not torches.can_place(target.point, target.normal):
		return {"ok": false, "msg": "It will not stand on a ceiling"}
	if tool.action == ToolDef.SCOOP:
		if world.submersion(target.point) <= 0.05:
			return {"ok": false, "msg": "No water there"}
		if kit.inventory.count_of("water") >= ToolCatalog.BUCKET_LITRES:
			return {"ok": false, "msg": "The bucket is full"}
	return {"ok": true, "msg": ""}

## One use of the tool. `place`: (pickaxe) put stone there instead. Returns a short description (debug output).
func use(tool_id: String, t: Dictionary, from: Vector3, place: bool = false) -> String:
	if t.kind == "none" or not t.in_reach:
		return "out of reach" if t.kind != "none" else "nothing"
	match ToolCatalog.get_def(tool_id).action:
		ToolDef.SCOOP:
			return _scoop(t)
		ToolDef.MINE:
			return _mine(t, from, place)
		ToolDef.LIGHT:
			return plant_torch(t)
	return "nothing"

func _scoop(t: Dictionary) -> String:
	if world.submersion(t.point) <= 0.05:
		return "no water"
	var room := ToolCatalog.BUCKET_LITRES - kit.inventory.count_of("water")
	var got := kit.harvester.collect("water", mini(room, SCOOP_LITRES))
	return "scooped %d l" % got

## Stick a torch from the belt into what the tool points at (works with any tool in hand: [T]).
func plant_torch(t: Dictionary) -> String:
	var id := kit.belt.torch_to_plant()
	if id == "":
		return "no torch"
	if t.kind == "none" or not t.in_reach or not torches.place(t.point, t.normal, kit.belt.fuel_left(id), id):
		return "cannot place"
	kit.belt.remove(id)                                      # the piece goes into the ground with the fuel it has left
	return "planted a torch"

const SCOOP_LITRES := 5

## A rock is bitten into (it loses its shell, then breaks), a tree is notched and felled, a felled trunk is chopped,
## otherwise the ground is dug.
func _mine(t: Dictionary, from: Vector3, place: bool) -> String:
	if place:
		world.fill(t.point + t.normal * 1.2, 1.8, BlockTypes.STONE)
		return "placed"
	if t.kind == "tree":
		var tres := world.hit_tree(t, from)
		var tn: int = {"hit": 9, "fell": 14, "chop": 10, "gone": 14}[tres.event]
		debris.burst(t.point, t.normal, tres.colors, tn, 0.12 + 0.08 * t.tree.trunk_r)
		if tres.event == "fell":
			tree_fall.start_fall(t.tree, t.chunk, tres.dir)
		kit.harvester.from_tree(tres)
		return "%s %s (%d units)" % [tres.event, tres.wood, tres.units]
	if t.kind == "rock":
		var res := world.hit_rock(t)
		var n: int = {"hit": 2, "shed": 7, "broken": 11}[res.event]
		n = int(n * (1.0 + t.rock.size))              # a big rock throws more pieces
		debris.burst(t.point, t.normal, res.colors, n, 0.10 + 0.07 * t.rock.size)
		kit.harvester.from_rock(res)
		if res.event != "broken":
			physics.check_rock(t.rock, t.chunk)               # what is left must still rest on something, or it falls
		physics.check_around(t.rock.pos, t.rock.size * 1.75 + 0.3, t.rock)      # the rocks that lay on it may have lost their support
		return "%s %s (%d units)" % [res.event, res.type, res.units]
	var item := kit.harvester.from_ground(t.point)
	world.carve(t.point, ToolAim.GROUND_RADIUS)
	_ground_debris(t.point)
	return "dug " + item

## Pieces of ground flying off where the terrain is dug (they vanish; the dug hole is the real change).
func _ground_debris(p: Vector3) -> void:
	var d := p.normalized()
	var col := Column.new()
	gen.sample_column(d, col)
	var alt := p.length() - WorldConfig.PLANET_RADIUS
	var ground_col: Color = gen.surface.color_for(col) if alt > col.height - 3.0 else BlockTypes.COLORS[BlockTypes.STONE]
	debris.burst(p, d, [ground_col, ground_col.darkened(0.2), BlockTypes.COLORS[BlockTypes.STONE]], 6, 0.16)
