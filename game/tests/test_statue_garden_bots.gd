extends GameTest
## Statue Garden bot-only rounds: every slot (slot 0 too, via its own BotBrain) is a bot.
## Each round must end with a valid ranking (every slot once) in 30-70 s with some catches
## (bots have imperfect reflexes); the numbers are printed so the pacing can be judged. Plus a
## slot-bias check over 12 seeded 4-bot rounds at time scale 2 (the phase clock runs twice as
## fast, the walking does not), and a check that stopped bots really stand still.

const ID := &"statue_garden"


## Runs one bot-only round; returns [seconds, winner slot (-1 time-up), catches, ranking].
func _bot_round(count: int, seed_value: int, scale: float, quiet: bool = false) -> Array:
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as StatueGarden
	mg.rng.seed = seed_value
	mg.bot_rng.seed = seed_value * 31 + 7
	mg.time_scale = scale
	mg.shuffle_lanes()
	# _start rolled the reflexes from the unseeded rng: roll them again from the seed.
	for p in ps:
		mg._bot_reflex[p.slot] = mg.bot_rng.randf()
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
	var catches := watch(mg, &"caught")
	var wins := watch(mg, &"won")
	var frames := 0
	var limit := int((mg.time_limit + 2.0) / physics_delta())
	while not mg.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void: brain0.fill_intent(ps[0].intent, physics_delta()))
		frames += 1
	brain0.queue_free()
	var seconds := frames * physics_delta()
	var winner: int = wins[0][0] if wins.size() == 1 else -2
	if not assert_true(mg.is_finished(), "%d bots, seed %d: round finished" % [count, seed_value]):
		return [seconds, -2, catches.size(), []]
	var sorted := ranking.duplicate()
	sorted.sort()
	var all: Array[int] = []
	for i in count:
		all.append(i)
	assert_eq(sorted, all, "every slot exactly once")
	if winner >= 0:
		assert_eq(ranking[0], winner, "the winner ranks first")
	var per_slot: Array[int] = []
	for i in count:
		per_slot.append(int(mg.catches.get(i, 0)))
	if not quiet:
		print("  statue bots=%d seed=%d scale=%.1f: %.1f s, winner %d, ranking %s, %d catches %s, %d phases" % [
			count, seed_value, scale, seconds, winner, ranking, catches.size(), per_slot, mg.phase_index + 1])
	return [seconds, winner, catches.size(), ranking.duplicate()]


func _check_pacing(r: Array) -> void:
	var seconds: float = r[0]
	assert_true(seconds >= 30.0 and seconds <= 70.0, "round length %.1f s in 30-70 s" % seconds)
	assert_true(int(r[1]) >= 0, "somebody reached the statue")
	assert_true(int(r[2]) >= 1, "some catches (%d)" % int(r[2]))


func test_4_bots_seed_1() -> void:
	_check_pacing(await _bot_round(4, 1, 1.0))


func test_4_bots_seed_2() -> void:
	_check_pacing(await _bot_round(4, 2, 1.0))


func test_8_bots_seed_1() -> void:
	_check_pacing(await _bot_round(8, 1, 1.0))


func test_8_bots_seed_2() -> void:
	_check_pacing(await _bot_round(8, 2, 1.0))


func test_no_slot_bias_over_12_rounds() -> void:
	var wins: Array[int] = [0, 0, 0, 0]
	var total := 0.0
	var timeouts := 0
	for k in 12:
		var r := await _bot_round(4, 100 + k, 2.0, true)
		if int(r[1]) >= 0:
			wins[int(r[1])] += 1
		else:
			timeouts += 1
		total += float(r[0])
		_teardown_round()
	print("  statue 12 x 4 bots (scale 2): wins per slot %s, %d time-ups, mean %.1f s" % [wins, timeouts, total / 12.0])
	for s in 4:
		assert_true(wins[s] <= 6, "slot %d won %d of 12" % [s, wins[s]])


## A bot whose stop has fired keeps still through RED (no fidgeting, wandering or shoving),
## unless something knocks it.
func test_stopped_bots_stand_still() -> void:
	var ps := spawn_arena(8, ID, false)
	var mg := get_minigame() as StatueGarden
	mg.rng.seed = 9
	for p in ps:
		var c := p.get_component(&"controller") as ControllerComponent
		if c.brain:
			(c.brain as BotBrain).configure(900 + p.slot)
	var reds := 0
	var drifted: Array[String] = []
	var watched := 0
	while reds < 4 and not mg.is_finished():
		await step(1)
		if mg.phase != StatueGarden.Phase.RED:
			continue
		reds += 1
		var start: Dictionary[int, Vector3] = {}
		# From 1.4 s into RED (every bot's stop has fired and settled) to its end.
		await step(int(1.4 / physics_delta()))
		var caught := watch(mg, &"caught")
		for p in ps:
			if p.slot != 0 and mg._bot_stopped.get(p.slot, false):
				start[p.slot] = p.global_position
		var idx := mg.phase_index
		while mg.phase == StatueGarden.Phase.RED and mg.phase_index == idx and not mg.is_finished():
			await step(1)
		for s: int in start:
			if caught.any(func(c: Array) -> bool: return c[0] == s):
				continue
			watched += 1
			var d := Vector2(ps[s].global_position.x - start[s].x, ps[s].global_position.z - start[s].z).length()
			if d > 0.15:
				drifted.append("P%d %.2f m in RED %d" % [s, d, idx])
	print("  statue still-check: %d bot-REDs watched, drifted: %s" % [watched, drifted])
	assert_true(watched >= 8, "watched %d stopped bots" % watched)
	assert_true(drifted.size() <= watched / 10, "stopped bots stand still: %s" % [drifted])


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
