extends GameTest
## Game modes UI: the lobby's Game setup (host) vs the summary line (client), setup panel ->
## Session, focus chains on both pages, Esc / B, persistence, Practice from the panel, the vote
## cards and markers, the mutator badge and the intro card's mutator sticker.

const MENU_SCENE_PATH := "res://ui/menu/menu_root.tscn"
const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")
const S := preload("res://session/session.gd")
const SETUP_PATH := "user://test_modes_game_setup.json"

var menu: MenuRoot = null
var arena: Stage = null


func before_each() -> void:
	Net.leave()
	Session.abort_session()
	Session.configure(8, GameModes.Order.SHUFFLE, [], Mutators.Mode.OFF)
	Session.forced_mutator = &""
	Session.scene_override = DEV_ARENA
	Session.order_seed = 99


func after_each() -> void:
	Session.abort_session()
	Session.scene_override = null
	Session.order_seed = -1
	Session.time_scale = 1.0
	Session.forced_mutator = &""
	Session.configure(8, GameModes.Order.SHUFFLE, [], Mutators.Mode.OFF)
	if is_instance_valid(menu):
		remove_child(menu)
		menu.queue_free()
	if arena:
		arena.clear()
		remove_child(arena)
		arena.queue_free()
		arena = null
	if FileAccess.file_exists(SETUP_PATH):
		DirAccess.remove_absolute(SETUP_PATH)
	Net.leave()


func _menu_host(bots: int = 1) -> void:
	menu = (load(MENU_SCENE_PATH) as PackedScene).instantiate() as MenuRoot
	add_child(menu)
	await step(1)
	menu.title.host_button.pressed.emit()
	await step(1)
	for i in bots:
		Net.add_bot()
	await step(2)


func _arena() -> void:
	arena = STAGE_SCENE.instantiate() as Stage
	add_child(arena)


func _offline(count: int) -> void:
	Net.start_offline()
	for i in count - 1:
		Net.add_bot()
	_arena()


func _info(slot: int, peer: int, player_name: String, bot: bool) -> PlayerInfo:
	return PlayerInfo.new(slot, peer, player_name, bot, Cosmetics.default_loadout(slot))


func _overlay() -> ModesOverlay:
	return Session.get_node_or_null(^"ModesOverlay") as ModesOverlay


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


func _press(action: StringName) -> void:
	var down := InputEventAction.new()
	down.action = action
	down.pressed = true
	Input.parse_input_event(down)
	await step(2)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await step(2)


# --- Lobby: host vs client -------------------------------------------------------------------

func test_host_gets_game_setup_and_client_gets_the_summary() -> void:
	await _menu_host(1)
	var lobby := menu.lobby
	assert_true(lobby.setup_button.is_visible_in_tree(), "host: Game setup button")
	assert_eq(lobby.setup_label.text, "8 rounds · Shuffle · Mutators: off", "host summary")
	assert_false(lobby.client_bar.visible, "no client line for the host")
	var roster: Dictionary = {0: _info(0, 1, "Host", false), 1: _info(1, 77, "Me", false)}
	lobby.refresh(roster, 1, false)
	assert_false(lobby.setup_button.is_visible_in_tree(), "client: no Game setup")
	assert_true(lobby.client_bar.visible and lobby.waiting_label.text.containsn("waiting"), "waiting")
	Session.configure(12, GameModes.Order.VOTE, [&"bumper_sumo", &"blob_ball"], Mutators.Mode.SOMETIMES)
	assert_eq(lobby.client_setup_label.text, "12 rounds · Vote (2 games) · Mutators: sometimes", "client sees the host's setup")
	lobby.open_setup()
	assert_false(lobby.setup_panel.is_open(), "a client cannot open the panel")


func test_setup_panel_drives_session_and_start() -> void:
	await _menu_host(1)
	var lobby := menu.lobby
	var panel := lobby.setup_panel
	lobby.open_setup()
	await step(1)
	assert_true(panel.is_open(), "open")
	var f := get_viewport().gui_get_focus_owner()
	assert_true(f != null and panel.is_ancestor_of(f), "focus goes into the panel")
	assert_true(panel.is_in_group(&"blocks_player_input"), "the blob ignores input meanwhile")
	panel.round_buttons[12].button_pressed = true
	assert_eq(lobby.selected_rounds, 12, "rounds -> overlay")
	assert_eq(Session.setup_rounds, 12, "rounds -> Session")
	panel.order_buttons[GameModes.Order.PLAYLIST].button_pressed = true
	assert_eq(Session.order_mode, GameModes.Order.PLAYLIST, "order -> Session")
	panel.mutator_buttons[Mutators.Mode.ALWAYS].button_pressed = true
	assert_eq(Session.mutator_mode, Mutators.Mode.ALWAYS, "mutators -> Session")
	panel.game_buttons[&"hot_potato"].button_pressed = false
	assert_false(Session.playlist.has(&"hot_potato"), "unticked -> not in the playlist")
	assert_eq(Session.playlist.size(), MinigameRegistry.IDS.size() - 1, "the rest ticked")
	panel.none_button.pressed.emit()
	assert_true(lobby.start_button.disabled, "Playlist with nothing ticked: no START")
	assert_true(lobby.start_hint.visible and lobby.start_hint.text.containsn("tick"), "hint says why")
	panel.all_button.pressed.emit()
	assert_false(lobby.start_button.disabled, "All: START again")
	assert_eq(lobby.setup_label.text, "12 rounds · Playlist (%d games) · Mutators: always" % MinigameRegistry.IDS.size(), "summary follows")
	panel.done_button.pressed.emit()
	await step(1)
	assert_false(panel.is_open(), "Done closes")
	assert_false(panel.is_in_group(&"blocks_player_input"), "input back")


