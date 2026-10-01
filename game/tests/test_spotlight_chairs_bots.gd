extends GameTest
## Spotlight Chairs bot-only rounds: every slot (slot 0 too, via its own BotBrain) is a bot.
## Each round must finish inside the time limit with one survivor and a valid ranking; the
## lengths are printed so the pacing can be judged. Plus a slot-bias check over 12 seeded
## 4-bot rounds (time scale 2: music, warning and pause run twice as fast).

const ID := &"spotlight_chairs"


## Runs one bot-only round; returns [round length in s, winner slot, checks, nobody-sat checks].
func _bot_round(count: int, seed_value: int, scale: float, quiet: bool = false) -> Array:
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as SpotlightChairs
	mg.rng.seed = seed_value
	mg.bot_rng.seed = seed_value * 31 + 7
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
	var checks := watch(mg, &"checked")
	var frames := 0
	var limit := int((mg.time_limit + 2.0) / physics_delta())
	while not mg.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void: brain0.fill_intent(ps[0].intent, physics_delta()))
		frames += 1
	brain0.queue_free()
	var seconds := frames * physics_delta()
	if not assert_true(mg.is_finished(), "%d bots, seed %d: round finished" % [count, seed_value]):
		return [seconds, -1, checks.size(), 0]
	var sorted := ranking.duplicate()
	sorted.sort()
	var all: Array[int] = []
	for i in count:
		all.append(i)
	assert_eq(sorted, all, "every slot exactly once")
	var alive := ps.filter(func(p: Player) -> bool: return p.alive)
	assert_eq(alive.size(), 1, "one survivor")
	assert_true(seconds < mg.time_limit, "inside the time limit (%.1f s)" % seconds)
	var empty := 0
	var outs: Array[int] = []
	for c: Array in checks:
		if (c[2] as Array).is_empty():
			empty += 1
		outs.append((c[2] as Array).size())
	if not quiet:
		print("  chairs bots=%d seed=%d scale=%.1f: %.1f s, ranking %s, %d checks, outs per check %s" % [
			count, seed_value, scale, seconds, ranking, checks.size(), outs])
	return [seconds, ranking[0], checks.size(), empty]


func test_4_bots_seed_1() -> void:
	await _bot_round(4, 1, 1.0)


func test_4_bots_seed_2() -> void:
	await _bot_round(4, 2, 1.0)


func test_8_bots_seed_1() -> void:
	var r := await _bot_round(8, 1, 1.0)
	assert_true(float(r[0]) < 85.0, "8 bots finish with room to spare (%.1f s)" % float(r[0]))


func test_8_bots_seed_2_time_scale() -> void:
	await _bot_round(8, 2, 2.0)


func test_no_slot_bias_over_12_rounds() -> void:
	var wins: Array[int] = [0, 0, 0, 0]
	var total := 0.0
	for k in 12:
		var r := await _bot_round(4, 100 + k, 2.0, true)
		if int(r[1]) >= 0:
			wins[int(r[1])] += 1
		total += float(r[0])
		_teardown_round()
	print("  chairs 12 x 4 bots (scale 2): wins per slot %s, mean %.1f s" % [wins, total / 12.0])
	for s in 4:
		assert_true(wins[s] <= 6, "slot %d won %d of 12" % [s, wins[s]])


## Clears the arena between rounds inside one test (the harness tears down only at the end).
func _teardown_round() -> void:
	if stage:
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
	players.clear()
	ranking = []
	Net.leave()
