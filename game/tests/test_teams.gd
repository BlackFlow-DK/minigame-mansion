extends GameTest
## Teams, tied rankings and roles: Minigame.finish with tied groups, the Session scoring and
## signals for them (including the time-out path), assign_teams / finish_teams / is_ally,
## set_role_text, the round UI showing teams and roles, and nothing carrying over to the
## next round. Offline; Session runs on its own Stage with the dev arena as every round.

const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")
const UI_SCENE: PackedScene = preload("res://ui/round/round_ui.tscn")
const S := preload("res://session/session.gd")

## The Stage Session plays on (kept out of the harness `stage`).
var arena: Stage = null
var ui: RoundUI = null
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
	if ui:
		remove_child(ui)
		ui.queue_free()
		ui = null
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


func _rec(sig: Signal) -> Array:
	var events: Array = []
	var cb := func(...args: Array) -> void: events.append(args)
	sig.connect(cb)
	_connections.append([sig, cb])
	return events


func _on(sig: Signal, cb: Callable) -> void:
	sig.connect(cb)
	_connections.append([sig, cb])


func _wait_state(s: int, max_frames: int = 600) -> bool:
	for i in max_frames:
		if Session.state == s:
			return true
		await step(1)
	return Session.state == s


## Team sizes of a slot -> team map with `count` teams.
func _sizes(split: Dictionary, count: int) -> Array[int]:
	var sizes: Array[int] = []
	sizes.resize(count)
	for s: int in split:
		sizes[split[s]] += 1
	return sizes


# --- Tied rankings -----------------------------------------------------------------------

func test_normalize_ranking_to_groups() -> void:
	var g := Minigame.normalize_ranking([3, [1, 2], 0])
	assert_eq(g, [[3], [1, 2], [0]], "slots and groups -> groups")
	assert_true(g[1] is Array and (g[1] as Array).is_typed() and (g[1] as Array).get_typed_builtin() == TYPE_INT, "groups are Array[int]")
	assert_eq(Minigame.normalize_ranking([1, [1, 2], [], 2, [3, 3]]), [[1], [2], [3]], "repeats keep their first place, empty groups go")
	assert_eq(Minigame.normalize_ranking([] as Array[int]), [], "empty")
	assert_eq(Minigame.normalize_ranking([0, 1, 2] as Array[int]), [[0], [1], [2]], "a plain ranking: one slot per group")
	assert_eq(Minigame.flatten_groups([[3], [1, 2], [0]]), [3, 1, 2, 0] as Array[int], "flat order")
	assert_eq(Minigame.group_place([[3], [1, 2], [0]], 2), 2, "tied second")
	assert_eq(Minigame.group_place([[3], [1, 2], [0]], 0), 4, "after a tie the place skips")
	assert_eq(Minigame.group_place([[3], [1, 2], [0]], 7), 0, "absent")


func test_points_for_groups() -> void:
	assert_eq(S.points_for_groups([[0], [1, 2], [3]]), {0: 4, 1: 3, 2: 3, 3: 1}, "tied 2nd: both 3, next is 4th")
	assert_eq(S.points_for_groups([[0, 1, 2, 3]]), {0: 4, 1: 4, 2: 4, 3: 4}, "all tied first")
	assert_eq(S.points_for_groups([[4, 5, 6, 7], [0, 1, 2, 3]]), {4: 5, 5: 5, 6: 5, 7: 5, 0: 1, 1: 1, 2: 1, 3: 1}, "two teams of 4: 1st and 5th place")
	assert_eq(S.points_for_groups([[0], [1]], 6), {0: 5, 1: 4}, "table from player_count")
	assert_eq(S.points_for_groups([[5, 6], [0], [1], [2], [3], [4, 7]]), {5: 5, 6: 5, 0: 3, 1: 2, 2: 1, 3: 1, 4: 0, 7: 0}, "8 players, ties at both ends")
	# The old tied_top form is the same code path.
	assert_eq(S.points_for_ranking([0, 1, 2], 2), S.points_for_groups([[0, 1], [2]]), "points_for_ranking = groups")


