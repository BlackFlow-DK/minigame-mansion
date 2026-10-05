extends GameTest
## Ghost Tag: the attic map, starting ghosts and head start, catches (touch, shove), the boo and
## the rise, the living's shove defence, chains, the early end, the ranking rule, the ghost look
## being restored on every exit path, and the lights per quality. Offline through the harness.

const ID := &"ghost_tag"
const HEAD_FRAMES := 180  # 3 s head start at 60 ticks/s


func _mg() -> GhostTag:
	return get_minigame() as GhostTag


## Spawns `count` scripted players with slot 0 as the only starting ghost.
func _arena(count: int) -> GhostTag:
	spawn_arena(count, ID)
	var mg := _mg()
	mg.set_starting_ghosts([0] as Array[int])
	return mg


## Spawns, then plays the head start out (the ghost is awake when this returns).
func _awake_arena(count: int) -> GhostTag:
	var mg := _arena(count)
	await step(HEAD_FRAMES + 2)
	return mg


func _put(p: Player, at: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, at))
	p.velocity = Vector3.ZERO


func _speed(p: Player) -> float:
	return (p.get_component(&"movement") as MovementComponent).max_speed


## The blob's look right now: per mesh [transparency, overlay], plus the feet's visibility.
func _look_of(p: Player) -> Array:
	var root := (p.get_component(&"visuals") as VisualsComponent).get_model_root()
	var out: Array = []
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		if String(n.get_path()).contains("GhostTag"):
			continue
		var g := n as GeometryInstance3D
		out.append([String(root.get_path_to(g)), g.transparency, g.material_overlay])
	for f: String in ["FootL", "FootR"]:
		var foot := root.find_child(f, true, false) as Node3D
		out.append([f, foot.visible if foot else null])
	return out


## Every player's normal look (slot -> _look_of), taken while it is not a ghost: the random
## starting ghosts are swapped for another player for the snapshot. Leaves `ghosts` as the
## starting ghosts.
func _normal_looks(mg: GhostTag, ghosts: Array[int]) -> Dictionary:
	var snap: Dictionary = {}
	var first := mg.original_ghosts.duplicate()
	for p in players:
		if not first.has(p.slot):
			snap[p.slot] = _look_of(p)
	var other: Array[int] = []
	for p in players:
		if not first.has(p.slot):
			other.append(p.slot)
			break
	mg.set_starting_ghosts(other)
	for s in first:
		snap[s] = _look_of(players[s])
	mg.set_starting_ghosts(ghosts)
	return snap


func _has_our_nodes(p: Player) -> bool:
	var root := (p.get_component(&"visuals") as VisualsComponent).get_model_root()
	return root.find_child("GhostTagSheet", true, false) != null or root.find_child("GhostTagLantern", true, false) != null


# --- Map ---------------------------------------------------------------------------------------

func test_map_loads_with_spawns_spread_around_the_loop() -> void:
	var ps := spawn_arena(8, ID)
	var mg := _mg()
	assert_true(mg != null, "ghost_tag loads")
	assert_eq(mg.time_limit, 60.0, "60 s round")
	assert_eq(mg.music_track, &"vault_jazz", "an existing music track")
	assert_true(Music.TRACKS.has(mg.music_track), "track exists")
	var pts := mg.get_spawn_points()
	assert_eq(pts.size(), 8, "8 spawn points")
	for i in pts.size():
		var o := pts[i].origin
		assert_true(mg.is_safe(o), "spawn %d on open floor" % i)
		assert_eq(mg.map.nearest_nav(o), mg.map.index_of(o), "spawn %d has room for a blob" % i)
		assert_true(absf(o.x) >= 9.0 or absf(o.z) >= 6.0, "spawn %d on the ring corridor" % i)
		for j in range(i + 1, pts.size()):
			var d := Vector2(o.x - pts[j].origin.x, o.z - pts[j].origin.z).length()
			assert_true(d >= 6.5, "spawns %d and %d %.1f m apart" % [i, j, d])
			if i < 4 and j < 4:
				assert_true(d >= 13.5, "first four spawns spread out (%d-%d: %.1f m)" % [i, j, d])
	# one connected loop: every nav cell reachable from spawn 0
	var field := mg.map.bfs(PackedInt32Array([mg.map.index_of(pts[0].origin)]))
	var unreached := 0
	for k in mg.map.nav_cells:
		if field[k] < 0:
			unreached += 1
	assert_eq(unreached, 0, "every walkable cell is connected")
	assert_true(mg.map.nav_cells.size() > 400, "plenty of room (%d nav cells)" % mg.map.nav_cells.size())
	await step(30)
	for i in ps.size():
		assert_true(ps[i].is_on_floor(), "P%d stands on the attic floor" % i)
		assert_near(ps[i].global_position, pts[i].origin, 0.2, "P%d at its spawn" % i)


