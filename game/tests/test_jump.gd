extends GameTest
## Jump component: gravity, variable height, coyote time, buffering, landing.
## Only the Player API and events: intent in, position/velocity/signals out.

const FLOOR_EDGE_X := 10.0  # dev arena floor spans x -10..10, top at y = 0


## One player standing on the dev arena floor, settled.
func _grounded_player() -> Player:
	var p := spawn_arena(1)[0]
	await step(3)
	assert_true(p.is_on_floor(), "starts on the floor")
	return p


func _jump_comp(p: Player) -> JumpComponent:
	return p.get_component(&"jump") as JumpComponent


## Presses jump on frame 0 and holds it for `hold_frames`; returns the peak height reached
## within `frames`.
func _jump_peak(p: Player, hold_frames: int, frames: int = 90) -> float:
	var start_y := p.global_position.y
	var peak := [start_y]
	await step(frames, func(i: int) -> void:
		p.intent.jump_pressed = i == 0
		p.intent.jump_held = i < hold_frames
		peak[0] = maxf(peak[0], p.global_position.y))
	return peak[0] - start_y


## Walks the player off the +X edge; returns once it is no longer on the floor (or fails).
func _walk_off_edge(p: Player) -> bool:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(FLOOR_EDGE_X - 0.6, 0.0, 0.0)))
	await step(2)
	for i in 90:
		await step(1, func(_i: int) -> void:
			p.intent.move = Vector2.RIGHT
			p.velocity.x = 5.0)  # the run component owns horizontal speed; stand in for it
		if not p.is_on_floor():
			return true
	fail("never left the floor (x = %f)" % p.global_position.x)
	return false


func test_full_jump_height() -> void:
	var p: Player = await _grounded_player()
	var jumped := watch(p, &"jumped")
	var h: float = await _jump_peak(p, 999)
	assert_eq(jumped.size(), 1, "one jump")
	assert_true(h > 1.2 and h < 1.4, "full jump apex around 1.3 m (got %f)" % h)


func test_short_hop_is_lower() -> void:
	var p: Player = await _grounded_player()
	var full: float = await _jump_peak(p, 999)
	await step(10)
	var hop: float = await _jump_peak(p, 2)
	assert_true(hop > 0.2, "short hop leaves the ground (got %f)" % hop)
	assert_true(hop < full * 0.6, "short hop (%f) clearly lower than full jump (%f)" % [hop, full])


func test_no_double_jump() -> void:
	var p: Player = await _grounded_player()
	var jumped := watch(p, &"jumped")
	var landed := watch(p, &"landed")
	# Press again at frame 20 (near the apex): neither an air jump nor a buffered one on landing.
	await step(90, func(i: int) -> void:
		p.intent.jump_pressed = i == 0 or i == 20
		p.intent.jump_held = true)
	assert_eq(jumped.size(), 1, "second press in the air is ignored")
	assert_eq(landed.size(), 1, "landed back once")
	assert_true(p.is_on_floor(), "back on the floor")


func test_landed_fires_once_with_plausible_speed() -> void:
	var p: Player = await _grounded_player()
	var landed := watch(p, &"landed")
	await _jump_peak(p, 999, 120)
	assert_eq(landed.size(), 1, "landed exactly once")
	if landed.size() == 1:
		var speed: float = landed[0][0]
		# A 1.3 m fall under fall gravity lands at roughly 8-10 m/s.
		assert_true(speed > 4.0 and speed < 15.0, "impact speed plausible (got %f)" % speed)


func test_no_landed_while_standing() -> void:
	var p := spawn_arena(1)[0]
	var landed := watch(p, &"landed")
	await step(30)
	assert_eq(landed.size(), 0, "standing at spawn raises no landed")


