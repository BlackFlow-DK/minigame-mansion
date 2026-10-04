extends Node
## Blob Ball multi-process check actor, driven by run_ball_net.ps1 (same pattern as
## game/minigames/hot_potato/dev/potato_net.gd).
##   godot_console --headless --path game res://minigames/blob_ball/dev/ball_net.tscn -- --role=host|client
##       --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC] [--time-scale=X]
## Every round loads Blob Ball (Session.scene_override). This peer's own blob is driven by a
## BotBrain, plus a "striker" reflex: it presses shove whenever the ball is in reach in front
## (so client shoves on the ball really happen). Roster bots use the host's normal bot brains.
## Writes <dir>/<name>.json ten times a second (goal timeline, accepted kicks with the ball
## speed right after, score, rankings, the client's ball prediction error) and runs new lines
## of <dir>/<name>.cmd:
##   bot                host: Net.add_bot()
##   session <rounds>   host: Session.start_session
##   quit

const BALL_SCENE := "res://minigames/blob_ball/blob_ball.tscn"

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 180.0
var _events: Array[String] = []
var _kicks: Array[String] = []
var _rankings: Array = []
var _cmds_done: int = 0
var _poll: float = 0.0
var _write_accum: float = 0.0
var _age: float = 0.0
var _quitting: bool = false
var _brain: BotBrain = null
var _me: Player = null
var _shove_cd: float = 0.0
var _mg: BlobBall = null

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
			"time-scale": Session.time_scale = float(v)
	Session.scene_override = load(BALL_SCENE) as PackedScene
	stage.players_spawned.connect(_on_players_spawned)
	Session.round_intro.connect(_on_round_intro)
	Session.round_ranked.connect(_on_round_ranked)
	Session.session_finished.connect(func(_r: Array[int]) -> void: _event("session_finished"))
	Net.server_closed.connect(func() -> void: _event("server_closed"); _quit())
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r); _quit())
	Net.set_local_profile(_name, {})
	if _role == "host":
		var err := Net.host_game("Ball Net")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	for v: Variant in spawned:
		var p := v as Player
		if p == null or p.slot != Net.local_slot():
			continue
		var c := p.get_component(&"controller") as ControllerComponent
		if c:
			c.scripted = true
		if _brain:
			_brain.queue_free()
		_brain = BotBrain.new()
		_brain.player = p
		add_child(_brain)
		_brain.configure(1000 + p.slot)
		_me = p


func _on_round_intro(_info: Dictionary, index: int) -> void:
	_mg = Session.current_minigame as BlobBall
	_event("round_intro:%d:%s" % [index, "blob_ball" if _mg else "other"])
	if _mg == null:
		return
	_mg.ball_kicked.connect(_on_kicked)


func _on_kicked(slot: int) -> void:
	if _mg == null:
		return
	var v := _mg.ball.vel
	_kicks.append("%d:%.1f" % [slot, Vector2(v.x, v.z).length()])
	_write()


func _on_round_ranked(groups: Array, _points: Dictionary) -> void:
	_rankings.append(groups)
	_event("round_finished")


func _physics_process(delta: float) -> void:
	if _brain and is_instance_valid(_me) and _me.is_inside_tree():
		_brain.fill_intent(_me.intent, delta)
		_shove_cd -= delta
		var mg := _mg if _mg and is_instance_valid(_mg) else null
		if mg and _shove_cd <= 0.0 and not _me.frozen and mg.phase == BlobBall.Phase.PLAY \
				and mg.sim.in_kick_reach(mg.ball, _me.global_position, _me.facing, mg.kick_reach * 0.8, 50.0):
			_me.intent.action_pressed = true
			_shove_cd = 0.8


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
			_event("bot:%d" % Net.add_bot())
		"session":
			Session.start_session(int(parts[1]))
		"quit":
			_quit()


func _event(e: String) -> void:
	_events.append(e)
	_write()


func _quit() -> void:
	if _quitting:
		return
	_quitting = true
	_events.append("quit")
	_write()
	get_tree().quit.call_deferred()


func _write() -> void:
	if _dir == "":
		return
	var mg: BlobBall = stage.minigame as BlobBall if stage else null
	var goals: Array = []
	var score: Array = []
	var err: Dictionary = {}
	var phase := -1
	if mg:
		goals.assign(mg.goal_log)
		score.assign(mg.score)
		err = mg.net_error.duplicate()
		phase = mg.phase
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "session_state": Session.state, "round_index": Session.round_index,
		"players": stage.players.size() if stage else 0, "phase": phase,
		"goals": goals, "score": score, "kicks": _kicks, "net_error": err,
		"rankings": _rankings, "events": _events,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
