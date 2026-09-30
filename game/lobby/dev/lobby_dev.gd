extends Node3D
## Dev view of the lobby hall: offline, you + bots, like the sandbox (the sandbox only takes
## registry ids). User args after `--`:
##   --players=N        total players 1..8 (default 8: you + 7 bots)
##   --scatter          start the players around the hall's toys instead of on the spawn arc
##   --warmup=S         run the first S seconds at --timescale=X (default 4) so bots spread out
##   --overview         hold a fixed camera over the whole hall instead of framing the players
## Esc / Start (`pause`) quits.

const LOBBY: PackedScene = preload("res://lobby/lobby.tscn")
const SCATTER: Array[Vector3] = [
	Vector3(-5.9, 0.6, -3.0), Vector3(0.4, 2.0, -7.4), Vector3(8.0, 0.0, -3.4), Vector3(-8.2, 0.0, -1.8),
	Vector3(3.0, 0.0, 4.0), Vector3(-1.0, 1.0, -4.5), Vector3(10.3, 0.6, -1.0), Vector3(-6.5, 0.0, 6.0),
]

@onready var stage: Stage = $Stage


func _ready() -> void:
	var player_count := 8
	var scatter := false
	var warmup := 0.0
	var timescale := 4.0
	var overview := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--players="):
			player_count = clampi(arg.trim_prefix("--players=").to_int(), 1, Net.MAX_PLAYERS)
		elif arg == "--scatter":
			scatter = true
		elif arg.begins_with("--warmup="):
			warmup = arg.trim_prefix("--warmup=").to_float()
		elif arg.begins_with("--timescale="):
			timescale = arg.trim_prefix("--timescale=").to_float()
		elif arg == "--overview":
			overview = true
	Net.start_offline()
	for i in player_count - 1:
		Net.add_bot()
	var lobby := stage.load_minigame_scene(LOBBY)
	if lobby == null:
		return
	var players: Array[Player] = []
	players.assign(stage.players.values())
	lobby._setup(players)
	for p in players:
		p.frozen = false
	lobby._start()
	if scatter:
		for i in players.size():
			players[i].place_at(Transform3D(Basis(), SCATTER[i % SCATTER.size()]))
	if overview:
		var cam := lobby.get_node(^"Camera") as ArenaCamera
		cam.mode = ArenaCamera.Mode.FIXED
	if warmup > 0.0:
		Engine.time_scale = timescale
		get_tree().create_timer(warmup / maxf(timescale, 0.01), true, false, true).timeout.connect(func() -> void: Engine.time_scale = 1.0)
	print("lobby_dev: %d player(s)" % players.size())


func _physics_process(delta: float) -> void:
	if stage.minigame and not stage.minigame.is_finished():
		stage.minigame._host_tick(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		get_tree().quit()
