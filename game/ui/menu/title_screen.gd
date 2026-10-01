class_name MenuTitleScreen
extends Control
## Title screen: the game logo (styled text, drop shadow, a gentle idle bob), the name field,
## the three ways to play as big buttons (Host / Join / Play offline), the secondary grid
## (Wardrobe / How to play / Settings / Quit), the Mansion Coin balance (top right), the version
## (bottom left, `application/config/version`) and the one-time "New here?" prompt for the
## Training Room. Pure view; MenuRoot acts on the signals.

signal host_pressed
signal join_pressed
signal offline_pressed
signal wardrobe_pressed
signal quit_pressed
signal settings_pressed
## How to play: open the Training Room (tutorial).
signal how_to_play_pressed
## The first-run "New here? Try the Training Room" prompt was answered.
signal training_prompt_answered(accepted: bool)
## The name field lost focus or was submitted (MenuRoot saves the profile).
signal name_committed(player_name: String)

const MAX_NAME_LENGTH := 16
const DEFAULT_NAME := "Player"

var name_edit: LineEdit
var host_button: Button
var join_button: Button
var offline_button: Button
var wardrobe_button: Button
var quit_button: Button
var how_to_play_button: Button
var settings_button: Button
## Wardrobe / How to play / Settings / Quit.
var secondary_grid: GridContainer
## The first-run prompt (an overlay over the whole title).
var training_prompt: Control
var prompt_yes_button: Button
var prompt_no_button: Button
var coin_balance: CoinBalance
var version_label: Label
var message_panel: PanelContainer
var message_label: Label
## The two logo words (they bob) and the menu panel.
var logo_words: Array[Label] = []
var menu_panel: PanelContainer

var _t: float = 0.0


