class_name Look
extends RefCounted
## Shared look helpers: palette, quality switch and the toon treatment for models.
## Owner: look and effects. Static only; never instanced.
##
##   Look.apply_toon($Model)              # soft-ramp toon + rim + outline on every surface
##   Look.toon_material(Look.RED)         # a shared toon material for code-built props
##   Look.set_quality(Look.Quality.LOW)   # LOW / MEDIUM / HIGH, live, everywhere (see below)
##
## Quality levels (docs/performance.md has the measurements behind them):
##   HIGH    as designed: SSAO, glow, fog, soft 2-split sun shadows (4096 atlas), outlines,
##           full resolution, each viewport's own MSAA.
##   MEDIUM  for mid GPUs: glow, fog, 2-split sun shadows (2048 atlas, light blur), outlines,
##           full resolution, MSAA off + FXAA. No SSAO.
##   LOW     for integrated graphics: no SSAO / glow / fog / outlines, one low-res sun
##           shadow split (1024 atlas, light blur), 3D at 0.75 scale (FSR1 upscale) + FXAA, effect pools and
##           particle counts capped (Fx), the lobby keeps only its fire and portal lights.
##   `is_high()` means "not LOW" (the full effect set: feel extras, flash lights, rings).
## Viewports: every StageLook configures the viewport it renders into (`apply_viewport`); a
## viewport may carry the meta `look_scale_factor` (the title's hall) which further scales its
## 3D resolution below HIGH. Nodes in group QUALITY_GROUP get `apply_quality()` called on
## every switch (lobby lights, the Fx pools).
##
## How the toon keeps albedo: every surface keeps a StandardMaterial3D (a copy of its own
## material, same resource_name, same albedo), only its shading switches to Godot's toon
## diffuse (a smoothstep ramp whose width is the roughness), toon specular and rim. To recolour
## one model, duplicate its active material and set the copy (what Cosmetics does): the copy
## keeps the toon and the outline. Only a brand-new material loses it; call apply_toon again
## after that, it is idempotent and cheap.
##
## Sharing: there is ONE toon copy per source material (and one toon_material per colour),
## cached for the session, exactly mirroring how imported materials are already shared by
## every instance of a model. Never mutate a toon material in place; duplicate it first.
## Why cached: a material whose last reference is the MeshInstance3D is freed together with
## the node, and under the headless dummy renderer that logs `material_get_instance_shader_
## parameters: Parameter "material" is null` (the RID goes before its render instance), which
## fails tests. Cached materials outlive the nodes, and 8 players cost no extra materials.

enum Quality { LOW, MEDIUM, HIGH }

# Palette (sRGB), shared with the artists.
const WOOD := Color("#8a5a3c")
const DARK_WOOD := Color("#5b3a29")
const PLUM := Color("#6d4a7c")
const TEAL := Color("#2fa7a0")
const CREAM := Color("#f3e6c8")
const GOLD := Color("#e8b33a")
const RED := Color("#d9483b")
const GREEN := Color("#58b368")
const BLUE := Color("#3f7fd9")
const PINK := Color("#f08fb0")
const CHARCOAL := Color("#2e2a33")
const LAVA := Color("#ff6a1f")

## Marks a material that already has the toon treatment.
const TOON_META := &"look_toon"
## StageLook nodes (re-applied by the quality switch).
const STAGE_GROUP := &"stage_look"
## Any node with an `apply_quality()` method that must follow the quality switch.
const QUALITY_GROUP := &"look_quality"
## Names accepted by `--quality=` and Settings, in Quality order.
const QUALITY_NAMES: Array[String] = ["low", "medium", "high"]
## 3D render scale per quality (before a viewport's `look_scale_factor`); below 1 upscales with FSR1.
const RENDER_SCALE: Array[float] = [0.75, 1.0, 1.0]
## Directional shadow atlas size per quality.
const SHADOW_ATLAS: Array[int] = [1024, 2048, 4096]

