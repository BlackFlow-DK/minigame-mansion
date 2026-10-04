extends GameTest
## Masquerade bot-only rounds: every slot (slot 0 too, via its own BotBrain handed to the
## minigame's bot driver) is a bot among the NPC extras. Each round must finish validly (a
## ranking with every slot once, no extras), ideally in 30-70 s with a mix of right and wrong
## shoves; the numbers are printed so the pacing can be judged. Plus a slot-bias check over 12
## seeded 4-bot rounds (split over six tests to stay inside the runner's time limit).

const ID := &"masquerade"


## Runs one bot-only round; returns [seconds, winner slot or -1, unmasks, wrong shoves].
func _bot_round(count: int, seed_value: int, quiet: bool = false) -> Array:
	Masquerade.next_seed = seed_value
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as Masquerade
	var brain0 := BotBrain.new()
	brain0.player = ps[0]
	brain0.minigame = mg
	add_child(brain0)
	(ps[0].get_component(&"controller") as ControllerComponent).scripted = true
	mg.drive_with_bot(ps[0], brain0)
	var frames := 0
	var limit := int((mg.time_limit + 1.0) / physics_delta())
	while not mg.is_finished() and frames < limit:
		await step(1)
		frames += 1
	var seconds := frames * physics_delta()
	brain0.queue_free()
	if not assert_true(mg.is_finished(), "%d bots, seed %d: round finished" % [count, seed_value]):
		return [seconds, -1, 0, 0]
	var sorted := ranking.duplicate()
	sorted.sort()
	var all: Array[int] = []
	for i in count:
		all.append(i)
	assert_eq(sorted, all, "every slot exactly once, no extras")
	for s in ranking:
		assert_true(s < Stage.EXTRA_SLOT_BASE, "no extra in the ranking")
	var winner := -1
	if (mg.finish_groups[0] as Array).size() == 1:
		winner = int((mg.finish_groups[0] as Array)[0])
	if not quiet:
		print("  masquerade bots=%d seed=%d: %.1f s, groups %s, unmasks %d, wrong %d, hunts %d, shoves %d, points %s" % [
			count, seed_value, seconds, mg.finish_groups, mg.unmask_log.size(), mg.wrong_log.size(), mg.bots.hunts,
			mg.bots.shoves, mg.points])
	return [seconds, winner, mg.unmask_log.size(), mg.wrong_log.size()]


func test_4_bots_seed_1() -> void:
	await _bot_round(4, 1)


func test_4_bots_seed_2() -> void:
	await _bot_round(4, 2)


func test_8_bots_seed_1() -> void:
	var r := await _bot_round(8, 1)
	assert_true(int(r[2]) >= 1, "8 bots unmask somebody")


func test_8_bots_seed_2() -> void:
	await _bot_round(8, 2)


func _bias_batch(first: int) -> void:
	var wins: Array = []
	for k in 2:
		var r := await _bot_round(4, 100 + first + k, true)
		wins.append(int(r[1]))
		_teardown_round()
	print("  masquerade bias batch %d: winners %s" % [first, wins])
	_record(wins)


func test_slot_bias_a() -> void:
	await _bias_batch(0)


func test_slot_bias_b() -> void:
	await _bias_batch(2)


func test_slot_bias_c() -> void:
	await _bias_batch(4)


func test_slot_bias_d() -> void:
	await _bias_batch(6)


func test_slot_bias_e() -> void:
	await _bias_batch(8)


## The last batch also judges all 12 rounds (the batches share a static tally; tests run in
## file order).
func test_slot_bias_z() -> void:
	await _bias_batch(10)
	var wins: Array[int] = [0, 0, 0, 0]
	for w: int in _tally:
		if w >= 0:
			wins[w] += 1
	print("  masquerade 12 x 4 bots: wins per slot %s (ties/time-outs: %d)" % [wins, _tally.count(-1)])
	if _tally.size() < 12:
		print("  (only %d rounds tallied: run the whole file to judge the bias)" % _tally.size())
		return
	for s in 4:
		assert_true(wins[s] <= 6, "slot %d won %d of 12" % [s, wins[s]])


static var _tally: Array = []


func _record(wins: Array) -> void:
	_tally.append_array(wins)


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
