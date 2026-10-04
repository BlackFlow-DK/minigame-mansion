class_name HideRoom
extends Node3D
## Hide and Sneak: the parlour, built in code on every peer. The shell (floor, walls, decor,
## lights, the seekers' closet behind the back wall) is fixed and built at once; the furniture
## comes from `HideLayout.generate(seed)` when the host's seed arrives (`build_furniture`).
## Furniture is drawn with one MultiMesh per kind (prop-heavy room: draw calls stay flat), the
## same merged, toon-shaded mesh a disguised hider wears (`kind_mesh`), so a disguise and the
## real thing look exactly alike. Colliders: one StaticBody3D (world layer) for everything.

const ENV_DIR := "res://assets/models/env/"
const WALL_H := 3.2

## Every peer: the furniture as built ({kind, pos, yaw}), index = furniture id.
var furniture: Array[Dictionary] = []
## The seed the furniture was built from (-1 = none yet).
var layout_seed: int = -1

static var _kind_meshes: Dictionary = {}  # kind -> Mesh (merged, toon, outline-prepared)

var _body: StaticBody3D = null
var _furniture_body: StaticBody3D = null
var _multis: Array[MultiMeshInstance3D] = []
var _slot_of: Array[Vector2i] = []        # furniture id -> (kind, instance index)
var _base_xform: Array[Transform3D] = []  # furniture id -> resting transform
var _jiggle: Dictionary = {}              # furniture id -> seconds since the jiggle started
var _lamps: Array[OmniLight3D] = []


func _ready() -> void:
	add_to_group(Look.QUALITY_GROUP)
	_build_shell()
	apply_quality()


## The merged furniture mesh of `kind`: every mesh of the kit model baked into one ArrayMesh
## (node transforms and the kind's scale applied), toon materials on its surfaces, prepared for
## the outline pass. Cached for the app's lifetime; shared by the furniture and the disguises.
static func kind_mesh(kind: int) -> Mesh:
	if _kind_meshes.has(kind):
		return _kind_meshes[kind]
	var info: Dictionary = HideLayout.KINDS[kind]
	var scene := load(String(info["path"])) as PackedScene
	var out := ArrayMesh.new()
	if scene == null:
		push_error("hide_and_sneak: missing prop %s" % info["path"])
		_kind_meshes[kind] = out
		return out
	var root := scene.instantiate() as Node3D
	var scale := Transform3D.IDENTITY.scaled(Vector3.ONE * float(info["scale"]))
	var meshes: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.push_front(root)
	for n in meshes:
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var q: Node = mi
		while q != null and q != root:
			if q is Node3D:
				xf = (q as Node3D).transform * xf
			q = q.get_parent()
		xf = scale * xf
		var nb := xf.basis.inverse().transposed()
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i in verts.size():
				verts[i] = xf * verts[i]
			arrays[Mesh.ARRAY_VERTEX] = verts
			if arrays[Mesh.ARRAY_NORMAL] != null:
				var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				for i in nrm.size():
					nrm[i] = (nb * nrm[i]).normalized()
				arrays[Mesh.ARRAY_NORMAL] = nrm
			if arrays[Mesh.ARRAY_TANGENT] != null:
				var tan: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
				for i in range(0, tan.size() - 3, 4):
					var t := (xf.basis * Vector3(tan[i], tan[i + 1], tan[i + 2])).normalized()
					tan[i] = t.x
					tan[i + 1] = t.y
					tan[i + 2] = t.z
				arrays[Mesh.ARRAY_TANGENT] = tan
			var prim := Mesh.PRIMITIVE_TRIANGLES
			if mi.mesh is ArrayMesh:
				prim = (mi.mesh as ArrayMesh).surface_get_primitive_type(s)
			out.add_surface_from_arrays(prim, arrays)
			var idx := out.get_surface_count() - 1
			out.surface_set_material(idx, Look.toon_from(mi.get_active_material(s), true))
	root.free()
	out.resource_name = String(info["id"])
	# Bake the outline normals (Look's inverted-hull pass) once, on a throwaway instance.
	var tmp := MeshInstance3D.new()
	tmp.mesh = out
	Look.prepare_outline(tmp)
	var baked := tmp.mesh
	tmp.free()
	_kind_meshes[kind] = baked
	return baked


