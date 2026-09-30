extends Node3D
## Proof scene for the mansion hall kit (game/assets/models/env/*.glb): assembles a 20 x 16 m hall
## from the kit in code, with 1 m capsules for scale. Not the real lobby.
## Views (user arg): --view=iso (default, ~50 deg gameplay camera), eye, eye2, eye3, eye4, kit --pieces=a,b,c (piece line-up).

const ENV_DIR := "res://assets/models/env/"
const HALL_X := 10.0  # half extents: the wall centre lines
const HALL_Z := 8.0

var _view: String = "iso"
var _cache: Dictionary[String, PackedScene] = {}


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
	_add_environment()
	if _view == "kit":
		_build_kit_sheet()
		return
	_build_hall()
	_add_capsules()
	_add_camera()


func place(piece: String, pos: Vector3, yaw_deg: float = 0.0, parent: Node = null) -> Node3D:
	if not _cache.has(piece):
		var scene := load(ENV_DIR + piece + ".glb") as PackedScene
		if scene == null:
			push_error("showcase: missing kit piece %s" % piece)
			return null
		_cache[piece] = scene
	var node := _cache[piece].instantiate() as Node3D
	node.position = pos
	node.rotation_degrees.y = yaw_deg
	(parent if parent != null else self).add_child(node)
	return node


func _build_hall() -> void:
	var floors := Node3D.new()
	floors.name = "Floor"
	add_child(floors)
	for ix in 5:
		for iz in 4:
			place("floor_tile_4x4", Vector3(-8.0 + 4.0 * ix, 0, -6.0 + 4.0 * iz), 0.0, floors)

	var walls := Node3D.new()
	walls.name = "Walls"
	add_child(walls)
	# back wall (z=-8, faces +Z), front wall (z=+8, faces -Z)
	var back: Array[String] = ["wall_4m", "wall_4m", "wall_4m", "wall_4m", "wall_window"]
	var front: Array[String] = ["wall_window", "wall_4m", "wall_door", "wall_4m", "wall_window"]
	for i in 5:
		place(back[i], Vector3(-8.0 + 4.0 * i, 0, -HALL_Z), 0.0, walls)
		place(front[i], Vector3(-8.0 + 4.0 * i, 0, HALL_Z), 180.0, walls)
	# side walls: left (x=-10, faces +X), right (x=+10, faces -X)
	var left: Array[String] = ["wall_window", "wall_4m", "wall_4m", "wall_window"]
	var right: Array[String] = ["wall_4m", "wall_door", "wall_window", "wall_4m"]
	for i in 4:
		place(left[i], Vector3(-HALL_X, 0, -6.0 + 4.0 * i), 90.0, walls)
		place(right[i], Vector3(HALL_X, 0, -6.0 + 4.0 * i), -90.0, walls)
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			place("wall_corner", Vector3(sx * HALL_X, 0, sz * HALL_Z), 0.0, walls)

	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	# staircase against the back wall, landing at the top, plus the glowing minigame portal
	place("grand_staircase", Vector3(0, 0, -4.85), 0.0, props)
	place("minigame_door_arch", Vector3(-7.5, 0, -7.55), 0.0, props)
	place("grandfather_clock", Vector3(5.6, 0, -7.58), 0.0, props)
	place("candelabra", Vector3(-5.0, 0, -7.5), 0.0, props)
	place("suit_of_armour", Vector3(-3.9, 0, -1.9), 0.0, props)
	place("suit_of_armour", Vector3(3.9, 0, -1.9), 0.0, props)
	place("pillar", Vector3(-6.0, 0, 5.0), 0.0, props)
	place("pillar", Vector3(6.0, 0, 5.0), 0.0, props)
	# fireplace on the left wall with a seating group
	place("fireplace", Vector3(-9.35, 0, 2.0), 90.0, props)
	place("portrait_frame_a", Vector3(-9.25, 2.6, 2.0), 90.0, props)
	place("sofa", Vector3(-5.6, 0, 2.0), -90.0, props)
	place("armchair", Vector3(-7.2, 0, -0.5), -30.0, props)
	place("armchair", Vector3(-7.2, 0, 4.5), -150.0, props)
	place("side_table", Vector3(-5.6, 0, 0.2), 0.0, props)
	place("side_table", Vector3(-5.6, 0, 3.8), 0.0, props)
	place("bookshelf", Vector3(-9.6, 0, -2.0), 90.0, props)
	# right side: piano, bookshelves
	place("piano", Vector3(8.5, 0, -4.5), -90.0, props)
	place("portrait_frame_c", Vector3(9.83, 2.3, -6.0), -90.0, props)
	place("bookshelf", Vector3(9.6, 0, 5.0), -90.0, props)
	place("bookshelf", Vector3(4.0, 0, 7.6), 180.0, props)
	place("potted_plant", Vector3(9.2, 0, 7.1), 0.0, props)
	place("potted_plant", Vector3(-9.2, 0, 7.1), 0.0, props)
	place("potted_plant", Vector3(9.2, 0, -7.2), 0.0, props)
	place("candelabra", Vector3(-1.9, 0, 7.5), 180.0, props)
	place("candelabra", Vector3(1.9, 0, 7.5), 180.0, props)
	# portraits
	place("portrait_frame_c", Vector3(-4.0, 2.0, -7.83), 0.0, props)
	place("portrait_frame_b", Vector3(0.0, 3.2, -7.83), 0.0, props)
	place("portrait_frame_a", Vector3(4.0, 2.0, -7.83), 0.0, props)
	place("portrait_frame_a", Vector3(-4.0, 2.0, 7.83), 180.0, props)
	place("portrait_frame_b", Vector3(0.0, 3.0, 7.83), 180.0, props)
	# centre: rug, winner's podium, chandelier
	place("rug_long", Vector3(0, 0.005, 2.0), 0.0, props)
	place("trophy_pedestal", Vector3(0, 0, 1.6), 0.0, props)
	place("chandelier", Vector3(0, 5.0, 1.6), 0.0, props)
	_boost_emissives(self)
	_add_lights()


