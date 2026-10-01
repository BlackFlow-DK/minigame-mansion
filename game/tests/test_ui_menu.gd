extends GameTest
## Menu UI: screen transitions, lobby host/client views, discovery list, join errors, pause.
## Network paths are driven by emitting the Net / Session autoload signals directly.

const MENU_SCENE_PATH := "res://ui/menu/menu_root.tscn"

var menu: MenuRoot


func before_each() -> void:
	Net.leave()
	menu = (load(MENU_SCENE_PATH) as PackedScene).instantiate() as MenuRoot
	add_child(menu)
	await step(1)


func after_each() -> void:
	if is_instance_valid(menu):
		remove_child(menu)
		menu.queue_free()


func _send(ev: InputEvent) -> void:
	Input.parse_input_event(ev)
	await step(2)


func _action(action: StringName) -> void:
	var down := InputEventAction.new()
	down.action = action
	down.pressed = true
	await _send(down)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	await _send(up)


func _neighbor(c: Control, side: StringName) -> Node:
	var p: NodePath = c.get(side)
	return c.get_node_or_null(p) if not p.is_empty() else null


func _host() -> void:
	menu.title.host_button.pressed.emit()
	await step(1)


func _info(slot: int, peer: int, player_name: String, bot: bool) -> PlayerInfo:
	return PlayerInfo.new(slot, peer, player_name, bot, Cosmetics.default_loadout(slot))


func _game(address: String, players: int, in_game: bool = false) -> Dictionary:
	return {"name": "Game at %s" % address, "address": address, "port": Net.DEFAULT_PORT, "players": players, "max_players": 8, "in_game": in_game}


# --- Title ---------------------------------------------------------------------------------

func test_starts_on_title_with_default_focus() -> void:
	assert_eq(menu.screen, MenuRoot.TITLE, "screen")
	assert_true(menu.title.visible and menu.backdrop.visible, "title and backdrop shown")
	assert_false(menu.join.visible or menu.lobby.visible or menu.pause.visible, "other screens hidden")
	assert_true(menu.title.host_button.has_focus(), "Host has focus")
	var t := menu.title
	assert_eq(_neighbor(t.host_button, &"focus_neighbor_bottom"), t.join_button, "Host -> Join")
	assert_eq(_neighbor(t.name_edit, &"focus_neighbor_bottom"), t.host_button, "name -> Host")
	assert_eq(_neighbor(t.quit_button, &"focus_neighbor_bottom"), t.name_edit, "Quit wraps to name")
	assert_eq(_neighbor(t.name_edit, &"focus_neighbor_top"), t.settings_button, "name wraps up to the last row (Settings | Quit)")


func test_wardrobe_button_follows_scene_presence() -> void:
	assert_eq(menu.title.wardrobe_button.visible, ResourceLoader.exists(MenuRoot.WARDROBE_PATH), "wardrobe button visible iff the scene exists")


func test_host_goes_to_lobby_with_name() -> void:
	menu.title.name_edit.text = "  Zed  "
	await _host()
	assert_eq(menu.screen, MenuRoot.LOBBY, "screen")
	assert_true(menu.lobby.visible, "lobby shown")
	assert_false(menu.title.visible or menu.backdrop.visible, "title and backdrop hidden over the 3D lobby")
	assert_eq(Net.roster.size(), 1, "roster")
	assert_eq(Net.roster[Net.local_slot()].name, "Zed", "trimmed name reaches Net")
	assert_eq(menu.lobby.row_count(), 1, "roster rows")
	assert_true(menu.lobby.host_bar.visible, "host controls")


func test_empty_name_falls_back() -> void:
	menu.title.name_edit.text = "   "
	assert_eq(menu.title.player_name(), MenuTitleScreen.DEFAULT_NAME, "fallback name")


# --- Lobby ---------------------------------------------------------------------------------

