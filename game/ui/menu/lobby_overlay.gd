class_name MenuLobbyOverlay
extends Control
## Lobby overlay drawn over the 3D lobby world: roster (colour, name, bot tag, host crown),
## host-only controls (Game setup: rounds, order, playlist, mutators, practice in a panel
## (GameSetupPanel); add/remove bot; a pulsing START), "Waiting for host" plus the host's setup
## summary for clients, the host's LAN address(es) (click one to copy it: "Copied!"), your Mansion Coins,
## Wardrobe (change your look; everyone sees it live) and Leave. Pure view: `refresh()` feeds
## it, signals report clicks. Game modes: the setup panel's choices go to `Session.configure`
## (host) and Practice to `Session.start_practice`; clients read `Session` for their summary line.
## No solid panels: every block sits on a soft dark scrim (a gradient that fades out), so blobs
## standing at the screen edges stay visible through it, and the middle stays clear (and
## click-through) for the world.

signal start_pressed(rounds: int)
signal add_bot_pressed
signal remove_bot_pressed(slot: int)
signal leave_pressed
signal wardrobe_pressed
## An address was copied to the clipboard.
signal address_copied(address: String)
## Host: Practice started from the setup panel (Session.start_practice is called too).
signal practice_pressed(id: StringName, mutator: StringName)

const ROUND_CHOICES: Array[int] = [4, 8, 12]
const DEFAULT_ROUNDS := 8
const MIN_PLAYERS := 2
## Seconds "Copied!" shows on an address button.
const COPIED_SECONDS := 1.4
const MAX_ADDRESSES := 3
const ROSTER_W := 300.0
const INFO_W := 330.0

var selected_rounds: int = DEFAULT_ROUNDS
var is_host_view: bool = false

var info_label: Label
## The address buttons' holder ("Friends can join at" block).
var address_box: VBoxContainer
var leave_button: Button
var wardrobe_button: Button
## Your Mansion Coins (top-left, beside "LOBBY").
var coin_balance: CoinBalance
var count_label: Label
var roster_list: VBoxContainer
var add_bot_button: Button
var host_bar: Control
var client_bar: Control
var waiting_label: Label
var start_button: Button
var start_hint: Label
## rounds -> toggle Button (in the setup panel)
var round_buttons: Dictionary[int, Button] = {}
## Host: opens the Game setup panel.
var setup_button: Button
## Host: the setup in one line under START; clients: the host's setup under "Waiting...".
var setup_label: Label
var client_setup_label: Label
var setup_panel: GameSetupPanel
## The soft dark gradients behind each block (tests check they stay translucent).
var scrims: Array[TextureRect] = []

var _max_players: int = 8
## slot -> remove Button (bots only, host view only)
var _remove_buttons: Dictionary[int, Button] = {}
var _player_count: int = 0
var _info_block: VBoxContainer
var _roster_block: VBoxContainer
var _roster_scrim: TextureRect
var _info_scrim: TextureRect
## The setup was sent to Session since this peer became the host view.
var _setup_pushed: bool = false


