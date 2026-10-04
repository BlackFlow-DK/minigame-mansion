extends GameTest
## Portrait Panic: deterministic layouts, the SHUFFLE -> SHOW -> DROP loop (target tiles stay,
## the rest drop with their colliders and come back), falls knock out and tie per DROP, the
## numbers shrink per loop, each twist (MEMORY, DECOY, SWAP) does what it says, bot hooks.

const ID := &"portrait_panic"


func _game() -> PortraitPanic:
	return get_minigame() as PortraitPanic


## Spawns `count` scripted players with a seeded host RNG (before the first loop starts).
func _spawn(count: int, seed_value: int = 7) -> Array[Player]:
	var ps := spawn_arena(count, ID)
	var g := _game()
	g.rng.seed = seed_value
	g.bot_rng.seed = seed_value * 31 + 7
	return ps


## Steps until `cond` holds (or `max_frames`); returns true if it held.
func _until(cond: Callable, max_frames: int = 60 * 20, each_frame: Callable = Callable()) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await step(1, each_frame)
	return cond.call()


func _phase_is(p: PortraitPanic.Phase) -> Callable:
	return func() -> bool: return _game().phase == p


## Puts `p` on the centre (plus `offset`) of cell `cell`.
func _put(p: Player, cell: int, offset: Vector3 = Vector3.ZERO) -> void:
	var g := _game()
	p.place_at(Transform3D(Basis.IDENTITY, g.get_cell_position(cell) + offset))
	p.velocity = Vector3.ZERO


func _non_target_cells() -> Array[int]:
	var g := _game()
	var out: Array[int] = []
	for i in PortraitPanic.CELLS:
		if g.layout[i] != g.target:
			out.append(i)
	return out


# --- Pure rules ---------------------------------------------------------------------------------

func test_layout_is_deterministic_by_seed() -> void:
	for args: Array in [[42, 4, 8, 3], [7, 6, 4, 0], [1234, 8, 2, 7], [99, 5, 6, 5]]:
		var a := PortraitPanic.make_layout(args[0], args[1], args[2], args[3])
		var b := PortraitPanic.make_layout(args[0], args[1], args[2], args[3])
		assert_eq(a, b, "same seed, same layout %s" % str(args))
		assert_eq(a.size(), PortraitPanic.CELLS, "one symbol per cell")
		var counts: Dictionary = {}
		for s in a:
			assert_true(s < PortraitPanic.SYMBOL_COUNT, "a real symbol")
			counts[s] = int(counts.get(s, 0)) + 1
		assert_eq(counts.size(), int(args[1]), "%d symbols in play" % args[1])
		assert_eq(int(counts.get(args[3], 0)), int(args[2]), "target on exactly %d cells" % args[2])
		var rare := 0
		for s: int in counts:
			if s != args[3] and int(counts[s]) == int(args[2]):
				rare += 1
		assert_true(rare >= 1, "another symbol is as rare as the target (no tell)")
		# Targets are spread: no two touching while K <= 8 on a 7 x 7 floor.
		var cells := PortraitPanic.cells_with(a, args[3])
		for i in cells.size():
			for j in range(i + 1, cells.size()):
				var dr := absi(cells[i] / 7 - cells[j] / 7)
				var dc := absi(cells[i] % 7 - cells[j] % 7)
				assert_true(maxi(dr, dc) >= 2, "target cells %d and %d do not touch" % [cells[i], cells[j]])
	var x := PortraitPanic.make_layout(1, 6, 4, 2)
	var y := PortraitPanic.make_layout(2, 6, 4, 2)
	assert_true(x != y, "another seed, another layout")


