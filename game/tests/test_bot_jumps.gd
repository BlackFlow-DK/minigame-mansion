extends GameTest
## Bot brain jump probes with real physics: a bot whose goal lies up a ledge or across a hole
## that the minigame's `is_safe` says nothing about (a plain Minigame: everything is "safe")
## jumps up a 0.9 m ledge and across a 2.0 m gap, and fails sensibly at impossible ones: it does
## not hop at a wall higher than its jump (nor at a ledge its own jump tuning cannot reach), and it
## stops at the edge of a hole too wide to jump instead of running off it.


class GoalGame extends Minigame:
	var goal: Vector3 = Vector3.ZERO

	func get_bot_goal(_player: Player) -> Vector3:
		return goal


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
func _bot(goal: Vector3, at: Vector3, skill: float = 1.0, seed_value: int = 31) -> Player:
	var ps := spawn_arena(2, &"", false)
	var g := GoalGame.new()
	g.goal = goal
	add_child(g)
	g.players = ps
	ps[0].place_at(Transform3D(Basis.IDENTITY, Vector3(-8.0, 0.0, -8.0)))
	ps[1].place_at(Transform3D(Basis(Vector3.UP, PI * 0.5), at))  # facing +X, the way to go
	var b := BotBrain.of(ps[1])
	b.minigame = g
	b.configure(seed_value, skill, 0.0)
	return ps[1]


## A floor slab with its top at `top` over x in [x0, x1], `width` m wide (z).
func _floor(x0: float, x1: float, top: float = 0.0, width: float = 4.0) -> void:
	_box(Vector3((x0 + x1) * 0.5, top - 0.5, 0.0), Vector3(x1 - x0, 1.0, width))


func test_jumps_up_a_0_9_m_ledge() -> void:
	_floor(90.0, 112.0)
	_box(Vector3(108.0, 0.45, 0.0), Vector3(8.0, 0.9, 4.0))  # a step 0.9 m up from x = 104
	var p := _bot(Vector3(108.0, 0.9, 0.0), Vector3(96.0, 0.05, 0.0))
	var b := BotBrain.of(p)
	var jumps := watch(p, &"jumped")
	await step(240)
	print("  ledge 0.9 m: at %s, %d jumps (%d planned)" % [p.global_position, jumps.size(), b.planned_jumps])
	assert_true(p.global_position.x > 104.6 and p.global_position.y > 0.8, "on top of the ledge (%s)" % p.global_position)
	assert_true(b.planned_jumps >= 1, "a planned take-off, not a bump-and-hop")
	assert_true(jumps.size() <= 2, "no frantic hopping (%d jumps)" % jumps.size())


func test_jumps_up_the_ledge_from_a_standstill() -> void:
	_floor(90.0, 112.0)
	_box(Vector3(108.0, 0.45, 0.0), Vector3(8.0, 0.9, 4.0))
	var p := _bot(Vector3(108.0, 0.9, 0.0), Vector3(103.5, 0.05, 0.0))  # right at the foot
	await step(240)
	assert_true(p.global_position.x > 104.6 and p.global_position.y > 0.8, "climbed from a standstill (%s)" % p.global_position)


func test_jumps_across_a_2_m_gap() -> void:
	_floor(90.0, 100.0)
	_floor(102.0, 112.0)  # a 2.0 m hole with nothing below
	var p := _bot(Vector3(108.0, 0.0, 0.0), Vector3(93.0, 0.05, 0.0))
	var b := BotBrain.of(p)
	var lowest := [INF]
	await step(240, func(_i: int) -> void: lowest[0] = minf(lowest[0], p.global_position.y))
	print("  gap 2.0 m: at %s, lowest y %.2f, %d planned jumps" % [p.global_position, lowest[0], b.planned_jumps])
	assert_true(p.global_position.x > 103.0 and p.global_position.y > -0.3, "across and standing (%s)" % p.global_position)
	assert_true(b.planned_jumps >= 1, "jumped from the edge")


func test_does_not_hop_at_a_wall_too_high() -> void:
	_floor(90.0, 112.0)
	_box(Vector3(104.2, 0.9, 0.0), Vector3(0.4, 1.8, 4.0))  # 1.8 m: over the 1.3 m apex
	var p := _bot(Vector3(108.0, 0.0, 0.0), Vector3(96.0, 0.05, 0.0))
	var jumps := watch(p, &"jumped")
	await step(300)
	print("  wall 1.8 m: at %s, %d jumps" % [p.global_position, jumps.size()])
	assert_true(jumps.size() <= 1, "does not keep hopping at it (%d jumps)" % jumps.size())
	assert_true(p.global_position.x < 104.0, "still on this side (%s)" % p.global_position)


func test_reads_its_own_jump_tuning() -> void:
	_floor(90.0, 112.0)
	_box(Vector3(108.0, 0.45, 0.0), Vector3(8.0, 0.9, 4.0))
	var p := _bot(Vector3(108.0, 0.9, 0.0), Vector3(96.0, 0.05, 0.0))
	(p.get_component(&"jump") as JumpComponent).jump_height = 0.8  # a heavy blob: 0.9 m is too high
	var b := BotBrain.of(p)
	var jumps := watch(p, &"jumped")
	await step(240)
	assert_eq(b.planned_jumps, 0, "no planned jump at a ledge its jump cannot reach")
	assert_true(jumps.size() <= 1, "and no hopping at it (%d)" % jumps.size())
	assert_true(p.global_position.y < 0.5, "still below (%s)" % p.global_position)


func test_stops_at_a_hole_too_wide() -> void:
	_floor(90.0, 100.0)
	_floor(105.0, 112.0)  # 5 m: far beyond any jump
	var p := _bot(Vector3(108.0, 0.0, 0.0), Vector3(93.0, 0.05, 0.0))
	var b := BotBrain.of(p)
	var lowest := [INF]
	await step(300, func(_i: int) -> void: lowest[0] = minf(lowest[0], p.global_position.y))
	print("  hole 5 m: at %s, lowest y %.2f" % [p.global_position, lowest[0]])
	assert_true(lowest[0] > -0.3, "never ran off the edge (lowest y %.2f)" % lowest[0])
	assert_eq(b.planned_jumps, 0, "did not try the jump")


func test_clumsy_bots_mostly_make_a_high_ledge() -> void:
	# Clumsy bots at a 1.1 m ledge (near the 1.15 m limit): they get up, with more tries than a
	# sharp one (timing errors, short missed jumps, wandering).
	var made := 0
	var tries := 0
	for k in 6:
		_floor(90.0, 112.0, 0.0, 10.0)
		_box(Vector3(108.0, 0.55, 0.0), Vector3(8.0, 1.1, 10.0))
		var p := _bot(Vector3(108.0, 1.1, 0.0), Vector3(96.0, 0.05, 0.0), 0.0, 400 + k)
		var jumps := watch(p, &"jumped")
		var top := [-INF]
		await step(480, func(_i: int) -> void: top[0] = maxf(top[0], p.global_position.y))
		tries += jumps.size()
		if top[0] > 1.0:
			made += 1
		_reset()
	print("  clumsy at 1.1 m: %d of 6 up, %d jumps" % [made, tries])
	assert_true(made >= 4, "clumsy bots still climb it mostly (%d of 6)" % made)


func _reset() -> void:
	for c in get_children():
		if c is StaticBody3D or c is Minigame:
			c.queue_free()
	if stage:
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
	players.clear()
	Net.leave()
