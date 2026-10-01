extends GameTest
## Game feel (`Feel` autoload, FeelTime, hit-stop in the visuals, camera intro sweep):
## every hook fires on its own signal without errors, the clocks always come back to 1.0,
## transitions finish and never take input, and nothing leaks from one round to the next.

const CAMERA_SCENE: PackedScene = preload("res://camera/arena_camera.tscn")

var _feel: Node
var _cam: ArenaCamera = null
var _saved_reduced_motion: bool = false


func before_each() -> void:
	_feel = get_node(^"/root/Feel")
	_saved_reduced_motion = get_node(^"/root/Settings").get(&"reduced_motion")
	_reset_session()


func after_each() -> void:
	get_node(^"/root/Settings").set(&"reduced_motion", _saved_reduced_motion)
	_feel.call(&"reset_moment")
	_feel.call(&"open_curtain", false)
	_feel.set(&"curtain", 0.0)
	Session.set_physics_process(true)
	_reset_session()


func _reset_session() -> void:
	Session.state = Session.State.LOBBY
	Session.round_index = -1
	Session.round_count = 0
	Session.phase_duration = 0.0
	Session.phase_time_left = 0.0
	Session.time_scale = 1.0
	Session.current_minigame = null


func _seconds(s: float) -> int:
	return ceili(s * 60.0)


func _vis(p: Player) -> VisualsComponent:
	return p.get_component(&"visuals") as VisualsComponent


## An arena with an ArenaCamera in the minigame (where Feel looks for it), made current.
func _arena_with_camera(count: int) -> Array[Player]:
	var ps := spawn_arena(count)
	_cam = CAMERA_SCENE.instantiate() as ArenaCamera
	stage.minigame.add_child(_cam)
	_cam.make_current()
	return ps


func _assert_clocks_normal(context: String) -> void:
	assert_eq(Engine.time_scale, 1.0, "%s: Engine.time_scale untouched" % context)
	assert_eq(FeelTime.scale, 1.0, "%s: visual time back to 1" % context)


# --- Hit feel ------------------------------------------------------------------------------

func test_hit_stop_freezes_the_model_not_the_body() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var vis := _vis(p)
	await step(10)
	var pivot := vis.get_node(^"Pivot") as Node3D
	var body_before := p.global_position
	p.apply_impulse(Vector3(16.0, 0.0, 0.0), ps[1])
	await step(1)
	assert_true(vis.get_hit_stop() > 0.0, "victim in hit-stop")
	assert_true(vis.get_hit_stop() <= VisualsComponent.HIT_STOP, "hit-stop at most %.3f s" % VisualsComponent.HIT_STOP)
	var held := pivot.global_position
	await step(1)
	var flat := func(v: Vector3) -> Vector2: return Vector2(v.x, v.z)
	var body_gap: float = (flat.call(p.global_position) as Vector2).distance_to(flat.call(held))
	var model_gap: float = (flat.call(pivot.global_position) as Vector2).distance_to(flat.call(held))
	assert_true(p.global_position.distance_to(body_before) > 0.1, "the body keeps flying (physics untouched)")
	assert_true(model_gap < 0.11 and body_gap > model_gap + 0.1,
		"the model holds where it was hit, shivering (model %.3f, body %.3f from the hold)" % [model_gap, body_gap])
	await step(5)
	assert_eq(vis.get_hit_stop(), 0.0, "hit-stop over within 0.1 s")
	await step(30)
	assert_true(pivot.position.length() < 0.01, "model caught up with the body (%s)" % pivot.position)
	_assert_clocks_normal("after a hit")


