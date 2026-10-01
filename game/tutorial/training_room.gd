class_name TrainingRoom
extends Minigame
## The Training Room: an offline, solo tutorial course through the mansion garden. A Minigame
## that never finishes on its own (like the lobby): MainApp loads it through the Stage with the
## local human plus DUMMY_COUNT bots (the dummies), runs `_setup` / `_start`, ticks
## `_host_tick`, and returns to the title when the room asks with `exit_requested`.
##
## The course runs down -Z: nine stations (res://tutorial/stations/), each a stretch of lawn
## with one task, and a gate after each one that opens when its task is done:
##   Move -> Jump -> Shove -> Getting shoved -> Lava tiles -> Shrinking ring -> Hot potato
##   -> Coin rain -> Finish
## Falling off the course puts the player back at the current station's start (and resets
## that station). The dummies are bots whose controllers are scripted: their intent is cleared
## every tick and only the station that owns them steers them. The UI (TrainingUI) shows a card
## per station, the checklist, the Esc hint and the finish panel.
##
## Dev: `res://tutorial/dev/training_dev.tscn` runs the room standalone (screenshots).

## A station became the current one.
signal station_started(index: int)
## A station's task was done (its gate opens).
signal station_completed(index: int)
## The finish mat was reached, `seconds` after the course started.
signal course_finished(seconds: float)
## The player asked to leave: back to the title, or straight into an offline game.
signal exit_requested(play_offline: bool)
## Live progress text of the current station changed.
signal progress_changed(index: int, text: String)

enum Id { MOVE, JUMP, SHOVE, SHOVED, LAVA, RING, POTATO, COINS, FINISH }

const STATION_SCRIPTS: Array[Script] = [
	preload("res://tutorial/stations/station_move.gd"),
	preload("res://tutorial/stations/station_jump.gd"),
	preload("res://tutorial/stations/station_shove.gd"),
	preload("res://tutorial/stations/station_shoved.gd"),
	preload("res://tutorial/stations/station_lava.gd"),
	preload("res://tutorial/stations/station_ring.gd"),
	preload("res://tutorial/stations/station_potato.gd"),
	preload("res://tutorial/stations/station_coins.gd"),
	preload("res://tutorial/stations/station_finish.gd"),
]
## Bots the room needs (MainApp adds them before loading it).
const DUMMY_COUNT := 4
const DUMMY_NAMES: Array[String] = ["Dummy", "Shover", "Bomber", "Catcher"]
## Below this the player fell off the course; dummies below DUMMY_FALL_Y go back to their post.
const FALL_Y := -0.5
const DUMMY_FALL_Y := -3.0
## Mansion Coins for finishing the course (once per profile; Progression owns the rule).
const REWARD_REASON := &"tutorial"
const REWARD := 20

const ENV := "res://assets/models/env/"
const HALF_W := TrainingStation.HALF_W
## Collision faces of the course's sides.
const SIDE_X := 4.3
const START_Z := 3.0

## Read by the bot brain: the dummies never chase or shove on their own.
@export_range(0.0, 1.0) var bot_aggression_scale: float = 0.0

var stations: Array[TrainingStation] = []
## gates[i] closes the end of station i (the last station has none).
var gates: Array[TrainingGate] = []
## Index of the current station; stations.size() once the course is finished.
var current: int = 0
var human: Player = null
var dummies: Array[Player] = []
## Seconds since `_start` (stops at the finish).
var elapsed: float = 0.0
var finish_time: float = -1.0
var falls: int = 0
## Mansion Coins the finish gave (0 when this profile already had the reward).
var reward_given: int = 0
## The camera looks at the player from a fixed angle, aimed a little behind the blob so it sits
## above the middle of the screen, clear of the card at the bottom.
const CAMERA_LEAD := Vector3(0.0, 0.5, 1.3)
const CAMERA_X := 1.2

## Total length of the course (m).
var course_length: float = 0.0
var camera: ArenaCamera = null
var beacon: TrainingBeacon = null
var ui: TrainingUI = null

var _posts: Array[Transform3D] = []
var _post_station: Array[int] = []
var _post_dummies: Array[Player] = []
var _started: bool = false


func _ready() -> void:
	camera = get_node_or_null(^"ArenaCamera") as ArenaCamera
	var z := 0.0
	for i in STATION_SCRIPTS.size():
		var st := STATION_SCRIPTS[i].new() as TrainingStation
		st.name = "Station%d" % i
		st.room = self
		st.position = Vector3(0.0, 0.0, z)
		add_child(st)
		st.build()
		st.completed.connect(_on_station_completed.bind(i))
		st.progress_changed.connect(func(text: String) -> void: progress_changed.emit(i, text))
		stations.append(st)
		for post in st.dummy_posts():
			_posts.append(post)
			_post_station.append(i)
		if i < STATION_SCRIPTS.size() - 1:
			var gate := TrainingGate.new()
			gate.name = "Gate%d" % i
			gate.position = Vector3(0.0, 0.0, z + st.gate_z())
			add_child(gate)
			gates.append(gate)
		z -= st.length
	course_length = -z
	_build_surroundings()
	_place_spawns()
	beacon = TrainingBeacon.new()
	beacon.name = "Beacon"
	add_child(beacon)
	beacon.point_at(stations[0].target(), true)
	ui = TrainingUI.new()
	ui.name = "TrainingUI"
	ui.room = self
	add_child(ui)


