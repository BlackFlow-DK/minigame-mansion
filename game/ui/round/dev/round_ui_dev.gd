extends Node3D
## Dev scene for the round UI: fakes Net.roster and Session data and emits the Session
## signals itself. Name tags come from the Stage (`Stage.name_tags`), as in the game.
## User args after `--`:
##   --players=N   2..8 (default 4)
##   --phase=X     intro | hud | results | podium | all (default all: loops through every panel)
## Esc quits.

const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")
const NAMES: Array[String] = ["Sander", "Mads", "Freja", "Bartholomew the Great", "Ida", "Oliver", "Sofie", "Karl"]

@onready var stage: Stage = $Stage
@onready var ui: RoundUI = $RoundUI

var _count: int = 4
var _phase: String = "all"


func _ready() -> void:
	# Real-time animations: cap the frame rate so screenshot frame counts map to seconds.
	Engine.max_fps = 60
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--players="):
			_count = clampi(arg.trim_prefix("--players=").to_int(), 2, Net.MAX_PLAYERS)
		elif arg.begins_with("--phase="):
			_phase = arg.trim_prefix("--phase=")
	Net.start_offline()
	for i in _count - 1:
		Net.add_bot()
	for slot: int in Net.roster:
		Net.roster[slot].name = NAMES[slot]
	var minigame := stage.load_minigame_scene(DEV_ARENA)
	minigame.title = "Coin Scramble"
	minigame.rule_text = "Grab the most coins before time runs out. Shove to make others drop theirs!"
	minigame.time_limit = 45.0
	Session.current_minigame = minigame
	Session.round_count = 8
	Session.round_index = 2
	for slot: int in Net.roster:
		Session.scores[slot] = [7, 4, 9, 2, 5, 3, 1, 6][slot]
	match _phase:
		"intro":
			_intro()
		"hud":
			_hud()
		"results":
			_results()
		"podium":
			_podium()
		_:
			_loop()


func _intro() -> void:
	Session.round_intro.emit({"id": &"coin_scramble", "title": stage.minigame.title, "rule_text": stage.minigame.rule_text}, Session.round_index)


func _hud() -> void:
	_intro()
	Session.round_started.emit()
	for slot: int in Net.roster:
		ui.set_counter(slot, [3, 11, 0, 5, 8, 2, 14, 6][slot])
	var victim := stage.get_player(1)
	if victim:
		victim.eliminate(&"dev")
	RoundUI.push_banner("SUDDEN DEATH!", 60.0)


func _results() -> void:
	var ranking := _ranking()
	var points := _points(ranking)
	for slot: int in points:
		Session.scores[slot] = int(Session.scores.get(slot, 0)) + int(points[slot])
	Session.round_finished.emit(ranking, points)


func _podium() -> void:
	var ranking: Array[int] = []
	ranking.assign(Session.scores.keys())
	ranking.sort_custom(func(a: int, b: int) -> bool: return Session.scores[a] > Session.scores[b])
	Session.session_finished.emit(ranking)


func _loop() -> void:
	while is_inside_tree():
		_intro()
		await get_tree().create_timer(RoundIntroCard.LEAD_SECONDS).timeout
		_hud()
		await get_tree().create_timer(5.0).timeout
		_results()
		await get_tree().create_timer(RoundResults.TOTAL_SECONDS + 1.5).timeout
		_podium()
		await get_tree().create_timer(6.0).timeout
		Session.state_changed.emit(Session.State.LOBBY)
		await get_tree().create_timer(3.0).timeout


## A shuffled-looking but fixed ranking of every roster slot.
func _ranking() -> Array[int]:
	var order: Array[int] = [3, 0, 5, 1, 7, 2, 6, 4]
	var ranking: Array[int] = []
	for s in order:
		if Net.roster.has(s):
			ranking.append(s)
	return ranking


func _points(ranking: Array[int]) -> Dictionary:
	var table: Array[int] = [4, 3, 2, 1]
	var points: Dictionary = {}
	for i in ranking.size():
		points[ranking[i]] = table[i] if i < table.size() else 0
	return points


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		get_tree().quit()
