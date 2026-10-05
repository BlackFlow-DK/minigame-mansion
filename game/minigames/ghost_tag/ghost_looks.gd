extends Node3D
## Ghost Tag presentation on every peer: the lantern every living blob carries and the ghost
## look. Driven by GhostTag (its RPCs call `set_ghost`); never decides anything itself.
##
## Living blob: a `ghost_lantern` prop in its right hand plus a warm light (an OmniLight3D
##   without shadows on MEDIUM/HIGH; on LOW a soft additive glow disc on the floor instead).
## Ghost: through the visuals' public `get_model_root()` only: every GeometryInstance3D under
##   the model root gets a pale blue-white `material_overlay` and instance `transparency`
##   (the original values are saved first), the feet are hidden (it floats), and a translucent
##   `ghost_sheet` (our own node, parented to the model root) wobbles and bobs over it. A cold
##   light / glow disc replaces the lantern.
## `restore(slot)` / `restore_all()` put back exactly what was saved and remove our nodes; GhostTag
## calls them when the round ends (on every peer) and when it leaves the tree (stage cleared).
## Lights and discs are our own children (they follow the players in _process), so they go
## with the minigame. Follows the Look quality switch (group Look.QUALITY_GROUP).
## Night: a dark veil (`ghost_dark.gdshader`, a plane above the walls) with soft pools of light
## around every lantern, every ghost and the moonlit windows: the mood and the readability are
## the same at every quality (on LOW it stands in for the per-blob lights).

signal look_changed(slot: int, ghost: bool)

const SHEET_SCENE := preload("res://assets/models/props/ghost_sheet.glb")
const LANTERN_SCENE := preload("res://assets/models/props/ghost_lantern.glb")

const LANTERN_COLOR := Color(1.0, 0.72, 0.38)
const GHOST_COLOR := Color(0.55, 0.78, 1.0)
## Instance transparency of a ghost's own meshes (0 opaque .. 1 invisible).
const GHOST_TRANSPARENCY := 0.35
const LANTERN_ENERGY := 1.9
const LANTERN_RANGE := 4.2
const GHOST_ENERGY := 1.1
const GHOST_RANGE := 2.6
const DARK_SHADER := preload("res://minigames/ghost_tag/ghost_dark.gdshader")
## Veil opacity during the round and after it (the results are not left in the dark).
const DARK_ALPHA := 0.62
const DARK_ALPHA_AFTER := 0.25
## Light pools in the veil: radius (m) and strength of a lantern and of a ghost's glow.
const LANTERN_POOL := Vector2(3.3, 1.0)
const GHOST_POOL := Vector2(2.1, 0.8)

var _players: Array[Player] = []
## The slot of each `_players` entry (a leaver's node is freed: its slot is still known here).
var _player_slots: Array[int] = []
## slot -> true while the ghost look is on.
var _ghost: Dictionary[int, bool] = {}
## slot -> Array of [GeometryInstance3D, transparency, material_overlay, cast_shadow]
var _saved: Dictionary[int, Array] = {}
## slot -> Array of [Node3D, visible] (feet we hid)
var _hidden: Dictionary[int, Array] = {}
var _sheets: Dictionary[int, Node3D] = {}
var _lanterns: Dictionary[int, Node3D] = {}
var _lights: Dictionary[int, OmniLight3D] = {}
var _discs: Dictionary[int, MeshInstance3D] = {}
## Lanterns are carried (and lit) only while true (the round end keeps lights, drops props).
var _carry: bool = true
var _clock: float = 0.0
var _low: bool = false
var _veil: MeshInstance3D = null
var _veil_mat: ShaderMaterial = null
var _static_holes: Array[Vector4] = []
## slot -> (seconds left, total) of a rising sheet.
var _rise: Dictionary[int, Vector2] = {}

static var _overlay_mat: StandardMaterial3D = null
static var _sheet_mat: StandardMaterial3D = null
static var _disc_mesh: QuadMesh = null
static var _disc_mats: Dictionary = {}