# --- Minigame ------------------------------------------------------------------------------

func _setup(p_players: Array[Player]) -> void:
	human = null
	dummies.clear()
	var local := Net.local_slot()
	for p in p_players:
		if not is_instance_valid(p):
			continue
		if human == null and not p.is_bot and (local < 0 or p.slot == local):
			human = p
		elif p.is_bot:
			dummies.append(p)
	dummies.sort_custom(func(a: Player, b: Player) -> bool: return a.slot < b.slot)
	_post_dummies.clear()
	for k in _posts.size():
		var d: Player = dummies[k] if k < dummies.size() else null
		_post_dummies.append(d)
		var st := stations[_post_station[k]]
		st.dummies.append(d)
		if d:
			d.display_name = DUMMY_NAMES[k] if k < DUMMY_NAMES.size() else "Dummy"
			var controller := d.get_component(&"controller") as ControllerComponent
			if controller:
				controller.scripted = true
			d.place_at(_posts[k])
	if dummies.size() < _posts.size():
		push_warning("TrainingRoom: %d dummies for %d posts" % [dummies.size(), _posts.size()])
	for st in stations:
		st.player = human
	if ui:
		ui.bind(human)


func _start() -> void:
	if _started:
		return
	_started = true
	_begin(0)


func _host_tick(delta: float) -> void:
	if not _started:
		return
	if finish_time < 0.0:
		elapsed += delta
	for d in dummies:
		if TrainingStation.live(d):
			d.intent.clear()
	_check_falls()
	for i in stations.size():
		if i == current:
			stations[i].tick(delta)
		else:
			stations[i].idle_tick(delta)


## Bots never roam here: a dummy's goal is where it stands.
func get_bot_goal(player: Player) -> Vector3:
	return player.global_position if player else Vector3.ZERO


func is_safe(pos: Vector3) -> bool:
	return pos.y > FALL_Y


# --- Public ------------------------------------------------------------------------------------

## The player wants out (finish panel, or the pause menu's Skip through MainApp).
func request_exit(play_offline: bool = false) -> void:
	exit_requested.emit(play_offline)


func is_station_done(index: int) -> bool:
	return index >= 0 and index < stations.size() and stations[index].done


func is_course_finished() -> bool:
	return finish_time >= 0.0


## Dev / screenshots: completes every station before `index` at once (gates open, no
## animation) and makes `index` current, with the player at its start.
func jump_to_station(index: int) -> void:
	index = clampi(index, 0, stations.size() - 1)
	for i in index:
		var st := stations[i]
		st.active = false
		st.done = true
		if i < gates.size():
			gates[i].open(false)
		station_completed.emit(i)
	if human:
		human.place_at(stations[index].entry())
	_begin(index)
	if beacon:
		beacon.point_at(stations[index].target(), true)
	_aim_camera(true)


# --- Flow ----------------------------------------------------------------------------------------

func _begin(index: int) -> void:
	current = index
	var st := stations[index]
	st.player = human
	st.active = true
	st.begin()
	station_started.emit(index)


func _on_station_completed(index: int) -> void:
	if index != current:
		return
	stations[index].active = false
	Sfx.play(&"join_chime")
	if index < gates.size():
		gates[index].open()
	station_completed.emit(index)
	if index + 1 < stations.size():
		_begin(index + 1)
	else:
		current = stations.size()
		finish_time = elapsed
		var progression := get_node_or_null(^"/root/Progression")
		if progression and progression.has_method(&"award"):
			reward_given = int(progression.call(&"award", REWARD_REASON, REWARD))
		course_finished.emit(finish_time)


func _check_falls() -> void:
	if TrainingStation.live(human) and human.global_position.y < FALL_Y:
		var st := stations[mini(current, stations.size() - 1)]
		falls += 1
		var at := human.global_position
		Fx.play(st.fall_effect, Vector3(at.x, maxf(at.y, -0.9), at.z))
		Sfx.play(&"lava_sizzle" if st.fall_effect == &"splash_lava" else &"eliminated_pop", at)
		human.respawn_at(st.entry())
		st.reset()
	for k in _post_dummies.size():
		var d := _post_dummies[k]
		if TrainingStation.live(d) and d.global_position.y < DUMMY_FALL_Y:
			d.respawn_at(_posts[k])


func _process(_delta: float) -> void:
	_aim_camera(false)
	if beacon == null:
		return
	var showing := current < stations.size() and stations[current].show_beacon()
	beacon.visible = showing
	if showing:
		beacon.point_at(stations[current].target())


func _aim_camera(snap: bool) -> void:
	if camera == null or not TrainingStation.live(human):
		return
	var at := human.global_position + CAMERA_LEAD
	at.x = clampf(at.x, -CAMERA_X, CAMERA_X)
	at.y = clampf(at.y, 0.5, 1.6)
	camera.fixed_focus = at
	if snap:
		camera.snap()


