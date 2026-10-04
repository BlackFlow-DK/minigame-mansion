extends Node
## Multi-process Statue Garden check actor, driven by run_statue_net_check.ps1 (same pattern as
## the Spotlight Chairs check). One headless host and clients on this PC:
##   godot_console --headless --path game res://minigames/statue_garden/dev/statue_net_check.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC]
##       [--reckless]
## Every peer's own player is driven by a BotBrain (so clients really simulate and shove),
## except with --reckless: then it never stops walking (in a slow circle, so no wall or bench
## can stop it): it must be caught in every RED, on every peer. Bots run on the host as usual.
## Writes <dir>/<name>.json ten times a second: the phase timeline (index, phase, length and
## when this peer saw it), the catches, the win and the ranking as this peer saw them. Runs
## new lines of <dir>/<name>.cmd:
##   bot        host: Net.add_bot()
##   session    host: a 1-round Session of statue_garden
##   quit

const STATUE_SCENE := "res://minigames/statue_garden/statue_garden.tscn"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 150.0
var _reckless: bool = false
var _events: Array[String] = []
var _phases: Array[String] = []
var _phase_times: Array[float] = []
var _catches: Array[String] = []
var _wins: Array[int] = []
var _ranking: Array = []
var _round_t0: int = -1
var _brain: Node = null
var _walk_angle: float = 0.0
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
			"reckless": _reckless = true
	stage.players_spawned.connect(_on_players_spawned)
	Net.server_closed.connect(func() -> void: _event("server_closed"); _quit())
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r); _quit())
	Session.round_started.connect(func() -> void: _round_t0 = Time.get_ticks_msec(); _event("round_started"))
	Session.round_finished.connect(_on_round_finished)
	Net.set_local_profile(_name, {})
	# Every peer loads the statue scene for the round, as every peer would load the same
	# registry id in a real session.
	Session.scene_override = load(STATUE_SCENE) as PackedScene
	if _role == "host":
		var err := Net.host_game("Statue Check")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	var m := stage.minigame
	if m and m.has_signal(&"phase_changed") and not m.has_meta(&"net_check"):
		m.set_meta(&"net_check", true)
		m.connect(&"phase_changed", _on_phase)
		m.connect(&"caught", _on_caught)
		m.connect(&"won", func(slot: int) -> void: _wins.append(slot))
	for v: Variant in spawned:
		var p := v as Player
		if p.slot != Net.local_slot():
			continue
		var c := p.get_component(&"controller") as ControllerComponent
		if c:
			c.scripted = true
		if _brain and is_instance_valid(_brain):
			_brain.queue_free()
		_brain = null
		if _reckless:
			continue
		_brain = (load(BOT_BRAIN_PATH) as GDScript).new() as Node
		_brain.set(&"player", p)
		_brain.name = "LocalBrain"
		add_child(_brain)
		_brain.call(&"configure", _name.hash() & 0xFFFF)


func _on_phase(phase: int, index: int, length: float) -> void:
	_phases.append("%d:%d:%.3f" % [index, phase, length])
	_phase_times.append((Time.get_ticks_msec() - _round_t0) / 1000.0 if _round_t0 >= 0 else -1.0)


func _on_caught(slot: int, index: int) -> void:
	_catches.append("%d:%d" % [index, slot])


func _on_round_finished(ranking: Array[int], _points: Dictionary) -> void:
	_ranking = ranking.duplicate()
	_event("round_finished")


func _physics_process(delta: float) -> void:
	var me := stage.get_player(Net.local_slot())
	if me == null:
		return
	if _reckless:
		_walk_angle += delta * 0.9
		me.intent.move = Vector2(sin(_walk_angle), -cos(_walk_angle))
		return
	if _brain and is_instance_valid(_brain):
		_brain.call(&"fill_intent", me.intent, delta)


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
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "session_state": Session.state,
		"scene": stage.minigame.scene_file_path if stage.minigame else "",
		"players": ps, "events": _events, "phases": _phases, "phase_times": _phase_times,
		"catches": _catches, "wins": _wins, "ranking": _ranking, "cmds_done": _cmds_done,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
