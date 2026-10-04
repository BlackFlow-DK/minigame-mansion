extends GameTest
## Hide and Sneak: layout, roles and rotation, disguises (applied and restored on every exit
## path), role tuning, pokes (reveal, furniture, budget, refill, cooldown), rustles, the glow,
## and the ranking rule. Scripted controllers: the test writes intents and calls the host API.

const ID := &"hide_and_sneak"


func before_each() -> void:
	HideAndSneak.reset_rotation()


func _spawn(count: int, seed_value: int = 1) -> HideAndSneak:
	HideAndSneak.test_seed = seed_value
	spawn_arena(count, ID)
	return get_minigame() as HideAndSneak


## Skips HIDE: SEEK starts on the next host tick.
func _to_seek(mg: HideAndSneak) -> void:
	mg.hide_time = 0.0
	await step(2)
	assert_eq(mg.phase, HideAndSneak.Phase.SEEK, "SEEK started")


func _player(slot: int) -> Player:
	return stage.get_player(slot)


## Puts `seeker` 1.0 m from `at`, facing it, away from everything else if possible.
func _stand_before(seeker: Player, at: Vector3, from_dir: Vector3 = Vector3.BACK) -> void:
	var pos := at + from_dir.normalized() * 1.0
	seeker.place_at(Transform3D(Basis.looking_at(at - pos, Vector3.UP, true), pos))


## A furniture piece with no hider and no other furniture within `clear` m (id), -1 if none.
func _lonely_furniture(mg: HideAndSneak, clear: float = 1.8) -> int:
	var room := mg.room()
	for i in room.furniture.size():
		var p: Vector3 = room.furniture[i]["pos"]
		var ok := absf(p.z) < 6.5 and absf(p.x) < 8.5
		for h in mg.hider_slots:
			if _player(h).global_position.distance_to(p) < 2.5:
				ok = false
		for j in room.furniture.size():
			if j != i and (room.furniture[j]["pos"] as Vector3).distance_to(p) < clear:
				ok = false
		if ok:
			return i
	return -1


# --- Layout ---------------------------------------------------------------------------------

func test_layout_is_deterministic_by_seed() -> void:
	var a := HideLayout.generate(42)
	var b := HideLayout.generate(42)
	var c := HideLayout.generate(43)
	assert_eq(HideLayout.fingerprint(a), HideLayout.fingerprint(b), "same seed, same room")
	assert_true(HideLayout.fingerprint(a) != HideLayout.fingerprint(c), "another seed, another room")
	for layout in [a, c, HideLayout.generate(7), HideLayout.generate(99)]:
		assert_true(layout.size() >= 40 and layout.size() <= 60, "40-60 pieces (%d)" % layout.size())
		var kinds := {}
		for i in layout.size():
			var f: Dictionary = layout[i]
			kinds[f["kind"]] = true
			var rest: Array[Dictionary] = []
			for j in layout.size():
				if j != i:
					rest.append(layout[j])
			assert_true(HideLayout.fits(f["pos"], HideLayout.kind_radius(int(f["kind"])), rest, 0.0), "piece %d fits (no overlap, in the room)" % i)
		assert_true(kinds.size() >= 6, "at least 6 kinds (%d)" % kinds.size())


func test_every_peer_builds_the_seeded_room() -> void:
	var mg := _spawn(4, 5)
	var room := mg.room()
	assert_true(room.layout_seed >= 0, "the host's seed arrived")
	assert_eq(HideLayout.fingerprint(room.furniture), HideLayout.fingerprint(HideLayout.generate(room.layout_seed)), "room built from the seed")
	var multis := 0
	for n in room.get_children():
		if n is MultiMeshInstance3D:
			multis += 1
	assert_eq(multis, HideLayout.kind_count(), "one MultiMesh per kind")


# --- Roles ----------------------------------------------------------------------------------

func test_seekers_by_player_count() -> void:
	for n in [2, 3, 4, 5]:
		assert_eq(HideAndSneak.seeker_count(n), 1, "%d players: 1 seeker" % n)
	for n in [6, 7, 8]:
		assert_eq(HideAndSneak.seeker_count(n), 2, "%d players: 2 seekers" % n)
	var mg := _spawn(6)
	assert_eq(mg.seekers.size(), 2, "6 players: 2 seekers")
	assert_eq(mg.hider_slots.size(), 4, "the other 4 hide")
	for s in mg.seekers:
		assert_true(mg.role_of(s).contains("SEEKER"), "seeker role line")
	for s in mg.hider_slots:
		assert_true(mg.role_of(s).contains("HIDE"), "hider role line")


