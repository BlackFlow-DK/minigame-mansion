extends Node3D
## Camera dev sandbox: a copy of res://dev/sandbox.tscn with an ArenaCamera made current.
## User args after `--`:
##   --players=N       total players 1..8 (default 8: you + 7 bots)
##   --minigame=<id>   a MinigameRegistry id (default: the flat dev arena)
##   --scatter         place the players at fixed spread-out spots instead of the spawn ring
##   --mode=frame|follow|fixed
## Esc / Start (`pause`) quits.

const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")
const SCATTER: Array[Vector3] = [
	Vector3(-7.5, 0, -6.0), Vector3(6.5, 0, -7.5), Vector3(-6.0, 0, 6.5), Vector3(7.5, 0, 5.5),
	Vector3(0.5, 0, 0.0), Vector3(3.0, 0, -2.5), Vector3(-3.5, 0, 2.0), Vector3(-1.0, 0, 8.5)]

@onready var stage: Stage = $Stage
@onready var camera: ArenaCamera = $ArenaCamera


func _ready() -> void:
	var player_count := 8
	var minigame_id := &""
	var scatter := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--players="):
			player_count = clampi(arg.trim_prefix("--players=").to_int(), 1, Net.MAX_PLAYERS)
		elif arg.begins_with("--minigame="):
			minigame_id = StringName(arg.trim_prefix("--minigame="))
		elif arg == "--scatter":
			scatter = true
		elif arg.begins_with("--mode="):
			match arg.trim_prefix("--mode="):
				"follow": camera.mode = ArenaCamera.Mode.FOLLOW_LOCAL
				"fixed": camera.mode = ArenaCamera.Mode.FIXED
	Net.start_offline()
	for i in player_count - 1:
		Net.add_bot()
	var minigame: Minigame
	if minigame_id != &"":
		minigame = stage.load_minigame(minigame_id)
	else:
		minigame = stage.load_minigame_scene(DEV_ARENA)
	if minigame == null:
		return
	var players: Array[Player] = []
	players.assign(stage.players.values())
	if scatter:
		for i in players.size():
			players[i].place_at(Transform3D(Basis.IDENTITY, SCATTER[i % SCATTER.size()]))
	minigame._setup(players)
	for p in players:
		p.frozen = false
	minigame._start()
	camera.make_current()
	camera.snap()
	print("camera sandbox: '%s' with %d player(s)" % [minigame.title, players.size()])


func _physics_process(delta: float) -> void:
	if stage.minigame and not stage.minigame.is_finished():
		stage.minigame._host_tick(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		get_tree().quit()
