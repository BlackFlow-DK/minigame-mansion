extends GameTest
## Paint Splat: the rules, driven through the Player API and the minigame's own
## (RPC-carried) state and signals. Offline, the host's `call_local` RPCs run in place, so
## `tiles_painted` / `counts_changed` firing here is the RPC firing.

const ID := &"paint_splat"
const PaintSplat := preload("res://minigames/paint_splat/paint_splat.gd")


## Offline arena with `count` scripted players and no automatic bombs.
func _arena(count: int = 2) -> PaintSplat:
	spawn_arena(count, ID)
	var mg := get_minigame() as PaintSplat
	mg.bombs_enabled = false
	mg._rng.seed = 4242
	return mg


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))


func _owned(mg: PaintSplat, slot: int) -> int:
	var n := 0
	for i in PaintSplat.TILE_COUNT:
		if mg.tile_owner(i) == slot:
			n += 1
	return n


func test_scene_loads_with_8_spawns() -> void:
	var ps := spawn_arena(8, ID)
	var mg := get_minigame() as PaintSplat
	if not assert_true(mg != null, "paint_splat loads with its own script"):
		return
	assert_eq(ps.size(), 8, "8 players spawned")
	var points := mg.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn markers")
	assert_near(mg.time_limit, 45.0, 0.001, "45 s round")
	assert_eq(PaintSplat.TILE_COUNT, 196, "14 x 14 tiles")
	for t in points:
		assert_true(mg.is_safe(t.origin), "spawn %s is inside the walls" % t.origin)
		var to_centre := -Vector3(t.origin.x, 0.0, t.origin.z).normalized()
		assert_true(t.basis.z.dot(to_centre) > 0.99, "spawn %s faces the centre" % t.origin)
		# Every spawn is the same distance from the walls and the centre (no slot starts better).
		assert_near(maxf(absf(t.origin.x), absf(t.origin.z)), 4.5, 0.001, "spawn ring")
		assert_near(minf(absf(t.origin.x), absf(t.origin.z)), 2.5, 0.001, "spawn ring")
	await step(30)
	for p in ps:
		assert_true(p.global_position.y > -0.1 and p.global_position.y < 0.3, "P%d stands on the floor (y=%.2f)" % [p.slot, p.global_position.y])
	assert_false(mg.is_safe(Vector3(6.8, 0.0, 0.0)), "next to the wall is unsafe")
	assert_eq(PaintSplat.tile_at(Vector3(-6.9, 0.0, -6.9)), 0, "first tile at -X -Z")
	assert_eq(PaintSplat.tile_at(Vector3(6.9, 0.0, 6.9)), 195, "last tile at +X +Z")
	assert_eq(PaintSplat.tile_at(Vector3(7.2, 0.0, 0.0)), -1, "off the floor")
	assert_eq(PaintSplat.tiles_within(Vector3(0.5, 0.0, 0.5), 3.0).size(), 29, "a radius-3 splash covers 29 tiles")


func test_walking_paints_tiles_and_updates_the_counter() -> void:
	var mg := _arena(2)
	var p := players[0]
	_put(p, Vector3(-5.5, 0.0, 4.5))
	_put(players[1], Vector3(5.5, 0.0, -4.5))
	var counters := watch(mg, &"counts_changed")
	await step(10)
	assert_eq(mg.tile_owner(PaintSplat.tile_at(p.global_position)), 0, "standing paints the tile under you")
	assert_eq(mg.counts[0], 1, "count 1")
	# Run along -Z across the floor.
	await step(90, func(_i: int) -> void: p.intent.move = Vector2(0.0, -1.0))
	await step(10, func(_i: int) -> void: p.intent.move = Vector2.ZERO)
	var travelled := 4.5 - p.global_position.z
	assert_true(travelled > 5.0, "ran %.1f m" % travelled)
	var ix := PaintSplat.tile_at(p.global_position) % PaintSplat.GRID
	var col := 0
	for iz in PaintSplat.GRID:
		if mg.tile_owner(iz * PaintSplat.GRID + ix) == 0:
			col += 1
	assert_true(col >= int(travelled), "a trail of %d tiles in the column (ran %.1f m)" % [col, travelled])
	assert_eq(mg.counts[0], _owned(mg, 0), "count matches the owner map")
	assert_eq(mg.counts[1], _owned(mg, 1), "other count matches")
	assert_true(counters.size() > 0 and counters.back() == [0, mg.counts[0]], "the counter reported slot 0 -> %d: %s" % [mg.counts[0], str(counters.back())])
	# Jumping blobs do not paint mid-air: hop while being carried sideways over fresh tiles.
	var before: int = mg.counts[0]
	var air := [0]
	await step(40, func(i: int) -> void:
		p.intent.jump_pressed = i == 0
		p.intent.jump_held = true
		if p.global_position.y > mg.paint_height + 0.1:
			air[0] += 1
			p.global_position += Vector3(0.05, 0.0, 0.0)
		elif i > 3:
			p.intent.jump_held = false)
	assert_true(air[0] > 5, "was in the air (%d frames)" % air[0])
	assert_true(mg.counts[0] - before <= 2, "barely any paint from the air (%d -> %d)" % [before, mg.counts[0]])


