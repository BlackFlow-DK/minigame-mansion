extends GameTest
## Snowball Fight: scoop and throw, the ball arc (pure functions), cover, hits (knockback, score
## once), snow-ins and release, the ammo pile, the blizzard's double points, the ranking and its
## tie-breaks, the host's checks of throws and hit reports, aim assist. Offline the host's
## `call_local` RPCs run in place, so the signals firing here are the RPCs firing.

const ID := &"snowball_fight"


## Offline arena with `count` scripted players, everyone parked in a far corner. Await it.
func _arena(count: int = 2) -> SnowballFight:
	spawn_arena(count, ID)
	await step(2)
	var mg := get_minigame() as SnowballFight
	mg.ai_enabled = false
	for i in players.size():
		_put(players[i], Vector3(-8.6 + 0.9 * i, 0.0, 6.2), Vector3.FORWARD)
	await step(2)
	return mg


func _fill(d: Dictionary, values: Array) -> void:
	for i in values.size():
		d[i] = values[i]


func _put(p: Player, pos: Vector3, facing: Vector3 = Vector3.RIGHT) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))
	p.velocity = Vector3.ZERO
	p.facing = facing.normalized()


## Steps until `cond` holds or `max_frames` pass; `each` runs before every tick.
func _step_until(cond: Callable, max_frames: int, each: Callable = Callable()) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await step(1, each)
	return cond.call()


## Gives `p` a ready ball through the real scoop (press, wait out the scoop).
func _arm(mg: SnowballFight, p: Player) -> void:
	assert_true(mg.press(p), "P%d scoops" % p.slot)
	await _step_until(func() -> bool: return mg.can_throw(p.slot), 40)


## Host: a ball from `from` straight at `to` (both blobs), ammo rules aside.
func _inject_at(mg: SnowballFight, from: Player, to: Player) -> int:
	var dir := SnowArc.flat_dir(to.global_position - from.global_position)
	return mg.inject_launch(from.slot, SnowArc.release_point(from.global_position, dir), dir)


func test_scene_loads_registered_with_symmetric_spawns() -> void:
	assert_true(MinigameRegistry.has(ID), "snowball_fight is registered")
	var info := MinigameCatalog.info(ID)
	assert_true(bool(info["known"]), "catalog entry")
	assert_eq(info["kind"], &"throwing", "kind throwing")
	var ps := spawn_arena(8, ID)
	var mg := get_minigame() as SnowballFight
	if not assert_true(mg != null, "loads with its own script"):
		return
	assert_eq(ps.size(), 8, "8 players")
	assert_near(mg.time_limit, 60.0, 0.001, "60 s")
	assert_true(mg.mutator_blocklist.has(&"super_shove"), "super shove blocked (no shove this round)")
	var points := mg.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn markers")
	for i in points.size():
		assert_true(SnowYard.walkable(points[i].origin, 0.6), "spawn %d stands clear of cover" % i)
		var to_centre := -Vector3(points[i].origin.x, 0.0, points[i].origin.z).normalized()
		assert_true((points[i].basis * Vector3.MODEL_FRONT).dot(to_centre) > 0.99, "spawn %d faces the centre" % i)
	for k in 4:
		assert_near(points[2 * k].origin, -points[2 * k + 1].origin, 0.001, "spawns %d and %d mirror through the centre" % [2 * k, 2 * k + 1])
	for p in ps:
		assert_false((p.get_component(&"shove") as ShoveComponent).enabled, "P%d cannot shove" % p.slot)
	# The cover layout is point-symmetric too (no side is better).
	for i in SnowYard.WALLS.size():
		var mirrored := -SnowYard.WALLS[i]
		var found := false
		for j in SnowYard.WALLS.size():
			found = found or (SnowYard.WALLS[j].distance_to(mirrored) < 0.001 and SnowYard.WALL_ALONG_Z[j] == SnowYard.WALL_ALONG_Z[i])
		assert_true(found, "wall %d has a mirror twin" % i)
	assert_true(SnowYard.WALLS.size() >= 6 and SnowYard.WALLS.size() <= 8, "6-8 snow walls")
	await step(30)
	for p in ps:
		assert_true(p.global_position.y > -0.1 and p.global_position.y < 0.3, "P%d stands on the snow" % p.slot)


