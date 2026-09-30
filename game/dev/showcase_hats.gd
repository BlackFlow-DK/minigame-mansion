extends Node3D
## Dev showcase for game/assets/models/cosmetics/hat_*.glb: stand-in heads (sphere r=0.38 at y=0.62
## on a simple blob body, eyes on +Z at y=0.68), each wearing one hat at the HatSocket (0, 1.0, 0).
## Two rows of six by default. Optional user args after "--":
##   --hats=top_hat,crown   only these, one row   --yaw=90  turn the heads (side/back views)
##   --pitch=35  camera elevation in degrees   --zoom=1.5  closer (default 1.12)   --nospin  freeze propeller
const IDS: Array[String] = [
	"top_hat", "party_cone", "crown", "wizard", "cowboy", "chef",
	"propeller_cap", "pirate", "viking", "flower_pot", "traffic_cone", "cat_ears",
]
const SPACING := 1.35
const ROW_DEPTH := 2.5

var _spinners: Array[Node3D] = []


func _ready() -> void:
	var ids: Array[String] = IDS.duplicate()
	var yaw := 0.0
	var pitch := 24.0
	var zoom := 1.12
	var spin := true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hats="):
			ids = []
			for s in arg.trim_prefix("--hats=").split(",", false):
				ids.append(s)
		elif arg.begins_with("--yaw="):
			yaw = arg.trim_prefix("--yaw=").to_float()
		elif arg.begins_with("--pitch="):
			pitch = arg.trim_prefix("--pitch=").to_float()
		elif arg.begins_with("--zoom="):
			zoom = arg.trim_prefix("--zoom=").to_float()
		elif arg == "--nospin":
			spin = false
	_build_world()
	var cols := 6 if ids.size() > 6 else ids.size()
	var rows := ceili(ids.size() / float(cols))
	var stagger := SPACING * 0.5 if rows > 1 else 0.0
	for i in ids.size():
		var head := _make_head(ids[i])
		var col := i % cols
		@warning_ignore("integer_division")
		var row := i / cols
		head.position = Vector3((col - (cols - 1) * 0.5) * SPACING + (row % 2) * stagger - stagger * 0.5, 0.0, -row * ROW_DEPTH)
		head.rotation_degrees.y = yaw
		add_child(head)
	var width := (cols - 1) * SPACING + 1.7 + stagger
	var depth := (rows - 1) * ROW_DEPTH
	var vf := 28.0
	var dist := (width * 0.5) / (tan(deg_to_rad(vf) * 0.5) * 16.0 / 9.0) + depth * 0.5 + 0.6
	dist /= zoom
	var target := Vector3(0.0, 0.95, -depth * 0.5)
	var cam := Camera3D.new()
	cam.fov = vf
	add_child(cam)
	var p := deg_to_rad(pitch)
	cam.position = target + Vector3(0.0, sin(p), cos(p)) * dist
	cam.look_at(target, Vector3.UP)
	if not spin:
		_spinners.clear()


func _process(delta: float) -> void:
	for s in _spinners:
		s.rotate_y(delta * 14.0)


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#7d9bb5")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#e8e4f0")
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	sun.light_energy = 0.95
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	floor_mi.mesh = plane
	floor_mi.material_override = _flat(Color("#a39b8e"))
	add_child(floor_mi)


func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m


func _make_head(id: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Stand_" + id
	var skin := _flat(Color("#b9bcc6"))
	var body := MeshInstance3D.new()
	var bs := SphereMesh.new()
	bs.radius = 0.34
	bs.height = 0.68
	body.mesh = bs
	body.material_override = skin
	body.position = Vector3(0, 0.34, 0)
	root.add_child(body)
	var head := MeshInstance3D.new()
	var hs := SphereMesh.new()
	hs.radius = 0.38
	hs.height = 0.76
	head.mesh = hs
	head.material_override = skin
	head.position = Vector3(0, 0.62, 0)
	root.add_child(head)
	for sx in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = 0.05
		es.height = 0.10
		eye.mesh = es
		eye.material_override = _flat(Color("#1b1820"))
		var ex: float = sx * 0.14
		var ey := 0.68
		var ez := sqrt(0.38 * 0.38 - ex * ex - (ey - 0.62) * (ey - 0.62))
		eye.position = Vector3(ex, ey, ez)
		root.add_child(eye)
	var socket := Node3D.new()
	socket.name = "HatSocket"
	socket.position = Vector3(0, 1.0, 0)
	root.add_child(socket)
	var path := "res://assets/models/cosmetics/hat_%s.glb" % id
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("showcase_hats: missing %s" % path)
		return root
	var hat := scene.instantiate() as Node3D
	socket.add_child(hat)
	var spin := hat.find_child("Spin", true, false) as Node3D
	if spin:
		_spinners.append(spin)
	return root
