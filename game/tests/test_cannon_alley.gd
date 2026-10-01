extends GameTest
## Cannon Alley: the schedule and ball maths (pure functions), hits, jumps, knock-outs, the
## host's hit validation, the time limit and the bot hooks. Offline, the host's `call_local`
## RPCs run in place, so `hit_confirmed` firing here is the RPC firing.

const ID := &"cannon_alley"
## Far-row cannon 3 stands at x = 0 and fires +Z; far-row cannon 4 at x = 2.5.
const MID_CANNON := 3
const SIDE_CANNON := 4


## Offline arena with `count` scripted players and an empty schedule (tests inject shots).
## Await it: the first physics steps settle the bodies, so later place_at calls stick (a body
## moved before its first step still sits at its spawn in the physics server, and a blob
## put on top of it rides along like on a moving platform).
func _arena(count: int = 2) -> CannonAlley:
	spawn_arena(count, ID)
	await step(2)
	var mg := get_minigame() as CannonAlley
	mg.begin(1, 0.0, false)
	return mg


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))


## Round time of the ball's first touch of a blob standing at `feet` (-1 if never).
func _first_touch(s: CannonSchedule.Shot, feet: Vector3) -> float:
	var t := s.t
	while t < s.t + CannonSchedule.flight_time(s):
		if CannonSchedule.touches(CannonSchedule.ball_position(s, t), feet):
			return t
		t += 0.001
	return -1.0


## Steps until `cond` holds or `max_frames` pass; `each` runs before every tick.
func _step_until(cond: Callable, max_frames: int, each: Callable = Callable()) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await step(1, each)
	return cond.call()


func test_scene_loads_with_8_spawns_equidistant_from_both_walls() -> void:
	assert_true(MinigameRegistry.has(ID), "cannon_alley is registered")
	var ps := spawn_arena(8, ID)
	var mg := get_minigame() as CannonAlley
	if not assert_true(mg != null, "cannon_alley loads with its own script"):
		return
	assert_eq(ps.size(), 8, "8 players spawned")
	assert_near(mg.time_limit, 60.0, 0.001, "60 s cap")
	var points := mg.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn markers")
	for i in points.size():
		var o := points[i].origin
		assert_near(absf(o.z - CannonSchedule.LANE_HALF_Z), absf(o.z + CannonSchedule.LANE_HALF_Z), 0.001, "spawn %d is as far from both cannon rows" % i)
		assert_true(mg.is_safe(o), "spawn %d is inside the lane" % i)
	for k in 4:
		assert_near(points[2 * k].origin.x, -points[2 * k + 1].origin.x, 0.001, "spawns %d and %d mirror each other" % [2 * k, 2 * k + 1])
	assert_eq(mg.get_node(^"Cannons").get_child_count(), CannonSchedule.cannon_count(), "every cannon stands")
	assert_true(CannonSchedule.cannon_count() >= 12 and CannonSchedule.cannon_count() <= 16, "6-8 cannons per side")
	await step(30)
	for p in ps:
		assert_true(p.global_position.y > -0.1 and p.global_position.y < 0.3, "P%d stands on the floor (y=%.2f)" % [p.slot, p.global_position.y])
	assert_false(mg.is_safe(Vector3(0.0, 0.0, 4.9)), "the lane edge by the muzzles is unsafe")
	assert_false(mg.is_safe(Vector3(9.3, 0.0, 0.0)), "the end wall zone is unsafe")


