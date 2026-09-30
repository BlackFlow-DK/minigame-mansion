extends GameTest
## Skeleton guarantees: physics steps headless, spawning, tick order, events, controller.

const PLAYER_SCENE: PackedScene = preload("res://player/player.tscn")


## Records every physics_tick/post_tick into a shared log as "<name>:tick" / "<name>:post".
class Recorder extends PlayerComponent:
	var log_ref: Array[String]
	var push_x: float = 0.0
	var seen_positions: Dictionary = {}

	func physics_tick(_delta: float) -> void:
		log_ref.append("%s:tick" % name)
		seen_positions[name + ":tick"] = player.global_position
		if push_x != 0.0:
			player.velocity = Vector3(push_x, 0.0, 0.0)

	func post_tick(_delta: float) -> void:
		log_ref.append("%s:post" % name)
		seen_positions[name + ":post"] = player.global_position


func test_input_map_has_contract_actions() -> void:
	for action: StringName in [&"move_left", &"move_right", &"move_forward", &"move_back", &"jump", &"action", &"pause"]:
		if assert_true(InputMap.has_action(action), "missing action %s" % action):
			assert_true(InputMap.action_get_events(action).size() >= 2, "%s needs keyboard and gamepad events" % action)


func test_headless_physics_steps() -> void:
	var body := RigidBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = SphereShape3D.new()
	body.add_child(shape)
	add_child(body)
	body.global_position = Vector3(0, 10, 0)
	await step(30)
	assert_true(body.global_position.y < 9.0, "rigid body fell (y = %f)" % body.global_position.y)


func test_players_spawn_at_spawn_points() -> void:
	var ps := spawn_arena(4)
	assert_eq(ps.size(), 4, "player count")
	var points := get_minigame().get_spawn_points()
	assert_eq(points.size(), 8, "spawn point count")
	for i in ps.size():
		var p := ps[i]
		assert_eq(p.slot, i, "slot")
		assert_eq(String(p.name), "P%d" % i, "node name")
		assert_eq(p.is_bot, i != 0, "is_bot of slot %d" % i)
		assert_near(p.global_position, points[i].origin, 0.001, "position of slot %d" % i)
		assert_near(p.facing, (points[i].basis * Vector3.MODEL_FRONT).normalized(), 0.001, "facing of slot %d" % i)
		assert_eq(p.global_basis, Basis.IDENTITY, "root rotation of slot %d" % i)
		assert_false(p.frozen, "unfrozen after spawn_arena")
	assert_eq(stage.get_player(2), ps[2], "get_player")


func test_tick_order() -> void:
	spawn_arena(1)
	var events: Array[String] = []
	var p := PLAYER_SCENE.instantiate() as Player
	var holder := p.get_node(^"Components")
	var names: Array[String] = []
	for child in holder.get_children():
		names.append(String(child.name))
		holder.remove_child(child)
		child.free()
	for n in names:
		var r := Recorder.new()
		r.name = n
		r.log_ref = events
		if n == "movement":
			r.push_x = 60.0  # 1 m per tick: move_and_slide must happen between shove and post
		holder.add_child(r)
	p.slot = 7
	stage.add_child(p)
	p.global_position = Vector3(0, 0.05, 3)
	await step(1)
	var expected: Array[String] = ["controller:tick", "status:tick", "movement:tick", "jump:tick", "shove:tick"]
	for n in names:
		expected.append("%s:post" % n)
	assert_eq(events, expected, "tick order")
	var shove := p.get_component(&"shove") as Recorder
	var first_post := p.get_component(StringName(names[0])) as Recorder
	var before: Vector3 = shove.seen_positions["shove:tick"]
	var after: Vector3 = first_post.seen_positions[names[0] + ":post"]
	assert_true(after.x - before.x > 0.5, "move_and_slide ran between shove tick and post_tick (%s -> %s)" % [before, after])
	# Only the authority ticks.
	events.clear()
	p.set_multiplayer_authority(2)
	await step(2)
	assert_eq(events.size(), 0, "a non-authority copy does not tick")


func test_frozen_and_locked_clear_intent() -> void:
	var p := spawn_arena(1)[0]
	var write := func(_i: int) -> void:
		p.intent.move = Vector2.RIGHT
		p.intent.jump_pressed = true
	await step(1, write)
	assert_eq(p.intent.move, Vector2.RIGHT, "intent kept while free")
	p.frozen = true
	await step(1, write)
	assert_eq(p.intent.move, Vector2.ZERO, "frozen clears move")
	assert_false(p.intent.jump_pressed, "frozen clears jump")
	p.frozen = false
	p.control_locked = true
	await step(1, write)
	assert_eq(p.intent.move, Vector2.ZERO, "control_locked clears move")


func test_emit_event_raises_signal() -> void:
	var p := spawn_arena(2)[1]
	var landed := watch(p, &"landed")
	var jumped := watch(p, &"jumped")
	p.emit_event(&"landed", [3.5])
	p.emit_event(&"jumped")
	assert_eq(landed, [[3.5]], "landed args")
	assert_eq(jumped, [[]], "jumped args")


func test_eliminate_and_respawn() -> void:
	var p := spawn_arena(2)[0]
	var out := watch(p, &"eliminated")
	var back := watch(p, &"respawned")
	p.eliminate(&"fell")
	assert_eq(out, [[&"fell"]], "eliminated args")
	assert_false(p.alive, "dead after eliminate")
	assert_false(p.visible, "hidden after eliminate")
	var xform := Transform3D(Basis.IDENTITY, Vector3(1, 0, 2))
	p.respawn_at(xform)
	assert_true(p.alive and p.visible, "alive and visible after respawn")
	assert_near(p.global_position, Vector3(1, 0, 2), 0.001, "respawn position")
	assert_eq(back.size(), 1, "respawned raised once")


func test_apply_impulse_reaches_velocity() -> void:
	var p := spawn_arena(1)[0]
	p.apply_impulse(Vector3(0, 0, 5))
	assert_near(p.velocity, Vector3(0, 0, 5), 0.001, "status stub adds the impulse")


func test_knock_out_finishes_with_ranking() -> void:
	var ps := spawn_arena(3)
	get_minigame().knock_out(ps[1])
	assert_true(ranking.is_empty(), "not finished with two left")
	get_minigame().knock_out(ps[0])
	assert_eq(ranking, [2, 0, 1], "survivor first, then reverse knock-out order")


func test_human_controller_maps_input() -> void:
	var p := spawn_arena(1, &"", false)[0]
	Input.action_press(&"move_right")
	await step(1)
	assert_near(p.intent.move, Vector2(1, 0), 0.001, "right -> +X")
	Input.action_release(&"move_right")
	Input.action_press(&"move_forward")
	await step(1)
	assert_near(p.intent.move, Vector2(0, -1), 0.001, "forward (away from the camera) -> -Z")
	Input.action_release(&"move_forward")
	Input.action_press(&"jump")
	Input.action_press(&"action")
	await step(1)
	assert_true(p.intent.jump_pressed and p.intent.jump_held, "jump pressed + held on the first tick")
	assert_true(p.intent.action_pressed, "action pressed on the first tick")
	await step(1)
	assert_false(p.intent.jump_pressed, "jump_pressed only on the first tick")
	assert_true(p.intent.jump_held, "jump still held")
	assert_false(p.intent.action_pressed, "action_pressed only on the first tick")
	Input.action_release(&"jump")
	await step(1)
	assert_false(p.intent.jump_held, "jump released")
	assert_eq(p.intent.move, Vector2.ZERO, "no move without input")