const OUTLINE_MATERIAL: ShaderMaterial = preload("res://look/materials/outline.tres")

## Toon ramp softness comes from roughness: keep it in a range that reads as soft vinyl.
const ROUGHNESS_MIN := 0.45
const ROUGHNESS_MAX := 0.85
const RIM := 0.35
const RIM_TINT := 0.45

static var quality: Quality = Quality.HIGH
static var _quality_from_args := false
static var _outline: ShaderMaterial
static var _outlined: Array[WeakRef] = []
## [source mesh, weight] -> outline-ready copy (holds both, so neither is freed while cached).
static var _outline_meshes: Dictionary = {}
## [source material, outline] -> its toon copy; [colour, roughness, outline] -> toon_material.
static var _toon_cache: Dictionary = {}
## Prints one line per prepared mesh (size, fill, open, weight) for tuning the opt-outs.
static var outline_debug: bool = false


## Current quality. The first call reads `--quality=low|medium|high` from the user args.
static func get_quality() -> Quality:
	if not _quality_from_args:
		_quality_from_args = true
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--quality="):
				var q := quality_from_name(arg.trim_prefix("--quality="))
				if q >= 0:
					quality = q as Quality
	return quality


## "low" | "medium" | "high" -> Quality, -1 when unknown.
static func quality_from_name(text: String) -> int:
	return QUALITY_NAMES.find(text.strip_edges().to_lower())


## MEDIUM or HIGH: the full effect set (feel extras, flash lights, rings) and outlines.
static func is_high() -> bool:
	return get_quality() != Quality.LOW


static func is_low() -> bool:
	return get_quality() == Quality.LOW


## Switches quality at runtime: every StageLook re-applies (environment, sun shadows, its
## viewport's resolution and AA), every toon material gains or drops its outline pass and
## every node in QUALITY_GROUP gets `apply_quality()`.
static func set_quality(q: Quality) -> void:
	_quality_from_args = true
	quality = q
	var outlines := q != Quality.LOW
	# copies other systems made of toon materials share the outline material: collapse it
	outline_material().set_shader_parameter(&"enabled", outlines)
	var kept: Array[WeakRef] = []
	for ref in _outlined:
		var m := ref.get_ref() as BaseMaterial3D
		if m:
			_set_outline(m, outlines)
			kept.append(ref)
	_outlined = kept
	apply_shadow_settings()
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for n in tree.get_nodes_in_group(STAGE_GROUP):
		if n.has_method(&"apply"):
			n.call(&"apply")
	for n in tree.get_nodes_in_group(QUALITY_GROUP):
		if n.has_method(&"apply_quality"):
			n.call(&"apply_quality")


## Global shadow budget for the current quality: directional atlas size, soft-shadow filter.
static func apply_shadow_settings() -> void:
	var q := get_quality()
	RenderingServer.directional_shadow_atlas_set_size(SHADOW_ATLAS[q], true)
	# HARD on LOW leaves acne rings on round shapes at 1024 texels: the very-low PCF is cheap
	var filter := RenderingServer.SHADOW_QUALITY_SOFT_LOW
	if q != Quality.HIGH:
		filter = RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW
	RenderingServer.directional_soft_shadow_filter_set_quality(filter)
	RenderingServer.positional_soft_shadow_filter_set_quality(filter)


