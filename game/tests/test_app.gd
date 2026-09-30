extends GameTest
## The main scene end to end, offline and headless: title -> Play offline -> lobby with bots
## -> a 2-round Session on the registry minigames -> podium -> back to the lobby, checking
## Session state, Stage contents and UI panels at each step. Also: leaving, the podium
## timing out, the sandbox args, and menus taking the human's input away from the blob.

const MAIN_SCENE_PATH := "res://main/main.tscn"

var app: MainApp
var _connections: Array = []
var _saved_podium_time: float = 8.0


func before_each() -> void:
	Net.leave()
	Session.abort_session()
	Session.time_scale = 50.0
	Session.order_seed = 4321
	_saved_podium_time = Session.podium_time
	app = (load(MAIN_SCENE_PATH) as PackedScene).instantiate() as MainApp
	add_child(app)
	await step(2)


func after_each() -> void:
	for c: Array in _connections:
		var sig: Signal = c[0]
		if sig.is_connected(c[1]):
			sig.disconnect(c[1])
	_connections.clear()
	Session.abort_session()
	Session.time_scale = 1.0
	Session.order_seed = -1
	Session.podium_time = _saved_podium_time
	if is_instance_valid(app):
		app.stage.clear()
		remove_child(app)
		app.queue_free()
	Net.leave()


# --- Helpers ---------------------------------------------------------------------------

func _on(sig: Signal, cb: Callable) -> void:
	sig.connect(cb)
	_connections.append([sig, cb])


func _wait(cond: Callable, max_frames: int = 900) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await step(1)
	return cond.call()


func _wait_state(s: int, max_frames: int = 900) -> bool:
	return await _wait(func() -> bool: return Session.state == s, max_frames)


func _players() -> Array[Player]:
	var out: Array[Player] = []
	for slot: int in app.stage.players:
		var p := app.stage.players[slot]
		if is_instance_valid(p):
			out.append(p)
	return out


func _all_frozen(value: bool) -> bool:
	var ps := _players()
	for p in ps:
		if p.frozen != value:
			return false
	return not ps.is_empty()


## Title -> Play offline -> 3 bots added from the lobby overlay.
func _to_lobby_with_bots(bots: int = 3) -> void:
	app.menu.title.offline_button.pressed.emit()
	await step(2)
	for i in bots:
		app.menu.lobby.add_bot_button.pressed.emit()
		await step(1)
	await step(2)


## Round 1 is decided by knock-outs (ranking 0,1,2,3); round 2 by the time-limit backstop
## (everyone survives and shares first place).
func _drive_rounds() -> void:
	_on(Session.round_intro, func(_info: Dictionary, index: int) -> void:
		if index == 1 and Session.current_minigame:
			Session.current_minigame.time_limit = 2.0)
	_on(Session.round_started, func() -> void:
		if Session.round_index == 0:
			for slot: int in [3, 2, 1]:
				Session.current_minigame.knock_out(app.stage.get_player(slot)))


# --- Tests -----------------------------------------------------------------------------

func test_starts_on_title_with_an_empty_stage() -> void:
	assert_eq(app.menu.screen, MenuRoot.TITLE, "screen")
	assert_eq(app.app_state, MainApp.AppState.TITLE, "app state")
	assert_true(app.stage.minigame == null and app.stage.players.is_empty(), "stage empty")
	assert_eq(app.round_ui.view, RoundUI.View.NONE, "round UI hidden")
	assert_true(app.menu.title.offline_button.visible, "Play offline on the title")


