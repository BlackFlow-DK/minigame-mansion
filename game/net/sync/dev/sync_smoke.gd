extends Node
## Multi-process player-sync smoke actor, driven by game/net/sync/dev/run_sync_smoke.ps1.
##   godot_console --headless --path game res://net/sync/dev/sync_smoke.tscn -- --role=host|client
##       --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC] [--time-scale=X]
##       [--order-seed=N] [--scene-override=res://x.tscn]   (Session round order / every round's scene)
## Writes <dir>/<name>.json (players as seen here, event counts, Session state and scores) ten
## times a second and runs new lines of <dir>/<name>.cmd:
##   load dev|<id>          host: Stage.load_minigame* (clients follow the host manifest)
##   unfreeze               host: unfreeze every player on every peer
##   walk <x> <z> <secs>    own player walks along (x, z)
##   shove <slot>           own player walks up to <slot> (a player or an extra) and shoves it
##   eliminate <slot>       host: Player.eliminate
##   session <rounds>       host: Session.start_session
##   knockout <slot>        host: current minigame knock_out
##   endround <slot>...     host: current minigame finish(ranking)
##   extras <n> [mode]      host: Stage.spawn_extras(n), brains in `mode` (default wander)
##   extras_mode <mode>     host: every extra's brain to `mode` (wander | dance | idle)
##   freeze_extras 0|1      host: (un)freeze every extra
##   despawn_extras         host: Stage.despawn_extras
##   quit
##   quit_at <unix ms>      quit at that wall-clock time (several actors leave in the same frame)
## Every player controller is scripted (intent comes from the commands only); extras keep
## their brains. The JSON also has `extras` (as `players`) and `tx_bps` (ENet bytes sent per
## second by this peer over the last second). Extras runner: run_extras_smoke.ps1.

## Counted player events -> their argument count.
const COUNTED: Dictionary = {&"got_hit": 2, &"eliminated": 1, &"respawned": 1, &"shove_hit": 1, &"shove_started": 0, &"stunned": 1}

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 120.0
var _events: Array[String] = []
var _counts: Dictionary = {}
var _rounds: Array = []
var _final_scores: Dictionary = {}
var _final_wins: Dictionary = {}
## Players in the current round when it started (the points table depends on it).
var _round_players: int = 0
var _final_ranking: Array = []
var _cmds_done: int = 0
var _poll: float = 0.0
var _write_accum: float = 0.0
var _age: float = 0.0
var _quitting: bool = false
var _walk_dir: Vector2 = Vector2.ZERO
var _walk_left: float = 0.0
var _shove_target: int = -1
var _shoves_done: int = 0
var _walks_done: int = 0
var _quit_at_ms: float = -1.0
## Bytes ENet sent per second over the last full second (to every peer).
var _tx_bps: float = 0.0
var _tx_accum: float = 0.0

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
			"order-seed": Session.order_seed = int(v)
			"scene-override": Session.scene_override = load(v) as PackedScene
	stage.players_spawned.connect(_on_players_spawned)
	stage.extras_spawned.connect(_on_players_spawned)
	Net.server_closed.connect(func() -> void: _event("server_closed"); _quit())
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r); _quit())
	Session.round_started.connect(_on_round_started)
	Session.round_finished.connect(_on_round_finished)
	Session.session_finished.connect(_on_session_finished)
	Net.set_local_profile(_name, {})
	if _role == "host":
		var err := Net.host_game("Sync Smoke")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _on_players_spawned(spawned: Array) -> void:
	for v: Variant in spawned:
		var p := v as Player
		var c := p.get_component(&"controller") as ControllerComponent
		if c and not p.is_extra:  # extras keep their brains
			c.scripted = true
		for sig: StringName in COUNTED:
			var cb := _count.bind(sig, p.slot)
			p.connect(sig, cb.unbind(COUNTED[sig]) if COUNTED[sig] > 0 else cb)


func _count(sig: StringName, slot: int) -> void:
	var key := "%s:%d" % [sig, slot]
	_counts[key] = int(_counts.get(key, 0)) + 1


func _on_round_started() -> void:
	_round_players = stage.players.size()


func _on_round_finished(ranking: Array[int], points: Dictionary) -> void:
	var pts: Dictionary = {}
	for s: Variant in points:
		pts[str(s)] = points[s]
	_rounds.append({"ranking": ranking, "points": pts, "players": _round_players,
			"table": Session.place_points(_round_players)})
	_event("round_finished")


