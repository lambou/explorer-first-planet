class_name ToolAim
extends Node3D
## The mouse-aimed tool. The cursor is free; a ray from the camera through it finds what the tool will hit: a rock
## (nearest wins) or the ground. A PATCH that follows the surface shows where and how big the blow is: a translucent
## area with a bright outline, every point of it dropped onto the real surface (the terrain for the ground, the rock's
## own bitten surface for a rock), so it covers the targeted shape and never sinks into the floor or floats over it.
## White inside the player's reach, red outside it (the tool does nothing there). Display + picking only.
## SECONDARY by design: it never takes part in moving the player or the camera, and it never makes a frame longer. Finding the target runs every
## PICK_EVERY frames; the marker patch is built in slices of at most BUDGET_US microseconds a frame (the old patch stays on screen, moved to the new
## target, until the new one is ready). The reticle on the screen does not depend on any of it (AimOverlay).

const REACH := 4.5                 # metres from the ball: the arm's length; nothing farther can be altered
const GROUND_RADIUS := 2.4         # what one dig removes (same as VoxelWorld.carve in main)
const MAX_RAY := 70.0
const PICK_EVERY := 3               # the target is looked for every this many frames (the reticle and the tool use the last answer)
const BUDGET_US := 900             # the marker patch is built at most this long per frame
const SEGS := 28                   # points around the patch
const SEGS_ROCK := 18              # a rock needs a surface search per point: fewer points
const RINGS := [0.5, 0.9, 1.0]     # radii of the point rings (fractions of the patch radius): fill, outline inner edge, outline outer edge

var _mi: MeshInstance3D
var _imm := ImmediateMesh.new()
var _dot: MeshInstance3D
var _fill: ShaderMaterial
var _line: ShaderMaterial
var _key := ""
var reach := REACH                 # debugging aid: main can widen it for screenshots (--reach=)
var target := {"kind": "none"}

func _init() -> void:
	_fill = _material(0.20)
	_line = _material(0.95)
	_mi = MeshInstance3D.new()
	_mi.mesh = _imm
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mi)
	var sm := SphereMesh.new()
	sm.radius = 0.05
	sm.height = 0.10
	sm.radial_segments = 8
	sm.rings = 4
	_dot = MeshInstance3D.new()
	_dot.mesh = sm
	_dot.material_override = _line
	_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_dot)
	visible = false

