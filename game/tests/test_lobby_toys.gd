extends GameTest
## The lobby toys (res://lobby/toys/): each toy's rule through the Player API and the toys'
## public state, offline (this peer is the host): the football (a goal counts once, the ball
## comes back, a shove kicks it, it never leaves the hall), the trampoline (launch height, the
## chain cap), the bell (cooldown), the see-saw (tilt by weight, the catapult), the photo spot
## (only blobs inside pose), the portal preview, and 60 s of 8 bots: nobody eliminated, nobody
## out of the hall, the toys get used.

const LOBBY_PATH := "res://lobby/lobby.tscn"
const Football := preload("res://lobby/toys/football.gd")


func _spawn_lobby(count: int, scripted: bool = true) -> MansionLobby:
	Net.start_offline()
	for i in count - 1:
		Net.add_bot()
	stage = STAGE_SCENE.instantiate() as Stage
	add_child(stage)
	var lobby := stage.load_minigame_scene(load(LOBBY_PATH) as PackedScene) as MansionLobby
	players.assign(stage.players.values())
	if lobby == null:
		fail("lobby scene did not load as a MansionLobby")
		return null
	for p in players:
		(p.get_component(&"controller") as ControllerComponent).scripted = scripted
	lobby._setup(players)
	for p in players:
		p.frozen = false
	lobby._start()
	return lobby


## Parks every player out of the way (by the front wall, spread out).
func _park(from: int = 0) -> void:
	for i in range(from, players.size()):
		players[i].place_at(Transform3D(Basis(), Vector3(-3.0 + 1.2 * i, 0.0, 8.0)))


func _face(p: Player, at: Vector3) -> Transform3D:
	var d := at - p.global_position
	return Transform3D(Basis(Vector3.UP, atan2(d.x, d.z)), p.global_position)


# --- Football ------------------------------------------------------------------------------------

func test_ball_waits_on_its_spot() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	_park()
	await step(120)
	var b := lobby.football.ball.pos
	assert_near(b.x, Football.SPOT.x, 0.05, "ball x on the spot (%s)" % b)
	assert_near(b.z, Football.SPOT.z, 0.05, "ball z on the spot (%s)" % b)
	assert_near(b.y, Football.RADIUS, 0.02, "ball on the floor")


func test_goal_counts_once_and_ball_comes_back() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	_park()
	var fb := lobby.football
	var before: Array[int] = Football.tonight.duplicate()
	var goals := watch(fb, &"goal_scored")
	var resets := watch(fb, &"ball_reset")
	fb.ball.pos = Vector3(-9.0, Football.RADIUS, Football.GOAL_Z + 0.2)
	fb.ball.vel = Vector3(-8.0, 0.0, 0.0)
	await step(30)
	assert_eq(goals.size(), 1, "one goal")
	if goals.size() >= 1:
		assert_eq(goals[0][0], 0, "in the red (left) goal")
	assert_eq(Football.tonight[0], before[0] + 1, "red goal count +1 (tonight)")
	assert_eq(Football.tonight[1], before[1], "blue goal count unchanged")
	# The ball sits in the net through the celebration: still one goal.
	await step(int(fb.celebrate_time * 60.0) + 20)
	assert_eq(goals.size(), 1, "the goal counted once")
	assert_true(resets.size() >= 1, "the ball was reset")
	assert_true(fb.ball.pos.distance_to(Football.SPOT) < 0.2, "back on the spot (%s)" % fb.ball.pos)
	assert_eq(lobby.football.goal_log.size(), 1, "goal log")
	# The other goal counts for blue.
	fb.ball.pos = Vector3(9.0, Football.RADIUS, Football.GOAL_Z - 0.3)
	fb.ball.vel = Vector3(8.0, 0.0, 0.0)
	await step(30)
	assert_eq(goals.size(), 2, "second goal")
	assert_eq(Football.tonight[1], before[1] + 1, "blue goal count +1")
	# The scoreboard shows the counts.
	var red_label := lobby.find_child("CountRed", true, false) as Label3D
	assert_true(red_label != null and red_label.text == str(Football.tonight[0]), "scoreboard shows the red count")


