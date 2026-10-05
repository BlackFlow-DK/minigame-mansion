extends GameTest
## Session: round flow, scoring, round order and edge cases. Drives the real `Session`
## autoload offline on its own Stage, with the flat dev arena as every round's scene
## (`Session.scene_override`); the test finishes rounds on command with `finish()`.

const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")
const S := preload("res://session/session.gd")

## The Stage Session plays on (kept out of the harness `stage` so the harness does not
## also call `_host_tick`).
var arena: Stage = null
var _connections: Array = []


func before_each() -> void:
	Session.abort_session()
	Session.scene_override = DEV_ARENA
	Session.time_scale = 50.0
	Session.order_seed = 1234


func after_each() -> void:
	for c: Array in _connections:
		var sig: Signal = c[0]
		if sig.is_connected(c[1]):
			sig.disconnect(c[1])
	_connections.clear()
	Session.abort_session()
	Session.scene_override = null
	Session.time_scale = 1.0
	Session.order_seed = -1
	if arena:
		arena.clear()
		remove_child(arena)
		arena.queue_free()
		arena = null


# --- Helpers ---------------------------------------------------------------------------

func _offline(count: int) -> void:
	Net.start_offline()
	for i in count - 1:
		Net.add_bot()
	arena = STAGE_SCENE.instantiate() as Stage
	add_child(arena)


## Like `watch`, but disconnected in after_each (Session outlives the test).
func _rec(sig: Signal) -> Array:
	var events: Array = []
	var cb := func(...args: Array) -> void: events.append(args)
	sig.connect(cb)
	_connections.append([sig, cb])
	return events


func _wait_state(s: int, max_frames: int = 600) -> bool:
	for i in max_frames:
		if Session.state == s:
			return true
		await step(1)
	return Session.state == s


func _finish(ranking: Array) -> void:
	var r: Array[int] = []
	r.assign(ranking)
	Session.current_minigame.finish(r)


func _all_frozen(value: bool) -> bool:
	for p: Player in arena.players.values():
		if p.frozen != value:
			return false
	return not arena.players.is_empty()


# --- Tests -----------------------------------------------------------------------------

func test_full_session_walks_states_in_order() -> void:
	_offline(4)
	var states := _rec(Session.state_changed)
	var intros := _rec(Session.round_intro)
	var starts := _rec(Session.round_started)
	var finishes := _rec(Session.round_finished)
	var ends := _rec(Session.session_finished)
	Session.start_session(3)
	assert_eq(Session.state, S.State.INTRO, "INTRO right after start")
	assert_eq(Session.round_count, 3, "round_count")
	assert_true(_all_frozen(true), "players frozen during INTRO")
	var rankings: Array = [[0, 1, 2, 3], [1, 0, 3, 2], [1, 2, 0, 3]]
	for r in 3:
		if not assert_true(await _wait_state(S.State.PLAYING), "round %d reached PLAYING" % r):
			return
		assert_eq(Session.round_index, r, "round_index")
		assert_true(_all_frozen(false), "players unfrozen while PLAYING (round %d)" % r)
		_finish(rankings[r])
		assert_eq(Session.state, S.State.RESULTS, "RESULTS right after finish (round %d)" % r)
		assert_true(_all_frozen(true), "players frozen in RESULTS (round %d)" % r)
	if not assert_true(await _wait_state(S.State.PODIUM), "reached PODIUM"):
		return
	assert_true(await _wait_state(S.State.LOBBY), "back to LOBBY")
	var P := S.State
	assert_eq(states, [[P.INTRO], [P.PLAYING], [P.RESULTS], [P.INTRO], [P.PLAYING], [P.RESULTS],
		[P.INTRO], [P.PLAYING], [P.RESULTS], [P.PODIUM], [P.LOBBY]], "state order")
	assert_eq(intros.size(), 3, "round_intro count")
	var ids: Array[StringName] = []
	for i in intros.size():
		var info: Dictionary = intros[i][0]
		assert_eq(intros[i][1], i, "round_intro index")
		assert_true(MinigameRegistry.has(info["id"]), "intro id from the registry")
		assert_eq(info["title"], "Dev Arena", "intro title from the loaded scene")
		assert_true(info.has("rule_text"), "intro has rule_text")
		ids.append(info["id"])
	assert_true(ids[0] != ids[1] and ids[1] != ids[2] and ids[0] != ids[2], "no repeats: %s" % [ids])
	assert_eq(starts.size(), 3, "round_started count")
	assert_eq(finishes.size(), 3, "round_finished count")
	assert_eq(finishes[0], [[0, 1, 2, 3], {0: 4, 1: 3, 2: 2, 3: 1}], "round 1 result")
	assert_eq(finishes[1], [[1, 0, 3, 2], {1: 4, 0: 3, 3: 2, 2: 1}], "round 2 result")
	assert_eq(Session.scores, {0: 9, 1: 11, 2: 6, 3: 4} as Dictionary[int, int], "totals")
	assert_eq(ends, [[[1, 0, 2, 3]]], "final ranking")
	assert_eq(Session.round_index, -1, "round_index reset in LOBBY")
	assert_true(arena.minigame == null and arena.players.is_empty(), "stage cleared in LOBBY")


