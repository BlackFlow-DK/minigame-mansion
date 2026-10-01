class_name SettingsScreen
extends Control
## Settings screen (res://ui/settings/settings.tscn), opened by MenuRoot from the title and the
## pause menu. Reads and writes the `Settings` autoload (every change applies live; volume
## sliders play a short preview blip on their bus). Two columns: Sound + Player (name, the
## Training Room prompt) on the left, Display + Comfort on the right. Keyboard / gamepad: up
## and down walk every control, left/right change sliders and chips, Esc / B closes.
## Owner: UI polish.

signal closed
## The name field was committed (Enter or focus left it); MenuRoot saves / sends it.
signal name_committed(player_name: String)
## "Show it again" for the first-run Training Room prompt.
signal reset_tutorial_requested

const VOLUMES: Array[Array] = [[&"master_volume", "Master"], [&"music_volume", "Music"],
	[&"sfx_volume", "Effects"], [&"ui_volume", "Interface"]]
const TOGGLES: Array[Array] = [[&"fullscreen", "Fullscreen"], [&"show_fps", "Show FPS"],
	[&"screen_shake", "Screen shake"], [&"reduced_motion", "Reduced motion"]]
## Seconds between two preview blips while a slider moves.
const PREVIEW_GAP := 0.12
## Label column widths (left: Sound / Player, right: Display / Comfort).
const LABEL_W := 140.0
const RIGHT_LABEL_W := 196.0
const MUSIC_PREVIEW := "res://audio/sfx/piano_e.wav"

var back_button: Button
var name_edit: LineEdit
var reset_tutorial_button: Button
var reset_tutorial_note: Label
## key -> HSlider (volumes)
var sliders: Dictionary[StringName, HSlider] = {}
## key -> "80%" label
var value_labels: Dictionary[StringName, Label] = {}
## key -> On/Off toggle Button (fullscreen, show_fps, screen_shake, reduced_motion)
var toggles: Dictionary[StringName, Button] = {}
## "1280x720" -> chip
var size_buttons: Dictionary[String, Button] = {}
## "low" / "high" -> chip
var quality_buttons: Dictionary[String, Button] = {}
var panel: PanelContainer
var center: CenterContainer

## Sliders have no focus stylebox of their own: this one draws the theme's focus ring.
class FocusSlider extends HSlider:
	func _ready() -> void:
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)

	func _draw() -> void:
		if has_focus():
			draw_style_box(get_theme_stylebox(&"focus", &"Button"), Rect2(Vector2.ZERO, size))


var _dim: ColorRect
var _syncing: bool = false
var _preview_at: Dictionary[StringName, int] = {}
var _music_preview: AudioStreamPlayer
var _name_before: String = ""


