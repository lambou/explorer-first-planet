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
var rescue: PlayerRescue
var hud: Hud
var debris: RockDebris
var physics: RockPhysics
var tree_fall: TreePhysics
var far_trees: FarTrees
var aim: ToolAim
var kit: PlayerKit            # what the explorer carries and owns (data); the Hud shows it
var tool_user: ToolUser       # what a tool does to the world
var autosave: Autosave           # saves everything done in the world, by itself
var _snapshot := WorldSnapshot.new()
var _playtime := 0.0          # seconds played (saved)
var tree_fade := TreeFade.new()  # which trees block the view and fade (the shader does the fading)
var torches: PlacedTorches    # the torches planted in the world
var _aiming := false          # the mouse is held by the game (playing, window active, no menu): the crosshair is live
var character: PlayerCharacter  # the explorer's looks (the ball is only his physics)
var rig: ToolRig              # the tool in the ball's hand, animated; says when the blow lands
var _tool_cd := 0.0           # short cooldown between strikes (guards rapid re-clicks)
var _lmb_prev := false        # left button state last frame, for click-edge detection
var _vcur := Vector2.ZERO      # where the tool aims on screen: the crosshair, the middle of the window (--aim= moves it for tests)
var playing := true                # false while Boot shows the loading screen: the world builds, nothing answers the player yet
var _has_focus := true             # the window is the active one (from the focus events)
var _mouse_freed := false          # Esc: the mouse is given back until the next click
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

const BOOT_SCENE := "res://src/boot/boot.tscn"

func _ready() -> void:
	# Run on its own (F6 on this scene, no debugging options) the game would skip the menu: go through it, like the project does.
	if get_parent() == get_tree().root and OS.get_cmdline_user_args().is_empty():
		set_process(false)
		set_process_input(false)
		set_process_unhandled_input(false)
		set_physics_process(false)
		get_tree().change_scene_to_file.call_deferred(BOOT_SCENE)
		return
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
	if _repro.has("loadsave"):                           # debugging aid (--loadsave=file): play a COPY of a saved game; the debugging runs never save
		SaveGame.path = String(_repro.loadsave)
		SaveGame.pending = SaveGame.read()
	var saved := SaveGame.pending                       # a saved game (the menu's Continue): its world part goes back before any chunk is built
	SaveGame.pending = {}
	if not saved.is_empty():
		WorldSnapshot.restore_world(saved, world)
	debris = RockDebris.new()
	debris.world = world
	add_child(debris)
	physics = RockPhysics.new()
	physics.world = world
	physics.debris = debris
	add_child(physics)
	world.rock_piece_shed.connect(physics.drop_piece)     # a rock cut in two: the unsupported piece falls
	world.terrain_edited.connect(physics.after_edit)    # digging: loose rocks next to it may fall
	far_trees = FarTrees.new()
	far_trees.setup(gen, world.trees.field)
	add_child(far_trees)
	tree_fall = TreePhysics.new()
	tree_fall.world = world
	add_child(tree_fall)
	world.terrain_edited.connect(tree_fall.after_edit)    # digging: trees whose ground is gone fall
	tree_fall.landed.connect(_on_tree_landed)
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

	kit = PlayerKit.new()
	kit.harvester.bind_world(gen, world.rocks, world.trees)
	tool_user = ToolUser.new()
	tool_user.world = world
	tool_user.gen = gen
	tool_user.debris = debris
	tool_user.physics = physics
	tool_user.tree_fall = tree_fall
	tool_user.kit = kit
	torches = PlacedTorches.new()
	torches.world = world
	add_child(torches)
	torches.dropped.connect(func(id: String, left: float) -> void:
		kit.belt.add(id, 1, left)
		hud.say("A torch fell: its ground was dug away"))
	torches.burnt_out.connect(func() -> void: hud.say("A torch burnt out", UiTheme.WARN))
	rescue = PlayerRescue.new()                          # a player lost deep inside the ground is put back on the surface above
	rescue.player = player
	rescue.world = world
	rescue.gen = gen
	add_child(rescue)
	rescue.rescued.connect(func(depth: float) -> void: print("RESCUE moved from %d m inside the ground to %s" % [int(depth), player.global_position]); hud.say("You were %d m inside the ground: moved to the surface above" % int(depth), UiTheme.WARN))
	tool_user.torches = torches

	hud = Hud.new()
	add_child(hud)
	hud.bind(kit)
	hud.radar.setup(gen)
	# the mouse turns the camera, instantly (see _input); the crosshair in the middle of the screen is where the tool aims
	# the mouse is held in the window only while the game is being played AND the window is the active one (see _process)
	_has_focus = DisplayServer.window_is_focused()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.visible = playing
	hud.enabled = playing
	_vcur = get_viewport().get_visible_rect().size * 0.5
	aim = ToolAim.new()
	add_child(aim)
	rig = ToolRig.new()
	rig.setup(player, cam, kit)
	add_child(rig)
	rig.struck.connect(_on_tool_struck)
	character = PlayerCharacter.new()
	add_child(character)
	character.setup(player, rig)
	rig.character = character
	autosave = Autosave.new()
	autosave.capture = _capture_save
	add_child(autosave)
	if not saved.is_empty():
		var clock := WorldSnapshot.restore_player(saved, player, kit, torches)
		sun_angle = clock.sun_angle
		season = clock.season
		_playtime = clock.playtime
	# everything done in the world is saved shortly after (and every 30 s, and at close)
	world.terrain_edited.connect(func(_c: Vector3, _r: float) -> void: autosave.request())
	kit.inventory.changed.connect(autosave.request)
	kit.belt.changed.connect(autosave.request)
	tree_fall.landed.connect(func(_t: TreeInst, _p: Vector3, _c: Array) -> void: autosave.request())
	autosave.enabled = playing and (_repro.is_empty() or _repro.has("save"))       # the debugging runs never save (unless --save=1)
	_apply_repro()

