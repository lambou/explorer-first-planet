class_name UiTheme
extends RefCounted
## The look of the survival UI in one place: colours, sizes and the few styles every panel shares.

const SLOT := 54.0
const GAP := 4.0
const PANEL := Color(0.06, 0.07, 0.09, 0.82)
const SLOT_BG := Color(0.17, 0.18, 0.21, 0.88)
const SLOT_EDGE := Color(0.32, 0.34, 0.40, 1.0)
const SELECTED := Color(1.0, 0.82, 0.35)
const TEXT := Color(0.94, 0.95, 0.97)
const TEXT_DIM := Color(0.62, 0.65, 0.72)
const GOOD := Color(0.55, 0.88, 0.5)
const WARN := Color(1.0, 0.72, 0.30)
const BAD := Color(1.0, 0.38, 0.32)

static func panel_style(margin: int = 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.set_content_margin_all(margin)
	sb.set_corner_radius_all(8)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	return sb

static func font() -> Font:
	return ThemeDB.fallback_font

## Text with a dark outline (readable over any background).
static func text(ci: CanvasItem, pos: Vector2, s: String, size: int, color: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	ci.draw_string_outline(font(), pos, s, align, width, size, 4, Color(0, 0, 0, 0.85))
	ci.draw_string(font(), pos, s, align, width, size, color)
