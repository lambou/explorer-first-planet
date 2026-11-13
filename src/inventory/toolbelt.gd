class_name Toolbelt
extends RefCounted
## The tools the player owns and the one in hand. Tools are worn gear: they do not count against the carry weight.
## Burnable tools (torches) are pieces with their own fuel: only the piece in hand burns, a planted torch carries its
## remaining fuel with it and brings it back when picked up. Pure data: the tool bar shows it, the rig draws the tool in
## hand, ToolUser applies it.

signal changed
signal selected(tool_id: String)
signal burnt_out(tool_id: String)       # the piece in hand ran out of fuel

var tools: Array = []             # tool ids, in the order they were got
var counts := {}                  # tool id -> how many (torches come in numbers)
var fuel := {}                    # burnable tool id -> seconds left of each piece; the first is the one in hand
var index := 0

## The belt as plain data (for the save), and back.
func to_data() -> Dictionary:
	return {"tools": tools.duplicate(), "counts": counts.duplicate(), "fuel": fuel.duplicate(true), "index": index}

func from_data(d: Dictionary) -> void:
	tools = []
	counts = {}
	fuel = {}
	for id: String in d.tools:
		if ToolCatalog.has_tool(id):                      # a tool that no longer exists in the game is dropped
			tools.append(id)
			counts[id] = d.counts[id]
			if d.fuel.has(id):
				fuel[id] = (d.fuel[id] as Array).duplicate()
	index = clampi(d.index, 0, maxi(tools.size() - 1, 0))
	changed.emit()
	selected.emit(current_id())

## `burn`: the fuel each new piece starts with (burnable tools; 0 or less = a full piece).
func add(id: String, n: int = 1, burn: float = 0.0) -> void:
	if not ToolCatalog.has_tool(id):
		return
	if not counts.has(id):
		tools.append(id)
		counts[id] = 0
	counts[id] += n
	var full := ToolCatalog.get_def(id).burn_seconds
	if full > 0.0:
		if not fuel.has(id):
			fuel[id] = []
		for i in n:
			fuel[id].append(minf(burn, full) if burn > 0.0 else full)
	changed.emit()

## Use up `n` pieces (a planted torch). The last one leaves the belt, and the next tool is taken in hand.
func remove(id: String, n: int = 1) -> void:
	if not counts.has(id):
		return
	counts[id] -= n
	if fuel.has(id):
		for i in mini(n, fuel[id].size()):
			fuel[id].pop_front()
	if counts[id] > 0:
		changed.emit()
		return
	var was_current: bool = tools[index] == id
	var pos := tools.find(id)
	counts.erase(id)
	fuel.erase(id)
	tools.remove_at(pos)
	if pos < index:
		index -= 1
	index = clampi(index, 0, maxi(tools.size() - 1, 0))
	changed.emit()
	if was_current:
		selected.emit(current_id())

## Fuel left (seconds) in the piece of `id` in hand, or -1 for a tool that does not burn.
func fuel_left(id: String) -> float:
	if not fuel.has(id) or fuel[id].is_empty():
		return -1.0
	return fuel[id][0]

## The piece in hand burns (only if it is a burnable tool). Returns true when it ran out and is gone.
func burn_held(dt: float) -> bool:
	var id := current_id()
	if not fuel.has(id) or fuel[id].is_empty():
		return false
	fuel[id][0] -= dt
	if fuel[id][0] > 0.0:
		return false
	remove(id)
	burnt_out.emit(id)
	return true

## The torch [T] plants: the one in hand if it is a torch, else the first torch on the belt. "" when there is none.
func torch_to_plant() -> String:
	var cur := current_id()
	if cur != "" and ToolCatalog.get_def(cur).action == ToolDef.LIGHT:
		return cur
	for id: String in tools:
		if ToolCatalog.get_def(id).action == ToolDef.LIGHT:
			return id
	return ""

func count_of(id: String) -> int:
	return counts.get(id, 0)

func current_id() -> String:
	return tools[index] if not tools.is_empty() else ""

func current() -> ToolDef:
	return ToolCatalog.get_def(current_id())

func select(i: int) -> void:
	if i < 0 or i >= tools.size():
		return
	index = i
	selected.emit(tools[i])
	changed.emit()

func select_id(id: String) -> void:
	select(tools.find(id))

func cycle(dir: int = 1) -> void:
	if tools.size() > 1:
		select(posmod(index + dir, tools.size()))
