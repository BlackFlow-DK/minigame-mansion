extends GameTest
## Coin Scramble: the rules, driven through the Player API and the minigame's own
## (RPC-carried) state and signals. Offline, the host's `call_local` RPCs run in place, so
## `coins_changed` / `coin_collected` firing here is the RPC firing.

const ID := &"coin_scramble"
const CoinScramble := preload("res://minigames/coin_scramble/coin_scramble.gd")
const CoinPiece := preload("res://minigames/coin_scramble/coin_piece.gd")


## Offline arena with `count` scripted players and no rain (tests place coins themselves).
func _arena(count: int = 2) -> CoinScramble:
	spawn_arena(count, ID)
	var mg := get_minigame() as CoinScramble
	mg.rain_enabled = false
	mg._rng.seed = 12345  # drop scatter is deterministic in tests
	return mg


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func test_scene_loads_with_8_spawns() -> void:
	var ps := spawn_arena(8, ID)
	var mg := get_minigame() as CoinScramble
	if not assert_true(mg != null, "coin_scramble loads with its own script"):
		return
	assert_eq(ps.size(), 8, "8 players spawned")
	var points := mg.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn markers")
	assert_near(mg.time_limit, 45.0, 0.001, "45 s round")
	for t in points:
		assert_true(mg.is_safe(t.origin), "spawn %s is inside the vault, off the hazards" % t.origin)
	await step(30)
	for p in ps:
		assert_true(p.global_position.y > -0.1 and p.global_position.y < 0.3, "P%d stands on the floor (y=%.2f)" % [p.slot, p.global_position.y])
	assert_false(mg.is_safe(Vector3(9.6, 0.0, 0.0)), "the wall zone is unsafe")


func test_walking_onto_a_coin_collects_it_exactly_once() -> void:
	var mg := _arena(2)
	var p := players[0]
	_put(p, Vector3(-6.0, 0.0, 2.0))
	_put(players[1], Vector3(6.0, 0.0, -2.0))
	var counters := watch(mg, &"coins_changed")
	var collected := watch(mg, &"coin_collected")
	var id := mg.spawn_rain_coin(Vector3(-6.0, 0.0, -1.0), 1, 1.0)
	await step(20)
	var coin := mg.get_coin(id) as CoinPiece
	if not assert_true(coin != null, "the coin is on the floor"):
		return
	assert_true(coin.has_landed(), "it landed")
	assert_eq(collected.size(), 0, "not collected from 3 m away")
	# Walk along -Z over the coin, then back over the same spot.
	await step(45, func(_i: int) -> void: p.intent.move = Vector2(0.0, -1.0))
	await step(45, func(_i: int) -> void: p.intent.move = Vector2(0.0, 1.0))
	await step(10, func(_i: int) -> void: p.intent.move = Vector2.ZERO)
	assert_eq(collected.size(), 1, "collected exactly once")
	if collected.size() > 0:
		assert_eq(collected[0], [id, 0], "by player 0")
	assert_eq(mg.coins[0], 1, "count")
	assert_eq(mg.coins[1], 0, "the other player got nothing")
	assert_true(mg.get_coin(id) == null, "the coin is gone")
	assert_true(counters.size() > 0 and counters.back() == [0, 1], "the counter RPC reported slot 0 -> 1: %s" % str(counters))


func test_big_coin_is_worth_five() -> void:
	var mg := _arena(2)
	_put(players[0], Vector3(-6.0, 0.0, 2.0))
	_put(players[1], Vector3(6.0, 0.0, -2.0))
	mg.spawn_rain_coin(Vector3(-6.0, 0.0, 2.0), 5, 1.0)
	await step(20)
	assert_eq(mg.coins[0], 5, "a big coin is worth 5")