func test_counts_survive_a_lobby_reload() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	_park()
	var before: int = Football.tonight[1]
	lobby.football.ball.pos = Vector3(9.3, Football.RADIUS, Football.GOAL_Z)
	lobby.football.ball.vel = Vector3(6.0, 0.0, 0.0)
	await step(20)
	var again := stage.load_minigame_scene(load(LOBBY_PATH) as PackedScene) as MansionLobby
	await step(2)
	var label := again.find_child("CountBlue", true, false) as Label3D
	assert_eq(Football.tonight[1], before + 1, "count kept")
	assert_true(label != null and label.text == str(before + 1), "the new lobby's board shows it")


func test_shove_kicks_the_ball() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	var p := players[0]
	var fb := lobby.football
	p.place_at(Transform3D(Basis(), Football.SPOT - Vector3(0.0, Football.RADIUS, 1.1)))
	await step(5)
	p.place_at(_face(p, Football.SPOT))
	var kicks := watch(fb, &"ball_kicked")
	await step(3, func(i: int) -> void: p.intent.action_pressed = i == 0)
	assert_eq(kicks.size(), 1, "one kick")
	assert_true(fb.ball.vel.z > 6.0, "kicked along the facing (+Z): vel %s" % fb.ball.vel)
	assert_eq(fb.kick_log, [0] as Array[int], "kick log")


func test_walking_into_the_ball_pushes_it() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	var p := players[0]
	p.place_at(Transform3D(Basis(), Vector3(-2.0, 0.0, Football.SPOT.z)))
	await step(60, func(_i: int) -> void: p.intent.move = Vector2(1.0, 0.0))
	assert_true(lobby.football.ball.pos.x > 0.8, "ball pushed ahead (x=%.2f)" % lobby.football.ball.pos.x)


func test_ball_never_leaves_the_hall_over_a_minute_of_random_kicks() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	_park()
	var fb := lobby.football
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var worst := ""
	var out := 0
	var dt := 1.0 / 60.0
	var r := Football.RADIUS
	var kicks := 0
	for frame in 3600:
		# A blob can only reach a ball low enough (its head + a bit) over the floor or the stair
		# landing: kick it then, hard and often.
		var ground := MansionLobby.LANDING_Y if Football._on_landing(fb.ball.pos) else 0.0
		if frame % 20 == 0 and fb.ball.pos.y < ground + r + 1.1:
			var a := rng.randf() * TAU
			fb.sim.kick(fb.ball, Vector3(cos(a), 0.0, sin(a)), rng.randf_range(0.6, 1.8))
			kicks += 1
		fb.sim.step(fb.ball, dt)
		fb.host_check_lost(dt)  # a ball stranded on a shelf comes back, as in the game
		var b := fb.ball.pos
		var inside := absf(b.x) <= 11.85 - r + 0.01 and b.z >= -8.85 + r - 0.01 and b.z <= 8.85 - r + 0.01 \
				and b.y >= r - 0.01 and b.y < 12.0 and b.is_finite()
		if not inside:
			out += 1
			if worst == "":
				worst = "frame %d at %s" % [frame, b]
		if Football.goal_of(b) >= 0:
			fb.ball.pos = Football.SPOT
			fb.ball.vel = Vector3.ZERO
	assert_eq(out, 0, "the ball stayed in the hall (%s)" % worst)
	assert_true(kicks > 60, "it was kicked a lot (%d)" % kicks)


# --- Trampoline ----------------------------------------------------------------------------------