func test_roles_rotate_across_rounds() -> void:
	var r := RandomNumberGenerator.new()
	r.seed = 3
	var slots: Array[int] = [0, 1, 2, 3]
	var seen: Array[int] = []
	var last: Array[int] = []
	for round_i in 4:
		var pick := HideAndSneak.pick_seekers(slots, r)
		assert_eq(pick.size(), 1, "one seeker of 4")
		assert_false(pick.has(last[0]) if not last.is_empty() else false, "never last round's seeker twice in a row")
		seen.append(pick[0])
		last = pick
	seen.sort()
	assert_eq(seen, slots, "in 4 rounds each of 4 players sought once")
	# 8 players: 2 seekers per round, 4 rounds cover everyone.
	HideAndSneak.reset_rotation()
	var eight: Array[int] = [0, 1, 2, 3, 4, 5, 6, 7]
	var all := {}
	for round_i in 4:
		for s in HideAndSneak.pick_seekers(eight, r):
			all[s] = int(all.get(s, 0)) + 1
	assert_eq(all.size(), 8, "8 players: everyone sought once in 4 rounds")
	# The minigame itself goes through the rotation.
	HideAndSneak.reset_rotation()
	var mg := _spawn(4, 9)
	assert_eq(mg.seekers, HideAndSneak.last_seekers(), "the round's seekers are remembered")


# --- Disguises ------------------------------------------------------------------------------

func _assert_disguised(mg: HideAndSneak, p: Player, want: bool) -> void:
	var d := p.get_node_or_null(^"HideDisguise")
	var model := (p.get_component(&"visuals") as VisualsComponent).get_model_root()
	if want:
		assert_true(d != null, "P%d wears a prop" % p.slot)
		assert_false(model.visible, "P%d blob hidden" % p.slot)
		assert_true(mg.disguises.has(p.slot), "P%d listed as disguised" % p.slot)
	else:
		assert_true(d == null, "P%d prop removed" % p.slot)
		assert_true(model.visible, "P%d blob shown" % p.slot)


func test_hiders_are_disguised_on_spawn() -> void:
	var mg := _spawn(5)
	assert_eq(mg.phase, HideAndSneak.Phase.HIDE, "HIDE phase")
	for s in mg.hider_slots:
		_assert_disguised(mg, _player(s), true)
		var d := _player(s).get_node(^"HideDisguise") as HideDisguise
		assert_eq(d.kind, mg.disguises[s], "wears its assigned kind")
	for s in mg.seekers:
		var p := _player(s)
		_assert_disguised(mg, p, false)
		assert_true(p.frozen, "seeker frozen in the closet")
		assert_true(p.global_position.z < HideLayout.BACK_Z, "seeker behind the back wall")
	await step(30)
	for s in mg.seekers:
		assert_true(_player(s).frozen, "still frozen during HIDE")


func test_disguises_restored_after_time_out() -> void:
	var mg := _spawn(4)
	mg.time_scale = 30.0
	var done := await run_until_finished(600)
	assert_true(done, "round timed out")
	for p in players:
		_assert_disguised(mg, p, false)
		var move := p.get_component(&"movement") as MovementComponent
		assert_near(move.max_speed, 6.0, 0.01, "P%d speed restored" % p.slot)
		assert_true((p.get_component(&"jump") as JumpComponent).jump_enabled, "P%d jump restored" % p.slot)
		assert_true((p.get_component(&"shove") as ShoveComponent).enabled, "P%d shove restored" % p.slot)
	assert_eq(mg.finish_groups[0].size(), 3, "3 survivors share first place")


func test_disguises_restored_when_the_minigame_leaves() -> void:
	var mg := _spawn(4)
	var hider := _player(mg.hider_slots[0])
	_assert_disguised(mg, hider, true)
	stage.remove_child(mg)
	_assert_disguised(mg, hider, false)
	assert_near((hider.get_component(&"movement") as MovementComponent).max_speed, 6.0, 0.01, "speed restored")
	stage.add_child(mg)  # let the harness tear it down normally