func test_start_disabled_below_two_players() -> void:
	await _host()
	var lobby := menu.lobby
	# Keep Session out of it (the real one would start a session); the wiring is checked instead.
	assert_true(lobby.start_pressed.is_connected(menu._on_start), "Start is wired to Session.start_session")
	lobby.start_pressed.disconnect(menu._on_start)
	var starts := watch(lobby, &"start_pressed")
	assert_true(lobby.start_button.disabled, "Start disabled with 1 player")
	assert_true(lobby.start_hint.visible, "hint shown")
	lobby.start_button.pressed.emit()
	assert_eq(starts.size(), 0, "no start with 1 player")

	lobby.add_bot_button.pressed.emit()
	await step(1)
	assert_eq(Net.roster.size(), 2, "bot added")
	assert_false(lobby.start_button.disabled, "Start enabled with 2 players")
	assert_false(lobby.start_hint.visible, "hint hidden")
	assert_eq(lobby.selected_rounds, 8, "default rounds")
	lobby.round_buttons[12].button_pressed = true
	lobby.start_button.pressed.emit()
	assert_eq(starts, [[12]], "start with 12 rounds")

	var bot_slot := -1
	for s: int in Net.roster:
		if Net.roster[s].is_bot:
			bot_slot = s
	var rm := lobby.remove_button_for(bot_slot)
	if assert_true(rm != null, "remove button on the bot row"):
		rm.pressed.emit()
		await step(1)
	assert_eq(Net.roster.size(), 1, "bot removed")
	assert_true(lobby.start_button.disabled, "Start disabled again")


func test_add_bot_disabled_when_full() -> void:
	await _host()
	for i in Net.MAX_PLAYERS - 1:
		menu.lobby.add_bot_button.pressed.emit()
	await step(1)
	assert_eq(Net.roster.size(), Net.MAX_PLAYERS, "full roster")
	assert_true(menu.lobby.add_bot_button.disabled, "Add bot disabled at 8")
	assert_eq(menu.lobby.count_label.text, "8/8", "count label")


func test_client_view_hides_host_controls() -> void:
	await _host()
	var roster: Dictionary = {0: _info(0, 1, "Host", false), 1: _info(1, 77, "Me", false), 2: _info(2, 1, "Bot 2", true)}
	var lobby := menu.lobby
	lobby.refresh(roster, 1, false)
	assert_false(lobby.host_bar.visible, "no rounds/start for a client")
	assert_false(lobby.add_bot_button.visible, "no add bot for a client")
	assert_true(lobby.client_bar.visible and lobby.waiting_label.text.containsn("waiting"), "waiting for host")
	assert_eq(lobby.remove_button_for(2), null, "no remove bot for a client")
	assert_eq(lobby.row_count(), 3, "rows")

	lobby.refresh(roster, 0, true)
	assert_true(lobby.host_bar.visible, "host controls back for the host")
	assert_false(lobby.client_bar.visible, "no waiting text for the host")
	assert_true(lobby.remove_button_for(2) != null, "remove bot for the host")
	assert_eq(lobby.remove_button_for(0), null, "humans cannot be removed")


func test_lobby_focus_is_opt_in() -> void:
	await _host()
	menu.lobby.add_bot_button.pressed.emit()
	await step(1)
	var focused := get_viewport().gui_get_focus_owner()
	assert_false(focused != null and menu.lobby.is_ancestor_of(focused), "no focus in the lobby at first (Space/A would press it)")
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.pressed = true
	await _send(tab)
	assert_true(menu.lobby.start_button.has_focus(), "Tab focuses Start")
	assert_eq(_neighbor(menu.lobby.start_button, &"focus_neighbor_left"), menu.lobby.round_buttons[12], "Start <- 12")


func test_session_state_hides_and_restores_lobby() -> void:
	await _host()
	Session.state_changed.emit(Session.State.INTRO)
	assert_eq(menu.screen, MenuRoot.NONE, "hidden outside LOBBY")
	assert_false(menu.lobby.visible, "lobby hidden")
	Session.state_changed.emit(Session.State.PLAYING)
	assert_eq(menu.screen, MenuRoot.NONE, "still hidden")
	Session.state_changed.emit(Session.State.LOBBY)
	assert_eq(menu.screen, MenuRoot.LOBBY, "back in the lobby")
	assert_true(menu.lobby.visible, "lobby shown")