func test_overlapping_claims_in_one_tick_change_nothing() -> void:
	var mg := _arena(2)
	var claims: Dictionary[int, int] = {}
	mg._claim(claims, 10, 0)
	mg._claim(claims, 10, 1)
	mg._claim(claims, 11, 1)
	mg._claim(claims, 11, 1)
	mg._flush(claims)
	assert_eq(mg.tile_owner(10), -1, "a tile two blobs claim in the same tick stays as it was")
	assert_eq(mg.tile_owner(11), 1, "a single claim paints")


func test_stunned_blobs_tiles_go_to_the_shover() -> void:
	var mg := _arena(3)
	var victim := players[0]
	var shover := players[1]
	_put(victim, Vector3(-3.5, 0.0, 0.5))
	_put(shover, Vector3(5.5, 0.0, -5.5))
	_put(players[2], Vector3(5.5, 0.0, 5.5))
	# The victim owns a patch around itself.
	var patch := PaintSplat.tiles_within(Vector3(-2.5, 0.0, 0.5), 2.5)
	var slots := PackedInt32Array()
	slots.resize(patch.size())
	slots.fill(0)
	mg._rpc_paint(patch, slots)
	await step(5)
	var own_before: int = mg.counts[0]
	assert_true(own_before >= patch.size(), "victim holds its patch (%d)" % own_before)
	var shover_before: int = mg.counts[1]
	var under := PaintSplat.tile_at(victim.global_position)
	var stunned := watch(victim, &"stunned")
	victim.apply_impulse(Vector3(7.0, 1.0, 0.0), shover)
	var locked := [0]
	await step(45, func(_i: int) -> void:
		if victim.control_locked:
			locked[0] += 1)
	if not assert_true(stunned.size() > 0 and locked[0] > 0, "the hit stunned the victim"):
		return
	assert_eq(mg.tile_owner(under), 1, "the tile under the stunned blob went to the shover")
	var taken: int = mg.counts[1] - shover_before
	assert_true(taken >= 3, "the shover took %d tiles along the slide" % taken)
	assert_eq(mg.counts[0], own_before - taken, "the victim lost exactly those (%d -> %d)" % [own_before, mg.counts[0]])
	assert_eq(mg.counts[1], _owned(mg, 1), "shover count matches the map")
	# Once the stun is over, the victim paints its own colour again.
	assert_false(victim.control_locked, "stun over")
	await step(40, func(_i: int) -> void: victim.intent.move = Vector2(0.0, 1.0))
	assert_eq(mg.tile_owner(PaintSplat.tile_at(victim.global_position)), 0, "victim paints again after the stun")


