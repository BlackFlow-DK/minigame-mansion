extends Node3D
## Lobby toy: a photo spot. A framed backdrop, a taped floor area in front of it and a big red
## button. Shoving the button (or bumping into it) starts a 3-2-1 countdown on the frame; at
## zero everyone standing in the area strikes the cheer pose (`VisualsComponent.play_emote`), a
## flash goes off and the frame says "SAY CHEESE!". Pure fun, no state: the host validates the
## press (reach, cooldown) and sends `start` to every peer; each peer runs the countdown and
## picks the blobs inside from what it sees.

signal countdown_started
## Every peer, at zero: the slots inside the area that struck the pose.
signal photo_taken(slots: Array[int])

const FRAME_MODEL := "res://assets/models/props/toy_photo_frame.glb"
const BUTTON_MODEL := "res://assets/models/props/toy_photo_button.glb"
## Area in front of the frame, relative to the frame's origin: x half-width, z from..to.
const AREA_HALF_X := 1.3
const AREA_Z0 := 0.65
const AREA_Z1 := 2.35
const BUTTON_OFFSET := Vector3(2.0, 0.0, 1.05)
const BUTTON_RADIUS := 0.24

@export var countdown: float = 3.0
## Seconds after the photo before the button works again.
@export var cooldown: float = 1.5
@export var reach: float = 0.85
@export var cone_deg: float = 75.0
@export var bump_speed: float = 1.6

var lobby: MansionLobby = null
## Every peer: photos taken (network check).
var photo_count: int = 0

var _left: float = -1.0
var _cooldown_left: float = 0.0
var _last_tick: int = -1
var _flash: float = 0.0
var _cheese: float = 0.0
var _press: float = 0.0
var _big: Label3D = null
var _flash_mat: StandardMaterial3D = null
var _flash_mesh: MeshInstance3D = null
var _flash_light: OmniLight3D = null
var _cap: Node3D = null
var _cap_rest: Vector3 = Vector3.ZERO


func setup(p_lobby: MansionLobby, pos: Vector3) -> void:
	lobby = p_lobby
	position = pos
	var scene := load(FRAME_MODEL) as PackedScene
	if scene:
		var m := scene.instantiate() as Node3D
		add_child(m)
		Look.apply_toon(m)
	var bscene := load(BUTTON_MODEL) as PackedScene
	if bscene:
		var b := bscene.instantiate() as Node3D
		b.position = BUTTON_OFFSET
		add_child(b)
		Look.apply_toon(b)
		_cap = b.get_node_or_null(^"ButtonCap") as Node3D
		if _cap:
			_cap_rest = _cap.position
	var body := lobby.make_static_body("PhotoBody")
	lobby.add_solid_box(body, Transform3D(Basis(), pos + Vector3(0.0, 1.45, 0.0)), Vector3(2.9, 2.9, 0.2), 0.5)
	for sx: float in [-1.0, 1.0]:
		lobby.add_solid_box(body, Transform3D(Basis(), pos + Vector3(sx * 1.15, 0.06, 0.15)), Vector3(0.2, 0.12, 0.75), 0.6)
	lobby.add_solid_cylinder(body, pos + BUTTON_OFFSET, 0.22, 0.98, 0.6)
	_build_area()
	_big = MansionLobby.make_label("Sign", 0.72, Color("#fff3c4"), Color(0.25, 0.08, 0.2))
	_big.position = Vector3(0.0, 2.2, 0.3)
	_big.visible = false
	add_child(_big)
	_flash_mesh = MeshInstance3D.new()
	_flash_mesh.name = "Flash"
	var q := QuadMesh.new()
	q.size = Vector2(2.6, 2.2)
	_flash_mesh.mesh = q
	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_mat.albedo_color = Color(1.0, 1.0, 0.95, 0.0)
	_flash_mesh.material_override = _flash_mat
	_flash_mesh.position = Vector3(0.0, 1.4, 0.12)
	_flash_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flash_mesh.visible = false
	add_child(_flash_mesh)


## Taped outline of the area on the floor and a camera icon in its middle (one mesh).
func _build_area() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := 0.07
	var x0 := -AREA_HALF_X
	var x1 := AREA_HALF_X
	var y := 0.012
	# dashed tape on the four sides
	var sides: Array = [[Vector2(x0, AREA_Z0), Vector2(x1, AREA_Z0)], [Vector2(x1, AREA_Z0), Vector2(x1, AREA_Z1)],
		[Vector2(x1, AREA_Z1), Vector2(x0, AREA_Z1)], [Vector2(x0, AREA_Z1), Vector2(x0, AREA_Z0)]]
	for s: Array in sides:
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		var n := int(ceil(a.distance_to(b) / 0.35))
		for i in n:
			var t0 := float(i) / n
			var t1 := minf(t0 + 0.65 / n, 1.0)
			_quad_line(st, a.lerp(b, t0), a.lerp(b, t1), w, y)
	# corner brackets, a little thicker
	for c: Vector2 in [Vector2(x0, AREA_Z0), Vector2(x1, AREA_Z0), Vector2(x1, AREA_Z1), Vector2(x0, AREA_Z1)]:
		var sx := 1.0 if c.x < 0.0 else -1.0
		var sz := 1.0 if c.y < AREA_Z1 - 0.1 else -1.0
		_quad_line(st, c, c + Vector2(sx * 0.35, 0.0), 0.12, y + 0.001)
		_quad_line(st, c, c + Vector2(0.0, sz * 0.35), 0.12, y + 0.001)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "Area"
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#f2c94c")
	mat.roughness = 0.7
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