func test_walls_hold_and_bots_stay_on_the_floor() -> void:
	var ps := spawn_arena(2, ID)
	var mg := _mg()
	mg.set_starting_ghosts([1] as Array[int])
	_put(ps[0], Vector3(-6.0, 0.0, -7.25))
	# run north into the tall wall, hopping, for 2 s; then west into the corner
	await step(120, func(i: int) -> void:
		ps[0].intent.move = Vector2(0, -1) if i < 60 else Vector2(-1, -0.3)
		ps[0].intent.jump_pressed = i % 20 == 0
		ps[0].intent.jump_held = true)
	var p := ps[0].global_position
	assert_true(p.z > -8.5 + 0.35 and p.x > -11.5 + 0.35, "still inside the walls (%s)" % p)
	assert_true(mg.is_safe(Vector3(p.x, 0, p.z)), "where it stands is safe for bots")
	assert_false(mg.is_safe(Vector3(0, 0, -8.8)), "inside the outer wall is not safe")
	assert_false(mg.is_safe(Vector3(5, 0, -1.25)), "inside a room wall is not safe")
	assert_false(mg.is_safe(Vector3(20, 0, 0)), "outside the attic is not safe")
	# an interior wall cannot be hopped either (colliders are 3 m tall)
	_put(ps[0], Vector3(5.0, 0.0, -0.5))
	await step(90, func(i: int) -> void:
		ps[0].intent.move = Vector2(0, -1)
		ps[0].intent.jump_pressed = i % 15 == 0
		ps[0].intent.jump_held = true)
	assert_true(ps[0].global_position.z > -1.5, "the room wall holds (z %.2f)" % ps[0].global_position.z)


# --- Starting ghosts and the head start -------------------------------------------------------

func test_ghost_count_by_player_count() -> void:
	for n in range(1, 9):
		assert_eq(GhostTag.ghost_count_for(n), 2 if n >= 7 else 1, "%d players" % n)
	spawn_arena(4, ID)
	var mg := _mg()
	assert_eq(mg.original_ghosts.size(), 1, "4 players: one ghost")
	var g := mg.original_ghosts[0]
	assert_eq(mg.role_of(g), "You are the GHOST", "ghost role line")
	for p in players:
		if p.slot != g:
			assert_eq(mg.role_of(p.slot), "Run!", "P%d role line" % p.slot)
	assert_eq(mg.looks().ghost_look_slots(), mg.original_ghosts, "ghost look on the ghost only")


func test_eight_players_get_two_ghosts() -> void:
	spawn_arena(8, ID)
	var mg := _mg()
	assert_eq(mg.original_ghosts.size(), 2, "8 players: two ghosts")
	assert_eq(mg.looks().ghost_look_slots(), mg.original_ghosts, "both look like ghosts")
	var picks: Dictionary = {}
	var r := RandomNumberGenerator.new()
	for i in 400:
		r.seed = i
		for s in GhostTag.pick_ghosts([0, 1, 2, 3, 4, 5, 6, 7] as Array[int], r):
			picks[s] = int(picks.get(s, 0)) + 1
	for s in 8:
		assert_true(int(picks.get(s, 0)) > 60 and int(picks.get(s, 0)) < 140, "slot %d starts as a ghost fairly often (%d of 800)" % [s, picks.get(s, 0)])