## 3D resolution and anti-aliasing of `vp` for the current quality. HIGH restores what the
## viewport had before Look first touched it (its own MSAA / screen-space AA) at full scale.
static func apply_viewport(vp: Viewport) -> void:
	if vp == null:
		return
	if not vp.has_meta(&"look_base_msaa"):
		vp.set_meta(&"look_base_msaa", vp.msaa_3d)
		vp.set_meta(&"look_base_ssaa", vp.screen_space_aa)
	var q := get_quality()
	var factor := 1.0
	if q != Quality.HIGH:
		factor = float(vp.get_meta(&"look_scale_factor", 1.0))
	var s := clampf(RENDER_SCALE[q] * factor, 0.25, 1.0)
	vp.scaling_3d_scale = s
	if s < 0.999 and RenderingServer.get_current_rendering_method() != "gl_compatibility":
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR  # FSR needs RenderingDevice
	if q == Quality.HIGH:
		vp.msaa_3d = vp.get_meta(&"look_base_msaa") as Viewport.MSAA
		vp.screen_space_aa = vp.get_meta(&"look_base_ssaa") as Viewport.ScreenSpaceAA
	else:
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA


## Gives every MeshInstance3D under `root` (root included) the house toon look while keeping
## each surface's albedo colour, texture and name. Unshaded and shader materials are left
## alone. `outline` adds the inverted-hull outline pass (next_pass; MEDIUM and HIGH only).
## Returns the number of surfaces changed.
static func apply_toon(root: Node3D, outline: bool = true) -> int:
	if root == null:
		return 0
	var meshes: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		meshes.append(root as MeshInstance3D)
	for n in root.find_children("*", "MeshInstance3D", true, false):
		meshes.append(n as MeshInstance3D)
	var changed := 0
	for mi in meshes:
		if mi.mesh == null:
			continue
		if outline:
			prepare_outline(mi)
		if mi.material_override:
			var m := toon_from(mi.material_override, outline)
			if m != mi.material_override:
				mi.material_override = m
				changed += 1
		else:
			for s in mi.mesh.get_surface_count():
				var src := mi.get_active_material(s)
				var m := toon_from(src, outline)
				if m != src:
					mi.set_surface_override_material(s, m)
					changed += 1
	return changed


## Outline weight of a mesh, from its size in metres (after the node scales above it) and its
## mean thickness 2 * volume / area (a slab gives its thickness, a tube its radius). A hull
## thicker than the part itself swamps it: thin parts (frames, chains, cloth, lids, cheeks),
## tiny parts (pupils, glints) and open sheets get weight 0.
const OUTLINE_MIN_THICKNESS := 0.02
const OUTLINE_MIN_SIZE := 0.07

## Swaps `mi.mesh` for a cached copy that carries, per vertex, the averaged ("smoothed")
## normal of every face meeting at that position in CUSTOM0.xyz and the mesh's outline
## weight in CUSTOM0.w. The outline pushes along that normal, so split normals (hard edges,
## UV seams, surface borders) no longer tear the hull into spikes; weight 0 (thin, tiny,
## open or wiry parts) collapses the hull. Meshes never prepared get no outline at all.
## Keeps surfaces, their materials (by object, so re-tinting by material name still works)
## and names. Idempotent; one copy per source mesh and weight. Returns the weight.
static func prepare_outline(mi: MeshInstance3D) -> float:
	var mesh := mi.mesh
	if mesh == null:
		return 0.0
	if mesh.has_meta(&"look_outline_weight"):
		return mesh.get_meta(&"look_outline_weight")
	if mesh is ArrayMesh and (mesh as ArrayMesh).get_blend_shape_count() > 0:
		return 0.0  # morphing meshes would need the smoothing redone per shape
	var weight := _outline_weight(mi)
	var key := [mesh, weight]
	var baked: ArrayMesh = _outline_meshes.get(key)
	if baked == null:
		baked = _bake_outline_mesh(mesh, weight)
		if baked == null:
			return 0.0
		_outline_meshes[key] = baked
	mi.mesh = baked
	return weight