func test_hider_and_seeker_tuning() -> void:
	var mg := _spawn(4)
	var h := _player(mg.hider_slots[0])
	await step(2)
	assert_near((h.get_component(&"movement") as MovementComponent).max_speed, 6.0 * 0.35, 0.01, "hider at 35 %")
	assert_false((h.get_component(&"jump") as JumpComponent).jump_enabled, "hider cannot jump")
	assert_false((h.get_component(&"shove") as ShoveComponent).enabled, "hider cannot shove")
	for q in players:
		if q != h and mg.hider_slots.has(q.slot):
			q.place_at(Transform3D(Basis.IDENTITY, Vector3(-4.0 + q.slot, 0.0, 6.5)))
	h.place_at(Transform3D(Basis.IDENTITY, HideLayout.CLEAR_CENTER + Vector3(-1.5, 0.0, 0.0)))
	var y0 := h.global_position.y
	var shoves := watch(h, &"shove_started")
	var top := [0.0]
	await step(50, func(i: int) -> void:
		h.intent.move = Vector2.RIGHT
		h.intent.jump_pressed = i % 10 == 0
		h.intent.jump_held = true
		top[0] = maxf(top[0], Vector2(h.velocity.x, h.velocity.z).length()))
	var v: float = top[0]
	assert_true(v <= 6.0 * 0.35 + 0.05 and v > 1.8, "walks at hider speed (%.2f)" % v)
	assert_near(h.global_position.y, y0, 0.05, "never left the ground")
	assert_eq(shoves.size(), 0, "no shove")
	await _to_seek(mg)
	var s := _player(mg.seekers[0])
	assert_false(s.frozen, "seeker out of the closet")
	assert_true(s.global_position.z > HideLayout.BACK_Z, "seeker inside the room")
	assert_near((s.get_component(&"movement") as MovementComponent).max_speed, 6.0 * 1.1, 0.01, "seeker at 110 %")
	assert_false((s.get_component(&"shove") as ShoveComponent).enabled, "action is a poke, not a shove")


func test_action_cycles_the_disguise_while_hiding() -> void:
	var mg := _spawn(4)
	var h := _player(mg.hider_slots[0])
	var before: int = mg.disguises[h.slot]
	var changes := watch(mg, &"disguise_changed")
	await step(2, func(i: int) -> void: h.intent.action_pressed = i == 0)
	assert_eq(mg.disguises[h.slot], (before + 1) % HideLayout.kind_count(), "next kind")
	assert_eq((h.get_node(^"HideDisguise") as HideDisguise).kind, mg.disguises[h.slot], "the prop changed")
	assert_eq(changes.size(), 1, "one change")
	await _to_seek(mg)
	mg.cycle_disguise(h.slot)
	assert_eq(changes.size(), 1, "no changes once SEEK starts")


# --- Pokes ------------------------------------------------------------------------------------

func test_poke_on_a_hider_reveals_and_knocks_out() -> void:
	var mg := _spawn(4)
	await _to_seek(mg)
	var s := _player(mg.seekers[0])
	var h := _player(mg.hider_slots[0])
	var reveals := watch(mg, &"revealed")
	var outs := watch(h, &"eliminated")
	_stand_before(s, h.global_position)
	await step(1)
	var pokes: int = mg.pokes_left[s.slot]
	assert_eq(mg.poke(s.slot), HideAndSneak.PokeTarget.HIDER, "the poke found the hider")
	assert_eq(reveals.size(), 1, "revealed")
	_assert_disguised(mg, h, false)
	assert_eq(mg.pokes_left[s.slot], pokes, "finding a hider costs no poke")
	assert_eq(mg.finds[s.slot], 1, "one find")
	await step(int(mg.reveal_delay * 60.0) + 5)
	assert_false(h.alive, "caught hider knocked out")
	assert_true(mg.knocked_out.has(h.slot), "recorded as knocked out")
	assert_eq(outs.size(), 1, "eliminated once")
	assert_eq(outs[0][0], &"found", "reason found")


func test_human_action_pokes_through_the_host() -> void:
	var mg := _spawn(4)
	await _to_seek(mg)
	var s := _player(mg.seekers[0])
	var h := _player(mg.hider_slots[0])
	_stand_before(s, h.global_position)
	var reveals := watch(mg, &"revealed")
	await step(2, func(i: int) -> void: s.intent.action_pressed = i == 0)
	assert_eq(reveals.size(), 1, "action press = poke")


func test_poke_on_furniture_spends_a_poke_and_jiggles() -> void:
	var mg := _spawn(3, 4)
	await _to_seek(mg)
	var s := _player(mg.seekers[0])
	var id := _lonely_furniture(mg)
	assert_true(id >= 0, "a lonely piece of furniture")
	var at: Vector3 = mg.room().furniture[id]["pos"]
	_stand_before(s, at, (Vector3(0, 0, 0.8) - at).normalized())
	await step(1)
	var before: int = mg.pokes_left[s.slot]
	assert_eq(before, mg.poke_budget(2), "budget 3 + 2 per hider")
	var poked := watch(mg, &"poked")
	assert_eq(mg.poke(s.slot), HideAndSneak.PokeTarget.FURNITURE, "hit furniture")
	assert_eq(poked[0][2], id, "that piece")
	assert_eq(mg.pokes_left[s.slot], before - 1, "one poke spent")
	assert_true(mg.room().is_jiggling(id), "it jiggles")
	assert_eq(mg.poke(s.slot), HideAndSneak.PokeTarget.NONE, "cooldown: no second poke at once")
	await step(int(mg.poke_cooldown * 60.0) + 2)
	assert_eq(mg.poke(s.slot), HideAndSneak.PokeTarget.FURNITURE, "after the cooldown it pokes again")