func test_head_start_freezes_the_ghost() -> void:
	var mg := _arena(4)
	var ps := players
	var caught := watch(mg, &"caught")
	var woke := watch(mg, &"ghosts_woke")
	_put(ps[1], ps[0].global_position + Vector3(0.85, 0, 0))
	var p2_start := ps[2].global_position
	await step(HEAD_FRAMES - 10, func(_i: int) -> void:
		ps[0].intent.move = Vector2(1, 0)
		ps[2].intent.move = Vector2(0, 1) if ps[2].global_position.z < 0 else Vector2(0, -1))
	assert_true(ps[0].frozen, "the ghost is frozen during the head start")
	assert_false(mg.awake, "not awake yet")
	assert_true(caught.is_empty(), "no catch while it sleeps, even touching")
	assert_true(ps[2].global_position.distance_to(p2_start) > 2.0, "the living run")
	await step(20)
	assert_eq(woke.size(), 1, "it wakes after 3 s")
	assert_true(mg.awake, "awake")
	assert_eq(caught.size(), 1, "the touching blob is caught at once")
	await step(40)
	assert_false(ps[0].frozen, "after the boo the ghost moves freely")


# --- Catches -----------------------------------------------------------------------------------

func test_touch_catches_then_converts_after_the_boo() -> void:
	var mg := await _awake_arena(4)
	var ps := players
	var caught := watch(mg, &"caught")
	var converted := watch(mg, &"converted")
	_put(ps[1], ps[0].global_position + Vector3(0.9, 0, 0))
	await step(1)
	assert_eq(caught.size(), 1, "a touch catches")
	if caught.is_empty():
		return
	assert_eq(caught[0][0], 0, "by the ghost")
	assert_eq(caught[0][1], 1, "P1")
	assert_true(ps[0].frozen and ps[1].frozen, "boo: both frozen")
	assert_false(mg.is_ghost(1), "not a ghost yet")
	assert_false(mg.is_living(1), "but no longer living")
	await step(30)
	assert_true(converted.is_empty(), "still in the boo at 0.5 s")
	await step(8)
	assert_eq(converted.size(), 1, "turned after the 0.6 s boo")
	assert_true(mg.is_ghost(1), "P1 is a ghost")
	assert_true(mg.looks().is_ghost_look(1), "and looks like one")
	assert_false(ps[0].frozen, "the ghost goes on")
	assert_true(ps[1].frozen, "the new ghost is still rising")
	await step(62)
	assert_false(ps[1].frozen, "risen after 1 s")
	assert_near(_speed(ps[1]), 6.0 * mg.ghost_speed_bonus, 0.001, "ghosts run 6 % faster")
	assert_near(_speed(ps[2]), 6.0, 0.001, "the living at normal speed")
	assert_eq(mg.credit[0], 1.0, "credited to the ghost")


func test_ghost_shove_catches() -> void:
	var mg := await _awake_arena(4)
	var ps := players
	var caught := watch(mg, &"caught")
	_put(ps[1], ps[0].global_position + Vector3(1.25, 0, 0))
	ps[0].facing = Vector3.RIGHT
	await step(1)
	assert_true(caught.is_empty(), "1.25 m apart is no touch")
	await step(3, func(i: int) -> void: ps[0].intent.action_pressed = i == 0)
	assert_eq(caught.size(), 1, "a landed ghost shove catches")
	if not caught.is_empty():
		assert_eq(caught[0][1], 1, "P1 caught")


