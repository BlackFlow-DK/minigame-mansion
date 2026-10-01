class_name TrainingBeacon
extends Node3D
## The "go here next" marker of the Training Room: a gold arrow bobbing over the current
## station's goal and a soft pulsing ring on the ground under it. It glides to a new goal.

const ARROW_SCENE := "res://assets/models/props/arrow_marker.glb"
const ARROW_HEIGHT := 2.7

## Where the beacon points (global, on the ground).
var goal: Vector3 = Vector3.ZERO

var _arrow: Node3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _time: float = 0.0
var _snapped: bool = false


func _ready() -> void:
	top_level = true
	var scene := load(ARROW_SCENE) as PackedScene
	_arrow = scene.instantiate() as Node3D if scene else Node3D.new()
	_arrow.name = "Arrow"
	_arrow.scale = Vector3.ONE * 1.1
	add_child(_arrow)
	Look.apply_toon(_arrow)
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.55
	torus.outer_radius = 0.75
	torus.rings = 40
	torus.ring_segments = 6
	_ring.mesh = torus
	_ring.scale = Vector3(1.0, 0.2, 1.0)
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ring_mat.albedo_color = Color(1.0, 0.8, 0.3, 0.6)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)


func point_at(at: Vector3, snap: bool = false) -> void:
	goal = at
	if snap or not _snapped:
		_snapped = true
		global_position = at


func _process(delta: float) -> void:
	_time += delta
	global_position = global_position.lerp(goal, 1.0 - exp(-6.0 * delta))
	_arrow.position.y = ARROW_HEIGHT + 0.18 * sin(_time * 3.2)
	_arrow.rotation.y = _time * 1.6
	var pulse := 0.5 + 0.5 * sin(_time * 4.0)
	_ring.position.y = 0.06
	_ring.scale = Vector3(1.0 + 0.25 * pulse, 0.2, 1.0 + 0.25 * pulse)
	_ring_mat.albedo_color.a = 0.25 + 0.35 * (1.0 - pulse)
