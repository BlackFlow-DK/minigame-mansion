class_name MenuLobbyOverlay
extends Control
## Lobby overlay drawn over the 3D lobby world: roster (colour, name, bot tag, host crown),
## host-only controls (rounds 4/8/12, add/remove bot, Start), "Waiting for host" for clients,
## the host's LAN address(es), Wardrobe (change your look; everyone sees it live) and Leave. Pure view: `refresh()` feeds it, signals report clicks.
## The middle of the screen stays clear (and click-through) for the world.

signal start_pressed(rounds: int)
signal add_bot_pressed
signal remove_bot_pressed(slot: int)
signal leave_pressed
signal wardrobe_pressed

const ROUND_CHOICES: Array[int] = [4, 8, 12]
const DEFAULT_ROUNDS := 8
const MIN_PLAYERS := 2

var selected_rounds: int = DEFAULT_ROUNDS
var is_host_view: bool = false

var info_label: Label
var address_label: Label
var leave_button: Button
var wardrobe_button: Button
var count_label: Label
var roster_list: VBoxContainer
var add_bot_button: Button
var host_bar: Control
var client_bar: Control
var waiting_label: Label
var start_button: Button
var start_hint: Label
## rounds -> toggle Button
var round_buttons: Dictionary[int, Button] = {}

var _max_players: int = 8
## slot -> remove Button (bots only, host view only)
var _remove_buttons: Dictionary[int, Button] = {}
var _player_count: int = 0


func _init() -> void:
	name = "LobbyOverlay"
	MenuUI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Top-left: lobby card with address and Leave.
	var info := PanelContainer.new()
	info.position = Vector2(24, 24)
	info.custom_minimum_size = Vector2(330, 0)
	add_child(info)
	var info_col := MenuUI.vbox(8)
	info.add_child(info_col)
	info_col.add_child(MenuUI.label("LOBBY", &"HeaderLabel"))
	info_label = MenuUI.label("", &"MutedLabel")
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_col.add_child(info_label)
	address_label = MenuUI.label("", &"")
	address_label.add_theme_font_size_override(&"font_size", 26)
	address_label.add_theme_color_override(&"font_color", MenuUI.PLUM)
	address_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_col.add_child(address_label)
	var buttons := MenuUI.hbox(10)
	info_col.add_child(buttons)
	wardrobe_button = MenuUI.button("Wardrobe")
	wardrobe_button.custom_minimum_size = Vector2(150, 0)
	buttons.add_child(wardrobe_button)
	leave_button = MenuUI.button("Leave", &"DangerButton")
	leave_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	leave_button.custom_minimum_size = Vector2(140, 0)
	buttons.add_child(leave_button)
	var hint := MenuUI.label("Tab / Select: use this menu", &"MutedLabel")
	hint.add_theme_font_size_override(&"font_size", 15)
	info_col.add_child(hint)

	# Right: players.
	var roster_panel := PanelContainer.new()
	roster_panel.anchor_left = 1.0
	roster_panel.anchor_right = 1.0
	roster_panel.offset_left = -404
	roster_panel.offset_right = -24
	roster_panel.offset_top = 24
	roster_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(roster_panel)
	var roster_col := MenuUI.vbox(8)
	roster_panel.add_child(roster_col)
	var head := MenuUI.hbox()
	roster_col.add_child(head)
	var players_l := MenuUI.label("Players", &"HeaderLabel")
	players_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(players_l)
	count_label = MenuUI.label("0/8", &"HeaderLabel")
	count_label.add_theme_color_override(&"font_color", MenuUI.CHARCOAL)
	head.add_child(count_label)
	roster_list = MenuUI.vbox(6)
	roster_col.add_child(roster_list)
	add_bot_button = MenuUI.button("+ Add bot", &"")
	add_bot_button.add_theme_font_size_override(&"font_size", 22)
	roster_col.add_child(add_bot_button)

	# Bottom centre: start bar (host) / waiting bar (client).
	var bottom := MenuUI.full_rect(CenterContainer.new())
	bottom.anchor_top = 1.0
	bottom.offset_top = -130
	bottom.offset_bottom = -24
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bottom)
	var host_panel := PanelContainer.new()
	host_bar = host_panel
	bottom.add_child(host_panel)
	var host_col := MenuUI.vbox(4)
	host_panel.add_child(host_col)
	var host_row := MenuUI.hbox(14)
	host_col.add_child(host_row)
	var rounds_l := MenuUI.label("Rounds", &"")
	rounds_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	host_row.add_child(rounds_l)
	var group := ButtonGroup.new()
	for r in ROUND_CHOICES:
		var b := MenuUI.button(str(r), &"ChipButton", 64)
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = r == selected_rounds
		b.toggled.connect(func(on: bool) -> void:
			if on:
				selected_rounds = r)
		host_row.add_child(b)
		round_buttons[r] = b
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(10, 0)
	host_row.add_child(spacer)
	start_button = MenuUI.button("START!", &"PrimaryButton", 200)
	host_row.add_child(start_button)
	start_hint = MenuUI.label("Need at least 2 players: add a bot or wait for friends.", &"MutedLabel", HORIZONTAL_ALIGNMENT_CENTER)
	host_col.add_child(start_hint)

	var client_panel := PanelContainer.new()
	client_panel.theme_type_variation = &"DarkPanel"
	client_bar = client_panel
	bottom.add_child(client_panel)
	waiting_label = MenuUI.label("Waiting for the host to start...", &"LightLabel", HORIZONTAL_ALIGNMENT_CENTER)
	waiting_label.add_theme_font_size_override(&"font_size", 28)
	client_panel.add_child(waiting_label)

	leave_button.pressed.connect(func() -> void: leave_pressed.emit())
	wardrobe_button.pressed.connect(func() -> void: wardrobe_pressed.emit())
	add_bot_button.pressed.connect(func() -> void: add_bot_pressed.emit())
	start_button.pressed.connect(func() -> void:
		if _player_count >= MIN_PLAYERS and is_host_view:
			start_pressed.emit(selected_rounds))


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
	start_button.disabled = _player_count < MIN_PLAYERS
	start_hint.visible = start_button.disabled

	_refresh_focus_links()
	if had_focus and not _focus_inside():
		if _remove_buttons.has(focused_slot):
			_remove_buttons[focused_slot].grab_focus()
		else:
			focus_default()


