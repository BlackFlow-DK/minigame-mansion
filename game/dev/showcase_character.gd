extends Node3D
## Character showcase for the player blob (art review, not gameplay).
## Views (user arg after "--"): --view=row (default: front, three-quarter, side, back + tinted),
## --view=close (face close-up), --view=close34 (three-quarter close-up), --view=anim (rest / blink + look / mouth open / eyes shut, mouth closed),
## --view=game (eight tinted blobs from gameplay distance, ~12 m).
## On start it prints every imported node with its position and checks the contract names and sockets.

const BLOB := preload("res://assets/models/character/blob.glb")

const CONTRACT_NODES: Array[String] = [
	"Body", "EyeL", "EyeR", "PupilL", "PupilR", "LidL", "LidR", "Mouth",
	"CheekL", "CheekR", "HandL", "HandR", "FootL", "FootR",
]
const CONTRACT_SOCKETS := {
	"HatSocket": Vector3(0.0, 1.0, 0.0),
	"FaceSocket": Vector3(0.0, 0.68, 0.37),
	"NeckSocket": Vector3(0.0, 0.40, 0.0),
	"BackSocket": Vector3(0.0, 0.50, -0.37),
}
## Lid rotation.x (radians) for a half-closed and a fully closed eye; 0 = open (rest).
const LID_HALF := 1.2
const LID_CLOSED := 2.0
const TINTS: Array[Array] = [
	["#ff5a5f", "#ffd0c2"], ["#3fa9f5", "#d6ecff"], ["#62c370", "#e3f7c6"], ["#ffc93c", "#fff2c2"],
	["#a26bff", "#e6d6ff"], ["#ff8c42", "#ffe0c7"], ["#2ec4b6", "#cff7f0"], ["#f7f7f7", "#9aa0a6"],
]

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	var view := "row"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			view = arg.trim_prefix("--view=")
	_report()
	match view:
		"close":
			_add_blob(Vector3(0, 0, 0), 0.0)
			_look(Vector3(0.0, 0.72, 1.55), Vector3(0.0, 0.55, 0.0), 40.0)
		"close34":
			_add_blob(Vector3(0, 0, 0), -40.0)
			_look(Vector3(0.0, 0.8, 1.8), Vector3(0.0, 0.5, 0.0), 40.0)
		"anim":
			_build_anim()
		"game":
			_build_game()
		_:
			_build_row()


func _build_row() -> void:
	var angles: Array[float] = [0.0, -35.0, -90.0, 180.0]
	for i in angles.size():
		_add_blob(Vector3(-2.7 + 1.35 * i, 0, 0), angles[i])
	var tinted := _add_blob(Vector3(2.7, 0, 0), -20.0)
	_tint(tinted, Color("#3fa9f5"), Color("#ffe066"))
	_look(Vector3(0.0, 1.5, 5.6), Vector3(0.0, 0.5, 0.0), 40.0)


func _build_anim() -> void:
	# Proves the animation rig: rest, blink half + pupils looking, mouth wide open, eyes shut + mouth shut.
	var rest := _add_blob(Vector3(-1.8, 0, 0), 0.0)
	var look := _add_blob(Vector3(-0.6, 0, 0), 0.0)
	_part(look, "LidL").rotation.x = LID_HALF
	_part(look, "LidR").rotation.x = LID_HALF
	_part(look, "PupilL").position += Vector3(0.02, 0.0, 0.0)
	_part(look, "PupilR").position += Vector3(0.02, 0.0, 0.0)
	_part(look, "Mouth").scale = Vector3(0.8, 0.45, 1.0)
	var shout := _add_blob(Vector3(0.6, 0, 0), 0.0)
	_part(shout, "PupilL").position += Vector3(0.0, 0.015, 0.0)
	_part(shout, "PupilR").position += Vector3(0.0, 0.015, 0.0)
	_part(shout, "Mouth").scale = Vector3(1.15, 1.8, 1.0)
	var shut := _add_blob(Vector3(1.8, 0, 0), 0.0)
	_part(shut, "LidL").rotation.x = LID_CLOSED
	_part(shut, "LidR").rotation.x = LID_CLOSED
	_part(shut, "Mouth").scale = Vector3(0.9, 0.15, 1.0)
	_tint(shut, Color("#ff5a5f"), Color("#ffd0c2"))
	_tint(shout, Color("#62c370"), Color("#e3f7c6"))
	_look(Vector3(0.0, 1.0, 3.6), Vector3(0.0, 0.55, 0.0), 40.0)
	rest.name = "Rest"


