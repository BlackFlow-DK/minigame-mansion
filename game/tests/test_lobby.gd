extends GameTest
## The lobby hall (res://lobby/lobby.tscn) through Stage, like Session will load it:
## it loads with 8 spawns, never finishes, the stairs are walkable, a fallen player comes
## back, bots stay inside, and the toys react.

const LOBBY_PATH := "res://lobby/lobby.tscn"


## Like spawn_arena, for a scene that is not in the minigame registry.
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


func _inside_hall(pos: Vector3) -> bool:
	return absf(pos.x) < 11.9 and pos.z > -8.9 and pos.z < 8.9 and pos.y > -0.3 and pos.y < 6.0


func test_scene_loads_with_eight_spawns() -> void:
	var lobby := _spawn_lobby(8)
	if lobby == null:
		return
	assert_eq(lobby.title, "The Mansion")
	assert_eq(lobby.time_limit, 0.0, "no time limit")
	var points := lobby.get_spawn_points()
	assert_eq(points.size(), 8, "spawn markers")
	for t in points:
		assert_true(lobby.is_safe(t.origin), "spawn %s inside the hall" % t.origin)
		assert_near((t.basis * Vector3.MODEL_FRONT).z, 1.0, 0.01, "spawn faces the camera (+Z)")
	assert_eq(players.size(), 8)
	var cam := lobby.get_node_or_null(^"Camera") as ArenaCamera
	assert_true(cam != null and cam.mode == ArenaCamera.Mode.FRAME_ALL, "arena camera in FRAME_ALL")
	await step(45)
	for p in players:
		assert_true(p.is_on_floor(), "P%d stands on the floor" % p.slot)
		assert_near(p.global_position.y, 0.0, 0.05, "P%d floor height" % p.slot)
	var pendulum := lobby.find_child("Pendulum", true, false) as Node3D
	assert_true(pendulum != null, "the clock has a pendulum")
	var swing_before := pendulum.rotation.z if pendulum else 0.0
	await step(20)
	assert_true(pendulum != null and not is_equal_approx(pendulum.rotation.z, swing_before), "the pendulum swings")
	await step(120)
	assert_false(lobby.is_finished(), "the lobby never finishes")


func test_walking_at_the_stairs_reaches_the_landing() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	var p := players[0]
	p.place_at(Transform3D(Basis(), Vector3(0.5, 0.0, 0.5)))
	await step(10)
	var grounded := [0]
	await step(150, func(_i: int) -> void:
		p.intent.move = Vector2(0.0, -1.0)
		if p.is_on_floor():
			grounded[0] += 1)
	var pos := p.global_position
	assert_near(pos.y, MansionLobby.LANDING_Y, 0.15, "on the landing (y)")
	assert_true(pos.z < -7.0 and pos.z > -8.85, "on the landing (z=%.2f)" % pos.z)
	assert_true(grounded[0] > 135, "walked up without hopping (grounded %d/150 ticks)" % grounded[0])
	await step(30)
	assert_eq(lobby.get_portal_crowd(), 1, "the portal sees the player before it")
	assert_true(lobby.get_portal_heat() > 0.0, "the portal warms up")


func test_player_dropped_outside_is_returned() -> void:
	var lobby := _spawn_lobby(2)
	if lobby == null:
		return
	var p := players[1]
	var respawns := watch(p, &"respawned")
	var eliminations := watch(p, &"eliminated")
	p.place_at(Transform3D(Basis(), Vector3(30.0, 3.0, 0.0)))
	await step(240)
	assert_eq(respawns.size(), 1, "respawned once")
	assert_eq(eliminations.size(), 0, "nobody is eliminated in the lobby")
	assert_true(p.alive, "alive")
	assert_true(lobby.is_safe(p.global_position) and p.global_position.y > -0.1 and p.global_position.y < 0.5,
		"back on the floor at a spawn point (%s)" % p.global_position)


func test_bots_stay_inside_for_twenty_seconds() -> void:
	var lobby := _spawn_lobby(8, false)
	if lobby == null:
		return
	var start: Array[Vector3] = []
	for p in players:
		start.append(p.global_position)
	var escaped: Array[String] = []
	await step(1200, func(i: int) -> void:
		for p in players:
			if not _inside_hall(p.global_position) and escaped.size() < 5:
				escaped.append("P%d at %s (tick %d)" % [p.slot, p.global_position, i]))
	assert_true(escaped.is_empty(), "every player stays in the hall: %s" % str(escaped))
	var moved := 0
	for i in range(1, players.size()):
		if players[i].global_position.distance_to(start[i]) > 2.0:
			moved += 1
	assert_true(moved >= 4, "bots mill about (%d of 7 moved)" % moved)


func test_bot_goals_are_safe() -> void:
	var lobby := _spawn_lobby(2)
	if lobby == null:
		return
	var bot := players[1]
	var spots: Array[Vector3] = [Vector3(0, 0, 1), Vector3(-10, 0, 7), Vector3(10, 0, -3), Vector3(0.5, 2, -7.5)]
	for i in 200:
		bot.place_at(Transform3D(Basis(), spots[i % spots.size()]))
		var goal := lobby.get_bot_goal(bot)
		assert_true(lobby.is_safe(goal), "goal %s is safe" % goal)
	assert_false(lobby.is_safe(Vector3(0, 0, 12)), "outside the front is unsafe")
	assert_false(lobby.is_safe(Vector3(13, 0, 0)), "outside the side is unsafe")


func test_cushion_bounces_a_landing_blob() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	var p := players[0]
	var seat: Vector3 = lobby.get_cushion_tops()[0]
	var bounces := watch(lobby, &"cushion_bounced")
	var peak := await _peak_after_landing(p, seat + Vector3(0.0, 1.5, 0.0))
	assert_true(bounces.size() >= 1, "a cushion bounce happened")
	assert_true(peak > seat.y + 1.8, "bounced higher than it fell (peak %.2f, seat %.2f)" % [peak, seat.y])
	# Control: the plain floor does not bounce.
	var floor_peak := await _peak_after_landing(p, Vector3(0.0, 1.5, 3.0))
	assert_true(floor_peak < 0.2, "the floor does not bounce (peak %.2f)" % floor_peak)


func test_floor_keyboard_lights_the_key_under_a_blob() -> void:
	var lobby := _spawn_lobby(1)
	if lobby == null:
		return
	var p := players[0]
	var pressed := watch(lobby, &"piano_key_pressed")
	p.place_at(Transform3D(Basis(), lobby.get_key_position(2) + Vector3(0.0, 0.1, 0.0)))
	await step(20)
	assert_true(lobby.is_key_lit(2), "key 2 lights up")
	assert_false(lobby.is_key_lit(5), "key 5 stays dark")
	assert_eq(pressed.size(), 1, "one key press")
	assert_eq(pressed[0], [2], "key 2 pressed")


## Drops `p` from `from`, then returns the highest y it reaches after its first landing.
func _peak_after_landing(p: Player, from: Vector3) -> float:
	var landings := watch(p, &"landed")
	p.place_at(Transform3D(Basis(), from))
	var peak := -INF
	for i in 120:
		await step(1)
		if not landings.is_empty():
			peak = maxf(peak, p.global_position.y)
	return peak
