extends GameTest
## Game modes: the minigame catalog, round-order pools (playlist, min players), the vote (tally,
## ties, bot votes, the real Session flow), mutator rolls by setting and blocklist, mutators on
## players (compose with body size and minigame tuning, restore exactly; Session's RPC path on
## every player), practice (no points, no coins, back to LOBBY) and the late-join snapshot.

const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")
const S := preload("res://session/session.gd")
const IN_PROGRESS: Array[StringName] = [&"statue_garden", &"masquerade", &"hide_and_sneak", &"ghost_tag"]
const CosmeticsData := preload("res://cosmetics/catalog.gd")
const PLANNED: Array[StringName] = [&"portrait_panic", &"snowball_fight", &"rising_tide"]

var arena: Stage = null
var _connections: Array = []


func before_each() -> void:
	Session.abort_session()
	Session.scene_override = DEV_ARENA
	Session.time_scale = 50.0
	Session.order_seed = 4321
	_reset_setup()


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
	_reset_setup()
	Mutators.set_mirror(false)
	if arena:
		arena.clear()
		remove_child(arena)
		arena.queue_free()
		arena = null


func _reset_setup() -> void:
	Session.configure(8, GameModes.Order.SHUFFLE, [], Mutators.Mode.OFF)
	Session.forced_mutator = &""


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


func _size(p: Player) -> SizeComponent:
	return p.get_component(&"size") as SizeComponent


# --- Catalog ---------------------------------------------------------------------------------

func test_catalog_covers_every_registry_id_and_the_upcoming_ones() -> void:
	var all: Array[StringName] = []
	all.append_array(MinigameRegistry.IDS)
	all.append_array(IN_PROGRESS)
	all.append_array(PLANNED)
	for id in all:
		var info := MinigameCatalog.info(id)
		assert_true(info["known"], "%s has a catalog entry" % id)
		assert_true(str(info["name"]) != "" and str(info["rule"]) != "", "%s: name and rule" % id)
		assert_true(MinigameCatalog.KIND_NAMES.has(info["kind"]), "%s: known kind" % id)
		assert_true(int(info["min"]) >= 2 and int(info["max"]) <= 8, "%s: 2..8 players" % id)
	assert_eq(MinigameCatalog.min_players(&"hide_and_sneak"), 3, "Hide and Sneak needs 3")
	assert_eq(MinigameCatalog.min_players(&"blob_ball"), 2, "team games need 2")
	var unknown := MinigameCatalog.info(&"brand_new_game")
	assert_false(unknown["known"], "unknown id")
	assert_eq(unknown["name"], "Brand New Game", "name from the id")
	assert_eq(unknown["kind"], &"party", "fallback kind")
	assert_true(MinigameCatalog.fits(&"brand_new_game", 2), "fallback 2..8")


# --- Round order -----------------------------------------------------------------------------

func test_playlist_pool_and_order_never_draw_an_unticked_id() -> void:
	var ticked: Array[StringName] = [&"bumper_sumo", &"coin_scramble", &"blob_ball"]
	var pool := GameModes.pool(GameModes.Order.PLAYLIST, ticked, 4)
	assert_eq(pool, [&"bumper_sumo", &"coin_scramble", &"blob_ball"] as Array[StringName], "registry order, ticked only")
	assert_eq(GameModes.pool(GameModes.Order.SHUFFLE, ticked, 4), MinigameRegistry.IDS, "Shuffle ignores the ticks")
	for seed_value in 30:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var order := S.build_round_order(12, rng, pool)
		assert_eq(order.size(), 12, "12 rounds from 3 ids (repeats)")
		for id in order:
			if not assert_true(ticked.has(id), "seed %d drew unticked %s" % [seed_value, id]):
				return
		for i in range(1, order.size()):
			if not assert_true(order[i] != order[i - 1], "no id twice in a row"):
				return