func test_setup_panel_focus_chains_and_back_keys() -> void:
	await _menu_host(1)
	var lobby := menu.lobby
	var panel := lobby.setup_panel
	lobby.open_setup()
	await step(2)
	_check_chain(panel, panel.focus_chain(), "setup page")
	assert_true(panel.focus_chain().has(panel.game_buttons[&"bumper_sumo"]), "games reachable with a pad")
	assert_true(panel.round_buttons[8].has_focus(), "focus starts on the current rounds chip")
	panel.practice_button.pressed.emit()
	await step(2)
	assert_true(panel.is_practice_page(), "practice page")
	_check_chain(panel, panel.focus_chain(), "practice page")
	assert_true(panel.focus_chain().has(panel.practice_mutator_buttons[&"giant"]), "mutator chips reachable")
	await _press(&"ui_cancel")
	assert_true(panel.is_open() and not panel.is_practice_page(), "B / Esc: back to the setup page")
	panel.done_button.grab_focus()
	await _press(&"ui_cancel")
	assert_false(panel.is_open(), "B / Esc again: closed")
	assert_true(lobby.setup_button.has_focus(), "focus back on Game setup")
	lobby.focus_default()
	_check_chain(lobby, lobby.focus_chain(), "lobby host")
	assert_true(lobby.focus_chain().has(lobby.setup_button), "Game setup in the lobby chain")


func test_setup_panel_fits_1280x720() -> void:
	await _menu_host(1)
	var panel := menu.lobby.setup_panel
	menu.lobby.open_setup()
	await step(2)
	for practice: bool in [false, true]:
		panel.show_page(practice)
		await step(2)
		var page := panel.practice_page if practice else panel.setup_page
		var bg := page.get_parent().get_parent().get_parent() as Control  # Panel > Margin > VBox > page
		var inner := Rect2(bg.global_position, bg.size)
		for c in panel.focus_chain():
			var r := c.get_global_rect()
			var scroll := c.get_parent().get_parent() as ScrollContainer
			if scroll:
				continue  # grid entries scroll
			assert_true(inner.encloses(r), "%s inside the panel (%s in %s)" % [c.name, r, inner])
		assert_true(bg.size.x <= MenuUI.DESIGN_SIZE.x and bg.size.y <= MenuUI.DESIGN_SIZE.y, "panel fits 1280x720")
		assert_true(page.size.y >= page.get_combined_minimum_size().y - 0.5, "page not squeezed")


func test_setup_persists_for_the_host() -> void:
	var a := GameSetupPanel.new()
	add_child(a)
	a.path = SETUP_PATH
	a.persist = true
	a.set_rounds(4)
	a.set_order(GameModes.Order.VOTE)
	a.set_mutator_mode(Mutators.Mode.SOMETIMES)
	a.set_ticked(&"cannon_alley", false)
	assert_true(FileAccess.file_exists(SETUP_PATH), "saved on change")
	var b := GameSetupPanel.new()
	add_child(b)
	b.path = SETUP_PATH
	b.load_setup()
	assert_eq([b.rounds, b.order, b.mutator_mode], [4, GameModes.Order.VOTE, Mutators.Mode.SOMETIMES], "loaded")
	assert_false(b.ticked().has(&"cannon_alley"), "unticked game stays unticked")
	assert_eq(b.ticked().size(), MinigameRegistry.IDS.size() - 1, "new games would start ticked (only exclusions are stored)")
	var c := GameSetupPanel.new()
	add_child(c)
	assert_false(c.persist, "test / dev runs never write the file")
	for p: Node in [a, b, c]:
		remove_child(p)
		p.queue_free()


# --- Practice from the panel -----------------------------------------------------------------

