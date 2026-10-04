extends GameTest
## Rising Tide: the tower layout (spawns, every mandatory step, headroom), the water height function
## (deterministic, breathers), drowning, crumbling blocks, awning launches, hanging platforms,
## scripted big / normal / small blobs climbing to the roof, the ranking rules and the bot hooks.
## Offline, the host's `call_local` RPCs run in place.

const ID := &"rising_tide"


## Offline arena with `count` scripted players, the round clock started at `t0` with `seed_value`.
## Await it: the first physics steps settle the bodies so later place_at calls stick.
func _arena(count: int = 2, seed_value: int = 5, t0: float = 0.0) -> RisingTide:
	spawn_arena(count, ID)
	await step(2)
	var mg := get_minigame() as RisingTide
	mg.begin(seed_value, t0)
	return mg


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))


## Steps until `cond` holds or `max_frames` pass; `each` runs before every tick.
func _step_until(cond: Callable, max_frames: int, each: Callable = Callable()) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await step(1, each)
	return cond.call()


## A round time at which the water stands at `h` (searched; the function is monotone).
func _time_at_height(h: float) -> float:
	var lo := 0.0
	var hi := TideTower.water_end_time()
	for i in 60:
		var m := (lo + hi) * 0.5
		if TideTower.water_height(m) < h:
			lo = m
		else:
			hi = m
	return hi


func test_tower_loads_with_8_spawns_on_the_ground() -> void:
	assert_true(MinigameRegistry.has(ID), "rising_tide is registered")
	assert_eq(MinigameCatalog.info(ID)["kind"], &"climb", "catalog kind")
	var ps := spawn_arena(8, ID)
	var mg := get_minigame() as RisingTide
	if not assert_true(mg != null, "rising_tide loads with its own script"):
		return
	assert_eq(ps.size(), 8, "8 players spawned")
	assert_near(mg.time_limit, 75.0, 0.001, "75 s backstop")
	assert_true(TideTower.water_end_time() > 60.0 and TideTower.water_end_time() < 70.0, "the water tops out in 60-70 s (%.1f)" % TideTower.water_end_time())
	var points := mg.get_spawn_points()
	assert_eq(points.size(), 8, "8 spawn markers")
	var lanes := {}
	for i in points.size():
		var o := points[i].origin
		assert_near(o, TideTower.spawn_xform(i).origin, 0.001, "spawn %d matches TideTower" % i)
		assert_near(o.y, 0.0, 0.001, "spawn %d on the ground" % i)
		assert_true(mg.is_safe(o), "spawn %d is safe" % i)
		lanes[snappedf(o.z, 0.1)] = true
		for j in i:
			assert_true(Vector2(o.x - points[j].origin.x, o.z - points[j].origin.z).length() >= 1.1, "spawns %d and %d apart" % [i, j])
	assert_eq(lanes.size(), 3, "spawns spread across all three lanes")
	var first: Dictionary = {}
	for k in 4:
		first[snappedf(points[k].origin.z, 0.1)] = true
	assert_eq(first.size(), 3, "the first four already use every lane")
	await step(30)
	for p in ps:
		assert_true(p.global_position.y > -0.1 and p.global_position.y < 0.3, "P%d stands on the ground (y=%.2f)" % [p.slot, p.global_position.y])
	# the host's shuffled spawn order: every spawn used once, different seeds differ
	var slots := PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7])
	var a := RisingTide.spawn_order(slots, 11)
	var used := {}
	for k in range(1, a.size(), 2):
		used[a[k]] = true
	assert_eq(used.size(), 8, "every spawn point used once")
	assert_eq(a, RisingTide.spawn_order(slots, 11), "same seed, same order")
	var differ := false
	for sd in range(12, 20):
		differ = differ or RisingTide.spawn_order(slots, sd) != a
	assert_true(differ, "other seeds shuffle differently")


