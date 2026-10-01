extends GameTest
## The Training Room (res://tutorial/) on its own: a scripted player plays the whole course
## (every station completes in order, each gate stays shut until its station is done and opens
## after, the finish panel shows), plus the hazards' failure paths and the card glyphs.
## The app entry points (title, first-run prompt, pause menu, Skip) are in test_tutorial_app.gd.

const ROOM_SCENE := "res://tutorial/training_room.tscn"

var room: TrainingRoom
var me: Player
var _jump_held: bool = false
var _action: bool = false
var _saved_coins: int = 0
var _saved_claimed: Array[String] = []


func before_each() -> void:
	_saved_coins = Progression.coins
	_saved_claimed = Progression.claimed.duplicate()


func after_each() -> void:
	Progression.coins = _saved_coins
	Progression.claimed = _saved_claimed


func _load_room() -> void:
	Net.start_offline()
	for i in TrainingRoom.DUMMY_COUNT:
		Net.add_bot()
	stage = STAGE_SCENE.instantiate() as Stage
	add_child(stage)
	room = stage.load_minigame_scene(load(ROOM_SCENE) as PackedScene) as TrainingRoom
	players.assign(stage.players.values())
	for p in players:
		if not p.is_bot:
			(p.get_component(&"controller") as ControllerComponent).scripted = true
	room._setup(players)
	for p in players:
		p.frozen = false
	room._start()
	me = room.human


func _st(i: int) -> TrainingStation:
	return room.stations[i]


## One scripted tick: walk toward `to` (flat), jump while `jump` is true (one press per hold),
## press shove every other tick while `shove` is true.
func _drive(to: Vector3, jump: bool = false, shove: bool = false) -> void:
	var d := Vector2(to.x - me.global_position.x, to.z - me.global_position.z)
	me.intent.move = d.normalized() * clampf(d.length() / 0.5, 0.0, 1.0) if d.length() > 0.08 else Vector2.ZERO
	# A player holds jump through the rise of a jump (a full-height hop), then lets go.
	var hold := jump or (_jump_held and not me.is_on_floor() and me.velocity.y > 0.0)
	me.intent.jump_pressed = hold and not _jump_held
	me.intent.jump_held = hold
	_jump_held = hold
	_action = shove and not _action
	me.intent.action_pressed = _action


## Steps until `done` is true (or `max_frames`), steering with `drive` (called before each tick).
func _until(done: Callable, drive: Callable, max_frames: int = 900) -> bool:
	for i in max_frames:
		if done.call():
			return true
		await step(1, func(_i: int) -> void: drive.call())
	return done.call()


func _station_done(i: int) -> Callable:
	return func() -> bool: return _st(i).done


# --- The whole course ----------------------------------------------------------------------------

