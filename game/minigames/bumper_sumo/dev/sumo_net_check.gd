extends Node
## Multi-process Bumper Sumo check actor, driven by run_sumo_net_check.ps1 (same pattern
## as game/net/sync/dev/). One headless host and clients on this PC:
##   godot_console --headless --path game res://minigames/bumper_sumo/dev/sumo_net_check.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC]
## Every peer's own human player is driven by a BotBrain (so clients really simulate and
## shove); bots run on the host as usual. Writes <dir>/<name>.json ten times a second and
## runs new lines of <dir>/<name>.cmd:
##   bot        host: Net.add_bot()
##   session    host: a 1-round Session of bumper_sumo
##   quit

const SUMO_SCENE := "res://minigames/bumper_sumo/bumper_sumo.tscn"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 150.0
var _events: Array[String] = []
var _ring_events: Array[String] = []
var _ring_times: Dictionary = {}
var _eliminations: Array[String] = []
var _ranking: Array = []
## The spawn layout this peer applied ("turn|slots"), from BumperSumo.spawn_layout_applied.
var _layout: String = ""
var _round_t0: int = -1
var _brain: Node = null
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
	Session.round_started.connect(func() -> void: _round_t0 = Time.get_ticks_msec(); _event("round_started"))
	Session.round_finished.connect(_on_round_finished)
	Net.set_local_profile(_name, {})
	# Every peer loads the sumo scene for the round, as every peer would load the same
	# registry id in a real session.
	Session.scene_override = load(SUMO_SCENE) as PackedScene
	if _role == "host":
		var err := Net.host_game("Sumo Check")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	var m := stage.minigame
	if m and m.has_signal(&"ring_dropped") and not m.has_meta(&"net_check"):
		m.set_meta(&"net_check", true)
		m.connect(&"ring_warned", _on_ring.bind("warn"))
		m.connect(&"ring_dropped", _on_ring.bind("drop"))
		m.connect(&"spawn_layout_applied", func(turn: float, slots: PackedInt32Array) -> void:
			_layout = "%.5f|%s" % [turn, str(slots)])
	for v: Variant in spawned:
		var p := v as Player
		p.eliminated.connect(func(reason: StringName) -> void: _eliminations.append("%d:%s" % [p.slot, reason]))
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


func _on_ring(index: int, kind: String) -> void:
	var key := "%s:%d" % [kind, index]
	_ring_events.append(key)
	if _round_t0 >= 0:
		_ring_times[key] = (Time.get_ticks_msec() - _round_t0) / 1000.0


func _on_round_finished(ranking: Array[int], _points: Dictionary) -> void:
	_ranking = ranking.duplicate()
	_event("round_finished")


func _physics_process(delta: float) -> void:
	var me := stage.get_player(Net.local_slot())
	if me == null or _brain == null or not is_instance_valid(_brain):
		return
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
			ps[str(slot)] = {"alive": p.alive, "y": p.global_position.y, "auth": p.get_multiplayer_authority()}
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "session_state": Session.state,
		"scene": stage.minigame.scene_file_path if stage.minigame else "",
		"players": ps, "events": _events, "ring_events": _ring_events, "ring_times": _ring_times,
		"eliminations": _eliminations, "ranking": _ranking, "cmds_done": _cmds_done,
		"layout": _layout,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