# --- Building ------------------------------------------------------------------------------------

func _place_spawns() -> void:
	var spawns := get_node_or_null(^"Spawns")
	if spawns == null:
		return
	var points: Array[Transform3D] = [stations[0].call(&"spawn") as Transform3D]
	points.append_array(_posts)
	var finish_z := -course_length + 3.5
	var i := 0
	for child in spawns.get_children():
		var m := child as Marker3D
		if m == null:
			continue
		if i < points.size():
			m.transform = points[i]
		else:
			# Spare markers (more bots than dummies): spectators by the finish.
			m.transform = Transform3D(Basis(), Vector3(-3.0 + 1.2 * (i - points.size()), 0.05, finish_z))
		i += 1


## Side walls (the mansion on the left, a hedge on the right), the low hedge behind the
## start, the mansion's garden door at the end, lawns outside, and the invisible barriers.
func _build_surroundings() -> void:
	var deco := Node3D.new()
	deco.name = "Surroundings"
	add_child(deco)
	var end_z := -course_length
	# Mansion wall on the left, 4 m pieces from the start to past the end.
	var pieces: Array[String] = ["wall_window", "wall_4m", "wall_window", "wall_4m", "wall_4m"]
	var n := int(ceil((course_length + START_Z + 1.0) / 4.0))
	for k in n:
		_place(deco, pieces[k % pieces.size()], Vector3(-HALF_W - 0.45, 0.0, START_Z - 2.0 - 4.0 * k), 90.0)
	# End: the mansion's back wall with its garden door.
	for x: float in [-4.0, 0.0, 4.0]:
		_place(deco, "wall_door" if x == 0.0 else "wall_window", Vector3(x, 0.0, end_z - 1.4))
	# Hedge on the right with topiary balls, and a low hedge behind the start.
	var hedge := Look.toon_material(Color("#3f8a47"), 0.8)
	var hedge_light := Look.toon_material(Color("#4f9d52"), 0.8)
	_mesh_box(deco, Vector3(HALF_W + 0.75, 0.6, (START_Z + end_z) * 0.5), Vector3(0.9, 1.2, course_length + START_Z + 1.0), hedge)
	_mesh_box(deco, Vector3(0.0, 0.5, START_Z + 0.4), Vector3(2.0 * HALF_W + 2.4, 1.0, 0.9), hedge)
	var z := START_Z - 3.0
	var k2 := 0
	while z > end_z + 2.0:
		var ball := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.55
		sm.height = 1.1
		ball.mesh = sm
		ball.material_override = hedge_light
		ball.position = Vector3(HALF_W + 0.75, 1.55, z)
		deco.add_child(ball)
		if k2 % 2 == 1:
			_place(deco, "potted_plant", Vector3(HALF_W + 1.7, 0.0, z - 3.0))
		z -= 7.0
		k2 += 1
	# Lawn outside the course (never under it: the ponds must show).
	var lawn := Look.toon_material(Color("#6fae55"), 0.9, false)
	_mesh_box(deco, Vector3(HALF_W + 20.6, -0.06, (START_Z + end_z) * 0.5), Vector3(40.0, 0.1, course_length + 40.0), lawn)
	_mesh_box(deco, Vector3(0.0, -0.06, START_Z + 10.0), Vector3(80.0, 0.1, 16.0), lawn)
	var patio := Look.toon_material(Color("#9a8f86"), 0.9, false)
	_mesh_box(deco, Vector3(-HALF_W - 20.6, -0.06, (START_Z + end_z) * 0.5), Vector3(40.0, 0.1, course_length + 40.0), patio)

	var body := StaticBody3D.new()
	body.name = "Barriers"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var h := 8.0
	var mid := (START_Z + end_z) * 0.5
	var span := course_length + START_Z + 2.0
	_shape(body, Vector3(-SIDE_X - 0.25, h * 0.5, mid), Vector3(0.5, h, span))
	_shape(body, Vector3(SIDE_X + 0.25, h * 0.5, mid), Vector3(0.5, h, span))
	_shape(body, Vector3(0.0, h * 0.5, START_Z + 0.25), Vector3(2.0 * SIDE_X + 1.0, h, 0.5))
	_shape(body, Vector3(0.0, h * 0.5, end_z - 0.75), Vector3(2.0 * SIDE_X + 1.0, h, 0.5))


func _place(parent: Node3D, piece: String, pos: Vector3, yaw_deg: float = 0.0) -> Node3D:
	var scene := load(ENV + piece + ".glb") as PackedScene
	if scene == null:
		push_warning("TrainingRoom: missing kit piece %s" % piece)
		return null
	var node := scene.instantiate() as Node3D
	node.position = pos
	node.rotation_degrees.y = yaw_deg
	parent.add_child(node)
	Look.apply_toon(node)
	return node


func _mesh_box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _shape(body: StaticBody3D, pos: Vector3, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position = pos
	body.add_child(cs)
