extends Node3D
## Hot Potato presentation: the lit bomb floating over the holder, on every peer.
## Pure presentation: the minigame tells it who holds the bomb (`show_on`) and how urgent
## it is (`set_level`, a coarse 0..3 step, never the real fuse time). It follows the holder
## each frame; the bomb throbs on every tick, the ticks and the throb speed up and the
## glow gets redder with the level; the spark flickers; a gold arrow and a glowing ring on
## the floor mark the holder; `bomb_fuse_loop` follows the holder and `bomb_tick` ticks.

const BOMB_SCENE: PackedScene = preload("res://assets/models/props/bomb.glb")
const ARROW_SCENE: PackedScene = preload("res://assets/models/props/arrow_marker.glb")

## The bomb model is 0.45 m across; this makes it about as wide as a blob.
const BOMB_SCALE := 2.0
## Bomb centre above the holder's origin: above hats (~1.35 m) and the name tag (1.55 m).
const BOMB_HEIGHT := 2.25
const ARROW_HEIGHT := 3.1
## Seconds between ticks per urgency level.
const TICK_INTERVAL: Array[float] = [0.85, 0.5, 0.28, 0.14]
## Glow strength per urgency level.
const HEAT: Array[float] = [0.35, 0.6, 0.85, 1.0]
## Render layer of the bomb meshes (the holder light's cull mask leaves it out).
const BOMB_LAYER := 1 << 10
const GLOW_COLOR := Color(2.2, 0.35, 0.08)
const RING_COLOR := Color(2.6, 0.7, 0.15)

## The player the bomb follows (null = hidden).
var target: Player = null
## Urgency 0..3.
var level: int = 0

var _bomb: Node3D
var _spark: Node3D
var _arrow: Node3D
var _glow_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _light: OmniLight3D
var _loop_id: int = -1
var _tick_left: float = 0.0
var _throb: float = 0.0
var _time: float = 0.0


func _ready() -> void:
	top_level = true
	_bomb = BOMB_SCENE.instantiate() as Node3D
	_bomb.name = "Bomb"
	_bomb.position.y = BOMB_HEIGHT
	_bomb.scale = Vector3.ONE * BOMB_SCALE
	add_child(_bomb)
	Look.apply_toon(_bomb)
	# The bomb stays black: it sits on its own render layer that the holder light skips.
	for mi in _bomb.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).layers = BOMB_LAYER
	_spark = _bomb.find_child("EmitSpark", true, false) as Node3D

	var glow := MeshInstance3D.new()
	glow.name = "Glow"
	var sphere := SphereMesh.new()
	sphere.radius = 0.225 * 1.5
	sphere.height = 0.45 * 1.5
	sphere.radial_segments = 20
	sphere.rings = 10
	glow.mesh = sphere
	_glow_mat = _additive(GLOW_COLOR)
	glow.material_override = _glow_mat
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bomb.add_child(glow)

	_arrow = ARROW_SCENE.instantiate() as Node3D
	_arrow.name = "Arrow"
	_arrow.position.y = ARROW_HEIGHT
	_arrow.scale = Vector3.ONE * 1.4
	add_child(_arrow)
	Look.apply_toon(_arrow)

	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.6
	torus.outer_radius = 0.85
	torus.rings = 40
	torus.ring_segments = 8
	_ring.mesh = torus
	_ring.scale = Vector3(1.0, 0.25, 1.0)
	_ring.position.y = 0.05
	_ring_mat = _additive(RING_COLOR)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)

	_light = OmniLight3D.new()
	_light.name = "Light"
	_light.position.y = 1.1
	_light.light_cull_mask = 0xFFFFF & ~BOMB_LAYER
	_light.light_color = Color(1.0, 0.45, 0.18)
	_light.omni_range = 4.0
	_light.shadow_enabled = false
	add_child(_light)

	visible = false


func _exit_tree() -> void:
	_stop_loop()


## Puts the bomb on `p` at urgency `lvl`.
func show_on(p: Player, lvl: int) -> void:
	target = p
	set_level(lvl)
	_throb = 1.0
	_tick_left = TICK_INTERVAL[level]
	_follow()
	visible = p != null
	if p and _loop_id < 0:
		_loop_id = Sfx.play_loop(&"bomb_fuse_loop", global_position + Vector3.UP * BOMB_HEIGHT)


func set_level(lvl: int) -> void:
	level = clampi(lvl, 0, TICK_INTERVAL.size() - 1)
	_tick_left = minf(_tick_left, TICK_INTERVAL[level])


## Hides the bomb (it exploded or its holder left).
func hide_bomb() -> void:
	target = null
	visible = false
	_stop_loop()


## World position of the bomb itself.
func bomb_position() -> Vector3:
	return _bomb.global_position if _bomb else global_position


func _process(delta: float) -> void:
	if target == null:
		return
	if not is_instance_valid(target) or not target.alive:
		hide_bomb()
		return
	_time += delta
	_follow()
	var at := bomb_position()
	if _loop_id >= 0:
		Sfx.move_loop(_loop_id, at)
	_tick_left -= delta
	if _tick_left <= 0.0:
		_tick_left += TICK_INTERVAL[level]
		_throb = 1.0
		Sfx.play(&"bomb_tick", at)
	_throb = maxf(_throb - delta * 7.0, 0.0)

	var heat := HEAT[level]
	var wobble := sin(_time * TAU * (1.2 + level * 0.8))
	_bomb.scale = Vector3.ONE * BOMB_SCALE * (1.0 + 0.14 * _throb * (0.6 + heat * 0.4) + 0.025 * wobble)
	_bomb.rotation = Vector3(0.12 * sin(_time * 3.1), _time * 1.4, 0.12 * cos(_time * 2.3))
	var c := GLOW_COLOR
	c.a = heat * (0.08 + 0.4 * _throb)
	_glow_mat.albedo_color = c
	if _spark:
		_spark.scale = Vector3.ONE * randf_range(0.6, 1.5)
		_spark.rotation.y += delta * 14.0
	_arrow.position.y = ARROW_HEIGHT + 0.12 * sin(_time * 4.0)
	_arrow.rotation.y = _time * 2.0
	var rc := RING_COLOR
	rc.a = 0.75 + 0.25 * _throb
	_ring_mat.albedo_color = rc
	_ring.scale = Vector3(1.0 + 0.15 * _throb, 0.25, 1.0 + 0.15 * _throb)
	_light.light_energy = 1.2 + 1.8 * heat * _throb + randf_range(0.0, 0.35)


func _follow() -> void:
	if target and is_instance_valid(target):
		global_position = target.global_position


func _stop_loop() -> void:
	if _loop_id >= 0:
		Sfx.stop_loop(_loop_id)
		_loop_id = -1


static func _additive(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = color
	m.disable_receive_shadows = true
	return m