func test_schedule_is_deterministic_and_ramps_up() -> void:
	var a := CannonSchedule.build(4242)
	var b := CannonSchedule.build(4242)
	var c := CannonSchedule.build(4243)
	assert_true(a.size() > 60, "a full schedule (%d shots)" % a.size())
	if not assert_eq(a.size(), b.size(), "same seed, same number of shots"):
		return
	var same := true
	for i in a.size():
		same = same and a[i].id == i and a[i].t == b[i].t and a[i].cannon == b[i].cannon and a[i].speed == b[i].speed
	assert_true(same, "same seed, same shots")
	var differs := a.size() != c.size()
	for i in mini(a.size(), c.size()):
		differs = differs or a[i].t != c[i].t or a[i].cannon != c[i].cannon
	assert_true(differs, "another seed, another schedule")
	var last_fire := {}
	var fired := {}
	var early := 0
	var late := 0
	var early_speed := 0.0
	var late_speed := 0.0
	var slow_walls := 0
	var early_fast := 0
	var late_fast := 0
	for i in a.size():
		var s := a[i]
		if i > 0:
			assert_true(s.t >= a[i - 1].t, "sorted by fire time")
		assert_true(s.speed >= CannonSchedule.MIN_SPEED and s.speed <= CannonSchedule.MAX_SPEED, "speed %.2f in 5-9 m/s" % s.speed)
		assert_true(s.t >= CannonSchedule.START_DELAY, "no shot before the start delay")
		if last_fire.has(s.cannon):
			assert_true(s.t - float(last_fire[s.cannon]) >= CannonSchedule.CANNON_REST - 0.0001, "cannon %d rests between shots" % s.cannon)
		last_fire[s.cannon] = s.t
		fired[s.cannon] = true
		var fast_pattern := s.pattern != CannonSchedule.Pattern.SLOW_WALL
		if s.t < 20.0:
			early += 1
			if fast_pattern:
				early_speed += s.speed
				early_fast += 1
		elif s.t >= 34.0 and s.t < 52.0:
			late += 1
			if fast_pattern:
				late_speed += s.speed
				late_fast += 1
		if s.pattern == CannonSchedule.Pattern.SLOW_WALL and s.speed <= CannonSchedule.SLOW_SPEED:
			slow_walls += 1
	assert_eq(fired.size(), CannonSchedule.cannon_count(), "every cannon fires")
	assert_true(late > early, "thicker later (%d shots in 18 s late vs %d in the first 18 s)" % [late, early])
	assert_true(late_speed / maxf(late_fast, 1) > early_speed / maxf(early_fast, 1) + 0.8, "faster later (%.2f vs %.2f m/s, slow walls aside)" % [late_speed / maxf(late_fast, 1), early_speed / maxf(early_fast, 1)])
	assert_true(slow_walls > 0, "there are slow walls to jump")
	# Ball motion: out of the muzzle, down onto the floor, across to the far side.
	var s0 := a[0]
	var d := CannonSchedule.cannon_dir(s0.cannon)
	var start := CannonSchedule.ball_position(s0, s0.t)
	assert_near(start, Vector3(CannonSchedule.cannon_x(s0.cannon), CannonSchedule.MUZZLE_Y, -d * CannonSchedule.LANE_HALF_Z), 0.001, "starts at the muzzle")
	var end := CannonSchedule.ball_position(s0, s0.t + CannonSchedule.flight_time(s0))
	assert_near(end.z, d * (CannonSchedule.LANE_HALF_Z - CannonSchedule.BALL_RADIUS), 0.001, "ends at the far side")
	assert_near(end.y, CannonSchedule.ROLL_Y, 0.001, "rolls on the floor")
	var prev := start.z
	for k in range(1, 40):
		var z := CannonSchedule.ball_position(s0, s0.t + CannonSchedule.flight_time(s0) * k / 40.0).z
		assert_true((z - prev) * d > 0.0, "keeps rolling the same way")
		prev = z
	# The live balls follow the function of the round clock.
	var mg: CannonAlley = await _arena(2)
	_put(players[0], Vector3(-9.0, 0.0, 0.0))
	_put(players[1], Vector3(9.0, 0.0, 0.0))
	mg.begin(4242, 20.0)
	await step(90)
	var checked := 0
	for id: int in mg._balls:
		var s: CannonSchedule.Shot = mg._shot_by_id[id]
		assert_near(mg._balls[id].position, CannonSchedule.ball_position(s, mg._t_vis), 0.01, "ball %d where the schedule says" % id)
		checked += 1
	assert_true(checked > 0, "balls were flying at 21.5 s (%d)" % checked)


func test_standing_blob_is_hit_when_the_ball_arrives() -> void:
	var mg: CannonAlley = await _arena(2)
	var p := players[1]
	_put(players[0], Vector3(-7.5, 0.0, 3.0))
	_put(p, Vector3(0.0, 0.0, 0.0))
	await step(10)
	var id := mg.inject_shot(MID_CANNON, mg.round_time() + 0.5, 6.0)
	var s: CannonSchedule.Shot = mg._shot_by_id[id]
	var expected := _first_touch(s, p.global_position)
	assert_true(expected > s.t, "the ball reaches the blob")
	var hit_at := [-1.0]
	var speed_after := [0.0]
	p.got_hit.connect(func(imp: Vector3, src: int) -> void:
		if hit_at[0] < 0.0:
			hit_at[0] = mg.round_time()
			speed_after[0] = Vector2(imp.x, imp.z).length()
			assert_eq(src, -1, "no source player"))
	var stuns := watch(p, &"stunned")
	var confirmed := watch(mg, &"hit_confirmed")
	await step(int((expected - mg.round_time() + 0.6) * 60.0))
	assert_near(hit_at[0], expected, 2.5 / 60.0, "hit when the ball arrives")
	assert_true(speed_after[0] >= mg.knockback * 0.9, "big knockback (%.1f)" % speed_after[0])
	if assert_eq(stuns.size(), 1, "stunned once"):
		assert_near(float(stuns[0][0]), mg.hit_stun, 0.01, "a 1.2 s stun")
	assert_eq(confirmed.size(), 1, "the host counted it")
	assert_eq(mg.hits[1], 1, "one hit")
	assert_true(p.alive, "still in after one hit")
	assert_eq(mg.lives_left(1), 1, "one life left")
	assert_eq(mg.hits[0], 0, "the bystander was not hit")
	# A shove still stuns the normal way (the ball's stun tuning was only for the ball).
	var status := p.get_component(&"status") as StatusComponent
	assert_near(status.stun_max, 0.6, 0.001, "status tuning restored")


