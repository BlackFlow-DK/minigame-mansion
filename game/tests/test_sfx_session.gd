extends GameTest
## Session/roster sounds (game/audio/session_sounds.gd).

const SessionSounds := preload("res://audio/session_sounds.gd")

var _node: Node = null
var _req: Array = []


func before_each() -> void:
	Net.start_offline()
	_node = SessionSounds.new()
	add_child(_node)
	_req = watch(_node, &"requested")


func after_each() -> void:
	if is_instance_valid(_node):
		_node.queue_free()


func _sounds() -> Array[StringName]:
	var out: Array[StringName] = []
	for e: Array in _req:
		out.append(e[0])
	return out


func test_countdown_beeps_once_per_second() -> void:
	var intro: int = Session.State.INTRO
	for t: float in [5.0, 3.5, 3.0, 2.5, 2.0, 1.2, 0.9, 0.3]:
		_node.update_countdown(intro, t, 3.0)
	assert_eq(_sounds().count(&"countdown_beep"), 3, "3-2-1")
	_node.update_countdown(Session.State.PLAYING, 0.0, 3.0)
	_node.update_countdown(Session.State.LOBBY, 2.0, 3.0)
	assert_eq(_sounds().count(&"countdown_beep"), 3, "no beeps outside INTRO")


func test_round_flow_sounds() -> void:
	_node._on_round_started()
	var won: Array[int] = [0, 1]
	_node._on_round_finished(won, {0: 4, 1: 3})
	await step(40)
	var lost: Array[int] = [1, 0]
	_node._on_round_finished(lost, {1: 4, 0: 3})
	await step(40)
	var final: Array[int] = [0, 1]
	_node._on_session_finished(final)
	var expected: Array[StringName] = [&"countdown_go", &"round_end", &"round_win_jingle", &"round_end", &"podium_fanfare"]
	assert_eq(_sounds(), expected, "round flow")


func test_session_signals_are_connected() -> void:
	assert_true(Session.round_started.is_connected(_node._on_round_started), "round_started")
	assert_true(Session.round_finished.is_connected(_node._on_round_finished), "round_finished")
	assert_true(Session.session_finished.is_connected(_node._on_session_finished), "session_finished")


func test_join_and_leave_chimes() -> void:
	var slot := Net.add_bot()
	assert_true(slot > 0, "bot added")
	assert_eq(_sounds(), [&"join_chime"] as Array[StringName], "join chime")
	Net.remove_bot(slot)
	assert_eq(_sounds(), [&"join_chime", &"leave_chime"] as Array[StringName], "leave chime")
	Net.leave()
	assert_eq(_sounds().size(), 2, "leaving ourselves is silent")
	Net.start_offline()
	assert_eq(_sounds().size(), 2, "our own slot appearing is silent")
