extends GameTest
## Bot brain: asserts on the INTENT the brain produces for constructed situations
## (movement/jump/shove are other systems). Brains are driven by hand with fill_intent;
## the arena is spawned scripted, so the controllers leave intents alone.


## A minigame with a fixed goal and an unsafe band min_x < x < max_x.
class FakeGame extends Minigame:
	var goal: Vector3 = Vector3.ZERO
	var unsafe_min_x: float = INF
	var unsafe_max_x: float = INF

	func get_bot_goal(_player: Player) -> Vector3:
		return goal

	func is_safe(pos: Vector3) -> bool:
		return not (pos.x > unsafe_min_x and pos.x < unsafe_max_x)


var game: FakeGame


## Four players parked far apart; returns them. ps[1] is the bot under test (at the origin).
func _world() -> Array[Player]:
	var ps := spawn_arena(4)
	game = FakeGame.new()
	add_child(game)
	game.players = ps
	for i in ps.size():
		_put(ps[i], Vector3(30.0 + 6.0 * i, 0.0, 30.0))
	_put(ps[1], Vector3.ZERO)
	return ps


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))  # facing +Z


func _brain(p: Player, seed_value: int, skill: float = -1.0, aggression: float = -1.0) -> BotBrain:
	var b := BotBrain.new()
	b.player = p
	b.minigame = game
	add_child(b)
	b.configure(seed_value, skill, aggression)
	return b


## Runs the brain `ticks` times without stepping physics; one record per tick.
func _run(b: BotBrain, ticks: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var intent := PlayerIntent.new()
	for i in ticks:
		b.fill_intent(intent, physics_delta())
		out.append({ "move": intent.move, "jump": intent.jump_pressed, "held": intent.jump_held, "action": intent.action_pressed })
	return out


func _actions(records: Array[Dictionary]) -> int:
	var n := 0
	for r in records:
		if r["action"]:
			n += 1
	return n


func test_moves_toward_goal() -> void:
	var ps := _world()
	game.goal = Vector3(6.0, 0.0, 3.0)
	var want := Vector2(6.0, 3.0).normalized()
	var recs := _run(_brain(ps[1], 11, 1.0, 0.0), 90)
	for r in recs.slice(60):
		var m: Vector2 = r["move"]
		assert_true(m.length() > 0.5, "moves with purpose (%s)" % m)
		assert_true(m.normalized().dot(want) > 0.95, "heads for the goal (%s)" % m)


func test_stops_near_goal() -> void:
	var ps := _world()
	game.goal = Vector3(0.3, 0.0, 0.2)
	var recs := _run(_brain(ps[1], 12, 1.0, 0.0), 90)
	for r in recs.slice(30):
		assert_near(r["move"], Vector2.ZERO, 0.001, "stands at the goal")


func test_shoves_enemy_in_front_within_range() -> void:
	var ps := _world()
	game.goal = Vector3.ZERO
	_put(ps[2], Vector3(0.0, 0.0, 1.0))  # right in front (facing +Z)
	var recs := _run(_brain(ps[1], 13, 0.5, 0.0), 120)
	assert_true(_actions(recs) >= 1, "shoves the enemy in front")
	for i in range(1, recs.size()):
		assert_false(recs[i]["action"] and recs[i - 1]["action"], "action_pressed is a one-tick edge")


func test_no_shove_when_enemy_not_in_front_or_far() -> void:
	var ps := _world()
	game.goal = Vector3.ZERO
	for spot: Vector3 in [Vector3(0.0, 0.0, -1.0), Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 3.0)]:
		_put(ps[2], spot)
		var recs := _run(_brain(ps[1], 14, 0.5, 0.0), 120)
		assert_eq(_actions(recs), 0, "no shove with the enemy at %s" % spot)


class CalmGame extends FakeGame:
	var bot_aggression_scale: float = 0.0


func test_aggression_scale_zero_never_shoves() -> void:
	var ps := _world()
	var calm := CalmGame.new()
	add_child(calm)
	calm.players = ps
	_put(ps[2], Vector3(0.0, 0.0, 1.0))  # right in front
	var b := BotBrain.new()
	b.player = ps[1]
	b.minigame = calm
	add_child(b)
	b.configure(13, 0.5, 1.0)
	assert_eq(_actions(_run(b, 120)), 0, "a calm minigame gets no shoves")


func test_steers_away_from_unsafe_edge() -> void:
	var ps := _world()
	game.goal = Vector3(6.0, 0.0, 0.0)
	game.unsafe_min_x = 1.0  # everything past x = 1 is unsafe, no far side to jump to
	_put(ps[1], Vector3(0.6, 0.0, 0.0))
	for skill: float in [0.0, 1.0]:
		var recs := _run(_brain(ps[1], 15, skill, 0.0), 120)
		var moving := 0
		for r in recs:
			var m: Vector2 = r["move"]
			# Within its lookahead (0.9 m at skill 0) the bot may only drift to x <= 1.0.
			assert_true(0.6 + m.x * 0.9 <= 1.001, "never heads off the edge (skill %s, move %s)" % [skill, m])
			if m.length() > 0.3:
				moving += 1
		assert_true(moving > 30, "steers along instead of freezing (skill %s)" % skill)


