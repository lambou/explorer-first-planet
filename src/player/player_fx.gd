class_name PlayerFx
extends Node3D
## Puffs around the explorer: dust kicked up by his boots (the colour of the ground he is on) and foam / droplets on the water. Nothing is
## kept: no bodies, no collisions; one MultiMesh draws every puff (one draw call) and the oldest are recycled. Display only: PlayerCharacter
## decides when and where (a boot lands, a slide, a splash).

const MAX := 480
const SPRING := 0.9            # how fast a dust puff rises (m/s along the planet's up), a hot breath of ground
const DRAG := 2.6

var _mm: MultiMesh
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _life := PackedFloat32Array()
var _span := PackedFloat32Array()      # the life each puff started with
var _size := PackedFloat32Array()
var _grow := PackedFloat32Array()      # > 0: the puff swells as it fades (dust); < 0: it only shrinks (droplets)
var _grav := PackedFloat32Array()      # 0 = dust (rises and thins), > 0 = pulled down (droplets)
var _col := PackedColorArray()
var _stretch := PackedFloat32Array()   # > 0: a streak, stretched along _dir by this factor
var _dir := PackedVector3Array()       # the direction a streak points along
var _n := 0
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	top_level = true
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 6
	sm.rings = 3
	_mm.mesh = sm
	_mm.instance_count = MAX
	_mm.visible_instance_count = 0
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = _mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS     # (alpha hash renders opaque in the compatibility renderer)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 1000.0              # the instances live in world space around the player, the node sits at the origin
	add_child(mi)
	for i in MAX:
		_pos.append(Vector3.ZERO)
		_vel.append(Vector3.ZERO)
		_life.append(0.0)
		_span.append(1.0)
		_size.append(0.0)
		_grow.append(0.0)
		_grav.append(0.0)
		_col.append(Color.WHITE)
		_stretch.append(0.0)
		_dir.append(Vector3.FORWARD)
	_rng.seed = 777

func active() -> int:
	return _n

func _slot() -> int:
	if _n < MAX:
		_n += 1
		return _n - 1
	return _rng.randi() % MAX                  # all slots busy: recycle one

## `count` dust puffs at `point` (on the ground), thrown along `away` (sideways speed, m/s) and up, of ground colour `ground`.
func dust(point: Vector3, away: Vector3, up: Vector3, ground: Color, count: int, size: float) -> void:
	var col := ground.lightened(0.25).lerp(Color(0.8, 0.78, 0.72), 0.25)
	for i in count:
		var k := _slot()
		var jit := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 0.5
		_pos[k] = point + up * 0.06 + jit * 0.12
		_vel[k] = away * _rng.randf_range(0.3, 1.0) + up * _rng.randf_range(0.3, 1.1) + jit
		_span[k] = _rng.randf_range(0.7, 1.2)
		_life[k] = _span[k]
		_size[k] = size * _rng.randf_range(0.7, 1.3)
		_grow[k] = 1.6
		_stretch[k] = 0.0
		_grav[k] = 0.0
		col.a = 0.5
		_col[k] = col

## A glowing puff that coasts (no rise, little drag) and shrinks away: the trail of a flier.
func glow(point: Vector3, vel: Vector3, size: float, color: Color) -> void:
	var k := _slot()
	_pos[k] = point + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 0.05
	_vel[k] = vel
	_span[k] = _rng.randf_range(0.35, 0.6)
	_life[k] = _span[k]
	_size[k] = size
	_grow[k] = -0.7
	_grav[k] = -1.0
	_stretch[k] = 0.0
	_col[k] = color

## A little bubble: it rises slowly, swells a touch and pops (the trail of a diver).
func bubble(point: Vector3, vel: Vector3, size: float) -> void:
	var k := _slot()
	_pos[k] = point + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 0.08
	_vel[k] = vel
	_span[k] = _rng.randf_range(0.9, 1.6)
	_life[k] = _span[k]
	_size[k] = size
	_grow[k] = 0.4
	_grav[k] = 0.0
	_stretch[k] = 0.0
	_col[k] = Color(0.85, 0.96, 1.0, 0.6)

