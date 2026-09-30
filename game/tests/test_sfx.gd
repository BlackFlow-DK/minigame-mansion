extends GameTest
## Sfx autoload: files, playback headless, polyphony, loops, buses, UI hooks.

## name -> [min_sec, max_sec] (mirrors art/scripts/audio/gen_sfx.py SPECS).
const FILES := {
	"jump": [0.1, 0.4], "land_soft": [0.08, 0.3], "land_hard": [0.2, 0.5],
	"step_a": [0.04, 0.12], "step_b": [0.04, 0.12], "step_c": [0.04, 0.12],
	"shove_whoosh": [0.15, 0.5], "hit_bonk": [0.15, 0.4], "stun_wobble": [0.5, 1.2],
	"eliminated_pop": [0.2, 0.5], "respawn": [0.3, 0.8], "coin": [0.15, 0.4],
	"coin_big": [0.4, 0.9], "bomb_tick": [0.04, 0.15], "bomb_fuse_loop": [0.5, 2.0],
	"explosion": [0.8, 1.6], "platform_crack": [0.2, 0.6], "platform_fall": [0.5, 1.2],
	"lava_sizzle": [0.5, 1.2], "countdown_beep": [0.1, 0.3], "countdown_go": [0.3, 0.8],
	"round_win_jingle": [0.8, 1.6], "round_end": [0.4, 1.0], "podium_fanfare": [2.0, 3.0],
	"ui_move": [0.03, 0.1], "ui_click": [0.05, 0.15], "ui_back": [0.05, 0.2],
	"join_chime": [0.3, 0.8], "leave_chime": [0.3, 0.8], "portal_hum_loop": [1.0, 4.0],
	"piano_c": [1.0, 2.0], "piano_d": [1.0, 2.0], "piano_e": [1.0, 2.0], "piano_f": [1.0, 2.0],
	"piano_g": [1.0, 2.0], "piano_a": [1.0, 2.0], "piano_b": [1.0, 2.0],
}

var _saved_sounds: Dictionary = {}


func before_each() -> void:
	_saved_sounds = Sfx.sounds.duplicate(true)


func after_each() -> void:
	Sfx.sounds.assign(_saved_sounds)


func test_every_file_exists_imports_and_has_plausible_length() -> void:
	for sound: String in FILES:
		var path := "res://audio/sfx/%s.wav" % sound
		if not assert_true(ResourceLoader.exists(path), "%s exists" % path):
			continue
		assert_true(FileAccess.file_exists(path + ".import"), "%s has an .import file" % path)
		var stream := load(path) as AudioStreamWAV
		if not assert_true(stream != null, "%s loads as AudioStreamWAV" % path):
			continue
		var len_s := stream.get_length()
		var range_s: Array = FILES[sound]
		assert_true(len_s >= range_s[0] and len_s <= range_s[1],
			"%s length %.3f s within %s" % [sound, len_s, str(range_s)])
		var loops := sound.ends_with("_loop")
		assert_eq(stream.loop_mode == AudioStreamWAV.LOOP_FORWARD, loops, "%s loop mode" % sound)


func test_every_file_has_a_table_entry() -> void:
	for sound: String in FILES:
		assert_true(Sfx.has_sound(StringName(sound)), "table entry for %s" % sound)
	assert_true(Sfx.has_sound(&"step"), "step alias")
	for sound in Sfx.sound_names():
		assert_true(Sfx.has_sound(sound), "table entry %s has a file" % sound)


func test_play_every_sound_headless() -> void:
	for sound in Sfx.sounds:
		Sfx.sounds[sound]["gap"] = 0
	var played := watch(Sfx, &"played")
	var names: Array[StringName] = []
	for sound in Sfx.sound_names():
		if not String(sound).ends_with("_loop"):
			names.append(sound)
	Sfx.play(&"portal_hum_loop")  # loops are refused by play() (warns once): use play_loop
	for sound in names:
		Sfx.play(sound)
		Sfx.play(sound, Vector3(1.0, 0.0, 2.0))
	Sfx.play(&"no_such_sound")
	Sfx.play(&"no_such_sound", Vector3.ZERO)
	await step(5)
	assert_eq(played.size(), names.size() * 2, "every known sound played twice")
	for e: Array in played:
		assert_true(e[0] != &"no_such_sound", "unknown sound does not play")