func test_scoring_table() -> void:
	# The table scales with the players in the round: 2-3 3/2/1, 4-5 4/3/2/1, 6-8 5/4/3/2/1/1.
	assert_eq(S.place_points(2), [3, 2, 1] as Array[int], "2 players")
	assert_eq(S.place_points(3), [3, 2, 1] as Array[int], "3 players")
	assert_eq(S.place_points(4), [4, 3, 2, 1] as Array[int], "4 players")
	assert_eq(S.place_points(5), [4, 3, 2, 1] as Array[int], "5 players")
	assert_eq(S.place_points(6), [5, 4, 3, 2, 1, 1] as Array[int], "6 players")
	assert_eq(S.place_points(8), [5, 4, 3, 2, 1, 1] as Array[int], "8 players")
	assert_eq(S.points_for_ranking([0, 1]), {0: 3, 1: 2}, "2 players: 3/2")
	assert_eq(S.points_for_ranking([3, 2, 1, 0]), {3: 4, 2: 3, 1: 2, 0: 1}, "4 players: 4/3/2/1")
	assert_eq(S.points_for_ranking([5, 4, 3, 2, 1, 0]), {5: 5, 4: 4, 3: 3, 2: 2, 1: 1, 0: 1}, "places 1..6 of 6")
	assert_eq(S.points_for_ranking([7, 6, 5, 4, 3, 2, 1, 0]), {7: 5, 6: 4, 5: 3, 4: 2, 3: 1, 2: 1, 1: 0, 0: 0}, "8 players: last two score 0")
	assert_eq(S.points_for_ranking([2, 0], 1, 4), {2: 4, 0: 3}, "table from player_count, not ranking length")
	assert_eq(S.points_for_ranking([0, 1, 2], 2), {0: 3, 1: 3, 2: 1}, "two tied first, next is third")
	assert_eq(S.points_for_ranking([]), {}, "empty")
	# Through a round: missing players score 0, unknown slots are dropped.
	_offline(4)
	var finishes := _rec(Session.round_finished)
	Session.start_session(1)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	_finish([2, 7, 0, 2])
	assert_eq(finishes, [[[2, 0], {2: 4, 0: 3, 1: 0, 3: 0}]], "missing -> 0, unknown and duplicate dropped")
	assert_eq(Session.scores, {0: 3, 1: 0, 2: 4, 3: 0} as Dictionary[int, int], "totals")


func test_tie_break_by_wins_then_slot() -> void:
	assert_eq(S.rank_totals([0, 1, 2, 3], {0: 5, 1: 5, 2: 5, 3: 7}, {0: 0, 1: 1, 2: 1, 3: 0}), [3, 1, 2, 0], "total, wins, slot")
	# Session: 0 and 2 win a round each, all three end on 4 points.
	_offline(3)
	var ends := _rec(Session.session_finished)
	Session.start_session(2)
	for ranking: Array in [[0, 1, 2], [2, 1, 0]]:
		if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
			return
		_finish(ranking)
	assert_true(await _wait_state(S.State.PODIUM), "PODIUM")
	assert_eq(Session.scores, {0: 4, 1: 4, 2: 4} as Dictionary[int, int], "all tied on points (3 players: 3/2/1)")
	assert_eq(Session.round_wins, {0: 1, 1: 0, 2: 1} as Dictionary[int, int], "wins")
	assert_eq(ends, [[[0, 2, 1]]], "wins break the tie, then slot")


func test_round_order_no_repeat_until_all_played() -> void:
	var n := MinigameRegistry.IDS.size()
	for seed_value in 20:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var order := S.build_round_order(n * 3 + 1, rng)
		assert_eq(order.size(), n * 3 + 1, "length")
		for bag in 3:
			var chunk := order.slice(bag * n, bag * n + n)
			for id in MinigameRegistry.IDS:
				assert_true(chunk.has(id), "seed %d bag %d has %s: %s" % [seed_value, bag, id, order])
		for i in order.size() - 1:
			assert_true(order[i] != order[i + 1], "seed %d: no id twice in a row: %s" % [seed_value, order])
	var a := RandomNumberGenerator.new()
	a.seed = 42
	var b := RandomNumberGenerator.new()
	b.seed = 42
	assert_eq(S.build_round_order(8, a), S.build_round_order(8, b), "same seed, same order")


