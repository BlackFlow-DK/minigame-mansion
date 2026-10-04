extends Node3D
## Lobby toy: the minigame portal advertises what is coming. Inside the arch a coloured emblem
## and the name of a minigame cycle slowly through the session's pool (the host's playlist when
## one is ticked, else every playable minigame that fits the player count; from
## `MinigameCatalog`), and the portal's glow takes on that minigame's colour. The cycle runs on
## the wall clock, so every peer on the LAN shows the same one without any traffic.
## `flare()` (the host pressed START: every peer sees Session leave LOBBY) makes the portal blaze.

signal shown(id: StringName)

## Seconds per minigame.
@export var period: float = 3.5

var lobby: MansionLobby = null
## The minigame shown now.
var current: StringName = &""

var _emblem: MeshInstance3D = null
var _emblem_mat: StandardMaterial3D = null
var _ring_mat: StandardMaterial3D = null
var _name: Label3D = null
var _kind: Label3D = null
var _pop: float = 0.0
var _flare: float = 0.0
var _color: Color = Color(0.35, 1.0, 0.88)
var _target_color: Color = Color(0.35, 1.0, 0.88)
var _base_portal: Color = Color.WHITE
var _base_deep: Color = Color.WHITE
var _index: int = -1


func setup(p_lobby: MansionLobby, pos: Vector3) -> void:
	lobby = p_lobby
	position = pos
	var ring := MeshInstance3D.new()
	ring.name = "EmblemRing"
	var tm := TorusMesh.new()
	tm.inner_radius = 0.4
	tm.outer_radius = 0.5
	tm.rings = 24
	tm.ring_segments = 8
	ring.mesh = tm
	ring.rotation.x = PI * 0.5
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.albedo_color = Color("#e8b33a")
	_ring_mat.metallic = 0.5
	_ring_mat.roughness = 0.35
	_ring_mat.emission_enabled = true
	_ring_mat.emission = Color("#e8b33a")
	_ring_mat.emission_energy_multiplier = 0.4
	ring.material_override = _ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	_emblem = MeshInstance3D.new()
	_emblem.name = "Emblem"
	var disc := CylinderMesh.new()
	disc.top_radius = 0.42
	disc.bottom_radius = 0.42
	disc.height = 0.03
	disc.radial_segments = 24
	disc.rings = 1
	_emblem.mesh = disc
	_emblem.rotation.x = PI * 0.5
	_emblem_mat = StandardMaterial3D.new()
	_emblem_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_emblem.material_override = _emblem_mat
	_emblem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_emblem)
	_kind = _label("Kind", 40, Vector3(0.0, 0.0, 0.03))
	_name = _label("Name", 64, Vector3(0.0, -0.82, 0.0))
	_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name.width = 400.0
	if lobby.emit_material(&"EmitPortal"):
		_base_portal = lobby.emit_material(&"EmitPortal").emission
	if lobby.emit_material(&"EmitPortalDeep"):
		_base_deep = lobby.emit_material(&"EmitPortalDeep").emission
	_refresh(true)


func _label(label_name: String, size: int, at: Vector3) -> Label3D:
	var l := Label3D.new()
	l.name = label_name
	l.font_size = size
	l.pixel_size = 0.0045
	l.outline_size = 12
	l.modulate = Color("#fff6e0")
	l.outline_modulate = Color(0.08, 0.05, 0.12)
	l.shaded = false
	l.position = at
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(l)
	return l


## The ids the portal cycles through.
static func pool() -> Array[StringName]:
	var count := maxi(1, Net.roster.size())
	var src: Array[StringName] = []
	if not Session.playlist.is_empty():
		src.assign(Session.playlist)
	else:
		src = MinigameCatalog.playable()
	var out: Array[StringName] = []
	for id in src:
		if MinigameCatalog.fits(id, count):
			out.append(id)
	if out.is_empty():
		out = MinigameCatalog.playable()
	return out


## The portal blazes up for a moment (every peer).
func flare() -> void:
	_flare = 1.0
	Fx.play(&"respawn_sparkle", position + Vector3(0.0, -0.9, 0.3), _target_color)
	Fx.play(&"shockwave", position + Vector3(0.0, -1.3, 0.4), _target_color)


func get_flare() -> float:
	return _flare


func _refresh(force: bool) -> void:
	var ids := pool()
	if ids.is_empty():
		return
	var i := int(floor(Time.get_unix_time_from_system() / maxf(period, 0.5))) % ids.size()
	if not force and i == _index and current == ids[i]:
		return
	_index = i
	current = ids[i]
	var info := MinigameCatalog.info(current)
	_target_color = info["color"]
	_name.text = String(info["name"])
	_kind.text = String(info["kind_name"]).to_upper()
	_pop = 1.0
	shown.emit(current)


func _process(delta: float) -> void:
	_refresh(false)
	_color = _color.lerp(_target_color, minf(1.0, delta * 3.0))
	_pop = maxf(0.0, _pop - delta * 3.0)
	_flare = maxf(0.0, _flare - delta * 0.8)
	var s := 1.0 + 0.18 * _pop * _pop + 0.25 * _flare
	_emblem.scale = Vector3.ONE * s
	_emblem_mat.albedo_color = _color.lerp(Color.WHITE, 0.6 * _flare)
	_ring_mat.emission_energy_multiplier = 0.4 + 3.0 * _flare
	_name.modulate.a = 1.0 - 0.6 * _pop
	var portal := lobby.emit_material(&"EmitPortal")
	if portal:
		portal.emission = _base_portal.lerp(_color, 0.55).lerp(Color.WHITE, 0.5 * _flare)
	var deep := lobby.emit_material(&"EmitPortalDeep")
	if deep:
		deep.emission = _base_deep.lerp(_color.darkened(0.3), 0.5)
	lobby.set_portal_tint(_color, _flare)