func test_practice_from_the_panel() -> void:
	await _menu_host(0)
	_arena()
	var lobby := menu.lobby
	var panel := lobby.setup_panel
	var pressed := watch(lobby, &"practice_pressed")
	lobby.open_setup()
	panel.show_page(true)
	panel.practice_buttons[&"bumper_sumo"].button_pressed = true
	assert_true(panel.start_practice_button.disabled, "1 player: sumo needs 2")
	assert_true(panel.practice_hint.text.containsn("needs 2"), "hint")
	Net.add_bot()
	await step(2)
	panel.set_player_count(Net.roster.size())
	assert_false(panel.start_practice_button.disabled, "2 players: go")
	panel.practice_mutator_buttons[&"tiny"].button_pressed = true
	var launches := watch(Session, &"session_launching")
	panel.start_practice_button.pressed.emit()
	await step(1)
	assert_eq(pressed, [[&"bumper_sumo", &"tiny"]], "practice_pressed")
	assert_false(panel.is_open(), "panel closed")
	assert_eq(launches.size(), 1, "the launch beat first (portal flare)")
	assert_eq(Session.state, S.State.LOBBY, "still in the lobby during the beat")
	assert_true(await _wait_until(func() -> bool: return Session.state == S.State.INTRO,
			int(Session.launch_time * 60.0) + 10), "practice round started after the beat")
	assert_true(Session.practice, "as practice")
	assert_eq(Session.round_mutator, &"tiny", "with the mutator")


# --- Vote cards ------------------------------------------------------------------------------

func test_vote_cards_markers_and_input() -> void:
	_offline(4)
	await step(1)
	var overlay := _overlay()
	if not assert_true(overlay != null, "Session has the modes overlay"):
		return
	var vs := overlay.vote_screen
	assert_false(vs.visible, "hidden in the lobby")
	Session.vote_time = 8.0
	Session.configure(2, GameModes.Order.VOTE, [], Mutators.Mode.OFF)
	Session.start_session(2)
	await step(1)
	assert_true(vs.visible, "shown in VOTE")
	assert_eq(vs.cards().size(), 3, "3 cards")
	for i in 3:
		var name_l := vs._card_names[i]
		assert_eq(name_l.text, MinigameCatalog.display_name(Session.vote_candidates[i]), "card %d name" % i)
	assert_eq(vs.cursor, 1, "local marker starts on the middle card")
	assert_false(Session.vote_marks.has(0), "not a vote until moved or locked")
	await _press(&"ui_right")
	assert_eq(vs.cursor, 2, "right")
	assert_eq(Session.vote_marks.get(0, -1), 2, "sent")
	assert_true(vs.marker_slots(2).has(0), "my blob under card 2")
	await _press(&"ui_right")
	assert_eq(vs.cursor, 0, "wraps")
	await _press(&"action")
	assert_true(Session.vote_locked.has(0), "action locks")
	await _press(&"ui_left")
	assert_eq(Session.vote_marks[0], 0, "locked: no more moves")
	for i in 60 * 9:
		if Session.vote_winner >= 0:
			break
		await step(1)
	assert_true(Session.vote_winner >= 0, "decided")
	assert_true(vs.get_title().ends_with("WINS!"), "winner announced (%s)" % vs.get_title())
	var bots := 0
	for i in 3:
		bots += vs.marker_slots(i).size()
	assert_eq(bots, 4, "every player's marker shown")
	assert_true(await _wait_until(func() -> bool: return Session.state == S.State.INTRO, 400), "INTRO follows")
	assert_false(vs.visible, "cards gone")


func _wait_until(cond: Callable, frames: int) -> bool:
	for i in frames:
		if cond.call():
			return true
		await step(1)
	return cond.call()


# --- Mutator badge and sticker ---------------------------------------------------------------

func test_mutator_badge_and_intro_sticker() -> void:
	_offline(3)
	await step(1)
	var overlay := _overlay()
	var card := RoundIntroCard.new()
	add_child(card)
	Session.forced_mutator = &"low_gravity"
	Session.time_scale = 50.0
	Session.start_session(2)
	card.play("Dev Arena", "rule", 0, 2)
	assert_eq(card.get_mutator_text(), "MUTATOR: Low gravity!", "intro sticker")
	assert_eq(overlay.badge_text(), "MUTATOR · LOW GRAVITY", "badge during INTRO")
	assert_true(await _wait_until(func() -> bool: return Session.state == S.State.PLAYING, 600), "playing")
	assert_eq(overlay.badge_text(), "MUTATOR · LOW GRAVITY", "badge while playing")
	var r: Array[int] = [0, 1, 2]
	Session.current_minigame.finish(r)
	assert_eq(overlay.badge_text(), "", "badge gone at RESULTS")
	assert_eq(card.get_mutator_text(), "", "sticker cleared with the mutator")
	Session.forced_mutator = &""
	card.play("Dev Arena", "rule", 1, 2)
	assert_eq(card.get_mutator_text(), "", "no mutator: no sticker")
	remove_child(card)
	card.queue_free()
