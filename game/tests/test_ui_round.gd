extends GameTest
## Round UI: every Session signal shows the right panel, bar race order/values, eliminations,
## counters, banner, 2 and 8 players, name tags. Session is driven by emitting its signals.

const UI_SCENE: PackedScene = preload("res://ui/round/round_ui.tscn")
const NAME_TAG_SCENE: PackedScene = preload("res://ui/round/name_tag.tscn")

var ui: RoundUI = null


func before_each() -> void:
	_reset_session()


func after_each() -> void:
	if ui:
		remove_child(ui)
		ui.queue_free()
		ui = null
	_reset_session()


func _reset_session() -> void:
	Session.state = Session.State.LOBBY
	Session.scores.clear()
	Session.round_index = -1
	Session.round_count = 0
	Session.current_minigame = null


## Offline roster of `count` (slot 0 human, rest bots) unless one exists, then a RoundUI.
func _make_ui(count: int = 4) -> RoundUI:
	if Net.roster.size() != count:
		Net.start_offline()
		for i in count - 1:
			Net.add_bot()
	ui = UI_SCENE.instantiate() as RoundUI
	add_child(ui)
	return ui


func _assert_only(v: RoundUI.View, context: String) -> void:
	assert_eq(ui.view, v, "%s: view" % context)
	assert_eq(ui.intro.visible, v == RoundUI.View.INTRO, "%s: intro visible" % context)
	assert_eq(ui.hud.visible, v == RoundUI.View.HUD, "%s: hud visible" % context)
	assert_eq(ui.results.visible, v == RoundUI.View.RESULTS, "%s: results visible" % context)
	assert_eq(ui.podium.visible, v == RoundUI.View.PODIUM, "%s: podium visible" % context)


func _intro(index: int = 0) -> void:
	Session.round_index = index
	Session.round_intro.emit({"id": &"test", "title": "Bumper Sumo", "rule_text": "Shove everyone off."}, index)


func _seconds(s: float) -> int:
	return ceili(s * 60.0)


# --- Panels per signal ---------------------------------------------------------------

func test_starts_hidden() -> void:
	_make_ui(4)
	await step(2)
	_assert_only(RoundUI.View.NONE, "fresh")


func test_round_intro_shows_title_card_then_countdown() -> void:
	_make_ui(4)
	Session.round_count = 8
	_intro(2)
	await step(2)
	_assert_only(RoundUI.View.INTRO, "round_intro")
	assert_eq(ui.intro.get_title(), "BUMPER SUMO", "title")
	assert_eq(ui.intro.get_rule(), "Shove everyone off.", "rule")
	assert_eq(ui.intro.get_round_text(), "ROUND 3 OF 8", "round text")
	assert_eq(ui.intro.count_value, 0, "no countdown yet")
	var count_at := RoundIntroCard.CARD_IN + RoundIntroCard.CARD_HOLD + RoundIntroCard.CARD_PARK
	await step(_seconds(count_at + 0.2))
	assert_eq(ui.intro.count_value, 3, "countdown at 3")
	await step(_seconds(2.0))
	assert_eq(ui.intro.count_value, 1, "countdown at 1")
	_assert_only(RoundUI.View.INTRO, "still intro until round_started")


func test_round_started_shows_hud_with_timer() -> void:
	var ps := spawn_arena(4)
	get_minigame().time_limit = 30.0
	Session.current_minigame = get_minigame()
	Session.round_count = 4
	_make_ui(4)
	_intro(1)
	Session.round_started.emit()
	await step(2)
	_assert_only(RoundUI.View.HUD, "round_started")
	assert_true(ui.hud.is_timer_shown(), "timer shown with a time limit")
	await step(60)
	assert_near(ui.hud.get_time_left(), 29.0, 0.1, "time left after 1 s")
	for p in ps:
		assert_true(ui.hud.get_card(p.slot) != null, "card for slot %d" % p.slot)


func test_hud_hides_timer_without_time_limit() -> void:
	spawn_arena(2)
	get_minigame().time_limit = 0.0
	Session.current_minigame = get_minigame()
	_make_ui(2)
	_intro()
	Session.round_started.emit()
	await step(2)
	assert_false(ui.hud.is_timer_shown(), "no timer without a time limit")


