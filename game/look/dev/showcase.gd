extends Node3D
## Look and effects showcase: placeholder blobs and primitive props on a round stage under
## a StageLook, effects fired on a timer. User args after `--`:
##   --preset=warm_hall|bright_day|lava_cave|night_party   (default warm_hall)
##   --quality=low|high                                     (read by Look)
##   --effect=<name>      fire only this effect, at the centre, every --every frames
##   --fire=<frame>       process frame of the first shot (default 20)
##   --every=<frames>     frames between shots (default 100)
##   --color=#rrggbb      tint passed to Fx.play (default: per blob / white)
##   --close              a close camera on the centre (for effect shots)
## Without --effect it cycles every effect around the stage.

const BLOB_COLORS: Array[Color] = [Look.RED, Look.BLUE, Look.GREEN, Look.GOLD, Look.PINK, Look.TEAL]

var _preset: StageLook.Preset = StageLook.Preset.WARM_HALL
var _effect: StringName = &""
var _fire_frame: int = 20
var _every: int = 100
var _color: Color = Color.WHITE
var _close: bool = false
var _frame: int = 0
var _cycle: int = 0
var _blobs: Array[Node3D] = []
var _hopper: Node3D
var _look: StageLook
var _camera: Camera3D


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--preset="):
			var key := arg.trim_prefix("--preset=").to_upper()
			if StageLook.Preset.has(key):
				_preset = StageLook.Preset[key]
		elif arg.begins_with("--effect="):
			_effect = StringName(arg.trim_prefix("--effect="))
		elif arg.begins_with("--fire="):
			_fire_frame = arg.trim_prefix("--fire=").to_int()
		elif arg.begins_with("--every="):
			_every = maxi(1, arg.trim_prefix("--every=").to_int())
		elif arg.begins_with("--color="):
			_color = Color.from_string(arg.trim_prefix("--color="), Color.WHITE)
		elif arg == "--close":
			_close = true
	_look = $StageLook as StageLook
	_look.preset = _preset
	_camera = $Camera3D as Camera3D
	if _close:
		_camera.position = Vector3(0, 3.2, 5.6)
		_camera.look_at(Vector3(0.3, 0.8, 0.4))
	else:
		_camera.look_at(Vector3(0, 0.3, 0.6))
	_build_surroundings()
	_build_stage()
	_build_props()
	_build_blobs()


func _process(delta: float) -> void:
	_frame += 1
	if _hopper:
		var t := float(_frame) / 60.0
		_hopper.position.y = absf(sin(t * 2.2)) * 1.6
	for i in _blobs.size():
		_blobs[i].rotation.y += delta * (0.3 if i % 2 == 0 else -0.25)
	if _frame < _fire_frame or (_frame - _fire_frame) % _every != 0:
		return
	if _effect != &"":
		_fire(_effect, Vector3(0.4, 0, 0.3))
		return
	var name_: StringName = FxLibrary.NAMES[_cycle % FxLibrary.NAMES.size()]
	var blob := _blobs[_cycle % _blobs.size()]
	_cycle += 1
	_fire(name_, blob.global_position)


func _fire(effect: StringName, at: Vector3) -> void:
	var col := _color
	var pos := at
	match effect:
		&"hit_stars":
			pos += Vector3(0, 0.6, 0.3)
			if col == Color.WHITE:
				col = Look.BLUE
		&"poof":
			pos += Vector3(0, 0.5, 0)
			if col == Color.WHITE:
				col = Look.PINK
		&"stun_swirl":
			pos += Vector3(0, 1.12, 0)
		&"coin_pickup":
			pos += Vector3(0, 0.6, 0)
		&"shove_whoosh", &"respawn_sparkle":
			if col == Color.WHITE:
				col = Look.RED
	var fx := Fx.play(effect, pos, col)
	if fx and effect == &"shove_whoosh":
		fx.basis = Basis.looking_at(Vector3(-1, 0, -0.4).normalized(), Vector3.UP)
	if fx and effect == &"stun_swirl":
		fx.hold(3.0)


