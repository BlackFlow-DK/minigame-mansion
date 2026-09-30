extends Node
## Multi-process full-game smoke actor, driven by game/main/dev/run_app_smoke.ps1.
## Runs the REAL main scene (child `Main`) and drives it through its menus:
##   godot_console --headless --path game res://main/dev/app_smoke.tscn -- --name=N --dir=<state dir>
##       [--port=PORT] [--bind-ip=127.0.0.1] [--life=SEC] [--time-scale=X] [--round-time=S]
## (`--name`, `--time-scale`, `--round-time` are read by main.gd itself.)
## Writes <dir>/<name>.json (what this peer's app shows: menu screen, message, Session, round
## UI panel, Stage players) ten times a second and runs new lines of <dir>/<name>.cmd:
##   host                    title: Host game
##   discover                title: Join game (LAN discovery starts)
##   join_found <port>       join screen: join the discovered game on <port>
##   join <addr>             title: Join game, then join <addr>
##   addbot                  lobby overlay: + Add bot
##   walk <x> <z> <secs>     own player walks along (x, z)
##   start <rounds>          lobby overlay: pick rounds, START!
##   first_round <id>        host: pick Session.order_seed so round 1 plays minigame <id>
##   podium_time <secs>      Session.podium_time
##   knockout <slot>         host: current minigame knock_out
##   back                    podium: Back to lobby
##   leave                   lobby overlay: Leave
##   quit
## Every local controller is scripted (intent comes from the commands only).

var _name: String = "Player"
var _dir: String = ""
var _life: float = 180.0
var _events: Array[String] = []
var _games: Array = []
var _rounds: Array = []
var _final_scores: Dictionary = {}
var _cmds_done: int = 0
var _poll: float = 0.0
var _write_accum: float = 0.0
var _age: float = 0.0
var _quitting: bool = false
var _walk_dir: Vector2 = Vector2.ZERO
var _walk_left: float = 0.0
var _walks_done: int = 0
## Per round start: did this peer's Session drive the minigame the Stage shows (so it got
## _setup and _start), how many players it has, and the per-player tuning it applied.
var _round_starts: Array = []

@onready var app: MainApp = $Main


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		var v := kv[1] if kv.size() > 1 else ""
		match kv[0]:
			"name": _name = v
			"dir": _dir = v
			"life": _life = float(v)
	app.stage.players_spawned.connect(_on_players_spawned)
	Net.server_closed.connect(func() -> void: _event("server_closed"))
	Net.join_failed.connect(func(r: String) -> void: _event("join_failed:" + r))
	Net.games_found.connect(func(games: Array) -> void: _games = games)
	Session.round_started.connect(_on_round_started)
	Session.round_finished.connect(_on_round_finished)
	Session.session_finished.connect(_on_session_finished)
	app.menu.screen_changed.connect(func(s: StringName) -> void: _event("screen:" + s))
	_event("ready")


func _on_players_spawned(spawned: Array[Player]) -> void:
	for p in spawned:
		var c := p.get_component(&"controller") as ControllerComponent
		if c and not p.is_bot:
			c.scripted = true


func _on_round_started() -> void:
	var mg := app.stage.minigame
	_round_starts.append({
		"index": Session.round_index,
		"cm_ok": is_instance_valid(Session.current_minigame) and Session.current_minigame == mg,
		"players": mg.players.size() if mg else -1,
		"scene": mg.scene_file_path if mg else "",
		"tuning": _tuning(),
	})
	_event("round_started:%d" % Session.round_index)


## slot -> shove force: minigames tune components in _setup on every peer.
func _tuning() -> Dictionary:
	var out: Dictionary = {}
	for slot: int in app.stage.players:
		var p := app.stage.players[slot]
		var shove := p.get_component(&"shove") as ShoveComponent if is_instance_valid(p) else null
		out[str(slot)] = snappedf(shove.force, 0.01) if shove else -1.0
	return out


## Host-decided minigame state every peer must agree on at the end of a round.
func _minigame_state() -> String:
	var mg := app.stage.minigame
	if mg == null:
		return ""
	var rs: Variant = mg.get(&"ring_states")
	if rs != null:
		return "rings:" + str(rs)
	return ""