func _ready() -> void:
	add_to_group(Look.QUALITY_GROUP)
	_low = Look.is_low()
	_veil_mat = ShaderMaterial.new()
	_veil_mat.shader = DARK_SHADER
	_veil_mat.set_shader_parameter(&"dark_color", Color(0.03, 0.03, 0.09, DARK_ALPHA))
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 50.0)
	_veil = MeshInstance3D.new()
	_veil.name = "NightVeil"
	_veil.mesh = plane
	_veil.material_override = _veil_mat
	_veil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_veil.position = Vector3(0.0, 2.8, 0.0)
	# never culled: it covers the whole view
	_veil.custom_aabb = AABB(Vector3(-30.0, -1.0, -25.0), Vector3(60.0, 2.0, 50.0))
	add_child(_veil)


## Fixed light pools in the veil (the windows): Vector4(x, z, radius, strength).
func set_static_holes(holes: Array[Vector4]) -> void:
	_static_holes = holes.duplicate()


## The veil's opacity now (tests).
func veil_alpha() -> float:
	var c: Color = _veil_mat.get_shader_parameter(&"dark_color")
	return c.a


func _exit_tree() -> void:
	restore_all()


## Every peer, at _setup: the round's players get lanterns.
func track(players: Array[Player]) -> void:
	_players = players.duplicate()
	_player_slots.clear()
	for p in _players:
		_player_slots.append(p.slot if is_instance_valid(p) else -1)
	for p in _players:
		if is_instance_valid(p) and not _lanterns.has(p.slot):
			_give_lantern(p)
		_ensure_light(p)


## Turns the ghost look on (or off) for `p`. `rise` > 0: the sheet grows out of the floor over
## that many seconds (a freshly turned ghost rising).
func set_ghost(p: Player, on: bool, rise: float = 0.0) -> void:
	if p == null or not is_instance_valid(p):
		return
	if on == _ghost.get(p.slot, false):
		return
	if on:
		_drop_lantern(p.slot)
		_apply_ghost(p)
		if rise > 0.0:
			_rise[p.slot] = Vector2(rise, rise)
	else:
		restore(p.slot)
		if _carry:
			_give_lantern(p)
	_ensure_light(p)
	look_changed.emit(p.slot, on)


## True while `slot` wears the ghost look (an overlay is on its model).
func is_ghost_look(slot: int) -> bool:
	return _ghost.get(slot, false)


## Slots wearing the ghost look, ascending.
func ghost_look_slots() -> Array[int]:
	var out: Array[int] = []
	for s: int in _ghost:
		if _ghost[s]:
			out.append(s)
	out.sort()
	return out


## Removes the ghost look of `slot` (exactly the saved values come back).
func restore(slot: int) -> void:
	# (a leaver's model may be freed already: check before casting)
	if _saved.has(slot):
		for e: Array in _saved[slot]:
			if not is_instance_valid(e[0]):
				continue
			var g := e[0] as GeometryInstance3D
			g.transparency = e[1]
			g.material_overlay = e[2]
			g.cast_shadow = e[3]
		_saved.erase(slot)
	if _hidden.has(slot):
		for e: Array in _hidden[slot]:
			if not is_instance_valid(e[0]):
				continue
			var n := e[0] as Node3D
			n.visible = e[1]
		_hidden.erase(slot)
	if _sheets.has(slot):
		var s := _sheets[slot]
		if is_instance_valid(s):
			s.get_parent().remove_child(s)
			s.queue_free()
		_sheets.erase(slot)
	var was: bool = _ghost.get(slot, false)
	_ghost.erase(slot)
	_rise.erase(slot)
	if was:
		look_changed.emit(slot, false)


## Round over / leaving: every look back to normal, lantern props gone. With `keep_lights` the
## warm lights stay on every blob (the results scene is not left in the dark).
func restore_all(keep_lights: bool = false) -> void:
	_carry = false
	if _veil_mat:
		_veil_mat.set_shader_parameter(&"dark_color", Color(0.03, 0.03, 0.09, DARK_ALPHA_AFTER))
	for slot: int in _ghost.keys():
		restore(slot)
	for slot: int in _lanterns.keys():
		_drop_lantern(slot)
	if keep_lights:
		for p in _players:
			if is_instance_valid(p):
				_ensure_light(p)
	else:
		for slot: int in _lights.keys():
			_lights[slot].queue_free()
		_lights.clear()
		for slot: int in _discs.keys():
			_discs[slot].queue_free()
		_discs.clear()


## Look.set_quality: LOW swaps every light for a glow disc, and back.
func apply_quality() -> void:
	var low := Look.is_low()
	if low == _low:
		return
	_low = low
	for p in _players:
		if is_instance_valid(p):
			_ensure_light(p)


