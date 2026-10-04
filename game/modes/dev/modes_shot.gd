extends Node
## Dev driver for game-modes screenshots: runs the REAL main scene (child `Main`) offline and
## puts the lobby's Game setup UI on screen. Pair with tools/godot-screenshot.ps1:
##   -Scene res://modes/dev/modes_shot.tscn -GameArgs "--offline --bots=3 --view=setup"
## `--view=`: `setup` (host panel), `practice` (practice page, a game and a mutator picked),
## `client` (the lobby as a client sees it: waiting line plus the host's setup summary).
## Round shots need no driver: main.tscn with `--offline --bots=N --auto-start=R
## [--order=vote] [--mutator=giant] [--round-minigame=id]`.

var _view: String = "setup"
var _done: bool = false

@onready var app: MainApp = $Main


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")


func _process(_delta: float) -> void:
	if _done or not (app.stage.minigame is MansionLobby) or Net.roster.size() < 2:
		return
	_done = true
	var lobby := app.menu.lobby
	match _view:
		"setup":
			lobby.setup_panel.set_order(GameModes.Order.PLAYLIST)
			lobby.setup_panel.set_mutator_mode(Mutators.Mode.SOMETIMES)
			lobby.setup_panel.set_ticked(&"cannon_alley", false)
			lobby.setup_panel.set_ticked(&"hot_potato", false)
			lobby.open_setup()
		"practice":
			lobby.open_setup()
			lobby.setup_panel.show_page(true)
			lobby.setup_panel.practice_buttons[&"bumper_sumo"].button_pressed = true
			lobby.setup_panel.practice_mutator_buttons[&"low_gravity"].button_pressed = true
			lobby.setup_panel.start_practice_button.grab_focus()
		"client":
			Session.configure(8, GameModes.Order.VOTE, [], Mutators.Mode.SOMETIMES)
			var roster: Dictionary = {}
			for s: int in Net.roster:
				var info: PlayerInfo = Net.roster[s]
				roster[s] = PlayerInfo.new(s, 1 if s == 0 else (77 if s == 1 else 1), "Host" if s == 0 else info.name, info.is_bot and s != 1, info.loadout)
			lobby.refresh(roster, 1, false)
			lobby.set_addresses(PackedStringArray(), false, "")