func test_round_finished_shows_results_then_bar_race() -> void:
	_make_ui(4)
	# Totals already include this round's points (see RoundUI doc).
	Session.scores = {0: 5, 1: 9, 2: 4, 3: 3} as Dictionary[int, int]
	var ranking: Array[int] = [2, 3, 0, 1]
	var points := {2: 4, 3: 3, 0: 2, 1: 1}
	Session.round_finished.emit(ranking, points)
	await step(2)
	_assert_only(RoundUI.View.RESULTS, "round_finished")
	assert_false(ui.results.is_race_shown(), "ranking first")
	# Before the race the bars show the old totals: 1:8, 0:3, 2:0, 3:0.
	assert_eq(ui.results.get_bar_order(), [1, 0, 2, 3] as Array[int], "start order by old totals")
	assert_eq(ui.results.get_bar_value(2), 0, "slot 2 starts at its old total")
	await step(_seconds(RoundResults.TOTAL_SECONDS + 0.5))
	assert_true(ui.results.is_race_shown(), "bar race shown")
	assert_true(ui.results.is_race_done(), "bar race finished")
	var expected: Array[int] = [1, 0, 2, 3]
	assert_eq(ui.results.get_bar_order(), expected, "final order")
	assert_eq(ui.results.get_bar_screen_order(), expected, "final on-screen order")
	for slot: int in Session.scores:
		assert_eq(ui.results.get_bar_value(slot), Session.scores[slot], "final value of slot %d" % slot)


func test_bar_race_reorders_when_overtaken() -> void:
	_make_ui(3)
	Session.scores = {0: 6, 1: 5, 2: 8} as Dictionary[int, int]
	var ranking: Array[int] = [2, 0, 1]
	Session.round_finished.emit(ranking, {2: 4, 0: 3, 1: 0})
	await step(2)
	assert_eq(ui.results.get_bar_order(), [1, 2, 0] as Array[int], "old totals 5, 4, 3")
	await step(_seconds(RoundResults.TOTAL_SECONDS + 0.5))
	assert_eq(ui.results.get_bar_order(), [2, 0, 1] as Array[int], "new totals 8, 6, 5")
	assert_eq(ui.results.get_bar_screen_order(), [2, 0, 1] as Array[int], "rows moved")


func test_session_finished_shows_podium_confetti_and_host_back_button() -> void:
	_make_ui(4)
	Session.scores = {0: 12, 1: 20, 2: 7, 3: 15} as Dictionary[int, int]
	var final_ranking: Array[int] = [1, 3, 0, 2]
	var pressed := watch(ui, &"back_to_lobby_pressed")
	Session.session_finished.emit(final_ranking)
	await step(2)
	_assert_only(RoundUI.View.PODIUM, "session_finished")
	assert_eq(ui.podium.final_ranking, final_ranking, "podium ranking")
	assert_false(ui.podium.is_back_button_shown(), "no button during the reveal")
	await step(_seconds(RoundPodium.CELEBRATE_AT + 0.5))
	assert_true(ui.podium.is_confetti_on(), "confetti")
	await step(_seconds(RoundUI.BACK_BUTTON_HOST_DELAY))
	assert_true(ui.podium.is_back_button_shown(), "host sees Back to lobby")
	ui.podium.back_pressed.emit()
	await step(1)
	_assert_only(RoundUI.View.NONE, "after Back to lobby")
	assert_eq(pressed.size(), 1, "back_to_lobby_pressed emitted")


func test_state_lobby_reveals_back_button_on_podium() -> void:
	_make_ui(2)
	Session.scores = {0: 3, 1: 4} as Dictionary[int, int]
	Session.session_finished.emit([1, 0] as Array[int])
	await step(2)
	Session.state_changed.emit(Session.State.LOBBY)
	await step(1)
	_assert_only(RoundUI.View.PODIUM, "podium stays")
	assert_true(ui.podium.is_back_button_shown(), "button once Session is back in LOBBY")


func test_state_lobby_hides_everything_else() -> void:
	_make_ui(4)
	_intro()
	Session.round_started.emit()
	await step(2)
	Session.state_changed.emit(Session.State.LOBBY)
	await step(1)
	_assert_only(RoundUI.View.NONE, "lobby")


func test_full_flow_switches_panels() -> void:
	_make_ui(4)
	_intro()
	await step(1)
	_assert_only(RoundUI.View.INTRO, "intro")
	Session.round_started.emit()
	await step(1)
	_assert_only(RoundUI.View.HUD, "hud")
	Session.scores = {0: 4, 1: 3, 2: 2, 3: 1} as Dictionary[int, int]
	Session.round_finished.emit([0, 1, 2, 3] as Array[int], {0: 4, 1: 3, 2: 2, 3: 1})
	await step(1)
	_assert_only(RoundUI.View.RESULTS, "results")
	_intro(1)
	await step(1)
	_assert_only(RoundUI.View.INTRO, "next intro")
	Session.session_finished.emit([0, 1, 2, 3] as Array[int])
	await step(1)
	_assert_only(RoundUI.View.PODIUM, "podium")


# --- HUD details ---------------------------------------------------------------------