## The look of the patch: a flat colour that is pulled toward the camera when drawn (a depth bias, `bias` metres), so
## the patch always wins the depth test against the surface under it (the mesh of the terrain is only an approximation of
## the density surface the patch was placed on, and can lie above it) while anything really in front still hides it.
## No depth writes, so it never hides anything itself. Cost: nothing but one extra vertex step.
const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform vec4 col : source_color = vec4(1.0);
uniform float bias = 0.45;
void vertex() {
	vec3 v = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v += normalize(-v) * bias;
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
}
void fragment() {
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
"""

static func _material(alpha: float) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	m.render_priority = 2
	m.set_shader_parameter("col", Color(1, 1, 1, alpha))
	return m

## What is under the mouse. `mouse` in viewport pixels. Returns
## {kind: "rock" | "ground" | "none", point, normal, in_reach, radius, rock?, chunk?, t}.
var _frames := PICK_EVERY            # frames since the last pick
var _world: VoxelWorld
var _job := {}                     # the patch being built: {t, rings, k, i, segs, ...}; empty = none
var job_us := 0                    # work done on the patch in the last frame (microseconds) and the worst frame
var worst_job_us := 0
var pick_us := 0                  # cost of the last pick (ray searches) and of the last patch build, microseconds: shown in the debug panel
var patch_us := 0
var worst_pick_us := 0
var worst_patch_us := 0

func pick(cam: Camera3D, world: VoxelWorld, player_pos: Vector3, mouse: Vector2, force: bool = false) -> Dictionary:
	_frames += 1
	if _frames < PICK_EVERY and not force:
		return target                                      # the last answer: a target does not change in a frame or two
	_frames = 0
	_world = world
	var t0 := Time.get_ticks_usec()
	var origin := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	var ground := world.raycast(origin, dir, MAX_RAY)
	var rock := world.rock_ray(origin, dir, MAX_RAY)
	var tree := world.tree_ray(origin, dir, MAX_RAY)
	var t := {"kind": "none"}
	var gt := INF
	if ground.hit:
		gt = origin.distance_to(ground.point)
	var near_t := minf(gt + 0.3, rock.t if rock.hit else INF)
	if tree.hit and tree.t <= near_t:
		var tr: TreeInst = tree.tree
		t = {"kind": "tree", "point": tree.point, "normal": tree.normal, "tree": tr, "chunk": tree.chunk, "t": tree.t,
			"radius": clampf(tree.r * 0.9, 0.25, 1.0), "in_reach": player_pos.distance_to(tree.point) <= reach,
			"cyl_a": tree.a, "cyl_d": tree.d, "cyl_r": tree.r * 0.8, "cyl_len": tree.len}
	elif rock.hit and rock.t <= gt + 0.3:
		var r: RockInst = rock.rock
		t = {"kind": "rock", "point": rock.point, "normal": rock.normal, "rock": r, "chunk": rock.chunk, "t": rock.t,
			"radius": maxf(0.25, world.rocks.bite_radius(r)), "in_reach": player_pos.distance_to(rock.point) <= reach}
	elif ground.hit:
		var p: Vector3 = ground.point
		var e := 0.5
		var g := Vector3(
			world.density_at(p + Vector3(e, 0, 0)) - world.density_at(p - Vector3(e, 0, 0)),
			world.density_at(p + Vector3(0, e, 0)) - world.density_at(p - Vector3(0, e, 0)),
			world.density_at(p + Vector3(0, 0, e)) - world.density_at(p - Vector3(0, 0, e)))
		var n := (-g).normalized() if g.length() > 0.0001 else p.normalized()
		t = {"kind": "ground", "point": p, "normal": n, "t": gt, "radius": GROUND_RADIUS * 0.9,
			"in_reach": player_pos.distance_to(p) <= reach}
	target = t
	pick_us = Time.get_ticks_usec() - t0
	worst_pick_us = maxi(worst_pick_us, pick_us)
	_show(world, t)
	return t

## The tool points at nothing (the mouse is outside the action perimeter).
func clear() -> void:
	target = {"kind": "none"}
	_job = {}
	visible = false

func _show(world: VoxelWorld, t: Dictionary) -> void:
	if t.kind == "none":
		_job = {}
		visible = false
		return                                           # (out of reach the patch stays, in red: the tool cannot work there)
	visible = true
	global_transform = Transform3D(Basis.IDENTITY, t.point)
	var col := Color(1.0, 1.0, 1.0)
	if not t.in_reach:
		col = Color(1.0, 0.25, 0.2)
	elif t.kind == "rock" or t.kind == "tree":
		col = Color(1.0, 0.85, 0.3)
	_fill.set_shader_parameter("col", Color(col.r, col.g, col.b, 0.20))
	_line.set_shader_parameter("col", Color(col.r, col.g, col.b, 0.95))
	# the patch only changes when the target moves, the ground is edited or the rock is hit
	var pt: Vector3 = t.point
	var key := "%s|%d|%.2f,%.2f,%.2f|%.2f" % [t.kind, world.edit_rev, pt.x, pt.y, pt.z, t.rock.hits if t.kind == "rock" else 0.0]
	if key != _key:
		_key = key
		_start_patch(t)

## Start building the patch for target `t`: rings of points around it, each dropped onto the surface (that is the slow part), then triangles between them.
## The work happens in _process, a slice per frame.
func _start_patch(t: Dictionary) -> void:
	var n: Vector3 = t.normal
	var ref := Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD
	var tx := n.cross(ref).normalized()
	var is_rock: bool = t.kind == "rock"
	_job = {"t": t, "n": n, "tx": tx, "tz": tx.cross(n), "rad": t.radius, "rock": is_rock, "tree": t.kind == "tree",
		"frame": RockMesher.frame_of(t.rock) if is_rock else {}, "segs": SEGS_ROCK if is_rock else SEGS, "k": 0, "i": 0,
		"rings": [PackedVector3Array()]}

func _process(_delta: float) -> void:
	if _job.is_empty() or _world == null:
		job_us = 0
		return
	var t0 := Time.get_ticks_usec()
	var t: Dictionary = _job.t
	var centre: Vector3 = t.point
	var rock: RockInst = t.rock if _job.rock else null
	var segs: int = _job.segs
	while Time.get_ticks_usec() - t0 < BUDGET_US:
		var k: int = _job.k
		var i: int = _job.i
		var a := TAU * i / segs
		var p0 := centre + ((_job.tx as Vector3) * cos(a) + (_job.tz as Vector3) * sin(a)) * float(_job.rad) * float(RINGS[k])
		var q: Vector3 = _on_cylinder(p0, t, centre) if _job.tree else _on_surface(_world, p0, _job.n, rock, _job.frame, centre)
		var ring: PackedVector3Array = _job.rings[k]
		ring.append(q)
		_job.rings[k] = ring                                   # (a packed array taken out of an Array is a copy: put it back)
		i += 1
		if i >= segs:
			i = 0
			k += 1
			if k >= RINGS.size():
				_assemble(_job.rings as Array, segs)
				_job = {}
				break
			(_job.rings as Array).append(PackedVector3Array())
		_job.k = k
		_job.i = i
	job_us = Time.get_ticks_usec() - t0
	worst_job_us = maxi(worst_job_us, job_us)

## The patch is complete: its triangles replace the old patch's.
func _assemble(rings: Array, segs: int) -> void:
	var n: Vector3 = _job.n
	_imm.clear_surfaces()
	# translucent area: a fan from the centre to the first ring, then the band to the second
	var fill := PackedVector3Array()
	var c0 := n * 0.04
	for i in segs:
		var j := (i + 1) % segs
		_tri(fill, c0, rings[0][i], rings[0][j])
		_quad(fill, rings[0][i], rings[0][j], rings[1][j], rings[1][i])
	# bright outline: the band between the last two rings
	var line := PackedVector3Array()
	for i in segs:
		var j := (i + 1) % segs
		_quad(line, rings[1][i], rings[1][j], rings[2][j], rings[2][i])
	_draw(fill, _fill)
	_draw(line, _line)

func _draw(verts: PackedVector3Array, mat: Material) -> void:
	if verts.is_empty():
		return
	_imm.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
	for v in verts:
		_imm.surface_add_vertex(v)
	_imm.surface_end()

func _tri(out: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	if a == Vector3.INF or b == Vector3.INF or c == Vector3.INF:
		return
	out.append(a)
	out.append(b)
	out.append(c)

func _quad(out: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(out, a, b, c)
	_tri(out, a, c, d)

## A point of a tree trunk (a cylinder around the trunk's axis), under `p0`, lifted a little off the bark.
func _on_cylinder(p0: Vector3, t: Dictionary, centre: Vector3) -> Vector3:
	var a: Vector3 = t.cyl_a
	var d: Vector3 = t.cyl_d
	var along := clampf((p0 - a).dot(d), 0.0, float(t.cyl_len))
	var on_axis := a + d * along
	var out := (p0 - on_axis)
	if out.length() < 0.001:
		return Vector3.INF
	return on_axis + out.normalized() * (float(t.cyl_r) + 0.03) - centre

## The point of the surface below / above `p0` (along the target's normal), as a position local to the target and lifted a
## little off the surface so it does not flicker against it. Vector3.INF where there is no surface to be found.
func _on_surface(world: VoxelWorld, p0: Vector3, n: Vector3, rock: RockInst, frame: Dictionary, centre: Vector3) -> Vector3:
	if rock != null:
		# the rock's REAL surface under this point: look along the target's normal, from above the rock to below it (a ray from the rock's
		# centre folds the patch into a fan as soon as the rock has a crater)
		var span := maxf(rock.size * 0.8, 0.5)
		var from := p0 + n * span
		var steps := 8
		var prev := 0.0
		for i in range(1, steps + 1):
			var tt := span * 2.0 * i / steps
			if RockMesher._inside(rock, frame, from - n * tt):
				var lo := prev
				var hi := tt
				for k in 3:
					var mid := (lo + hi) * 0.5
					if RockMesher._inside(rock, frame, from - n * mid):
						hi = mid
					else:
						lo = mid
				return from - n * ((lo + hi) * 0.5) + n * 0.03 - centre
			prev = tt
		return Vector3.INF
	var step := 0.3
	var s := 0.0
	if world.density_at(p0) > 0.0:
		# inside the ground: climb out along the normal
		for i in 9:
			if world.density_at(p0 + n * (s + step)) <= 0.0:
				return p0 + n * (_bisect(world, p0, n, s, s + step) + 0.05) - centre
			s += step
	else:
		# in the air: sink along the normal until the ground
		for i in 9:
			if world.density_at(p0 - n * (s + step)) > 0.0:
				return p0 + n * (_bisect(world, p0, n, -s - step, -s) + 0.05) - centre
			s += step
	return Vector3.INF

## Where along the normal the density crosses zero; `s_solid` is solid, `s_air` is air.
func _bisect(world: VoxelWorld, p0: Vector3, n: Vector3, s_solid: float, s_air: float) -> float:
	for i in 4:
		var mid := (s_solid + s_air) * 0.5
		if world.density_at(p0 + n * mid) > 0.0:
			s_solid = mid
		else:
			s_air = mid
	return (s_solid + s_air) * 0.5

## One line for the panel about what is under the tool.
func describe(world: VoxelWorld) -> String:
	if target.kind == "none":
		return "Target  -\n"
	var reach: String = "" if target.in_reach else "  (too far)"
	if target.kind == "ground":
		return "Target  ground%s\n" % reach
	if target.kind == "tree":
		var tr: TreeInst = target.tree
		var ty := world.trees.catalog.by_id(tr.type_id)
		if tr.state == TreeInst.FALLEN:
			return "Target  fallen %s  %.1f m left  %.0f blows%s\n" % [ty.name, tr.remaining, ceilf(world.trees.blows_to_chop(tr) * tr.remaining / maxf(tr.length, 0.1)), reach]
		return "Target  %s  %.0f m tall  %.0f blows left%s\n" % [ty.name, tr.height, ceilf(maxf(world.trees.blows_to_fell(tr) - tr.hits, 0.0)), reach]
	var r: RockInst = target.rock
	var cat := world.rocks.catalog
	var s := "Target  %s" % cat.by_id(r.layers[0][0]).name
	if r.layers.size() > 1:
		s += " with %s core" % cat.by_id(r.layers[1][0]).name
	var left := maxf(world.rocks.layer_hardness(r) - r.hits, 0.0)
	s += "  %.1f m  %.0f blows left%s\n" % [r.size * 2.0, ceilf(left), reach]
	return s