func test_living_shove_on_a_ghost_only_stuns_it() -> void:
	var mg := await _awake_arena(4)
	var ps := players
	var caught := watch(mg, &"caught")
	var ghost_hit := watch(ps[0], &"got_hit")
	var ghost_stun := watch(ps[0], &"stunned")
	var living_hit := watch(ps[3], &"got_hit")
	# P1 shoves the ghost; P2 shoves P3 far away (a living-on-living shove to compare)
	_put(ps[1], ps[0].global_position + Vector3(1.2, 0, 0))
	ps[1].facing = Vector3.LEFT
	_put(ps[2], Vector3(10.25, 0, 4.0))
	_put(ps[3], Vector3(10.25, 0, 2.8))
	ps[2].facing = Vector3.FORWARD
	await step(3, func(i: int) -> void:
		ps[1].intent.action_pressed = i == 0
		ps[2].intent.action_pressed = i == 0)
	assert_eq(ghost_hit.size(), 1, "the shove landed on the ghost")
	assert_eq(living_hit.size(), 1, "the other shove landed on P3")
	if ghost_hit.is_empty() or living_hit.is_empty():
		return
	var ratio := (ghost_hit[0][0] as Vector3).length() / (living_hit[0][0] as Vector3).length()
	assert_near(ratio, mg.ghost_knockback, 0.02, "the ghost is only nudged (%.2f of a normal shove)" % ratio)
	assert_eq(ghost_stun.size(), 1, "the ghost is stunned")
	if not ghost_stun.is_empty():
		assert_near(ghost_stun[0][0], mg.ghost_shove_stun, 0.001, "for 0.4 s")
	assert_true(mg.is_ghost(0), "still a ghost")
	assert_true(mg.is_living(1), "the shover is fine")
	# a stunned ghost cannot catch, even touching (P1 waits on the side it slides toward)
	_put(ps[1], ps[0].global_position + Vector3(-0.85, 0, 0))
	await step(10)
	assert_true((ps[0].get_component(&"status") as StatusComponent).is_stunned(), "still stunned")
	assert_true(caught.is_empty(), "no catch while stunned")
	await step(20)
	_put(ps[1], ps[0].global_position + Vector3(-0.85, 0, 0))
	await step(2)
	assert_eq(caught.size(), 1, "the stun wore off: caught")


func test_conversion_chain_timing() -> void:
	var mg := await _awake_arena(4)
	var ps := players
	var caught := watch(mg, &"caught")
	var t0 := mg.round_time()
	_put(ps[1], ps[0].global_position + Vector3(0.9, 0, 0))
	await step(1)
	# P2 presses against the fresh victim the whole time
	_put(ps[2], ps[1].global_position + Vector3(0.85, 0, 0.0))
	await step(90, func(_i: int) -> void: ps[2].intent.move = Vector2(-0.2, 0))
	assert_eq(caught.size(), 1, "no chain catch during the boo and the rise (1.6 s)")
	await step(15, func(_i: int) -> void: ps[2].intent.move = Vector2(-0.2, 0))
	assert_eq(caught.size(), 2, "the risen ghost catches the next one")
	if caught.size() < 2:
		return
	assert_eq(caught[1][0], 1, "P1 caught P2")
	var gap := float(caught[1][2]) - float(caught[0][2])
	assert_true(gap >= mg.boo_time + mg.rise_time - 0.02, "chain gap %.2f s >= boo + rise" % gap)
	assert_true(float(caught[0][2]) >= t0, "times on the round clock")
	assert_eq(mg.credit[0], 1.0 + mg.chain_credit, "the starting ghost is credited with the chain")
	assert_eq(mg.lineage[2], 0, "P2 belongs to P0's chain")


func test_early_end_when_everyone_is_caught() -> void:
	var mg := await _awake_arena(2)
	var ps := players
	var over := watch(mg, &"round_over")
	_put(ps[1], ps[0].global_position + Vector3(0.9, 0, 0))
	await step(1)
	assert_true(mg.is_finished(), "the last catch ends the round at once")
	assert_near(mg.finish_grace, 2.0, 0.001, "2 s end grace")
	assert_eq(ranking, [0, 1] as Array[int], "the ghost caught everyone: first")
	assert_eq(over.size(), 1, "every peer is told")
	assert_false(mg.looks().is_ghost_look(0), "the curse lifts at the end")