func _on_round_finished(ranking: Array[int], points: Dictionary) -> void:
	var pts: Dictionary = {}
	for s: Variant in points:
		pts[str(s)] = points[s]
	_rounds.append({"ranking": ranking, "points": pts,
		"scene": app.stage.minigame.scene_file_path if app.stage.minigame else "",
		"cm_ok": is_instance_valid(Session.current_minigame) and Session.current_minigame == app.stage.minigame,
		"mg_state": _minigame_state()})
	_event("round_finished")


func _on_session_finished(_final: Array[int]) -> void:
	_final_scores = {}
	for s: int in Session.scores:
		_final_scores[str(s)] = Session.scores[s]
	_event("session_finished")


func _physics_process(delta: float) -> void:
	var me := app.stage.get_player(Net.local_slot())
	if me == null:
		return
	if _walk_left > 0.0:
		me.intent.move = _walk_dir
		_walk_left -= delta
		if _walk_left <= 0.0:
			me.intent.move = Vector2.ZERO
			_walks_done += 1


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
	var menu := app.menu
	match parts[0]:
		"host":
			menu.title.host_button.pressed.emit()
		"discover":
			menu.title.join_button.pressed.emit()
		"join_found":
			for g: Variant in _games:
				var d := g as Dictionary
				if d and int(d.get("port", -1)) == int(parts[1]):
					menu.join.join_requested.emit(str(d["address"]))
					_event("joining:" + str(d["address"]))
					return
			_event("join_found:none")
		"join":
			menu.title.join_button.pressed.emit()
			menu.join.join_requested.emit(parts[1])
		"addbot":
			menu.lobby.add_bot_button.pressed.emit()
		"walk":
			_walk_dir = Vector2(float(parts[1]), float(parts[2])).normalized()
			_walk_left = float(parts[3])
		"first_round":
			for seed_value in 1000:
				var rng := RandomNumberGenerator.new()
				rng.seed = seed_value
				if Session.build_round_order(2, rng)[0] == StringName(parts[1]):
					Session.order_seed = seed_value
					_event("order_seed:%d" % seed_value)
					return
		"start":
			menu.lobby.selected_rounds = int(parts[1])
			menu.lobby.start_button.pressed.emit()
		"podium_time":
			Session.podium_time = float(parts[1])
		"knockout":
			var p := app.stage.get_player(int(parts[1]))
			if p and Session.current_minigame:
				Session.current_minigame.knock_out(p)
		"back":
			app.round_ui.podium.back_pressed.emit()
		"leave":
			menu.lobby.leave_button.pressed.emit()
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
	if _dir == "" or not is_node_ready():
		return
	var ps: Dictionary = {}
	for slot: int in app.stage.players:
		var p := app.stage.players[slot]
		if not is_instance_valid(p):
			continue
		var pos := p.global_position
		ps[str(slot)] = {
			"x": pos.x, "y": pos.y, "z": pos.z, "alive": p.alive, "frozen": p.frozen,
			"auth": p.get_multiplayer_authority(), "local": p.is_authority(), "bot": p.is_bot,
		}
	var roster: Dictionary = {}
	for slot: int in Net.roster:
		roster[str(slot)] = {"name": Net.roster[slot].name, "bot": Net.roster[slot].is_bot,
			"primary": str(Net.roster[slot].loadout.get("primary", ""))}
	var menu := app.menu
	var state := {
		"name": _name, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "roster": roster, "in_progress": Net.session_in_progress,
		"screen": String(menu.screen), "app_state": int(app.app_state),
		"message": menu.title.message_label.text if menu.title.message_panel.visible else "",
		"overlay_visible": menu.lobby.is_visible_in_tree(),
		"round_view": int(app.round_ui.view), "back_shown": app.round_ui.podium.is_back_button_shown(),
		"session_state": int(Session.state), "round_index": Session.round_index,
		"scene": app.stage.minigame.scene_file_path if app.stage.minigame else "",
		"follow_roster": app.stage.follow_roster, "load_id": app.stage.net_load_id,
		"players": ps, "games": _games.size(), "game_ports": _games.map(func(g: Variant) -> int: return int((g as Dictionary).get("port", -1))),
		"events": _events,
		"rounds": _rounds, "round_starts": _round_starts, "final_scores": _final_scores, "walks_done": _walks_done, "cmds_done": _cmds_done,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
