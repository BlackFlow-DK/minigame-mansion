extends GameTest
## Movement (running): top speed, stopping, turning, facing, frozen, external velocity, air control.
## Only the Player API and shared state are used. The jump component may or may not add
## gravity; the tests hold the blob on the floor (or in the air) themselves so they pass either way.


func _horizontal_speed(p: Player) -> float:
	return Vector2(p.velocity.x, p.velocity.z).length()


## One player on the dev arena (slot 0 at (0, 0, 5)), pressed onto the floor for a few ticks
## so `is_on_floor()` is true before the test starts.
func _grounded_player() -> Player:
	var p := spawn_arena(1)[0]
	await step(3, func(_i: int) -> void: _press_down(p))
	assert_true(p.is_on_floor(), "player starts on the floor")
	return p


func _press_down(p: Player) -> void:
	p.velocity.y = minf(p.velocity.y, -1.0)


func _run(p: Player, move: Vector2) -> Callable:
	return func(_i: int) -> void:
		_press_down(p)
		p.intent.move = move


func test_reaches_top_speed() -> void:
	var p: Player = await _grounded_player()
	var movement := p.get_component(&"movement") as MovementComponent
	if not assert_true(movement != null, "movement component present"):
		return
	await step(12, _run(p, Vector2.LEFT))
	assert_true(_horizontal_speed(p) >= movement.max_speed * 0.95, "near top speed within 0.2 s (%f)" % _horizontal_speed(p))
	var peak := 0.0
	for i in 48:
		await step(1, _run(p, Vector2.LEFT))
		peak = maxf(peak, _horizontal_speed(p))
	assert_near(_horizontal_speed(p), movement.max_speed, 0.01, "holds top speed")
	assert_true(peak <= movement.max_speed + 0.01, "never exceeds top speed (%f)" % peak)
	assert_near(p.velocity.normalized(), Vector3.LEFT, 0.01, "runs along the input")
	assert_true(p.global_position.x < -4.0, "actually moved (x = %f)" % p.global_position.x)
	# Half stick, half speed.
	await step(40, _run(p, Vector2.LEFT * 0.5))
	assert_near(_horizontal_speed(p), movement.max_speed * 0.5, 0.01, "analog stick scales speed")


func test_tuning_changes_top_speed() -> void:
	var p: Player = await _grounded_player()
	var movement := p.get_component(&"movement") as MovementComponent
	movement.max_speed = 9.0
	await step(40, _run(p, Vector2.LEFT))
	assert_near(_horizontal_speed(p), 9.0, 0.01, "exported max_speed is honoured")


func test_stops_when_released() -> void:
	var p: Player = await _grounded_player()
	await step(40, _run(p, Vector2.LEFT))
	var released_at := p.global_position
	await step(1, _run(p, Vector2.ZERO))
	assert_true(_horizontal_speed(p) > 1.0, "does not stop dead in one tick")
	await step(14, _run(p, Vector2.ZERO))
	assert_near(_horizontal_speed(p), 0.0, 0.001, "stopped within 0.25 s")
	var slide := (p.global_position - released_at) * Vector3(1, 0, 1)
	assert_true(slide.length() < 1.0, "short stopping distance (%f m)" % slide.length())
	var at_rest := p.global_position
	await step(20, _run(p, Vector2.ZERO))
	assert_near(p.global_position * Vector3(1, 0, 1), at_rest * Vector3(1, 0, 1), 0.001, "stays put")


func test_quick_turn_around() -> void:
	var p: Player = await _grounded_player()
	await step(30, _run(p, Vector2.RIGHT))
	assert_true(p.velocity.x > 5.9, "running right")
	var frames := 0
	while p.velocity.x > -5.5 and frames < 60:
		await step(1, _run(p, Vector2.LEFT))
		frames += 1
	assert_true(frames <= 15, "full reversal within 0.25 s (took %d ticks)" % frames)
	assert_true(absf(p.velocity.z) < 0.01, "no sideways drift on a straight reversal")