func test_time_out_ranks_survivors_first_then_by_time() -> void:
	var mg := await _awake_arena(4)
	var ps := players
	_put(ps[1], ps[0].global_position + Vector3(0.9, 0, 0))
	await step(1)
	var t1: float = mg.caught_at[1]
	# keep the ghosts away from P2 and P3, speed the clock up for the rest of the round
	_put(ps[2], Vector3(10.25, 0, 7.0))
	_put(ps[3], Vector3(10.25, 0, -7.0))
	mg.time_scale = 8.0
	var ok := await run_until_finished(60 * 20)
	assert_true(ok, "the round times out")
	assert_near(mg.round_time(), 60.0, 0.2, "at 60 s")
	assert_eq(mg.finish_groups, [[2, 3], [0], [1]], "survivors tied first, the ghost (1/3 = 20 s) above P1 (%.1f s)" % t1)
	assert_true(mg.finish_groups[0] is Array and (mg.finish_groups[0] as Array).size() == 2, "a tied group")


func test_ranking_rule() -> void:
	var four: Array[int] = [0, 1, 2, 3]
	assert_eq(GhostTag.rank_groups(four, [0], {1: 30.0}, {0: 1.0}, 60.0), [[2, 3], [1], [0]],
		"1 of 3 caught = 20 s: below a blob caught at 30 s")
	assert_eq(GhostTag.rank_groups(four, [0], {1: 30.0, 2: 10.0}, {0: 2.0}, 60.0), [[3], [0], [1], [2]],
		"2 of 3 = 40 s: above blobs caught at 30 and 10 s")
	assert_eq(GhostTag.rank_groups(four, [0], {1: 30.0, 2: 10.0, 3: 50.0}, {0: 3.0}, 60.0), [[0], [3], [1], [2]],
		"caught everyone: first")
	assert_eq(GhostTag.rank_groups(four, [0], {}, {0: 0.0}, 60.0), [[1, 2, 3], [0]], "caught nobody: last")
	assert_eq(GhostTag.rank_groups(four, [0], {1: 25.0, 2: 25.0}, {0: 2.0}, 60.0), [[3], [0], [1, 2]],
		"caught at the same moment: tied")
	var eight: Array[int] = [0, 1, 2, 3, 4, 5, 6, 7]
	# two starting ghosts, both credited with the team's 3.5 (own + chain) of 7 = 30 s
	assert_eq(GhostTag.rank_groups(eight, [0, 1], {2: 30.0, 3: 12.0, 4: 45.0}, {0: 3.5, 1: 3.5}, 60.0),
		[[5, 6, 7], [4], [0, 1, 2], [3]], "ghosts tie with a blob caught at the same 'time'")
	var points := Session.points_for_groups([[5, 6, 7], [4], [0, 1, 2], [3]], 8)
	assert_eq(points[5], 5, "survivors share first")
	assert_eq(points[0], 1, "the ghosts share 5th place")


# --- Looks ---------------------------------------------------------------------------------------

func test_looks_restored_after_finish() -> void:
	spawn_arena(2, ID)
	var mg := _mg()
	var ps := players
	var normal := _normal_looks(mg, [1] as Array[int])
	assert_true(mg.looks().is_ghost_look(1), "P1 is the ghost")
	assert_false(_look_of(ps[1]) == normal[1], "the ghost look changes the model")
	assert_eq(_look_of(ps[0]), normal[0], "a redrawn ghost is back to normal")
	assert_true(_has_our_nodes(ps[0]), "the living carry a lantern")
	await step(HEAD_FRAMES + 2)
	_put(ps[0], ps[1].global_position + Vector3(0.9, 0, 0))
	await step(1)
	assert_true(mg.is_finished(), "caught: over")
	assert_eq(_look_of(ps[1]), normal[1], "the ghost's model is exactly as before")
	assert_eq(_look_of(ps[0]), normal[0], "the caught blob's too")
	assert_false(_has_our_nodes(ps[0]) or _has_our_nodes(ps[1]), "no sheet or lantern left")
	assert_near(_speed(ps[1]), 6.0, 0.001, "speed back")
	var status := ps[1].get_component(&"status") as StatusComponent
	assert_near(status.knockback_multiplier, 1.0, 0.001, "knockback back")
	assert_near(status.stun_max, 0.6, 0.001, "stun back")