func test_scoop_then_throw() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	_put(p, Vector3(-3.0, 0.0, 0.0), Vector3.RIGHT)
	await step(3)
	var mv := p.get_component(&"movement") as MovementComponent
	var base := mv.max_speed
	var scoops := watch(mg, &"scooped")
	var launches := watch(mg, &"ball_launched")
	assert_true(mg.press(p), "first press: scoop")
	assert_eq(scoops.size(), 1, "scoop started")
	assert_eq(mg.ammo_of(0), 1, "a ball in hand")
	assert_true(mg.is_scooping(0), "still scooping")
	assert_false(mg.can_throw(0), "cannot throw mid-scoop")
	assert_false(mg.press(p), "a press mid-scoop does nothing")
	await step(2)
	assert_near(mv.max_speed, base * mg.scoop_speed, 0.01, "slowed while scooping")
	await step(int(mg.scoop_time * 60.0) + 2)
	assert_false(mg.is_scooping(0), "scoop done after 0.35 s")
	assert_true(mg.can_throw(0), "ready to throw")
	assert_near(mv.max_speed, base * mg.carry_speed, 0.01, "carrying: 90 % speed")
	assert_true(mg.press(p), "second press: throw")
	if not assert_eq(launches.size(), 1, "one ball thrown"):
		return
	var id: int = launches[0][0]
	assert_eq(launches[0][1], 0, "thrown by P0")
	assert_eq(mg.ammo_of(0), 0, "hands empty")
	var b := mg.get_ball(id)
	assert_near(b.dir, Vector3.RIGHT, 0.001, "along the facing")
	assert_near(b.origin, SnowArc.release_point(p.global_position, Vector3.RIGHT), 0.05, "from the hand")
	await step(2)
	assert_near(mv.max_speed, base, 0.01, "full speed again")
	await step(10)
	var s := mg.sim_time() - b.t0
	if not b.nodes.is_empty():
		assert_near(b.nodes[0].position, b.position(s), 0.35, "the ball mesh flies the arc")
	assert_true(b.position(s).x > b.origin.x + 2.0, "it flies away (%.2f m)" % (b.position(s).x - b.origin.x))
	# Empty-handed again: the next press scoops instead of throwing.
	assert_true(mg.press(p), "third press")
	assert_eq(scoops.size(), 2, "scoops again")
	assert_eq(launches.size(), 1, "no second ball")


func test_arc_is_deterministic_shallow_and_ends_on_the_ground() -> void:
	var origin := SnowArc.release_point(Vector3(-6.5, 0.0, 2.0), Vector3.RIGHT)
	var a: Array = SnowArc.end_of(origin, Vector3.RIGHT)
	var b: Array = SnowArc.end_of(origin, Vector3.RIGHT)
	assert_eq(a, b, "same launch, same end")
	assert_eq(int(a[1]), SnowArc.End.GROUND, "lands in the open")
	var land := SnowArc.position(origin, Vector3.RIGHT, float(a[0]))
	var reach := land.x - origin.x
	assert_true(reach > 9.5 and reach < 11.5, "about 11 m of range (%.2f m)" % reach)
	assert_near(SnowArc.reach(), reach, 0.1, "reach() agrees")
	var top := 0.0
	var s := 0.0
	while s < float(a[0]):
		top = maxf(top, SnowArc.position(origin, Vector3.RIGHT, s).y)
		s += 0.01
	assert_true(top < SnowYard.WALL_H + SnowArc.RADIUS - 0.2, "shallow: never clears a snow wall (peak %.2f m)" % top)
	assert_near(SnowArc.position(origin, Vector3.RIGHT, 0.5) - origin, Vector3(7.0, SnowArc.LIFT * 0.5 - 0.5 * SnowArc.GRAVITY * 0.25, 0.0), 0.0001, "14 m/s along the ground")
	# Diagonal throws are as long.
	var diag := Vector3(1.0, 0.0, 1.0).normalized()
	var d: Array = SnowArc.end_of(Vector3(-6.0, 0.95, -5.5), diag)
	assert_true(int(d[1]) != SnowArc.End.TIMEOUT, "every ball ends")


