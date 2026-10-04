class_name MenuBackdrop
extends Control
## Background of the title, join and settings screens: the lit mansion hall (the lobby scene,
## built once in its own SubViewport world) with a few blobs idling on it and a camera drifting
## slowly across it, under a vignette and a soft plum wash so the logo and panels read.
## Headless (tests) or without the lobby scene it falls back to the painted 2D backdrop: plum
## with soft diagonal stripes and slowly drifting confetti dots.
## While hidden the 3D view stops rendering and processing.
## Startup: building the hall costs ~0.5 s, so it waits until the backdrop has been shown for two
## drawn frames (the window opens on the title over a flat plum backdrop at once) and then fades
## in over FADE_IN. A run that goes straight into a game (the backdrop never shown) never builds
## it. The empty SubViewport exists from `_ready` on, so MenuRoot can tune its scale.

const LOBBY_PATH := "res://lobby/lobby.tscn"
const BLOB_PATH := "res://assets/models/character/blob.glb"
const DOT_COUNT := 38
const DOT_COLOURS: Array[Color] = [MenuUI.TEAL, MenuUI.GOLD, MenuUI.RED, MenuUI.CREAM]
## Idle blobs: position on the hall floor / stairs, yaw (radians), default-loadout slot.
const BLOBS: Array[Array] = [
	[Vector3(-2.7, 0.0, 4.4), 0.45, 0], [Vector3(-1.0, 0.0, 5.1), 0.1, 1], [Vector3(0.6, 0.0, 4.3), -0.35, 4],
	[Vector3(-0.9, 2.0, -7.0), 0.0, 3], [Vector3(0.9, 2.0, -7.1), 0.0, 2],
]
## Camera drift: a slow sway across the open front of the hall.
const CAM_BASE := Vector3(0.0, 7.0, 12.5)
const CAM_LOOK := Vector3(0.0, -0.2, -2.5)
const CAM_SWAY := Vector3(4.0, 0.25, 1.0)
const CAM_PERIOD := 46.0
## Seconds the hall takes to fade in over the flat backdrop once built.
const FADE_IN := 0.6
## The flat backdrop shown until the hall is built (close to the hall under the wash).
const FLAT_COLOUR := Color("#3b2a40")

## True when the 3D mansion view is in use (false headless / fallback / not built yet).
var is_3d: bool = false
## True from `_ready` until the 3D hall is built (it will be, the first time the backdrop shows).
var pending_3d: bool = false

var _building: bool = false

var _dots: Array[Dictionary] = []
var _t: float = 0.0
var _viewport: SubViewport
var _view: TextureRect
var _world: Node3D
var _camera: Camera3D
var _blobs: Array[Node3D] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in DOT_COUNT:
		_dots.append({
			"pos": Vector2(rng.randf(), rng.randf()),
			"r": rng.randf_range(6.0, 26.0),
			"speed": rng.randf_range(0.004, 0.018),
			"phase": rng.randf() * TAU,
			"colour": DOT_COLOURS[i % DOT_COLOURS.size()],
		})
	if DisplayServer.get_name() != "headless" and ResourceLoader.exists(LOBBY_PATH):
		_make_view()
		pending_3d = true
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


## The (still empty, not rendering) SubViewport, the TextureRect showing it (transparent until
## the hall fades in) and the wash and vignette over it.
func _make_view() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "MansionView"
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.audio_listener_enable_3d = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_view = TextureRect.new()
	_view.name = "View"
	MenuUI.full_rect(_view)
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_view.texture = _viewport.get_texture()
	_view.modulate.a = 0.0
	add_child(_view)
	add_child(_shade(_wash_texture()))
	add_child(_shade(_vignette_texture()))
	get_viewport().size_changed.connect(_fit_viewport)
	_fit_viewport()


## After two drawn frames of the flat backdrop: builds the hall, then fades it in.
func _build_later() -> void:
	_building = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	_building = false
	if not is_inside_tree() or not pending_3d:
		return
	if not is_visible_in_tree():
		return  # left the title within two frames (straight into a game): build when shown again
	_build_3d()
	pending_3d = false
	queue_redraw()
	_on_visibility_changed()
	if is_3d:
		create_tween().tween_property(_view, ^"modulate:a", 1.0, FADE_IN)


func _build_3d() -> void:
	var ps := load(LOBBY_PATH) as PackedScene
	if ps == null:
		return
	_world = ps.instantiate() as Node3D
	# The hall's own gameplay camera would fight ours.
	var cam := _world.get_node_or_null(^"Camera")
	if cam:
		_world.remove_child(cam)
		cam.free()
	_viewport.add_child(_world)
	_camera = Camera3D.new()
	_camera.fov = 40.0
	_camera.current = true
	_viewport.add_child(_camera)
	_add_blobs()
	is_3d = true
	_drift(_t)


