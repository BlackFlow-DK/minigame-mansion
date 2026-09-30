extends GameTest
## Floor Is Lava: tiles crack under grounded players and fall `crack_delay` later, players
## in the lava are knocked out, the late collapse ends every round, bots can play it.

const ID := &"floor_is_lava"


func _game() -> FloorIsLava:
	return get_minigame() as FloorIsLava


func _slots_ok(r: Array[int], count: int) -> bool:
	if r.size() != count:
		return false
	for s in count:
		if r.count(s) != 1:
			return false
	return true


func test_scene_loads_with_8_spawns_on_solid_tiles() -> void:
	var ps := spawn_arena(8, ID)
	var g := _game()
	assert_true(g != null, "root is FloorIsLava")
	if g == null:
		return
	assert_eq(g.rings, 5, "8 players play on 5 rings")
	assert_eq(g.solid_tiles().size(), 91, "5 rings = 91 tiles")
	var points := g.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn points")
	for pt in points:
		var i := g.tile_at(pt.origin)
		assert_true(i >= 0 and g.get_tile_state(i) == FloorIsLava.TileState.SOLID, "spawn on a solid tile")
		var to_centre := -Vector3(pt.origin.x, 0.0, pt.origin.z).normalized()
		assert_true((pt.basis * Vector3.MODEL_FRONT).dot(to_centre) > 0.95, "spawn faces the centre")
	for p in ps:
		assert_true(g.is_safe(p.global_position), "player %d starts on a solid tile" % p.slot)
	await step(30)
	for p in ps:
		assert_true(p.alive and p.is_on_floor(), "player %d stands on its tile" % p.slot)


func test_small_rounds_use_fewer_tiles_and_spawns_stay_on_the_field() -> void:
	spawn_arena(2, ID)
	var g := _game()
	assert_eq(g.rings, 3, "2 players play on 3 rings")
	assert_eq(g.solid_tiles().size(), 37, "3 rings = 37 tiles")
	for pt in g.get_spawn_points():
		assert_true(g.is_safe(pt.origin), "every spawn point exists in the smallest field")


func test_standing_still_player_falls_into_lava_and_is_knocked_out() -> void:
	var ps := spawn_arena(3, ID)
	var out := watch(ps[0], &"eliminated")
	var frames := 0
	while out.is_empty() and frames < 60 * 6:
		await step(1)
		frames += 1
	assert_eq(out.size(), 1, "the idle player was eliminated")
	if out.is_empty():
		return
	assert_true(String(out[0][0]).contains("lava"), "reason mentions lava: %s" % out[0][0])
	var g0 := _game()
	assert_true(g0.knocked_out.has(0), "recorded as knocked out")
	# grace 1.5 s + touch 0.5 s + crack 0.7 s + a fall of 1.2 m: about 3.0 s.
	var expect := g0.grace_time + g0.touch_time + g0.crack_delay + 0.3
	var secs := frames * physics_delta()
	assert_near(secs, expect, 0.25, "out after %.2f s" % secs)


func test_tile_cracks_then_falls_on_time_and_loses_its_collider() -> void:
	var ps := spawn_arena(2, ID)
	var g := _game()
	var tile := g.tile_at(ps[0].global_position)
	var cracked := watch(g, &"tile_cracked")
	var fell := watch(g, &"tile_fell")
	var crack_frame := -1
	var fall_frame := -1
	var collider_while_cracking := false
	for f in 60 * 3:
		await step(1)
		if crack_frame < 0 and _has_index(cracked, tile):
			crack_frame = f
			collider_while_cracking = g.tile_has_collider(tile)
			assert_eq(g.get_tile_state(tile), FloorIsLava.TileState.CRACKING, "cracking state")
			assert_false(g.is_safe(g.get_tile_position(tile)), "a cracking tile is not safe")
		if fall_frame < 0 and _has_index(fell, tile):
			fall_frame = f
			break
	assert_true(crack_frame >= 0, "tile under the idle player cracked")
	assert_true(fall_frame >= 0, "and fell")
	var crack_s := (crack_frame + 1) * physics_delta()
	var fall_s := (fall_frame - crack_frame) * physics_delta()
	assert_near(crack_s, g.grace_time + g.touch_time, 0.05, "cracks after the grace period plus touch_time")
	assert_near(fall_s, g.crack_delay, 0.05, "falls crack_delay later")
	assert_true(collider_while_cracking, "a cracking tile still holds you")
	assert_false(g.tile_has_collider(tile), "collider gone once it falls")
	assert_eq(g.get_tile_state(tile), FloorIsLava.TileState.FALLEN, "fallen state")
	await step(10)
	assert_true(ps[0].global_position.y < -0.2, "the player drops through")


func _has_index(events: Array, index: int) -> bool:
	for e: Array in events:
		if e[0] == index:
			return true
	return false


func test_late_collapse_ends_the_round_before_the_time_limit() -> void:
	var ps := spawn_arena(4, ID)
	var g := _game()
	g.grace_time = 1000.0  # players never crack tiles: only the collapse can end it
	var first_collapse := -1.0
	var cracked := watch(g, &"tile_cracked")
	var finished := false
	for f in 60 * 62:
		if g.is_finished():
			finished = true
			break
		if first_collapse < 0.0 and not cracked.is_empty():
			first_collapse = g.elapsed
			var first: int = cracked[0][0]
			assert_eq(g._ring(first), g.rings, "the outer ring goes first")
		await step(1)
	assert_true(finished, "round finished")
	assert_true(g.elapsed < g.time_limit - 5.0, "ended by the collapse at %.1f s" % g.elapsed)
	assert_near(first_collapse, g.collapse_start, 0.2, "collapse starts on time")
	assert_true(_slots_ok(ranking, ps.size()), "valid ranking %s" % str(ranking))