func test_hit_drops_coins_that_become_collectable_after_the_delay() -> void:
	var mg := _arena(3)
	var victim := players[0]
	var other := players[1]
	_put(victim, Vector3(-6.5, 0.0, -1.0))  # drops land clear of bar, bumpers and chests
	_put(other, Vector3(6.0, 0.0, -2.0))
	_put(players[2], Vector3(0.0, 0.0, 7.5))
	for i in 4:
		mg.spawn_rain_coin(victim.global_position, 1, 0.6)
	await step(15)
	assert_eq(mg.coins[0], 4, "victim holds 4")
	assert_eq(mg.coin_ids().size(), 0, "floor is empty")
	# A shove-type hit (a source player): up to 3 coins drop.
	victim.apply_impulse(Vector3(0.5, 0.0, 0.0), other)
	await step(1)
	assert_eq(mg.coins[0], 1, "lost 3")
	var dropped := mg.coin_ids()
	if not assert_eq(dropped.size(), 3, "3 coins scattered"):
		return
	for id in dropped:
		var c := mg.get_coin(id) as CoinPiece
		assert_true(_flat(c.land).distance_to(_flat(victim.global_position)) > 1.0, "coin %d lands away from the victim" % id)
		assert_true(_flat(c.land).length() <= CoinScramble.RAIN_RADIUS + 0.01, "coin %d lands inside the vault" % id)
	var mine := mg.get_coin(dropped[0]) as CoinPiece
	var theirs := mg.get_coin(dropped[1]) as CoinPiece
	# The victim parks on one of them, the other player on another.
	await step(2)
	_put(victim, _flat(mine.land))
	_put(other, _flat(theirs.land))
	await step(20)  # ~0.37 s: still in the air
	assert_true(mg.get_coin(dropped[1]) != null, "nobody grabs a coin mid-hop")
	await step(15)  # ~0.62 s: landed; the other player may grab, the victim may not
	assert_true(mg.get_coin(dropped[1]) == null, "the other player grabbed a dropped coin after the short delay")
	assert_eq(mg.coins[1], 1, "other player's count")
	assert_true(mg.get_coin(dropped[0]) != null, "the victim cannot instantly regrab")
	assert_eq(mg.coins[0], 1, "victim count unchanged during the delay")
	await step(60)  # past victim_delay (1.5 s)
	assert_true(mg.get_coin(dropped[0]) == null, "after the delay the victim can collect it")
	assert_eq(mg.coins[0], 2, "victim count after regrab")


func test_count_never_goes_negative_and_bumpers_do_not_rob() -> void:
	var mg := _arena(2)
	var victim := players[0]
	_put(victim, Vector3(-6.0, 0.0, 2.0))
	_put(players[1], Vector3(6.0, 0.0, -2.0))
	var counts := watch(mg, &"coins_changed")
	mg.spawn_rain_coin(victim.global_position, 1, 0.6)
	await step(15)
	assert_eq(mg.coins[0], 1, "victim holds 1")
	# A weak sourceless hit (a bumper) drops nothing.
	victim.apply_impulse(Vector3(-8.5, 3.0, 0.0))
	await step(30)
	assert_eq(mg.coins[0], 1, "a bumper bounce drops nothing")
	# A big sourceless hit (the spinner) drops up to 5: here only 1.
	victim.apply_impulse(Vector3(-11.5, 6.0, 0.0))
	await step(2)
	assert_eq(mg.coins[0], 0, "dropped the only coin")
	assert_eq(mg.coin_ids().size(), 1, "exactly one coin scattered")
	await step(30)
	victim.apply_impulse(Vector3(-11.5, 6.0, 0.0))
	await step(2)
	victim.apply_impulse(Vector3(-0.5, 0.0, 0.0), players[1])
	await step(30)
	assert_eq(mg.coins[0], 0, "still 0, never negative")
	assert_true(mg.coin_ids().size() <= 1, "no coins made out of nothing")
	for e: Array in counts:
		assert_true(int(e[1]) >= 0, "counter never negative: %s" % str(e))


func test_no_second_drop_during_the_drop_cooldown() -> void:
	var mg := _arena(2)
	var victim := players[0]
	_put(victim, Vector3(-6.0, 0.0, 2.0))
	_put(players[1], Vector3(6.0, 0.0, -2.0))
	for i in 6:
		mg.spawn_rain_coin(victim.global_position, 1, 0.6)
	await step(15)
	assert_eq(mg.coins[0], 6, "victim holds 6")
	victim.apply_impulse(Vector3(-0.5, 0.0, 0.0), players[1])
	await step(20)
	assert_eq(mg.coins[0], 3, "first shove drops 3")
	victim.apply_impulse(Vector3(-0.5, 0.0, 0.0), players[1])
	await step(2)
	assert_eq(mg.coins[0], 3, "a shove right after drops nothing")
	await step(int(mg.drop_cooldown * 60.0))
	var stand := victim.global_position
	victim.apply_impulse(Vector3(-0.5, 0.0, 0.0), players[1])
	await step(2)
	assert_eq(mg.coins[0], 0, "after the cooldown the next shove drops again (at %s)" % stand)