func test_tied_finish_through_session() -> void:
	_offline(4)
	var finishes := _rec(Session.round_finished)
	var ranked := _rec(Session.round_ranked)
	Session.start_session(1)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	var mg := Session.current_minigame
	var emitted := watch(mg, &"finished")
	mg.finish([[2, 0], 1, 3])
	assert_eq(emitted, [[[2, 0, 1, 3]]], "finished keeps the flat Array[int]")
	assert_eq(mg.finish_groups, [[2, 0], [1], [3]], "finish_groups")
	assert_eq(finishes, [[[2, 0, 1, 3], {2: 4, 0: 4, 1: 2, 3: 1}]], "flat ranking; tied pair both score 1st, then 3rd")
	assert_eq(ranked, [[[[2, 0], [1], [3]], {2: 4, 0: 4, 1: 2, 3: 1}]], "round_ranked carries the groups")
	assert_eq(Session.round_groups, [[2, 0], [1], [3]], "round_groups")
	assert_eq(Session.round_wins, {0: 1, 1: 0, 2: 1, 3: 0} as Dictionary[int, int], "both tied winners get a win")
	# Progression pays the tied place (slot 0 is the local human; 2nd place would be 4 coins).
	assert_eq(Progression.round_place(finishes[0][0], finishes[0][1], 0, Session.round_groups), 1, "local shares 1st")
	assert_eq(Progression.round_place([2, 0, 1, 3], {}, 1, [[2, 0], [1], [3]]), 3, "next after a tie is 3rd")
	assert_eq(Progression.round_place([0, 1, 2, 3], {}, 3, [[0], [1], [2, 3]]), 3, "tied 3rd")


func test_tied_group_in_the_middle_and_leaver() -> void:
	_offline(4)
	var finishes := _rec(Session.round_finished)
	Session.start_session(1)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	Net.remove_bot(2)
	await step(2)
	Session.current_minigame.finish([3, [1, 2], 0, 7])
	assert_eq(finishes, [[[3, 1, 0], {3: 4, 1: 3, 0: 2}]], "the leaver drops out of its group; places count who is left; the 4-player table stays")
	assert_eq(Session.round_groups, [[3], [1], [0]], "groups after cleaning")


func test_time_out_survivors_are_one_group() -> void:
	_offline(3)
	Session.time_scale = 10.0
	var finishes := _rec(Session.round_finished)
	var ranked := _rec(Session.round_ranked)
	_on(Session.round_intro, func(_info: Dictionary, _index: int) -> void: Session.current_minigame.time_limit = 3.0)
	Session.start_session(1)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	Session.current_minigame.knock_out(arena.get_player(1))
	assert_true(await _wait_state(S.State.RESULTS, 60), "time limit ended the round")
	assert_eq(finishes, [[[0, 2, 1], {0: 3, 2: 3, 1: 1}]], "same result as before groups")
	assert_eq(ranked, [[[[0, 2], [1]], {0: 3, 2: 3, 1: 1}]], "survivors are one tied group")
	assert_eq(Session.current_minigame.finish_groups, [[0, 2], [1]], "the backstop finished the minigame with the groups")
	assert_eq(Progression.round_place([0, 2, 1], {0: 3, 2: 3, 1: 1}, 2, Session.round_groups), 1, "tied survivor is 1st")


# --- Teams ---------------------------------------------------------------------------------

func test_split_teams_is_even_for_2_to_8_players() -> void:
	for n in range(2, 9):
		var slots: Array[int] = []
		for s in n:
			slots.append(s)
		for count in [2, 3, 4]:
			if count > n:
				continue
			for trial in 12:
				var split := Minigame.split_teams(slots, count)
				assert_eq(split.size(), n, "%d players, %d teams: everyone on a team" % [n, count])
				var sizes := _sizes(split, count)
				assert_true(sizes.max() - sizes.min() <= 1, "%d players, %d teams: sizes %s differ by at most 1" % [n, count, sizes])
	# The odd player does not always land on the same team.
	var seen: Dictionary = {}
	for trial in 40:
		var sizes := _sizes(Minigame.split_teams([0, 1, 2, 3, 4] as Array[int], 2), 2)
		seen[sizes[0]] = true
	assert_eq(seen.size(), 2, "which team gets the odd player varies")
	assert_eq(_sizes(Minigame.split_teams([0, 1, 2] as Array[int], 9), Minigame.MAX_TEAMS).count(0), 1, "count clamped to MAX_TEAMS")


