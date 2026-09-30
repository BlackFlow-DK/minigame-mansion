extends Node3D
## Dev scene for looking at the menu screens (and screenshots). Offline; fakes the network
## paths by emitting the autoload signals. User args:
##   --menu-screen=title|title_msg|join|join_error|join_connecting|lobby|lobby_full|lobby_client|lobby_offline|pause
## e.g. tools/godot-screenshot.ps1 -Scene res://ui/menu/dev/menu_dev.tscn -GameArgs "--menu-screen=lobby"

const MENU_SCENE: PackedScene = preload("res://ui/menu/menu_root.tscn")

var menu: MenuRoot


func _ready() -> void:
	_build_world()
	menu = MENU_SCENE.instantiate() as MenuRoot
	add_child(menu)
	var which := "title"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--menu-screen="):
			which = arg.trim_prefix("--menu-screen=")
	_setup.call_deferred(which)


func _setup(which: String) -> void:
	match which:
		"title":
			pass
		"title_msg":
			Net.start_offline()
			Net.server_closed.emit()
		"join", "join_error", "join_connecting":
			menu.title.join_button.pressed.emit()
			Net.games_found.emit(_fake_games())
			if which == "join_error":
				Net.join_failed.emit("the game is full (8/8 players).")
			elif which == "join_connecting":
				menu.set_connecting("192.168.1.42")
		"lobby", "lobby_full", "lobby_offline", "pause":
			menu.title.set_player_name("Sander")
			menu.title.host_button.pressed.emit()
			var bots := 7 if which == "lobby_full" else 3
			for i in bots:
				Net.add_bot()
			if which == "lobby":
				# What a LAN host sees (the offline stub cannot host yet).
				menu.offline_game = false
				menu.lobby.set_addresses(PackedStringArray(["192.168.1.23", "10.0.0.7"]), false)
			if which == "pause":
				Session.state_changed.emit(Session.State.PLAYING)
				menu.open_pause()
		"lobby_client":
			Net.start_offline()
			menu.show_screen(MenuRoot.LOBBY)
			var roster: Dictionary = {}
			var names := ["Sander", "Mia", "Bot 2", "Jonas with a very long name"]
			for s in names.size():
				roster[s] = PlayerInfo.new(s, [1, 77, 1, 88][s], names[s], s == 2, Cosmetics.default_loadout(s))
			menu.lobby.refresh(roster, 1, false)
			menu.lobby.set_addresses(PackedStringArray(), false)
		_:
			push_warning("menu_dev: unknown --menu-screen=%s" % which)


func _fake_games() -> Array:
	return [
		{"name": "Sander's game", "address": "192.168.1.23", "port": 24565, "players": 3, "max_players": 8, "in_game": false},
		{"name": "Mia's game", "address": "192.168.1.42", "port": 24565, "players": 8, "max_players": 8, "in_game": false},
		{"name": "Jonas's really long named party game room", "address": "192.168.1.77", "port": 24565, "players": 5, "max_players": 8, "in_game": true},
		{"name": "Sander's game", "address": "192.168.1.23", "port": 24565, "players": 4, "max_players": 8, "in_game": false},
	]


## A stand-in for the 3D lobby world so the overlay is judged against something busy.
func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("#8fb8c9")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.7, 0.75)
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 7, 9)
	cam.rotation_degrees = Vector3(-35, 0, 0)
	add_child(cam)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30, 30)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("#c9a978")
	floor_mesh.material_override = fm
	add_child(floor_mesh)
	for i in 5:
		var blob := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.4
		cap.height = 1.0
		blob.mesh = cap
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(Cosmetics.default_loadout(i)["primary"])
		blob.material_override = m
		blob.position = Vector3(-4.0 + i * 2.0, 0.5, sin(i * 1.7) * 1.5)
		add_child(blob)