func test_every_route_step_is_a_small_hop_with_headroom() -> void:
	var all := TideTower.pieces()
	assert_eq(TideTower.ids_of(TideTower.Kind.CRUMBLE).size(), 6, "a few crumbling blocks")
	assert_eq(TideTower.ids_of(TideTower.Kind.AWNING).size(), 2, "two awnings")
	assert_eq(TideTower.ids_of(TideTower.Kind.HANGING).size(), 6, "hanging platforms")
	for s in TideTower.SECTIONS:
		var y := TideTower.floor_y(s)
		for alt: bool in [false, true]:
			var r := TideTower.route(s, alt)
			assert_true(r.size() >= 1, "section %d has a %s route" % [s, "alt" if alt else "main"])
			if TideTower.ALT_KIND[s] == TideTower.Alt.AWNING and alt:
				continue
			var prev := y
			var prev_piece: TideTower.Piece = null
			for id in r:
				var pc: TideTower.Piece = TideTower.piece(id)
				var rise := pc.top - prev
				assert_true(rise > 0.0 and rise <= 0.9 + 0.001, "section %d step %d rises %.2f (<= 0.9)" % [s, pc.step, rise])
				if prev_piece:
					var gap := maxf(pc.x0 - prev_piece.x1, prev_piece.x0 - pc.x1)
					var limit := 0.11 if pc.kind != TideTower.Kind.HANGING else 0.11
					assert_true(gap <= limit, "section %d step %d: gap %.2f" % [s, pc.step, gap])
				prev = pc.top
				prev_piece = pc
			# last step to the next floor: +0.9 at most, and touching the edge (hanging: within the sway)
			var last: TideTower.Piece = TideTower.piece(r[r.size() - 1])
			var up := TideTower.floor_y(s + 1) - last.top
			assert_true(up > 0.0 and up <= 0.9 + 0.001, "section %d: onto the next floor is %.2f up" % [s, up])
			var e := TideTower.edge_x(s)
			var near := minf(absf(last.x0 - e), absf(last.x1 - e))
			if last.kind == TideTower.Kind.HANGING:
				assert_true(near - TideTower.SWAY_AMP >= 0.04 and near + TideTower.SWAY_AMP <= 0.76, "section %d: the top hanging platform never slides under the floor and never leaves more than 0.75 m (%.2f)" % [s, near])
			else:
				assert_near(near, 0.0, 0.001, "section %d: the top step touches the edge" % s)
		# the awning sits at the high end, next to the edge
		if TideTower.ALT_KIND[s] == TideTower.Alt.AWNING:
			var aw: TideTower.Piece = TideTower.piece(TideTower.route(s, true)[0])
			assert_true(minf(absf(aw.x0 - TideTower.edge_x(s)), absf(aw.x1 - TideTower.edge_x(s))) < 0.01, "awning %d at the edge" % s)
	# headroom: over every walkable top, nothing solid lower than 2.7 m (hanging: their sway range)
	for a: TideTower.Piece in all:
		for b: TideTower.Piece in all:
			if a == b or b.bottom <= a.top + 0.05:
				continue
			if a.kind == TideTower.Kind.FLOOR and b.section == a.section and b.kind != TideTower.Kind.FLOOR and b.kind != TideTower.Kind.ROOF:
				continue  # the floor's own stairs and alt pieces (the walkway is the front lane)
			# hanging platforms sway together: grow by the sway only against everything else
			var grow := TideTower.SWAY_AMP if ((a.kind == TideTower.Kind.HANGING) != (b.kind == TideTower.Kind.HANGING) or a.section != b.section) and (a.kind == TideTower.Kind.HANGING or b.kind == TideTower.Kind.HANGING) else 0.0
			var ox := minf(a.x1, b.x1 + grow) - maxf(a.x0, b.x0 - grow)
			var oz := minf(a.z1, b.z1) - maxf(a.z0, b.z0)
			if ox <= 0.001 or oz <= 0.001:
				continue
			assert_true(b.bottom - a.top >= 2.7 - 0.001, "headroom over piece %d (kind %d, s%d) under %d (kind %d, s%d): %.2f" % [a.id, a.kind, a.section, b.id, b.kind, b.section, b.bottom - a.top])
	# the walkway (front lane) is clear at every floor's level from its arrival edge to past the low end
	for s in TideTower.SECTIONS:
		var y := TideTower.floor_y(s)
		for pc: TideTower.Piece in all:
			if pc.section == s and pc.kind != TideTower.Kind.FLOOR and pc.kind != TideTower.Kind.ROOF:
				assert_true(pc.z1 <= TideTower.Z_FRONT - TideTower.LANE_W + 0.001, "section %d piece %d keeps out of the front lane" % [s, pc.id])
		var span := TideTower.floor_span(s)
		var xl := TideTower.low_x(s) - TideTower.dir(s) * 0.95
		assert_true(xl > span.x + 0.4 and xl < span.y - 0.4, "section %d: room past the low end on floor %d" % [s, s])
		assert_true(y >= 0.0, "floor height")