## Launch options that load the exact view from a captured HUD panel (the panel prints the same numbers):
##   --pos=X,Y,Z  --heading=DEG  --pitch=DEG  --dist=M  --sun=DEG  --shot=path.png  (shot: save the frame and quit)
## Survival aids: --give=clay:6,rock:granite:3  (items into the pack)  --tool=ID  --menu=1  (inventory screen open)
##   --roll=SPEED (the player is pushed sideways at that m/s)  --jump=FRAME  --turnaround=1 (the character faces the camera)
##   --behindtree=1 (the player is moved 5 m behind the nearest tree, as seen from the camera: it blocks the view)
##   --stairs=1 (a 0.3 m step under the character, to see the boots take different heights)
##   --use=FRAME  (one use of the tool in hand at that frame, at the cursor / --aim)  --addtool=torch  --plant=FRAME  --pickup=FRAME
## The player stays frozen at the position so the view does not drift.
func _apply_repro() -> void:
	if _repro.has("give"):
		for part: String in String(_repro.give).split(","):
			var f := part.split(":")
			var id := f[0] if f.size() < 3 else f[0] + ":" + f[1]
			if id.begins_with("rock:"):
				kit.harvester.rock_item(id.get_slice(":", 1))
			kit.inventory.add(id, int(f[f.size() - 1]))
	if _repro.has("addtool"):
		kit.belt.add(String(_repro.addtool))
	if _repro.has("tool"):
		kit.belt.select_id(String(_repro.tool))
	if _repro.has("menu"):
		hud.set_menu_open(true)
	if _repro.has("pos"):
		var v := String(_repro.pos).split_floats(",")
		if v.size() == 3:
			player.position = Vector3(v[0], v[1], v[2])
			player.spawn_pos = player.position
	cam.locked = _repro.has("pos")
	if _repro.has("wind"):
		world.grass.forced_wind = float(_repro.wind)
	if _repro.has("reach"):
		aim.reach = float(_repro.reach)
	if _repro.has("tilt"):
		cam.tilt = deg_to_rad(float(_repro.tilt))
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

## The mouse is held only while the game is played with its window active (see _process); the moment the window loses focus it is let go.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_has_focus = true
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_has_focus = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if autosave != null:
			autosave.request()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST and autosave != null:
		autosave.save_now()                              # closing the game: the save is written at once

## The loading screen asks: how much of the starting ground is built (0..1), and may the game start.
func loading_progress() -> float:
	return world.area_progress(player.global_position) if world != null and player != null else 0.0

func is_ready_to_play() -> bool:
	return world != null and player != null and not player.freeze and world.is_area_ready(player.global_position)

## The loading screen is gone: the game answers the player now.
func begin_play() -> void:
	playing = true
	hud.visible = true
	hud.enabled = true
	_mouse_freed = false
	autosave.enabled = _repro.is_empty() or _repro.has("save")