func test_time_limit_ends_round() -> void:
	_offline(3)
	Session.time_scale = 10.0
	var finishes := _rec(Session.round_finished)
	var set_limit := func(_info: Dictionary, _index: int) -> void: Session.current_minigame.time_limit = 3.0
	Session.round_intro.connect(set_limit)
	_connections.append([Session.round_intro, set_limit])
	Session.start_session(1)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	assert_near(Session.phase_duration, 3.0, 0.001, "phase_duration is the time limit")
	Session.current_minigame.knock_out(arena.get_player(1))
	# 3 s limit + 1 s grace at 10x = 24 frames.
	await step(18)
	assert_eq(Session.state, S.State.PLAYING, "still playing before the limit")
	assert_true(await _wait_state(S.State.RESULTS, 30), "time limit ended the round")
	assert_true(Session.current_minigame.is_finished(), "Session finished the minigame")
	assert_eq(finishes, [[[0, 2, 1], {0: 3, 2: 3, 1: 1}]], "survivors share first, then knocked out (3 players: 3/2/1)")
	assert_eq(Session.round_wins, {0: 1, 1: 0, 2: 1} as Dictionary[int, int], "tied survivors both win")


func test_player_leaving_mid_round_is_excluded() -> void:
	_offline(3)
	var finishes := _rec(Session.round_finished)
	Session.start_session(2)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	Net.remove_bot(2)
	await step(2)
	assert_eq(Session.state, S.State.PLAYING, "round continues with 2 left")
	_finish([2, 1, 0])
	assert_eq(finishes, [[[1, 0], {1: 3, 0: 2}]], "departed player excluded; the table is still the 3-player one")


func test_early_finish_with_one_player_left() -> void:
	_offline(2)
	var finishes := _rec(Session.round_finished)
	var ends := _rec(Session.session_finished)
	Session.start_session(3)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	_finish([1, 0])
	if not assert_true(await _wait_state(S.State.PLAYING), "round 2 PLAYING"):
		return
	Net.remove_bot(1)
	assert_eq(Session.state, S.State.PODIUM, "straight to PODIUM")
	assert_eq(finishes.size(), 1, "only the finished round is scored")
	assert_eq(ends, [[[0]]], "final ranking of who is left")
	assert_eq(Session.scores, {0: 2, 1: 3} as Dictionary[int, int], "this session's totals")
	assert_true(await _wait_state(S.State.LOBBY), "then LOBBY")


## Too few players before the first round is scored: nothing to rank, no session coins, LOBBY
## (INTRO and PLAYING of round 1; the launch beat cancels itself, see test_preload).
func test_too_few_players_before_the_first_result_returns_to_the_lobby() -> void:
	_offline(2)
	var ends := _rec(Session.session_finished)
	var states := _rec(Session.state_changed)
	var coins := Progression.coins
	for wait_for: int in [S.State.INTRO, S.State.PLAYING]:
		Session.scores = {0: 30, 1: 12}  # the last session's, kept for the lobby UI
		Session.round_wins = {0: 5, 1: 2}
		Session.start_session(3)
		if not assert_true(await _wait_state(wait_for), "state %d" % wait_for):
			return
		assert_eq(Session.scores, {0: 0, 1: 0} as Dictionary[int, int], "the new session starts at 0")
		Net.remove_bot(1)
		assert_eq(Session.state, S.State.LOBBY, "LOBBY, not the podium (left in %d)" % wait_for)
		assert_false(Net.session_in_progress, "joiners welcome again")
		await step(5)
		assert_eq(Session.state, S.State.LOBBY, "stays in the lobby")
		Net.add_bot()
	assert_eq(ends.size(), 0, "no session_finished")
	assert_false(states.has([S.State.PODIUM]), "never PODIUM")
	assert_eq(Progression.coins, coins, "no session coins")


func test_start_ignored_outside_lobby_and_when_too_few() -> void:
	_offline(1)
	var states := _rec(Session.state_changed)
	Session.start_session(2)
	assert_eq(Session.state, S.State.LOBBY, "one player: ignored")
	Net.add_bot()
	var intros := _rec(Session.round_intro)
	Session.start_session(2)
	assert_eq(Session.state, S.State.INTRO, "started")
	Session.start_session(5)
	assert_eq(Session.round_count, 2, "second start ignored")
	assert_eq(intros.size(), 1, "no second intro")
	assert_eq(states, [[S.State.INTRO]], "one transition")
