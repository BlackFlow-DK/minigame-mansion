class_name HideDisguise
extends Node3D
## Hide and Sneak: the furniture a hider wears, a child of its Player on every peer (the blob
## model is hidden meanwhile; HideAndSneak does both and undoes both). Shows the kind's merged
## furniture mesh, turned to the player's facing snapped to quarter turns. Presentation only,
## every peer, from replicated state: a moving prop wobbles (the tell), `rustle()` gives the
## involuntary shiver, `set_glow` a faint see-through glow (seekers, last seconds), and on the
## hider's own peer a faint ghost of the blob shows through so they know where they are.

const NODE_NAME := &"HideDisguise"
const GHOST_SHADER: Shader = preload("res://minigames/hide_and_sneak/hide_ghost.gdshader")

var player: Player = null
var kind: int = -1
## True on the hider's own peer: shows the ghost blob.
var own: bool = false

var _mesh: MeshInstance3D = null
var _ghost: MeshInstance3D = null
var _glow_mat: StandardMaterial3D = null
var _yaw: float = 0.0
var _yaw_target: float = 0.0
var _jitter: float = 0.0
var _last_pos: Vector3 = Vector3.INF
var _speed: float = 0.0
var _clock: float = 0.0
var _rustle_t: float = 99.0
var _pop_t: float = 99.0


func _init(p: Player = null, p_kind: int = 0, p_own: bool = false) -> void:
	player = p
	own = p_own
	name = String(NODE_NAME)
	_mesh = MeshInstance3D.new()
	_mesh.name = "Prop"
	add_child(_mesh)
	if p:
		_jitter = deg_to_rad(float(hash(p.slot * 31 + 7) % 15) - 7.0)
		_yaw = _snap(p.facing)
		_yaw_target = _yaw
	set_kind(p_kind)


func _ready() -> void:
	top_level = false
	if own:
		_ghost = MeshInstance3D.new()
		_ghost.name = "Ghost"
		var s := SphereMesh.new()
		s.radius = 0.4
		s.height = 1.0
		s.radial_segments = 16
		s.rings = 8
		_ghost.mesh = s
		var m := ShaderMaterial.new()
		m.shader = GHOST_SHADER
		var c := Color.WHITE
		if player:
			c = Look.parse_color(player.loadout.get("primary", ""), Color.WHITE)
		m.set_shader_parameter(&"color", c.lerp(Color.WHITE, 0.25))
		m.render_priority = 2
		_ghost.material_override = m
		_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ghost.position = Vector3(0.0, 0.5, 0.0)
		add_child(_ghost)


## Every peer: wear `p_kind` now (a little pop when it changes).
func set_kind(p_kind: int) -> void:
	if p_kind == kind:
		return
	var changed := kind >= 0
	kind = p_kind
	_mesh.mesh = HideRoom.kind_mesh(kind)
	if changed:
		_pop_t = 0.0


## The involuntary shiver (every RUSTLE_INTERVAL s).
func rustle() -> void:
	_rustle_t = 0.0


## Faint glow seen through walls (seekers' peers, last seconds of the round).
func set_glow(on: bool) -> void:
	if not on:
		_mesh.material_overlay = null
		return
	if _glow_mat == null:
		_glow_mat = StandardMaterial3D.new()
		_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_glow_mat.no_depth_test = true
		_glow_mat.render_priority = 1
		_glow_mat.albedo_color = Color(1.0, 0.85, 0.5, 0.18)
	_mesh.material_overlay = _glow_mat


func has_glow() -> bool:
	return _mesh.material_overlay != null


func _process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	_clock += delta
	var pos := player.global_position
	if _last_pos != Vector3.INF and delta > 0.0:
		var v := Vector2(pos.x - _last_pos.x, pos.z - _last_pos.z).length() / delta
		_speed = lerpf(_speed, minf(v, 6.0), 1.0 - exp(-12.0 * delta))
	_last_pos = pos
	if _speed > 0.3:
		_yaw_target = _snap(player.facing)
	_yaw = lerp_angle(_yaw, _yaw_target, 1.0 - exp(-8.0 * delta))
	# Wobble while it moves: a waddle side to side and a little hop.
	var k := clampf(_speed / 2.0, 0.0, 1.0)
	var roll := sin(_clock * 13.0) * 0.09 * k
	var bob := absf(sin(_clock * 13.0)) * 0.05 * k
	# Rustle: a quick shiver that fades.
	if _rustle_t < 0.9:
		_rustle_t += delta
		var r := 1.0 - _rustle_t / 0.9
		roll += sin(_rustle_t * 45.0) * 0.07 * r
		bob += absf(sin(_rustle_t * 30.0)) * 0.03 * r
	var s := 1.0
	if _pop_t < 0.35:
		_pop_t += delta
		s = 1.0 + 0.18 * sin(clampf(_pop_t / 0.35, 0.0, 1.0) * PI)
	_mesh.transform = Transform3D(Basis(Vector3.UP, _yaw + _jitter) * Basis(Vector3.BACK, roll) * Basis().scaled(Vector3.ONE * s),
		Vector3(0.0, bob, 0.0))
	if _glow_mat and _mesh.material_overlay == _glow_mat:
		_glow_mat.albedo_color.a = 0.14 + 0.08 * sin(_clock * 4.0)


static func _snap(facing: Vector3) -> float:
	if facing.length_squared() < 0.0001:
		return 0.0
	return snappedf(atan2(facing.x, facing.z), PI * 0.5)
