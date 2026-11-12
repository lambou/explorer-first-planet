class_name ToolAim
extends Node3D
## The mouse-aimed tool. The cursor is free; a ray from the camera through it finds what the tool will hit: a rock
## (nearest wins) or the ground. A ring lying on that surface shows where and how big the blow is: white inside the
## player's reach, red outside it (the tool does nothing there). Display + picking only: it never changes the world.

const REACH := 4.5                 # metres from the ball: the arm's length; nothing farther can be altered
const GROUND_RADIUS := 2.4         # what one dig removes (same as VoxelWorld.carve in main)
const MAX_RAY := 70.0

var _ring: MeshInstance3D
var _dot: MeshInstance3D
var _mat: StandardMaterial3D
var reach := REACH                 # debugging aid: main can widen it for screenshots (--reach=)
var target := {"kind": "none"}

func _init() -> void:
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(1, 1, 1, 0.9)
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.render_priority = 2
	var tm := TorusMesh.new()
	tm.inner_radius = 0.93
	tm.outer_radius = 1.0
	tm.rings = 32
	tm.ring_segments = 4
	_ring = MeshInstance3D.new()
	_ring.mesh = tm
	_ring.material_override = _mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	var sm := SphereMesh.new()
	sm.radius = 0.06
	sm.height = 0.12
	sm.radial_segments = 8
	sm.rings = 4
	_dot = MeshInstance3D.new()
	_dot.mesh = sm
	_dot.material_override = _mat
	_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_dot)
	visible = false

## What is under the mouse. `mouse` in viewport pixels. Returns
## {kind: "rock" | "ground" | "none", point, normal, in_reach, radius, rock?, chunk?, t}.
func pick(cam: Camera3D, world: VoxelWorld, player_pos: Vector3, mouse: Vector2) -> Dictionary:
	var origin := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	var ground := world.raycast(origin, dir, MAX_RAY)
	var rock := world.rock_ray(origin, dir, MAX_RAY)
	var t := {"kind": "none"}
	var gt := INF
	if ground.hit:
		gt = origin.distance_to(ground.point)
	if rock.hit and rock.t <= gt + 0.3:
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
	_show(t)
	return t

func _show(t: Dictionary) -> void:
	if t.kind == "none":
		visible = false
		return
	visible = true
	var n: Vector3 = t.normal
	var ref := Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD
	var x := n.cross(ref).normalized()
	var z := x.cross(n)
	var rad: float = t.radius
	global_transform = Transform3D(Basis(x * rad, n * rad, z * rad), t.point + n * 0.05)
	_dot.scale = Vector3.ONE / maxf(rad, 0.1)           # the dot keeps its own size whatever the ring's
	var col := Color(1.0, 1.0, 1.0, 0.9) if t.in_reach else Color(1.0, 0.25, 0.2, 0.75)
	if t.kind == "rock" and t.in_reach:
		col = Color(1.0, 0.85, 0.3, 0.95)
	_mat.albedo_color = col

## One line for the panel about what is under the tool.
func describe(world: VoxelWorld) -> String:
	if target.kind == "none":
		return "Target  -\n"
	var reach: String = "" if target.in_reach else "  (too far)"
	if target.kind == "ground":
		return "Target  ground%s\n" % reach
	var r: RockInst = target.rock
	var cat := world.rocks.catalog
	var s := "Target  %s" % cat.by_id(r.layers[0][0]).name
	if r.layers.size() > 1:
		s += " with %s core" % cat.by_id(r.layers[1][0]).name
	var left := maxf(world.rocks.layer_hardness(r) - r.hits, 0.0)
	s += "  %.1f m  %.0f blows left%s\n" % [r.size * 2.0, ceilf(left), reach]
	return s
