class_name StaticMerge
extends RefCounted
## Merges the static scenery under a node into one mesh per material, so a hall built from 30
## floor tiles and 20 wall pieces draws a handful of meshes instead of hundreds (every surface
## of every MeshInstance3D is a draw in the depth pre-pass, the colour pass, each shadow split
## and, MEDIUM/HIGH, the outline pass). Owner: look and effects. Static only.
##
##   StaticMerge.merge(hall)                      # everything static under `hall`
##   StaticMerge.merge(course, [moving], 24.0)    # skip `moving`; 24 m cells keep culling
##
## What is merged: visible MeshInstance3D surfaces (triangles, no skin, no blend shapes) whose
## material is a plain opaque BaseMaterial3D (no normal map, no billboard, no local triplanar).
## A mesh instance is merged whole or not at all; ShaderMaterial, transparent or
## `visibility_range` surfaces, nodes under `skip` and nodes with the meta `no_merge` stay as
## they are. Merged sources keep their node (children, scripts and references stay valid) but
## lose their mesh (`mesh = null`, meta `static_merged`). Materials are kept by object, so the
## toon look, the live outline switch (`Look.set_quality`) and shared emissive copies still
## work; the per-vertex outline data (CUSTOM0 from `Look.prepare_outline`) is carried over and
## rotated with each piece, so outlines look the same.
## Group key: material, shadow casting, render layers and (when `cell` > 0) the grid cell of
## the piece's centre, so a long course keeps frustum culling per cell.
## Call it after the scenery is final (materials swapped, toon applied) and never on things
## that move, animate or get re-tinted per instance.

const MERGED_META := &"static_merged"
const SKIP_META := &"no_merge"

## Prints why each mesh instance was left out (tuning).
static var debug: bool = false


## Merges what it can under `root` (the merged meshes become children of `root`, in its local
## space). Returns {"sources": instances merged, "surfaces": surfaces merged, "meshes": new
## mesh instances}.
static func merge(root: Node3D, skip: Array = [], cell: float = 0.0, node_name: String = "Merged") -> Dictionary:
	var stats := {"sources": 0, "surfaces": 0, "meshes": 0}
	if root == null:
		return stats
	var groups: Dictionary = {}  # key -> {"material", "shadow", "layers", "parts": [[mesh, surface, xform]]}
	var order: Array = []
	var merged_sources: Array[MeshInstance3D] = []
	var canon: Dictionary = {}
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var xform: Variant = _local_xform(root, mi, skip)
		if xform == null or not _mergeable(mi):
			continue
		var centre: Vector3 = (xform as Transform3D) * mi.mesh.get_aabb().get_center()
		var cell_key := Vector3i((centre / cell).floor()) if cell > 0.0 else Vector3i.ZERO
		for s in mi.mesh.get_surface_count():
			var mat := _canonical(mi.get_active_material(s), canon)
			var key := [mat, mi.cast_shadow, mi.layers, cell_key]
			if not groups.has(key):
				groups[key] = {"material": mat, "shadow": mi.cast_shadow, "layers": mi.layers, "parts": []}
				order.append(key)
			(groups[key]["parts"] as Array).append([mi.mesh, s, xform])
			stats["surfaces"] += 1
		merged_sources.append(mi)
	if merged_sources.is_empty():
		return stats
	var i := 0
	for key: Variant in order:
		var g: Dictionary = groups[key]
		var mesh := _build(g["parts"])
		if mesh == null:
			continue
		mesh.surface_set_material(0, g["material"])
		var out := MeshInstance3D.new()
		out.name = "%s%d" % [node_name, i]
		out.mesh = mesh
		out.cast_shadow = g["shadow"]
		out.layers = g["layers"]
		root.add_child(out)
		i += 1
	stats["meshes"] = i
	for mi in merged_sources:
		mi.mesh = null
		mi.set_meta(MERGED_META, true)
	stats["sources"] = merged_sources.size()
	return stats


