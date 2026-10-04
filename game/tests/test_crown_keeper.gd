extends GameTest
## Crown Keeper: room, pickup, points, knock-offs and their no-grab windows, the idle
## return, the double-points finale, ranking and tie-break. Offline through the harness; the
## host is this process. Bot rounds live in test_crown_keeper_bots.gd.

const ID := &"crown_keeper"


func _mg() -> CrownKeeper:
	return get_minigame() as CrownKeeper


func _place(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))
	p.velocity = Vector3.ZERO


func _max_speed(p: Player) -> float:
	return (p.get_component(&"movement") as MovementComponent).max_speed


## Puts every player but the listed ones out of the way (near the walls, spread out).
func _park_others(keep: Array[Player]) -> void:
	var i := 0
	for p in players:
		if keep.has(p):
			continue
		var a := TAU * (0.1 + 0.13 * i)
		_place(p, Vector3(sin(a), 0.0, cos(a)) * 8.2)
		i += 1


# --- Room ----------------------------------------------------------------------------------------

func test_scene_loads_with_8_safe_spawns() -> void:
	var ps := spawn_arena(8, ID)
	var mg := _mg()
	assert_true(mg != null, "crown_keeper loads")
	assert_eq(mg.time_limit, 60.0, "60 s round")
	var points := mg.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn points")
	for t in points:
		assert_true(mg.is_safe(t.origin), "spawn %s is safe" % t.origin)
		var r := Vector2(t.origin.x, t.origin.z).length()
		assert_near(r, 6.5, 0.01, "every spawn the same distance from the throne")
	assert_eq(mg.crown_state, CrownKeeper.CrownState.THRONE, "the crown starts on the throne")
	assert_eq(mg.holder_slot, -1, "nobody wears it")
	await step(30)
	for i in ps.size():
		assert_true(ps[i].is_on_floor(), "P%d stands on the floor" % i)
		assert_near(ps[i].global_position, points[i].origin, 0.2, "P%d stays at its spawn" % i)


func test_walls_keep_everyone_inside() -> void:
	var ps := spawn_arena(3, ID)
	var dirs := [Vector2(0, 1), Vector2(1, 0), Vector2(-0.7, -0.7)]
	await step(300, func(i: int) -> void:
		for k in ps.size():
			ps[k].intent.move = dirs[k]
			ps[k].intent.jump_pressed = i % 20 == 0
			ps[k].intent.jump_held = true)
	for p in ps:
		assert_true(CrownKeeper.in_octagon(p.global_position, CrownKeeper.PLAY_APOTHEM + 0.05),
			"P%d inside the walls (%s)" % [p.slot, p.global_position])


func test_dais_steps_can_be_jumped() -> void:
	var ps := spawn_arena(2, ID)
	var p := ps[0]
	_park_others([p])
	_place(p, Vector3(0.0, 0.0, 4.5))
	# Walk at the throne, hopping: the steps are 0.25 m each.
	await step(150, func(i: int) -> void:
		p.intent.move = Vector2(0, -1)
		p.intent.jump_pressed = i % 25 == 0
		p.intent.jump_held = true)
	assert_true(p.global_position.y > CrownKeeper.DAIS_H2 - 0.05, "up on the top step (y=%.2f)" % p.global_position.y)


# --- Pickup ------------------------------------------------------------------------------------------

func test_touch_on_the_throne_takes_the_crown() -> void:
	var ps := spawn_arena(4, ID)
	var mg := _mg()
	var taken := watch(mg, &"crown_taken")
	_park_others([ps[2]])
	await step(2)
	assert_true(taken.is_empty(), "nobody near the throne: no pickup")
	# On the top step at the back of the throne (the reach covers every side).
	_place(ps[2], Vector3(0.0, CrownKeeper.DAIS_H2, -1.4))
	await step(3)
	assert_eq(taken.size(), 1, "touching the throne took the crown")
	if not taken.is_empty():
		assert_eq(taken[0], [2, true], "P2 took it off the throne")
	assert_eq(mg.holder_slot, 2, "P2 wears it")
	assert_eq(mg.crown_state, CrownKeeper.CrownState.WORN, "worn")
	assert_eq(mg.crown_changes, 1, "one pickup")


func test_standing_below_the_dais_does_not_take_it() -> void:
	var ps := spawn_arena(2, ID)
	var mg := _mg()
	_park_others([ps[0]])
	_place(ps[0], Vector3(0.0, 0.0, 3.3))  # on the floor in front of the dais
	await step(20)
	assert_eq(mg.holder_slot, -1, "the crown stays on the throne")


