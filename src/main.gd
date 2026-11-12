extends Node3D
## Composition root: wires generator, world, player, camera, sun and HUD.

const R := WorldConfig.PLANET_RADIUS
const DAY_LENGTH := 480.0   # seconds for one full turn of the sun (at least 6 minutes)
const REACH := 8.0
const AXIAL_TILT := 23.4    # degrees: the planet's axis is tilted like the Earth's, which gives latitudes real days, seasons, polar day/night
const YEAR_DAYS := 24.0     # a year lasts this many days

var gen: PlanetGenerator
var world: VoxelWorld
var far: FarTerrain
var player: BallPlayer
var cam: OrbitCamera
var hud: Hud
var debris: RockDebris
var physics: RockPhysics
var aim: ToolAim
var _tool_cd := 0.0           # seconds until the tool may strike again while the button is held
var _vcur := Vector2.ZERO      # the tool's cursor (viewport pixels): moves inside the action perimeter, pushes the camera at its edge
var _pushing := false          # the cursor is against the perimeter and turning the camera
const PERIMETER := 0.30        # radius of the action perimeter as a fraction of the window height
var sun: DirectionalLight3D
var sun_disc: MeshInstance3D
var env: Environment
var sun_angle := 0.8       # the planet's spin (angle of the sun around the polar axis, one turn per day)
var season := 1.0          # position in the year: the sun's declination swings +-AXIAL_TILT
var _hud_timer := 0.0
var _hole := 0.0
var _was_dark := false
var _dark := 0.0       # 0 = the outside world is there, 1 = enclosed underground
var _under := false       # the camera is under water (with hysteresis, see _process)
var _far_hidden := false
var _col := Column.new()
var _repro := {}          # launch options that reproduce a captured view (see _apply_repro)
var _frame := 0
var _sweep: Array = []          # camera sweep (--sweep): the views to try
var _sweep_res: Array = []

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			WorldConfig.world_seed = WorldConfig.parse_seed(a.substr(7))   # a number or any text
		elif a == "--random-seed":
			WorldConfig.world_seed = WorldConfig.random_seed()
		elif a.begins_with("--") and a.contains("="):
			_repro[a.get_slice("=", 0).substr(2)] = a.get_slice("=", 1)
	print("World seed: ", WorldConfig.world_seed)
	gen = PlanetGenerator.new(WorldConfig.world_seed)

	world = VoxelWorld.new()
	add_child(world)
	world.setup(gen)
	debris = RockDebris.new()
	debris.world = world
	add_child(debris)
	physics = RockPhysics.new()
	physics.world = world
	add_child(physics)
	world.terrain_edited.connect(physics.after_edit)      # digging: loose rocks next to it may fall
	far = FarTerrain.new()
	add_child(far)
	far.setup(gen, world.water)

	_setup_environment()

	player = BallPlayer.new()
	add_child(player)
	player.freeze = true
	player.spawn_pos = gen.find_spawn()
	if String(_repro.get("spawn", "")).begins_with("cave"):
		var cs := _cave_spawn_from(Vector3.ZERO, String(_repro.spawn) == "cave-sinkhole")
		if cs != Vector3.ZERO:
			player.spawn_pos = cs
		else:
			print("No cave found for the spawn; using the surface spawn")
	player.position = player.spawn_pos
	# the game starts in the early morning at the spawn: the sun just above the horizon and rising, never at night
	if not _repro.has("sun"):
		sun_angle = SkyDome.sun_angle_for_elevation(player.spawn_pos.normalized(), deg_to_rad(AXIAL_TILT) * sin(season), 0.18, true)

	cam = OrbitCamera.new()
	cam.target = player
	cam.world = world
	cam.far = 20000.0
	add_child(cam)
	cam.current = true
	player.cam = cam
	player.world = world

	hud = Hud.new()
	add_child(hud)
	hud.radar.setup(gen)
	# the mouse aims the tool inside the action perimeter; pushing past its edge turns the camera (see _unhandled_input)
	# capture the mouse only while the window really has focus (started from the editor it may be in the background):
	# otherwise it stays free until the player clicks in the game
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if (DisplayServer.window_is_focused() or _repro.has("pos")) else Input.MOUSE_MODE_VISIBLE
	_vcur = get_viewport().get_visible_rect().size * 0.5
	aim = ToolAim.new()
	add_child(aim)
	_apply_repro()

