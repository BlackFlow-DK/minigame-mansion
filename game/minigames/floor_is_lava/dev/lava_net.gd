extends Node
## Multi-process Floor Is Lava check actor, driven by run_lava_net.ps1 (same pattern as
## game/net/sync/dev/). One headless host and two headless clients play a real one-round
## Session of floor_is_lava; every human is driven by a BotBrain on its own peer, the host
## fills the roster with bots.
##   godot_console --headless --path game res://minigames/floor_is_lava/dev/lava_net.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT]
##       [--life=SEC]
## Writes <dir>/<name>.json ten times a second and runs new lines of <dir>/<name>.cmd:
##   bots <n>     host: add bots until the roster has n players
##   session      host: Session.start_session(1) (every peer loads floor_is_lava)
##   quit

const LAVA_SCENE: PackedScene = preload("res://minigames/floor_is_lava/floor_is_lava.tscn")

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 150.0
var _events: Array[String] = []
var _rounds: Array = []
var _cracked: Array[int] = []
var _fell: Array[int] = []
## The spawn layout this peer applied ("turn|slots"), from FloorIsLava.spawn_layout_applied.
var _layout: String = ""
var _fell_at_finish: Array = []
var _eliminated: Array[int] = []
var _brain: BotBrain = null
var _cmds_done: int = 0
var _poll: float = 0.0
var _write_accum: float = 0.0
var _age: float = 0.0
var _quitting: bool = false
var _hooked: Minigame = null

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
	Session.scene_override = LAVA_SCENE
	stage.players_spawned.connect(_on_players_spawned)
	Net.server_closed.connect(func() -> void: _event("server_closed"); _quit())
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r); _quit())
	Session.round_finished.connect(_on_round_finished)
	Session.session_finished.connect(func(_r: Array[int]) -> void: _event("session_finished"))
	Net.set_local_profile(_name, {})
	if _role == "host":
		var err := Net.host_game("Lava Net")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	var lava := stage.minigame as FloorIsLava
	if lava and lava != _hooked:
		_hooked = lava
		lava.tile_cracked.connect(func(i: int) -> void: _cracked.append(i))
		lava.tile_fell.connect(func(i: int) -> void: _fell.append(i))
		lava.spawn_layout_applied.connect(func(turn: float, slots: PackedInt32Array) -> void:
			_layout = "%.5f|%s" % [turn, str(slots)])
	for v: Variant in spawned:
		var p := v as Player
		p.eliminated.connect(func(_r: StringName) -> void: _eliminated.append(p.slot))
		if p.slot != Net.local_slot() or p.is_bot:
			continue
		var c := p.get_component(&"controller") as ControllerComponent
		if c:
			c.scripted = true
		if _brain:
			_brain.queue_free()
		_brain = BotBrain.new()
		_brain.player = p
		add_child(_brain)
		_brain.configure(hash(_name) & 0xffff)


func _on_round_finished(ranking: Array[int], _points: Dictionary) -> void:
	_rounds.append(ranking)
	_fell_at_finish.append(_fell.size())
	_event("round_finished")


func _physics_process(delta: float) -> void:
	var me := stage.get_player(Net.local_slot())
	if me == null or _brain == null or not is_instance_valid(_brain) or _brain.player != me:
		return
	_brain.fill_intent(me.intent, delta)


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
			while Net.roster.size() < int(parts[1]):
				if Net.add_bot() < 0:
					break
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
	_events.append("quit")
	_write()
	get_tree().quit.call_deferred()


func _write() -> void:
	if _dir == "":
		return
	var state := {
		"name": _name, "role": _role, "local_slot": Net.local_slot(), "roster_size": Net.roster.size(),
		"load_id": stage.net_load_id, "players": stage.players.size(),
		"session_state": Session.state, "rounds": _rounds, "events": _events,
		"cracked": _cracked, "fell": _fell, "fell_at_finish": _fell_at_finish, "eliminated": _eliminated,
		"cmds_done": _cmds_done, "layout": _layout,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