func test_wearer_is_slower_and_cannot_shove() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	var base := _max_speed(ps[1])
	mg.give_crown(1)
	await step(2)
	assert_near(_max_speed(ps[1]), base * mg.wearer_speed_factor, 0.001, "wearer runs 8 % slower")
	assert_near(_max_speed(ps[0]), base, 0.001, "others at normal speed")
	assert_false((ps[1].get_component(&"shove") as ShoveComponent).enabled, "wearer's shove is off")
	assert_true((ps[0].get_component(&"shove") as ShoveComponent).enabled, "others can shove")
	# The wearer's action does not hit anyone.
	_park_others([ps[0], ps[1]])
	_place(ps[1], Vector3(-4.0, 0.0, 0.0))
	_place(ps[0], Vector3(-2.9, 0.0, 0.0))
	ps[1].facing = Vector3.RIGHT
	var hit := watch(ps[0], &"got_hit")
	await step(20, func(i: int) -> void: ps[1].intent.action_pressed = i == 0)
	assert_true(hit.is_empty(), "the wearer's action shoves nobody")
	mg.knock_off(ps[1], Vector3.LEFT)
	await step(2)
	assert_near(_max_speed(ps[1]), base, 0.001, "speed back once the crown is off")
	assert_true((ps[1].get_component(&"shove") as ShoveComponent).enabled, "shove back once the crown is off")


func test_wearer_hat_hidden_under_the_crown_and_restored() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	var wearer := ps[1]
	wearer.loadout["hat"] = "crown"  # a cosmetic crown: it must never stack with the royal one
	var cos := wearer.get_component(&"cosmetics") as CosmeticsComponent
	cos.refresh()
	var hat_node := func() -> Node:
		var root := (wearer.get_component(&"visuals") as VisualsComponent).get_model_root()
		var socket := root.find_child("HatSocket", true, false) if root else null
		return socket.get_node_or_null(^"Cosmetic_hat") if socket else null
	assert_true(hat_node.call() != null, "the cosmetic crown is on before")
	var tag := NameTag.of(wearer)
	mg.give_crown(1)
	await step(2)
	assert_true(mg.is_hat_hidden(wearer), "hat hidden while wearing the royal crown")
	assert_eq(str(cos.shown_look().get("hat", "")), "", "shown look has no hat")
	assert_true(hat_node.call() == null, "no hat model under the crown")
	assert_eq(str(wearer.loadout.get("hat", "")), "crown", "the real loadout is untouched")
	if tag:
		assert_near(tag.raise, CrownKeeper.WEARER_TAG_RAISE, 0.001, "name tag raised over the crown")
	assert_false(mg.is_hat_hidden(ps[0]), "nobody else loses a hat")
	mg.knock_off(wearer, Vector3.LEFT)
	await step(2)
	assert_false(mg.is_hat_hidden(wearer), "hat back once the crown is off")
	assert_false(cos.has_look_override(), "override cleared")
	assert_true(hat_node.call() != null, "the cosmetic crown is back")
	if tag:
		assert_eq(tag.raise, 0.0, "name tag back down")
	# Wearing at the end of the round, then the stage clears: the hat still comes back.
	mg.give_crown(2)
	await step(2)
	var cos2 := ps[2].get_component(&"cosmetics") as CosmeticsComponent
	var had_hat := str(ps[2].loadout.get("hat", "")) != ""
	assert_eq(mg.is_hat_hidden(ps[2]), had_hat, "P2's hat hidden if it has one")
	var parent := mg.get_parent()
	parent.remove_child(mg)
	assert_false(cos2.has_look_override(), "leaving the tree restores the hat")
	parent.add_child(mg)


# --- Points ----------------------------------------------------------------------------------------------

func test_points_accrue_once_per_second_for_the_wearer_only() -> void:
	var ps := spawn_arena(4, ID)
	var mg := _mg()
	var snaps := watch(mg, &"scores_changed")
	mg.give_crown(1)
	await step(59)
	assert_eq(mg.scores[1], 0, "nothing before a full second")
	await step(2)
	assert_eq(mg.scores[1], 1, "1 point after 1 s")
	await step(120)
	assert_eq(mg.scores[1], 3, "3 points after ~3 s")
	for s in [0, 2, 3]:
		assert_eq(mg.scores[s], 0, "P%d has nothing" % s)
	assert_eq(snaps.size(), 3, "one snapshot per point")
	# The wearer keeps its seconds across holds: 0.5 s + 0.5 s worn = 1 point.
	mg.knock_off(ps[1], Vector3.RIGHT)
	mg.give_crown(2)
	await step(30)
	mg.knock_off(ps[2], Vector3.RIGHT)
	await step(30)
	mg.give_crown(2)
	await step(32)
	assert_eq(mg.scores[2], 1, "worn time adds up across holds")
	assert_eq(mg.scores[1], 3, "P1 keeps its points")