func test_loop_numbers_shrink() -> void:
	var p0 := PortraitPanic.loop_params(0)
	assert_eq(int(p0["symbols"]), 4, "4 symbols first")
	assert_eq(int(p0["targets"]), 8, "8 targets first")
	assert_near(float(p0["show"]), 4.5, 0.001, "4.5 s first")
	var prev := p0
	for i in range(1, 12):
		var p := PortraitPanic.loop_params(i)
		assert_true(float(p["show"]) <= float(prev["show"]), "SHOW never grows")
		assert_true(int(p["targets"]) <= int(prev["targets"]), "targets never grow")
		assert_true(int(p["symbols"]) >= int(prev["symbols"]), "symbols never shrink")
		prev = p
	assert_near(float(PortraitPanic.loop_params(1)["show"]), 4.15, 0.001, "0.35 s less per loop")
	assert_near(float(PortraitPanic.loop_params(20)["show"]), 2.0, 0.001, "down to 2.0 s")
	assert_eq(int(PortraitPanic.loop_params(20)["targets"]), 2, "down to 2 targets")
	assert_eq(int(PortraitPanic.loop_params(20)["symbols"]), 8, "up to 8 symbols")


func test_swap_layout_rows_is_a_pure_row_trade() -> void:
	var a := PortraitPanic.make_layout(5, 8, 3, 1)
	var b := PortraitPanic.swap_layout_rows(a, 1, 4)
	for c in 7:
		assert_eq(b[1 * 7 + c], a[4 * 7 + c], "row 1 got row 4")
		assert_eq(b[4 * 7 + c], a[1 * 7 + c], "row 4 got row 1")
	for r: int in [0, 2, 3, 5, 6]:
		for c in 7:
			assert_eq(b[r * 7 + c], a[r * 7 + c], "row %d untouched" % r)
	assert_eq(PortraitPanic.swap_layout_rows(b, 1, 4), a, "swapping back restores it")


# --- Live loop -----------------------------------------------------------------------------------

func test_scene_loads_and_players_start_on_an_even_ring() -> void:
	var ps := _spawn(8)
	var g := _game()
	assert_true(g != null, "root is PortraitPanic")
	if g == null:
		return
	assert_eq(g.get_spawn_points().size(), 8, "8 spawn markers")
	var angles: Array[float] = []
	for p in ps:
		var local := g.to_local(p.global_position)
		assert_near(Vector2(local.x, local.z).length(), PortraitPanic.SPAWN_RADIUS, 0.01, "P%d on the ring" % p.slot)
		assert_true(g.is_safe(p.global_position), "P%d starts on a tile" % p.slot)
		angles.append(atan2(local.x, local.z))
	angles.sort()
	for i in 8:
		assert_near(fposmod(angles[(i + 1) % 8] - angles[i], TAU), TAU / 8.0, 0.01, "even spacing")
	await step(30)
	for p in ps:
		assert_true(p.alive and p.is_on_floor(), "P%d stands on its tile" % p.slot)


func test_targets_stay_others_drop_and_come_back() -> void:
	var ps := _spawn(2)
	var g := _game()
	var drops := watch(g, &"dropped")
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHOW)), "SHOW comes")
	# Keep both safe on target tiles.
	var targets := g.target_cells()
	assert_eq(targets.size(), 8, "8 target tiles in loop 1")
	_put(ps[0], targets[0])
	_put(ps[1], targets[1])
	assert_true(await _until(_phase_is(PortraitPanic.Phase.DROP)), "DROP comes")
	assert_eq(drops.size(), 1, "one drop event")
	var cells: PackedInt32Array = drops[0][1]
	assert_eq(cells.size(), PortraitPanic.CELLS - 8, "every other tile drops")
	for i in PortraitPanic.CELLS:
		var is_target := g.layout[i] == g.target
		assert_eq(g.cell_has_collider(i), is_target, "cell %d collider %s" % [i, "kept" if is_target else "gone"])
		assert_eq(g.gone[i] == 0, is_target, "cell %d gone flag" % i)
		if not is_target:
			assert_false(g.is_safe(g.get_cell_position(i)), "a dropped cell is not safe")
	await step(30)
	assert_true(ps[0].alive and ps[1].alive, "both on targets survive the drop")
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHUFFLE)), "next SHUFFLE")
	for i in PortraitPanic.CELLS:
		assert_true(g.cell_has_collider(i), "cell %d collider back" % i)
		assert_eq(g.gone[i], 0, "cell %d back" % i)
	assert_eq(g.loop_index, 1, "second loop")