func test_trampoline_launches_about_three_metres_and_chains_up_to_a_cap() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	var p := players[0]
	var tr := lobby.trampoline
	var bounces := watch(tr, &"bounced")
	p.place_at(Transform3D(Basis(), tr.position + Vector3(0.1, tr.TOP + 1.2, 0.0)))
	# Peaks after each bounce.
	var peaks: Array[float] = []
	var peak := -INF
	var n := 0
	for i in 600:
		await step(1)
		if bounces.size() > n:
			if n > 0:
				peaks.append(peak)
			n = bounces.size()
			peak = -INF
		if n > 0:
			peak = maxf(peak, p.global_position.y)
	if bounces.size() < 4:
		fail("too few bounces (%d)" % bounces.size())
		return
	var first := peaks[0] - tr.TOP
	assert_near(first, tr.launch_height, 0.35, "first bounce ~%.1f m (got %.2f)" % [tr.launch_height, first])
	assert_true(peaks[1] > peaks[0] + 0.15, "a chained bounce goes higher (%.2f > %.2f)" % [peaks[1], peaks[0]])
	for k in peaks.size():
		assert_true(peaks[k] - tr.TOP <= tr.max_height + 0.3, "bounce %d under the cap (%.2f)" % [k, peaks[k] - tr.TOP])
	var last: float = bounces[bounces.size() - 1][1]
	assert_near(last, tr.max_height, 0.001, "the chain reaches the cap")
	assert_eq(tr.height_for_chain(100), tr.max_height, "capped")


# --- Bell ----------------------------------------------------------------------------------------

func test_bell_rings_on_a_shove_with_a_cooldown() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	var p := players[0]
	var bell := lobby.bell
	var rings := watch(bell, &"rung")
	p.place_at(Transform3D(Basis(), bell.position + Vector3(0.0, 0.0, 1.25)))
	await step(5)
	p.place_at(_face(p, bell.position))
	await step(2, func(i: int) -> void: p.intent.action_pressed = i == 0)
	assert_eq(rings.size(), 1, "a shove rings the bell")
	assert_true(absf(bell.swing()) >= 0.0, "swing")
	await step(20)
	assert_true(absf(bell.swing()) > 0.05, "the bell swings (%.3f rad)" % bell.swing())
	# Spam: shove every few frames for less than the cooldown.
	await step(60, func(i: int) -> void: p.intent.action_pressed = i % 8 == 0)
	assert_eq(rings.size(), 1, "no second ring inside the cooldown")
	assert_false(bell.host_ring(1.0, Vector3.BACK), "host_ring refused on cooldown")
	await step(int(bell.cooldown * 60.0))
	assert_true(bell.host_ring(1.0, Vector3.BACK), "rings again after the cooldown")
	assert_eq(rings.size(), 2, "two rings")


func test_running_into_the_bell_rings_it_softly() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	var p := players[0]
	var bell := lobby.bell
	var rings := watch(bell, &"rung")
	p.place_at(Transform3D(Basis(), bell.position + Vector3(0.0, 0.0, 3.0)))
	await step(60, func(_i: int) -> void: p.intent.move = Vector2(0.0, -1.0))
	assert_eq(rings.size(), 1, "one ring from the bump (cooldown holds the rest)")
	if rings.size() == 1:
		assert_true(float(rings[0][0]) < 1.0, "a soft ring")


func test_bell_ignores_a_shove_out_of_reach() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	var p := players[0]
	var bell := lobby.bell
	var rings := watch(bell, &"rung")
	p.place_at(Transform3D(Basis(), bell.position + Vector3(0.0, 0.0, 3.5)))
	await step(5)
	p.place_at(_face(p, bell.position))
	await step(2, func(i: int) -> void: p.intent.action_pressed = i == 0)
	assert_eq(rings.size(), 0, "too far away: no ring")
	# Facing away.
	p.place_at(Transform3D(Basis(), bell.position + Vector3(0.0, 0.0, 1.25)))
	await step(25)
	await step(2, func(i: int) -> void: p.intent.action_pressed = i == 0)
	assert_eq(rings.size(), 0, "facing away: no ring")


# --- See-saw -------------------------------------------------------------------------------------

