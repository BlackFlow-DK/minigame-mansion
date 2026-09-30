extends Node3D
## Dev showcase for the face / neck / back wearables (art/scripts/cosmetics/wearables_*.py).
## Stand-in blobs (body + head + two eyes + mouth, the dimensions in docs/contract.md) each wear one item at its socket.
## Run: tools\godot-screenshot.ps1 -Scene res://dev/showcase_wearables.tscn -Out build\screenshots\x.png -GameArgs "--group=face --view=front"
## User args: --group=face|neck|back|all  --items=face_monocle,neck_scarf  --view=front|back|side  --yaw=<deg, default 32>
##            --cam=<distance m>  --cols=<blobs per row>  --labels=0

const GROUPS := {
	"face": ["face_round_glasses", "face_star_shades", "face_monocle", "face_moustache", "face_clown_nose", "face_eye_patch"],
	"neck": ["neck_scarf", "neck_bow_tie", "neck_gold_chain", "neck_flower_lei", "neck_bandana"],
	"back": ["back_cape", "back_backpack", "back_angel_wings", "back_jetpack", "back_turtle_shell"],
}
const SOCKETS := {
	"face": Vector3(0.0, 0.68, 0.37),
	"neck": Vector3(0.0, 0.40, 0.0),
	"back": Vector3(0.0, 0.50, -0.37),
}
const BLOB_COLORS: Array[Color] = [
	Color("#f2b8c6"), Color("#9ecbe8"), Color("#f4d58d"), Color("#b6dfb0"), Color("#d2b8e8"), Color("#f0b48e"),
]

var _items: Array[String] = []
var _view := "front"
var _yaw := 32.0
var _cam := 0.0
var _cols := 0
var _labels := true


func _ready() -> void:
	var group := "all"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--group="):
			group = arg.trim_prefix("--group=")
		elif arg.begins_with("--items="):
			for it in arg.trim_prefix("--items=").split(",", false):
				_items.append(it)
		elif arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
		elif arg.begins_with("--yaw="):
			_yaw = arg.trim_prefix("--yaw=").to_float()
		elif arg.begins_with("--cam="):
			_cam = arg.trim_prefix("--cam=").to_float()
		elif arg.begins_with("--cols="):
			_cols = arg.trim_prefix("--cols=").to_int()
		elif arg.begins_with("--labels="):
			_labels = arg.trim_prefix("--labels=") != "0"
	if _items.is_empty():
		if group == "all":
			for g: String in GROUPS:
				_items.append_array(GROUPS[g])
		else:
			_items.append_array(GROUPS.get(group, []))
	_build_environment()
	_build_blobs()


func _mat(color: Color, rough := 0.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	return m


func _sphere(parent: Node3D, pos: Vector3, scl: Vector3, color: Color, rough := 0.6) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 32
	sm.rings = 16
	mi.mesh = sm
	mi.material_override = _mat(color, rough)
	mi.position = pos
	mi.scale = scl
	parent.add_child(mi)
	return mi


func _make_blob(color: Color) -> Node3D:
	var root := Node3D.new()
	_sphere(root, Vector3(0, 0.40, 0), Vector3.ONE * 0.40, color)
	_sphere(root, Vector3(0, 0.62, 0), Vector3.ONE * 0.38, color)
	for s in [-1.0, 1.0]:
		_sphere(root, Vector3(s * 0.14, 0.68, 0.335), Vector3(0.09, 0.09, 0.05), Color.WHITE, 0.3)
		_sphere(root, Vector3(s * 0.14, 0.68, 0.368), Vector3(0.042, 0.042, 0.03), Color("#1e1a24"), 0.3)
		_sphere(root, Vector3(s * 0.52, 0.36, 0.06), Vector3.ONE * 0.10, color.darkened(0.15))
		_sphere(root, Vector3(s * 0.20, 0.07, 0.12), Vector3(0.13, 0.07, 0.17), color.darkened(0.15))
	_sphere(root, Vector3(0, 0.55, 0.365), Vector3(0.045, 0.014, 0.012), Color("#7a2f3a"), 0.4)
	_sphere(root, Vector3(-0.2, 0.585, 0.29), Vector3(0.05, 0.03, 0.02), Color("#f08fb0").lightened(0.2), 0.8)
	_sphere(root, Vector3(0.2, 0.585, 0.29), Vector3(0.05, 0.03, 0.02), Color("#f08fb0").lightened(0.2), 0.8)
	return root


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#9fb0c6")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#e8eef8")
	env.ambient_light_energy = 0.75
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, 28, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 200, 0)
	fill.light_energy = 0.35
	add_child(fill)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	floor_mi.mesh = pm
	floor_mi.material_override = _mat(Color("#6f7b8c"), 0.9)
	add_child(floor_mi)


func _build_blobs() -> void:
	var n := _items.size()
	var spacing := 1.75 if _items.any(func(i: String) -> bool: return i.begins_with("back_")) else 1.3
	var cols := _cols if _cols > 0 else n
	var rows := ceili(float(n) / cols)
	var base_yaw := _yaw
	if _view == "back":
		base_yaw = 180.0 - _yaw
	elif _view == "side":
		base_yaw = 90.0
	for i in n:
		var item := _items[i]
		var col := i % cols
		var row := i / cols
		var pos := Vector3((col - (cols - 1) * 0.5) * spacing, 0.0, -row * 2.0)
		var blob := _make_blob(BLOB_COLORS[i % BLOB_COLORS.size()])
		blob.position = pos
		blob.rotation_degrees.y = base_yaw
		add_child(blob)
		var slot := item.get_slice("_", 0)
		var scene := load("res://assets/models/cosmetics/%s.glb" % item) as PackedScene
		if scene == null:
			push_error("showcase: missing model %s" % item)
			continue
		var inst := scene.instantiate() as Node3D
		inst.position = SOCKETS[slot]
		blob.add_child(inst)
		if _labels:
			var lb := Label3D.new()
			lb.text = item
			lb.pixel_size = 0.0035
			lb.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			lb.no_depth_test = true
			lb.modulate = Color("#2e2a33")
			lb.outline_size = 0
			lb.position = pos + Vector3(0, 1.22, 0)
			add_child(lb)
	var width := (cols - 1) * spacing + spacing
	var cam := Camera3D.new()
	cam.fov = 30.0
	var tan_h := tan(deg_to_rad(cam.fov * 0.5)) * 16.0 / 9.0
	var dist := maxf(width * 0.5 / tan_h, 0.75 / tan(deg_to_rad(cam.fov * 0.5))) + 0.3
	if _cam > 0.0:
		dist = _cam
	var target_y := 0.55
	if n == 1:
		target_y = SOCKETS[_items[0].get_slice("_", 0)].y
		if _cam <= 0.0:
			dist = 2.4
	var z_mid := -(rows - 1) * 1.0
	cam.position = Vector3(0, target_y + 0.25 * dist * 0.35, z_mid + dist)
	add_child(cam)
	cam.look_at(Vector3(0, target_y, z_mid), Vector3.UP)
	cam.current = true