func test_buffered_jump_fires_on_landing() -> void:
	var p: Player = await _grounded_player()
	var jumped := watch(p, &"jumped")
	var pressed_in_air := [false]
	# Full jump; on the way down, press again just before touching the floor.
	await step(120, func(i: int) -> void:
		var falling_low := p.velocity.y < 0.0 and p.global_position.y < 0.35 and not p.is_on_floor()
		var press: bool = i == 0 or (falling_low and not pressed_in_air[0])
		if press and i > 0:
			pressed_in_air[0] = true
		p.intent.jump_pressed = press
		p.intent.jump_held = true)
	assert_true(pressed_in_air[0], "the second press happened in the air")
	assert_eq(jumped.size(), 2, "the early press jumps again right on landing")


func test_coyote_jump_after_leaving_ledge() -> void:
	var p := spawn_arena(1)[0]
	var jumped := watch(p, &"jumped")
	if not await _walk_off_edge(p):
		return
	await step(3)  # 0.05 s in the air, inside coyote time
	var y_before := p.global_position.y
	await step(20, func(i: int) -> void:
		p.intent.jump_pressed = i == 0
		p.intent.jump_held = true)
	assert_eq(jumped.size(), 1, "coyote jump taken")
	assert_true(p.global_position.y > y_before + 0.5, "rose after the coyote jump")


func test_walk_off_ledge_falls_and_late_jump_fails() -> void:
	var p := spawn_arena(1)[0]
	var jumped := watch(p, &"jumped")
	if not await _walk_off_edge(p):
		return
	await step(15)  # 0.25 s: coyote time is over
	await step(1, func(_i: int) -> void:
		p.intent.jump_pressed = true
		p.intent.jump_held = true)
	await step(40, func(_i: int) -> void:
		p.intent.jump_pressed = false)
	assert_eq(jumped.size(), 0, "no jump after coyote time ran out")
	assert_true(p.global_position.y < -2.0, "fell off the ledge (y = %f)" % p.global_position.y)
	assert_true(p.velocity.y < -5.0, "falling fast (vy = %f)" % p.velocity.y)


func test_terminal_velocity() -> void:
	var p := spawn_arena(1)[0]
	var jc := _jump_comp(p)
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(30.0, 0.0, 0.0)))  # off the arena
	var fastest := [0.0]
	await step(120, func(_i: int) -> void: fastest[0] = minf(fastest[0], p.velocity.y))
	assert_near(fastest[0] as float,-jc.terminal_velocity, 0.01, "fall speed capped")


func test_disabled_flag_blocks_jumping() -> void:
	var p: Player = await _grounded_player()
	var jumped := watch(p, &"jumped")
	_jump_comp(p).jump_enabled = false
	var h: float = await _jump_peak(p, 999, 40)
	assert_eq(jumped.size(), 0, "no jump while disabled")
	assert_true(h < 0.05, "stayed on the floor (rose %f)" % h)
	_jump_comp(p).jump_enabled = true
	h = await _jump_peak(p, 999, 40)
	assert_eq(jumped.size(), 1, "jumps again once re-enabled")


func test_upward_impulse_is_kept() -> void:
	var p: Player = await _grounded_player()
	var jumped := watch(p, &"jumped")
	p.apply_impulse(Vector3(0.0, 6.0, 0.0))
	var peak := [0.0]
	await step(40, func(_i: int) -> void: peak[0] = maxf(peak[0], p.global_position.y))
	assert_true(peak[0] > 0.5, "an upward impulse lifts the player (peak %f)" % peak[0])
	assert_eq(jumped.size(), 0, "an impulse is not a jump")


func test_frozen_player_cannot_jump_but_falls() -> void:
	var p := spawn_arena(1)[0]
	var jumped := watch(p, &"jumped")
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(0.0, 2.0, 0.0)))
	p.frozen = true
	await step(60, func(_i: int) -> void:
		p.intent.jump_pressed = true
		p.intent.jump_held = true)
	assert_eq(jumped.size(), 0, "frozen: no jump")
	assert_true(p.is_on_floor(), "frozen: gravity still settles the player on the floor")
