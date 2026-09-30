class_name BlobShadow
extends MeshInstance3D
## A soft round contact shadow straight under its parent: shows where a jumping player will
## land. Casts a ray down against the world layer each physics frame, lies flat on what it
## hits, shrinks and fades with height, hides when nothing is below. Add it as a child of
## the thing to follow. Owner: look and effects.

const MATERIAL: ShaderMaterial = preload("res://look/materials/blob_shadow.tres")

## Radius on the ground at zero height, metres.
@export var radius: float = 0.46
## Beyond this height the shadow is at its faintest; the ray reaches twice as far.
@export var fade_height: float = 5.0
## Physics layers the shadow lands on (default: `world`).
@export_flags_3d_physics var collision_mask: int = 1
## Strength on the ground and at `fade_height`.
@export var near_strength: float = 0.5
@export var far_strength: float = 0.14

static var _quad: PlaneMesh

var _exclude: Array[RID] = []


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _quad == null:
		_quad = PlaneMesh.new()
		_quad.size = Vector2.ONE
	mesh = _quad
	material_override = MATERIAL
	# never land on the body we belong to
	var p := get_parent()
	while p:
		if p is CollisionObject3D:
			_exclude.append((p as CollisionObject3D).get_rid())
			break
		p = p.get_parent()
	visible = false


func _physics_process(_delta: float) -> void:
	var target := get_parent() as Node3D
	if target == null or not target.is_inside_tree() or not is_inside_tree():
		return
	var feet := target.global_position
	var from := feet + Vector3.UP * 0.25
	var q := PhysicsRayQueryParameters3D.create(from, feet + Vector3.DOWN * fade_height * 2.0, collision_mask, _exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		visible = false
		return
	visible = true
	var pos: Vector3 = hit["position"]
	var n: Vector3 = hit["normal"]
	var h := clampf((feet.y - pos.y) / fade_height, 0.0, 1.0)
	var size := radius * 2.0 * lerpf(1.0, 0.55, h)
	var basis := Basis.IDENTITY
	if n.dot(Vector3.UP) < 0.999:
		basis = Basis(Quaternion(Vector3.UP, n.normalized()))
	global_transform = Transform3D(basis.scaled(Vector3(size, 1.0, size)), pos + n * 0.015)
	set_instance_shader_parameter(&"strength", lerpf(near_strength, far_strength, h))