func _process(delta: float) -> void:
	if playing:
		_playtime += delta
	# the mouse: held (captured) while the game is played with its window active, no menu open and Esc not pressed; otherwise it is an ordinary
	# cursor. Decided afresh every frame from the window's focus, so it can never stay held in a window that is in the background.
	var tests := not _repro.is_empty()                 # the debugging runs never take the mouse
	var focused := _has_focus and DisplayServer.window_is_focused()
	var held := playing and focused and not hud.menu_open() and not _mouse_freed and not tests
	var wanted := Input.MOUSE_MODE_CAPTURED if held else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != wanted:
		Input.mouse_mode = wanted
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
	var vsize := get_viewport().get_visible_rect().size
	_vcur = _repro_mouse() if _repro.has("aim") else vsize * 0.5
	var aiming := _repro.has("aim") or held
	_aiming = aiming
	# the character faces where the camera faces, and his head follows how far the camera looks up or down
	character.aim_dir = cam.view_fwd
	var cup := player.global_position.normalized()
	character.look_pitch = asin(clampf((-cam.global_transform.basis.z).dot(cup), -1.0, 1.0))
	if aiming:
		aim.pick(cam, world, player.global_position, _vcur)
	else:
		aim.clear()
	var cstate := 0
	if aim.target.kind != "none":
		cstate = 2 if not aim.target.in_reach else (3 if aim.target.kind == "rock" else 1)
	hud.aim_overlay.update_state(_vcur, cstate, aiming)
	_tool_cd -= delta
	kit.update(delta)
	# one use per click: holding the button does not repeat. The tool swings first; the world changes when it lands (_on_tool_struck)
	var lmb := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if lmb and not _lmb_prev and aiming and _tool_cd <= 0.0 and not rig.busy:
		if Input.is_key_pressed(KEY_SHIFT) and kit.belt.current_id() == "pickaxe":
			_use_tool(true)                          # Shift + click: place stone where the pickaxe points (an old debug aid)
		else:
			_begin_tool_use()
	_lmb_prev = lmb
	if _repro.has("use") and _frame == int(_repro.use):
		_begin_tool_use()
	if _repro.has("roll"):
		var upr := player.global_position.normalized()
		var rr := cam.view_fwd.cross(upr).normalized()
		if _repro.has("toward"):
			rr = -cam.view_fwd                       # --toward=1: towards the camera, face first
		var vr := player.linear_velocity
		player.linear_velocity = rr * float(_repro.roll) + upr * vr.dot(upr)
	if _repro.has("jump") and _frame == int(_repro.jump):
		player.apply_central_impulse(player.global_position.normalized() * BallPlayer.JUMP_IMPULSE)
	if _repro.has("turnaround") and _frame < 340:
		character.facing = -cam.view_fwd
	if _repro.has("behindtree") and _frame == 200:
		var best: TreeInst = null
		for c3: Vector3i in world.chunks:
			for tt: TreeInst in (world.chunks[c3] as Chunk).trees:
				if tt.state == TreeInst.STANDING and tt.height > 8.0 and tt.pos.distance_to(player.global_position) < 40.0:
					if best == null or tt.pos.distance_to(player.global_position) < best.pos.distance_to(player.global_position):
						best = tt
		if best != null:
			var upt := best.pos.normalized()
			var ft := (cam.view_fwd - upt * cam.view_fwd.dot(upt)).normalized()
			player.global_position = best.pos + ft * 5.0 + upt * 1.0
			player.linear_velocity = Vector3.ZERO
			cam.distance = 9.0
			print("BEHINDTREE tree %.1f m high, crown radius %.1f" % [best.height, best.canopy_r])
	if _repro.has("stairs") and _frame == 200:
		_debug_stairs()
	if _repro.has("plant") and _frame == int(_repro.plant):
		_place_torch()
	if _repro.has("pickup") and _frame == int(_repro.pickup):
		_pickup_torch()
	if _repro.has("nofar"):
		far.visible = false          # debugging aid: which layer draws what
	if _repro.has("pos"):
		player.freeze = true                      # hold the captured position
		if _repro.has("dig") and _frame == 300:
			# debugging aid (--dig=x,y,z,r): dig a sphere there, as the tool would
			var dg := String(_repro.dig).split_floats(",")
			if dg.size() == 4:
				world.carve(Vector3(dg[0], dg[1], dg[2]), dg[3])
		if _repro.has("seq") and _frame >= 340:
			_seq_step()
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
	if _repro.has("camtest") and _frame >= 340:
		_camtest_step()
	if _repro.has("rockfall") and _frame >= 340:
		_rockfall_step()
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
		# debugging aid: how far is the ball's surface inside the ground? (density at 14 points of its 0.5 m sphere; > 0 = inside)
		var ball_p := player.global_position
		var bworst := -9.0
		var bcentre := world.density_at(ball_p)
		for dv in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK, Vector3(1, 1, 1).normalized(), Vector3(-1, 1, 1).normalized(), Vector3(1, -1, 1).normalized(), Vector3(-1, -1, 1).normalized(), Vector3(1, 1, -1).normalized(), Vector3(-1, 1, -1).normalized(), Vector3(1, -1, -1).normalized(), Vector3(-1, -1, -1).normalized()]:
			bworst = maxf(bworst, world.density_at(ball_p + dv * 0.5))
		print("RENDER primitives %d, draw calls %d, objects %d, frame %.1f ms, fps %d" % [Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_FPS)])
		print("BALL centre density %.2f, worst surface point %.2f  %s" % [bcentre, bworst, "PARTLY IN THE GROUND" if bworst > 0.25 and bcentre < 0.0 else ("buried" if bcentre >= 0.0 else "ok")])
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
	far_trees.update(player.global_position, delta)          # the far forest: flat cards beyond the streamed chunks
	world.grass.update(Time.get_ticks_msec() / 1000.0, player.global_position)       # the wind and the player, shared by all grass
	# a camera hugging the water surface would clip the nearest bit of the surface (near plane) and see through
	# it: the closer to the surface, the smaller the near plane (0.3 m normally, down to 0.04 m)
	cam.near = clampf(absf(cam_sub) * 0.7, 0.04, 0.3)
	# the air look is set first, every frame; the underwater effect blends from it
	env.fog_density = 0.00018
	env.fog_sky_affect = 1.0
	if not UnderwaterEffect.apply(env, sun, cam_sub, day):
		UnderwaterEffect.reset(sun, env)
	# trees between the camera and the player fade out (dithered), and so does a crown the camera is inside
	RenderingServer.global_shader_parameter_set("tree_cam", Vector4(cam.global_position.x, cam.global_position.y, cam.global_position.z, 0.0))
	tree_fade.update(world.chunks, cam.global_position, player.global_position + player.global_position.normalized() * 0.5, delta)     # whole trees in the line of sight fade
	RenderingServer.global_shader_parameter_set("tree_target", Vector4(player.global_position.x, player.global_position.y, player.global_position.z, 0.0))
	world.grass.set_light(sd, sun.light_color, sun.light_energy, env.ambient_light_energy)    # the grass is lit by hand with what the sun and the water just ended up with

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
		+ "%s\n" % physics.stats()
		+ "%s   FPS %d\n\n" % ["FLY" if player.fly else "ROLL", Engine.get_frames_per_second()]
		+ aim.describe(world)
		+ "[WASD] move (relative to the camera)\n[Space] jump / swim up\n[Ctrl] dive\n[F] fly\n[R] respawn\n[C] cave spawn (Shift: sinkhole)\n[mouse] look around (the cross in the middle is the tool aim)\n[LMB] use the tool   [Esc] free the mouse\n[Q] next tool   [1-9] bar slot   [Tab / I] inventory\n[T] plant a torch   [E] pick it up\n[Shift+LMB] place stone (pickaxe)\n"
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

