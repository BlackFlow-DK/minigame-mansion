extends GameTest
## Mansion Dash: the course and the hazard maths (pure functions, deterministic), hammer hits,
## pond falls and respawns at the last checkpoint, the finish order (crossing-time
## interpolation, ties), progress ranking for the unfinished, the round's end rules and the bot
## hooks. Offline, the host's `call_local` RPCs run in place.

const ID := &"mansion_dash"


## Offline arena with `count` scripted players and a fixed layout started at `t0`. Await it: the
## first physics steps settle the bodies so later place_at calls stick.
func _arena(count: int = 2, seed_value: int = 5, t0: float = 0.0) -> MansionDash:
	spawn_arena(count, ID)
	await step(2)
	var mg := get_minigame() as MansionDash
	mg.begin(seed_value, t0)
	return mg


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis(Vector3.UP, PI), pos))


## Steps until `cond` holds or `max_frames` pass; `each` runs before every tick.
func _step_until(cond: Callable, max_frames: int, each: Callable = Callable()) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await step(1, each)
	return cond.call()


## First round time >= `after` at which hammer `k`'s angle crosses 0 (the head at its lowest).
func _hammer_low_time(l: DashCourse.Layout, k: int, after: float) -> float:
	var t := after
	var prev := DashCourse.hammer_angle(l, k, t)
	while t < after + 10.0:
		t += 0.002
		var a := DashCourse.hammer_angle(l, k, t)
		if signf(a) != signf(prev):
			return t
		prev = a
	return -1.0


func test_course_loads_with_8_even_spawns() -> void:
	assert_true(MinigameRegistry.has(ID), "mansion_dash is registered")
	var ps := spawn_arena(8, ID)
	var mg := get_minigame() as MansionDash
	if not assert_true(mg != null, "mansion_dash loads with its own script"):
		return
	assert_eq(ps.size(), 8, "8 players spawned")
	assert_near(mg.time_limit, 75.0, 0.001, "75 s cap")
	var points := mg.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn markers")
	var xs: Array[float] = []
	for i in points.size():
		var o := points[i].origin
		assert_true(o.z > DashCourse.START_Z + 0.5 and o.z < DashCourse.PEN_BACK_Z - 0.5, "spawn %d in the start pen" % i)
		assert_near(o, DashCourse.spawn_xform(i).origin, 0.001, "spawn %d matches DashCourse.spawn_xform" % i)
		assert_near(Vector2(o.x, o.z - DashCourse.FIRST_CHOKE_Z).length(), DashCourse.SPAWN_ARC_R, 0.001,
			"spawn %d is the same run from the first choke" % i)
		var f := points[i].basis * Vector3.MODEL_FRONT
		assert_near(f, Vector3(0.0, 0.0, -1.0), 0.001, "spawn %d faces down the course" % i)
		assert_true(mg.is_safe(o), "spawn %d is safe" % i)
		xs.append(o.x)
	for k in 4:
		assert_near(points[k].origin.x, -points[7 - k].origin.x, 0.001, "spawns %d and %d mirror each other" % [k, 7 - k])
	for k in 7:
		assert_near(points[k + 1].origin.distance_to(points[k].origin), DashCourse.SPAWN_SPACING, 0.01, "evenly spaced")
	# _setup's start layout: every slot on its own point of the 8-point arc.
	var used: Dictionary = {}
	for p in ps:
		var i: int = mg.spawn_index.get(p.slot, -1)
		assert_true(i >= 0 and i < 8 and not used.has(i), "P%d has its own spawn index (%d)" % [p.slot, i])
		used[i] = true
		assert_near(p.global_position, DashCourse.spawn_xform(i, 8).origin, 0.05, "P%d stands on spawn point %d" % [p.slot, i])
	await step(30)
	for p in ps:
		assert_true(p.global_position.y > -0.1 and p.global_position.y < 0.3, "P%d stands on the floor (y=%.2f)" % [p.slot, p.global_position.y])
	assert_eq(mg.get_node(^"Hammers").get_child_count(), 1 + DashCourse.HAMMER_Z.size(), "the rail and every hammer")
	assert_eq(mg.get_node(^"Rafts").get_child_count(), 2 * DashCourse.ROW_Z.size(), "two rafts per row")
	assert_eq(DashCourse.CHECKPOINT_Z.size(), 3, "three checkpoints")
	assert_near(DashCourse.TOTAL, 70.5, 0.001, "a 70 m course")
	# walk the course's walkable profile: the ramp is solid, the hedges and the pond are not
	assert_true(mg.is_safe(Vector3(0.0, 0.0, 29.0)), "the slalom's first row has a middle gap")
	assert_false(mg.is_safe(Vector3(3.0, 0.0, 29.0)), "and hedges either side")
	assert_true(mg.is_safe(Vector3(0.0, 0.0, 26.3 + 2.0)), "between hedge rows is open")
	assert_false(mg.is_safe(Vector3(4.4, 0.0, 0.0)), "the course edge is unsafe")


