extends GameTest
## Round transitions: the launch beat between the lobby's START and the first round (every
## peer hears `Session.session_launching`, the round order and randomness are unchanged, it
## cancels cleanly) and the threaded preload of the next round's scene (`Session.upcoming`,
## `Stage.preload_minigame` / `take_scene`, through the real Session flow in every mode).

const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")
const S := preload("res://session/session.gd")

var arena: Stage = null
var _connections: Array = []


func before_each() -> void:
	Session.abort_session()
	Session.scene_override = DEV_ARENA
	Session.time_scale = 50.0
	Session.order_seed = 2468
	Session.configure(8, GameModes.Order.SHUFFLE, [], Mutators.Mode.OFF)


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
	Session.configure(8, GameModes.Order.SHUFFLE, [], Mutators.Mode.OFF)
	Stage.drop_preloads()
	if arena:
		arena.clear()
		remove_child(arena)
		arena.queue_free()
		arena = null


func _offline(count: int) -> void:
	Net.start_offline()
	for i in count - 1:
		Net.add_bot()
	arena = STAGE_SCENE.instantiate() as Stage
	add_child(arena)


func _rec(sig: Signal) -> Array:
	var events: Array = []
	var cb := func(...args: Array) -> void: events.append(args)
	sig.connect(cb)
	_connections.append([sig, cb])
	return events


func _wait_state(s: int, max_frames: int = 900) -> bool:
	for i in max_frames:
		if Session.state == s:
			return true
		await step(1)
	return Session.state == s


func _finish_now() -> void:
	var r: Array[int] = []
	r.assign(Net.roster.keys())
	r.sort()
	Session.current_minigame.finish(r)


# --- Launch beat ---------------------------------------------------------------------------------

func test_launch_beat_then_the_first_round() -> void:
	_offline(4)
	Session.time_scale = 1.0
	var launches := _rec(Session.session_launching)
	var intros := _rec(Session.round_intro)
	Session.start_session(2, 0.75)
	assert_eq(Session.state, S.State.LOBBY, "still in the lobby")
	assert_true(Session.is_launching(), "launching")
	assert_eq(launches, [[0.75]], "every peer hears START with the beat")
	assert_true(Net.session_in_progress, "joiners refused from START on")
	var first := Session.upcoming
	assert_true(first != &"" and first == Session.round_order[0], "the first round is announced (%s)" % first)
	var order := Session.round_order.duplicate()
	Session.start_session(5)
	Session.start_practice(&"bumper_sumo")
	assert_eq(Session.round_order, order, "a second START during the beat is ignored")
	assert_eq(launches.size(), 1, "one beat")
	await step(40)
	assert_eq(Session.state, S.State.LOBBY, "the lobby stays up for the beat")
	assert_eq(intros.size(), 0, "no intro yet")
	assert_true(await _wait_state(S.State.INTRO, 15), "INTRO right after the beat")
	assert_eq(intros[0][0]["id"], first, "the announced round is played")
	assert_eq(Session.round_count, 2, "round count")
	assert_false(Session.is_launching(), "beat over")
	assert_eq(Session.upcoming, &"", "cleared by the intro")


func test_launch_beat_keeps_the_round_order_and_vote_draws() -> void:
	_offline(4)
	Session.start_session(4)
	var direct := Session.round_order.duplicate()
	Session.abort_session()
	Session.start_session(4, 0.5)
	assert_true(await _wait_state(S.State.INTRO), "intro after the beat")
	assert_eq(Session.round_order, direct, "same order with the beat")
	Session.abort_session()
	Session.configure(2, GameModes.Order.VOTE, [], Mutators.Mode.OFF)
	Session.start_session(2)
	var cards := Session.vote_candidates.duplicate()
	Session.abort_session()
	var launches := _rec(Session.session_launching)
	Session.start_session(2, 0.5)
	assert_eq(Session.upcoming, &"", "VOTE: the first round is not known yet")
	assert_eq(launches.size(), 1, "VOTE flares too")
	assert_true(await _wait_state(S.State.VOTE), "vote after the beat")
	assert_eq(Session.vote_candidates, cards, "same cards with the beat")


func test_launch_cancelled_when_players_leave_or_abort() -> void:
	_offline(2)
	Session.start_session(1, 0.5)
	Net.remove_bot(1)
	await step(30)
	assert_eq(Session.state, S.State.LOBBY, "too few players: stays in the lobby")
	assert_false(Session.is_launching(), "launch dropped")
	assert_false(Net.session_in_progress, "joiners welcome again")
	Net.add_bot()
	Session.start_practice(&"bumper_sumo", &"", 0.5)
	assert_true(Session.is_launching(), "practice launches")
	Session.abort_session()
	assert_false(Session.is_launching(), "abort drops the beat")
	assert_false(Net.session_in_progress, "not in progress")
	await step(30)
	assert_eq(Session.state, S.State.LOBBY, "nothing started")
	Session.start_session(1, 0.5)
	assert_true(await _wait_state(S.State.INTRO, 60), "a new START works")


