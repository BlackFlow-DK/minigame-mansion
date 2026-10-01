extends GameTest
## The Training Room inside the real main scene: How to play on the title, the one-time
## first-run prompt, the lobby pause menu's Training Room, Skip tutorial (back to the title),
## and the finish panel's Play offline / Back to title.

const MAIN_SCENE_PATH := "res://main/main.tscn"
const FLAG_PATH := "user://test_training_prompt.cfg"
const PROFILE_PATH := "user://test_training_profile.json"

var app: MainApp
var _saved_profile_path: String = ""
var _saved_coins: int = 0
var _saved_claimed: Array[String] = []


func before_each() -> void:
	Net.leave()
	Session.abort_session()
	_saved_coins = Progression.coins
	_saved_claimed = Progression.claimed.duplicate()
	_saved_profile_path = Cosmetics.profile_path
	Cosmetics.profile_path = PROFILE_PATH
	_remove(PROFILE_PATH)
	_remove(FLAG_PATH)
	app = (load(MAIN_SCENE_PATH) as PackedScene).instantiate() as MainApp
	add_child(app)
	app.menu.persist_profile = false  # never write the real user://profile.json
	app.menu.training_flag_path = FLAG_PATH
	await step(2)


func after_each() -> void:
	if is_instance_valid(app):
		app.end_training()
		app.stage.clear()
		remove_child(app)
		app.queue_free()
	Net.leave()
	_remove(PROFILE_PATH)
	_remove(FLAG_PATH)
	Cosmetics.profile_path = _saved_profile_path
	Progression.coins = _saved_coins
	Progression.claimed = _saved_claimed


static func _remove(path: String) -> void:
	for suffix: String in ["", ".bak", ".tmp", ".corrupt"]:  # the file and its crash-safe save sidecars
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))


func _room() -> TrainingRoom:
	return app.stage.minigame as TrainingRoom


func _in_training() -> void:
	assert_true(app.is_training(), "training running")
	assert_true(_room() != null, "the Training Room is loaded through the Stage")
	assert_eq(app.stage.players.size(), 1 + TrainingRoom.DUMMY_COUNT, "you + the dummies")
	assert_eq(app.menu.screen, MenuRoot.NONE, "no menu screen over the course")
	assert_eq(app.app_state, MainApp.AppState.TRAINING, "app state")
	var me := app.stage.get_player(Net.local_slot())
	assert_true(me != null and not me.frozen and not me.is_bot, "you can move")


func _assert_title() -> void:
	assert_false(app.is_training(), "training over")
	assert_eq(app.menu.screen, MenuRoot.TITLE, "title screen")
	assert_true(app.stage.minigame == null and app.stage.players.is_empty(), "stage cleared")
	assert_eq(Net.local_slot(), -1, "not in a game")
	assert_eq(app.app_state, MainApp.AppState.TITLE, "app state title")


func test_how_to_play_then_skip_returns_to_the_title() -> void:
	assert_true(app.menu.title.how_to_play_button.visible, "How to play on the title")
	app.menu.title.how_to_play_button.pressed.emit()
	await step(3)
	_in_training()
	# Esc: the pause menu offers Skip tutorial instead of Leave game.
	app.menu.open_pause()
	assert_true(app.menu.pause.skip_tutorial_button.visible, "Skip tutorial shown")
	assert_false(app.menu.pause.leave_button.visible, "Leave game hidden")
	assert_false(app.menu.pause.training_button.visible, "no Training Room entry inside it")
	app.menu.pause.skip_tutorial_button.pressed.emit()
	await step(3)
	assert_false(app.menu.pause.visible, "pause closed")
	_assert_title()
	# The room ticks while it runs, and nothing is left ticking after.
	app.menu.title.offline_button.pressed.emit()
	await step(3)
	assert_true(app.stage.minigame is MansionLobby, "Play offline still reaches the lobby")


func test_finish_panel_play_offline_goes_to_the_lobby() -> void:
	app.start_training()
	await step(3)
	var room := _room()
	room.jump_to_station(TrainingRoom.Id.FINISH)
	var me := room.human
	me.place_at(Transform3D(Basis(), room.stations[TrainingRoom.Id.FINISH].target() + Vector3.UP * 0.05))
	for i in 120:
		if room.ui.is_finish_shown():
			break
		await step(1)
	assert_true(room.is_course_finished(), "course finished")
	assert_true(room.ui.is_finish_shown(), "finish panel")
	room.ui.play_button.pressed.emit()
	await step(3)
	assert_false(app.is_training(), "training over")
	assert_true(app.stage.minigame is MansionLobby, "offline lobby")
	assert_eq(app.menu.screen, MenuRoot.LOBBY, "lobby overlay")
	assert_eq(app.stage.players.size(), 1, "just you: the dummies are gone")


func test_finish_panel_back_to_title() -> void:
	app.start_training()
	await step(3)
	_room().request_exit(false)
	await step(3)
	_assert_title()


func test_first_run_prompt_shows_once() -> void:
	app.menu.persist_profile = true  # a real first run (the profile path is a test file)
	assert_true(app.menu.offer_training_once(), "first run: the prompt shows")
	assert_true(app.menu.title.is_training_prompt_visible(), "prompt visible")
	assert_true(app.menu.title.prompt_yes_button.has_focus(), "Yes focused")
	app.menu.title.prompt_yes_button.pressed.emit()
	await step(3)
	_in_training()
	app.end_training()
	await step(2)
	_assert_title()
	_remove(PROFILE_PATH)
	assert_false(app.menu.offer_training_once(), "never asked twice")
	assert_false(app.menu.title.is_training_prompt_visible(), "no prompt")


func test_first_run_prompt_no_thanks_and_dev_runs() -> void:
	app.menu.persist_profile = false
	assert_false(app.menu.offer_training_once(), "dev/test runs never ask")
	app.menu.persist_profile = true
	assert_true(app.menu.offer_training_once(), "asked")
	app.menu.title.prompt_no_button.pressed.emit()
	await step(2)
	assert_false(app.is_training(), "No thanks stays on the title")
	assert_eq(app.menu.screen, MenuRoot.TITLE, "title")
	assert_false(app.menu.offer_training_once(), "not again")


func test_lobby_pause_menu_opens_the_training_room() -> void:
	app.menu.title.offline_button.pressed.emit()
	await step(2)
	app.menu.lobby.add_bot_button.pressed.emit()
	await step(2)
	app.menu.open_pause()
	assert_true(app.menu.pause.training_button.visible, "Training Room in the lobby pause menu")
	assert_false(app.menu.pause.skip_tutorial_button.visible, "no Skip outside the tutorial")
	# Another human in the game: going would leave them behind, so no entry.
	Net.roster[6] = PlayerInfo.new(6, 77, "Bob", false, {})
	assert_false(app.menu.can_open_training(), "not with other humans in the game")
	Net.roster.erase(6)
	assert_true(app.menu.can_open_training(), "only bots: allowed")
	app.menu.pause.training_button.pressed.emit()
	await step(3)
	_in_training()
	assert_false(app.menu.pause.visible, "pause closed")
	assert_false(app.stage.follow_roster, "the course does not follow the roster")
