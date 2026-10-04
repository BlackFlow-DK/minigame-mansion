extends GameTest
## Ghost Tag bot-only rounds: every slot (slot 0 too) is driven by a BotBrain at real speed.
## A round must end with a valid ranking and typically leave 1-3 survivors (neither a wipe-out
## by 20 s nor everybody surviving); over 12 seeded rounds the starting ghost's points stay
## within 25 % of the average player's and no spawn slot is favoured. Prints the numbers.

const ID := &"ghost_tag"


## Plays one bot-only round. Returns {ranking, groups, survivors, catches, first_catch, last_catch,
## end_time, ghost_points, avg_points, points}.
func _bot_round(count: int, seed_value: int) -> Dictionary:
	GhostTag.seed_next = seed_value
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as GhostTag
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
	var frames := 0
	var limit := int(mg.time_limit * 60.0) + 120
	while not mg.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void: brain0.fill_intent(ps[0].intent, physics_delta()))
		frames += 1
	brain0.queue_free()
	assert_true(mg.is_finished(), "%d bots, seed %d: round finished" % [count, seed_value])
	var out := {}
	if not mg.is_finished():
		return out
	assert_eq(ranking.size(), count, "ranking has every slot")
	var sorted := ranking.duplicate()
	sorted.sort()
	var all: Array[int] = []
	for i in count:
		all.append(i)
	assert_eq(sorted, all, "every slot exactly once")
	var groups := mg.finish_groups
	var points := Session.points_for_groups(groups, count)
	var survivors := 0
	for s in all:
		if mg.is_living(s):
			survivors += 1
	var total := 0
	for s: int in points:
		total += int(points[s])
	var ghost_points := 0.0
	for g in mg.original_ghosts:
		ghost_points += float(points.get(g, 0))
	ghost_points /= maxf(mg.original_ghosts.size(), 1.0)
	var first := INF
	var last := 0.0
	for e: Array in catches:
		first = minf(first, float(e[2]))
		last = maxf(last, float(e[2]))
	var credit_text: Array[String] = []
	for g in mg.original_ghosts:
		credit_text.append("%d:%.0f(own %d)" % [g, mg.credit.get(g, 0.0), mg.own_catches.get(g, 0)])
	print("  ghost_tag bots=%d seed=%d: %d survivors, %d catches (first %.1f s, last %.1f s), end %.1f s, ghosts %s, ghost pts %.1f vs avg %.2f, groups %s" % [
		count, seed_value, survivors, catches.size(), first if catches.size() > 0 else -1.0, last, mg.round_time(),
		", ".join(credit_text), ghost_points, float(total) / count, groups])
	out = {"ranking": ranking.duplicate(), "groups": groups, "survivors": survivors, "catches": catches.size(),
		"first_catch": first, "last_catch": last, "end_time": mg.round_time(), "ghost_points": ghost_points,
		"avg_points": float(total) / count, "points": points}
	return out


func _clear_stage() -> void:
	stage.clear()
	remove_child(stage)
	stage.queue_free()
	stage = null
	players.clear()
	ranking.clear()
	Net.leave()
	await step(2)


func _check_healthy(r: Dictionary, count: int) -> void:
	if r.is_empty():
		return
	assert_true(int(r.survivors) < count - GhostTag.ghost_count_for(count), "somebody was caught (%d survivors)" % r.survivors)
	assert_true(float(r.end_time) > 20.0, "no wipe-out by 20 s (ended %.1f s)" % r.end_time)


func test_bots_4_seed_1() -> void:
	_check_healthy(await _bot_round(4, 1), 4)


func test_bots_8_seed_2() -> void:
	_check_healthy(await _bot_round(8, 2), 8)


## 12 seeded rounds (4 and 8 bots alternating) in batches of two (each test has its own time limit):
## every round neither a wipe-out by 20 s nor everyone surviving, survivors typically (most
## rounds) 1-3, the starting ghost's mean points within 25 % of the average
## player's, and no spawn slot favoured. The last batch checks the totals.
static var _rounds: Array[Dictionary] = []
static var _slot_points: Dictionary = {}
static var _slot_rounds: Dictionary = {}


func _batch(seeds: Array[int]) -> void:
	for seed_value in seeds:
		var count := 4 if seed_value % 2 == 0 else 8
		var r := await _bot_round(count, seed_value)
		if r.is_empty():
			return
		r["count"] = count
		_check_healthy(r, count)
		_rounds.append(r)
		var pts: Dictionary = r.points
		for s: int in pts:
			# points relative to the round's average (4- and 8-player rounds score differently)
			_slot_points[s] = float(_slot_points.get(s, 0.0)) + float(pts[s]) / maxf(float(r.avg_points), 0.01)
			_slot_rounds[s] = int(_slot_rounds.get(s, 0)) + 1
		await _clear_stage()


func test_balance_rounds_1_2() -> void:
	await _batch([300, 301])


func test_balance_rounds_3_4() -> void:
	await _batch([302, 303])


func test_balance_rounds_5_6() -> void:
	await _batch([304, 305])


func test_balance_rounds_7_8() -> void:
	await _batch([306, 307])


func test_balance_rounds_9_10() -> void:
	await _batch([308, 309])


func test_balance_rounds_11_12() -> void:
	await _batch([310, 311])
	if _rounds.size() < 12:
		return  # run alone (filtered): the totals need all six batches
	var ghost_rel := 0.0
	var survivors: Array[int] = []
	var typical := 0
	for r in _rounds:
		ghost_rel += float(r.ghost_points) / maxf(float(r.avg_points), 0.01)
		survivors.append(int(r.survivors))
		if int(r.survivors) >= 1 and int(r.survivors) <= 3:
			typical += 1
	ghost_rel /= _rounds.size()
	var shares: Array[String] = []
	for s in 8:
		if _slot_rounds.has(s):
			shares.append("%d:%.2f" % [s, float(_slot_points[s]) / float(_slot_rounds[s])])
	print("  ghost_tag balance (%d rounds): survivors %s (%d of 12 with 1-3), starting ghost points %.2f x average, slot points x average %s" % [
		_rounds.size(), survivors, typical, ghost_rel, " ".join(shares)])
	assert_true(typical >= 7, "typically (most rounds) 1-3 survivors (%d of 12 rounds)" % typical)
	assert_true(absf(ghost_rel - 1.0) <= 0.25, "starting ghost scores %.2f x the average (within 25 %%)" % ghost_rel)
	for s in 4:
		var rel := float(_slot_points[s]) / float(_slot_rounds[s])
		assert_true(rel > 0.5 and rel < 1.6, "slot %d scores %.2f x the average" % [s, rel])
