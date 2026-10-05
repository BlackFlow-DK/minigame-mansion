extends GameTest
## Blob Ball: pitch, teams, ball physics (shoves, walls, determinism), goals, kick-off resets,
## first to 3, time-out, golden goal and tie. Offline through the harness (this process is
## the host); the networked side is covered by minigames/blob_ball/dev/run_ball_net.ps1.

const ID := &"blob_ball"
const R := BlobBallSim.RADIUS


func _mg() -> BlobBall:
	return get_minigame() as BlobBall


func _frames(seconds: float) -> int:
	return int(ceil(seconds / physics_delta()))


## Sends the ball into the goal `team` attacks and waits for the goal (or `max_frames`).
func _force_goal(mg: BlobBall, team: int, max_frames: int = 400) -> bool:
	for i in max_frames:
		if mg.phase == BlobBall.Phase.PLAY:
			break
		await step(1)
	var before := mg.goal_log.size()
	var att := BlobBall.attack_dir(team)
	mg.ball.pos = Vector3(att * (mg.sim.half_length - 1.0), R, 0.0)
	mg.ball.vel = Vector3(att * 9.0, 0.0, 0.0)
	for i in 120:
		await step(1)
		if mg.goal_log.size() > before or mg.is_finished():
			return true
	return false


# --- Pitch and teams ------------------------------------------------------------------------------

func test_pitch_loads_with_teams_in_their_halves() -> void:
	var ps := spawn_arena(8, ID)
	var mg := _mg()
	if not assert_true(mg != null, "blob_ball loads"):
		return
	assert_eq(mg.get_spawn_points().size(), 8, "8 spawn markers")
	assert_near(mg.sim.half_length, 11.0, 0.001, "22 m pitch for 8")
	assert_near(mg.sim.half_width, 6.5, 0.001, "13 m wide")
	assert_true(mg.get_node_or_null(^"Pitch/WallColliders") != null, "walls built")
	assert_true(mg.get_node_or_null(^"Pitch/GoalLeft") != null and mg.get_node_or_null(^"Pitch/GoalRight") != null, "two goals")
	assert_true(mg.has_teams(), "teams assigned")
	assert_eq(mg.team_slots(0).size(), 4, "4 orange")
	assert_eq(mg.team_slots(1).size(), 4, "4 blue")
	assert_near(mg.ball.pos, Vector3(0.0, R, 0.0), 0.001, "ball on the centre spot")
	assert_true(mg.is_safe(Vector3(3.0, 0.0, 2.0)), "pitch is safe")
	assert_false(mg.is_safe(Vector3(0.0, 0.0, 8.0)), "beyond the side wall is not")
	assert_true(mg.get_node_or_null(^"Scoreboard") != null, "scoreboard")
	await step(20)
	for p in ps:
		var t := mg.team_of(p.slot)
		assert_true(p.global_position.x * BlobBall.attack_dir(t) < -1.0, "P%d (team %d) starts in its own half at %s" % [p.slot, t, p.global_position])
		assert_true(p.facing.x * BlobBall.attack_dir(t) > 0.9, "P%d faces the centre" % p.slot)
		assert_true(p.is_on_floor(), "P%d stands on the pitch" % p.slot)
	assert_eq(mg.role_of(ps[0].slot).contains("goal"), true, "role line names the goal to attack")


func test_small_pitch_and_odd_teams() -> void:
	spawn_arena(3, ID)
	var mg := _mg()
	assert_near(mg.sim.half_length, 8.0, 0.001, "16 m pitch for 3")
	assert_near(mg.sim.half_width, 5.0, 0.001, "10 m wide")
	var a := mg.team_slots(0).size()
	var b := mg.team_slots(1).size()
	assert_eq(a + b, 3, "everyone on a team")
	assert_true(absi(a - b) == 1, "sizes differ by one (%d / %d)" % [a, b])
	var small := 0 if a < b else 1
	assert_near(mg.kick_power(mg.team_slots(small)[0]), mg.small_team_kick_bonus, 0.001, "smaller team shoves harder")
	assert_near(mg.kick_power(mg.team_slots(1 - small)[0]), 1.0, 0.001, "bigger team normal")


