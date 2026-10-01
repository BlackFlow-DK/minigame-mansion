extends GameTest
## Settings autoload and screen: values persist in a JSON file and come back, broken or odd
## values fall back to defaults, volumes map onto the audio buses (Master / Music / Sfx / Ui;
## Music is created when missing), applying at startup sets buses, quality and the FPS overlay,
## the comfort flags other systems read, and the screen's controls write the settings live.

const TEST_PATH := "user://test_settings.json"
const SCREEN_PATH := "res://ui/settings/settings.tscn"

var _saved: Dictionary = {}
var _saved_db: Dictionary = {}
var _saved_mute: Dictionary = {}
var _saved_quality: int = 0


func before_each() -> void:
	_saved = Settings.to_dict()
	for bus: StringName in [&"Master", &"Music", &"Sfx", &"Ui"]:
		var i := AudioServer.get_bus_index(bus)
		if i >= 0:
			_saved_db[bus] = AudioServer.get_bus_volume_db(i)
			_saved_mute[bus] = AudioServer.is_bus_mute(i)
	_saved_quality = Look.get_quality()
	Settings.path = TEST_PATH
	Settings.persist = false
	_remove()


func after_each() -> void:
	for key: String in _saved:
		Settings.set(StringName(key), _saved[key])
	for bus: StringName in _saved_db:
		var i := AudioServer.get_bus_index(bus)
		if i >= 0:
			AudioServer.set_bus_volume_db(i, _saved_db[bus])
			AudioServer.set_bus_mute(i, _saved_mute[bus])
	Look.set_quality(_saved_quality as Look.Quality)
	Settings.show_fps = false
	Settings.set_value(&"show_fps", false, false)
	Settings.path = Settings.PATH
	Settings.persist = false
	_remove()


func _remove() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(TEST_PATH)


func _bus_linear(bus: StringName) -> float:
	var i := AudioServer.get_bus_index(bus)
	if i < 0 or AudioServer.is_bus_mute(i):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(i))


# --- Autoload ------------------------------------------------------------------------------------

func test_settings_persist_and_come_back() -> void:
	Settings.persist = true
	Settings.reset_to_defaults()
	assert_true(FileAccess.file_exists(TEST_PATH), "saved to the file")
	Settings.set_value(&"music_volume", 0.25)
	Settings.set_value(&"sfx_volume", 0.4)
	Settings.set_value(&"quality", "low")
	Settings.set_value(&"window_size", "1600x900")
	Settings.set_value(&"screen_shake", false)
	Settings.set_value(&"reduced_motion", true)
	Settings.set_value(&"show_fps", true)
	var written := Settings.to_dict()
	# Forget everything in memory, then load the file.
	for key: StringName in Settings.KEYS:
		Settings.set(key, Settings.DEFAULTS[key])
	Settings.load_settings()
	assert_eq(Settings.to_dict(), written, "every value came back")
	assert_near(Settings.music_volume, 0.25, 0.0001, "music volume")
	assert_eq(Settings.quality, "low", "quality")
	assert_false(Settings.screen_shake, "screen shake off")
	assert_true(Settings.reduced_motion, "reduced motion on")


func test_odd_values_and_broken_files_fall_back() -> void:
	Settings.set_value(&"master_volume", 7.0, false)
	assert_near(Settings.master_volume, 1.0, 0.0001, "volume clamped to 1")
	Settings.set_value(&"window_size", "640x480", false)
	assert_eq(Settings.window_size, Settings.DEFAULTS[&"window_size"], "unknown size: default")
	Settings.set_value(&"quality", "ultra", false)
	assert_eq(Settings.quality, "high", "unknown quality: default")
	var f := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string("{ not json")
	f.close()
	Settings.load_settings()
	assert_eq(Settings.to_dict(), _defaults(), "a broken file gives defaults")
	f = FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"sfx_volume": "loud", "show_fps": true, "nonsense": 3}))
	f.close()
	Settings.load_settings()
	assert_near(Settings.sfx_volume, 1.0, 0.0001, "a bad value: default")
	assert_true(Settings.show_fps, "good values are kept")


func _defaults() -> Dictionary:
	var out := {}
	for key: StringName in Settings.KEYS:
		out[String(key)] = Settings.DEFAULTS[key]
	return out