func test_spinner_angle_is_deterministic() -> void:
	var start := CoinScramble.spinner_angle(0.0, 1.0, 1.0)
	var times: Array[float] = [0.0, 0.5, 1.0, 7.3, 14.5, 26.7, 30.0, 44.9, 60.0]
	for t in times:
		var a := CoinScramble.spinner_angle(t, 1.0, 1.03)
		assert_eq(a, CoinScramble.spinner_angle(t, 1.0, 1.03), "same input, same angle at %.1f" % t)
		assert_near(CoinScramble.spinner_angle(t, -1.0, 1.03) - start, -(a - start), 0.0001, "dir mirrors at %.1f" % t)
		if t > 0.0:
			var h := 0.001
			var num := (CoinScramble.spinner_angle(t + h, 1.0, 1.03) - CoinScramble.spinner_angle(t - h, 1.0, 1.03)) / (2.0 * h)
			assert_near(num, CoinScramble.spinner_rate(t, 1.0, 1.03), 0.01, "angle is the integral of rate at %.1f" % t)
	# Profile: after the ramp-up its plateaus speed up twice and reverse once.
	var plateaus: Array[float] = []
	var prev := CoinScramble.spinner_rate(1.0)
	var t2 := 1.25
	while t2 <= 45.0:
		var r := CoinScramble.spinner_rate(t2)
		if absf(r - prev) < 0.000001 and (plateaus.is_empty() or absf(plateaus.back() - r) > 0.000001):
			plateaus.append(r)
		prev = r
		t2 += 0.25
	var reversals := 0
	var speedups := 0
	for k in range(1, plateaus.size()):
		if signf(plateaus[k]) != signf(plateaus[k - 1]):
			reversals += 1
		if absf(plateaus[k]) > absf(plateaus[k - 1]) + 0.1:
			speedups += 1
	assert_eq(reversals, 1, "reverses once")
	assert_eq(speedups, 2, "speeds up twice")
	# The live bar follows the function of the round clock.
	var mg := _arena(2)
	await step(90)
	var bar := mg.get_node(^"Spinner/Bar") as Node3D
	var expected := CoinScramble.spinner_angle(mg.round_time(), mg._dir, mg._speed)
	assert_near(Vector2(bar.basis.x.x, bar.basis.x.z), Vector2(cos(expected), -sin(expected)), 0.001, "bar turned to spinner_angle(round_time)")


func test_bar_hits_a_standing_player_but_not_a_jumping_one() -> void:
	var mg := _arena(2)
	var p := players[1]
	_put(players[0], Vector3(-7.0, 0.0, 2.0))
	var hits := watch(p, &"got_hit")
	var off_bar := func() -> Vector3:
		var a := CoinScramble.spinner_angle(mg.round_time(), mg._dir, mg._speed) + PI * 0.5
		return Vector3(cos(a), 0.0, -sin(a)) * 2.2
	var on_bar := func() -> Vector3:
		var a := CoinScramble.spinner_angle(mg.round_time(), mg._dir, mg._speed)
		return Vector3(cos(a), 0.0, -sin(a)) * 2.2
	_put(p, off_bar.call())
	await step(5)
	assert_eq(hits.size(), 0, "not hit off the bar")
	# Jump, and while the feet are above the bar keep the blob right over it.
	var over_frames := [0]
	await step(50, func(i: int) -> void:
		p.intent.jump_pressed = i == 0
		p.intent.jump_held = true
		var pos := p.global_position
		if pos.y > CoinScramble.BAR_TOP + 0.08:
			var q: Vector3 = on_bar.call()
			p.global_position = Vector3(q.x, pos.y, q.z)
			over_frames[0] += 1
		else:
			var q: Vector3 = off_bar.call()
			p.global_position = Vector3(q.x, pos.y, q.z))
	assert_true(over_frames[0] >= 10, "spent %d frames right over the bar" % over_frames[0])
	assert_eq(hits.size(), 0, "a jumping player clears the bar")
	# Standing on the bar's path: swept.
	await step(10, func(_i: int) -> void: p.intent.clear())
	_put(p, on_bar.call())
	await step(2)
	if assert_eq(hits.size(), 1, "a standing player is hit once"):
		var impulse: Vector3 = hits[0][0]
		assert_true(impulse.length() >= mg.big_hit_impulse, "a big hit (%.1f)" % impulse.length())
		assert_eq(hits[0][1], -1, "no source player")
	assert_true(Vector2(p.velocity.x, p.velocity.z).length() > 5.0, "swept away")