func test_backs_off_unsafe_ground() -> void:
	var ps := _world()
	game.goal = Vector3(6.0, 0.0, 0.0)
	game.unsafe_min_x = 1.0
	_put(ps[1], Vector3(1.5, 0.0, 0.0))  # standing on unsafe ground
	var recs := _run(_brain(ps[1], 16, 0.5, 0.0), 90)
	for r in recs.slice(60):
		var m: Vector2 = r["move"]
		assert_true(m.x < -0.3 and m.length() > 0.5, "heads back to safe ground (%s)" % m)


func test_keeps_course_over_small_gap() -> void:
	var ps := _world()
	game.goal = Vector3(6.0, 0.0, 0.0)
	game.unsafe_min_x = 1.0
	game.unsafe_max_x = 1.8  # a 0.8 m gap with safe ground behind it
	_put(ps[1], Vector3(0.3, 0.0, 0.0))
	var recs := _run(_brain(ps[1], 17, 1.0, 0.0), 90)
	for r in recs.slice(60):
		var m: Vector2 = r["move"]
		assert_true(m.x > 0.7, "commits to the gap instead of turning away (%s)" % m)


func test_recovers_after_knock() -> void:
	var ps := _world()
	game.goal = Vector3(6.0, 0.0, 0.0)
	var b := _brain(ps[1], 18, 0.8, 0.0)
	_run(b, 60)
	ps[1].velocity = Vector3(10.0, 0.0, 0.0)  # knocked toward +X, the way it was walking
	var recs := _run(b, 1)
	assert_eq(b.state, BotBrain.State.RECOVER, "knock enters recover")
	assert_true((recs[0]["move"] as Vector2).x < 0.0, "fights the knock (%s)" % recs[0]["move"])


func test_different_seeds_differ() -> void:
	var ps := _world()
	game.goal = Vector3(6.0, 0.0, 3.0)
	var a := _run(_brain(ps[1], 1), 180)
	var b := _run(_brain(ps[1], 2), 180)
	assert_true(a != b, "seed 1 and seed 2 produce different intents")


func test_same_seed_reproducible() -> void:
	var ps := _world()
	game.goal = Vector3(6.0, 0.0, 3.0)
	_put(ps[2], Vector3(1.0, 0.0, 1.0))  # someone to chase and shove
	var a := _run(_brain(ps[1], 7), 240)
	var b := _run(_brain(ps[1], 7), 240)
	assert_eq(a, b, "same seed, same intents")


func test_dead_or_frozen_gives_empty_intent() -> void:
	var ps := _world()
	game.goal = Vector3(6.0, 0.0, 0.0)
	_put(ps[2], Vector3(0.0, 0.0, 1.0))
	var b := _brain(ps[1], 19, 1.0, 0.5)
	_run(b, 60)
	var intent := PlayerIntent.new()
	for mode in ["frozen", "dead"]:
		intent.move = Vector2.RIGHT
		intent.jump_pressed = true
		intent.jump_held = true
		intent.action_pressed = true
		if mode == "frozen":
			ps[1].frozen = true
		else:
			ps[1].frozen = false
			ps[1].eliminate(&"test")
		b.fill_intent(intent, physics_delta())
		assert_eq(intent.move, Vector2.ZERO, "%s: no move" % mode)
		assert_false(intent.jump_pressed or intent.jump_held or intent.action_pressed, "%s: no buttons" % mode)


func test_controller_runs_brain_for_bots() -> void:
	var ps := spawn_arena(4, &"", false)
	var ctrl0 := ps[0].get_component(&"controller") as ControllerComponent
	assert_true(ctrl0.brain == null, "the human has no brain")
	var moved := {}
	var record := func(_i: int) -> void:
		for p in ps:
			if p.intent.move.length() > 0.1:
				moved[p.slot] = true
	await step(120, record)
	for i in range(1, ps.size()):
		var ctrl := ps[i].get_component(&"controller") as ControllerComponent
		assert_true(ctrl.brain is BotBrain, "bot %d has a BotBrain" % i)
	assert_false(moved.has(0), "the human did not move")
	assert_true(moved.size() >= 1, "bots produce movement intents through the controller")


# --- Goals: re-think --------------------------------------------------------------------------

## Counts get_bot_goal calls; answers `goal`.
class CountingGame extends Minigame:
	var goal: Vector3 = Vector3.ZERO
	var asked: int = 0

	func get_bot_goal(_player: Player) -> Vector3:
		asked += 1
		return goal