func _init() -> void:
	name = "Settings"
	add_to_group(&"blocks_player_input")
	MenuUI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim = MenuUI.full_rect(ColorRect.new()) as ColorRect
	_dim.color = Color(MenuUI.CHARCOAL, 0.55)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	center = MenuUI.full_rect(CenterContainer.new()) as CenterContainer
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(1080, 0)
	center.add_child(panel)
	var col := MenuUI.vbox(10)
	panel.add_child(col)

	var head := MenuUI.hbox(16)
	col.add_child(head)
	var title := MenuUI.label("Settings", &"HeaderLabel")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var hint := MenuUI.label("Esc / B to close", &"MutedLabel")
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(hint)
	back_button = MenuUI.button("Back", &"SecondaryButton", 120)
	head.add_child(back_button)

	var columns := MenuUI.hbox(44)
	col.add_child(columns)
	var left := MenuUI.vbox(8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(left)
	var right := MenuUI.vbox(8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right)

	# Left: Sound, Player.
	left.add_child(_section("Sound"))
	for v: Array in VOLUMES:
		left.add_child(_volume_row(v[0], v[1]))
	left.add_child(_section("Player"))
	var name_row := _row("Name")
	name_edit = LineEdit.new()
	name_edit.max_length = MenuTitleScreen.MAX_NAME_LENGTH
	name_edit.placeholder_text = "Type your name"
	name_edit.select_all_on_focus = true
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_edit)
	left.add_child(name_row)
	var tut_row := _row("Tutorial")
	reset_tutorial_button = MenuUI.button("Show the welcome prompt again", &"SecondaryButton")
	reset_tutorial_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_tutorial_button.tooltip_text = "The \"New here? Try the Training Room\" prompt shows again on the title screen."
	tut_row.add_child(reset_tutorial_button)
	left.add_child(tut_row)
	reset_tutorial_note = MenuUI.label("", &"MutedLabel")
	reset_tutorial_note.add_theme_font_size_override(&"font_size", 16)
	reset_tutorial_note.custom_minimum_size = Vector2(0, 20)
	left.add_child(reset_tutorial_note)

	# Right: Display, Comfort.
	right.add_child(_section("Display"))
	right.add_child(_toggle_row(&"fullscreen", "Fullscreen"))
	var size_row := _row("Window", RIGHT_LABEL_W)
	var size_group := ButtonGroup.new()
	for s: String in Settings.WINDOW_SIZES:
		var b := _chip(s.replace("x", " x "), size_group)
		b.add_theme_font_size_override(&"font_size", 16)
		b.pressed.connect(_on_size_chip.bind(s))
		size_row.add_child(b)
		size_buttons[s] = b
	right.add_child(size_row)
	var q_row := _row("Quality", RIGHT_LABEL_W)
	var q_group := ButtonGroup.new()
	for q: String in Settings.QUALITIES:
		var b := _chip(q.capitalize(), q_group)
		b.custom_minimum_size = Vector2(110, 0)
		b.pressed.connect(_on_quality_chip.bind(q))
		q_row.add_child(b)
		quality_buttons[q] = b
	right.add_child(q_row)
	right.add_child(_toggle_row(&"show_fps", "Show FPS"))
	right.add_child(_section("Comfort"))
	right.add_child(_toggle_row(&"screen_shake", "Screen shake"))
	right.add_child(_toggle_row(&"reduced_motion", "Reduced motion"))

	back_button.pressed.connect(close)
	reset_tutorial_button.pressed.connect(_on_reset_tutorial)
	name_edit.text_submitted.connect(func(_t: String) -> void:
		_commit_name()
		reset_tutorial_button.grab_focus())
	name_edit.focus_exited.connect(_commit_name)
	visible = false


func _ready() -> void:
	_music_preview = AudioStreamPlayer.new()
	_music_preview.bus = &"Music" if AudioServer.get_bus_index(&"Music") >= 0 else &"Master"
	if ResourceLoader.exists(MUSIC_PREVIEW):
		_music_preview.stream = load(MUSIC_PREVIEW) as AudioStream
	add_child(_music_preview)
	Settings.changed.connect(_on_setting_changed)
	sync_from_settings()


## Shows the screen. `player_name`: the name field; `over_game`: dim the game behind it (the
## title has its own backdrop); `name_editable`: false while a round runs.
func open(player_name: String, over_game: bool, name_editable: bool = true) -> void:
	_name_before = player_name
	name_edit.text = player_name
	name_edit.editable = name_editable
	name_edit.tooltip_text = "" if name_editable else "Change your name in the lobby."
	reset_tutorial_note.text = ""
	_dim.visible = over_game
	sync_from_settings()
	visible = true
	UiMotion.enter(self, center)
	focus_default()


## Saves and hides; emits `closed`.
func close() -> void:
	if not visible:
		return
	_commit_name()
	Settings.save_settings()
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func focus_default() -> void:
	refresh_focus()
	MenuUI.focus_first([sliders[&"master_volume"], back_button])


## Every control top to bottom: Back, the left column, then the right column (wrapping).
func refresh_focus() -> Array[Control]:
	var rows: Array = [back_button]
	for v: Array in VOLUMES:
		rows.append(sliders[v[0]])
	rows.append_array([name_edit, reset_tutorial_button, toggles[&"fullscreen"]])
	var sizes: Array = []
	for s: String in Settings.WINDOW_SIZES:
		sizes.append(size_buttons[s])
	rows.append(sizes)
	var qs: Array = []
	for q: String in Settings.QUALITIES:
		qs.append(quality_buttons[q])
	rows.append(qs)
	rows.append_array([toggles[&"show_fps"], toggles[&"screen_shake"], toggles[&"reduced_motion"]])
	return MenuUI.chain_grid(rows)


## Shows the current Settings values (without writing them back).
func sync_from_settings() -> void:
	_syncing = true
	for v: Array in VOLUMES:
		var key: StringName = v[0]
		sliders[key].value = float(Settings.get_value(key))
		_show_percent(key)
	for key: StringName in toggles:
		_set_toggle(toggles[key], bool(Settings.get_value(key)))
	for s: String in size_buttons:
		size_buttons[s].set_pressed_no_signal(Settings.window_size == s)
		size_buttons[s].disabled = Settings.fullscreen
	for q: String in quality_buttons:
		quality_buttons[q].set_pressed_no_signal(Settings.quality == q)
	_syncing = false
	if is_inside_tree() and visible:
		refresh_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"pause"):
		get_viewport().set_input_as_handled()
		close()


