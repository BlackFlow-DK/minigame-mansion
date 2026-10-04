extends GameTest
## Statue Garden: the phase cycle, catching (moving / sliding / jumping in RED after the grace;
## standing still or skidding to a stop inside it is safe), the shove timing trick, the win at
## the plinth, the distance ranking, the time limit and the bot goals. Bot-only rounds are in
## test_statue_garden_bots.gd. Offline through the harness; the host is this process.

const ID := &"statue_garden"


func _mg() -> StatueGarden:
	return get_minigame() as StatueGarden


func _place(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis(Vector3.UP, PI), pos))


## Steps until the minigame is in `phase` (skipping phases), at most `max_frames`.
func _reach(mg: StatueGarden, phase: StatueGarden.Phase, max_frames: int = 600) -> bool:
	for i in max_frames:
		if mg.phase == phase:
			return true
		if mg.phase != StatueGarden.Phase.IDLE:
			mg.skip_phase()
		await step(1)
	return mg.phase == phase


func _frames(seconds: float) -> int:
	return int(ceil(seconds / physics_delta()))


func test_scene_loads_with_8_spawns_on_the_start_line() -> void:
	var ps := spawn_arena(8, ID)
	var mg := _mg()
	assert_true(mg != null, "statue_garden loads as StatueGarden")
	if mg == null:
		return
	assert_eq(mg.time_limit, 75.0, "75 s limit")
	assert_eq(mg.get_spawn_points().size(), 8, "8 spawn points")
	assert_true(mg.get_node_or_null(^"Statue") != null, "the statue stands")
	assert_true(mg._statue_head != null and mg._statue_body != null, "statue body and head found")
	assert_true(not mg._eye_mats.is_empty(), "the eyes have their own glow material")
	await step(30)
	var lanes: Array[int] = []
	for p in ps:
		assert_true(p.alive and p.is_on_floor(), "P%d stands on the lawn" % p.slot)
		assert_near(p.global_position.z, StatueGarden.START_Z, 0.1, "P%d on the start line" % p.slot)
		assert_true(mg.is_safe(p.global_position), "P%d starts somewhere safe" % p.slot)
		var d := StatueGarden.distance_to_statue(p.global_position)
		assert_true(d > 24.0 and d < 28.0, "P%d starts %.1f m from the statue" % [p.slot, d])
		lanes.append(mg.lane_of[p.slot])
	lanes.sort()
	assert_eq(lanes, [0, 1, 2, 3, 4, 5, 6, 7] as Array[int], "one lane each")
	assert_eq(mg.phase, StatueGarden.Phase.GREEN, "the first phase is GREEN")
	for c: Array in StatueGarden.obstacle_circles():
		assert_false(mg.is_safe(c[0]), "obstacle %s is not safe ground" % c[0])


func test_phases_cycle_with_the_right_durations() -> void:
	spawn_arena(2, ID)
	var mg := _mg()
	mg.rng.seed = 42
	var phases := watch(mg, &"phase_changed")
	var frame_of: Array[int] = []
	var seen := 0
	for f in _frames(40.0):
		await step(1)
		while seen < phases.size():
			frame_of.append(f)
			seen += 1
	assert_true(phases.size() >= 12, "%d phases in 40 s" % phases.size())
	var expect := StatueGarden.Phase.GREEN
	for i in phases.size():
		var ph: int = phases[i][0]
		var length: float = phases[i][2]
		assert_eq(ph, int(expect), "phase %d in order" % i)
		assert_eq(phases[i][1], i, "phase index %d" % i)
		match ph:
			StatueGarden.Phase.GREEN:
				var lo := mg.first_green_min if i == 0 else mg.green_range.x
				assert_true(length >= lo - 0.001 and length <= mg.green_range.y + 0.001, "GREEN %d lasts %.2f s" % [i, length])
				expect = StatueGarden.Phase.WARNING
			StatueGarden.Phase.WARNING:
				assert_near(length, mg.warn_time, 0.001, "WARNING %d" % i)
				expect = StatueGarden.Phase.RED
			StatueGarden.Phase.RED:
				assert_true(length >= mg.red_range.x - 0.001 and length <= mg.red_range.y + 0.001, "RED %d lasts %.2f s" % [i, length])
				expect = StatueGarden.Phase.GREEN
		if i + 1 < phases.size():
			var took := (frame_of[i + 1] - frame_of[i]) * physics_delta()
			assert_near(took, length, 2.5 * physics_delta(), "phase %d really lasted its length" % i)