func test_assign_teams_replicates_rings_and_allies() -> void:
	var ps := spawn_arena(8)
	var mg := get_minigame()
	var changed := watch(mg, &"teams_changed")
	assert_false(mg.has_teams(), "no teams before")
	assert_eq(mg.team_of(0), -1, "team_of without teams")
	assert_false(mg.is_ally(ps[0], ps[1]), "no allies without teams")
	mg.assign_teams(2)
	assert_eq(changed.size(), 1, "teams_changed")
	assert_true(mg.has_teams(), "has_teams")
	assert_eq(mg.team_count, 2, "team_count")
	assert_eq(mg.team_slots(0).size(), 4, "team 0 has 4")
	assert_eq(mg.team_slots(1).size(), 4, "team 1 has 4")
	for p in ps:
		var t := mg.team_of(p.slot)
		assert_true(t == 0 or t == 1, "slot %d on a team" % p.slot)
		var ring := p.get_component(&"team") as TeamComponent
		if assert_true(ring != null, "team component on P%d" % p.slot):
			assert_eq(ring.team, t, "ring team of P%d" % p.slot)
			assert_true(ring.is_ring_shown(), "ring shown under P%d" % p.slot)
			assert_eq(ring.color, Minigame.team_color(t), "ring colour")
		for q in ps:
			assert_eq(mg.is_ally(p, q), mg.team_of(q.slot) == t, "is_ally(%d, %d)" % [p.slot, q.slot])
	assert_true(Minigame.team_color(0) != Minigame.team_color(1), "two team colours")
	assert_eq(Minigame.team_name(0), "ORANGE", "team 0 name")
	assert_eq(Minigame.team_name(1), "BLUE", "team 1 name")
	# Dead players are left out; an odd count splits 4 / 3.
	mg.knock_out(ps[7])
	mg.assign_teams(2)
	assert_eq(mg.team_of(7), -1, "an eliminated player gets no team")
	var sizes := [mg.team_slots(0).size(), mg.team_slots(1).size()]
	sizes.sort()
	assert_eq(sizes, [3, 4], "7 players: 4 and 3")


func test_finish_teams_ranks_teams_as_tied_groups() -> void:
	spawn_arena(5)
	var mg := get_minigame()
	mg.assign_teams(2)
	var t0 := mg.team_slots(0)
	var t1 := mg.team_slots(1)
	mg.finish_teams([1, 0] as Array[int])
	var expected: Array[int] = []
	expected.append_array(t1)
	expected.append_array(t0)
	assert_eq(ranking, expected, "flat ranking: team 1 then team 0")
	assert_eq(mg.finish_groups, [t1, t0], "each team is one group")
	assert_eq(S.points_for_groups(mg.finish_groups, 5), _team_points(t1, 4, t0, [4, 3, 2, 1][t1.size()]), "winners all 1st, losers all at their shared place")


func _team_points(win: Array[int], win_pts: int, lose: Array[int], lose_pts: int) -> Dictionary:
	var out: Dictionary = {}
	for s in win:
		out[s] = win_pts
	for s in lose:
		out[s] = lose_pts
	return out


func test_finish_teams_through_session_with_missing_team_and_loner() -> void:
	_offline(4)
	var finishes := _rec(Session.round_finished)
	Session.start_session(1)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	var mg := Session.current_minigame
	mg.knock_out(arena.get_player(3))
	mg.assign_teams(2)
	var t0 := mg.team_slots(0)
	var t1 := mg.team_slots(1)
	mg.finish_teams([0] as Array[int])
	var flat: Array[int] = []
	flat.append_array(t0)
	flat.append_array(t1)
	flat.append(3)
	assert_eq(finishes[0][0], flat, "team 0, then the unlisted team 1, then the player without a team")
	var pts: Dictionary = finishes[0][1]
	for s in t0:
		assert_eq(pts[s], 4, "team 0 member %d scores 1st" % s)
	for s in t1:
		assert_eq(pts[s], [4, 3, 2, 1][t0.size()], "team 1 member %d scores the shared place" % s)
	assert_eq(pts[3], [4, 3, 2, 1][3], "the loner is 4th")
	for s in t0:
		assert_eq(Session.round_wins[s], 1, "every winner gets a round win")


# --- Roles ---------------------------------------------------------------------------------

func test_role_text_replicates_offline() -> void:
	spawn_arena(3)
	var mg := get_minigame()
	var changes := watch(mg, &"role_changed")
	mg.set_role_text(0, "You are the SEEKER")
	mg.set_role_text(2, "You are a HIDER")
	assert_eq(changes, [[0, "You are the SEEKER"], [2, "You are a HIDER"]], "role_changed per call")
	assert_eq(mg.role_of(0), "You are the SEEKER", "role_of")
	assert_eq(mg.role_of(1), "", "no role")
	mg.set_role_text(2, "")
	assert_eq(mg.role_of(2), "", "cleared")
	assert_false(mg.roles.has(2), "cleared from roles")


# --- Round UI ------------------------------------------------------------------------------

