extends GameTest
## Status component: knockback, stun, immunity, invulnerable, respawn. Player API and events only.


func _status(p: Player) -> StatusComponent:
	return p.get_component(&"status") as StatusComponent


func test_impulse_moves_player_in_its_direction() -> void:
	var p := spawn_arena(1)[0]
	var start := p.global_position
	p.apply_impulse(Vector3(6, 0, 0))
	assert_near(p.velocity, Vector3(6, 0, 0), 0.001, "impulse added to velocity")
	await step(6)
	var moved := p.global_position - start
	assert_true(moved.x > 0.2, "moved along +X (%s)" % moved)
	assert_true(absf(moved.z) < 0.05, "no sideways drift (%s)" % moved)


func test_events_carry_impulse_and_source() -> void:
	var ps := spawn_arena(2)
	var victim := ps[0]
	var hits := watch(victim, &"got_hit")
	var stuns := watch(victim, &"stunned")
	victim.apply_impulse(Vector3(0, 0, -5), ps[1])
	if assert_eq(hits.size(), 1, "got_hit raised once"):
		assert_near(hits[0][0], Vector3(0, 0, -5), 0.001, "got_hit impulse")
		assert_eq(hits[0][1], 1, "got_hit source slot")
	if assert_eq(stuns.size(), 1, "stunned raised once"):
		var s: StatusComponent = _status(victim)
		assert_true(stuns[0][0] >= s.stun_min and stuns[0][0] <= s.stun_max, "stun within min..max (%s)" % stuns[0][0])
	victim.apply_impulse(Vector3.ZERO)  # immune, ignored
	await step(20)
	victim.apply_impulse(Vector3(1, 0, 0))
	assert_eq(hits.size(), 2, "second hit after immunity")
	assert_eq(hits[1][1], -1, "no source -> slot -1")


func test_control_locked_for_stun_duration() -> void:
	var p := spawn_arena(1)[0]
	var s := _status(p)
	s.stun_min = 0.5
	s.stun_max = 0.5
	var stuns := watch(p, &"stunned")
	p.apply_impulse(Vector3(3, 0, 0))
	assert_true(p.control_locked, "locked right after the hit")
	assert_eq(stuns.size(), 1, "stunned raised")
	if stuns.size() == 1:
		assert_near(stuns[0][0], 0.5, 0.0001, "stunned duration")
	await step(27)  # 0.45 s
	assert_true(p.control_locked, "still locked at 0.45 s")
	await step(5)  # 0.533 s
	assert_false(p.control_locked, "unlocked after 0.5 s")


func test_intent_ignored_while_stunned() -> void:
	var p := spawn_arena(1)[0]
	p.apply_impulse(Vector3(3, 0, 0))
	await step(1, func(_i: int) -> void: p.intent.move = Vector2.LEFT)
	assert_eq(p.intent.move, Vector2.ZERO, "intent cleared while stunned")


func test_stun_scales_with_strength() -> void:
	var ps := spawn_arena(2)
	var weak := watch(ps[0], &"stunned")
	var strong := watch(ps[1], &"stunned")
	var s := _status(ps[0])
	ps[0].apply_impulse(Vector3(1, 0, 0))
	ps[1].apply_impulse(Vector3(100, 0, 0))
	if assert_eq(weak.size(), 1, "weak stunned") and assert_eq(strong.size(), 1, "strong stunned"):
		assert_true(weak[0][0] < strong[0][0], "weak stun shorter (%s vs %s)" % [weak[0][0], strong[0][0]])
		assert_near(strong[0][0], s.stun_max, 0.0001, "strong hit clamps to stun_max")
		assert_true(weak[0][0] >= s.stun_min, "weak hit at least stun_min")


func test_immunity_blocks_second_hit() -> void:
	var p := spawn_arena(1)[0]
	var hits := watch(p, &"got_hit")
	p.apply_impulse(Vector3(4, 0, 0))
	p.apply_impulse(Vector3(4, 0, 0))
	assert_eq(hits.size(), 1, "second hit in the same frame ignored")
	assert_near(p.velocity, Vector3(4, 0, 0), 0.001, "velocity added once")
	await step(6)  # 0.1 s, still immune
	p.apply_impulse(Vector3(0, 0, 4))
	assert_eq(hits.size(), 1, "hit at 0.1 s ignored")
	await step(10)  # 0.27 s
	p.apply_impulse(Vector3(0, 0, 4))
	assert_eq(hits.size(), 2, "hit after immunity registers")


