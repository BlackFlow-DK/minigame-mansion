extends Node3D
## Outline check: the real blob.glb dressed through Cosmetics.apply and toon'd through
## BlobToon.apply (exactly like the player components do), under a StageLook, perspective
## camera. User args after `--`:
##   --view=close   three dressed blobs from ~3 m (default)
##   --view=wardrobe  one blob filling the screen (the wardrobe preview distance)
##   --view=far     eight dressed blobs from ~16 m (gameplay distance)
##   --debug        print each prepared mesh's size, fill and outline weight
##   --squash       squash-and-stretch the model roots (as the animator does mid-landing)
##   --combo=N      first combo for close/wardrobe (0..3)
##   --preset=warm_hall|bright_day|lava_cave|night_party

const BLOB: PackedScene = preload("res://assets/models/character/blob.glb")
const COMBOS: Array[Dictionary] = [
	{"primary": "#e0303a", "secondary": "#fff1c1", "hat": "top_hat", "face": "round_glasses", "neck": "scarf", "back": "cape"},
	{"primary": "#2f7fe0", "secondary": "#cde8ff", "hat": "wizard", "face": "star_shades", "neck": "bow_tie", "back": "angel_wings"},
	{"primary": "#58b368", "secondary": "#f3e6c8", "hat": "cowboy", "face": "moustache", "neck": "bandana", "back": "backpack"},
	{"primary": "#f08fb0", "secondary": "#fff1c1", "hat": "viking", "face": "eye_patch", "neck": "gold_chain", "back": "turtle_shell"},
	{"primary": "#e8b33a", "secondary": "#6d4a7c", "hat": "pirate", "face": "monocle", "neck": "flower_lei", "back": "jetpack"},
	{"primary": "#2fa7a0", "secondary": "#f3e6c8", "hat": "crown", "face": "clown_nose", "neck": "gold_chain", "back": "cape"},
	{"primary": "#6d4a7c", "secondary": "#f08fb0", "hat": "propeller_cap", "face": "round_glasses", "neck": "bow_tie", "back": "jetpack"},
	{"primary": "#d9483b", "secondary": "#f3e6c8", "hat": "chef", "face": "moustache", "neck": "scarf", "back": "backpack"},
]


func _ready() -> void:
	var view := "close"
	var squash := false
	var first := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			view = arg.trim_prefix("--view=")
		elif arg == "--debug":
			Look.outline_debug = true
		elif arg == "--squash":
			squash = true
		elif arg.begins_with("--combo="):
			first = clampi(arg.trim_prefix("--combo=").to_int(), 0, COMBOS.size() - 1)
		elif arg.begins_with("--preset="):
			var key := arg.trim_prefix("--preset=").to_upper()
			if StageLook.Preset.has(key):
				($StageLook as StageLook).preset = StageLook.Preset[key]
	var cam := $Camera3D as Camera3D
	match view:
		"far":
			for i in 8:
				var a := TAU * i / 8.0
				_blob(COMBOS[i], Vector3(cos(a) * 4.0, 0, sin(a) * 4.0), -a + PI * 0.5 + 0.6, squash and i % 2 == 0)
			cam.position = Vector3(0, 11.0, 12.0)
			cam.look_at(Vector3(0, 0.4, 0))
		"wardrobe":
			_blob(COMBOS[first], Vector3.ZERO, -0.45, squash)
			cam.fov = 40.0
			cam.position = Vector3(0, 1.0, 2.2)
			cam.look_at(Vector3(0, 0.62, 0))
		_:
			for i in 3:
				_blob(COMBOS[(first + i) % COMBOS.size()], Vector3((i - 1) * 1.35, 0, 0), -0.35 + 0.35 * i, squash)
			cam.position = Vector3(0, 1.6, 3.6)
			cam.look_at(Vector3(0, 0.6, 0))


func _blob(loadout: Dictionary, pos: Vector3, yaw: float, squash: bool) -> void:
	var holder := Node3D.new()
	holder.position = pos
	holder.rotation.y = yaw
	add_child(holder)
	var model := BLOB.instantiate() as Node3D
	holder.add_child(model)
	get_node(^"/root/Cosmetics").call(&"apply", model, loadout)
	BlobToon.apply(model)
	if squash:
		model.scale = Vector3(1.22, 0.78, 1.22)
	holder.add_child(BlobShadow.new())