func test_wrong_tile_falls_and_is_knocked_out_target_survives() -> void:
	var ps := _spawn(3)
	var g := _game()
	var fell := watch(g, &"player_fell")
	var out := watch(ps[1], &"eliminated")
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHOW)), "SHOW comes")
	var targets := g.target_cells()
	_put(ps[0], targets[0])
	_put(ps[2], targets[1])
	_put(ps[1], _non_target_cells()[0])
	assert_true(await _until(_phase_is(PortraitPanic.Phase.DROP)), "DROP comes")
	assert_true(await _until(func() -> bool: return not out.is_empty(), 90), "the blob on a wrong tile is out")
	if out.is_empty():
		return
	assert_eq(out[0][0], &"fell", "reason fell")
	assert_true(ps[0].alive and ps[2].alive, "the blobs on target tiles stand")
	assert_eq(fell.size(), 1, "one fall")
	assert_eq(fell[0][1], 0, "in loop 1")
	assert_true(g.knocked_out.has(1), "recorded")
	assert_false(g.is_finished(), "two left: the round goes on")


func test_everyone_falling_in_one_drop_ties() -> void:
	var ps := _spawn(4)
	var g := _game()
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHOW)), "SHOW comes")
	var wrong := _non_target_cells()
	_put(ps[0], g.target_cells()[0])
	for k in range(1, 4):
		_put(ps[k], wrong[k * 5])
	assert_true(await _until(func() -> bool: return g.is_finished(), 60 * 12), "finished after the drop")
	assert_eq(str(g.finish_groups), str([[0], [1, 2, 3]]), "the survivor, then the three who fell together as one group")
	assert_eq(ranking[0], 0, "survivor first")


func test_last_ones_falling_together_share_first_place() -> void:
	var ps := _spawn(3)
	var g := _game()
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHOW)), "SHOW comes")
	var wrong := _non_target_cells()
	for k in 3:
		_put(ps[k], wrong[k * 7])
	assert_true(await _until(func() -> bool: return g.is_finished(), 60 * 12), "finished")
	assert_eq(str(g.finish_groups), str([[0, 1, 2]]), "all three tie for first")


func test_falls_at_other_times_rank_in_order() -> void:
	var ps := _spawn(3)
	var g := _game()
	await step(5)
	# Off the floor during SHUFFLE: out on its own.
	ps[2].place_at(Transform3D(Basis.IDENTITY, g.to_global(Vector3(20.0, 0.5, 0.0))))
	assert_true(await _until(func() -> bool: return not ps[2].alive, 120), "P2 fell off")
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHOW)), "SHOW comes")
	_put(ps[0], g.target_cells()[0])
	_put(ps[1], _non_target_cells()[3])
	assert_true(await _until(func() -> bool: return g.is_finished(), 60 * 12), "finished")
	assert_eq(str(g.finish_groups), str([[0], [1], [2]]), "winner, then the drop faller, then the first out")


func test_time_limit_ties_the_survivors() -> void:
	_spawn(3)
	var g := _game()
	g.time_limit = 3.0
	assert_true(await run_until_finished(60 * 5), "finished at the time limit")
	assert_eq(str(g.finish_groups), str([[0, 1, 2]]), "survivors share first place")
	assert_near(g.finish_grace, 2.0, 0.001, "finish grace 2 s")