func _on_session_finished(final: Array[int]) -> void:
	_final_scores = {}
	for s: int in Session.scores:
		_final_scores[str(s)] = Session.scores[s]
	_final_wins = {}
	for s: int in Session.round_wins:
		_final_wins[str(s)] = Session.round_wins[s]
	_final_ranking = final.duplicate()
	_event("session_finished")


@rpc("authority", "call_local", "reliable")
func _rpc_unfreeze() -> void:
	for p: Player in stage.players.values():
		p.frozen = false
	_event("unfrozen")


func _physics_process(delta: float) -> void:
	var me := stage.get_player(Net.local_slot())
	if me == null:
		return
	me.intent.action_pressed = false
	if _walk_left > 0.0:
		me.intent.move = _walk_dir
		_walk_left -= delta
		if _walk_left <= 0.0:
			me.intent.move = Vector2.ZERO
			_walks_done += 1
		return
	if _shove_target >= 0:
		var target := stage.get_body(_shove_target)
		if target == null:
			_shove_target = -1
			return
		var to := target.global_position - me.global_position
		to.y = 0.0
		if to.length() > 1.0:
			var d := to.normalized()
			me.intent.move = Vector2(d.x, d.z)
			return
		me.intent.move = Vector2.ZERO
		me.facing = to.normalized()
		me.intent.action_pressed = true
		_shove_target = -1
		_shoves_done += 1


func _process(delta: float) -> void:
	_age += delta
	_tx_accum += delta
	if _tx_accum >= 1.0:
		var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
		if enet and enet.host:
			_tx_bps = enet.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA) / _tx_accum
		_tx_accum = 0.0
	if _quit_at_ms > 0.0 and Time.get_unix_time_from_system() * 1000.0 >= _quit_at_ms and not _quitting:
		_event("quit_at")
		_quit()
		return
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
		"load":
			if parts[1] == "dev":
				stage.load_minigame_scene(load("res://dev/dev_arena.tscn") as PackedScene)
			else:
				stage.load_minigame(StringName(parts[1]))
		"unfreeze":
			_rpc_unfreeze.rpc()
		"walk":
			_walk_dir = Vector2(float(parts[1]), float(parts[2])).normalized()
			_walk_left = float(parts[3])
		"shove":
			_shove_target = int(parts[1])
		"eliminate":
			var p := stage.get_player(int(parts[1]))
			if p:
				p.eliminate(&"smoke")
		"session":
			Session.start_session(int(parts[1]))
		"knockout":
			var p := stage.get_player(int(parts[1]))
			if p and Session.current_minigame:
				Session.current_minigame.knock_out(p)
		"endround":
			var r: Array[int] = []
			for i in range(1, parts.size()):
				r.append(int(parts[i]))
			if Session.current_minigame:
				Session.current_minigame.finish(r)
		"quit":
			_quit()
		"quit_at":
			_quit_at_ms = float(parts[1])
		"extras":
			var mode := StringName(parts[2]) if parts.size() > 2 else &"wander"
			for x in stage.spawn_extras(int(parts[1])):
				BotBrain.of(x).configure_extra(mode, x.slot)
		"extras_mode":
			for x in stage.extras:
				BotBrain.of(x).configure_extra(StringName(parts[1]), x.slot)
		"freeze_extras":
			for x in stage.extras:
				x.frozen = parts[1] == "1"
		"despawn_extras":
			stage.despawn_extras()


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
		if not is_instance_valid(p):
			continue
		var pos := p.global_position
		ps[str(slot)] = {
			"x": pos.x, "y": pos.y, "z": pos.z, "alive": p.alive, "frozen": p.frozen,
			"auth": p.get_multiplayer_authority(), "local": p.is_authority(),
			"locked": p.control_locked,
		}
	var xs: Dictionary = {}
	for x in stage.extras:
		if not is_instance_valid(x):
			continue
		var xp := x.global_position
		xs[str(x.slot)] = {"x": xp.x, "y": xp.y, "z": xp.z, "alive": x.alive, "name": String(x.name),
			"auth": x.get_multiplayer_authority(), "local": x.is_authority()}
	var knocked: Array = stage.minigame.knocked_out if stage.minigame else []
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "load_id": stage.net_load_id,
		"scene": stage.minigame.scene_file_path if stage.minigame else "",
		"players": ps, "extras": xs, "tx_bps": _tx_bps, "knocked_out": knocked, "counts": _counts, "events": _events,
		"session_state": Session.state, "round_index": Session.round_index,
		"rounds": _rounds, "final_scores": _final_scores, "final_wins": _final_wins,
		"final_ranking": _final_ranking,
		"walks_done": _walks_done, "shoves_done": _shoves_done, "cmds_done": _cmds_done,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
