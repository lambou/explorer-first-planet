class_name Inventory
extends RefCounted
## What the player carries: a row of slots holding stacks, and a weight limit. Pure data + rules (no nodes, no world):
## the UI shows it, the harvest and crafting layers fill and empty it. A stack is {"id": item id, "count": units}; an
## empty slot is {}.

signal changed

const SLOTS := 27                 # 3 rows of 9; the first row is the bar at the bottom of the screen
const CAPACITY_KG := 100.0        # the most the player can carry

var capacity_kg := CAPACITY_KG
var slots: Array = []

func _init(p_slots: int = SLOTS, p_capacity_kg: float = CAPACITY_KG) -> void:
	capacity_kg = p_capacity_kg
	for i in p_slots:
		slots.append({})

## The slots as plain data (for the save), and back.
func to_data() -> Array:
	return slots.duplicate(true)

func from_data(d: Array) -> void:
	for i in slots.size():
		slots[i] = (d[i] as Dictionary).duplicate() if i < d.size() else {}
	changed.emit()

func weight() -> float:
	var w := 0.0
	for s: Dictionary in slots:
		if not s.is_empty():
			w += float(s.count) * ItemCatalog.get_def(s.id).unit_kg
	return w

func free_kg() -> float:
	return maxf(0.0, capacity_kg - weight())

func count_of(id: String) -> int:
	var n := 0
	for s: Dictionary in slots:
		if not s.is_empty() and s.id == id:
			n += s.count
	return n

## Ids of the held items that carry `tag`, the most plentiful first.
func items_with_tag(tag: String) -> Array:
	var counts := {}
	for s: Dictionary in slots:
		if s.is_empty():
			continue
		var d := ItemCatalog.get_def(s.id)
		if d.has_tag(tag):
			counts[s.id] = counts.get(s.id, 0) + s.count
	var ids := counts.keys()
	ids.sort_custom(func(a: String, b: String) -> bool: return counts[a] > counts[b] or (counts[a] == counts[b] and a < b))
	return ids

## How many units of `id` fit right now: limited by the weight left and by the room in the slots.
func room_for(id: String) -> int:
	var d := ItemCatalog.get_def(id)
	if d == null:
		return 0
	var by_weight := 1 << 30 if d.unit_kg <= 0.0 else int(floor((free_kg() + 1e-4) / d.unit_kg))
	var by_slots := 0
	for s: Dictionary in slots:
		if s.is_empty():
			by_slots += d.max_stack
		elif s.id == id:
			by_slots += d.max_stack - s.count
	return mini(by_weight, by_slots)

## Put units in. Returns how many went in (the rest was too heavy, or there was no room).
func add(id: String, n: int) -> int:
	var k := mini(n, room_for(id))
	if k <= 0:
		return 0
	var d := ItemCatalog.get_def(id)
	var left := k
	for s: Dictionary in slots:
		if left > 0 and not s.is_empty() and s.id == id and s.count < d.max_stack:
			var put := mini(left, d.max_stack - s.count)
			s.count += put
			left -= put
	for i in slots.size():
		if left > 0 and (slots[i] as Dictionary).is_empty():
			var put2 := mini(left, d.max_stack)
			slots[i] = {"id": id, "count": put2}
			left -= put2
	changed.emit()
	return k

## Take units out (all or nothing). The smallest stacks go first.
func remove(id: String, n: int) -> bool:
	if count_of(id) < n:
		return false
	var left := n
	var order: Array = []
	for i in slots.size():
		var s: Dictionary = slots[i]
		if not s.is_empty() and s.id == id:
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return slots[a].count < slots[b].count)
	for i: int in order:
		if left <= 0:
			break
		var s2: Dictionary = slots[i]
		var take := mini(left, s2.count)
		s2.count -= take
		left -= take
		if s2.count <= 0:
			slots[i] = {}
	changed.emit()
	return true

## A click on slot `i` while holding `held` (a stack or {}): returns what is held afterwards. Same item merges,
## different items swap, an empty hand takes the stack.
func click_slot(i: int, held: Dictionary) -> Dictionary:
	var s: Dictionary = slots[i]
	var out := {}
	if held.is_empty():
		out = s
		slots[i] = {}
	elif s.is_empty():
		slots[i] = held
	elif s.id == held.id:
		var d := ItemCatalog.get_def(s.id)
		var put := mini(held.count, d.max_stack - s.count)
		s.count += put
		if held.count > put:
			out = {"id": held.id, "count": held.count - put}
	else:
		slots[i] = held
		out = s
	changed.emit()
	return out
