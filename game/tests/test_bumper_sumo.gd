extends GameTest
## Bumper Sumo: scene layout, knockback tuning (edge ring-out vs. mid-platform), the ring
## drop schedule, falling off a dropping ring, and bot-only rounds (see also
## test_bumper_sumo_bots.gd).

const ID := &"bumper_sumo"


func _sumo() -> BumperSumo:
	return get_minigame() as BumperSumo


## Places `p` at `pos` looking along `look` (on XZ).
func _place(p: Player, pos: Vector3, look: Vector3 = Vector3.MODEL_FRONT) -> void:
	var basis := Basis.looking_at(-look.normalized(), Vector3.UP)  # +Z along `look`
	p.place_at(Transform3D(basis, pos))


func _flat_r(p: Player) -> float:
	return Vector2(p.global_position.x, p.global_position.z).length()


## Shover at `from` shoves the victim standing at `to` (along from -> to). Bystanders go far
## to the side. Returns after the shove press.
func _shove(shover: Player, victim: Player, from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	_place(shover, from, dir)
	_place(victim, to, -dir)
	var side := Vector3(-dir.z, 0.0, dir.x)
	var n := 0
	for p in players:
		if p != shover and p != victim:
			_place(p, side * (4.0 + 1.5 * n) - dir * 1.5)
			n += 1
	var hits := watch(shover, &"shove_hit")
	await step(3)
	# Place again: a first teleport whose path crosses another body's can leave the two
	# pushed apart (engine artifact), so the second placement is the one that counts.
	_place(shover, from, dir)
	_place(victim, to, -dir)
	await step(2)
	await step(1, func(_i: int) -> void: shover.intent.action_pressed = true)
	shover.intent.action_pressed = false
	await step(2)
	assert_eq(hits.size(), 1, "the shove hit the victim")


func test_scene_loads_with_8_spawns_on_the_platform() -> void:
	var ps := spawn_arena(8, ID)
	var m := _sumo()
	assert_true(m != null, "bumper_sumo loads as BumperSumo")
	if m == null:
		return
	var points := m.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn points")
	for t in points:
		var r := Vector2(t.origin.x, t.origin.z).length()
		assert_true(r < 7.0 - 1.0, "spawn well inside the smallest start radius (r=%.2f)" % r)
		var look := t.basis * Vector3.MODEL_FRONT
		assert_true(look.dot(-t.origin.normalized()) > 0.95, "spawn faces the centre")
	assert_eq(m.platform_radius(), 9.0, "8 players start on the 9 m platform")
	for i in 4:
		assert_true(m.is_ring_solid(i), "ring %d solid at the start" % i)
	await step(30)
	for p in ps:
		assert_true(p.alive and p.is_on_floor(), "P%d stands on the platform" % p.slot)
		assert_near(p.global_position.y, 0.0, 0.05, "P%d on top of the platform" % p.slot)


## The spawn points `pts` (local to the minigame) form an even ring of `radius`: equal
## radii, equal angles between neighbours, each facing the centre.
func _assert_even_ring(pts: Array[Transform3D], radius: float, what: String) -> void:
	var n := pts.size()
	var angles: Array[float] = []
	for t in pts:
		var flat := Vector3(t.origin.x, 0.0, t.origin.z)
		assert_near(flat.length(), radius, 0.01, "%s: on the %.1f m circle" % [what, radius])
		var look := t.basis * Vector3.MODEL_FRONT
		assert_true(look.dot(-flat.normalized()) > 0.999, "%s: faces the centre" % what)
		angles.append(atan2(flat.x, flat.z))
	angles.sort()
	for i in n:
		var gap := fposmod(angles[(i + 1) % n] - angles[i], TAU)
		assert_near(gap, TAU / n, 0.01, "%s: equal angles (%d players)" % [what, n])


## Where the players stand now, as spawn transforms local to `mg` (origin + facing).
func _player_points(mg: Minigame, ps: Array[Player]) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for p in ps:
		var local := mg.to_local(p.global_position)
		local.y = 0.0
		out.append(Transform3D(Basis.looking_at(-p.facing, Vector3.UP), local))
	return out


func test_spawn_layout_is_an_even_ring_for_2_to_8() -> void:
	spawn_arena(2, ID)
	var m := _sumo()
	for n in range(2, 9):
		for turn: float in [0.0, 0.7, 2.9, 5.5]:
			var pts := m.spawn_layout(n, turn)
			assert_eq(pts.size(), n, "%d points for %d players" % [n, n])
			_assert_even_ring(pts, BumperSumo.SPAWN_RADIUS, "sumo n=%d turn=%.1f" % [n, turn])
	# 8 players: the markers themselves (turn 0), in marker order.
	var markers := m.get_spawn_points()
	var eight := m.spawn_layout(8, 0.0)
	for i in 8:
		assert_true(eight[i].origin.distance_to(m.to_local(markers[i].origin)) < 0.001, "8 players: point %d is marker %d" % [i, i])


func _check_start_layout(n: int) -> void:
	var ps := spawn_arena(n, ID)
	var m := _sumo()
	_assert_even_ring(_player_points(m, ps), BumperSumo.SPAWN_RADIUS, "sumo %d players" % n)
	var slots := PackedInt32Array()
	for i in range(n - 1, -1, -1):
		slots.append(ps[i].slot)
	m._rpc_spawn_layout(1.25, slots)
	var pts := m.spawn_layout(n, 1.25)
	for i in n:
		var p := stage.get_player(slots[i])
		assert_true(m.to_local(p.global_position).distance_to(pts[i].origin) < 0.001, "slot %d on point %d" % [slots[i], i])
	await step(30)
	for p in ps:
		assert_true(p.alive and p.is_on_floor(), "%d players: P%d stands on the platform" % [n, p.slot])


func test_players_start_on_the_host_layout_3() -> void:
	await _check_start_layout(3)


func test_players_start_on_the_host_layout_5() -> void:
	await _check_start_layout(5)


func test_players_start_on_the_host_layout_8() -> void:
	await _check_start_layout(8)


func test_small_rounds_start_platform() -> void:
	spawn_arena(3, ID)
	var m := _sumo()
	# Balance pass: SMALL_ROUND_PLAYERS is 0, so 3 players get the full 9 m platform too.
	var small := 3 <= BumperSumo.SMALL_ROUND_PLAYERS
	assert_eq(m.platform_radius(), 7.0 if small else 9.0, "3 players' start platform")
	assert_eq(m.is_ring_solid(3), not small, "ring 3 present unless small rounds start on 7 m")
	assert_true(m.is_ring_solid(2), "ring 2 present")


func test_tuning_applied_on_every_player() -> void:
	var ps := spawn_arena(4, ID)
	for p in ps:
		var shove := p.get_component(&"shove") as ShoveComponent
		var status := p.get_component(&"status") as StatusComponent
		assert_eq(status.knockback_multiplier, BumperSumo.KNOCKBACK_MULTIPLIER, "sumo knockback")
		assert_eq(shove.force, BumperSumo.SHOVE_FORCE, "sumo shove force")
		assert_true(shove.cooldown < 0.6, "shorter shove cooldown")


func test_shove_near_edge_rings_out() -> void:
	var ps := spawn_arena(4, ID)
	var victim := ps[1]
	var outs := watch(victim, &"eliminated")
	await _shove(ps[0], victim, Vector3(5.4, 0, 0), Vector3(6.5, 0, 0))
	await step(150)
	assert_eq(outs.size(), 1, "victim eliminated once")
	if outs.size() == 1:
		assert_eq(outs[0][0], &"fell", "reason fell")
	assert_true(_sumo().knocked_out.has(victim.slot), "victim knocked out")
	assert_true(ps[0].alive, "shover stays in")


func test_shove_in_the_middle_does_not_ring_out() -> void:
	var ps := spawn_arena(4, ID)
	var victim := ps[1]
	var start := Vector3(0.55, 0, 0)
	await _shove(ps[0], victim, Vector3(-0.55, 0, 0), start)
	await step(150)
	var moved := victim.global_position.distance_to(start)
	print("  mid-platform shove slid the victim %.2f m" % moved)
	assert_true(moved > 3.0, "the shove really pushed (%.2f m)" % moved)
	assert_true(victim.alive, "victim still in")
	assert_true(_flat_r(victim) < 9.0 - 0.5, "victim still on the platform")
	assert_near(victim.global_position.y, 0.0, 0.1, "victim on top")


func test_rings_drop_on_schedule() -> void:
	spawn_arena(4, ID)
	var m := _sumo()
	var warned := watch(m, &"ring_warned")
	var dropped := watch(m, &"ring_dropped")
	var dt := physics_delta()
	# Just before the first warning.
	await step(int((BumperSumo.DROP_INTERVAL - BumperSumo.WARN_TIME) / dt) - 3)
	assert_eq(warned.size(), 0, "no warning yet")
	assert_true(m.is_safe(Vector3(7.5, 0, 0)), "ring 3 safe before the warning")
	await step(6)
	assert_eq(warned.size(), 1, "ring 3 warns at ~9.5 s")
	assert_eq(m.ring_states[3], BumperSumo.RingState.WARNING, "ring 3 warning")
	assert_false(m.is_safe(Vector3(7.5, 0, 0)), "a warning ring is unsafe for bots")
	assert_true(m.is_safe(Vector3(5.5, 0, 0)), "ring 2 still safe")
	assert_true(m.is_ring_solid(3), "still solid while warning")
	await step(int(BumperSumo.WARN_TIME / dt))
	assert_eq(dropped.size(), 1, "ring 3 dropped at ~12 s")
	assert_false(m.is_ring_solid(3), "ring 3 collider gone")
	assert_eq(m.platform_radius(), 7.0, "platform now 7 m")
	# A ray down onto ring 3 hits nothing any more, onto ring 2 it still hits.
	await step(1)
	assert_false(_ground_at(Vector3(8.0, 0, 0)), "nothing under r=8")
	assert_true(_ground_at(Vector3(6.0, 0, 0)), "ground under r=6")
	await step(int(BumperSumo.DROP_INTERVAL / dt) + 2)
	assert_eq(dropped.size(), 2, "ring 2 dropped at ~24 s")
	assert_false(m.is_ring_solid(2), "ring 2 collider gone")
	assert_true(m.is_ring_solid(1), "ring 1 still there")
	await step(int(BumperSumo.DROP_INTERVAL / dt) + 2)
	assert_eq(dropped.size(), 3, "ring 1 dropped at ~36 s")
	assert_eq(m.platform_radius(), 3.0, "only the core is left")
	assert_true(m.is_ring_solid(0), "the core never drops")
	assert_eq(dropped.map(func(a: Array) -> int: return a[0]), [3, 2, 1], "outermost first")
	assert_true(_ground_at(Vector3(1.0, 0, 1.0)), "ground on the core")


func test_player_on_dropping_ring_falls_out() -> void:
	var ps := spawn_arena(4, ID)
	var m := _sumo()
	var faller := ps[2]
	var outs := watch(faller, &"eliminated")
	_place(faller, Vector3(8.0, 0, 0))
	var dt := physics_delta()
	await step(int(BumperSumo.DROP_INTERVAL / dt) - 5)
	assert_true(faller.alive, "still in before the drop")
	assert_near(faller.global_position.y, 0.0, 0.1, "standing on ring 3 before the drop")
	await step(90)
	assert_eq(outs.size(), 1, "fell and was eliminated")
	if outs.size() == 1:
		assert_eq(outs[0][0], &"fell", "reason fell")
	assert_eq(m.knocked_out, [faller.slot] as Array[int], "only the faller is out")
	for p in ps:
		if p != faller:
			assert_true(p.alive, "P%d on ring 1 is fine" % p.slot)


func test_last_blob_standing_wins() -> void:
	var ps := spawn_arena(2, ID)
	var victim := ps[1]
	await _shove(ps[0], victim, Vector3(5.0, 0, 0), Vector3(6.1, 0, 0))
	await step(150)
	var m := _sumo()
	assert_true(m.is_finished(), "round over when one is left")
	assert_eq(ranking, [ps[0].slot, victim.slot] as Array[int], "survivor first")


func test_time_limit_without_session_ranks_survivors() -> void:
	var ps := spawn_arena(3, ID)
	var m := _sumo()
	# Everyone hops onto the core so nobody falls.
	for i in ps.size():
		_place(ps[i], Vector3(cos(i * 2.0), 0, sin(i * 2.0)) * 1.2)
	var done := await run_until_finished(int((m.time_limit + 2.0) / physics_delta()))
	assert_true(done, "finished at the time limit")
	assert_true(m.elapsed >= m.time_limit - 0.05, "not before the limit")
	assert_eq(ranking, [0, 1, 2] as Array[int], "survivors by slot")


func _ground_at(pos: Vector3) -> bool:
	var space := stage.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 2.0, pos + Vector3.DOWN * 3.0, 1)
	return not space.intersect_ray(q).is_empty()