func _init() -> void:
	name = "LobbyOverlay"
	MenuUI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Scrims first (drawn under the blocks).
	_info_scrim = _scrim(Vector2(0.0, 0.0), Vector2(1.0, 0.0))
	_info_scrim.position = Vector2.ZERO
	add_child(_info_scrim)
	_roster_scrim = _scrim(Vector2(1.0, 0.0), Vector2(0.0, 0.0))
	_roster_scrim.anchor_left = 1.0
	_roster_scrim.anchor_right = 1.0
	add_child(_roster_scrim)
	var bottom_scrim := _scrim(Vector2(0.5, 1.0), Vector2(1.0, 1.0))
	bottom_scrim.anchor_left = 0.5
	bottom_scrim.anchor_right = 0.5
	bottom_scrim.anchor_top = 1.0
	bottom_scrim.anchor_bottom = 1.0
	bottom_scrim.offset_left = -470.0
	bottom_scrim.offset_right = 470.0
	bottom_scrim.offset_top = -300.0
	add_child(bottom_scrim)

	# Top-left: LOBBY, coins, how friends join, Wardrobe / Leave.
	_info_block = MenuUI.vbox(8)
	_info_block.position = Vector2(24, 18)
	_info_block.custom_minimum_size = Vector2(INFO_W, 0)
	_info_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_info_block)
	var info_head := MenuUI.hbox(12)
	_info_block.add_child(info_head)
	var lobby_l := MenuUI.label("LOBBY", &"ScrimHeader")
	info_head.add_child(lobby_l)
	coin_balance = CoinBalance.make(18)
	coin_balance.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info_head.add_child(coin_balance)
	info_label = MenuUI.label("", &"ScrimLabel")
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_label.custom_minimum_size = Vector2(INFO_W, 0)
	_info_block.add_child(info_label)
	address_box = MenuUI.vbox(6)
	_info_block.add_child(address_box)
	var buttons := MenuUI.hbox(10)
	_info_block.add_child(buttons)
	wardrobe_button = MenuUI.button("Wardrobe", &"SecondaryButton", 150)
	buttons.add_child(wardrobe_button)
	leave_button = MenuUI.button("Leave", &"SecondaryDangerButton", 120)
	buttons.add_child(leave_button)
	var hint := MenuUI.label("Tab / Select: use this menu", &"ScrimLabel")
	hint.add_theme_font_size_override(&"font_size", 15)
	hint.modulate.a = 0.85
	_info_block.add_child(hint)

	# Top-right: players.
	_roster_block = MenuUI.vbox(5)
	_roster_block.anchor_left = 1.0
	_roster_block.anchor_right = 1.0
	_roster_block.offset_left = -24.0 - ROSTER_W
	_roster_block.offset_right = -24.0
	_roster_block.offset_top = 18.0
	_roster_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_roster_block)
	var head := MenuUI.hbox()
	_roster_block.add_child(head)
	var players_l := MenuUI.label("Players", &"ScrimHeader")
	players_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(players_l)
	count_label = MenuUI.label("0/8", &"ScrimHeader")
	count_label.add_theme_color_override(&"font_color", MenuUI.GOLD)
	head.add_child(count_label)
	roster_list = MenuUI.vbox(4)
	roster_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_roster_block.add_child(roster_list)
	add_bot_button = MenuUI.button("+ Add bot", &"SecondaryButton")
	_roster_block.add_child(add_bot_button)
	_roster_block.resized.connect(_fit_scrims)
	_info_block.resized.connect(_fit_scrims)

	# Bottom centre: start bar (host) / waiting text (client).
	var bottom := MenuUI.full_rect(CenterContainer.new())
	bottom.anchor_top = 1.0
	bottom.offset_top = -138
	bottom.offset_bottom = -12
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bottom)
	var host_col := MenuUI.vbox(4)
	host_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host_bar = host_col
	bottom.add_child(host_col)
	var host_row := MenuUI.hbox(12)
	host_row.alignment = BoxContainer.ALIGNMENT_CENTER
	host_col.add_child(host_row)
	setup_panel = GameSetupPanel.new()
	round_buttons = setup_panel.round_buttons
	selected_rounds = setup_panel.rounds
	setup_button = MenuUI.button("Game setup", &"BigButton", 230)
	setup_button.tooltip_text = "Rounds, order, playlist, mutators, practice"
	host_row.add_child(setup_button)
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(14, 0)
	host_row.add_child(spacer)
	start_button = MenuUI.button("START!", &"PrimaryButton", 210)
	host_row.add_child(start_button)
	setup_label = MenuUI.label("", &"ScrimLabel", HORIZONTAL_ALIGNMENT_CENTER)
	host_col.add_child(setup_label)
	start_hint = MenuUI.label("Need at least 2 players: add a bot or wait for friends.", &"ScrimLabel", HORIZONTAL_ALIGNMENT_CENTER)
	host_col.add_child(start_hint)

	var client_col := MenuUI.vbox(4)
	client_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	client_bar = client_col
	bottom.add_child(client_col)
	waiting_label = MenuUI.label("Waiting for the host to start...", &"ScrimHeader", HORIZONTAL_ALIGNMENT_CENTER)
	waiting_label.add_theme_font_size_override(&"font_size", 28)
	client_col.add_child(waiting_label)
	client_setup_label = MenuUI.label("", &"ScrimLabel", HORIZONTAL_ALIGNMENT_CENTER)
	client_col.add_child(client_setup_label)

	# Last: the setup panel draws over everything else.
	add_child(setup_panel)
	setup_panel.setup_changed.connect(_on_setup_changed)
	setup_panel.practice_requested.connect(_on_practice_requested)
	setup_panel.closed.connect(func(had_focus: bool) -> void:
		if had_focus and is_visible_in_tree():
			_refresh_focus_links()
			setup_button.grab_focus())
	setup_button.pressed.connect(open_setup)

	leave_button.pressed.connect(func() -> void: leave_pressed.emit())
	wardrobe_button.pressed.connect(func() -> void: wardrobe_pressed.emit())
	add_bot_button.pressed.connect(func() -> void: add_bot_pressed.emit())
	start_button.pressed.connect(func() -> void:
		if _player_count >= MIN_PLAYERS and is_host_view and setup_panel.can_start():
			start_pressed.emit(selected_rounds))
	visibility_changed.connect(_update_pulse)
	visibility_changed.connect(func() -> void:
		if not is_visible_in_tree():
			setup_panel.close())


