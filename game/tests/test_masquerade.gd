extends GameTest
## Masquerade rules, offline: the disguise (everyone and every extra looks the same, no name
## tags, normal size) and its release on every exit path, unmasking, wrong shoves on NPCs, the
## end and the ranking with ties, extras kept out of ranking and points, the "that's you" ring.
## Rule tests stop the bot driver and park the extras (frozen, in a row at the front) so shoves
## are scripted exactly.

const ID := &"masquerade"
const NAME_TAG_PATH := "res://ui/round/name_tag.tscn"


## Like spawn_arena, with options: `big` (slot whose roster size is big), `tags` (attach a
## NameTag to every player before _setup, as Stage does with a display), `bots` (keep the
## bot driver), `park` (default true: freeze the extras in a row at the front).
func _arena(count: int, opts: Dictionary = {}) -> Masquerade:
	Masquerade.next_seed = int(opts.get("seed", 5))
	Net.start_offline()
	for i in count - 1:
		Net.add_bot()
	if opts.has("big"):
		(Net.roster[int(opts["big"])] as PlayerInfo).loadout["size"] = "big"
	stage = STAGE_SCENE.instantiate() as Stage
	add_child(stage)
	var mg := stage.load_minigame(ID) as Masquerade
	players.assign(stage.players.values())
	mg.finished.connect(func(r: Array[int]) -> void: ranking = r)
	for p in players:
		(p.get_component(&"controller") as ControllerComponent).scripted = true
		if opts.get("tags", false):
			var tag := (load(NAME_TAG_PATH) as PackedScene).instantiate()
			tag.name = "NameTag"
			p.add_child(tag)
			tag.call(&"setup", p)
	mg._setup(players)
	for p in players:
		p.frozen = false
	mg._start()
	if not opts.get("bots", false):
		mg.bots = null
	if opts.get("park", true):
		for i in stage.extras.size():
			var x := stage.extras[i]
			x.frozen = true
			x.place_at(Transform3D(Basis.IDENTITY, Vector3(-8.0 + 0.82 * i, 0.0, 6.5)))
	# Physics sees a teleport a frame late (a blob standing on a parked extra would ride along):
	# let it settle before the test places anyone.
	await step(3)
	return mg


## Puts `p` at `pos` facing +X (or `dir`).
func _put(p: Player, pos: Vector3, yaw := PI / 2.0) -> void:
	p.place_at(Transform3D(Basis(Vector3.UP, yaw), pos))
	p.velocity = Vector3.ZERO


## One scripted shove by `p`.
func _shove(p: Player) -> void:
	await step(2, func(i: int) -> void: p.intent.action_pressed = i == 0)


func _real_key(p: Player) -> Array:
	return MasqDisguise.colour_key(p.loadout)


func _look_key() -> Array:
	return MasqDisguise.colour_key(MasqDisguise.LOOK)


# --- Disguise ------------------------------------------------------------------------------