## Balance: a race, so body size does not change run speed (jump, shove and knockback still do).
func test_run_speed_ignores_body_size() -> void:
	var mg := await _arena(3)
	assert_near(mg.size_speed_share, 0.0, 0.001, "no size speed in the dash")
	(players[0].get_component(&"size") as SizeComponent).set_size_override("small")
	(players[2].get_component(&"size") as SizeComponent).set_size_override("big")
	# Three lanes across the start pen (flat, nothing in the way), running along +X for 1 s.
	for i in 3:
		_put(players[i], Vector3(-3.5, 0.0, DashCourse.PEN_BACK_Z - 0.8 - 1.2 * i))
	await step(10)
	await step(60, func(_i: int) -> void:
		for p in players:
			p.intent.move = Vector2.RIGHT)
	var run: Array[float] = []
	for p in players:
		run.append(p.global_position.x + 3.5)
	assert_near(run[0], run[1], 0.05, "small runs as far as normal (%s)" % str(run))
	assert_near(run[2], run[1], 0.05, "big runs as far as normal (%s)" % str(run))
	var big_jump := (players[2].get_component(&"jump") as JumpComponent).jump_height
	var normal_jump := (players[1].get_component(&"jump") as JumpComponent).jump_height
	assert_true(big_jump < normal_jump, "the size still sets the jump (%.2f < %.2f)" % [big_jump, normal_jump])