func _ready() -> void:
	_fit_scrims.call_deferred()
	Session.setup_changed.connect(_refresh_setup_labels)
	_refresh_setup_labels()


## Host: opens the Game setup panel (focus goes into it).
func open_setup() -> void:
	if not is_host_view:
		return
	setup_panel.set_player_count(_player_count)
	setup_panel.open()


func _on_setup_changed(rounds: int, order: int, ticked: Array, mutators: int) -> void:
	selected_rounds = rounds
	if is_host_view:
		Session.configure(rounds, order, ticked, mutators)
	_refresh_setup_labels()
	refresh_start()


func _on_practice_requested(id: StringName, mutator: StringName) -> void:
	if not is_host_view:
		return
	setup_panel.close()
	practice_pressed.emit(id, mutator)
	Session.start_practice(id, mutator)


## The summary lines: the host's own panel, or what the host sent (clients).
func _refresh_setup_labels() -> void:
	setup_label.text = setup_panel.summary()
	var games := Session.playlist.size() if not Session.playlist.is_empty() else MinigameCatalog.playable().size()
	client_setup_label.text = GameModes.summary(Session.setup_rounds, Session.order_mode, Session.mutator_mode, games)


## START: enabled with enough players and a usable setup; the hint says why not.
func refresh_start() -> void:
	start_button.disabled = _player_count < MIN_PLAYERS or not setup_panel.can_start()
	if _player_count < MIN_PLAYERS:
		start_hint.text = "Need at least 2 players: add a bot or wait for friends."
	else:
		start_hint.text = "Tick at least one game in Game setup."
	start_hint.visible = start_button.disabled
	_update_pulse()


## Rebuilds the view. `roster`: slot -> PlayerInfo (Net.roster). `local_slot`: this peer's
## human (-1 if none). `is_host`: show the host controls.
func refresh(roster: Dictionary, local_slot: int, is_host: bool, max_players: int = 8) -> void:
	is_host_view = is_host
	_max_players = max_players
	var had_focus := _focus_inside()
	var focused_slot := -1
	var owner_focus := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	for s: int in _remove_buttons:
		if _remove_buttons[s] == owner_focus:
			focused_slot = s

	for c in roster_list.get_children():
		roster_list.remove_child(c)
		c.queue_free()
	_remove_buttons.clear()

	var slots: Array = roster.keys()
	slots.sort()
	for s: int in slots:
		roster_list.add_child(_make_row(roster[s], s == local_slot, is_host))
	_player_count = slots.size()

	count_label.text = "%d/%d" % [_player_count, max_players]
	host_bar.visible = is_host
	client_bar.visible = not is_host
	add_bot_button.visible = is_host
	add_bot_button.disabled = _player_count >= max_players
	setup_panel.set_player_count(_player_count)
	if not is_host:
		setup_panel.close()
		_setup_pushed = false
	elif not _setup_pushed:
		# This peer hosts now: its saved (or dev-arg) setup becomes the session's.
		_setup_pushed = true
		Session.configure(setup_panel.rounds, setup_panel.order, setup_panel.ticked(), setup_panel.mutator_mode)
	_refresh_setup_labels()
	refresh_start()

	_refresh_focus_links()
	if had_focus and not _focus_inside():
		if _remove_buttons.has(focused_slot):
			_remove_buttons[focused_slot].grab_focus()
		else:
			focus_default()


## Address lines for friends; `offline` shows a note instead. Each address is a button that
## copies it to the clipboard.
func set_addresses(addresses: PackedStringArray, offline: bool, note: String = "") -> void:
	for c in address_box.get_children():
		address_box.remove_child(c)
		c.queue_free()
	if offline:
		info_label.text = note if note != "" else "Offline game: friends cannot join."
	elif is_host_view:
		if addresses.is_empty():
			info_label.text = "Friends on your network will see this game in their Join list."
		else:
			info_label.text = "Friends can join at (click to copy):"
			for i in mini(addresses.size(), MAX_ADDRESSES):
				address_box.add_child(_make_address_button(addresses[i]))
	else:
		info_label.text = note if note != "" else "You joined this game. Run around while you wait!"
	address_box.visible = address_box.get_child_count() > 0
	_refresh_focus_links()


## The address buttons, in order.
func address_buttons() -> Array[Button]:
	var out: Array[Button] = []
	for c in address_box.get_children():
		if c is Button and not c.is_queued_for_deletion():
			out.append(c as Button)
	return out


