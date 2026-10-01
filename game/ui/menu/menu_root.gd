class_name MenuRoot
extends CanvasLayer
## Menu UI root (menu_root.tscn): owns the title, join, lobby-overlay and pause screens and the
## transitions between them, driven by the `Net`, `Session` and `Cosmetics` autoloads only.
##
##   title --Host--> lobby          (Net.host_game; falls back to Net.start_offline with a note)
##   title --Join--> join --(roster gains our slot)--> lobby
##   title --Play offline--> lobby  (Net.start_offline: you + bots on this PC)
##   lobby --Session leaves LOBBY--> none (hidden) --Session back in LOBBY--> lobby
##   any --Net.server_closed--> title with a message;  Leave -> Net.leave() -> title
##   Esc/Start in lobby or in game: pause menu (the game keeps running)
##   title --How to play--> Training Room (MainApp runs it; `training_requested`); the first run
##   (no profile yet) offers it once; the lobby's pause menu offers it when only bots would be
##   left behind; in the Training Room the pause menu offers Skip tutorial
##
## The layout is designed at 1280x720 and scaled uniformly to the window, so it also works
## without a project stretch mode.

signal screen_changed(screen: StringName)
## The player wants the Training Room (How to play, the first-run prompt, the lobby pause menu).
signal training_requested
## Pause menu in the Training Room: Skip tutorial.
signal training_skip_requested

const WARDROBE_PATH := "res://ui/wardrobe/wardrobe.tscn"
const JOIN_TIMEOUT_SEC := 12.0
## Remembers that the first-run Training Room prompt was shown (never asked twice).
const TRAINING_FLAG_PATH := "user://training_prompt.cfg"
## Appended to join failures that can be a firewall block.
const FIREWALL_HINT := " Check that both PCs allow Minigame Mansion through Windows Firewall on Private AND Public networks, and try the host's IP address (shown in the host's lobby)."

const TITLE := &"title"
const JOIN := &"join"
const LOBBY := &"lobby"
const WARDROBE := &"wardrobe"
## In a game but outside the lobby state: nothing shown (the pause menu can still open).
const NONE := &"none"

var screen: StringName = &""
var root: Control
var backdrop: MenuBackdrop
var title: MenuTitleScreen
var join: MenuJoinScreen
var lobby: MenuLobbyOverlay
var pause: MenuPauseMenu
## True when hosting fell back to an offline game.
var offline_game: bool = false
## False: the name / loadout are only handed to Net, never saved to the profile file (dev and
## test runs set it so `--name=` and friends leave `user://profile.json` alone).
var persist_profile: bool = true
## True while MainApp runs the Training Room (pause menu: Skip tutorial).
var in_training: bool = false
## Where the first-run prompt flag lives (tests point it elsewhere).
var training_flag_path: String = TRAINING_FLAG_PATH

var _loadout: Dictionary = {}
var _lobby_note: String = ""
var _join_timer: Timer
var _wardrobe_layer: CanvasLayer
var _wardrobe: Node = null
## Screen to return to when the wardrobe closes (title, or lobby when opened in a game).
var _wardrobe_return: StringName = TITLE
var _first_run_name: String = ""


