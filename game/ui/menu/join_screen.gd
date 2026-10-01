class_name MenuJoinScreen
extends Control
## Join screen: live list of LAN games (fed by MenuRoot from `Net.games_found`), manual IP
## fallback, connecting state and join errors. Pure view; MenuRoot acts on the signals.

signal join_requested(address: String)
signal back_pressed
signal cancel_pressed

## A discovered game that has not been reported again for this long is dropped.
const STALE_MS := 6000

var back_button: Button
var list_box: VBoxContainer
var empty_label: Label
var searching_label: Label
var ip_edit: LineEdit
var ip_join_button: Button
var status_row: HBoxContainer
var status_label: Label
var cancel_button: Button
var error_panel: PanelContainer
var error_label: Label

## key "address:port" -> { "game": Dictionary (normalised), "seen": int msec, "button": Button }
var _games: Dictionary = {}
var _connecting: bool = false
var _dots_t: float = 0.0


func _init() -> void:
	name = "JoinScreen"
	MenuUI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var center := MenuUI.full_rect(CenterContainer.new())
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(760, 0)
	center.add_child(panel)
	var col := MenuUI.vbox(12)
	panel.add_child(col)

	var head := MenuUI.hbox(16)
	col.add_child(head)
	back_button = MenuUI.button("Back", &"", 120)
	head.add_child(back_button)
	var title := MenuUI.label("Join a game", &"HeaderLabel")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(title)
	searching_label = MenuUI.label("Searching", &"MutedLabel")
	searching_label.custom_minimum_size = Vector2(120, 0)
	searching_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(searching_label)

	col.add_child(MenuUI.label("Games on your network", &"MutedLabel"))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 230)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	# Margin so the focus ring of a row is not clipped by the scroll area.
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: StringName in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		pad.add_theme_constant_override(side, 9)
	scroll.add_child(pad)
	var list_holder := MenuUI.vbox(10)
	list_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(list_holder)
	empty_label = MenuUI.label("No games found yet. The host must be on the same network (Wi-Fi or cable) and have pressed Host game. "
			+ "Still nothing? Both PCs must allow Minigame Mansion through Windows Firewall on Private AND Public networks; or type the host's IP below.", &"MutedLabel")
	empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	empty_label.custom_minimum_size = Vector2(600, 0)
	list_holder.add_child(empty_label)
	list_box = MenuUI.vbox(10)
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_holder.add_child(list_box)

	col.add_child(HSeparator.new())
	col.add_child(MenuUI.label("Not listed? Type the host's IP address:", &"MutedLabel"))
	var ip_row := MenuUI.hbox(12)
	col.add_child(ip_row)
	ip_edit = LineEdit.new()
	ip_edit.placeholder_text = "for example 192.168.1.23"
	ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip_edit.max_length = 64
	ip_row.add_child(ip_edit)
	ip_join_button = MenuUI.button("Join", &"PrimaryButton", 130)
	ip_row.add_child(ip_join_button)

	status_row = MenuUI.hbox(12)
	status_row.visible = false
	col.add_child(status_row)
	status_label = MenuUI.label("", &"HeaderLabel")
	status_label.add_theme_font_size_override(&"font_size", 24)
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_row.add_child(status_label)
	cancel_button = MenuUI.button("Cancel", &"DangerButton", 130)
	status_row.add_child(cancel_button)

	error_panel = PanelContainer.new()
	error_panel.theme_type_variation = &"ErrorPanel"
	error_label = MenuUI.label("", &"ErrorLabel")
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	error_panel.add_child(error_label)
	error_panel.visible = false
	col.add_child(error_panel)

	back_button.pressed.connect(func() -> void: back_pressed.emit())
	cancel_button.pressed.connect(func() -> void: cancel_pressed.emit())
	ip_join_button.pressed.connect(_on_ip_join)
	ip_edit.text_submitted.connect(func(_t: String) -> void: _on_ip_join())


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_dots_t += delta
	searching_label.text = "Searching" + ".".repeat(int(_dots_t * 2.0) % 4)
	if Engine.get_process_frames() % 30 == 0:
		prune_stale(Time.get_ticks_msec())


