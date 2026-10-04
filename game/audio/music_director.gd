extends Node
## Picks the music from the app state and the Session. Owner: audio. Self-contained: add it
## anywhere in the tree (the orchestrator instances it in the main scene) and it listens on
## its own (`Session.state_changed`, `Net.roster_changed`, and whether we are in a game).
##
## | When                                   | Music                                          |
## |----------------------------------------|------------------------------------------------|
## | not in a game (title, join screen)     | `title_theme`                                  |
## | LOBBY                                  | `lobby_waltz`                                  |
## | VOTE (game modes: picking the next     | `lobby_waltz` ducked to VOTE_DUCK under the    |
## | round)                                 | cards, `countdown_beep` on each of the last    |
## |                                        | VOTE_BEEPS seconds (until the tally)           |
## | INTRO / PLAYING of round N             | the minigame's `music_track` if it has one,    |
## |                                        | else by its StageLook preset: LAVA_CAVE        |
## |                                        | `lava_drums`, BRIGHT_DAY `sky_sumo`,           |
## |                                        | NIGHT_PARTY `night_party`, WARM_HALL           |
## |                                        | `vault_jazz` (also the fallback)               |
## | ... `music_track = &"none"`            | INTRO (the title card) still plays the preset  |
## |                                        | track; at GO (PLAYING) it stops within         |
## |                                        | SILENCE_FADE s and the round is silent         |
## | RESULTS                                | round music ducked + `results_sting` on top    |
## | PODIUM                                 | `podium_theme`, ducked under the fanfare       |
##
## It acts only when that context changes (a new round, its GO for a silent round, results,
## vote, podium, lobby, title), never every frame: a minigame that calls `Music.stop()` /
## `Music.play()` itself during its round (from `_start()` on, since `_setup()` runs before the
## round's music starts) keeps control until RESULTS. A minigame whose own sound is the round's
## music (Statue Garden, Spotlight Chairs) sets `music_track = &"none"` instead.

## Test seam: every track this node picks (&"" = silence), before it reaches `Music`.
signal track_requested(track: StringName)
## Test seam: a VOTE countdown beep (`seconds_left` 3, 2, 1), before it reaches `Sfx`.
signal vote_beep(seconds_left: int)

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
## VOTE: the lobby waltz goes down this far (0..1 of its volume) under the vote cards.
const VOTE_DUCK := 0.5
## VOTE: a countdown beep on each of the last this-many whole seconds.
const VOTE_BEEPS := 3
## A silent round (`music_track = &"none"`): the intro track fades out this fast at GO, so the
## minigame's own tune starts clean.
const SILENCE_FADE := 0.4

## When false the node still decides and emits `track_requested` but leaves `Music` alone.
@export var output_enabled: bool = true
@export var fade_time: float = 1.5
## Results: how far the round music goes down under the sting (0..1 of its volume).
@export var results_duck: float = 0.7
## Podium: duck under `podium_fanfare` (Sfx) for this long.
@export var podium_duck: float = 0.55
@export var podium_duck_time: float = 2.8

## "title", "lobby", "vote:<index>", "round:<index>", "round:<index>:quiet" (a silent round
## after GO), "results:<index>" or "podium".
var context: String = ""
var _state: int = 0
var _in_game: bool = false
## VOTE: the last whole second beeped (so each beeps once).
var _beeped: int = -1


func _ready() -> void:
	Session.state_changed.connect(_on_state_changed)
	Net.roster_changed.connect(_on_roster_changed)
	_in_game = Net.local_slot() >= 0
	refresh(Session.state)


func _process(_delta: float) -> void:
	if (Net.local_slot() >= 0) != _in_game:
		_on_roster_changed()
	if context.begins_with("vote:"):
		_tick_vote()


func _on_state_changed(state: int) -> void:
	refresh(state)


func _on_roster_changed() -> void:
	_in_game = Net.local_slot() >= 0
	refresh(_state)


## Re-derives the context from `state` and acts if it changed.
func refresh(state: int) -> void:
	_state = state
	var ctx := context_for(_in_game, state, Session.round_index)
	if ctx.begins_with("round:") and state == Session.State.PLAYING \
			and track_for_minigame(Session.current_minigame) == &"":
		ctx += ":quiet"
	if ctx == context:
		return
	var was_vote := context.begins_with("vote:")
	context = ctx
	if was_vote and output_enabled:
		Music.cancel_duck()  # the vote ended early (everyone locked): no ducked round intro
	if ctx == "title":
		_play(TITLE_TRACK)
	elif ctx == "lobby":
		_play(LOBBY_TRACK)
	elif ctx.begins_with("vote:"):
		_beeped = -1
		_play(LOBBY_TRACK)
		if output_enabled:
			Music.duck(VOTE_DUCK, maxf(Session.phase_duration, 1.0))
	elif ctx == "podium":
		_play(PODIUM_TRACK)
		if output_enabled:
			Music.duck(podium_duck, podium_duck_time)
	elif ctx.ends_with(":quiet"):
		_play(&"", SILENCE_FADE)
	elif ctx.begins_with("round:"):
		_play(intro_track_for_minigame(Session.current_minigame))
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
	if state == Session.State.VOTE:
		return "vote:%d" % Session.vote_index
	return "lobby"


## VOTE: one beep per whole second in the last VOTE_BEEPS, until the votes are tallied.
func _tick_vote() -> void:
	if Session.state != Session.State.VOTE or Session.vote_winner >= 0:
		return
	var left := ceili(Session.phase_time_left)
	if left < 1 or left > VOTE_BEEPS or left == _beeped:
		return
	_beeped = left
	vote_beep.emit(left)
	if output_enabled:
		Sfx.play(&"countdown_beep", Vector3.INF, 0.0, 1.0 + 0.06 * float(VOTE_BEEPS - left))


## The round music of `minigame` once play starts: its `music_track` (&"none" = silence) if
## set, else by the preset of its StageLook, else DEFAULT_ROUND_TRACK.
static func track_for_minigame(minigame: Node) -> StringName:
	if minigame == null or not is_instance_valid(minigame):
		return DEFAULT_ROUND_TRACK
	var override: Variant = minigame.get(&"music_track")
	if override != null and str(override) != "":
		var t := StringName(str(override))
		return &"" if t == &"none" else t
	return preset_track(minigame)


## The music under the title card (INTRO): the round track, except that a silent round
## (`music_track = &"none"`) gets its preset's track until GO.
static func intro_track_for_minigame(minigame: Node) -> StringName:
	var t := track_for_minigame(minigame)
	return t if t != &"" else preset_track(minigame)


## The track of `minigame`'s StageLook preset (DEFAULT_ROUND_TRACK without one).
static func preset_track(minigame: Node) -> StringName:
	if minigame == null or not is_instance_valid(minigame):
		return DEFAULT_ROUND_TRACK
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


func _play(track: StringName, fade: float = -1.0) -> void:
	track_requested.emit(track)
	if not output_enabled:
		return
	var f := fade_time if fade < 0.0 else fade
	if track == &"":
		Music.stop(f)
	else:
		Music.play(track, f)