# --- Builders ----------------------------------------------------------------------------------

func _section(text: String) -> Label:
	var l := MenuUI.label(text.to_upper(), &"HeaderLabel")
	l.add_theme_font_size_override(&"font_size", 22)
	l.add_theme_color_override(&"font_color", MenuUI.TEAL.darkened(0.25))
	return l


func _row(text: String, label_w: float = LABEL_W) -> HBoxContainer:
	var row := MenuUI.hbox(12)
	row.custom_minimum_size = Vector2(0, 46)
	var l := MenuUI.label(text, &"")
	l.custom_minimum_size = Vector2(label_w, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	return row


func _volume_row(key: StringName, text: String) -> HBoxContainer:
	var row := _row(text)
	var s := FocusSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(180, 30)
	s.focus_mode = Control.FOCUS_ALL
	s.value_changed.connect(_on_volume.bind(key))
	s.drag_ended.connect(func(_changed: bool) -> void: Settings.save_settings())
	row.add_child(s)
	sliders[key] = s
	var pct := MenuUI.label("100%", &"", HORIZONTAL_ALIGNMENT_RIGHT)
	pct.custom_minimum_size = Vector2(66, 0)
	pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(pct)
	value_labels[key] = pct
	return row


func _toggle_row(key: StringName, text: String) -> HBoxContainer:
	var row := _row(text, RIGHT_LABEL_W)
	var b := MenuUI.button("Off", &"ChipButton", 110)
	b.toggle_mode = true
	b.add_theme_font_size_override(&"font_size", 20)
	b.toggled.connect(_on_toggle.bind(key, b))
	row.add_child(b)
	toggles[key] = b
	return row


func _chip(text: String, group: ButtonGroup) -> Button:
	var b := MenuUI.button(text, &"ChipButton")
	b.toggle_mode = true
	b.button_group = group
	b.add_theme_font_size_override(&"font_size", 20)
	return b


# --- Reactions ---------------------------------------------------------------------------------

func _on_volume(value: float, key: StringName) -> void:
	_show_percent(key)
	if _syncing:
		return
	Settings.set_value(key, value, false)
	_preview(key)


func _show_percent(key: StringName) -> void:
	value_labels[key].text = "%d%%" % roundi(sliders[key].value * 100.0)


## A short blip on the bus the slider controls (not headless, at most every PREVIEW_GAP).
func _preview(key: StringName) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var now := Time.get_ticks_msec()
	if now - int(_preview_at.get(key, -100000)) < int(PREVIEW_GAP * 1000.0):
		return
	_preview_at[key] = now
	match key:
		&"music_volume":
			if _music_preview.stream:
				_music_preview.bus = &"Music" if AudioServer.get_bus_index(&"Music") >= 0 else &"Master"
				_music_preview.play()
		&"sfx_volume":
			Sfx.play(&"coin")
		_:
			Sfx.play(&"ui_click")


func _on_toggle(on: bool, key: StringName, b: Button) -> void:
	b.text = "On" if on else "Off"
	if _syncing:
		return
	Settings.set_value(key, on)


func _set_toggle(b: Button, on: bool) -> void:
	b.set_pressed_no_signal(on)
	b.text = "On" if on else "Off"


func _on_size_chip(size_text: String) -> void:
	if not _syncing:
		Settings.set_value(&"window_size", size_text)


func _on_quality_chip(q: String) -> void:
	if not _syncing:
		Settings.set_value(&"quality", q)


func _on_setting_changed(key: StringName) -> void:
	if key == &"fullscreen" or key == &"window_size" or key == &"quality" or toggles.has(key):
		var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
		sync_from_settings()
		if visible and f != null and not MenuUI.focusable(f):
			focus_default()


func _commit_name() -> void:
	if not name_edit.editable:
		return
	var n := name_edit.text.strip_edges()
	if n == "" or n == _name_before:
		return
	_name_before = n
	name_committed.emit(n)


func _on_reset_tutorial() -> void:
	reset_tutorial_requested.emit()
	reset_tutorial_note.text = "Done: it greets you on the title screen again."
