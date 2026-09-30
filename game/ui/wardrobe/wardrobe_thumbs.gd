class_name WardrobeThumbs
extends Node
## Renders one small picture per catalog item for the wardrobe tiles. Owner: wardrobe UI.
##
## One studio per item slot (its own SubViewport + World3D: transparent background, a neutral
## blob, soft key/fill light, a camera), so the four slots render in parallel, one item per
## frame each. Face, neck and back items are shown on the neutral blob (a monocle alone is just a
## ring, a cape alone is a red rag); hats are shown on their own. Every item is framed to fill the picture.
## Pictures are cached for the whole session (static), so reopening the wardrobe is instant.
## Headless (tests, no GPU) the studios still stage every item but cannot read pixels back:
## such items get a blank placeholder that is not cached.

signal thumb_ready(slot: StringName, id: String, texture: Texture2D)
signal all_ready

const THUMB_PX := 192
const FOV := 22.0
## Neutral blob colours for the pictures (items never use the player colours).
const STUDIO_LOADOUT := {"primary": "#cfc6dc", "secondary": "#f7f1e6", "hat": "", "face": "", "neck": "", "back": ""}
## Per slot: camera direction (from the subject towards the camera), whether the blob shows,
## and the part of the blob that must stay in the picture (blob space).
const STUDIO := {
	&"hat": {"dir": Vector3(0.45, 0.55, 1.0), "blob": false},
	&"face": {"dir": Vector3(0.32, 0.12, 1.0), "blob": true, "region": AABB(Vector3(-0.4, 0.4, 0.05), Vector3(0.8, 0.62, 0.35))},
	&"neck": {"dir": Vector3(0.35, 0.45, 1.0), "blob": true, "region": AABB(Vector3(-0.42, 0.12, -0.1), Vector3(0.84, 0.62, 0.5))},
	&"back": {"dir": Vector3(-0.4, 0.35, -1.0), "blob": true, "region": AABB(Vector3(-0.3, 0.2, -0.42), Vector3(0.6, 0.7, 0.3))},
}

## "slot:id" -> Texture2D, shared by every wardrobe opened this session.
static var _cache: Dictionary = {}
static var _placeholder: ImageTexture

## "slot:id" -> true once the item was put in its studio without trouble (tests read it).
var staged: Dictionary = {}
var _textures: Dictionary = {}
var _pending: int = 0
var _running: bool = false


## True when this renderer can read pixels back (not headless).
static func can_capture() -> bool:
	return DisplayServer.get_name() != "headless"


static func key_of(slot: StringName, id: String) -> String:
	return "%s:%s" % [slot, id]


## Drops every cached picture (tests; after the item models changed).
static func clear_cache() -> void:
	_cache.clear()


static func placeholder() -> Texture2D:
	if _placeholder == null:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		_placeholder = ImageTexture.create_from_image(img)
	return _placeholder


## The picture of an item, or null while it is still rendering. "" (None) never has one.
func get_texture(slot: StringName, id: String) -> Texture2D:
	var key := key_of(slot, id)
	if _textures.has(key):
		return _textures[key]
	return _cache.get(key)


func is_done() -> bool:
	return _running == false and _pending == 0


## Starts rendering every item that has no cached picture. Emits thumb_ready per item and
## all_ready at the end (also right away when everything was cached).
func render_all() -> void:
	if _running:
		return
	_running = true
	_pending = 0
	var todo: Dictionary = {}
	for slot: StringName in Cosmetics.SLOTS:
		var ids: Array[String] = []
		for entry: Dictionary in Cosmetics.catalog(slot):
			var id: String = entry["id"]
			if id == "":
				continue
			var key := key_of(slot, id)
			if _cache.has(key):
				staged[key] = true
				_textures[key] = _cache[key]
			else:
				ids.append(id)
		if not ids.is_empty():
			todo[slot] = ids
	_running = false
	if todo.is_empty():
		all_ready.emit.call_deferred()
		return
	_pending = todo.size()
	for slot: StringName in todo:
		_render_slot(slot, todo[slot])