func test_splash_bomb_paints_a_radius_for_the_first_to_touch_it() -> void:
	var mg := _arena(3)
	_put(players[0], Vector3(-5.5, 0.0, 5.5))
	_put(players[1], Vector3(5.5, 0.0, 5.5))
	_put(players[2], Vector3(5.5, 0.0, -5.5))
	var spawned := watch(mg, &"bomb_spawned")
	var claimed := watch(mg, &"bomb_claimed")
	var at := Vector3(0.5, 0.0, -0.5)
	var id := mg.spawn_bomb(at)
	assert_eq(spawned.size(), 1, "bomb_spawned")
	assert_eq(mg.bomb_ids(), [id] as Array[int], "one bomb")
	# Standing on the spot while it falls does not grab it.
	_put(players[1], at + Vector3(0.3, 0.0, 0.0))
	await step(int(mg.bomb_fall_time * 60.0 * 0.6))
	assert_eq(claimed.size(), 0, "nobody grabs a falling bomb")
	_put(players[1], Vector3(5.5, 0.0, 5.5))
	await step(int(mg.bomb_fall_time * 60.0))
	assert_true(mg.bomb_landed(id), "landed")
	assert_eq(claimed.size(), 0, "nobody near: still there")
	_put(players[2], at + Vector3(0.0, 0.0, 0.5))
	await step(3)
	if not assert_eq(claimed.size(), 1, "grabbed"):
		return
	assert_eq(claimed[0], [id, 2], "by player 2")
	assert_eq(mg.bomb_ids().size(), 0, "the bomb is gone")
	var splash := PaintSplat.tiles_within(at, mg.splash_radius)
	for i in splash:
		assert_eq(mg.tile_owner(i), 2, "tile %d inside the splash" % i)
	assert_true(mg.counts[2] >= splash.size(), "counted (%d >= %d)" % [mg.counts[2], splash.size()])
	assert_eq(mg.tile_owner(PaintSplat.tile_at(at + Vector3(3.6, 0.0, 0.0))), -1, "a tile just outside the radius is untouched")


func test_bombs_drop_every_interval() -> void:
	spawn_arena(2, ID)
	var mg := get_minigame() as PaintSplat
	mg.time_scale = 6.0
	var spawned := watch(mg, &"bomb_spawned")
	var times: Array[float] = []
	mg.bomb_spawned.connect(func(_id: int, _p: Vector3) -> void: times.append(mg.round_time()))
	assert_true(await run_until_finished(60 * 20), "round finished")
	assert_eq(spawned.size(), 2, "bombs at 15 s and 30 s, none at the very end: %s" % str(times))
	if times.size() == 2:
		assert_near(times[0], 15.0, 0.2, "first bomb")
		assert_near(times[1], 30.0, 0.2, "second bomb")
	for e: Array in spawned:
		var p: Vector3 = e[1]
		assert_true(mg.is_safe(p), "bomb lands inside the walls %s" % p)


func test_ranking_tie_break_and_final_splat() -> void:
	var s4: Array[int] = [0, 1, 2, 3]
	assert_eq(PaintSplat.rank_by_tiles(s4, {0: 3, 1: 5, 2: 3, 3: 0}, {0: 4.0, 1: 1.0, 2: 2.0, 3: 0.0}), [1, 2, 0, 3] as Array[int], "tiles, then who reached it first")
	assert_eq(PaintSplat.rank_by_tiles(s4, {0: 2, 1: 2, 2: 2, 3: 2}, {0: 1.0, 1: 1.0, 2: 1.0, 3: 1.0}), [0, 1, 2, 3] as Array[int], "full tie: by slot")
	# Live: slot 2 reaches 1 tile first, slot 0 later, slot 1 never (all frozen: nobody walks).
	var mg := _arena(3)
	for p in players:
		p.frozen = true
	await step(5)
	assert_eq(mg.counts.values(), [0, 0, 0], "frozen blobs paint nothing")
	mg._rpc_paint(PackedInt32Array([5]), PackedInt32Array([2]))
	await step(30)
	mg._rpc_paint(PackedInt32Array([9]), PackedInt32Array([0]))
	await step(30)
	var over := watch(mg, &"round_over")
	mg.time_limit = mg.round_time() + 0.25
	var limit := mg.time_limit
	for i in 60:
		if not over.is_empty():
			break
		await step(1)
	assert_eq(over.size(), 1, "round_over once, at the time limit")
	assert_false(mg.is_finished(), "the floor freezes before the ranking goes out")
	assert_eq(mg.final_ranking, [2, 0, 1] as Array[int], "tie broken by who reached 1 first")
	assert_true(mg.time_limit > limit + mg.final_freeze, "time limit pushed past the freeze (Session's backstop waits)")
	var frames := 0
	while not mg.is_finished() and frames < 600:
		await step(1)
		frames += 1
	assert_true(mg.is_finished(), "finished after the freeze")
	assert_near(frames / 60.0, mg.final_freeze, 0.1, "the final splat lasts final_freeze")
	assert_eq(ranking, [2, 0, 1] as Array[int], "finished with the tile ranking")
	assert_eq(over.size(), 1, "round_over still once")