## Repeated static pieces under `root` (the same mesh with the same materials, at least
## `min_count` times) become one MultiMeshInstance3D per mesh: one draw per surface for all of
## them, wherever they stand (a long course seen in parts keeps its draw count low, where a
## merge per cell would not). Same skip rules as merge(); sources lose their mesh the same way.
## The MultiMesh mesh is a copy whose surfaces carry the active (toon) materials.
## Returns {"sources", "multimeshes"}.
static func batch(root: Node3D, skip: Array = [], min_count: int = 3, node_name: String = "Batch") -> Dictionary:
	var stats := {"sources": 0, "multimeshes": 0}
	if root == null:
		return stats
	var groups: Dictionary = {}  # key -> [[mi, xform]]
	var order: Array = []
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var xform: Variant = _local_xform(root, mi, skip)
		if xform == null or not _mergeable(mi):
			continue
		var key: Array = [mi.mesh, mi.cast_shadow, mi.layers]
		for s in mi.mesh.get_surface_count():
			key.append(mi.get_active_material(s))
		if not groups.has(key):
			groups[key] = []
			order.append(key)
		(groups[key] as Array).append([mi, xform])
	var i := 0
	for key: Array in order:
		var items: Array = groups[key]
		if items.size() < min_count:
			continue
		var src_mi := items[0][0] as MeshInstance3D
		var mesh := _with_materials(src_mi)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = items.size()
		for k in items.size():
			mm.set_instance_transform(k, items[k][1])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s%d" % [node_name, i]
		mmi.multimesh = mm
		mmi.cast_shadow = src_mi.cast_shadow
		mmi.layers = src_mi.layers
		root.add_child(mmi)
		for it: Array in items:
			var mi := it[0] as MeshInstance3D
			mi.mesh = null
			mi.set_meta(MERGED_META, true)
		stats["sources"] += items.size()
		i += 1
	stats["multimeshes"] = i
	return stats


## A copy of `mi`'s mesh whose surfaces carry its active materials (MultiMesh has no per-surface
## overrides). Keeps the outline data and its meta.
static func _with_materials(mi: MeshInstance3D) -> Mesh:
	var src := mi.mesh
	var same := true
	for s in src.get_surface_count():
		if mi.get_active_material(s) != src.surface_get_material(s):
			same = false
	if same:
		return src
	var copy := src.duplicate() as Mesh
	if copy is ArrayMesh:
		for s in copy.get_surface_count():
			(copy as ArrayMesh).surface_set_material(s, mi.get_active_material(s))
	elif copy is PrimitiveMesh:
		(copy as PrimitiveMesh).material = mi.get_active_material(0)
	return copy


## One material object per look: every kit model imports its own copy of "Wood", "Brass"...
## Two materials with the same name and every stored property equal (textures and next_pass
## by object) are the same look, so the first one seen stands for both. Different names stay
## apart (a script may animate one of them, e.g. the lobby's EmitFire).
static func _canonical(mat: Material, canon: Dictionary) -> Material:
	if mat == null:
		return mat
	var key: Array = [mat.get_class()]
	for p: Dictionary in mat.get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_STORAGE and p["name"] != "resource_path" and p["name"] != "resource_scene_unique_id":
			key.append(mat.get(p["name"]))
	if mat.has_meta(Look.TOON_META):
		key.append(true)
	var got: Material = canon.get(key)
	if got == null:
		canon[key] = mat
		return mat
	return got


## The transform of `mi` in `root`'s space, or null when `mi` is hidden or under a `skip` node
## (walks the parents, so it works before `root` enters the tree).
static func _local_xform(root: Node3D, mi: MeshInstance3D, skip: Array) -> Variant:
	var xf := Transform3D.IDENTITY
	var n: Node = mi
	while n != root:
		if n == null or skip.has(n) or n.has_meta(SKIP_META):
			return null
		if n is Node3D:
			if not (n as Node3D).visible:
				return null
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


static func _mergeable(mi: MeshInstance3D) -> bool:
	var why := why_not(mi)
	if debug and why != "":
		print("merge: skip %s (%s)" % [mi.get_path() if mi.is_inside_tree() else NodePath(mi.name), why])
	return why == ""


## "" when `mi` can be merged, else the reason.
static func why_not(mi: MeshInstance3D) -> String:
	var mesh := mi.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return "no mesh"
	if not (mesh is ArrayMesh or mesh is PrimitiveMesh):
		return "mesh type"
	if mesh is ArrayMesh and (mesh as ArrayMesh).get_blend_shape_count() > 0:
		return "blend shapes"
	if mi.skin != null or mi.visibility_range_end > 0.0 or mi.transparency > 0.0 or mi.material_overlay != null:
		return "instance settings"
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh:
			var am := mesh as ArrayMesh
			if am.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				return "primitive"
			var fmt: int = am.surface_get_format(s)
			if fmt & (Mesh.ARRAY_FORMAT_BONES | Mesh.ARRAY_FORMAT_WEIGHTS):
				return "skinned"
			var custom0: int = (fmt >> Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) & Mesh.ARRAY_FORMAT_CUSTOM_MASK
			if fmt & Mesh.ARRAY_FORMAT_CUSTOM0 and custom0 != Mesh.ARRAY_CUSTOM_RGBA_FLOAT:
				return "custom0 format"
			if fmt & (Mesh.ARRAY_FORMAT_CUSTOM1 | Mesh.ARRAY_FORMAT_CUSTOM2 | Mesh.ARRAY_FORMAT_CUSTOM3):
				return "custom1-3"
		var mat := mi.get_active_material(s)
		var m := mat as BaseMaterial3D
		if m == null:
			return "material %s" % (mat.get_class() if mat else "null")
		if m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return "transparent %s" % m.resource_name
		if m.normal_enabled or m.heightmap_enabled or m.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED \
				or (m.uv1_triplanar and not m.uv1_world_triplanar) or m.grow or m.use_point_size:
			return "material feature %s" % m.resource_name
	return ""