## Debugging aid (--seq=prefix): farm the biggest rock near the player completely. Every 10 frames one blow with the tool, aimed at the rock
## (the cursor is placed on it), then a screenshot "<prefix>_<blow>.png" and a line with what is left of the rock. Quits after the rock is gone.
var _seq_rock: RockInst = null
var _seq_blow := 0
var _seq_wait := 0
func _seq_gone() -> bool:
	var st = world.rocks.changed.get(_seq_rock.id)
	return st is bool and st
func _seq_step() -> void:
	aim.reach = 50.0
	if _seq_rock == null:
		var best: RockInst = null
		for c: Vector3i in world.chunks:
			for r: RockInst in (world.chunks[c] as Chunk).rocks:
				if r.size >= 1.3 and r.pos.distance_to(player.global_position) < 24.0 and not r.deposit:
					if best == null or r.size > best.size:
						best = r
		if best == null:
			print("SEQ no big rock near the player")
			get_tree().quit()
			return
		_seq_rock = best
		# a clean study view: no grass or trees in front, no panel, the camera close to the rock from the side
		for c2: Vector3i in world.chunks:
			var ch2: Chunk = world.chunks[c2]
			for k in ch2.grass_nodes:
				(ch2.grass_nodes[k] as Node3D).visible = false
			if ch2.tree_instance != null:
				ch2.tree_instance.visible = false
			if ch2.tree_far != null:
				ch2.tree_far.visible = false
		far_trees.visible = false
		hud.visible = false
		var upq := best.pos.normalized()
		var sidev := upq.cross(Vector3.UP).normalized()
		player.global_position = best.pos + sidev * (best.size * 2.2 + 2.2) + upq * 0.5
		player.freeze = true
		cam.pitch = 0.18
		cam.distance = 5.0
		var to_rock := (best.pos - player.global_position)
		to_rock -= upq * to_rock.dot(upq)
		cam.fwd = to_rock.normalized()
		print("SEQ rock size %.2f m, layers %s, %d blows needed" % [best.size, best.layers, int(ceilf(world.rocks.layer_hardness(best)))])
		return
	_seq_wait += 1
	var sp := cam.unproject_position(_seq_rock.pos)
	_vcur = sp
	if _seq_wait == 3:
		aim.pick(cam, world, player.global_position, _vcur)
		if aim.target.kind != "rock":
			print("SEQ the cursor is not on the rock (target %s)" % aim.target.kind)
		_use_tool(false)
		_seq_blow += 1
	elif _seq_wait == 5:
		if _seq_blow in [2, 6, 12, 18, 24]:
			get_viewport().get_texture().get_image().save_png("%s_%02d_just.png" % [String(_repro.seq), _seq_blow])      # right after the click, the new shape not ready yet
	elif _seq_wait == 40:
		var left := 0.0 if _seq_gone() else RockMesher.volume_fraction(_seq_rock)
		var tris := 0
		for c: Vector3i in world.chunks:
			var ch: Chunk = world.chunks[c]
			if ch.rock_instance != null and ch.rocks.has(_seq_rock):
				tris = (ch.rock_instance.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3
		print("SEQ blow %2d  rock left %3.0f%%  bites %d  size %.2f  chunk rock mesh %d triangles" % [_seq_blow, left * 100.0, _seq_rock.bites.size(), _seq_rock.size, tris])
		get_viewport().get_texture().get_image().save_png("%s_%02d.png" % [String(_repro.seq), _seq_blow])
	elif _seq_wait >= 42:
		_seq_wait = 0
		if _seq_gone() or _seq_blow > 80:
			print("SEQ done after %d blows" % _seq_blow)
			get_tree().quit()

## Debugging aid (--rockfall=prefix [--mode=undercut|chip] [--rocksize=m]): watch a rock fall FRAME BY FRAME. A loose rock near the player is found,
## the camera is put beside it, then (undercut) the ground under it is dug away, or (chip) the pickaxe strikes its underside until it lets go.
## Every frame from the first blow/dig until it has rested (and a few more) is saved as "<prefix>_<frame>.png" with a line of numbers
## (position, speed, spin, contact points). Run with --fixed-fps 60 so one frame is one physics step.
var _rf_rock: RockInst = null
var _rf_phase := 0
var _rf_t := 0
var _rf_start := Vector3.ZERO
var _rf_rest := 0
var _rf_blows := 0
func _rockfall_step() -> void:
	aim.reach = 50.0
	var prefix := String(_repro.rockfall)
	if _rf_phase == 0:
		var want := float(_repro.get("rocksize", 1.0))
		var best: RockInst = null
		for c: Vector3i in world.chunks:
			for r: RockInst in (world.chunks[c] as Chunk).rocks:
				if _repro.has("layered") and r.layers.size() < 2:
					continue
				var lay := _repro.has("layered")                          # a layered rock is rare: any size from 0.6 m, loose or sunk
				if r.deposit or (r.fixed and not lay) or (not lay and (r.size < want * 0.7 or r.size > want * 1.5)) or (lay and r.size < 0.6) or r.pos.distance_to(player.global_position) > 45.0:
					continue
				if best == null or absf(r.size - want) < absf(best.size - want):
					best = r
		if best == null:
			print("RF no loose rock of that size near the player")
			get_tree().quit()
			return
		_rf_rock = best
		for c2: Vector3i in world.chunks:
			var ch2: Chunk = world.chunks[c2]
			for k in ch2.grass_nodes:
				(ch2.grass_nodes[k] as Node3D).visible = false
			if ch2.tree_instance != null:
				ch2.tree_instance.visible = false
			if ch2.tree_far != null:
				ch2.tree_far.visible = false
		far_trees.visible = false
		hud.visible = false
		for hv in [player, character, rig]:
			if hv != null:
				hv.visible = false                         # nothing between the camera and the rock
		var upq := best.pos.normalized()
		var sidev := upq.cross(Vector3.UP).normalized()
		var dist := best.size * 3.2 + 3.0
		player.global_position = best.pos + sidev * (dist + 5.0) + upq * 0.6        # parked behind the study camera
		player.freeze = true
		var rcam := Camera3D.new()
		rcam.fov = 50.0
		add_child(rcam)
		rcam.global_position = best.pos + sidev * dist + upq * (best.size * 0.9 + 0.6)
		rcam.look_at(best.pos + upq * (best.size * 0.1), upq)
		rcam.current = true
		_rf_start = best.pos
		print("RF rock size %.2f layers %s fixed %s at %s" % [best.size, best.layers, best.fixed, best.pos])
		var dn := best.pos.normalized()
		var dline := ""
		for k in [-1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5]:
			dline += " %+.1f:%.2f" % [k * best.size, world.density_at(best.pos + dn * k * best.size)]
		print("RF density along up (m from centre):", dline, "  normal.up %.2f  ground slope check" % best.normal.dot(dn))
		var rf0 := RockMesher.frame_of(best)
		var lows := ""
		for dv in [-dn, -dn + rf0.x * 0.6, -dn - rf0.x * 0.6, -dn + rf0.z * 0.6, -dn - rf0.z * 0.6]:
			var wv: Vector3 = dv.normalized()
			var lw := RockMesher.surface_radius(best, rf0, Vector3(wv.dot(rf0.x), wv.dot(rf0.y), wv.dot(rf0.z)))
			lows += " %.2f" % world.density_at(best.pos + wv * lw)
		print("RF density at the 5 lowest outline points:", lows)
		_rf_phase = 1
		_rf_t = 0
		return
	_rf_t += 1
	var up := _rf_start.normalized()
	if _rf_phase == 1:
		if _rf_t == 30:                                       # a second of calm first: the "before" picture
			get_viewport().get_texture().get_image().save_png("%s_before.png" % prefix)
		if _rf_t == 40:
			if String(_repro.get("mode", "undercut")) == "hitonly":
				pass
			elif String(_repro.get("mode", "undercut")) == "drop":
				# a rock let go above the rock: it must land ON it and roll off, never sink into it (--rockcontacts=0: the control)
				physics.rock_contacts = String(_repro.get("rockcontacts", "1")) != "0"
				var pc := RockInst.new()
				pc.id = 9990001
				pc.size = 0.7
				pc.shape = 11
				pc.layers = [[_rf_rock.layers[0][0], 1.0]]
				pc.pos = _rf_rock.pos + up * (_rf_rock.size * 1.1 + 2.6) + up.cross(Vector3.UP).normalized() * 0.35
				pc.normal = up
				physics.drop_piece(pc)
				print("RF dropped a %.1f m rock onto the %.1f m rock" % [pc.size, _rf_rock.size])
			elif String(_repro.get("mode", "undercut")) == "chip":
				var side := up.cross(Vector3.UP).normalized() * 2.0
				for tries in 60:
					if physics.active() > 0 or not world.chunks.has(VoxelWorld.world_to_chunk(_rf_rock.pos)):
						break
					var from := _rf_rock.pos + up * 1.0 + side
					var aimpt := _rf_rock.pos - up * (_rf_rock.size * 0.6)
					var res := world.rock_ray(from, aimpt - from, 20.0)
					if not res.hit:
						break
					aim.target = {"kind": "rock", "rock": res.rock, "chunk": res.chunk, "point": res.point, "normal": res.normal, "in_reach": true}
					print("RF blow: ", _use_tool(false))
			else:
				world.carve(_rf_rock.pos - up * (_rf_rock.size * 0.4), _rf_rock.size * 2.0)
				print("RF dug under the rock")
			_rf_phase = 2
			_rf_t = 0
		return
	if _rf_phase == 2:
		var f := _rf_t
		if String(_repro.get("mode", "undercut")).begins_with("hit"):
			# the player's way: blow after blow from where the camera is, at the middle of the rock, one blow every 30 frames
			var gone := _rf_rock == null or not (world.chunks.has(VoxelWorld.world_to_chunk(_rf_rock.pos)) and (world.chunks[VoxelWorld.world_to_chunk(_rf_rock.pos)] as Chunk).rocks.has(_rf_rock))
			if f % 30 == 1 and _rf_blows < int(_repro.get("blows", 12)) and physics.active() == 0 and not gone:
				var from := get_viewport().get_camera_3d().global_position
				var res := world.rock_ray(from, _rf_rock.pos + up * (_rf_rock.size * float(_repro.get("aimh", 0.0))) - from, 60.0)
				if res.hit:
					aim.target = {"kind": "rock", "rock": res.rock, "chunk": res.chunk, "point": res.point, "normal": res.normal, "in_reach": true}
					_rf_blows += 1
					var t_before: int = physics._touching(_rf_rock)
					var out := _use_tool(false)
					print("RF f%03d BLOW %d: %s  | left %.0f%%  bites %d  size %.2f  touching %d -> %d (fixed %s)" % [f, _rf_blows, out, RockMesher.volume_fraction(_rf_rock) * 100.0, _rf_rock.bites.size(), _rf_rock.size, t_before, physics._touching(_rf_rock), _rf_rock.fixed])
				else:
					print("RF f%03d no rock on the ray" % f)
			if f % 30 == 20:
				_rf_rest = 0
			if (_rf_blows >= int(_repro.get("blows", 12)) or gone) and physics.active() == 0 and f % 30 == 29:
				print("RF done after %d frames" % f)
				get_tree().quit()
		get_viewport().get_texture().get_image().save_png("%s_%03d.png" % [prefix, f])
		var line := "RF f%03d  falling %d  %.2f ms" % [f, physics.active(), physics._last_us / 1000.0]
		for b in physics.debug_bodies():
			line += "  | h %+.2f  v %.2f  w %.2f  contacts %d  rest %.2f" % [(b.p as Vector3).length() - _rf_start.length(), (b.v as Vector3).length(), (b.w as Vector3).length(), b.n_hit, b.rest]
		print(line)
		if physics.active() == 0 and f > 5:
			_rf_rest += 1
		if String(_repro.get("mode", "undercut")).begins_with("hit"):
			return
		if _rf_rest >= 12 or f >= int(_repro.get("frames", 240)):
			print("RF done after %d frames" % f)
			var rr := _rf_rock
			print("RF rock now: size %.2f  bites %s  left %.0f%%  cut verts %d  fixed %s  normal.up %.2f" % [rr.size, rr.bites, RockMesher.volume_fraction(rr) * 100.0, (rr.cut.verts as PackedVector3Array).size() if not rr.cut.is_empty() else -1, rr.fixed, rr.normal.dot(rr.pos.normalized())])
			var upc := rr.pos.normalized()
			player.global_position = rr.pos + upc.cross(Vector3.UP).normalized() * 2.6 + upc * 0.6
			cam.distance = 2.4
			var tr := rr.pos - player.global_position
			tr -= upc * tr.dot(upc)
			cam.fwd = tr.normalized()
			_rf_phase = 3
			_rf_t = 0
		return
	if _rf_phase == 3:
		if _rf_t == 8:
			get_viewport().get_texture().get_image().save_png("%s_close.png" % prefix)
			get_tree().quit()

## Debugging aid (--camtest=prefix --loadsave=file): the player's own situation. In the loaded world, the camera is turned (by the same call the
## mouse makes) towards the nearest rock, then the rock is struck. Every frame: where the camera is and what its safety logic is doing,
## and every few frames a picture "<prefix>_<frame>.png". Look for jumps of the camera position and flips of the search goal.
var _ct_phase := 0
var _ct_t := 0
var _ct_rock: RockInst = null
var _ct_prev := Vector3.ZERO
var _ct_blows := 0
var _ct_ok := 0
func _camtest_step() -> void:
	var prefix := String(_repro.camtest)
	if _ct_phase == 0:
		if _repro.has("at") and _ct_t == 0:                                   # stand where a screenshot was taken (--at=x,y,z)
			var av := String(_repro.at).split_floats(",")
			player.global_position = Vector3(av[0], av[1], av[2])
			player.linear_velocity = Vector3.ZERO
		_ct_t += 1
		player.freeze = true
		if _ct_t < 150 or not world.is_area_ready(player.global_position):
			return
		_ct_t = 0
		var best: RockInst = null
		for c: Vector3i in world.chunks:
			for r: RockInst in (world.chunks[c] as Chunk).rocks:
				if r.deposit or r.size < float(_repro.get("minsize", 0.6)):
					continue
				var d := r.pos.distance_to(player.global_position)
				if d < 14.0 and (best == null or d < best.pos.distance_to(player.global_position)):
					best = r
		if best == null:
			print("CT no rock near the player")
			get_tree().quit()
			return
		_ct_rock = best
		player.freeze = true
		cam.pitch = float(_repro.get("campitch", 1.12))
		cam.distance = 9.0
		print("CT player %s  rock size %.2f layers %s at %.1f m" % [player.global_position, best.size, best.layers, best.pos.distance_to(player.global_position)])
		_ct_phase = 1
		_ct_t = 0
		return
	_ct_t += 1
	player.freeze = true
	var up := player.global_position.normalized()
	var to_rock := _ct_rock.pos - player.global_position
	to_rock -= up * to_rock.dot(up)
	var ang := cam.view_fwd.signed_angle_to(to_rock.normalized(), up)
	if _ct_phase == 1:
		if absf(ang) > 0.03:
			cam.turn(Vector2(-clampf(ang, -0.08, 0.08) / 0.003, 0.0))         # the same call the mouse makes
			_ct_ok = 0
		else:
			_ct_ok += 1
			if _ct_ok > 25:
				_ct_phase = 2
				_ct_t = 0
				print("CT camera is on the rock")
	if _ct_phase == 2 and _ct_t % 40 == 5 and _ct_blows < int(_repro.get("blows", 3)):
		var res := world.rock_ray(cam.global_position, -cam.global_transform.basis.z, 40.0)
		var ctr := "the cross (screen centre) is on: " + ("a ROCK" if res.hit else "no rock")
		if not res.hit:
			res = world.rock_ray(cam.global_position, (_ct_rock.pos - cam.global_position), 40.0)
			ctr += "; aiming straight at the rock: " + ("hit" if res.hit else "NOTHING (the ray misses it)")
		print("CT ", ctr)
		if res.hit:
			aim.target = {"kind": "rock", "rock": res.rock, "chunk": res.chunk, "point": res.point, "normal": res.normal, "in_reach": true}
			_ct_blows += 1
			print("CT blow %d: %s" % [_ct_blows, _use_tool(false)])
	var back := cam.global_position - player.global_position
	var jump := cam.global_position.distance_to(_ct_prev) if _ct_prev != Vector3.ZERO else 0.0
	_ct_prev = cam.global_position
	var line := "CT f%03d ph%d  cam %.2f m from ball, %+.2f up  jump %.2f  lift %+.2f yaw_off %+.2f goal %s  to-rock %+.0f deg  ball %s" % [_ct_t, _ct_phase, back.length(), back.dot(up), jump, cam._lift, rad_to_deg(cam._yaw_off), ("search" if cam._has_goal else "-"), rad_to_deg(ang), ("visible" if player.visible else "HIDDEN")]
	var cres := world.raycast(cam.global_position, -cam.global_transform.basis.z, 60.0)
	if cres.hit and _ct_t % 20 == 0:
		print("CT marker (screen centre) lands %.2f m from the ball" % player.global_position.distance_to(cres.point))
	print(line + "   [" + cam.dbg + "]")
	if _ct_t % 4 == 0:
		get_viewport().get_texture().get_image().save_png("%s_%d_%03d.png" % [prefix, _ct_phase, _ct_t])
	if _repro.has("walk") and _ct_phase == 2 and _ct_t > 40 * int(_repro.get("blows", 3)) + 40:
		_ct_phase = 3                                          # the walking test: he walks forward at 4 m/s, then stops
		_ct_t = 0
		print("CT walk starts")
	if _ct_phase == 3:
		var wf := cam.view_fwd
		wf = (wf - up * wf.dot(up)).normalized().cross(up)               # sideways: nothing in the way
		if _ct_t < 100:
			player.global_position += wf * (4.0 / 60.0)
		var sp2 := cam.unproject_position(player.global_position + up * 0.8)
		print("CT walk f%03d ball on screen at (%.0f, %.0f) of %s, cam %.1f m from him" % [_ct_t, sp2.x, sp2.y, get_viewport().get_visible_rect().size, cam.global_position.distance_to(player.global_position)])
		if _ct_t % 10 == 0:
			get_viewport().get_texture().get_image().save_png("%s_3_%03d.png" % [prefix, _ct_t])
		if _ct_t > 200:
			print("CT done")
			get_tree().quit()
		return
	if (_ct_phase == 1 and _ct_t > 400) or (_ct_phase == 2 and _ct_t > 40 * int(_repro.get("blows", 3)) + 40):
		print("CT done")
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

## Debugging aid (--stairs): a solid step 0.3 m high whose edge runs under the character, so his two boots stand at different heights.
func _debug_stairs() -> void:
	var up := player.global_position.normalized()
	var fwd := _flat_dir(cam.view_fwd, up)
	var right := fwd.cross(up).normalized()
	var space := get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(player.global_position, player.global_position - up * 4.0, 1, [player.get_rid()]))
	if hit.is_empty():
		print("STAIRS no ground under the player")
		return
	for c2: Vector3i in world.chunks:                                      # a clear view of the boots: no grass in the way
		for k in (world.chunks[c2] as Chunk).grass_nodes:
			((world.chunks[c2] as Chunk).grass_nodes[k] as Node3D).visible = false
	var step := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(3.0, 0.3, 4.0)
	cs.shape = bs
	step.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = bs.size
	mi.mesh = bm
	step.add_child(mi)
	add_child(step)
	step.global_transform = Transform3D(Basis(right, up, -fwd), hit.position + right * 1.5 + up * 0.15)
	player.global_position = hit.position + up * 0.8 + right * 0.08           # on the step, its edge just under the ball: one boot over the step, the other over the drop

