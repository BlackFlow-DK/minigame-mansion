extends TrainingStation
## Station 5, Floor is lava taster: a 3x3 patch of the real hex tiles over a lava pit. A tile
## cracks shortly after you stand on it and drops soon after; keep moving to the far side.
## Tiles come back after a fall and a little after the station is done.

enum TileState { SOLID, CRACKING, FALLEN }

const TILE_SCENE := "res://assets/models/props/hex_tile.glb"
const TILE_CRACKED_SCENE := "res://assets/models/props/hex_tile_cracked.glb"
const TILE_RADIUS := 1.0
const TILE_THICKNESS := 0.4
const TILE_TOP := 0.03
const COL_STEP := 1.59
const ROW_STEP := 1.836
const HALF_ROW := 0.918
## Near edge of the pit (local z); the far edge is computed from the tiles.
const PIT_NEAR := -2.5
## Seconds stood on before a tile cracks, and from cracking to falling.
const TOUCH_TIME := 0.2
const CRACK_DELAY := 0.75
const FALL_TIME := 1.2
const RESTORE_AFTER := 2.0

## Local centres of the 9 tiles.
var tile_centres: Array[Vector3] = []
var tile_states: Array[int] = []
## Local z where the exit lawn starts.
var pit_far: float = 0.0

var _bodies: Array[StaticBody3D] = []
var _visuals: Array[Node3D] = []
var _solid: Array[Node3D] = []
var _cracked: Array[Node3D] = []
var _touch: PackedFloat32Array = []
var _timer: PackedFloat32Array = []
var _restore_left: float = -1.0


func _init() -> void:
	checklist_name = "Lava tiles"
	card_title = "Floor is lava"
	card_line = "Tiles crack under you. Keep moving to the far side!"
	card_tip = "A cracked tile glows, wobbles, then drops into the lava."
	glyphs = [&"move", &"jump"]
	fall_effect = &"splash_lava"
	length = 11.0


func build() -> void:
	# Side columns sit a half row further down the course than the middle one.
	for c in 3:
		var x := (c - 1) * COL_STEP
		var shift := HALF_ROW if c == 1 else 0.0
		for r in 3:
			tile_centres.append(Vector3(x, TILE_TOP, PIT_NEAR - TILE_RADIUS * 0.866 - r * ROW_STEP + shift))
	pit_far = PIT_NEAR + HALF_ROW - TILE_RADIUS * 0.866 * 2.0 - 2.0 * ROW_STEP
	add_ground(0.0, PIT_NEAR)
	add_ground(pit_far, -length)
	add_liquid(PIT_NEAR, pit_far, -0.9, true)
	var shape := _tile_shape()
	var solid_scene := load(TILE_SCENE) as PackedScene
	var cracked_scene := load(TILE_CRACKED_SCENE) as PackedScene
	for i in tile_centres.size():
		var body := StaticBody3D.new()
		body.name = "Tile%d" % i
		body.collision_layer = 1
		body.collision_mask = 0
		body.position = tile_centres[i]
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		var visual := Node3D.new()
		visual.name = "Visual"
		body.add_child(visual)
		var yaw := deg_to_rad(60.0 * (i % 3))
		var solid := solid_scene.instantiate() as Node3D if solid_scene else Node3D.new()
		solid.rotation.y = yaw
		visual.add_child(solid)
		Look.apply_toon(solid)
		var cracked := cracked_scene.instantiate() as Node3D if cracked_scene else Node3D.new()
		cracked.rotation.y = yaw
		cracked.visible = false
		visual.add_child(cracked)
		Look.apply_toon(cracked)
		add_child(body)
		_bodies.append(body)
		_visuals.append(visual)
		_solid.append(solid)
		_cracked.append(cracked)
	tile_states.resize(tile_centres.size())
	tile_states.fill(TileState.SOLID)
	_touch.resize(tile_centres.size())
	_timer.resize(tile_centres.size())
	# Rocks in the lava at the sides.
	for p: Vector3 in [Vector3(-3.4, -0.85, PIT_NEAR - 1.2), Vector3(3.3, -0.85, PIT_NEAR - 3.2)]:
		add_model("res://assets/models/props/lava_rock_a.glb", p, 30.0, 0.8)


