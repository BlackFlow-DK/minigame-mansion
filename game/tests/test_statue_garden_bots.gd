extends GameTest
## Statue Garden bot-only rounds: every slot (slot 0 too, via its own BotBrain) is a bot.
## Each round must end with a valid ranking (every slot once) in 30-70 s with some catches
## (bots have imperfect reflexes: the brain's skill-based hold reaction to `bot_should_hold`);
## the numbers are printed so the pacing can be judged. Plus a
## slot-bias check over 12 seeded 4-bot rounds at time scale 2 (the phase clock runs twice as
## fast, the walking does not), and a check that stopped bots really stand still.

const ID := &"statue_garden"


## Runs one bot-only round; returns [seconds, winner slot (-1 time-up), catches, ranking].
## `brain_seeds` (optional): the personality seed per slot (else seed_value * 100 + slot).
func _bot_round(count: int, seed_value: int, scale: float, quiet: bool = false, brain_seeds: Array[int] = []) -> Array:
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as StatueGarden
	mg.rng.seed = seed_value
	mg.time_scale = scale
	mg.shuffle_lanes()
	var brain0 := BotBrain.new()
	brain0.player = ps[0]
	brain0.minigame = mg
	add_child(brain0)
	brain0.configure(brain_seeds[0] if not brain_seeds.is_empty() else seed_value * 100)
	(ps[0].get_component(&"controller") as ControllerComponent).scripted = true
	for p in ps:
		var c := p.get_component(&"controller") as ControllerComponent
		if c.brain:
			(c.brain as BotBrain).configure(brain_seeds[p.slot] if not brain_seeds.is_empty() else seed_value * 100 + p.slot)
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


## The 12 rounds run in blocks of 3 (one test each: every test has 60 s, and the slower walk of
## the balance pass made one 12-round test too long on a loaded machine); the last block asserts.
## Personalities rotate over the slots (4 per block of 4 rounds, each slot plays each once), so
## the check measures seats, not which slot drew the sharpest bot (as balance_runner does).
static var _bias_wins: Array[int] = [0, 0, 0, 0]
static var _bias_rounds: int = 0
static var _bias_timeouts: int = 0
static var _bias_total: float = 0.0


func _bias_block(first: int) -> void:
	for k in range(first, first + 3):
		var seeds: Array[int] = []
		for s in 4:
			seeds.append(7000 + 10 * (k / 4) + (s + k) % 4)
		var r := await _bot_round(4, 100 + k, 2.0, true, seeds)
		if not is_inside_tree():
			return
		if int(r[1]) >= 0:
			_bias_wins[int(r[1])] += 1
		else:
			_bias_timeouts += 1
		_bias_total += float(r[0])
		_bias_rounds += 1
		_teardown_round()


func test_no_slot_bias_block_0() -> void: await _bias_block(0)
func test_no_slot_bias_block_1() -> void: await _bias_block(3)
func test_no_slot_bias_block_2() -> void: await _bias_block(6)


func test_no_slot_bias_over_12_rounds() -> void:
	await _bias_block(9)
	print("  statue %d x 4 bots (scale 2): wins per slot %s, %d time-ups, mean %.1f s" % [
		_bias_rounds, _bias_wins, _bias_timeouts, _bias_total / maxi(_bias_rounds, 1)])
	if _bias_rounds < 12:
		return  # filtered to this block alone: nothing pooled to judge
	for s in 4:
		assert_true(_bias_wins[s] <= 6, "slot %d won %d of 12" % [s, _bias_wins[s]])


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
			var brain := BotBrain.of(p)
			if p.slot != 0 and brain and brain.is_held():
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
