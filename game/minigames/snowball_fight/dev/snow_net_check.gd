extends Node
## Multi-process Snowball Fight check actor, driven by run_snow_net_check.ps1 (same pattern as
## cannon_alley/dev/). One headless host and two headless clients on this PC:
##   godot_console --headless --path game res://minigames/snowball_fight/dev/snow_net_check.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC]
## Every peer's own human player walks with a BotBrain and scoops/throws with the minigame's thrower
## AI (`ai_slots`), so clients really send throw requests and hit reports to the host; host bots
## run as usual. Every peer records every launch it saw (id, thrower, sim time, origin, direction
## and where its own SnowArc says the ball ends), every confirmed hit, the scores, snow-ins and the
## ranking. Writes <dir>/<name>.json ten times a second and runs new lines of <dir>/<name>.cmd:
##   bot        host: Net.add_bot()
##   session    host: a 1-round Session of snowball_fight
##   quit

const SCENE_PATH := "res://minigames/snowball_fight/snowball_fight.tscn"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 150.0
var _events: Array[String] = []
var _ranking: Array = []
var _launches: Array[String] = []
var _confirmed: Array[String] = []
var _snowins: Array[String] = []
var _local_hits: int = 0
var _brain: Node = null
var _minigame: SnowballFight = null
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
		var err := Net.host_game("Snow Check")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	var m := stage.minigame as SnowballFight
	if m and not m.has_meta(&"net_check"):
		m.set_meta(&"net_check", true)
		_minigame = m
		m.round_began.connect(func(_t0: float) -> void: _event("round_began"))
		m.ball_launched.connect(func(id: int, slot: int) -> void:
			var b := m.get_ball(id)
			_launches.append("%d:%d:%.4f:%.3f,%.3f,%.3f:%.4f,%.4f:%.4f:%d" % [id, slot, b.t0, b.origin.x, b.origin.y, b.origin.z,
				b.dir.x, b.dir.z, b.t_end, b.end_kind]))
		m.hit_confirmed.connect(func(id: int, thrower: int, victim: int, points: int) -> void:
			_confirmed.append("%d:%d>%d:%d" % [id, thrower, victim, points]))
		m.snowed_in.connect(func(slot: int) -> void: _snowins.append(str(slot)))
		m.local_hit.connect(func(_slot: int, _id: int) -> void: _local_hits += 1)
	if m and not m.ai_slots.has(Net.local_slot()):
		m.ai_slots.append(Net.local_slot())
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
	# Let go of the scene override now (see cannon_net_check.gd).
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
	var scores: Dictionary = {}
	var snowed: Dictionary = {}
	var accepted_throws := 0
	var accepted_hits := 0
	var rejected := 0
	var ignored := 0
	if _minigame and is_instance_valid(_minigame):
		for s: int in _minigame.scores:
			scores[str(s)] = _minigame.scores[s]
			snowed[str(s)] = _minigame.snowed_count.get(s, 0)
		accepted_throws = _minigame.accepted_remote_throws
		accepted_hits = _minigame.accepted_remote_hits
		rejected = _minigame.rejected_reports
		ignored = _minigame.ignored_reports
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "session_state": Session.state,
		"scene": stage.minigame.scene_file_path if stage.minigame else "",
		"players": ps, "events": _events, "ranking": _ranking, "launches": _launches,
		"confirmed": _confirmed, "snowins": _snowins, "scores": scores, "snowed": snowed,
		"local_hits": _local_hits, "accepted_throws": accepted_throws, "accepted_hits": accepted_hits,
		"rejected": rejected, "ignored": ignored, "cmds_done": _cmds_done,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
