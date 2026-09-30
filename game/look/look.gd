class_name Look
extends RefCounted
## Shared look helpers: palette, quality switch and the toon treatment for models.
## Owner: look and effects. Static only; never instanced.
##
##   Look.apply_toon($Model)              # soft-ramp toon + rim + outline on every surface
##   Look.toon_material(Look.RED)         # a fresh toon material for code-built props
##   Look.set_quality(Look.Quality.LOW)   # drops SSAO, glow, fog and outlines everywhere
##
## How the toon keeps albedo: every surface keeps a StandardMaterial3D (a duplicate of its
## own material, same resource_name, same albedo), only its shading switches to Godot's
## toon diffuse (a smoothstep ramp whose width is the roughness), toon specular and rim.
## So another system can still set `albedo_color` on the active material, or duplicate it
## and recolour the copy: the look survives (the copy keeps the outline next_pass too).
## Only a brand-new material loses it; call apply_toon again after that, it is idempotent
## and cheap.

enum Quality { LOW, HIGH }

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


## Current quality. The first call reads `--quality=low|high` from the user args.
static func get_quality() -> Quality:
	if not _quality_from_args:
		_quality_from_args = true
		for arg in OS.get_cmdline_user_args():
			if arg == "--quality=low":
				quality = Quality.LOW
			elif arg == "--quality=high":
				quality = Quality.HIGH
	return quality


static func is_high() -> bool:
	return get_quality() == Quality.HIGH


## Switches quality at runtime: every StageLook re-applies (SSAO, glow, fog, shadows) and
## every toon material gains or drops its outline pass.
static func set_quality(q: Quality) -> void:
	_quality_from_args = true
	quality = q
	var high := q == Quality.HIGH
	# copies other systems made of toon materials share the outline material: collapse it
	outline_material().set_shader_parameter(&"enabled", high)
	var kept: Array[WeakRef] = []
	for ref in _outlined:
		var m := ref.get_ref() as BaseMaterial3D
		if m:
			_set_outline(m, high)
			kept.append(ref)
	_outlined = kept
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for n in tree.get_nodes_in_group(STAGE_GROUP):
		if n.has_method(&"apply"):
			n.call(&"apply")


## Gives every MeshInstance3D under `root` (root included) the house toon look while keeping
## each surface's albedo colour, texture and name. Unshaded and shader materials are left
## alone. `outline` adds the inverted-hull outline pass (next_pass; HIGH quality only).
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
	var m := base.duplicate() as BaseMaterial3D
	m.resource_name = base.resource_name
	_configure(m, outline)
	return m


## A fresh toon material in `color` for props built in code.
static func toon_material(color: Color, roughness: float = 0.6, outline: bool = true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	_configure(m, outline)
	return m


## The shared outline pass material.
static func outline_material() -> ShaderMaterial:
	if _outline == null:
		_outline = OUTLINE_MATERIAL
		_outline.set_shader_parameter(&"enabled", is_high())
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
		_set_outline(m, is_high())
		if _outlined.size() > 1024:
			_outlined = _outlined.filter(func(r: WeakRef) -> bool: return r.get_ref() != null)
		_outlined.append(weakref(m))
