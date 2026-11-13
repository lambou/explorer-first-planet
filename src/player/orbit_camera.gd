class_name OrbitCamera
extends Camera3D
## Third-person camera whose "up" is always the planet's radial direction. It is made for walking about an open world:
##   - it pivots on the character's BODY (not his feet) and a little AHEAD of him, along the way the camera faces, so he sits in the lower part
##     of the screen and what lies in front of him (where the mouse points) is in view; the lead shrinks where the spot ahead is inside the ground;
##   - it is TERRAIN-AWARE: it reads the slope of the ground ahead and tilts with it, so the view keeps the same angle to the GROUND (not to the
##     horizon): facing a hill it drops lower and looks up the slope and over the crest (a camera held at a fixed angle to the horizon looks
##     down onto the hillside like a wall), facing downhill it rises a little so the view is not a grazing one;
##   - where its view is blocked it finds a clear one (raised, swung round, lowered along a tunnel) as before.

var target: Node3D
var fwd := Vector3.FORWARD
var pitch := 0.45
var locked := false           # ignore the mouse (reproducing a captured view)
var distance := 9.0
var _yaw_input := 0.0
var _probe := SphereShape3D.new()
var world: VoxelWorld          # terrain data: a second, collision-independent safety check
var _lift := 0.0                # how much the camera is raised above the player's chosen angle (smoothed)
var _yaw_off := 0.0             # how far the camera swung round the ball to find a clear view (smoothed)
var _goal := Vector2.ZERO       # the view found by the search: (raise, swing)
var _has_goal := false
var _search_cd := 0.0
var view_fwd := Vector3.FORWARD  # the direction the camera really looks along (the top of the screen): the controls and the radar follow it
var tilt := 0.0                 # the view tilted UP from the ball (looking at the sky and the treetops); the camera itself stays low
const MAX_TILT := 1.45
const MAX_PITCH := 1.55         # straight down, almost
const UNDERGROUND_MAX := 7.0
const PIVOT_HEIGHT := 0.85      # the camera looks at this height above the ball's centre: the middle of the character's body
const GOAL_HOLD := 0.6          # seconds the plain view must stay open before a search result is dropped (no flicker at an obstacle's edge)
const LEAD := 0.8               # metres ahead of the character the camera looks, on open ground
const FOLLOW := 0.8             # how much of the slope ahead the camera's pitch follows (1 = the same angle to the ground as on the flat)
const DROP_MAX := 0.5           # (radians) facing a hill the camera drops by at most this much ...
const RISE_MAX := 0.3           # ... and facing downhill it rises by at most this much