func test_scripted_player_finishes_the_course() -> void:
	_load_room()
	assert_true(me != null and not me.is_bot, "a human player")
	assert_eq(room.dummies.size(), TrainingRoom.DUMMY_COUNT, "dummies")
	assert_eq(room.stations.size(), 9, "nine stations")
	assert_eq(room.gates.size(), 8, "a gate after every station but the last")
	for d in room.dummies:
		assert_true((d.get_component(&"controller") as ControllerComponent).scripted, "dummy %d is scripted" % d.slot)
	var started := watch(room, &"station_started")
	var completed := watch(room, &"station_completed")
	for g in room.gates:
		assert_true(g.is_blocking(), "%s shut at the start" % g.name)
	assert_true(room.ui.is_row_current(0), "checklist highlights Move")

	# 1 Move: the mat.
	assert_true(await _until(_station_done(0), func() -> void: _drive(_st(0).target())), "Move done")
	await _gate_opened(0)
	# 2 Jump: two gaps, then the ledge.
	var jump := _st(1)
	assert_true(await _until(_station_done(1), func() -> void:
		var z := jump.to_local(me.global_position).z
		var near_gap := (z < -1.9 and z > -2.5) or (z < -6.9 and z > -7.5)
		var at_ledge := z < -9.3 and z > -10.7 and me.global_position.y < 0.5
		_drive(jump.target(), me.is_on_floor() and (near_gap or at_ledge)), 1200), "Jump done")
	await _gate_opened(1)
	# 3 Shove: walk to the dummy and shove it off its pad.
	var shove := _st(2)
	assert_true(await _until(_station_done(2), func() -> void:
		var d := shove.dummies[0]
		var close := TrainingStation.flat_dist(me.global_position, d.global_position) < 1.15
		_drive(d.global_position, false, close), 900), "Shove done")
	await _gate_opened(2)
	# 4 Getting shoved: stand on the red mat; the dummy comes and shoves.
	var shoved := _st(3)
	var hits := watch(me, &"got_hit")
	var stuns := watch(me, &"stunned")
	assert_true(await _until(_station_done(3), func() -> void: _drive(shoved.target()), 900), "Getting shoved done")
	assert_true(hits.size() >= 1 and int(hits[0][1]) == shoved.dummies[0].slot, "hit by the Shover dummy")
	assert_true(stuns.size() >= 1, "stunned")
	await _gate_opened(3)
	# 5 Lava: run straight across the tiles.
	var lava := _st(4)
	assert_true(await _until(_station_done(4), func() -> void: _drive(lava.target()), 900), "Lava done")
	await _gate_opened(4)
	# 6 Ring: onto the ring, then the core; wait for the drop.
	var ring := _st(5)
	assert_true(await _until(_station_done(5), func() -> void: _drive(ring.target()), 900), "Ring done")
	assert_true(await _until(func() -> bool: return int(ring.get(&"state")) == 0, func() -> void: _drive(ring.target()), 300), "ring back up")
	await _gate_opened(5)
	# 7 Hot potato: take the bomb, pass it to the Catcher.
	var potato := _st(6)
	assert_true(await _until(func() -> bool: return potato.holder_slot() == me.slot, func() -> void:
		_drive(potato.dummies[0].global_position), 900), "got the bomb")
	assert_true(await _until(_station_done(6), func() -> void:
		var target := potato.dummies[1].global_position if potato.holder_slot() == me.slot else potato.to_global(Vector3(0, 0, -6))
		_drive(target), 900), "Hot potato done")
	await _gate_opened(6)
	# 8 Coins: grab the nearest coin until five.
	var coins := _st(7)
	assert_true(await _until(_station_done(7), func() -> void:
		var spots: Array[Vector3] = coins.coin_positions()
		var best := coins.target()
		var bd := INF
		for c in spots:
			var dd := TrainingStation.flat_dist(c, me.global_position)
			if dd < bd:
				bd = dd
				best = c
		_drive(best), 2400), "Coin rain done")
	assert_eq(int(coins.get(&"collected")), 5, "five coins")
	await _gate_opened(7)
	# 9 Finish.
	var finished := watch(room, &"course_finished")
	assert_true(await _until(_station_done(8), func() -> void: _drive(_st(8).target()), 900), "Finish done")
	assert_eq(finished.size(), 1, "course_finished once")
	assert_true(room.is_course_finished(), "course finished")
	assert_true(room.elapsed < 180.0, "under 3 minutes (%.1f s)" % room.elapsed)
	assert_eq(room.reward_given, TrainingRoom.REWARD, "finish reward")
	assert_true(await _until(func() -> bool: return room.ui.is_finish_shown(), func() -> void: _drive(me.global_position), 180), "finish panel shown")
	assert_eq(started.size(), 8, "every later station started (Move started in _start)")
	print("training course: %.1f s, %d falls" % [room.elapsed, room.falls])
	var order: Array[int] = []
	for c: Array in completed:
		order.append(int(c[0]))
	assert_eq(order, [0, 1, 2, 3, 4, 5, 6, 7, 8] as Array[int], "stations completed in order")
	assert_false(room.is_finished(), "the room never finishes on its own")
	var exits := watch(room, &"exit_requested")
	room.ui.title_button.pressed.emit()
	assert_eq(exits, [[false]], "Back to title asks to exit")


## Gate `i` opened once station `i` was done, and the next station's gate is still shut.
func _gate_opened(i: int) -> void:
	assert_false(room.gates[i].is_blocking(), "gate %d open after station %d" % [i, i])
	if i + 1 < room.gates.size():
		assert_true(room.gates[i + 1].is_blocking(), "gate %d still shut" % (i + 1))
	assert_eq(room.current, i + 1, "station %d current" % (i + 1))
	await step(1)


# --- Failure paths ----------------------------------------------------------------------------------

func test_standing_on_lava_tiles_drops_you_back_to_the_start() -> void:
	_load_room()
	room.jump_to_station(TrainingRoom.Id.LAVA)
	var lava := _st(TrainingRoom.Id.LAVA)
	var tile: Vector3 = lava.to_global(lava.get(&"tile_centres")[1] as Vector3)
	me.place_at(Transform3D(Basis(), tile + Vector3.UP * 0.1))
	var fell := watch(me, &"respawned")
	await step(150, func(_i: int) -> void: me.intent.move = Vector2.ZERO)
	assert_eq(fell.size(), 1, "fell into the lava and came back")
	assert_eq(room.falls, 1, "one fall counted")
	assert_near(me.global_position.z, lava.entry().origin.z, 0.6, "back at the station start")
	assert_false(lava.done, "not done")
	for i in 9:
		assert_true(lava.call(&"is_tile_solid", i), "tile %d restored" % i)


