class_name BlobRig
extends RefCounted
## Handles on the parts of one `blob.glb` instance and their rest positions.
## The model is a flat list of separate objects under its root (docs/contract.md
## "Character model and cosmetics"); every part rests at identity rotation and scale.
## Artist's rig notes: lids pivot at the eye centre, `rotation.x` 0 = open (hidden),
## 1.2 = half, 2.0 = shut; the mouth rests half-open (scale y 1), 0.15 = closed, 1.8 = shout;
## pupils may slide at most +-0.02 m in x/y; L is +X.

const SCENE: PackedScene = preload("res://assets/models/character/blob.glb")
## Low-poly twin (art/scripts/character/blob_lod.py): same parts, origins and material slots,
## ~40 % of the triangles. Crowd extras and far blobs swap to it below HIGH (VisualsComponent).
const LOD_PATH := "res://assets/models/character/blob_lod.glb"
const PARTS: Array[StringName] = [
	&"Body", &"EyeL", &"EyeR", &"PupilL", &"PupilR", &"LidL", &"LidR", &"Mouth",
	&"CheekL", &"CheekR", &"HandL", &"HandR", &"FootL", &"FootR",
]
## Parts lying on the body's surface (they cast no sun shadow of their own).
const FACE_PARTS: Array[StringName] = [
	&"EyeL", &"EyeR", &"PupilL", &"PupilR", &"LidL", &"LidR", &"Mouth", &"CheekL", &"CheekR",
]
const SOCKETS: Array[StringName] =[&"HatSocket", &"FaceSocket", &"NeckSocket", &"BackSocket"]

const LID_OPEN := 0.0
const LID_HALF := 1.2
const LID_SHUT := 2.0
const MOUTH_CLOSED := 0.15
const MOUTH_SHOUT := 1.8
const PUPIL_RANGE := 0.02

var root: Node3D
var body: Node3D
var pupil_l: Node3D
var pupil_r: Node3D
var lid_l: Node3D
var lid_r: Node3D
var mouth: Node3D
var cheek_l: Node3D
var cheek_r: Node3D
var hand_l: Node3D
var hand_r: Node3D
var foot_l: Node3D
var foot_r: Node3D
## Part name -> rest position (model-root space).
var rest: Dictionary[StringName, Vector3] = {}
## Midpoint of the two eye centres at rest (model-root space).
var eye_centre: Vector3 = Vector3(0.0, 0.665, 0.3)

## Part name -> LOD mesh (outline-prepared, surface materials = blob.glb's), built once.
static var _lod_meshes: Dictionary = {}
static var _lod_loaded: bool = false


## The low-poly mesh of `part` (null when blob_lod.glb is missing or has no such part). Its
## surfaces carry the very materials of blob.glb's part, in the same order, so a swapped-in LOD
## keeps the toon look, the cosmetics tint (surface overrides by index) and the outline.
static func lod_mesh(part: StringName) -> Mesh:
	if not _lod_loaded:
		_lod_loaded = true
		_load_lods()
	return _lod_meshes.get(part)


static func _load_lods() -> void:
	if not ResourceLoader.exists(LOD_PATH):
		return
	var lod_scene := load(LOD_PATH) as PackedScene
	if lod_scene == null:
		return
	var lod_root := lod_scene.instantiate() as Node3D
	var full_root := SCENE.instantiate() as Node3D
	for part in PARTS:
		var lod_mi := lod_root.get_node_or_null(NodePath(String(part))) as MeshInstance3D
		var full_mi := full_root.get_node_or_null(NodePath(String(part))) as MeshInstance3D
		if lod_mi == null or full_mi == null or lod_mi.mesh == null or full_mi.mesh == null:
			continue
		var full := full_mi.mesh
		var lod := lod_mi.mesh.duplicate() as Mesh
		if lod.get_surface_count() != full.get_surface_count():
			push_warning("BlobRig: blob_lod.glb part %s has %d surfaces, blob.glb %d: no LOD" % [part, lod.get_surface_count(), full.get_surface_count()])
			continue
		var same := true
		for s in full.get_surface_count():
			var fm := full.surface_get_material(s)
			var lm := lod.surface_get_material(s)
			if fm == null or lm == null or fm.resource_name != lm.resource_name:
				same = false
				break
			lod.surface_set_material(s, fm)
		if not same:
			push_warning("BlobRig: blob_lod.glb part %s: material slots differ from blob.glb: no LOD" % part)
			continue
		var tmp := MeshInstance3D.new()
		tmp.mesh = lod
		Look.prepare_outline(tmp)  # smoothed normals for the outline pass (MEDIUM)
		_lod_meshes[part] = tmp.mesh
		tmp.free()
	lod_root.free()
	full_root.free()


## Instances the model. Returns null (and reports) if the scene is broken.
static func instantiate() -> BlobRig:
	var model := SCENE.instantiate() as Node3D
	if model == null:
		push_error("BlobRig: blob.glb did not instance as a Node3D")
		return null
	return BlobRig.new(model)


func _init(model_root: Node3D) -> void:
	root = model_root
	for n in PARTS:
		var node := root.get_node_or_null(NodePath(String(n))) as Node3D
		if node:
			rest[n] = node.position
	body = _part(&"Body")
	pupil_l = _part(&"PupilL")
	pupil_r = _part(&"PupilR")
	lid_l = _part(&"LidL")
	lid_r = _part(&"LidR")
	mouth = _part(&"Mouth")
	cheek_l = _part(&"CheekL")
	cheek_r = _part(&"CheekR")
	hand_l = _part(&"HandL")
	hand_r = _part(&"HandR")
	foot_l = _part(&"FootL")
	foot_r = _part(&"FootR")
	if rest.has(&"EyeL") and rest.has(&"EyeR"):
		eye_centre = (rest[&"EyeL"] + rest[&"EyeR"]) * 0.5


## True when every contract part and socket is present.
func is_complete() -> bool:
	for n in PARTS:
		if root.get_node_or_null(NodePath(String(n))) == null:
			return false
	for s in SOCKETS:
		if root.get_node_or_null(NodePath(String(s))) == null:
			return false
	return true


func rest_of(part: StringName) -> Vector3:
	return rest.get(part, Vector3.ZERO)


func _part(n: StringName) -> Node3D:
	var node := root.get_node_or_null(NodePath(String(n))) as Node3D
	if node == null:
		push_error("BlobRig: blob.glb has no part '%s'" % n)
	return node
