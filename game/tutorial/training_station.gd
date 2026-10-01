class_name TrainingStation
extends Node3D
## One station of the Training Room (res://tutorial/training_room.tscn): a stretch of the
## garden course from its origin (z = 0, local) to z = -`length`, with its own floor, props
## and task. The room makes it current with `begin()`, ticks it on the host with `tick()`
## while it is current, calls `reset()` after the player fell off the course, and opens the
## gate at the station's far end once it raises `completed`.
## The card the player sees comes from `card_title`, `card_line`, `card_tip` and `glyphs`.
## Subclasses live in res://tutorial/stations/; they build their scenery in `build()` from the
## helpers below (floor slabs with collision, ponds, pads) and never talk to other stations.

## The task is done (raised once).
signal completed
## Live task progress for the card ("3 / 5 coins"), empty to hide it.
signal progress_changed(text: String)

## Half the walkable width of the course (x in -HALF_W..HALF_W).
const HALF_W := 4.0
## Floor slab: grass on top, soil below, collision down to this depth.
const GRASS_T := 0.22
const SOIL_DEPTH := 1.4
## The stone path down the middle of the course.
const PATH_HALF_W := 1.3

const GRASS := Color("#7bbd5d")
const SOIL := Color("#7a5236")
const PATH := Color("#e8d6ab")
const STONE := Color("#b8ada2")
const TEAL := Color("#2fa7a0")
const GOLD := Color("#e8b33a")
const CREAM := Color("#f3e6c8")
const PLUM := Color("#6d4a7c")
const CHARCOAL := Color("#2e2a33")

const WATER_MATERIAL := "res://look/materials/water.tres"
const LAVA_MATERIAL := "res://look/materials/lava.tres"

## Short name for the checklist.
var checklist_name: String = ""
## Card: plum title, one-line instruction, optional muted tip.
var card_title: String = ""
var card_line: String = ""
var card_tip: String = ""
## Glyph groups for the card, in order: &"move", &"jump", &"shove", &"pause".
var glyphs: Array[StringName] = []
## Metres covered along -Z.
var length: float = 10.0

var room: TrainingRoom = null
## The human player (set by the room before `begin`).
var player: Player = null
## Dummy blobs of this station, in the order of `dummy_posts()` (set by the room in _setup).
## Their controllers are scripted: the room clears their intent every tick, the station steers.
var dummies: Array[Player] = []
## Effect played where the player drops into this station's pit.
var fall_effect: StringName = &"poof"
var done: bool = false
var active: bool = false

## Materials made here: held by the station so they outlive their meshes (see Look).
var _own_materials: Array[Material] = []


## Virtual: scenery and colliders (called by the room once, in its _ready).
func build() -> void:
	pass


## Virtual: the station became the current one.
func begin() -> void:
	pass


## Virtual: host, every physics frame while this station is current.
func tick(_delta: float) -> void:
	pass


## Virtual: the player fell off the course while this station was current: put it back.
func reset() -> void:
	pass


## Virtual: where the beacon points (global). Default: the middle of the station.
func target() -> Vector3:
	return to_global(Vector3(0.0, 0.0, -length * 0.5))


## Virtual: where this station's dummies stand (global; the basis +Z is where they look).
func dummy_posts() -> Array[Transform3D]:
	return []


## The dummy at `index`, or null when it is missing or out of play.
func dummy(index: int) -> Player:
	if index < 0 or index >= dummies.size() or not live(dummies[index]):
		return null
	return dummies[index]


## Walks `p` toward `to` (flat) at `speed` (0..1 of its top speed). True once within `stop` m.
static func steer(p: Player, to: Vector3, speed: float = 1.0, stop: float = 0.2) -> bool:
	if p == null:
		return false
	var d := Vector2(to.x - p.global_position.x, to.z - p.global_position.z)
	if d.length() <= stop:
		p.intent.move = Vector2.ZERO
		return true
	p.intent.move = d.normalized() * clampf(speed, 0.0, 1.0) * clampf(d.length() / 0.6, 0.35, 1.0)
	return false


## Virtual: whether the room's beacon should show now (a station with its own marker hides it).
func show_beacon() -> bool:
	return true


## Where the player comes back after a fall (global), facing down the course.
func entry() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, PI), to_global(Vector3(0.0, 0.05, -1.3)))


## Local z of the gate at the far end.
func gate_z() -> float:
	return -length + 0.25


## Marks the task done (once).
func complete() -> void:
	if done:
		return
	done = true
	completed.emit()


func set_progress(text: String) -> void:
	progress_changed.emit(text)


## Flat (XZ) distance between two points.
static func flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func live(p: Player) -> bool:
	return p != null and is_instance_valid(p) and p.is_inside_tree() and p.alive


