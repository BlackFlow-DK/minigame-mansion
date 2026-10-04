extends Node
## Multi-process Masquerade check actor, driven by run_masq_net_check.ps1 (same pattern as the
## Spotlight Chairs check). One headless host and clients on this PC:
##   godot_console --headless --path game res://minigames/masquerade/dev/masq_net_check.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC]
## Every peer's own human player is driven by its own MasqBots (NPC strolls plus suspicion hunts,
## so clients really simulate and shove); roster bots run on the host as usual. Every player gets
## a NameTag before _setup, as Stage would give it with a display (headless gets none), so the
## check can see the disguise hide it. Writes <dir>/<name>.json ten times a second: the
## unmaskings and wrong shoves as this peer saw them (with times), the final points, the
## eliminations, the ranking, and a look snapshot 2.5 s into the round: the fingerprint
## (MasqDisguise.fingerprint) of another real player and of an NPC extra.
## Runs new lines of <dir>/<name>.cmd:
##   bot        host: Net.add_bot()
##   session    host: a 1-round Session of masquerade
##   quit

const MASQ_SCENE := "res://minigames/masquerade/masquerade.tscn"
const NAME_TAG_PATH := "res://ui/round/name_tag.tscn"
const SNAPSHOT_AT := 2.5

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 150.0
var _events: Array[String] = []
var _unmasks: Array[String] = []
var _unmask_times: Array[float] = []
var _wrongs: Array[String] = []
var _eliminations: Array[String] = []
var _ranking: Array = []
var _points: Dictionary = {}
var _snapshot: Dictionary = {}
var _round_t0: int = -1
var _driver: MasqBots = null
var _brain: BotBrain = null
var _rng := RandomNumberGenerator.new()
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
	_rng.seed = _name.hash() & 0xFFFF
	stage.players_spawned.connect(_on_players_spawned)
	Net.server_closed.connect(func() -> void: _event("server_closed"); _quit())
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r); _quit())
	Session.round_started.connect(_on_round_started)
	Session.round_finished.connect(_on_round_finished)
	Net.set_local_profile(_name, {})
	Session.scene_override = load(MASQ_SCENE) as PackedScene
	if _role == "host":
		var err := Net.host_game("Masquerade Check")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	var m := stage.minigame
	if m and m.has_signal(&"unmasked") and not m.has_meta(&"net_check"):
		m.set_meta(&"net_check", true)
		m.connect(&"unmasked", _on_unmasked)
		m.connect(&"wrong_shove", func(s: int, x: int) -> void: _wrongs.append("%d>%d" % [s, x]))
	for v: Variant in spawned:
		var p := v as Player
		p.eliminated.connect(func(reason: StringName) -> void: _eliminations.append("%d:%s" % [p.slot, reason]))
		if p.get_node_or_null(^"NameTag") == null:
			var tag := (load(NAME_TAG_PATH) as PackedScene).instantiate()
			tag.name = "NameTag"
			p.add_child(tag)
			tag.call(&"setup", p)
		if p.slot == Net.local_slot():
			var c := p.get_component(&"controller") as ControllerComponent
			if c:
				c.scripted = true


func _on_round_started() -> void:
	_round_t0 = Time.get_ticks_msec()
	_event("round_started")
	var m := stage.minigame
	var me := stage.get_player(Net.local_slot())
	if m == null or me == null:
		return
	_driver = MasqBots.new(m, _rng, Masquerade.DANCE_CENTERS)
	_driver.hunt_chance = 0.4
	_brain = BotBrain.new()
	_brain.player = me
	_brain.name = "LocalBrain"
	add_child(_brain)
	_driver.add(me, _brain)


func _on_unmasked(victim: int, shover: int) -> void:
	_unmasks.append("%d<%d" % [victim, shover])
	_unmask_times.append((Time.get_ticks_msec() - _round_t0) / 1000.0 if _round_t0 >= 0 else -1.0)


func _on_round_finished(ranking: Array[int], _pts: Dictionary) -> void:
	_ranking = ranking.duplicate()
	var m := stage.minigame
	if m:
		var pts: Dictionary = m.get(&"points")
		for s: int in pts:
			_points[str(s)] = pts[s]
	_event("round_finished")


func _physics_process(delta: float) -> void:
	if _driver and stage.minigame and not stage.minigame.get(&"over"):
		_driver.tick(delta)
	if _snapshot.is_empty() and _round_t0 >= 0 and (Time.get_ticks_msec() - _round_t0) / 1000.0 >= SNAPSHOT_AT:
		_take_snapshot()


## Another real player still in disguise (not flashing) and an NPC extra, as this peer sees them.
func _take_snapshot() -> void:
	var m := stage.minigame as Masquerade
	if m == null or stage.extras.is_empty():
		return
	var other: Player = null
	for p in m.players:
		if p.slot != Net.local_slot() and p.alive and not m.found.has(p.slot) and not m.disguise.is_flashing(p):
			other = p
			break
	if other == null:
		return
	var x := stage.extras[0]
	_snapshot = {
		"player_slot": other.slot, "player_is_bot": other.is_bot,
		"player": MasqDisguise.fingerprint(other), "extra": MasqDisguise.fingerprint(x),
		"look": MasqDisguise.colour_key(MasqDisguise.LOOK),
		"real": MasqDisguise.colour_key(other.loadout), "extras": stage.extras.size(),
	}


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
	# Let go of the scene override now (see chairs_net_check.gd).
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
		"players": ps, "events": _events, "unmasks": _unmasks, "unmask_times": _unmask_times, "wrongs": _wrongs,
		"eliminations": _eliminations, "ranking": _ranking, "points": _points, "snapshot": _snapshot,
		"cmds_done": _cmds_done,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
