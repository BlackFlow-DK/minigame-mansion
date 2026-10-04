extends Node3D
## Micro-benchmark of the blob animation cost (VisualsComponent._process plus the emote
## component, when present), headless. Dev arena, 8 players (bots, running) + 20 extras.
## Each visuals node's own _process is switched off and called here inside a timer, so the
## numbers are pure animation CPU time (no rendering).
##   godot_console --headless --fixed-fps 60 --path game res://player/dev/bench_anim.tscn -- --frames=900
## Prints one line: `bench_anim: players=<us/blob/frame> extras=<us/blob/frame> nodes=<a>-><b>`.

const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")

@onready var stage: Stage = $Stage

var _frames: int = 900
var _warmup: int = 120
var _frame: int = 0
var _vis_players: Array[Node] = []
var _vis_extras: Array[Node] = []
var _us_players: int = 0
var _us_extras: int = 0
var _nodes_start: int = 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="):
			_frames = int(arg.trim_prefix("--frames="))
	Net.start_offline()
	for i in 7:
		Net.add_bot()
	var minigame := stage.load_minigame_scene(DEV_ARENA)
	var players: Array[Player] = []
	players.assign(stage.players.values())
	minigame._setup(players)
	for p in players:
		p.frozen = false
	minigame._start()
	var xs := stage.spawn_extras(20)
	for x in xs:
		BotBrain.of(x).configure_extra(&"wander", x.slot, minigame.global_position)
	for p in players:
		_vis_players.append(p.get_component(&"visuals"))
	for x in xs:
		_vis_extras.append(x.get_component(&"visuals"))
	for v in _vis_players + _vis_extras:
		v.set_process(false)


func _physics_process(delta: float) -> void:
	if stage.minigame and not stage.minigame.is_finished():
		stage.minigame._host_tick(delta)


func _process(delta: float) -> void:
	_frame += 1
	var t0 := Time.get_ticks_usec()
	for v in _vis_players:
		if is_instance_valid(v):
			v._process(delta)
	var t1 := Time.get_ticks_usec()
	for v in _vis_extras:
		if is_instance_valid(v):
			v._process(delta)
	var t2 := Time.get_ticks_usec()
	if _frame == _warmup:
		_nodes_start = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	if _frame > _warmup:
		_us_players += t1 - t0
		_us_extras += t2 - t1
	if _frame >= _warmup + _frames:
		var n := float(_frames)
		print("bench_anim: players=%.1f extras=%.1f us/blob/frame nodes=%d->%d" % [
			_us_players / n / maxf(_vis_players.size(), 1), _us_extras / n / maxf(_vis_extras.size(), 1),
			_nodes_start, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
		get_tree().quit()
