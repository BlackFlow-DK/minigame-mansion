class_name BlobToon
extends RefCounted
## The house toon look (Look.toon_from) for a blob model and whatever it wears, with one shared
## toon material per source material instead of a fresh copy per player.
##
## Why shared: every blob wearing the same colour/item shows the same material anyway, and a
## per-instance material that dies together with its MeshInstance3D makes Godot's headless
## (dummy) renderer print `Parameter "material" is null` when the player is freed. Cached
## materials outlive the nodes, so that never happens, and 8 players cost no extra materials.
## Materials are never mutated here or afterwards; a new look means a new cached entry.
##
## Callers: the visuals component when it instances the blob, and the cosmetics component after
## every `Cosmetics.apply` (which swaps in plain tinted materials and plain item meshes).

## Source material -> its toon version (holds both, so neither is freed while cached).
static var _cache: Dictionary = {}


## Gives every MeshInstance3D under `root` (root included) the toon look, reusing cached
## toon materials. Idempotent: surfaces that are already toon are left alone.
## Returns the number of surfaces changed.
static func apply(root: Node3D, outline: bool = true) -> int:
	if root == null:
		return 0
	var meshes: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.append(root)
	var changed := 0
	for node in meshes:
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		if outline:
			Look.prepare_outline(mi)  # smoothed-normal copy of the mesh (cached per source mesh)
		if mi.material_override:
			var m := toon_of(mi.material_override, outline)
			if m != mi.material_override:
				mi.material_override = m
				changed += 1
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s)
			if src == null:
				continue
			var m := toon_of(src, outline)
			if m != src:
				mi.set_surface_override_material(s, m)
				changed += 1
	return changed


## The shared toon version of `src` (`src` itself if it already is toon or must stay as is).
static func toon_of(src: Material, outline: bool = true) -> Material:
	if src.has_meta(Look.TOON_META):
		return src
	var key := [src, outline]
	var cached: Material = _cache.get(key)
	if cached == null:
		cached = Look.toon_from(src, outline)
		_cache[key] = cached
	return cached
