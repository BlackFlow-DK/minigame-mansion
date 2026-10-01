class_name MenuPauseMenu
extends Control
## Pause menu (Esc / Start): Resume, Leave game, Quit. It never pauses the tree: the game is
## multiplayer and keeps running underneath. Pure view; MenuRoot acts on the signals.
## `configure()`: in the Training Room it offers Skip tutorial instead of Leave game; in the
## lobby (when it is just you and bots) it also offers the Training Room.

signal resume_pressed
signal leave_pressed
signal quit_pressed
signal training_pressed
signal skip_tutorial_pressed

var resume_button: Button
var leave_button: Button
var quit_button: Button
var training_button: Button
var skip_tutorial_button: Button
var note_label: Label

const NOTE_GAME := "The game keeps running for everyone else!"
const NOTE_TRAINING := "Training Room: take your time, or skip straight to the title."


func _init() -> void:
	name = "PauseMenu"
	# While visible the player's blob ignores input (ControllerComponent.INPUT_BLOCKER_GROUP).
	add_to_group(&"blocks_player_input")
	MenuUI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := MenuUI.full_rect(ColorRect.new()) as ColorRect
	dim.color = Color(MenuUI.CHARCOAL, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var center := MenuUI.full_rect(CenterContainer.new())
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	center.add_child(panel)
	var col := MenuUI.vbox(14)
	panel.add_child(col)
	col.add_child(MenuUI.label("Paused", &"HeaderLabel", HORIZONTAL_ALIGNMENT_CENTER))
	note_label = MenuUI.label(NOTE_GAME, &"MutedLabel", HORIZONTAL_ALIGNMENT_CENTER)
	note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(note_label)
	resume_button = MenuUI.button("Resume", &"PrimaryButton")
	skip_tutorial_button = MenuUI.button("Skip tutorial")
	training_button = MenuUI.button("Training Room")
	leave_button = MenuUI.button("Leave game")
	quit_button = MenuUI.button("Quit to desktop", &"DangerButton")
	for b: Button in [resume_button, skip_tutorial_button, training_button, leave_button, quit_button]:
		col.add_child(b)
	skip_tutorial_button.visible = false
	training_button.visible = false
	skip_tutorial_button.pressed.connect(func() -> void: skip_tutorial_pressed.emit())
	training_button.pressed.connect(func() -> void: training_pressed.emit())
	resume_button.pressed.connect(func() -> void: resume_pressed.emit())
	leave_button.pressed.connect(func() -> void: leave_pressed.emit())
	quit_button.pressed.connect(func() -> void: quit_pressed.emit())
	visible = false


## In the Training Room: Skip tutorial instead of Leave game. `can_train`: offer the Training
## Room (the lobby, when nobody else would be left behind).
func configure(in_training: bool, can_train: bool) -> void:
	skip_tutorial_button.visible = in_training
	leave_button.visible = not in_training
	training_button.visible = can_train and not in_training
	note_label.text = NOTE_TRAINING if in_training else NOTE_GAME


func focus_default() -> void:
	MenuUI.chain_vertical([resume_button, skip_tutorial_button, training_button, leave_button, quit_button])
	resume_button.grab_focus()
