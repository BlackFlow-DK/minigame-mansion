extends Node
## Multi-process Net smoke actor, driven by game/net/dev/run_net_smoke.ps1. Run headless:
##   godot_console --headless --path game res://net/dev/net_smoke.tscn -- --role=host|client|scan
##       --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--proto=N] [--life=SEC]
## Writes <dir>/<name>.json (roster as seen here, events, discovered games) on every change and
## executes new lines of <dir>/<name>.cmd: `profile <name> <#rrggbb>`, `add_bot`, `fill_bots`,
## `in_progress 0|1`, `quit`. Quits by itself after join_failed, server_closed or --life seconds.

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 90.0
var _events: Array[String] = []
var _games: Array = []
var _cmds_done: int = 0
var _poll: float = 0.0
var _age: float = 0.0
var _quitting: bool = false


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
			"proto": Net._hello_version = int(v)
	Net.roster_changed.connect(_event.bind("roster"))
	Net.join_failed.connect(_on_join_failed)
	Net.server_closed.connect(_on_server_closed)
	Net.games_found.connect(_on_games_found)
	Net.set_local_profile(_name, {})
	match _role:
		"host":
			var err := Net.host_game("Smoke Game")
			_event("host_game:%s" % error_string(err))
			if err != OK:
				_quit()
		"client":
			_event("join_game:%s" % error_string(Net.join_game(_join)))
		"scan":
			Net.start_discovery()
			_event("scanning")


func _on_join_failed(reason: String) -> void:
	_event("join_failed:" + reason)
	_quit()


func _on_server_closed() -> void:
	_event("server_closed")
	_quit()


func _on_games_found(games: Array) -> void:
	_games = games
	_event("games")


func _process(delta: float) -> void:
	_age += delta
	if _age > _life:
		_event("life_expired")
		_quit()
		return
	_poll += delta
	if _poll < 0.1:
		return
	_poll = 0.0
	var path := _dir.path_join(_name + ".cmd")
	if not FileAccess.file_exists(path):
		return
	# Only complete lines: the runner may be mid-write.
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
		"profile":
			Net.set_local_profile(parts[1], {"primary": parts[2], "secondary": "#ffffff", "hat": "", "face": "", "neck": "", "back": ""})
		"add_bot":
			Net.add_bot()
		"fill_bots":
			while Net.add_bot() >= 0:
				pass
		"in_progress":
			Net.session_in_progress = parts[1] == "1"
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


func _roster_key() -> String:
	var slots := Net.roster.keys()
	slots.sort()
	var parts: PackedStringArray = []
	for s: int in slots:
		var p := Net.roster[s]
		parts.append("%d/%d/%s/%s/%s" % [s, p.peer_id, p.name, "bot" if p.is_bot else "human", p.loadout.get("primary", "")])
	return "|".join(parts)


func _write() -> void:
	if _dir == "":
		return
	var roster: Array = []
	for d: Dictionary in NetProtocol.roster_to_array(Net.roster):
		roster.append({"slot": d["slot"], "peer_id": d["peer_id"], "name": d["name"], "is_bot": d["is_bot"], "primary": d["loadout"].get("primary", "")})
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "is_host": Net.is_host(),
		"offline_peer": multiplayer.multiplayer_peer is OfflineMultiplayerPeer,
		"local_slot": Net.local_slot(), "in_progress": Net.session_in_progress,
		"roster_key": _roster_key(), "roster": roster, "games": _games, "events": _events,
		"cmds_done": _cmds_done, "quitting": _quitting,
	}
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
