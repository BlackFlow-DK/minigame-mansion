extends Node
## Autoload `Settings`: the player's options on this PC, saved in `user://settings.json` and
## applied at startup. Owner: UI polish (settings screen: res://ui/settings/settings.tscn).
##
##   Volumes 0..1 (linear) -> audio buses Master / Music / Sfx / Ui (through `Sfx.set_volume`;
##     a missing bus, e.g. Music before the music system exists, is created and sent to Master)
##   fullscreen, window_size ("1280x720" | "1600x900" | "1920x1080") -> the window
##   quality ("high" | "low") -> `Look.set_quality`
##   screen_shake, reduced_motion -> flags other systems read (see below); show_fps -> overlay
##
## Other systems read the comfort flags without depending on this file existing:
##   var s := get_tree().root.get_node_or_null(^"Settings")
##   if s and not s.screen_shake: amount = 0.0
##   if s and s.reduced_motion: ...skip or shorten the animation...
## and may listen to `changed(key)` for live updates.
##
## Test runs (a `--script` main loop) and dev runs (MainApp/Progression dev args,
## `--screenshot=`) neither load, apply nor save the file: defaults only, so screenshots and
## tests stay deterministic. Tests drive `path`, `persist`, `load_settings()` and `apply()`.

## A value changed (`key` is one of KEYS).
signal changed(key: StringName)

const PATH := "user://settings.json"
const KEYS: Array[StringName] = [&"master_volume", &"music_volume", &"sfx_volume", &"ui_volume",
	&"fullscreen", &"window_size", &"quality", &"screen_shake", &"reduced_motion", &"show_fps"]
const DEFAULTS := {
	&"master_volume": 1.0, &"music_volume": 0.6, &"sfx_volume": 1.0, &"ui_volume": 1.0,
	&"fullscreen": false, &"window_size": "1280x720", &"quality": "high",
	&"screen_shake": true, &"reduced_motion": false, &"show_fps": false,
}
## Volume key -> audio bus.
const BUSES := {&"master_volume": &"Master", &"music_volume": &"Music", &"sfx_volume": &"Sfx", &"ui_volume": &"Ui"}
const WINDOW_SIZES: Array[String] = ["1280x720", "1600x900", "1920x1080"]
const QUALITIES: Array[String] = ["low", "high"]
## User args that make a run a dev/test run (no settings file). Mirrors Progression.DEV_ARGS.
const DEV_ARGS: Array[String] = ["name", "offline", "auto-host", "auto-join", "bots", "auto-start",
	"round-time", "time-scale", "round-minigame", "open-wardrobe", "min-players", "fps", "screenshot",
	"sandbox", "minigame", "players", "coins"]

var master_volume: float = 1.0
var music_volume: float = 0.6
var sfx_volume: float = 1.0
var ui_volume: float = 1.0
var fullscreen: bool = false
var window_size: String = "1280x720"
var quality: String = "high"
## False: cameras do not shake (the feel system reads it).
var screen_shake: bool = true
## True: shorter / calmer animations (the feel system and the menus read it).
var reduced_motion: bool = false
var show_fps: bool = false

## Where the settings live (tests point it elsewhere).
var path: String = PATH
## Write changes to `path`. Off for test and dev runs.
var persist: bool = true

var _fps_layer: CanvasLayer
var _fps_label: Label
var _fps_t: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var tool_run := get_tree().get_script() != null
	var dev := is_dev_run(OS.get_cmdline_user_args())
	_build_fps_overlay()
	if tool_run or dev:
		persist = false
		return
	var had_file := FileAccess.file_exists(path)
	load_settings()
	apply_audio()
	apply_quality()
	if had_file:
		apply_display()
	_update_fps_overlay()


## True when the user args make this a dev/test run (see DEV_ARGS).
static func is_dev_run(args: PackedStringArray) -> bool:
	for arg in args:
		if arg.begins_with("--") and DEV_ARGS.has(arg.trim_prefix("--").split("=", true, 1)[0]):
			return true
	return false


# --- Values ----------------------------------------------------------------------------------

func get_value(key: StringName) -> Variant:
	return get(key)


## Sets `key` (clamped / validated), applies just that part, saves (unless `save` is false: a
## slider being dragged saves when it lets go) and emits `changed`. Unknown keys are ignored.
## Returns true when the value changed.
func set_value(key: StringName, value: Variant, save: bool = true) -> bool:
	if not KEYS.has(key):
		push_warning("Settings.set_value: unknown key '%s'" % key)
		return false
	var clean: Variant = _clean(key, value)
	if get(key) == clean:
		return false
	set(key, clean)
	_apply_key(key)
	if save:
		save_settings()
	changed.emit(key)
	return true


## Everything back to DEFAULTS (applied and saved).
func reset_to_defaults() -> void:
	for key: StringName in KEYS:
		set(key, DEFAULTS[key])
	apply()
	save_settings()
	for key: StringName in KEYS:
		changed.emit(key)


func to_dict() -> Dictionary:
	var out := {}
	for key: StringName in KEYS:
		out[String(key)] = get(key)
	return out