static func _flat_dir(v: Vector3, up: Vector3) -> Vector3:
	return (v - up * v.dot(up)).normalized()

## The mouse button went down: swing the tool in hand at what it points at, if it can do anything there.
func _begin_tool_use() -> void:
	var tool := kit.belt.current()
	if tool == null:
		return
	var t: Dictionary = aim.target
	var can := tool_user.check(tool, t)
	if not can.ok:
		hud.say(can.msg, UiTheme.WARN)
		return
	if tool.action == ToolDef.LIGHT:
		_place_torch()                                   # a torch is planted, not swung
		return
	var snap := t.duplicate()
	if tool.action == ToolDef.SCOOP:
		snap["lift"] = clampf(world.submersion(t.point), 0.0, 4.0)       # the bucket dips under the surface, not down to the sea bed
	_tool_cd = rig.use_time()
	rig.begin_use(snap)

## [T]: plant a torch from the belt where the mouse points, whatever tool is in hand.
func _place_torch() -> void:
	var torch_id := kit.belt.torch_to_plant()
	if torch_id == "":
		hud.say("No torch to plant: craft one first", UiTheme.WARN)
		return
	var can := tool_user.check(ToolCatalog.get_def(torch_id), aim.target)
	if not can.ok:
		hud.say(can.msg if can.msg != "" else "Point at a surface within reach", UiTheme.WARN)
		return
	tool_user.plant_torch(aim.target)
	autosave.request()

