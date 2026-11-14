class_name WaterRipples
extends RefCounted
## Rings on the water surface made by whatever disturbs it (a swimmer, a splash, a body skimming the surface). A small ring buffer of SLOTS rings;
## the surface shader draws each as an expanding wave that fades (exp(-age * decay)) and a short white foam ring. Slots whose age passed LIFE are
## ignored. Display only: nothing here touches the world. Used through WaterSystem.add_ripple (the module boundary).

const SLOTS := 8
const LIFE := 3.5            # seconds a ring lives

var _pos := PackedVector4Array()     # xyz = where (world), w = strength (0 = unused)
var _t0 := PackedFloat32Array()      # when it started (seconds)
var _next := 0

func _init() -> void:
	for i in SLOTS:
		_pos.append(Vector4.ZERO)
		_t0.append(-100.0)

func add(p: Vector3, strength: float, now: float) -> void:
	_pos[_next] = Vector4(p.x, p.y, p.z, strength)
	_t0[_next] = now
	_next = (_next + 1) % SLOTS

## Writes the rings (and their ages) to the water materials.
func upload(materials: Array, now: float) -> void:
	var live := _pos.duplicate()
	var ages := PackedFloat32Array()
	for i in SLOTS:
		var age := now - _t0[i]
		ages.append(age)
		if age > LIFE:
			live[i] = Vector4(live[i].x, live[i].y, live[i].z, 0.0)
	for m: ShaderMaterial in materials:
		m.set_shader_parameter("rip", live)
		m.set_shader_parameter("rip_age", ages)
