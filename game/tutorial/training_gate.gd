class_name TrainingGate
extends Node3D
## A garden gate across the whole Training Room course: two stone posts with gold caps and
## a plum slatted gate between them. Closed it blocks the way (a tall invisible collider, so
## nobody jumps over it); `open()` drops the collider at once and sinks the gate into the lawn.

signal opened

const WIDTH := 8.0
const HEIGHT := 1.35
const BLOCK_HEIGHT := 5.0

var is_open: bool = false

var _body: StaticBody3D
var _shape: CollisionShape3D
var _gate: Node3D


func _ready() -> void:
	_body = StaticBody3D.new()
	_body.name = "Blocker"
	_body.collision_layer = 1
	_body.collision_mask = 0
	_shape = CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(WIDTH, BLOCK_HEIGHT, 0.4)
	_shape.shape = box
	_shape.position = Vector3(0.0, BLOCK_HEIGHT * 0.5, 0.0)
	_body.add_child(_shape)
	add_child(_body)

	_gate = Node3D.new()
	_gate.name = "Gate"
	add_child(_gate)
	var plum := Look.toon_material(Color("#6d4a7c"), 0.6)
	var gold := Look.toon_material(Color("#e8b33a"), 0.4)
	var wood := Look.toon_material(Color("#8a5a3c"), 0.7)
	# Upright pickets between two rails.
	var pickets := 13
	for i in pickets:
		var x := -WIDTH * 0.5 + 0.55 + (WIDTH - 1.1) * float(i) / float(pickets - 1)
		_mesh(_gate, Vector3(0.2, HEIGHT - 0.1, 0.16), Vector3(x, (HEIGHT - 0.1) * 0.5, 0.0), plum)
		_mesh(_gate, Vector3(0.26, 0.12, 0.2), Vector3(x, HEIGHT - 0.04, 0.0), gold)
	for y: float in [0.3, HEIGHT - 0.35]:
		_mesh(_gate, Vector3(WIDTH - 0.9, 0.14, 0.12), Vector3(0.0, y, 0.1), wood)
	# Posts stay put when the gate opens.
	var stone := Look.toon_material(Color("#b8ada2"), 0.8)
	for sx: float in [-1.0, 1.0]:
		_mesh(self, Vector3(0.5, HEIGHT + 0.5, 0.5), Vector3(sx * (WIDTH * 0.5 - 0.1), (HEIGHT + 0.5) * 0.5, 0.0), stone)
		_mesh(self, Vector3(0.62, 0.14, 0.62), Vector3(sx * (WIDTH * 0.5 - 0.1), HEIGHT + 0.55, 0.0), gold)


## Opens the gate (idempotent). `animate` false: jump to the open state (dev screenshots).
func open(animate: bool = true) -> void:
	if is_open:
		return
	is_open = true
	_shape.set_deferred(&"disabled", true)
	_body.collision_layer = 0
	if animate and is_inside_tree():
		var tw := create_tween()
		tw.tween_property(_gate, ^"position:y", 0.12, 0.12).set_trans(Tween.TRANS_SINE)
		tw.tween_property(_gate, ^"position:y", -HEIGHT - 0.2, 0.55).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		tw.tween_callback(func() -> void: _gate.visible = false)
		Sfx.play(&"platform_fall", global_position + Vector3.UP * 0.5)
		Fx.play(&"dust_puff", global_position + Vector3.UP * 0.2, Color(0.75, 0.65, 0.5))
	else:
		_gate.position.y = -HEIGHT - 0.2
		_gate.visible = false
	opened.emit()


## True while the collider still blocks the way.
func is_blocking() -> bool:
	return not is_open and _body.collision_layer != 0


func _mesh(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
