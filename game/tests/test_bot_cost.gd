extends GameTest
## Bot brain cost: microseconds per `fill_intent` call (one think-or-tick of one bot), measured
## over bot-only stretches of real minigames with every slot driven by hand. Prints the numbers
## (the per-think budget is judged from them: the brain may not get more than ~25 % slower than
## before a change) and asserts only a generous ceiling, so a loaded machine does not flake.

const CEILING_US := 400.0


## Mean microseconds per fill_intent over `frames` frames of `id` with `count` bots.
func _measure(id: StringName, count: int, frames: int, seed_value: int) -> float:
	seed(seed_value)
	var ps := spawn_arena(count, id, true)
	var brains: Array[BotBrain] = []
	for p in ps:
		var b := BotBrain.new()
		b.player = p
		add_child(b)
		b.configure(seed_value * 13 + p.slot)
		brains.append(b)
	var spent := [0]
	var calls := [0]
	var dt := physics_delta()
	await step(frames, func(_i: int) -> void:
		for b in brains:
			var t0 := Time.get_ticks_usec()
			b.fill_intent(b.player.intent, dt)
			spent[0] += Time.get_ticks_usec() - t0
			calls[0] += 1)
	for b in brains:
		b.queue_free()
	var us := float(spent[0]) / maxf(float(calls[0]), 1.0)
	print("  bot cost %s bots=%d: %.1f us per fill_intent over %d calls" % [id, count, us, calls[0]])
	return us


## Per physics frame: every brain's fill_intent time summed and the `is_safe` calls it made (bots
## through their controllers, extras too), with the brain budget on or off. Returns
## [mean ms, p99 ms, max ms, mean calls, p99 calls, max calls] over `frames` frames.
func _frame_load(id: StringName, frames: int, seed_value: int, budget: bool) -> Array:
	seed(seed_value)
	spawn_arena(8, id, false)
	BotBrain.profile_frames.clear()
	BotBrain.profile_calls.clear()
	BotBrain.budget_enabled = budget
	BotBrain.profile = true
	await step(frames)
	BotBrain.profile = false
	BotBrain.budget_enabled = true
	var t := _stats(BotBrain.profile_frames.values(), 0.001)
	var c := _stats(BotBrain.profile_calls.values(), 1.0)
	print("  brains %s, budget %s (8 players, %d frames): %.2f ms mean, p99 %.2f, max %.2f; is_safe calls per frame mean %.0f, p99 %.0f, max %.0f" % [
		id, "on" if budget else "off", frames, t[0], t[1], t[2], c[0], c[1], c[2]])
	if stage:
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
	players.clear()
	Net.leave()
	return t + c


static func _stats(values: Array, scale: float) -> Array:
	if values.is_empty():
		return [0.0, 0.0, 0.0]
	values.sort()
	var mean := 0.0
	for x: int in values:
		mean += x * scale / values.size()
	return [mean, values[int(values.size() * 0.99)] * scale, values[-1] * scale]


func _load_ab(id: StringName) -> void:
	var off: Array = await _frame_load(id, 600, 7, false)
	var on: Array = await _frame_load(id, 600, 7, true)
	assert_true(float(on[4]) <= float(off[4]) * 1.1 + 5.0, "%s: the budget does not add is_safe calls (p99 %d vs %d)" % [id, on[4], off[4]])
	assert_true(float(on[4]) <= 400.0 and float(on[5]) <= 600.0, "%s: is_safe calls per frame p99 %d (<= 400), max %d (<= 600)" % [id, on[4], on[5]])


func test_frame_load_portrait_panic() -> void:
	await _load_ab(&"portrait_panic")


func test_frame_load_rising_tide() -> void:
	await _load_ab(&"rising_tide")


func test_frame_load_floor_is_lava() -> void:
	await _load_ab(&"floor_is_lava")


func test_frame_load_masquerade() -> void:
	await _load_ab(&"masquerade")

func test_cost_floor_is_lava() -> void:
	var us := await _measure(&"floor_is_lava", 8, 900, 3)
	assert_true(us < CEILING_US, "%.1f us per think" % us)


func test_cost_mansion_dash() -> void:
	var us := await _measure(&"mansion_dash", 8, 900, 4)
	assert_true(us < CEILING_US, "%.1f us per think" % us)


func test_cost_bumper_sumo() -> void:
	var us := await _measure(&"bumper_sumo", 8, 900, 5)
	assert_true(us < CEILING_US, "%.1f us per think" % us)