func _init() -> void:
	name = "TitleScreen"
	MenuUI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var center := MenuUI.full_rect(CenterContainer.new())
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var row := MenuUI.hbox(56)
	center.add_child(row)

	# Logo side: each word sits in a holder so it can bob without the box re-laying it out.
	var logo := MenuUI.vbox(0)
	logo.alignment = BoxContainer.ALIGNMENT_CENTER
	logo.custom_minimum_size = Vector2(580, 0)
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(logo)
	var words := [["MINIGAME", &"TitleLabel", 128.0, 112], ["MANSION", &"SubtitleLabel", 96.0, 84]]
	for w: Array in words:
		var holder := Control.new()
		holder.custom_minimum_size = Vector2(580, float(w[2]))
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		logo.add_child(holder)
		var word := MenuUI.label(str(w[0]), w[1], HORIZONTAL_ALIGNMENT_CENTER)
		MenuUI.full_rect(word)
		word.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		word.add_theme_font_size_override(&"font_size", int(w[3]))
		word.resized.connect(func() -> void: word.pivot_offset = word.size * 0.5)
		holder.add_child(word)
		logo_words.append(word)
	var tag_gap := Control.new()
	tag_gap.custom_minimum_size = Vector2(0, 14)
	logo.add_child(tag_gap)
	var tag := MenuUI.label("Party games for up to 8 friends on your network", &"LightLabel", HORIZONTAL_ALIGNMENT_CENTER)
	tag.add_theme_font_size_override(&"font_size", 22)
	tag.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tag.custom_minimum_size = Vector2(480, 0)
	logo.add_child(tag)

	# Menu side.
	menu_panel = PanelContainer.new()
	menu_panel.custom_minimum_size = Vector2(410, 0)
	menu_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(menu_panel)
	var col := MenuUI.vbox(12)
	menu_panel.add_child(col)

	message_panel = PanelContainer.new()
	message_panel.theme_type_variation = &"ErrorPanel"
	message_label = MenuUI.label("", &"ErrorLabel")
	message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message_panel.add_child(message_label)
	message_panel.visible = false
	col.add_child(message_panel)

	var name_col := MenuUI.vbox(4)
	col.add_child(name_col)
	name_col.add_child(MenuUI.label("Your name", &"MutedLabel"))
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Type your name"
	name_edit.max_length = MAX_NAME_LENGTH
	name_edit.select_all_on_focus = true
	name_col.add_child(name_edit)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 2)
	col.add_child(gap)

	# Primary: the three ways to play, big.
	host_button = MenuUI.button("Host game", &"PrimaryButton")
	join_button = MenuUI.button("Join game", &"BigButton")
	offline_button = MenuUI.button("Play offline", &"BigButton")
	for b: Button in [host_button, join_button, offline_button]:
		col.add_child(b)

	col.add_child(HSeparator.new())

	# Secondary: smaller, two by two.
	secondary_grid = GridContainer.new()
	secondary_grid.columns = 2
	secondary_grid.add_theme_constant_override(&"h_separation", 12)
	secondary_grid.add_theme_constant_override(&"v_separation", 12)
	col.add_child(secondary_grid)
	wardrobe_button = MenuUI.button("Wardrobe", &"SecondaryButton")
	how_to_play_button = MenuUI.button("How to play", &"SecondaryButton")
	settings_button = MenuUI.button("Settings", &"SecondaryButton")
	quit_button = MenuUI.button("Quit", &"SecondaryDangerButton")
	for b: Button in [wardrobe_button, how_to_play_button, settings_button, quit_button]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		secondary_grid.add_child(b)

	# Corners: coins (top right), version (bottom left).
	coin_balance = CoinBalance.make(26)
	coin_balance.anchor_left = 1.0
	coin_balance.anchor_right = 1.0
	coin_balance.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	coin_balance.offset_left = -24.0
	coin_balance.offset_right = -24.0
	coin_balance.offset_top = 22.0
	add_child(coin_balance)
	version_label = MenuUI.label("v" + version_string(), &"LightLabel")
	version_label.add_theme_font_size_override(&"font_size", 17)
	version_label.add_theme_constant_override(&"outline_size", 6)
	version_label.modulate.a = 0.85
	version_label.anchor_top = 1.0
	version_label.anchor_bottom = 1.0
	version_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version_label.offset_left = 22.0
	version_label.offset_top = -16.0
	version_label.offset_bottom = -16.0
	add_child(version_label)

	host_button.pressed.connect(func() -> void: host_pressed.emit())
	join_button.pressed.connect(func() -> void: join_pressed.emit())
	offline_button.pressed.connect(func() -> void: offline_pressed.emit())
	wardrobe_button.pressed.connect(func() -> void: wardrobe_pressed.emit())
	quit_button.pressed.connect(func() -> void: quit_pressed.emit())
	settings_button.pressed.connect(func() -> void: settings_pressed.emit())
	how_to_play_button.pressed.connect(func() -> void: how_to_play_pressed.emit())
	_build_training_prompt()
	name_edit.text_submitted.connect(_on_name_submitted)
	name_edit.focus_exited.connect(func() -> void: name_committed.emit(player_name()))


func _ready() -> void:
	refresh_focus()


## `application/config/version` from project.godot ("dev" when unset).
static func version_string() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "dev"))


## Idle logo: the words bob and sway out of phase (still under reduced motion).
func _process(delta: float) -> void:
	if not is_visible_in_tree() or logo_words.is_empty():
		return
	_t += delta
	var calm := UiMotion.reduced_motion()
	for i in logo_words.size():
		var w := logo_words[i]
		w.position.y = 0.0 if calm else sin(_t * 1.7 + i * 1.3) * (6.0 - i * 1.5)
		w.rotation = 0.0 if calm else sin(_t * 0.85 + i * 2.1) * (0.022 - i * 0.008)


## The trimmed name, or "Player" when empty.
func player_name() -> String:
	var n := name_edit.text.strip_edges()
	return n if n != "" else DEFAULT_NAME