func _add_blobs() -> void:
	var blob_scene := load(BLOB_PATH) as PackedScene if ResourceLoader.exists(BLOB_PATH) else null
	if blob_scene == null:
		return
	for b: Array in BLOBS:
		var holder := Node3D.new()
		holder.position = b[0]
		holder.rotation.y = b[1]
		_world.add_child(holder)
		var model := blob_scene.instantiate() as Node3D
		holder.add_child(model)
		Look.apply_toon(model)
		Cosmetics.apply(model, Cosmetics.default_loadout(int(b[2])))
		_blobs.append(holder)


## A full-rect overlay showing `tex` stretched.
func _shade(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	MenuUI.full_rect(r)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.texture = tex
	return r


## Plum on the left (behind the logo), clear in the middle, a little on the right (the panel).
func _wash_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 0.62, 1.0])
	g.colors = PackedColorArray([Color(MenuUI.PLUM.darkened(0.35), 0.72), Color(MenuUI.PLUM.darkened(0.35), 0.25),
		Color(MenuUI.PLUM.darkened(0.35), 0.1), Color(MenuUI.CHARCOAL, 0.45)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 256
	t.height = 4
	return t


func _vignette_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	g.colors = PackedColorArray([Color(MenuUI.CHARCOAL, 0.0), Color(MenuUI.CHARCOAL, 0.12), Color(MenuUI.CHARCOAL, 0.8)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.08, 1.08)
	t.width = 256
	t.height = 256
	return t


func _fit_viewport() -> void:
	if _viewport == null:
		return
	var px := get_window().size if get_window() else Vector2i(1280, 720)
	_viewport.size = Vector2i(maxi(px.x, 320), maxi(px.y, 180))


func _on_visibility_changed() -> void:
	var on := is_visible_in_tree()
	if on and pending_3d and not _building:
		_build_later()
	if _viewport and is_3d:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
		_world.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	set_process(on)


func _process(delta: float) -> void:
	_t += delta
	if is_3d:
		_drift(_t)
	elif not pending_3d:
		queue_redraw()


## Camera sway and idle blob bob at time `t` (calmer under reduced motion).
func _drift(t: float) -> void:
	var k := 0.35 if UiMotion.reduced_motion() else 1.0
	var a := TAU * t / CAM_PERIOD
	var pos := CAM_BASE + Vector3(sin(a) * CAM_SWAY.x * k, sin(a * 2.0) * CAM_SWAY.y * k, cos(a) * CAM_SWAY.z * k)
	_camera.position = pos
	_camera.look_at(CAM_LOOK + Vector3(sin(a) * 1.2 * k, 0, 0), Vector3.UP)
	for i in _blobs.size():
		var b := _blobs[i]
		var model := b.get_child(0) as Node3D
		if model:
			var ph := t * 2.2 + i * 1.9
			model.position.y = absf(sin(ph)) * 0.12 * k
			model.scale = Vector3(1.0 + 0.04 * cos(ph * 2.0) * k, 1.0 - 0.04 * cos(ph * 2.0) * k, 1.0 + 0.04 * cos(ph * 2.0) * k)


func _draw() -> void:
	var s := size
	if pending_3d or is_3d:
		draw_rect(Rect2(Vector2.ZERO, s), FLAT_COLOUR)  # under the hall while it fades in
		return
	draw_rect(Rect2(Vector2.ZERO, s), MenuUI.PLUM)
	var stripe := Color(MenuUI.CHARCOAL, 0.09)
	var w := 70.0
	var x := -s.y
	while x < s.x:
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, s.y), Vector2(x + w, s.y), Vector2(x + w + s.y, 0), Vector2(x + s.y, 0)]), stripe)
		x += w * 2.0
	for d in _dots:
		var p: Vector2 = d["pos"]
		var yy := fposmod(p.y - _t * float(d["speed"]), 1.0)
		var xx := p.x + sin(_t * 0.6 + float(d["phase"])) * 0.01
		var c: Color = d["colour"]
		var r: float = d["r"]
		var at := Vector2(xx * s.x, yy * (s.y + 60.0) - 30.0)
		draw_circle(at, r + 3.0, Color(MenuUI.CHARCOAL, 0.25))
		draw_circle(at, r, Color(c, 0.55))
	# Darken the bottom edge a little so panels pop.
	var shade := PackedColorArray([Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(MenuUI.CHARCOAL, 0.45), Color(MenuUI.CHARCOAL, 0.45)])
	draw_polygon(PackedVector2Array([Vector2(0, s.y * 0.6), Vector2(s.x, s.y * 0.6), Vector2(s.x, s.y), Vector2(0, s.y)]), shade)
