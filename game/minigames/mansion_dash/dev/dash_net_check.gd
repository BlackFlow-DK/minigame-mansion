extends Node
## Multi-process Mansion Dash check actor, driven by run_dash_net_check.ps1 (same pattern as
## cannon_alley/dev/). One headless host and two headless clients on this PC:
##   godot_console --headless --path game res://minigames/mansion_dash/dev/dash_net_check.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC]
## Every peer's own human player is driven by a BotBrain (so clients really run the course, get
## hit, fall in and cross the line); bots run on the host as usual. Every peer records, when its
## round clock passes each SAMPLE_TIMES entry, every hazard's position at exactly that round time
## computed from its own layout (hammer heads, rafts, sweeper and turntable angles, live logs),
## and the host-decided events in arrival order (checkpoints, falls, finishes). Writes
## <dir>/<name>.json ten times a second and runs new lines of <dir>/<name>.cmd:
##   bot        host: Net.add_bot()
##   session    host: a 1-round Session of mansion_dash
##   quit

const SCENE_PATH := "res://minigames/mansion_dash/mansion_dash.tscn"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"
const SAMPLE_TIMES: Array[float] = [2.0, 5.0, 8.0, 11.0, 14.0, 17.0, 20.0, 23.0, 26.0, 29.0, 32.0, 36.0, 40.0, 45.0, 50.0]

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 170.0
var _events: Array[String] = []
var _ranking: Array = []
var _samples: Dictionary = {}
var _next_sample: int = 0
var _seed: int = -1
var _checkpoints: Array[String] = []
var _finishes: Array[String] = []
var _falls: Array[String] = []
var _local_hits: int = 0
var _layout: String = ""
var _brain: Node = null
var _minigame: MansionDash = null
var _cmds_done: int = 0
var _poll: float = 0.0
var _write_accum: float = 0.0
var _age: float = 0.0
var _quitting: bool = false

@onready var stage: Stage = $Stage


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"role": _role = v
			"name": _name = v
			"dir": _dir = v
			"join": _join = v
			"life": _life = float(v)
	stage.players_spawned.connect(_on_players_spawned)
	Net.server_closed.connect(func() -> void: _event("server_closed"); _quit())
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r); _quit())
	Session.round_started.connect(func() -> void: _event("round_started"))
	Session.round_finished.connect(_on_round_finished)
	Net.set_local_profile(_name, {})
	Session.scene_override = load(SCENE_PATH) as PackedScene
	if _role == "host":
		var err := Net.host_game("Dash Check")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	var m := stage.minigame as MansionDash
	if m and not m.has_meta(&"net_check"):
		m.set_meta(&"net_check", true)
		_minigame = m
		m.round_began.connect(func(seed_value: int, _t0: float) -> void:
			_seed = seed_value
			_event("round_began"))
		m.checkpoint_reached.connect(func(slot: int, index: int) -> void: _checkpoints.append("%d:%d" % [slot, index]))
		m.player_finished.connect(func(slot: int, place: int, time: float) -> void: _finishes.append("%d:%d@%.3f" % [slot, place, time]))
		m.fell.connect(func(slot: int) -> void: _falls.append(str(slot)))
		m.local_hit.connect(func(_slot: int, _kind: StringName) -> void: _local_hits += 1)
		m.spawn_layout_applied.connect(func(slots: PackedInt32Array) -> void: _layout = str(Array(slots)))
	for v: Variant in spawned:
		var p := v as Player
		if p.slot != Net.local_slot():
			continue
		var c := p.get_component(&"controller") as ControllerComponent
		if c:
			c.scripted = true
		if _brain and is_instance_valid(_brain):
			_brain.queue_free()
		_brain = (load(BOT_BRAIN_PATH) as GDScript).new() as Node
		_brain.set(&"player", p)
		_brain.name = "LocalBrain"
		add_child(_brain)
		_brain.call(&"configure", _name.hash() & 0xFFFF)


func _on_round_finished(ranking: Array[int], _points: Dictionary) -> void:
	_ranking = ranking.duplicate()
	_event("round_finished")


