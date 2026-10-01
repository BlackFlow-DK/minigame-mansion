extends Node
## Autoload `Music`: background music. Owner: audio.
##
## `play(track, fade)` cross-fades from whatever plays to `track` (two decks, equal-power);
## playing the track that already plays does nothing. `stop(fade)` fades out.
## `play_sting(track)` plays a one-shot (the results flourish) on its own player on top of the
## music, which keeps playing. `duck(amount, seconds)` lowers the music by `amount` (0..1 of
## its volume) for `seconds`, then lets it back up; a sting or fanfare sits above it.
## `set_volume(linear)` / `get_volume()` set the `Music` bus (created from code when the
## project has none, like Sfx's buses).
##
## Tracks: res://audio/music/<track>.ogg (art/scripts/audio/gen_music.py). Loops loop through
## their .import settings. Which track plays when: game/audio/music_director.gd.
##
## Works headless: fades, ducking, `current` and the signals all run; only the actual play()
## is skipped (a stream still playing at quit is reported as a leaked resource).

## A different track (or &"" after stop()) was asked for.
signal track_changed(track: StringName)
## A sting started.
signal sting_played(track: StringName)

const MUSIC_DIR := "res://audio/music/"
const BUS := &"Music"
const TRACKS: Array[StringName] = [
	&"title_theme", &"lobby_waltz", &"lava_drums", &"sky_sumo", &"night_party",
	&"vault_jazz", &"podium_theme", &"results_sting",
]
## Bus volume (linear) when this autoload creates the bus.
const DEFAULT_VOLUME := 0.6
const SILENT_DB := -80.0

## Seconds the ducking takes to go down / to come back up.
@export var duck_attack: float = 0.25
@export var duck_release: float = 0.9

## The track playing (or fading in); &"" when stopped.
var current: StringName = &""
## Current duck multiplier (1 = not ducked).
var duck_gain: float = 1.0

var _decks: Array[AudioStreamPlayer] = []
var _deck_track: Array[StringName] = [&"", &""]
var _gain: Array[float] = [0.0, 0.0]
var _target: Array[float] = [0.0, 0.0]
var _rate: Array[float] = [1.0, 1.0]
var _active: int = 0
var _sting: AudioStreamPlayer
var _duck_amount: float = 0.0
var _duck_left: float = 0.0
var _streams: Dictionary[StringName, AudioStream] = {}
var _warned: Dictionary[StringName, bool] = {}
var _audible: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_audible = DisplayServer.get_name() != "headless"
	_ensure_bus()
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.name = "Deck%d" % i
		p.bus = BUS
		p.volume_db = SILENT_DB
		add_child(p)
		_decks.append(p)
	_sting = AudioStreamPlayer.new()
	_sting.name = "Sting"
	_sting.bus = BUS
	add_child(_sting)


## Release every stream on quit, so the audio server holds nothing when leaks are checked.
func _exit_tree() -> void:
	for p: AudioStreamPlayer in _decks + [_sting]:
		p.stop()
		p.stream = null
	_streams.clear()


func _process(delta: float) -> void:
	for i in 2:
		_gain[i] = move_toward(_gain[i], _target[i], _rate[i] * delta)
		if _gain[i] <= 0.0 and _target[i] <= 0.0 and _deck_track[i] != &"":
			_decks[i].stop()
			_deck_track[i] = &""
	var want := 1.0
	if _duck_left > 0.0:
		_duck_left -= delta
		want = 1.0 - _duck_amount
	else:
		_duck_amount = 0.0
	var speed := 1.0 / maxf(duck_attack if want < duck_gain else duck_release, 0.001)
	duck_gain = move_toward(duck_gain, want, speed * delta)
	_apply_volumes()


# --- API -------------------------------------------------------------------------------------

