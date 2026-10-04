extends GameTest
## Animation pass (v0.3): the new visuals API is callable headless, motion and events start
## the right reactions, every reaction lets the model root settle back to identity, remote
## copies animate from replicated position/facing/events only, and nothing piles up nodes.


func after_each() -> void:
	Session.state = Session.State.LOBBY
	if stage:
		stage.follow_roster = false


func _vis(p: Player) -> VisualsComponent:
	return p.get_component(&"visuals") as VisualsComponent


func _at_rest(p: Player) -> bool:
	var b := _vis(p).get_model_root().transform.basis
	return (b.x - Vector3.RIGHT).length() < 0.002 and (b.y - Vector3.UP).length() < 0.002 \
		and (b.z - Vector3.BACK).length() < 0.002


## Hands outside the body ellipsoid (centre y 0.45, radii 0.41 / 0.55) by `margin` m, feet soles
## not under the floor, face parts at rest positions (pupils within range), sockets untouched.
func _pose_ok(p: Player, what: String) -> bool:
	var root := _vis(p).get_model_root()
	var ok := true
	for hand: String in ["HandL", "HandR"]:
		var h := (root.get_node(hand) as Node3D).position
		var dy := (h.y - VisualsComponent.BODY_CENTRE_Y) / VisualsComponent.BODY_RY
		if absf(dy) < 1.0:
			var r := VisualsComponent.BODY_RX * sqrt(1.0 - dy * dy)
			ok = assert_true(Vector2(h.x, h.z).length() >= r + 0.05, "%s: %s out of the body (%s)" % [what, hand, h]) and ok
	for foot: String in ["FootL", "FootR"]:
		var f := root.get_node(foot) as Node3D
		var sole := f.global_position.y - VisualsComponent.FOOT_HALF_HEIGHT * 0.8 * _vis(p).scale.y
		ok = assert_true(sole >= p.global_position.y - 0.03, "%s: %s above the floor (%f)" % [what, foot, sole - p.global_position.y]) and ok
	var sockets := {"HatSocket": Vector3(0, 1, 0), "FaceSocket": Vector3(0, 0.68, 0.37)}
	for s: String in sockets:
		ok = assert_near((root.get_node(s) as Node3D).position, sockets[s], 0.0001, "%s: %s stays put" % [what, s]) and ok
	for i in 2:
		var pupil := root.get_node(["PupilL", "PupilR"][i]) as Node3D
		var rest := _vis(p)._pupil_rest[i]
		ok = assert_true(Vector2(pupil.position.x - rest.x, pupil.position.y - rest.y).length() <= BlobRig.PUPIL_RANGE + 0.001
			and is_equal_approx(pupil.position.z, rest.z), "%s: pupil %d in range" % [what, i]) and ok
	return ok


func test_new_api_is_callable_headless() -> void:
	var p := spawn_arena(1)[0]
	var vis := _vis(p)
	await step(5)
	assert_eq(vis.play_result_pose(1, 8), &"victory", "1st: victory")
	assert_eq(vis.play_result_pose(2, 8), &"clap_nod", "2nd: clap and nod")
	assert_eq(vis.play_result_pose(3, 8), &"clap_nod", "3rd: clap and nod")
	assert_eq(vis.play_result_pose(5, 8), &"clap", "5th: polite clap")
	assert_eq(vis.play_result_pose(8, 8), &"sulk", "last: sulk")
	assert_eq(vis.play_result_pose(2, 2), &"sulk", "last of two: sulk")
	assert_eq(vis.play_result_pose(0, 8), &"", "place 0 stops")
	assert_eq(vis.get_emote(), &"", "stopped")
	for e: StringName in VisualsComponent.EMOTES:
		assert_true(vis.play_emote(e, true), "emote %s" % e)
		await step(20)
		assert_eq(vis.get_reaction(), &"emote", "%s shows" % e)
		assert_true(_pose_ok(p, String(e)), "%s pose" % e)
	vis.stop_emote()
	assert_false(vis.set_carry_pose(&"juggle"), "unknown carry refused")
	for kind: StringName in [&"overhead", &"front"]:
		assert_true(vis.set_carry_pose(kind), "carry %s" % kind)
		await step(30)
		assert_eq(vis.get_carry_pose(), kind, "carrying %s" % kind)
		var point := vis.get_carry_point()
		assert_true(point.is_finite() and point.y > p.global_position.y + 0.3, "carry point %s" % point)
		var hand := vis.get_model_root().get_node("HandL") as Node3D
		if kind == &"overhead":
			assert_true(hand.position.y > 1.1, "hands overhead (%f)" % hand.position.y)
		else:
			assert_true(hand.position.z > 0.35, "hands in front (%f)" % hand.position.z)
		assert_true(_pose_ok(p, "carry %s" % kind), "carry pose")
	vis.play_throw()
	assert_eq(vis.get_carry_pose(), &"none", "throw ends the carry")
	await step(3)
	assert_eq(vis.get_reaction(), &"throw", "throwing")
	await step(40)
	assert_eq(vis.get_action(), &"", "throw over")
	vis.set_interest_point(Vector3(5.0, 1.0, 0.0), 0.8)
	vis.set_interest_point(Vector3.INF)  # ignored
	vis.set_panic(1.0)
	assert_false(vis.play_fidget(&"juggle"), "unknown fidget refused")
	for fidget: StringName in VisualsComponent.FIDGETS:
		assert_true(vis.play_fidget(fidget), "fidget %s" % fidget)
		await step(int(VisualsComponent.ACTIONS[fidget] * 30.0))
		assert_eq(vis.get_reaction(), &"fidget", "%s plays" % fidget)
		assert_true(_pose_ok(p, String(fidget)), "%s pose" % fidget)
		await step(int(VisualsComponent.ACTIONS[fidget] * 35.0))
	await step(120)
	assert_true(_at_rest(p), "scale back to identity after the API tour")