func test_cover_blocks_balls() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	var v := players[1]
	# Wall 0 runs along X at (-2.4, -3.4): P0 south of it, P1 north of it.
	_put(p, Vector3(-2.4, 0.0, -5.2), Vector3.BACK)
	_put(v, Vector3(-2.4, 0.0, -1.4), Vector3.FORWARD)
	await step(3)
	assert_false(SnowArc.clear_shot(p.global_position, v.global_position), "the wall is in the way")
	assert_true(SnowArc.clear_shot(Vector3(-6.5, 0.0, 2.0), Vector3(-1.0, 0.0, 2.0)), "the open middle is clear")
	var hits := watch(v, &"got_hit")
	var ends := watch(mg, &"ball_ended")
	await _arm(mg, p)
	assert_true(mg.throw_at(p, Vector3.BACK), "thrown at the wall")
	await step(30)
	assert_eq(hits.size(), 0, "the blob behind the wall is not hit")
	if assert_eq(ends.size(), 1, "the ball ended"):
		assert_eq(ends[0][1], SnowArc.End.COVER, "against cover")
	assert_eq(mg.scores[0], 0, "no points")
	# A snowman blocks too.
	var sm := SnowYard.SNOWMEN[0]
	_put(p, Vector3(sm.x + 2.5, 0.0, sm.y), Vector3.LEFT)
	_put(v, Vector3(sm.x - 1.3, 0.0, sm.y), Vector3.RIGHT)
	await step(3)
	assert_false(SnowArc.clear_shot(p.global_position, v.global_position), "the snowman is in the way")


func test_hit_knocks_back_and_scores_once() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	var v := players[1]
	_put(p, Vector3(-3.0, 0.0, 0.8), Vector3.RIGHT)
	_put(v, Vector3(2.0, 0.0, 0.8), Vector3.LEFT)
	await step(3)
	await _arm(mg, p)
	var got := watch(v, &"got_hit")
	var stuns := watch(v, &"stunned")
	var confirmed := watch(mg, &"hit_confirmed")
	var locals := watch(mg, &"local_hit")
	var counter := [0.0]
	v.got_hit.connect(func(_imp: Vector3, _src: int) -> void: counter[0] = v.velocity.x)
	assert_true(mg.press(p), "thrown (aim assist on P1)")
	assert_true(await _step_until(func() -> bool: return not got.is_empty(), 40), "P1 hit")
	await step(2)
	if assert_eq(got.size(), 1, "hit once"):
		var imp: Vector3 = got[0][0]
		assert_true(Vector2(imp.x, imp.z).length() >= mg.knockback * 0.95, "knockback ~8 m/s (%.1f)" % Vector2(imp.x, imp.z).length())
		assert_true(imp.x > 0.0, "pushed away from the thrower")
		assert_eq(got[0][1], 0, "source P0")
	assert_true(counter[0] > 5.0, "sliding away (%.1f m/s)" % counter[0])
	assert_eq(stuns.size(), 1, "a short stun")
	if not stuns.is_empty():
		assert_true(float(stuns[0][0]) < 0.7, "small stun (%.2f s)" % float(stuns[0][0]))
	assert_eq(locals.size(), 1, "seen locally once")
	assert_eq(confirmed.size(), 1, "the host counted it once")
	assert_eq(mg.scores[0], 1, "+1 for the thrower")
	assert_eq(mg.hits_taken[1], 1, "one hit taken")
	assert_eq(mg.hits_landed[0], 1, "one hit landed")
	assert_true(mg.active_balls().is_empty(), "the ball is gone")
	# The same ball reported again (another peer, a duplicate packet) counts nothing.
	var id: int = confirmed[0][0]
	var ignored := mg.ignored_reports
	mg._host_hit(id, 1, v.global_position, multiplayer.get_unique_id())
	assert_eq(mg.scores[0], 1, "still 1")
	assert_eq(mg.ignored_reports, ignored + 1, "duplicate ignored")