func test_server_closed_returns_to_title_with_message() -> void:
	await _host()
	Net.server_closed.emit()
	assert_eq(menu.screen, MenuRoot.TITLE, "title")
	assert_true(menu.title.message_panel.visible, "message shown")
	assert_true(menu.title.message_label.text.containsn("closed"), "message text: %s" % menu.title.message_label.text)
	menu.title.join_button.pressed.emit()
	await step(1)
	menu.join.back_button.pressed.emit()
	assert_false(menu.title.message_panel.visible, "message cleared after moving on")


func test_leave_returns_to_title() -> void:
	await _host()
	menu.lobby.leave_button.pressed.emit()
	assert_eq(menu.screen, MenuRoot.TITLE, "title")
	assert_true(Net.roster.is_empty(), "left the game")


# --- Pause ---------------------------------------------------------------------------------

func test_pause_menu_in_game() -> void:
	await _action(&"pause")
	assert_false(menu.pause.visible, "no pause on the title")
	await _host()
	Session.state_changed.emit(Session.State.PLAYING)
	await _action(&"pause")
	assert_true(menu.pause.visible, "pause opens in game")
	assert_true(menu.pause.resume_button.has_focus(), "Resume focused")
	assert_false(get_tree().paused, "tree keeps running")
	menu.pause.resume_button.pressed.emit()
	assert_false(menu.pause.visible, "Resume closes")
	await _action(&"pause")
	assert_true(menu.pause.visible, "opens again")
	await _action(&"pause")
	assert_false(menu.pause.visible, "pause toggles closed")
	await _action(&"pause")
	menu.pause.leave_button.pressed.emit()
	assert_false(menu.pause.visible, "closed after leaving")
	assert_eq(menu.screen, MenuRoot.TITLE, "title after Leave game")
	assert_true(Net.roster.is_empty(), "left the game")


# --- Join ----------------------------------------------------------------------------------

func test_join_screen_and_back() -> void:
	menu.title.join_button.pressed.emit()
	await step(1)
	assert_eq(menu.screen, MenuRoot.JOIN, "join screen")
	assert_true(menu.join.visible and menu.backdrop.visible, "join shown")
	assert_false(menu.title.visible, "title hidden")
	assert_true(menu.join.ip_edit.has_focus(), "IP field focused while the list is empty")
	menu.join.back_button.pressed.emit()
	assert_eq(menu.screen, MenuRoot.TITLE, "back to title")
	menu.title.join_button.pressed.emit()
	await step(1)
	await _action(&"ui_cancel")
	assert_eq(menu.screen, MenuRoot.TITLE, "ui_cancel goes back")


func test_discovery_list_updates_and_dedupes() -> void:
	menu.title.join_button.pressed.emit()
	await step(1)
	var join := menu.join
	assert_true(join.empty_label.visible, "empty hint")
	Net.games_found.emit([_game("192.168.1.10", 3), _game("192.168.1.11", 8), _game("192.168.1.10", 3)])
	assert_eq(join.game_count(), 2, "duplicates merged")
	assert_false(join.empty_label.visible, "hint hidden")
	assert_true(join.row_button(0).has_focus(), "first game takes focus from the empty IP field")
	assert_true(join.row_button(1).disabled, "full game cannot be joined")

	Net.games_found.emit([_game("192.168.1.10", 5, true)])
	assert_eq(join.game_count(), 2, "update does not add a row")
	var g := join.listed_games()[0]
	assert_eq(g["players"], 5, "player count updated")
	assert_eq(g["in_game"], true, "state updated")
	var count_l := join.row_button(0).get_child(0).get_node(^"Count") as Label
	assert_eq(count_l.text, "5/8", "row text updated")

	Net.games_found.emit([{"name": "no address"}, "junk", null])
	assert_eq(join.game_count(), 2, "unusable entries ignored")

	join.update_games([_game("10.0.0.9", 1)], 1)
	assert_eq(join.game_count(), 3, "third game")
	join.prune_stale(1 + MenuJoinScreen.STALE_MS + 1)
	assert_eq(join.game_count(), 2, "stale game dropped, fresh ones kept")

	var joins := watch(join, &"join_requested")
	join.row_button(0).pressed.emit()
	assert_eq(joins, [["192.168.1.10"]], "row joins its address")