## Launch options that load the exact view from a captured HUD panel (the panel prints the same numbers):
##   --pos=X,Y,Z  --heading=DEG  --pitch=DEG  --dist=M  --sun=DEG  --shot=path.png  (shot: save the frame and quit)
## The player stays frozen at the position so the view does not drift.
func _apply_repro() -> void:
	if _repro.has("pos"):
		var v := String(_repro.pos).split_floats(",")
		if v.size() == 3:
			player.position = Vector3(v[0], v[1], v[2])
			player.spawn_pos = player.position
	cam.locked = _repro.has("pos")
	if _repro.has("reach"):
		aim.reach = float(_repro.reach)
	if _repro.has("pitch"):
		cam.pitch = deg_to_rad(float(_repro.pitch))
	if _repro.has("dist"):
		cam.distance = float(_repro.dist)
	if _repro.has("sun"):
		sun_angle = deg_to_rad(float(_repro.sun))
	if _repro.has("season"):
		season = deg_to_rad(float(_repro.season))
	if _repro.has("heading"):
		var up := player.position.normalized()
		var north := (Vector3.UP - up * Vector3.UP.dot(up)).normalized()
		var east := Vector3.UP.cross(up).normalized()
		var h := deg_to_rad(float(_repro.heading))
		cam.fwd = north * cos(h) + east * sin(h)

## Compass heading (0 = north, 90 = east) of where the camera looks, along the ground.
func _heading_deg() -> float:
	var up := player.global_position.normalized()
	var north := (Vector3.UP - up * Vector3.UP.dot(up)).normalized()
	var east := Vector3.UP.cross(up).normalized()
	return fposmod(rad_to_deg(atan2(cam.view_fwd.dot(east), cam.view_fwd.dot(north))), 360.0)

func _setup_environment() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = SkyDome.create()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.82      # camera exposure: sunlit sand/grass no longer burn out to white
	env.fog_enabled = true
	env.fog_density = 0.00018
	env.fog_light_color = Color(0.62, 0.70, 0.80)
	env.fog_aerial_perspective = 0.4
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 140.0   # sharp shadows near the player; farther ground is simply lit
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.shadow_blur = 1.4
	add_child(sun)
	sun_disc = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 650.0
	sm.height = 1300.0
	sun_disc.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1, 0.95, 0.7)
	m.disable_fog = true
	sun_disc.material_override = m
	sun_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sun_disc)

## Direction towards the sun. The planet spins about its polar axis (Y) once a day; the axis is tilted against
## the orbit, so over the year the sun's declination goes from +AXIAL_TILT (northern summer) to -AXIAL_TILT.
## Noon elevation at latitude phi is 90 - |phi - declination|: tropics get the sun overhead, the poles get
## months of day or night. (The world itself stays still; only the sun moves, which is the same picture.)
func _sun_dir() -> Vector3:
	var decl := deg_to_rad(AXIAL_TILT) * sin(season)
	return Vector3(cos(decl) * cos(sun_angle), sin(decl), cos(decl) * sin(sun_angle)).normalized()