func test_hazards_are_deterministic_functions_of_seed_and_time() -> void:
	var a := DashCourse.build(4242)
	var b := DashCourse.build(4242)
	var c := DashCourse.build(4243)
	assert_true(a.log_t.size() > 80, "a full log schedule (%d logs)" % a.log_t.size())
	assert_eq(a.log_t, b.log_t, "same seed, same log times")
	assert_eq(a.log_lane, b.log_lane, "same seed, same log lanes")
	assert_eq(a.hammer_phase, b.hammer_phase, "same seed, same hammers")
	assert_true(a.log_t != c.log_t or a.hammer_phase != c.hammer_phase, "another seed, another layout")
	for i in range(1, a.log_t.size()):
		assert_true(a.log_t[i] >= a.log_t[i - 1], "logs sorted by release time")
	var times: Array[float] = [0.0, 3.3, 7.77, 12.5, 30.01, 61.9]
	for t in times:
		for k in DashCourse.HAMMER_Z.size():
			assert_eq(DashCourse.hammer_head(a, k, t), DashCourse.hammer_head(b, k, t), "hammer %d at %.2f" % [k, t])
			var head := DashCourse.hammer_head(a, k, t)
			assert_near(head.distance_to(Vector3(0.0, DashCourse.PIVOT_Y, DashCourse.HAMMER_Z[k])), DashCourse.ARM, 0.001, "the head hangs on its arm")
		for r in DashCourse.ROW_Z.size():
			for i in 2:
				assert_eq(DashCourse.platform_position(a, r, i, t), DashCourse.platform_position(b, r, i, t), "raft %d/%d" % [r, i])
				assert_true(absf(DashCourse.platform_x(a, r, i, t)) + DashCourse.PLAT_HALF_X <= DashCourse.HALF_W, "rafts stay inside the pond")
			var gap := absf(DashCourse.platform_x(a, r, 1, t) - DashCourse.platform_x(a, r, 0, t))
			assert_true(gap >= 2.0 * DashCourse.PLAT_HALF_X, "the two rafts of row %d never overlap (%.2f)" % [r, gap])
		assert_eq(DashCourse.sweep_angle(a, t), DashCourse.sweep_angle(b, t), "sweeper at %.2f" % t)
	# a log rocks on the crest, then rolls down the ramp, staying on the ground
	var i0 := 0
	var t0: float = a.log_t[i0]
	assert_false(DashCourse.log_active(a, i0, t0 - DashCourse.LOG_WOBBLE - 0.01), "not yet")
	assert_true(DashCourse.log_active(a, i0, t0 - 0.1), "rocking on the crest")
	assert_near(DashCourse.log_position(a, i0, t0 - 0.1).z, DashCourse.LOG_Z_RELEASE, 0.001, "at the crest")
	var prev := DashCourse.LOG_Z_RELEASE
	for k in range(1, 20):
		var p := DashCourse.log_position(a, i0, t0 + DashCourse.log_travel_time() * k / 20.0)
		assert_true(p.z > prev, "rolls toward the start")
		assert_near(p.y, DashCourse.ground_y(p.z) + DashCourse.LOG_R, 0.001, "on the ground")
		prev = p.z
	assert_false(DashCourse.log_active(a, i0, t0 + DashCourse.log_travel_time() + 0.01), "gone at the ramp foot")
	# the live scene follows the functions of the round clock
	var mg: MansionDash = await _arena(2, 4242, 20.0)
	await step(30)
	for k in DashCourse.HAMMER_Z.size():
		assert_near(mg._hammers[k].rotation.z, DashCourse.hammer_angle(mg.layout, k, mg._t_vis), 0.001, "hammer %d node" % k)
	for r in DashCourse.ROW_Z.size():
		for i in 2:
			# AnimatableBody3D (sync_to_physics) shows its new place after the physics step: a tick behind
			assert_near(mg._rafts[r * 2 + i].position, DashCourse.platform_position(mg.layout, r, i, mg.round_time()), 0.06, "raft %d/%d body" % [r, i])
	var live := 0
	for id: int in mg._logs:
		assert_near(mg._logs[id].position, DashCourse.log_position(mg.layout, id, mg._t_vis), 0.001, "log %d node" % id)
		live += 1
	assert_true(live > 0, "logs are rolling at 20.5 s (%d)" % live)