func test_water_height_is_deterministic_with_breathers() -> void:
	assert_near(TideTower.water_height(0.0), TideTower.WATER_START, 0.0001, "starts below the ground floor")
	assert_true(TideTower.WATER_START < -0.5, "below the first platforms")
	assert_near(TideTower.water_height(1.0) - TideTower.water_height(0.0), TideTower.WATER_RATE0, 0.01, "slow at first (0.18 m/s)")
	var prev := TideTower.water_height(0.0)
	var flat := 0.0
	var flats: Array[float] = []
	var t := 0.0
	while t < TideTower.water_end_time() + 5.0:
		t += 0.05
		var h := TideTower.water_height(t)
		assert_true(h >= prev - 0.00001, "never sinks (%.2f at %.2f)" % [h, t])
		assert_eq(h, TideTower.water_height(t), "same time, same height")
		if absf(h - prev) < 0.00001 and h < TideTower.WATER_TOP - 0.001:
			flat += 0.05
		elif flat > 0.0:
			flats.append(flat)
			flat = 0.0
		prev = h
	assert_eq(flats.size(), 2, "two breathers (%s)" % [flats])
	for f in flats:
		assert_near(f, TideTower.BREATHER_TIME, 0.11, "each breather lasts 2 s")
	for i in TideTower.BREATHERS.size():
		var b0 := TideTower.breather_start(i)
		assert_near(TideTower.water_height(b0 + 1.0), TideTower.BREATHERS[i], 0.001, "breather %d at %.1f m" % [i, TideTower.BREATHERS[i]])
		assert_eq(TideTower.breather_at(b0 + 1.0), i, "breather %d running" % i)
		assert_eq(TideTower.breather_at(b0 - 0.5), -1, "not yet")
	var late := TideTower.breather_start(1) + 6.0
	assert_near(TideTower.water_height(late + 1.0) - TideTower.water_height(late), TideTower.WATER_RATE1, 0.02, "fast at the end (0.5 m/s)")
	var end_t := TideTower.water_end_time()
	assert_near(TideTower.water_height(end_t), TideTower.WATER_TOP, 0.001, "tops out at the end time")
	assert_true(TideTower.water_height(end_t - 0.5) < TideTower.WATER_TOP, "still rising just before")
	assert_true(TideTower.WATER_TOP < TideTower.ROOF_Y - 0.5 and TideTower.WATER_TOP > TideTower.ROOF_Y - 1.0, "stops just below the roof")
	# the live scene's water follows the round clock
	var mg: RisingTide = await _arena(2, 3, 20.0)
	await step(20)
	assert_near(mg.water_y(), TideTower.water_height(mg.round_time()), 0.0001, "water_y follows the clock")
	var water := mg.get_node(^"Water") as MeshInstance3D
	assert_near(water.position.y, TideTower.water_height(mg._t_vis), 0.0001, "the water mesh too")


func test_drowning_after_0_6_s_under_water() -> void:
	var t_flood := _time_at_height(1.2)
	var mg: RisingTide = await _arena(3, 4, t_flood)
	var dry := players[0]
	var diver := players[1]
	var dipper := players[2]
	_put(dry, Vector3(-5.0, TideTower.floor_y(1) + 0.05, TideTower.LANE_FRONT))
	_put(diver, Vector3(-3.0, 0.05, TideTower.LANE_FRONT))  # centre at 0.55 < 1.2: under water
	_put(dipper, Vector3(-5.6, TideTower.floor_y(1) + 0.05, TideTower.LANE_MID))
	var outs := watch(diver, &"eliminated")
	var drowned := watch(mg, &"drowned")
	var t0 := mg.round_time()
	await step(int(0.6 * 60.0) - 6)
	assert_true(diver.alive, "still holding its breath after 0.5 s")
	assert_true(await _step_until(func() -> bool: return not diver.alive, 20), "drowned")
	assert_near(mg.round_time() - t0, 0.6, 0.06, "after 0.6 s under water")
	if assert_eq(outs.size(), 1, "one elimination"):
		assert_eq(outs[0][0], &"drowned", "reason drowned")
	assert_eq(drowned.size(), 1, "the minigame saw it")
	assert_eq(mg.knocked_out, [1] as Array[int], "recorded as knocked out")
	# a dip shorter than 0.6 s does not count, and the timer starts over
	for k in 2:
		_put(dipper, Vector3(-3.4, 0.05, TideTower.LANE_MID))
		await step(24)
		_put(dipper, Vector3(-5.6, TideTower.floor_y(1) + 0.05, TideTower.LANE_MID))
		await step(6)
	assert_true(dipper.alive, "two 0.4 s dips are survived")
	assert_true(dry.alive, "the dry one is fine")