## [E]: pick up the planted torch the mouse points at.
func _pickup_torch() -> void:
	if not _aiming:
		return
	var got := torches.pick_up(cam.project_ray_origin(_vcur), cam.project_ray_normal(_vcur), player.global_position, aim.reach)
	if not got.is_empty():
		kit.belt.add(got.id, 1, got.fuel)                  # it keeps the fuel it has left
		autosave.request()
		hud.say("Picked up a %s (%s left)" % [ToolCatalog.get_def(got.id).name.to_lower(), _clock(got.fuel)], UiTheme.GOOD)
	else:
		hud.say("No torch there", UiTheme.WARN)

static func _clock(seconds: float) -> String:
	return "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]

## The tool landed: now the world changes and the harvest is taken.
func _on_tool_struck(target: Dictionary) -> void:
	tool_user.use(kit.belt.current_id(), target, player.global_position, false)
	autosave.request()                                  # a rock chipped, a tree cut ...

## The game as data, for the save.
func _capture_save() -> Dictionary:
	return _snapshot.capture(world, player, kit, torches, {"sun_angle": sun_angle, "season": season, "playtime": _playtime})

## Debugging aids (--hit, --seq) strike at once, with the pickaxe, without the swing.
func _use_tool(place: bool) -> String:
	return tool_user.use("pickaxe", aim.target, player.global_position, place)

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

## A felled tree hit the ground: its crown bursts into leaves.
func _on_tree_landed(_tree: TreeInst, point: Vector3, colors: Array) -> void:
	debris.burst(point, point.normalized(), colors, 28, 0.2)

func _unhandled_input(event: InputEvent) -> void:
	if not playing:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_F: player.toggle_fly()
			KEY_R: player.respawn()
			KEY_C: _spawn_in_cave()
			KEY_T: _place_torch()
			KEY_E: _pickup_torch()
			KEY_ESCAPE: _mouse_freed = true                          # give the mouse back (click in the window to take it again)
	elif event is InputEventMouseButton and event.pressed and _mouse_freed and not hud.menu_open():
		_mouse_freed = false                                       # this click only takes the mouse back: no swing

## The mouse turns the camera, at once: what you move is what the view does.
func _input(event: InputEvent) -> void:
	if playing and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and event is InputEventMouseMotion:
		cam.turn(event.relative)