## Uneven teams: a lone blob (1 v 2) starts a goal up; golden goal: the ball rolls further and
## a harder golden shove keeps the normal lift.
func test_lone_blob_head_start_and_sharper_golden_goal() -> void:
	spawn_arena(3, ID)
	var mg := _mg()
	var lone := mg.short_team()
	assert_true(lone >= 0 and mg.team_slots(lone).size() == 1, "3 players: a lone blob")
	assert_eq(mg.score[lone], mg.lone_blob_head_start, "the lone blob's side starts a goal up")
	assert_eq(mg.score[1 - lone], 0, "the pair starts at 0")
	var roll := mg.sim.roll_decel
	mg._rpc_golden(mg.match_time)
	assert_near(mg.sim.roll_decel, roll * mg.golden_roll_scale, 0.0001, "golden goal: the ball rolls further")
	mg.golden_kick_boost = 0.5
	mg.clock = mg.match_time + mg.golden_goal_time  # the end of the golden goal: full boost
	var s := mg.team_slots(1 - lone)[0]
	mg.ball = mg.sim.kickoff_state()
	mg._kick_ball(s, Vector3.RIGHT)
	assert_near(mg.ball.vel.x, mg.sim.kick_speed * 1.5, 0.01, "1.5x the shot speed")
	assert_near(mg.ball.vel.y, mg.sim.kick_lift, 0.01, "the normal lift (under the bar)")


func test_teams_split_evenly_for_every_count() -> void:
	for n: int in [2, 4, 6]:
		var ids: Array[int] = []
		for i in n:
			ids.append(i)
		var split := Minigame.split_teams(ids, 2)
		var c := [0, 0]
		for s: int in split:
			c[split[s]] += 1
		assert_eq(c[0], c[1], "%d players split evenly" % n)
	spawn_arena(6, ID)
	var mg := _mg()
	assert_eq(mg.team_slots(0).size(), 3, "3 orange of 6")
	assert_eq(mg.team_slots(1).size(), 3, "3 blue of 6")
	assert_near(mg.sim.half_length, 11.0, 0.001, "big pitch for 6")


# --- Ball physics -----------------------------------------------------------------------------------

func test_shove_launches_ball_along_facing() -> void:
	var ps := spawn_arena(2, ID)
	var mg := _mg()
	await step(5)
	var face := Vector3(1.0, 0.0, 1.0).normalized()
	var shover := ps[0]
	ps[1].place_at(Transform3D(Basis.IDENTITY, Vector3(-6.0, 0.0, -4.0)))
	mg.ball.pos = Vector3(0.0, R, 0.0)
	mg.ball.vel = Vector3.ZERO
	shover.place_at(Transform3D(Basis(Vector3.UP, atan2(face.x, face.z)), -face * (R + 0.4 + 0.35)))
	var kicks := watch(mg, &"ball_kicked")
	await step(2)
	await step(1, func(_i: int) -> void: shover.intent.action_pressed = true)
	await step(1)
	assert_eq(kicks.size(), 1, "one kick")
	if kicks.size() > 0:
		assert_eq(kicks[0][0], shover.slot, "credited to the shover")
	var flat := Vector3(mg.ball.vel.x, 0.0, mg.ball.vel.z)
	assert_true(flat.length() > 9.0, "launched hard (%.1f m/s)" % flat.length())
	assert_true(flat.normalized().dot(face) > 0.97, "along the facing (%s)" % flat.normalized())
	assert_true(mg.ball.vel.y > 1.0 or mg.ball.pos.y > R + 0.05, "with some lift")
	var start := mg.ball.pos
	await step(20)
	var moved := mg.ball.pos - start
	assert_true(Vector3(moved.x, 0.0, moved.z).normalized().dot(face) > 0.95, "ball travels along the facing")


func test_walking_into_the_ball_nudges_it() -> void:
	var ps := spawn_arena(2, ID)
	var mg := _mg()
	await step(5)
	ps[1].place_at(Transform3D(Basis.IDENTITY, Vector3(-6.0, 0.0, -4.0)))
	mg.ball.pos = Vector3(2.0, R, 0.0)
	mg.ball.vel = Vector3.ZERO
	ps[0].place_at(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-1.0, 0.0, 0.0)))
	await step(60, func(_i: int) -> void: ps[0].intent.move = Vector2(1.0, 0.0))
	assert_true(mg.ball.pos.x > 3.5, "ball pushed ahead (x=%.2f)" % mg.ball.pos.x)
	var gap := Vector2(mg.ball.pos.x - ps[0].global_position.x, mg.ball.pos.z - ps[0].global_position.z).length()
	assert_true(gap > R + 0.4 - 0.15, "the ball never sinks into the blob (gap %.2f)" % gap)


