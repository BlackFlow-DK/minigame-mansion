extends GameTest
## Spotlight Chairs: pad count, the check (on a pad survives, off a pad is out, one blob per
## pad: the first on it), the shuffle, and a scripted round to the end. Bot-only rounds are
## in test_spotlight_chairs_bots.gd. Offline through the harness; the host is this process.

const ID := &"spotlight_chairs"


func _mg() -> SpotlightChairs:
	return get_minigame() as SpotlightChairs


func _place(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis(), pos))


## Far from every pad (and from each other): `i`-th parking spot along the front.
func _park(mg: SpotlightChairs, p: Player, i: int) -> void:
	var best := Vector3(-7.0 + 1.6 * i, 0.0, 6.8)
	for k in 30:
		if mg.pad_under(best) < 0 and mg._nearest_pad_dist(best) > 1.2:
			break
		best.z -= 0.4
	_place(p, best)


## Runs the music until it stops, then through the warning to the check.
func _stop_and_check(mg: SpotlightChairs) -> void:
	mg.stop_music_now()
	await step(2)
	assert_eq(mg.phase, SpotlightChairs.Phase.WARNING, "the music stopped: warning")
	await step(int(mg.warn_time / physics_delta()) + 3)


func test_scene_loads_with_8_spawns_and_one_pad_fewer_than_players() -> void:
	var ps := spawn_arena(8, ID)
	var mg := _mg()
	assert_true(mg != null, "spotlight_chairs loads as SpotlightChairs")
	if mg == null:
		return
	assert_eq(mg.time_limit, 90.0, "90 s backstop")
	var points := mg.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn points")
	for t in points:
		assert_true(mg.is_safe(t.origin), "spawn %s inside the room" % t.origin)
		assert_true(mg.pad_under(t.origin) < 0, "spawn %s not on a pad" % t.origin)
	assert_eq(mg.pad_positions.size(), 7, "8 players: 7 pads")
	for i in mg.pad_positions.size():
		assert_true(mg.is_safe(mg.pad_positions[i]), "pad %d inside the room" % i)
		for j in range(i + 1, mg.pad_positions.size()):
			var d := SpotlightChairs._flat_dist(mg.pad_positions[i], mg.pad_positions[j])
			assert_true(d >= SpotlightChairs.PAD_MIN_GAP, "pads %d and %d %.2f m apart" % [i, j, d])
	await step(30)
	for p in ps:
		assert_true(p.alive and p.is_on_floor(), "P%d stands on the ballroom floor" % p.slot)
		assert_near(p.global_position.y, 0.0, 0.05, "P%d on the floor" % p.slot)
	assert_eq(mg.phase, SpotlightChairs.Phase.MUSIC, "the music plays")
	for n in [2, 3, 4, 5, 6, 7]:
		assert_eq(SpotlightChairs.ring_layout(n - 1).size(), n - 1, "%d players: %d pads" % [n, n - 1])
	for count in [1, 3, 5, 7]:
		var lay := mg.random_layout(count)
		assert_eq(lay.size(), count, "random layout of %d pads" % count)
		for q in lay:
			assert_true(mg.is_safe(q), "random pad %s inside the room" % q)


func test_small_rounds_get_fewer_pads() -> void:
	spawn_arena(4, ID)
	assert_eq(_mg().pad_positions.size(), 3, "4 players: 3 pads")