func test_three_hits_snow_you_in_then_release() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	var v := players[1]
	var snowed := watch(mg, &"snowed_in")
	var freed := watch(mg, &"released")
	var confirmed := watch(mg, &"hit_confirmed")
	for k in 3:
		_put(p, Vector3(-3.0, 0.0, 0.8), Vector3.RIGHT)
		_put(v, Vector3(2.0, 0.0, 0.8), Vector3.LEFT)
		await step(2)
		_inject_at(mg, p, v)
		assert_true(await _step_until(func() -> bool: return confirmed.size() == k + 1, 40), "hit %d" % (k + 1))
		if k < 2:
			assert_false(mg.is_snowed(1), "not snowed after %d hits" % (k + 1))
			await step(50)  # stun and immunity over
	var snowed_at := mg.sim_time()
	assert_eq(snowed.size(), 1, "snowed in on the third hit")
	assert_true(mg.is_snowed(1), "is snowed")
	assert_true(v.frozen, "frozen as a snowman")
	assert_eq(mg.hits_taken[1], 0, "counter reset")
	assert_eq(mg.snowed_count[1], 1, "one snow-in")
	assert_eq(mg.ammo_of(1), 0, "no ball while snowed")
	assert_true((mg._shells[1] as Node3D).visible, "the snowman shell shows")
	assert_false(mg.press(v), "cannot act")
	await step(5)
	var spot := v.global_position
	# Snowed blobs cannot be hit.
	var got := watch(v, &"got_hit")
	_put(p, Vector3(spot.x - 4.0, 0.0, spot.z), Vector3.RIGHT)
	await step(2)
	_inject_at(mg, p, v)
	await step(40)
	assert_eq(got.size(), 0, "no hit while snowed in")
	assert_near(Vector2(v.global_position.x, v.global_position.z), Vector2(spot.x, spot.z), 0.05, "stays put")
	assert_true(await _step_until(func() -> bool: return not freed.is_empty(), int(mg.snowed_time * 60.0) + 10), "released")
	assert_near(mg.sim_time() - snowed_at, mg.snowed_time, 0.1, "after 3 s")
	assert_false(v.frozen, "can move again")
	assert_false((mg._shells[1] as Node3D).visible, "shell gone")
	assert_true(mg.is_invulnerable(1), "1 s of invulnerability")
	_put(v, Vector3(2.0, 0.0, 0.8), Vector3.LEFT)
	_put(p, Vector3(-3.0, 0.0, 0.8), Vector3.RIGHT)
	await step(2)
	_inject_at(mg, p, v)
	await step(30)
	assert_eq(got.size(), 0, "invulnerable right after release")
	await step(40)
	assert_false(mg.is_invulnerable(1), "invulnerability over")
	_put(v, Vector3(2.0, 0.0, 0.8), Vector3.LEFT)
	_put(p, Vector3(-3.0, 0.0, 0.8), Vector3.RIGHT)
	await step(2)
	_inject_at(mg, p, v)
	assert_true(await _step_until(func() -> bool: return got.size() == 1, 40), "hittable again")
	await step(2)
	assert_eq(mg.hits_taken[1], 1, "counting from zero")


