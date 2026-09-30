extends Node3D
## Fit check: every cosmetic on the REAL blob, dressed through `Cosmetics.apply()` with the
## catalog fit. One row per loadout, one column per view (front, three-quarter from above,
## side, back), orthographic camera so rows and columns line up.
## Run: tools\godot-screenshot.ps1 -Scene res://cosmetics/dev/fit_check.tscn -Resolution 1600x900
##        -Out build\screenshots\fit_hat_1.png -GameArgs "--group=hat --page=0"
## User args: --group=hat|face|neck|back|combo|defaults  --page=N (3 rows per page)  --rows=N
##            --items=hat:crown,face:monocle (one row per item; "hat:crown+face:monocle" dresses one row
##              in both; "face:moustache@ox/oy/oz/rx/ry/rz/s" tries a fit on that row instead of the catalog's)
##            --zoom=1.0  --cy=0.8 (view centre y)  --colw=1.3  --rowh=1.8  --views=front,34,side,back

const BLOB := preload("res://assets/models/character/blob.glb")
const VIEWS := {
	"front": [0.0, 0.0],
	"34": [-35.0, 22.0],
	"side": [-90.0, 0.0],
	"back": [180.0, 0.0],
	"top": [0.0, 60.0],
}
const COMBOS: Array[Array] = [
	["top_hat", "round_glasses", "scarf", "cape"],
	["wizard", "star_shades", "bow_tie", "angel_wings"],
	["cowboy", "moustache", "bandana", "backpack"],
	["viking", "eye_patch", "gold_chain", "turtle_shell"],
	["pirate", "monocle", "flower_lei", "jetpack"],
	["chef", "clown_nose", "scarf", "cape"],
	["propeller_cap", "round_glasses", "bow_tie", "jetpack"],
	["cat_ears", "star_shades", "flower_lei", "angel_wings"],
	["crown", "monocle", "gold_chain", "cape"],
	["flower_pot", "moustache", "bandana", "turtle_shell"],
	["traffic_cone", "clown_nose", "scarf", "backpack"],
	["party_cone", "eye_patch", "bow_tie", "angel_wings"],
]


func _ready() -> void:
	var group := "hat"
	var page := 0
	var rows_per_page := 3
	var zoom := 1.0
	var cy := 0.8
	var col_w := 1.3
	var row_h := 1.8
	var items: Array[String] = []
	var views: Array[String] = ["front", "34", "side", "back"]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--group="):
			group = arg.trim_prefix("--group=")
		elif arg.begins_with("--page="):
			page = arg.trim_prefix("--page=").to_int()
		elif arg.begins_with("--rows="):
			rows_per_page = arg.trim_prefix("--rows=").to_int()
		elif arg.begins_with("--zoom="):
			zoom = arg.trim_prefix("--zoom=").to_float()
		elif arg.begins_with("--colw="):
			col_w = arg.trim_prefix("--colw=").to_float()
		elif arg.begins_with("--rowh="):
			row_h = arg.trim_prefix("--rowh=").to_float()
		elif arg.begins_with("--cy="):
			cy = arg.trim_prefix("--cy=").to_float()
		elif arg.begins_with("--items="):
			for s in arg.trim_prefix("--items=").split(",", false):
				items.append(s)
		elif arg.begins_with("--views="):
			views.clear()
			for s in arg.trim_prefix("--views=").split(",", false):
				views.append(s)
	var loadouts := _loadouts(group, items)
	var first := page * rows_per_page
	loadouts = loadouts.slice(first, first + rows_per_page)
	_build_world()
	var primaries := Cosmetics.palette(&"primary")
	var secondaries := Cosmetics.palette(&"secondary")
	for r in loadouts.size():
		var lo: Dictionary = loadouts[r]
		if not lo.has("primary"):
			lo["primary"] = primaries[(first + r) % 8]
			lo["secondary"] = secondaries[(first + r) % secondaries.size()]
		var y := -r * row_h
		for c in views.size():
			var view: Array = VIEWS.get(views[c], VIEWS["front"])
			var blob := BLOB.instantiate() as Node3D
			blob.position = Vector3(c * col_w, y, r * 1.5)  # lower rows in front
			# Yaw first, then tip the top towards the camera (world X) to look from above.
			blob.basis = Basis(Vector3.RIGHT, deg_to_rad(view[1])) * Basis(Vector3.UP, deg_to_rad(view[0]))
			add_child(blob)
			Cosmetics.apply(blob, lo)
			Cosmetics.apply(blob, lo)  # second call must be a no-op
			for slot: String in lo.get("_fit", {}):
				var node := Cosmetics.get_item_node(blob, StringName(slot))
				if node:
					node.transform = Cosmetics.fit_transform(lo["_fit"][slot])
		var label := Label3D.new()
		label.text = _label(lo)
		label.pixel_size = 0.0028
		label.modulate = Color("#1e1a24")
		label.outline_size = 0
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.position = Vector3(-0.55, y + 0.5, r * 1.5)
		add_child(label)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	var rows := maxi(loadouts.size(), 1)
	cam.size = maxf(rows * row_h, 1.6) / zoom
	var width := (views.size() - 1) * col_w
	cam.position = Vector3(width * 0.5 - 0.35 / zoom, cy - (rows - 1) * row_h * 0.5, 10.0)
	add_child(cam)
	cam.current = true


func _loadouts(group: String, items: Array[String]) -> Array:
	var out: Array = []
	if not items.is_empty():
		for spec in items:
			var lo := {"hat": "", "face": "", "neck": "", "back": ""}
			for part in spec.split("+", false):
				var slot := part.get_slice(":", 0)
				var rest := part.get_slice(":", 1)
				lo[slot] = rest.get_slice("@", 0)
				if rest.contains("@"):
					var fit := rest.get_slice("@", 1)
					var n := fit.split_floats("/")
					var count := n.size()
					n.resize(9)
					var scl := Vector3(n[6], n[7], n[8]) if count >= 9 else Vector3.ONE * (n[6] if count >= 7 else 1.0)
					if not lo.has("_fit"):
						lo["_fit"] = {}
					lo["_fit"][slot] = {"offset": Vector3(n[0], n[1], n[2]), "rotation": Vector3(n[3], n[4], n[5]), "scale": scl}
					lo["_label"] = lo.get("_label", "") + fit + " "
			out.append(lo)
		return out
	if group == "defaults":
		for s in 8:
			out.append(Cosmetics.default_loadout(s))
		return out
	if group == "combo":
		for combo in COMBOS:
			out.append({"hat": combo[0], "face": combo[1], "neck": combo[2], "back": combo[3]})
		return out
	for entry: Dictionary in Cosmetics.catalog(StringName(group)):
		if entry["id"] == "":
			continue
		var lo := {"hat": "", "face": "", "neck": "", "back": ""}
		lo[group] = entry["id"]
		out.append(lo)
	return out


func _label(lo: Dictionary) -> String:
	var parts: Array[String] = []
	for slot in ["hat", "face", "neck", "back"]:
		if lo.get(slot, "") != "":
			parts.append(lo[slot])
	if lo.has("_label"):
		parts.append(lo["_label"])
	return "\n".join(parts) if not parts.is_empty() else "(none)"


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#b8c4d4")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#eef2f8")
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 25, 0)
	sun.light_energy = 1.1
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, 200, 0)
	fill.light_energy = 0.45
	add_child(fill)
