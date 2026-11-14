class_name OceanTest
extends Node
## Debugging aid (--oceantest=DIR): drops the explorer over the deepest sea and runs a script of swimming situations, printing what the body, the
## camera and the character do ("OT ..." lines) and saving screenshots to DIR. Nothing here is part of the game.
##   fall in, float and tread at the surface, dive with Ctrl, hang in neutral buoyancy, swim along the steered pitch, rise and surface.

var m: Node
var dir: String
var f := 0
var _viol := 0
var _viol2 := 0
var _deep_frames := 0
var _col := Column.new()

func _init(main: Node, out_dir: String) -> void:
	m = main
	dir = out_dir

func _process(_d: float) -> void:
	f += 1
	var p: BallPlayer = m.player
	var up := p.global_position.normalized()
	match f:
		330:
			var best := Vector3.ZERO
			var lowest := 1e9
			for i in 4000:
				var d: Vector3 = m.gen.fibonacci_dir(i, 4000)
				m.gen.sample_column(d, _col)
				if PlanetGenerator.is_sea(_col.land, _col.height) and _col.height < lowest:
					lowest = _col.height
					best = d
			print("OT deepest sea %.1f m below the surface" % lowest)
			p.position = best * (WorldConfig.PLANET_RADIUS + 6.0)
			p.spawn_pos = p.position
			p.linear_velocity = Vector3.ZERO
			m.cam.distance = 8.0
			print("OT --- falls in from 6 m")
		395: _shot("R1a_entry")
		415: _shot("R1b_entry")
		445: _shot("R1c_entry")
		455: m.cam.distance = 3.5
		460:
			_say("floating still at the surface")
			p.position = p.position.normalized() * WorldConfig.PLANET_RADIUS
			p.linear_velocity = Vector3.ZERO
			m._repro["faceangle"] = "90"
		500: _shot("1_idle_side")
		520: m._repro.erase("faceangle")
		560: _shot("1_idle_back")
		600:
			_say("Ctrl held: dive")
			_key(KEY_CTRL, true)
		690: _shot("2_dive")
		720:
			_say("Ctrl released: neutral buoyancy, deep idle")
			_key(KEY_CTRL, false)
			m._repro["faceangle"] = "90"
		800: _shot("3_deep_idle_side")
		840:
			m._repro.erase("faceangle")
			_say("W held, mouse steered the pitch down 30 degrees")
			p.swim_pitch = deg_to_rad(-30.0)
			p.dbg_kz = 1.0
		930: _shot("4_swim_down")
		960:
			_say("pitch up 50 degrees: swim up and surface")
			p.swim_pitch = deg_to_rad(50.0)
		1100: _shot("5_surfacing")
		1200:
			_say("W released at the surface")
			p.dbg_kz = 0.0
		1300: _shot("6_surface_again")
		1340:
			_say("surface swim with W (wake)")
			p.position = p.position.normalized() * WorldConfig.PLANET_RADIUS
			p.linear_velocity = Vector3.ZERO
			m.cam.distance = 8.0
		1400: p.dbg_kz = 1.0
		1480: _shot("R2_wake")
		1500: p.dbg_kz = 0.0
		1570: _shot("R3_idle_ring")
		1600:
			_say("sun overhead, 4 m under water")
			m._repro["sun"] = "0"
			m.sun_angle = SkyDome.sun_angle_for_elevation(p.global_position.normalized(), 0.0, 1.1, true)
			p.position = p.position.normalized() * (WorldConfig.PLANET_RADIUS - 4.0)
			p.linear_velocity = Vector3.ZERO
			m.cam.distance = 4.0
		1700: _shot("X1_rays_side")
		1710: m.cam.tilt = 0.9
		1780: _shot("X2_rays_up")
		1790: m.cam.tilt = 0.0
		1800:
			p.position = p.position.normalized() * (WorldConfig.PLANET_RADIUS - 14.0)
			p.linear_velocity = Vector3.ZERO
		1880: _shot("X3_rays_deeper")
		1900:
			m.sun_angle = SkyDome.sun_angle_for_elevation(p.global_position.normalized(), 0.0, 0.45, true)
			p.position = p.position.normalized() * (WorldConfig.PLANET_RADIUS - 4.0)
			p.linear_velocity = Vector3.ZERO
			m.cam.tilt = 0.0
		1990: _shot("X4_sun_mid")
		2000: m.sun_angle = SkyDome.sun_angle_for_elevation(p.global_position.normalized(), 0.0, 0.15, true)
		2090: _shot("X5_sun_low")
		2100: m.sun_angle = SkyDome.sun_angle_for_elevation(p.global_position.normalized(), 0.0, -0.3, true)
		2190: _shot("X6_sun_below")
		2200: get_tree().quit()
	if f >= 330:
		var pd: float = p.water_depth
		var cs: float = m.world.submersion(m.cam.global_position)
		if pd > 1.3 and cs < 0.1:
			_viol += 1
			if _viol <= 6:
				print("OT VIOLATION f%d: the player is %.2f m deep and the camera is %.2f m %s the surface" % [f, pd, absf(cs), "above" if cs < 0.0 else "under"])
		if pd > 1.3:
			_deep_frames += 1
		if pd < -0.5 and pd > -1.0e8 and cs > 0.1:
			_viol2 += 1
			if _viol2 <= 4:
				print("OT VIOLATION f%d: the player is %.2f m above the water and the camera is %.2f m under it" % [f, absf(pd), cs])
	if f == 2199:
		print("OT camera-above-water frames while the player was deep: %d of %d; camera-under-water frames while the player was above the water: %d" % [_viol, _deep_frames, _viol2])
	if f >= 330 and f % 10 == 0:
		var alt := p.global_position.length() - WorldConfig.PLANET_RADIUS
		var cam_alt: float = m.cam.global_position.length() - WorldConfig.PLANET_RADIUS
		print("OT f%d alt=%.2f state=%s vup=%.2f v=%.2f pitch=%.0f swell=%.3f cam_alt=%.2f camdist=%.2f lean=%.2f mv=%.2f" % [f, alt, str(p.swim_state), p.linear_velocity.dot(up), p.linear_velocity.length(), rad_to_deg(p.swim_pitch), m.world.submersion(p.global_position) + alt, cam_alt, m.cam.global_position.distance_to(p.global_position), m.character._swim_lean, m.character._mv])

func _say(t: String) -> void:
	print("OT --- ", t)

func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = down
	Input.parse_input_event(e)

func _shot(name: String) -> void:
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])
