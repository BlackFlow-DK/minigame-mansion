class_name MenuPauseMenu
extends Control
## Pause menu (Esc / Start): Resume, Leave game, Quit. It never pauses the tree: the game is
## multiplayer and keeps running underneath. Pure view; MenuRoot acts on the signals.

signal resume_pressed
signal leave_pressed
signal quit_pressed

var resume_button: Button
var leave_button: Button
var quit_button: Button


func _init() -> void:
	name = "PauseMenu"
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
	var note := MenuUI.label("The game keeps running for everyone else!", &"MutedLabel", HORIZONTAL_ALIGNMENT_CENTER)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(note)
	resume_button = MenuUI.button("Resume", &"PrimaryButton")
	leave_button = MenuUI.button("Leave game")
	quit_button = MenuUI.button("Quit to desktop", &"DangerButton")
	for b: Button in [resume_button, leave_button, quit_button]:
		col.add_child(b)
	resume_button.pressed.connect(func() -> void: resume_pressed.emit())
	leave_button.pressed.connect(func() -> void: leave_pressed.emit())
	quit_button.pressed.connect(func() -> void: quit_pressed.emit())
	visible = false


func focus_default() -> void:
	MenuUI.chain_vertical([resume_button, leave_button, quit_button])
	resume_button.grab_focus()