func test_staying_on_the_ring_drops_you() -> void:
	_load_room()
	room.jump_to_station(TrainingRoom.Id.RING)
	var ring := _st(TrainingRoom.Id.RING)
	var centre: Vector3 = ring.to_global(ring.get(&"centre") as Vector3)
	me.place_at(Transform3D(Basis(), centre + Vector3(0.0, 0.1, 2.4)))  # on the outer ring
	var fell := watch(me, &"respawned")
	await step(220, func(_i: int) -> void: me.intent.move = Vector2.ZERO)
	assert_eq(fell.size(), 1, "the ring dropped under the player")
	assert_false(ring.done, "not done")
	assert_eq(int(ring.get(&"state")), 0, "ring reset")


func test_bomb_blows_on_a_slow_player_and_rearms() -> void:
	_load_room()
	room.jump_to_station(TrainingRoom.Id.POTATO)
	var potato := _st(TrainingRoom.Id.POTATO)
	assert_true(await _until(func() -> bool: return potato.holder_slot() == me.slot, func() -> void:
		_drive(potato.dummies[0].global_position), 600), "the Bomber hands over the bomb")
	potato.set(&"fuse_left", 0.3)
	var hits := watch(me, &"got_hit")
	await step(40, func(_i: int) -> void: me.intent.move = Vector2.ZERO)
	assert_true(hits.size() >= 1, "the blast pushed the player")
	assert_false(potato.done, "not done")
	assert_true(await _until(func() -> bool: return potato.holder_slot() == potato.dummies[0].slot, func() -> void: _drive(me.global_position), 200), "the Bomber gets a new bomb")


func test_dummy_off_its_pad_counts_only_once_it_is_off() -> void:
	_load_room()
	room.jump_to_station(TrainingRoom.Id.SHOVE)
	await step(30)
	assert_false(_st(TrainingRoom.Id.SHOVE).done, "a dummy standing on its pad is not done")
	assert_true(room.gates[TrainingRoom.Id.SHOVE].is_blocking(), "gate shut")


# --- UI -------------------------------------------------------------------------------------------

func test_card_shows_the_last_used_device_first() -> void:
	_load_room()
	room.jump_to_station(TrainingRoom.Id.JUMP)
	await step(90)
	var ui := room.ui
	assert_eq(ui.shown_station, TrainingRoom.Id.JUMP, "card shows Jump")
	assert_near(ui.card_offset, 0.0, 0.5, "card slid in")
	ui.set_device(TrainingUI.Device.KEYBOARD)
	await step(1)
	var texts := ui.card_glyph_texts()
	assert_eq(",".join(texts.slice(0, 4)), "W,A,S,D", "keyboard first: WASD (%s)" % [texts])
	assert_true(texts.has("Space") and texts.has("A"), "Space and (A) both shown")
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_A
	pad.pressed = true
	ui._input(pad)
	await step(1)
	texts = ui.card_glyph_texts()
	assert_eq(ui.device, TrainingUI.Device.GAMEPAD, "a pad button switches to the gamepad")
	assert_eq(texts[0], "L", "gamepad first: the left stick (%s)" % [texts])
	var key := InputEventKey.new()
	key.keycode = KEY_W
	key.pressed = true
	ui._input(key)
	assert_eq(ui.device, TrainingUI.Device.KEYBOARD, "a key switches back")
	assert_true(ui.is_row_current(TrainingRoom.Id.JUMP), "checklist highlights Jump")
	assert_false(ui.is_row_current(TrainingRoom.Id.MOVE), "Move is not current")
	# Done: the green check pops on the card, then the next card slides in.
	var sounds := watch(Sfx, &"played")
	_st(TrainingRoom.Id.JUMP).complete()
	await step(2)
	assert_true(ui.card_done, "green check on the Jump card")
	assert_true(sounds.any(func(a: Array) -> bool: return a[0] == &"join_chime"), "completion chime")
	assert_false(room.gates[TrainingRoom.Id.JUMP].is_blocking(), "gate opened")
	await step(90)
	assert_eq(ui.shown_station, TrainingRoom.Id.SHOVE, "the Shove card replaced it")
	assert_false(ui.card_done, "no check on the new card")