func test_ammo_pile_gives_three_balls_to_the_first_toucher() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	_put(p, Vector3(3.0, 0.0, 0.0), Vector3.LEFT)
	mg.begin(19.5)
	var piles := watch(mg, &"pile_changed")
	await step(20)
	assert_false(mg.pile_active, "no pile before 20 s")
	assert_true(await _step_until(func() -> bool: return mg.pile_active, 30), "the pile appears at 20 s")
	assert_true(mg._pile.visible, "and shows")
	assert_true(await _step_until(func() -> bool: return mg.ammo_of(0) > 0, 90, func(_i: int) -> void: p.intent.move = Vector2.LEFT), "P0 runs into the pile")
	await step(1, func(_i: int) -> void: p.intent.move = Vector2.ZERO)
	assert_eq(mg.ammo_of(0), mg.pile_balls, "3 balls at once")
	assert_false(mg.pile_active, "taken")
	if assert_eq(piles.size(), 2, "appeared, then taken"):
		assert_eq(piles[1][1], 0, "by P0")
	assert_true(mg.can_throw(0), "ready at once (no scoop)")
	var launches := watch(mg, &"ball_launched")
	for k in 3:
		assert_true(await _step_until(func() -> bool: return mg.can_throw(0), 30), "ready for throw %d" % (k + 1))
		assert_true(mg.throw_at(p, Vector3.BACK), "throw %d" % (k + 1))
	assert_eq(launches.size(), 3, "three balls thrown")
	assert_eq(mg.ammo_of(0), 0, "empty")
	# The second pile comes at 40 s (P0 steps off the spot first).
	_put(p, Vector3(3.0, 0.0, 0.0), Vector3.LEFT)
	await step(2)
	mg.begin(39.9)
	assert_true(await _step_until(func() -> bool: return mg.pile_active, 20), "another pile at 40 s")
	assert_eq(piles.size(), 3, "announced")


func test_blizzard_doubles_points() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	var v := players[1]
	var storms := watch(mg, &"blizzard_started")
	mg.begin(49.8)
	assert_false(mg.is_blizzard(), "no blizzard at 49.8 s")
	await step(20)
	assert_true(mg.is_blizzard(), "blizzard from 50 s")
	assert_eq(storms.size(), 1, "announced once")
	_put(p, Vector3(-3.0, 0.0, 0.8), Vector3.RIGHT)
	_put(v, Vector3(2.0, 0.0, 0.8), Vector3.LEFT)
	await step(2)
	var confirmed := watch(mg, &"hit_confirmed")
	_inject_at(mg, p, v)
	assert_true(await _step_until(func() -> bool: return not confirmed.is_empty(), 40), "hit")
	assert_eq(confirmed[0][3], 2, "worth 2")
	assert_eq(mg.scores[0], 2, "double points")


func test_ranking_and_tie_breaks() -> void:
	var mg: SnowballFight = await _arena(4)
	_fill(mg.scores, [3, 3, 1, 0])
	_fill(mg.snowed_count, [1, 0, 0, 0])
	mg.last_hit_time.clear()
	mg.last_hit_time[0] = 10.0
	mg.last_hit_time[1] = 20.0
	mg.last_hit_time[2] = 5.0
	assert_eq(Minigame.flatten_groups(mg.ranking_groups()), [1, 0, 2, 3] as Array[int], "points, then fewer snow-ins")
	_fill(mg.snowed_count, [0, 0, 0, 0])
	assert_eq(Minigame.flatten_groups(mg.ranking_groups()), [0, 1, 2, 3] as Array[int], "then the earlier last hit")
	_fill(mg.scores, [2, 2, 0, 0])
	mg.last_hit_time.clear()
	mg.last_hit_time[0] = 12.0
	mg.last_hit_time[1] = 12.0
	var groups := mg.ranking_groups()
	assert_eq(groups.size(), 2, "two tied groups")
	assert_eq(groups[0], [0, 1] as Array[int], "equal on everything: shared first")
	assert_eq(groups[1], [2, 3] as Array[int], "no hits at all: shared third")
	mg.end_round()
	assert_true(mg.is_finished(), "finished")
	assert_eq(mg.finish_groups, groups, "finish got the groups")
	assert_near(mg.finish_grace, 2.0, 0.001, "2 s grace")
	assert_eq(ranking, [0, 1, 2, 3] as Array[int], "flat ranking")


