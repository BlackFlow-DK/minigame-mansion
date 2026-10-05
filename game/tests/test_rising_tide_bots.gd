extends GameTest
## Rising Tide bot-only rounds: every slot is a BotBrain driven from the test (so every slot ticks
## the same way); the round seed and the brains are seeded, so every round here is deterministic.
## Each round must end validly (every slot ranked once, within the time limit); the checked rounds
## must neither see everybody drown in the first 15 s nor everybody survive, with the drownings on
## the climb (not those knocked off the roof) spread over the round. Twelve seeded 4-bot rounds (two per test, to stay inside the runner's time
## limit) check that no slot wins more than half of them.

const ID := &"rising_tide"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"
## Round clock multiplier for these tests (the water, sway and crumbles run this much faster than the
## blobs move, a harder round than the real one).
const TIME_SCALE := 1.0

static var _wins: Dictionary = {}
static var _rounds: int = 0


## One bot-only round; returns {seconds, ranking, drowned: {slot: time}, roof: int}.
func _round(count: int, seed_value: int, check: bool = true) -> Dictionary:
	var ps := spawn_arena(count, ID, false)
	var m := get_minigame() as RisingTide
	m.time_scale = TIME_SCALE
	m.tower_seed = seed_value * 7 + 3
	m._rpc_spawn_layout(RisingTide.spawn_order(_slots(ps), m.tower_seed))
	m.begin(m.tower_seed)
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
	var routes := {}
	var launches := [0]
	m.launched.connect(func(_s: int) -> void: launches[0] += 1)
	var crumbles := [0]
	m.crumble_fell.connect(func(_i: int) -> void: crumbles[0] += 1)
	var levels := {}
	var dt := physics_delta()
	var frames := 0
	var limit := int((m.time_limit / TIME_SCALE + 3.0) / dt)
	while not m.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void:
			for b in brains:
				b.fill_intent(b.player.intent, dt))
		frames += 1
		if frames % 60 == 0:
			for p in ps:
				if p.alive:
					levels[p.slot] = maxi(int(levels.get(p.slot, 0)), TideTower.level_of(p.global_position.y))
	for p in ps:
		for s in TideTower.SECTIONS:
			if m._route_alt.get(p.slot * 16 + s, false):
				routes[s] = int(routes.get(s, 0)) + 1
	for b in brains:
		b.queue_free()
	if not assert_true(m.is_finished(), "round finished (seed %d)" % seed_value):
		return {"seconds": -1.0, "ranking": [], "drowned": {}, "roof": 0}
	var seconds := m.round_time()
	assert_true(seconds <= m.time_limit + 0.05, "within the time limit (%.1f s)" % seconds)
	assert_eq(ranking.size(), count, "every slot ranked")
	for s in count:
		assert_eq(ranking.count(s), 1, "slot %d exactly once" % s)
	var times: Array[String] = []
	for s: int in m.drown_times:
		times.append("%d@%.1f" % [s, m.drown_times[s]])
	print("  tide bots=%d seed=%d: %.1f s, groups %s, drowned [%s], roof %s, summit %d, best floors %s, alt routes %s, launches %d, crumbles %d" % [
			count, seed_value, seconds, m.finish_groups, ", ".join(times), m.roof_times.keys(), m.summit_slot, levels, routes, launches[0], crumbles[0]])
	if check:
		var early := 0
		for s: int in m.drown_times:
			if m.drown_times[s] < 15.0:
				early += 1
		assert_true(early < count, "not everybody drowned in the first 15 s (seed %d)" % seed_value)
		assert_true(m.drown_times.size() >= 1, "not everybody survived (seed %d)" % seed_value)
		# The climb's drownings spread over the round (no single wave takes everyone). A bot that
		# had reached the roof and was knocked off in the summit scramble is not a climb drowning.
		var climb: Array = []
		for s: int in m.drown_times:
			if not m.roof_times.has(s):
				climb.append(m.drown_times[s])
		if climb.size() >= 3:
			assert_true(float(climb.max()) - float(climb.min()) >= 10.0, "climb drownings spread over the round (%s)" % [times])
	return {"seconds": seconds, "ranking": ranking.duplicate(), "drowned": m.drown_times.duplicate(), "roof": m.roof_times.size()}


func _slots(ps: Array[Player]) -> PackedInt32Array:
	var out := PackedInt32Array()
	for p in ps:
		out.append(p.slot)
	return out


func test_4_bots_seed_1() -> void:
	await _round(4, 1)


func test_8_bots_seed_1() -> void:
	await _round(8, 1)


func test_8_bots_seed_2() -> void:
	await _round(8, 2)


func _bias_batch(seeds: Array[int]) -> void:
	for s in seeds:
		var r: Dictionary = await _round(4, 100 + s, false)
		var rk: Array = r["ranking"]
		if not rk.is_empty():
			_wins[rk[0]] = int(_wins.get(rk[0], 0)) + 1
			_rounds += 1
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
	print("  tide slot bias: %d rounds, wins by slot %s" % [_rounds, _wins])
	if _rounds < 12:
		return  # a filtered run; the full run checks the whole batch
	for s in 4:
		assert_true(int(_wins.get(s, 0)) <= 6, "slot %d won %d of 12 (at most half)" % [s, int(_wins.get(s, 0))])
