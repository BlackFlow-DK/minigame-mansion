extends Node
## Session and roster sounds. Owner: audio. Self-contained: add it anywhere in the tree
## (the orchestrator instances it in the main scene) and it listens on its own.
##
## - INTRO countdown: `countdown_beep` on each whole second of the last `Session.countdown_time`
##   seconds (derived from `Session.phase_time_left`), `countdown_go` on `round_started`.
## - `round_finished`: `round_end`, then `round_win_jingle` if the local player shares first.
## - `session_finished`: `podium_fanfare`.
## - `Net.roster_changed`: `join_chime` when someone else joins, `leave_chime` when someone
##   leaves (once per change, not per slot; silent when we ourselves leave).

## Test seam: every sound this node asks for, before it reaches `Sfx`.
signal requested(sound: StringName)

## When false the node still emits `requested` but does not call `Sfx` (tests).
@export var output_enabled: bool = true
## Delay of the win jingle after the round-end sound.
@export var win_jingle_delay: float = 0.45

var _last_count: int = -1
var _known_slots: Array[int] = []


func _ready() -> void:
	_known_slots.assign(Net.roster.keys())
	Session.round_started.connect(_on_round_started)
	Session.round_finished.connect(_on_round_finished)
	Session.session_finished.connect(_on_session_finished)
	Net.roster_changed.connect(_on_roster_changed)


func _process(_delta: float) -> void:
	update_countdown(Session.state, Session.phase_time_left, Session.countdown_time)


## Beeps once per whole second while INTRO is in its last `countdown` seconds.
func update_countdown(state: int, time_left: float, countdown: float) -> void:
	if state != Session.State.INTRO or time_left <= 0.0 or time_left > countdown:
		_last_count = -1
		return
	var n := ceili(time_left)
	if n != _last_count:
		_last_count = n
		_request(&"countdown_beep")


func _on_round_started() -> void:
	_last_count = -1
	_request(&"countdown_go")


func _on_round_finished(ranking: Array[int], points: Dictionary) -> void:
	_request(&"round_end")
	var me := Net.local_slot()
	if me < 0 or ranking.is_empty() or not points.has(me):
		return
	var best: int = points.get(ranking[0], 0)
	if int(points[me]) > 0 and int(points[me]) >= best:
		get_tree().create_timer(win_jingle_delay).timeout.connect(_request.bind(&"round_win_jingle"))


func _on_session_finished(_final_ranking: Array[int]) -> void:
	_request(&"podium_fanfare")


func _on_roster_changed() -> void:
	var now: Array[int] = []
	now.assign(Net.roster.keys())
	if now.is_empty():
		_known_slots = now
		return
	var me := Net.local_slot()
	var joined := false
	var left := false
	for s in now:
		if s != me and not _known_slots.has(s):
			joined = true
	for s in _known_slots:
		if not now.has(s):
			left = true
	_known_slots = now
	if joined:
		_request(&"join_chime")
	if left:
		_request(&"leave_chime")


func _request(sound: StringName) -> void:
	if not is_inside_tree():
		return
	requested.emit(sound)
	if output_enabled:
		Sfx.play(sound)