func test_playlist_session_plays_only_ticked_games() -> void:
	_offline(4)
	Session.configure(4, GameModes.Order.PLAYLIST, [&"hot_potato", &"paint_splat"], Mutators.Mode.OFF)
	assert_eq(Session.playlist, [&"hot_potato", &"paint_splat"] as Array[StringName], "playlist stored")
	var intros := _rec(Session.round_intro)
	Session.start_session(4)
	for r in 4:
		if not assert_true(await _wait_state(S.State.PLAYING), "round %d playing" % r):
			return
		_finish_now()
	assert_true(await _wait_state(S.State.PODIUM), "podium")
	assert_eq(intros.size(), 4, "4 intros")
	for e: Array in intros:
		assert_true([&"hot_potato", &"paint_splat"].has(e[0]["id"]), "only ticked ids (%s)" % e[0]["id"])


func test_min_player_filter() -> void:
	var ids: Array[StringName] = [&"bumper_sumo", &"hide_and_sneak", &"blob_ball"]
	assert_eq(GameModes.fitting(ids, 2), [&"bumper_sumo", &"blob_ball"] as Array[StringName], "Hide and Sneak needs 3+")
	assert_eq(GameModes.fitting(ids, 3), ids, "3 players: all")
	assert_eq(GameModes.pool(GameModes.Order.SHUFFLE, [], 2, ids), [&"bumper_sumo", &"blob_ball"] as Array[StringName], "pool filters")
	# Only an unfit game ticked: the pool falls back to what fits instead of stalling.
	assert_eq(GameModes.pool(GameModes.Order.PLAYLIST, [&"hide_and_sneak"], 2, ids), [&"bumper_sumo", &"blob_ball"] as Array[StringName], "fallback")
	var rng := RandomNumberGenerator.new()
	for i in 50:
		var c := GameModes.pick_candidates(GameModes.pool(GameModes.Order.VOTE, [], 2, ids), rng)
		if not assert_false(c.has(&"hide_and_sneak"), "never a vote card that needs 3+ with 2 players"):
			return


# --- Vote ------------------------------------------------------------------------------------

func test_vote_tally_counts_ties_and_no_votes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	assert_eq(GameModes.tally({0: 2, 1: 2, 2: 0}, 3, rng), 2, "most votes wins")
	assert_eq(GameModes.counts({0: 2, 1: 2, 2: 0, 3: 9}, 3), [1, 0, 2] as Array[int], "counts ignore bad indices")
	var seen := {}
	for i in 200:
		seen[GameModes.tally({0: 0, 1: 1, 2: 2, 3: 2, 4: 0}, 3, rng)] = true
	assert_eq(seen.keys().size(), 2, "a 2-2 tie goes either way")
	assert_false(seen.has(1), "never the loser")
	seen.clear()
	for i in 200:
		seen[GameModes.tally({}, 3, rng)] = true
	assert_eq(seen.keys().size(), 3, "no votes: any card")
	assert_eq(GameModes.tally({}, 0, rng), -1, "no candidates")


func test_vote_candidates_are_distinct_and_avoid_the_last_game() -> void:
	var rng := RandomNumberGenerator.new()
	for i in 100:
		var c := GameModes.pick_candidates(MinigameRegistry.IDS, rng, &"bumper_sumo", [&"coin_scramble"])
		var uniq := {}
		for id in c:
			uniq[id] = true
		if not assert_eq(uniq.size(), 3, "3 distinct candidates"):
			return
		if not assert_false(c.has(&"bumper_sumo"), "not last round's game while others are left"):
			return
	var two: Array[StringName] = [&"a", &"b"]
	assert_eq(GameModes.pick_candidates(two, rng).size(), 2, "fewer ids than cards: all of them")