func test_last_blob_dry_wins_and_drowned_rank_by_lateness() -> void:
	var t_flood := _time_at_height(1.5)
	var mg: RisingTide = await _arena(4, 6, t_flood)
	_put(players[3], Vector3(-5.0, TideTower.floor_y(1) + 0.05, TideTower.LANE_FRONT))
	_put(players[1], Vector3(-3.0, TideTower.floor_y(1) + 0.05, TideTower.LANE_FRONT))
	_put(players[2], Vector3(-6.0, TideTower.floor_y(1) + 0.05, TideTower.LANE_FRONT))
	_put(players[0], Vector3(-3.0, 0.05, TideTower.LANE_FRONT))
	await step(12)
	# 1 and 2 go under together a moment later: they tie
	_put(players[1], Vector3(-1.0, 0.05, TideTower.LANE_FRONT))
	_put(players[2], Vector3(-2.0, 0.05, TideTower.LANE_MID))
	assert_true(await _step_until(func() -> bool: return mg.is_finished(), 90), "the round ended")
	assert_eq(mg.finish_groups, [[3], [1, 2], [0]], "the survivor, then the same-tick pair, then the first out")
	assert_eq(ranking, [3, 1, 2, 0] as Array[int], "flat order")
	assert_near(mg.finish_grace, 2.0, 0.001, "a closing moment for the flag wave")


func test_crumbling_block_falls_0_8_s_after_standing_and_grows_back() -> void:
	var mg: RisingTide = await _arena(2, 2, 0.0)
	var ids := TideTower.ids_of(TideTower.Kind.CRUMBLE)
	var pc: TideTower.Piece = TideTower.piece(ids[0])
	var i := mg.crumble_index_of(ids[0])
	_put(players[0], Vector3(-6.0, TideTower.floor_y(1) + 0.05, TideTower.LANE_FRONT))
	var cracks := watch(mg, &"crumble_cracked")
	var falls := watch(mg, &"crumble_fell")
	var regrows := watch(mg, &"crumble_regrew")
	assert_true(mg.crumble_has_collider(i), "solid at first")
	var top := Vector3(pc.center().x, pc.top + 0.05, pc.center().z)
	assert_true(mg.is_safe(top), "an intact crumble block is safe")
	_put(players[1], top)
	assert_true(await _step_until(func() -> bool: return cracks.size() > 0, 30), "standing on it cracks it")
	var t_crack := mg.round_time()
	assert_false(mg.is_safe(top), "a cracking block is not safe for bots")
	assert_true(mg.crumble_has_collider(i), "still solid while cracking")
	assert_true(await _step_until(func() -> bool: return falls.size() > 0, 80), "it falls")
	assert_near(mg.round_time() - t_crack, 0.8, 0.04, "0.8 s after it cracked")
	assert_false(mg.crumble_has_collider(i), "its collider is gone")
	assert_eq(mg.crumble_state[i], RisingTide.CrumbleState.FALLEN, "fallen")
	await step(20)
	assert_true(players[1].global_position.y < pc.top - 0.5, "the blob on it dropped (y=%.2f)" % players[1].global_position.y)
	# grows back once nobody is in the way
	_put(players[1], Vector3(-6.0, TideTower.floor_y(1) + 0.05, TideTower.LANE_MID))
	assert_true(await _step_until(func() -> bool: return regrows.size() > 0, int((mg.crumble_regrow + 1.0) * 60.0)), "grows back")
	assert_true(mg.crumble_has_collider(i), "solid again")
	assert_eq(mg.crumble_state[i], RisingTide.CrumbleState.SOLID, "solid state")