func test_moving_in_red_is_caught_and_still_is_not() -> void:
	var ps := spawn_arena(4, ID)
	var mg := _mg()
	var catches := watch(mg, &"caught")
	var respawns := watch(ps[0], &"respawned")
	# Walk everyone up the lawn in GREEN, then: P0 keeps walking, P1 stops at once, P2
	# skids to a stop inside the grace, P3 stops in WARNING.
	await step(20, func(_i: int) -> void:
		for p in ps:
			p.intent.move = Vector2(0.0, -1.0))
	assert_true(await _reach(mg, StatueGarden.Phase.WARNING), "WARNING")
	var walk := func(_i: int) -> void:
		for p in ps:
			p.intent.clear()
		ps[0].intent.move = Vector2(0.0, -1.0)
		ps[1].intent.move = Vector2(0.0, -1.0) if mg.phase == StatueGarden.Phase.WARNING else Vector2.ZERO
		if mg.phase == StatueGarden.Phase.WARNING or (mg.phase == StatueGarden.Phase.RED and mg.elapsed - mg._red_start < 0.12):
			ps[2].intent.move = Vector2(0.0, -1.0)
	await step(_frames(mg.warn_time) - 3, walk)
	assert_eq(mg.phase, StatueGarden.Phase.WARNING, "still WARNING")
	assert_true(catches.is_empty(), "nobody is caught in WARNING")
	await step(10, walk)
	assert_eq(mg.phase, StatueGarden.Phase.RED, "RED")
	assert_true(catches.is_empty(), "nobody is caught inside the grace")
	var z0 := ps[0].global_position.z
	await step(_frames(mg.red_grace + StatueGarden.MOVE_WINDOW) + 4, walk)
	assert_eq(catches.size(), 1, "one blob caught")
	if catches.size() >= 1:
		assert_eq(catches[0][0], 0, "the walker is caught")
	assert_eq(respawns.size(), 1, "sent back with respawn_at")
	assert_true(ps[0].alive, "caught is not eliminated")
	if respawns.size() == 1:
		var xf: Transform3D = respawns[0][0]
		assert_near(xf.origin, mg.start_transform(0).origin, 0.01, "back to its spot on the start line")
		assert_true(xf.origin.z > z0 + 1.0, "pushed back from %.1f" % z0)
	assert_eq(mg.catches.get(0, 0), 1, "the catch is counted")
	# The respawned walker is spared for the rest of this RED; the still ones stay safe.
	await step(30, walk)
	assert_eq(catches.size(), 1, "still only one catch this RED")
	for s in [1, 2, 3]:
		assert_false(catches.any(func(c: Array) -> bool: return c[0] == s), "P%d (still) not caught" % s)


func test_jumping_in_red_is_caught() -> void:
	var ps := spawn_arena(2, ID)
	var mg := _mg()
	var catches := watch(mg, &"caught")
	assert_true(await _reach(mg, StatueGarden.Phase.RED), "RED")
	await step(_frames(mg.red_grace) + 2)
	await step(1, func(_i: int) -> void:
		ps[1].intent.jump_pressed = true
		ps[1].intent.jump_held = true)
	await step(20, func(_i: int) -> void: ps[1].intent.jump_held = true)
	assert_eq(catches.size(), 1, "the jumper is caught")
	if catches.size() == 1:
		assert_eq(catches[0][0], 1, "P1 caught for jumping")


## P0 stands right behind P1. `shove_phase`: when P0 shoves. Returns the catches.
func _shove_trick(at_warning_left: float, in_red: bool) -> Array:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	await step(5)
	_place(ps[1], Vector3(-2.0, 0.0, 9.0))
	_place(ps[0], Vector3(-2.0, 0.0, 10.0))
	await step(10)
	var catches := watch(mg, &"caught")
	assert_true(await _reach(mg, StatueGarden.Phase.WARNING), "WARNING")
	ps[0].facing = Vector3(0.0, 0.0, -1.0)
	var shoved := [false]
	var drive := func(_i: int) -> void:
		for p in ps:
			p.intent.clear()
		var go := false
		if in_red:
			go = mg.phase == StatueGarden.Phase.RED and mg.elapsed - mg._red_start > mg.red_grace + 0.3
		else:
			go = mg.phase == StatueGarden.Phase.WARNING and mg._phase_left <= at_warning_left
		if go and not shoved[0]:
			shoved[0] = true
			ps[0].intent.action_pressed = true
	await step(_frames(mg.warn_time + mg.red_grace + 1.2), drive)
	assert_true(shoved[0], "P0 shoved")
	return catches


func test_shoved_in_red_is_caught() -> void:
	var catches := await _shove_trick(0.0, true)
	assert_true(catches.any(func(c: Array) -> bool: return c[0] == 1), "the victim sliding in RED is caught")


func test_shove_in_warning_catches_only_the_victim() -> void:
	var catches := await _shove_trick(0.12, false)
	assert_true(catches.any(func(c: Array) -> bool: return c[0] == 1), "the victim slides into RED and is caught")
	assert_false(catches.any(func(c: Array) -> bool: return c[0] == 0), "the shover stood still in RED: safe")
	assert_false(catches.any(func(c: Array) -> bool: return c[0] == 2), "the bystander is safe")