func test_rehit_extends_stun_without_stacking_forever() -> void:
	var p := spawn_arena(1)[0]
	var s := _status(p)
	s.stun_min = 0.5
	s.stun_max = 0.5
	s.stun_chain_max = 1.0
	var stuns := watch(p, &"stunned")
	p.apply_impulse(Vector3(3, 0, 0))
	await step(15)  # 0.25 s into a 0.5 s stun
	p.apply_impulse(Vector3(3, 0, 0))
	assert_eq(stuns.size(), 2, "re-hit extends the stun")
	await step(24)  # 0.65 s: past the first stun, inside the extension
	assert_true(p.control_locked, "extended stun still holds")
	# Keep hitting every 0.25 s: the chain must still break at stun_chain_max.
	var free_frame := -1
	for i in 60:
		if i % 15 == 0:
			p.apply_impulse(Vector3(3, 0, 0))
		await step(1)
		if not p.control_locked and free_frame < 0:
			free_frame = 39 + i + 1
	assert_true(free_frame > 0, "control came back despite constant hits")
	assert_true(free_frame <= 62, "chain capped near 1.0 s (free at frame %d)" % free_frame)


func test_invulnerable_blocks_all() -> void:
	var p := spawn_arena(1)[0]
	_status(p).invulnerable = true
	var hits := watch(p, &"got_hit")
	var stuns := watch(p, &"stunned")
	p.apply_impulse(Vector3(10, 0, 0))
	assert_near(p.velocity, Vector3.ZERO, 0.001, "no knockback")
	assert_false(p.control_locked, "not locked")
	assert_eq(hits.size() + stuns.size(), 0, "no events")


func test_frozen_and_dead_ignore_impulses() -> void:
	var ps := spawn_arena(2)
	var hits := watch(ps[0], &"got_hit")
	ps[0].frozen = true
	ps[0].apply_impulse(Vector3(10, 0, 0))
	assert_near(ps[0].velocity, Vector3.ZERO, 0.001, "frozen: no knockback")
	assert_false(ps[0].control_locked, "frozen: not locked")
	assert_eq(hits.size(), 0, "frozen: no events")
	ps[1].eliminate(&"test")
	var dead_hits := watch(ps[1], &"got_hit")
	ps[1].apply_impulse(Vector3(10, 0, 0))
	assert_eq(dead_hits.size(), 0, "dead: no events")
	assert_false(ps[1].control_locked, "dead: not locked")


func test_respawn_clears_stun() -> void:
	var p := spawn_arena(1)[0]
	var hits := watch(p, &"got_hit")
	p.apply_impulse(Vector3(12, 0, 0))
	await step(2)
	assert_true(p.control_locked, "stunned")
	p.eliminate(&"fell")
	p.respawn_at(Transform3D(Basis.IDENTITY, Vector3(0, 0, 2)))
	assert_false(p.control_locked, "respawn clears the stun")
	p.apply_impulse(Vector3(1, 0, 0))
	assert_eq(hits.size(), 2, "respawn clears immunity")


func test_multiplier_scales_knockback() -> void:
	var ps := spawn_arena(2)
	_status(ps[1]).knockback_multiplier = 2.5
	var hits := watch(ps[1], &"got_hit")
	ps[0].apply_impulse(Vector3(4, 0, 0))
	ps[1].apply_impulse(Vector3(4, 0, 0))
	assert_near(ps[0].velocity, Vector3(4, 0, 0), 0.001, "default multiplier 1")
	assert_near(ps[1].velocity, Vector3(10, 0, 0), 0.001, "multiplier 2.5")
	if hits.size() == 1:
		assert_near(hits[0][0], Vector3(10, 0, 0), 0.001, "got_hit reports the applied impulse")
