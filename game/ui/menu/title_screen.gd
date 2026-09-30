class_name MenuTitleScreen
extends Control
## Title screen: logo, name entry, Host / Join / Play offline / Wardrobe / Quit. Pure view; MenuRoot acts on the signals.

signal host_pressed
signal join_pressed
signal offline_pressed
signal wardrobe_pressed
signal quit_pressed
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
	for b: Button in [host_button, join_button, offline_button, wardrobe_button, quit_button]:
		col.add_child(b)

	host_button.pressed.connect(func() -> void: host_pressed.emit())
	join_button.pressed.connect(func() -> void: join_pressed.emit())
	offline_button.pressed.connect(func() -> void: offline_pressed.emit())
	wardrobe_button.pressed.connect(func() -> void: wardrobe_pressed.emit())
	quit_button.pressed.connect(func() -> void: quit_pressed.emit())
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
	refresh_focus()


## Shows `text` in a red banner above the name (empty hides it).
func show_message(text: String) -> void:
	message_label.text = text
	message_panel.visible = text != ""


func refresh_focus() -> void:
	MenuUI.chain_vertical([name_edit, host_button, join_button, offline_button, wardrobe_button, quit_button])


func focus_default() -> void:
	refresh_focus()
	MenuUI.focus_first([host_button, join_button])


func _on_name_submitted(_text: String) -> void:
	name_committed.emit(player_name())
	host_button.grab_focus()