var _slope := 0.0               # the slope of the ground ahead (radians, uphill positive), smoothed
var _slope_goal := 0.0
var _slope_cd := 0.0
var dbg := ""                  # the numbers of the last frame (debugging aid: main.gd --camtest prints them)
var _open_t := 0.0              # how long the plain view has been open since the search found a better one
var _reach_s := 0.0             # the arm length in use (shrinks at once when blocked, grows back smoothly)
var _lead := 0.0                # the lead in use (smoothed; shrinks when the spot ahead is inside the ground)

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
	# push down = the camera rises over the ball; push up = it sinks to ground level and then the VIEW tilts up to the sky
	var np := pitch + push.y * 0.003
	if push.y < 0.0 and np < -0.2:
		tilt = clampf(tilt + (-0.2 - np), 0.0, MAX_TILT)
		np = -0.2
	elif push.y > 0.0 and tilt > 0.0:
		var used := minf(tilt, push.y * 0.003)
		tilt -= used
		np = pitch + (push.y * 0.003 - used)
	pitch = clampf(np, -0.2, 1.4)

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
	var cave := world != null and world.underground
	_update_slope(tp, up, delta, cave)
	var base_pitch := clampf(pitch - clampf(_slope * FOLLOW, -RISE_MAX, DROP_MAX), -0.2, MAX_PITCH)     # the pitch the player chose, tilted with the ground ahead
	var eye := tp + up * PIVOT_HEIGHT                       # the middle of the character's body: the arm always starts HERE, in the open air
	var pivot := eye + fwd * _clear_lead(eye, delta, cave)  # what the camera looks at (ahead of the ball); the camera itself stays behind the ball
	var exclude: Array[RID] = []
	if target is CollisionObject3D:
		exclude.append((target as CollisionObject3D).get_rid())
	# The player must always be able to see the ball. If the usual spot behind it is blocked (a hole, a shaft, a tunnel, a rock, a wall), the
	# camera looks for the best clear view around the ball: raised up to straight above, swung round it, or lowered along a tunnel. It takes the
	# one with the longest clear arm that stays closest to what the player chose, and glides there.
	var arm0 := _arm(eye, pivot, up, base_pitch, 0.0, dist, exclude)
	var goal := Vector2.ZERO
	if arm0 < dist - 0.05:
		_open_t = 0.0
		_search_cd -= delta
		if _search_cd <= 0.0 or not _has_goal:
			_goal = _search(eye, pivot, up, base_pitch, dist, exclude)
			_search_cd = 0.3
			_has_goal = true
		goal = _goal
	elif _has_goal and _open_t < GOAL_HOLD:
		_open_t += delta                                      # the plain view just opened: it flickers at the edge of an obstacle, wait before swinging back
		goal = _goal
	else:
		_has_goal = false
	_lift = lerpf(_lift, goal.x, 0.18)
	_yaw_off = lerp_angle(_yaw_off, goal.y, 0.18)
	var pt := clampf(base_pitch + _lift, -0.2, MAX_PITCH)
	var back := _back(up, pt, _yaw_off)
	view_fwd = fwd.rotated(up, _yaw_off)
	# The camera spot is behind the ball, as far as the player chose; the way there is measured from the BODY. If something is in the way the arm
	# shortens towards the ball (it never collapses onto the point ahead of him), at once when blocked and growing back smoothly.
	var spot := pivot + back * dist
	var to_spot := spot - eye
	var arm_len := to_spot.length()
	var arm_dir := to_spot / maxf(arm_len, 0.001)
	var clear := _sweep(eye, arm_dir, arm_len, exclude)
	clear = minf(clear, _density_reach(eye, arm_dir, clear))
	if clear < _reach_s or _reach_s <= 0.0:
		_reach_s = clear
	else:
		_reach_s = lerpf(_reach_s, clear, 1.0 - exp(-delta * 3.0))
	var reach := _reach_s
	dbg = "arm0 %.1f clear %.1f/%.1f lead %.1f swing %+.0f lift %+.2f" % [arm0, clear, arm_len, _lead, rad_to_deg(_yaw_off), _lift]
	var look_up := up.lerp(view_fwd, smoothstep(1.2, 1.5, pt)).normalized()     # from straight above, the top of the screen is the heading
	var pos := eye + arm_dir * reach
	# Last guard: the camera AND the corners of its near plane must be in open air with a margin (a corner poking into a wall
	# shows the underground behind it). If not, the camera is pulled toward the ball until they are.
	if world != null:
		var tries := 0
		while tries < 14 and reach > 0.05 and _near_plane_blocked(pos, pivot, look_up):
			reach *= 0.86
			pos = eye + arm_dir * reach
			tries += 1
	if reach < 0.3:
		# ball pressed against a wall: look along the ball's heading from right next to it
		global_transform = Transform3D(Basis.looking_at(view_fwd, up), pos)
	else:
		global_position = pos
		look_at(pivot, look_up)
		if tilt > 0.001:
			# tilt the view up: rotate the look direction about the camera's right axis (the ball slides down the screen)
			var f := -global_transform.basis.z
			var right := global_transform.basis.x
			var f2 := f.rotated(right, tilt)
			if f2.dot(up) < f.dot(up):
				f2 = f.rotated(right, -tilt)
			look_at(pos + f2 * 10.0, up)
	# the ball would fill the screen when the camera is this close
	if target is Node3D:
		(target as Node3D).visible = pos.distance_to(tp) > 0.7          # the ball stays visible unless the camera is practically inside it