func test_hammer_hits_a_standing_blob_and_not_one_outside_its_arc() -> void:
	var mg: MansionDash = await _arena(2, 9)
	var k := 1
	var hz: float = DashCourse.HAMMER_Z[k]
	var p := players[1]
	var safe := players[0]
	_put(safe, Vector3(0.0, 0.0, hz + 1.4))  # between two hammers: outside every arc
	_put(p, Vector3(0.0, 0.0, hz))
	await step(5)
	var low := _hammer_low_time(mg.layout, k, mg.round_time() + 0.3)
	assert_true(low > 0.0, "the head comes down")
	var hits := watch(p, &"got_hit")
	var safe_hits := watch(safe, &"got_hit")
	var kinds := watch(mg, &"local_hit")
	var stuns := watch(p, &"stunned")
	var dir := signf(DashCourse.hammer_rate(mg.layout, k, low))
	await _step_until(func() -> bool: return hits.size() > 0, int((low - mg.round_time() + 0.5) * 60.0))
	if not assert_eq(hits.size(), 1, "the standing blob is hit once"):
		return
	var imp: Vector3 = hits[0][0]
	assert_near(mg.round_time(), low, 0.25, "when the head swings through")
	assert_true(absf(imp.x) >= mg.hammer_push * 0.9, "big sideways knockback (%.1f)" % imp.x)
	assert_eq(signf(imp.x), dir, "the way the head swings")
	assert_near(imp.z, 0.0, 0.001, "sideways, not along the course")
	assert_eq(kinds[0], [1, &"hammer"], "a hammer hit")
	if assert_eq(stuns.size(), 1, "stunned"):
		assert_near(float(stuns[0][0]), mg.hammer_stun, 0.01, "the hammer's stun")
	var status := p.get_component(&"status") as StatusComponent
	assert_near(status.stun_max, 0.6, 0.001, "status tuning restored")
	# a whole swing cycle later the blob between the hammers was never touched
	await step(int(mg.layout.hammer_period[k] * 60.0) + 10)
	assert_eq(safe_hits.size(), 0, "a blob outside the arcs is never hit")
	for t in 200:
		var tt := mg.round_time() + t * 0.02
		for kk in DashCourse.HAMMER_Z.size():
			assert_false(DashCourse.hammer_touches(mg.layout, kk, tt, Vector3(0.0, 0.0, hz + 1.4)), "between hammers is outside every arc")


func test_falling_in_the_pond_respawns_at_the_last_checkpoint() -> void:
	var mg: MansionDash = await _arena(2, 3)
	var p := players[1]
	_put(players[0], Vector3(-3.0, 0.0, 30.0))
	# on the pond bank: the host records checkpoint 1 (index 1)
	_put(p, Vector3(0.0, 0.05, -11.3))
	await _step_until(func() -> bool: return mg.checkpoints[1] == 1, 30)
	assert_eq(mg.checkpoints[1], 1, "checkpoint 1 (the pond bank) reached")
	var falls := watch(mg, &"fell")
	var respawns := watch(p, &"respawned")
	var t_in := mg.round_time()
	_put(p, Vector3(0.6, -0.9, -17.9))  # in the water between rows 1 and 2
	assert_true(await _step_until(func() -> bool: return falls.size() > 0, 30), "the host saw the fall")
	assert_eq(falls[0][0], 1, "slot 1 fell")
	assert_true(p.alive, "falling in is not a knock-out")
	await step(int(mg.respawn_delay * 60.0) - 15)
	assert_eq(respawns.size(), 0, "still in the water before the delay")
	assert_true(await _step_until(func() -> bool: return respawns.size() > 0, 40), "respawned")
	assert_near(mg.round_time() - t_in, mg.respawn_delay, 0.15, "after about 1 s")
	var xf: Transform3D = respawns[0][0]
	assert_near(xf.origin.z, DashCourse.RESPAWN_Z[1], 0.001, "at checkpoint 1")
	assert_near(p.global_position, xf.origin, 0.15, "the player is there")
	assert_true(p.global_position.y > -0.2, "on dry ground")
	assert_eq(mg.checkpoints[1], 1, "the checkpoint is kept")
	await step(30)
	assert_eq(falls.size(), 1, "one fall, no double respawn")
	assert_eq(mg.falls, 1, "the host counted one fall")


