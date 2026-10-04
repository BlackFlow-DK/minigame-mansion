extends Node3D
## Dev scene for NPC extras: the offline sandbox (1 human + bots, playing at once) plus extras.
##   godot --path game res://stage/dev/extras_sandbox.tscn -- --players=8 --extras=20
##     [--minigame=<id>] [--extras-mode=wander|dance|idle] [--extras-camera]
##     [--perf-seconds=10 --perf-warmup=3 --perf-out=<abs .csv> --perf-label=x --quality=low --fps=0]
## `--extras-camera` frames players and extras with an ArenaCamera (include_extras).
## Any `--perf-*` arg attaches the PerfProbe (game/tools/perf), which measures and quits.
## Esc / Start (`pause`) quits.

const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")
const CAMERA_SCENE: PackedScene = preload("res://camera/arena_camera.tscn")
const PROBE_PATH := "res://tools/perf/perf_probe.gd"

@onready var stage: Stage = $Stage


func _ready() -> void:
	var cfg := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			var kv := arg.trim_prefix("--").split("=", true, 1)
			cfg[kv[0]] = kv[1] if kv.size() > 1 else ""
	var player_count := clampi(int(cfg.get("players", "4")), 1, Net.MAX_PLAYERS)
	var extra_count := clampi(int(cfg.get("extras", "20")), 0, Stage.MAX_EXTRAS)
	var mode := StringName(cfg.get("extras-mode", "wander"))
	var minigame_id := StringName(cfg.get("minigame", ""))
	Net.start_offline()
	for i in player_count - 1:
		Net.add_bot()
	var minigame: Minigame = stage.load_minigame(minigame_id) if minigame_id != &"" else stage.load_minigame_scene(DEV_ARENA)
	if minigame == null:
		return
	var players: Array[Player] = []
	players.assign(stage.players.values())
	minigame._setup(players)
	for p in players:
		p.frozen = false
	minigame._start()
	var xs := stage.spawn_extras(extra_count)
	for x in xs:
		BotBrain.of(x).configure_extra(mode, x.slot, minigame.global_position)
	if cfg.has("extras-camera"):
		var cam := CAMERA_SCENE.instantiate() as ArenaCamera
		cam.include_extras = true
		add_child(cam)
		cam.make_current()
		cam.snap()
	if cfg.keys().any(func(k: String) -> bool: return k.begins_with("perf-")):
		var probe: Node = (load(PROBE_PATH) as Script).new()
		probe.name = "PerfProbe"
		cfg["perf-target"] = "extras_sandbox"
		cfg["minigame"] = "%s+%dx" % [minigame_id if minigame_id != &"" else &"dev_arena", xs.size()]
		probe.set(&"config", cfg)
		get_tree().root.add_child.call_deferred(probe)
	print("extras_sandbox: '%s' with %d player(s) and %d %s extra(s)" % [minigame.title, players.size(), xs.size(), mode])


func _physics_process(delta: float) -> void:
	if stage.minigame and not stage.minigame.is_finished():
		stage.minigame._host_tick(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		get_tree().quit()