## Address lines for friends; `offline` shows a note instead.
func set_addresses(addresses: PackedStringArray, offline: bool, note: String = "") -> void:
	if offline:
		info_label.text = note if note != "" else "Offline game: friends cannot join."
		address_label.text = ""
		address_label.visible = false
	elif is_host_view:
		if addresses.is_empty():
			info_label.text = "Friends on your network will see this game in their Join list."
			address_label.visible = false
		else:
			info_label.text = "Friends can join at:"
			address_label.text = "\n".join(addresses)
			address_label.visible = true
	else:
		info_label.text = note if note != "" else "You joined this game. Run around while you wait!"
		address_label.visible = false


func remove_button_for(slot: int) -> Button:
	return _remove_buttons.get(slot, null)


func row_count() -> int:
	return roster_list.get_child_count()


func focus_default() -> void:
	_refresh_focus_links()
	MenuUI.focus_first([start_button, add_bot_button, leave_button])


func _make_row(info: PlayerInfo, is_me: bool, host_view: bool) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"RowPanel"
	panel.custom_minimum_size = Vector2(0, 44)
	var row := MenuUI.hbox(10)
	panel.add_child(row)
	var colour := Color.from_string(str(info.loadout.get("primary", "")), Color(MenuUI.TEAL))
	row.add_child(MenuIcon.blob(colour, 30))
	var name_l := MenuUI.label(info.name + ("  (you)" if is_me else ""), &"")
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.clip_text = true
	name_l.custom_minimum_size = Vector2(60, 0)
	row.add_child(name_l)
	if info.is_bot:
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override(&"panel", MenuUI.chip_box(MenuUI.TEAL))
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		chip.add_child(MenuUI.label("BOT", &"ChipLabel", HORIZONTAL_ALIGNMENT_CENTER))
		row.add_child(chip)
	elif info.peer_id == 1:
		row.add_child(MenuIcon.crown(28))
	if info.is_bot and host_view:
		var rm := MenuUI.button("X", &"SmallButton")
		rm.custom_minimum_size = Vector2(38, 32)
		rm.tooltip_text = "Remove %s" % info.name
		var slot := info.slot
		rm.pressed.connect(func() -> void: remove_bot_pressed.emit(slot))
		row.add_child(rm)
		_remove_buttons[info.slot] = rm
	return panel


func _refresh_focus_links() -> void:
	if not is_inside_tree():
		return
	var order: Array = []
	var slots: Array = _remove_buttons.keys()
	slots.sort()
	for s: int in slots:
		order.append(_remove_buttons[s])
	order.append(add_bot_button)
	var first_round: Button = round_buttons[ROUND_CHOICES[0]]
	order.append_array([first_round, start_button, wardrobe_button, leave_button])
	var live := MenuUI.chain_vertical(order)
	# The rounds chips and Start share a row: left/right walks it, up/down leaves it.
	var row: Array = []
	for r in ROUND_CHOICES:
		row.append(round_buttons[r])
	row.append(start_button)
	var i := live.find(first_round)
	if i >= 0 and live.size() > 1:
		var above := live[(i - 1 + live.size()) % live.size()]
		var below: Control = wardrobe_button if MenuUI.focusable(wardrobe_button) 				else (leave_button if MenuUI.focusable(leave_button) else null)
		MenuUI.chain_horizontal(row, above, below)
		if MenuUI.focusable(start_button):
			start_button.focus_neighbor_top = start_button.get_path_to(above)


func _focus_inside() -> bool:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	return f != null and is_ancestor_of(f)
