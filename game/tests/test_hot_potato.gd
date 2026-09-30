extends GameTest
## Hot Potato: arena, holder, passing (touch, shove, no pass-back), fuse expiry and
## bot-only rounds. Offline through the harness; the host is this process.

const ID := &"hot_potato"


func _mg() -> HotPotato:
	return get_minigame() as HotPotato


## Spawns `count` scripted players, lets the first bomb land, then gives it to `slot` with a
## long fuse and no grace so a test controls every hand-over.
func _arena_with_holder(count: int, slot: int) -> HotPotato:
	spawn_arena(count, ID)
	var mg := _mg()
	mg.rng.seed = 7
	await step(1)
	mg.give_bomb(slot, 60.0, 0.0)
	return mg


func _flat_dist(a: Player, b: Player) -> float:
	var d := a.global_position - b.global_position
	return Vector2(d.x, d.z).length()


func _max_speed(p: Player) -> float:
	return (p.get_component(&"movement") as MovementComponent).max_speed


# --- Arena ---------------------------------------------------------------------------------

func test_scene_loads_with_8_spawns_inside_the_fence() -> void:
	var ps := spawn_arena(8, ID)
	var mg := _mg()
	assert_true(mg != null, "hot_potato loads")
	assert_eq(mg.time_limit, 180.0, "180 s backstop (Session ends a stalled round)")
	var points := mg.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn points")
	for t in points:
		var r := Vector2(t.origin.x, t.origin.z).length()
		assert_true(r < HotPotato.PLAY_RADIUS - 1.0, "spawn %s inside the fence" % t.origin)
		assert_true(mg.is_safe(t.origin), "spawn is safe for bots")
		for o in mg.obstacle_positions:
			assert_true(Vector2(t.origin.x - o.x, t.origin.z - o.z).length() > 1.3, "spawn %s clear of obstacle %s" % [t.origin, o])
	assert_eq(ps.size(), 8, "8 players")
	await step(30)
	for i in ps.size():
		assert_true(ps[i].is_on_floor(), "P%d stands on the courtyard" % i)
		assert_near(ps[i].global_position, points[i].origin, 0.2, "P%d stays at its spawn" % i)


func test_fence_keeps_everyone_inside() -> void:
	var ps := spawn_arena(2, ID)
	var dirs := [Vector2(0, 1), Vector2(1, 0)]
	await step(240, func(_i: int) -> void:
		for k in ps.size():
			ps[k].intent.move = dirs[k]
			ps[k].intent.jump_pressed = _i % 20 == 0
			ps[k].intent.jump_held = true)
	for p in ps:
		var r := Vector2(p.global_position.x, p.global_position.z).length()
		assert_true(r <= HotPotato.PLAY_RADIUS + 0.05, "P%d inside the fence (r=%.2f)" % [p.slot, r])


# --- Holder ----------------------------------------------------------------------------------

func test_exactly_one_holder_at_start() -> void:
	var ps := spawn_arena(4, ID)
	var mg := _mg()
	mg.rng.seed = 3
	var given := watch(mg, &"bomb_given")
	assert_eq(mg.holder_slot, -1, "no bomb before play ticks")
	await step(2)
	assert_eq(given.size(), 1, "one bomb handed out")
	var h := mg.holder_slot
	assert_true(h >= 0 and h < 4, "holder is a player")
	assert_eq(given[0][0], h, "bomb_given names the holder")
	assert_true(mg.fuse_left() > 3.0, "fuse is running")
	var rig := mg.get_node(^"BombRig") as Node3D
	assert_true(rig.visible, "bomb shown")
	for p in ps:
		var base := 6.0
		if p.slot == h:
			assert_near(_max_speed(p), base * mg.holder_speed_bonus, 0.001, "holder runs faster")
		else:
			assert_near(_max_speed(p), base, 0.001, "others at normal speed")


func test_touch_passes_once_and_respects_no_pass_back() -> void:
	var mg := await _arena_with_holder(4, 0)
	var ps := players
	var passed := watch(mg, &"bomb_passed")
	ps[1].place_at(Transform3D(Basis.IDENTITY, ps[0].global_position + Vector3(1.6, 0, 0)))
	# P1 walks into P0 and keeps pushing against it.
	var walk := func(_i: int) -> void: ps[1].intent.move = Vector2(-1, 0)
	var frames := 0
	while passed.is_empty() and frames < 60:
		await step(1, walk)
		frames += 1
	assert_eq(passed.size(), 1, "touch passed the bomb")
	if passed.is_empty():
		return
	assert_eq(passed[0], [0, 1, HotPotato.PassKind.TOUCH], "P0 -> P1 by touch")
	assert_eq(mg.holder_slot, 1, "P1 holds it")
	assert_true(_flat_dist(ps[0], ps[1]) < mg.touch_distance, "they touch")
	await step(1, walk)
	assert_near(_max_speed(ps[1]), 6.0 * mg.holder_speed_bonus * mg.gotcha_slow_factor, 0.001, "gotcha: new holder slowed")
	# Still touching, but inside the no-pass-back window: no pass back.
	await step(38, walk)
	assert_true(_flat_dist(ps[0], ps[1]) < mg.touch_distance, "still touching")
	assert_eq(passed.size(), 1, "no pass back inside 0.8 s")
	assert_eq(mg.holder_slot, 1, "P1 still holds it")
	assert_near(_max_speed(ps[1]), 6.0 * mg.holder_speed_bonus, 0.001, "slow wore off")
	# After the window it goes straight back.
	await step(15, walk)
	assert_eq(passed.size(), 2, "passes back after the window")
	assert_eq(mg.holder_slot, 0, "P0 holds it again")