## Run start, skid, banking, panic run, then air phases and a heavy two-stage landing.
func test_locomotion_and_air_reactions() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var vis := _vis(p)
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(-3.0, 0.0, 0.0)))
	await step(10)
	var seen := {}
	await step(50, func(_i: int) -> void:
		p.intent.move = Vector2(1.0, 0.0)
		seen[vis.get_reaction()] = true)
	assert_true(vis._since_start < 1.0, "run start kick happened")
	assert_true(seen.has(&"run"), "runs")
	await step(25, func(_i: int) -> void:
		p.intent.move = Vector2.ZERO
		seen[vis.get_reaction()] = true)
	assert_true(seen.has(&"skid"), "skids on a hard stop (saw %s)" % [seen.keys()])
	assert_true(_pose_ok(p, "after skid"), "skid pose")
	# Turning in a circle banks (lean toward the inside, arms out).
	var max_bank := [0.0]
	await step(60, func(i: int) -> void:
		var a := i * 0.08
		p.intent.move = Vector2(cos(a), -sin(a))
		max_bank[0] = maxf(max_bank[0], absf(vis._bank)))
	assert_true(max_bank[0] > 0.08, "banks in turns (%f)" % max_bank[0])
	# A knock, then running: panic arms.
	p.apply_impulse(Vector3(0.0, 1.0, 3.0), ps[1])
	await step(45)
	var panic := [false]
	await step(40, func(_i: int) -> void:
		p.intent.move = Vector2(-1.0, 0.0)
		panic[0] = panic[0] or vis.get_reaction() == &"panic")
	assert_true(panic[0], "panic run after a knock")
	p.intent.move = Vector2.ZERO
	p.place_at(Transform3D.IDENTITY)
	await step(60)
	# Air: tuck at the apex, reaching down on the way down.
	var tuck := [0.0]
	var reach := [0.0]
	var landed := watch(p, &"landed")
	for i in 120:
		await step(1, func(_j: int) -> void:
			p.intent.jump_pressed = i == 0
			p.intent.jump_held = true)
		tuck[0] = maxf(tuck[0], vis._tuck_w)
		reach[0] = maxf(reach[0], vis._reach_w)
		if landed.size() > 0:
			break
	assert_true(tuck[0] > 0.6, "tucks at the apex (%f)" % tuck[0])
	assert_true(reach[0] > 0.2, "reaches down on the way down (%f)" % reach[0])
	# Heavy landing from high up: two squash stages.
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(0.0, 5.0, 0.0)))
	landed.clear()
	for i in 120:
		await step(1)
		if landed.size() > 0:
			break
	assert_true(landed.size() > 0 and landed[0][0] > 9.0, "heavy landing")
	var minima: Array[float] = []
	var prev := [9.0, 9.0]
	for i in 30:
		await step(1)
		var y := vis.get_model_root().transform.basis.y.y
		if prev[1] > prev[0] and y > prev[0]:
			minima.append(prev[0])
		prev = [y, prev[0]]
	assert_true(minima.size() >= 2, "two squash stages (minima %s)" % [minima])
	vis._fidget_in = 999.0
	await step(120)
	assert_true(_at_rest(p), "scale back to identity after locomotion and landing")


