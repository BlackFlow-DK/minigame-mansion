extends GameTest
## Bot brain hooks: the action hook (reaction delay, cooldown, the default shove off), the aim
## hook (the bot faces the aim point before pressing, aim error by skill, a reach to close in
## first), the hold reaction (late to stop, late to go, `bot_reaction_scale`), extras (no hooks
## unless the minigame opts in), allies, determinism and the difficulty knob.


## A minigame with hooks the test drives; it counts the calls and remembers the first yes.
class HookGame extends Minigame:
	var goal: Vector3 = Vector3.ZERO
	var want: bool = false
	var aim: Vector3 = Vector3.ZERO
	var cooldown: float = 0.0
	var asked: int = 0
	var first_yes: int = -1   # `clock` (ticks) when bot_wants_action first answered true
	var clock: int = 0

	func get_bot_goal(_player: Player) -> Vector3:
		return goal

	func bot_wants_action(_player: Player) -> bool:
		asked += 1
		if want and first_yes < 0:
			first_yes = clock
		return want

	func bot_aim(_player: Player) -> Vector3:
		return aim

	func bot_action_cooldown() -> float:
		return cooldown


class ReachGame extends HookGame:
	func bot_action_reach() -> float:
		return 1.2


class HoldGame extends Minigame:
	var goal: Vector3 = Vector3.ZERO
	var hold: bool = false
	var bot_reaction_scale: float = 1.0

	func get_bot_goal(_player: Player) -> Vector3:
		return goal

	func bot_should_hold(_player: Player) -> bool:
		return hold


class AllyGame extends Minigame:
	var ally_slot: int = -1

	func get_bot_goal(p: Player) -> Vector3:
		return p.global_position

	func is_ally(a: Player, b: Player) -> bool:
		return b.slot == ally_slot or a.slot == ally_slot


class ExtraHookGame extends HookGame:
	var bot_extra_hooks: bool = true


## Four players parked apart in a corner of the dev floor; ps[1] (the bot under test) at the
## origin facing +Z.
func _world(game: Minigame) -> Array[Player]:
	var ps := spawn_arena(4)
	add_child(game)
	game.players = ps
	for i in ps.size():
		_put(ps[i], Vector3(-8.0, 0.0, -8.0 + 3.0 * i))
	_put(ps[1], Vector3.ZERO)
	return ps


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))


func _brain(p: Player, game: Minigame, seed_value: int, skill: float = -1.0, aggression: float = 0.0) -> BotBrain:
	var b := BotBrain.new()
	b.player = p
	b.minigame = game
	add_child(b)
	b.configure(seed_value, skill, aggression)
	return b


## Drives `b` for `ticks` physics frames (the player really moves and turns); one record per tick.
func _drive(b: BotBrain, ticks: int, game: HookGame = null) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	await step(ticks, func(_i: int) -> void:
		if game:
			game.clock += 1
		b.fill_intent(b.player.intent, physics_delta())
		out.append({ "move": b.player.intent.move, "action": b.player.intent.action_pressed,
			"facing": b.player.facing, "pos": b.player.global_position, "held": b.is_held() }))
	return out


func _press_ticks(recs: Array[Dictionary]) -> Array[int]:
	var out: Array[int] = []
	for i in recs.size():
		if recs[i]["action"]:
			out.append(i)
	return out


# --- Action hook ---------------------------------------------------------------------------------

func test_action_hook_presses_after_the_reaction_delay() -> void:
	for skill: float in [0.0, 1.0]:
		var g := HookGame.new()
		g.goal = Vector3.ZERO
		g.want = true
		var ps := _world(g)
		var b := _brain(ps[1], g, 41, skill)
		var recs := await _drive(b, 120, g)
		var presses := _press_ticks(recs)
		assert_true(presses.size() >= 1, "skill %s: pressed" % skill)
		if presses.is_empty():
			continue
		var waited := (presses[0] + 1 - g.first_yes) * physics_delta()
		var least := lerpf(BotBrain.ACTION_REACTION.x, BotBrain.ACTION_REACTION.y, skill) * 0.8
		assert_true(waited >= least - physics_delta(), "skill %s: waited %.2f s >= %.2f s" % [skill, waited, least])
		assert_true(waited <= least * 1.6 + 0.05, "skill %s: and not much longer (%.2f s)" % [skill, waited])
		for i in range(1, recs.size()):
			assert_false(recs[i]["action"] and recs[i - 1]["action"], "a one-tick edge")
		_clear(g)


