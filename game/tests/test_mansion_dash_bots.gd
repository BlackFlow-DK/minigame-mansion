extends GameTest
## Mansion Dash bot-only races: every slot is a BotBrain driven from the test (so every slot ticks
## the same way), the layout and the brains are seeded, so every race here is deterministic. They
## run at the real round speed (the harness steps physics as fast as the CPU allows). Each race
## must end with a valid full ranking within the time limit; the checked races must see a bot
## finish in a sane time and the finishers lead the ranking in finish order.
## Twelve seeded 4-bot races (two per test, to stay inside the runner's time limit) check that no
## slot wins more than half of them.

const ID := &"mansion_dash"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"
## Each checked race's first bot crosses the line in this window (round clock seconds)...
const FIRST_MIN := 18.0
const FIRST_MAX := 60.0
## ...and over the twelve bias races the first finish averages in this window: the target. Bots run
## flat out but play the course at MansionDash.bot_skill_scale of their skill (misjudged hammers,
## mistimed raft jumps, stale lines), so a decent human beats them; a clean bot run is ~21 s.
const FIRST_MEAN_MIN := 28.0
const FIRST_MEAN_MAX := 45.0

static var _firsts: Array[float] = []

static var _wins: Dictionary = {}
static var _races: int = 0


## One bot-only race; returns {seconds, ranking, finish_times, falls}.
func _race(count: int, seed_value: int, check: bool = true) -> Dictionary:
	var ps := spawn_arena(count, ID, false)
	var m := get_minigame() as MansionDash
	m.course_seed = seed_value * 7 + 3
	m.begin(m.course_seed)
	var brains: Array[BotBrain] = []
	for p in ps:
		var ctrl := p.get_component(&"controller") as ControllerComponent
		ctrl.scripted = true
		var brain := (load(BOT_BRAIN_PATH) as GDScript).new() as BotBrain
		brain.player = p
		brain.name = "TestBrain%d" % p.slot
		add_child(brain)
		brain.configure(seed_value * 97 + p.slot * 13)
		brains.append(brain)
	var hits := {}
	m.local_hit.connect(func(_s: int, kind: StringName) -> void: hits[kind] = int(hits.get(kind, 0)) + 1)
	var cp_times := {}
	m.checkpoint_reached.connect(func(s: int, k: int) -> void: cp_times[s] = "%s %.0f" % [cp_times.get(s, ""), m.round_time()])
	var fall_by := {}
	m.fell.connect(func(s: int) -> void: fall_by[s] = int(fall_by.get(s, 0)) + 1)
	var dt := physics_delta()
	var frames := 0
	var limit := int((m.time_limit + 3.0) / dt)
	while not m.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void:
			for b in brains:
				b.fill_intent(b.player.intent, dt))
		frames += 1
	var where: Array[String] = []
	for p in ps:
		where.append("%d:cp%d z%.1f" % [p.slot, m.checkpoints.get(p.slot, -1), p.global_position.z])
	for b in brains:
		b.queue_free()
	if not assert_true(m.is_finished(), "race finished (seed %d)" % seed_value):
		return {"seconds": -1.0, "ranking": [], "finish_times": {}, "falls": 0}
	var seconds := m.round_time()
	assert_true(seconds <= m.time_limit + 0.05, "within the time limit (%.1f s)" % seconds)
	assert_eq(ranking.size(), count, "every slot ranked")
	for s in count:
		assert_eq(ranking.count(s), 1, "slot %d exactly once" % s)
	var times: Array[String] = []
	for s: int in m.finish_order:
		times.append("%d@%.1f" % [s, m.finish_times[s]])
	print("  dash bots=%d seed=%d: %.1f s, ranking %s, finished [%s], falls %s, hits %s, checkpoints %s, at end [%s]" % [
			count, seed_value, seconds, ranking, ", ".join(times), fall_by, hits, cp_times, ", ".join(where)])
	if check:
		assert_true(m.finish_order.size() >= 1, "somebody finished (seed %d)" % seed_value)
		if not m.finish_order.is_empty():
			var first: float = m.finish_times[m.finish_order[0]]
			assert_true(first >= FIRST_MIN and first <= FIRST_MAX, "first finisher at %.1f s, in %d-%d s" % [first, FIRST_MIN, FIRST_MAX])
		assert_eq(ranking.slice(0, m.finish_order.size()), m.finish_order, "finishers lead the ranking in finish order")
	return {"seconds": seconds, "ranking": ranking.duplicate(), "finish_times": m.finish_times.duplicate(), "falls": m.falls}


func test_4_bots_seed_1() -> void:
	await _race(4, 1)


func test_8_bots_seed_1() -> void:
	await _race(8, 1)


func test_8_bots_seed_2() -> void:
	await _race(8, 2)


func _bias_batch(seeds: Array[int]) -> void:
	for s in seeds:
		var r: Dictionary = await _race(4, 100 + s, false)
		var rk: Array = r["ranking"]
		var ft: Dictionary = r["finish_times"]
		if not ft.is_empty():
			var first := INF
			for fs: int in ft:
				first = minf(first, float(ft[fs]))
			_firsts.append(first)
		if not rk.is_empty():
			_wins[rk[0]] = int(_wins.get(rk[0], 0)) + 1
			_races += 1
		_teardown()
		ranking = []
		await step(2)


func test_slot_bias_races_1_2() -> void:
	await _bias_batch([1, 2])


func test_slot_bias_races_3_4() -> void:
	await _bias_batch([3, 4])


func test_slot_bias_races_5_6() -> void:
	await _bias_batch([5, 6])


func test_slot_bias_races_7_8() -> void:
	await _bias_batch([7, 8])


func test_slot_bias_races_9_10() -> void:
	await _bias_batch([9, 10])


func test_slot_bias_races_11_12() -> void:
	await _bias_batch([11, 12])
	var mean := 0.0
	for f in _firsts:
		mean += f / maxf(_firsts.size(), 1.0)
	print("  dash slot bias: %d races, wins by slot %s; first finish mean %.1f s over %d races" % [_races, _wins, mean, _firsts.size()])
	if _races < 12:
		return  # a filtered run; the full run checks the whole batch
	assert_true(_firsts.size() >= 10, "somebody finished in most races (%d of 12)" % _firsts.size())
	assert_true(mean >= FIRST_MEAN_MIN and mean <= FIRST_MEAN_MAX, "first finish averages %.1f s, target %d-%d s" % [mean, FIRST_MEAN_MIN, FIRST_MEAN_MAX])
	for s in 4:
		assert_true(int(_wins.get(s, 0)) <= 6, "slot %d won %d of 12 (at most half)" % [s, int(_wins.get(s, 0))])