## Cross-fades to `track` over `fade` seconds (0 = cut). Same track as now: nothing happens.
## &"" stops. Unknown tracks warn once and leave the music as it is.
func play(track: StringName, fade: float = 1.0) -> void:
	if track == &"":
		stop(fade)
		return
	if track == current:
		return
	var rate := 1.0 / maxf(fade, 0.001)
	var other := 1 - _active
	if _deck_track[_active] == track:
		pass  # stopped a moment ago and still fading out: fade it back in
	elif _deck_track[other] == track:
		# Coming back to the track that is still fading out: fade it back in, no restart.
		_active = other
	else:
		var stream := _stream(track)
		if stream == null:
			return
		_active = other
		var p := _decks[_active]
		p.stop()
		p.stream = stream
		_gain[_active] = 0.0 if fade > 0.0 else 1.0
		_deck_track[_active] = track
		if _audible:
			p.play()
	_target[_active] = 1.0
	_rate[_active] = rate
	_target[1 - _active] = 0.0
	_rate[1 - _active] = rate
	if fade <= 0.0:
		_gain[1 - _active] = 0.0
	current = track
	_apply_volumes()
	track_changed.emit(track)


## Fades the music out over `fade` seconds (0 = at once).
func stop(fade: float = 1.0) -> void:
	var rate := 1.0 / maxf(fade, 0.001)
	for i in 2:
		_target[i] = 0.0
		_rate[i] = rate
		if fade <= 0.0:
			_gain[i] = 0.0
	if current != &"":
		current = &""
		track_changed.emit(&"")
	_apply_volumes()


## Plays a one-shot track (e.g. `results_sting`) over the music, not ducked.
func play_sting(track: StringName) -> void:
	var stream := _stream(track)
	if stream == null:
		return
	_sting.stop()
	_sting.stream = stream
	_sting.volume_db = 0.0
	if _audible:
		_sting.play()
	sting_played.emit(track)


## Lowers the music by `amount` (0..1 of its volume) for `seconds`, then lets it back up.
## Overlapping ducks keep the deeper amount and the later end.
func duck(amount: float, seconds: float) -> void:
	amount = clampf(amount, 0.0, 1.0)
	if _duck_left > 0.0:
		_duck_amount = maxf(_duck_amount, amount)
		_duck_left = maxf(_duck_left, seconds)
	else:
		_duck_amount = amount
		_duck_left = seconds


## Ends any duck at once (leaving a game, tests).
func cancel_duck() -> void:
	_duck_left = 0.0
	_duck_amount = 0.0
	duck_gain = 1.0
	_apply_volumes()


func is_playing() -> bool:
	return current != &""


func has_track(track: StringName) -> bool:
	return ResourceLoader.exists(MUSIC_DIR + String(track) + ".ogg")


## Sets the Music bus volume from a linear 0..1 slider value (0 mutes).
func set_volume(linear: float) -> void:
	var idx := AudioServer.get_bus_index(BUS)
	if idx < 0:
		return
	linear = clampf(linear, 0.0, 1.0)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(idx, linear <= 0.0)


## Linear 0..1 volume of the Music bus (0 when muted).
func get_volume() -> float:
	var idx := AudioServer.get_bus_index(BUS)
	if idx < 0 or AudioServer.is_bus_mute(idx):
		return 0.0
	return clampf(db_to_linear(AudioServer.get_bus_volume_db(idx)), 0.0, 1.0)


## Fade gains of the two decks, the active one first (tests / debug).
func deck_gains() -> Array[float]:
	return [_gain[_active], _gain[1 - _active]]


# --- Internals ---------------------------------------------------------------------------------

func _apply_volumes() -> void:
	for i in 2:
		# Equal-power curve: the sum of two uncorrelated decks stays level mid-fade.
		var amp := sin(clampf(_gain[i], 0.0, 1.0) * PI * 0.5) * duck_gain
		_decks[i].volume_db = linear_to_db(amp) if amp > 0.0001 else SILENT_DB


func _stream(track: StringName) -> AudioStream:
	if not _streams.has(track):
		var path := MUSIC_DIR + String(track) + ".ogg"
		var loaded := load(path) as AudioStream if ResourceLoader.exists(path) else null
		if loaded == null:
			if not _warned.has(track):
				_warned[track] = true
				push_warning("Music: unknown track '%s'" % track)
			return null
		# A path-less copy (see Sfx._pick_stream): a cached resource still playing at quit
		# turns into an "ERROR: resources still in use" line.
		_streams[track] = loaded.duplicate() as AudioStream
	return _streams[track]


func _ensure_bus() -> void:
	if AudioServer.get_bus_index(BUS) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, BUS)
	AudioServer.set_bus_send(idx, &"Master")
	AudioServer.set_bus_volume_db(idx, linear_to_db(DEFAULT_VOLUME))
