class_name Radar
extends Control
## A small globe in the corner of the screen: the planet as seen from space (continents, oceans,
## ice), always turned so the point you stand on faces you. A marker shows your position, an arrow
## your heading, N is the direction of the north pole, and the sun lights the globe: a dark night side, an
## orange sunrise / sunset line and a small sun where it is overhead (so you see where it is day, where
## it is night, and the polar day / night of the tilted planet).
## Zoom ([+] / [-]): the camera flies down towards the ground, and a detailed relief map of the
## area around you (made on a worker thread) is blended into the globe, so zooming shows real
## detail, not a blown-up picture. Display only: it reads the world generator, never changes it.

const SIZE := 190
const MAP_W := 256
const MAP_H := 128
const LOCAL_PX := 256
const FOV := 34.0

# camera distances (globe radius = 1) of the zoom levels and their names
const ZOOM_DIST := [3.4, 2.2, 1.6, 1.25]
const ZOOM_NAME := ["World", "Continent", "Region", "Local"]

const SHADER := """
shader_type spatial;
render_mode unshaded;
uniform sampler2D map : filter_linear, repeat_enable;
uniform sampler2D local_map : filter_linear, repeat_disable;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform vec3 c_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 c_right = vec3(1.0, 0.0, 0.0);
uniform vec3 c_up = vec3(0.0, 0.0, 1.0);
uniform float local_span = 0.0;     // radians covered by the detailed map (0 = none yet)
varying vec3 wn;
void vertex() {
	wn = NORMAL;
}
void fragment() {
	vec3 n = normalize(wn);
	vec3 c = texture(map, UV).rgb;
	if (local_span > 0.0) {
		float cd = clamp(dot(n, c_dir), -1.0, 1.0);
		float th = acos(cd);
		if (th < local_span) {
			vec3 t = n - c_dir * cd;
			float tl = length(t);
			vec2 q = vec2(0.0);
			if (tl > 0.00001) {
				t /= tl;
				q = vec2(dot(t, c_right), dot(t, c_up)) * (th / local_span);
			}
			vec3 lc = texture(local_map, vec2(0.5 + 0.5 * q.x, 0.5 - 0.5 * q.y)).rgb;
			c = mix(c, lc, 1.0 - smoothstep(0.85, 1.0, th / local_span));
		}
	}
	// day / night: the sunlit half is bright, the dark half is deep blue-black, with an orange band along the
	// terminator (sunrise / sunset line). Under the zenith sun the globe is at its brightest.
	float sd = dot(n, sun_dir);
	float lit = smoothstep(-0.04, 0.10, sd);
	float twilight = exp(-pow(sd / 0.10, 2.0));
	vec3 day_col = c * (0.78 + 0.22 * clamp(sd, 0.0, 1.0));
	vec3 night_col = c * vec3(0.10, 0.12, 0.22) + vec3(0.004, 0.006, 0.02);
	vec3 col = mix(night_col, day_col, lit);
	col = mix(col, col * vec3(1.35, 0.85, 0.55) + vec3(0.10, 0.04, 0.0), twilight * 0.55);
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = col + vec3(0.25, 0.45, 0.9) * rim * 0.5 * (0.35 + 0.65 * lit);
}
"""

var _vp: SubViewport
var _cam: Camera3D
var _marker: MeshInstance3D
var _sun_marker: MeshInstance3D       # the point of the globe where the sun is overhead
var _mat: ShaderMaterial
var _label: Label
var _overlay: Control        # ring, N and heading arrow: a child drawn above the globe
var _heading := 0.0
var _pulse := 0.0
var _up := Vector3.UP
var _gen: PlanetGenerator
var _mutex := Mutex.new()

var _map_image: Image
var _map_ready := false

var zoom_level := 0
var _dist := 3.4                    # displayed camera distance (eases towards the level's distance)
var _pos := Vector3.ZERO