func test_ball_bounces_off_walls_and_never_leaves_the_pitch() -> void:
	var sim := BlobBallSim.new()
	sim.configure(22.0, 13.0, 4.0)
	var s := sim.kickoff_state()
	# A straight roll into the side wall comes back.
	s.vel = Vector3(0.0, 0.0, 12.0)
	for i in 90:
		sim.step(s, 1.0 / 60.0)
	assert_true(s.vel.z < -2.0, "bounced off the side wall (vz=%.2f)" % s.vel.z)
	# 60 s of random kicks, every frame inside.
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var worst := -INF
	s = sim.kickoff_state()
	for frame in 3600:
		if frame % 25 == 0:
			var a := rng.randf() * TAU
			sim.kick(s, Vector3(cos(a), 0.0, sin(a)), rng.randf_range(0.8, 1.8))
		sim.step(s, 1.0 / 60.0)
		worst = maxf(worst, _outside_by(sim, s.pos))
		if sim.goal_side(s) >= 0:
			s = sim.kickoff_state()  # a goal: back to the centre like the game does
	assert_true(worst <= 0.002, "ball centre never past the walls (worst %.4f m)" % worst)


## How far the ball centre is beyond where it may be (<= 0 inside).
func _outside_by(sim: BlobBallSim, p: Vector3) -> float:
	var r := R
	if absf(p.x) > sim.half_length and absf(p.z) < sim.goal_half_width:
		return maxf(maxf(absf(p.x) - (sim.half_length + sim.goal_depth - r), absf(p.z) - (sim.goal_half_width - r)), p.y - (sim.goal_height - r))
	var out := maxf(absf(p.z) - (sim.half_width - r), r - p.y - 0.001)
	if absf(p.z) >= sim.goal_half_width or p.y >= sim.goal_height:
		out = maxf(out, absf(p.x) - (sim.half_length - r))
	var cr := sim.corner_radius - r
	var cx := absf(p.x) - (sim.half_length - sim.corner_radius)
	var cz := absf(p.z) - (sim.half_width - sim.corner_radius)
	if cx > 0.0 and cz > 0.0 and absf(p.z) >= sim.goal_half_width:
		out = maxf(out, sqrt(cx * cx + cz * cz) - cr)
	return out


func test_integrator_is_deterministic() -> void:
	var paths: Array = []
	for run in 2:
		var sim := BlobBallSim.new()
		sim.configure(19.0, 11.5, 3.8)
		var s := sim.kickoff_state()
		var path: Array[Vector3] = []
		for frame in 900:
			if frame % 40 == 0:
				var a := float(frame) * 0.37
				sim.kick(s, Vector3(cos(a), 0.0, sin(a)), 1.0 + 0.2 * sin(a))
			sim.step(s, 1.0 / 60.0)
			var blob := Vector3(sin(frame * 0.05) * 4.0, 0.0, cos(frame * 0.03) * 3.0)
			sim.contact(s, blob, Vector3(cos(frame * 0.05) * 0.2, 0.0, -sin(frame * 0.03) * 0.09) * 60.0, 0.4, 0.4, 0.6, 0.28)
			sim.collide_bounds(s)
			if sim.goal_side(s) >= 0:
				s = sim.kickoff_state()
			path.append(s.pos)
		paths.append(path)
	var same := true
	for i in (paths[0] as Array).size():
		if paths[0][i] != paths[1][i]:
			same = false
			fail("paths split at frame %d: %s vs %s" % [i, paths[0][i], paths[1][i]])
			break
	assert_true(same, "same inputs, same path (bit for bit)")


func test_fast_ball_bumps_a_blob() -> void:
	var ps := spawn_arena(2, ID)
	var mg := _mg()
	await step(5)
	ps[1].place_at(Transform3D(Basis.IDENTITY, Vector3(-6.0, 0.0, -4.0)))
	ps[0].place_at(Transform3D(Basis.IDENTITY, Vector3(3.0, 0.0, 0.0)))
	mg.ball.pos = Vector3(0.0, R, 0.0)
	mg.ball.vel = Vector3(14.0, 0.0, 0.0)
	var hits := watch(ps[0], &"got_hit")
	await step(30)
	assert_true(hits.size() >= 1, "the blob got bumped")
	assert_true(mg.ball.vel.x < 3.0, "the ball bounced off it (vx=%.2f)" % mg.ball.vel.x)


