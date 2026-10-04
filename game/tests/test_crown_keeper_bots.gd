extends GameTest
## Crown Keeper bot-only rounds: every slot (slot 0 too) is driven by a BotBrain. Checks the
## round ends with a valid ranking and that the crown really changes hands (no bot keeps it
## all round), and that no spawn slot is favoured. Prints the numbers per round.

const ID := &"crown_keeper"


## Plays one bot-only round. Returns {ranking, scores, changes, knocks, returns, top_share}.
func _bot_round(count: int, seed_value: int, scale: float) -> Dictionary:
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as CrownKeeper
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
	var knocks := watch(mg, &"crown_knocked")
	var returns := watch(mg, &"crown_returned")
	var wearers := {}
	mg.crown_taken.connect(func(s: int, _t: bool) -> void: wearers[s] = true)
	var frames := 0
	var limit := int(mg.time_limit / scale * 60.0) + 120
	while not mg.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void: brain0.fill_intent(ps[0].intent, physics_delta()))
		frames += 1
	brain0.queue_free()
	assert_true(mg.is_finished(), "%d bots, seed %d: round finished" % [count, seed_value])
	assert_eq(ranking.size(), count, "ranking has every slot")
	var sorted := ranking.duplicate()
	sorted.sort()
	var all: Array[int] = []
	for i in count:
		all.append(i)
	assert_eq(sorted, all, "every slot exactly once")
	var total := 0
	var top := 0
	for s in mg.scores:
		total += mg.scores[s]
		top = maxi(top, mg.scores[s])
	for i in range(ranking.size() - 1):
		assert_true(mg.scores[ranking[i]] >= mg.scores[ranking[i + 1]], "ranking follows the points")
	var share := float(top) / maxf(total, 1.0)
	var score_list: Array = []
	for s in ranking:
		score_list.append("%d:%d" % [s, mg.scores[s]])
	print("  crown_keeper bots=%d seed=%d scale=%.1f: %d pickups, %d knock-offs, %d returns, %d wearers, %d pts total, top share %.2f, ranking %s" % [
		count, seed_value, scale, mg.crown_changes, knocks.size(), returns.size(), wearers.size(), total, share, " ".join(score_list)])
	return {"ranking": ranking.duplicate(), "scores": mg.scores.duplicate(), "changes": mg.crown_changes,
		"knocks": knocks.size(), "wearers": wearers.size(), "total": total, "top_share": share}


## A healthy round: the crown keeps moving and several bots get to wear it.
func _check_healthy(r: Dictionary, count: int, scale: float) -> void:
	var min_changes := int(10.0 / scale) if count >= 8 else int(8.0 / scale)
	assert_true(int(r.changes) >= min_changes, "crown changed hands %d times (want >= %d)" % [r.changes, min_changes])
	assert_true(int(r.wearers) >= mini(3, count), "%d different wearers" % r.wearers)
	assert_true(float(r.top_share) < 0.7, "top score share %.2f (no bot hogs the crown)" % r.top_share)
	assert_true(int(r.total) >= int(40.0), "the crown was worn most of the round (%d points)" % r.total)


func test_bots_4_real_time() -> void:
	var r := await _bot_round(4, 1, 1.0)
	_check_healthy(r, 4, 1.0)


func test_bots_8_real_time() -> void:
	var r := await _bot_round(8, 2, 1.0)
	_check_healthy(r, 8, 1.0)


func test_bots_4_seed_3() -> void:
	var r := await _bot_round(4, 3, 1.0)
	_check_healthy(r, 4, 1.0)


func test_bots_8_seed_4() -> void:
	var r := await _bot_round(8, 4, 1.0)
	_check_healthy(r, 8, 1.0)


## 12 seeded 4-bot rounds at double clock speed, in three batches (each test has its own
## time limit): no spawn slot wins or scores much more than the others (each slot gets a
## fresh bot personality every round). The last batch checks the totals.
static var _bias_wins: Array[int] = [0, 0, 0, 0]
static var _bias_points: Array[int] = [0, 0, 0, 0]
static var _bias_rounds: int = 0
static var _bias_changes: int = 0


func _bias_batch(seeds: Array[int]) -> void:
	for seed_value in seeds:
		var r := await _bot_round(4, seed_value, 2.0)
		var rk: Array = r.ranking
		if rk.is_empty():
			return
		_bias_wins[rk[0]] += 1
		var sc: Dictionary = r.scores
		for s in 4:
			_bias_points[s] += int(sc.get(s, 0))
		_bias_changes += int(r.changes)
		_bias_rounds += 1
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
		players.clear()
		ranking.clear()
		Net.leave()
		await step(2)


func test_slot_bias_rounds_1_to_4() -> void:
	await _bias_batch([100, 101, 102, 103])


func test_slot_bias_rounds_5_to_8() -> void:
	await _bias_batch([104, 105, 106, 107])


func test_slot_bias_rounds_9_to_12() -> void:
	await _bias_batch([108, 109, 110, 111])
	if _bias_rounds < 12:
		return  # run alone (filtered): the totals need all three batches
	var grand := 0
	for s in 4:
		grand += _bias_points[s]
	var shares: Array[String] = []
	for s in 4:
		shares.append("%.2f" % (float(_bias_points[s]) / maxf(grand, 1.0)))
	print("  crown_keeper slot bias (%d rounds): wins %s, point shares %s, mean pickups %.1f" % [
		_bias_rounds, _bias_wins, shares, _bias_changes / float(_bias_rounds)])
	for s in 4:
		assert_true(_bias_wins[s] <= 6, "slot %d won %d of 12" % [s, _bias_wins[s]])
		var share := float(_bias_points[s]) / maxf(grand, 1.0)
		assert_true(share > 0.1 and share < 0.42, "slot %d took %.2f of all points" % [s, share])