# detailed map: what is on the GPU, what is being made, what is wanted
var _local_has := false
var _local_center := Vector3.UP
var _local_span := 0.0
var _local_level := -1
var _local_busy := false
var _local_result: Dictionary = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(SIZE, SIZE + 38)
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	offset_left = -(SIZE + 16)
	offset_top = -(SIZE + 38 + 16)
	offset_right = -16
	offset_bottom = -16

	# a round panel clips the view to a circle (zoomed in, the globe fills the whole square)
	var disc := Panel.new()
	disc.size = Vector2(SIZE, SIZE)
	disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var round := StyleBoxFlat.new()
	round.bg_color = Color(0, 0, 0, 1)        # only the shape matters (clip mask)
	round.set_corner_radius_all(SIZE / 2)
	disc.add_theme_stylebox_override("panel", round)
	disc.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	add_child(disc)
	var holder := SubViewportContainer.new()
	holder.stretch = true
	holder.size = Vector2(SIZE, SIZE)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.add_child(holder)
	_vp = SubViewport.new()
	_vp.own_world_3d = true            # its own little world, separate from the game
	_vp.transparent_bg = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.size = Vector2i(SIZE, SIZE)
	holder.add_child(_vp)

	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	var globe := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 96
	sm.rings = 48
	globe.mesh = sm
	globe.material_override = _mat
	_vp.add_child(globe)

	_marker = MeshInstance3D.new()
	var mm := SphereMesh.new()
	mm.radius = 0.04
	mm.height = 0.08
	_marker.mesh = mm
	var mk := StandardMaterial3D.new()
	mk.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mk.albedo_color = Color(1.0, 0.85, 0.1)
	_marker.material_override = mk
	_vp.add_child(_marker)

	_sun_marker = MeshInstance3D.new()
	var sm2 := SphereMesh.new()
	sm2.radius = 0.05
	sm2.height = 0.10
	_sun_marker.mesh = sm2
	var smk := StandardMaterial3D.new()
	smk.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smk.albedo_color = Color(1.0, 0.98, 0.7)
	smk.emission_enabled = true
	smk.emission = Color(1.0, 0.9, 0.4)
	_sun_marker.material_override = smk
	_vp.add_child(_sun_marker)

	_cam = Camera3D.new()
	_cam.fov = FOV
	_cam.near = 0.05
	_cam.far = 20.0
	_vp.add_child(_cam)
	_cam.current = true

	_label = Label.new()
	_label.position = Vector2(0, SIZE + 2)
	_label.size = Vector2(SIZE, 36)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label)

	_overlay = Control.new()
	_overlay.size = Vector2(SIZE, SIZE)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

func _unhandled_input(event: InputEvent) -> void:
	# mouse wheel: up = zoom in, down = zoom out (hold Ctrl for the camera distance instead)
	if event is InputEventMouseButton and event.pressed and not event.ctrl_pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_level = mini(zoom_level + 1, ZOOM_DIST.size() - 1)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_level = maxi(zoom_level - 1, 0)
			get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_EQUAL, KEY_KP_ADD:
				zoom_level = mini(zoom_level + 1, ZOOM_DIST.size() - 1)
			KEY_MINUS, KEY_KP_SUBTRACT:
				zoom_level = maxi(zoom_level - 1, 0)

## Starts drawing the world map on a worker thread (about half a second), then shows it.
func setup(gen: PlanetGenerator) -> void:
	_gen = gen
	WorkerThreadPool.add_task(_build_task.bind(gen))

func _build_task(gen: PlanetGenerator) -> void:
	var img := build_map(gen, MAP_W, MAP_H)
	_mutex.lock()
	_map_image = img
	_map_ready = true
	_mutex.unlock()

# ---------------------------------------------------------------- maps