# --- Rules ----------------------------------------------------------------------------------------

func test_goal_scores_once_then_kickoff_reset() -> void:
	var ps := spawn_arena(4, ID)
	var mg := _mg()
	await step(5)
	var goals := watch(mg, &"goal_scored")
	var resets := watch(mg, &"kickoff_reset")
	mg.ball.pos = Vector3(mg.sim.half_length - 1.0, R, 0.0)
	mg.ball.vel = Vector3(8.0, 0.0, 0.0)
	await step(30)
	assert_eq(goals.size(), 1, "one goal")
	if goals.size() == 1:
		assert_eq(goals[0][0], 0, "ORANGE scores in the right goal")
	assert_eq(mg.score, [1, 0] as Array[int], "1 - 0")
	assert_eq(mg.phase, BlobBall.Phase.CELEBRATE, "celebrating")
	for p in ps:
		assert_true(p.frozen, "P%d frozen for the celebration" % p.slot)
	await step(_frames(mg.celebrate_time) + 2)
	assert_eq(goals.size(), 1, "still exactly one goal while the ball sits in the net")
	assert_eq(resets.size(), 1, "kick-off reset")
	assert_near(mg.ball.pos, Vector3(0.0, R, 0.0), 0.05, "ball back on the centre spot")
	await step(3)
	for t in 2:
		var slots := mg.team_slots(t)
		for i in slots.size():
			var p := ps[slots[i]]
			assert_near(p.global_position * Vector3(1, 0, 1), mg.formation(t, i, slots.size()).origin, 0.1, "P%d at its kick-off spot" % p.slot)
			assert_true(p.frozen, "P%d still frozen during the kick-off count" % p.slot)
	await step(_frames(mg.kickoff_time) + 2)
	assert_eq(mg.phase, BlobBall.Phase.PLAY, "play resumes")
	for p in ps:
		assert_false(p.frozen, "P%d unfrozen" % p.slot)
	assert_false(mg.is_finished(), "one goal does not end the match")


