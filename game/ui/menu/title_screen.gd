class_name MenuTitleScreen
extends Control
## Title screen: logo, name entry, Host / Join / Play offline + How to play / Wardrobe (with
## the Mansion Coin balance) / Quit, and the one-time "New here?" prompt for the Training
## Room. Pure view; MenuRoot acts on the signals.

signal host_pressed
signal join_pressed
signal offline_pressed
signal wardrobe_pressed
signal quit_pressed
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
## Play offline + How to play side by side.
var offline_row: HBoxContainer
## The first-run prompt (an overlay over the whole title).
var training_prompt: Control
var prompt_yes_button: Button
var prompt_no_button: Button
## Wardrobe button + the Mansion Coin balance.
var wardrobe_row: HBoxContainer
var coin_balance: CoinBalance
var message_panel: PanelContainer
var message_label: Label


func _init() -> void:
	name = "TitleScreen"
	MenuUI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var center := MenuUI.full_rect(CenterContainer.new())
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var row := MenuUI.hbox(70)
	center.add_child(row)

	# Logo side.
	var logo := MenuUI.vbox(0)
	logo.alignment = BoxContainer.ALIGNMENT_CENTER
	logo.custom_minimum_size = Vector2(520, 0)
	row.add_child(logo)
	logo.add_child(MenuUI.label("MINIGAME", &"TitleLabel", HORIZONTAL_ALIGNMENT_CENTER))
	logo.add_child(MenuUI.label("MANSION", &"SubtitleLabel", HORIZONTAL_ALIGNMENT_CENTER))
	var tag := MenuUI.label("Party games for up to 8 friends on your network", &"LightLabel", HORIZONTAL_ALIGNMENT_CENTER)
	tag.add_theme_font_size_override(&"font_size", 20)
	tag.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tag.custom_minimum_size = Vector2(440, 0)
	var tag_gap := Control.new()
	tag_gap.custom_minimum_size = Vector2(0, 14)
	logo.add_child(tag_gap)
	logo.add_child(tag)

	# Menu side.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(400, 0)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(panel)
	var col := MenuUI.vbox(14)
	panel.add_child(col)

	message_panel = PanelContainer.new()
	message_panel.theme_type_variation = &"ErrorPanel"
	message_label = MenuUI.label("", &"ErrorLabel")
	message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message_panel.add_child(message_label)
	message_panel.visible = false
	col.add_child(message_panel)

	col.add_child(MenuUI.label("Your name", &"MutedLabel"))
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Type your name"
	name_edit.max_length = MAX_NAME_LENGTH
	name_edit.select_all_on_focus = true
	col.add_child(name_edit)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 4)
	col.add_child(gap)

	host_button = MenuUI.button("Host game", &"PrimaryButton")
	join_button = MenuUI.button("Join game")
	offline_button = MenuUI.button("Play offline")
	wardrobe_button = MenuUI.button("Wardrobe")
	quit_button = MenuUI.button("Quit", &"DangerButton")
	how_to_play_button = MenuUI.button("How to play")
	for b: Button in [host_button, join_button]:
		col.add_child(b)
	offline_row = MenuUI.hbox(10)
	col.add_child(offline_row)
	for b: Button in [offline_button, how_to_play_button]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		offline_row.add_child(b)
	# Wardrobe with the Mansion Coin balance beside it (where the coins get spent).
	wardrobe_row = MenuUI.hbox(10)
	col.add_child(wardrobe_row)
	wardrobe_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wardrobe_row.add_child(wardrobe_button)
	coin_balance = CoinBalance.make(20)
	coin_balance.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wardrobe_row.add_child(coin_balance)
	col.add_child(quit_button)

	host_button.pressed.connect(func() -> void: host_pressed.emit())
	join_button.pressed.connect(func() -> void: join_pressed.emit())
	offline_button.pressed.connect(func() -> void: offline_pressed.emit())
	wardrobe_button.pressed.connect(func() -> void: wardrobe_pressed.emit())
	quit_button.pressed.connect(func() -> void: quit_pressed.emit())
	how_to_play_button.pressed.connect(func() -> void: how_to_play_pressed.emit())
	_build_training_prompt()
	name_edit.text_submitted.connect(_on_name_submitted)
	name_edit.focus_exited.connect(func() -> void: name_committed.emit(player_name()))


func _ready() -> void:
	refresh_focus()


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
	wardrobe_row.visible = available
	refresh_focus()


## Shows `text` in a red banner above the name (empty hides it).
func show_message(text: String) -> void:
	message_label.text = text
	message_panel.visible = text != ""


func refresh_focus() -> void:
	MenuUI.chain_vertical([name_edit, host_button, join_button, offline_button, wardrobe_button, quit_button])
	# How to play sits right of Play offline: same up/down, left/right between the two.
	MenuUI.chain_horizontal([offline_button, how_to_play_button])
	if offline_button.focus_neighbor_top != NodePath():
		how_to_play_button.focus_neighbor_top = how_to_play_button.get_path_to(offline_button.get_node(offline_button.focus_neighbor_top))
	if offline_button.focus_neighbor_bottom != NodePath():
		how_to_play_button.focus_neighbor_bottom = how_to_play_button.get_path_to(offline_button.get_node(offline_button.focus_neighbor_bottom))


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
	dim.color = Color(MenuUI.CHARCOAL, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	training_prompt.add_child(dim)
	var center := MenuUI.full_rect(CenterContainer.new())
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	training_prompt.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 0)
	center.add_child(panel)
	var col := MenuUI.vbox(14)
	panel.add_child(col)
	col.add_child(MenuUI.label("New here?", &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER))
	var text := MenuUI.label("Try the Training Room: a quick garden course that teaches you to move, jump, shove and survive every game.", &"", HORIZONTAL_ALIGNMENT_CENTER)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(text)
	var row := MenuUI.hbox(14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)
	prompt_yes_button = MenuUI.button("Yes, show me!", &"PrimaryButton")
	prompt_no_button = MenuUI.button("No thanks")
	row.add_child(prompt_yes_button)
	row.add_child(prompt_no_button)
	MenuUI.chain_horizontal([prompt_yes_button, prompt_no_button], prompt_yes_button, prompt_yes_button)
	prompt_no_button.focus_neighbor_top = prompt_no_button.get_path_to(prompt_no_button)
	prompt_no_button.focus_neighbor_bottom = prompt_no_button.get_path_to(prompt_no_button)
	prompt_yes_button.pressed.connect(answer_training_prompt.bind(true))
	prompt_no_button.pressed.connect(answer_training_prompt.bind(false))
