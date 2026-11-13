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
var view_fwd := Vector3.FORWARD  # the direction the camera really looks along (the top of the screen): the controls and the radar follow it
var tilt := 0.0                 # the view tilted UP from the ball (looking at the sky and the treetops); the camera itself stays low
const MAX_TILT := 1.45
const MAX_PITCH := 1.55         # straight down, almost
const UNDERGROUND_MAX := 7.0
const PIVOT_HEIGHT := 0.85      # the camera looks at this height above the ball's centre: the middle of the character's body
const FOCUS_DEAD := 1.6         # metres the player may be from where the camera looks before it follows him
const FOCUS_RATE := 5.0         # how fast it follows once he is further (per second)
const FOCUS_SNAP := 25.0        # further than this (a teleport) it does not glide
const CAMERA_LIFT := 2.6        # metres the camera sits higher than the plain arm puts it (the view looks down a little more)
const LEAD := 2.4               # metres ahead of the character the camera looks, on open ground
const FOLLOW := 0.8             # how much of the slope ahead the camera's pitch follows (1 = the same angle to the ground as on the flat)
const DROP_MAX := 0.5           # (radians) facing a hill the camera drops by at most this much ...
const RISE_MAX := 0.3           # ... and facing downhill it rises by at most this much

var _slope := 0.0               # the slope of the ground ahead (radians, uphill positive), smoothed
var _slope_goal := 0.0
var _slope_cd := 0.0
var dbg := ""                  # the numbers of the last frame (debugging aid: main.gd --camtest prints them)
var _reach_s := 0.0             # the arm length in use (shrinks at once when blocked, grows back smoothly)
var _focus := Vector3.ZERO      # the point the camera orbits (follows the player loosely)
var _focus_ready := false
var _lead := 0.0                # the lead in use (smoothed; shrinks when the spot ahead is inside the ground)

func _ready() -> void:
	near = 0.3
	_probe.radius = 0.5   # covers the near-plane corners

func _unhandled_input(event: InputEvent) -> void:
	if locked:
		return
	if event is InputEventMouseButton and event.pressed and event.ctrl_pressed:   # Ctrl + wheel = camera distance (plain wheel zooms the radar)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(0.5, distance - 0.7)
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
	pitch = clampf(np, -0.2, MAX_PITCH)

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
	var focus_goal := eye + fwd * _clear_lead(eye, delta, cave)       # where the camera would look if it were rigid: a little ahead of the ball
	# The camera does not sit rigidly on the player: it orbits a FOCUS point that follows him loosely. Inside FOCUS_DEAD of the goal the focus stays put
	# (he can walk and jump about the screen, the picture does not bob); outside it, it is dragged along with a lag. The mouse still turns the view freely.
	if not _focus_ready or cave or _focus.distance_to(focus_goal) > FOCUS_SNAP:
		_focus = focus_goal                                    # first frame, a cave (tight), or he was moved far (respawn, rescue)
		_focus_ready = true
	else:
		var off := _focus - focus_goal
		if off.length() > FOCUS_DEAD:
			off = off.normalized() * FOCUS_DEAD
		_focus = _focus.lerp(focus_goal + off, 1.0 - exp(-delta * FOCUS_RATE))
	var pivot := _focus                                       # what the camera orbits and looks at
	var exclude: Array[RID] = []
	if target is CollisionObject3D:
		exclude.append((target as CollisionObject3D).get_rid())
	# The mouse owns the view: an obstacle only pulls the camera in along the arm (below), it never turns or raises it.
	var pt := base_pitch
	var back := _back(up, pt)
	view_fwd = fwd
	# The camera spot is behind the ball, as far as the player chose; the way there is measured from the BODY. If something is in the way the arm
	# shortens towards the ball (it never collapses onto the point ahead of him), at once when blocked and growing back smoothly.
	var spot := pivot + back * dist + up * CAMERA_LIFT     # a little above where the plain arm would put it
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
	dbg = "clear %.1f/%.1f lead %.1f" % [clear, arm_len, _lead]
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