func test_own_goal_counts_for_the_other_team_and_credits() -> void:
	var ps := spawn_arena(2, ID)
	var mg := _mg()
	await step(5)
	var orange := ps[mg.team_slots(0)[0]]
	# An orange shove into the right goal credits the orange shover.
	var face := Vector3(1.0, 0.0, 0.0)
	mg.ball.pos = Vector3(mg.sim.half_length - 3.0, R, 0.0)
	mg.ball.vel = Vector3.ZERO
	var blue := ps[mg.team_slots(1)[0]]
	blue.place_at(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	orange.place_at(Transform3D(Basis(Vector3.UP, PI * 0.5), mg.ball.pos * Vector3(1, 0, 1) - face * (R + 0.7)))
	await step(2)
	await step(1, func(_i: int) -> void: orange.intent.action_pressed = true)
	var ok := false
	for i in 120:
		await step(1)
		if mg.goal_log.size() > 0:
			ok = true
			break
	assert_true(ok, "the shot goes in")
	assert_eq(mg.goals_by_slot.get(orange.slot, 0), 1, "credited to the shover")
	await step(_frames(mg.celebrate_time + mg.kickoff_time) + 6)
	# Orange now shoves the ball into its OWN goal (left): blue scores, nobody credited.
	face = Vector3(-1.0, 0.0, 0.0)
	mg.ball.pos = Vector3(-mg.sim.half_length + 3.0, R, 0.0)
	mg.ball.vel = Vector3.ZERO
	orange.place_at(Transform3D(Basis(Vector3.UP, -PI * 0.5), mg.ball.pos * Vector3(1, 0, 1) - face * (R + 0.7)))
	var goals := watch(mg, &"goal_scored")
	await step(2)
	await step(1, func(_i: int) -> void: orange.intent.action_pressed = true)
	for i in 120:
		await step(1)
		if goals.size() > 0:
			break
	assert_eq(goals.size(), 1, "own goal scored")
	if goals.size() == 1:
		assert_eq(goals[0][0], 1, "it counts for BLUE")
		assert_eq(goals[0][3], -1, "nobody credited for an own goal")
	assert_eq(mg.score, [1, 1] as Array[int], "1 - 1")


func test_first_to_three_wins_with_team_order() -> void:
	spawn_arena(4, ID)
	var mg := _mg()
	await step(5)
	for k in 3:
		assert_true(await _force_goal(mg, 1), "blue goal %d" % (k + 1))
	assert_true(mg.is_finished(), "third goal ends the match")
	assert_eq(mg.score, [0, 3] as Array[int], "0 - 3")
	assert_eq(mg.finish_groups.size(), 2, "two tied groups (the teams)")
	if mg.finish_groups.size() == 2:
		assert_eq(mg.finish_groups[0], mg.team_slots(1), "BLUE first")
		assert_eq(mg.finish_groups[1], mg.team_slots(0), "ORANGE second")
	assert_near(mg.finish_grace, 2.0, 0.001, "2 s end grace")
	assert_eq(ranking.size(), 4, "flat ranking has everyone")


func test_time_out_most_goals_wins() -> void:
	spawn_arena(4, ID)
	var mg := _mg()
	mg.match_time = 4.0
	await step(5)
	assert_true(await _force_goal(mg, 0), "orange scores")
	assert_true(await run_until_finished(_frames(10.0)), "ends at the whistle")
	assert_false(mg.golden, "no golden goal when someone leads")
	assert_eq(mg.finish_groups.size(), 2, "two teams")
	if mg.finish_groups.size() == 2:
		assert_eq(mg.finish_groups[0], mg.team_slots(0), "ORANGE first")
	assert_true(mg.clock >= 4.0 - 0.05, "not before the time")


func test_draw_goes_to_golden_goal_then_tie() -> void:
	spawn_arena(4, ID)
	var mg := _mg()
	mg.match_time = 1.0
	mg.golden_goal_time = 1.5
	assert_true(await run_until_finished(_frames(6.0)), "finishes")
	assert_true(mg.golden, "went to golden goal")
	assert_eq(mg.score, [0, 0] as Array[int], "0 - 0")
	assert_eq(mg.finish_groups.size(), 1, "one tied group")
	if mg.finish_groups.size() == 1:
		assert_eq((mg.finish_groups[0] as Array).size(), 4, "everyone in it")
	assert_true(mg.clock >= 2.5 - 0.05, "after the golden goal time (%.2f)" % mg.clock)


func test_golden_goal_ends_it() -> void:
	spawn_arena(4, ID)
	var mg := _mg()
	mg.match_time = 0.5
	for i in _frames(1.0):
		await step(1)
		if mg.golden:
			break
	assert_true(mg.golden, "golden goal started")
	assert_false(mg.is_finished(), "not over yet")
	assert_true(await _force_goal(mg, 1), "blue scores")
	assert_true(mg.is_finished(), "the golden goal ends it")
	if mg.finish_groups.size() == 2:
		assert_eq(mg.finish_groups[0], mg.team_slots(1), "BLUE first")


# --- Bots ----------------------------------------------------------------------------------------

func test_bot_goal_puts_chaser_behind_the_ball() -> void:
	var ps := spawn_arena(2, ID)
	var mg := _mg()
	await step(5)
	var orange := ps[mg.team_slots(0)[0]]
	mg.ball.pos = Vector3(2.0, R, 1.0)
	mg.ball.vel = Vector3.ZERO
	orange.place_at(Transform3D(Basis.IDENTITY, Vector3(-1.0, 0.0, -3.0)))
	var g := mg.get_bot_goal(orange)
	assert_true(g.x < mg.ball.pos.x - 0.5, "off the line: get behind the ball first (goal %s)" % g)
	assert_true(mg.is_safe(g), "goal on the pitch")
	# Lined up behind it: run through the ball toward the blue goal.
	orange.place_at(Transform3D(Basis.IDENTITY, Vector3(-3.0, 0.0, 1.0)))
	g = mg.get_bot_goal(orange)
	assert_true(g.x > mg.ball.pos.x + 0.5, "lined up: run through it (goal %s)" % g)
	# Standing on the wrong side: goes round, not through.
	orange.place_at(Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, 1.0)))
	g = mg.get_bot_goal(orange)
	assert_true(absf(g.z - mg.ball.pos.z) > 1.0, "goes round the ball (goal %s)" % g)