## Equirectangular map of the planet: pixel column x <-> the angle theta = 2 pi x / w around the
## pole axis (matching the UV layout of Godot's SphereMesh), row y <-> latitude (top = north).
static func build_map(gen: PlanetGenerator, w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var col := Column.new()
	for py in h:
		var lat := PI * 0.5 - PI * (py + 0.5) / h
		for px in w:
			var th := TAU * (px + 0.5) / w
			var d := Vector3(cos(lat) * sin(th), sin(lat), cos(lat) * cos(th))
			gen.sample_column(d, col, 64)
			var c := _map_color(gen, col)
			# faint graticule every 30 degrees
			if px % (w / 12) == 0 or py % (h / 6) == 0:
				c = c.lerp(Color.WHITE, 0.10)
			img.set_pixel(px, py, c)
	return img

static func _map_color(gen: PlanetGenerator, col: Column) -> Color:
	var h := col.height
	if h < 0.0:
		var t := clampf(-h / 700.0, 0.0, 1.0)
		var c := Color(0.16, 0.50, 0.68).lerp(Color(0.03, 0.10, 0.30), sqrt(t))   # shallow -> deep
		if col.temperature < 0.14:
			c = c.lerp(Color(0.85, 0.92, 0.97), 0.8)                              # sea ice
		return c
	return gen.surface.color_for(col)

## Azimuthal-equidistant projection around `c` (what the shader does, in CPU form).
## Returns (u, v) in [-1, 1] for a point at angle <= span from the centre.
static func project(n: Vector3, c: Vector3, right: Vector3, up: Vector3, span: float) -> Vector2:
	var cd := clampf(n.dot(c), -1.0, 1.0)
	var th := acos(cd)
	var t := n - c * cd
	var tl := t.length()
	if tl < 0.00001:
		return Vector2.ZERO
	t /= tl
	return Vector2(t.dot(right), t.dot(up)) * (th / span)

## Inverse of `project`: the direction on the globe for map coordinates (u, v).
static func local_dir(c: Vector3, right: Vector3, up: Vector3, span: float, u: float, v: float) -> Vector3:
	var r := sqrt(u * u + v * v)
	if r < 0.000001:
		return c
	var th := r * span
	return (c * cos(th) + (right * u + up * v) / r * sin(th)).normalized()

## Detailed relief map of the area around `c` (square, covers an angle of `span` radians to every
## side): colours from the world generator at the detail that fits one pixel, plus hill shading.
static func build_local_map(gen: PlanetGenerator, c: Vector3, right: Vector3, up: Vector3, span: float, size: int) -> Image:
	var col := Column.new()
	var colors := PackedColorArray()
	var heights := PackedFloat32Array()
	colors.resize(size * size)
	heights.resize(size * size)
	var px_m := span * 2.0 * float(WorldConfig.PLANET_RADIUS) / size
	var step := maxi(1, int(px_m))
	for py in size:
		var v := 1.0 - (py + 0.5) / size * 2.0
		for px in size:
			var u := (px + 0.5) / size * 2.0 - 1.0
			var d := local_dir(c, right, up, span, u, v)
			gen.sample_column(d, col, step)
			colors[px + size * py] = _map_color(gen, col)
			heights[px + size * py] = col.height
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for py in size:
		for px in size:
			var i := px + size * py
			var x0 := maxi(px - 1, 0)
			var x1 := mini(px + 1, size - 1)
			var y0 := maxi(py - 1, 0)
			var y1 := mini(py + 1, size - 1)
			# light from the north-west: the slope towards the south-east side is shaded
			var s := (heights[x0 + size * y0] - heights[x1 + size * y1]) / (2.0 * px_m)
			var shade := 1.0 + clampf(s * 3.2, -0.5, 0.5)
			var cc := colors[i]
			img.set_pixel(px, py, Color(cc.r * shade, cc.g * shade, cc.b * shade))
	return img

## Half-angle (radians) of the cap of the globe that is visible from camera distance `dist`.
static func visible_half_angle(dist: float) -> float:
	var phi := deg_to_rad(FOV * 0.5)
	var disc := 1.0 - dist * dist * sin(phi) * sin(phi)
	if disc <= 0.0:
		return PI * 0.5
	var t := dist * cos(phi) - sqrt(disc)
	return atan2(t * sin(phi), dist - t * cos(phi))

## Latitude / longitude text of a world position.
static func lat_lon_text(pos: Vector3) -> String:
	var r := pos.length()
	if r < 1.0:
		return ""
	var lat := rad_to_deg(asin(clampf(pos.y / r, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(pos.z, pos.x))
	return "%.0f°%s  %.0f°%s" % [absf(lat), "N" if lat >= 0.0 else "S", absf(lon), "E" if lon >= 0.0 else "W"]

# ---------------------------------------------------------------- per frame

## pos = player position, fwd = direction the player faces (tangent), sun = unit vector to the sun.
func set_view(pos: Vector3, fwd: Vector3, sun: Vector3) -> void:
	if _cam == null or pos.length() < 1.0:
		return
	_pos = pos
	var d := pos.normalized()
	# north is always up on the radar (the direction to the pole, flattened onto the ground)
	var north := Vector3.UP - d * d.dot(Vector3.UP)
	if north.length() > 0.02:
		_up = north.normalized()
	_dist = lerpf(_dist, ZOOM_DIST[zoom_level], 0.18)
	_cam.look_at_from_position(d * _dist, Vector3.ZERO, _up)
	_marker.position = d * 1.02
	var ms := clampf((_dist - 1.0) / 2.4, 0.1, 1.0)
	_marker.scale = Vector3.ONE * ms * (1.0 + 0.25 * sin(_pulse))
	_mat.set_shader_parameter("sun_dir", sun)
	_sun_marker.position = sun.normalized() * 1.03
	_sun_marker.scale = Vector3.ONE * clampf((_dist - 1.0) / 2.4, 0.15, 1.0)
	var b := _cam.global_transform.basis
	_heading = atan2(fwd.dot(b.x), fwd.dot(b.y))
	var text := lat_lon_text(pos)
	if zoom_level > 0 and _local_has:
		text += "\n%s   %.1f km wide   [+/-]" % [ZOOM_NAME[zoom_level], 2.0 * _local_span * WorldConfig.PLANET_RADIUS / 1000.0 / 1.15]
	else:
		text += "\n%s   [+/-] zoom" % ZOOM_NAME[zoom_level]
	_label.text = text
	_overlay.queue_redraw()
	_request_local_map(d)

## Does the detailed map still cover the view? If not (zoomed, moved away, other level): make a new one.
func _request_local_map(d: Vector3) -> void:
	if zoom_level == 0 or _gen == null or _local_busy:
		return
	var span := visible_half_angle(ZOOM_DIST[zoom_level]) * 1.15
	var stale := not _local_has or _local_level != zoom_level or acos(clampf(d.dot(_local_center), -1.0, 1.0)) > 0.3 * _local_span
	if not stale:
		return
	_local_busy = true
	var up := _up
	var right := (-d).cross(up).normalized()
	up = right.cross(-d).normalized()
	WorkerThreadPool.add_task(_local_task.bind(_gen, d, right, up, span, zoom_level))

func _local_task(gen: PlanetGenerator, c: Vector3, right: Vector3, up: Vector3, span: float, level: int) -> void:
	var img := build_local_map(gen, c, right, up, span, LOCAL_PX)
	_mutex.lock()
	_local_result = {"img": img, "c": c, "right": right, "up": up, "span": span, "level": level}
	_mutex.unlock()

func _process(delta: float) -> void:
	_pulse += delta * 4.0
	_mutex.lock()
	var img := _map_image if _map_ready else null
	_map_ready = false
	var res := _local_result
	_local_result = {}
	_mutex.unlock()
	if img != null:
		_mat.set_shader_parameter("map", ImageTexture.create_from_image(img))
	if not res.is_empty():
		_mat.set_shader_parameter("local_map", ImageTexture.create_from_image(res.img))
		_mat.set_shader_parameter("c_dir", res.c)
		_mat.set_shader_parameter("c_right", res.right)
		_mat.set_shader_parameter("c_up", res.up)
		_mat.set_shader_parameter("local_span", res.span)
		_local_center = res.c
		_local_span = res.span
		_local_level = res.level
		_local_has = true
		_local_busy = false
	# zoomed out to the world view: the global map is enough
	if zoom_level == 0 and _local_has and _dist > ZOOM_DIST[1] + 0.4:
		_mat.set_shader_parameter("local_span", 0.0)
		_local_has = false

func _draw_overlay() -> void:
	var c := Vector2(SIZE, SIZE) * 0.5
	_overlay.draw_arc(c, SIZE * 0.5 - 1.5, 0.0, TAU, 96, Color(1, 1, 1, 0.45), 2.5, true)
	_overlay.draw_string(ThemeDB.fallback_font, c + Vector2(-5, -SIZE * 0.5 + 15), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.9))
	# heading arrow just ahead of the marker
	var dir := Vector2(sin(_heading), -cos(_heading))
	var perp := Vector2(-dir.y, dir.x)
	var tip := c + dir * 26.0
	_overlay.draw_colored_polygon(PackedVector2Array([tip, c + dir * 13.0 + perp * 6.0, c + dir * 13.0 - perp * 6.0]), Color(1.0, 0.85, 0.1))
	_overlay.draw_polyline(PackedVector2Array([tip, c + dir * 13.0 + perp * 6.0, c + dir * 13.0 - perp * 6.0, tip]), Color(0, 0, 0, 0.7), 1.5)