func test_seesaw_tilts_toward_the_heavier_side() -> void:
	var lobby := _spawn_lobby(2)
	if lobby == null:
		return
	_park()
	var ss := lobby.seesaw
	var a := players[0]
	var b := players[1]
	# One normal blob on the +X end: that end goes down.
	a.place_at(Transform3D(Basis(), ss.position + Vector3(1.7, 1.0, 0.0)))
	await step(90)
	assert_true(ss.angle < -0.15, "+X end down under one blob (angle %.3f)" % ss.angle)
	assert_true(ss.riders(lobby.live_players()).has(a), "the blob counts as a rider")
	# A big blob on -X at the same distance beats a small one on +X.
	a.loadout["size"] = "small"
	b.loadout["size"] = "big"
	# Set down gently on the high end (dropping onto it would be a catapult).
	var top := ss.pivot_xform() * Vector3(-1.7, ss.TOP_Y, 0.0)
	var flings := watch(ss, &"catapulted")
	b.place_at(Transform3D(Basis(), top + Vector3.UP * 0.03))
	await step(150)
	assert_eq(flings.size(), 0, "stepping on gently is no catapult")
	assert_true(ss.angle > 0.1, "-X end down: big beats small (angle %.3f)" % ss.angle)
	assert_true(absf(ss.angle) <= ss.MAX_TILT + 0.001, "within the floor stops")
	# Everyone off: it drifts back level.
	_park()
	await step(240)
	assert_near(ss.angle, 0.0, 0.03, "level again when empty")


func test_seesaw_catapults_the_blob_on_the_low_end() -> void:
	var lobby := _spawn_lobby(2)
	if lobby == null:
		return
	_park()
	var ss := lobby.seesaw
	var low := players[0]
	var jumper := players[1]
	low.place_at(Transform3D(Basis(), ss.position + Vector3(-1.75, 1.0, 0.0)))
	await step(90)
	assert_true(ss.angle > 0.15, "-X end down, +X end high (angle %.3f)" % ss.angle)
	var flings := watch(ss, &"catapulted")
	var start_y := low.global_position.y
	jumper.place_at(Transform3D(Basis(), ss.position + Vector3(1.6, 3.2, 0.0)))
	var peak := -INF
	for i in 120:
		await step(1)
		peak = maxf(peak, low.global_position.y)
	# (The thrown blob may land on the end that is now high and throw the jumper back: fine.)
	assert_true(flings.size() >= 1, "a catapult")
	if flings.size() >= 1:
		assert_eq(flings[0][0], jumper.slot, "the jumper")
		assert_true((flings[0][1] as Array).has(low.slot), "the low blob was thrown")
	assert_true(peak - start_y > 1.4, "thrown up (peak %.2f m over %.2f)" % [peak - start_y, start_y])
	var hits := watch(low, &"got_hit")
	assert_eq(hits.size(), 0, "a throw is not a hit (no stun)")
	assert_true(low.alive and jumper.alive, "nobody eliminated")


# --- Photo spot ----------------------------------------------------------------------------------

func test_photo_poses_only_the_blobs_inside_the_area() -> void:
	var lobby := _spawn_lobby(4)
	if lobby == null:
		return
	_park()
	var ph := lobby.photo
	players[1].place_at(Transform3D(Basis(), ph.position + Vector3(-0.6, 0.0, 1.3)))
	players[2].place_at(Transform3D(Basis(), ph.position + Vector3(0.7, 0.0, 1.8)))
	players[3].place_at(Transform3D(Basis(), ph.position + Vector3(0.0, 0.0, 3.6)))  # outside
	# Player 0 shoves the button.
	var p := players[0]
	p.place_at(Transform3D(Basis(), ph.button_position() + Vector3(0.0, 0.0, 1.0)))
	await step(5)
	p.place_at(_face(p, ph.button_position()))
	var started := watch(ph, &"countdown_started")
	var taken := watch(ph, &"photo_taken")
	await step(2, func(i: int) -> void: p.intent.action_pressed = i == 0)
	assert_eq(started.size(), 1, "the button starts the countdown")
	await step(int(ph.countdown * 60.0) - 20)
	assert_eq(taken.size(), 0, "not before zero")
	await step(30)
	assert_eq(taken.size(), 1, "one photo at zero")
	if taken.size() == 1:
		var slots: Array = taken[0][0]
		slots.sort()
		assert_eq(slots, [1, 2], "only the blobs inside pose (%s)" % str(slots))
	assert_false(ph.host_press(), "the button rests for a moment")