func test_on_a_pad_survives_off_a_pad_is_out() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	mg.rng.seed = 11
	await step(2)
	_place(ps[0], mg.pad_positions[0])
	_place(ps[1], mg.pad_positions[1])
	_park(mg, ps[2], 0)
	await step(10)
	assert_eq(mg.pad_owners, [0, 1] as Array[int], "each pad owned by the blob on it")
	var outs := watch(ps[2], &"eliminated")
	var checks := watch(mg, &"checked")
	await _stop_and_check(mg)
	assert_eq(checks.size(), 1, "one check")
	assert_true(ps[0].alive and ps[1].alive, "blobs on pads survive")
	assert_false(ps[2].alive, "the blob off a pad is out")
	assert_eq(outs.size(), 1, "eliminated once")
	if outs.size() == 1:
		assert_eq(outs[0][0], &"no_seat", "reason no_seat")
	assert_eq(mg.knocked_out, [2] as Array[int], "knocked out in order")
	assert_true(ps[0].frozen and ps[1].frozen, "everyone frozen for the pause")
	assert_eq(mg.phase, SpotlightChairs.Phase.PAUSE, "pause after the check")
	# The pause runs out: pads shuffle to one fewer, the music resumes, blobs unfreeze.
	await step(int(mg.pause_time / physics_delta()) + 4)
	assert_eq(mg.phase, SpotlightChairs.Phase.MUSIC, "music again")
	assert_eq(mg.round_index, 1, "second round")
	assert_eq(mg.pad_positions.size(), 1, "2 left: 1 pad")
	assert_false(ps[0].frozen or ps[1].frozen, "unfrozen for the music")


## `first` steps on the pad, a moment later `second` squeezes on too: only `first` is safe.
func _two_on_one_pad(first: int, second: int) -> void:
	var ps := spawn_arena(4, ID)
	var mg := _mg()
	await step(2)
	var pad := mg.pad_positions[0]
	_place(ps[first], pad + Vector3(-0.3, 0.0, 0.0))
	var others := [0, 1, 2, 3].filter(func(s: int) -> bool: return s != first and s != second)
	_place(ps[others[0]], mg.pad_positions[1])
	_place(ps[others[1]], mg.pad_positions[2])
	_park(mg, ps[second], 0)
	await step(20)
	_place(ps[second], pad + Vector3(0.3, 0.0, 0.0))
	await step(20)
	assert_true(mg.pad_under(ps[second].global_position) == 0, "the second blob stands on the pad too")
	assert_true(mg.pad_under(ps[first].global_position) == 0, "the first blob is still on it")
	assert_eq(mg.pad_owners[0], first, "the first on the pad owns it")
	await _stop_and_check(mg)
	assert_true(ps[first].alive, "P%d (first on the pad) safe" % first)
	assert_false(ps[second].alive, "P%d (second on the same pad) out" % second)
	assert_true(ps[others[0]].alive and ps[others[1]].alive, "the others on their own pads survive")


func test_two_on_one_pad_only_the_first_is_safe() -> void:
	await _two_on_one_pad(0, 1)


func test_two_on_one_pad_arrival_not_slot_decides() -> void:
	await _two_on_one_pad(3, 0)


func test_nobody_on_a_pad_nobody_is_out() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	await step(2)
	for i in ps.size():
		_park(mg, ps[i], i * 2)
	await step(5)
	await _stop_and_check(mg)
	for p in ps:
		assert_true(p.alive, "P%d still in (nobody sat)" % p.slot)
	await step(int(mg.pause_time / physics_delta()) + 4)
	assert_eq(mg.pad_positions.size(), 2, "still 2 pads for 3 players")