func test_vote_session_flow_with_bots_and_the_local_vote() -> void:
	_offline(4)
	Session.vote_time = 8.0
	Session.configure(2, GameModes.Order.VOTE, [], Mutators.Mode.OFF)
	var states := _rec(Session.state_changed)
	var started := _rec(Session.vote_started)
	var decided := _rec(Session.vote_decided)
	var intros := _rec(Session.round_intro)
	Session.time_scale = 1.0
	Session.start_session(2)
	assert_eq(Session.state, S.State.VOTE, "VOTE before round 1")
	assert_true(Net.session_in_progress, "session in progress")
	assert_eq(started.size(), 1, "vote_started")
	assert_eq(Session.vote_candidates.size(), 3, "3 cards")
	assert_eq(Session.vote_index, 0, "for round 0")
	assert_true(arena.players.values().all(func(p: Player) -> bool: return p.frozen), "players frozen while voting")
	Session.vote(2, false)
	assert_eq(Session.vote_marks.get(0, -1), 2, "local marker on card 2")
	Session.vote(0, true)
	assert_eq(Session.vote_marks[0], 0, "moved and locked on card 0")
	assert_true(Session.vote_locked.has(0), "locked")
	Session.vote(1, true)
	assert_eq(Session.vote_marks[0], 0, "a lock is final")
	# Bots vote within the vote time; all locked ends it early.
	for i in 60 * 9:
		if Session.vote_winner >= 0:
			break
		await step(1)
	assert_eq(decided.size(), 1, "the host decided")
	for s: int in Net.roster:
		assert_true(Session.vote_marks.has(s), "slot %d voted" % s)
	var counts := GameModes.counts(Session.vote_marks, 3)
	assert_eq(counts[Session.vote_winner], counts.max(), "winner has the most votes (ties random)")
	var winner_id: StringName = decided[0][1]
	assert_true(await _wait_state(S.State.INTRO, 300), "INTRO after the reveal")
	assert_eq(intros[0][0]["id"], winner_id, "round 1 is the winner")
	assert_eq(Session.vote_candidates.size(), 0, "vote cleared at the intro")
	Session.time_scale = 50.0
	assert_true(await _wait_state(S.State.PLAYING), "round 1 plays")
	_finish_now()
	assert_true(await _wait_state(S.State.VOTE), "VOTE again before round 2")
	assert_eq(Session.vote_index, 1, "for round 1")
	assert_true(states.has([S.State.VOTE]), "state_changed(VOTE)")


func test_vote_input_ignores_non_players_and_bad_cards() -> void:
	_offline(3)
	Session.configure(2, GameModes.Order.VOTE, [], Mutators.Mode.OFF)
	Session.start_session(2)
	Session._host_vote(0, 7, true)
	assert_false(Session.vote_marks.has(0), "bad card index ignored")
	Session._host_vote(55, 1, true)
	assert_false(Session.vote_marks.has(55), "a slot not in the roster is ignored")
	Session.abort_session()
	Session.vote(1, true)
	assert_false(Session.vote_marks.has(0), "no votes outside VOTE")


# --- Mutator rolls ---------------------------------------------------------------------------

func test_mutator_roll_rates_by_setting() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var n := 4000
	var got := {Mutators.Mode.OFF: 0, Mutators.Mode.SOMETIMES: 0, Mutators.Mode.ALWAYS: 0}
	for mode: int in got.keys():
		for i in n:
			if Mutators.roll(mode, [], rng) != &"":
				got[mode] += 1
	assert_eq(got[Mutators.Mode.OFF], 0, "Off: never")
	assert_eq(got[Mutators.Mode.ALWAYS], n, "Always: every round")
	var rate := float(got[Mutators.Mode.SOMETIMES]) / n
	assert_true(rate > 0.22 and rate < 0.28, "Sometimes: about 25%% (%.3f)" % rate)


func test_mutator_blocklist_avoid_and_forced() -> void:
	var rng := RandomNumberGenerator.new()
	var block: Array[StringName] = [&"slippery", &"mirror"]
	assert_false(Mutators.allowed(block).has(&"slippery"), "allowed() drops the blocked")
	assert_eq(Mutators.allowed(block).size(), Mutators.IDS.size() - 2, "the rest stay")
	for i in 500:
		var m := Mutators.roll(Mutators.Mode.ALWAYS, block, rng, &"", &"turbo")
		if not assert_false(block.has(m) or m == &"turbo", "never blocked, not last round's (%s)" % m):
			return
	assert_eq(Mutators.roll(Mutators.Mode.OFF, [], rng, &"giant"), &"giant", "forced wins over Off")
	assert_eq(Mutators.roll(Mutators.Mode.ALWAYS, block, rng, &"slippery"), &"", "forced but blocked: none")
	var every: Array = []
	every.assign(Mutators.IDS)
	assert_eq(Mutators.roll(Mutators.Mode.ALWAYS, every, rng), &"", "all blocked: none")