func test_full_offline_loop() -> void:
	Session.podium_time = 1000.0  # the host leaves the podium with its button, not by timeout
	app.menu.title.set_player_name("Wolfgang_Amadeus")
	await _to_lobby_with_bots(3)
	# Lobby: 4 blobs, unfrozen, following the roster, overlay up.
	assert_eq(app.menu.screen, MenuRoot.LOBBY, "lobby overlay")
	assert_eq(app.app_state, MainApp.AppState.LOBBY, "app state lobby")
	assert_true(app.stage.minigame is MansionLobby, "lobby loaded")
	assert_true(app.stage.follow_roster, "lobby follows the roster")
	assert_eq(app.stage.players.size(), 4, "4 blobs")
	assert_eq(app.menu.lobby.row_count(), 4, "4 roster rows")
	assert_true(_all_frozen(false), "lobby players unfrozen")
	var bot := app.stage.get_player(1)
	var bot_start := bot.global_position
	await step(150)
	assert_true(bot.global_position.distance_to(bot_start) > 0.5, "a lobby bot wanders (%s -> %s)" % [bot_start, bot.global_position])

	# Start a 2-round session from the overlay.
	_drive_rounds()
	var finished := watch(Session, &"round_finished")
	app.menu.lobby.selected_rounds = 2
	app.menu.lobby.start_button.pressed.emit()
	assert_true(await _wait_state(Session.State.INTRO), "round 1 intro")
	assert_eq(Session.round_count, 2, "round count")
	assert_true(Net.session_in_progress, "Net.session_in_progress set")
	assert_false(app.stage.follow_roster, "rounds do not follow the roster")
	assert_false(app.stage.minigame is MansionLobby, "a minigame replaced the lobby")
	assert_true(MinigameRegistry.has(StringName(app.stage.minigame.scene_file_path.get_file().get_basename())), "registry minigame loaded")
	assert_eq(app.stage.players.size(), 4, "4 players in the round")
	assert_true(_all_frozen(true), "frozen during the intro")
	assert_eq(app.menu.screen, MenuRoot.NONE, "overlay hidden in the round")
	assert_eq(app.round_ui.view, RoundUI.View.INTRO, "title card")
	assert_eq(app.app_state, MainApp.AppState.ROUND, "app state round")

	assert_true(await _wait_state(Session.State.RESULTS), "round 1 results")
	assert_eq(app.round_ui.view, RoundUI.View.RESULTS, "results panel")
	assert_true(await _wait(func() -> bool: return Session.state == Session.State.PLAYING and Session.round_index == 1), "round 2 playing")
	assert_true(_all_frozen(false), "unfrozen after the countdown")
	assert_eq(app.round_ui.view, RoundUI.View.HUD, "HUD")
	var card := app.round_ui.hud.get_card(0)
	assert_eq(card.full_name, "Wolfgang_Amadeus", "HUD card name")
	assert_true(card.get_name_text().ends_with("...") and card.get_name_text().length() < 16, "long name cut with an ellipsis: %s" % card.get_name_text())
	assert_true(await _wait_state(Session.State.PODIUM), "podium")
	assert_eq(finished.size(), 2, "two rounds finished")
	assert_eq(app.round_ui.view, RoundUI.View.PODIUM, "podium panel")
	assert_eq(app.app_state, MainApp.AppState.PODIUM, "app state podium")
	assert_eq(Session.scores, {0: 8, 1: 7, 2: 6, 3: 5} as Dictionary[int, int], "final scores")

	# The host's "Back to lobby": everyone back in the hall.
	app.round_ui.podium.back_pressed.emit()
	assert_true(await _wait_state(Session.State.LOBBY, 30), "back in LOBBY")
	await step(2)
	assert_true(app.stage.minigame is MansionLobby, "lobby reloaded")
	assert_eq(app.stage.players.size(), 4, "4 blobs again")
	assert_true(_all_frozen(false), "unfrozen again")
	assert_eq(app.menu.screen, MenuRoot.LOBBY, "overlay back")
	assert_eq(app.round_ui.view, RoundUI.View.NONE, "round UI hidden")
	assert_false(Net.session_in_progress, "Net.session_in_progress cleared")
	assert_eq(app.app_state, MainApp.AppState.LOBBY, "app state lobby again")