func test_eliminated_players_grey_out() -> void:
	var ps := spawn_arena(4)
	_make_ui(4)
	_intro()
	Session.round_started.emit()
	await step(2)
	ps[2].eliminate(&"test")
	await step(1)
	for p in ps:
		assert_eq(ui.hud.get_card(p.slot).eliminated, p.slot == 2, "eliminated flag of slot %d" % p.slot)
	ps[2].respawn_at(Transform3D.IDENTITY)
	await step(1)
	assert_false(ui.hud.get_card(2).eliminated, "respawn clears the grey")
	ps[3].eliminate(&"test")
	_intro(1)
	await step(1)
	assert_false(ui.hud.get_card(3).eliminated, "a new round starts un-greyed")


func test_counters_update_and_reset() -> void:
	_make_ui(4)
	_intro()
	Session.round_started.emit()
	await step(1)
	RoundUI.push_counter(1, 7)
	get_tree().call_group(RoundUI.GROUP, &"set_counter", 3, 2)
	await step(1)
	assert_true(ui.hud.get_card(1).counter_shown, "counter shown")
	assert_eq(ui.hud.get_card(1).counter_value, 7, "static accessor")
	assert_eq(ui.hud.get_card(3).counter_value, 2, "group call")
	assert_false(ui.hud.get_card(0).counter_shown, "untouched counter hidden")
	ui.set_counter(1, 8)
	assert_eq(ui.hud.get_card(1).counter_value, 8, "counter updates")
	_intro(1)
	await step(1)
	assert_false(ui.hud.get_card(1).counter_shown, "counters reset each round")


func test_scores_on_strip() -> void:
	_make_ui(3)
	Session.scores = {0: 4, 1: 11, 2: 0} as Dictionary[int, int]
	_intro()
	Session.round_started.emit()
	await step(1)
	assert_eq(ui.hud.get_card(1).get_score_text(), "11", "total score")


func test_banner_shows_and_hides() -> void:
	_make_ui(2)
	RoundUI.push_banner("SUDDEN DEATH!", 1.0)
	await step(2)
	assert_true(ui.is_banner_shown(), "banner shown")
	assert_eq(ui.get_banner_text(), "SUDDEN DEATH!", "banner text")
	await step(_seconds(1.3))
	assert_false(ui.is_banner_shown(), "banner gone after its time")


func test_accessors_without_ui_are_noops() -> void:
	RoundUI.push_counter(0, 3)
	RoundUI.push_banner("nobody listens")
	assert_true(RoundUI.get_instance() == null, "no instance")


func test_two_and_eight_players() -> void:
	for count: int in [2, 8]:
		_reset_session()
		_make_ui(count)
		_intro()
		Session.round_started.emit()
		await step(1)
		var cards := 0
		for slot in count:
			if ui.hud.get_card(slot) != null:
				cards += 1
		assert_eq(cards, count, "%d cards" % count)
		var ranking: Array[int] = []
		var points: Dictionary = {}
		for i in count:
			var slot := count - 1 - i  # highest slot wins
			ranking.append(slot)
			points[slot] = count - i
			Session.scores[slot] = 2 * (count - i)
		Session.round_finished.emit(ranking, points)
		await step(_seconds(RoundResults.TOTAL_SECONDS + 0.5))
		assert_eq(ui.results.get_bar_order(), ranking, "%d players: bar order" % count)
		assert_eq(ui.results.get_bar_screen_order(), ranking, "%d players: screen order" % count)
		Session.session_finished.emit(ranking)
		await step(_seconds(RoundPodium.CELEBRATE_AT + 0.5))
		_assert_only(RoundUI.View.PODIUM, "%d players podium" % count)
		remove_child(ui)
		ui.queue_free()
		ui = null


# --- Name tag ------------------------------------------------------------------------

func test_name_tag_follows_fades_and_hides() -> void:
	var ps := spawn_arena(2)
	var p := ps[1]
	var tag := NAME_TAG_SCENE.instantiate() as NameTag
	p.add_child(tag)
	tag.setup(p)
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	cam.global_position = p.global_position + Vector3(0, 3, 6)
	await step(2)
	assert_eq((tag.get_node(^"Name") as Label3D).text, p.display_name, "shows the name")
	assert_near(tag.global_position, p.global_position + Vector3.UP * tag.height, 0.01, "floats above the player")
	assert_near(tag.alpha, 1.0, 0.001, "opaque up close")
	assert_true(tag.visible, "visible while alive")
	cam.global_position = p.global_position + Vector3(0, 0, tag.fade_end + 5.0)
	await step(2)
	assert_near(tag.alpha, 0.0, 0.001, "faded when far")
	cam.global_position = p.global_position + Vector3(0, 0, (tag.fade_start + tag.fade_end) * 0.5)
	await step(2)
	assert_true(tag.alpha > 0.1 and tag.alpha < 0.9, "half faded in between (%f)" % tag.alpha)
	p.eliminate(&"test")
	await step(2)
	assert_false(tag.visible, "hidden while eliminated")
	cam.queue_free()
