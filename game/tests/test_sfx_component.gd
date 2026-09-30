extends GameTest
## Player sfx component: every event maps to a sound; footsteps from movement, not intent.


func _sounds(events: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for e: Array in events:
		out.append(e[0])
	return out


func test_reacts_to_each_event() -> void:
	var ps := spawn_arena(2)
	await step(10)
	var p := ps[0]
	var comp := p.get_component(&"sfx") as SfxComponent
	if not assert_true(comp != null, "sfx component present"):
		return
	var req := watch(comp, &"requested")
	p.emit_event(&"jumped")
	p.emit_event(&"landed", [1.0])     # too soft: silent
	p.emit_event(&"landed", [6.0])
	p.emit_event(&"landed", [16.0])
	p.emit_event(&"shove_started")
	p.emit_event(&"shove_hit", [1])
	p.emit_event(&"got_hit", [Vector3.RIGHT, 1])   # from a shove: the shover bonks, not us
	p.emit_event(&"got_hit", [Vector3.RIGHT, -1])  # bumper/explosion
	p.emit_event(&"stunned", [1.0])
	p.eliminate(&"test")
	p.respawn_at(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 3.0)))
	var expected: Array[StringName] = [&"jump", &"land_soft", &"land_hard", &"shove_whoosh",
		&"hit_bonk", &"hit_bonk", &"stun_wobble", &"eliminated_pop", &"respawn"]
	assert_eq(_sounds(req), expected, "event sounds")
	# landings get louder with impact
	assert_true(float(req[2][2]) >= float(req[1][2]), "hard landing not quieter than soft")
	assert_near(req[8][1], Vector3(0.0, 0.0, 3.0), 0.001, "respawn sound at the respawn point")


func test_footsteps_while_walking() -> void:
	var ps := spawn_arena(2)
	await step(20)
	var comp := ps[0].get_component(&"sfx") as SfxComponent
	var req := watch(comp, &"requested")
	await step(90, func(_i: int) -> void: ps[0].intent.move = Vector2.RIGHT)
	var steps := _sounds(req).count(&"step")
	assert_true(steps >= 3, "walking 1.5 s gives footsteps (got %d)" % steps)
	assert_true(steps <= 12, "not a machine gun (got %d)" % steps)
	ps[0].intent.move = Vector2.ZERO
	await step(30)
	req.clear()
	await step(30)
	assert_true(_sounds(req).count(&"step") == 0, "standing still: no more steps")


## Remote copies are moved by sync, not by intent: steps must follow the position alone.
func test_footsteps_follow_position_not_intent() -> void:
	var ps := spawn_arena(2)
	await step(20)
	var p := ps[1]
	var comp := p.get_component(&"sfx") as SfxComponent
	var req := watch(comp, &"requested")
	var start := p.global_position
	await step(60, func(i: int) -> void:
		p.velocity = Vector3.ZERO
		p.global_position = start + Vector3(0.1 * (i + 1), 0.0, 0.0))
	var steps := _sounds(req).count(&"step")
	assert_true(steps >= 4, "6 m of sync-driven movement gives steps (got %d)" % steps)
	req.clear()
	p.global_position = start + Vector3(0.0, 0.0, -4.0)  # teleport
	await step(2)
	assert_eq(_sounds(req).count(&"step"), 0, "a teleport is not a step")


func test_no_footsteps_in_the_air() -> void:
	var ps := spawn_arena(2)
	await step(20)
	var p := ps[1]
	var comp := p.get_component(&"sfx") as SfxComponent
	var req := watch(comp, &"requested")
	comp._on_jumped()  # airborne as far as sound knows, without moving vertically
	var start := p.global_position
	await step(40, func(i: int) -> void:
		p.velocity = Vector3.ZERO
		p.global_position = start + Vector3(0.1 * (i + 1), 0.0, 0.0))
	assert_eq(_sounds(req).count(&"step"), 0, "no steps between jumped and landed")
	comp._on_landed(0.0)
	var mid := p.global_position
	await step(40, func(i: int) -> void:
		p.velocity = Vector3.ZERO
		p.global_position = mid + Vector3(0.1 * (i + 1), 0.0, 0.0))
	assert_true(_sounds(req).count(&"step") >= 2, "steps again after landing")


func test_component_never_touches_gameplay_state() -> void:
	var ps := spawn_arena(2)
	await step(10)
	var p := ps[0]
	var before := [p.velocity, p.facing, p.frozen, p.control_locked, p.alive]
	var comp := p.get_component(&"sfx") as SfxComponent
	comp._on_jumped()
	comp._on_landed(20.0)
	comp._on_stunned(1.0)
	comp._on_got_hit(Vector3.ONE, -1)
	assert_eq([p.velocity, p.facing, p.frozen, p.control_locked, p.alive], before, "state untouched")
