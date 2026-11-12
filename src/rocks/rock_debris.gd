class_name RockDebris
extends Node3D
## Debris: the pieces that fly off when a rock (or the ground) is broken. They fall under the planet's gravity,
## bounce a little on the ground, shrink and vanish after ~2 s. Nothing is kept: no physics bodies, no collision
## shapes. One MultiMesh draws them all (one draw call) and at most MAX pieces exist; the oldest are recycled.
## Cost per frame: one density lookup per live piece.

const MAX := 96
const GRAVITY := 16.0
const LIFE := 2.2

var world: VoxelWorld
var _mm: MultiMesh
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _life := PackedFloat32Array()
var _size := PackedFloat32Array()
var _col := PackedColorArray()
var _n := 0
var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 5
	sm.rings = 2
	_mm.mesh = sm
	_mm.instance_count = MAX
	_mm.visible_instance_count = 0
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = _mm
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	for i in MAX:
		_pos.append(Vector3.ZERO)
		_vel.append(Vector3.ZERO)
		_life.append(0.0)
		_size.append(0.0)
		_col.append(Color.WHITE)
	_rng.seed = 12345

func active() -> int:
	return _n

## `count` pieces of the given colours burst from `point`, mostly along `normal` (away from the surface).
func burst(point: Vector3, normal: Vector3, colors: Array, count: int, piece_size: float) -> void:
	for i in count:
		var k: int
		if _n < MAX:
			k = _n
			_n += 1
		else:
			k = _rng.randi() % MAX              # all slots busy: recycle one
		var dir := (normal + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 0.9).normalized()
		_pos[k] = point + dir * 0.1
		_vel[k] = dir * _rng.randf_range(2.5, 6.5)
		_life[k] = LIFE * _rng.randf_range(0.7, 1.0)
		_size[k] = piece_size * _rng.randf_range(0.5, 1.2)
		_col[k] = colors[_rng.randi() % colors.size()]

func _process(delta: float) -> void:
	if _n == 0:
		return
	var i := 0
	while i < _n:
		_life[i] -= delta
		if _life[i] <= 0.0:
			_n -= 1                                  # swap the last live piece into this slot
			_pos[i] = _pos[_n]
			_vel[i] = _vel[_n]
			_life[i] = _life[_n]
			_size[i] = _size[_n]
			_col[i] = _col[_n]
			continue
		var p := _pos[i]
		var down := -p.normalized()
		var v := _vel[i] + down * GRAVITY * delta
		var np := p + v * delta
		if world != null and world.density_at(np) > 0.0:
			# hit the ground: lose most of the speed, slide a little
			var up := -down
			var vn := up * v.dot(up)
			v = (v - vn) * 0.55 - vn * 0.25
			np = p
		_pos[i] = np
		_vel[i] = v
		i += 1
	for j in _n:
		var s := _size[j] * clampf(_life[j] / 0.5, 0.0, 1.0)
		_mm.set_instance_transform(j, Transform3D(Basis().scaled(Vector3.ONE * s), _pos[j]))
		_mm.set_instance_color(j, _col[j])
	_mm.visible_instance_count = _n