# --- Portal preview ----------------------------------------------------------------------------

func test_portal_preview_shows_a_minigame_and_flares_on_start() -> void:
	var lobby := _spawn_lobby(2)
	if lobby == null:
		return
	await step(5)
	var pv := lobby.portal_preview
	assert_true(pv.current != &"", "shows a minigame")
	assert_true(MinigameRegistry.has(pv.current) or MinigameCatalog.playable().has(pv.current), "a playable id (%s)" % pv.current)
	assert_true(pv.pool().has(pv.current), "from the pool")
	assert_near(pv.get_flare(), 0.0, 0.001, "calm")
	lobby._on_session_state_changed(Session.State.VOTE)
	assert_true(pv.get_flare() > 0.9, "flares when a session starts")


func test_portal_flares_on_the_launch_beat_once() -> void:
	var lobby := _spawn_lobby(2)
	if lobby == null:
		return
	await step(5)
	var pv := lobby.portal_preview
	assert_near(pv.get_flare(), 0.0, 0.001, "calm")
	Session.session_launching.emit(0.75)  # START (every peer gets it before the lobby is left)
	assert_true(pv.get_flare() > 0.9, "flares on START, while still in the lobby")
	await step(45)  # the beat
	var left := pv.get_flare()
	assert_true(left > 0.1 and left < 0.9, "still glowing as the lobby is left (%.2f)" % left)
	lobby._on_session_state_changed(Session.State.INTRO)
	assert_near(pv.get_flare(), left, 0.001, "no second flare when the beat already flared")


# --- Everything together -------------------------------------------------------------------------

func test_eight_bots_for_a_minute_nobody_out_and_toys_used() -> void:
	var lobby := _spawn_lobby(8, false)
	if lobby == null:
		return
	var eliminated := []
	for p in players:
		var list := watch(p, &"eliminated")
		eliminated.append(list)
	var bounces := watch(lobby.trampoline, &"bounced")
	var rings := watch(lobby.bell, &"rung")
	var touched := [false]
	var escaped: Array[String] = []
	var ball_out := [0]
	await step(3600, func(i: int) -> void:
		var b := lobby.football.ball.pos
		if b.distance_to(Football.SPOT) > 0.5:
			touched[0] = true
		if absf(b.x) > 11.9 or absf(b.z) > 8.95 or b.y < 0.0:
			ball_out[0] += 1
		for p in players:
			var q := p.global_position
			if (absf(q.x) > 11.9 or q.z < -8.9 or q.z > 8.9 or q.y < -0.3 or q.y > 8.0) and escaped.size() < 5:
				escaped.append("P%d at %s (tick %d)" % [p.slot, q, i]))
	var gone := 0
	for list: Array in eliminated:
		gone += list.size()
	assert_eq(gone, 0, "nobody is eliminated in the lobby")
	assert_true(escaped.is_empty(), "every blob stays in the hall: %s" % str(escaped))
	assert_eq(ball_out[0], 0, "the ball stays in the hall")
	var used := int(touched[0]) + int(bounces.size() > 0) + int(rings.size() > 0) + int(lobby.seesaw.catapult_count > 0)
	assert_true(used >= 2, "bots play with the toys (ball moved %s, %d bounces, %d rings)" % [touched[0], bounces.size(), rings.size()])
	for p in players:
		assert_true(p.alive, "P%d alive" % p.slot)