func test_action_hook_cooldown_spaces_presses() -> void:
	var g := HookGame.new()
	g.want = true
	g.cooldown = 1.0
	var ps := _world(g)
	var b := _brain(ps[1], g, 42, 1.0)
	var presses := _press_ticks(await _drive(b, 240, g))
	assert_true(presses.size() >= 2, "pressed again after the cooldown (%d)" % presses.size())
	for i in range(1, presses.size()):
		var gap := (presses[i] - presses[i - 1]) * physics_delta()
		assert_true(gap >= 1.0 - 0.001, "presses %.2f s apart (cooldown 1 s)" % gap)
	assert_eq(b.acts, presses.size(), "acts counts the presses")


func test_action_hook_no_means_no_press_and_no_default_shove() -> void:
	var g := HookGame.new()
	g.want = false
	var ps := _world(g)
	_put(ps[2], Vector3(0.0, 0.0, 1.0))  # an enemy right in front: the default would shove
	var b := _brain(ps[1], g, 43, 1.0, 1.0)
	var presses := _press_ticks(await _drive(b, 180, g))
	assert_eq(presses.size(), 0, "the hook said no: no press, no default shove")
	assert_true(g.asked >= 3, "the hook was asked every think (%d)" % g.asked)


func test_without_the_hook_the_default_shove_stays() -> void:
	var g := AllyGame.new()
	var ps := _world(g)
	_put(ps[2], Vector3(0.0, 0.0, 1.0))
	var b := _brain(ps[1], g, 44, 0.8, 0.0)
	var presses := _press_ticks(_run(b, 120))
	assert_true(presses.size() >= 1, "shoves the enemy in front")


func test_no_shove_with_an_ally_in_front() -> void:
	var g := AllyGame.new()
	var ps := _world(g)
	g.ally_slot = 3
	_put(ps[2], Vector3(0.0, 0.0, 1.0))   # enemy in front
	_put(ps[3], Vector3(0.25, 0.0, 0.9))  # and an ally right beside it
	var b := _brain(ps[1], g, 45, 0.8, 1.0)
	assert_eq(_press_ticks(_run(b, 120)).size(), 0, "never shoves with an ally in front")
	g.ally_slot = -1
	var b2 := _brain(ps[1], g, 45, 0.8, 1.0)
	assert_true(_press_ticks(_run(b2, 120)).size() >= 1, "the same two as enemies: shoves")