func test_bot_round_4() -> void:
	await _bot_round(4, 11)


func test_bot_round_8() -> void:
	await _bot_round(8, 23)


## All slots are bots (slot 0's human controller gets a BotBrain driven here). Returns
## {ranking, counts, stats}; asserts a valid ranking ordered by tiles.
func _play_bots(count: int, seed_value: int, scale: float, even: bool) -> Dictionary:
	var ps := spawn_arena(count, ID, false)
	var mg := get_minigame() as PaintSplat
	mg.time_scale = scale
	mg._rng.seed = seed_value
	var c0 := ps[0].get_component(&"controller") as ControllerComponent
	c0.scripted = true
	var brain := BotBrain.new()
	brain.player = ps[0]
	brain.minigame = mg
	add_child(brain)
	var brains: Array[BotBrain] = [brain]
	for p in ps:
		if p.slot != 0:
			var b := p.get_component(&"controller").get_node_or_null(^"BotBrain") as BotBrain
			if b:
				brains.append(b)
	for b in brains:
		if even:
			b.configure(seed_value * 101 + b.player.slot, 0.65, 0.5)
		else:
			b.configure(seed_value * 101 + b.player.slot)
	var stats := {"shoves": 0, "bombs": 0}
	for p in ps:
		p.got_hit.connect(func(_imp: Vector3, src: int) -> void:
			if src >= 0:
				stats["shoves"] += 1)
	mg.bomb_claimed.connect(func(_id: int, _s: int) -> void: stats["bombs"] += 1)
	for i in 60 * 50:
		if mg.is_finished():
			break
		await step(1, func(_f: int) -> void: brain.fill_intent(ps[0].intent, physics_delta()))
	brain.queue_free()
	var out := {"ranking": ranking.duplicate(), "counts": mg.counts.duplicate(), "stats": stats}
	if not assert_true(mg.is_finished(), "the round finished"):
		return out
	var sorted := ranking.duplicate()
	sorted.sort()
	var all: Array[int] = []
	for p in ps:
		all.append(p.slot)
	assert_eq(sorted, all, "every slot ranked exactly once")
	var prev := 1 << 30
	var total := 0
	for s in ranking:
		assert_true(mg.counts[s] <= prev, "ranking follows tiles")
		prev = mg.counts[s]
		total += mg.counts[s]
	assert_eq(total, PaintSplat.TILE_COUNT - _owned(mg, -1), "counts add up to the painted tiles")
	return out


func _bot_round(count: int, seed_value: int) -> void:
	var r := await _play_bots(count, seed_value, 1.5, false)
	var counts: Dictionary = r["counts"]
	var rk: Array = r["ranking"]
	if rk.size() != count:
		return
	var scores: Array[int] = []
	var total := 0
	for s: int in rk:
		scores.append(int(counts[s]))
		total += int(counts[s])
	assert_true(total >= PaintSplat.TILE_COUNT * 0.6, "most of the floor got painted (%d)" % total)
	assert_true(scores[0] < total * 0.55, "no bot has everything %s" % str(scores))
	assert_true(scores[scores.size() - 1] > 0, "even the last bot painted something %s" % str(scores))
	assert_true(scores[0] > scores[scores.size() - 1], "a spread %s" % str(scores))
	print("  paint_splat bots x%d: ranking %s tiles %s, painted %d/%d, %s" % [count, str(rk), str(scores), total, PaintSplat.TILE_COUNT, str(r["stats"])])


## 12 seeded rounds of 4 equal bots (same skill and aggression): no slot wins more than half.
func test_no_slot_bias_over_12_rounds() -> void:
	var wins := {0: 0, 1: 0, 2: 0, 3: 0}
	for k in 12:
		var r := await _play_bots(4, 2000 + k, 4.0, true)
		var rk: Array = r["ranking"]
		if rk.is_empty():
			return
		wins[int(rk[0])] += 1
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
		players.clear()
		ranking = []
		Net.leave()
		await step(2)
	print("  paint_splat slot wins over 12 rounds: %s" % str(wins))
	for s: int in wins:
		assert_true(wins[s] <= 6, "slot %d won %d of 12" % [s, wins[s]])
