extends GameTest
## Cannon Alley bot-only rounds: every slot is a BotBrain driven from the test (so every slot
## ticks the same way; with slot 0 alone driven from here it won noticeably more often), the
## schedule and the brains are seeded, so every round here is deterministic. They run at the
## real round speed (time_scale 1; the harness steps physics as fast as the CPU allows). Each
## round must finish with a valid ranking (every slot exactly once) and last 25-55 s on the
## round clock. Twelve seeded 4-bot rounds (two per test, to stay well inside the runner's
## time limit on a busy machine) check that no slot wins far more than its share (3 of 12; at most 6 allowed).

const ID := &"cannon_alley"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"
const MIN_LENGTH := 25.0
const MAX_LENGTH := 55.0

## slot -> wins over the bias rounds run so far in this test run.
static var _wins: Dictionary = {}
static var _bias_rounds: int = 0


## One bot-only round; returns {seconds, ranking} (seconds -1 when it did not finish).
func _bot_round(count: int, seed_value: int, check_length: bool = true) -> Dictionary:
	var ps := spawn_arena(count, ID, false)
	var m := get_minigame() as CannonAlley
	m.begin(seed_value * 7 + 3)
	var brains: Array[BotBrain] = []
	for p in ps:
		var ctrl := p.get_component(&"controller") as ControllerComponent
		var brain: BotBrain
		# Every slot gets a brain driven from here, so all slots tick in the same order
		# (slot 0 has no controller brain; the others' own brains stay idle).
		ctrl.scripted = true
		brain = (load(BOT_BRAIN_PATH) as GDScript).new() as BotBrain
		brain.player = p
		brain.name = "TestBrain%d" % p.slot
		add_child(brain)
		brain.configure(seed_value * 97 + p.slot * 13)
		brains.append(brain)
	var out_times: Array[String] = []
	var jumps_over := {}
	for p in ps:
		p.eliminated.connect(func(r: StringName) -> void: out_times.append("%d@%.1f(%s)" % [p.slot, m.round_time(), r]))
	var dt := physics_delta()
	var frames := 0
	var limit := int((m.time_limit + 2.0) / dt)
	while not m.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void:
			for b in brains:
				b.fill_intent(b.player.intent, dt))
		frames += 1
		# Count bots that are right above a slow ball (a successful hop).
		for path in m.imminent_paths(0.0):
			if not bool(path["slow"]):
				continue
			for p in ps:
				var f := p.global_position
				if p.alive and f.y > 0.5 and absf(f.x - float(path["x"])) < 0.5 and absf(f.z - float(path["z0"])) < 0.5:
					jumps_over[p.slot] = true
	for b in brains:
		b.queue_free()
	if not assert_true(m.is_finished(), "round finished (seed %d)" % seed_value):
		return {"seconds": -1.0, "ranking": []}
	var seconds := m.round_time()
	assert_eq(ranking.size(), count, "every slot ranked")
	for s in count:
		assert_eq(ranking.count(s), 1, "slot %d exactly once" % s)
	if check_length:
		assert_true(seconds >= MIN_LENGTH and seconds <= MAX_LENGTH, "round length %.1f s in %d-%d s (seed %d)" % [seconds, MIN_LENGTH, MAX_LENGTH, seed_value])
	var confirmed := 0
	for s: int in m.hits:
		confirmed += m.hits[s]
	print("  cannon bots=%d seed=%d: %.1f s, ranking %s, hits %d, hoppers %d, outs %s" % [count, seed_value, seconds, ranking, confirmed, jumps_over.size(), ", ".join(out_times)])
	return {"seconds": seconds, "ranking": ranking.duplicate()}


func test_4_bots_seed_1() -> void:
	await _bot_round(4, 1)


func test_4_bots_seed_2() -> void:
	await _bot_round(4, 2)


func test_8_bots_seed_1() -> void:
	await _bot_round(8, 1)


func test_8_bots_seed_2() -> void:
	await _bot_round(8, 2)


func _bias_batch(seeds: Array[int]) -> void:
	for s in seeds:
		var r: Dictionary = await _bot_round(4, 100 + s, false)
		var rk: Array = r["ranking"]
		if not rk.is_empty():
			_wins[rk[0]] = int(_wins.get(rk[0], 0)) + 1
			_bias_rounds += 1
		_teardown()
		ranking = []
		await step(2)


func test_slot_bias_rounds_1_2() -> void:
	await _bias_batch([1, 2])


func test_slot_bias_rounds_3_4() -> void:
	await _bias_batch([3, 4])


func test_slot_bias_rounds_5_6() -> void:
	await _bias_batch([5, 6])


func test_slot_bias_rounds_7_8() -> void:
	await _bias_batch([7, 8])


func test_slot_bias_rounds_9_10() -> void:
	await _bias_batch([9, 10])


func test_slot_bias_rounds_11_12() -> void:
	await _bias_batch([11, 12])
	print("  cannon slot bias: %d rounds, wins by slot %s" % [_bias_rounds, _wins])
	if _bias_rounds < 12:
		return  # a filtered run; the full run checks the whole batch
	for s in 4:
		assert_true(int(_wins.get(s, 0)) <= 6, "slot %d won %d of 12 (share 3)" % [s, int(_wins.get(s, 0))])