## Runs the brain `ticks` times without stepping physics (positions and facing stay put).
func _run(b: BotBrain, ticks: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var intent := PlayerIntent.new()
	for i in ticks:
		b.fill_intent(intent, physics_delta())
		out.append({ "move": intent.move, "action": intent.action_pressed })
	return out


# --- Aim hook ----------------------------------------------------------------------------------

## Angle (deg) between the facing at each press and the true direction to the aim point.
func _aim_errors(skill: float, seed_value: int, acts: int) -> Array[float]:
	var g := HookGame.new()
	g.want = true
	g.cooldown = 0.3
	var ps := _world(g)
	var b := _brain(ps[1], g, seed_value, skill)
	var errs: Array[float] = []
	var k := 0
	var ticks := 0
	while errs.size() < acts and ticks < 60 * 40:
		# A new aim point around the bot after each press.
		var a := TAU * (0.37 * k + 0.1)
		g.aim = ps[1].global_position + Vector3(cos(a), 0.0, sin(a)) * 4.0
		var pressed := false
		while not pressed and ticks < 60 * 40:
			ticks += 1
			await step(1, func(_i: int) -> void: b.fill_intent(ps[1].intent, physics_delta()))
			if ps[1].intent.action_pressed:
				pressed = true
				var want := Vector2(g.aim.x - ps[1].global_position.x, g.aim.z - ps[1].global_position.z).normalized()
				var face := Vector2(ps[1].facing.x, ps[1].facing.z).normalized()
				errs.append(rad_to_deg(absf(face.angle_to(want))))
		k += 1
	_clear(g)
	return errs


func test_aim_hook_faces_before_pressing_with_skill_based_error() -> void:
	var sharp := await _aim_errors(1.0, 51, 16)
	var clumsy := await _aim_errors(0.0, 52, 16)
	var mean := func(xs: Array[float]) -> float:
		var s := 0.0
		for x in xs:
			s += x
		return s / maxf(xs.size(), 1.0)
	var ms: float = mean.call(sharp)
	var mc: float = mean.call(clumsy)
	print("  aim error: sharp %.1f deg %s, clumsy %.1f deg %s" % [ms, str(sharp.map(func(x: float) -> int: return roundi(x))),
		mc, str(clumsy.map(func(x: float) -> int: return roundi(x)))])
	assert_eq(sharp.size(), 16, "a sharp bot pressed 16 times")
	assert_eq(clumsy.size(), 16, "a clumsy bot pressed 16 times")
	var worst := 0.0
	for x in sharp:
		worst = maxf(worst, x)
	assert_true(worst <= BotBrain.ACT_AIM_ERROR_DEG.y + BotBrain.AIM_TOLERANCE_DEG + 1.0, "sharp: faced the aim (worst %.1f deg)" % worst)
	assert_true(ms < 6.0, "sharp aim is tight (%.1f deg)" % ms)
	assert_true(mc > ms + 1.5, "clumsy aim is worse (%.1f vs %.1f deg)" % [mc, ms])
	for x in clumsy:
		assert_true(x <= BotBrain.ACT_AIM_ERROR_DEG.x + BotBrain.AIM_TOLERANCE_DEG + 1.0, "clumsy error bounded (%.1f deg)" % x)


func test_aim_reach_closes_in_first() -> void:
	var g := ReachGame.new()
	g.want = true
	g.aim = Vector3(5.0, 0.0, 0.0)
	var ps := _world(g)
	var b := _brain(ps[1], g, 53, 1.0)
	var recs := await _drive(b, 240, g)
	var presses := _press_ticks(recs)
	assert_true(presses.size() >= 1, "pressed once close")
	if presses.is_empty():
		return
	var at: Vector3 = recs[presses[0]]["pos"]
	var d := Vector2(at.x - 5.0, at.z).length()
	assert_true(d <= 1.3, "pressed within reach (%.2f m from the aim point)" % d)


# --- Hold reaction -----------------------------------------------------------------------------

## Ticks until a held/unheld brain's intent changes after the hold answer flips at tick 0.
func _hold_lag(skill: float, scale: float, seed_value: int) -> Vector2:
	var g := HoldGame.new()
	g.goal = Vector3(0.0, 0.0, 30.0)
	g.bot_reaction_scale = scale
	var ps := _world(g)
	var b := _brain(ps[1], g, seed_value, skill)
	await _drive(b, 60)
	assert_false(b.is_held(), "walking")
	g.hold = true
	var recs := await _drive(b, 120)
	var stop := recs.find_custom(func(r: Dictionary) -> bool: return r["held"])
	assert_true(b.is_held(), "held in the end")
	for i in range(maxi(stop, 0), recs.size()):
		assert_eq(recs[i]["move"], Vector2.ZERO, "held: no move")
	g.hold = false
	recs = await _drive(b, 120)
	var go := recs.find_custom(func(r: Dictionary) -> bool: return not r["held"])
	_clear(g)
	return Vector2(stop + 1, go + 1) * physics_delta()


func test_hold_is_noticed_after_a_reaction() -> void:
	for skill: float in [0.0, 1.0]:
		var lag := await _hold_lag(skill, 1.0, 61)
		var stop_min := lerpf(BotBrain.HOLD_STOP.x, BotBrain.HOLD_STOP.y, skill)
		var go_min := lerpf(BotBrain.HOLD_GO.x, BotBrain.HOLD_GO.y, skill)
		print("  hold lag skill %.0f: stop %.2f s (>= %.2f), go %.2f s (>= %.2f)" % [skill, lag.x, stop_min, lag.y, go_min])
		assert_true(lag.x >= stop_min - physics_delta() and lag.x <= stop_min + BotBrain.HOLD_STOP_JITTER + 0.05, "skill %s: late to stop (%.2f s)" % [skill, lag.x])
		assert_true(lag.y >= go_min - physics_delta() and lag.y <= go_min + BotBrain.HOLD_GO_JITTER + 0.6, "skill %s: late to go (%.2f s)" % [skill, lag.y])
	var fast := await _hold_lag(0.0, 0.5, 61)
	var slow := await _hold_lag(0.0, 1.0, 61)
	assert_near(fast.x, slow.x * 0.5, 0.05, "bot_reaction_scale halves the stop lag")


# --- Extras ------------------------------------------------------------------------------------

func test_extras_poll_no_hooks_unless_opted_in() -> void:
	var g := HookGame.new()
	g.want = true
	var ps := _world(g)
	var x := ps[2]
	_put(x, Vector3(4.0, 0.0, 4.0))
	x.is_extra = true
	var b := _brain(x, g, 71)
	b.configure_extra(&"wander", 71)
	await _drive(b, 120, g)
	assert_eq(g.asked, 0, "an extra never asks the action hook")
	assert_eq(b.acts, 0, "nor presses")
	x.is_extra = false
	b.configure_extra(&"wander", 72)
	await _drive(b, 120, g)
	assert_true(g.asked > 0, "a real player posing as an NPC asks it (%d)" % g.asked)
	assert_true(b.acts >= 1, "and acts on it")
	_clear(g)
	var g2 := ExtraHookGame.new()
	g2.want = true
	var ps2 := _world(g2)
	ps2[2].is_extra = true
	var b2 := _brain(ps2[2], g2, 73)
	b2.configure_extra(&"dance", 73, Vector3(2.0, 0.0, 2.0))
	await _drive(b2, 120, g2)
	assert_true(g2.asked > 0, "an opted-in minigame's extras ask it (%d)" % g2.asked)


# --- Determinism, difficulty ---------------------------------------------------------------------

func test_same_seed_same_acts() -> void:
	var runs: Array = []
	for k in 2:
		var g := HookGame.new()
		g.want = true
		g.cooldown = 0.4
		g.aim = Vector3(3.0, 0.0, 2.0)
		g.goal = Vector3(-2.0, 0.0, 4.0)
		var ps := _world(g)
		var b := _brain(ps[1], g, 81)
		var recs := await _drive(b, 240, g)
		runs.append(recs.map(func(r: Dictionary) -> Array: return [r["move"], r["action"]]))
		_clear(g)
	assert_eq(runs[0], runs[1], "same seed, same intents and presses")


func test_difficulty_maps_onto_skill_ranges() -> void:
	assert_eq(BotBrain.skill_range(0.5), BotBrain.SKILL_NORMAL, "0.5 is the normal spread")
	assert_eq(BotBrain.skill_range(0.0), BotBrain.SKILL_EASY, "0 easy")
	assert_eq(BotBrain.skill_range(1.0), BotBrain.SKILL_HARD, "1 hard")
	var ps := spawn_arena(2)
	var b := BotBrain.new()
	b.player = ps[1]
	add_child(b)
	var means: Array[float] = []
	var saved := BotBrain.difficulty
	for d: float in [0.0, 0.5, 1.0]:
		BotBrain.difficulty = d
		var s := 0.0
		for i in 40:
			b.configure(1000 + i)
			var r := BotBrain.skill_range(d)
			assert_true(b.skill >= r.x and b.skill <= r.y, "difficulty %.1f: skill %.2f in range" % [d, b.skill])
			s += b.skill / 40.0
		means.append(s)
	BotBrain.difficulty = saved
	assert_true(means[0] < means[1] and means[1] < means[2], "harder difficulty, sharper bots %s" % [means])
	b.configure(5, 0.3)
	assert_near(b.skill, 0.3, 0.0001, "an explicit skill is kept")


func _clear(g: Minigame) -> void:
	for c in get_children():
		if c is BotBrain:
			c.queue_free()
	if stage:
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
	players.clear()
	Net.leave()
	if is_instance_valid(g):
		g.queue_free()