func test_double_points_in_the_finale() -> void:
	spawn_arena(2, ID)
	var mg := _mg()
	var coronation := watch(mg, &"coronation_started")
	mg.give_crown(0)
	mg.set_round_time(mg.time_limit - mg.double_window - 1.0)
	await step(30)
	assert_false(mg.double_time, "not yet")
	await step(40)
	assert_true(mg.double_time, "finale started")
	assert_eq(coronation.size(), 1, "announced once")
	var before: int = mg.scores[0]
	await step(120)
	assert_eq(mg.scores[0] - before, 4, "2 s in the finale = 4 points")


# --- Knock-off ------------------------------------------------------------------------------------------

func test_shove_on_wearer_launches_the_crown_along_the_shove() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	mg.rng.seed = 11
	_park_others([ps[0], ps[1]])
	_place(ps[1], Vector3(-4.0, 0.0, 1.0))
	_place(ps[0], Vector3(-5.2, 0.0, 1.0))
	await step(1)
	mg.give_crown(1)
	var knocked := watch(mg, &"crown_knocked")
	await step(30)  # past the wear shield
	ps[0].facing = Vector3.RIGHT
	var victim_at := ps[1].global_position
	await step(3, func(i: int) -> void: ps[0].intent.action_pressed = i == 0)
	assert_eq(knocked.size(), 1, "the shove knocked the crown off")
	if knocked.is_empty():
		return
	assert_eq(knocked[0][0], 1, "off P1")
	assert_eq(mg.holder_slot, -1, "nobody wears it")
	assert_eq(mg.crown_state, CrownKeeper.CrownState.LOOSE, "loose")
	var land: Vector3 = knocked[0][1]
	var off := land - victim_at
	var flat := Vector2(off.x, off.z)
	assert_true(flat.length() > 1.5 and flat.length() < 3.6, "lands 2-3 m away (%.2f)" % flat.length())
	assert_true(flat.normalized().dot(Vector2.RIGHT) > 0.85, "along the shove (+X): %s" % flat)
	assert_near(land.y, CrownKeeper.ground_height(land), 0.001, "rests on the floor")
	# The flight is the pure arc: it starts at the head and ends on the landing spot.
	var from := mg.crown_position()
	assert_true(from.y > 1.0, "starts up at the head")
	await step(60)
	assert_near(mg.crown_position(), land, 0.001, "came to rest on the landing spot")


func test_no_grab_windows_after_a_knock() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	mg.rng.seed = 5
	_park_others([ps[0], ps[1], ps[2]])
	_place(ps[0], Vector3(-5.0, 0.0, 1.0))
	await step(1)
	mg.give_crown(0)
	await step(1)
	mg.knock_off(ps[0], Vector3.RIGHT)
	var land := mg.landing_spot()
	var taken := watch(mg, &"crown_taken")
	# The previous wearer stands right where the crown lands (it arrives there at ~0.83 s).
	_place(ps[0], land)
	await step(60)  # 1.0 s
	assert_true(taken.is_empty(), "the previous wearer cannot re-grab inside 1.2 s")
	assert_eq(mg.blocked_slot(), 0, "P0 is blocked")
	await step(18)  # 1.3 s
	assert_eq(taken.size(), 1, "after 1.2 s it may")
	if not taken.is_empty():
		assert_eq(taken[0], [0, false], "P0 picked it up off the floor")
	# Anyone else: not before 0.4 s even when touching it all the way.
	mg.knock_off(ps[0], Vector3.LEFT)
	_place(ps[0], Vector3(8.0, 0.0, -2.0))
	taken.clear()
	var frames := 0
	while taken.is_empty() and frames < 120:
		await step(1, func(_i: int) -> void: _place(ps[1], mg.crown_position() + Vector3.DOWN * 0.5))
		frames += 1
	assert_eq(taken.size(), 1, "P1 grabbed it")
	assert_true(frames >= 24 and frames <= 27, "first grab at 0.4 s (frame %d)" % frames)
	if not taken.is_empty():
		assert_eq(taken[0][0], 1, "P1 has it")


func test_wear_shield_blocks_an_instant_second_knock() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	_park_others([ps[0], ps[1]])
	_place(ps[1], Vector3(-4.0, 0.0, 1.0))
	_place(ps[0], Vector3(-5.2, 0.0, 1.0))
	await step(1)
	mg.give_crown(1)
	var knocked := watch(mg, &"crown_knocked")
	ps[0].facing = Vector3.RIGHT
	await step(3, func(i: int) -> void: ps[0].intent.action_pressed = i == 0)
	assert_true(knocked.is_empty(), "a shove inside the wear shield does nothing")
	assert_eq(mg.holder_slot, 1, "P1 keeps it")