# --- File ------------------------------------------------------------------------------------

## Reads `path` (missing or broken file: its `.bak`, else defaults). Does not apply.
func load_settings() -> void:
	const Store := preload("res://cosmetics/cosmetics.gd")
	for key: StringName in KEYS:
		set(key, DEFAULTS[key])
	var data: Variant = Store.read_json_dict(path)
	if data == null:
		data = Store.read_json_dict(path + Store.BACKUP_SUFFIX)
		if FileAccess.file_exists(path):
			push_warning("Settings: %s is unreadable, using %s" % [path, "the backup" if data != null else "defaults"])
	if not data is Dictionary:
		return
	var d := data as Dictionary
	for key: StringName in KEYS:
		if d.has(String(key)):
			set(key, _clean(key, d[String(key)]))


## Writes `path` when `persist`, crash-safe (tmp + rename, previous file kept as `.bak`).
## Returns OK when skipped.
func save_settings() -> Error:
	const Store := preload("res://cosmetics/cosmetics.gd")
	if not persist:
		return OK
	var err := Store.write_json_atomic(path, JSON.stringify(to_dict(), "\t"))
	if err != OK:
		push_warning("Settings: cannot write %s (%s)" % [path, error_string(err)])
	return err


# --- Applying --------------------------------------------------------------------------------

func apply() -> void:
	apply_audio()
	apply_display()
	apply_quality()
	_update_fps_overlay()


## Sets every bus volume (creating a missing bus, e.g. Music).
func apply_audio() -> void:
	for key: StringName in BUSES:
		_apply_volume(key)


## Fullscreen or a windowed size (skipped headless).
func apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if fullscreen:
		if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	var want := window_size_vector(window_size)
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	want = Vector2i(mini(want.x, usable.size.x), mini(want.y, usable.size.y))
	if DisplayServer.window_get_size() != want:
		DisplayServer.window_set_size(want)
		DisplayServer.window_set_position(usable.position + (usable.size - want) / 2)


## `Look.set_quality` (unless `--quality=` was given on the command line).
func apply_quality() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			return
	Look.set_quality(Look.Quality.LOW if quality == "low" else Look.Quality.HIGH)


## "1600x900" -> Vector2i(1600, 900) (unknown: 1280x720).
static func window_size_vector(text: String) -> Vector2i:
	var parts := text.split("x")
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		return Vector2i(int(parts[0]), int(parts[1]))
	return Vector2i(1280, 720)


func _apply_key(key: StringName) -> void:
	if BUSES.has(key):
		_apply_volume(key)
	elif key == &"fullscreen" or key == &"window_size":
		apply_display()
	elif key == &"quality":
		apply_quality()
	elif key == &"show_fps":
		_update_fps_overlay()


func _apply_volume(key: StringName) -> void:
	var bus: StringName = BUSES[key]
	if AudioServer.get_bus_index(bus) < 0:
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus)
		AudioServer.set_bus_send(idx, &"Master")
	Sfx.set_volume(bus, float(get(key)))


func _clean(key: StringName, value: Variant) -> Variant:
	match key:
		&"master_volume", &"music_volume", &"sfx_volume", &"ui_volume":
			return clampf(float(value), 0.0, 1.0) if (value is float or value is int) else DEFAULTS[key]
		&"window_size":
			return str(value) if WINDOW_SIZES.has(str(value)) else DEFAULTS[key]
		&"quality":
			return str(value) if QUALITIES.has(str(value)) else DEFAULTS[key]
		_:
			return bool(value) if (value is bool or value is int or value is float) else DEFAULTS[key]


# --- FPS overlay -----------------------------------------------------------------------------

func _build_fps_overlay() -> void:
	_fps_layer = CanvasLayer.new()
	_fps_layer.name = "FpsOverlay"
	_fps_layer.layer = 120
	add_child(_fps_layer)
	_fps_label = Label.new()
	_fps_label.name = "Fps"
	_fps_label.anchor_left = 1.0
	_fps_label.anchor_right = 1.0
	_fps_label.offset_left = -130.0
	_fps_label.offset_right = -10.0
	_fps_label.offset_top = 6.0
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fps_label.add_theme_font_size_override(&"font_size", 18)
	_fps_label.add_theme_color_override(&"font_color", Color("#f3e6c8"))
	_fps_label.add_theme_color_override(&"font_outline_color", Color("#2e2a33"))
	_fps_label.add_theme_constant_override(&"outline_size", 6)
	_fps_layer.add_child(_fps_label)
	_update_fps_overlay()


func _update_fps_overlay() -> void:
	if _fps_layer:
		_fps_layer.visible = show_fps
		set_process(show_fps)


## The FPS overlay is showing.
func is_fps_shown() -> bool:
	return _fps_layer != null and _fps_layer.visible


func _process(delta: float) -> void:
	_fps_t -= delta
	if _fps_t <= 0.0 and _fps_label:
		_fps_t = 0.25
		_fps_label.text = "%d FPS" % Engine.get_frames_per_second()
