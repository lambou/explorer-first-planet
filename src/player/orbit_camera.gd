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
var _lift := 0.0                # how much the camera is raised above the player's chosen angle (smoothed)
var _yaw_off := 0.0             # how far the camera swung round the ball to find a clear view (smoothed)
var _goal := Vector2.ZERO       # the view found by the search: (raise, swing)
var _has_goal := false
var _search_cd := 0.0
var view_fwd := Vector3.FORWARD  # the direction the camera really looks along (the top of the screen): the controls and the radar follow it
const MAX_PITCH := 1.55         # straight down, almost
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

func _process(delta: float) -> void:
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
	# The player must always be able to see the ball. If the usual spot behind it is blocked (a hole, a shaft, a tunnel, a
	# wall), the camera looks for the best clear view around the ball: raised up to straight above, swung round it, or lowered
	# along a tunnel. It takes the one with the longest clear arm that stays closest to what the player chose, and glides there.
	var arm0 := _arm(pivot, up, pitch, 0.0, dist, exclude)
	var goal := Vector2.ZERO
	if arm0 < dist - 0.05:
		_search_cd -= delta
		if _search_cd <= 0.0 or not _has_goal:
			_goal = _search(pivot, up, dist, exclude)
			_search_cd = 0.3
			_has_goal = true
		goal = _goal
	else:
		_has_goal = false
	_lift = lerpf(_lift, goal.x, 0.18)
	_yaw_off = lerp_angle(_yaw_off, goal.y, 0.18)
	var pt := clampf(pitch + _lift, -0.2, MAX_PITCH)
	var back := _back(up, pt, _yaw_off)
	view_fwd = fwd.rotated(up, _yaw_off)
	# Final safety sweep: the camera stops before any terrain, so its view never enters the ground.
	var reach := _sweep(pivot, back, dist, exclude)
	reach = minf(reach, _density_reach(pivot, back, reach))
	var look_up := up.lerp(view_fwd, smoothstep(1.2, 1.5, pt)).normalized()     # from straight above, the top of the screen is the heading
	var pos := pivot + back * reach
	# Last guard: the camera AND the corners of its near plane must be in open air with a margin (a corner poking into a wall
	# shows the underground behind it). If not, the camera is pulled toward the ball until they are.
	if world != null:
		var tries := 0
		while tries < 14 and reach > 0.05 and _near_plane_blocked(pos, pivot, look_up):
			reach *= 0.86
			pos = pivot + back * reach
			tries += 1
	if reach < 0.3:
		# ball pressed against a wall: look along the ball's heading from right next to it
		global_transform = Transform3D(Basis.looking_at(view_fwd, up), pos)
	else:
		global_position = pos
		look_at(pivot, look_up)
	# the ball would fill the screen when the camera is this close
	if target is Node3D:
		(target as Node3D).visible = reach > 0.45          # the ball stays visible unless the camera is practically inside it

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

func _back(up: Vector3, pt: float, yaw_off: float = 0.0) -> Vector3:
	var f := fwd.rotated(up, yaw_off) if yaw_off != 0.0 else fwd
	return -f * cos(pt) + up * sin(pt)

## The clear arm length (up to `dist`) of the view at pitch `pt`, swung round by `yo`: sphere sweep + terrain data.
func _arm(pivot: Vector3, up: Vector3, pt: float, yo: float, dist: float, exclude: Array[RID]) -> float:
	var dir := _back(up, clampf(pt, -0.2, MAX_PITCH), yo)
	var r := _sweep(pivot, dir, dist, exclude)
	return minf(r, _density_reach(pivot, dir, r))

## The best clear view around the ball: (raise, swing) relative to the player's own angle. Scores the length of the clear
## arm (capped at the wanted distance) and prefers little swing and little raise, so an open view is never given up lightly.
func _search(pivot: Vector3, up: Vector3, dist: float, exclude: Array[RID]) -> Vector2:
	var best := Vector2.ZERO
	var best_score := -1.0e9
	for yo in [0.0, 0.8, -0.8, 1.6, -1.6, PI]:
		for pa in [0.0, 0.4, 0.8, 1.2, 2.0, -0.3, -0.6]:
			var pt := clampf(pitch + pa, -0.2, MAX_PITCH)
			var arm := _arm(pivot, up, pt, yo, dist, exclude)
			var score := minf(arm, dist) - 0.6 * absf(yo) - 0.9 * absf(pt - pitch)
			if arm >= dist - 0.05:
				score += 1.0                               # a fully open view
			if score > best_score:
				best_score = score
				best = Vector2(pt - pitch, yo)
	return best

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
