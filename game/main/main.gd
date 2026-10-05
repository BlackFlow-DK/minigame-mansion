class_name MainApp
extends Node
## The game (main scene `res://main/main.tscn`). Owns the app flow and wires the systems
## together; each system keeps its own logic:
##
##   title --(host | join | play offline)--> lobby --START--> session rounds --> podium --> lobby
##   title / lobby pause --Training Room--> tutorial (offline: you + dummy bots) --> title | lobby
##
## - Stage (`Main/Stage`, the same node path on every peer, as player sync requires).
## - MenuRoot: title, join, lobby overlay and pause screens (drives Net / Session itself).
## - RoundUI: title card, HUD, results, podium. SessionSounds: countdown beeps, jingles.
##
## While this peer is in a game and `Session.state == LOBBY`, the host (or offline peer) loads
## the lobby hall through the Stage with `follow_roster` on: joiners appear and leavers
## disappear on every peer. Every peer unfreezes lobby players on `Stage.players_spawned`.
## When the session returns to LOBBY (the host's "Back to lobby" or the podium timing out) the
## podium closes on every peer. Leaving (or the host closing the game) clears the stage and the
## round UI; MenuRoot shows the title with its message. F11 / Alt+Enter toggle fullscreen.
##
## User args after `--`:
##   --sandbox | --minigame=<id> | --players=N   the offline dev sandbox (res://dev/sandbox.tscn)
##                                               instead of the game, exactly as before
## Dev / test args for the game itself:
##   --name=X            player name for this run
##   --offline           skip the title: offline game;  --auto-host: host a LAN game
##   --auto-join=ADDR    join ADDR ("ip" or "ip:port")
##   --bots=N            host/offline: add N bots once in the lobby
##   --auto-start=R      host/offline: start an R-round session once the lobby is up with
##                       at least `--min-players=M` players (default 2)
##   --round-time=S      shorten every round's time limit to S seconds (this peer's view)
##   --time-scale=X      Session.time_scale (phase timers run X times faster)
##   --fps=N             cap the frame rate (screenshots: frame counts map to seconds)
##   --round-minigame=ID every round plays minigame ID (Session.scene_override; screenshots)
##   --open-wardrobe     open the wardrobe once in the lobby
## Any of these dev args also keeps the run from saving the profile (user://profile.json).
##
## Training Room (res://tutorial/): `start_training()` (MenuRoot.training_requested) leaves any
## game, starts an offline roster with TrainingRoom.DUMMY_COUNT bots and loads the room through
## the Stage; this script runs its _setup/_start and ticks it like the lobby. Its finish panel
## (`exit_requested`) or the pause menu's Skip tutorial end it: back to the title, or on into
## an offline game. The first run (no profile yet) offers it once (MenuRoot.offer_training_once).

enum AppState { TITLE, LOBBY, ROUND, PODIUM, TRAINING }

signal app_state_changed(state: AppState)

const LOBBY_SCENE: PackedScene = preload("res://lobby/lobby.tscn")
const SANDBOX_SCENE := "res://dev/sandbox.tscn"
const TRAINING_SCENE := "res://tutorial/training_room.tscn"
## Dev / test args; any of them makes this run leave the saved profile alone.
const DEV_ARGS: Array[String] = ["name", "offline", "auto-host", "auto-join", "bots", "auto-start", "round-time",
	"time-scale", "round-minigame", "open-wardrobe", "unlock-all", "coins"]

var app_state: AppState = AppState.TITLE

var _args: Dictionary = {}
var _bots_added: bool = false
var _auto_started: bool = false
var _wardrobe_opened: bool = false
## True while the Training Room runs.
var _training: bool = false

@onready var stage: Stage = $Stage
@onready var menu: MenuRoot = $MenuRoot
@onready var round_ui: RoundUI = $RoundUI