func test_awnings_launch_every_size_up_a_floor() -> void:
	var mg: RisingTide = await _arena(3, 2, 0.0)
	var aw: TideTower.Piece = TideTower.piece(TideTower.ids_of(TideTower.Kind.AWNING)[0])
	var sizes: Array[String] = ["small", "normal", "big"]
	for k in 3:
		var p := players[k]
		(p.get_component(&"size") as SizeComponent).set_size_override(sizes[k], true)
	await step(2)
	for k in 3:
		var p := players[k]
		var others: Array[Player] = []
		for q in players:
			if q != p:
				others.append(q)
		for q in others:
			_put(q, Vector3(-5.0 + q.slot, 0.05, TideTower.LANE_FRONT))
		var launches := watch(mg, &"launched")
		_put(p, Vector3(aw.center().x, aw.top + 0.6, aw.center().z))
		var peak := -INF
		for f in 90:
			await step(1)
			peak = maxf(peak, p.global_position.y)
		assert_true(launches.size() >= 1, "%s blob launched" % sizes[k])
		var rise := peak - aw.top
		assert_true(rise >= mg.awning_apex - 0.25 and rise <= mg.awning_apex + 0.3, "%s blob rises %.2f m (about %.1f)" % [sizes[k], rise, mg.awning_apex])
		assert_true(peak > TideTower.floor_y(aw.section + 1) + 0.9, "%s: clears the next floor's edge" % sizes[k])
		var tall := (p.get_component(&"size") as SizeComponent).body_scale
		assert_true(peak + tall < TideTower.floor_y(aw.section + 2) - TideTower.FLOOR_THICK, "%s: never bumps the shelf above (head at %.2f)" % [sizes[k], peak + tall])


func test_hanging_platforms_sway_together_from_the_seed() -> void:
	var mg: RisingTide = await _arena(2, 77, 10.0)
	var phase := TideTower.sway_phase(77)
	for t: float in [0.0, 1.3, 7.7, 30.2]:
		for s in TideTower.SECTIONS:
			var a := TideTower.sway(s, t, phase)
			assert_eq(a, TideTower.sway(s, t, phase), "deterministic")
			assert_true(absf(a) <= TideTower.SWAY_AMP + 0.0001, "within the amplitude")
	assert_true(TideTower.sway_phase(77) != TideTower.sway_phase(78), "the seed sets the phase")
	await step(30)
	var ids := TideTower.ids_of(TideTower.Kind.HANGING)
	for i in ids.size():
		var body := mg.get_node(^"Hanging").get_node("Hang%d" % i) as AnimatableBody3D
		assert_near(body.position, mg.hanging_position(i, mg.round_time()), 0.06, "hanging %d follows the clock" % i)
	# a blob riding a hanging platform moves with it
	var hp := mg.hanging_position(0, mg.round_time())
	_put(players[1], hp + Vector3(0.0, 0.05, 0.0))
	await step(10)
	var start_x := players[1].global_position.x
	var plat_x := mg.hanging_position(0, mg.round_time()).x
	await step(40)
	var moved := players[1].global_position.x - start_x
	var plat_moved := mg.hanging_position(0, mg.round_time()).x - plat_x
	assert_near(moved, plat_moved, 0.12, "the rider sways with it")
	assert_true(players[1].global_position.y > hp.y - 0.1, "and stays on top")


## Drives `p` up the main route of every section to the roof the way the bot brain does: walk to
## get_bot_goal, hop when blocked on the floor, hold the jump. Water frozen below the ground.
func _climb(size_id: String) -> void:
	var mg: RisingTide = await _arena(2, 9, 0.0)
	mg._freeze_at = 0.0  # the water stays at its start
	var p := players[0]
	_put(players[1], Vector3(6.0, 0.05, TideTower.LANE_FRONT))
	var size := p.get_component(&"size") as SizeComponent
	size.set_size_override(size_id, true)
	await step(2)
	for s in TideTower.SECTIONS:
		mg.force_route(p, s, false)
	var jump := p.get_component(&"jump") as JumpComponent
	assert_near(jump.jump_height, 1.3 * float(Cosmetics.size_info(size_id)["jump"]), 0.01, "%s blob's jump height" % size_id)
	var st := {"blocked": 0, "hold": 0, "best": 0}
	var jumps := watch(p, &"jumped")
	var reached := await _step_until(func() -> bool: return TideTower.on_roof(p.global_position) and p.is_on_floor(), 60 * 50,
		func(_i: int) -> void:
			var goal := mg.get_bot_goal(p)
			var to := Vector2(goal.x - p.global_position.x, goal.z - p.global_position.z)
			p.intent.move = to.normalized() if to.length() > 0.05 else Vector2.ZERO
			var hv := Vector2(p.velocity.x, p.velocity.z).length()
			if p.is_on_floor() and to.length() > 0.3 and hv < 0.6:
				st["blocked"] += 1
			else:
				st["blocked"] = 0
			p.intent.jump_pressed = false
			if st["blocked"] >= 8 and st["hold"] <= 0:
				p.intent.jump_pressed = true
				st["hold"] = 24
				st["blocked"] = 0
			p.intent.jump_held = st["hold"] > 0
			st["hold"] -= 1
			st["best"] = maxi(st["best"], TideTower.level_of(p.global_position.y)))
	assert_true(reached, "a %s blob climbs the main routes to the roof (got to floor %d, at %s)" % [size_id, st["best"], p.global_position])
	assert_true(jumps.size() >= 20, "by hopping up the steps (%d jumps)" % jumps.size())
	print("  tide climb %s: roof at %.1f s with %d jumps" % [size_id, mg.round_time(), jumps.size()])