func test_looks_restored_after_time_out() -> void:
	spawn_arena(3, ID)
	var mg := _mg()
	var ps := players
	var normal := _normal_looks(mg, [0] as Array[int])
	await step(HEAD_FRAMES + 2)
	_put(ps[1], ps[0].global_position + Vector3(0.9, 0, 0))
	await step(40)
	assert_true(mg.looks().is_ghost_look(1), "P1 turned")
	_put(ps[2], Vector3(10.25, 0, 7.0))
	_put(ps[0], Vector3(-10.0, 0, -7.0))
	_put(ps[1], Vector3(-10.25, 0, 0.0))
	mg.time_scale = 8.0
	assert_true(await run_until_finished(60 * 20), "times out")
	for p in ps:
		assert_eq(_look_of(p), normal[p.slot], "P%d's model is exactly as before" % p.slot)
		assert_false(_has_our_nodes(p), "P%d: nothing of ours left on the model" % p.slot)
	assert_true(mg.looks().ghost_look_slots().is_empty(), "no ghost look left")
	assert_true(mg.looks().veil_alpha() < 0.3, "the night veil lifts for the results")


func test_looks_restored_when_the_stage_clears() -> void:
	spawn_arena(3, ID)
	var mg := _mg()
	var ps := players
	var normal := _normal_looks(mg, [0] as Array[int])
	await step(HEAD_FRAMES + 2)
	_put(ps[2], ps[0].global_position + Vector3(0.9, 0, 0))
	await step(40)
	assert_true(mg.looks().is_ghost_look(2), "P2 turned")
	# the minigame leaves the tree mid-round (Stage.clear) while the players still exist
	stage.minigame = null
	stage.remove_child(mg)
	for p in ps:
		assert_eq(_look_of(p), normal[p.slot], "P%d restored when the minigame leaves" % p.slot)
		assert_false(_has_our_nodes(p), "P%d: nothing of ours left on the model" % p.slot)
		assert_near(_speed(p), 6.0, 0.001, "P%d speed back" % p.slot)
	mg.queue_free()


func test_lights_follow_quality() -> void:
	var was := Look.get_quality()
	Look.set_quality(Look.Quality.HIGH)
	spawn_arena(8, ID)
	var mg := _mg()
	await step(2)
	assert_eq(mg.looks().light_count(), 8, "HIGH: one shadowless light per blob")
	assert_eq(mg.looks().disc_count(), 0, "no glow discs")
	for l in mg.looks().find_children("*", "OmniLight3D", false, false):
		assert_false((l as OmniLight3D).shadow_enabled, "lights cast no shadows")
	Look.set_quality(Look.Quality.LOW)
	await step(2)
	assert_eq(mg.looks().light_count(), 0, "LOW: no per-blob lights")
	assert_eq(mg.looks().disc_count(), 8, "LOW: a glow disc per blob instead")
	Look.set_quality(was)
	await step(1)


# --- Leavers (review fixes) ----------------------------------------------------------------------