func test_shuffle_moves_pads() -> void:
	var ps := spawn_arena(5, ID)
	var mg := _mg()
	mg.rng.seed = 5
	var layouts := watch(mg, &"layout_changed")
	await step(2)
	for i in 4:
		_place(ps[i], mg.pad_positions[i])
	_park(mg, ps[4], 0)
	await step(5)
	var before := mg.pad_positions.duplicate()
	await _stop_and_check(mg)
	assert_false(ps[4].alive, "P4 out")
	await step(int(mg.pause_time / physics_delta()) + 4)
	assert_eq(layouts.size(), 1, "one new layout sent")
	var after := mg.pad_positions
	assert_eq(after.size(), 3, "4 left: 3 pads")
	for q in after:
		assert_true(mg.is_safe(q), "new pad %s inside the room" % q)
		for b in before:
			assert_true(SpotlightChairs._flat_dist(q, b) >= SpotlightChairs.PAD_MOVE_MIN - 0.01, "new pad %s moved away from %s" % [q, b])
	for i in after.size():
		for j in range(i + 1, after.size()):
			assert_true(SpotlightChairs._flat_dist(after[i], after[j]) >= SpotlightChairs.PAD_MIN_GAP - 0.01, "new pads spaced")
	# The pad models really sit at the new spots after the animation.
	await step(30)
	for i in after.size():
		var node := mg.get_node(NodePath("Pads/Pad%d" % i)) as Node3D
		assert_true(node.visible, "pad %d shown" % i)
		assert_near(node.position, after[i], 0.05, "pad %d model at its new spot" % i)
	assert_false((mg.get_node(^"Pads/Pad3") as Node3D).visible, "the fourth pad sank away")


## Scripted players walk to assigned pads each round: the round ends with one survivor
## and a ranking of survivor first, then reverse knock-out order.
func test_round_ends_with_one_survivor_and_valid_ranking() -> void:
	var ps := spawn_arena(4, ID)
	var mg := _mg()
	mg.time_scale = 2.0
	# Round r: players[0..pads-1] head for pads in slot order (P3 is out first, then P2, then P1).
	var drive := func(_i: int) -> void:
		for p in ps:
			p.intent.clear()
			if not p.alive or mg.phase == SpotlightChairs.Phase.PAUSE:
				continue
			var target := Vector3.INF
			if p.slot < mg.pad_positions.size():
				target = mg.pad_positions[p.slot]
			else:
				target = Vector3(-6.0 + 3.0 * p.slot, 0.0, 6.5)
			var to := Vector2(target.x - p.global_position.x, target.z - p.global_position.z)
			if to.length() > 0.15:
				p.intent.move = to.normalized() * clampf(to.length() / 1.0, 0.3, 1.0)
	var frames := 0
	while not mg.is_finished() and frames < 60 * 90:
		await step(1, drive)
		frames += 1
	assert_true(mg.is_finished(), "the round finished")
	assert_eq(ranking, [0, 1, 2, 3] as Array[int], "survivor first, then reverse knock-out order")
	assert_eq(mg.knocked_out, [3, 2, 1] as Array[int], "one out per music round")
	var alive := ps.filter(func(p: Player) -> bool: return p.alive)
	assert_eq(alive.size(), 1, "one survivor")
	assert_true(mg.elapsed < mg.time_limit, "inside the time limit (%.1f s)" % mg.elapsed)


func test_bot_goals() -> void:
	var ps := spawn_arena(4, ID)
	var mg := _mg()
	mg.bot_rng.seed = 3
	await step(2)
	# Early in the music: somewhere near a pad, never on the stage or outside.
	for k in 20:
		var g := mg.get_bot_goal(ps[1])
		assert_true(mg.is_safe(g), "wander goal %s safe" % g)
		assert_true(mg._nearest_pad_dist(g) < 3.0, "wander goal %s near a pad" % g)
	# Warning: the nearest pad nobody holds.
	_place(ps[2], mg.pad_positions[0])
	_place(ps[1], mg.pad_positions[0] + Vector3(1.2, 0.0, 0.0))
	await step(3)
	mg.stop_music_now()
	await step(2)
	var goal := mg.get_bot_goal(ps[1])
	assert_true(mg.pad_positions.has(goal), "warning: the goal is a pad")
	assert_true(goal != mg.pad_positions[0], "not the pad P2 already holds")
	assert_eq(mg.get_bot_goal(ps[2]), mg.pad_positions[0], "a pad owner stays on its pad")
	assert_false(mg.is_safe(Vector3(0.0, 0.0, -7.5)), "the stage back is not a goal area")
	assert_false(mg.is_safe(Vector3(9.8, 0.0, 0.0)), "the wall is not safe")