func test_shove_by_holder_passes() -> void:
	var mg := await _arena_with_holder(4, 0)
	var ps := players
	var passed := watch(mg, &"bomb_passed")
	ps[1].place_at(Transform3D(Basis.IDENTITY, ps[0].global_position + Vector3(1.2, 0, 0)))
	ps[0].facing = Vector3.RIGHT
	await step(1)
	assert_true(passed.is_empty(), "1.2 m apart is no touch")
	await step(3, func(i: int) -> void: ps[0].intent.action_pressed = i == 0)
	assert_eq(passed.size(), 1, "the shove passed the bomb")
	if not passed.is_empty():
		assert_eq(passed[0], [0, 1, HotPotato.PassKind.SHOVE], "P0 -> P1 by shove")
	assert_eq(mg.holder_slot, 1, "P1 holds it")


func test_shove_on_holder_does_not_pass() -> void:
	var mg := await _arena_with_holder(4, 0)
	var ps := players
	var passed := watch(mg, &"bomb_passed")
	var hit := watch(ps[0], &"got_hit")
	ps[1].place_at(Transform3D(Basis.IDENTITY, ps[0].global_position + Vector3(1.2, 0, 0)))
	ps[1].facing = Vector3.LEFT
	await step(30, func(i: int) -> void: ps[1].intent.action_pressed = i == 0)
	assert_eq(hit.size(), 1, "P1's shove landed on the holder")
	assert_true(passed.is_empty(), "shoving the holder does not take the bomb")
	assert_eq(mg.holder_slot, 0, "P0 still holds it")


func test_new_bomb_grace_blocks_passing() -> void:
	spawn_arena(2, ID)
	var mg := _mg()
	await step(1)
	mg.give_bomb(0, 60.0, 1.0)
	var passed := watch(mg, &"bomb_passed")
	var ps := players
	ps[1].place_at(Transform3D(Basis.IDENTITY, ps[0].global_position + Vector3(0.9, 0, 0)))
	await step(45)
	assert_true(passed.is_empty(), "no pass during the 1 s grace")
	await step(30)
	assert_eq(passed.size(), 1, "passes once the grace is over")


# --- Fuse --------------------------------------------------------------------------------------

func test_fuse_expiry_knocks_out_the_holder_and_reassigns() -> void:
	var mg := await _arena_with_holder(4, 0)
	var ps := players
	var exploded := watch(mg, &"bomb_exploded")
	var given := watch(mg, &"bomb_given")
	var out := watch(ps[0], &"eliminated")
	var bystander_hit := watch(ps[3], &"got_hit")
	ps[3].place_at(Transform3D(Basis.IDENTITY, ps[0].global_position + Vector3(-1.5, 0, 0)))
	mg.give_bomb(0, 0.5, 0.0)
	given.clear()
	await step(40)
	assert_eq(exploded.size(), 1, "the bomb blew")
	assert_false(ps[0].alive, "holder is out")
	assert_eq(out.size(), 1, "eliminated once")
	if not out.is_empty():
		assert_eq(out[0][0], &"bomb", "reason bomb")
	assert_eq(mg.knocked_out, [0] as Array[int], "knock-out recorded")
	assert_eq(mg.holder_slot, -1, "nobody holds a bomb during the pause")
	assert_eq(bystander_hit.size(), 1, "the blast pushed the bystander")
	assert_true(ps[3].alive, "the blast is harmless")
	await step(100)
	assert_true(given.is_empty(), "2 s pause before the next bomb")
	await step(30)
	assert_eq(given.size(), 1, "a new bomb")
	assert_true(mg.holder_slot in [1, 2, 3], "new holder is a survivor")
	assert_false(mg.is_finished(), "round goes on")