func test_loops_shrink_and_twists_start_at_loop_4() -> void:
	var ps := _spawn(2, 11)
	var g := _game()
	g.time_scale = 3.0
	g.time_limit = 0.0
	var loops := watch(g, &"loop_started")
	# Keep both players on target tiles every SHOW so the loops go on.
	var keep := func(_i: int) -> void:
		if g.phase == PortraitPanic.Phase.SHOW or g.phase == PortraitPanic.Phase.DROP:
			var t := g.target_cells()
			for k in ps.size():
				if g.cell_at(ps[k].global_position) != t[k % t.size()] or ps[k].global_position.y < -0.1:
					_put(ps[k], t[k % t.size()], PortraitPanic.SPOTS[k + 1])
	assert_true(await _until(func() -> bool: return loops.size() >= 9, 60 * 60, keep), "nine loops")
	var prev_show := INF
	var prev_targets := 99
	var last_twist := -1
	for e: Array in loops:
		var idx: int = e[0]
		var params := PortraitPanic.loop_params(idx)
		var lay: PackedByteArray = e[1]
		var tgt: int = e[2]
		var tw: int = e[3]
		var n := PortraitPanic.cells_with(lay, tgt).size()
		assert_eq(n, int(params["targets"]), "loop %d: %d target tiles" % [idx + 1, n])
		assert_true(n <= prev_targets, "targets never grow")
		prev_targets = n
		var distinct: Dictionary = {}
		for s in lay:
			distinct[s] = true
		assert_eq(distinct.size(), int(params["symbols"]), "loop %d: symbols in play" % [idx + 1])
		if idx < 3:
			assert_eq(tw, PortraitPanic.Twist.NONE, "no twist in loop %d" % [idx + 1])
		else:
			assert_true(tw != PortraitPanic.Twist.NONE, "a twist in loop %d" % [idx + 1])
			assert_true(tw != last_twist, "never the same twist twice in a row")
		last_twist = tw
		prev_show = minf(prev_show, float(params["show"]))
	assert_true(ps[0].alive and ps[1].alive, "both kept alive")
	assert_near(float(PortraitPanic.loop_params(8)["show"]), 2.0, 0.001, "loop 9 at the 2 s floor")


func test_memory_hides_every_face_until_the_drop() -> void:
	var ps := _spawn(2)
	var g := _game()
	g.next_twist = PortraitPanic.Twist.MEMORY
	var hidden := watch(g, &"faces_hidden")
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHOW)), "SHOW comes")
	_put(ps[0], g.target_cells()[0])
	_put(ps[1], g.target_cells()[1])
	for i in PortraitPanic.CELLS:
		assert_true(g.face_visible(i), "faces up at the start of SHOW")
	await step(int(g.memory_hide_at * 60.0) + 2)
	assert_eq(hidden.size(), 1, "hidden once, 1 s into SHOW")
	assert_true(g.faces_down, "faces down flag")
	await step(int(0.9 * 60.0))
	for i in PortraitPanic.CELLS:
		assert_false(g.face_visible(i), "cell %d face down" % i)
	assert_true(await _until(_phase_is(PortraitPanic.Phase.DROP)), "DROP comes")
	assert_false(g.faces_down, "DROP turns them up")
	await step(30)
	for i in g.target_cells():
		assert_true(g.face_visible(i), "target cell %d face up again" % i)


func test_decoy_shows_two_symbols_and_the_second_counts() -> void:
	var ps := _spawn(2)
	var g := _game()
	g.next_twist = PortraitPanic.Twist.DECOY
	var shows := watch(g, &"show_started")
	var reveals := watch(g, &"decoy_revealed")
	var drops := watch(g, &"dropped")
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHOW)), "SHOW comes")
	assert_true(g.decoy >= 0 and g.decoy != g.target, "a decoy symbol unlike the target")
	assert_eq(shows[0][1], g.decoy, "the portrait shows the decoy first")
	assert_eq(g.portrait_symbol(), g.decoy, "portrait: decoy")
	assert_true(PortraitPanic.cells_with(g.layout, g.decoy).size() > 0, "the decoy is on the floor too")
	_put(ps[0], g.target_cells()[0])
	_put(ps[1], PortraitPanic.cells_with(g.layout, g.decoy)[0])
	assert_true(await _until(func() -> bool: return not reveals.is_empty(), 60 * 6), "revealed")
	assert_eq(reveals[0][1], g.target, "the second symbol is the target")
	assert_eq(g.portrait_symbol(), g.target, "portrait: target")
	assert_true(await _until(_phase_is(PortraitPanic.Phase.DROP)), "DROP comes")
	var cells: PackedInt32Array = drops[0][1]
	for c in PortraitPanic.cells_with(g.layout, g.decoy):
		assert_true(cells.has(c), "decoy cell %d drops" % c)
	for c in g.target_cells():
		assert_false(cells.has(c), "target cell %d stays" % c)
	await step(60)
	assert_true(ps[0].alive, "the blob on the second symbol stands")
	assert_false(ps[1].alive, "the blob on the first symbol fell")