func test_finish_order_by_interpolated_crossing_time() -> void:
	# pure maths: interpolation and the same-tick tie rule
	assert_near(DashCourse.finish_crossing(Vector3(0, 0, -37.8), Vector3(0, 0, -38.2), 10.0, 0.1), 10.05, 0.0001, "half way through the step")
	assert_eq(DashCourse.finish_crossing(Vector3(0, 0, -37.0), Vector3(0, 0, -37.5), 10.0, 0.1), -1.0, "not yet across")
	assert_eq(DashCourse.finish_crossing(Vector3(0, 0, -38.5), Vector3(0, 0, -39.0), 10.0, 0.1), -1.0, "already across")
	var mg: MansionDash = await _arena(3, 2)
	var a := players[0]
	var b := players[1]
	var c := players[2]
	_put(c, Vector3(1.2, 0.0, -33.9))
	_put(a, Vector3(-1.0, 0.0, -37.85))
	_put(b, Vector3(-3.0, 0.0, -37.9))
	await step(3)
	var fins := watch(mg, &"player_finished")
	# same tick: both cross; a is further past the line at the same interpolated time
	_put(a, Vector3(-1.0, 0.0, -38.25))  # 0.4 m step, half way at the line -> frac 0.375
	_put(b, Vector3(-3.0, 0.0, -38.0))   # 0.1 m step, frac 1.0: later
	await step(2)
	if not assert_eq(fins.size(), 2, "two finishers"):
		return
	assert_eq(fins[0][0], 0, "a crossed earlier in the step")
	assert_eq(fins[0][1], 1, "a is 1st")
	assert_eq(fins[1][0], 1, "then b")
	assert_true(float(fins[0][2]) < float(fins[1][2]), "a's crossing time is earlier")
	assert_false(mg.is_finished(), "c is still racing")
	assert_eq(mg.place_of(0), 1, "HUD place 1st")
	# c runs for it
	await _step_until(func() -> bool: return fins.size() == 3, 200, func(_i: int) -> void:
		c.intent.move = Vector2(0.0, -1.0))
	assert_eq(fins.size(), 3, "c finished")
	assert_true(mg.is_finished(), "everyone through: the round is over")
	assert_eq(ranking, [0, 1, 2] as Array[int], "finish order")
	assert_near(mg.finish_grace, 2.0, 0.001, "a short closing moment")


func test_same_time_tie_goes_to_the_one_further_past_the_line() -> void:
	var mg: MansionDash = await _arena(3, 2)
	_put(players[2], Vector3(3.5, 0.0, -30.0))
	_put(players[0], Vector3(-1.0, 0.0, -37.9))
	_put(players[1], Vector3(1.0, 0.0, -37.8))
	await step(3)
	var fins := watch(mg, &"player_finished")
	# both reach the line at the same fraction of the step; slot 1 ends further past it
	_put(players[0], Vector3(-1.0, 0.0, -38.1))  # frac 0.5, 0.1 past
	_put(players[1], Vector3(1.0, 0.0, -38.2))   # frac 0.5, 0.2 past
	await step(2)
	if assert_eq(fins.size(), 2, "two finishers in one step"):
		assert_near(float(fins[0][2]), float(fins[1][2]), 0.0001, "the same crossing time")
		assert_eq(fins[0][0], 1, "the one further past the line wins the tie")


func test_unfinished_are_ranked_by_checkpoint_then_distance() -> void:
	var mg: MansionDash = await _arena(5, 4, 0.0)
	# 0 and 1 past checkpoint 1 (1 further along), 2 past checkpoint 0 but far up the ramp,
	# 3 in the slalom, 4 finished.
	_put(players[4], Vector3(0.0, 0.0, -37.7))
	_put(players[0], Vector3(-1.0, 0.0, -11.3))
	_put(players[1], Vector3(1.0, 0.0, -23.0))
	_put(players[2], Vector3(0.0, DashCourse.RAMP_H + 0.05, -6.5))
	_put(players[3], Vector3(0.0, 0.0, 27.0))
	await step(3)
	_put(players[4], Vector3(0.0, 0.0, -38.3))
	await step(3)
	assert_eq(mg.finish_order, [4] as Array[int], "4 finished")
	assert_eq(mg.checkpoints[1], 2, "1 at checkpoint 2")
	assert_eq(mg.checkpoints[0], 1, "0 at checkpoint 1")
	assert_eq(mg.checkpoints[2], 0, "2 at checkpoint 0")
	assert_eq(mg.checkpoints[3], -1, "3 at none")
	assert_eq(mg.current_ranking(), [4, 1, 0, 2, 3] as Array[int], "finisher, then by checkpoint, then distance")
	# a sinking player counts from its checkpoint, not from where it sank
	var ranks := DashCourse.rank([] as Array[int], [5, 6] as Array[int], {5: 1, 6: 1}, {5: 30.0, 6: 35.0})
	assert_eq(ranks, [6, 5] as Array[int], "same checkpoint: further along first")
	ranks = DashCourse.rank([] as Array[int], [5, 6] as Array[int], {5: 2, 6: 1}, {5: 30.0, 6: 50.0})
	assert_eq(ranks, [5, 6] as Array[int], "a later checkpoint beats distance")
	# the window: 12 s after the first finisher the round ends with that ranking
	mg.begin(4, mg.finish_times[4] + mg.finish_window - 0.3)
	mg._first_finish_t = mg.finish_times[4]
	assert_true(await _step_until(func() -> bool: return mg.is_finished(), 60), "the finish window closed the round")
	assert_eq(ranking, [4, 1, 0, 2, 3] as Array[int], "final ranking")