func test_knockback_spin_and_social_reactions() -> void:
	var ps := spawn_arena(3)
	var a := ps[0]
	var b := ps[1]
	var c := ps[2]
	# One at a time (a body teleported from under another one carries it like a platform).
	b.place_at(Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(2.3, 0.0, 0.0)))
	c.place_at(Transform3D(Basis.IDENTITY, Vector3(-1.5, 0.0, 3.0)))
	await step(2)
	a.place_at(Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0.0, 0.0, 0.0)))
	await step(20)
	# b shoves at thin air toward a: a ducks.
	await step(4, func(i: int) -> void: b.intent.action_pressed = i == 0)
	assert_eq(_vis(a).get_reaction(), &"flinch", "a flinches at the whiff")
	assert_true(_pose_ok(a, "flinch"), "flinch pose")
	await step(60)
	# a shoves b (in reach now): a gloats afterwards.
	b.place_at(Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(1.05, 0.0, 0.0)))
	await step(10)
	var hits := watch(a, &"shove_hit")
	var gloat := [false]
	await step(50, func(i: int) -> void:
		a.intent.action_pressed = i == 0
		gloat[0] = gloat[0] or _vis(a).get_action() == &"gloat")
	assert_eq(hits.size(), 1, "shove landed")
	assert_true(gloat[0], "attacker gloats")
	await step(90)
	# A knockout nearby: the others wince.
	c.eliminate(&"test")
	await step(3)
	assert_eq(_vis(a).get_reaction(), &"wince", "a winces at the knockout nearby")
	await step(60)
	# Big knockback spins in the air (not with reduced motion).
	a.apply_impulse(Vector3(12.0, 6.0, 0.0))
	var spun := [false]
	await step(30, func(_i: int) -> void: spun[0] = spun[0] or _vis(a)._spin_t < VisualsComponent.SPIN_TIME)
	assert_true(spun[0], "spins on a big knockback")
	await step(200)
	assert_true(_at_rest(a) and _at_rest(b), "scale back to identity after the social round")


func test_idle_life_fidgets_sleep_and_reduced_motion() -> void:
	var p := spawn_arena(1)[0]
	var vis := _vis(p)
	stage.follow_roster = true  # the lobby hall
	var acts := {}
	await step(60 * 14, func(_i: int) -> void:
		if vis.get_action() != &"":
			acts[vis.get_action()] = true)
	assert_true(acts.size() >= 1, "fidgets on its own when idle (saw %s)" % [acts.keys()])
	await step(60 * 8)
	assert_eq(vis.get_reaction(), &"sleep", "nods off after %d s in the lobby" % int(VisualsComponent.SLEEP_AFTER))
	assert_eq(vis.get_expression(), &"sleepy", "sleepy face")
	var zzz := vis.find_child("Zzz", true, false) as Label3D
	assert_true(zzz != null and zzz.visible, "zzz shows")
	await step(20, func(_i: int) -> void: p.intent.move = Vector2(1.0, 0.0))
	await step(30)
	assert_true(vis.get_sleep() < 0.2, "wakes when moving (%f)" % vis.get_sleep())
	assert_false(zzz.visible, "zzz hidden")
	# Not in a game round.
	stage.follow_roster = false
	vis._idle_time = VisualsComponent.SLEEP_AFTER + 5.0
	await step(60)
	assert_true(vis.get_sleep() < 0.1, "no sleeping outside the lobby")
	# Reduced motion: calmer amplitudes, no spin.
	var settings := get_tree().root.get_node_or_null(^"Settings")
	if settings:
		var was: bool = settings.get(&"reduced_motion")
		settings.set(&"reduced_motion", true)
		vis._lod_in = 0.0
		await step(2)
		assert_near(vis._calm, 0.5, 0.001, "reduced motion halves the amplitudes")
		p.apply_impulse(Vector3(12.0, 6.0, 0.0))
		var spun := [false]
		await step(30, func(_i: int) -> void: spun[0] = spun[0] or vis._spin_t < VisualsComponent.SPIN_TIME)
		assert_false(spun[0], "no knockback spin with reduced motion")
		settings.set(&"reduced_motion", was)
	vis._fidget_in = 999.0
	p.place_at(Transform3D.IDENTITY)  # the knock sent it off the arena
	await step(150)
	assert_true(_at_rest(p), "scale back to identity")


func test_interest_point_turns_eyes_and_body() -> void:
	var p := spawn_arena(1)[0]
	var vis := _vis(p)
	await step(20)
	var left := Basis(Vector3.UP, vis._yaw) * Vector3.RIGHT
	for i in 40:
		vis.set_interest_point(p.global_position + left * 4.0 + Vector3.UP * 0.7, 1.0)
		await step(1)
	assert_true(vis._twist > 0.1, "body turns toward the interest point (%f)" % vis._twist)
	var pupil := (vis.get_model_root().get_node("PupilL") as Node3D).position.x - vis._pupil_rest[0].x
	assert_true(pupil > 0.008, "pupils follow (%f)" % pupil)
	await step(90)
	assert_true(absf(vis._twist) < 0.25, "interest fades when no longer fed (%f)" % vis._twist)