# --- Builders (local coordinates; z_near > z_far) ----------------------------------------------

## A grass slab with its top at `top` covering x0..x1, z_far..z_near, with a box collider and
## the stone path strip down the middle.
func add_ground(z_near: float, z_far: float, top: float = 0.0, x0: float = -HALF_W, x1: float = HALF_W, path: bool = true) -> StaticBody3D:
	var size := Vector3(x1 - x0, SOIL_DEPTH + top, z_near - z_far)
	var centre := Vector3((x0 + x1) * 0.5, top - size.y * 0.5, (z_near + z_far) * 0.5)
	var body := add_static_box(centre, size)
	add_box(Vector3(centre.x, top - GRASS_T * 0.5, centre.z), Vector3(size.x, GRASS_T, size.z), GRASS, body)
	add_box(Vector3(centre.x, (top - GRASS_T - SOIL_DEPTH) * 0.5, centre.z), Vector3(size.x - 0.04, SOIL_DEPTH + top - GRASS_T, size.z - 0.04), SOIL, body)
	if path and x0 < -PATH_HALF_W and x1 > PATH_HALF_W:
		add_box(Vector3(0.0, top + 0.01, centre.z), Vector3(PATH_HALF_W * 2.0, 0.03, size.z), PATH, body, false)
	return body


## A StaticBody3D (world layer) with one box shape.
func add_static_box(centre: Vector3, size: Vector3, parent: Node = null) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = centre
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	(parent if parent else self).add_child(body)
	return body


## A toon box mesh. `pos` is in the station frame (or `parent`'s when that is a Node3D under it:
## then it is converted).
func add_box(pos: Vector3, size: Vector3, color: Color, parent: Node3D = null, outline: bool = true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = Look.toon_material(color, 0.7, outline)
	_attach(mi, pos, parent)
	return mi


## A flat disc (cylinder) mesh, top at pos.y.
func add_disc(pos: Vector3, radius: float, height: float, color: Color, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 40
	mi.mesh = cm
	mi.material_override = Look.toon_material(color, 0.6)
	_attach(mi, pos - Vector3(0.0, height * 0.5, 0.0), parent)
	return mi


## A pond (water) or lava lake filling x0..x1, z_far..z_near at height `y`.
func add_liquid(z_near: float, z_far: float, y: float, lava: bool = false, x0: float = -HALF_W - 0.3, x1: float = HALF_W + 0.3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(x1 - x0, z_near - z_far)
	pm.subdivide_width = 8
	pm.subdivide_depth = 8
	mi.mesh = pm
	var mat := load(LAVA_MATERIAL if lava else WATER_MATERIAL) as Material
	if mat:
		mi.set_surface_override_material(0, mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3((x0 + x1) * 0.5, y, (z_near + z_far) * 0.5)
	add_child(mi)
	# Dark pit walls below the rim, so the pond reads as sunk into the lawn.
	add_box(Vector3((x0 + x1) * 0.5, y - 0.6, (z_near + z_far) * 0.5), Vector3(x1 - x0, 0.2, z_near - z_far), SOIL.darkened(0.4), null, false)
	return mi


## A glowing target ring on the ground (teal; `set_ring_done` turns it gold).
func add_ring_marker(pos: Vector3, radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = radius - 0.16
	tm.outer_radius = radius
	tm.rings = 48
	tm.ring_segments = 6
	mi.mesh = tm
	mi.scale = Vector3(1.0, 0.35, 1.0)
	mi.material_override = glow_material(TEAL, 2.2)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos + Vector3(0.0, 0.04, 0.0)
	add_child(mi)
	return mi


func set_ring_done(mi: MeshInstance3D) -> void:
	if mi:
		mi.material_override = glow_material(GOLD, 2.6)


## An unshaded-ish emissive material (held by this station).
func glow_material(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_own_materials.append(m)
	return m


## Instances a prop/kit model with the toon look.
func add_model(path: String, pos: Vector3, yaw_deg: float = 0.0, scale_by: float = 1.0, parent: Node3D = null) -> Node3D:
	var scene := load(path) as PackedScene
	if scene == null:
		push_warning("training: missing model %s" % path)
		return null
	var node := scene.instantiate() as Node3D
	node.rotation_degrees.y = yaw_deg
	node.scale = Vector3.ONE * scale_by
	_attach(node, pos, parent)
	Look.apply_toon(node)
	return node


func _attach(n: Node3D, pos: Vector3, parent: Node3D) -> void:
	if parent == null:
		n.position = pos
		add_child(n)
	else:
		parent.add_child(n)
		n.global_position = to_global(pos) if is_inside_tree() else pos - parent.position
