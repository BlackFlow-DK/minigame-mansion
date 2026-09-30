class_name GameTest
extends Node
## Base class for headless tests. Put tests in `game/tests/test_<system>*.gd`, `extends GameTest`;
## every method named `test_*` is one test (it may `await`). Run: tools/godot-test.ps1 [-Filter x].
## Each test gets a fresh instance of the script. A test fails on a failed assert, on any
## engine/script error or push_error while it runs, or when it exceeds the runner's time limit.
##
##   func test_walks() -> void:
##       var ps := spawn_arena(2)                       # offline arena, players unfrozen
##       await step(30, func(_i: int) -> void: ps[0].intent.move = Vector2.RIGHT)
##       assert_true(ps[0].global_position.x > 0.5, "moved right")
##
## Physics really steps: the runner uses --fixed-fps 60, so each step() frame is exactly
## one physics tick of 1/60 s and runs as fast as the CPU allows.

const DEV_ARENA_PATH := "res://dev/dev_arena.tscn"
const STAGE_SCENE: PackedScene = preload("res://stage/stage.tscn")

## The arena's Stage (after spawn_arena).
var stage: Stage = null
## The spawned players, sorted by slot (after spawn_arena).
var players: Array[Player] = []
## The ranking the minigame finished with, empty until it emits `finished`.
var ranking: Array[int] = []
## Failure messages collected so far (read by the runner).
var failures: Array[String] = []
## Set by the runner harness when the test (and teardown) completed.
var done: bool = false


## Virtual: runs before each test (may await).
func before_each() -> void:
	pass


## Virtual: runs after each test (may await), before the arena is freed.
func after_each() -> void:
	pass


# --- Arena -------------------------------------------------------------------------

## Starts an offline roster (slot 0 human, the rest bots), loads `minigame_id` (a
## MinigameRegistry id; empty = the flat dev arena) and spawns `count` players.
## Then runs the minigame flow like Session would: `_setup`, unfreeze, `_start`, and from
## then on `_host_tick` every physics frame until it finishes.
## `scripted` (default): every controller leaves `intent` alone, so the test writes
## `player.intent` itself each frame. Pass false for real human input / bot brains.
func spawn_arena(count: int = 4, minigame_id: StringName = &"", scripted: bool = true) -> Array[Player]:
	Net.start_offline()
	for i in count - 1:
		Net.add_bot()
	stage = STAGE_SCENE.instantiate() as Stage
	add_child(stage)
	var minigame: Minigame
	if minigame_id == &"":
		minigame = stage.load_minigame_scene(load(DEV_ARENA_PATH) as PackedScene)
	else:
		minigame = stage.load_minigame(minigame_id)
	players.assign(stage.players.values())
	if minigame == null:
		fail("spawn_arena: could not load minigame '%s'" % minigame_id)
		return players
	minigame.finished.connect(func(r: Array[int]) -> void: ranking = r)
	for p in players:
		var controller := p.get_component(&"controller") as ControllerComponent
		if controller:
			controller.scripted = scripted
	minigame._setup(players)
	for p in players:
		p.frozen = false
	minigame._start()
	return players


## The loaded minigame, or null.
func get_minigame() -> Minigame:
	return stage.minigame if stage else null


func _physics_process(delta: float) -> void:
	var m := get_minigame()
	if m and not m.is_finished():
		m._host_tick(delta)


# --- Time ----------------------------------------------------------------------------

## Advances `frames` physics ticks. `each_frame(i)` runs right before tick i's player
## ticks (write intents there). On return every tick has fully completed.
func step(frames: int = 1, each_frame: Callable = Callable()) -> void:
	for i in frames:
		await get_tree().physics_frame
		if each_frame.is_valid():
			each_frame.call(i)
	await get_tree().process_frame


## Steps until the minigame finishes or `max_frames` pass. Returns true if it finished.
func run_until_finished(max_frames: int = 60 * 90) -> bool:
	for i in max_frames:
		var current := get_minigame()
		if current == null or current.is_finished():
			break
		await step(1)
	var m := get_minigame()
	return m != null and m.is_finished()


## Seconds per physics tick.
func physics_delta() -> float:
	return 1.0 / Engine.physics_ticks_per_second


# --- Signals -------------------------------------------------------------------------

## Records every emission of `obj.signal_name`: returns an Array that gets one entry
## (the Array of signal args) per emission, updated live.
func watch(obj: Object, signal_name: StringName) -> Array:
	var events: Array = []
	obj.connect(signal_name, func(...args: Array) -> void: events.append(args))
	return events


# --- Asserts ---------------------------------------------------------------------------

func fail(message: String) -> void:
	failures.append("%s%s" % [message, _where()])


func assert_true(condition: bool, message: String = "expected true") -> bool:
	if not condition:
		fail(message)
	return condition


func assert_false(condition: bool, message: String = "expected false") -> bool:
	return assert_true(not condition, message)


## `==` comparison (use assert_near for floats and vectors).
func assert_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	var ok: bool = typeof(actual) == typeof(expected) and actual == expected
	if not ok:
		fail("%s expected %s, got %s" % [message, var_to_str(expected), var_to_str(actual)])
	return ok


## For float, Vector2 and Vector3: |actual - expected| <= tolerance.
func assert_near(actual: Variant, expected: Variant, tolerance: float = 0.001, message: String = "") -> bool:
	var dist := INF
	match typeof(actual):
		TYPE_FLOAT, TYPE_INT:
			dist = absf(float(actual) - float(expected))
		TYPE_VECTOR2, TYPE_VECTOR3:
			if typeof(expected) == typeof(actual):
				dist = (actual - expected).length()
	var ok := dist <= tolerance
	if not ok:
		fail("%s expected %s (+-%s), got %s" % [message, str(expected), str(tolerance), str(actual)])
	return ok


# --- Runner interface ------------------------------------------------------------------

## Called by run_tests.gd: before_each, the test, after_each, teardown; then `done`.
func run_test(method: StringName) -> void:
	await before_each()
	if failures.is_empty():
		await call(method)
	await after_each()
	_teardown()
	done = true


func _teardown() -> void:
	for action in InputMap.get_actions():
		Input.action_release(action)
	if stage:
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
	players.clear()
	Net.leave()


func _where() -> String:
	for bt in Engine.capture_script_backtraces():
		for i in bt.get_frame_count():
			var file := bt.get_frame_file(i)
			if file != "" and not file.ends_with("/harness.gd"):
				return " (%s:%d)" % [file.get_file(), bt.get_frame_line(i)]
	return ""