func _ready() -> void:
	root = Control.new()
	root.name = "Root"
	root.theme = load(MenuUI.THEME_PATH) as Theme
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	backdrop = MenuUI.full_rect(MenuBackdrop.new()) as MenuBackdrop
	backdrop.name = "Backdrop"
	root.add_child(backdrop)
	title = MenuTitleScreen.new()
	join = MenuJoinScreen.new()
	lobby = MenuLobbyOverlay.new()
	pause = MenuPauseMenu.new()
	for c: Control in [title, join, lobby, pause]:
		c.visible = false
		root.add_child(c)

	_join_timer = Timer.new()
	_join_timer.one_shot = true
	_join_timer.wait_time = JOIN_TIMEOUT_SEC
	_join_timer.timeout.connect(_on_join_timeout)
	add_child(_join_timer)
	_wardrobe_layer = CanvasLayer.new()
	_wardrobe_layer.name = "WardrobeLayer"
	_wardrobe_layer.layer = layer + 1
	add_child(_wardrobe_layer)

	title.host_pressed.connect(_on_host)
	title.join_pressed.connect(_on_join_menu)
	title.offline_pressed.connect(play_offline)
	title.wardrobe_pressed.connect(open_wardrobe)
	title.quit_pressed.connect(_quit)
	title.name_committed.connect(_on_name_committed)
	title.how_to_play_pressed.connect(func() -> void: training_requested.emit())
	title.training_prompt_answered.connect(_on_training_prompt_answered)
	join.join_requested.connect(_on_join_requested)
	join.back_pressed.connect(_on_join_back)
	join.cancel_pressed.connect(_on_join_cancel)
	lobby.start_pressed.connect(_on_start)
	lobby.add_bot_pressed.connect(_on_add_bot)
	lobby.remove_bot_pressed.connect(_on_remove_bot)
	lobby.leave_pressed.connect(leave_game)
	lobby.wardrobe_pressed.connect(open_wardrobe)
	pause.resume_pressed.connect(close_pause)
	pause.leave_pressed.connect(leave_game)
	pause.quit_pressed.connect(_quit)
	pause.training_pressed.connect(func() -> void: training_requested.emit())
	pause.skip_tutorial_pressed.connect(func() -> void:
		close_pause()
		training_skip_requested.emit())

	Net.roster_changed.connect(_on_roster_changed)
	Net.games_found.connect(_on_games_found)
	Net.join_failed.connect(_on_join_failed)
	Net.server_closed.connect(_on_server_closed)
	Session.state_changed.connect(_on_session_state_changed)

	get_viewport().size_changed.connect(_apply_ui_scale)
	_apply_ui_scale()
	_load_profile()
	title.set_wardrobe_available(ResourceLoader.exists(WARDROBE_PATH))
	lobby.wardrobe_button.visible = ResourceLoader.exists(WARDROBE_PATH)
	if _in_game():
		_enter_lobby()
	else:
		show_screen(TITLE)


func show_screen(s: StringName) -> void:
	screen = s
	backdrop.visible = s == TITLE or s == JOIN or s == WARDROBE
	title.visible = s == TITLE
	join.visible = s == JOIN
	lobby.visible = s == LOBBY
	if s != LOBBY and s != NONE:
		pause.visible = false
	match s:
		TITLE:
			title.focus_default()
		JOIN:
			join.focus_default()
		LOBBY:
			_refresh_lobby()
			_release_focus()
	screen_changed.emit(s)


func open_pause() -> void:
	pause.configure(in_training, can_open_training())
	pause.visible = true
	pause.focus_default()


func close_pause() -> void:
	pause.visible = false
	_release_focus()


## The lobby's pause menu offers the Training Room only when nobody else would be left behind
## (an offline game, or a hosted one with only bots in it): going there leaves the game.
func can_open_training() -> bool:
	if in_training or screen != LOBBY or Session.state != Session.State.LOBBY or not _in_game():
		return false
	for slot: int in Net.roster:
		if slot != Net.local_slot() and not Net.roster[slot].is_bot:
			return false
	return true


## Hands the title's name and look to Net (and saves them when allowed), as Host / Join do.
func commit_profile() -> void:
	_commit_profile()


## First run (no profile file yet, never asked before): shows "New here? Try the Training
## Room" once. Returns true if it was shown. Dev and test runs (`persist_profile` off) never ask.
func offer_training_once() -> bool:
	if not persist_profile or screen != TITLE or _in_game():
		return false
	if FileAccess.file_exists(Cosmetics.profile_path) or FileAccess.file_exists(training_flag_path):
		return false
	var cfg := ConfigFile.new()
	cfg.set_value("training", "prompted", true)
	cfg.save(training_flag_path)
	title.show_training_prompt()
	return true


