class_name NameTag
extends Node3D
## Floating name tag: the player's name over their head plus a dot in their colour.
## Self-contained: instance `res://ui/round/name_tag.tscn` anywhere (usually as a child of
## the Player) and call `setup(player)`. It follows the player every frame (top_level),
## billboards to the camera, hides while the player is eliminated and fades with distance
## from the active camera. Owner: round UI.

## Metres above the player's origin (the blob is 1.0 m tall).
@export var height: float = 1.55
## Fully visible up to this camera distance, invisible beyond `fade_end`.
@export var fade_start: float = 16.0
@export var fade_end: float = 26.0

var player: Player = null
## Current opacity 0..1 (distance fade). Read by tests.
var alpha: float = 1.0

@onready var _name: Label3D = $Name
@onready var _dot: MeshInstance3D = $Dot
var _dot_material: StandardMaterial3D


func _ready() -> void:
	top_level = true
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


func _process(_delta: float) -> void:
	if not is_instance_valid(player):
		visible = false
		return
	visible = player.alive
	global_position = player.global_position + Vector3.UP * height
	var cam := get_viewport().get_camera_3d()
	var a := 1.0
	if cam:
		a = 1.0 - smoothstep(fade_start, fade_end, cam.global_position.distance_to(global_position))
	_set_alpha(a)


func _apply() -> void:
	if not is_instance_valid(player):
		return
	var color := _player_color()
	_name.text = player.display_name if player.display_name != "" else RoundStyle.player_name(player.slot)
	_name.outline_modulate = RoundStyle.CHARCOAL
	_name.modulate = RoundStyle.CREAM
	_dot_material.albedo_color = color
	_set_alpha(alpha)
	global_position = player.global_position + Vector3.UP * height


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
