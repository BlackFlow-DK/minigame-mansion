extends Node
## Multi-process Cannon Alley check actor, driven by run_cannon_net_check.ps1 (same pattern as
## bumper_sumo/dev/). One headless host and two headless clients on this PC:
##   godot_console --headless --path game res://minigames/cannon_alley/dev/cannon_net_check.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC]
## Every peer's own human player is driven by a BotBrain (so clients really dodge, get hit and
## report their hits to the host); bots run on the host as usual. Every peer records, when its
## round clock passes each SAMPLE_TIMES entry, the positions of every ball in flight at exactly
## that round time, computed from its own copy of the schedule. Writes <dir>/<name>.json ten
## times a second and runs new lines of <dir>/<name>.cmd:
##   bot        host: Net.add_bot()
##   session    host: a 1-round Session of cannon_alley
##   quit

const SCENE_PATH := "res://minigames/cannon_alley/cannon_alley.tscn"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"
const SAMPLE_TIMES: Array[float] = [3.0, 6.0, 9.0, 12.0, 15.0, 18.0, 21.0, 24.0, 27.0, 30.0, 33.0, 36.0, 40.0, 45.0, 50.0]

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 150.0
var _events: Array[String] = []
var _eliminations: Array[String] = []
var _ranking: Array = []
var _samples: Dictionary = {}
var _next_sample: int = 0
var _seed: int = -1
var _shot_count: int = 0
var _confirmed: Array[String] = []
var _local_hits: int = 0
var _brain: Node = null
var _minigame: CannonAlley = null
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
		var err := Net.host_game("Cannon Check")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	var m := stage.minigame as CannonAlley
	if m and not m.has_meta(&"net_check"):
		m.set_meta(&"net_check", true)
		_minigame = m
		m.round_began.connect(func(seed_value: int, _t0: float) -> void:
			_seed = seed_value
			_shot_count = m.shots.size()
			_event("round_began"))
		m.hit_confirmed.connect(func(slot: int, count: int) -> void: _confirmed.append("%d:%d" % [slot, count]))
		m.local_hit.connect(func(_slot: int, _id: int) -> void: _local_hits += 1)
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
		var balls: Array[String] = []
		for s in m.shots:
			if CannonSchedule.is_flying(s, at):
				var pos := CannonSchedule.ball_position(s, at)
				balls.append("%d:%.3f,%.3f,%.3f" % [s.id, pos.x, pos.y, pos.z])
		_samples["%.1f" % at] = ",".join(balls) if not balls.is_empty() else "-"
		_next_sample += 1


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
	var hits: Dictionary = {}
	var accepted := 0
	var rejected := 0
	if _minigame and is_instance_valid(_minigame):
		for s: int in _minigame.hits:
			hits[str(s)] = _minigame.hits[s]
		accepted = _minigame.accepted_remote_reports
		rejected = _minigame.rejected_reports
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "session_state": Session.state,
		"scene": stage.minigame.scene_file_path if stage.minigame else "",
		"players": ps, "events": _events, "eliminations": _eliminations, "ranking": _ranking,
		"seed": _seed, "shot_count": _shot_count, "samples": _samples, "hits": hits,
		"confirmed": _confirmed, "local_hits": _local_hits, "accepted_remote": accepted,
		"rejected": rejected, "cmds_done": _cmds_done,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