func test_round_ends_at_the_limit_with_every_slot_ranked() -> void:
	var mg: SnowballFight = await _arena(3)
	mg.begin(58.5)
	assert_true(await run_until_finished(150), "finished at 60 s")
	assert_true(mg.round_time() >= 60.0 and mg.round_time() < 60.2, "on time (%.2f)" % mg.round_time())
	var sorted := ranking.duplicate()
	sorted.sort()
	assert_eq(sorted, [0, 1, 2] as Array[int], "every slot once")


func test_host_refuses_implausible_throws_and_reports() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	var v := players[1]
	_put(p, Vector3(-3.0, 0.0, 0.8), Vector3.RIGHT)
	_put(v, Vector3(4.0, 0.0, 0.8), Vector3.LEFT)
	await step(3)
	var me := multiplayer.get_unique_id()
	var launches := watch(mg, &"ball_launched")
	mg._host_throw(0, SnowArc.release_point(p.global_position, Vector3.RIGHT), Vector3.RIGHT, me)
	assert_eq(launches.size(), 0, "no ball, no throw")
	await _arm(mg, p)
	mg._host_throw(0, Vector3(6.0, 1.0, 6.0), Vector3.RIGHT, me)  # far from where the host sees P0
	mg._host_throw(0, SnowArc.release_point(p.global_position, Vector3.RIGHT), Vector3.RIGHT, me + 5)  # not P0's peer
	mg._host_throw(0, SnowArc.release_point(p.global_position, Vector3.RIGHT), Vector3.UP, me)  # no direction
	assert_eq(launches.size(), 0, "all refused")
	assert_eq(mg.rejected_reports, 3, "three refused")
	var id := _inject_at(mg, p, v)
	await step(8)
	var b := mg.get_ball(id)
	var s := mg.sim_time() - b.t0
	var ball := b.position(s)
	var rejected := mg.rejected_reports
	mg._host_hit(id, 1, Vector3(ball.x, 0.0, ball.z + 3.0), me)  # off the path
	mg._host_hit(id, 1, Vector3(ball.x + 4.0, 0.0, ball.z), me)  # where the ball will be later
	mg._host_hit(99999, 1, v.global_position, me)  # no such ball
	mg._host_hit(id, 0, p.global_position, me)  # the thrower
	mg._host_hit(id, 1, Vector3(ball.x, 0.0, ball.z), me + 5)  # not P1's peer
	mg._host_hit(id, 1, Vector3(ball.x, 0.0, ball.z), me)  # on the path, but the host sees P1 4+ m away
	assert_eq(mg.rejected_reports, rejected + 6, "six refused")
	assert_eq(mg.scores[0], 0, "nothing scored")


func test_aim_assist_snaps_within_12_degrees() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	var v := players[1]
	_put(p, Vector3(-4.0, 0.0, 0.8), Vector3.RIGHT)
	_put(v, Vector3(2.0, 0.0, 0.8 + 6.0 * tan(deg_to_rad(9.0))), Vector3.LEFT)
	await step(2)
	var dir := mg.aim_assist(p, Vector3.RIGHT)
	assert_near(dir, SnowArc.flat_dir(v.global_position - p.global_position), 0.001, "9 degrees off: aimed at P1")
	_put(v, Vector3(2.0, 0.0, 0.8 + 6.0 * tan(deg_to_rad(18.0))), Vector3.LEFT)
	await step(2)
	assert_near(mg.aim_assist(p, Vector3.RIGHT), Vector3.RIGHT, 0.001, "18 degrees off: straight ahead")


