extends GameTest
## Music autoload (game/audio/music.gd): files, cross-fades, ducking, stings, volume. Headless.

## track -> [seconds, loops] (.ogg; mirrors art/scripts/audio/gen_music.py SONGS: bars * beats * 60 / bpm).
const FILES := {
	"title_theme": [16 * 4 * 60.0 / 70.0, true],
	"lobby_waltz": [24 * 3 * 60.0 / 90.0, true],
	"lava_drums": [16 * 4 * 60.0 / 120.0, true],
	"sky_sumo": [16 * 4 * 60.0 / 128.0, true],
	"night_party": [16 * 4 * 60.0 / 110.0, true],
	"vault_jazz": [16 * 4 * 60.0 / 115.0, true],
	"podium_theme": [8.0, true],
	"results_sting": [4.0, false],
}

var _saved_volume: float = 1.0


func before_each() -> void:
	_saved_volume = Music.get_volume()
	Music.stop(0.0)
	Music.cancel_duck()


func after_each() -> void:
	Music.stop(0.0)
	Music.cancel_duck()
	Music.set_volume(_saved_volume)


func test_every_track_exists_imports_and_has_its_length_and_loop_mode() -> void:
	assert_eq(Music.TRACKS.size(), FILES.size(), "TRACKS lists every file")
	for track: String in FILES:
		var path := "res://audio/music/%s.ogg" % track
		if not assert_true(ResourceLoader.exists(path), "%s exists" % path):
			continue
		assert_true(FileAccess.file_exists(path + ".import"), "%s has an .import file" % path)
		assert_true(Music.TRACKS.has(StringName(track)), "%s in Music.TRACKS" % track)
		var stream := load(path) as AudioStreamOggVorbis
		if not assert_true(stream != null, "%s loads as AudioStreamOggVorbis" % path):
			continue
		assert_near(stream.get_length(), float(FILES[track][0]), 0.01, "%s length" % track)
		assert_eq(stream.loop, bool(FILES[track][1]), "%s loop flag" % track)
		assert_near(stream.loop_offset, 0.0, 0.0001, "%s loop offset" % track)


func test_music_bus_exists_and_volume_round_trips() -> void:
	assert_true(AudioServer.get_bus_index(Music.BUS) >= 0, "Music bus created")
	Music.set_volume(0.5)
	assert_near(Music.get_volume(), 0.5, 0.01, "set_volume(0.5)")
	Music.set_volume(0.0)
	assert_eq(Music.get_volume(), 0.0, "0 mutes")


func test_play_crossfades_between_decks() -> void:
	var changes := watch(Music, &"track_changed")
	Music.play(&"lobby_waltz", 0.5)
	assert_eq(Music.current, &"lobby_waltz", "current")
	assert_true(Music.is_playing(), "playing")
	assert_near(Music.deck_gains()[0], 0.0, 0.001, "starts silent")
	await step(15)
	assert_near(Music.deck_gains()[0], 0.5, 0.05, "half way after 0.25 s")
	await step(20)
	assert_near(Music.deck_gains()[0], 1.0, 0.001, "full after the fade")
	Music.play(&"lobby_waltz", 0.5)
	assert_eq(changes.size(), 1, "same track again: no restart")
	Music.play(&"night_party", 0.5)
	await step(15)
	var g := Music.deck_gains()
	assert_near(g[0], 0.5, 0.05, "new deck half up")
	assert_near(g[1], 0.5, 0.05, "old deck half down")
	await step(20)
	g = Music.deck_gains()
	assert_near(g[0], 1.0, 0.001, "new deck full")
	assert_near(g[1], 0.0, 0.001, "old deck silent")
	Music.stop(0.25)
	assert_eq(Music.current, &"", "stopped")
	await step(20)
	g = Music.deck_gains()
	assert_near(g[0] + g[1], 0.0, 0.001, "faded out")
	assert_eq(changes.size(), 3, "lobby, night_party, stop")


func test_quick_back_and_forth_reuses_the_fading_deck() -> void:
	Music.play(&"sky_sumo", 0.0)
	Music.play(&"lava_drums", 1.0)
	await step(10)
	Music.play(&"sky_sumo", 1.0)
	assert_eq(Music.current, &"sky_sumo", "back to sky_sumo")
	var g := Music.deck_gains()
	assert_true(g[0] > 0.7, "sky_sumo deck was still loud, fades back up from there (%.2f)" % g[0])


func test_duck_lowers_then_recovers() -> void:
	Music.play(&"vault_jazz", 0.0)
	Music.duck(0.6, 0.5)
	await step(20)
	assert_near(Music.duck_gain, 0.4, 0.02, "ducked to 40%")
	Music.duck(0.3, 0.1)
	assert_near(Music.duck_gain, 0.4, 0.02, "a shallower duck does not lift an active one")
	await step(100)
	assert_near(Music.duck_gain, 1.0, 0.001, "back up after the duck")


func test_sting_plays_over_the_music_and_unknown_tracks_are_ignored() -> void:
	var stings := watch(Music, &"sting_played")
	Music.play(&"vault_jazz", 0.0)
	Music.play_sting(&"results_sting")
	assert_eq(stings.size(), 1, "sting played")
	assert_eq(Music.current, &"vault_jazz", "the loop keeps playing under the sting")
	Music.play(&"no_such_track")
	assert_eq(Music.current, &"vault_jazz", "unknown track leaves the music alone")
	assert_false(Music.has_track(&"no_such_track"), "has_track false")
	assert_true(Music.has_track(&"podium_theme"), "has_track true")
