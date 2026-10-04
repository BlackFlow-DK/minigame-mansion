class_name NameTag
extends Node3D
## Floating name tag: the player's name over their head plus a dot in their colour.
## Self-contained: instance `res://ui/round/name_tag.tscn` anywhere (usually as a child of
## the Player) and call `setup(player)`. It follows the player every frame (top_level),
## billboards to the camera, hides while the player is eliminated and fades with distance
## from the active camera. Owner: round UI.
## Crowds: once per frame all tags are laid out together on screen; a tag whose name would
## overlap one already placed (the local player's first, then nearest to the camera) steps up
## by a line, at most MAX_STEPS times, and if it still overlaps it dims to CROWD_ALPHA.
## Minigames hide a player's tag with `suppressed` (disguises, prop hunts); find the tag with
## `NameTag.of(player)` rather than by node name.

## Metres above the player's origin (the blob is 1.0 m tall).
@export var height: float = 1.55
## Fully visible up to this camera distance, invisible beyond `fade_end`.
@export var fade_start: float = 28.0
@export var fade_end: float = 40.0

## Crowd layout: lines a tag may step up, and the opacity of one that still overlaps.
const MAX_STEPS := 2
const CROWD_ALPHA := 0.45
## Screen-space gap kept between two names, in pixels.
const CROWD_PAD := 6.0

var player: Player = null
## NPC extras (`Player.is_extra`) get no tag unless this is set before setup (Stage sets it
## for `Stage.extra_name_tags`).
var show_extras: bool = false
## Current opacity 0..1 (distance fade). Read by tests.
var alpha: float = 1.0
## Metres this tag is lifted above `height` to clear a crowd (smoothed). Read by tests.
var lift: float = 0.0
## 1, or CROWD_ALPHA while it overlaps another name even after stepping up.
var crowd_alpha: float = 1.0
## Extra metres above `height` for something carried over the head (a bomb, a royal crown),
## set by a minigame on every peer; 0 = none. Unlike `height` the size component leaves it alone.
var raise: float = 0.0
## Hidden on purpose by a minigame (this peer only; set it on every peer). Shows again when cleared.
var suppressed: bool = false:
	set(value):
		suppressed = value
		if value:
			visible = false
		elif is_instance_valid(player):
			visible = player.alive and (show_extras or not player.is_extra)

static var _tags: Array[WeakRef] = []
static var _layout_frame: int = -1
var _lift_target: float = 0.0

@onready var _name: Label3D = $Name
@onready var _dot: MeshInstance3D = $Dot
var _dot_material: StandardMaterial3D
## Name and colour last shown: re-applied when the player's roster entry changes (lobby
## rename / wardrobe recolour reach Player.display_name / loadout through the Stage).
var _shown_name: String = ""
var _shown_primary: Variant = null


func _ready() -> void:
	top_level = true
	_tags.append(weakref(self))
	_dot_material = StandardMaterial3D.new()
	_dot_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dot_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_dot_material.no_depth_test = true
	_dot_material.render_priority = 10
	_dot.material_override = _dot_material
	var font := RoundStyle.get_theme().default_font
	if font:
		_name.font = font
	_apply()


## Binds the tag to `p`: name and colour from the player (roster colour as fallback).
func setup(p: Player) -> void:
	player = p
	if is_node_ready():
		_apply()


## The NameTag shown over `p` (a child of it), or null.
static func of(p: Player) -> NameTag:
	if p == null or not is_instance_valid(p):
		return null
	for child in p.get_children():
		if child is NameTag:
			return child as NameTag
	return null


func _process(delta: float) -> void:
	if not is_instance_valid(player) or (player.is_extra and not show_extras) or suppressed:
		visible = false
		return
	visible = player.alive
	if player.display_name != _shown_name or player.loadout.get("primary", "") != _shown_primary:
		_apply()
	var cam := get_viewport().get_camera_3d()
	if Engine.get_process_frames() != _layout_frame:
		_layout_frame = Engine.get_process_frames()
		_layout_crowd(cam)
	lift = lerpf(lift, _lift_target, 1.0 - exp(-14.0 * delta))
	global_position = player.global_position + Vector3.UP * (height + raise + lift)
	var a := 1.0
	if cam:
		a = 1.0 - smoothstep(fade_start, fade_end, cam.global_position.distance_to(global_position))
	_set_alpha(a * crowd_alpha)


