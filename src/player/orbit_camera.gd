class_name OrbitCamera
extends Camera3D
## Third-person camera whose "up" is always the planet's radial direction.

var target: Node3D
var fwd := Vector3.FORWARD
var pitch := 0.45
var locked := false           # ignore the mouse (reproducing a captured view)
var distance := 8.0
var _yaw_input := 0.0
var _probe := SphereShape3D.new()
var world: VoxelWorld          # terrain data: a second, collision-independent safety check
var _lift := 0.0
const UNDERGROUND_MAX := 7.0

func _ready() -> void:
	near = 0.3
	_probe.radius = 0.5   # covers the near-plane corners

func _unhandled_input(event: InputEvent) -> void:
	if locked:
		return
	if event is InputEventMouseButton and event.pressed and event.ctrl_pressed:   # Ctrl + wheel = camera distance (plain wheel zooms the radar)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(3.0, distance - 0.7)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(30.0, distance + 0.7)

## Turn the camera by a mouse push (pixels): main calls this with what goes beyond the action perimeter.
func turn(push: Vector2) -> void:
	if locked:
		return
	_yaw_input -= push.x * 0.003
	pitch = clampf(pitch + push.y * 0.003, -0.2, 1.4)

func _process(_delta: float) -> void:
	if target == null:
		return
	# in a cave or shaft the camera only ever sits at a spot that fits in the room
	var dist := minf(distance, UNDERGROUND_MAX) if (world != null and world.underground) else distance
	var tp := target.global_position
	var up := tp.normalized()
	fwd = fwd - up * fwd.dot(up)
	if fwd.length() < 0.001:
		fwd = up.cross(Vector3.RIGHT)
	fwd = fwd.normalized().rotated(up, _yaw_input)
	_yaw_input = 0.0
	var pivot := tp + up * 0.5
	var exclude: Array[RID] = []
	if target is CollisionObject3D:
		exclude.append((target as CollisionObject3D).get_rid())
	# In a narrow shaft or tunnel the usual spot behind the ball is rock. Try raising the camera
	# (a steeper angle, finally looking straight down the shaft) and take the first clear one.
	var want_lift := 0.0
	var best_reach := -1.0
	for dp in [0.0, 0.3, 0.6, 0.9, 1.2]:
		var r := _sweep(pivot, _back(up, minf(pitch + dp, 1.5)), dist, exclude)
		if r > best_reach + 0.05:
			best_reach = r
			want_lift = dp
		if r >= dist - 0.05:
			break
	_lift = lerpf(_lift, want_lift, 0.2)
	var back := _back(up, minf(pitch + _lift, 1.5))
	# Final safety sweep: the camera stops before any terrain, so its view never enters the ground.
	var reach := _sweep(pivot, back, dist, exclude)
	reach = minf(reach, _density_reach(pivot, back, reach))
	var pos := pivot + back * reach
	# Last guard: the camera AND the corners of its near plane must be in open air with a margin (a corner poking into a wall
	# shows the underground behind it). If not, the camera is pulled toward the ball until they are.
	if world != null:
		var tries := 0
		while tries < 14 and reach > 0.05 and _near_plane_blocked(pos, pivot, up):
			reach *= 0.86
			pos = pivot + back * reach
			tries += 1
	if reach < 0.3:
		# ball pressed against a wall: look along the ball's heading from right next to it
		global_transform = Transform3D(Basis.looking_at(fwd, up), pos)
	else:
		global_position = pos
		look_at(pivot, up)
	# the ball would fill the screen when the camera is this close
	if target is Node3D:
		(target as Node3D).visible = reach > 0.8

## Is the camera, or a corner of its near plane, inside the ground or within CLEARANCE of it?
const CLEARANCE := 0.25
func _near_plane_blocked(pos: Vector3, pivot: Vector3, up: Vector3) -> bool:
	var dir := (pivot - pos)
	if dir.length() < 0.001:
		return false
	var cb := Basis.looking_at(dir.normalized(), up)
	var ahead := -cb.z * maxf(near, 0.3)
	for off: Vector3 in [Vector3.ZERO, cb.x * 0.45, -cb.x * 0.45, cb.y * 0.3, -cb.y * 0.3, ahead, ahead + cb.x * 0.45, ahead - cb.x * 0.45]:
		if world.density_at(pos + off) > -CLEARANCE:
			return true
	return false

func _back(up: Vector3, pt: float) -> Vector3:
	return -fwd * cos(pt) + up * sin(pt)

## Walks along the arm and tests the terrain *data* (not physics): works even where no collision shape
## exists yet (rock that was never built because nobody is near it). Returns the safe arm length.
func _density_reach(pivot: Vector3, dir: Vector3, max_d: float) -> float:
	if world == null:
		return max_d
	var side := dir.cross(Vector3.UP)
	if side.length() < 0.01:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized()
	var upv := side.cross(dir).normalized()
	var t := 0.5
	while t <= max_d:
		var c := pivot + dir * t
		if world.density_at(c) > 0.0 or world.density_at(c + side * 0.45) > 0.0 or world.density_at(c - side * 0.45) > 0.0 				or world.density_at(c + upv * 0.45) > 0.0 or world.density_at(c - upv * 0.45) > 0.0:
			return maxf(t - 0.5, 0.0)
		t += 0.5
	return max_d

## How far (up to `dist`) the camera can travel from the pivot along `dir` without any terrain
## entering its view. Two checks, because each has a blind spot: a sphere sweep (ignores shapes it
## already overlaps at the start, e.g. a wall right next to the ball in a narrow shaft) and a fan
## of thin rays (which still hit such a wall, from inside or outside).
func _sweep(pivot: Vector3, dir: Vector3, dist: float, exclude: Array[RID]) -> float:
	var space := get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _probe
	params.transform = Transform3D(Basis.IDENTITY, pivot)
	params.motion = dir * dist
	params.collision_mask = 1
	params.exclude = exclude
	var res := space.cast_motion(params)
	var reach := dist * (res[0] if res.size() > 0 else 1.0)
	var side := dir.cross(Vector3.UP)
	if side.length() < 0.01:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized()
	var upv := side.cross(dir).normalized()
	for off in [Vector3.ZERO, side * 0.4, -side * 0.4, upv * 0.4, -upv * 0.4]:
		var from: Vector3 = pivot + off
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * dist, 1, exclude)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			reach = minf(reach, maxf(from.distance_to(hit.position) - 0.5, 0.0))
	return reach