func test_podium_timeout_keeps_the_podium_until_dismissed() -> void:
	Session.podium_time = 0.5
	await _to_lobby_with_bots(1)
	_on(Session.round_intro, func(_info: Dictionary, _index: int) -> void:
		Session.current_minigame.time_limit = 1.0)
	Session.start_session(1)
	assert_true(await _wait_state(Session.State.PODIUM), "podium")
	assert_true(await _wait_state(Session.State.LOBBY, 120), "podium timed out to LOBBY")
	await step(2)
	assert_true(app.stage.minigame is MansionLobby, "lobby loaded under the podium")
	assert_eq(app.round_ui.view, RoundUI.View.PODIUM, "podium still up")
	assert_eq(app.menu.screen, MenuRoot.NONE, "no lobby overlay over the podium")
	assert_true(app.round_ui.podium.is_back_button_shown(), "back button shown")
	app.round_ui.podium.back_pressed.emit()
	await step(1)
	assert_eq(app.menu.screen, MenuRoot.LOBBY, "overlay after dismissing the podium")
	assert_eq(app.app_state, MainApp.AppState.LOBBY, "app state lobby")


func test_leave_returns_to_title_and_clears_everything() -> void:
	await _to_lobby_with_bots(2)
	Session.start_session(2)
	assert_true(await _wait_state(Session.State.PLAYING), "playing")
	app.menu.open_pause()
	app.menu.pause.leave_button.pressed.emit()
	await step(2)
	assert_eq(app.menu.screen, MenuRoot.TITLE, "title")
	assert_eq(Session.state, Session.State.LOBBY, "Session reset")
	assert_true(app.stage.minigame == null and app.stage.players.is_empty(), "stage cleared")
	assert_eq(app.round_ui.view, RoundUI.View.NONE, "round UI hidden")
	assert_eq(app.app_state, MainApp.AppState.TITLE, "app state title")
	# And back in: a fresh lobby.
	app.menu.title.offline_button.pressed.emit()
	await step(2)
	assert_true(app.stage.minigame is MansionLobby and app.stage.players.size() == 1, "fresh lobby")


func test_menus_take_input_away_from_the_blob() -> void:
	await _to_lobby_with_bots(1)
	var me := app.stage.get_player(Net.local_slot())
	Input.action_press(&"move_right")
	await step(2)
	assert_true(me.intent.move.length() > 0.5, "moves with no menu in use")
	app.menu.open_pause()
	await step(2)
	assert_near(me.intent.move.length(), 0.0, 0.001, "pause menu: no movement")
	app.menu.close_pause()
	await step(2)
	assert_true(me.intent.move.length() > 0.5, "moves again after resume")
	Input.action_release(&"move_right")
	# Focus in the lobby overlay (Tab): Space presses the button, the blob does not jump.
	app.menu.lobby.focus_default()
	Input.action_press(&"jump")
	await step(1)
	assert_false(me.intent.jump_pressed, "no jump while the overlay has focus")
	Input.action_release(&"jump")
	assert_true(app.menu.get_viewport().gui_get_focus_owner() != null, "overlay had focus")
	app.menu.get_viewport().gui_release_focus()
	await step(1)
	var y0 := me.global_position.y
	Input.action_press(&"jump")
	await step(8)
	Input.action_release(&"jump")
	assert_true(me.global_position.y > y0 + 0.2, "jumps again once the overlay lets go")


func test_sandbox_args_are_recognised() -> void:
	assert_true(MainApp.wants_sandbox(MainApp.parse_user_args(PackedStringArray(["--minigame=bumper_sumo", "--players=8"]))), "old sandbox args")
	assert_true(MainApp.wants_sandbox(MainApp.parse_user_args(PackedStringArray(["--sandbox"]))), "--sandbox")
	assert_false(MainApp.wants_sandbox(MainApp.parse_user_args(PackedStringArray(["--offline", "--bots=3"]))), "game args")
	assert_eq(MainApp.parse_user_args(PackedStringArray(["--auto-join=127.0.0.1:24600", "--x"])), {"auto-join": "127.0.0.1:24600", "x": ""}, "parse")