func _on_training_prompt_answered(accepted: bool) -> void:
	if accepted:
		training_requested.emit()


## Leaves the current game (Net.leave) and returns to the title screen.
func leave_game() -> void:
	_join_timer.stop()
	pause.visible = false
	offline_game = false
	_lobby_note = ""
	Net.leave()
	title.show_message("")
	show_screen(TITLE)


## Join screen: shows "Connecting..." and arms the join timeout. Called after Net.join_game succeeded.
func set_connecting(address: String) -> void:
	join.set_connecting(address)
	_join_timer.start(JOIN_TIMEOUT_SEC)


## Opens the wardrobe scene (another system's) over the title or the lobby; returns there when
## it closes. In a game the wardrobe hands the new look to Net itself, so everyone sees it live;
## the local blob ignores input while it is open.
func open_wardrobe() -> void:
	if _wardrobe != null or not ResourceLoader.exists(WARDROBE_PATH):
		return
	_wardrobe_return = LOBBY if _in_game() else TITLE
	if _wardrobe_return == TITLE:
		_commit_profile()
	var ps := load(WARDROBE_PATH) as PackedScene
	if ps == null:
		title.show_message("The wardrobe could not be opened.")
		return
	_wardrobe = ps.instantiate()
	_wardrobe.add_to_group(&"blocks_player_input")
	_wardrobe.tree_exited.connect(_on_wardrobe_closed, CONNECT_ONE_SHOT)
	for sig: StringName in [&"closed", &"close_requested", &"done", &"back_pressed"]:
		if _wardrobe.has_signal(sig):
			_wardrobe.connect(sig, func(..._args: Array) -> void: close_wardrobe(), CONNECT_ONE_SHOT)
	_wardrobe_layer.add_child(_wardrobe)
	show_screen(WARDROBE)


func close_wardrobe() -> void:
	if _wardrobe != null and is_instance_valid(_wardrobe):
		_wardrobe.queue_free()


## Closes the wardrobe as if Done was pressed (keeps the edits), e.g. when a round starts.
func finish_wardrobe() -> void:
	if _wardrobe != null and is_instance_valid(_wardrobe):
		if _wardrobe.has_method(&"done"):
			_wardrobe.call(&"done")  # emits closed -> close_wardrobe
		else:
			close_wardrobe()


## This machine's IPv4 LAN addresses (private ranges first; loopback and link-local skipped).
static func lan_addresses() -> PackedStringArray:
	var private_ips: PackedStringArray = []
	var other: PackedStringArray = []
	for a in IP.get_local_addresses():
		if not a.contains(".") or a.begins_with("127.") or a.begins_with("169.254.") or a.begins_with("0."):
			continue
		var parts := a.split(".")
		var second := parts[1].to_int() if parts.size() > 1 else -1
		if a.begins_with("10.") or a.begins_with("192.168.") or (a.begins_with("172.") and second >= 16 and second <= 31):
			private_ips.append(a)
		else:
			other.append(a)
	private_ips.sort()
	return private_ips if not private_ips.is_empty() else other


# --- Title -------------------------------------------------------------------------------

func _on_host() -> void:
	_commit_profile()
	title.show_message("")
	var err := Net.host_game("%s's game" % title.player_name())
	offline_game = err != OK
	if offline_game:
		Net.start_offline()
		_lobby_note = "LAN hosting is not available right now, so this is an offline game: add bots to play."
	else:
		_lobby_note = ""
	_enter_lobby()


## Offline game on this PC (you + bots); also the fallback when hosting fails.
func play_offline() -> void:
	_commit_profile()
	title.show_message("")
	Net.start_offline()
	offline_game = true
	_lobby_note = "Offline game: add bots, then press START."
	_enter_lobby()


func _on_join_menu() -> void:
	_commit_profile()
	title.show_message("")
	join.reset()
	show_screen(JOIN)
	Net.start_discovery()


func _on_name_committed(player_name: String) -> void:
	if persist_profile:
		Cosmetics.save_profile(player_name, _loadout)