## The slope of the ground in front of the character (every 0.1 s), smoothed every frame; none in caves.
func _update_slope(tp: Vector3, up: Vector3, delta: float, cave: bool) -> void:
	_slope_cd -= delta
	if _slope_cd <= 0.0:
		_slope_cd = 0.1
		_slope_goal = 0.0
		if world != null and not cave:
			var near_h := _ground_height(tp + fwd * 3.0, up)
			var far_h := _ground_height(tp + fwd * 9.0, up)
			if not is_nan(near_h) and not is_nan(far_h):
				_slope_goal = clampf(atan2(far_h - near_h, 6.0), -0.9, 0.9)
	_slope = lerpf(_slope, _slope_goal, 1.0 - exp(-delta * 3.0))

## Height (along `up`, relative to the point's own height) of the ground surface above/below `q`: found in the terrain data, NAN if there is none near.
func _ground_height(q: Vector3, up: Vector3) -> float:
	var t := 8.0
	if world.density_at(q + up * t) > 0.0:
		return t                                         # the point is deep inside a rising hill: as steep as it gets
	while t > -8.0:
		var next := t - 1.0
		if world.density_at(q + up * next) > 0.0:
			var lo := next                               # solid
			var hi := t                                  # air
			for i in 5:
				var mid := (lo + hi) * 0.5
				if world.density_at(q + up * mid) > 0.0:
					lo = mid
				else:
					hi = mid
			return (lo + hi) * 0.5
		t = next
	return NAN

## How far ahead of the character the camera looks: LEAD on open ground, less where that spot (or the air just short of it) is inside the ground.
func _clear_lead(from: Vector3, delta: float, cave: bool) -> float:
	var goal := 0.0 if cave else LEAD
	if world != null and goal > 0.0:
		while goal > 0.2 and (world.density_at(from + fwd * goal) > -0.4 or world.density_at(from + fwd * goal * 0.5) > -0.4):
			goal *= 0.6
		if goal <= 0.2:
			goal = 0.0
	_lead = lerpf(_lead, goal, 1.0 - exp(-delta * 4.0))
	return _lead

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
func _arm(eye: Vector3, pivot: Vector3, up: Vector3, pt: float, yo: float, dist: float, exclude: Array[RID]) -> float:
	var spot := pivot + _back(up, clampf(pt, -0.2, MAX_PITCH), yo) * dist
	var to := spot - eye
	var l := maxf(to.length(), 0.001)
	var d := to / l
	var r := _sweep(eye, d, l, exclude)
	return minf(r, _density_reach(eye, d, r)) * dist / l          # as a share of the wanted arm, in metres of the wanted arm

## The best clear view around the ball: (raise, swing) relative to the player's own angle. Scores the length of the clear
## arm (capped at the wanted distance) and prefers little swing and little raise, so an open view is never given up lightly.
func _search(eye: Vector3, pivot: Vector3, up: Vector3, base: float, dist: float, exclude: Array[RID]) -> Vector2:
	var best := Vector2.ZERO
	var best_score := -1.0e9
	for yo in [0.0, 0.8, -0.8, 1.6, -1.6, PI]:
		for pa in [0.0, 0.4, 0.8, 1.2, 2.0, -0.3, -0.6]:
			var pt := clampf(base + pa, -0.2, MAX_PITCH)
			var arm := _arm(eye, pivot, up, pt, yo, dist, exclude)
			var score := minf(arm, dist) - 0.6 * absf(yo) - 0.9 * absf(pt - base)
			if arm >= dist - 0.05:
				score += 1.0                               # a fully open view
			if score > best_score:
				best_score = score
				best = Vector2(pt - base, yo)
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