## Lights in the scene now (tests, perf report).
func light_count() -> int:
	return _lights.size()


func disc_count() -> int:
	return _discs.size()


# --- Per frame ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	_clock += delta
	var holes := PackedVector4Array()
	for h in _static_holes:
		holes.append(h)
	for i in _players.size():
		var p: Player = _players[i] if is_instance_valid(_players[i]) else null
		if p == null or not p.is_inside_tree():
			# a leaver (removed, then freed): its light or glow goes with it
			if i < _player_slots.size():
				_drop_light(_player_slots[i])
			continue
		var s := p.slot
		var ghost: bool = _ghost.get(s, false)
		var base := p.global_position
		if p.alive and holes.size() < 16:
			var pool := GHOST_POOL if ghost else LANTERN_POOL
			var flicker := 1.0 if ghost else 1.0 + 0.03 * sin(_clock * 11.0 + float(s) * 2.3)
			holes.append(Vector4(base.x, base.z, pool.x * flicker, pool.y))
		if _lights.has(s):
			_lights[s].global_position = base + Vector3.UP * (0.75 if ghost else 1.05)
			_lights[s].visible = p.alive
		if _discs.has(s):
			_discs[s].global_position = Vector3(base.x, 0.03, base.z)
			_discs[s].visible = p.alive
		if _sheets.has(s) and is_instance_valid(_sheets[s]):
			# wobble and bob: the hem breathes, the sheet floats a little above the blob
			var t := _clock * 3.2 + float(s) * 1.7
			var sheet := _sheets[s]
			sheet.position = Vector3(0.0, 0.05 + 0.035 * sin(t * 0.8), 0.0)
			sheet.rotation = Vector3(0.05 * sin(t * 0.9), 0.12 * sin(t * 0.5), 0.05 * cos(t * 1.1))
			var w := 1.0 + 0.045 * sin(t * 1.3)
			var grow := 1.0
			if _rise.has(s):
				var r := _rise[s]
				r.x -= delta
				if r.x <= 0.0:
					_rise.erase(s)
				else:
					_rise[s] = r
					grow = lerpf(0.25, 1.0, ease(1.0 - r.x / maxf(r.y, 0.01), -2.0))
			sheet.scale = Vector3(w, 1.0 - 0.03 * sin(t * 1.3), 2.0 - w) * grow
	if _veil_mat:
		_veil_mat.set_shader_parameter(&"holes", holes)
		_veil_mat.set_shader_parameter(&"hole_count", holes.size())


# --- Ghost ---------------------------------------------------------------------------------

func _apply_ghost(p: Player) -> void:
	var root := _model_root(p)
	_ghost[p.slot] = true
	if root == null:
		return
	var saved: Array = []
	for g in _geometry(root):
		saved.append([g, g.transparency, g.material_overlay, g.cast_shadow])
		g.material_overlay = _overlay()
		g.transparency = GHOST_TRANSPARENCY
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_saved[p.slot] = saved
	var hidden: Array = []
	for foot_name: String in ["FootL", "FootR"]:
		var foot := root.find_child(foot_name, true, false) as Node3D
		if foot:
			hidden.append([foot, foot.visible])
			foot.visible = false
	_hidden[p.slot] = hidden
	var sheet := SHEET_SCENE.instantiate() as Node3D
	sheet.name = "GhostTagSheet"
	for mi in _geometry(sheet):
		var m := mi as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		for i in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i)
			if src and src.resource_name == "GhostEye":
				m.set_surface_override_material(i, Look.toon_material(Color("#1d1a2b"), 0.6, false))
			else:
				m.set_surface_override_material(i, _sheet_material())
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(sheet)
	_sheets[p.slot] = sheet


static func _overlay() -> StandardMaterial3D:
	if _overlay_mat == null:
		_overlay_mat = StandardMaterial3D.new()
		_overlay_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_overlay_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_overlay_mat.albedo_color = Color(0.82, 0.92, 1.0, 0.62)
	return _overlay_mat


static func _sheet_material() -> StandardMaterial3D:
	if _sheet_mat == null:
		_sheet_mat = StandardMaterial3D.new()
		_sheet_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_sheet_mat.albedo_color = Color(0.86, 0.93, 1.0, 0.42)
		_sheet_mat.emission_enabled = true
		_sheet_mat.emission = Color(0.5, 0.7, 1.0)
		_sheet_mat.emission_energy_multiplier = 0.55
		_sheet_mat.rim_enabled = true
		_sheet_mat.rim = 0.8
		_sheet_mat.roughness = 0.8
	return _sheet_mat