## A thin line of wind, fixed in the world and pointing along `dir`, `length` times its width; it appears and fades fast as he rushes past.
func streak(point: Vector3, dir: Vector3, length: float, size: float, color: Color) -> void:
	var k := _slot()
	_pos[k] = point
	_vel[k] = Vector3.ZERO
	_span[k] = _rng.randf_range(0.18, 0.32)
	_life[k] = _span[k]
	_size[k] = size
	_grow[k] = 0.0
	_grav[k] = -1.0
	_stretch[k] = length / maxf(size, 0.001)
	_dir[k] = dir
	_col[k] = color

## `count` water droplets and foam at `point` (on the water's surface), thrown up and out.
func splash(point: Vector3, away: Vector3, up: Vector3, count: int, size: float) -> void:
	for i in count:
		var k := _slot()
		var jit := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(0, 1), _rng.randf_range(-1, 1))
		_pos[k] = point + up * 0.05
		_vel[k] = away * _rng.randf_range(0.2, 1.0) + up * _rng.randf_range(1.2, 3.4) + jit * 0.9
		_span[k] = _rng.randf_range(0.5, 0.9)
		_life[k] = _span[k]
		_size[k] = size * _rng.randf_range(0.5, 1.2)
		_grow[k] = -0.4
		_grav[k] = 9.0
		_col[k] = Color(0.92, 0.96, 1.0, 0.8)

## Foam on the surface: a flat, slow puff that stays and thins (the wake of a swimmer).
func foam(point: Vector3, up: Vector3, size: float) -> void:
	var k := _slot()
	_pos[k] = point + up * 0.04
	_vel[k] = Vector3(_rng.randf_range(-0.2, 0.2), 0.0, _rng.randf_range(-0.2, 0.2)) - up * 0.0
	_span[k] = _rng.randf_range(0.9, 1.4)
	_life[k] = _span[k]
	_size[k] = size
	_grow[k] = 2.2
	_grav[k] = 0.0
	_col[k] = Color(0.95, 0.98, 1.0, 0.55)

func _process(delta: float) -> void:
	if _n == 0:
		return
	var i := 0
	while i < _n:
		_life[i] -= delta
		if _life[i] <= 0.0:
			_n -= 1                              # swap the last live puff into this slot
			_pos[i] = _pos[_n]
			_vel[i] = _vel[_n]
			_life[i] = _life[_n]
			_span[i] = _span[_n]
			_size[i] = _size[_n]
			_grow[i] = _grow[_n]
			_grav[i] = _grav[_n]
			_col[i] = _col[_n]
			_stretch[i] = _stretch[_n]
			_dir[i] = _dir[_n]
			continue
		var up := _pos[i].normalized()
		var v := _vel[i]
		if _grav[i] > 0.0:
			v -= up * _grav[i] * delta
		elif _grav[i] < 0.0:
			v *= exp(-1.0 * delta)                   # coasting: no rise
		else:
			v *= exp(-DRAG * delta)
			v += up * SPRING * delta
		_vel[i] = v
		_pos[i] += v * delta
		i += 1
	for j in _n:
		var u := 1.0 - _life[j] / _span[j]                              # 0 born .. 1 gone
		var s := _size[j] * (1.0 + _grow[j] * u)
		var c := _col[j]
		c.a *= (1.0 - u) * minf(1.0, u * 12.0 + 0.35)                  # thins out as it ages, appears at once
		var sc := maxf(s, 0.001)
		if _stretch[j] > 0.0:
			var b := Basis.looking_at(_dir[j], _pos[j].normalized()) * Basis.from_scale(Vector3(sc, sc, sc * _stretch[j]))
			_mm.set_instance_transform(j, Transform3D(b, _pos[j]))
		else:
			_mm.set_instance_transform(j, Transform3D(Basis().scaled(Vector3.ONE * sc), _pos[j]))
		_mm.set_instance_color(j, c)
	_mm.visible_instance_count = _n
