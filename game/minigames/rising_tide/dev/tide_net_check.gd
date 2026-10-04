extends Node
## Multi-process Rising Tide check actor, driven by run_tide_net_check.ps1 (same pattern as
## mansion_dash/dev/). One headless host and two headless clients on this PC:
##   godot_console --headless --path game res://minigames/rising_tide/dev/tide_net_check.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC]
## Every peer's own human player is driven by a BotBrain (so clients really climb, stand on crumbling
## blocks, get launched and drown); bots run on the host as usual. Every peer records, when its round
## clock passes each SAMPLE_TIMES entry, the water height and every hanging platform's position at
## exactly that round time computed from its own clock, and the host-decided events in arrival order
## (crumbles cracking / falling / growing back, with whether the collider is gone on this peer;
## drownings; roof arrivals; the summit). Writes <dir>/<name>.json ten times a second and runs new lines
## of <dir>/<name>.cmd:
##   bot        host: Net.add_bot()
##   session    host: a 1-round Session of rising_tide
##   quit

const SCENE_PATH := "res://minigames/rising_tide/rising_tide.tscn"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"
const SAMPLE_TIMES: Array[float] = [2.0, 5.0, 8.0, 11.0, 14.0, 17.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0, 45.0, 50.0, 55.0, 60.0]

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 200.0
var _events: Array[String] = []
var _ranking: Array = []
var _samples: Dictionary = {}
var _next_sample: int = 0
var _seed: int = -1
var _crumbles: Array[String] = []
var _drowned: Array[String] = []
var _roof: Array[String] = []
var _summit: int = -1
var _launches: int = 0
var _bad_colliders: int = 0
var _max_y: Dictionary = {}
var _brain: Node = null
var _minigame: RisingTide = null
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
		var err := Net.host_game("Tide Check")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	var m := stage.minigame as RisingTide
	if m and not m.has_meta(&"net_check"):
		m.set_meta(&"net_check", true)
		_minigame = m
		m.round_began.connect(func(seed_value: int, _t0: float) -> void:
			_seed = seed_value
			_event("round_began"))
		m.crumble_cracked.connect(func(i: int) -> void: _crumbles.append("c%d" % i))
		m.crumble_fell.connect(func(i: int) -> void:
			if m.crumble_has_collider(i):
				_bad_colliders += 1
			_crumbles.append("f%d" % i))
		m.crumble_regrew.connect(func(i: int) -> void:
			if not m.crumble_has_collider(i):
				_bad_colliders += 1
			_crumbles.append("r%d" % i))
		m.drowned.connect(func(slot: int) -> void: _drowned.append(str(slot)))
		m.roof_reached.connect(func(slot: int, time: float) -> void: _roof.append("%d@%.3f" % [slot, time]))
		m.summit_reached.connect(func(slot: int) -> void: _summit = slot)
		m.launched.connect(func(_slot: int) -> void: _launches += 1)
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
		_brain.call(&"configure", _name.hash() & 0xFFFF, 0.85)


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
	for p in m.players:
		if is_instance_valid(p) and p.alive:
			_max_y[str(p.slot)] = maxf(float(_max_y.get(str(p.slot), -10.0)), p.global_position.y)
	while _next_sample < SAMPLE_TIMES.size() and m.round_time() >= SAMPLE_TIMES[_next_sample]:
		var at := SAMPLE_TIMES[_next_sample]
		_samples["%.1f" % at] = _sample(m, at)
		_next_sample += 1


## The water and every hanging platform at round time `at`, from this peer's own clock functions.
static func _sample(m: RisingTide, at: float) -> String:
	var parts: Array[String] = ["w:%.4f" % TideTower.water_height(at)]
	for i in TideTower.ids_of(TideTower.Kind.HANGING).size():
		var p := m.hanging_position(i, at)
		parts.append("h%d:%.4f" % [i, p.x])
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
	var fallen: Array = []
	if _minigame and is_instance_valid(_minigame):
		for i in _minigame.crumble_state.size():
			if _minigame.crumble_state[i] == RisingTide.CrumbleState.FALLEN:
				fallen.append(i)
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "session_state": Session.state,
		"scene": stage.minigame.scene_file_path if stage.minigame else "",
		"players": ps, "events": _events, "ranking": _ranking, "seed": _seed, "samples": _samples,
		"crumbles": _crumbles, "drowned": _drowned, "roof": _roof, "summit": _summit, "launches": _launches,
		"bad_colliders": _bad_colliders, "max_y": _max_y, "fallen_now": fallen, "cmds_done": _cmds_done,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