## A friendly first-run name ("Wobbly Blob", "Sunny Pudding"), at most 16 characters, so
## friends can tell each other apart before anyone renames.
static func random_name(rng: RandomNumberGenerator = null) -> String:
	const ADJECTIVES: Array[String] = ["Wobbly", "Bouncy", "Sunny", "Sneaky", "Fuzzy", "Jolly", "Zippy",
		"Grumpy", "Sparkly", "Sleepy", "Mighty", "Squishy", "Dizzy", "Cheeky", "Plucky", "Breezy"]
	const NOUNS: Array[String] = ["Blob", "Jelly", "Pudding", "Bean", "Dumpling", "Gumdrop", "Mochi",
		"Noodle", "Muffin", "Pickle", "Waffle", "Biscuit"]
	var r := rng if rng else RandomNumberGenerator.new()
	if rng == null:
		r.randomize()
	return ("%s %s" % [ADJECTIVES[r.randi() % ADJECTIVES.size()], NOUNS[r.randi() % NOUNS.size()]]).left(MAX_NAME_LENGTH)


func set_player_name(n: String) -> void:
	name_edit.text = n.left(MAX_NAME_LENGTH)


func set_wardrobe_available(available: bool) -> void:
	wardrobe_button.visible = available
	refresh_focus()


## Shows `text` in a red banner above the name (empty hides it).
func show_message(text: String) -> void:
	message_label.text = text
	message_panel.visible = text != ""


## Name, Host, Join, Play offline, then the 2x2 grid; up/down and left/right both wrap.
func refresh_focus() -> Array[Control]:
	return MenuUI.chain_grid([name_edit, host_button, join_button, offline_button,
		[wardrobe_button, how_to_play_button], [settings_button, quit_button]])


func focus_default() -> void:
	refresh_focus()
	MenuUI.focus_first([host_button, join_button])


func _on_name_submitted(_text: String) -> void:
	name_committed.emit(player_name())
	host_button.grab_focus()


# --- First-run prompt ---------------------------------------------------------------------

## Shows the one-time "New here? Try the Training Room" prompt over the title.
func show_training_prompt() -> void:
	training_prompt.visible = true
	UiMotion.enter(training_prompt, training_prompt.get_node(^"Center") as Control)
	MenuUI.chain_grid([[prompt_yes_button, prompt_no_button]])
	prompt_yes_button.grab_focus()


func is_training_prompt_visible() -> bool:
	return training_prompt.visible


## Closes the prompt with `accepted` (also what Yes / No / Esc do).
func answer_training_prompt(accepted: bool) -> void:
	if not training_prompt.visible:
		return
	training_prompt.visible = false
	training_prompt_answered.emit(accepted)
	if not accepted:
		focus_default()


func _unhandled_input(event: InputEvent) -> void:
	if training_prompt.visible and event.is_action_pressed(&"ui_cancel"):
		answer_training_prompt(false)
		get_viewport().set_input_as_handled()


func _build_training_prompt() -> void:
	training_prompt = MenuUI.full_rect(Control.new())
	training_prompt.name = "TrainingPrompt"
	training_prompt.mouse_filter = Control.MOUSE_FILTER_STOP
	training_prompt.visible = false
	add_child(training_prompt)
	var dim := MenuUI.full_rect(ColorRect.new()) as ColorRect
	dim.color = Color(MenuUI.CHARCOAL, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	training_prompt.add_child(dim)
	var center := MenuUI.full_rect(CenterContainer.new())
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	training_prompt.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 0)
	center.add_child(panel)
	var col := MenuUI.vbox(14)
	panel.add_child(col)
	col.add_child(MenuUI.label("New here?", &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER))
	var text := MenuUI.label("Try the Training Room: a quick garden course that teaches you to move, jump, shove and survive every game.", &"", HORIZONTAL_ALIGNMENT_CENTER)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(text)
	var row := MenuUI.hbox(18)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)
	prompt_yes_button = MenuUI.button("Yes, show me!", &"PrimaryButton")
	prompt_no_button = MenuUI.button("No thanks")
	row.add_child(prompt_yes_button)
	row.add_child(prompt_no_button)
	prompt_yes_button.pressed.connect(answer_training_prompt.bind(true))
	prompt_no_button.pressed.connect(answer_training_prompt.bind(false))