func test_bot_hooks() -> void:
	var mg: SnowballFight = await _arena(2)
	assert_false(mg.is_safe(Vector3(SnowYard.WALLS[0].x, 0.0, SnowYard.WALLS[0].y)), "a wall is unsafe ground")
	assert_false(mg.is_safe(Vector3(9.9, 0.0, 0.0)), "the yard edge is unsafe")
	assert_true(mg.is_safe(Vector3(0.0, 0.0, 1.5)), "open snow is safe")
	var goal := mg.get_bot_goal(players[1])
	assert_true(mg.is_safe(goal), "a bot goal is walkable (%s)" % goal)
	assert_near(mg.bot_aggression_scale, 0.0, 0.001, "bots never shove")


# --- Carry pose and leavers (review fixes) ------------------------------------------------------

## Holding a ball shows the overhead carry pose (a valid VisualsComponent kind) with the ball on
## the raised hands; a throw that leaves balls in hand keeps it; empty hands and the round end
## put the hands down.
func test_carry_pose_while_holding_a_ball() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	_put(p, Vector3(-3.0, 0.0, 0.0), Vector3.RIGHT)
	await step(3)
	var vis := p.get_component(&"visuals") as VisualsComponent
	assert_eq(vis.get_carry_pose(), &"none", "empty hands: no carry pose")
	await _arm(mg, p)
	await step(2)
	assert_eq(vis.get_carry_pose(), &"overhead", "holding a ball: overhead")
	var c: Node3D = mg._carry.get(0)
	if assert_true(c != null and c.visible, "the carried ball shows"):
		assert_near(c.global_position, vis.get_carry_point(), 0.01, "on the raised hands")
	assert_true(mg.press(p), "throw")
	await step(2)
	assert_eq(vis.get_carry_pose(), &"none", "thrown, hands empty: pose off")
	# Three balls from the pile: the pose comes back after a throw while balls are left.
	mg._rpc_pile_taken(0, 3)
	await step(2)
	assert_eq(vis.get_carry_pose(), &"overhead", "pile balls: overhead")
	await step(20)
	assert_true(mg.press(p), "throw one of three")
	await step(2)
	assert_eq(mg.ammo_of(0), 2, "two left")
	assert_eq(vis.get_carry_pose(), &"overhead", "still carrying after the throw")
	mg.end_round()
	await step(2)
	assert_eq(vis.get_carry_pose(), &"none", "round over: hands down")
	assert_false(c.visible, "carried balls hidden at the end")


## Leaving the tree mid-round (stage cleared) takes the carry pose off too.
func test_carry_pose_cleared_when_the_minigame_leaves() -> void:
	var mg: SnowballFight = await _arena(2)
	var p := players[0]
	_put(p, Vector3(-3.0, 0.0, 0.0), Vector3.RIGHT)
	await step(3)
	await _arm(mg, p)
	await step(2)
	var vis := p.get_component(&"visuals") as VisualsComponent
	assert_eq(vis.get_carry_pose(), &"overhead", "carrying")
	stage.minigame = null
	stage.remove_child(mg)
	assert_eq(vis.get_carry_pose(), &"none", "pose cleared when the minigame leaves")
	mg.queue_free()


## A leaver that leaves one player ends the round through end_round: points ranking with the
## leaver last, the end grace and the end RPC (every peer stops), not the base's flat finish.
func test_leavers_end_the_round_through_end_round() -> void:
	var mg: SnowballFight = await _arena(3)
	mg.scores[2] = 3
	Net.remove_bot(1)
	await step(2)
	assert_false(mg.is_finished(), "two left: the round goes on")
	assert_eq(mg.knocked_out, [1] as Array[int], "leaver recorded")
	Net.remove_bot(2)
	await step(2)
	assert_true(mg.is_finished(), "one left: over")
	assert_eq(mg.finish_groups, [[0], [2], [1]], "the one who stayed, then the leavers, last out first")
	assert_near(mg.finish_grace, mg.end_grace, 0.001, "with the end grace")
	assert_false(mg.is_running(), "the end RPC ran")
