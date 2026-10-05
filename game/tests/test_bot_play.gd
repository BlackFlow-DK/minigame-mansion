extends GameTest
## Bot brain in the real minigames: whole bot-only rounds, measured. Every slot (slot 0
## too) is driven by a BotBrain. Prints the numbers the tuning is judged by and asserts
## the targets: Floor Is Lava rounds last, Coin Scramble's floor does not sit at the cap,
## Hot Potato bombs are not ping-ponged between two blobs.

const CoinScramble := preload("res://minigames/coin_scramble/coin_scramble.gd")

var brain0: BotBrain = null


## Spawns a bot-only round of `id` with `count` players; everything seeded from `seed_value`.
func _bots(id: StringName, count: int, seed_value: int) -> Array[Player]:
	seed(seed_value)
	var ps := spawn_arena(count, id, false)
	(ps[0].get_component(&"controller") as ControllerComponent).scripted = true
	brain0 = BotBrain.new()
	brain0.player = ps[0]
	add_child(brain0)
	brain0.configure(seed_value * 31 + 7)
	return ps


## One frame with slot 0's brain driven by hand.
func _tick() -> void:
	await step(1, func(_i: int) -> void: brain0.fill_intent(players[0].intent, physics_delta()))


## Fraction of alive-bot frames spent (nearly) standing still, accumulated by the caller.
func _still_count(ps: Array[Player]) -> Vector2i:
	var still := 0
	var alive := 0
	for p in ps:
		if p.alive:
			alive += 1
			if Vector2(p.velocity.x, p.velocity.z).length() < 0.5:
				still += 1
	return Vector2i(still, alive)


# --- Floor Is Lava ------------------------------------------------------------------------------

## Returns [seconds, early_falls, shoved_falls, collapse_falls].
func _lava_round(count: int, seed_value: int) -> Array:
	var ps := _bots(&"floor_is_lava", count, seed_value)
	var g := get_minigame() as FloorIsLava
	var last_hit := {}
	var outs: Array = []  # [time, slot]
	var jumps := [0]
	for p in ps:
		p.jumped.connect(func() -> void: jumps[0] += 1)
		p.got_hit.connect(func(_imp: Vector3, src: int) -> void:
			if src >= 0:
				last_hit[p.slot] = g.elapsed)
		p.eliminated.connect(func(_r: StringName) -> void: outs.append([g.elapsed, p.slot]))
	var frames := 0
	var still := Vector2i.ZERO
	while not g.is_finished() and frames < 60 * 65:
		await _tick()
		still += _still_count(ps)
		frames += 1
	var early := 0
	var shoved := 0
	var late := 0
	for o: Array in outs:
		var t: float = o[0]
		var s: int = o[1]
		if last_hit.has(s) and t - float(last_hit[s]) < 2.0:
			shoved += 1
		elif t >= g.collapse_start:
			late += 1
		else:
			early += 1
	var secs := frames * physics_delta()
	print("  lava bots=%d seed=%d: %.1f s; falls: %d shoved, %d in the collapse, %d own mistakes; standing %.0f%%; %d jumps; knock-outs at %s" % [
		count, seed_value, secs, shoved, late, early, 100.0 * still.x / maxi(still.y, 1), jumps[0], str(outs.map(func(o: Array) -> String: return "%.1f" % o[0]))])
	assert_true(g.is_finished(), "round finished")
	assert_true(jumps[0] > 0, "bots jump on a crumbling floor")
	return [secs, early, shoved, late]


## Lava rounds now often run to the collapse (~37 s): split over three tests to stay inside the
## runner's per-test time limit; the last one judges all five.
static var _lava: Array = []   # [secs, early, falls] per round


func _lava_batch(seeds: Array) -> void:
	for s: int in seeds:
		var r := await _lava_round(8, s)
		_lava.append([r[0], r[1], r[1] + r[2] + r[3]])
		_teardown_round()


func test_lava_8_bots_last_a() -> void:
	_lava.clear()
	await _lava_batch([11, 12])


func test_lava_8_bots_last_b() -> void:
	await _lava_batch([13, 14])


func test_lava_8_bots_last() -> void:
	await _lava_batch([15])
	if _lava.size() < 5:
		print("  (only %d lava rounds: run the whole file to judge them)" % _lava.size())
		return
	var secs: Array[float] = []
	var early := 0
	var falls := 0
	for r: Array in _lava:
		secs.append(r[0])
		early += int(r[1])
		falls += int(r[2])
	secs.sort()
	var mean := 0.0
	for x in secs:
		mean += x / secs.size()
	var median := secs[secs.size() / 2]
	print("  lava mean %.1f s, median %.1f s, own mistakes %d of %d falls" % [mean, median, early, falls])
	assert_true(median >= 20.0, "8-bot lava rounds typically last 20 s (median %.1f s)" % median)
	assert_true(early * 2 < falls, "most falls come from shoves or the collapse (%d of %d own mistakes)" % [early, falls])


# --- Coin Scramble ------------------------------------------------------------------------------