func test_attacker_freezes_on_shove_hit_and_hits_shake_the_camera() -> void:
	var ps := _arena_with_camera(2)
	await step(5)
	_cam.trauma = 0.0
	ps[1].emit_event(&"shove_hit", [0])
	await step(1)
	assert_true(_vis(ps[1]).get_hit_stop() > 0.0, "attacker hit-stop on shove_hit")
	ps[0].emit_event(&"got_hit", [Vector3(6, 0, 0), 1])
	assert_true(_cam.trauma > 0.15, "got_hit shakes (local player involved: %f)" % _cam.trauma)
	var after_hit := _cam.trauma
	ps[1].eliminate(&"fell")
	assert_true(_cam.trauma > after_hit, "an elimination shakes harder")
	await step(_seconds(1.0))
	assert_eq(_cam.trauma, 0.0, "shake decays")
	_assert_clocks_normal("after hits")


func test_elimination_flourish_poof_ring_and_tag() -> void:
	var ps := spawn_arena(2)
	var played := watch(Fx, &"played")
	ps[0].eliminate(&"lava")
	var names: Array = played.map(func(a: Array) -> StringName: return a[0])
	for n: StringName in [&"splash_lava", &"poof", &"shockwave", &"ko_tag"]:
		assert_true(names.has(n), "lava knockout plays %s (%s)" % [n, names])
	played.clear()
	ps[0].respawn_at(Transform3D(Basis.IDENTITY, Vector3(1, 0, 1)))
	names = played.map(func(a: Array) -> StringName: return a[0])
	assert_true(names.has(&"respawn_sparkle") and names.has(&"shockwave"), "respawn sparkle + ring (%s)" % [names])


func test_low_quality_skips_the_heavy_parts() -> void:
	var ps := spawn_arena(2)
	var was := Look.get_quality()
	Look.set_quality(Look.Quality.LOW)
	var played := watch(Fx, &"played")
	ps[0].eliminate(&"cannon")
	var names: Array = played.map(func(a: Array) -> StringName: return a[0])
	assert_false(names.has(&"shockwave") or names.has(&"explosion"), "no rings/explosions on LOW (%s)" % [names])
	assert_true(names.has(&"poof") and names.has(&"ko_tag"), "poof and OUT! stay readable on LOW")
	Session.round_finished.emit([1, 0] as Array[int], {})
	assert_false(_feel.call(&"is_spotlight_on"), "no spotlight on LOW")
	assert_eq(_feel.get(&"vignette"), 0.0, "no vignette on LOW")
	await step(_seconds(0.8))
	_assert_clocks_normal("LOW knockout")
	Look.set_quality(was)


# --- Round moments -------------------------------------------------------------------------

func test_knockout_slow_motion_then_confetti_and_clocks_return() -> void:
	var ps := _arena_with_camera(3)
	await step(3)
	ps[1].eliminate(&"fell")
	ps[2].eliminate(&"fell")
	var started := watch(_feel, &"knockout_started")
	var finished := watch(_feel, &"knockout_finished")
	var played := watch(Fx, &"played")
	Session.round_finished.emit([0, 2, 1] as Array[int], {0: 4, 2: 3, 1: 2})
	assert_eq(started.size(), 1, "knockout moment starts on round_finished")
	assert_true(_feel.call(&"is_slowmo"), "slow-motion running")
	assert_near(FeelTime.scale, 0.3, 0.001, "visual time slowed")
	assert_eq(Engine.time_scale, 1.0, "Engine.time_scale untouched (network safe)")
	assert_true(_cam.is_focusing(), "camera pushes in on the winner")
	assert_eq(_vis(ps[0]).get_emote(), &"cheer", "winner cheers")
	assert_true(_feel.call(&"is_spotlight_on"), "winner spotlight")
	await step(_seconds(0.3))
	assert_true(_feel.get(&"vignette") > 0.5, "vignette in")
	await step(_seconds(0.45))
	assert_eq(finished.size(), 1, "slow-motion ends after %.1f s" % 0.6)
	var names: Array = played.map(func(a: Array) -> StringName: return a[0])
	assert_true(names.has(&"confetti"), "confetti after the slow-motion (%s)" % [names])
	_assert_clocks_normal("after the knockout")
	await step(_seconds(2.0))
	assert_eq(_feel.get(&"vignette"), 0.0, "vignette gone")


