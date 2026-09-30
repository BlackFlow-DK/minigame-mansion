class_name WardrobePreview
extends TextureRect
## The wardrobe's live 3D preview: a blob on a trophy pedestal in a little corner of the
## mansion, rendered in its own SubViewport + World3D (so it never clashes with the game
## world's environment) and shown as this rect's texture. Owner: wardrobe UI.
##
## The blob idles in code with the character's own rig handles and face presets (BlobRig,
## BlobExpressions, AnimSpring): breathing, blinking, glancing, hands swaying. `react()` makes
## it hop and cheer when something is equipped. `turn()` / drag spins the turntable.
## The viewport renders at the rect's on-screen pixel size, so it stays sharp at any UI scale.

const PEDESTAL_SCENE: PackedScene = preload("res://assets/models/env/trophy_pedestal.glb")
const FLOOR_SCENE: PackedScene = preload("res://assets/models/env/floor_tile_4x4.glb")
const WALL_SCENE: PackedScene = preload("res://assets/models/env/wall_4m.glb")
const PORTRAIT_SCENE: PackedScene = preload("res://assets/models/env/portrait_frame_b.glb")
const PLANT_SCENE: PackedScene = preload("res://assets/models/env/potted_plant.glb")
const CANDELABRA_SCENE: PackedScene = preload("res://assets/models/env/candelabra.glb")

## Top of the trophy pedestal (the blob stands here).
const PEDESTAL_TOP := 0.746
## Resting view: a little three-quarter turn so the face and the side both read.
const REST_YAW := 0.38
const BACK_YAW := PI + 0.38
const DRAG_TURN := 0.012
const HOP_TIME := 0.42
const CHEER_TIME := 1.1
const BLINK_TIME := 0.14
## Palms forward, fingers up (left hand); the right hand uses the X-mirrored rotation.
const PALM_FORWARD_L := Basis(Vector3(0, 0, -1), Vector3(0, -1, 0), Vector3(-1, 0, 0))

signal turned

var viewport: SubViewport
var camera: Camera3D
var rig: BlobRig
## The loadout on the blob now (a copy).
var loadout: Dictionary = {}

var _turntable: Node3D
var _motion: Node3D
var _rng := RandomNumberGenerator.new()
var _clock: float = 0.0
var _yaw: float = REST_YAW
var _yaw_target: float = REST_YAW
var _spin: float = 0.0
var _hop_t: float = 99.0
var _hop_height: float = 0.0
var _landed: bool = true
var _cheer_t: float = 99.0
var _squash := AnimSpring.new(1.0, 300.0, 11.0)
var _lid: float = 0.0
var _mouth: Vector2 = Vector2(0.95, 0.7)
var _cheek: float = 1.0
var _pupil_scale: float = 1.0
var _blink_in: float = 1.5
var _blink_t: float = -1.0
var _glance: Vector2 = Vector2.ZERO
var _glance_in: float = 0.8
var _pupil: Vector2 = Vector2.ZERO
var _dragging: bool = false


func _init() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	_rng.seed = 4242


func _ready() -> void:
	_build_world()
	texture = viewport.get_texture()
	resized.connect(_fit_viewport)
	item_rect_changed.connect(_fit_viewport)
	_fit_viewport()


## The blob.glb instance (sockets and parts are its children).
func get_model_root() -> Node3D:
	return rig.root if rig else null


## Dresses the blob in `new_loadout` (sanitized by the caller).
func show_loadout(new_loadout: Dictionary) -> void:
	loadout = new_loadout.duplicate()
	if rig == null:
		return
	Cosmetics.apply(rig.root, loadout)
	toon(rig.root)


## A reaction to a change. `kind`: &"colour" (a small hop), &"hat" / &"face" / &"neck" /
## &"back" (hop, cheer, and turn so the new item is in view), &"random" (spin, hop, cheer).
func react(kind: StringName) -> void:
	_hop_t = 0.0
	_landed = false
	_squash.value = minf(_squash.value, 0.86)
	_squash.velocity = 6.0
	match kind:
		&"colour":
			_hop_height = 0.1
			_cheer_t = 0.5
		&"random":
			_hop_height = 0.24
			_cheer_t = 0.0
			_spin = TAU
		_:
			_hop_height = 0.18
			_cheer_t = 0.0
	if kind == &"back":
		_face_towards(BACK_YAW)
	elif kind == &"hat" or kind == &"face" or kind == &"neck":
		_face_towards(REST_YAW)


## Turns the turntable by `radians` (positive: the blob turns to its left, anticlockwise from above).
func turn(radians: float) -> void:
	if radians == 0.0:
		return
	_yaw_target += radians
	turned.emit()


func get_yaw() -> float:
	return _yaw_target


## `Look.apply_toon`, skipped headless: there (dummy renderer) toon copies of imported
## materials log "material_get_instance_shader_parameters: material is null" errors when their
## meshes are freed, which fails tests. Nothing is drawn headless anyway.
static func toon(root: Node3D) -> void:
	if DisplayServer.get_name() != "headless":
		Look.apply_toon(root)


