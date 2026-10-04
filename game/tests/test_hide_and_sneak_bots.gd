extends GameTest
## Hide and Sneak bot-only rounds: every slot (slot 0 too) is driven by a BotBrain and the
## host AI (hider spots, seeker suspicion and pokes). Rounds must end with a valid ranking;
## over 12 seeded rounds the seekers must find a fair share (40-70 % of hiders) and score
## about the table average (within 25 %). Prints the numbers per round.

const ID := &"hide_and_sneak"

## Totals over the fairness rounds (filled by the test_fair_* parts, checked by the last one).
static var _fair: Dictionary = {}


func before_each() -> void:
	HideAndSneak.reset_rotation()


## Plays one bot-only round; returns {ranking, groups, points, seekers, hiders, found}.
func _bot_round(count: int, seed_value: int, scale: float) -> Dictionary:
	HideAndSneak.test_seed = seed_value
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as HideAndSneak
	mg.time_scale = scale
	mg.ai_humans = true
	var brain0 := BotBrain.new()
	brain0.player = ps[0]
	brain0.minigame = mg
	add_child(brain0)
	brain0.configure(seed_value * 100, 1.0 if mg.hider_slots.has(0) else 0.85, 0.0)
	(ps[0].get_component(&"controller") as ControllerComponent).scripted = true
	var frames := 0
	var limit := int((mg.hide_time + mg.seek_time) / scale * 60.0) + 240
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
	var groups: Array = mg.finish_groups.duplicate(true)
	var points := Session.points_for_groups(groups, count)
	var found := mg.caught_time.size()
	var furniture_pokes := 0
	for s in mg.seekers:
		furniture_pokes += mg.poke_budget(mg.hider_slots.size(), mg.seekers.size()) - int(mg.pokes_left.get(s, 0))
	print("  hide bots=%d seed=%d scale=%.1f: seekers %s finds %s, found %d/%d, groups %s, points %s, %.1f s" % [
		count, seed_value, scale, str(mg.seekers), str(mg.finds), found, mg.hider_slots.size(), str(groups), str(points),
		frames / 60.0 * scale])
	return {"ranking": ranking.duplicate(), "groups": groups, "points": points, "seekers": mg.seekers.duplicate(),
		"hiders": mg.hider_slots.size(), "found": found}


func test_bots_3_scaled() -> void:
	await _bot_round(3, 11, 2.0)


func test_bots_5_scaled() -> void:
	await _bot_round(5, 12, 2.0)


func test_bots_8_scaled() -> void:
	await _bot_round(8, 13, 2.0)


func _fair_rounds(seeds: Array) -> void:
	for sd: int in seeds:
		var count: int = [4, 5, 6, 8][sd % 4]
		var r := await _bot_round(count, 100 + sd, 1.0)
		var seek_pts := 0
		var all_pts := 0
		for s: int in r.points:
			all_pts += int(r.points[s])
			if (r.seekers as Array).has(s):
				seek_pts += int(r.points[s])
		_fair["rounds"] = int(_fair.get("rounds", 0)) + 1
		_fair["seek_pts"] = float(_fair.get("seek_pts", 0.0)) + float(seek_pts) / (r.seekers as Array).size()
		_fair["avg_pts"] = float(_fair.get("avg_pts", 0.0)) + float(all_pts) / count
		_fair["found"] = int(_fair.get("found", 0)) + int(r.found)
		_fair["hiders"] = int(_fair.get("hiders", 0)) + int(r.hiders)
		# Tear down between rounds in one test.
		await _reset_arena()


func _reset_arena() -> void:
	if stage:
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
	ranking = []
	players.clear()
	Net.leave()
	await get_tree().process_frame
	HideAndSneak.reset_rotation()


func test_fair_part_1() -> void:
	_fair.clear()
	await _fair_rounds([0, 1, 2, 3])


func test_fair_part_2() -> void:
	await _fair_rounds([4, 5, 6, 7])


func test_fair_part_3() -> void:
	await _fair_rounds([8, 9, 10, 11])


func test_fair_seekers_score_about_average() -> void:
	var n := int(_fair.get("rounds", 0))
	if n < 12:
		await _fair_rounds(range(n, 12))
		n = int(_fair.get("rounds", 0))
	var seek := float(_fair["seek_pts"]) / n
	var avg := float(_fair["avg_pts"]) / n
	var found := float(_fair["found"]) / maxf(float(_fair["hiders"]), 1.0)
	print("  hide fairness over %d rounds: seeker %.2f pts/round vs table %.2f (ratio %.2f), found %.0f %%" % [n, seek, avg, seek / avg, found * 100.0])
	assert_true(absf(seek / avg - 1.0) <= 0.25, "seekers score %.2f vs table %.2f (within 25 %%)" % [seek, avg])
	assert_true(found >= 0.4 and found <= 0.7, "found %.0f %% of hiders (want 40-70 %%)" % (found * 100.0))
