extends GameTest
## Music director (game/audio/music_director.gd): which track plays for each app/Session
## state. Drives `Session.state_changed` and `Net` itself; Session's own state stays LOBBY.

const MusicDirector := preload("res://audio/music_director.gd")

var _director: Node = null
var _picks: Array = []
var _minigames: Array[Node] = []


func before_each() -> void:
	Music.stop(0.0)
	Music.cancel_duck()


func after_each() -> void:
	# free() (not queue_free): the harness calls Net.leave() right after this.
	if is_instance_valid(_director):
		_director.free()
	for mg in _minigames:
		if is_instance_valid(mg):
			mg.free()
	_minigames.clear()
	Session.current_minigame = null
	Session.round_index = -1
	Music.stop(0.0)
	Music.cancel_duck()


func _spawn_director() -> void:
	_director = MusicDirector.new()
	_picks = watch(_director, &"track_requested")
	add_child(_director)


func _picked() -> Array[StringName]:
	var out: Array[StringName] = []
	for e: Array in _picks:
		out.append(e[0])
	return out


## A bare minigame with a StageLook child at `preset`, optionally with a `music_track`.
func _minigame(preset: int, music_track: String = "") -> Minigame:
	var mg: Minigame
	if music_track != "":
		var script := GDScript.new()
		script.source_code = "extends Minigame\nvar music_track: StringName = &\"%s\"\n" % music_track
		script.reload()
		mg = script.new() as Minigame
	else:
		mg = Minigame.new()
	var look := StageLook.new()
	look.preset = preset as StageLook.Preset
	mg.add_child(look)
	_minigames.append(mg)
	return mg


func _enter_round(index: int, mg: Minigame) -> void:
	Session.round_index = index
	Session.current_minigame = mg
	Session.state_changed.emit(Session.State.INTRO)


func test_title_then_lobby() -> void:
	Net.leave()
	_spawn_director()
	assert_eq(_director.context, "title", "not in a game: title")
	assert_eq(Music.current, &"title_theme", "title_theme")
	Net.start_offline()
	assert_eq(_director.context, "lobby", "offline game: lobby")
	assert_eq(Music.current, &"lobby_waltz", "lobby_waltz")
	Net.leave()
	assert_eq(Music.current, &"title_theme", "left: title again")


func test_round_track_follows_the_look_preset() -> void:
	var expected := {
		StageLook.Preset.LAVA_CAVE: &"lava_drums",
		StageLook.Preset.BRIGHT_DAY: &"sky_sumo",
		StageLook.Preset.NIGHT_PARTY: &"night_party",
		StageLook.Preset.WARM_HALL: &"vault_jazz",
	}
	for preset: int in expected:
		assert_eq(MusicDirector.track_for_minigame(_minigame(preset)), expected[preset], "preset %d" % preset)
	assert_eq(MusicDirector.track_for_minigame(null), &"vault_jazz", "no minigame: fallback")
	var bare := Node3D.new()
	_minigames.append(bare)
	assert_eq(MusicDirector.track_for_minigame(bare), &"vault_jazz", "no StageLook: fallback")


func test_music_track_override_and_none() -> void:
	assert_eq(MusicDirector.track_for_minigame(_minigame(StageLook.Preset.LAVA_CAVE, "night_party")), &"night_party", "override wins")
	assert_eq(MusicDirector.track_for_minigame(_minigame(StageLook.Preset.LAVA_CAVE, "none")), &"", "none = silence")
	Net.start_offline()
	_spawn_director()
	_enter_round(0, _minigame(StageLook.Preset.BRIGHT_DAY, "none"))
	assert_eq(_picked().back(), &"", "director asks for silence")
	assert_eq(Music.current, &"", "music stopped for the round")


## Any minigame may declare `music_track = &"none"`: its round is silent through intro and play.
func test_a_declared_silent_round_is_silent() -> void:
	var mg := _minigame(StageLook.Preset.NIGHT_PARTY, "none")
	Net.start_offline()
	_spawn_director()
	assert_eq(Music.current, &"lobby_waltz", "lobby music first")
	_enter_round(0, mg)
	assert_eq(_picked().back(), &"", "director asks for silence")
	assert_eq(Music.current, &"", "no night_party under a silent round")
	Session.state_changed.emit(Session.State.PLAYING)
	assert_eq(Music.current, &"", "still silent while playing")


## The rule, for every registry minigame: silent exactly when it declares `music_track = &"none"`,
## else a track that exists (its own or the preset's).
func test_every_registry_minigame_gets_a_round_track() -> void:
	for id: StringName in MinigameRegistry.IDS:
		var scene := load(MinigameRegistry.scene_path(id)) as PackedScene
		if not assert_true(scene != null, "%s loads" % id):
			continue
		var mg := scene.instantiate()
		_minigames.append(mg)
		var track := MusicDirector.track_for_minigame(mg)
		var declared: Variant = mg.get(&"music_track")
		if declared != null and StringName(str(declared)) == &"none":
			assert_eq(track, &"", "%s declares none: director silent" % id)
		else:
			assert_true(Music.has_track(track), "%s -> %s exists" % [id, track])


func test_full_session_flow() -> void:
	Net.start_offline()
	_spawn_director()
	assert_eq(Music.current, &"lobby_waltz", "lobby")
	var stings := watch(Music, &"sting_played")

	_enter_round(0, _minigame(StageLook.Preset.LAVA_CAVE))
	assert_eq(Music.current, &"lava_drums", "round 1 intro: lava")
	var picks_before := _picks.size()
	Session.state_changed.emit(Session.State.PLAYING)
	assert_eq(_picks.size(), picks_before, "INTRO -> PLAYING of the same round: no new pick")

	# A minigame taking over (Spotlight Chairs) is left alone until the next phase.
	Music.stop(0.0)
	Session.state_changed.emit(Session.State.PLAYING)
	assert_eq(Music.current, &"", "minigame's own Music.stop() is respected")

	Music.play(&"lava_drums", 0.0)
	Session.state_changed.emit(Session.State.RESULTS)
	assert_eq(stings.size(), 1, "results sting")
	assert_eq(stings[0][0], &"results_sting", "the results sting")
	assert_eq(Music.current, &"lava_drums", "round music keeps going under the sting")
	await step(30)
	assert_true(Music.duck_gain < 0.5, "ducked under the sting (%.2f)" % Music.duck_gain)

	_enter_round(1, _minigame(StageLook.Preset.NIGHT_PARTY))
	assert_eq(Music.current, &"night_party", "round 2: night party")
	Session.state_changed.emit(Session.State.PLAYING)
	Session.state_changed.emit(Session.State.RESULTS)
	assert_eq(stings.size(), 2, "second sting")

	Session.state_changed.emit(Session.State.PODIUM)
	assert_eq(Music.current, &"podium_theme", "podium")
	Session.state_changed.emit(Session.State.LOBBY)
	assert_eq(Music.current, &"lobby_waltz", "back to the lobby waltz")
	var expected: Array[StringName] = [&"lobby_waltz", &"lava_drums", &"results_sting", &"night_party", &"results_sting", &"podium_theme", &"lobby_waltz"]
	assert_eq(_picked(), expected, "pick order")