## Copies `address` to the clipboard and flashes "Copied!" on its button.
func copy_address(address: String) -> void:
	DisplayServer.clipboard_set(address)
	for b in address_buttons():
		if str(b.get_meta(&"address", "")) == address:
			b.text = "Copied!"
			var t := b.create_tween()
			t.tween_interval(COPIED_SECONDS)
			t.tween_callback(func() -> void:
				if is_instance_valid(b):
					b.text = address)
	address_copied.emit(address)


func remove_button_for(slot: int) -> Button:
	return _remove_buttons.get(slot, null)


func row_count() -> int:
	return roster_list.get_child_count()


func focus_default() -> void:
	if setup_panel.is_open():
		setup_panel.focus_default()
		return
	_refresh_focus_links()
	MenuUI.focus_first([start_button, setup_button, add_bot_button, wardrobe_button, leave_button])


## Every focusable control in navigation order (tests walk it).
func focus_chain() -> Array[Control]:
	return _refresh_focus_links()


func _make_row(info: PlayerInfo, is_me: bool, host_view: bool) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"ScrimRow"
	panel.custom_minimum_size = Vector2(0, 36)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := MenuUI.hbox(8)
	panel.add_child(row)
	var colour := Color.from_string(str(info.loadout.get("primary", "")), Color(MenuUI.TEAL))
	row.add_child(MenuIcon.blob(colour, 26))
	var name_l := MenuUI.label(info.name + ("  (you)" if is_me else ""), &"ScrimLabel")
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.clip_text = true
	name_l.custom_minimum_size = Vector2(60, 0)
	name_l.tooltip_text = info.name
	name_l.mouse_filter = Control.MOUSE_FILTER_PASS
	if is_me:
		name_l.add_theme_color_override(&"font_color", MenuUI.GOLD)
	row.add_child(name_l)
	if info.is_bot:
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override(&"panel", MenuUI.chip_box(MenuUI.TEAL))
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		chip.add_child(MenuUI.label("BOT", &"ChipLabel", HORIZONTAL_ALIGNMENT_CENTER))
		row.add_child(chip)
	elif info.peer_id == 1:
		row.add_child(MenuIcon.crown(24))
	if info.is_bot and host_view:
		var rm := MenuUI.button("X", &"SmallButton")
		rm.custom_minimum_size = Vector2(32, 28)
		rm.add_theme_font_size_override(&"font_size", 16)
		rm.tooltip_text = "Remove %s" % info.name
		var slot := info.slot
		rm.pressed.connect(func() -> void: remove_bot_pressed.emit(slot))
		row.add_child(rm)
		_remove_buttons[info.slot] = rm
	return panel


func _make_address_button(address: String) -> Button:
	var b := MenuUI.button(address, &"CopyButton")
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.set_meta(&"address", address)
	b.set_meta(&"sfx_press", &"ui_click")
	b.tooltip_text = "Click to copy %s" % address
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(copy_address.bind(address))
	return b


## A soft dark gradient: darkest at `from` (UV in the rect), clear at the distance of `to`
## (an ellipse that reaches 0 at the rect's edges).
func _scrim(from: Vector2, to: Vector2) -> TextureRect:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 0.8, 1.0])
	g.colors = PackedColorArray([Color(MenuUI.CHARCOAL, 0.68), Color(MenuUI.CHARCOAL, 0.55),
		Color(MenuUI.CHARCOAL, 0.25), Color(MenuUI.CHARCOAL, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = from
	tex.fill_to = to
	tex.width = 128
	tex.height = 128
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scrims.append(r)
	return r


## Sizes the corner scrims to their blocks (plus a soft margin).
func _fit_scrims() -> void:
	var info_size := _info_block.size + Vector2(170, 130)
	_info_scrim.size = info_size
	var rs := _roster_block.size + Vector2(170, 130)
	_roster_scrim.offset_left = -rs.x
	_roster_scrim.offset_right = 0.0
	_roster_scrim.offset_top = 0.0
	_roster_scrim.offset_bottom = rs.y


## START pulses for the host while it can be pressed.
func _update_pulse() -> void:
	var want := is_visible_in_tree() and is_host_view and not start_button.disabled
	if want:
		UiMotion.pulse(start_button)
	else:
		UiMotion.stop_pulse(start_button)


## True while START is pulsing.
func is_start_pulsing() -> bool:
	return UiMotion.is_pulsing(start_button)


func _refresh_focus_links() -> Array[Control]:
	if not is_inside_tree():
		return []
	var rows: Array = []
	for b in address_buttons():
		rows.append(b)
	rows.append([wardrobe_button, leave_button])
	var slots: Array = _remove_buttons.keys()
	slots.sort()
	for s: int in slots:
		rows.append(_remove_buttons[s])
	rows.append(add_bot_button)
	rows.append([setup_button, start_button])
	return MenuUI.chain_grid(rows)


func _focus_inside() -> bool:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	return f != null and is_ancestor_of(f)