## Clears the list, error and connecting state (on entering the screen).
func reset() -> void:
	for key: String in _games.keys():
		_remove_game(key)
	_connecting = false
	status_row.visible = false
	error_panel.visible = false
	_update_empty()
	_set_inputs_enabled(true)


## Merges a `Net.games_found` report into the list. Games are keyed by address:port, so repeats
## update their row instead of adding one. `now_msec` < 0 means the current time.
func update_games(games: Array, now_msec: int = -1) -> void:
	var now := now_msec if now_msec >= 0 else Time.get_ticks_msec()
	var was_empty := _games.is_empty()
	for raw: Variant in games:
		var g := normalize_game(raw)
		if g.is_empty():
			continue
		var key := "%s:%d" % [g["address"], g["port"]]
		if _games.has(key):
			_games[key]["game"] = g
			_games[key]["seen"] = now
			_apply_row(_games[key]["button"] as Button, g)
		else:
			var b := _make_row(g)
			_games[key] = {"game": g, "seen": now, "button": b}
	_update_empty()
	_refresh_focus_links()
	# First games arrived while the untouched IP field held focus: hop to the list.
	if was_empty and not _games.is_empty() and ip_edit.has_focus() and ip_edit.text == "":
		MenuUI.focus_first(list_box.get_children())


## Drops games not reported for STALE_MS.
func prune_stale(now_msec: int) -> void:
	var removed := false
	for key: String in _games.keys():
		if now_msec - int(_games[key]["seen"]) > STALE_MS:
			_remove_game(key)
			removed = true
	if removed:
		_update_empty()
		_refresh_focus_links()


func game_count() -> int:
	return _games.size()


## The normalised game entries, in list order.
func listed_games() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b in list_box.get_children():
		for key: String in _games:
			if _games[key]["button"] == b:
				out.append(_games[key]["game"])
	return out


func row_button(index: int) -> Button:
	return list_box.get_child(index) as Button if index < list_box.get_child_count() else null


## "Connecting to <address>..." with a Cancel button; list and IP entry are disabled meanwhile.
func set_connecting(address: String) -> void:
	_connecting = true
	error_panel.visible = false
	status_label.text = "Connecting to %s..." % address
	status_row.visible = true
	_set_inputs_enabled(false)
	cancel_button.grab_focus()


func is_connecting() -> bool:
	return _connecting


## Leaves the connecting state without an error (Cancel).
func stop_connecting() -> void:
	_connecting = false
	status_row.visible = false
	_set_inputs_enabled(true)
	focus_default()


## Shows a join error and leaves the connecting state.
func show_error(text: String) -> void:
	var was_connecting := _connecting
	_connecting = false
	status_row.visible = false
	_set_inputs_enabled(true)
	error_label.text = text
	error_panel.visible = true
	if was_connecting or not _focus_inside():
		focus_default()


func focus_default() -> void:
	_refresh_focus_links()
	if _connecting:
		cancel_button.grab_focus()
		return
	var first: Array = list_box.get_children()
	first.append_array([ip_edit, back_button])
	MenuUI.focus_first(first)


