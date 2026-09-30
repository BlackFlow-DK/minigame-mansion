extends Node3D
## Props showcase (art review scene). User args after `--`:
##   --vignette=lava|sumo|potato|coin   (default lava) one little arena per minigame, with a 1 m capsule for scale
##   --piece=<glb name>                  show a single piece from assets/models/props/ next to a capsule (prints its node tree)
##   --cam=x,y,z --look=x,y,z            override the camera position / target
##   --view=iso|front|top|side|back      single-piece camera preset (default an iso 3/4 view)

const DIR := "res://assets/models/props/"

var _vignette := "lava"
var _piece := ""
var _cam_pos := Vector3.INF
var _look := Vector3.INF
var _view := "iso"
var _cam: Camera3D


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--vignette="):
			_vignette = arg.trim_prefix("--vignette=")
		elif arg.begins_with("--piece="):
			_piece = arg.trim_prefix("--piece=")
		elif arg.begins_with("--cam="):
			_cam_pos = _vec(arg.trim_prefix("--cam="))
		elif arg.begins_with("--look="):
			_look = _vec(arg.trim_prefix("--look="))
		elif arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
	_build_environment()
	var cam_pos := Vector3(0, 14, 14)
	var look := Vector3.ZERO
	if _piece != "":
		var r := _show_piece(_piece)
		cam_pos = r[0]
		look = r[1]
	else:
		match _vignette:
			"lava":
				look = Vector3(0, -0.3, 0)
				cam_pos = Vector3(0, 7.5, 8.5)
				_lava()
			"sumo":
				look = Vector3(0, -1.0, 0)
				cam_pos = Vector3(0, 17, 16)
				_sumo()
			"potato":
				look = Vector3(0, 0, 0)
				cam_pos = Vector3(0, 13, 13)
				_potato()
			"coin":
				look = Vector3(0, 0, 0)
				cam_pos = Vector3(0, 13, 13)
				_coin()
	if _cam_pos != Vector3.INF:
		cam_pos = _cam_pos
	if _look != Vector3.INF:
		look = _look
	_cam.position = cam_pos
	_cam.look_at(look, Vector3.UP)


func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float())


# --- environment ---------------------------------------------------------

func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.55, 0.85)
	sky_mat.sky_horizon_color = Color(0.72, 0.82, 0.92)
	sky_mat.ground_horizon_color = Color(0.72, 0.82, 0.92)
	sky_mat.ground_bottom_color = Color(0.45, 0.5, 0.62)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.82, 0.8, 0.85)
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 3.0
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_hdr_threshold = 1.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-52), deg_to_rad(35), 0)
	sun.light_energy = 0.85
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 50.0
	_cam.far = 200.0
	add_child(_cam)
	_cam.current = true


# --- helpers ---------------------------------------------------------------

func _load(piece_name: String) -> PackedScene:
	return load(DIR + piece_name + ".glb") as PackedScene


func _place(piece_name: String, pos: Vector3, yaw_deg := 0.0, s := 1.0) -> Node3D:
	var scene := _load(piece_name)
	if scene == null:
		push_error("missing piece " + piece_name)
		return null
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation.y = deg_to_rad(yaw_deg)
	n.scale = Vector3.ONE * s
	add_child(n)
	return n


func _capsule(pos: Vector3, color := Color(0.85, 0.3, 0.55)) -> void:
	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.4
	cap.height = 1.0
	mi.mesh = cap
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	mi.material_override = m
	mi.position = pos + Vector3(0, 0.5, 0)
	add_child(mi)


func _plane(size: float, y: float, color: Color, emissive := 0.0) -> void:
	var mi := MeshInstance3D.new()
	var p := PlaneMesh.new()
	p.size = Vector2(size, size)
	mi.mesh = p
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if emissive > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emissive
	mi.material_override = m
	mi.position.y = y
	add_child(mi)


func _tint(n: Node, mat_name: String, color: Color) -> void:
	for c in n.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var m := mi.get_active_material(i)
			if m != null and m.resource_name == mat_name:
				var d := m.duplicate() as StandardMaterial3D
				d.albedo_color = color
				mi.set_surface_override_material(i, d)


