class_name TeamComponent
extends PlayerComponent
## Team marker: a flat ring in the team colour on the ground under the blob, shown while the
## player is on a team. Owner: teams (Minigame). `Minigame.assign_teams` sets it on every peer
## through its RPC; the minigame clears it when it leaves the tree (round over). Pure visuals:
## no ticks, no gameplay state. Hidden with the player (a dead player is hidden).

## Ring radii in metres at body scale 1 (the blob is about 0.8 m wide).
const RING_INNER := 0.47
const RING_OUTER := 0.62
## Height above the feet (clears the floor without z-fighting).
const RING_Y := 0.035

## Team index, -1 = none.
var team: int = -1
var color: Color = Color.WHITE

var _ring: MeshInstance3D
var _disc: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _disc_mat: StandardMaterial3D


func _ready() -> void:
	_ring_mat = _material(1.0)
	_disc_mat = _material(0.22)
	var torus := TorusMesh.new()
	torus.inner_radius = RING_INNER
	torus.outer_radius = RING_OUTER
	torus.rings = 32
	torus.ring_segments = 8
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	_ring.mesh = torus
	_ring.material_override = _ring_mat
	_ring.scale = Vector3(1.0, 0.35, 1.0)
	_ring.position.y = RING_Y
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = RING_INNER
	disc_mesh.bottom_radius = RING_INNER
	disc_mesh.height = 0.01
	disc_mesh.radial_segments = 32
	disc_mesh.rings = 1
	_disc = MeshInstance3D.new()
	_disc.name = "Disc"
	_disc.mesh = disc_mesh
	_disc.material_override = _disc_mat
	_disc.position.y = RING_Y - 0.01
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_disc)
	set_team(team, color)


## Shows the ring in `p_color` for `p_team` (>= 0), or hides it (-1).
func set_team(p_team: int, p_color: Color) -> void:
	team = p_team
	color = p_color
	if _ring == null:
		return
	_ring_mat.albedo_color = Color(p_color, 1.0)
	_disc_mat.albedo_color = Color(p_color, 0.22)
	_ring.visible = team >= 0
	_disc.visible = team >= 0
	set_process(team >= 0)
	_follow_size()


func has_team() -> bool:
	return team >= 0


## True while the ring is shown. Read by tests.
func is_ring_shown() -> bool:
	return _ring != null and _ring.visible


func _process(_delta: float) -> void:
	_follow_size()


## The ring widens with the body size (SizeComponent.shown_scale).
func _follow_size() -> void:
	var s := 1.0
	var size := player.get_component(&"size") as SizeComponent if player else null
	if size:
		s = size.shown_scale
	scale = Vector3(s, 1.0, s)


func _material(alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(color, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.render_priority = -1
	return m
