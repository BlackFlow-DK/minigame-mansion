extends Node
## Picks the music from the app state and the Session. Owner: audio. Self-contained: add it
## anywhere in the tree (the orchestrator instances it in the main scene) and it listens on
## its own (`Session.state_changed`, `Net.roster_changed`, and whether we are in a game).
##
## | When                                   | Music                                          |
## |----------------------------------------|------------------------------------------------|
## | not in a game (title, join screen)     | `title_theme`                                  |
## | LOBBY                                  | `lobby_waltz`                                  |
## | INTRO / PLAYING of round N             | the minigame's `music_track` if it has one     |
## |                                        | (`&"none"` = silence), else by its StageLook   |
## |                                        | preset: LAVA_CAVE `lava_drums`, BRIGHT_DAY     |
## |                                        | `sky_sumo`, NIGHT_PARTY `night_party`,         |
## |                                        | WARM_HALL `vault_jazz` (also the fallback)     |
## | RESULTS                                | round music ducked + `results_sting` on top    |
## | PODIUM                                 | `podium_theme`, ducked under the fanfare       |
##
## It acts only when that context changes (a new round, results, podium, lobby, title), never
## every frame: a minigame that calls `Music.stop()` / `Music.play()` itself during its round
## (from `_start()` on, since `_setup()` runs before the round's music starts) keeps control
## until RESULTS. Alternatively set `music_track = &"none"` on the minigame root.

## Test seam: every track this node picks (&"" = silence), before it reaches `Music`.
signal track_requested(track: StringName)

const TITLE_TRACK := &"title_theme"
const LOBBY_TRACK := &"lobby_waltz"
const PODIUM_TRACK := &"podium_theme"
const STING_TRACK := &"results_sting"
const DEFAULT_ROUND_TRACK := &"vault_jazz"
const PRESET_TRACKS := {
	StageLook.Preset.WARM_HALL: &"vault_jazz",
	StageLook.Preset.BRIGHT_DAY: &"sky_sumo",
	StageLook.Preset.LAVA_CAVE: &"lava_drums",
	StageLook.Preset.NIGHT_PARTY: &"night_party",
}

## When false the node still decides and emits `track_requested` but leaves `Music` alone.
@export var output_enabled: bool = true
@export var fade_time: float = 1.5
## Results: how far the round music goes down under the sting (0..1 of its volume).
@export var results_duck: float = 0.7
## Podium: duck under `podium_fanfare` (Sfx) for this long.
@export var podium_duck: float = 0.55
@export var podium_duck_time: float = 2.8

## "title", "lobby", "round:<index>", "results:<index>" or "podium".
var context: String = ""
var _state: int = 0
var _in_game: bool = false


func _ready() -> void:
	Session.state_changed.connect(_on_state_changed)
	Net.roster_changed.connect(_on_roster_changed)
	_in_game = Net.local_slot() >= 0
	refresh(Session.state)


func _process(_delta: float) -> void:
	if (Net.local_slot() >= 0) != _in_game:
		_on_roster_changed()


func _on_state_changed(state: int) -> void:
	refresh(state)


func _on_roster_changed() -> void:
	_in_game = Net.local_slot() >= 0
	refresh(_state)


## Re-derives the context from `state` and acts if it changed.
func refresh(state: int) -> void:
	_state = state
	var ctx := context_for(_in_game, state, Session.round_index)
	if ctx == context:
		return
	context = ctx
	if ctx == "title":
		_play(TITLE_TRACK)
	elif ctx == "lobby":
		_play(LOBBY_TRACK)
	elif ctx == "podium":
		_play(PODIUM_TRACK)
		if output_enabled:
			Music.duck(podium_duck, podium_duck_time)
	elif ctx.begins_with("round:"):
		_play(track_for_minigame(Session.current_minigame))
	elif ctx.begins_with("results:"):
		track_requested.emit(STING_TRACK)
		if output_enabled:
			Music.duck(results_duck, maxf(Session.phase_duration, 4.0))
			Music.play_sting(STING_TRACK)


func context_for(in_game: bool, state: int, round_index: int) -> String:
	if not in_game:
		return "title"
	if state == Session.State.INTRO or state == Session.State.PLAYING:
		return "round:%d" % round_index
	if state == Session.State.RESULTS:
		return "results:%d" % round_index
	if state == Session.State.PODIUM:
		return "podium"
	return "lobby"


## The round music of `minigame`: its `music_track` (&"none" = silence) if set, else by the
## preset of its StageLook, else DEFAULT_ROUND_TRACK.
static func track_for_minigame(minigame: Node) -> StringName:
	if minigame == null or not is_instance_valid(minigame):
		return DEFAULT_ROUND_TRACK
	var override: Variant = minigame.get(&"music_track")
	if override != null and str(override) != "":
		var t := StringName(str(override))
		return &"" if t == &"none" else t
	var look := _find_look(minigame)
	if look:
		return PRESET_TRACKS.get(look.preset, DEFAULT_ROUND_TRACK)
	return DEFAULT_ROUND_TRACK


static func _find_look(node: Node) -> StageLook:
	for child in node.get_children():
		if child is StageLook:
			return child as StageLook
		var deeper := _find_look(child)
		if deeper:
			return deeper
	return null


func _play(track: StringName) -> void:
	track_requested.emit(track)
	if not output_enabled:
		return
	if track == &"":
		Music.stop(fade_time)
	else:
		Music.play(track, fade_time)