func test_a_big_blob_climbs_to_the_roof() -> void:
	await _climb("big")


func test_a_normal_blob_climbs_to_the_roof() -> void:
	await _climb("normal")


func test_a_small_blob_climbs_to_the_roof() -> void:
	await _climb("small")


func test_ranking_summit_roof_order_height_and_ties() -> void:
	var s := {
		0: {"height": 21.6, "roof_t": 40.0},
		1: {"height": 21.6, "roof_t": 35.0},
		2: {"height": 20.7, "roof_t": -1.0},
		3: {"height": 21.6, "roof_t": 45.0},
		4: {"height": 20.72, "roof_t": -1.0},
		5: {"height": 19.0, "roof_t": -1.0},
	}
	# 3 touched the flag first: first among survivors although it reached the roof last
	var g := TideTower.rank(s, 3, [[7], [6, 8]])
	assert_eq(g, [[3], [1], [0], [4, 2], [5], [6, 8], [7]], "summit, roof by arrival, height (tie within 5 cm), drowned latest first")
	# the summit holder drowned: no bonus
	var s2 := s.duplicate(true)
	s2.erase(3)
	assert_eq(TideTower.rank(s2, -1, []), [[1], [0], [4, 2], [5]], "without a summit holder")
	# same arrival time on the roof: a tie
	var s3 := {0: {"height": 21.6, "roof_t": 30.0}, 1: {"height": 21.6, "roof_t": 30.0}}
	assert_eq(TideTower.rank(s3, -1, []), [[0, 1]], "same arrival time ties")
	# live: the water tops out with blobs on the roof and below
	var mg: RisingTide = await _arena(4, 8, TideTower.water_end_time() - 3.0)
	_put(players[2], Vector3(0.6, TideTower.ROOF_Y + 0.05, TideTower.LANE_FRONT))
	await step(10)
	_put(players[0], Vector3(TideTower.FLAG_POS.x, TideTower.ROOF_Y + 0.05, TideTower.FLAG_POS.z))
	await step(10)
	_put(players[0], Vector3(0.0, TideTower.ROOF_Y + 0.05, TideTower.LANE_MID))
	var st: TideTower.Piece = TideTower.piece(TideTower.route(5, false)[2])
	_put(players[1], Vector3(st.center().x, st.top + 0.05, st.center().z))
	_put(players[3], Vector3(-5.0, TideTower.floor_y(5) + 0.05, TideTower.LANE_FRONT))
	assert_eq(mg.summit_slot, 0, "slot 0 touched the flag")
	assert_true(mg.roof_times[2] < mg.roof_times[0], "slot 2 was on the roof first")
	assert_true(await _step_until(func() -> bool: return mg.is_finished(), 60 * 5), "the water topped out")
	assert_eq(mg.finish_groups, [[0], [2], [1], [3]], "summit, roof, then the step below; the one on floor 5 drowned")