func _face_towards(yaw: float) -> void:
	# The nearest equivalent angle, so the blob turns the short way round.
	_yaw_target = _yaw_target + wrapf(yaw - _yaw_target, -PI, PI)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		turn((event as InputEventMouseMotion).relative.x * DRAG_TURN)
		accept_event()
	elif event is InputEventScreenDrag:
		turn((event as InputEventScreenDrag).relative.x * DRAG_TURN)
		accept_event()


## Renders at the rect's real pixel size (UI scale and window size included).
func _fit_viewport() -> void:
	if viewport == null:
		return
	var s := get_global_transform_with_canvas().get_scale()
	var px := (size * s).round()
	viewport.size = Vector2i(clampi(int(px.x), 16, 4096), clampi(int(px.y), 16, 4096))


func _process(delta: float) -> void:
	if rig == null or not is_visible_in_tree():
		return
	delta = minf(delta, 0.1)
	_clock += delta
	_hop_t += delta
	_cheer_t += delta

	# Turntable: eases to the target, plus the randomise spin and a lazy sway.
	_yaw = lerpf(_yaw, _yaw_target, 1.0 - exp(-9.0 * delta))
	_spin = lerpf(_spin, 0.0, 1.0 - exp(-4.5 * delta))
	if absf(_spin) < 0.001:
		_spin = 0.0
	_turntable.rotation.y = _yaw + _spin + 0.1 * sin(_clock * 0.55)

	# Hop: anticipation squash (react), stretch in the air, a squash on landing.
	var hop := 0.0
	var air := 0.0
	if _hop_t < HOP_TIME:
		var u := _hop_t / HOP_TIME
		hop = _hop_height * sin(PI * u)
		air = sin(PI * u)
	elif not _landed:
		_landed = true
		_squash.value = minf(_squash.value, 1.0 - 0.9 * _hop_height)
		_squash.velocity = 0.0
	_squash.step(1.0 + 0.1 * air * (1.0 if _hop_t < HOP_TIME * 0.5 else -0.3), delta)
	var breath := 1.0 + 0.018 * sin(_clock * TAU / 2.8)
	_motion.position = Vector3(0.0, hop, 0.0)
	_motion.rotation = Vector3(0.03 * sin(_clock * 0.9), 0.0, 0.035 * sin(_clock * 0.7))
	_motion.scale = Vector3(1.0 / sqrt(breath), breath, 1.0 / sqrt(breath))
	var sq := clampf(_squash.value, 0.6, 1.4)
	var inv := 1.0 / sqrt(sq)
	rig.root.transform = Transform3D(Basis.from_scale(Vector3(inv, sq, inv)), Vector3.ZERO)

	var cheer := _envelope(_cheer_t, 0.12, CHEER_TIME - 0.5, 0.38)
	_pose_hands(cheer, air)
	_pose_feet(air)
	_pose_face(delta, cheer)


func _pose_hands(cheer: float, air: float) -> void:
	var hands: Array[Node3D] = [rig.hand_l, rig.hand_r]
	for i in 2:
		var hand := hands[i]
		if hand == null:
			continue
		var sgn := 1.0 if i == 0 else -1.0
		var rest := rig.rest_of(&"HandL" if i == 0 else &"HandR")
		var pos := rest + Vector3(0.0, 0.012 * sin(_clock * TAU / 2.8 + sgn * 0.4), 0.02 * sin(_clock * 1.3 + sgn))
		pos += Vector3(sgn * 0.05, 0.12, 0.0) * air
		var rot := Quaternion(Vector3.BACK, sgn * 0.12 * sin(_clock * 1.1))
		if cheer > 0.001:
			var up := Vector3(sgn * 0.52, 0.76 + 0.06 * sin(_clock * 13.0 + sgn * 0.9), 0.07)
			pos = pos.lerp(up, cheer)
			rot = rot.slerp(_palm_forward(sgn), cheer)
		hand.transform = Transform3D(Basis(rot.normalized()), pos)


func _pose_feet(air: float) -> void:
	var feet: Array[Node3D] = [rig.foot_l, rig.foot_r]
	for i in 2:
		var foot := feet[i]
		if foot == null:
			continue
		var rest := rig.rest_of(&"FootL" if i == 0 else &"FootR")
		foot.transform = Transform3D(Basis(Vector3.RIGHT, 0.35 * air), rest + Vector3(0.0, 0.05 * air, -0.02 * air))