func _load_profile() -> void:
	var p := Cosmetics.load_profile()
	var n := str(p.get("name", ""))
	if n == "" or n == Cosmetics.DEFAULT_NAME:
		# First run (or never renamed): a friendly random name instead of everyone being
		# "Player"; the same one for the whole run, saved with the profile on Host / Join.
		if _first_run_name == "":
			_first_run_name = MenuTitleScreen.random_name()
		n = _first_run_name
	title.set_player_name(n)
	var l: Variant = p.get("loadout", {})
	_loadout = l as Dictionary if l is Dictionary and not (l as Dictionary).is_empty() else Cosmetics.default_loadout(0)


func _commit_profile() -> void:
	var n := title.player_name()
	if persist_profile:
		Cosmetics.save_profile(n, _loadout)
	# An untouched profile carries slot 0's default colours; sending it would make every
	# such player red. Send none instead, so the host gives each player its slot's colours.
	Net.set_local_profile(n, {} if _loadout == Cosmetics.default_loadout(0) else _loadout)


func _on_wardrobe_closed() -> void:
	_wardrobe = null
	if not is_inside_tree() or not Net.is_inside_tree():
		return  # the app is quitting with the wardrobe open
	_load_profile()
	if screen == WARDROBE:
		if _wardrobe_return == LOBBY and _in_game():
			_enter_lobby()
		else:
			show_screen(TITLE)


func _quit() -> void:
	get_tree().quit()


# --- Join --------------------------------------------------------------------------------

func _on_games_found(games: Array) -> void:
	join.update_games(games)


func _on_join_requested(address: String) -> void:
	var err := Net.join_game(address)
	if err != OK:
		join.show_error("Could not join %s: %s." % [address, _error_text(err)])
		return
	set_connecting(address)


func _on_join_failed(reason: String) -> void:
	if screen != JOIN:
		return
	_join_timer.stop()
	var text := "Could not join: %s" % (reason if reason.strip_edges() != "" else "the host did not accept the connection.")
	if reason == "timeout" or reason == "could not connect":
		text += "." + FIREWALL_HINT
	join.show_error(text)


func _on_join_timeout() -> void:
	if screen != JOIN or not join.is_connecting():
		return
	Net.leave()
	join.show_error(("No answer after %d seconds. Check the address, and that you are on the same network as the host." % int(JOIN_TIMEOUT_SEC)) + FIREWALL_HINT)


func _on_join_cancel() -> void:
	_join_timer.stop()
	Net.leave()
	join.stop_connecting()


func _on_join_back() -> void:
	_join_timer.stop()
	if join.is_connecting():
		Net.leave()
		join.stop_connecting()
	Net.stop_discovery()
	show_screen(TITLE)


static func _error_text(err: Error) -> String:
	match err:
		ERR_UNAVAILABLE:
			return "network play is not available in this build"
		ERR_CANT_RESOLVE:
			return "that address could not be found"
		ERR_ALREADY_IN_USE, ERR_ALREADY_EXISTS:
			return "already connected to a game"
		ERR_INVALID_PARAMETER:
			return "that does not look like an address"
	return error_string(err).to_lower()


# --- Lobby / game ----------------------------------------------------------------------

func _in_game() -> bool:
	return Net.local_slot() >= 0


func _enter_lobby() -> void:
	show_screen(LOBBY if Session.state == Session.State.LOBBY else NONE)


func _refresh_lobby() -> void:
	var host := Net.is_host()
	lobby.refresh(Net.roster, Net.local_slot(), host, Net.MAX_PLAYERS)
	var addrs := lan_addresses() if host and not offline_game else PackedStringArray()
	lobby.set_addresses(addrs, offline_game, _lobby_note)


func _on_roster_changed() -> void:
	if screen == JOIN and join.is_connecting() and _in_game():
		_join_timer.stop()
		Net.stop_discovery()
		join.stop_connecting()
		_enter_lobby()
		return
	if screen == LOBBY or screen == NONE:
		_refresh_lobby()