func test_swap_trades_two_rows_deterministically() -> void:
	var ps := _spawn(2, 21)
	var g := _game()
	g.next_twist = PortraitPanic.Twist.SWAP
	var swaps := watch(g, &"rows_swapped")
	var drops := watch(g, &"dropped")
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHOW)), "SHOW comes")
	var before := g.layout.duplicate()
	var rows := g.swap_rows
	assert_true(rows.x >= 0 and rows.y > rows.x and rows.y - rows.x >= 2, "two rows, apart: %s" % rows)
	var has_target := false
	for c in 7:
		has_target = has_target or before[rows.x * 7 + c] == g.target or before[rows.y * 7 + c] == g.target
	assert_true(has_target, "a swapped row holds a target tile")
	assert_true(await _until(func() -> bool: return not swaps.is_empty(), 60 * 6), "swapped")
	assert_eq(swaps[0][1], rows.x, "row a")
	assert_eq(swaps[0][2], rows.y, "row b")
	assert_eq(g.layout, PortraitPanic.swap_layout_rows(before, rows.x, rows.y), "layout = rows traded")
	_put(ps[0], g.target_cells()[0])
	_put(ps[1], g.target_cells()[1])
	assert_true(await _until(_phase_is(PortraitPanic.Phase.DROP)), "DROP comes")
	assert_eq(drops[0][1], PortraitPanic.drop_cells_of(g.layout, g.target), "the drop follows the swapped layout")
	# Same seed, same rows.
	var r1 := Vector2i()
	var r2 := Vector2i()
	g.rng.seed = 77
	r1 = g._pick_swap_rows(before, g.target)
	g.rng.seed = 77
	r2 = g._pick_swap_rows(before, g.target)
	assert_eq(r1, r2, "row pick is deterministic by seed")


func test_is_safe_and_bot_goals() -> void:
	var ps := _spawn(8)
	var g := _game()
	await step(2)
	assert_eq(g.phase, PortraitPanic.Phase.SHUFFLE, "first loop shuffling")
	assert_true(g.is_safe(g.get_cell_position(24)), "SHUFFLE: any tile is safe")
	assert_false(g.is_safe(g.to_global(Vector3(PortraitPanic.HALF - 0.1, 0.0, 0.0))), "the rim is not")
	assert_false(g.is_safe(g.to_global(Vector3(30.0, 0.0, 0.0))), "off the floor is not")
	assert_true(await _until(_phase_is(PortraitPanic.Phase.SHOW)), "SHOW comes")
	assert_true(g.is_safe(g.get_cell_position(_non_target_cells()[0])), "while reading, any tile is safe")
	await step(int(g.bot_read_time * 60.0) + 2)
	for i in PortraitPanic.CELLS:
		var safe := g.is_safe(g.get_cell_position(i))
		assert_eq(safe, g.layout[i] == g.target, "SHOW: cell %d safe only if a target" % i)
	await step(int(g.bot_react.x * 1.3 * 60.0))
	var cells: Dictionary = {}
	for p in ps:
		var goal := g.get_bot_goal(p)
		var c := g.cell_at(goal)
		assert_true(c >= 0 and g.layout[c] == g.target, "P%d's goal is a target tile" % p.slot)
		cells[c] = true
	assert_true(cells.size() >= 5, "8 bots spread over the 8 targets (%d tiles used)" % cells.size())
