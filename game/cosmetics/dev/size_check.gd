extends Node3D
## Size check: real Player scenes (so the `size` component does the scaling) in small, normal
## and big, all wearing the same hat, glasses and cape, standing on a floor.
## Run: tools\godot-screenshot.ps1 -Scene res://cosmetics/dev/size_check.tscn -Frames 90
##        -Out build\screenshots\size_close.png [-GameArgs "--view=back --hat=crown"]
## User args: --view=front|34|back|side  --sizes=small,big (which, left to right)
##            --hat=id --face=id --neck=id --back=id  --zoom=1.0

const PLAYER_SCENE := "res://player/player.tscn"
const VIEWS := {"front": 0.0, "34": -35.0, "side": -90.0, "back": 180.0}


func _ready() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			var kv := arg.trim_prefix("--").split("=", true, 1)
			args[kv[0]] = kv[1]
	var sizes: PackedStringArray = String(args.get("sizes", "small,normal,big")).split(",", false)
	var yaw := deg_to_rad(float(VIEWS.get(args.get("view", "34"), -35.0)))
	var zoom := float(args.get("zoom", "1.0"))

	var look := (load("res://look/stage_look.tscn") as PackedScene).instantiate()
	look.set(&"preset", 0)
	add_child(look)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 1, 20)
	shape.shape = box
	shape.position.y = -0.5
	ground.add_child(shape)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	floor_mesh.mesh = plane
	floor_mesh.material_override = Look.toon_material(Color("#c9a978"))
	ground.add_child(floor_mesh)
	add_child(ground)

	var scene := load(PLAYER_SCENE) as PackedScene
	var spacing := 1.45
	for i in sizes.size():
		var p := scene.instantiate() as Player
		p.name = "P%d" % i
		p.slot = i
		p.loadout = {
			"primary": Cosmetics.palette(&"primary")[[0, 1, 2, 4][i % 4]],
			"secondary": Cosmetics.palette(&"secondary")[1],
			"hat": args.get("hat", "top_hat"), "face": args.get("face", "round_glasses"),
			"neck": args.get("neck", ""), "back": args.get("back", "cape"),
			"size": sizes[i],
		}
		p.frozen = true
		# Placed before entering the tree: blobs added on top of each other stack up.
		p.place_at(Transform3D(Basis(Vector3.UP, yaw), Vector3((i - (sizes.size() - 1) * 0.5) * spacing, 0.0, 0.0)))
		add_child(p)
		var label := Label3D.new()
		label.text = sizes[i]
		label.pixel_size = 0.004
		label.position = Vector3((i - (sizes.size() - 1) * 0.5) * spacing, 0.02, 0.9)
		label.rotation_degrees = Vector3(-90, 0, 0)
		label.modulate = Color("#2e2a33")
		label.outline_size = 0
		add_child(label)

	var cam := Camera3D.new()
	cam.fov = 32.0
	add_child(cam)
	var width := maxf((sizes.size() - 1) * spacing, 1.0)
	var dist := (2.2 + width * 1.35) / zoom
	cam.look_at_from_position(Vector3(0.0, 1.0 + dist * 0.28, dist), Vector3(0.0, 0.62, 0.0))
	cam.current = true
