extends Node
## Autoload `Session`: round order, scores and the flow lobby -> rounds -> podium.
## Host-driven; clients follow. Owner: session.
## Stub: signals, state and fields only.

enum State { LOBBY, INTRO, PLAYING, RESULTS, PODIUM }

signal state_changed(state: State)
## `info`: `{ "id": StringName, "title": String, "rule_text": String }`; `index` is 0-based.
signal round_intro(info: Dictionary, index: int)
signal round_started
## `ranking`: slots, best first. `points`: slot -> points earned this round.
signal round_finished(ranking: Array[int], points: Dictionary)
signal session_finished(final_ranking: Array[int])

var state: State = State.LOBBY
## slot -> total points.
var scores: Dictionary[int, int] = {}
## 0-based index of the current round, -1 before the first.
var round_index: int = -1
var round_count: int = 0
var current_minigame: Minigame = null


## Host only. Starts a session of `rounds` rounds with the current roster.
func start_session(_rounds: int) -> void:
	pass
