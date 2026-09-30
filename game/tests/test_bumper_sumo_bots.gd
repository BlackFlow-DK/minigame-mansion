extends GameTest
## Bumper Sumo bot-only rounds: every slot (slot 0 too, via its own BotBrain) is a bot.
## Each round must finish with a valid ranking (every slot exactly once); the length is
## printed so the tuning can be judged (target: typically 25-55 s) and must fall between
## 15 s (not everyone out at once) and the time limit (bots do fall).

const ID := &"bumper_sumo"
const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"


## Runs one bot-only round; returns the round length in seconds (-1 if it never finished).
func _bot_round(count: int, seed_value: int) -> float:
	var ps := spawn_arena(count, ID, false)
	var m := get_minigame() as BumperSumo
	m.goal_seed = seed_value
	m._start()  # re-seed the goal picks (the harness already called _start once)
	for p in ps:
		var ctrl := p.get_component(&"controller") as ControllerComponent
		var brain: BotBrain = ctrl.brain as BotBrain
		if p.slot == 0:
			ctrl.scripted = true
			brain = (load(BOT_BRAIN_PATH) as GDScript).new() as BotBrain
			brain.player = p
			brain.name = "TestBrain"
			add_child(brain)
		brain.configure(seed_value * 97 + p.slot * 13)
	var out_times: Array[String] = []
	for p in ps:
		p.eliminated.connect(func(_r: StringName) -> void: out_times.append("%.1f" % m.elapsed))
	var human := ps[0]
	var human_brain := get_node(^"TestBrain") as BotBrain
	var dt := physics_delta()
	var frames := 0
	var limit := int((m.time_limit + 2.0) / dt)
	while not m.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void: human_brain.fill_intent(human.intent, dt))
		frames += 1
	human_brain.queue_free()
	if not assert_true(m.is_finished(), "round finished"):
		return -1.0
	var seconds := m.elapsed
	assert_eq(ranking.size(), count, "every slot ranked")
	for s in count:
		assert_eq(ranking.count(s), 1, "slot %d exactly once" % s)
	assert_true(seconds >= 15.0, "bots do not all fall at once (%.1f s)" % seconds)
	assert_true(seconds < m.time_limit, "bots ring each other out before the time limit (%.1f s)" % seconds)
	print("  sumo bots=%d seed=%d: %.1f s, ranking %s, knock-outs at %s s" % [count, seed_value, seconds, ranking, ", ".join(out_times)])
	return seconds


func test_4_bots_seed_1() -> void:
	await _bot_round(4, 1)


func test_4_bots_seed_2() -> void:
	await _bot_round(4, 2)


func test_4_bots_seed_3() -> void:
	await _bot_round(4, 3)


func test_8_bots_seed_1() -> void:
	await _bot_round(8, 1)


func test_8_bots_seed_2() -> void:
	await _bot_round(8, 2)


func test_8_bots_seed_3() -> void:
	await _bot_round(8, 3)
