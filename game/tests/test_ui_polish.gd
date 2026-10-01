extends GameTest
## UI polish: focus chains without dead ends on every menu screen, the shared button pop and
## screen transitions, the title (version, coins, hierarchy), the lobby overlay (copyable
## addresses, START pulse, translucent scrims, address order), the settings screen reachable
## from the title and the pause menu, and "Show the welcome prompt again".

const MENU_SCENE_PATH := "res://ui/menu/menu_root.tscn"
const FLAG_PATH := "user://test_ui_polish_training.cfg"

var menu: MenuRoot
var _saved_motion: bool = false


func before_each() -> void:
	Net.leave()
	_saved_motion = Settings.reduced_motion
	Settings.reduced_motion = false
	menu = (load(MENU_SCENE_PATH) as PackedScene).instantiate() as MenuRoot
	menu.training_flag_path = FLAG_PATH
	add_child(menu)
	await step(1)


func after_each() -> void:
	Settings.reduced_motion = _saved_motion
	if is_instance_valid(menu):
		remove_child(menu)
		menu.queue_free()
	if FileAccess.file_exists(FLAG_PATH):
		DirAccess.remove_absolute(FLAG_PATH)
	Net.leave()


func _host_with_bots(bots: int) -> void:
	menu.title.host_button.pressed.emit()
	await step(1)
	for i in bots:
		Net.add_bot()
	await step(2)


func _info(slot: int, peer: int, player_name: String, bot: bool) -> PlayerInfo:
	return PlayerInfo.new(slot, peer, player_name, bot, Cosmetics.default_loadout(slot))


## Every control of `chain` points (up/down/left/right/next/previous) at a focusable control
## inside `screen`, and walking "down" from the first visits every row and comes back.
func _check_chain(screen: Control, chain: Array[Control], what: String) -> void:
	assert_true(chain.size() >= 2, "%s: a chain (%d controls)" % [what, chain.size()])
	for c in chain:
		for side: StringName in [&"focus_neighbor_top", &"focus_neighbor_bottom", &"focus_neighbor_left",
				&"focus_neighbor_right", &"focus_next", &"focus_previous"]:
			var p: NodePath = c.get(side)
			var n := c.get_node_or_null(p) as Control if not p.is_empty() else null
			if n == null or not MenuUI.focusable(n) or not screen.is_ancestor_of(n):
				fail("%s: %s.%s leads nowhere (%s)" % [what, c.name, side, p])
				return
	var seen: Dictionary = {}
	var at: Control = chain[0]
	for i in chain.size() * 2:
		seen[at] = true
		at = at.get_node(at.focus_next) as Control
		if at == chain[0]:
			break
	assert_eq(seen.size(), chain.size(), "%s: Tab walks every control once and wraps" % what)
	# Down from the top row reaches the last row and wraps back to the top.
	var down: Control = chain[0]
	var reached_last := false
	for i in chain.size() + 1:
		down = down.get_node(down.focus_neighbor_bottom) as Control
		if down == chain[chain.size() - 1] or down.get_parent() == chain[chain.size() - 1].get_parent():
			reached_last = true
	assert_true(reached_last, "%s: Down reaches the last row" % what)


# --- Focus chains ------------------------------------------------------------------------------