func test_landing_spots_stay_in_the_room_and_off_obstacles() -> void:
	spawn_arena(2, ID)
	for i in 400:
		var a := TAU * i / 400.0
		var p := Vector3(sin(a), 0.0, cos(a)) * (float(i % 23) * 0.5)
		var l := CrownKeeper.clamp_landing(p)
		assert_true(CrownKeeper.in_octagon(l, CrownKeeper.LAND_APOTHEM + 0.001), "inside the room: %s" % l)
		for c in CrownKeeper.PILLARS:
			assert_true(Vector2(l.x - c.x, l.z - c.z).length() > 0.9, "off pillar %s: %s" % [c, l])
		var tz := l.z - CrownKeeper.THRONE_POS.z
		assert_false(absf(l.x) < CrownKeeper.THRONE_HALF_X + 0.2 and tz > CrownKeeper.THRONE_Z_MIN - 0.2 \
			and tz < CrownKeeper.THRONE_Z_MAX + 0.2, "off the throne: %s" % l)
	assert_near(CrownKeeper.ground_height(Vector3(0, 0, 1.5)), CrownKeeper.DAIS_H2, 0.001, "top step")
	assert_near(CrownKeeper.ground_height(Vector3(0, 0, 2.5)), CrownKeeper.DAIS_H1, 0.001, "lower step")
	assert_near(CrownKeeper.ground_height(Vector3(0, 0, 5.0)), 0.0, 0.001, "floor")


func test_idle_crown_returns_to_the_throne() -> void:
	var ps := spawn_arena(2, ID)
	var mg := _mg()
	_park_others([ps[0]])
	_place(ps[0], Vector3(-5.0, 0.0, 1.0))
	await step(1)
	mg.give_crown(0)
	await step(1)
	mg.knock_off(ps[0], Vector3.LEFT)
	_place(ps[0], Vector3(6.0, 0.0, -2.0))
	var returned := watch(mg, &"crown_returned")
	await step(290)
	assert_true(returned.is_empty(), "still loose before 5 s")
	await step(15)
	assert_eq(returned.size(), 1, "back on the throne after 5 s untouched")
	assert_eq(mg.crown_state, CrownKeeper.CrownState.THRONE, "on the throne")
	assert_near(mg.crown_position(), CrownKeeper.THRONE_REST, 0.001, "at the seat")


func test_wearer_leaving_sends_the_crown_home() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	var returned := watch(mg, &"crown_returned")
	mg.give_crown(2)
	await step(2)
	mg.knock_out(ps[2], &"left")
	await step(2)
	assert_eq(returned.size(), 1, "the crown went home")
	assert_eq(mg.holder_slot, -1, "nobody wears it")


# --- Ranking -------------------------------------------------------------------------------------------------

func test_rank_by_points_and_tie_break() -> void:
	var slots: Array[int] = [0, 1, 2, 3]
	var ranking := CrownKeeper.rank_by_points(slots, {0: 5, 1: 9, 2: 5, 3: 0}, {0: 10.0, 1: 30.0, 2: 41.0, 3: -1.0})
	assert_eq(ranking, [1, 2, 0, 3] as Array[int], "points, then who wore it last")
	ranking = CrownKeeper.rank_by_points(slots, {0: 0, 1: 0, 2: 0, 3: 0}, {0: -1.0, 1: -1.0, 2: -1.0, 3: -1.0})
	assert_eq(ranking, [0, 1, 2, 3] as Array[int], "nobody scored: by slot")


func test_round_ends_at_the_time_limit_with_a_ranking() -> void:
	var ps := spawn_arena(3, ID)
	var mg := _mg()
	mg.time_limit = 4.0
	mg.double_window = 1.0
	var over := watch(mg, &"round_over")
	mg.give_crown(1)
	await step(90)
	mg.knock_off(ps[1], Vector3.RIGHT)
	mg.give_crown(2)
	await step(90)  # P1 1.5 s, P2 1.5 s: a tie on points; P2 wore it last
	mg.knock_off(ps[2], Vector3.LEFT)
	var finished := await run_until_finished(120)
	assert_true(finished, "finished at the time limit")
	assert_eq(ranking.size(), 3, "every slot ranked")
	assert_eq(over.size(), 1, "round_over once")
	assert_eq(mg.scores[1], mg.scores[2], "P1 and P2 tie on points (%d)" % mg.scores[1])
	assert_eq(ranking, [2, 1, 0] as Array[int], "tie goes to whoever wore it last")
	assert_near(mg.finish_grace, mg.end_grace, 0.001, "end grace for the winner's moment")
	assert_eq(mg.final_ranking, ranking, "every peer gets the ranking")
	assert_eq(mg.holder_slot, 2, "the winner gets the crown for the celebration")