func _render_slot(slot: StringName, ids: Array[String]) -> void:
	var studio := _build_studio(slot)
	add_child(studio.viewport)
	for id in ids:
		if not is_inside_tree():
			return
		var tex: Texture2D = await _shoot(studio, slot, id)
		# The wardrobe may have been freed while this frame was pending (closed early, or
		# force-closed when a round starts): stop quietly.
		if not is_instance_valid(self) or not is_inside_tree():
			return
		var key := key_of(slot, id)
		_textures[key] = tex
		if tex != placeholder():
			_cache[key] = tex
		thumb_ready.emit(slot, id, tex)
	studio.viewport.queue_free()
	_pending -= 1
	if _pending == 0:
		all_ready.emit()


func _shoot(studio: Dictionary, slot: StringName, id: String) -> Texture2D:
	var blob: Node3D = studio.blob
	var vp: SubViewport = studio.viewport
	var loadout := STUDIO_LOADOUT.duplicate()
	loadout[String(slot)] = id
	Cosmetics.apply(blob, loadout)
	WardrobePreview.toon(blob)
	var item := Cosmetics.get_item_node(blob, slot)
	if item != null:
		staged[key_of(slot, id)] = true
		_frame(studio, slot, item)
	if not can_capture():
		await get_tree().process_frame
		return placeholder()
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	if not is_instance_valid(self) or not is_instance_valid(vp) or not vp.is_inside_tree():
		return placeholder()
	var img := vp.get_texture().get_image()
	if img == null or img.is_empty():
		return placeholder()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Points the studio camera at `item` (plus the slot's blob region when the blob shows).
func _frame(studio: Dictionary, slot: StringName, item: Node3D) -> void:
	var cfg: Dictionary = STUDIO[slot]
	var blob: Node3D = studio.blob
	var box := _bounds(item, blob.global_transform.affine_inverse())
	if cfg.get("blob", false):
		box = box.merge(cfg["region"])
	var cam: Camera3D = studio.camera
	var fwd := -(cfg["dir"] as Vector3).normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var up := right.cross(fwd).normalized()
	var centre := blob.global_transform * box.get_center()
	var tan_half := tan(deg_to_rad(FOV) * 0.5)
	var dist := 0.0
	for i in 8:
		var p := blob.global_transform * box.get_endpoint(i) - centre
		var lateral := maxf(absf(p.dot(right)), absf(p.dot(up)))
		dist = maxf(dist, lateral / tan_half - p.dot(fwd))
	dist = dist * 1.08 + 0.05
	cam.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), centre - fwd * dist)
	cam.near = maxf(0.01, dist * 0.2)
	cam.far = dist * 4.0 + 2.0
	# The body only shows for face, neck and back items.
	for part: Node in blob.get_children():
		if part is MeshInstance3D:
			(part as MeshInstance3D).visible = cfg.get("blob", false)


## AABB of every mesh under `root`, in the space `to_space` maps global coordinates into.
func _bounds(root: Node3D, to_space: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	var meshes: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.append(root)
	for n in meshes:
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var box := (to_space * mi.global_transform) * mi.mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false
	if first:
		out = AABB(Vector3(-0.2, -0.2, -0.2), Vector3(0.4, 0.4, 0.4))
	return out


func _build_studio(slot: StringName) -> Dictionary:
	var vp := SubViewport.new()
	vp.name = "Studio_%s" % slot
	vp.size = Vector2i(THUMB_PX, THUMB_PX)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.93, 0.86, 0.95)
	env.ambient_light_energy = 0.65
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	var cam := Camera3D.new()
	cam.fov = FOV
	cam.current = true
	vp.add_child(cam)
	# Lights ride on the camera, so every slot is lit the same way whatever the view.
	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.9, 0.78)
	key.light_energy = 1.45
	key.rotation_degrees = Vector3(-38.0, -28.0, 0.0)
	cam.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.7, 0.62, 0.95)
	fill.light_energy = 0.55
	fill.light_specular = 0.2
	fill.rotation_degrees = Vector3(-15.0, 150.0, 0.0)
	cam.add_child(fill)

	var blob := BlobRig.SCENE.instantiate() as Node3D
	blob.name = "Blob"
	vp.add_child(blob)
	Cosmetics.apply(blob, STUDIO_LOADOUT)
	WardrobePreview.toon(blob)
	return {"viewport": vp, "camera": cam, "blob": blob}