func test_title_focus_chain_and_hierarchy() -> void:
	var t := menu.title
	var chain := t.refresh_focus()
	_check_chain(t, chain, "title")
	assert_true(t.host_button.has_focus(), "Host focused by default")
	assert_eq(t.host_button.theme_type_variation, &"PrimaryButton", "Host is the primary button")
	for b: Button in [t.join_button, t.offline_button]:
		assert_eq(b.theme_type_variation, &"BigButton", "%s is big" % b.text)
	for b: Button in [t.wardrobe_button, t.how_to_play_button, t.settings_button]:
		assert_eq(b.theme_type_variation, &"SecondaryButton", "%s is secondary" % b.text)
	assert_true(t.join_button.get_combined_minimum_size().y > t.settings_button.get_combined_minimum_size().y + 6.0,
		"primary buttons are clearly bigger than secondary ones")
	assert_eq(t.version_label.text, "v" + str(ProjectSettings.get_setting("application/config/version")), "version from project.godot")
	assert_eq(str(ProjectSettings.get_setting("application/config/version")), "0.2", "version 0.2")
	assert_true(t.coin_balance.is_visible_in_tree(), "coin balance on the title")
	# Grid moves: Down from Play offline lands on Wardrobe, Right goes to How to play.
	assert_eq(t.offline_button.get_node(t.offline_button.focus_neighbor_bottom), t.wardrobe_button, "offline -> wardrobe")
	assert_eq(t.wardrobe_button.get_node(t.wardrobe_button.focus_neighbor_right), t.how_to_play_button, "wardrobe -> how to play")
	assert_eq(t.how_to_play_button.get_node(t.how_to_play_button.focus_neighbor_bottom), t.quit_button, "how to play -> quit")
	assert_eq(t.quit_button.get_node(t.quit_button.focus_neighbor_bottom), t.name_edit, "quit wraps to the name")


func test_training_prompt_focus_chain() -> void:
	menu.title.show_training_prompt()
	await step(1)
	_check_chain(menu.title.training_prompt, MenuUI.chain_grid([[menu.title.prompt_yes_button, menu.title.prompt_no_button]]), "prompt")
	assert_true(menu.title.prompt_yes_button.has_focus(), "Yes focused")
	menu.title.answer_training_prompt(false)


func test_join_focus_chain() -> void:
	menu.title.join_button.pressed.emit()
	await step(1)
	menu.join.update_games([{"address": "192.168.1.9", "port": 24565, "game_name": "A", "players": 2, "max_players": 8}])
	await step(1)
	_check_chain(menu.join, menu.join.focus_chain(), "join")
	assert_eq(menu.join.ip_join_button.get_node(menu.join.ip_join_button.focus_neighbor_left), menu.join.ip_edit, "Join <- IP field")
	Net.stop_discovery()


func test_lobby_focus_chain_host_and_client() -> void:
	await _host_with_bots(3)
	menu.offline_game = false
	menu.lobby.set_addresses(PackedStringArray(["192.168.1.23", "10.0.0.7"]), false)
	await step(1)
	_check_chain(menu.lobby, menu.lobby.focus_chain(), "lobby host")
	assert_true(menu.lobby.focus_chain().has(menu.lobby.address_buttons()[0]), "addresses are reachable with a pad")
	var roster: Dictionary = {0: _info(0, 1, "Host", false), 1: _info(1, 77, "Me", false)}
	menu.lobby.refresh(roster, 1, false)
	menu.lobby.set_addresses(PackedStringArray(), false)
	await step(1)
	_check_chain(menu.lobby, menu.lobby.focus_chain(), "lobby client")


func test_pause_focus_chain_and_panel_settles() -> void:
	await _host_with_bots(1)
	Session.state_changed.emit(Session.State.PLAYING)
	menu.open_pause()
	await step(1)
	assert_true(menu.pause.modulate.a < 1.0, "the pause menu fades in")
	await step(30)
	assert_near(menu.pause.modulate.a, 1.0, 0.001, "faded in")
	assert_eq(menu.pause.center.position, Vector2.ZERO, "panel holder back home after the slide")
	assert_eq(menu.pause.center.size, menu.root.size, "panel holder fills the screen")
	_check_chain(menu.pause, menu.pause.refresh_focus(), "pause")
	assert_true(menu.pause.refresh_focus().has(menu.pause.settings_button), "Settings in the pause menu")
	Session.state_changed.emit(Session.State.LOBBY)


func test_settings_focus_chain() -> void:
	menu.open_settings()
	await step(2)
	_check_chain(menu.settings, menu.settings.refresh_focus(), "settings")
	assert_true(menu.settings.sliders[&"master_volume"].has_focus(), "Master volume focused first")
	menu.close_settings()


# --- Motion ------------------------------------------------------------------------------------

