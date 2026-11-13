class_name ItemIcon
extends RefCounted
## Draws the picture of an item (from its shape and colour) into a rectangle of any CanvasItem. Display only. Tools
## have real pictures rendered in Blender (see ToolBar); the carried things are simple drawn shapes, so a new rock type
## or wood needs no art.

static func draw(ci: CanvasItem, rect: Rect2, def: ItemDef) -> void:
	var c := def.color
	var edge := c.darkened(0.55)
	var light := c.lightened(0.35)
	match def.shape:
		"gem":
			_poly(ci, rect, [[0.5, 0.08], [0.82, 0.34], [0.5, 0.92], [0.18, 0.34]], c, edge)
			_poly(ci, rect, [[0.5, 0.08], [0.82, 0.34], [0.5, 0.40], [0.18, 0.34]], light, edge)
		"pile":
			_poly(ci, rect, [[0.08, 0.80], [0.30, 0.50], [0.46, 0.30], [0.62, 0.46], [0.90, 0.80]], c, edge)
			_poly(ci, rect, [[0.30, 0.50], [0.46, 0.30], [0.50, 0.55]], light, light)
		"log":
			_poly(ci, rect, [[0.10, 0.38], [0.74, 0.30], [0.74, 0.72], [0.10, 0.80]], c, edge)
			_poly(ci, rect, [[0.74, 0.30], [0.90, 0.40], [0.90, 0.62], [0.74, 0.72]], Color(0.86, 0.72, 0.5), edge)
			_poly(ci, rect, [[0.10, 0.38], [0.74, 0.30], [0.74, 0.40], [0.10, 0.48]], light, light)
		"brick":
			_poly(ci, rect, [[0.10, 0.42], [0.62, 0.42], [0.62, 0.78], [0.10, 0.78]], c, edge)
			_poly(ci, rect, [[0.10, 0.42], [0.30, 0.24], [0.82, 0.24], [0.62, 0.42]], light, edge)
			_poly(ci, rect, [[0.62, 0.42], [0.82, 0.24], [0.82, 0.60], [0.62, 0.78]], c.darkened(0.25), edge)
		"drop":
			_poly(ci, rect, [[0.5, 0.08], [0.72, 0.46], [0.74, 0.62], [0.62, 0.82], [0.38, 0.82], [0.26, 0.62], [0.28, 0.46]], c, edge)
			_poly(ci, rect, [[0.40, 0.50], [0.46, 0.40], [0.44, 0.66]], light, light)
		_:                                                            # "lump": a rough stone
			_poly(ci, rect, [[0.12, 0.66], [0.20, 0.38], [0.44, 0.22], [0.74, 0.30], [0.90, 0.56], [0.80, 0.80], [0.30, 0.84]], c, edge)
			_poly(ci, rect, [[0.20, 0.38], [0.44, 0.22], [0.74, 0.30], [0.58, 0.44], [0.34, 0.50]], light, light)

static func _poly(ci: CanvasItem, rect: Rect2, pts: Array, fill: Color, edge: Color) -> void:
	var p := PackedVector2Array()
	for q: Array in pts:
		p.append(rect.position + Vector2(q[0] * rect.size.x, q[1] * rect.size.y))
	ci.draw_colored_polygon(p, fill)
	p.append(p[0])
	ci.draw_polyline(p, edge, 1.5, true)
