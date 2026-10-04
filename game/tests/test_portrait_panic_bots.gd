extends GameTest
## Portrait Panic bot-only rounds: every slot (slot 0 too, via its own BotBrain) is a bot.
## Each round must end with a valid ranking (every slot once, tied groups allowed) in 30-75 s,
## with eliminations spread over several loops (not everyone in loop 1, not nobody for a
## minute). The numbers are printed so the pacing can be judged. Plus a slot-bias check over
## 12 seeded 4-bot rounds at time scale 2 (the phase clock runs twice as fast, the walking
## does not).

const ID := &"portrait_panic"


## One bot-only round. Returns {seconds, groups, falls_per_loop (loop -> count), first_fall_s, loops}.
func _bot_round(count: int, seed_value: int, scale: float = 1.0, quiet: bool = false) -> Dictionary:
	seed(seed_value)  # the spawn turn and anything else drawn from the global RNG
	var ps := spawn_arena(count, ID, false)
	var g := get_minigame() as PortraitPanic
	g.rng.seed = seed_value
	g.bot_rng.seed = seed_value * 31 + 7
	g.time_scale = scale
	var brain0 := BotBrain.new()
	brain0.player = ps[0]
	brain0.minigame = g
	add_child(brain0)
	brain0.configure(seed_value * 100)
	(ps[0].get_component(&"controller") as ControllerComponent).scripted = true
	for p in ps:
		var c := p.get_component(&"controller") as ControllerComponent
		if c.brain:
			(c.brain as BotBrain).configure(seed_value * 100 + p.slot)
	var falls := watch(g, &"player_fell")
	if OS.get_environment("PP_DEBUG") != "":
		g.player_fell.connect(func(slot: int, idx: int) -> void:
			var p := stage.get_player(slot)
			var hit := p.control_locked
			print("    fall slot %d loop %d phase %d clock %.2f local %s locked %s" % [slot, idx, g.phase, g.phase_clock, str(g.to_local(p.global_position)), hit]))
	var frames := 0
	var limit := int((g.time_limit + 2.0) / physics_delta())
	var first_fall := -1.0
	while not g.is_finished() and frames < limit:
		await step(1, func(_i: int) -> void: brain0.fill_intent(ps[0].intent, physics_delta()))
		frames += 1
		if first_fall < 0.0 and not falls.is_empty():
			first_fall = frames * physics_delta()
	brain0.queue_free()
	var seconds := frames * physics_delta()
	var per_loop: Dictionary = {}
	for e: Array in falls:
		per_loop[e[1]] = int(per_loop.get(e[1], 0)) + 1
	var out := {"seconds": seconds, "groups": g.finish_groups.duplicate(true), "per_loop": per_loop,
		"first_fall": first_fall, "loops": g.loop_index + 1}
	if not assert_true(g.is_finished(), "%d bots, seed %d: round finished" % [count, seed_value]):
		return out
	var flat := Minigame.flatten_groups(g.finish_groups)
	flat.sort()
	var all: Array[int] = []
	for i in count:
		all.append(i)
	assert_eq(flat, all, "every slot exactly once")
	if not quiet:
		print("  portrait bots=%d seed=%d: %.1f s, %d loops, falls per loop %s, first fall %.1f s, groups %s" % [
			count, seed_value, seconds, out["loops"], str(per_loop), first_fall, str(g.finish_groups)])
	return out


func _check_pacing(r: Dictionary, count: int) -> void:
	var seconds: float = r["seconds"]
	assert_true(seconds >= 30.0 and seconds <= 75.0, "round length %.1f s in 30-75 s" % seconds)
	var per_loop: Dictionary = r["per_loop"]
	assert_true(per_loop.size() >= 2, "eliminations spread over %d loops (want >= 2)" % per_loop.size())
	assert_true(int(per_loop.get(0, 0)) < count - 1, "not everyone out in loop 1 (%d)" % int(per_loop.get(0, 0)))
	assert_true(float(r["first_fall"]) >= 0.0 and float(r["first_fall"]) < 45.0, "someone falls before 45 s (%.1f)" % float(r["first_fall"]))


func test_4_bots_seed_1() -> void:
	_check_pacing(await _bot_round(4, 1), 4)


func test_4_bots_seed_2() -> void:
	_check_pacing(await _bot_round(4, 2), 4)


func test_8_bots_seed_1() -> void:
	_check_pacing(await _bot_round(8, 1), 8)


func test_8_bots_seed_2() -> void:
	_check_pacing(await _bot_round(8, 2), 8)


func test_no_slot_bias_over_12_rounds() -> void:
	var wins: Array[int] = [0, 0, 0, 0]
	var total := 0.0
	for k in 12:
		var r := await _bot_round(4, 100 + k, 2.0, OS.get_environment("PP_DEBUG") == "")
		var groups: Array = r["groups"]
		if not groups.is_empty():
			for s: int in groups[0]:
				wins[s] += 1
		total += float(r["seconds"])
		_teardown_round()
	print("  portrait 12 x 4 bots (scale 2): first-place finishes per slot %s, mean %.1f s" % [wins, total / 12.0])
	for s in 4:
		assert_true(wins[s] <= 6, "slot %d won %d of 12" % [s, wins[s]])


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