func _physics_process(delta: float) -> void:
	var me := stage.get_player(Net.local_slot())
	if me and _brain and is_instance_valid(_brain):
		_brain.call(&"fill_intent", me.intent, delta)
	var m := _minigame
	if m == null or not is_instance_valid(m) or _seed < 0:
		return
	while _next_sample < SAMPLE_TIMES.size() and m.round_time() >= SAMPLE_TIMES[_next_sample]:
		var at := SAMPLE_TIMES[_next_sample]
		_samples["%.1f" % at] = _sample(m.layout, at)
		_next_sample += 1


## Every hazard at round time `at`, from this peer's own layout.
static func _sample(l: DashCourse.Layout, at: float) -> String:
	var parts: Array[String] = []
	for k in DashCourse.HAMMER_Z.size():
		var h := DashCourse.hammer_head(l, k, at)
		parts.append("h%d:%.3f,%.3f" % [k, h.x, h.y])
	for r in DashCourse.ROW_Z.size():
		for i in 2:
			parts.append("r%d%d:%.3f" % [r, i, DashCourse.platform_x(l, r, i, at)])
	parts.append("sw:%.4f" % DashCourse.sweep_angle(l, at))
	parts.append("disc:%.4f" % DashCourse.disc_angle(l, at))
	var w := DashCourse.log_window(l, at, at)
	for i in range(w.x, w.y):
		if DashCourse.log_active(l, i, at):
			var p := DashCourse.log_position(l, i, at)
			parts.append("log%d:%.3f,%.3f,%.3f" % [i, p.x, p.y, p.z])
	return " ".join(parts)


func _process(delta: float) -> void:
	_age += delta
	if _age > _life and not _quitting:
		_event("life_expired")
		_quit()
		return
	_write_accum += delta
	if _write_accum >= 0.1:
		_write_accum = 0.0
		_write()
	_poll += delta
	if _poll < 0.1:
		return
	_poll = 0.0
	var path := _dir.path_join(_name + ".cmd")
	if not FileAccess.file_exists(path):
		return
	var lines := FileAccess.get_file_as_string(path).split("\n")
	lines.remove_at(lines.size() - 1)
	while _cmds_done < lines.size() and not _quitting:
		_run(lines[_cmds_done].strip_edges())
		_cmds_done += 1
		_write()


func _run(cmd: String) -> void:
	var parts := cmd.split(" ", false)
	if parts.is_empty():
		return
	_event("cmd:" + cmd)
	match parts[0]:
		"bot":
			Net.add_bot()
		"session":
			Session.intro_time = 0.5
			Session.countdown_time = 0.5
			Session.results_time = 3.0
			Session.podium_time = 3.0
			Session.start_session(1)
		"quit":
			_quit()


func _event(e: String) -> void:
	_events.append(e)
	_write()


func _quit() -> void:
	if _quitting:
		return
	_quitting = true
	# Let go of the scene override now: a PackedScene still held by the Session autoload
	# at exit is freed after the renderer and logs "Parameter "material" is null".
	Session.scene_override = null
	_events.append("quit")
	_write()
	get_tree().quit.call_deferred()


func _write() -> void:
	if _dir == "":
		return
	var ps: Dictionary = {}
	for slot: int in stage.players:
		var p := stage.players[slot]
		if is_instance_valid(p):
			ps[str(slot)] = {"alive": p.alive, "auth": p.get_multiplayer_authority()}
	var host_falls := -1
	if _minigame and is_instance_valid(_minigame):
		host_falls = _minigame.falls
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "session_state": Session.state,
		"scene": stage.minigame.scene_file_path if stage.minigame else "",
		"players": ps, "events": _events, "ranking": _ranking, "seed": _seed, "samples": _samples,
		"checkpoints": _checkpoints, "finishes": _finishes, "falls": _falls, "host_falls": host_falls,
		"local_hits": _local_hits, "cmds_done": _cmds_done, "layout": _layout,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