func _ready() -> void:
	_args = parse_user_args(OS.get_cmdline_user_args())
	if wants_sandbox(_args):
		get_tree().change_scene_to_file.call_deferred(SANDBOX_SCENE)
		return
	Net.roster_changed.connect(_refresh)
	Net.server_closed.connect(_refresh)
	Session.state_changed.connect(_on_session_state_changed)
	Session.round_intro.connect(_on_round_intro)
	stage.players_spawned.connect(_on_players_spawned)
	round_ui.back_to_lobby_pressed.connect(_on_back_to_lobby)
	menu.training_requested.connect(start_training)
	menu.training_skip_requested.connect(end_training.bind(false))
	Sfx.attach_ui(menu.root)
	var round_root := round_ui.get_node_or_null(^"Root") as Control
	if round_root:
		Sfx.attach_ui(round_root)
	for key in DEV_ARGS:
		if _args.has(key):
			menu.persist_profile = false
	if _args.has("fps"):
		Engine.max_fps = int(_args["fps"])
	if _args.has("round-minigame") and MinigameRegistry.has(StringName(_args["round-minigame"])):
		Session.scene_override = load(MinigameRegistry.scene_path(StringName(_args["round-minigame"]))) as PackedScene
	if _args.has("time-scale"):
		Session.time_scale = maxf(0.01, float(_args["time-scale"]))
	_refresh()
	_run_dev_args.call_deferred()
	if not _args.has("screenshot"):
		menu.offer_training_once.call_deferred()  # checks menu.persist_profile (off for dev/test runs)