func test_well_timed_jump_clears_a_slow_ball_and_a_late_one_does_not() -> void:
	var mg: CannonAlley = await _arena(2)
	var p := players[1]
	_put(players[0], Vector3(-7.5, 0.0, 3.0))
	_put(p, Vector3(0.0, 0.0, 0.0))
	await step(10)
	var hits := watch(p, &"got_hit")
	# Slow ball: centre over the blob at t_c. Take off 0.3 s before (apex just after it passes).
	var id := mg.inject_shot(MID_CANNON, mg.round_time() + 0.5, 5.0)
	var s: CannonSchedule.Shot = mg._shot_by_id[id]
	assert_true(s.speed <= CannonSchedule.SLOW_SPEED, "a slow ball")
	var t_c := s.t + (CannonSchedule.LANE_HALF_Z - p.global_position.z * CannonSchedule.cannon_dir(s.cannon)) / s.speed
	var over := [0]
	var jumped := [false]
	var each := func(_i: int) -> void:
		p.intent.jump_pressed = false
		p.intent.jump_held = jumped[0]
		if not jumped[0] and mg.round_time() >= t_c - 0.3:
			jumped[0] = true
			p.intent.jump_pressed = true
			p.intent.jump_held = true
		var ball := CannonSchedule.ball_position(s, mg.round_time())
		if absf(ball.z - p.global_position.z) < CannonSchedule.HIT_RADIUS and p.global_position.y > 0.3:
			over[0] += 1
	await step(int((t_c - mg.round_time() + 1.0) * 60.0), each)
	assert_true(jumped[0], "jumped")
	assert_true(over[0] >= 5, "was in the air while the ball passed under (%d frames)" % over[0])
	assert_eq(hits.size(), 0, "a well-timed jump clears a slow ball")
	assert_eq(mg.hits[1], 0, "no hit counted")
	# Same ball speed, jump pressed when the ball is already touching: hit.
	await step(30, func(_i: int) -> void: p.intent.clear())
	_put(p, Vector3(0.0, 0.0, 0.0))
	await step(5)
	var id2 := mg.inject_shot(MID_CANNON, mg.round_time() + 0.5, 5.0)
	var s2: CannonSchedule.Shot = mg._shot_by_id[id2]
	var t_c2 := s2.t + CannonSchedule.LANE_HALF_Z / s2.speed
	jumped[0] = false
	await step(int((t_c2 - mg.round_time() + 0.5) * 60.0), func(_i: int) -> void:
		p.intent.jump_pressed = false
		if not jumped[0] and mg.round_time() >= t_c2 - 0.05:
			jumped[0] = true
			p.intent.jump_pressed = true
			p.intent.jump_held = true)
	assert_true(jumped[0], "jumped late")
	assert_eq(hits.size(), 1, "a late jump is hit")


func test_two_hits_knock_out_and_end_the_round() -> void:
	var mg: CannonAlley = await _arena(2)
	var p := players[1]
	_put(players[0], Vector3(-7.5, 0.0, 3.0))
	_put(p, Vector3(0.0, 0.0, 0.0))
	await step(5)
	var outs := watch(p, &"eliminated")
	mg.inject_shot(MID_CANNON, mg.round_time() + 0.3, 8.0)
	assert_true(await _step_until(func() -> bool: return mg.hits[1] == 1, 120), "first hit counted")
	await step(2)
	assert_true(p.alive, "alive after the first hit")
	assert_true((mg._marks[1] as Node3D).visible, "the plaster shows")
	assert_false((mg._marks[0] as Node3D).visible, "no plaster on the unhit player")
	# Let the stun and the grace run out, stand in front of another cannon.
	await step(100)
	_put(p, Vector3(2.5, 0.0, 0.0))
	await step(5)
	mg.inject_shot(SIDE_CANNON, mg.round_time() + 0.3, 8.0)
	assert_true(await _step_until(func() -> bool: return not p.alive, 120), "second hit knocks out")
	if assert_eq(outs.size(), 1, "eliminated once"):
		assert_eq(outs[0][0], &"cannon", "reason cannon")
	assert_eq(mg.hits[1], 2, "two hits")
	assert_eq(mg.knocked_out, [1] as Array[int], "knock-out recorded")
	assert_true(mg.is_finished(), "one blob left: the round is over")
	assert_eq(ranking, [0, 1] as Array[int], "survivor first")