func target() -> Vector3:
	return to_global(Vector3(0.0, 0.0, pit_far - 1.6))


func tick(delta: float) -> void:
	if not live(player):
		return
	var local := to_local(player.global_position)
	if player.is_on_floor():
		for i in tile_centres.size():
			if tile_states[i] != TileState.SOLID:
				continue
			var on := Vector2(local.x - tile_centres[i].x, local.z - tile_centres[i].z).length() < TILE_RADIUS * 0.95 \
					and absf(local.y - TILE_TOP) < 0.3
			_touch[i] = _touch[i] + delta if on else 0.0
			if _touch[i] >= TOUCH_TIME:
				_crack(i)
	if local.z < pit_far - 0.6 and local.y > -0.3 and player.is_on_floor():
		complete()


## Host and presentation (offline): cracking tiles fall; fallen ones come back after `done`.
func _physics_process(delta: float) -> void:
	for i in tile_states.size():
		if tile_states[i] == TileState.CRACKING:
			_timer[i] += delta
			if _timer[i] >= CRACK_DELAY:
				_fall(i)
		elif tile_states[i] == TileState.FALLEN:
			_timer[i] += delta
	if done and _restore_left < 0.0:
		_restore_left = RESTORE_AFTER
	if _restore_left > 0.0:
		_restore_left -= delta
		if _restore_left <= 0.0:
			_restore_all()


func _process(_delta: float) -> void:
	for i in _visuals.size():
		var v := _visuals[i]
		match tile_states[i]:
			TileState.CRACKING:
				var t := _timer[i]
				var k := clampf(t / CRACK_DELAY, 0.0, 1.0)
				var amp := 0.02 + 0.07 * k
				v.rotation = Vector3(sin(t * 31.0 + i) * amp, 0.0, cos(t * 27.0 + i) * amp)
				v.position.y = -0.04 * k
			TileState.FALLEN:
				var t := _timer[i]
				v.position.y = -0.5 * 9.0 * t * t
				v.rotation.x = t * 0.6
				v.visible = t < FALL_TIME
			_:
				v.rotation = Vector3.ZERO
				v.position = Vector3.ZERO
				v.visible = true


func reset() -> void:
	_restore_all()


func is_tile_solid(i: int) -> bool:
	return tile_states[i] != TileState.FALLEN


func _crack(i: int) -> void:
	tile_states[i] = TileState.CRACKING
	_timer[i] = 0.0
	_solid[i].visible = false
	_cracked[i].visible = true
	var at := to_global(tile_centres[i])
	Sfx.play(&"platform_crack", at)
	Fx.play(&"dust_puff", at + Vector3.UP * 0.05, Color(0.55, 0.45, 0.4))


func _fall(i: int) -> void:
	tile_states[i] = TileState.FALLEN
	_timer[i] = 0.0
	_bodies[i].collision_layer = 0
	(_bodies[i].get_child(0) as CollisionShape3D).set_deferred(&"disabled", true)
	Sfx.play(&"platform_fall", to_global(tile_centres[i]))


func _restore_all() -> void:
	_restore_left = -1.0 if not done else 0.0
	for i in tile_states.size():
		tile_states[i] = TileState.SOLID
		_touch[i] = 0.0
		_timer[i] = 0.0
		_bodies[i].collision_layer = 1
		(_bodies[i].get_child(0) as CollisionShape3D).set_deferred(&"disabled", false)
		_solid[i].visible = true
		_cracked[i].visible = false


## Hexagonal prism, flat side toward +-Z, top face at y = 0.
func _tile_shape() -> ConvexPolygonShape3D:
	var pts := PackedVector3Array()
	for k in 6:
		var ang := deg_to_rad(60.0 * k)
		var v := Vector3(cos(ang) * TILE_RADIUS, 0.0, sin(ang) * TILE_RADIUS)
		pts.append(v)
		pts.append(v + Vector3.DOWN * TILE_THICKNESS)
	var s := ConvexPolygonShape3D.new()
	s.points = pts
	return s
