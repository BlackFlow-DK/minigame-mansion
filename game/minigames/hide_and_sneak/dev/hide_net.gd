extends Node
## Hide and Sneak multi-process check actor, driven by run_hide_net.ps1 (same pattern as
## hot_potato/dev/potato_net.gd).
##   godot_console --headless --path game res://minigames/hide_and_sneak/dev/hide_net.tscn -- --role=host|client
##       --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC] [--time-scale=X]
##       [--hide-seekers=a,b] (host)
## Every round loads Hide and Sneak (Session.scene_override). This peer's own blob is driven by
## a BotBrain; when it is a seeker it also walks to the nearest disguised hider and presses
## `action` (the client -> host poke path). Roster bots use the host's bot brains and AI.
## Writes <dir>/<name>.json ten times a second: layout fingerprint, seekers, the disguises seen
## on this peer when SEEK starts (slot:kind from the HideDisguise nodes), reveals in order,
## round rankings, whether this peer's screen was blacked out during HIDE. Commands in
## <dir>/<name>.cmd: `bot`, `session <rounds>`, `quit`.

const SCENE := "res://minigames/hide_and_sneak/hide_and_sneak.tscn"

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 180.0
var _events: Array[String] = []
var _reveals: Array[String] = []
var _rankings: Array = []
var _groups: Array = []
var _disguises_at_seek: String = ""
var _layout: String = ""
var _seekers: String = ""
var _blackout_seen: bool = false
var _blackout_frames: int = 0
var _cmds_done: int = 0
var _poll: float = 0.0
var _write_accum: float = 0.0
var _age: float = 0.0
var _press_left: float = 0.0
var _quitting: bool = false
var _brain: BotBrain = null
var _me: Player = null

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
	Session.scene_override = load(SCENE) as PackedScene
	stage.players_spawned.connect(_on_players_spawned)
	Session.round_intro.connect(_on_round_intro)
	Session.round_finished.connect(_on_round_finished)
	Session.round_ranked.connect(func(g: Array, _p: Dictionary) -> void: _groups.append(g))
	Session.session_finished.connect(func(_r: Array[int]) -> void: _event("session_finished"))
	Net.server_closed.connect(func() -> void: _event("server_closed"); _quit())
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r); _quit())
	Net.set_local_profile(_name, {})
	if _role == "host":
		var err := Net.host_game("Hide Net")
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
		_brain.configure(1000 + p.slot, 1.0, 0.0)
		_me = p


func _on_round_intro(_info: Dictionary, index: int) -> void:
	var mg := Session.current_minigame as HideAndSneak
	_event("round_intro:%d:%s" % [index, "hide_and_sneak" if mg else "other"])
	if mg == null:
		return
	mg.phase_changed.connect(_on_phase.bind(mg))
	mg.revealed.connect(func(s: int, by: int, _t: float) -> void:
		_reveals.append("%d>%d" % [s, by])
		_write())


func _on_phase(phase: int, mg: HideAndSneak) -> void:
	_event("phase:%d" % phase)
	if phase != HideAndSneak.Phase.SEEK:
		return
	_layout = HideLayout.fingerprint(mg.room().furniture)
	_seekers = ",".join(PackedStringArray(mg.seekers.map(func(s: int) -> String: return str(s))))
	var parts: PackedStringArray = []
	var slots: Array[int] = []
	for p in mg.players:
		if is_instance_valid(p):
			slots.append(p.slot)
	slots.sort()
	for s in slots:
		var p := stage.get_player(s)
		var d := p.get_node_or_null(^"HideDisguise") as HideDisguise if p else null
		if d:
			parts.append("%d:%d" % [s, d.kind])
	_disguises_at_seek = " ".join(parts)
	_write()


func _on_round_finished(ranking: Array[int], _points: Dictionary) -> void:
	_rankings.append(ranking)
	_event("round_finished")


func _physics_process(delta: float) -> void:
	if not (_brain and is_instance_valid(_me) and _me.is_inside_tree()):
		return
	_brain.fill_intent(_me.intent, delta)
	var mg := stage.minigame as HideAndSneak
	if mg == null:
		return
	if mg.phase == HideAndSneak.Phase.HIDE and mg.blackout_visible():
		_blackout_frames += 1
		_blackout_seen = _blackout_frames > 3
	# A seeker heads for the nearest disguised hider and pokes now and then (the client path).
	if mg.phase == HideAndSneak.Phase.SEEK and mg.seekers.has(_me.slot) and _me.alive and not _me.frozen:
		var best: Player = null
		var best_d := INF
		for s: int in mg.disguises:
			var p := stage.get_player(s)
			if p and p.alive and not mg.caught_time.has(s):
				var d := p.global_position.distance_to(_me.global_position)
				if d < best_d:
					best_d = d
					best = p
		if best:
			var to := best.global_position - _me.global_position
			_me.intent.move = Vector2(to.x, to.z).normalized() if best_d > 0.9 else Vector2.ZERO
		_press_left -= delta
		_me.intent.action_pressed = false
		if _press_left <= 0.0 and best_d < 1.4:
			_press_left = 1.0
			_me.intent.action_pressed = true


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
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "session_state": Session.state, "round_index": Session.round_index,
		"layout": _layout, "seekers": _seekers, "disguises": _disguises_at_seek, "reveals": _reveals,
		"blackout": _blackout_seen, "rankings": _rankings, "groups": _groups, "events": _events,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
