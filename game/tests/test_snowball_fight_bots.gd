extends GameTest
## Snowball Fight bot-only rounds: every slot is a bot (slot 0 is the harness's human, so it gets a
## BotBrain driven from here and the minigame's thrower AI through `ai_slots`). Brains and AIs are
## seeded, so each round is deterministic. Each round must end with a valid ranking (every slot
## once, ranked by points) with plenty of throws and hits. Twelve seeded 4-bot rounds (time scale
## 2: half-length rounds) check no slot wins far more than its share. The bots' personalities
## (skill, aggression) rotate over the seats in blocks of 4 rounds (as the balance runner does),
## so a seat's wins measure the seat, not the personality it happened to roll (before, each seat
## kept its own roll per seed; slot 1 once won 7 of 12). Limit: at most 7 of 12 (share 3): a fair
## seat reaches 8 with p ~ 0.003 (about 1 % for any of four). Large samples:
## docs/balance-v03-b.md (Snowball Fight, 96 rounds per count: no seat bias).

const ID := &"snowball_fight"

static var _wins: Dictionary = {}
static var _bias_rounds: int = 0


## One bot-only round. Returns {ranking, throws, hits, spread, snowins}.
## `rotate`: brain personalities shift by this many seats (brain seeds from `brain_seed`, or
## `seed_value` when < 0).
func _bot_round(count: int, seed_value: int, scale: float, rotate: int = 0, brain_seed: int = -1) -> Dictionary:
	var bseed := seed_value if brain_seed < 0 else brain_seed
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as SnowballFight
	mg.ai_seed = seed_value
	mg.time_scale = scale
	mg.ai_slots = [0]
	var brain0 := BotBrain.new()
	brain0.player = ps[0]
	brain0.minigame = mg
	add_child(brain0)
	brain0.configure(bseed * 100 + posmod(rotate, count))
	(ps[0].get_component(&"controller") as ControllerComponent).scripted = true
	for p in ps:
		var c := p.get_component(&"controller") as ControllerComponent
		if c.brain:
			(c.brain as BotBrain).configure(bseed * 100 + posmod(p.slot + rotate, count))
	var frames := 0
	var limit := int(mg.time_limit / scale * 60.0) + 120
	while not mg.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void: brain0.fill_intent(ps[0].intent, physics_delta()))
		frames += 1
	brain0.queue_free()
	if not assert_true(mg.is_finished(), "%d bots, seed %d: round finished" % [count, seed_value]):
		return {"ranking": []}
	assert_eq(ranking.size(), count, "ranking has every slot")
	var sorted := ranking.duplicate()
	sorted.sort()
	var all: Array[int] = []
	for i in count:
		all.append(i)
	assert_eq(sorted, all, "every slot exactly once")
	for i in range(ranking.size() - 1):
		assert_true(mg.scores[ranking[i]] >= mg.scores[ranking[i + 1]], "ranking follows the points")
	var throws := 0
	var hits := 0
	var snowins := 0
	var top := 0
	var low := 1 << 30
	for s: int in mg.scores:
		throws += mg.throws[s]
		hits += mg.hits_landed[s]
		snowins += mg.snowed_count[s]
		top = maxi(top, mg.scores[s])
		low = mini(low, mg.scores[s])
	var list: Array = []
	for s in ranking:
		list.append("%d:%d/%d" % [s, mg.scores[s], mg.throws[s]])
	print("  snowball bots=%d seed=%d scale=%.1f: %d throws, %d hits (%.0f %%), %d snow-ins, points %d..%d, ranking(pts/throws) %s, refused %d" % [
		count, seed_value, scale, throws, hits, 100.0 * hits / maxf(throws, 1.0), snowins, low, top, " ".join(list), mg.rejected_reports])
	assert_eq(mg.rejected_reports, 0, "the host refused no honest request")
	return {"ranking": ranking.duplicate(), "throws": throws, "hits": hits, "spread": top - low, "snowins": snowins}


func _check_lively(r: Dictionary, count: int, scale: float) -> void:
	if r["ranking"].is_empty():
		return
	var per_bot := float(r["throws"]) / count * scale
	assert_true(per_bot >= 8.0, "plenty of throws (%.1f per bot per minute)" % per_bot)
	assert_true(int(r["hits"]) >= int(count * 2 / scale), "plenty of hits (%d)" % r["hits"])
	var rate := float(r["hits"]) / maxf(float(r["throws"]), 1.0)
	assert_true(rate > 0.15 and rate < 0.85, "a fair hit rate (%.2f)" % rate)


func test_4_bots_real_time() -> void:
	_check_lively(await _bot_round(4, 1, 1.0), 4, 1.0)


func test_8_bots_real_time() -> void:
	_check_lively(await _bot_round(8, 2, 1.0), 8, 1.0)


func test_8_bots_time_scale_2() -> void:
	_check_lively(await _bot_round(8, 3, 2.0), 8, 2.0)


## Rounds 1-12: block (s - 1) / 4 shares one set of four personalities, rotated by one seat per
## round, so every seat plays every personality once per block.
func _bias_batch(seeds: Array[int]) -> void:
	for s in seeds:
		var r: Dictionary = await _bot_round(4, 200 + s, 2.0, (s - 1) % 4, 300 + (s - 1) / 4)
		var rk: Array = r["ranking"]
		if not rk.is_empty():
			_wins[rk[0]] = int(_wins.get(rk[0], 0)) + 1
			_bias_rounds += 1
		_teardown()
		ranking = []
		await step(2)


func test_slot_bias_rounds_1_3() -> void:
	await _bias_batch([1, 2, 3])


func test_slot_bias_rounds_4_6() -> void:
	await _bias_batch([4, 5, 6])


func test_slot_bias_rounds_7_9() -> void:
	await _bias_batch([7, 8, 9])


func test_slot_bias_rounds_10_12() -> void:
	await _bias_batch([10, 11, 12])
	print("  snowball slot bias: %d rounds, wins by slot %s" % [_bias_rounds, _wins])
	if _bias_rounds < 12:
		return  # a filtered run; the full run checks the whole batch
	for s in 4:
		assert_true(int(_wins.get(s, 0)) <= 7, "slot %d won %d of 12 (share 3)" % [s, int(_wins.get(s, 0))])
