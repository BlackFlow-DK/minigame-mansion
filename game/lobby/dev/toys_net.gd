extends Node
## Lobby toys multi-process check actor, driven by run_toys_net.ps1 (same pattern as
## game/minigames/blob_ball/dev/ball_net.gd).
##   godot_console --headless --path game res://lobby/dev/toys_net.tscn -- --role=host|client
##       --name=N --dir=<state dir> [--join=127.0.0.1:PORT] [--port=PORT] [--life=SEC]
## The host loads the lobby with Stage.follow_roster (as the app does); clients get it from the
## manifest. Every peer unfreezes players as they spawn. This peer's own blob is scripted: it
## stands still until a command moves it. Writes <dir>/<name>.json ten times a second (the
## toys' replicated state as this peer sees it) and runs new lines of <dir>/<name>.cmd:
##   kick               own blob steps in front of the ball, faces it and shoves
##   goal               host: the ball rolls into the blue goal
##   bell               own blob shoves the bell
##   photo              own blob shoves the photo button
##   seesaw_low         own blob stands on the -X end of the see-saw
##   seesaw_on          own blob stands on the +X end of the see-saw
##   jump_high          own blob drops onto the high end from above
##   park <i>           own blob goes to parking spot i
##   quit

const LOBBY_SCENE := "res://lobby/lobby.tscn"
const PARK: Array[Vector3] = [Vector3(-3.0, 0.0, 7.6), Vector3(-1.0, 0.0, 7.6), Vector3(1.0, 0.0, 7.6), Vector3(3.0, 0.0, 7.6)]

var _role: String = "client"
var _name: String = "Player"
var _dir: String = ""
var _join: String = ""
var _life: float = 180.0
var _events: Array[String] = []
var _cmds_done: int = 0
var _poll: float = 0.0
var _write_accum: float = 0.0
var _age: float = 0.0
var _quitting: bool = false
var _me: Player = null
var _press_in: int = -1
var _max_y: float = 0.0

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
	Net.set_local_profile(_name, {})
	if _role == "host":
		var err := Net.host_game("Toys Net")
		_event("host_game:%s" % error_string(err))
		if err != OK:
			_quit()
			return
		stage.follow_roster = true
		stage.load_minigame_scene(load(LOBBY_SCENE) as PackedScene)
	else:
		_event("join_game:%s" % error_string(Net.join_game(_join)))


func _lobby() -> MansionLobby:
	return stage.minigame as MansionLobby if stage else null


## As the app does (main.gd): the lobby's _setup for the new players, then unfreeze them.
func _on_players_spawned(spawned: Array) -> void:
	var lobby := _lobby()
	if lobby == null:
		return
	var typed: Array[Player] = []
	for v: Variant in spawned:
		var p := v as Player
		if p:
			typed.append(p)
	lobby._setup(typed)
	for p in typed:
		p.frozen = false


## This peer's own blob (found once the roster says which slot is ours), scripted.
func _find_me() -> Player:
	if _me and is_instance_valid(_me) and _me.is_inside_tree():
		return _me
	_me = null
	var p := stage.get_player(Net.local_slot()) if Net.local_slot() >= 0 else null
	if p == null or not p.is_authority():
		return null
	var c := p.get_component(&"controller") as ControllerComponent
	if c:
		c.scripted = true
	_me = p
	_event("me:%d" % p.slot)
	return _me


func _physics_process(_delta: float) -> void:
	if _find_me() == null:
		return
	_me.intent.clear()
	if _press_in >= 0:
		if _press_in == 0:
			_me.intent.action_pressed = true
		_press_in -= 1
	_max_y = maxf(_max_y, _me.global_position.y)


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


## Own blob to `pos`, facing `look_at` (on XZ), then (optionally) a shove a few frames later.
func _go(pos: Vector3, look_at: Vector3, shove: bool) -> void:
	if _find_me() == null:
		_event("no_blob")
		return
	var d := look_at - pos
	var basis := Basis(Vector3.UP, atan2(d.x, d.z)) if Vector2(d.x, d.z).length() > 0.01 else Basis()
	_me.place_at(Transform3D(basis, pos))
	_max_y = pos.y
	_press_in = 6 if shove else -1


func _run(cmd: String) -> void:
	var parts := cmd.split(" ", false)
	if parts.is_empty():
		return
	_event("cmd:" + cmd)
	var lobby := _lobby()
	if lobby == null and parts[0] != "quit":
		_event("no_lobby")
		return
	match parts[0]:
		"kick":
			var b := lobby.football.ball.pos
			_go(Vector3(b.x, 0.0, b.z + 1.05), Vector3(b.x, 0.0, b.z), true)
		"goal":
			if _role == "host":
				lobby.football.ball.pos = Vector3(9.4, 0.4, MansionLobby.Football.GOAL_Z)
				lobby.football.ball.vel = Vector3(7.0, 0.0, 0.0)
		"bell":
			var c := lobby.bell.position
			_go(c + Vector3(0.0, 0.0, 1.25), c, true)
		"photo":
			var c := lobby.photo.button_position()
			_go(c + Vector3(0.0, 0.0, 1.0), c, true)
		"seesaw_low":
			_go(lobby.seesaw.position + Vector3(-1.75, 1.0, 0.0), lobby.seesaw.position, false)
		"seesaw_on":
			_go(lobby.seesaw.position + Vector3(1.7, 1.0, 0.0), lobby.seesaw.position, false)
		"jump_high":
			var hx := 1.6 if lobby.seesaw.angle > 0.0 else -1.6
			_go(lobby.seesaw.position + Vector3(hx, 3.2, 0.0), lobby.seesaw.position, false)
		"park":
			var i := clampi(int(parts[1]) if parts.size() > 1 else 0, 0, PARK.size() - 1)
			_go(PARK[i], PARK[i] + Vector3.BACK, false)
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
	var lobby := _lobby()
	var state := {
		"name": _name, "role": _role, "peer_id": multiplayer.get_unique_id(), "local_slot": Net.local_slot(),
		"roster_size": Net.roster.size(), "players": stage.players.size() if stage else 0,
		"lobby": lobby != null, "events": _events, "me_max_y": _max_y,
	}
	if lobby:
		var fb := lobby.football
		state["toy_peers"] = lobby.toy_peers.size()
		state["ball"] = [fb.ball.pos.x, fb.ball.pos.y, fb.ball.pos.z]
		state["ball_speed"] = fb.ball.vel.length()
		state["kicks"] = fb.kick_log
		state["goals"] = fb.goal_log
		state["tonight"] = [MansionLobby.Football.tonight[0], MansionLobby.Football.tonight[1]]
		state["net_error"] = fb.net_error.duplicate()
		state["rings"] = lobby.bell.ring_log
		state["seesaw"] = lobby.seesaw.angle
		state["catapults"] = lobby.seesaw.catapult_count
		state["photos"] = lobby.photo.photo_count
		state["preview"] = String(lobby.portal_preview.current)
	var f := FileAccess.open(_dir.path_join(_name + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(state))
		f.close()
