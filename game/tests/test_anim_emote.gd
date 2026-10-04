extends GameTest
## Emote component: the key press becomes one replicated `emote` event, rate-limited, refused
## while frozen in a round but allowed in the lobby and on the podium; the visuals play it and
## cancel it on movement, a shove or a knockback; the sync hub relays it like any event.


func after_each() -> void:
	Session.state = Session.State.LOBBY


func _vis(p: Player) -> VisualsComponent:
	return p.get_component(&"visuals") as VisualsComponent


func _press(p: Player, id: int) -> Callable:
	return func(i: int) -> void: p.intent.emote = id if i == 0 else 0


func test_component_is_registered() -> void:
	var p := spawn_arena(1)[0]
	assert_true(p.get_component(&"emote") is EmoteComponent, "emote component")
	assert_false(Player.TICK_ORDER.has(&"emote"), "not ticked: it consumes the press in post_tick")
	assert_true(p.has_signal(&"emote"), "player event")
	p.intent.emote = 3
	p.intent.clear()
	assert_eq(p.intent.emote, 3, "clear() keeps the emote press for the emote component")
	await step(1)
	assert_eq(p.intent.emote, 0, "consumed")
	for id in [1, 2, 3, 4]:
		assert_ne_name(EmoteComponent.name_of(id))
	assert_eq(EmoteComponent.name_of(7), &"", "unknown id")
	for action: StringName in ControllerComponent.EMOTE_ACTIONS:
		assert_true(InputMap.has_action(action), "input action %s" % action)


func assert_ne_name(n: StringName) -> void:
	assert_true(n != &"" and VisualsComponent.EMOTES.has(n), "emote name %s known to the visuals" % n)


func test_press_raises_one_event_and_plays_it() -> void:
	var p := spawn_arena(1)[0]
	await step(5)
	var events := watch(p, &"emote")
	await step(3, _press(p, 1))
	assert_eq(events.size(), 1, "one event")
	assert_eq(events[0][0], 1, "id 1")
	await step(5)
	assert_eq(_vis(p).get_emote(), &"wave", "wave plays")
	assert_eq(_vis(p).get_reaction(), &"emote", "emote reaction")


func test_rate_limit() -> void:
	var p := spawn_arena(1)[0]
	await step(5)
	var events := watch(p, &"emote")
	var emote := p.get_component(&"emote") as EmoteComponent
	await step(1, _press(p, 2))
	await step(20, func(i: int) -> void: p.intent.emote = 3 if i % 5 == 0 else 0)
	assert_eq(events.size(), 1, "presses inside the cooldown are dropped")
	assert_true(emote.cooldown_left() > 0.0, "cooldown running")
	await step(int(emote.cooldown * 60.0))
	await step(1, _press(p, 3))
	assert_eq(events.size(), 2, "allowed again after %.1f s" % emote.cooldown)
	assert_eq(events[1][0], 3, "taunt")


func test_frozen_rules() -> void:
	var p := spawn_arena(1)[0]
	await step(5)
	var events := watch(p, &"emote")
	var emote := p.get_component(&"emote") as EmoteComponent
	p.frozen = true
	Session.state = Session.State.PLAYING
	await step(2, _press(p, 1))
	assert_eq(events.size(), 0, "no emotes while frozen in a round")
	Session.state = Session.State.RESULTS
	await step(2, _press(p, 1))
	assert_eq(events.size(), 0, "nor in the results")
	Session.state = Session.State.PODIUM
	await step(2, _press(p, 2))
	assert_eq(events.size(), 1, "on the podium")
	await step(60)
	Session.state = Session.State.LOBBY
	await step(2, _press(p, 4))
	assert_eq(events.size(), 2, "in the lobby")
	Session.state = Session.State.PLAYING
	await step(60)
	p.frozen = false
	await step(2, _press(p, 1))
	assert_eq(events.size(), 3, "unfrozen in a round: allowed")
	p.control_locked = true
	assert_false(emote.request(2), "not while stunned")


func test_cancel_rules() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var vis := _vis(p)
	p.place_at(Transform3D.IDENTITY)
	await step(5)
	await step(10, _press(p, 2))
	assert_eq(vis.get_emote(), &"dance", "dancing")
	await step(150)
	assert_eq(vis.get_emote(), &"dance", "the dance loops while standing")
	await step(20, func(_i: int) -> void: p.intent.move = Vector2(1.0, 0.0))
	assert_eq(vis.get_emote(), &"", "moving ends the dance")
	await step(60)
	await step(5, _press(p, 3))
	assert_eq(vis.get_emote(), &"taunt", "taunting")
	await step(3, func(i: int) -> void: p.intent.action_pressed = i == 0)
	assert_eq(vis.get_emote(), &"", "a shove ends it")
	await step(60)
	await step(5, _press(p, 1))
	assert_eq(vis.get_emote(), &"wave", "waving")
	p.apply_impulse(Vector3(3.0, 1.0, 0.0), ps[1])
	await step(3)
	assert_eq(vis.get_emote(), &"", "a knockback ends it")
	# A minigame's looping cheer is not cancelled by movement and resumes after a player emote.
	await step(60)
	p.place_at(Transform3D.IDENTITY)
	await step(30)
	vis.play_emote(&"cheer", true)
	await step(5, _press(p, 1))
	assert_eq(vis.get_emote(), &"wave", "wave over the cheer")
	await step(int(VisualsComponent.EMOTES[&"wave"] * 60.0) + 5)
	assert_eq(vis.get_emote(), &"cheer", "cheer resumes")
	await step(20, func(_i: int) -> void: p.intent.move = Vector2(1.0, 0.0))
	assert_eq(vis.get_emote(), &"cheer", "movement does not cancel an API emote")
	vis.stop_emote()


## The relay path offline: SyncHub accepts `emote` as a player event from the player's
## authority (no validation beyond that) and raises it on the copy.
func test_replication_through_the_hub() -> void:
	var ps := spawn_arena(2)
	var r := ps[1]
	r.set_multiplayer_authority(2)
	var hub := stage.sync_hub
	var events := watch(r, &"emote")
	assert_true(hub.receive_event(2, stage.net_load_id, r.slot, &"emote", [4]), "accepted from the authority")
	assert_eq(events.size(), 1, "raised on the copy")
	assert_false(hub.receive_event(3, stage.net_load_id, r.slot, &"emote", [1]), "refused from another client")
	await step(10)
	assert_eq(_vis(r).get_emote(), &"cry", "the copy cries")
	assert_true(hub.receive_event(1, stage.net_load_id, r.slot, &"emote", [2]), "the host may relay it")
	await step(5)
	assert_eq(_vis(r).get_emote(), &"dance", "the copy dances")


func test_bots_emote_in_the_lobby_hall_only() -> void:
	var ps := spawn_arena(3)
	var bot := ps[1]
	var emote := bot.get_component(&"emote") as EmoteComponent
	emote.bot_interval = Vector2(0.3, 0.5)
	emote._bot_in = 0.2
	var events := watch(bot, &"emote")
	await step(90)
	assert_eq(events.size(), 0, "no bot emotes outside the lobby hall (tests, sandbox)")
	stage.follow_roster = true
	await step(90)
	stage.follow_roster = false
	assert_true(events.size() >= 1, "bots emote in the lobby hall")
	var human := ps[0].get_component(&"emote") as EmoteComponent
	human._bot_in = 0.0
	var human_events := watch(ps[0], &"emote")
	stage.follow_roster = true
	await step(30)
	stage.follow_roster = false
	assert_eq(human_events.size(), 0, "humans never emote by themselves")