## One triangle surface from [mesh, surface, xform] parts.
static func _build(parts: Array) -> ArrayMesh:
	var has_color := false
	var has_uv := false
	var has_uv2 := false
	var has_custom := false
	for p: Array in parts:
		var mesh := p[0] as Mesh
		if mesh is ArrayMesh:
			var fmt: int = (mesh as ArrayMesh).surface_get_format(int(p[1]))
			has_color = has_color or bool(fmt & Mesh.ARRAY_FORMAT_COLOR)
			has_uv = has_uv or bool(fmt & Mesh.ARRAY_FORMAT_TEX_UV)
			has_uv2 = has_uv2 or bool(fmt & Mesh.ARRAY_FORMAT_TEX_UV2)
			has_custom = has_custom or bool(fmt & Mesh.ARRAY_FORMAT_CUSTOM0)
		else:
			has_uv = true  # PrimitiveMesh: vertex, normal, tangent, uv
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var custom := PackedFloat32Array()
	var indices := PackedInt32Array()
	for p: Array in parts:
		var arrays := (p[0] as Mesh).surface_get_arrays(int(p[1]))
		var xf: Transform3D = p[2]
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var count := v.size()
		if count == 0:
			continue
		var base := verts.size()
		verts.append_array(xf * v)
		var nb := xf.basis.inverse().transposed()
		var unit := nb.orthonormalized().is_equal_approx(nb)
		var src_n: Variant = arrays[Mesh.ARRAY_NORMAL]
		if src_n != null and (src_n as PackedVector3Array).size() == count:
			var nn: PackedVector3Array = Transform3D(nb, Vector3.ZERO) * (src_n as PackedVector3Array)
			if not unit:
				for k in nn.size():
					nn[k] = nn[k].normalized()
			normals.append_array(nn)
		else:
			var up := PackedVector3Array()
			up.resize(count)
			up.fill(nb * Vector3.UP)
			normals.append_array(up)
		if has_color:
			colors.append_array(_or_fill_colors(arrays[Mesh.ARRAY_COLOR], count))
		if has_uv:
			uvs.append_array(_or_fill_v2(arrays[Mesh.ARRAY_TEX_UV], count))
		if has_uv2:
			uv2s.append_array(_or_fill_v2(arrays[Mesh.ARRAY_TEX_UV2], count))
		if has_custom:
			custom.append_array(_rotated_custom(arrays[Mesh.ARRAY_CUSTOM0], count, nb))
		var flip := xf.basis.determinant() < 0.0
		var src_i: Variant = arrays[Mesh.ARRAY_INDEX]
		var idx := PackedInt32Array()
		if src_i != null and (src_i as PackedInt32Array).size() > 0:
			idx = (src_i as PackedInt32Array).duplicate()
		else:
			idx.resize(count)
			for k in count:
				idx[k] = k
		var t := 0
		while t + 2 < idx.size():
			var a := idx[t] + base
			var b := idx[t + 1] + base
			var c := idx[t + 2] + base
			idx[t] = a
			idx[t + 1] = c if flip else b
			idx[t + 2] = b if flip else c
			t += 3
		indices.append_array(idx)
	if verts.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	if has_color:
		arrays[Mesh.ARRAY_COLOR] = colors
	if has_uv:
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	if has_uv2:
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	var flags := 0
	if has_custom:
		arrays[Mesh.ARRAY_CUSTOM0] = custom
		flags = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	return mesh


static func _or_fill_colors(src: Variant, count: int) -> PackedColorArray:
	if src != null and (src as PackedColorArray).size() == count:
		return src
	var out := PackedColorArray()
	out.resize(count)
	out.fill(Color.WHITE)
	return out


static func _or_fill_v2(src: Variant, count: int) -> PackedVector2Array:
	if src != null and (src as PackedVector2Array).size() == count:
		return src
	var out := PackedVector2Array()
	out.resize(count)
	return out


## Outline data (smoothed normal xyz, weight w) turned with the piece; zeros (no outline)
## where the source had none.
static func _rotated_custom(src: Variant, count: int, nb: Basis) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count * 4)
	if src == null or (src as PackedFloat32Array).size() != count * 4:
		return out
	var c: PackedFloat32Array = src
	for k in count:
		var n := (nb * Vector3(c[k * 4], c[k * 4 + 1], c[k * 4 + 2])).normalized()
		out[k * 4] = n.x
		out[k * 4 + 1] = n.y
		out[k * 4 + 2] = n.z
		out[k * 4 + 3] = c[k * 4 + 3]
	return out