func test_session_reads_the_minigame_blocklist_before_the_round() -> void:
	_offline(3)
	var blocking := load("res://modes/dev/blocklist_arena.tscn") as PackedScene
	if not assert_true(blocking != null, "fixture scene"):
		return
	Session.scene_override = blocking
	assert_eq(Session._blocklist_for(&"bumper_sumo"), [&"giant", &"tiny", &"turbo", &"slippery", &"super_shove", &"heavy", &"mirror"], "script default read without loading the scene")
	Session.configure(4, GameModes.Order.SHUFFLE, [], Mutators.Mode.ALWAYS)
	var intros := _rec(Session.round_intro)
	Session.start_session(3)
	for r in 3:
		if not assert_true(await _wait_state(S.State.PLAYING), "round %d" % r):
			return
		assert_eq(Session.round_mutator, &"low_gravity", "the only allowed mutator")
		_finish_now()
	assert_eq(intros[0][0]["mutator"], &"low_gravity", "intro info carries it")
	assert_eq(intros[0][0]["mutator_line"], "Low gravity!", "and the card line")


# --- Mutators on players ---------------------------------------------------------------------

func test_mutators_compose_with_size_and_sumo_tuning_and_restore_exactly() -> void:
	var ps := spawn_arena(4, &"bumper_sumo")
	var big := ps[1]
	big.loadout["size"] = "big"
	await step(2)
	var status := big.get_component(&"status") as StatusComponent
	var jump := big.get_component(&"jump") as JumpComponent
	var shove := big.get_component(&"shove") as ShoveComponent
	var size := _size(big)
	var kb0 := status.knockback_multiplier
	var jh0 := jump.jump_height
	var force0 := shove.force
	var lift0 := shove.lift
	var radius0 := ((big.get_node(^"CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D).radius
	var sumo_kb := size.base_of(&"status", &"knockback_multiplier")
	assert_eq(sumo_kb, BumperSumo.KNOCKBACK_MULTIPLIER, "sumo's knockback tuning is the base")
	assert_eq(size.base_of(&"shove", &"force"), BumperSumo.SHOVE_FORCE, "sumo's shove force tweak is the base")
	assert_near(kb0, sumo_kb * SizeComponent.effective(CosmeticsData.size_entry("big"), "knockback"), 0.0001, "big x sumo")
	assert_near(force0, BumperSumo.SHOVE_FORCE * SizeComponent.effective(CosmeticsData.size_entry("big"), "shove"), 0.0001, "big x sumo force")

	Mutators.apply_to(big, &"heavy")
	await step(1)
	assert_near(status.knockback_multiplier, kb0 * 0.6, 0.0001, "heavy x big x sumo")
	assert_near(jump.jump_height, jh0 * 0.6, 0.0001, "heavy jump")
	assert_eq(size.base_of(&"status", &"knockback_multiplier"), sumo_kb, "the base stays sumo's")
	Mutators.apply_to(big, &"super_shove")
	await step(1)
	assert_eq(status.knockback_multiplier, kb0, "replacing the mutator drops the old one exactly")
	assert_near(shove.force, force0 * 1.8, 0.0001, "super shove x big x sumo")
	assert_eq(size.base_of(&"shove", &"force"), BumperSumo.SHOVE_FORCE, "the base stays sumo's force")
	assert_near(shove.lift, lift0 * 1.4, 0.0001, "lift (not a size stat)")
	# A minigame retunes mid-round to an absolute value: it becomes the new base.
	shove.force = 12.0
	await step(1)
	assert_near(shove.force, 12.0 * SizeComponent.effective(CosmeticsData.size_entry("big"), "shove") * 1.8, 0.0001, "retune composes")
	shove.force = force0 / SizeComponent.effective(CosmeticsData.size_entry("big"), "shove")
	await step(1)
	Mutators.apply_to(big, &"giant")
	await step(2)
	var radius := ((big.get_node(^"CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D).radius
	assert_near(radius, radius0 * 1.35, 0.0001, "giant capsule x big")
	assert_near(size.body_scale, 1.22 * 1.35, 0.0001, "giant body x big")

	Mutators.remove_from(big)
	await step(2)
	assert_eq(status.knockback_multiplier, kb0, "knockback restored exactly")
	assert_eq(jump.jump_height, jh0, "jump restored exactly")
	assert_eq(shove.lift, lift0, "lift restored exactly")
	assert_near(shove.force, force0, 0.00001, "force back")
	radius = ((big.get_node(^"CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D).radius
	assert_eq(radius, radius0, "capsule restored exactly")
	assert_eq(size.body_scale, 1.22, "body restored")
	assert_false(Mutators.applied_to(big), "no modifier left")


func test_every_mutator_applies_and_restores_exactly() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var keys: Array[String] = ["movement:max_speed", "movement:ground_accel", "movement:ground_friction",
		"movement:turn_accel", "movement:air_accel", "movement:overspeed_decel", "movement:locked_friction",
		"jump:jump_height", "jump:time_to_apex", "jump:terminal_velocity", "shove:force", "shove:lift",
		"shove:reach", "shove:width", "status:knockback_multiplier"]
	var before := _values(p, keys)
	for id in Mutators.IDS:
		var m := Mutators.get_mutator(id)
		Mutators.apply_to(p, id)
		await step(1)
		var now := _values(p, keys)
		for k in keys:
			var want: float = before[k] * float(m.stats.get(k, 1.0))
			if not assert_near(now[k], want, 0.0001, "%s: %s" % [id, k]):
				return
		assert_near(_size(p).body_scale, m.body_scale, 0.0001, "%s: body" % id)
		Mutators.remove_from(p)
		await step(1)
		var after := _values(p, keys)
		for k in keys:
			if not assert_eq(after[k], before[k], "%s: %s restored exactly" % [id, k]):
				return
	var jump := p.get_component(&"jump") as JumpComponent
	var g0 := jump.get_gravity_strength()
	Mutators.apply_to(p, &"low_gravity")
	await step(1)
	assert_near(jump.get_gravity_strength(), g0 * 0.45, 0.001, "low gravity: gravity x0.45")
	Mutators.remove_from(p)


func test_mutator_is_off_while_frozen_and_back_when_unfrozen() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var mv := p.get_component(&"movement") as MovementComponent
	var base := mv.max_speed
	Mutators.apply_to(p, &"turbo")
	await step(1)
	assert_near(mv.max_speed, base * 1.35, 0.0001, "turbo while playing")
	p.frozen = true
	await step(1)
	assert_eq(mv.max_speed, base, "base while frozen (minigames read/write bases in _setup)")
	assert_near(_size(p).body_scale, 1.0, 0.0001, "body scale is not a stat")
	p.frozen = false
	await step(1)
	assert_near(mv.max_speed, base * 1.35, 0.0001, "back after unfreezing")
	Mutators.remove_from(p)


func test_mirror_swaps_and_restores_the_move_actions() -> void:
	var left := InputMap.action_get_events(&"move_left")
	var right := InputMap.action_get_events(&"move_right")
	Mutators.set_mirror(true)
	assert_true(Mutators.is_mirrored(), "mirrored")
	assert_eq(InputMap.action_get_events(&"move_left").size(), right.size(), "left now has right's events")
	assert_true(InputMap.action_get_events(&"move_left")[0].is_match(right[0]), "same event")
	Mutators.set_mirror(true)
	assert_true(InputMap.action_get_events(&"move_right")[0].is_match(left[0]), "twice is still once")
	Mutators.set_mirror(false)
	assert_false(Mutators.is_mirrored(), "restored")
	var l2 := InputMap.action_get_events(&"move_left")
	assert_eq(l2.size(), left.size(), "left count back")
	for i in left.size():
		assert_true(l2[i].is_match(left[i]), "left event %d back in order" % i)


func test_session_rpc_applies_the_mutator_to_every_player_and_takes_it_off() -> void:
	_offline(4)
	Session.forced_mutator = &"giant"
	var changes := _rec(Session.mutator_changed)
	Session.start_session(2)
	assert_eq(Session.round_mutator, &"giant", "set with the INTRO")
	assert_eq(Session.current_minigame.active_mutator, &"giant", "the minigame knows")
	for p: Player in arena.players.values():
		assert_true(Mutators.applied_to(p), "slot %d has it" % p.slot)
		assert_near(_size(p).body_scale, 1.35, 0.0001, "slot %d is giant" % p.slot)
	# A client runs the same RPC handler: replay it as a client would receive it.
	Session._rpc_intro(0, 2, "bumper_sumo", 6.0, false, "tiny")
	for p: Player in arena.players.values():
		assert_near(_size(p).body_scale, 0.7, 0.0001, "client path: slot %d tiny" % p.slot)
	assert_true(await _wait_state(S.State.PLAYING), "playing")
	_finish_now()
	assert_eq(Session.state, S.State.RESULTS, "results")
	assert_eq(Session.round_mutator, &"", "off at RESULTS")
	for p: Player in arena.players.values():
		assert_false(Mutators.applied_to(p), "slot %d restored" % p.slot)
		assert_eq(_size(p).body_scale, 1.0, "slot %d normal size" % p.slot)
	assert_eq(changes.back(), [&""], "mutator_changed(none) last")


func test_late_spawned_players_get_the_round_mutator() -> void:
	_offline(3)
	Session.forced_mutator = &"tiny"
	Session.start_session(2)
	Net.add_bot()
	var extra := arena.spawn_players()  # a client's manifest would spawn them like this
	await step(1)
	for p in extra:
		assert_near(_size(p).body_scale, 0.7, 0.0001, "slot %d spawned late is tiny" % p.slot)


# --- Practice --------------------------------------------------------------------------------

func test_practice_plays_one_round_without_points_or_coins_and_returns_to_lobby() -> void:
	_offline(3)
	Session.scores = {0: 9, 1: 4, 2: 1}
	var coins := Progression.coins
	var states := _rec(Session.state_changed)
	var finishes := _rec(Session.round_finished)
	var ends := _rec(Session.session_finished)
	Session.start_practice(&"coin_scramble", &"turbo")
	assert_eq(Session.state, S.State.INTRO, "INTRO")
	assert_true(Session.practice, "practice flag")
	assert_eq(Session.round_count, 1, "one round")
	assert_eq(Session.round_mutator, &"turbo", "the picked mutator")
	assert_true(await _wait_state(S.State.PLAYING), "playing")
	_finish_now()
	assert_eq(Session.state, S.State.RESULTS, "results")
	assert_eq(finishes.size(), 1, "round_finished once")
	assert_eq(finishes[0][1], {0: 0, 1: 0, 2: 0}, "no points")
	assert_eq(Progression.coins, coins, "no coins")
	assert_eq(Progression.last_round_award, 0, "no award")
	assert_true(await _wait_state(S.State.LOBBY), "back to LOBBY")
	assert_eq(ends.size(), 0, "no podium / session_finished")
	assert_false(states.has([S.State.PODIUM]), "never PODIUM")
	assert_false(Session.practice, "flag cleared")


func test_practice_guards() -> void:
	_offline(2)
	Session.start_practice(&"not_a_game")
	assert_eq(Session.state, S.State.LOBBY, "unknown id ignored")
	Session.start_practice(&"bumper_sumo", &"no_such_mutator")
	assert_eq(Session.state, S.State.INTRO, "starts")
	assert_eq(Session.round_mutator, &"", "unknown mutator: none")
	Session.abort_session()
	Net.leave()
	Net.start_offline()
	Session.start_practice(&"bumper_sumo")
	assert_eq(Session.state, S.State.LOBBY, "one player: sumo needs 2")


func test_progression_skips_practice_rounds() -> void:
	_offline(2)
	var ranking: Array[int] = [0, 1]
	var coins := Progression.coins
	Session.practice = true
	Session.round_finished.emit(ranking, {0: 3, 1: 2})
	assert_eq(Progression.coins, coins, "practice: nothing")
	Session.practice = false
	Session.round_finished.emit(ranking, {0: 3, 1: 2})
	assert_true(Progression.coins > coins, "a real round still pays")


# --- Setup and late joiners ------------------------------------------------------------------

func test_configure_replicates_the_setup() -> void:
	_offline(2)
	var changed := _rec(Session.setup_changed)
	Session.configure(12, GameModes.Order.VOTE, [&"bumper_sumo", "blob_ball"], Mutators.Mode.SOMETIMES)
	assert_eq(changed.size(), 1, "setup_changed")
	assert_eq(Session.setup_rounds, 12, "rounds")
	assert_eq(Session.order_mode, GameModes.Order.VOTE, "order")
	assert_eq(Session.playlist, [&"bumper_sumo", &"blob_ball"] as Array[StringName], "playlist as StringNames")
	assert_eq(Session.mutator_mode, Mutators.Mode.SOMETIMES, "mutators")
	assert_eq(GameModes.summary(12, GameModes.Order.VOTE, Mutators.Mode.SOMETIMES, 2), "12 rounds · Vote (2 games) · Mutators: sometimes", "summary line")


func test_dev_args_set_the_setup() -> void:
	Session.apply_dev_args(PackedStringArray(["--order=playlist", "--playlist=bumper_sumo,hot_potato", "--mutators=always", "--mutator=giant", "--other=1"]))
	assert_eq(Session.order_mode, GameModes.Order.PLAYLIST, "order")
	assert_eq(Session.playlist, [&"bumper_sumo", &"hot_potato"] as Array[StringName], "playlist")
	assert_eq(Session.mutator_mode, Mutators.Mode.ALWAYS, "mutators")
	assert_eq(Session.forced_mutator, &"giant", "forced")


func test_snapshot_carries_mutator_practice_and_vote() -> void:
	_offline(3)
	Session.configure(2, GameModes.Order.VOTE, [], Mutators.Mode.OFF)
	Session.start_session(2)
	Session.vote(1, true)
	var vote_extra := Session.snapshot_extra()
	assert_eq(vote_extra["vote_candidates"].size(), 3, "candidates")
	assert_eq(vote_extra["vote_marks"], {0: 1}, "marks")
	assert_eq(vote_extra["vote_locked"], {0: true}, "locks")
	assert_eq(vote_extra["vote_index"], 0, "index")
	# A late joiner applies it (fields cleared first, as on a fresh peer).
	var cands := Session.vote_candidates.duplicate()
	Session._clear_vote()
	Session.apply_snapshot_extra(S.State.VOTE, vote_extra)
	assert_eq(Session.vote_candidates, cands, "candidates back")
	assert_eq(Session.vote_marks, {0: 1} as Dictionary[int, int], "marks back")
	assert_true(Session.vote_locked.has(0), "lock back")
	Session.abort_session()

	Session.start_practice(&"bumper_sumo", &"giant")
	var extra := Session.snapshot_extra()
	assert_eq(extra["mutator"], "giant", "mutator")
	assert_true(extra["practice"], "practice")
	Session._clear_mutator()
	Session.practice = false
	Session.apply_snapshot_extra(S.State.INTRO, extra)
	assert_eq(Session.round_mutator, &"giant", "mutator back")
	assert_true(Session.practice, "practice back")
	for p: Player in arena.players.values():
		assert_near(_size(p).body_scale, 1.35, 0.0001, "applied to slot %d" % p.slot)
	Session.apply_snapshot_extra(S.State.RESULTS, extra)
	assert_eq(Session.round_mutator, &"", "no mutator outside INTRO / PLAYING")


func _values(p: Player, keys: Array[String]) -> Dictionary:
	var out := {}
	for k in keys:
		var parts := k.split(":")
		out[k] = float(p.get_component(StringName(parts[0])).get(StringName(parts[1])))
	return out