# --- Scene building ---------------------------------------------------------------------

func _build_surroundings() -> void:
	var under := MeshInstance3D.new()
	under.name = "Surround"
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	plane.subdivide_width = 40
	plane.subdivide_depth = 40
	under.mesh = plane
	under.position.y = -0.35
	match _preset:
		StageLook.Preset.LAVA_CAVE:
			under.material_override = load("res://look/materials/lava.tres")
		StageLook.Preset.BRIGHT_DAY:
			under.material_override = load("res://look/materials/water.tres")
		_:
			var m := (load("res://look/materials/void_fade.tres") as ShaderMaterial).duplicate() as ShaderMaterial
			m.set_shader_parameter(&"color", Look.DARK_WOOD.darkened(0.5) if _preset == StageLook.Preset.WARM_HALL else Look.PLUM.darkened(0.6))
			m.set_shader_parameter(&"inner_radius", 7.0)
			m.set_shader_parameter(&"outer_radius", 24.0)
			under.material_override = m
			under.position.y = -1.5
	add_child(under)


func _build_stage() -> void:
	var body := StaticBody3D.new()
	body.name = "Floor"
	add_child(body)
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 7.0
	cyl.height = 0.6
	shape.shape = cyl
	shape.position.y = -0.3
	body.add_child(shape)
	var top_color := Look.WOOD
	var rug_color := Look.PLUM
	match _preset:
		StageLook.Preset.BRIGHT_DAY:
			top_color = Look.CREAM
			rug_color = Look.TEAL
		StageLook.Preset.LAVA_CAVE:
			top_color = Color(0.42, 0.36, 0.38)
			rug_color = Look.CHARCOAL
		StageLook.Preset.NIGHT_PARTY:
			top_color = Look.PLUM.darkened(0.2)
			rug_color = Look.BLUE.darkened(0.3)
	_add_mesh(body, _cylinder(7.0, 0.6, 48), Vector3(0, -0.3, 0), top_color)
	_add_mesh(body, _torus(6.85, 7.25), Vector3(0, -0.02, 0), Look.DARK_WOOD)
	_add_mesh(body, _cylinder(3.2, 0.04, 40), Vector3(0, 0.02, 0), rug_color)
	_add_mesh(body, _torus(3.1, 3.3), Vector3(0, 0.04, 0), Look.GOLD)
	# plank lines for a bit of structure
	for i in range(-6, 7, 2):
		if absi(i) <= 2:
			continue
		var plank := _add_mesh(body, _box(Vector3(0.06, 0.03, 12.5)), Vector3(float(i) * 0.5, 0.005, 0), Look.DARK_WOOD)
		plank.scale.z = sqrt(maxf(0.0, 1.0 - pow(float(i) * 0.5 / 7.0, 2.0)))