func test_time_limit_ends_the_race_with_a_full_ranking() -> void:
	var mg: MansionDash = await _arena(4, 6, 74.5)
	_put(players[0], Vector3(-1.0, 0.0, 19.5))
	_put(players[1], Vector3(1.0, 0.0, 25.0))
	_put(players[2], Vector3(-2.0, 0.0, 31.0))
	_put(players[3], Vector3(2.0, 0.0, 22.0))
	assert_true(await _step_until(func() -> bool: return mg.is_finished(), 60), "time up")
	assert_true(mg.round_time() <= mg.time_limit + 0.05, "at the limit (%.2f)" % mg.round_time())
	assert_eq(ranking, [0, 3, 1, 2] as Array[int], "by distance along the course")


func test_bot_hooks_follow_the_course() -> void:
	var mg: MansionDash = await _arena(2, 8, 5.0)
	var p := players[1]
	_put(players[0], Vector3(-3.0, 0.0, 33.0))
	# pond: water is unsafe, a raft's middle is safe, the banks are safe
	await step(2)
	var raft := DashCourse.platform_position(mg.layout, 1, 0, mg.round_time())
	assert_true(mg.is_safe(raft), "the middle of a raft is safe")
	assert_false(mg.is_safe(Vector3(raft.x, 0.0, (DashCourse.ROW_Z[0] + DashCourse.ROW_Z[1]) * 0.5)), "the water between rows is unsafe")
	assert_true(mg.is_safe(Vector3(0.0, 0.0, DashCourse.POND_Z0 + 0.4)), "the near bank is safe")
	assert_false(mg.is_safe(Vector3(DashCourse.BUMPERS[0].x, 0.0, DashCourse.BUMPERS[0].y)), "a bumper is unsafe")
	# hammers: where the head will be within the next moment is unsafe
	var k := 0
	var low := _hammer_low_time(mg.layout, k, mg.round_time() + 0.2)
	await step(int((low - mg.round_time() - 0.2) * 60.0))
	var head := DashCourse.hammer_head(mg.layout, k, mg.round_time() + 0.2)
	assert_false(mg.is_safe(Vector3(head.x, 0.0, DashCourse.HAMMER_Z[k])), "the head's path just ahead is unsafe")
	# goals lead down the course from every section
	for z: float in [33.0, 24.0, 16.0, 3.0, -9.0, -24.0, -34.0]:
		_put(p, Vector3(0.0, DashCourse.ground_y(z) + 0.05, z))
		await step(1)
		var g := mg.get_bot_goal(p)
		assert_true(g.z < z + 1.7, "goal from z=%.1f leads on (%s)" % [z, g])
		assert_true(absf(g.x) <= DashCourse.HALF_W, "goal inside the course")
	# a finished bot heads into the pen, clear of the line
	mg.finish_times[1] = 1.0
	assert_true(mg.get_bot_goal(p).z < DashCourse.FINISH_Z - 2.0, "finished: into the pen")