## Leaving the window (alt-tab, another window in front) frees the mouse; a click in the game takes it back.
func _notification(what: int) -> void:
	if (what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT) and not _repro.has("pos"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _process(delta: float) -> void:
	# safety net: never keep the mouse captured while the window is not the active one
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not _repro.has("pos") and not DisplayServer.window_is_focused():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	world.update_center(player.global_position)
	far.update_center(player.global_position)
	world.set_view(cam.global_position, -cam.global_transform.basis.z)
	hud.radar.set_view(player.global_position, cam.view_fwd, _sun_dir())
	var target_hole := world.covered_radius()
	_hole = target_hole if target_hole < _hole else lerpf(_hole, target_hole, 0.3)
	far.set_hole(player.global_position, _hole)
	if world.underground and not world.enclosed and world.sky_dir != Vector3.ZERO:
		far.set_sky_cut(player.global_position, player.global_position + world.sky_dir * 400.0, 9.0)
	else:
		far.set_sky_cut(Vector3.ZERO, Vector3.ZERO, 0.0)
	_frame += 1
	if _repro.has("aim"):
		_vcur = _repro_mouse()
	aim.pick(cam, world, player.global_position, _vcur)
	var vsize := get_viewport().get_visible_rect().size
	var cstate := 0
	if aim.target.kind != "none":
		cstate = 2 if not aim.target.in_reach else (3 if aim.target.kind == "rock" else 1)
	hud.aim_overlay.update_state(vsize * 0.5, vsize.y * PERIMETER, _vcur, cstate, _pushing, Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	_pushing = false
	_tool_cd -= delta
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and _tool_cd <= 0.0:
		_tool_cd = 0.24
		_use_tool(Input.is_key_pressed(KEY_SHIFT))
	if _repro.has("nofar"):
		far.visible = false          # debugging aid: which layer draws what
	if _repro.has("pos"):
		player.freeze = true                      # hold the captured position
		if _repro.has("dig") and _frame == 300:
			# debugging aid (--dig=x,y,z,r): dig a sphere there, as the tool would
			var dg := String(_repro.dig).split_floats(",")
			if dg.size() == 4:
				world.carve(Vector3(dg[0], dg[1], dg[2]), dg[3])
		if _repro.has("digdown") and _frame == 300:
			# debugging aid (--digdown=N): a shaft N metres deep straight down from the player
			var upd := player.global_position.normalized()
			var k := 0.0
			while k <= float(_repro.digdown):
				world.carve(player.global_position - upd * (k + 1.0), 2.4)
				k += 2.0
		if _repro.has("hit") and _frame == 352:
			_debug_hit(int(_repro.hit))
	elif player.freeze and world.is_area_ready(player.global_position):
		player.freeze = false
	if _repro.has("tunnel") and _frame == 302:
		# debugging aid (--tunnel=LENGTH,DEPTH): a tunnel along the heading, DEPTH metres under the player
		var tv := String(_repro.tunnel).split_floats(",")
		var upt := player.global_position.normalized()
		var fwt := (cam.fwd - upt * cam.fwd.dot(upt)).normalized()
		var base := player.global_position - upt * tv[1]
		var m := 0.0
		while m <= tv[0]:
			world.carve(base + fwt * m, 2.3)
			m += 1.6
	if _repro.has("below") and _frame == 325:
		var upb := player.global_position.normalized()
		player.global_position -= upb * float(_repro.below)       # into the pit / shaft / tunnel that was dug
	if _repro.has("sweep") and _frame >= 340:
		_sweep_step()
	if _repro.has("shot") and _frame == int(_repro.get("shotframe", 360)):          # --shot=file.png works with or without --pos
		# debugging aid: is the camera (or a corner of its near plane) inside solid ground? It never should be.
		var cb := cam.global_transform.basis
		var worst := -9.0
		for off in [Vector3.ZERO, cb.x * 0.35, -cb.x * 0.35, cb.y * 0.25, -cb.y * 0.25, -cb.z * 0.3]:
			worst = maxf(worst, world.density_at(cam.global_position + off + (-cb.z) * cam.near))
		print("CAMERA density (worst of centre and near-plane corners): %.2f  %s   ball %.1f m above ground" % [worst, "INSIDE GROUND" if worst > 0.0 else "ok", player.global_position.length() - R - _col.height])
		get_viewport().get_texture().get_image().save_png(String(_repro.shot))
		get_tree().quit()

	if not _repro.has("sun"):
		sun_angle += delta * TAU / DAY_LENGTH
		season += delta * TAU / (DAY_LENGTH * YEAR_DAYS)
	var sd := _sun_dir()
	sun.look_at_from_position(sd * 1000.0, Vector3.ZERO, Vector3.FORWARD if absf(sd.y) > 0.99 else Vector3.UP)
	sun_disc.global_position = cam.global_position + sd * 16000.0
	var cam_r := cam.global_position.length()
	var up_here := player.global_position.normalized()
	# the sun sets later the higher you stand (the true horizon is below eye level)
	var elev := sd.dot(up_here) - SkyDome.horizon_sine(cam_r)
	var day := smoothstep(-0.15, 0.3, elev)
	env.fog_light_color = SkyDome.horizon_color(sd, up_here, cam_r)     # far terrain fades into the sky's own haze colour
	# eye/camera adaptation: the higher the sun, the lower the exposure (a sun at the zenith no longer burns grass to white)
	env.tonemap_exposure = lerpf(0.95, 0.60, clampf(sd.dot(up_here), 0.0, 1.0))
	env.background_energy_multiplier = 1.0      # the sky shader does its own night
	SkyDome.update(env.sky, sd, cam.global_position.normalized(), float(_repro.get("cover", 0.55)), cam_r)
	env.ambient_light_energy = lerpf(0.05, 0.36, day)
	sun.light_energy = day * 0.72
	# Enclosed underground (no sky in sight): the outside world does not exist. No far terrain, sky,
	# sun or fog, so unbuilt rock can never show the outdoors through a gap; the cave is simply dark.
	# A cave with an opening that lets the sky in keeps the normal daylight and shadows.
	_dark = move_toward(_dark, 1.0 if world.enclosed else 0.0, delta * 3.0)
	# underwater state of the CAMERA with hysteresis: waves/bobbing at the surface must never flip the whole
	# look back and forth (that was the blink). Enter at 0.1 m under, leave at 0.1 m above.
	var cam_sub := world.submersion(cam.global_position)
	if cam_sub > 0.1:
		_under = true
	elif cam_sub < -0.1:
		_under = false
	# the far terrain disappears only well below the surface (and returns well above it): no popping
	if _under and cam_sub > 2.0:
		_far_hidden = true
	elif not _under or cam_sub < 0.5:
		_far_hidden = false
	far.visible = _dark < 0.5 and not _far_hidden
	sun_disc.visible = _dark < 0.5 and not _under
	env.background_mode = Environment.BG_SKY if _dark < 0.5 else Environment.BG_COLOR   # UnderwaterEffect overrides this below when submerged
	env.background_color = Color.BLACK
	env.fog_enabled = _dark < 0.5
	# the sky's ambient light keeps lighting surfaces even at energy 0: while enclosed, take the sky
	# out of the picture altogether (ambient = plain black, no sky reflections)
	var dark_now := _dark >= 0.5
	if dark_now != _was_dark:
		_was_dark = dark_now
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR if dark_now else Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_color = Color.BLACK
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED if dark_now else Environment.REFLECTION_SOURCE_BG
	env.ambient_light_energy *= (1.0 - _dark)
	sun.light_energy *= (1.0 - _dark)

	# water: the state of the sea here, and the camera under the surface (all in src/water/)
	world.water.update_state(player.global_position, Time.get_ticks_msec() / 1000.0)
	# a camera hugging the water surface would clip the nearest bit of the surface (near plane) and see through
	# it: the closer to the surface, the smaller the near plane (0.3 m normally, down to 0.04 m)
	cam.near = clampf(absf(cam_sub) * 0.7, 0.04, 0.3)
	# the air look is set first, every frame; the underwater effect blends from it
	env.fog_density = 0.00018
	env.fog_sky_affect = 1.0
	if not UnderwaterEffect.apply(env, sun, cam_sub, day):
		UnderwaterEffect.reset(sun, env)

	if _repro.has("nofar"):
		far.visible = false
	if player.global_position.length() < 100.0:   # fell to the planet's core
		player.respawn()

	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.1
		_update_hud(day)

func _update_hud(day: float) -> void:
	var p := player.global_position
	var r := p.length()
	gen.sample_column(p / r, _col)
	var ground := _col.height
	var alt := r - R
	var lon := rad_to_deg(atan2(p.z, p.x))
	hud.set_text("EXPLORER UNIVERSE\n"
		+ "seed %d\n" % WorldConfig.world_seed
		+ "X  %.1f\nY  %.1f\nZ  %.1f\n" % [p.x, p.y, p.z]
		+ "Altitude  %+.1f m\n" % alt
		+ "Ground  %+.1f m\n" % ground
		+ "Above ground  %.1f m\n" % (alt - ground)
		+ "Limits  +%d / -%d m\n" % [WorldConfig.MAX_HEIGHT, WorldConfig.max_depth_to_core()]
		+ "Lat %.0f  Lon %.0f\n" % [_col.latitude * 90.0, lon]
		+ "Temp %.2f  Moist %.2f\n" % [_col.temperature, _col.moisture]
		+ "%s\n" % ("Land" if _col.land > 0.0 else "Ocean")
		+ "Daylight  %.0f%%   Sun %.0f  Season %.0f  Decl %+.0f\n" % [day * 100.0, fposmod(rad_to_deg(sun_angle), 360.0), fposmod(rad_to_deg(season), 360.0), AXIAL_TILT * sin(season)]
		+ "Camera  heading %.0f  pitch %.0f  dist %.1f\n" % [_heading_deg(), rad_to_deg(cam.pitch), cam.distance]
		+ "Water  %s%s\n" % [world.water.state_name(), "  (camera under)" if _under else ""]
		+ "%s\n" % world.stats().replace("  building", " | build")
		+ "%s\n" % far.stats().replace("  building", " | build")
		+ "%s   FPS %d\n\n" % ["FLY" if player.fly else "ROLL", Engine.get_frames_per_second()]
		+ aim.describe(world)
		+ _harvest_text()
		+ "[WASD] move\n[Space] jump / swim up\n[Ctrl] dive\n[F] fly\n[R] respawn\n[C] cave spawn (Shift: sinkhole)\n[LMB] break / dig (hold)\n[RMB] place stone\n[mouse past the circle] turn camera\n"
		+ "[wheel / +/-] radar zoom\n[Ctrl+wheel] camera\n[Esc] free mouse")

## The nearest cave of either kind: a closed room (dark, fine) or a sinkhole floor open to the sky (daylight).
## `lit`: only the sinkhole kind (a shaft up to the sky; whether daylight really reaches is up to the sky detection).
func _cave_spawn_from(from_dir: Vector3, lit: bool) -> Vector3:
	var open_cave := gen.find_cave_spawn(from_dir, true)
	if lit or from_dir == Vector3.ZERO:
		if open_cave != Vector3.ZERO or lit:
			return open_cave
	var closed := gen.find_cave_spawn(from_dir, false)
	if open_cave == Vector3.ZERO:
		return closed
	if closed == Vector3.ZERO:
		return open_cave
	return open_cave if open_cave.angle_to(from_dir) <= closed.angle_to(from_dir) else closed

## Debugging aid (--sweep): after the digs, try many camera headings / pitches / distances around the player and
## measure each view: is the camera (or a corner of its near plane) inside the ground or touching it, and does solid ground
## lie between the camera and the ball? Prints a summary and the worst views, then quits.
func _sweep_step() -> void:
	const SETTLE := 9
	if _sweep.is_empty() and _sweep_res.is_empty():
		for h in [0.0, 60.0, 120.0, 180.0, 240.0, 300.0]:
			for pt in [-10.0, 5.0, 25.0, 55.0, 80.0]:
				for d in [4.0, 10.0, 22.0]:
					_sweep.append(Vector3(h, pt, d))
		_sweep_res.append("started")
	var k := (_frame - 340) / SETTLE
	var phase := (_frame - 340) % SETTLE
	if k >= _sweep.size():
		_sweep_report()
		return
	var v: Vector3 = _sweep[k]
	if phase == 0:
		var up := player.global_position.normalized()
		var north := (Vector3.UP - up * Vector3.UP.dot(up)).normalized()
		var east := Vector3.UP.cross(up).normalized()
		cam.fwd = north * cos(deg_to_rad(v.x)) + east * sin(deg_to_rad(v.x))
		cam.pitch = deg_to_rad(v.y)
		cam.distance = v.z
	elif phase == SETTLE - 1:
		var cb := cam.global_transform.basis
		var worst := -9.0
		for off in [Vector3.ZERO, cb.x * 0.45, -cb.x * 0.45, cb.y * 0.3, -cb.y * 0.3, -cb.z * 0.3, -cb.z * 0.3 + cb.x * 0.45, -cb.z * 0.3 - cb.x * 0.45]:
			worst = maxf(worst, world.density_at(cam.global_position + off))
		# inside a rock? (rocks are not part of the density field)
		var in_rock := false
		for c: Vector3i in world.chunks:
			var ch: Chunk = world.chunks[c]
			if ch.rocks.is_empty() or (ch.position + Vector3.ONE * 8.0).distance_to(cam.global_position) > 30.0:
				continue
			for r: RockInst in ch.rocks:
				if r.pos.distance_to(cam.global_position) > r.size * 1.9 + 1.0:
					continue
				var rf := RockMesher.frame_of(r)
				for off in [Vector3.ZERO, cb.x * 0.45, -cb.x * 0.45, cb.y * 0.3, -cb.y * 0.3, -cb.z * 0.3]:
					if RockMesher._inside(r, rf, cam.global_position + off):
						in_rock = true
		var pivot := player.global_position + player.global_position.normalized() * 0.5
		var blocked := 0
		for i in range(1, 12):
			if world.density_at(cam.global_position.lerp(pivot, i / 12.0)) > 0.0:
				blocked += 1
		var arm := cam.global_position.distance_to(pivot)
		_sweep_res.append({"view": v, "worst": worst, "blocked": blocked, "arm": arm, "rock": in_rock, "hidden": not player.visible, "pitch_now": rad_to_deg(cam.pitch + cam._lift), "swing": rad_to_deg(cam._yaw_off)})

func _sweep_report() -> void:
	var inside := 0
	var tight := 0
	var blocked := 0
	var rocks_in := 0
	var rock_list: Array = []
	var n := 0
	var worst_list: Array = []
	var block_list: Array = []
	for r in _sweep_res:
		if not (r is Dictionary):
			continue
		n += 1
		if r.rock:
			rocks_in += 1
			rock_list.append(r)
		if r.worst > 0.0:
			inside += 1
			worst_list.append(r)
		elif r.worst > -0.15:
			tight += 1
		if r.blocked > 0 and r.arm > 1.2:
			blocked += 1
			block_list.append(r)
	var pulled := 0
	var hidden := 0
	var topdown := 0
	var swung := 0
	var min_arm := 99.0
	var closest := -99.0
	for r in _sweep_res:
		if r is Dictionary:
			if r.arm < r.view.z - 0.6:
				pulled += 1
			if r.hidden:
				hidden += 1
			if r.pitch_now > 70.0:
				topdown += 1
			if absf(r.swing) > 20.0:
				swung += 1
			min_arm = minf(min_arm, r.arm)
			closest = maxf(closest, r.worst)
	gen.sample_column(player.global_position.normalized(), _col)
	print("SWEEP scene: ball is %.1f m above the ground there; camera pulled in short of its distance in %d of %d views, shortest arm %.1f m, tightest clearance %.2f m" % [player.global_position.length() - R - _col.height, pulled, n, min_arm, -closest])
	print("SWEEP the ball is hidden in %d views; the camera went (nearly) overhead in %d and swung round the ball in %d" % [hidden, topdown, swung])
	print("SWEEP %d views: %d INSIDE the ground, %d INSIDE a rock, %d touching (<15 cm), %d with ground between camera and ball" % [n, inside, rocks_in, tight, blocked])
	for r in rock_list.slice(0, 3):
		print("  IN ROCK  heading %.0f pitch %.0f dist %.0f   arm %.1f" % [r.view.x, r.view.y, r.view.z, r.arm])
	for r in worst_list.slice(0, 4):
		print("  INSIDE   heading %.0f pitch %.0f dist %.0f   worst %.2f  arm %.1f" % [r.view.x, r.view.y, r.view.z, r.worst, r.arm])
	for r in block_list.slice(0, 4):
		print("  BLOCKED  heading %.0f pitch %.0f dist %.0f   solid samples %d/11  arm %.1f" % [r.view.x, r.view.y, r.view.z, r.blocked, r.arm])
	get_tree().quit()

## Debugging aid (--hit=N): N blows with the tool at the current aim, as if the player held the button.
func _debug_hit(n: int) -> void:
	for i in n:
		aim.pick(cam, world, player.global_position, _repro_mouse())
		if aim.target.kind == "none":
			print("nothing under the tool")
			return
		print("blow ", i + 1, ": ", _use_tool(false))

func _repro_mouse() -> Vector2:
	if _repro.has("aim"):
		var a := String(_repro.aim).split_floats(",")
		if a.size() == 2:
			return Vector2(a[0], a[1])
	return _vcur

## One use of the tool at what the mouse points at: a rock is bitten into (loses its shell, then breaks);
## otherwise the ground is dug. `place`: put stone there instead. Returns a short description.
func _use_tool(place: bool) -> String:
	var t: Dictionary = aim.target
	if t.kind == "none" or not t.in_reach:
		return "out of reach" if t.kind != "none" else "nothing"
	if place:
		world.fill(t.point + t.normal * 1.2, 1.8, BlockTypes.STONE)
		return "placed"
	if t.kind == "rock":
		var res := world.hit_rock(t)
		var n: int = {"hit": 2, "shed": 7, "broken": 11}[res.event]
		n = int(n * (1.0 + t.rock.size))              # a big rock throws more pieces
		debris.burst(t.point, t.normal, res.colors, n, 0.10 + 0.07 * t.rock.size)
		return "%s %s (%d units)" % [res.event, res.type, res.units]
	world.carve(t.point, 2.4)
	_ground_debris(t.point)
	return "dug"

## Pieces of ground flying off where the terrain is dug (they vanish; the dug hole is the real change).
func _ground_debris(p: Vector3) -> void:
	var d := p.normalized()
	var col := Column.new()
	gen.sample_column(d, col)
	var alt := p.length() - R
	var ground_col: Color = gen.surface.color_for(col) if alt > col.height - 3.0 else BlockTypes.COLORS[BlockTypes.STONE]
	debris.burst(p, d, [ground_col, ground_col.darkened(0.2), BlockTypes.COLORS[BlockTypes.STONE]], 6, 0.16)

## [C]: move to the floor of the nearest cave (open or closed; this becomes the respawn point too).
## Shift+C: the nearest sinkhole floor (a shaft open to the sky).
func _spawn_in_cave() -> void:
	var cs := _cave_spawn_from(player.global_position.normalized(), Input.is_key_pressed(KEY_SHIFT))
	if cs == Vector3.ZERO:
		print("No cave found")
		return
	player.spawn_pos = cs
	player.freeze = true          # held until the cave around is built
	player.respawn()
	_hole = 0.0

func _harvest_text() -> String:
	if world.rocks.inventory.is_empty():
		return ""
	return "Harvest\n" + world.rocks.inventory_text() + "\n"

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_F: player.toggle_fly()
			KEY_R: player.respawn()
			KEY_C: _spawn_in_cave()
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not _repro.has("aim"):
		# the cursor roams inside the action perimeter; what would take it beyond the edge turns the camera
		var vsize := get_viewport().get_visible_rect().size
		var centre := vsize * 0.5
		var radius := vsize.y * PERIMETER
		var np: Vector2 = _vcur + event.relative
		var off: Vector2 = np - centre
		if off.length() > radius:
			var edge: Vector2 = centre + off.normalized() * radius
			cam.turn(np - edge)                  # only the outward push
			np = edge
			_pushing = true
		_vcur = np
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED           # back into the game (this click does nothing else)
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			aim.pick(cam, world, player.global_position, _vcur)
			_use_tool(true)                                          # place stone where the tool points