# --- Lantern and lights --------------------------------------------------------------------

func _give_lantern(p: Player) -> void:
	if not _carry or _lanterns.has(p.slot):
		return
	var root := _model_root(p)
	if root == null:
		return
	var lantern := LANTERN_SCENE.instantiate() as Node3D
	lantern.name = "GhostTagLantern"
	Look.apply_toon(lantern, false)
	for g in _geometry(lantern):
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hand := root.find_child("HandR", true, false) as Node3D
	if hand:
		hand.add_child(lantern)
		lantern.position = Vector3(0.0, 0.02, 0.0)
	else:
		root.add_child(lantern)
		lantern.position = Vector3(-0.42, 0.5, 0.08)
	_lanterns[p.slot] = lantern


## Removes `slot`'s light and glow disc (a player who left).
func _drop_light(slot: int) -> void:
	if _lights.has(slot):
		_lights[slot].queue_free()
		_lights.erase(slot)
	if _discs.has(slot):
		_discs[slot].queue_free()
		_discs.erase(slot)


func _drop_lantern(slot: int) -> void:
	if not _lanterns.has(slot):
		return
	var l := _lanterns[slot]
	if is_instance_valid(l):
		l.get_parent().remove_child(l)
		l.queue_free()
	_lanterns.erase(slot)


## The right light for `p` now: a warm lantern or a cold ghost glow; an omni light, or on LOW
## a glow disc.
func _ensure_light(p: Player) -> void:
	var ghost: bool = _ghost.get(p.slot, false)
	var color := GHOST_COLOR if ghost else LANTERN_COLOR
	if _low:
		if _lights.has(p.slot):
			_lights[p.slot].queue_free()
			_lights.erase(p.slot)
		var disc: MeshInstance3D = _discs.get(p.slot)
		if disc == null:
			disc = MeshInstance3D.new()
			disc.name = "Glow%d" % p.slot
			disc.mesh = _disc()
			disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(disc)
			_discs[p.slot] = disc
		disc.material_override = _disc_material(ghost)
		disc.scale = Vector3.ONE * (0.7 if ghost else 1.0)
		return
	if _discs.has(p.slot):
		_discs[p.slot].queue_free()
		_discs.erase(p.slot)
	var light: OmniLight3D = _lights.get(p.slot)
	if light == null:
		light = OmniLight3D.new()
		light.name = "Light%d" % p.slot
		light.shadow_enabled = false
		light.light_specular = 0.15
		light.omni_attenuation = 1.4
		add_child(light)
		_lights[p.slot] = light
	light.light_color = color
	light.light_energy = GHOST_ENERGY if ghost else LANTERN_ENERGY
	light.omni_range = GHOST_RANGE if ghost else LANTERN_RANGE


static func _disc() -> QuadMesh:
	if _disc_mesh == null:
		_disc_mesh = QuadMesh.new()
		_disc_mesh.size = Vector2(5.0, 5.0)
		_disc_mesh.orientation = PlaneMesh.FACE_Y
	return _disc_mesh


static func _disc_material(ghost: bool) -> StandardMaterial3D:
	if _disc_mats.has(ghost):
		return _disc_mats[ghost]
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	grad.add_point(0.35, Color(1, 1, 1, 0.45))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_texture = tex
	var c := GHOST_COLOR if ghost else LANTERN_COLOR
	m.albedo_color = Color(c.r * 0.45, c.g * 0.45, c.b * 0.45, 1.0)
	m.disable_receive_shadows = true
	_disc_mats[ghost] = m
	return m


# --- Helpers -------------------------------------------------------------------------------

static func _model_root(p: Player) -> Node3D:
	var v := p.get_component(&"visuals") as VisualsComponent if p else null
	return v.get_model_root() if v else null


static func _geometry(root: Node) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	if root is GeometryInstance3D:
		out.append(root)
	for c in root.get_children():
		# our own lantern / sheet are not part of the blob's look
		if c.name == &"GhostTagSheet" or c.name == &"GhostTagLantern":
			continue
		out.append_array(_geometry(c))
	return out