## Screen rect (pixels) of this tag's name at `extra_lift` metres up, or an empty Rect2 when
## it is not on screen.
func screen_rect(cam: Camera3D, extra_lift: float = 0.0) -> Rect2:
	if cam == null or not is_instance_valid(player) or not _name:
		return Rect2()
	var anchor := player.global_position + Vector3.UP * (height + raise + extra_lift) + _name.position
	if cam.is_position_behind(anchor):
		return Rect2()
	var c := cam.unproject_position(anchor)
	var px_per_m := c.distance_to(cam.unproject_position(anchor + cam.global_basis.y))
	var font := _name.font if _name.font else ThemeDB.fallback_font
	var outline_m := float(_name.outline_size) * _name.pixel_size
	var w_m := font.get_string_size(_name.text, HORIZONTAL_ALIGNMENT_LEFT, -1, _name.font_size).x * _name.pixel_size + outline_m
	var h_m := float(_name.font_size) * _name.pixel_size
	var sz := Vector2(w_m, h_m) * px_per_m
	return Rect2(c - sz * 0.5, sz)


## Lays out every live tag on screen once per frame (see the header).
static func _layout_crowd(cam: Camera3D) -> void:
	var live: Array[NameTag] = []
	var kept: Array[WeakRef] = []
	for ref in _tags:
		var t := ref.get_ref() as NameTag
		if t == null or not t.is_inside_tree():
			continue
		kept.append(ref)
		t._lift_target = 0.0
		t.crowd_alpha = 1.0
		if is_instance_valid(t.player) and t.player.alive and t.is_visible_in_tree() and t.alpha > 0.01:
			live.append(t)
	_tags = kept
	if cam == null or live.size() < 2:
		return
	var local := Net.local_slot()
	live.sort_custom(func(a: NameTag, b: NameTag) -> bool:
		if (a.player.slot == local) != (b.player.slot == local):
			return a.player.slot == local
		return cam.global_position.distance_squared_to(a.player.global_position) < cam.global_position.distance_squared_to(b.player.global_position))
	var placed: Array[Rect2] = []
	for t in live:
		var r := t.screen_rect(cam)
		if r.size == Vector2.ZERO:
			continue
		var step_m := float(t._name.font_size) * t._name.pixel_size * 0.92
		var lift_m := 0.0
		var steps := 0
		while _overlaps(r, placed) and steps < MAX_STEPS:
			steps += 1
			lift_m = step_m * steps
			r = t.screen_rect(cam, lift_m)
		if _overlaps(r, placed):
			lift_m = 0.0
			r = t.screen_rect(cam)
			t.crowd_alpha = CROWD_ALPHA
		else:
			placed.append(r)
		t._lift_target = lift_m


static func _overlaps(r: Rect2, placed: Array[Rect2]) -> bool:
	var grown := r.grow(CROWD_PAD * 0.5)
	for p in placed:
		if grown.intersects(p.grow(CROWD_PAD * 0.5)):
			return true
	return false


func _apply() -> void:
	if not is_instance_valid(player):
		return
	_shown_name = player.display_name
	_shown_primary = player.loadout.get("primary", "")
	var color := _player_color()
	_name.text = player.display_name if player.display_name != "" else RoundStyle.player_name(player.slot)
	_name.outline_modulate = RoundStyle.CHARCOAL
	_name.modulate = RoundStyle.CREAM
	_dot_material.albedo_color = color
	_set_alpha(alpha)
	global_position = player.global_position + Vector3.UP * (height + raise)


func _player_color() -> Color:
	var hex: Variant = player.loadout.get("primary", "")
	if hex is String and Color.html_is_valid(hex):
		return Color.html(hex)
	return RoundStyle.player_color(player.slot)


func _set_alpha(a: float) -> void:
	alpha = clampf(a, 0.0, 1.0)
	_name.modulate.a = alpha
	_name.outline_modulate.a = alpha
	_dot_material.albedo_color.a = alpha
	_name.visible = alpha > 0.01
	_dot.visible = alpha > 0.01