func test_normalize_game_accepts_variants() -> void:
	var g := MenuJoinScreen.normalize_game({"ip": "1.2.3.4", "players": [1, 2], "state": "playing", "host_name": "Bo"})
	assert_eq(g["address"], "1.2.3.4", "address from ip")
	assert_eq(g["players"], 2, "players from Array")
	assert_eq(g["in_game"], true, "in game from state")
	assert_eq(g["port"], Net.DEFAULT_PORT, "default port")
	assert_eq(g["name"], "Bo", "name from host_name")
	assert_eq(MenuJoinScreen.normalize_game({"name": "x"}), {}, "no address")


func test_join_failed_shows_error() -> void:
	menu.title.join_button.pressed.emit()
	await step(1)
	menu.set_connecting("192.168.1.10")
	assert_true(menu.join.is_connecting(), "connecting")
	assert_true(menu.join.status_row.visible, "status shown")
	assert_true(menu.join.ip_join_button.disabled, "join disabled while connecting")
	Net.join_failed.emit("Server is full")
	assert_false(menu.join.is_connecting(), "no longer connecting")
	assert_false(menu.join.status_row.visible, "status hidden")
	assert_true(menu.join.error_panel.visible, "error shown")
	assert_true(menu.join.error_label.text.contains("Server is full"), "reason shown: %s" % menu.join.error_label.text)
	assert_eq(menu.screen, MenuRoot.JOIN, "stays on join")
	assert_false(menu.join.ip_join_button.disabled, "join enabled again")


func test_version_mismatch_shows_clear_message() -> void:
	menu.title.join_button.pressed.emit()
	await step(1)
	menu.set_connecting("192.168.1.10")
	Net.join_failed.emit(NetProtocol.REASON_VERSION)
	assert_true(menu.join.error_panel.visible, "error shown")
	assert_true(menu.join.error_label.text.contains("different game version"), "clear version text: %s" % menu.join.error_label.text)


func test_empty_ip_shows_error() -> void:
	menu.title.join_button.pressed.emit()
	await step(1)
	var joins := watch(menu.join, &"join_requested")
	menu.join.ip_edit.text = "  "
	menu.join.ip_join_button.pressed.emit()
	assert_eq(joins.size(), 0, "no join without an address")
	assert_true(menu.join.error_panel.visible, "error shown")


func test_joined_when_roster_has_our_slot() -> void:
	menu.title.join_button.pressed.emit()
	await step(1)
	menu.set_connecting("192.168.1.10")
	Net.start_offline()  # stands in for the host's roster arriving: this peer now has a slot
	await step(1)
	assert_eq(menu.screen, MenuRoot.LOBBY, "lobby after joining")
	assert_false(menu.join.is_connecting(), "connecting state cleared")


func test_cancel_connecting() -> void:
	menu.title.join_button.pressed.emit()
	await step(1)
	menu.set_connecting("192.168.1.10")
	menu.join.cancel_button.pressed.emit()
	assert_false(menu.join.is_connecting(), "cancelled")
	assert_false(menu.join.error_panel.visible, "no error on cancel")
	assert_eq(menu.screen, MenuRoot.JOIN, "stays on join")


func test_lan_addresses_are_ipv4_and_not_loopback() -> void:
	for a in MenuRoot.lan_addresses():
		assert_true(a.count(".") == 3, "IPv4: %s" % a)
		assert_false(a.begins_with("127."), "no loopback: %s" % a)
