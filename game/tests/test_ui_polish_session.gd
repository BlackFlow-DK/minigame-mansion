extends GameTest
## Through the real main scene and a real offline Session (not the round UI dev scene):
## the podium shows Session's final ranking in order with matching totals, and a minigame's
## end grace (`finish(ranking, grace)`) holds PLAYING, everyone frozen, before RESULTS.

const MAIN_SCENE_PATH := "res://main/main.tscn"
const DEV_ARENA_SCENE: PackedScene = preload("res://dev/dev_arena.tscn")

var app: MainApp
var _connections: Array = []
var _saved_profile_path: String = ""
var _saved_podium_time: float = 8.0


func before_each() -> void:
	Net.leave()
	Session.abort_session()
	Session.time_scale = 20.0
	Session.order_seed = 99
	Session.scene_override = DEV_ARENA_SCENE
	_saved_podium_time = Session.podium_time
	Session.podium_time = 1000.0
	_saved_profile_path = Cosmetics.profile_path
	Cosmetics.profile_path = "user://test_ui_polish_session_profile.json"
	app = (load(MAIN_SCENE_PATH) as PackedScene).instantiate() as MainApp
	add_child(app)
	app.menu.persist_profile = false
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
	Session.scene_override = null
	Session.podium_time = _saved_podium_time
	if FileAccess.file_exists(Cosmetics.profile_path):
		DirAccess.remove_absolute(Cosmetics.profile_path)
	Cosmetics.profile_path = _saved_profile_path
	if is_instance_valid(app):
		app.stage.clear()
		remove_child(app)
		app.queue_free()
	Net.leave()


func _on(sig: Signal, cb: Callable) -> void:
	sig.connect(cb)
	_connections.append([sig, cb])


func _wait(cond: Callable, max_frames: int = 900) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await step(1)
	return cond.call()


func _offline_with_bots(bots: int) -> void:
	app.menu.title.offline_button.pressed.emit()
	await step(2)
	for i in bots:
		app.menu.lobby.add_bot_button.pressed.emit()
		await step(1)
	await step(2)


func test_podium_follows_the_final_ranking() -> void:
	await _offline_with_bots(3)
	# Three decided rounds: totals 0:4, 1:7, 2:9, 3:10, so the final order is 3, 2, 1, 0
	# (the reverse of slot order, unlike any dev data).
	var rounds: Array = [[2, 3, 0, 1], [3, 2, 1, 0], [1, 3, 2, 0]]
	_on(Session.round_started, func() -> void:
		var r: Array[int] = []
		r.assign(rounds[Session.round_index])
		Session.current_minigame.finish(r))
	var done := watch(Session, &"session_finished")
	Session.start_session(3)
	assert_true(await _wait(func() -> bool: return Session.state == Session.State.PODIUM, 60 * 60), "podium reached")
	assert_eq(done.size(), 1, "session_finished once")
	if done.is_empty():
		return
	var final: Array = done[0][0]
	assert_eq(final, [3, 2, 1, 0], "Session's final ranking")
	assert_eq(Session.scores, {0: 4, 1: 7, 2: 9, 3: 10} as Dictionary[int, int], "totals")
	var podium := app.round_ui.podium
	assert_eq(app.round_ui.view, RoundUI.View.PODIUM, "podium shown")
	assert_eq(podium.final_ranking, [3, 2, 1, 0] as Array[int], "podium order == final ranking")
	for i in range(1, final.size()):
		assert_true(Session.scores[final[i - 1]] >= Session.scores[final[i]], "totals never rise down the podium")
	# The blocks: 1st (centre) 10 pts, 2nd (left) 9 pts, 3rd (right) 7 pts; 4th in the row below.
	var pts := _labels_ending(podium, " pts")
	var want := {0: "10 pts", 1: "9 pts", 2: "7 pts"}
	for place: int in want:
		var col_x := RoundPodium.COLUMN_X[place]
		var found := ""
		for l: Label in pts:
			var x := l.get_global_rect().get_center().x - podium.get_global_rect().get_center().x + RoundPodium.STAGE_SIZE.x * 0.5
			if absf(x - col_x) < RoundPodium.BLOCK_W * 0.5:
				found = l.text
		assert_eq(found, want[place], "place %d block" % (place + 1))


func _labels_ending(root: Node, suffix: String) -> Array[Label]:
	var out: Array[Label] = []
	for n in root.find_children("*", "Label", true, false):
		if (n as Label).text.ends_with(suffix):
			out.append(n as Label)
	return out


func test_end_grace_holds_playing_then_results() -> void:
	await _offline_with_bots(2)
	Session.time_scale = 2.0
	var grace := 1.0
	_on(Session.round_started, func() -> void:
		var mg := Session.current_minigame
		mg.time_limit = 0.05  # the backstop would end the round almost at once
		var r: Array[int] = [2, 0, 1]
		mg.finish(r, grace))
	var results := watch(Session, &"round_finished")
	Session.start_session(1)
	assert_true(await _wait(func() -> bool: return Session.end_grace > 0.0, 600), "end grace started")
	assert_eq(Session.state, Session.State.PLAYING, "still PLAYING during the grace")
	for slot: int in app.stage.players:
		assert_true(app.stage.players[slot].frozen, "slot %d frozen" % slot)
	var frames := 0
	while Session.state == Session.State.PLAYING and frames < 300:
		await step(1)
		frames += 1
	assert_eq(Session.state, Session.State.RESULTS, "then RESULTS")
	# grace 1.0 s at time_scale 2 = 0.5 s = ~30 frames (the backstop did not cut it short).
	assert_true(frames >= 26 and frames <= 34, "held for the grace (%d frames)" % frames)
	assert_eq(results.size(), 1, "one round_finished")
	if not results.is_empty():
		assert_eq(results[0][0], [2, 0, 1] as Array[int], "the minigame's ranking")
	assert_near(Session.end_grace, 0.0, 0.0001, "grace cleared")


func test_finish_without_grace_goes_straight_to_results() -> void:
	await _offline_with_bots(1)
	var at: Dictionary = {}
	_on(Session.round_started, func() -> void:
		at["started"] = Engine.get_physics_frames()
		var r: Array[int] = [1, 0]
		Session.current_minigame.finish(r))
	_on(Session.round_finished, func(_r: Array[int], _p: Dictionary) -> void:
		at["results"] = Engine.get_physics_frames()
		at["grace"] = Session.end_grace)
	Session.start_session(1)
	assert_true(await _wait(func() -> bool: return at.has("results"), 600), "results")
	assert_true(int(at.get("results", 0)) - int(at.get("started", -100)) <= 1, "no grace: RESULTS at once")
	assert_near(float(at.get("grace", -1.0)), 0.0, 0.0001, "no grace")