## `hook`: emulate what Coin Scramble should do (request_bot_rethink when a coin appears
## or is taken), to show the brain's side of the hook.
func _coins(count: int, seed_value: int, hook: bool) -> float:
	var ps := _bots(&"coin_scramble", count, seed_value)
	var mg := get_minigame() as CoinScramble
	if hook:
		mg.coin_spawned.connect(func(_id: int) -> void: mg.request_bot_rethink())
		mg.coin_collected.connect(func(_id: int, _s: int) -> void: mg.request_bot_rethink())
	var frames := 0
	var at_cap := 0
	var sum := 0
	var still := Vector2i.ZERO
	var collected := watch(mg, &"coin_collected")
	while not mg.is_finished() and frames < 60 * 70:
		await _tick()
		var n := mg.coin_ids().size()
		sum += n
		if n >= mg.coin_cap:
			at_cap += 1
		still += _still_count(ps)
		frames += 1
	var cap_share := float(at_cap) / maxi(frames, 1)
	print("  coins bots=%d seed=%d hook=%s: %.1f s, mean floor coins %.1f (cap %d), at cap %.0f%% of the time, pickups %d, standing %.0f%%" % [
		count, seed_value, hook, frames * physics_delta(), float(sum) / maxi(frames, 1), mg.coin_cap, 100.0 * cap_share,
		collected.size(), 100.0 * still.x / maxi(still.y, 1)])
	assert_true(mg.is_finished(), "round finished")
	return cap_share


func test_coin_floor_not_at_cap() -> void:
	for count in [4, 8]:
		for hook in [false, true]:
			var share: float = await _coins(count, 5, hook)
			_teardown_round()
			assert_true(share < 0.25, "%d bots (hook %s): floor not sitting at the cap (%.0f%%)" % [count, hook, 100.0 * share])


# --- Hot Potato ---------------------------------------------------------------------------------

## `hook`: 0 none; 1 emulate what Hot Potato should do (request_bot_rethink on every new
## bomb and pass); 2 that plus a rethink every 0.5 s while a bomb is live (flee goals
## depend on where the holder is now). Returns [mean hold, quick pass-backs].
func _potato(seed_value: int, hook: int) -> Array:
	var ps := _bots(&"hot_potato", 8, seed_value)
	var mg := get_minigame() as HotPotato
	mg.rng.seed = seed_value
	if hook >= 1:
		mg.bomb_given.connect(func(_s: int) -> void: mg.request_bot_rethink())
		mg.bomb_passed.connect(func(_f: int, _to: int, _k: int) -> void: mg.request_bot_rethink())
	var t := [0.0]
	var since := [0.0]
	var holds: Array[float] = []
	var backs := [0]
	var last_from := [-1]
	mg.bomb_given.connect(func(_s: int) -> void:
		since[0] = t[0]
		last_from[0] = -1)
	mg.bomb_passed.connect(func(from: int, to: int, _k: int) -> void:
		var held: float = t[0] - since[0]
		holds.append(held)
		if to == last_from[0] and held < 1.5:
			backs[0] += 1
		since[0] = t[0]
		last_from[0] = from)
	var frames := 0
	var still := Vector2i.ZERO
	while not mg.is_finished() and frames < 60 * 150:
		await _tick()
		t[0] += physics_delta()
		still += _still_count(ps)
		frames += 1
		if hook >= 2 and frames % 30 == 0 and mg.holder_slot >= 0:
			mg.request_bot_rethink()
	var mean := 0.0
	for h in holds:
		mean += h
	mean /= maxf(holds.size(), 1)
	print("  potato bots=8 seed=%d hook=%d: %.1f s, %d passes, mean hold %.2f s, %d quick pass-backs, standing %.0f%%" % [
		seed_value, hook, frames * physics_delta(), holds.size(), mean, backs[0], 100.0 * still.x / maxi(still.y, 1)])
	assert_true(mg.is_finished(), "round finished")
	holds.sort()
	print("    holds: %s" % str(holds.map(func(h: float) -> String: return "%.1f" % h)))
	return [mean, backs[0]]


func _potato_series(hook: int) -> Vector2:
	var mean := 0.0
	var backs := 0
	for s in [3, 4, 5]:
		var r: Array = await _potato(s, hook)
		_teardown_round()
		mean += float(r[0]) / 3.0
		backs += int(r[1])
	print("  potato hook=%d: mean hold %.2f s over 3 rounds, %d quick pass-backs" % [hook, mean, backs])
	return Vector2(mean, backs)


func test_potato_holds_last() -> void:
	var r := await _potato_series(0)
	assert_true(r.x > 1.0, "holders keep the bomb a while (mean %.2f s)" % r.x)


func test_potato_rethink_hook_stops_ping_pong() -> void:
	var r := await _potato_series(1)
	assert_true(r.x > 1.3, "with the rethink hook holders keep it longer (mean %.2f s)" % r.x)
	assert_true(r.y <= 3.0, "few quick pass-backs with the hook (%d)" % r.y)


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
