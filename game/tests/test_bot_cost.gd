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


func test_cost_floor_is_lava() -> void:
	var us := await _measure(&"floor_is_lava", 8, 900, 3)
	assert_true(us < CEILING_US, "%.1f us per think" % us)


func test_cost_mansion_dash() -> void:
	var us := await _measure(&"mansion_dash", 8, 900, 4)
	assert_true(us < CEILING_US, "%.1f us per think" % us)


func test_cost_bumper_sumo() -> void:
	var us := await _measure(&"bumper_sumo", 8, 900, 5)
	assert_true(us < CEILING_US, "%.1f us per think" % us)