func test_urgency_rises_in_coarse_steps() -> void:
	var mg := await _arena_with_holder(2, 0)
	var levels := watch(mg, &"urgency_changed")
	mg.give_bomb(0, 2.0, 0.0)
	await step(118)
	var seen: Array = []
	for e in levels:
		seen.append(e[0])
	assert_eq(seen, [1, 2, 3], "urgency 0 -> 1 -> 2 -> 3")
	assert_eq(HotPotato.urgency_for(0.0), 0)
	assert_eq(HotPotato.urgency_for(0.95), 3)


func test_fuses_shrink_with_crowds_and_survivors() -> void:
	spawn_arena(8, ID)
	var mg := _mg()
	var full := mg.fuse_range_for(8)
	var last := mg.fuse_range_for(2)
	assert_true(last.y < full.y, "shorter as fewer remain")
	# Worst case for 8: seven bombs at the longest fuse plus the pauses stays under ~70 s.
	var worst := 0.0
	for alive in range(8, 1, -1):
		worst += mg.fuse_range_for(alive).y + mg.explosion_pause
	assert_true(worst < 72.0, "8-player worst case %.1f s" % worst)


# --- Bot rounds ------------------------------------------------------------------------------------

## A bot-only round: every slot (slot 0 too) is driven by a BotBrain. Returns the round
## length in game seconds (fuses scaled by `scale`).
func _bot_round(count: int, seed_value: int, scale: float) -> float:
	var ps := spawn_arena(count, ID, false)
	var mg := _mg()
	mg.rng.seed = seed_value
	mg.time_scale = scale
	var brain0 := BotBrain.new()
	brain0.player = ps[0]
	brain0.minigame = mg
	add_child(brain0)
	brain0.configure(seed_value * 100)
	(ps[0].get_component(&"controller") as ControllerComponent).scripted = true
	for p in ps:
		var c := p.get_component(&"controller") as ControllerComponent
		if c.brain:
			(c.brain as BotBrain).configure(seed_value * 100 + p.slot)
	var exploded := watch(mg, &"bomb_exploded")
	var frames := 0
	# Hold times in game seconds (fuse clock): from getting the bomb to passing or blowing.
	var holds: Array[float] = []
	var clock := [0, 0]  # [frame now, frame the current hold began] (lambdas copy plain locals)
	var end_hold := func() -> void:
		holds.append((clock[0] - clock[1]) * physics_delta() * scale)
		clock[1] = clock[0]
	mg.bomb_given.connect(func(_s: int) -> void: clock[1] = clock[0])
	mg.bomb_passed.connect(func(_f: int, _t: int, _k: int) -> void: end_hold.call())
	mg.bomb_exploded.connect(func(_s: int) -> void: end_hold.call())
	while not mg.is_finished() and frames < 60 * 150:
		await step(1, func(_i: int) -> void: brain0.fill_intent(ps[0].intent, physics_delta()))
		frames += 1
		clock[0] = frames
	assert_true(mg.is_finished(), "%d bots, seed %d: round finished" % [count, seed_value])
	assert_eq(ranking.size(), count, "ranking has every slot")
	var sorted := ranking.duplicate()
	sorted.sort()
	var all: Array[int] = []
	for i in count:
		all.append(i)
	assert_eq(sorted, all, "every slot exactly once")
	var expected: Array[int] = []
	for p in ps:
		if p.alive:
			expected.append(p.slot)
	assert_eq(expected.size(), 1, "one survivor")
	for i in range(mg.knocked_out.size() - 1, -1, -1):
		expected.append(mg.knocked_out[i])
	assert_eq(ranking, expected, "survivor first, then reverse elimination order")
	assert_eq(exploded.size(), count - 1, "one bomb per knock-out")
	var seconds := frames * physics_delta()
	var mean_hold := 0.0
	var short_holds := 0
	for h in holds:
		mean_hold += h
		if h < mg.pass_back_block + 0.1:
			short_holds += 1
	mean_hold /= maxf(holds.size(), 1)
	print("  hot_potato bots=%d seed=%d scale=%.1f: %.1f s, %d passes, mean hold %.2f s (%d holds, %d under 0.9 s)" % [
		count, seed_value, scale, seconds, mg.pass_count, mean_hold, holds.size(), short_holds])
	assert_true(mean_hold > 1.5, "mean hold %.2f s well above the 0.8 s pass-back window" % mean_hold)
	brain0.queue_free()
	return seconds


func test_bots_4_seed_1() -> void:
	await _bot_round(4, 1, 4.0)


func test_bots_4_seed_2() -> void:
	await _bot_round(4, 2, 4.0)


func test_bots_4_seed_3() -> void:
	await _bot_round(4, 3, 4.0)


func test_bots_8_seed_1() -> void:
	await _bot_round(8, 1, 4.0)


func test_bots_8_seed_2() -> void:
	await _bot_round(8, 2, 4.0)


func test_bots_4_real_time() -> void:
	var seconds := await _bot_round(4, 5, 1.0)
	assert_true(seconds < 75.0, "a 4-bot round takes %.1f s" % seconds)