func _boost_emissives(root: Node) -> void:
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if mat != null and mat.resource_name.begins_with("Emit") and mat.resource_name != "EmitMoon":
				mat.emission_energy_multiplier = 1.6


func _add_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.05, 0.1)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.5, 0.7)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.1
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _add_lights() -> void:
	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.65, 0.75, 1.0)
	moon.light_energy = 0.55
	moon.rotation_degrees = Vector3(-55, 25, 0)
	moon.shadow_enabled = true
	add_child(moon)
	_omni(Vector3(0, 3.8, 1.6), Color(1.0, 0.78, 0.5), 5.0, 16.0)
	_omni(Vector3(-8.2, 0.9, 2.0), Color(1.0, 0.55, 0.2), 2.5, 7.0)
	_omni(Vector3(-2.0, 3.2, -5.5), Color(1.0, 0.8, 0.55), 2.0, 9.0, false)
	_omni(Vector3(-7.5, 2.0, -6.0), Color(0.4, 1.0, 0.9), 2.0, 6.0, false)


func _omni(pos: Vector3, color: Color, energy: float, range_m: float, shadows: bool = true) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = range_m
	l.shadow_enabled = shadows
	add_child(l)


func _add_capsules() -> void:
	var spots: Array[Vector3] = [Vector3(2.5, 0.5, 4.2), Vector3(-1.0, 0.5, 6.0), Vector3(3.6, 0.5, -0.4), Vector3(0.9, 0.5, -1.2)]
	var colors: Array[Color] = [Color(0.95, 0.35, 0.55), Color(0.35, 0.8, 1.0), Color(1.0, 0.85, 0.2), Color(0.5, 0.9, 0.4)]
	for i in spots.size():
		var mi := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.4
		cap.height = 1.0
		var mat := StandardMaterial3D.new()
		mat.albedo_color = colors[i]
		cap.material = mat
		mi.mesh = cap
		mi.position = spots[i]
		mi.name = "Capsule%d" % i
		add_child(mi)


func _add_camera() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	match _view:
		"eye":  # blob eye level, from the entrance looking at the stairs
			cam.fov = 75.0
			cam.look_at_from_position(Vector3(3.5, 1.3, 7.0), Vector3(-1.0, 1.7, -6.0))
		"eye2":  # toward the fireplace and the seating group
			cam.fov = 75.0
			cam.look_at_from_position(Vector3(-1.5, 1.3, -3.2), Vector3(-9.5, 1.7, 2.6))
		"eye3":  # back over the hall from the foot of the stairs
			cam.fov = 75.0
			cam.look_at_from_position(Vector3(-2.0, 1.3, -1.0), Vector3(-2.0, 1.5, 6.0))
		"eye4":  # toward the portal arch and the piano side
			cam.fov = 75.0
			cam.look_at_from_position(Vector3(4.5, 1.3, 4.5), Vector3(-6.0, 1.7, -6.5))
		_:  # gameplay camera: ~50 deg pitch, centred on the hall
			cam.fov = 40.0
			var target := Vector3(0, 0, -0.5)
			var dist := 25.0
			cam.look_at_from_position(target + Vector3(0, sin(deg_to_rad(50.0)), cos(deg_to_rad(50.0))) * dist, target)


func _build_kit_sheet() -> void:
	## --view=kit --pieces=a,b,c : pieces in a row (spaced by their bounding boxes), a 1 m capsule beside each.
	var names: PackedStringArray = []
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--pieces="):
			names = arg.trim_prefix("--pieces=").split(",")
	var x := 0.0
	var tallest := 1.0
	for piece: String in names:
		var n := place(piece, Vector3.ZERO)
		if n == null:
			continue
		var box := _aabb(n)
		var lift := 0.0
		if piece.begins_with("portrait"):
			lift = 0.9
		if piece == "chandelier":
			lift = 3.0
		n.position = Vector3(x - box.position.x + 0.3, lift, 0.0)
		tallest = maxf(tallest, box.size.y + lift)
		var mi := MeshInstance3D.new()  # 1 m capsule for scale
		var cap := CapsuleMesh.new()
		cap.radius = 0.4
		cap.height = 1.0
		mi.mesh = cap
		mi.position = Vector3(x + 0.3, 0.5, box.end.z + 0.9)
		add_child(mi)
		x += box.size.x + 1.0
	_boost_emissives(self)
	var floor_mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(x + 30.0, 40.0)
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.35, 0.33, 0.38)
	plane.material = fm
	floor_mi.mesh = plane
	floor_mi.position = Vector3(x / 2.0, -0.002, 0.0)
	add_child(floor_mi)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -25, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 40.0
	add_child(cam)
	cam.current = true
	var c := Vector3(x / 2.0, tallest * 0.4, 0.0)
	var dist := maxf(x * 0.5 + 1.0, tallest * 1.2) / 0.647
	cam.look_at_from_position(c + Vector3(0, sin(deg_to_rad(20.0)), cos(deg_to_rad(20.0))) * dist, c)


func _aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var b := mi.global_transform * mi.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out