func test_facing_follows_move() -> void:
	var p: Player = await _grounded_player()
	var start := p.facing  # spawn 0 faces -Z
	await step(1, _run(p, Vector2.RIGHT))
	assert_true(p.facing.distance_to(Vector3.RIGHT) > 0.1, "turns smoothly, not instantly")
	assert_true(p.facing.distance_to(start) > 0.01, "starts turning at once")
	await step(20, _run(p, Vector2.RIGHT))
	assert_near(p.facing, Vector3.RIGHT, 0.02, "faces the move direction")
	assert_near(p.facing.length(), 1.0, 0.001, "facing is a unit vector")
	assert_near(p.facing.y, 0.0, 0.0001, "facing stays on XZ")
	var diag := Vector2(1, 1).normalized()
	await step(30, _run(p, diag))
	assert_near(p.facing, Vector3(diag.x, 0, diag.y), 0.02, "faces a diagonal")
	await step(30, _run(p, Vector2.ZERO))
	assert_near(p.facing, Vector3(diag.x, 0, diag.y), 0.02, "keeps facing when the stick is released")
	assert_eq(p.global_basis, Basis.IDENTITY, "root never rotates")


func test_frozen_does_not_move() -> void:
	var p: Player = await _grounded_player()
	await step(20, _run(p, Vector2.LEFT))
	p.frozen = true
	await step(1, _run(p, Vector2.LEFT))
	var held := p.global_position
	var facing := p.facing
	await step(30, _run(p, Vector2.UP))
	assert_near(p.global_position * Vector3(1, 0, 1), held * Vector3(1, 0, 1), 0.001, "frozen: no horizontal motion")
	assert_near(_horizontal_speed(p), 0.0, 0.0001, "frozen: no horizontal velocity")
	assert_near(p.facing, facing, 0.0001, "frozen: facing unchanged")
	p.frozen = false
	await step(10, _run(p, Vector2.UP))
	assert_true(_horizontal_speed(p) > 3.0, "moves again after unfreezing")


func test_external_velocity_decays() -> void:
	var p: Player = await _grounded_player()
	p.apply_impulse(Vector3(12, 0, 0))
	await step(1, _run(p, Vector2.ZERO))
	assert_true(p.velocity.x > 11.0, "a push survives the next tick (vx = %f)" % p.velocity.x)
	var last := p.velocity.x
	var frames := 0
	while p.velocity.x > 0.001 and frames < 120:
		await step(1, _run(p, Vector2.ZERO))
		assert_true(p.velocity.x <= last + 0.0001, "the push only decays")
		last = p.velocity.x
		frames += 1
	assert_true(frames > 10, "the push lasts a while (%d ticks)" % frames)
	assert_true(frames < 90, "and then it is gone (%d ticks)" % frames)
	# Running against a push slows it but does not cancel it at once.
	p.apply_impulse(Vector3(12, 0, 0))
	await step(1, _run(p, Vector2.LEFT))
	assert_true(p.velocity.x > 10.0, "running into a push does not erase it (vx = %f)" % p.velocity.x)


func test_control_locked_slides_longer() -> void:
	var free_p: Player = await _grounded_player()
	free_p.apply_impulse(Vector3(-5, 0, 0))
	await step(8, _run(free_p, Vector2.ZERO))
	var free_speed := _horizontal_speed(free_p)
	free_p.control_locked = true
	free_p.apply_impulse(Vector3(-5 - free_p.velocity.x, 0, 0))  # back to exactly -5
	await step(8, _run(free_p, Vector2.ZERO))
	var locked_speed := _horizontal_speed(free_p)
	assert_true(locked_speed > free_speed + 1.0, "stunned players slide further (%f vs %f)" % [locked_speed, free_speed])
	assert_true(locked_speed < 5.0, "but still slow down")


func test_air_control_weaker_than_ground() -> void:
	var p: Player = await _grounded_player()
	await step(6, _run(p, Vector2.LEFT))
	var ground_speed := _horizontal_speed(p)
	await step(30, _run(p, Vector2.ZERO))
	# Lift the blob well above the floor and hold it there (whatever gravity jump applies).
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(0, 30, 0)))
	var float_there := func(_i: int) -> void:
		p.velocity.y = 0.0
		p.intent.move = Vector2.LEFT
	await step(1, func(_i: int) -> void: p.velocity.y = 0.0)
	assert_false(p.is_on_floor(), "in the air")
	await step(6, float_there)
	var air_speed := _horizontal_speed(p)
	assert_true(air_speed > 0.1, "some air control (%f)" % air_speed)
	assert_true(air_speed < ground_speed * 0.6, "air control weaker than ground (%f vs %f)" % [air_speed, ground_speed])
	# Letting go in the air keeps most of the momentum.
	await step(30, float_there)
	var cruising := _horizontal_speed(p)
	await step(6, func(_i: int) -> void: p.velocity.y = 0.0)
	assert_true(_horizontal_speed(p) > cruising * 0.5, "air friction is gentle")
