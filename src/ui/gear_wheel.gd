class_name GearWheel
extends Control
## The quick gear menu (hold [G], like Resident Evil 4's item wheel): the tools in a ring around the screen centre. Point at one
## and release [G] (or click it) to take it in hand. The mouse is free while it is open, so nothing is swung.
## Display and choice only: it reads the Toolbelt and tells whoever owns it which tool was picked.

signal picked(index: int)

const RING := 130.0                   # distance of the tool icons from the centre
const ICON := 78.0
const DEAD := 44.0                    # inside this radius nothing is chosen

var _belt: Toolbelt
var _hover := -1
var _warped := false

func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)

func bind(belt: Toolbelt) -> void:
	_belt = belt

func open() -> void:
	_hover = -1
	_warped = false
	visible = true
	queue_redraw()

## Leaves the wheel; `choose` takes the pointed-at tool (key released or click) instead of leaving the hand as it was.
func close(choose: bool) -> void:
	if not visible:
		return
	visible = false
	if choose and _hover >= 0:
		picked.emit(_hover)

func _centre() -> Vector2:
	return size * 0.5

func _process(_delta: float) -> void:
	if not visible or _belt == null:
		return
	if not _warped and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.warp_mouse(_centre())                     # start from the middle: the first nudge picks a direction
		_warped = true
	var h := _sector_at(get_local_mouse_position()) if _warped else -1
	if h != _hover:
		_hover = h
		queue_redraw()

func _sector_at(p: Vector2) -> int:
	var n := _belt.tools.size()
	var off := p - _centre()
	if n == 0 or off.length() < DEAD:
		return -1
	var a := fposmod(atan2(off.x, -off.y), TAU)         # 0 = straight up, clockwise
	return int(round(a / (TAU / n))) % n

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_LEFT:
			close(true)
		elif e.button_index == MOUSE_BUTTON_RIGHT:
			close(false)
		accept_event()

func _draw() -> void:
	if _belt == null:
		return
	var c := _centre()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.5))
	draw_circle(c, RING + ICON * 0.8, Color(0.05, 0.06, 0.08, 0.72))
	draw_arc(c, RING + ICON * 0.8, 0.0, TAU, 64, Color(1, 1, 1, 0.12), 2.0)
	var n := _belt.tools.size()
	for i in n:
		var def := ToolCatalog.get_def(_belt.tools[i])
		var ang := TAU * i / n
		var pos := c + Vector2(sin(ang), -cos(ang)) * RING
		var r := Rect2(pos - Vector2(ICON, ICON) * 0.5, Vector2(ICON, ICON))
		var hot := i == _hover
		var held := i == _belt.index
		draw_rect(r, UiTheme.SLOT_BG)
		draw_rect(r, UiTheme.SELECTED if hot else (UiTheme.TEXT_DIM if held else UiTheme.SLOT_EDGE), false, 4.0 if hot else (2.0 if held else 1.0))
		draw_texture_rect(load(def.icon_path) as Texture2D, r.grow(-3.0), false)
		var cnt := _belt.count_of(def.id)
		if cnt > 1:
			UiTheme.text(self, r.position + Vector2(0, ICON - 5), str(cnt), 14, UiTheme.TEXT, HORIZONTAL_ALIGNMENT_RIGHT, ICON - 5)
	var shown := _hover if _hover >= 0 else _belt.index
	if shown >= 0 and shown < n:
		var d := ToolCatalog.get_def(_belt.tools[shown])
		UiTheme.text(self, c + Vector2(-120, -6), d.name, 20, UiTheme.SELECTED if _hover >= 0 else UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER, 240)
		UiTheme.text(self, c + Vector2(-120, 18), d.hint, 12, UiTheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, 240)
	UiTheme.text(self, c + Vector2(-200, RING + ICON + 24), "Point and release [G] / click to equip   -   right click or Esc to cancel", 12, UiTheme.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER, 400)