func test_polyphony_limit_holds() -> void:
	Sfx.stop_all()
	Sfx.sounds[&"hit_bonk"]["gap"] = 0
	var limit: int = Sfx.sounds[&"hit_bonk"]["max"]
	for i in 30:
		Sfx.play(&"hit_bonk", Vector3(i, 0.0, 0.0))
	assert_true(Sfx.voice_count(&"hit_bonk") <= limit, "at most %d bonks at once" % limit)
	assert_eq(Sfx.voice_count(&"hit_bonk"), limit, "limit reached, not exceeded")
	for i in 60:
		Sfx.play(&"hit_bonk")
	assert_true(Sfx.voice_count(&"hit_bonk") <= limit * 2, "2D and 3D pools each respect the limit")


func test_min_gap_drops_stacked_starts() -> void:
	Sfx.stop_all()
	Sfx.sounds[&"coin"]["gap"] = 5000
	var played := watch(Sfx, &"played")
	for i in 8:
		Sfx.play(&"coin", Vector3(i, 0.0, 0.0))
	assert_eq(played.size(), 1, "8 simultaneous coins -> one voice")


func test_loop_play_move_stop() -> void:
	var id := Sfx.play_loop(&"bomb_fuse_loop", Vector3(1.0, 0.0, 1.0))
	assert_true(id > 0, "loop id")
	assert_true(Sfx.is_loop_playing(id), "loop playing")
	Sfx.move_loop(id, Vector3(3.0, 0.0, 0.0))
	var id2 := Sfx.play_loop(&"portal_hum_loop")
	assert_true(id2 > 0 and id2 != id, "second loop id")
	Sfx.stop_loop(id)
	Sfx.stop_loop(id2)
	Sfx.stop_loop(id)  # twice: ignored
	assert_false(Sfx.is_loop_playing(id), "stopped")
	await step(30)
	assert_true(Sfx.get_node_or_null(NodePath("Loop_%d" % id)) == null, "loop player freed")
	assert_eq(Sfx.play_loop(&"no_such_loop"), -1, "unknown loop -> -1")
	var id3 := Sfx.play_loop(&"portal_hum_loop")
	Sfx.stop_all()
	assert_false(Sfx.is_loop_playing(id3), "stop_all stops loops")
	assert_eq(Sfx.voice_count(&"jump"), 0, "stop_all clears voices")


func test_buses_and_volume() -> void:
	assert_true(AudioServer.get_bus_index(&"Sfx") >= 0, "Sfx bus")
	assert_true(AudioServer.get_bus_index(&"Ui") >= 0, "Ui bus")
	Sfx.set_volume(&"Sfx", 0.5)
	assert_near(Sfx.get_volume(&"Sfx"), 0.5, 0.01, "Sfx at half")
	Sfx.set_volume(&"Ui", 0.0)
	assert_eq(Sfx.get_volume(&"Ui"), 0.0, "Ui muted")
	Sfx.set_volume(&"Sfx", 1.0)
	Sfx.set_volume(&"Ui", 1.0)
	assert_near(Sfx.get_volume(&"Ui"), 1.0, 0.01, "Ui restored")


func test_attach_ui_hooks_buttons() -> void:
	for sound: StringName in [&"ui_move", &"ui_click", &"ui_back"]:
		Sfx.sounds[sound]["gap"] = 0
	var root := VBoxContainer.new()
	var play := Button.new()
	play.text = "Play"
	var back := Button.new()
	back.name = "BackButton"
	var silent := Button.new()
	silent.set_meta(&"sfx_press", &"")
	root.add_child(play)
	root.add_child(back)
	root.add_child(silent)
	add_child(root)
	Sfx.attach_ui(root)
	Sfx.attach_ui(root)  # twice: no double sounds
	var played := watch(Sfx, &"played")
	play.focus_entered.emit()
	play.pressed.emit()
	back.pressed.emit()
	silent.pressed.emit()
	var late := Button.new()
	late.text = "Late"
	root.add_child(late)
	late.pressed.emit()
	var got: Array[StringName] = []
	for e: Array in played:
		got.append(e[0])
	assert_eq(got, [&"ui_move", &"ui_click", &"ui_back", &"ui_click"] as Array[StringName], "ui sounds")
	root.queue_free()
