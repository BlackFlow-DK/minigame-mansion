class_name VisualsComponent
extends PlayerComponent
## Shows the blob model and animates it in code. Owner: character animator.
## Stub: a placeholder capsule in the player's primary colour with two eyes on its
## front (+Z), turned to `player.facing` every frame on every peer.

var _model: Node3D


func _ready() -> void:
	_model = Node3D.new()
	_model.name = "Placeholder"
	add_child(_model)
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.0
	body.mesh = capsule
	body.position.y = 0.5
	body.material_override = _flat(_primary_colour())
	_model.add_child(body)
	for side: float in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var ball := SphereMesh.new()
		ball.radius = 0.09
		ball.height = 0.18
		eye.mesh = ball
		eye.position = Vector3(0.14 * side, 0.68, 0.34)
		eye.material_override = _flat(Color.WHITE)
		_model.add_child(eye)
		var pupil := MeshInstance3D.new()
		var dot := SphereMesh.new()
		dot.radius = 0.045
		dot.height = 0.09
		pupil.mesh = dot
		pupil.position = Vector3(0.14 * side, 0.68, 0.42)
		pupil.material_override = _flat(Color(0.05, 0.05, 0.08))
		_model.add_child(pupil)


func _process(_delta: float) -> void:
	if player == null:
		return
	var f := player.facing
	if f.length_squared() > 0.0001:
		rotation.y = atan2(f.x, f.z)


func _primary_colour() -> Color:
	if player and player.loadout.has("primary"):
		return Color.from_string(str(player.loadout["primary"]), Color.WHITE)
	return Color.WHITE


func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.7
	return m
