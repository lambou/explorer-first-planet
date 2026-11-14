class_name KeyHints
extends Control
## Keys on the screen itself: a column of key caps with what they do (bottom left), and, over anything the player can
## collect within reach, a pulsing ring with the key to press. Display only: the Hud / Main say what to show.

const CAP := 26.0

var _keys: Array = []                  # [[key text, what it does], ...]
var _mark_on := false
var _mark_pos := Vector2.ZERO
var _mark_key := ""
var _mark_text := ""
var _t := 0.0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func set_keys(keys: Array) -> void:
	if keys != _keys:
		_keys = keys
		queue_redraw()

## A collectible is within reach: ring it at `pos` (screen) and name the key that collects it.
func show_collect(pos: Vector2, key: String, text: String) -> void:
	_mark_on = true
	_mark_pos = pos
	_mark_key = key
	_mark_text = text

func hide_collect() -> void:
	if _mark_on:
		_mark_on = false
		queue_redraw()

func _process(delta: float) -> void:
	_t += delta
	if _mark_on:
		queue_redraw()

func _draw() -> void:
	var y := size.y - 16.0
	for i in range(_keys.size() - 1, -1, -1):
		y -= CAP + 6.0
		_cap(Vector2(16, y), _keys[i][0], _keys[i][1])
	if _mark_on:
		var pulse := 0.5 + 0.5 * sin(_t * 5.0)
		draw_arc(_mark_pos, 26.0 + pulse * 5.0, 0.0, TAU, 40, Color(UiTheme.SELECTED, 0.55 + 0.4 * pulse), 3.0)
		draw_arc(_mark_pos, 18.0, 0.0, TAU, 32, Color(1, 1, 1, 0.5), 1.5)
		_cap(_mark_pos + Vector2(-CAP * 0.5, 40.0), _mark_key, _mark_text, true)

## One key cap with its label to the right (or, centred under the point, for the collect prompt).
func _cap(pos: Vector2, key: String, text: String, centred: bool = false) -> void:
	var font := UiTheme.font()
	var w := maxf(CAP, font.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 14.0)
	var r := Rect2(pos, Vector2(w, CAP))
	var label_w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	if centred:
		r.position.x = _mark_pos.x - (w + 8.0 + label_w) * 0.5
		draw_rect(Rect2(r.position - Vector2(6, 4), Vector2(w + label_w + 22.0, CAP + 8.0)), Color(0, 0, 0, 0.55))
	else:
		draw_rect(Rect2(r.position - Vector2(4, 3), Vector2(w + label_w + 20.0, CAP + 6.0)), Color(0, 0, 0, 0.42))
	draw_rect(r, UiTheme.SLOT_BG)
	draw_rect(r, UiTheme.SELECTED if centred else UiTheme.TEXT_DIM, false, 2.0)
	draw_string(font, r.position + Vector2(0, CAP * 0.5 + 5.5), key, HORIZONTAL_ALIGNMENT_CENTER, w, 15, UiTheme.TEXT)
	UiTheme.text(self, r.position + Vector2(w + 8.0, CAP * 0.5 + 5.0), text, 14, UiTheme.TEXT)