static func _quad_line(st: SurfaceTool, a: Vector2, b: Vector2, w: float, y: float) -> void:
	var d := (b - a).normalized()
	var n := Vector2(-d.y, d.x) * w * 0.5
	var p := [a + n, b + n, b - n, a - n]
	var v: Array[Vector3] = []
	for q: Vector2 in p:
		v.append(Vector3(q.x, y, q.y))
	for i: int in [0, 1, 2, 0, 2, 3]:
		st.set_normal(Vector3.UP)
		st.add_vertex(v[i])


## True if world `pos` stands in the marked area.
func in_area(pos: Vector3) -> bool:
	var l := pos - position
	return absf(l.x) <= AREA_HALF_X and l.z >= AREA_Z0 and l.z <= AREA_Z1 and l.y < 1.2


func button_position() -> Vector3:
	return position + BUTTON_OFFSET


func in_reach(p_pos: Vector3, facing: Vector3, extra: float = 0.0) -> bool:
	return MansionLobby.reach_check(p_pos, facing, button_position() + Vector3.UP * 0.8, BUTTON_RADIUS,
		reach + extra, cone_deg + extra * 20.0, 0.0, 1.6)


func is_running() -> bool:
	return _left >= 0.0


func can_start() -> bool:
	return _left < 0.0 and _cooldown_left <= 0.0


## Host: starts the countdown if the button is free.
func host_press() -> bool:
	if not can_start():
		return false
	_cooldown_left = countdown + cooldown
	lobby.send_toys(&"_rpc_photo_start", [])
	apply_start()
	return true


## Host, every physics frame: a blob running into the button presses it.
func host_tick(delta: float, live: Array[Player]) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	if not can_start():
		return
	var c := button_position()
	for p in live:
		var q := p.global_position
		var to := Vector2(c.x - q.x, c.z - q.z)
		var d := to.length()
		if d > BUTTON_RADIUS + 0.75 or d < 0.001 or q.y > 1.0:
			continue
		if Vector2(p.velocity.x, p.velocity.z).dot(to / d) > bump_speed:
			host_press()
			return


## Every peer: the countdown starts.
func apply_start() -> void:
	_left = countdown
	_last_tick = -1
	_press = 1.0
	Sfx.play(&"toy_kick", button_position() + Vector3.UP * 0.9, -6.0, 1.6)
	countdown_started.emit()


func _physics_process(delta: float) -> void:
	if _left < 0.0:
		return
	_left -= delta
	var n := int(ceil(_left))
	if _left > 0.0 and n != _last_tick:
		_last_tick = n
		_big.visible = true
		_big.text = str(n)
		_big.scale = Vector3.ONE * 1.3
		Sfx.play(&"toy_tick", position + Vector3.UP * 1.5)
	if _left <= 0.0:
		_left = -1.0
		_snap()


func _snap() -> void:
	var slots: Array[int] = []
	if lobby:
		for p in lobby.live_players():
			if in_area(p.global_position):
				slots.append(p.slot)
				var v := p.get_component(&"visuals") as VisualsComponent
				if v:
					v.play_emote(&"cheer")
	photo_count += 1
	_flash = 1.0
	_cheese = 1.8
	_big.text = "SAY CHEESE!"
	_big.scale = Vector3.ONE * 0.62
	_big.visible = true
	Sfx.play(&"toy_shutter", position + Vector3(0.0, 1.5, 2.0))
	if not Look.is_low():
		if _flash_light == null:
			_flash_light = OmniLight3D.new()
			_flash_light.name = "FlashLight"
			_flash_light.light_color = Color(1.0, 0.98, 0.9)
			_flash_light.omni_range = 6.0
			_flash_light.position = Vector3(0.0, 2.0, 3.2)
			add_child(_flash_light)
		_flash_light.visible = true
	photo_taken.emit(slots)


func _process(delta: float) -> void:
	if _big and _big.visible and _cheese <= 0.0 and _left >= 0.0:
		_big.scale = _big.scale.lerp(Vector3.ONE, minf(1.0, delta * 10.0))
	if _cheese > 0.0:
		_cheese -= delta
		if _cheese <= 0.0:
			_big.visible = false
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 2.5)
		_flash_mat.albedo_color.a = _flash * 0.85
		_flash_mesh.visible = _flash > 0.0
		if _flash_light:
			_flash_light.light_energy = 6.0 * _flash
			_flash_light.visible = _flash > 0.0
	if _press > 0.0:
		_press = maxf(0.0, _press - delta * 3.0)
	if _cap:
		_cap.position = _cap_rest - Vector3.UP * 0.06 * minf(1.0, _press * 2.0)