## The round order was built at START: a setup change during the beat (VOTE -> SHUFFLE) or the
## session is refused, so round 1 is the vote, not an empty round.
func test_setup_is_locked_from_start_on() -> void:
	_offline(3)
	Session.configure(2, GameModes.Order.VOTE, [], Mutators.Mode.OFF)
	var changed := _rec(Session.setup_changed)
	var intros := _rec(Session.round_intro)
	Session.start_session(2, 0.5)
	assert_true(Session.is_launching(), "launching")
	Session.configure(2, GameModes.Order.SHUFFLE, [], Mutators.Mode.ALWAYS)
	assert_eq(Session.order_mode, GameModes.Order.VOTE, "order kept during the beat")
	assert_eq(Session.mutator_mode, Mutators.Mode.OFF, "mutators kept")
	assert_eq(changed.size(), 0, "nothing sent")
	assert_true(await _wait_state(S.State.VOTE), "the vote after the beat")
	assert_eq(intros.size(), 0, "no round without an id")
	Session.configure(5, GameModes.Order.PLAYLIST, [&"bumper_sumo"], Mutators.Mode.OFF)
	assert_eq(Session.order_mode, GameModes.Order.VOTE, "order kept while the session runs")
	assert_eq(Session.setup_rounds, 2, "rounds kept")
	Session.vote(0, true)
	assert_true(await _wait_state(S.State.INTRO), "intro of the winner")
	assert_true(intros[0][0]["id"] != &"", "a real id")
	Session.abort_session()
	Session.configure(5, GameModes.Order.SHUFFLE, [], Mutators.Mode.OFF)
	assert_eq(Session.order_mode, GameModes.Order.SHUFFLE, "the lobby takes it again")
	assert_eq(changed.size(), 1, "sent once")


# --- Next-round notice ---------------------------------------------------------------------------

func test_results_announce_the_next_round_in_order() -> void:
	_offline(3)
	Session.configure(3, GameModes.Order.PLAYLIST, [&"bumper_sumo", &"coin_scramble", &"crown_keeper"], Mutators.Mode.OFF)
	var intros := _rec(Session.round_intro)
	Session.start_session(3)
	for r in 3:
		if not assert_true(await _wait_state(S.State.PLAYING), "round %d plays" % r):
			return
		assert_eq(Session.upcoming, &"", "nothing announced during play")
		_finish_now()
		if not assert_true(await _wait_state(S.State.RESULTS), "round %d results" % r):
			return
		if r < 2:
			assert_eq(Session.upcoming, Session.round_order[r + 1], "RESULTS names round %d" % (r + 1))
			# scene_override plays the dev arena: nothing real to preload.
			assert_false(Stage.is_preloading(MinigameRegistry.scene_path(Session.upcoming)), "no preload with an override")
		else:
			assert_eq(Session.upcoming, &"", "the last round names nothing")
	var played: Array[StringName] = []
	for e: Array in intros:
		played.append(e[0]["id"])
	assert_eq(played, Session.round_order, "the announced ids are the ones played")


func test_vote_result_and_practice_name_the_round() -> void:
	_offline(3)
	Session.configure(1, GameModes.Order.VOTE, [], Mutators.Mode.OFF)
	Session.start_session(1)
	for i in 60 * 12:
		if Session.vote_winner >= 0:
			break
		await step(1)
	if not assert_true(Session.vote_winner >= 0, "the vote is decided"):
		return
	assert_eq(Session.upcoming, Session.vote_candidates[Session.vote_winner], "the winner preloads")
	assert_true(await _wait_state(S.State.INTRO), "its intro")
	Session.abort_session()
	Session.start_practice(&"coin_scramble", &"", 0.5)
	assert_eq(Session.upcoming, &"coin_scramble", "practice names its round")
	assert_true(await _wait_state(S.State.INTRO), "practice intro")
	assert_true(Session.practice, "practice")


# --- Threaded preload ----------------------------------------------------------------------------

func test_stage_takes_a_preloaded_scene() -> void:
	_offline(2)
	assert_false(Stage.preload_minigame(&"no_such_game"), "unknown id")
	var id := &"coin_scramble"
	var path := MinigameRegistry.scene_path(id)
	var requested := Stage.preload_minigame(id)
	assert_true(requested or ResourceLoader.has_cached(path), "requested (or in memory already)")
	if requested:
		assert_true(Stage.is_preloading(path), "pending")
		assert_true(Stage.preload_minigame(id), "a second request reuses the first")
	var mg := arena.load_minigame(id)
	if not assert_true(mg != null, "loaded"):
		return
	assert_eq(mg.scene_file_path, path, "the right scene")
	assert_false(Stage.is_preloading(path), "taken")
	assert_eq(arena.players.size(), 2, "players spawned")
	arena.clear()
	# A preload nobody takes is let go once it has finished.
	var other := MinigameRegistry.scene_path(&"bumper_sumo")
	if Stage.preload_minigame(&"bumper_sumo"):
		for i in 600:
			if ResourceLoader.load_threaded_get_status(other) != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				break
			await step(1)
		Stage.drop_preloads()
		assert_false(Stage.is_preloading(other), "dropped")
	assert_true(Stage.take_scene(other) != null, "a plain load still works")


func test_real_session_preloads_every_round_on_time() -> void:
	_offline(3)
	Session.scene_override = null
	Session.configure(2, GameModes.Order.PLAYLIST, [&"bumper_sumo", &"coin_scramble"], Mutators.Mode.OFF)
	Session.start_session(2, 0.5)
	var first := MinigameRegistry.scene_path(Session.round_order[0])
	assert_true(Stage.is_preloading(first) or ResourceLoader.has_cached(first), "round 1 preloads during the beat")
	for r in 2:
		if not assert_true(await _wait_state(S.State.INTRO), "round %d intro" % r):
			return
		var path := MinigameRegistry.scene_path(Session.round_order[r])
		assert_eq(arena.minigame.scene_file_path, path, "round %d plays its own scene" % r)
		assert_false(Stage.is_preloading(path), "round %d took its preload" % r)
		if not assert_true(await _wait_state(S.State.PLAYING), "round %d plays" % r):
			return
		_finish_now()
		if not assert_true(await _wait_state(S.State.RESULTS), "round %d results" % r):
			return
		if r == 0:
			var next := MinigameRegistry.scene_path(Session.round_order[1])
			assert_true(Stage.is_preloading(next) or ResourceLoader.has_cached(next), "round 2 preloads at RESULTS")