func _build_game() -> void:
	for i in TINTS.size():
		var col := i % 4
		var row := i / 4
		var blob := _add_blob(Vector3(-2.4 + 1.6 * col, 0, -1.0 + 2.0 * row), -15.0 + 12.0 * col)
		_tint(blob, Color(TINTS[i][0]), Color(TINTS[i][1]))
	# Roughly the gameplay camera: ~12 m away, looking down at about 45 degrees.
	_look(Vector3(0.0, 8.5, 8.5), Vector3(0.0, 0.3, -0.2), 50.0)


func _add_blob(pos: Vector3, yaw_deg: float) -> Node3D:
	var blob := BLOB.instantiate() as Node3D
	blob.position = pos
	blob.rotation.y = deg_to_rad(yaw_deg)
	add_child(blob)
	return blob


func _part(blob: Node3D, part_name: String) -> Node3D:
	return blob.get_node(part_name) as Node3D


func _look(from: Vector3, at: Vector3, fov: float) -> void:
	_camera.position = from
	_camera.fov = fov
	_camera.look_at(at, Vector3.UP)


## Recolours the PlayerPrimary / PlayerSecondary surfaces of one blob (per-instance overrides).
func _tint(blob: Node3D, primary: Color, secondary: Color) -> void:
	for node in blob.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(i) as BaseMaterial3D
			if mat == null:
				continue
			var colour: Color
			if mat.resource_name == "PlayerPrimary":
				colour = primary
			elif mat.resource_name == "PlayerSecondary":
				colour = secondary
			else:
				continue
			var copy := mat.duplicate() as BaseMaterial3D
			copy.albedo_color = colour
			mi.set_surface_override_material(i, copy)


func _report() -> void:
	var blob := BLOB.instantiate() as Node3D
	var tris := 0
	var materials: Dictionary = {}
	print("showcase: blob root '%s' children:" % blob.name)
	for child in blob.get_children():
		var n3 := child as Node3D
		var line := "  %-10s %-16s pos=%s" % [n3.name, n3.get_class(), n3.position]
		var mi := n3 as MeshInstance3D
		if mi != null:
			var t := 0
			var names: Array[String] = []
			for i in mi.mesh.get_surface_count():
				t += mi.mesh.surface_get_array_index_len(i) / 3
				var mat := mi.mesh.surface_get_material(i)
				names.append(mat.resource_name if mat else "<none>")
				materials[names[-1]] = true
			tris += t
			line += " tris=%d mats=%s" % [t, names]
		if n3.get_child_count() > 0:
			line += " children=%d" % n3.get_child_count()
		print(line)
	print("showcase: total tris=%d materials=%s" % [tris, materials.keys()])
	var ok := true
	for n in CONTRACT_NODES:
		if blob.get_node_or_null(n) == null:
			push_error("showcase: missing contract node %s" % n)
			ok = false
	for s: String in CONTRACT_SOCKETS:
		var node := blob.get_node_or_null(s) as Node3D
		if node == null:
			push_error("showcase: missing socket %s" % s)
			ok = false
		elif not node.position.is_equal_approx(CONTRACT_SOCKETS[s]):
			push_error("showcase: socket %s at %s, contract %s" % [s, node.position, CONTRACT_SOCKETS[s]])
			ok = false
	for m in ["PlayerPrimary", "PlayerSecondary"]:
		if not materials.has(m):
			push_error("showcase: material %s missing" % m)
			ok = false
	print("showcase: contract check %s" % ("OK" if ok else "FAILED"))
	blob.free()