func test_ranking_by_coins_with_tie_break() -> void:
	var slots: Array[int] = [0, 1, 2, 3]
	assert_eq(CoinScramble.rank_by_coins(slots, {0: 3, 1: 5, 2: 3, 3: 0}, {0: 4.0, 1: 1.0, 2: 2.0, 3: 0.0}), [1, 2, 0, 3] as Array[int], "coins, then who reached it first")
	assert_eq(CoinScramble.rank_by_coins(slots, {0: 2, 1: 2, 2: 2, 3: 2}, {0: 1.0, 1: 1.0, 2: 1.0, 3: 1.0}), [0, 1, 2, 3] as Array[int], "full tie: by slot")
	# Live: slot 2 reaches 1 coin before slot 0 does; slot 1 gets none.
	var mg := _arena(3)
	_put(players[0], Vector3(-6.0, 0.0, 2.0))
	_put(players[1], Vector3(6.0, 0.0, -2.0))
	_put(players[2], Vector3(0.0, 0.0, 7.0))
	mg.spawn_rain_coin(players[2].global_position, 1, 0.6)
	await step(30)
	mg.spawn_rain_coin(players[0].global_position, 1, 0.6)
	await step(30)
	var over := watch(mg, &"round_over")
	mg.time_limit = mg.round_time() + 0.25
	assert_true(await run_until_finished(120), "finishes at the time limit")
	assert_eq(ranking, [2, 0, 1] as Array[int], "tie broken by who reached 1 first")
	assert_eq(mg.final_ranking, ranking, "every peer's final ranking")
	assert_eq(over.size(), 1, "round_over once")


func test_bot_round_4() -> void:
	await _bot_round(4, 11)


func test_bot_round_8() -> void:
	await _bot_round(8, 23)


## A whole round with bots only (slot 0's human controller is replaced by a BotBrain driven
## here) at a test-only time scale. Checks the ranking and prints the scores.
func _bot_round(count: int, seed_value: int) -> void:
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as CoinScramble
	mg.time_scale = 1.5
	var c0 := ps[0].get_component(&"controller") as ControllerComponent
	c0.scripted = true
	var brain := BotBrain.new()
	brain.player = ps[0]
	brain.minigame = mg
	add_child(brain)
	brain.configure(seed_value)
	var hits := {"shove": 0, "bar": 0, "bumper": 0}
	for p in ps:
		p.got_hit.connect(func(imp: Vector3, src: int) -> void:
			var k := "shove" if src >= 0 else ("bar" if imp.length() >= mg.big_hit_impulse else "bumper")
			hits[k] += 1)
	var collected := watch(mg, &"coin_collected")
	var dropped := [0]
	var last := {}
	mg.coins_changed.connect(func(s: int, c: int) -> void:
		if c < int(last.get(s, 0)):
			dropped[0] += int(last.get(s, 0)) - c
		last[s] = c)
	var bar_jumps := {}
	var max_coins := 0
	for i in 60 * 50:
		if mg.is_finished():
			break
		await step(1, func(_f: int) -> void: brain.fill_intent(ps[0].intent, physics_delta()))
		max_coins = maxi(max_coins, mg.coin_ids().size())
		var a := CoinScramble.spinner_angle(mg.round_time(), mg._dir, mg._speed)
		for p in ps:
			var feet := p.global_position
			if feet.y > CoinScramble.BAR_TOP and CoinScramble.bar_overlaps(a, Vector3(feet.x, 0.0, feet.z), 0.3):
				bar_jumps[p.slot] = true
	if not assert_true(mg.is_finished(), "the round finished"):
		return
	var sorted := ranking.duplicate()
	sorted.sort()
	var all: Array[int] = []
	for p in ps:
		all.append(p.slot)
	assert_eq(sorted, all, "every slot ranked exactly once")
	var scores: Array[int] = []
	var total := 0
	for s in ranking:
		scores.append(mg.coins[s])
		total += mg.coins[s]
	for k in range(1, scores.size()):
		assert_true(scores[k] <= scores[k - 1], "ranking follows coins %s" % str(scores))
	assert_true(total >= count * 2, "coins were collected (total %d)" % total)
	assert_true(scores[0] > scores[scores.size() - 1], "a spread of scores %s" % str(scores))
	assert_true(max_coins <= mg.coin_cap + 20, "floor coin count stays near the cap (max %d)" % max_coins)
	print("  coin_scramble bots x%d: ranking %s scores %s, total %d, pickups %d, dropped %d, hits %s, bots over the bar %d, max floor coins %d" % [
		count, str(ranking), str(scores), total, collected.size(), dropped[0], str(hits), bar_jumps.size(), max_coins])