func test_poke_budget_runs_out_and_refills() -> void:
	var mg := _spawn(3, 4)
	await _to_seek(mg)
	var s := _player(mg.seekers[0])
	var id := _lonely_furniture(mg)
	var at: Vector3 = mg.room().furniture[id]["pos"]
	_stand_before(s, at, (Vector3(0, 0, 0.8) - at).normalized())
	await step(1)
	mg._set_pokes(s.slot, 1)
	mg.poke_cooldown = 0.0
	assert_eq(mg.poke(s.slot), HideAndSneak.PokeTarget.FURNITURE, "last poke")
	assert_eq(mg.pokes_left[s.slot], 0, "out of pokes")
	await step(2)
	assert_eq(mg.poke(s.slot), HideAndSneak.PokeTarget.NONE, "out of pokes: can only look")
	mg.time_scale = 5.0
	await step(int(mg.refill_time / 5.0 * 60.0) + 5)
	assert_eq(mg.pokes_left[s.slot], 1, "one poke back after refill_time")


func test_rustle_every_interval_and_glow_at_the_end() -> void:
	var mg := _spawn(4)
	await _to_seek(mg)
	mg.time_scale = 10.0
	var rustles := watch(mg, &"rustled")
	await step(int(mg.rustle_interval / 10.0 * 60.0) + 3)
	assert_eq(rustles.size(), 1, "first rustle at %d s" % int(mg.rustle_interval))
	assert_false(mg.glow_on, "no glow yet")
	await step(int((mg.seek_time - mg.glow_time - mg.rustle_interval) / 10.0 * 60.0) + 3)
	assert_eq(rustles.size(), 3, "rustles at 15, 30, 45 s")
	assert_true(mg.glow_on, "hiders glow in the last %d s" % int(mg.glow_time))


# --- Ranking ------------------------------------------------------------------------------------

func test_ranking_rule() -> void:
	# Survivors 4 and 5 tie first; seekers by finds; caught by seconds survived.
	var groups := HideAndSneak.compute_ranking([5, 4], [0, 1], {0: 1, 1: 2}, {2: 10.0, 3: 31.5})
	assert_eq(groups, [[4, 5], [1], [0], [3], [2]], "survivors, seekers by finds, caught by time")
	# Equal finds and equal survival times tie.
	groups = HideAndSneak.compute_ranking([], [0, 1], {0: 2, 1: 2}, {2: 20.0, 3: 20.0})
	assert_eq(groups, [[0, 1], [2, 3]], "ties")
	# A seeker who found everyone ranks above everyone.
	groups = HideAndSneak.compute_ranking([], [3], {3: 3}, {0: 5.0, 1: 40.0, 2: 12.0})
	assert_eq(groups, [[3], [1], [2], [0]], "found them all: first")
	# Nobody found: the seeker is last.
	groups = HideAndSneak.compute_ranking([0, 1, 2], [3], {3: 0}, {})
	assert_eq(groups, [[0, 1, 2], [3]], "nobody found")


func test_found_everyone_ends_the_round_with_the_seeker_first() -> void:
	var mg := _spawn(3)
	await _to_seek(mg)
	var s := _player(mg.seekers[0])
	mg.poke_cooldown = 0.0
	for h in mg.hider_slots.duplicate():
		_stand_before(s, _player(h).global_position)
		await step(20)
		assert_eq(mg.poke(s.slot), HideAndSneak.PokeTarget.HIDER, "found P%d" % h)
	assert_true(mg.is_finished(), "round over when the last hider is found")
	assert_eq(ranking[0], s.slot, "the seeker wins")
	assert_eq(mg.finish_grace, 2.0, "2 s grace")
	assert_eq(mg.finish_groups[0], [s.slot] as Array[int], "alone in first place")
	await step(int(mg.reveal_delay * 60.0) + 5)
	for h in mg.hider_slots:
		assert_false(_player(h).alive, "P%d out" % h)


func test_time_out_survivors_tie_first_and_seeker_follows() -> void:
	var mg := _spawn(4)
	await _to_seek(mg)
	var s := _player(mg.seekers[0])
	var first := _player(mg.hider_slots[0])
	_stand_before(s, first.global_position)
	await step(1)
	mg.poke(s.slot)
	mg.time_scale = 30.0
	assert_true(await run_until_finished(400), "timed out")
	var g: Array = mg.finish_groups
	assert_eq(g.size(), 3, "survivors, seeker, caught")
	assert_eq(g[0].size(), 2, "two survivors tied first")
	assert_eq(g[1], [s.slot] as Array[int], "then the seeker")
	assert_eq(g[2], [first.slot] as Array[int], "then the caught hider")