func test_reduced_motion_skips_intro_sweep_and_knockout_slow_motion() -> void:
	var settings := get_node(^"/root/Settings")
	var was: bool = settings.get(&"reduced_motion")
	settings.set(&"reduced_motion", true)
	var ps := _arena_with_camera(3)
	await step(3)
	var intro := watch(_feel, &"intro_started")
	Session.round_intro.emit({"id": &"test", "title": "T", "rule_text": ""}, 0)
	assert_eq(intro.size(), 1, "intro hook still fires")
	assert_false(_cam.is_sweeping(), "reduced motion: no intro sweep")
	Session.round_started.emit()
	ps[1].eliminate(&"fell")
	ps[2].eliminate(&"fell")
	var started := watch(_feel, &"knockout_started")
	var finished := watch(_feel, &"knockout_finished")
	var played := watch(Fx, &"played")
	Session.round_finished.emit([0, 2, 1] as Array[int], {0: 4, 2: 3, 1: 2})
	assert_eq(started.size(), 1, "knockout moment still starts")
	assert_false(_feel.call(&"is_slowmo"), "reduced motion: no slow-motion")
	_assert_clocks_normal("reduced-motion knockout")
	assert_eq(finished.size(), 1, "moment ends at once")
	var names: Array = played.map(func(a: Array) -> StringName: return a[0])
	assert_true(names.has(&"confetti"), "confetti still plays (%s)" % [names])
	await step(_seconds(0.3))
	assert_eq(_feel.get(&"vignette"), 0.0, "reduced motion: no vignette push")
	settings.set(&"reduced_motion", was)


func test_round_end_without_knockout_only_celebrates() -> void:
	var ps := _arena_with_camera(3)
	var started := watch(_feel, &"knockout_started")
	var celebrated := watch(_feel, &"winner_celebrated")
	Session.round_finished.emit([2, 0, 1] as Array[int], {})
	assert_eq(started.size(), 0, "several still standing: no slow-motion")
	assert_eq(celebrated.size(), 1, "winner celebrated")
	assert_eq(celebrated[0][0], 2, "the ranking's first")
	assert_eq(_vis(ps[2]).get_emote(), &"cheer", "winner cheers")
	_assert_clocks_normal("no knockout")


func test_next_round_mid_slow_motion_leaks_nothing() -> void:
	var ps := _arena_with_camera(2)
	ps[1].eliminate(&"fell")
	Session.round_finished.emit([0, 1] as Array[int], {})
	await step(2)
	assert_true(_feel.call(&"is_slowmo"), "slow-motion running")
	Session.round_intro.emit({"id": &"test", "title": "T", "rule_text": ""}, 1)
	_assert_clocks_normal("round_intro during slow-motion")
	assert_false(_feel.call(&"is_slowmo"), "slow-motion cut")
	assert_false(_feel.call(&"is_spotlight_on"), "spotlight off")
	assert_eq(_feel.get(&"vignette"), 0.0, "vignette off")
	Session.round_started.emit()
	Session.state_changed.emit(Session.State.LOBBY)
	await step(_seconds(0.6))
	assert_eq(_feel.get(&"letterbox"), 0.0, "letterbox gone in the lobby")
	assert_false(_feel.call(&"is_transitioning"), "curtain open")
	_assert_clocks_normal("lobby")


