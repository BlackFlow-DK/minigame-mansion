extends Node3D
## Dev scene for the wardrobe (and screenshots). Uses its own profile file, so the real one is
## never touched. User args (all optional):
##   --tab=colour|body|hat|face|neck|back page to open
##   --primary=#hex --secondary=#hex       saved colours to open with
##   --hat=id --face=id --neck=id --back=id --size=small|normal|big   saved items to open with
##   --name=Text                           saved name
##   --random=<seed>                       open with a random look (seeded)
##   --turn=<radians>                      turn the blob
##   --focus=tab|item|name|done            where the keyboard focus sits
##   --bg=title|world|menu                 plum backdrop (default), a 3D lobby stand-in, or the
##                                         real title menu opening it (as players reach it)
##   --equip=slot:id                       equip after opening (the preview reacts; size:big too)
## e.g. tools/godot-screenshot.ps1 -Scene res://ui/wardrobe/dev/wardrobe_dev.tscn -Frames 120 -GameArgs "--tab=hat --hat=crown"

const WARDROBE_SCENE := "res://ui/wardrobe/wardrobe.tscn"
const DEV_PROFILE := "user://wardrobe_dev_profile.json"

var wardrobe: Wardrobe
var _layer: CanvasLayer
var _args: Dictionary = {}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			var kv := arg.trim_prefix("--").split("=", true, 1)
			_args[kv[0]] = kv[1]
	Cosmetics.profile_path = DEV_PROFILE
	var look := Cosmetics.default_loadout(0)
	look["hat"] = ""
	if _args.has("random"):
		var rng := RandomNumberGenerator.new()
		rng.seed = int(_args["random"])
		look["primary"] = Cosmetics.palette(&"primary")[rng.randi_range(0, 15)]
		look["secondary"] = Cosmetics.palette(&"secondary")[rng.randi_range(0, 11)]
		for slot: StringName in Cosmetics.SLOTS:
			var items := Cosmetics.catalog(slot)
			look[String(slot)] = items[rng.randi_range(0, items.size() - 1)]["id"]
	for key in ["primary", "secondary", "hat", "face", "neck", "back", "size"]:
		if _args.has(key):
			look[key] = _args[key]
	Cosmetics.save_profile(_args.get("name", "Sander"), look)

	if _args.get("bg", "title") == "menu":
		_open_from_menu()
		return
	if _args.get("bg", "title") == "world":
		_build_world()
	else:
		var bg_layer := CanvasLayer.new()
		bg_layer.layer = -1
		add_child(bg_layer)
		var bg := ColorRect.new()
		bg.color = Color("#6d4a7c")
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg_layer.add_child(bg)
	_layer = CanvasLayer.new()
	_layer.layer = 5
	add_child(_layer)
	_open()


## The real path: the title menu's Wardrobe button (the menu instances and frees it).
func _open_from_menu() -> void:
	var menu := (load("res://ui/menu/menu_root.tscn") as PackedScene).instantiate() as MenuRoot
	add_child(menu)
	await get_tree().process_frame
	menu.open_wardrobe()
	await get_tree().process_frame
	wardrobe = menu.find_child("Wardrobe", true, false) as Wardrobe
	if wardrobe:
		_setup()


func _open() -> void:
	wardrobe = (load(WARDROBE_SCENE) as PackedScene).instantiate() as Wardrobe
	wardrobe.closed.connect(_on_closed)
	_layer.add_child(wardrobe)
	_setup.call_deferred()


func _setup() -> void:
	wardrobe.open_tab(StringName(_args.get("tab", "colour")))
	if _args.has("turn"):
		wardrobe.preview.turn(float(_args["turn"]))
	if _args.has("equip"):
		var parts := String(_args["equip"]).split(":")
		if parts.size() == 2 and parts[0] == "size":
			wardrobe.select_size(parts[1])
		elif parts.size() == 2:
			wardrobe.select_item(StringName(parts[0]), parts[1])
	await get_tree().process_frame
	match _args.get("focus", "tab"):
		"tab":
			(wardrobe.tab_buttons[wardrobe.current_tab] as Button).grab_focus()
		"item":
			var target := wardrobe._page_focus_target()
			if target:
				target.grab_focus()
		"name":
			wardrobe.name_edit.grab_focus()
		"done":
			wardrobe.done_button.grab_focus()


func _on_closed() -> void:
	print("wardrobe_dev: closed, saved %s" % Cosmetics.load_profile())
	wardrobe.queue_free()
	_open.call_deferred()


## A stand-in for the 3D lobby behind the overlay.
func _build_world() -> void:
	var look := (load("res://look/stage_look.tscn") as PackedScene).instantiate()
	add_child(look)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 7, 9)
	cam.rotation_degrees = Vector3(-35, 0, 0)
	add_child(cam)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30, 30)
	floor_mesh.mesh = plane
	floor_mesh.material_override = Look.toon_material(Color("#c9a978"))
	add_child(floor_mesh)
	for i in 5:
		var blob := BlobRig.SCENE.instantiate() as Node3D
		blob.position = Vector3(-4.0 + i * 2.0, 0.0, sin(i * 1.7) * 1.5)
		add_child(blob)
		Cosmetics.apply(blob, Cosmetics.default_loadout(i))
		Look.apply_toon(blob)