func test_time_limit_finishes_with_survivors_first() -> void:
	var ps := spawn_arena(3, ID)
	var g := _game()
	g.grace_time = 1000.0
	g.collapse_start = 1000.0
	g.time_limit = 1.0
	var done := await run_until_finished(90)
	assert_true(done, "finished at the time limit")
	assert_eq(ranking, [0, 1, 2] as Array[int], "survivors by slot")
	assert_eq(ps.size(), 3)


func test_is_safe_and_bot_goal() -> void:
	var ps := spawn_arena(4, ID)
	var g := _game()
	assert_true(g.is_safe(Vector3.ZERO), "centre tile is safe")
	assert_true(g.is_safe(Vector3(0.0, 5.0, 0.05)), "height does not matter")
	assert_false(g.is_safe(Vector3(40.0, 0.0, 0.0)), "off the field is not safe")
	var rim := g.get_tile_position(g.tile_at(Vector3(0.0, 0.0, 100.0).limit_length(4.0 * FloorIsLava.SQRT3 * FloorIsLava.SPACING)))
	assert_true(g.is_safe(rim), "centre of a rim tile is safe")
	assert_false(g.is_safe(rim + Vector3(0.0, 0.0, 0.8)), "its outer edge is not")
	var east := g.get_tile_position(g.tile_at(Vector3(1.5 * FloorIsLava.SPACING, 0.0, 0.0)))
	var centre := g.tile_at(Vector3.ZERO)
	g._rpc_crack(PackedInt32Array([centre]))
	assert_false(g.is_safe(Vector3.ZERO), "cracking tile is not safe")
	g._rpc_fall(PackedInt32Array([centre]))
	assert_false(g.is_safe(Vector3.ZERO), "fallen tile is not safe")
	var toward_hole := (Vector3.ZERO - east).normalized()
	assert_true(g.is_safe(east - toward_hole * 0.3), "next to a hole: the far side is safe")
	assert_false(g.is_safe(east + toward_hole * 0.75), "the edge by the hole is not")
	assert_false(g.tile_has_collider(centre), "fallen tile has no collider")
	var goals: Dictionary = {}
	var here := g.tile_at(ps[1].global_position)
	for k in 20:
		var goal := g.get_bot_goal(ps[1])
		var i := g.tile_at(goal)
		assert_true(i >= 0 and g.get_tile_state(i) == FloorIsLava.TileState.SOLID, "goal on a solid tile")
		var d := FloorIsLava._hex_distance(g._axial[here], g._axial[i])
		assert_true(d >= g.bot_goal_min and d <= g.bot_goal_max, "goal %d tiles away" % d)
		goals[i] = true
	assert_true(goals.size() >= 3, "goals vary (%d different)" % goals.size())


func test_bot_goal_falls_back_to_the_nearest_solid_tile() -> void:
	var ps := spawn_arena(2, ID)
	var g := _game()
	var keep := g.tile_at(ps[0].global_position + Vector3(1.59, 0.0, 0.0))
	var gone := PackedInt32Array()
	for i in g.tile_count():
		if i != keep and g.get_tile_state(i) == FloorIsLava.TileState.SOLID:
			gone.append(i)
	g._rpc_fall(gone)
	assert_eq(g.tile_at(g.get_bot_goal(ps[0])), keep, "the only solid tile left")


# --- Bot-only rounds -------------------------------------------------------------------------

func _bot_round(count: int, seed_value: int) -> void:
	seed(seed_value)
	var ps := spawn_arena(count, ID, false)
	# Slot 0 is the human: let a bot brain drive it too, so every slot plays.
	var brain := BotBrain.new()
	brain.player = ps[0]
	add_child(brain)
	brain.configure(seed_value * 31 + 7)
	var controller := ps[0].get_component(&"controller") as ControllerComponent
	controller.scripted = true
	var g := _game()
	var fallen := watch(g, &"tile_fell")
	var frames := 0
	while not g.is_finished() and frames < 60 * 65:
		await step(1, func(_i: int) -> void: brain.fill_intent(ps[0].intent, physics_delta()))
		frames += 1
	var secs := frames * physics_delta()
	print("  floor_is_lava bots=%d seed=%d: %.1f s, %d tiles fell, ranking %s" % [count, seed_value, secs, fallen.size(), str(ranking)])
	assert_true(g.is_finished(), "round finished")
	assert_true(_slots_ok(ranking, count), "every slot exactly once: %s" % str(ranking))
	assert_true(secs > 3.0, "not over in a flash (%.1f s)" % secs)
	assert_true(secs < g.time_limit, "ends before the time limit (%.1f s)" % secs)


func test_bot_round_4_seed_1() -> void:
	await _bot_round(4, 1)


func test_bot_round_4_seed_2() -> void:
	await _bot_round(4, 2)


func test_bot_round_4_seed_3() -> void:
	await _bot_round(4, 3)


func test_bot_round_8_seed_1() -> void:
	await _bot_round(8, 11)


func test_bot_round_8_seed_2() -> void:
	await _bot_round(8, 12)


func test_bot_round_8_seed_3() -> void:
	await _bot_round(8, 13)