## LOW quality and far from the camera: no fidgets, no face work.
func test_low_quality_far_skips_face() -> void:
	var p := spawn_arena(1)[0]
	var vis := _vis(p)
	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = p.global_position + Vector3(0.0, 2.0, 30.0)
	cam.make_current()
	var was := Look.quality
	Look.quality = Look.Quality.LOW
	vis._lod_in = 0.0
	await step(3)
	assert_true(vis._far, "far at LOW quality")
	var lid := (vis.get_model_root().get_node("LidL") as Node3D).rotation.x
	vis.set_expression(BlobExpressions.SLEEPY)
	await step(20)
	assert_near((vis.get_model_root().get_node("LidL") as Node3D).rotation.x, lid, 0.0001, "face frozen far away")
	vis._idle_time = 10.0
	vis._fidget_in = 0.0
	await step(10)
	assert_eq(vis.get_action(), &"", "no fidgets far away")
	Look.quality = was
	vis._lod_in = 0.0
	await step(3)
	assert_false(vis._far, "near again")
	vis.set_expression(&"")
	cam.queue_free()


## A remote copy, driven like the sync component would (position, facing, relayed events):
## skid from position deltas alone, emotes and social reactions from events.
func test_remote_copy_new_reactions() -> void:
	var ps := spawn_arena(2)
	var r := ps[1]
	r.set_multiplayer_authority(2)
	var vis := _vis(r)
	await step(5)
	r.facing = Vector3.RIGHT
	var start := r.global_position
	await step(40, func(i: int) -> void: r.global_position = start + Vector3(0.1 * i, 0.0, 0.0))
	assert_eq(vis.get_reaction(), &"run", "runs")
	var stop := r.global_position
	var seen := {}
	await step(20, func(_i: int) -> void:
		r.global_position = stop
		seen[vis.get_reaction()] = true)
	assert_true(seen.has(&"skid"), "skids from replicated positions (saw %s)" % [seen.keys()])
	await step(30)
	r.receive_event(&"emote", [2])
	await step(10)
	assert_eq(vis.get_emote(), &"dance", "remote dance")
	r.receive_event(&"emote", [99])
	await step(2)
	assert_eq(vis.get_emote(), &"dance", "unknown emote id ignored")
	await step(20, func(i: int) -> void: r.global_position = stop + Vector3(0.0, 0.0, 0.1 * i))
	assert_eq(vis.get_emote(), &"", "moving cancels the remote dance")
	r.receive_event(&"emote", [4])
	await step(10)
	assert_eq(vis.get_emote(), &"cry", "remote cry")
	var tears := vis.find_child("Tears", true, false) as CPUParticles3D
	assert_true(tears != null and tears.emitting, "tears flow")
	r.receive_event(&"got_hit", [Vector3(-6.0, 2.0, 0.0), 0])
	await step(2)
	assert_eq(vis.get_emote(), &"", "a knockback cancels the emote")
	assert_false(tears.emitting, "tears stop")
	await step(200)
	assert_true(_at_rest(r), "remote scale back to identity")


## 8 blobs emoting, fidgeting, crying and sleeping for 600 frames: the node count does not grow.
func test_no_node_growth() -> void:
	var ps := spawn_arena(8)
	stage.follow_roster = true
	await step(30)
	for p in ps:
		_vis(p).play_emote(&"cry", true)  # tears are made once per blob, on its first cry
	await step(30)
	for i in ps.size():
		_vis(ps[i]).play_emote([&"cry", &"dance", &"taunt", &"victory"][i % 4], true)
	await step(60)
	for p in ps:
		_vis(p).stop_emote()
		_vis(p)._idle_time = VisualsComponent.SLEEP_AFTER + 1.0
	await step(120)
	for i in ps.size():
		_vis(ps[i]).play_emote([&"cry", &"sulk"][i % 2], true)
	await step(30)
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	await step(600, func(i: int) -> void:
		if i % 150 == 0:
			for j in ps.size():
				_vis(ps[j]).play_emote([&"cry", &"dance", &"wave", &"sulk"][(i / 150 + j) % 4], true))
	var nodes_after := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var objects_after := Performance.get_monitor(Performance.OBJECT_COUNT)
	assert_true(nodes_after <= nodes, "node count steady (%d -> %d)" % [nodes, nodes_after])
	assert_true(objects_after <= objects + 8, "object count steady (%d -> %d)" % [objects, objects_after])