func test_rethink_request_switches_goal_quickly() -> void:
	var ps := _world()
	var cg := CountingGame.new()
	add_child(cg)
	cg.players = ps
	cg.goal = Vector3(6.0, 0.0, 0.0)
	var b := BotBrain.new()
	b.player = ps[1]
	b.minigame = cg
	add_child(b)
	b.configure(21, 0.5, 0.0)
	_run(b, 60)
	var before := cg.asked
	cg.goal = Vector3(-6.0, 0.0, 0.0)
	_run(b, 30)  # 0.5 s: well inside the routine refresh
	assert_eq(cg.asked, before, "without a request the bot sticks to its plan")
	cg.request_bot_rethink()
	var recs := _run(b, 30)
	assert_true(cg.asked > before, "a rethink request re-asks the goal")
	assert_true((recs[recs.size() - 1]["move"] as Vector2).x < -0.5, "and the bot turns to the new goal")
	# A request for another slot is ignored.
	var asked := cg.asked
	cg.request_bot_rethink(3)
	_run(b, 30)
	assert_eq(cg.asked, asked, "requests for other slots are ignored")


func test_reaching_the_goal_asks_for_the_next() -> void:
	var ps := _world()
	var cg := CountingGame.new()
	add_child(cg)
	cg.players = ps
	cg.goal = Vector3(0.2, 0.0, 0.0)  # already there
	var b := BotBrain.new()
	b.player = ps[1]
	b.minigame = cg
	add_child(b)
	b.configure(22, 0.5, 0.0)
	_run(b, 40)
	var asked := cg.asked
	cg.goal = Vector3(0.0, 0.0, 6.0)
	# The bot stands at a reached goal and looks again; it must not idle for the full refresh.
	var recs := _run(b, 30)
	assert_true(cg.asked >= asked, "asked again")
	var moved := false
	for r in recs:
		moved = moved or (r["move"] as Vector2).y > 0.5
	assert_true(moved or cg.asked > asked, "picks up a new goal soon after arriving")


# --- Jumps with real gravity -----------------------------------------------------------------

## Safe only over the listed x-ranges (Vector2(min, max)) with |z| < half_width.
class StripGame extends Minigame:
	var goal: Vector3 = Vector3.ZERO
	var ranges: Array[Vector2] = []
	var half_width: float = 1.6

	func get_bot_goal(_player: Player) -> Vector3:
		return goal

	func is_safe(pos: Vector3) -> bool:
		if absf(pos.z) > half_width or pos.y < -0.5:
			return false
		for r in ranges:
			if pos.x > r.x and pos.x < r.y:
				return true
		return false


func _box(center: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.global_position = center


## Bot slot 1 with its real brain (controller not scripted), the human parked on the dev floor.
func _physical_bot(game_node: Minigame, at: Vector3) -> Player:
	var ps := spawn_arena(2, &"", false)
	add_child(game_node)
	game_node.players = ps
	_put(ps[0], Vector3(-8.0, 0.0, -8.0))
	_put(ps[1], at)
	var b := (ps[1].get_component(&"controller") as ControllerComponent).brain as BotBrain
	b.minigame = game_node
	b.configure(31, 1.0, 0.0)
	return ps[1]


func test_hops_over_a_low_wall_when_stuck() -> void:
	var g := StripGame.new()
	g.ranges = [Vector2(91.0, 109.0)]
	g.half_width = 4.5
	g.goal = Vector3(106.0, 0.0, 0.0)
	_box(Vector3(100.0, -0.5, 0.0), Vector3(20.0, 1.0, 10.0))
	_box(Vector3(102.5, 0.3, 0.0), Vector3(0.4, 0.6, 10.0))  # a 0.6 m wall across the way
	var p := _physical_bot(g, Vector3(99.0, 0.05, 0.0))
	var jumps := watch(p, &"jumped")
	await step(240)
	assert_true(jumps.size() >= 1, "jumped when blocked")
	assert_true(p.global_position.x > 103.0, "got over the wall (x = %.2f)" % p.global_position.x)


func test_jumps_a_small_gap() -> void:
	var g := StripGame.new()
	# Platforms x 90..100 and 101.4..111.4 (a 1.4 m hole); safe 0.3 m inside their edges.
	g.ranges = [Vector2(90.3, 99.7), Vector2(101.7, 111.1)]
	g.goal = Vector3(108.0, 0.0, 0.0)
	_box(Vector3(95.0, -0.5, 0.0), Vector3(10.0, 1.0, 4.0))
	_box(Vector3(106.4, -0.5, 0.0), Vector3(10.0, 1.0, 4.0))
	var p := _physical_bot(g, Vector3(93.0, 0.05, 0.0))
	var jumps := watch(p, &"jumped")
	await step(240)
	assert_true(jumps.size() >= 1, "jumped")
	assert_true(p.global_position.x > 103.0 and p.global_position.y > -0.3,
		"crossed the gap and stands on the far side (%s)" % p.global_position)


func test_never_walks_off_an_edge() -> void:
	var g := StripGame.new()
	g.ranges = [Vector2(90.3, 99.7)]
	g.goal = Vector3(106.0, 0.0, 0.0)  # across a hole far too wide to jump
	_box(Vector3(95.0, -0.5, 0.0), Vector3(10.0, 1.0, 4.0))
	var p := _physical_bot(g, Vector3(93.0, 0.05, 0.0))
	var lowest := [INF]
	await step(300, func(_i: int) -> void: lowest[0] = minf(lowest[0], p.global_position.y))
	assert_true(lowest[0] > -0.3, "stayed on the platform (lowest y %.2f, at %s)" % [lowest[0], p.global_position])
