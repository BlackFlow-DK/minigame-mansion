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
	Session.state = Session.State.LOBBY
	Session.vote_index = -1
	Session.vote_winner = -1
	Session.phase_duration = 0.0
	Session.phase_time_left = 0.0
	Session.set_physics_process(true)
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
	assert_eq(MusicDirector.intro_track_for_minigame(_minigame(StageLook.Preset.LAVA_CAVE, "none")), &"lava_drums", "none: the preset under the title card")
	assert_eq(MusicDirector.intro_track_for_minigame(_minigame(StageLook.Preset.LAVA_CAVE, "night_party")), &"night_party", "an override plays from the intro")
	Net.start_offline()
	_spawn_director()
	_enter_round(0, _minigame(StageLook.Preset.BRIGHT_DAY, "none"))
	assert_eq(_picked().back(), &"sky_sumo", "intro: the look's track")
	Session.state_changed.emit(Session.State.PLAYING)
	assert_eq(_picked().back(), &"", "GO: director asks for silence")
	assert_eq(Music.current, &"", "music stopped for the round")


## Any minigame may declare `music_track = &"none"`: the title card still has music (the look's
## track, so the intro is never silent), and the round is silent from GO.
func test_a_declared_silent_round_is_silent_from_go() -> void:
	var mg := _minigame(StageLook.Preset.NIGHT_PARTY, "none")
	Net.start_offline()
	_spawn_director()
	assert_eq(Music.current, &"lobby_waltz", "lobby music first")
	_enter_round(0, mg)
	assert_eq(Music.current, &"night_party", "the intro card is not silent")
	assert_eq(_director.context, "round:0", "intro context")
	Session.state_changed.emit(Session.State.PLAYING)
	assert_eq(_director.context, "round:0:quiet", "silent from GO")
	assert_eq(Music.current, &"", "silent while playing")
	var picks := _picks.size()
	Session.state_changed.emit(Session.State.PLAYING)
	assert_eq(_picks.size(), picks, "no new pick while it stays PLAYING")
	Session.state_changed.emit(Session.State.RESULTS)
	assert_eq(_director.context, "results:0", "results as usual")


## VOTE (game modes): the lobby waltz ducked under the cards and a beep on each of the last
## three seconds, until the tally; then the round's own music.
func test_vote_ducks_the_waltz_and_beeps_the_last_seconds() -> void:
	Net.start_offline()
	Session.set_physics_process(false)  # this test drives the vote clock itself
	_spawn_director()
	var beeps := watch(_director, &"vote_beep")
	Music.play(&"lava_drums", 0.0)  # what the results left playing
	Session.vote_index = 1
	Session.vote_winner = -1
	Session.phase_duration = 8.0
	Session.phase_time_left = 8.0
	Session.state = Session.State.VOTE
	Session.state_changed.emit(Session.State.VOTE)
	assert_eq(_director.context, "vote:1", "vote context")
	assert_eq(Music.current, &"lobby_waltz", "the waltz, not the round's music")
	await step(30)
	assert_true(Music.duck_gain < 0.8, "ducked under the cards (%.2f)" % Music.duck_gain)
	assert_eq(beeps.size(), 0, "no beeps with 8 s left")
	for left: float in [3.5, 2.9, 2.2, 1.5, 0.6, 0.2]:
		Session.phase_time_left = left
		await step(1)
	var secs: Array = []
	for b in beeps:
		secs.append(b[0])
	assert_eq(secs, [3, 2, 1], "one beep on each of the last three seconds")
	Session.vote_winner = 0  # tallied: the reveal does not beep
	Session.phase_time_left = 1.5
	await step(2)
	assert_eq(beeps.size(), 3, "no beeps after the tally")
	_enter_round(1, _minigame(StageLook.Preset.LAVA_CAVE))
	assert_eq(Music.current, &"lava_drums", "the next round's music")
	assert_eq(Music.duck_gain, 1.0, "the vote's duck ends with it")


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
