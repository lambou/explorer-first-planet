class_name PlayerKit
extends RefCounted
## Everything the explorer owns, as plain data: what is carried (with its weight limit), the tools, and how things are
## gathered. The UI shows it, ToolUser and crafting change it, main only wires it. No nodes, so it is testable headless.

signal bar_slot_changed
signal torch_burnt_out

var inventory := Inventory.new()
var belt := Toolbelt.new()
var harvester: Harvester
var bar_slot := 0                       # the selected slot of the bar at the bottom (the first row of the inventory)

func _init() -> void:
	harvester = Harvester.new(inventory)
	for id: String in ToolCatalog.START:
		belt.add(id)

## Time passes: the torch in hand burns down.
func update(delta: float) -> void:
	if belt.burn_held(delta):
		torch_burnt_out.emit()

func select_bar_slot(i: int) -> void:
	bar_slot = clampi(i, 0, 8)
	bar_slot_changed.emit()

## How full the bucket is, 0..1 (its water is carried like anything else and counts against the weight).
func bucket_fill() -> float:
	return clampf(float(inventory.count_of("water")) / ToolCatalog.BUCKET_LITRES, 0.0, 1.0)