## Accepts any Dictionary shape Net may send: address|ip|host, port, name|game_name|host_name,
## players|player_count (int or Array), max_players, in_game|state. Returns {} if unusable.
static func normalize_game(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var d := raw as Dictionary
	var address := str(d.get("address", d.get("ip", d.get("host", "")))).strip_edges()
	if address == "":
		return {}
	var players_v: Variant = d.get("players", d.get("player_count", 0))
	var players: int = (players_v as Array).size() if players_v is Array else int(players_v)
	var in_game := false
	if d.has("in_game"):
		in_game = bool(d["in_game"])
	elif d.has("state"):
		var st := str(d["state"]).to_lower()
		in_game = st != "lobby" and st != "0"
	return {
		"address": address,
		"port": int(d.get("port", Net.DEFAULT_PORT)),
		"name": str(d.get("name", d.get("game_name", d.get("host_name", address)))),
		"players": players,
		"max_players": int(d.get("max_players", Net.MAX_PLAYERS)),
		"in_game": in_game,
	}


func _make_row(g: Dictionary) -> Button:
	var b := MenuUI.button("", &"RowButton")
	b.custom_minimum_size = Vector2(0, 56)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := MenuUI.hbox(14)
	MenuUI.full_rect(row)
	row.offset_left = 18
	row.offset_right = -14
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	var name_l := MenuUI.label("", &"")
	name_l.name = "Name"
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_l.add_theme_font_size_override(&"font_size", 22)
	row.add_child(name_l)
	var count_l := MenuUI.label("", &"")
	count_l.name = "Count"
	count_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(count_l)
	var chip := PanelContainer.new()
	chip.name = "Chip"
	chip.theme_type_variation = &"ChipPanel"
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.custom_minimum_size = Vector2(96, 0)
	var chip_l := MenuUI.label("", &"ChipLabel", HORIZONTAL_ALIGNMENT_CENTER)
	chip_l.name = "Label"
	chip_l.add_theme_font_size_override(&"font_size", 16)
	chip.add_child(chip_l)
	row.add_child(chip)
	for n: Control in [name_l, count_l, chip, chip_l]:
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list_box.add_child(b)
	b.pressed.connect(func() -> void:
		if not _connecting:
			join_requested.emit(str(b.get_meta(&"address"))))
	_apply_row(b, g)
	return b


func _apply_row(b: Button, g: Dictionary) -> void:
	var row := b.get_child(0)
	(row.get_node(^"Name") as Label).text = str(g["name"])
	(row.get_node(^"Count") as Label).text = "%d/%d" % [g["players"], g["max_players"]]
	var full: bool = int(g["players"]) >= int(g["max_players"])
	var chip := row.get_node(^"Chip") as PanelContainer
	var chip_l := chip.get_node(^"Label") as Label
	chip_l.text = "FULL" if full else ("IN GAME" if g["in_game"] else "IN LOBBY")
	chip.add_theme_stylebox_override(&"panel", MenuUI.chip_box(MenuUI.RED if full else (MenuUI.PLUM if g["in_game"] else MenuUI.TEAL)))
	b.set_meta(&"address", g["address"])
	b.set_meta(&"full", full)
	b.disabled = full or _connecting
	b.tooltip_text = "%s  (%s)" % [g["name"], g["address"]]


func _remove_game(key: String) -> void:
	var b := _games[key]["button"] as Button
	_games.erase(key)
	if is_instance_valid(b):
		var had_focus := b.has_focus()
		list_box.remove_child(b)
		b.queue_free()
		if had_focus:
			focus_default.call_deferred()


func _update_empty() -> void:
	empty_label.visible = _games.is_empty()


func _set_inputs_enabled(on: bool) -> void:
	ip_edit.editable = on
	ip_join_button.disabled = not on
	for b in list_box.get_children():
		(b as Button).disabled = (not on) or bool(b.get_meta(&"full", false))
	_refresh_focus_links()


func _refresh_focus_links() -> Array[Control]:
	if not is_inside_tree():
		return []
	var rows: Array = [back_button]
	rows.append_array(list_box.get_children())
	rows.append_array([[ip_edit, ip_join_button], cancel_button])
	return MenuUI.chain_grid(rows)


## Every focusable control in navigation order (tests walk it).
func focus_chain() -> Array[Control]:
	return _refresh_focus_links()


func _focus_inside() -> bool:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	return f != null and is_ancestor_of(f)


func _on_ip_join() -> void:
	if _connecting:
		return
	var addr := ip_edit.text.strip_edges()
	if addr == "":
		show_error("Type the host's IP address first (the host sees it in their lobby).")
		ip_edit.grab_focus()
		return
	join_requested.emit(addr)