## `--key=value` / `--flag` user args -> {key: value | ""}.
static func parse_user_args(args: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	for arg in args:
		if not arg.begins_with("--"):
			continue
		var kv := arg.trim_prefix("--").split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else ""
	return out


## The old sandbox args (and `--sandbox`) still open the dev sandbox from the main scene.
static func wants_sandbox(args: Dictionary) -> bool:
	return args.has("sandbox") or args.has("minigame") or args.has("players")


func _input(event: InputEvent) -> void:
	# In _input, not _unhandled_input: Alt+Enter must not also press a focused button.
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_F11 or (k.keycode == KEY_ENTER and k.alt_pressed):
		toggle_fullscreen()
		get_viewport().set_input_as_handled()


## Through Settings, so the choice is saved and the settings screen shows it.
func toggle_fullscreen() -> void:
	var fs := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	Settings.set_value(&"fullscreen", not fs)


# --- App flow ------------------------------------------------------------------------------

## Re-derives what the world should show from Net and Session.
func _refresh() -> void:
	if Net.local_slot() < 0:
		# Not in a game (left, host closed it, or still joining): nothing in the world.
		if stage.minigame != null or not stage.players.is_empty():
			stage.clear()
		stage.follow_roster = false
		round_ui.reset()
		_bots_added = false
		_auto_started = false
	elif _training:
		pass  # the Training Room owns the stage until it ends
	elif Session.state == Session.State.LOBBY and Net.is_host() and not (stage.minigame is MansionLobby):
		_load_lobby()
	_update_app_state()
	_maybe_auto_start()


func _load_lobby() -> void:
	stage.follow_roster = true
	stage.load_minigame_scene(LOBBY_SCENE)  # players_spawned unfreezes them


func _on_players_spawned(spawned: Array[Player]) -> void:
	var room := stage.minigame as TrainingRoom
	if room:
		room._setup(spawned)
		for p in spawned:
			if is_instance_valid(p):
				p.frozen = false
		room._start()
		return
	var lobby := stage.minigame as MansionLobby
	if lobby == null:
		return  # a round: Session unfreezes after the countdown
	lobby._setup(spawned)
	for p in spawned:
		if is_instance_valid(p):
			p.frozen = false


func _physics_process(delta: float) -> void:
	var room := stage.minigame as TrainingRoom
	if room and _training:
		room._host_tick(delta)
		return
	# The lobby is a Minigame that never finishes; nobody else ticks it.
	var lobby := stage.minigame as MansionLobby
	if lobby and Net.is_host() and Session.state == Session.State.LOBBY and not lobby.is_finished():
		lobby._host_tick(delta)


func _on_session_state_changed(state: int) -> void:
	if state == Session.State.LOBBY:
		_refresh()
		# The host went back (or the podium timed out): everyone's podium closes with it.
		if round_ui.view == RoundUI.View.PODIUM:
			round_ui.reset()
	_update_app_state()


func _on_back_to_lobby() -> void:
	if Session.state == Session.State.PODIUM:
		Session.return_to_lobby()  # host only; clients only see the button once in LOBBY
	elif Session.state == Session.State.LOBBY and Net.local_slot() >= 0 and menu.screen == MenuRoot.NONE:
		menu.show_screen(MenuRoot.LOBBY)
	_update_app_state()


func _on_round_intro(_info: Dictionary, _index: int) -> void:
	if _args.has("round-time") and Session.current_minigame:
		Session.current_minigame.time_limit = maxf(1.0, float(_args["round-time"]))


func _update_app_state() -> void:
	var s := AppState.TITLE
	if _training:
		s = AppState.TRAINING
	elif Net.local_slot() >= 0:
		match Session.state:
			Session.State.LOBBY:
				s = AppState.LOBBY
			Session.State.PODIUM:
				s = AppState.PODIUM
			_:
				s = AppState.ROUND
	if s != app_state:
		app_state = s
		app_state_changed.emit(s)


# --- Training Room ---------------------------------------------------------------------------

## Leaves any game and runs the Training Room (offline: you + the dummy bots).
func start_training() -> void:
	if _training:
		return
	var scene := load(TRAINING_SCENE) as PackedScene
	if scene == null:
		push_warning("MainApp: no Training Room scene")
		return
	if Net.local_slot() >= 0:
		menu.leave_game()
	menu.commit_profile()
	_training = true
	menu.in_training = true
	menu.show_screen(MenuRoot.NONE)
	Net.start_offline()
	for i in TrainingRoom.DUMMY_COUNT:
		Net.add_bot()
	stage.follow_roster = false
	var room := stage.load_minigame_scene(scene) as TrainingRoom  # players_spawned runs _setup/_start
	if room:
		room.exit_requested.connect(end_training)
	_update_app_state()


## Ends the Training Room: back to the title, or (`play_offline`) straight into an offline lobby.
func end_training(play_offline: bool = false) -> void:
	if not _training:
		return
	_training = false
	menu.in_training = false
	stage.clear()
	menu.leave_game()
	if play_offline:
		menu.play_offline()
	_update_app_state()


func is_training() -> bool:
	return _training


# --- Dev / test args -------------------------------------------------------------------------

func _run_dev_args() -> void:
	if _args.has("name"):
		menu.title.set_player_name(str(_args["name"]))
	if _args.has("offline"):
		menu.play_offline()
	elif _args.has("auto-host"):
		menu.title.host_button.pressed.emit()
	elif _args.has("auto-join"):
		menu.title.join_button.pressed.emit()
		menu.join.join_requested.emit(str(_args["auto-join"]))


func _maybe_auto_start() -> void:
	if Net.local_slot() < 0 or not Net.is_host() or Session.state != Session.State.LOBBY:
		return
	if _args.has("open-wardrobe") and not _wardrobe_opened and stage.minigame is MansionLobby:
		_wardrobe_opened = true
		menu.open_wardrobe.call_deferred()
	if _args.has("bots") and not _bots_added:
		_bots_added = true
		for i in int(_args["bots"]):
			Net.add_bot()  # re-enters _refresh through roster_changed
		return
	if _args.has("auto-start") and not _auto_started and stage.minigame is MansionLobby \
			and Net.roster.size() >= int(_args.get("min-players", "2")):
		_auto_started = true
		Session.start_session.call_deferred(maxi(1, int(_args["auto-start"])), Session.launch_time)  # like START
