extends Node
## Dev scene: the Training Room standalone (offline, you + the dummies), for screenshots and
## trying the course without the menus. User args after `--`:
##   --station=N   start at station N (earlier ones done, gates open)
##   --finish      reach the finish at once (the "You're ready!" panel)
##   --pad         show the gamepad glyphs first
##   --hold        do not let the player move (screenshots: the camera stays put)

const STAGE_SCENE := "res://stage/stage.tscn"
const ROOM_SCENE := "res://tutorial/training_room.tscn"

var stage: Stage
var room: TrainingRoom
var _args: Dictionary = {}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else ""
	Net.start_offline()
	for i in TrainingRoom.DUMMY_COUNT:
		Net.add_bot()
	stage = (load(STAGE_SCENE) as PackedScene).instantiate() as Stage
	add_child(stage)
	room = stage.load_minigame_scene(load(ROOM_SCENE) as PackedScene) as TrainingRoom
	var ps: Array[Player] = []
	ps.assign(stage.players.values())
	room._setup(ps)
	for p in ps:
		p.frozen = false
	if _args.has("hold") and room.human:
		(room.human.get_component(&"controller") as ControllerComponent).scripted = true
	room._start()
	room.exit_requested.connect(func(_offline: bool) -> void: get_tree().quit())
	if _args.has("pad"):
		room.ui.set_device(TrainingUI.Device.GAMEPAD)
	if _args.has("station"):
		room.jump_to_station(int(_args["station"]))
	if _args.has("finish"):
		room.jump_to_station(TrainingRoom.Id.FINISH)
		room.human.place_at(Transform3D(Basis(Vector3.UP, PI), room.stations[TrainingRoom.Id.FINISH].target() + Vector3.UP * 0.05))


func _physics_process(delta: float) -> void:
	if room and not room.is_finished():
		room._host_tick(delta)
