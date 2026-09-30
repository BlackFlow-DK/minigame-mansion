extends Node3D
## Dev sandbox (main scene for now): offline game, 1 human + bots on one arena, playing at once.
## User args after `--`:
##   --players=N       total players 1..8 (default 4: you + 3 bots)
##   --minigame=<id>   a MinigameRegistry id (default: the flat dev arena)
## Esc / Start (`pause`) quits.

const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")

@onready var stage: Stage = $Stage


func _ready() -> void:
	var player_count := 4
	var minigame_id := &""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--players="):
			player_count = clampi(arg.trim_prefix("--players=").to_int(), 1, Net.MAX_PLAYERS)
		elif arg.begins_with("--minigame="):
			minigame_id = StringName(arg.trim_prefix("--minigame="))
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
	minigame._setup(players)
	for p in players:
		p.frozen = false
	minigame._start()
	print("sandbox: '%s' with %d player(s)" % [minigame.title, players.size()])


func _physics_process(delta: float) -> void:
	if stage.minigame and not stage.minigame.is_finished():
		stage.minigame._host_tick(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		get_tree().quit()