func test_round_ui_shows_teams_and_role() -> void:
	_offline(8)
	ui = UI_SCENE.instantiate() as RoundUI
	add_child(ui)
	var assigned := [false]
	# Like a minigame doing it in _setup on the host: before round_intro reaches the UI.
	_on(Session.state_changed, func(s: int) -> void:
		if s == S.State.INTRO and not assigned[0]:
			assigned[0] = true
			Session.current_minigame.assign_teams(2)
			Session.current_minigame.set_role_text(0, "You are the SEEKER"))
	Session.start_session(1)
	await step(2)
	var mg := Session.current_minigame
	var mine := mg.team_of(0)
	assert_eq(ui.intro.get_team_text(), "TEAM " + Minigame.team_name(mine), "intro card: my team")
	assert_eq(ui.intro.get_role_text(), "You are the SEEKER", "intro card: my role")
	assert_eq(ui.hud.get_team_order(), [0, 1] as Array[int], "HUD strip: one box per team")
	for s: int in Net.roster:
		assert_eq(ui.hud.get_card_team(s), mg.team_of(s), "card %d in its team's box" % s)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	await step(2)
	assert_eq(ui.view, RoundUI.View.HUD, "HUD")
	assert_eq(ui.hud.get_team_order(), [0, 1] as Array[int], "HUD keeps the team boxes")
	await step(ceili(RoundUI.ROLE_BANNER_DELAY * 60.0) + 4)
	assert_true(ui.is_banner_shown(), "role banner after GO!")
	assert_eq(ui.get_banner_text(), "You are the SEEKER", "role banner text")
	ui.set_counter(3, 7)
	mg.assign_teams(2)  # a regroup mid-round keeps counters
	assert_eq(ui.hud.get_card(3).counter_value, 7, "counter kept through a regroup")
	mg.finish_teams([1, 0] as Array[int])
	await step(2)
	assert_eq(ui.view, RoundUI.View.RESULTS, "results")
	assert_eq(ui.results.get_row_texts(), ["TEAM BLUE", "TEAM ORANGE"] as Array[String], "results list the teams")


func test_round_ui_shows_a_tie_on_one_line() -> void:
	_offline(4)
	ui = UI_SCENE.instantiate() as RoundUI
	add_child(ui)
	Session.start_session(1)
	if not assert_true(await _wait_state(S.State.PLAYING), "PLAYING"):
		return
	Session.current_minigame.finish([3, [0, 2], 1])
	await step(2)
	var names: Array[String] = [RoundStyle.player_name(3), "%s & %s" % [RoundStyle.player_name(0), RoundStyle.player_name(2)], RoundStyle.player_name(1)]
	assert_eq(ui.results.get_row_texts(), names, "the tied pair shares one line")
	assert_eq(ui.hud.get_team_order(), [] as Array[int], "no team boxes without teams")


func test_nothing_leaks_into_the_next_round() -> void:
	_offline(4)
	ui = UI_SCENE.instantiate() as RoundUI
	add_child(ui)
	var intros := [0]
	_on(Session.state_changed, func(s: int) -> void:
		if s == S.State.INTRO:
			intros[0] += 1
			if intros[0] == 1:
				Session.current_minigame.assign_teams(2)
				Session.current_minigame.set_role_text(0, "You are the GHOST"))
	Session.start_session(2)
	if not assert_true(await _wait_state(S.State.PLAYING), "round 1 PLAYING"):
		return
	var first := Session.current_minigame
	assert_true(first.has_teams(), "round 1 has teams")
	first.finish_teams([0] as Array[int])
	assert_false(Session.round_groups.is_empty(), "round 1 groups")
	if not assert_true(await _wait_state(S.State.INTRO), "round 2 INTRO"):
		return
	await step(2)
	var second := Session.current_minigame
	assert_true(second != first, "a new minigame")
	assert_false(second.has_teams(), "no teams in round 2")
	assert_eq(second.role_of(0), "", "no role in round 2")
	assert_eq(Session.round_groups, [], "round_groups cleared at the intro")
	assert_eq(ui.intro.get_team_text(), "", "intro: no team")
	assert_eq(ui.intro.get_role_text(), "", "intro: no role")
	assert_eq(ui.hud.get_team_order(), [] as Array[int], "HUD: no team boxes")
	for p: Player in arena.players.values():
		var ring := p.get_component(&"team") as TeamComponent
		assert_false(ring.has_team() or ring.is_ring_shown(), "no ring on P%d" % p.slot)
	if not assert_true(await _wait_state(S.State.PLAYING), "round 2 PLAYING"):
		return
	await step(ceili(RoundUI.ROLE_BANNER_DELAY * 60.0) + 4)
	assert_false(ui.is_banner_shown(), "no role banner in round 2")
	Session.current_minigame.finish([1, 0, 2, 3])
	await step(2)
	assert_eq(ui.results.get_row_texts().size(), 4, "round 2 results: one line per player")


func test_rings_clear_when_the_minigame_leaves() -> void:
	var ps := spawn_arena(4)
	var mg := get_minigame()
	mg.assign_teams(2)
	var ring := ps[0].get_component(&"team") as TeamComponent
	assert_true(ring.is_ring_shown(), "ring shown")
	mg.get_parent().remove_child(mg)
	assert_false(ring.is_ring_shown(), "ring cleared with the round's minigame")
	assert_eq(ring.team, -1, "team cleared")
	stage.add_child(mg)
