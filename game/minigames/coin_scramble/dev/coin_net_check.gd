extends Node
## Coin Scramble multi-process check actor, driven by run_coin_net_check.ps1 (same pattern as
## game/net/sync/dev/). One headless host and two headless clients on this PC:
##   godot_console --headless --path game res://minigames/coin_scramble/dev/coin_net_check.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT]
##       [--life=SEC] [--time-scale=X]
## Every peer plays Coin Scramble for every round (Session.scene_override). Each peer walks its
## own human player toward `get_bot_goal` (so client-owned players collect coins the host
## has to see through synced positions); the host's bots use their normal brains.
## Writes <dir>/<name>.json ten times a second and runs new lines of <dir>/<name>.cmd:
##   bots <n>      host: add n bots
##   start         host: Session.start_session(1) with short intro/results
##   quit

const SCENE_PATH := "res://minigames/coin_scramble/coin_scramble.tscn"

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 180.0
var _events: Array[String] = []
var _cmds_done: int = 0
var _poll: float = 0.0
var _write_accum: float = 0.0
var _age: float = 0.0
var _quitting: bool = false
var _goal_timer: float = 0.0
var _goal: Vector3 = Vector3.INF
var _minigame: Minigame = null
var _spawned: int = 0
var _collected: Dictionary = {}   # slot -> pickups seen here
var _collect_log: Array = []      # [id, slot] in arrival order
var _final_counts: Dictionary = {}
var _final_ranking: Array = []
var _live_counts: Dictionary = {}
var _round_ranking: Array = []
var _hits: int = 0

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
	Session.scene_override = load(SCENE_PATH) as PackedScene
	Session.round_intro.connect(_on_round_intro)
	Session.round_finished.connect(_on_round_finished)
	Session.session_finished.connect(func(_r: Array[int]) -> void: _event("session_finished"))
	Net.server_closed.connect(func() -> void: _event("server_closed"); _quit())
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r); _quit())
	Net.set_local_profile(_name, {})
	if _role == "host":
		var err := Net.host_game("Coin Check")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_round_intro(_info: Dictionary, _index: int) -> void:
	_minigame = Session.current_minigame
	if _minigame == null:
		_event("no_minigame")
		return
	_event("round_intro:" + _minigame.scene_file_path.get_file())
	_minigame.connect(&"coin_spawned", func(_id: int) -> void: _spawned += 1)
	_minigame.connect(&"coin_collected", func(id: int, slot: int) -> void:
		_collected[str(slot)] = int(_collected.get(str(slot), 0)) + 1
		_collect_log.append([id, slot]))
	_minigame.connect(&"coins_changed", func(slot: int, count: int) -> void: _live_counts[str(slot)] = count)
	_minigame.connect(&"round_over", _on_round_over)
	for p in _minigame.players:
		p.got_hit.connect(func(_i: Vector3, _s: int) -> void: _hits += 1)
		var c := p.get_component(&"controller") as ControllerComponent
		if c and p.is_authority() and not p.is_bot:
			c.scripted = true


func _on_round_over(ranking: Array[int]) -> void:
	_final_ranking = ranking.duplicate()
	var counts: Dictionary = _minigame.get(&"coins")
	_final_counts = {}
	for s: int in counts:
		_final_counts[str(s)] = counts[s]
	_event("round_over")


func _on_round_finished(ranking: Array[int], _points: Dictionary) -> void:
	_round_ranking = ranking.duplicate()
	_event("round_finished")


func _physics_process(delta: float) -> void:
	var me := stage.get_player(Net.local_slot())
	if me == null or not is_instance_valid(_minigame) or me.frozen or not me.alive:
		return
	_goal_timer -= delta
	if _goal_timer <= 0.0 or _goal == Vector3.INF:
		_goal_timer = 0.3
		_goal = _minigame.get_bot_goal(me)
	var to := _goal - me.global_position
	to.y = 0.0
	me.intent.move = Vector2(to.x, to.z).normalized() if to.length() > 0.3 else Vector2.ZERO


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
		"bots":
			for i in int(parts[1]):
				Net.add_bot()
		"start":
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
			ps[str(slot)] = {"auth": p.get_multiplayer_authority(), "local": p.is_authority(), "bot": p.is_bot}
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "session_state": Session.state, "players": ps,
		"spawned": _spawned, "collected": _collected, "collect_log": _collect_log, "hits": _hits,
		"live_counts": _live_counts, "final_counts": _final_counts, "final_ranking": _final_ranking,
		"round_ranking": _round_ranking, "events": _events, "cmds_done": _cmds_done,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