func test_bot_hooks_follow_the_routes() -> void:
	var mg: RisingTide = await _arena(2, 8, 0.0)
	var p := players[1]
	_put(players[0], Vector3(6.0, 0.05, TideTower.LANE_FRONT))
	await step(2)
	# walls and gaps are unsafe, floors and steps safe
	assert_true(mg.is_safe(Vector3(-3.0, 0.0, TideTower.LANE_FRONT)), "the ground walkway")
	assert_false(mg.is_safe(Vector3(1.6, 0.0, TideTower.LANE_BACK)), "inside the 2.7 m crate stack")
	var s1: TideTower.Piece = TideTower.piece(TideTower.route(0, false)[0])
	assert_true(mg.is_safe(Vector3(s1.center().x, 0.0, s1.center().z)), "the first step is a hop up: safe")
	assert_false(mg.is_safe(Vector3(3.0, TideTower.floor_y(2), TideTower.LANE_FRONT) + Vector3(-4.5, 0.0, 0.0)), "off the end of shelf 2: a long drop")
	assert_true(mg.is_safe(Vector3(7.2, 0.0, 0.0)), "the wall is no danger (judged where a blob pressed against it stands)")
	# the water makes low ground unsafe a moment before it gets there
	mg.begin(8, _time_at_height(0.3))
	await step(1)
	assert_false(mg.is_safe(Vector3(-3.0, 0.0, TideTower.LANE_FRONT)), "the flooding ground")
	assert_true(mg.is_safe(Vector3(-3.0, TideTower.floor_y(1), TideTower.LANE_FRONT)), "floor 1 is dry")
	mg.begin(8, 0.0)
	await step(1)
	# goals lead up, section by section, along the walkway, into the route's lane, up the steps
	for s in TideTower.SECTIONS:
		mg.force_route(p, s, false)
		var y := TideTower.floor_y(s)
		var d := TideTower.dir(s)
		var xl := TideTower.low_x(s)
		var arrive := Vector3(-TideTower.edge_x(s) * 0.6, y + 0.05, TideTower.LANE_FRONT)
		_put(p, arrive)
		await step(1)
		var g := mg.get_bot_goal(p)
		assert_near(g.z, TideTower.LANE_FRONT, 0.01, "s%d: along the walkway" % s)
		assert_true((g.x - xl) * d < -0.4, "s%d: past the low end (%s)" % [s, g])
		assert_true(mg.is_safe(g), "s%d: the walkway goal is safe" % s)
		_put(p, Vector3(xl - d * 0.95, y + 0.05, TideTower.LANE_FRONT))
		await step(1)
		g = mg.get_bot_goal(p)
		assert_near(g.z, TideTower.LANE_BACK, 0.01, "s%d: into the back lane" % s)
		_put(p, Vector3(xl - d * 0.75, y + 0.05, TideTower.LANE_BACK))
		await step(1)
		g = mg.get_bot_goal(p)
		assert_near(g.y, TideTower.floor_y(s + 1), 0.01, "s%d: up the stairs" % s)
		assert_true(mg.is_safe(g), "s%d: the top goal is safe" % s)
	# on the roof: the flag first
	_put(p, Vector3(0.0, TideTower.ROOF_Y + 0.05, TideTower.LANE_MID))
	await step(1)
	assert_near(mg.get_bot_goal(p), TideTower.FLAG_POS, 0.01, "the flag")
	# the awning route leads onto the awning
	var aw: TideTower.Piece = TideTower.piece(TideTower.ids_of(TideTower.Kind.AWNING)[0])
	mg.force_route(p, aw.section, true)
	_put(p, Vector3(-3.0, 0.05, TideTower.LANE_FRONT))
	await step(1)
	var ga := mg.get_bot_goal(p)
	assert_near(ga.z, TideTower.LANE_MID, 0.01, "into the awning's lane, past its high end")
	assert_true(ga.x < aw.x0, "past its high end (%s)" % ga)
	_put(p, Vector3(ga.x, 0.05, ga.z))
	await step(1)
	ga = mg.get_bot_goal(p)
	assert_near(Vector2(ga.x, ga.z), Vector2(aw.center().x, aw.center().z), 0.01, "onto the awning")
	# a crumble route with a fallen block is given up
	var cid := TideTower.ids_of(TideTower.Kind.CRUMBLE)[0]
	var cpc: TideTower.Piece = TideTower.piece(cid)
	mg.force_route(p, cpc.section, true)
	assert_true(mg.wants_alt(p, cpc.section), "crumble route while intact")
	mg._rpc_crumble(PackedInt32Array([mg.crumble_index_of(cid)]))
	assert_false(mg.wants_alt(p, cpc.section), "not once a block cracks")