static func _outline_weight(mi: MeshInstance3D) -> float:
	var mesh := mi.mesh
	var size := mesh.get_aabb().size
	var scale := Vector3.ONE
	var n: Node = mi
	while n is Node3D:
		scale *= (n as Node3D).transform.basis.get_scale()
		n = n.get_parent()
	size *= scale
	var big := maxf(size.x, maxf(size.y, size.z))
	var stats := _mesh_stats(mesh)
	var uniform := pow(absf(scale.x * scale.y * scale.z), 1.0 / 3.0)
	var thickness: float = 2.0 * float(stats["volume"]) / maxf(float(stats["area"]), 1e-9) * uniform
	var open: bool = stats["open"]
	var w := 1.0
	if thickness < OUTLINE_MIN_THICKNESS or big < OUTLINE_MIN_SIZE or open:
		w = 0.0
	if outline_debug:
		print("outline: %-14s size %s thick %.3f open %s -> %.0f" % [mi.name, str(size.snapped(Vector3.ONE * 0.001)), thickness, open, w])
	return w


## Volume (closed meshes), area, and whether the welded surface has border edges.
static func _mesh_stats(mesh: Mesh) -> Dictionary:
	var volume := 0.0
	var area := 0.0
	var edges: Dictionary = {}
	for s in mesh.get_surface_count():
		if _primitive(mesh, s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if idx.size() > 0 else verts.size()
		var keys := PackedInt64Array()
		keys.resize(verts.size())
		for i in verts.size():
			keys[i] = _pos_key(verts[i])
		for t in range(0, count - 2, 3):
			var a := idx[t] if idx.size() > 0 else t
			var b := idx[t + 1] if idx.size() > 0 else t + 1
			var c := idx[t + 2] if idx.size() > 0 else t + 2
			volume += verts[a].dot(verts[b].cross(verts[c])) / 6.0
			area += (verts[b] - verts[a]).cross(verts[c] - verts[a]).length() * 0.5
			for e in [[keys[a], keys[b]], [keys[b], keys[c]], [keys[c], keys[a]]]:
				var lo: int = mini(e[0], e[1])
				var hi: int = maxi(e[0], e[1])
				if lo == hi:
					continue
				var ek := [lo, hi]
				edges[ek] = int(edges.get(ek, 0)) + 1
	var border := 0
	for k in edges:
		if int(edges[k]) == 1:
			border += 1
	# a few stray border edges (tiny holes, pinched poles) do not make a sheet
	return {"volume": absf(volume), "area": area, "open": border > maxi(8, edges.size() / 50)}


static func _primitive(mesh: Mesh, s: int) -> Mesh.PrimitiveType:
	if mesh is ArrayMesh:
		return (mesh as ArrayMesh).surface_get_primitive_type(s)
	return Mesh.PRIMITIVE_TRIANGLES  # PrimitiveMesh and friends


static func _pos_key(v: Vector3) -> int:
	var q := Vector3i((v * 5000.0).round())
	return ((q.x & 0x1fffff) << 42) | ((q.y & 0x1fffff) << 21) | (q.z & 0x1fffff)


static func _bake_outline_mesh(mesh: Mesh, weight: float) -> ArrayMesh:
	# angle-weighted normal sums per welded position, across every surface
	var sums: Dictionary = {}
	var surfaces: Array = []
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		surfaces.append(arrays)
		if _primitive(mesh, s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if idx.size() > 0 else verts.size()
		for t in range(0, count - 2, 3):
			var ids := PackedInt32Array([t, t + 1, t + 2])
			if idx.size() > 0:
				ids = PackedInt32Array([idx[t], idx[t + 1], idx[t + 2]])
			var p0 := verts[ids[0]]
			var p1 := verts[ids[1]]
			var p2 := verts[ids[2]]
			var fn := (p2 - p0).cross(p1 - p0)  # Godot winds front faces clockwise
			if fn.length_squared() < 1e-20:
				continue
			fn = fn.normalized()
			var corners := [[p0, p1, p2], [p1, p2, p0], [p2, p0, p1]]
			for c in 3:
				var e1: Vector3 = corners[c][1] - corners[c][0]
				var e2: Vector3 = corners[c][2] - corners[c][0]
				var angle := e1.angle_to(e2)
				var k := _pos_key(verts[ids[c]])
				sums[k] = (sums.get(k, Vector3.ZERO) as Vector3) + fn * angle
	var out := ArrayMesh.new()
	var flags := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	for s in mesh.get_surface_count():
		var arrays: Array = surfaces[s]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
		var custom := PackedFloat32Array()
		custom.resize(verts.size() * 4)
		for i in verts.size():
			var sn: Vector3 = sums.get(_pos_key(verts[i]), Vector3.ZERO)
			if sn.length_squared() < 1e-12:
				sn = (normals as PackedVector3Array)[i] if normals != null else Vector3.UP
			sn = sn.normalized()
			custom[i * 4] = sn.x
			custom[i * 4 + 1] = sn.y
			custom[i * 4 + 2] = sn.z
			custom[i * 4 + 3] = weight
		arrays[Mesh.ARRAY_CUSTOM0] = custom
		out.add_surface_from_arrays(_primitive(mesh, s), arrays, [], {}, flags)
		out.surface_set_material(s, mesh.surface_get_material(s))
		if mesh is ArrayMesh:
			out.surface_set_name(s, (mesh as ArrayMesh).surface_get_name(s))
	out.resource_name = mesh.resource_name
	out.set_meta(&"look_outline_weight", weight)
	return out


## The toon version of `src`: `src` itself when it already is toon or should not be touched
## (unshaded, ShaderMaterial), else a configured duplicate. null gives a white toon material.
static func toon_from(src: Material, outline: bool = true) -> Material:
	if src == null:
		return toon_material(Color.WHITE, 0.6, outline)
	if src.has_meta(TOON_META):
		return src
	var base := src as BaseMaterial3D
	if base == null or base.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
		return src
	var key := [src, outline]
	var m: BaseMaterial3D = _toon_cache.get(key)
	if m == null:
		m = base.duplicate() as BaseMaterial3D
		m.resource_name = base.resource_name
		_configure(m, outline)
		_toon_cache[key] = m
	return m


## The shared toon material in `color` for props built in code (do not mutate it; duplicate).
static func toon_material(color: Color, roughness: float = 0.6, outline: bool = true) -> StandardMaterial3D:
	var key := [color, roughness, outline]
	var m: StandardMaterial3D = _toon_cache.get(key)
	if m == null:
		m = StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = roughness
		_configure(m, outline)
		_toon_cache[key] = m
	return m


## The shared outline pass material.
static func outline_material() -> ShaderMaterial:
	if _outline == null:
		_outline = OUTLINE_MATERIAL
		_outline.set_shader_parameter(&"enabled", get_quality() != Quality.LOW)
	return _outline


## Parses a loadout colour ("#rrggbb" or a Color); `fallback` when missing or bad.
static func parse_color(value: Variant, fallback: Color = Color.WHITE) -> Color:
	if value is Color:
		return value
	if value is String or value is StringName:
		return Color.from_string(str(value), fallback)
	return fallback


## Adds or removes the outline pass without clobbering someone else's next_pass.
static func _set_outline(m: BaseMaterial3D, on: bool) -> void:
	var ours := outline_material()
	if on and m.next_pass == null:
		m.next_pass = ours
	elif not on and m.next_pass == ours:
		m.next_pass = null


static func _configure(m: BaseMaterial3D, outline: bool) -> void:
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_TOON
	m.roughness = clampf(m.roughness, ROUGHNESS_MIN, ROUGHNESS_MAX)
	m.metallic = minf(m.metallic, 0.3)
	m.metallic_specular = 0.35
	m.rim_enabled = true
	m.rim = RIM
	m.rim_tint = RIM_TINT
	m.set_meta(TOON_META, true)
	if outline:
		_set_outline(m, get_quality() != Quality.LOW)
		if _outlined.size() > 1024:
			_outlined = _outlined.filter(func(r: WeakRef) -> bool: return r.get_ref() != null)
		_outlined.append(weakref(m))