func _aabb_of(n: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for c in n.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		var a := mi.global_transform * mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


func _print_tree(n: Node, depth := 0) -> void:
	var extra := ""
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var mats: Array[String] = []
		for i in mi.mesh.get_surface_count():
			var m := mi.get_active_material(i)
			mats.append(m.resource_name if m else "<none>")
		extra = " mats=" + str(mats)
	var p := ""
	if n is Node3D:
		p = str((n as Node3D).position)
	print("  ".repeat(depth), n.name, " [", n.get_class(), "] pos=", p, extra)
	for c in n.get_children():
		_print_tree(c, depth + 1)


# --- single piece ------------------------------------------------------------

func _show_piece(piece_name: String) -> Array:
	var n := _place(piece_name, Vector3.ZERO)
	if n == null:
		return [Vector3(0, 3, 6), Vector3.ZERO]
	_print_tree(n)
	var a := _aabb_of(n)
	print("AABB pos=", a.position, " size=", a.size)
	_plane(80.0, a.position.y - 0.01, Color(0.78, 0.74, 0.68))
	_capsule(Vector3(a.end.x + 0.6, a.position.y if a.position.y < 0.0 else 0.0, 0.0))
	var c := a.get_center()
	var d := a.size.length() * 0.85 + 0.9
	var pos := c + Vector3(d * 0.45, d * 0.55, d * 0.85)
	match _view:
		"front":
			pos = c + Vector3(0, d * 0.1, d)
		"top":
			pos = c + Vector3(0.01, d, 0.01)
		"side":
			pos = c + Vector3(d, d * 0.1, 0)
		"back":
			pos = c + Vector3(d * 0.2, d * 0.5, -d)
	return [pos, c]


# --- vignettes -----------------------------------------------------------------

func _lava() -> void:
	# 19 hex tiles, flat-top, circumradius 1.0 (axial q, r within radius 2)
	var cracked := [Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, -2)]
	for q in range(-2, 3):
		for r in range(-2, 3):
			if absi(q + r) > 2:
				continue
			var pos := Vector3(1.5 * q, 0, sqrt(3.0) * (r + q / 2.0))
			var nm := "hex_tile_cracked" if Vector2i(q, r) in cracked else "hex_tile"
			_place(nm, pos)
	_capsule(Vector3(0, 0, 0))
	_capsule(Vector3(1.5, 0, 0.87), Color(0.3, 0.55, 0.9))
	_plane(60.0, -1.1, Color(1.0, 0.42, 0.12), 1.0)
	_place("lava_rock_a", Vector3(-4.2, -1.1, 1.2), 30)
	_place("lava_rock_b", Vector3(4.6, -1.1, -1.0), 200)
	_place("lava_rock_c", Vector3(-3.2, -1.1, -2.6), 90)
	_place("lava_rock_a", Vector3(3.6, -1.1, 3.4), 140, 0.8)
	_place("cave_stalagmite", Vector3(5.6, -1.1, 1.6), 0)
	_place("cave_stalagmite", Vector3(-5.6, -1.1, -0.6), 60, 0.8)
	for i in 3:
		_place("cave_wall_chunk", Vector3(-4.0 + 4.0 * i, -1.1, -6.2), 0)


func _sumo() -> void:
	_place("sumo_core", Vector3.ZERO)
	for i in 3:
		_place("sumo_ring_%d" % (i + 1), Vector3.ZERO)
	_capsule(Vector3(0, 0, 0))
	_capsule(Vector3(5.6, 0, 0.5), Color(0.3, 0.55, 0.9))
	_capsule(Vector3(-2.0, 0, 6.2), Color(0.35, 0.75, 0.45))
	for i in 4:
		var a := deg_to_rad(45.0 + 90.0 * i)
		_place("sumo_lantern", Vector3(cos(a), 0, sin(a)) * 8.2)
	var cl := [Vector3(-9, -3.5, 5), Vector3(8, -4.5, 7), Vector3(11, -2.5, -4), Vector3(-10, -3, -7),
			Vector3(1, -5.5, -11), Vector3(-2, -6.0, 12)]
	for i in cl.size():
		_place("cloud_puff", cl[i], i * 70.0, 1.6 + 0.2 * (i % 3))


func _potato() -> void:
	_place("arena_floor_disc", Vector3.ZERO)
	_capsule(Vector3(-1.5, 0, 1.0))
	_capsule(Vector3(2.5, 0, 2.5), Color(0.3, 0.55, 0.9))
	_place("bomb", Vector3(0.4, 0.225, 1.5))
	_place("arrow_marker", Vector3(0.4, 1.0, 1.5))
	_place("crate", Vector3(-4, 0, -2), 15)
	_place("crate", Vector3(-4.7, 0, -3.0), 40)
	_place("crate", Vector3(-4.3, 0.9, -2.5), 5)
	_place("barrel", Vector3(3.5, 0, -3.0))
	_place("barrel", Vector3(4.3, 0, -2.4), 30)
	_place("barrel", Vector3(3.9, 0, -3.9), 10)
	var n := 28
	for i in n:
		var a := TAU * i / n
		# the segment's long axis is X; rotate so it is tangent to the ring
		_place("fence_segment_2m", Vector3(sin(a), 0, cos(a)) * 8.9, rad_to_deg(a) + 90.0)


func _coin() -> void:
	_place("vault_floor_disc", Vector3.ZERO)
	for k in 8:
		_place("vault_wall_segment", Vector3.ZERO, 45.0 * k)
	var bar := _place("spinner_bar", Vector3.ZERO)
	if bar:
		bar.rotation.y = deg_to_rad(35)
	_capsule(Vector3(-2.2, 0, 1.6))
	_capsule(Vector3(2.6, 0, -1.4), Color(0.3, 0.55, 0.9))
	for i in 4:
		var a := deg_to_rad(45.0 + 90.0 * i)
		_place("bumper_post", Vector3(cos(a), 0, sin(a)) * 5.6)
	_place("treasure_chest", Vector3(0, 0, 8.0), 180)
	var cols := [Color(0.85, 0.28, 0.23), Color(0.25, 0.5, 0.85), Color(0.35, 0.7, 0.4), Color(0.9, 0.7, 0.2)]
	for i in 4:
		var a := deg_to_rad(90.0 * i + 20.0)
		var pad := _place("spawn_pad", Vector3(sin(a), 0, cos(a)) * 4.0)
		if pad:
			_tint(pad, "PlayerPrimary", cols[i])
	var coin_pos := [Vector3(-3.5, 0.5, -3.5), Vector3(-1.2, 0.5, -5.0), Vector3(1.8, 0.5, 3.6), Vector3(4.2, 0.5, 2.0),
			Vector3(-4.8, 0.5, 0.5), Vector3(0.6, 0.5, -3.0), Vector3(3.0, 0.5, -5.2)]
	for i in coin_pos.size():
		_place("coin", coin_pos[i], i * 33.0)
	_place("coin_big", Vector3(-1.0, 0.8, 4.2), 20)
	_place("coin_big", Vector3(4.6, 0.8, -3.3), -30)