func _on_session_state_changed(state: int) -> void:
	if state != Session.State.LOBBY and screen == WARDROBE and _in_game():
		finish_wardrobe()  # a round is starting: keep the edits, get out of the way
	if state == Session.State.LOBBY:
		if _in_game() and screen == NONE:
			show_screen(LOBBY)
	elif screen == LOBBY:
		show_screen(NONE)


func _on_start(rounds: int) -> void:
	if Net.is_host() and Net.roster.size() >= MenuLobbyOverlay.MIN_PLAYERS:
		Session.start_session(rounds)


func _on_add_bot() -> void:
	if Net.is_host():
		Net.add_bot()


func _on_remove_bot(slot: int) -> void:
	if Net.is_host():
		Net.remove_bot(slot)


func _on_server_closed() -> void:
	_join_timer.stop()
	pause.visible = false
	offline_game = false
	_lobby_note = ""
	Net.stop_discovery()
	if screen == JOIN and join.is_connecting():
		join.show_error("Could not join: the host closed the connection.")
		return
	title.show_message("The host closed the game.")
	show_screen(TITLE)


# --- Input -------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# A mouse click on a lobby button leaves it focused, which would keep the blob from moving
	# (ControllerComponent ignores input while a control has focus): mouse users need no focus.
	var mb := event as InputEventMouseButton
	if mb and not mb.pressed and screen == LOBBY and not pause.visible and _focus_in(lobby):
		# Deferred: the button acts on this release first (it may leave the lobby screen).
		(func() -> void:
			if screen == LOBBY and not pause.visible and _focus_in(lobby):
				_release_focus()).call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if pause.visible:
		if event.is_action_pressed(&"pause") or event.is_action_pressed(&"ui_cancel"):
			close_pause()
			get_viewport().set_input_as_handled()
		return
	match screen:
		LOBBY, NONE:
			if screen == LOBBY and _is_lobby_focus_toggle(event):
				if _focus_in(lobby):
					_release_focus()
				else:
					lobby.focus_default()
				get_viewport().set_input_as_handled()
			elif screen == LOBBY and event.is_action_pressed(&"ui_cancel") and _focus_in(lobby):
				_release_focus()
				get_viewport().set_input_as_handled()
			elif event.is_action_pressed(&"pause") and _in_game():
				open_pause()
				get_viewport().set_input_as_handled()
		JOIN:
			if event.is_action_pressed(&"ui_cancel"):
				_on_join_back()
				get_viewport().set_input_as_handled()
		WARDROBE:
			if event.is_action_pressed(&"ui_cancel"):
				close_wardrobe()
				get_viewport().set_input_as_handled()


## In the lobby the world is playable and Space / A both jump and press the focused button,
## so the overlay holds no focus until the player asks for it: Tab (keyboard) or Back/Select (pad).
static func _is_lobby_focus_toggle(event: InputEvent) -> bool:
	if event is InputEventKey:
		var k := event as InputEventKey
		return k.pressed and not k.echo and k.keycode == KEY_TAB
	if event is InputEventJoypadButton:
		var j := event as InputEventJoypadButton
		return j.pressed and j.button_index == JOY_BUTTON_BACK
	return false


func _focus_in(c: Control) -> bool:
	var f := root.get_viewport().gui_get_focus_owner()
	return f != null and c.is_ancestor_of(f)


func _release_focus() -> void:
	var f := root.get_viewport().gui_get_focus_owner()
	if f != null and root.is_ancestor_of(f):
		f.release_focus()


func _apply_ui_scale() -> void:
	var vs := get_viewport().get_visible_rect().size
	var s := clampf(minf(vs.x / MenuUI.DESIGN_SIZE.x, vs.y / MenuUI.DESIGN_SIZE.y), 0.5, 4.0)
	scale = Vector2(s, s)
	root.position = Vector2.ZERO
	root.size = vs / s