## The only ghost leaves before catching anyone: a living runner takes over as the ghost (on
## every peer: announced, the ghost look, frozen while it rises), it can catch, the round goes on.
func test_last_ghost_leaving_hands_the_ghost_to_a_runner() -> void:
	spawn_arena(4, ID)
	var mg := _mg()
	mg.set_starting_ghosts([1] as Array[int])
	await step(HEAD_FRAMES + 2)
	var converted := watch(mg, &"converted")
	Net.remove_bot(1)
	await step(2)
	assert_false(mg.is_finished(), "the round goes on")
	assert_eq(mg.knocked_out, [1] as Array[int], "leaver recorded")
	var ghosts: Array[int] = []
	for s: int in [0, 2, 3]:
		if mg.is_ghost(s):
			ghosts.append(s)
	if not assert_eq(ghosts.size(), 1, "one runner became the ghost"):
		return
	var g := ghosts[0]
	var gp := stage.get_player(g)
	assert_eq(converted.size(), 1, "through the normal conversion")
	assert_true(mg.looks().is_ghost_look(g), "it looks like a ghost")
	assert_true(mg.caught_at.has(g), "it stopped surviving (ranked like a catch now)")
	assert_true(gp.frozen, "frozen while it rises")
	await step(int(mg.rise_time * 60.0) + 4)
	assert_false(gp.frozen, "risen: it hunts")
	var victim: Player = null
	for s: int in [0, 2, 3]:
		if s != g:
			victim = stage.get_player(s)
			break
	var caught := watch(mg, &"caught")
	_put(victim, gp.global_position + Vector3(0.9, 0, 0))
	await step(1)
	assert_eq(caught.size(), 1, "the new ghost catches")
	if not caught.is_empty():
		assert_eq(caught[0][0], g, "by the new ghost")


## The ghost leaves during the head start: the new ghost stays frozen until the head start is over.
func test_ghost_leaving_in_the_head_start_waits_for_the_wake() -> void:
	spawn_arena(3, ID)
	var mg := _mg()
	mg.set_starting_ghosts([2] as Array[int])
	await step(30)
	Net.remove_bot(2)
	await step(2)
	var g := 0 if mg.is_ghost(0) else 1
	assert_true(mg.is_ghost(g), "a runner took over")
	await step(HEAD_FRAMES - 60)
	assert_true(stage.get_player(g).frozen, "still frozen in the head start")
	await step(40)
	assert_false(stage.get_player(g).frozen, "free once the ghosts wake")


## The only ghost leaves a two-player round: nobody is left to chase, the round ends through the
## minigame's own end (tied groups, the end RPC lifts the curse, the grace).
func test_ghost_leaving_two_players_ends_the_round_properly() -> void:
	spawn_arena(2, ID)
	var mg := _mg()
	mg.set_starting_ghosts([1] as Array[int])
	await step(HEAD_FRAMES + 2)
	var over := watch(mg, &"round_over")
	Net.remove_bot(1)
	await step(2)
	assert_true(mg.is_finished(), "over")
	assert_eq(over.size(), 1, "through the end RPC")
	assert_eq(mg.finish_groups, [[0], [1]], "the survivor first, the ghost who caught nobody last")
	assert_near(mg.finish_grace, mg.end_grace, 0.001, "with the end grace")
	assert_true(mg.over, "every peer knows it is over")
	assert_true(mg.looks().ghost_look_slots().is_empty(), "no ghost look left")


## The runner leaves a two-player round: the round ends through the minigame's end too (no
## flat base finish), and the ghost's sheet comes off for the results.
func test_runner_leaving_two_players_ends_the_round_properly() -> void:
	spawn_arena(2, ID)
	var mg := _mg()
	mg.set_starting_ghosts([0] as Array[int])
	await step(HEAD_FRAMES + 2)
	var over := watch(mg, &"round_over")
	Net.remove_bot(1)
	await step(2)
	assert_true(mg.is_finished(), "over")
	assert_eq(over.size(), 1, "through the end RPC")
	assert_true(mg.caught_at.has(1), "the leaver counts as caught")
	assert_near(mg.finish_grace, mg.end_grace, 0.001, "with the end grace")
	assert_false(mg.looks().is_ghost_look(0), "the curse lifts")
	assert_near(_speed(players[0]), 6.0, 0.001, "ghost tuning restored")