func test_intro_sweeps_the_camera_letterboxes_and_lifts_at_go() -> void:
	var ps := _arena_with_camera(4)
	await step(2)
	_cam.update_camera(0.0)
	var settled := _cam.global_transform
	var intro := watch(_feel, &"intro_started")
	Session.round_intro.emit({"id": &"test", "title": "T", "rule_text": ""}, 0)
	assert_eq(intro.size(), 1, "intro hook fired")
	assert_true(_cam.is_sweeping(), "camera sweeping")
	assert_eq(_feel.get(&"letterbox"), 1.0, "letterbox in")
	await step(1)
	var start := _cam.global_transform
	assert_true(start.origin.y > settled.origin.y + 3.0, "starts high (%.1f vs %.1f)" % [start.origin.y, settled.origin.y])
	assert_true(start.origin.distance_to(settled.origin) > 5.0, "starts wide/orbited")
	assert_eq(_cam.view_basis(), settled.basis, "the controls' basis never changes")
	await step(_seconds(1.25))
	var mid := _cam.global_transform.origin
	assert_true(mid.distance_to(settled.origin) < start.origin.distance_to(settled.origin), "flying in")
	await step(_seconds(1.4))
	assert_false(_cam.is_sweeping(), "sweep done after 2.5 s")
	assert_true(_cam.global_transform.basis.is_equal_approx(settled.basis), "settled on the arena framing")
	assert_eq(_feel.get(&"letterbox"), 1.0, "letterbox holds until GO")
	Session.round_started.emit()
	await step(_seconds(0.5))
	assert_eq(_feel.get(&"letterbox"), 0.0, "letterbox lifted at GO")
	assert_false(_feel.call(&"is_transitioning"), "curtain open")


func test_go_ends_a_sweep_early() -> void:
	_arena_with_camera(2)
	Session.round_intro.emit({"id": &"test", "title": "T", "rule_text": ""}, 0)
	await step(5)
	assert_true(_cam.is_sweeping(), "sweeping")
	Session.round_started.emit()
	assert_false(_cam.is_sweeping(), "GO stops the sweep at once")
	assert_true(_cam.global_transform.basis.is_equal_approx(_cam.view_basis()), "real basis for play")


# --- Transitions ---------------------------------------------------------------------------

func test_curtain_opens_on_every_stage_load_and_never_blocks_input() -> void:
	assert_false(_feel.call(&"blocks_input"), "overlay ignores the mouse")
	var changed := watch(_feel, &"transition_changed")
	var done := watch(_feel, &"transition_finished")
	Session.round_intro.emit({"id": &"test", "title": "T", "rule_text": ""}, 0)
	assert_eq(_feel.get(&"curtain"), 1.0, "covers the load")
	assert_eq(changed.size(), 1, "transition started")
	await step(_seconds(0.2))
	var mid: float = _feel.get(&"curtain")
	assert_true(mid > 0.0 and mid < 1.0, "mid-wipe (%f)" % mid)
	assert_false(_feel.call(&"blocks_input"), "never blocks input, even mid-wipe")
	await step(_seconds(0.25))
	assert_eq(_feel.get(&"curtain"), 0.0, "open within 0.4 s")
	assert_eq(done.size(), 1, "transition finished")
	assert_false(_feel.call(&"is_transitioning"), "released")
	Session.state_changed.emit(Session.State.LOBBY)
	assert_true(_feel.call(&"is_transitioning"), "lobby load wipes too")
	await step(_seconds(0.45))
	assert_false(_feel.call(&"is_transitioning"), "and finishes")


func test_curtain_closes_before_the_next_round_and_a_lost_load_reopens() -> void:
	Session.set_physics_process(false)  # hold Session's own clock: this test drives the phase
	Session.state = Session.State.RESULTS
	Session.round_index = 0
	Session.round_count = 2
	Session.phase_duration = 7.0
	Session.phase_time_left = 1.0
	await step(3)
	assert_eq(_feel.get(&"curtain"), 0.0, "open while results show")
	Session.phase_time_left = 0.3
	await step(1)
	assert_true(_feel.call(&"is_transitioning"), "closes in the last 0.35 s")
	await step(_seconds(0.4))
	assert_eq(_feel.get(&"curtain"), 1.0, "closed when the phase ends")
	assert_false(_feel.call(&"blocks_input"), "closed but input still passes")
	# The next round never arrives (lost RPC, dropped host): the failsafe opens it.
	await step(_seconds(1.1))
	assert_eq(_feel.get(&"curtain"), 0.0, "failsafe opened the curtain")
	# The last round's results lead to the podium, not a load: no curtain.
	Session.round_index = 1
	Session.phase_time_left = 0.3
	await step(_seconds(0.4))
	assert_eq(_feel.get(&"curtain"), 0.0, "no curtain before the podium")
