class_name ToolAim
extends Node3D
## The mouse-aimed tool. The cursor is free; a ray from the camera through it finds what the tool will hit: a rock
## (nearest wins) or the ground. A PATCH that follows the surface shows where and how big the blow is: a translucent
## area with a bright outline, every point of it dropped onto the real surface (the terrain for the ground, the rock's
## own bitten surface for a rock), so it covers the targeted shape and never sinks into the floor or floats over it.
## White inside the player's reach, red outside it (the tool does nothing there). Display + picking only.

const REACH := 4.5                 # metres from the ball: the arm's length; nothing farther can be altered
const GROUND_RADIUS := 2.4         # what one dig removes (same as VoxelWorld.carve in main)
const MAX_RAY := 70.0
const SEGS := 28                   # points around the patch
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
func pick(cam: Camera3D, world: VoxelWorld, player_pos: Vector3, mouse: Vector2) -> Dictionary:
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
	_show(world, t)
	return t

func _show(world: VoxelWorld, t: Dictionary) -> void:
	if t.kind == "none":
		visible = false
		return
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
		_build_patch(world, t)

## Build the patch: rings of points around the target, each dropped onto the surface, then triangles between them.
func _build_patch(world: VoxelWorld, t: Dictionary) -> void:
	var n: Vector3 = t.normal
	var centre: Vector3 = t.point
	var ref := Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD
	var tx := n.cross(ref).normalized()
	var tz := tx.cross(n)
	var rad: float = t.radius
	var is_rock: bool = t.kind == "rock"
	var is_tree: bool = t.kind == "tree"
	var rock: RockInst = t.rock if is_rock else null
	var frame := RockMesher.frame_of(rock) if is_rock else {}
	var rings: Array = []                       # per ring: PackedVector3Array (local to the target; INF = no surface there)
	for k in RINGS.size():
		var ring := PackedVector3Array()
		for i in SEGS:
			var a := TAU * i / SEGS
			var p0 := centre + (tx * cos(a) + tz * sin(a)) * rad * float(RINGS[k])
			ring.append(_on_cylinder(p0, t, centre) if is_tree else _on_surface(world, p0, n, rock, frame, centre))
		rings.append(ring)
	_imm.clear_surfaces()
	# translucent area: a fan from the centre to the first ring, then the band to the second
	var fill := PackedVector3Array()
	var c0 := n * 0.04
	for i in SEGS:
		var j := (i + 1) % SEGS
		_tri(fill, c0, rings[0][i], rings[0][j])
		_quad(fill, rings[0][i], rings[0][j], rings[1][j], rings[1][i])
	# bright outline: the band between the last two rings
	var line := PackedVector3Array()
	for i in SEGS:
		var j := (i + 1) % SEGS
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
		# a rock is star-shaped around its centre: along the direction from the centre the surface is one lookup
		var w := (p0 - rock.pos).normalized()
		var wl := Vector3(w.dot(frame.x), w.dot(frame.y), w.dot(frame.z))
		var l := RockMesher.surface_radius(rock, frame, wl)
		return rock.pos + w * (l + 0.03) - centre
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