func test_host_refuses_implausible_hit_reports() -> void:
	var mg: CannonAlley = await _arena(2)
	var p := players[1]
	_put(players[0], Vector3(-7.5, 0.0, 3.0))
	_put(p, Vector3(5.0, 0.0, 2.0))
	await step(5)
	var id := mg.inject_shot(MID_CANNON, mg.round_time() + 0.2, 6.0)
	await step(30)
	var s: CannonSchedule.Shot = mg._shot_by_id[id]
	var ball := CannonSchedule.ball_position(s, mg.round_time())
	var me := multiplayer.get_unique_id()
	mg._host_hit(1, id, Vector3(5.0, 0.0, ball.z), me)  # wrong column
	mg._host_hit(1, id, Vector3(0.0, 0.0, 4.5), me)  # the ball is nowhere near yet
	mg._host_hit(1, 99999, Vector3(0.0, 0.0, ball.z), me)  # no such shot
	mg._host_hit(1, id, Vector3(0.0, 0.0, ball.z), me + 7)  # not the player's peer
	mg._host_hit(1, id, Vector3(0.0, 0.0, ball.z), me)  # plausible path, but the host sees the player 5 m away
	assert_eq(mg.rejected_reports, 5, "five refused")
	assert_eq(mg.hits[1], 0, "nothing counted")
	# Plausible and where the host sees the player: counted once, duplicates ignored.
	_put(p, Vector3(0.3, 0.0, ball.z + 0.5))
	mg._host_hit(1, id, p.global_position, me)
	mg._host_hit(1, id, p.global_position, me)
	assert_eq(mg.hits[1], 1, "a plausible report counts once")


func test_round_ends_within_the_limit_with_a_valid_ranking() -> void:
	var ps := spawn_arena(4, ID)
	var mg := get_minigame() as CannonAlley
	mg.begin(77)
	assert_true(await run_until_finished(int((mg.time_limit + 1.0) * 60.0)), "finished")
	assert_true(mg.round_time() <= mg.time_limit + 0.05, "within the limit (%.1f s)" % mg.round_time())
	var sorted := ranking.duplicate()
	sorted.sort()
	assert_eq(sorted, [0, 1, 2, 3] as Array[int], "every slot ranked once")
	var ups := mg.time_up_ranking()
	assert_eq(ups.size(), ps.size(), "time-up ranking covers everyone")
	print("  cannon standing blobs: %.1f s, ranking %s, hits %s" % [mg.round_time(), ranking, mg.hits])


func test_bot_hooks_see_telegraphed_paths() -> void:
	var mg: CannonAlley = await _arena(2)
	var p := players[1]
	_put(players[0], Vector3(-7.5, 0.0, 3.0))
	_put(p, Vector3(0.0, 0.0, -3.0))
	await step(5)
	assert_true(mg.is_safe(Vector3(0.0, 0.0, -4.0)), "no shots: safe")
	var fast := mg.inject_shot(MID_CANNON, mg.round_time() + 0.4, 8.5)
	await step(6)  # the fuse is burning (0.3 s before the shot)
	var paths := mg.imminent_paths()
	assert_eq(paths.size(), 1, "the telegraphed shot is visible")
	assert_eq(int(paths[0]["id"]), fast, "that shot")
	assert_false(mg.is_safe(Vector3(0.0, 0.0, -4.0)), "its path by the muzzle is unsafe")
	assert_true(mg.is_safe(Vector3(2.5, 0.0, -4.0)), "the next column is safe")
	var goal := mg.get_bot_goal(p)
	for path in paths:
		assert_false(CannonAlley.on_path(goal, path), "the goal %s is off the ball's path" % goal)
	assert_true(mg.is_safe(goal), "the goal is safe")
	# A slow ball only blocks its own footprint, so a bot can run at it and hop it.
	await step(80)
	var slow := mg.inject_shot(SIDE_CANNON, mg.round_time() + 0.1, 5.0)
	await step(30)
	var s: CannonSchedule.Shot = mg._shot_by_id[slow]
	var ball := CannonSchedule.ball_position(s, mg.round_time())
	assert_false(mg.is_safe(Vector3(ball.x, 0.0, ball.z)), "the slow ball itself is unsafe")
	assert_true(mg.is_safe(Vector3(ball.x, 0.0, ball.z + 2.2)), "2 m ahead of a slow ball is still safe")
	assert_true(mg.is_safe(Vector3(ball.x, 0.0, ball.z - 1.2)), "behind it is safe")