func test_volumes_map_to_buses() -> void:
	var pairs := {&"master_volume": &"Master", &"music_volume": &"Music", &"sfx_volume": &"Sfx", &"ui_volume": &"Ui"}
	for key: StringName in pairs:
		Settings.set_value(key, 0.5, false)
		assert_true(AudioServer.get_bus_index(pairs[key]) >= 0, "bus %s exists" % pairs[key])
		assert_near(_bus_linear(pairs[key]), 0.5, 0.01, "%s -> %s" % [key, pairs[key]])
	Settings.set_value(&"sfx_volume", 0.0, false)
	assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index(&"Sfx")), "0 mutes the bus")
	assert_near(_bus_linear(&"Ui"), 0.5, 0.01, "other buses untouched")
	var music := AudioServer.get_bus_index(&"Music")
	assert_eq(AudioServer.get_bus_send(music), &"Master", "Music goes through Master")


func test_apply_at_startup() -> void:
	var f := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"master_volume": 0.8, "ui_volume": 0.3, "quality": "low", "show_fps": true}))
	f.close()
	Settings.load_settings()
	Settings.apply()
	assert_near(_bus_linear(&"Master"), 0.8, 0.01, "Master applied")
	assert_near(_bus_linear(&"Ui"), 0.3, 0.01, "Ui applied")
	assert_eq(Look.get_quality(), Look.Quality.LOW, "quality applied")
	assert_true(Settings.is_fps_shown(), "FPS overlay shown")
	Settings.set_value(&"quality", "high", false)
	assert_eq(Look.get_quality(), Look.Quality.HIGH, "quality switches live")
	Settings.set_value(&"show_fps", false, false)
	assert_false(Settings.is_fps_shown(), "FPS overlay hidden")


func test_comfort_flags_are_readable_by_name() -> void:
	var s := get_tree().root.get_node_or_null(^"Settings")
	assert_true(s != null, "the Settings autoload is at /root/Settings")
	var changes := watch(Settings, &"changed")
	Settings.set_value(&"screen_shake", false, false)
	Settings.set_value(&"reduced_motion", true, false)
	assert_false(bool(s.get(&"screen_shake")), "screen_shake readable")
	assert_true(bool(s.get(&"reduced_motion")), "reduced_motion readable")
	assert_eq(changes.size(), 2, "changed emitted per key")
	assert_eq(changes[0][0], &"screen_shake", "with the key")
	assert_true(UiMotion.reduced_motion(), "the menus follow reduced motion")
	assert_false(Settings.set_value(&"reduced_motion", true, false), "setting the same value is a no-op")


func test_dev_runs_leave_the_file_alone() -> void:
	assert_true(Settings.is_dev_run(PackedStringArray(["--screenshot=x.png"])), "screenshot runs")
	assert_true(Settings.is_dev_run(PackedStringArray(["--offline", "--bots=3"])), "dev args")
	assert_false(Settings.is_dev_run(PackedStringArray(["--quality=low"])), "a normal run")
	assert_eq(Settings.window_size_vector("1920x1080"), Vector2i(1920, 1080), "size parsing")


# --- Screen --------------------------------------------------------------------------------------

func test_screen_controls_write_settings_live() -> void:
	var screen := (load(SCREEN_PATH) as PackedScene).instantiate() as SettingsScreen
	add_child(screen)
	await step(1)
	screen.open("Tester", true)
	await step(1)
	assert_true(screen.visible, "open")
	screen.sliders[&"ui_volume"].value = 0.35
	assert_near(Settings.ui_volume, 0.35, 0.001, "slider writes the setting")
	assert_near(_bus_linear(&"Ui"), 0.35, 0.01, "and the bus")
	assert_eq(screen.value_labels[&"ui_volume"].text, "35%", "percent label")
	screen.toggles[&"reduced_motion"].button_pressed = true
	assert_true(Settings.reduced_motion, "reduced motion toggle")
	assert_eq(screen.toggles[&"reduced_motion"].text, "On", "toggle reads On")
	screen.toggles[&"screen_shake"].button_pressed = false
	assert_false(Settings.screen_shake, "screen shake toggle")
	screen.quality_buttons["low"].pressed.emit()
	assert_eq(Settings.quality, "low", "quality chip")
	assert_eq(Look.get_quality(), Look.Quality.LOW, "quality applied")
	screen.size_buttons["1600x900"].pressed.emit()
	assert_eq(Settings.window_size, "1600x900", "window size chip")
	# Changes from elsewhere (F11) show up on the screen.
	Settings.set_value(&"fullscreen", true, false)
	assert_true(screen.toggles[&"fullscreen"].button_pressed, "fullscreen toggle follows")
	assert_true(screen.size_buttons["1280x720"].disabled, "window sizes disabled in fullscreen")
	Settings.set_value(&"fullscreen", false, false)
	var closed := watch(screen, &"closed")
	screen.close()
	assert_eq(closed.size(), 1, "closed")
	assert_false(screen.visible, "hidden")
	screen.queue_free()