func test_touching_the_plinth_wins_and_the_rest_rank_by_distance() -> void:
	var ps := spawn_arena(4, ID)
	var mg := _mg()
	await step(5)
	var front := StatueGarden.STATUE_POS.z + StatueGarden.PLINTH_HALF.y
	_place(ps[2], Vector3(0.5, 0.0, front + 1.6))
	_place(ps[0], Vector3(-3.0, 0.0, 0.0))
	_place(ps[3], Vector3(3.0, 0.0, 4.0))
	_place(ps[1], Vector3(4.0, 0.0, 9.0))
	var wins := watch(mg, &"won")
	await step(5)
	assert_false(mg.is_finished(), "nobody touches it yet")
	var frames := 0
	while not mg.is_finished() and frames < 120:
		await step(1, func(_i: int) -> void:
			for p in ps:
				p.intent.clear()
			ps[2].intent.move = Vector2(0.0, -1.0))
		frames += 1
	assert_true(mg.is_finished(), "touching the plinth ends the round")
	assert_eq(ranking, [2, 0, 3, 1] as Array[int], "winner first, then nearest to the statue")
	assert_near(mg.finish_grace, mg.win_grace, 0.001, "a celebration as end grace")
	assert_eq(wins.size(), 1, "won raised once")
	if wins.size() == 1:
		assert_eq(wins[0][0], 2, "P2 won")
	assert_eq(mg.phase, StatueGarden.Phase.OVER, "the phase is over")


func test_time_limit_ranks_by_distance() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	mg.time_limit = 3.0
	await step(5)
	_place(ps[0], Vector3(0.0, 0.0, 8.0))
	_place(ps[1], Vector3(2.0, 0.0, -2.0))
	_place(ps[2], Vector3(-2.0, 0.0, 3.0))
	var wins := watch(mg, &"won")
	var done := await run_until_finished(_frames(4.0))
	assert_true(done, "the round ends at the time limit")
	assert_eq(ranking, [1, 2, 0] as Array[int], "nearest to the statue first")
	assert_near(mg.finish_grace, mg.time_up_grace, 0.001, "time-up grace")
	assert_true(wins.size() == 1 and wins[0][0] == -1, "won(-1): time ran out")
	assert_true(mg.elapsed >= 3.0 and mg.elapsed < 3.1, "at 3 s (%.2f)" % mg.elapsed)


func test_bot_goals_go_up_the_lane_then_stand_still() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	await step(5)
	assert_eq(mg.phase, StatueGarden.Phase.GREEN, "GREEN")
	for p in ps:
		var g := mg.get_bot_goal(p)
		assert_true(g.z < p.global_position.z - 2.0, "P%d's goal %s is up the lawn" % [p.slot, g])
		assert_true(mg.is_safe(g), "P%d's goal %s is safe" % [p.slot, g])
	# Right in front of the fountain: the goal steps round it.
	_place(ps[1], Vector3(0.2, 0.0, 4.6))
	await step(2)
	var g := mg.get_bot_goal(ps[1])
	assert_true(absf(g.x) > 1.6 and mg.is_safe(g), "round the fountain: %s" % g)
	# Close to the statue: straight at the plinth face.
	_place(ps[2], Vector3(5.0, 0.0, -9.5))
	await step(2)
	g = mg.get_bot_goal(ps[2])
	assert_near(g.z, StatueGarden.STATUE_POS.z + StatueGarden.PLINTH_HALF.y + 0.05, 0.01, "at the plinth face")
	assert_true(absf(g.x) < StatueGarden.PLINTH_HALF.x, "within the plinth's width")
	# WARNING: each bot keeps walking until its reflex fires, then its goal is where it stands.
	assert_true(await _reach(mg, StatueGarden.Phase.WARNING), "WARNING")
	await step(_frames(mg.warn_time) - 2)
	assert_true(await _reach(mg, StatueGarden.Phase.RED), "RED")
	await step(_frames(StatueGarden.BOT_STOP_DELAY.x + StatueGarden.BOT_STOP_JITTER) + 2)
	for p in ps:
		assert_near(mg.get_bot_goal(p), p.global_position, 0.001, "P%d: stand still" % p.slot)
	assert_false(mg.is_safe(Vector3(7.0, 0.0, 0.0)), "the hedge is not safe")
	assert_false(mg.is_safe(Vector3(0.0, 0.0, 15.5)), "behind the start hedge is not safe")


func test_lanes_are_shuffled_by_the_host() -> void:
	var orders: Dictionary[String, bool] = {}
	for k in 6:
		spawn_arena(4, ID)
		var mg := _mg()
		var order: Array[int] = []
		for s in 4:
			order.append(mg.lane_of[s])
		orders[str(order)] = true
		for s in 4:
			assert_near(players[s].global_position.x, StatueGarden.lane_x(mg.lane_of[s], 4), 0.01, "P%d in its lane" % s)
		_teardown()
	assert_true(orders.size() >= 2, "lane orders vary between rounds (%d seen)" % orders.size())