func test_buttons_pop_on_focus_and_hover() -> void:
	var b := menu.title.join_button
	b.grab_focus()
	await step(12)
	assert_near(b.scale.x, UiMotion.HOVER_SCALE, 0.005, "focused button pops to 1.04")
	assert_eq(b.pivot_offset, b.size * 0.5, "it grows from its centre")
	menu.title.host_button.grab_focus()
	await step(12)
	assert_near(b.scale.x, 1.0, 0.005, "back to 1.0 when focus leaves")
	Settings.reduced_motion = true
	b.grab_focus()
	await step(12)
	assert_near(b.scale.x, 1.0, 0.005, "reduced motion: no pop")
	# Buttons added later (the lobby roster's remove buttons) are hooked too.
	Settings.reduced_motion = false
	await _host_with_bots(2)
	var rm := menu.lobby.remove_button_for(1)
	assert_true(rm != null and rm.has_meta(&"_ui_motion"), "new buttons get the pop")


func test_screens_fade_and_slide_in() -> void:
	menu.title.join_button.pressed.emit()
	await step(1)
	assert_true(menu.join.modulate.a < 0.5, "join starts faded")
	assert_true(menu.join.position.y > 0.0, "and a little low")
	await step(20)
	assert_near(menu.join.modulate.a, 1.0, 0.001, "fully shown after ~0.25 s")
	assert_eq(menu.join.position, Vector2.ZERO, "in place")
	menu.join.back_button.pressed.emit()
	await step(1)
	assert_true(menu.title.visible and menu.title.modulate.a < 0.5, "title fades back in")
	await step(20)
	assert_near(menu.title.modulate.a, 1.0, 0.001, "title shown")
	assert_eq(menu.title.position, Vector2.ZERO, "title in place")


# --- Lobby ---------------------------------------------------------------------------------------

func test_lan_addresses_prefer_the_home_network() -> void:
	var sorted := MenuRoot.sort_lan_addresses(PackedStringArray(["172.29.208.1", "10.0.0.7", "127.0.0.1",
		"192.168.1.141", "169.254.3.3", "fe80::1", "172.30.144.1"]))
	assert_eq(sorted, PackedStringArray(["192.168.1.141", "10.0.0.7", "172.29.208.1", "172.30.144.1"]), "192.168 first, then 10, then 172")
	assert_eq(MenuRoot.sort_lan_addresses(PackedStringArray(["8.8.4.4"])), PackedStringArray(["8.8.4.4"]), "public only when nothing private")


func test_lobby_address_click_copies_it() -> void:
	await _host_with_bots(1)
	menu.offline_game = false
	menu.lobby.set_addresses(PackedStringArray(["192.168.1.23", "10.0.0.7", "172.29.0.1", "172.30.0.1"]), false)
	await step(1)
	var buttons := menu.lobby.address_buttons()
	assert_eq(buttons.size(), MenuLobbyOverlay.MAX_ADDRESSES, "at most 3 addresses")
	var copied := watch(menu.lobby, &"address_copied")
	buttons[0].pressed.emit()
	assert_eq(copied.size(), 1, "copied")
	assert_eq(copied[0][0], "192.168.1.23", "the clicked address")
	assert_eq(buttons[0].text, "Copied!", "Copied! shown")
	await step(int(MenuLobbyOverlay.COPIED_SECONDS * 60.0) + 10)
	assert_eq(buttons[0].text, "192.168.1.23", "address back after a moment")


func test_start_pulses_for_the_host_when_ready() -> void:
	menu.title.host_button.pressed.emit()
	await step(2)
	assert_false(menu.lobby.is_start_pulsing(), "alone: START disabled, no pulse")
	Net.add_bot()
	await step(2)
	assert_true(menu.lobby.is_start_pulsing(), "two players: START pulses")
	await step(20)
	assert_true(menu.lobby.start_button.scale.x > 1.005, "it really grows (%s)" % menu.lobby.start_button.scale)
	var roster: Dictionary = {0: _info(0, 1, "Host", false), 1: _info(1, 77, "Me", false)}
	menu.lobby.refresh(roster, 1, false)
	assert_false(menu.lobby.is_start_pulsing(), "clients: no pulse")


