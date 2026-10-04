extends Node
## Multi-process Portrait Panic check actor, driven by run_portrait_net.ps1 (same pattern as
## floor_is_lava/dev/). One headless host and two headless clients play a real one-round
## Session of portrait_panic; every human is driven by a BotBrain on its own peer, the host
## fills the roster with bots. The host forces the twists MEMORY, DECOY, SWAP on loops 1-3
## (`--portrait-twist=memory,decoy,swap`, passed to every actor; only the host's counts).
##   godot_console --headless --path game res://minigames/portrait_panic/dev/portrait_net.tscn --
##       --role=host|client --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT]
##       [--life=SEC]
## Writes <dir>/<name>.json ten times a second and runs new lines of <dir>/<name>.cmd:
##   bots <n>     host: add bots until the roster has n players
##   session      host: Session.start_session(1) (every peer loads portrait_panic)
##   quit

const SCENE: PackedScene = preload("res://minigames/portrait_panic/portrait_panic.tscn")

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 150.0
var _events: Array[String] = []
var _rounds: Array = []
var _groups: Array = []
## What this peer saw, in order (strings, compared across peers by the runner).
var _loops: Array[String] = []
var _shows: Array[String] = []
var _hides: Array[String] = []
var _reveals: Array[String] = []
var _swaps: Array[String] = []
var _drops: Array[String] = []
## MEMORY: tiles still face up 0.8 s after the hide (should be 0 on every peer).
var _faces_after_hide: Array[int] = []
var _layout: String = ""
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
	Session.scene_override = SCENE
	stage.players_spawned.connect(_on_players_spawned)
	Net.server_closed.connect(func() -> void: _event("server_closed"); _quit())
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r); _quit())
	Session.round_finished.connect(_on_round_finished)
	Session.round_ranked.connect(func(groups: Array, _points: Dictionary) -> void: _groups.append(str(groups)))
	Session.session_finished.connect(func(_r: Array[int]) -> void: _event("session_finished"))
	Net.set_local_profile(_name, {})
	if _role == "host":
		var err := Net.host_game("Portrait Net")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	var g := stage.minigame as PortraitPanic
	if g and g != _hooked:
		_hooked = g
		g.loop_started.connect(func(i: int, lay: PackedByteArray, tgt: int, tw: int) -> void:
			_loops.append("%d|%s|%d|%d|%d|%s|%.2f" % [i, lay.hex_encode(), tgt, tw, g.decoy, str(g.swap_rows), g.show_len]))
		g.show_started.connect(func(i: int, shown: int) -> void: _shows.append("%d|%d" % [i, shown]))
		g.faces_hidden.connect(func(i: int) -> void:
			_hides.append(str(i))
			get_tree().create_timer(0.8).timeout.connect(func() -> void:
				var up := 0
				if is_instance_valid(g):
					for c in PortraitPanic.CELLS:
						if g.face_visible(c):
							up += 1
				_faces_after_hide.append(up)))
		g.decoy_revealed.connect(func(i: int, tgt: int) -> void: _reveals.append("%d|%d" % [i, tgt]))
		g.rows_swapped.connect(func(i: int, a: int, b: int) -> void:
			_swaps.append("%d|%d|%d|%s" % [i, a, b, g.layout.hex_encode()]))
		g.dropped.connect(func(i: int, cells: PackedInt32Array) -> void: _drops.append("%d|%s" % [i, str(cells)]))
		g.spawn_layout_applied.connect(func(turn: float, slots: PackedInt32Array) -> void:
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
		"session_state": Session.state, "rounds": _rounds, "groups": _groups, "events": _events,
		"loops": _loops, "shows": _shows, "hides": _hides, "reveals": _reveals, "swaps": _swaps,
		"drops": _drops, "faces_after_hide": _faces_after_hide, "eliminated": _eliminated,
		"cmds_done": _cmds_done, "layout": _layout,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