func _pose_face(delta: float, cheer: float) -> void:
	var preset := BlobExpressions.get_preset(BlobExpressions.CHEER if cheer > 0.3 else BlobExpressions.HAPPY)
	var k := 1.0 - exp(-16.0 * delta)
	_lid = lerpf(_lid, preset["lid"], 1.0 - exp(-24.0 * delta))
	_mouth = _mouth.lerp(preset["mouth"], k)
	_cheek = lerpf(_cheek, preset["cheek"], k)
	_pupil_scale = lerpf(_pupil_scale, preset["pupil"], k)

	_blink_in -= delta
	if _blink_in <= 0.0:
		_blink_t = 0.0
		_blink_in = 0.3 if _rng.randf() < 0.18 else _rng.randf_range(1.6, 4.2)
	var blink := 0.0
	if _blink_t >= 0.0:
		_blink_t += delta
		blink = (1.0 - absf(_blink_t / BLINK_TIME * 2.0 - 1.0)) * BlobRig.LID_SHUT
		if _blink_t >= BLINK_TIME:
			_blink_t = -1.0
	var lid := maxf(_lid, blink)
	if rig.lid_l:
		rig.lid_l.rotation = Vector3(lid, 0.0, 0.0)
	if rig.lid_r:
		rig.lid_r.rotation = Vector3(lid, 0.0, 0.0)
	if rig.mouth:
		rig.mouth.scale = Vector3(_mouth.x, clampf(_mouth.y, BlobRig.MOUTH_CLOSED, BlobRig.MOUTH_SHOUT), 1.0)
	for cheek: Node3D in [rig.cheek_l, rig.cheek_r]:
		if cheek:
			cheek.scale = Vector3.ONE * _cheek

	# Glances around, and mostly at the camera (the player).
	_glance_in -= delta
	if _glance_in <= 0.0:
		_glance_in = _rng.randf_range(0.8, 2.6)
		_glance = Vector2.ZERO if _rng.randf() < 0.45 else \
			Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(0.006, 0.016)
	var at_camera := Vector2(-sin(_turntable.rotation.y) * 0.014, 0.004)
	var target := (at_camera + _glance).limit_length(BlobRig.PUPIL_RANGE)
	_pupil = _pupil.lerp(target, 1.0 - exp(-20.0 * delta))
	for p: Array in [[rig.pupil_l, &"PupilL"], [rig.pupil_r, &"PupilR"]]:
		var pupil := p[0] as Node3D
		if pupil:
			pupil.position = rig.rest_of(p[1]) + Vector3(_pupil.x, _pupil.y, 0.0)
			pupil.scale = Vector3.ONE * _pupil_scale


func _palm_forward(sgn: float) -> Quaternion:
	var q := PALM_FORWARD_L.get_rotation_quaternion()
	return q if sgn > 0.0 else Quaternion(q.x, -q.y, -q.z, q.w)


## 0 -> 1 over `attack`, holds, 1 -> 0 over `release`; 0 outside.
static func _envelope(t: float, attack: float, hold: float, release: float) -> float:
	if t < 0.0 or t > attack + hold + release:
		return 0.0
	if t < attack:
		return smoothstep(0.0, attack, t)
	if t < attack + hold:
		return 1.0
	return 1.0 - smoothstep(0.0, release, t - attack - hold)


func _build_world() -> void:
	viewport = SubViewport.new()
	viewport.name = "PreviewViewport"
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_PARENT_VISIBLE
	viewport.size = Vector2i(512, 512)
	add_child(viewport)
	var world := Node3D.new()
	world.name = "World"
	viewport.add_child(world)

	var look := (load("res://look/stage_look.tscn") as PackedScene).instantiate() as StageLook
	look.preset = StageLook.Preset.WARM_HALL
	look.light_yaw = -70.0
	look.shadow_distance = 14.0
	world.add_child(look)

	var set_dressing := Node3D.new()
	set_dressing.name = "Set"
	world.add_child(set_dressing)
	for x in [-1, 0, 1]:
		for z in [-1, 0]:
			var tile := FLOOR_SCENE.instantiate() as Node3D
			tile.position = Vector3(x * 4.0, 0.0, z * 4.0 + 1.0)
			set_dressing.add_child(tile)
	for x in [-1, 0, 1]:
		var wall := WALL_SCENE.instantiate() as Node3D
		wall.position = Vector3(x * 4.0, 0.0, -3.2)
		set_dressing.add_child(wall)
	var portrait := PORTRAIT_SCENE.instantiate() as Node3D
	portrait.position = Vector3(1.45, 1.2, -2.9)
	set_dressing.add_child(portrait)
	var plant := PLANT_SCENE.instantiate() as Node3D
	plant.position = Vector3(-1.9, 0.0, -2.2)
	set_dressing.add_child(plant)
	var candle := CANDELABRA_SCENE.instantiate() as Node3D
	candle.position = Vector3(2.35, 0.0, -2.3)
	set_dressing.add_child(candle)
	toon(set_dressing)

	var pedestal := PEDESTAL_SCENE.instantiate() as Node3D
	pedestal.name = "Pedestal"
	world.add_child(pedestal)
	toon(pedestal)

	_turntable = Node3D.new()
	_turntable.name = "Turntable"
	_turntable.position = Vector3(0.0, PEDESTAL_TOP, 0.0)
	world.add_child(_turntable)
	_motion = Node3D.new()
	_motion.name = "Motion"
	_turntable.add_child(_motion)
	rig = BlobRig.instantiate()
	if rig != null:
		rig.root.name = "Blob"
		_motion.add_child(rig.root)
		toon(rig.root)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 30.0
	camera.current = true
	world.add_child(camera)
	camera.look_at_from_position(Vector3(0.0, 1.95, 4.7), Vector3(0.0, 1.5, 0.0))