func test_lobby_overlay_has_no_solid_panels_over_the_hall() -> void:
	await _host_with_bots(7)
	await step(2)
	var solid: Array[String] = []
	var stack: Array[Node] = [menu.lobby]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is PanelContainer:
			var pc := n as PanelContainer
			var sb := pc.get_theme_stylebox(&"panel") as StyleBoxFlat
			if sb and sb.draw_center and sb.bg_color.a > 0.75 and pc.size.x > 200.0:
				solid.append(str(pc.get_path()))
		stack.append_array(n.get_children())
	assert_eq(solid, [] as Array[String], "no big opaque panels")
	assert_true(menu.lobby.scrims.size() >= 3, "scrims behind the blocks")
	for s in menu.lobby.scrims:
		var g := (s.texture as GradientTexture2D).gradient
		assert_true(g.colors[0].a <= 0.7 and g.colors[g.colors.size() - 1].a == 0.0, "scrims are translucent and fade out")
	assert_eq(menu.lobby.row_count(), 8, "8 roster rows")
	var roster_w := menu.lobby.roster_list.size.x
	assert_true(roster_w <= MenuLobbyOverlay.ROSTER_W + 1.0, "roster stays narrow (%d px)" % roster_w)


# --- Settings ------------------------------------------------------------------------------------

func test_settings_from_title_and_back_with_cancel() -> void:
	menu.title.settings_button.pressed.emit()
	await step(2)
	assert_true(menu.is_settings_open(), "settings open")
	assert_false(menu.title.visible, "title hidden under it")
	var cancel := InputEventAction.new()
	cancel.action = &"ui_cancel"
	cancel.pressed = true
	Input.parse_input_event(cancel)
	await step(2)
	cancel = cancel.duplicate()
	cancel.pressed = false
	Input.parse_input_event(cancel)
	await step(2)
	assert_false(menu.is_settings_open(), "Esc / B closes")
	assert_true(menu.title.visible, "title back")
	assert_true(menu.title.settings_button.has_focus(), "focus back on Settings")


func test_settings_from_pause_returns_to_pause() -> void:
	await _host_with_bots(1)
	Session.state_changed.emit(Session.State.PLAYING)
	Session.state = Session.State.PLAYING
	menu.open_pause()
	await step(1)
	menu.pause.settings_button.pressed.emit()
	Session.state = Session.State.LOBBY
	await step(1)
	assert_true(menu.is_settings_open() and not menu.pause.visible, "settings replace the pause menu")
	assert_true(menu.settings.is_in_group(&"blocks_player_input"), "the blob ignores input meanwhile")
	assert_false(menu.settings.name_edit.editable, "no renaming mid-round")
	menu.settings.back_button.pressed.emit()
	await step(1)
	assert_true(menu.pause.visible, "back to the pause menu")
	assert_true(menu.pause.settings_button.has_focus(), "on its Settings button")
	Session.state_changed.emit(Session.State.LOBBY)


func test_settings_name_renames_the_player() -> void:
	menu.persist_profile = false
	menu.open_settings()
	await step(1)
	menu.settings.name_edit.text = "Renamed Blob"
	menu.settings.name_edit.text_submitted.emit("Renamed Blob")
	assert_eq(menu.title.player_name(), "Renamed Blob", "title field follows")
	menu.close_settings()


func test_reset_tutorial_prompt_offers_it_again() -> void:
	menu.persist_profile = true
	var saved_profile := Cosmetics.profile_path
	Cosmetics.profile_path = "user://test_ui_polish_profile.json"
	var f := FileAccess.open(Cosmetics.profile_path, FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	assert_false(menu.offer_training_once(), "an existing profile: no prompt")
	menu.open_settings()
	await step(1)
	menu.settings.reset_tutorial_button.pressed.emit()
	assert_true(menu.settings.reset_tutorial_note.text != "", "a confirmation shows")
	menu.close_settings()
	await step(1)
	assert_true(menu.title.is_training_prompt_visible(), "the prompt greets the player again")
	menu.title.answer_training_prompt(false)
	assert_false(menu.offer_training_once(), "and only once")
	DirAccess.remove_absolute(Cosmetics.profile_path)
	Cosmetics.profile_path = saved_profile