func _build_props() -> void:
	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	# crate
	var crate := _add_mesh(props, _box(Vector3(1.1, 1.1, 1.1)), Vector3(-4.2, 0.55, -2.2), Look.WOOD)
	crate.rotation.y = 0.4
	_add_mesh(crate, _box(Vector3(1.16, 0.18, 1.16)), Vector3(0, 0.36, 0), Look.DARK_WOOD)
	_add_mesh(crate, _box(Vector3(1.16, 0.18, 1.16)), Vector3(0, -0.36, 0), Look.DARK_WOOD)
	# barrel
	var barrel := _add_mesh(props, _cylinder(0.45, 1.1, 20), Vector3(4.4, 0.55, -2.0), Look.RED)
	_add_mesh(barrel, _torus(0.43, 0.5), Vector3(0, 0.35, 0), Look.CHARCOAL)
	_add_mesh(barrel, _torus(0.43, 0.5), Vector3(0, -0.35, 0), Look.CHARCOAL)
	# ball, cone, pillar
	_add_mesh(props, _sphere(0.5), Vector3(3.3, 0.5, 2.8), Look.BLUE)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.05
	cone.bottom_radius = 0.4
	cone.height = 0.9
	_add_mesh(props, cone, Vector3(-3.6, 0.45, 2.9), Look.GREEN)
	_add_mesh(props, _cylinder(0.35, 2.4, 16), Vector3(-1.6, 1.2, -4.8), Look.CREAM)
	_add_mesh(props, _cylinder(0.5, 0.25, 16), Vector3(-1.6, 2.5, -4.8), Look.GOLD)
	# emissive coins (bloom check)
	for i in 3:
		var coin := _add_mesh(props, _cylinder(0.28, 0.08, 20), Vector3(1.6 + i * 0.75, 0.9, -3.8), Look.GOLD)
		coin.rotation = Vector3(PI * 0.5, 0.3 * i, 0)
		var m := coin.get_surface_override_material(0) as StandardMaterial3D
		m.emission_enabled = true
		m.emission = Look.GOLD
		m.emission_energy_multiplier = 1.6
	# a small lava pot (lava shader on a prop)
	var pot := _add_mesh(props, _cylinder(0.75, 0.5, 24), Vector3(5.2, 0.25, 1.0), Look.CHARCOAL)
	var lava := MeshInstance3D.new()
	lava.mesh = _cylinder(0.62, 0.05, 24)
	lava.position = Vector3(0, 0.25, 0)
	lava.material_override = load("res://look/materials/lava.tres")
	pot.add_child(lava)
	Look.apply_toon(props)


func _build_blobs() -> void:
	var holder := Node3D.new()
	holder.name = "Blobs"
	add_child(holder)
	var spots: Array[Vector3] = [
		Vector3(-2.2, 0, 1.2), Vector3(2.0, 0, 1.4), Vector3(-1.2, 0, -1.6),
		Vector3(1.2, 0, -1.0), Vector3(-2.9, 0, -0.6), Vector3(-1.6, 0, 3.0),
	]
	for i in spots.size():
		var blob := _blob(BLOB_COLORS[i])
		blob.position = spots[i]
		blob.rotation.y = -0.3 + 0.25 * i
		holder.add_child(blob)
		_blobs.append(blob)
		Look.apply_toon(blob)
	# a hopping blob with a blob shadow
	var hop_root := Node3D.new()
	hop_root.position = Vector3(3.0, 0, 0.2)
	holder.add_child(hop_root)
	_hopper = _blob(Look.CREAM.lerp(Look.PINK, 0.3))
	hop_root.add_child(_hopper)
	Look.apply_toon(_hopper)
	var shadow := BlobShadow.new()
	_hopper.add_child(shadow)
	for b in _blobs:
		b.add_child(BlobShadow.new())


func _blob(color: Color) -> Node3D:
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.4
	cap.height = 1.0
	cap.radial_segments = 32
	cap.rings = 12
	body.mesh = cap
	body.position.y = 0.5
	body.material_override = _std(color)
	root.add_child(body)
	for side: float in [-1.0, 1.0]:
		_add_mesh(root, _sphere(0.1), Vector3(0.14 * side, 0.68, 0.33), Color.WHITE)
		_add_mesh(root, _sphere(0.05), Vector3(0.14 * side, 0.68, 0.425), Look.CHARCOAL)
		_add_mesh(root, _sphere(0.1), Vector3(0.25 * side, 0.12, 0.08), color.darkened(0.25)).scale = Vector3(1.0, 0.6, 1.3)
		_add_mesh(root, _sphere(0.08), Vector3(0.43 * side, 0.45, 0.0), color.lightened(0.1))
	return root


func _add_mesh(parent: Node, mesh: Mesh, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.set_surface_override_material(0, _std(color))
	parent.add_child(mi)
	return mi


func _std(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.6
	return m


func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 24
	s.rings = 12
	return s


func _cylinder(r: float, h: float, segments: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = segments
	return c


func _torus(inner: float, outer: float) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	t.rings = 48
	t.ring_segments = 10
	return t