func test_everyone_and_every_extra_looks_the_same() -> void:
	var mg := await _arena(4, {"big": 2, "tags": true, "park": false})
	await step(3)
	assert_eq(stage.extras.size(), 20, "20 extras with 4 players")
	var ref := MasqDisguise.fingerprint(stage.extras[0])
	assert_eq(ref["colours"], _look_key(), "an extra wears the masquerade colours")
	assert_true(bool(ref["mask"]), "an extra wears the mask")
	assert_eq(ref["items"], [], "an extra wears nothing else")
	for b: Player in players + stage.extras:
		var fp := MasqDisguise.fingerprint(b)
		assert_eq(fp, ref, "blob %d looks exactly like an extra" % b.slot)
	for p in players:
		var tag := p.get_node(^"NameTag") as Node3D
		assert_false(tag.visible, "P%d name tag hidden" % p.slot)
		assert_eq(p.get_component(&"team").get(&"team"), -1, "no team ring")
	# The big player: shown at normal size, and moves / shoves like a normal one.
	var big := players[2]
	assert_eq(big.loadout["size"], "big", "slot 2 really is big")
	assert_eq((big.get_component(&"size") as SizeComponent).size_id, "normal", "but normal under the disguise")
	await step(5)
	assert_near((big.get_component(&"visuals") as Node3D).scale.x, 1.0, 0.001, "big blob shown at normal size")
	var capsule := (big.get_node(^"CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D
	assert_near(capsule.radius, 0.4, 0.001, "big blob has the normal capsule radius")
	assert_near(capsule.height, 1.0, 0.001, "big blob has the normal capsule height")
	var normal := players[1]
	for stat: Array in SizeComponent.STATS:
		assert_near(float(big.get_component(stat[0]).get(stat[1])), float(normal.get_component(stat[0]).get(stat[1])), 0.001,
			"big blob %s.%s like a normal one" % [stat[0], stat[1]])
	# Humans stroll: full stick is the fastest NPC stroll.
	var human := (players[0].get_component(&"movement") as MovementComponent).max_speed
	var bot := (players[1].get_component(&"movement") as MovementComponent).max_speed
	assert_near(human, bot * mg.human_speed_factor, 0.001, "humans walk at the NPC pace")
	assert_eq((players[0].get_component(&"shove") as ShoveComponent).cooldown, 1.2, "1.2 s shove cooldown")


func test_extras_count_and_never_players() -> void:
	var mg := await _arena(2)
	assert_eq(stage.extras.size(), 14, "14 extras with 2 players")
	assert_eq(mg.players.size(), 2, "extras are not players")
	for x in stage.extras:
		assert_true(x.is_extra and x.slot >= Stage.EXTRA_SLOT_BASE, "extra slot")
		assert_eq(x.loadout, MasqDisguise.LOOK, "extra spawned in the masquerade look")
	for slot: int in mg.points:
		assert_true(slot < Stage.EXTRA_SLOT_BASE, "points only for players")


## The NPC dancers are dealt over the dance circles (spread over the floor), not piled into one.
func test_dancers_spread_over_the_circles() -> void:
	await _arena(4, {"park": false})
	var per_circle: Dictionary = {}
	var dancers := 0
	for x in stage.extras:
		var brain := BotBrain.of(x)
		if brain.extra_mode != &"dance":
			continue
		dancers += 1
		per_circle[brain._dance_center] = int(per_circle.get(brain._dance_center, 0)) + 1
	assert_true(dancers >= 3, "some dancers (%d)" % dancers)
	assert_eq(per_circle.size(), mini(dancers, Masquerade.DANCE_CENTERS.size()), "every circle used before one doubles up")
	for c: Vector3 in per_circle:
		assert_true(Masquerade.DANCE_CENTERS.has(c), "a known circle")
		assert_true(int(per_circle[c]) - dancers / Masquerade.DANCE_CENTERS.size() <= 1, "even deal")


func test_players_are_placed_among_the_crowd() -> void:
	await _arena(4, {"park": false})
	var markers := get_minigame().get_spawn_points()
	for p in players:
		var on_marker := false
		for m in markers:
			if Vector2(m.origin.x - p.global_position.x, m.origin.z - p.global_position.z).length() < 0.05:
				on_marker = true
		assert_false(on_marker, "P%d is not on a spawn marker" % p.slot)
		assert_true(get_minigame().is_safe(p.global_position), "P%d on the floor" % p.slot)


# --- Rules ---------------------------------------------------------------------------------

func test_shove_on_a_real_player_unmasks_and_scores() -> void:
	var mg := await _arena(4, {"tags": true})
	var outs := watch(players[1], &"eliminated")
	_put(players[0], Vector3(0.0, 0.0, 0.0))
	_put(players[1], Vector3(1.0, 0.0, 0.0))
	await _shove(players[0])
	assert_true(mg.found.has(1), "P1 found")
	assert_eq(mg.points[0], 2, "shover +2")
	assert_eq(mg.unmask_log, [[1, 0]], "unmask logged")
	assert_true(players[1].frozen, "the unmasked stands revealed")
	assert_false(mg.disguise.holds(players[1]), "P1's disguise released")
	await step(2)
	var fp := MasqDisguise.fingerprint(players[1])
	assert_eq(fp["colours"], _real_key(players[1]), "true colours back")
	assert_false(bool(fp["mask"]), "mask off")
	assert_true((fp["items"] as Array).size() > 0, "own hat back")
	await step(int((mg.reveal_hold + 0.1) / physics_delta()))
	assert_false(players[1].alive, "out after the reveal")
	assert_eq(outs.size(), 1, "eliminated once")
	assert_eq(outs[0][0], &"unmasked", "reason unmasked")
	assert_eq(mg.knocked_out, [1], "knock_out recorded")
	assert_false(mg.is_finished(), "three still unfound")


func test_shove_on_an_npc_stuns_reveals_and_costs_a_point() -> void:
	var mg := await _arena(4)
	var x := stage.extras[0]
	x.frozen = false
	var hits := watch(x, &"got_hit")
	# First earn 2 points.
	_put(players[0], Vector3(0.0, 0.0, 0.0))
	_put(players[3], Vector3(1.0, 0.0, 0.0))
	await _shove(players[0])
	assert_eq(mg.points[0], 2, "2 points")
	await step(int(1.3 / physics_delta()))  # cooldown
	_put(players[0], Vector3(0.0, 0.0, -3.0))
	_put(x, Vector3(1.0, 0.0, -3.0))
	await _shove(players[0])
	assert_eq(mg.wrong_log, [[0, x.slot]], "wrong shove logged")
	assert_eq(mg.points[0], 1, "-1 point")
	assert_eq(hits.size(), 1, "the NPC was knocked")
	assert_true(players[0].control_locked, "shover stunned")
	await step(10)
	assert_eq(MasqDisguise.fingerprint(players[0])["colours"], _real_key(players[0]), "true colours flash")
	assert_true(bool(MasqDisguise.fingerprint(players[0])["mask"]), "still masked while flashing")
	await step(int(1.2 / physics_delta()))
	assert_true(players[0].control_locked, "still stunned at 1.4 s")
	await step(int(0.4 / physics_delta()))
	assert_false(players[0].control_locked, "stun over after 1.5 s")
	assert_eq(MasqDisguise.fingerprint(players[0])["colours"], _look_key(), "disguised again")
	# Not below zero.
	await step(int(0.5 / physics_delta()))
	_put(players[0], Vector3(0.0, 0.0, -3.0))
	_put(x, Vector3(1.0, 0.0, -3.0))
	x.velocity = Vector3.ZERO
	await _shove(players[0])
	await step(int(1.7 / physics_delta()))
	_put(players[0], Vector3(0.0, 0.0, -3.0))
	_put(x, Vector3(1.0, 0.0, -3.0))
	await _shove(players[0])
	assert_eq(mg.wrong_log.size(), 3, "three wrong shoves")
	assert_eq(mg.points[0], 0, "never below 0")
	assert_true(x.alive, "the NPC is fine")
	for slot: int in mg.points:
		assert_true(slot < Stage.EXTRA_SLOT_BASE, "no points for extras")


func test_fake_npc_shoves_hit_nobody() -> void:
	var mg := await _arena(4, {"park": false})
	mg.fake_shove_rate = 40.0
	var fakes := [0]
	var hits := [0]
	for x in stage.extras:
		x.shove_started.connect(func() -> void: fakes[0] += 1)
	for b: Player in players + stage.extras:
		b.got_hit.connect(func(_i: Vector3, _s: int) -> void: hits[0] += 1)
	await step(int(3.0 / physics_delta()))
	assert_true(int(fakes[0]) > 0, "NPCs fake-shoved (%d)" % fakes[0])
	assert_eq(hits[0], 0, "nobody got hit")
	assert_eq(mg.wrong_log.size() + mg.unmask_log.size(), 0, "no rule fired")


func test_last_unfound_wins() -> void:
	var mg := await _arena(3, {"tags": true})
	_put(players[0], Vector3(0.0, 0.0, 0.0))
	_put(players[1], Vector3(1.0, 0.0, 0.0))
	await _shove(players[0])
	await step(int(1.3 / physics_delta()))
	_put(players[0], Vector3(0.0, 0.0, -3.0))
	_put(players[2], Vector3(1.0, 0.0, -3.0))
	assert_false(mg.is_finished(), "not over with two unfound")
	await _shove(players[0])
	assert_true(mg.is_finished(), "over: one unfound left")
	assert_eq(ranking, [0, 2, 1] as Array[int], "winner, then last unmasked first")
	assert_eq(mg.finish_groups, [[0], [2], [1]], "no ties")
	assert_eq(mg.finish_grace, 2.0, "2 s end grace")
	# Released: the winner shows their own look (and tag) again; extras stay masked.
	await step(2)
	var fp := MasqDisguise.fingerprint(players[0])
	assert_eq(fp["colours"], _real_key(players[0]), "winner's own colours")
	assert_false(bool(fp["mask"]), "winner unmasked")
	assert_true(bool(fp["tag"]), "winner's name tag back")
	assert_true(bool(MasqDisguise.fingerprint(stage.extras[0])["mask"]), "extras stay masked")
	await step(int((mg.reveal_hold + 0.1) / physics_delta()))
	assert_false(players[2].alive, "the last unmasked still leaves after the reveal")
	assert_true(mg.over, "round over on this peer")


func test_time_out_ranks_survivors_by_points_with_ties() -> void:
	var mg := await _arena(4, {"big": 1})
	_put(players[0], Vector3(0.0, 0.0, 0.0))
	_put(players[3], Vector3(1.0, 0.0, 0.0))
	await _shove(players[0])
	assert_false(mg.is_finished(), "three unfound")
	mg.time_limit = mg.elapsed + 0.2
	await step(int(0.4 / physics_delta()))
	assert_true(mg.is_finished(), "time-out")
	assert_eq(mg.finish_groups, [[0], [1, 2], [3]], "survivors by points (tied), then the unmasked")
	await step(5)
	for p in [players[0], players[1], players[2]]:
		var fp := MasqDisguise.fingerprint(p)
		assert_eq(fp["colours"], _real_key(p), "P%d own colours after the time-out" % p.slot)
		assert_false(bool(fp["mask"]), "P%d mask off" % p.slot)
	assert_near((players[1].get_component(&"visuals") as Node3D).scale.x, 1.22, 0.01, "big blob big again")


func test_stage_clear_releases_the_disguise() -> void:
	var mg := await _arena(3, {"tags": true})
	await step(2)
	assert_eq(MasqDisguise.fingerprint(players[1])["colours"], _look_key(), "disguised")
	# The minigame leaves the tree (stage cleared / next load) while the players still exist.
	stage.remove_child(mg)
	await step(2)
	for p in players:
		var fp := MasqDisguise.fingerprint(p)
		assert_eq(fp["colours"], _real_key(p), "P%d own colours" % p.slot)
		assert_false(bool(fp["mask"]), "P%d mask off" % p.slot)
		assert_true(bool(fp["tag"]), "P%d tag back" % p.slot)
	mg.queue_free()
	stage.minigame = null


func test_leavers_are_knocked_out_and_the_last_one_wins() -> void:
	var mg := await _arena(3, {"tags": true})
	Net.remove_bot(2)
	await step(2)
	assert_false(mg.is_finished(), "two left")
	assert_eq(mg.players.size(), 2, "leaver removed")
	Net.remove_bot(1)
	await step(2)
	assert_true(mg.is_finished(), "one left: finished")
	assert_eq(ranking[0], 0, "the one who stayed wins")
	await step(2)
	assert_eq(MasqDisguise.fingerprint(players[0])["colours"], _real_key(players[0]), "winner restored")


func test_you_ring_only_for_the_local_player_and_brief() -> void:
	var mg := await _arena(3)
	var ring := mg.get_node_or_null(^"YouRing") as Node3D
	assert_true(ring != null, "ring for the local human")
	await step(3)
	assert_near(Vector2(ring.global_position.x, ring.global_position.z),
		Vector2(players[0].global_position.x, players[0].global_position.z), 0.01, "under the local player")
	await step(int((mg.you_ring_time + 0.2) / physics_delta()))
	assert_true(mg.get_node_or_null(^"YouRing") == null, "gone after the first seconds")


func test_bot_goal_and_safety() -> void:
	var mg := await _arena(2)
	assert_true(mg.is_safe(Vector3(0.0, 0.0, 0.0)), "middle is safe")
	assert_false(mg.is_safe(Vector3(9.5, 0.0, 0.0)), "the wall is not")
	assert_false(mg.is_safe(Vector3(0.0, 0.0, -7.5)), "the back is not")
	for i in 20:
		assert_true(mg.is_safe(mg.get_bot_goal(players[1])), "goal %d on the floor" % i)


func test_a_driven_bot_leaving_mid_round_is_fine() -> void:
	var mg := await _arena(4, {"bots": true, "park": false})
	await step(60)
	Net.remove_bot(3)
	await step(120)
	assert_eq(mg.players.size(), 3, "leaver removed")
	assert_eq(mg.knocked_out, [3], "leaver knocked out")
	assert_false(mg.is_finished(), "three still play")