## Every peer: (re)builds the furniture for `seed`. Same seed, same room.
func build_furniture(seed_value: int) -> void:
	if seed_value == layout_seed:
		return
	layout_seed = seed_value
	furniture = HideLayout.generate(seed_value)
	for m in _multis:
		m.queue_free()
	_multis.clear()
	if _furniture_body:
		_furniture_body.queue_free()
	_furniture_body = StaticBody3D.new()
	_furniture_body.name = "FurnitureBody"
	_furniture_body.collision_mask = 0
	add_child(_furniture_body)
	_slot_of.clear()
	_base_xform.clear()
	_jiggle.clear()
	var per_kind: Array[Array] = []
	for k in HideLayout.kind_count():
		per_kind.append([])
	for i in furniture.size():
		var f := furniture[i]
		var kind := int(f["kind"])
		var xf := Transform3D(Basis(Vector3.UP, float(f["yaw"])), f["pos"] as Vector3)
		_slot_of.append(Vector2i(kind, per_kind[kind].size()))
		per_kind[kind].append(xf)
		_base_xform.append(xf)
		_add_collider(kind, xf)
	for k in HideLayout.kind_count():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = kind_mesh(k)
		mm.instance_count = per_kind[k].size()
		for i in per_kind[k].size():
			mm.set_instance_transform(i, per_kind[k][i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Furniture_%s" % HideLayout.KINDS[k]["id"]
		mmi.multimesh = mm
		add_child(mmi)
		_multis.append(mmi)


func _add_collider(kind: int, xf: Transform3D) -> void:
	var info: Dictionary = HideLayout.KINDS[kind]
	var size: Vector3 = info["size"]
	var cs := CollisionShape3D.new()
	if String(info["shape"]) == "cyl":
		var cyl := CylinderShape3D.new()
		cyl.radius = size.x
		cyl.height = size.y
		cs.shape = cyl
	else:
		var box := BoxShape3D.new()
		box.size = size
		cs.shape = box
	cs.transform = xf * Transform3D(Basis.IDENTITY, Vector3(0.0, size.y * 0.5, 0.0))
	_furniture_body.add_child(cs)


## Every peer: furniture `id` wobbles for a moment (a seeker poked it, nothing inside).
func jiggle(id: int) -> void:
	if id >= 0 and id < _base_xform.size():
		_jiggle[id] = 0.0


func is_jiggling(id: int) -> bool:
	return _jiggle.has(id)


func _process(delta: float) -> void:
	if _jiggle.is_empty():
		return
	for id: int in _jiggle.keys():
		var t: float = _jiggle[id] + delta
		var sk := _slot_of[id]
		var mm := _multis[sk.x].multimesh if sk.x < _multis.size() else null
		if t >= 0.6:
			_jiggle.erase(id)
			if mm:
				mm.set_instance_transform(sk.y, _base_xform[id])
			continue
		_jiggle[id] = t
		var k := (1.0 - t / 0.6)
		var tilt := sin(t * 38.0) * 0.12 * k
		var squash := 1.0 + sin(t * 30.0) * 0.08 * k
		var b := Basis(Vector3.RIGHT, tilt).scaled(Vector3(1.0 / sqrt(squash), squash, 1.0 / sqrt(squash)))
		if mm:
			var base := _base_xform[id]
			mm.set_instance_transform(sk.y, Transform3D(base.basis * b, base.origin))


## Look quality switch: LOW keeps two lamps, unshadowed.
func apply_quality() -> void:
	var low := Look.is_low()
	for i in _lamps.size():
		_lamps[i].visible = not low or i < 2
		_lamps[i].shadow_enabled = false


# --- Shell ---------------------------------------------------------------------------------------

func _build_shell() -> void:
	_body = StaticBody3D.new()
	_body.name = "RoomBody"
	_body.collision_mask = 0
	add_child(_body)
	var hx := HideLayout.HALF_X
	var bz := HideLayout.BACK_Z
	var fz := HideLayout.FRONT_Z
	# Floor: 5 x 4 parquet tiles, plus one in the closet behind the door.
	for ix in 5:
		for iz in 4:
			_place("floor_tile_4x4", Vector3(-8.0 + 4.0 * ix, 0.0, -6.0 + 4.0 * iz), 0.0)
	_place("floor_tile_4x4", Vector3(0.0, 0.0, -10.0), 0.0)
	_box(Vector3(0.0, -0.25, 0.0), Vector3(2.0 * hx + 0.6, 0.5, fz - bz + 0.6))
	_box(Vector3(0.0, -0.25, -10.0), Vector3(4.0, 0.5, 4.0))
	var surround := MeshInstance3D.new()
	surround.name = "Surround"
	var plane := PlaneMesh.new()
	plane.size = Vector2(90.0, 90.0)
	surround.mesh = plane
	surround.material_override = Look.toon_material(Color("#1b1424"), 0.9, false)
	surround.position = Vector3(0.0, -0.2, 0.0)
	add_child(surround)
	# A rug in the middle (where the hiders start).
	_place("rug_long", HideLayout.CLEAR_CENTER + Vector3(0.0, 0.01, 0.0), 90.0)

	# Walls: back (the closet door in the middle), both sides; the front is open.
	var back: Array[String] = ["wall_window", "wall_4m", "wall_door", "wall_4m", "wall_window"]
	for i in back.size():
		_place(back[i], Vector3(-8.0 + 4.0 * i, 0.0, bz), 0.0)
	var side: Array[String] = ["wall_4m", "wall_window", "wall_4m", "wall_window"]
	for i in side.size():
		var z := -6.0 + 4.0 * i
		_place(side[i], Vector3(-hx, 0.0, z), 90.0)
		_place(side[3 - i], Vector3(hx, 0.0, z), -90.0)
	for sx: float in [-1.0, 1.0]:
		_place("wall_corner", Vector3(sx * hx, 0.0, bz), 0.0)
		_place("wall_corner", Vector3(sx * hx, 0.0, fz), 0.0)
	var plinth := MeshInstance3D.new()
	plinth.name = "FrontPlinth"
	var pm := BoxMesh.new()
	pm.size = Vector3(2.0 * hx, 0.3, 0.3)
	plinth.mesh = pm
	plinth.material_override = Look.toon_material(Look.DARK_WOOD, 0.7)
	plinth.position = Vector3(0.0, 0.15, fz)
	add_child(plinth)
	_box(Vector3(0.0, WALL_H * 0.5, bz), Vector3(2.0 * hx + 0.6, WALL_H, 0.3))
	_box(Vector3(0.0, WALL_H * 0.5, fz), Vector3(2.0 * hx + 0.6, WALL_H, 0.3))
	for sx: float in [-1.0, 1.0]:
		_box(Vector3(sx * hx, WALL_H * 0.5, 0.0), Vector3(0.3, WALL_H, fz - bz + 0.6))
	# The closet: a 4 x 3 m box behind the door (colliders only; the wall hides it).
	_box(Vector3(0.0, WALL_H * 0.5, -11.6), Vector3(4.6, WALL_H, 0.3))
	for sx: float in [-1.0, 1.0]:
		_box(Vector3(sx * 2.15, WALL_H * 0.5, -9.9), Vector3(0.3, WALL_H, 3.6))

	# Decor (fixed): fireplace, piano, bookshelves along the walls, two sofas framing the rug.
	for d: Array in HideLayout.DECOR:
		var path: String = d[0]
		_place(path.get_file().get_basename(), d[1], d[2])
		var rect: Array = d[3]
		if not rect.is_empty():
			var size := Vector3(float(rect[2]) - float(rect[0]), 1.2, float(rect[3]) - float(rect[1]))
			var tall := 2.6 if path.contains("bookshelf") or path.contains("fireplace") else 1.2
			size.y = tall
			_box(Vector3((float(rect[0]) + float(rect[2])) * 0.5, tall * 0.5, (float(rect[1]) + float(rect[3])) * 0.5), size)
	for z: float in [-1.6, 6.0]:
		_place("portrait_frame_a" if z < 0.0 else "portrait_frame_c", Vector3(-hx + 0.17, 2.4, z), 90.0)
	for z: float in [-5.0, 6.0]:
		_place("portrait_frame_b", Vector3(hx - 0.17, 2.4, z), -90.0)
	for x: float in [-6.3, -3.7]:
		_place("candelabra", Vector3(x, 1.25, -7.2), 0.0).scale = Vector3.ONE * 0.5

	# Warm lamps: the fire, and two chandeliers' worth of light from above the back half.
	var lights := Node3D.new()
	lights.name = "Lights"
	add_child(lights)
	var lamp_spots: Array[Vector3] = [Vector3(-5.0, 1.2, -6.4), Vector3(4.5, 5.2, -2.0), Vector3(-4.5, 5.2, 2.5), Vector3(4.0, 5.2, 4.5)]
	var lamp_colors: Array[Color] = [Color(1.0, 0.6, 0.3), Color(1.0, 0.8, 0.55), Color(1.0, 0.8, 0.55), Color(1.0, 0.82, 0.6)]
	for i in lamp_spots.size():
		var lamp := OmniLight3D.new()
		lamp.light_color = lamp_colors[i]
		lamp.light_energy = 2.2 if i == 0 else 1.6
		lamp.omni_range = 7.0 if i == 0 else 11.0
		lamp.position = lamp_spots[i]
		lights.add_child(lamp)
		_lamps.append(lamp)
	for x: float in [-5.0, 5.0]:
		var ch := _place("chandelier", Vector3(x, 6.6, -4.2), 0.0)
		for n: Node in ch.find_children("*", "GeometryInstance3D", true, false):
			(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _place(piece: String, pos: Vector3, yaw_deg: float) -> Node3D:
	var scene := load(ENV_DIR + piece + ".glb") as PackedScene
	if scene == null:
		push_error("hide_and_sneak: missing kit piece %s" % piece)
		return Node3D.new()
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation_degrees.y = yaw_deg
	add_child(n)
	Look.apply_toon(n)
	return n


func _box(center: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = center
	_body.add_child(cs)
