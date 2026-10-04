extends GameTest
## Blob Ball bot-only matches (every slot, slot 0 too, driven by a BotBrain): the match ends
## with a valid tied-group ranking (two teams, or one tied group) and bots actually score.
## Prints goals per match; each test plays two seeds.

const ID := &"blob_ball"

var brain0: BotBrain = null


## Plays one whole bot match; returns [goals, seconds, kicks].
func _match(count: int, seed_value: int) -> Array:
	seed(seed_value)
	var ps := spawn_arena(count, ID, false)
	(ps[0].get_component(&"controller") as ControllerComponent).scripted = true
	brain0 = BotBrain.new()
	brain0.player = ps[0]
	add_child(brain0)
	brain0.configure(seed_value * 31 + 7)
	var mg := get_minigame() as BlobBall
	var frames := 0
	var limit := int((mg.match_time + mg.golden_goal_time + 40.0) / physics_delta())
	while frames < limit and not mg.is_finished():
		await step(1, func(_i: int) -> void: brain0.fill_intent(players[0].intent, physics_delta()))
		frames += 1
	var goals := mg.score[0] + mg.score[1]
	var out := [goals, frames * physics_delta(), mg.kick_log.size()]
	print("  blob_ball bots=%d seed=%d: %s after %.1f s (clock %.1f), score %d-%d, %d kicks, groups %s" % [
		count, seed_value, "finished" if mg.is_finished() else "NOT finished", out[1], mg.clock,
		mg.score[0], mg.score[1], out[2], str(mg.finish_groups)])
	assert_true(mg.is_finished(), "match ends (seed %d)" % seed_value)
	_check_groups(mg, count)
	_teardown_round()
	return out


func _check_groups(mg: BlobBall, count: int) -> void:
	var groups := mg.finish_groups
	var flat := Minigame.flatten_groups(groups)
	assert_eq(flat.size(), count, "everyone ranked once")
	var seen: Dictionary = {}
	for s in flat:
		assert_false(seen.has(s), "slot %d ranked once" % s)
		seen[s] = true
	if mg.score[0] == mg.score[1]:
		assert_eq(groups.size(), 1, "a tie is one tied group")
	else:
		var w := 0 if mg.score[0] > mg.score[1] else 1
		assert_eq(groups.size(), 2, "two team groups")
		if groups.size() == 2:
			assert_eq(groups[0], mg.team_slots(w), "the team with more goals first")
			assert_eq(groups[1], mg.team_slots(1 - w), "then the other team")


func _series(count: int, seeds: Array) -> void:
	var total := 0
	for s: int in seeds:
		var r := await _match(count, s)
		total += int(r[0])
	print("  blob_ball bots=%d: %d goals in %d matches" % [count, total, seeds.size()])
	assert_true(total >= 1, "bots score at least sometimes (%d goals)" % total)


func test_bots_2v2() -> void:
	await _series(4, [11, 12])


## 4v4 matches take ~16 s each, so one per test; the goals add up across the two tests.
static var _goals_4v4: int = 0


func test_bots_4v4_first() -> void:
	var r := await _match(8, 21)
	_goals_4v4 += int(r[0])


func test_bots_4v4_second() -> void:
	var r := await _match(8, 22)
	_goals_4v4 += int(r[0])
	print("  blob_ball bots=8: %d goals over the 4v4 matches so far" % _goals_4v4)
	assert_true(_goals_4v4 >= 1, "bots score at least sometimes in 4v4 (%d goals)" % _goals_4v4)


func test_bots_1v1() -> void:
	await _series(2, [31])


func _teardown_round() -> void:
	if brain0:
		brain0.queue_free()
		brain0 = null
	if stage:
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
	players.clear()
	ranking = []
	Net.leave()
