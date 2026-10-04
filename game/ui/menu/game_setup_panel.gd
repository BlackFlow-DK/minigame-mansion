class_name GameSetupPanel
extends Control
## The host's "Game setup" panel over the lobby (game modes): Rounds 4/8/12, Order (Shuffle /
## Playlist / Vote), Mutators (Off / Sometimes / Always), the playlist grid (tick the games
## Playlist and Vote draw from; All / None) and Practice (a scrollable grid of every game plus a
## mutator pick, then "Start practice"). Pure view plus its own small save file: the lobby
## overlay turns its signals into Session calls. Gamepad navigable (focus rows, gold ring),
## Esc / B closes (or goes back from the practice page). Fits 1280x720.

signal setup_changed(rounds: int, order: int, ticked: Array, mutators: int)
signal practice_requested(id: StringName, mutator: StringName)
## `had_focus`: a control in the panel had keyboard / pad focus (give it back to the opener).
signal closed(had_focus: bool)

const PATH := "user://game_setup.json"
const PANEL_SIZE := Vector2(980, 640)
const GRID_COLUMNS := 3
const GAME_BUTTON_W := 296.0

var rounds: int = 8
var order: int = GameModes.Order.SHUFFLE
var mutator_mode: int = Mutators.Mode.OFF
## Unticked ids (stored this way round, so a new minigame starts ticked).
var excluded: Array[StringName] = []
var practice_id: StringName = &""
var practice_mutator: StringName = &""
## Where the setup is saved (tests point it elsewhere); off for test and dev runs.
var path: String = PATH
var persist: bool = true

var round_buttons: Dictionary[int, Button] = {}
var order_buttons: Array[Button] = []
var mutator_buttons: Array[Button] = []
## id -> toggle Button in the playlist grid.
var game_buttons: Dictionary[StringName, Button] = {}
var all_button: Button
var none_button: Button
var practice_button: Button
var done_button: Button
## Practice page.
var practice_page: Control
var setup_page: Control
## id -> Button in the practice grid.
var practice_buttons: Dictionary[StringName, Button] = {}
## mutator id (&"" = none) -> chip.
var practice_mutator_buttons: Dictionary[StringName, Button] = {}
var start_practice_button: Button
var back_button: Button
var practice_hint: Label
var games_note: Label

var _player_count: int = 1
var _bg: Panel
var _title: Label


func _init() -> void:
	name = "GameSetupPanel"
	MenuUI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# The Settings autoload already knows test and dev runs (it does not save then either).
	var settings := _autoload(&"Settings")
	persist = settings != null and bool(settings.get(&"persist"))
	if persist:
		load_setup()
	else:
		_from_session()
	_build()
	_sync_buttons()


static func _autoload(autoload_name: StringName) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(NodePath(String(autoload_name))) if tree else null


# --- Public ------------------------------------------------------------------------------------

func open() -> void:
	show_page(false)
	visible = true
	add_to_group(&"blocks_player_input")
	UiMotion.enter(self, _bg)
	focus_default()


func close() -> void:
	if not visible:
		return
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var had_focus := f != null and is_ancestor_of(f)
	visible = false
	if is_in_group(&"blocks_player_input"):
		remove_from_group(&"blocks_player_input")
	closed.emit(had_focus)


func is_open() -> bool:
	return visible


## The practice page (true) or the setup page.
func show_page(practice: bool) -> void:
	practice_page.visible = practice
	setup_page.visible = not practice
	_title.text = "PRACTICE" if practice else "GAME SETUP"
	_refresh_focus()
	if visible:
		focus_default()


func is_practice_page() -> bool:
	return practice_page.visible


## The players in the lobby now (greys out games that need more, gates Start practice).
func set_player_count(count: int) -> void:
	_player_count = maxi(1, count)
	_sync_buttons()


## Ticked ids in registry order.
func ticked() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in MinigameCatalog.playable():
		if not excluded.has(id):
			out.append(id)
	return out


func set_rounds(r: int) -> void:
	if r == rounds:
		return
	rounds = r
	_changed()


func set_order(o: int) -> void:
	if o == order:
		return
	order = o
	_changed()


func set_mutator_mode(m: int) -> void:
	if m == mutator_mode:
		return
	mutator_mode = m
	_changed()


func set_ticked(id: StringName, on: bool) -> void:
	if on == not excluded.has(id):
		return
	if on:
		excluded.erase(id)
	else:
		excluded.append(id)
	_changed()


func tick_all(on: bool) -> void:
	excluded.clear()
	if not on:
		excluded.assign(MinigameCatalog.playable())
	_changed()


## "8 rounds · Vote (6 games) · Mutators: sometimes".
func summary() -> String:
	return GameModes.summary(rounds, order, mutator_mode, ticked().size())


## True when START may go: Playlist / Vote need at least one ticked game.
func can_start() -> bool:
	return order == GameModes.Order.SHUFFLE or not ticked().is_empty()


func focus_default() -> void:
	_refresh_focus()
	if practice_page.visible:
		MenuUI.focus_first([_selected_practice_button(), start_practice_button, back_button])
	else:
		MenuUI.focus_first([round_buttons.get(rounds), done_button])


## Every focusable control of the shown page in navigation order (tests walk it).
func focus_chain() -> Array[Control]:
	return _refresh_focus()


# --- Persistence -------------------------------------------------------------------------------

func load_setup() -> void:
	const Store := preload("res://cosmetics/cosmetics.gd")
	var data: Variant = Store.read_json_dict(path)
	if not data is Dictionary:
		return
	var d := data as Dictionary
	var r := int(d.get("rounds", rounds))
	rounds = r if GameModes.ROUND_CHOICES.has(r) else rounds
	order = clampi(int(d.get("order", order)), 0, GameModes.ORDER_NAMES.size() - 1)
	mutator_mode = clampi(int(d.get("mutators", mutator_mode)), 0, Mutators.MODE_NAMES.size() - 1)
	excluded.clear()
	for id: Variant in d.get("excluded", []):
		excluded.append(StringName(str(id)))


func save_setup() -> Error:
	const Store := preload("res://cosmetics/cosmetics.gd")
	if not persist:
		return OK
	var ex: Array = []
	for id in excluded:
		ex.append(String(id))
	var data := {"rounds": rounds, "order": order, "mutators": mutator_mode, "excluded": ex}
	return Store.write_json_atomic(path, JSON.stringify(data, "\t"))


## Starts from what Session holds (dev args such as `--order=vote` land there).
func _from_session() -> void:
	var session := _autoload(&"Session")
	if session == null:
		return
	rounds = int(session.get(&"setup_rounds")) if GameModes.ROUND_CHOICES.has(int(session.get(&"setup_rounds"))) else rounds
	order = int(session.get(&"order_mode"))
	mutator_mode = int(session.get(&"mutator_mode"))
	var pl: Array = session.get(&"playlist")
	excluded.clear()
	if not pl.is_empty():
		for id in MinigameCatalog.playable():
			if not pl.has(id):
				excluded.append(id)


# --- Building ----------------------------------------------------------------------------------

func _build() -> void:
	var shade := ColorRect.new()
	shade.color = Color(MenuUI.CHARCOAL, 0.45)
	MenuUI.full_rect(shade)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)
	var center := CenterContainer.new()
	MenuUI.full_rect(center)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_bg = Panel.new()
	_bg.custom_minimum_size = PANEL_SIZE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(MenuUI.CHARCOAL, 0.94)
	style.border_color = MenuUI.GOLD
	style.set_border_width_all(4)
	style.set_corner_radius_all(22)
	style.shadow_color = Color(0, 0, 0, 0.4)
	style.shadow_size = 8
	_bg.add_theme_stylebox_override(&"panel", style)
	center.add_child(_bg)
	var margin := MarginContainer.new()
	MenuUI.full_rect(margin)
	for side: StringName in [&"margin_left", &"margin_right"]:
		margin.add_theme_constant_override(side, 28)
	margin.add_theme_constant_override(&"margin_top", 18)
	margin.add_theme_constant_override(&"margin_bottom", 20)
	_bg.add_child(margin)
	var col := MenuUI.vbox(12)
	margin.add_child(col)

	var head := MenuUI.hbox(12)
	col.add_child(head)
	_title = MenuUI.label("GAME SETUP", &"ScrimHeader")
	_title.add_theme_color_override(&"font_color", MenuUI.GOLD)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	done_button = MenuUI.button("Done", &"SecondaryButton", 120)
	done_button.pressed.connect(close)
	head.add_child(done_button)

	setup_page = MenuUI.vbox(12)
	setup_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(setup_page)
	_build_setup_page(setup_page)
	practice_page = MenuUI.vbox(12)
	practice_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(practice_page)
	_build_practice_page(practice_page)
	practice_page.visible = false


func _build_setup_page(page: VBoxContainer) -> void:
	var rg := ButtonGroup.new()
	var row := _row(page, "Rounds")
	for r in GameModes.ROUND_CHOICES:
		var b := _chip(str(r), rg, 70)
		b.toggled.connect(func(on: bool) -> void:
			if on:
				set_rounds(r))
		row.add_child(b)
		round_buttons[r] = b
	var og := ButtonGroup.new()
	row = _row(page, "Order")
	for i in GameModes.ORDER_NAMES.size():
		var b := _chip(GameModes.ORDER_NAMES[i], og, 140)
		b.toggled.connect(func(on: bool) -> void:
			if on:
				set_order(i))
		row.add_child(b)
		order_buttons.append(b)
	var mg := ButtonGroup.new()
	row = _row(page, "Mutators")
	for i in Mutators.MODE_NAMES.size():
		var b := _chip(Mutators.MODE_NAMES[i], mg, 140)
		b.toggled.connect(func(on: bool) -> void:
			if on:
				set_mutator_mode(i))
		row.add_child(b)
		mutator_buttons.append(b)

	row = _row(page, "Games")
	all_button = MenuUI.button("All", &"SecondaryButton", 80)
	all_button.pressed.connect(tick_all.bind(true))
	row.add_child(all_button)
	none_button = MenuUI.button("None", &"SecondaryButton", 80)
	none_button.pressed.connect(tick_all.bind(false))
	row.add_child(none_button)
	games_note = MenuUI.label("", &"ScrimLabel")
	games_note.add_theme_font_size_override(&"font_size", 16)
	games_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	games_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(games_note)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	page.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override(&"h_separation", 10)
	grid.add_theme_constant_override(&"v_separation", 8)
	scroll.add_child(grid)
	for id in MinigameCatalog.playable():
		var info := MinigameCatalog.info(id)
		var b := MenuUI.button(str(info["name"]), &"ChipButton", GAME_BUTTON_W)
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.icon = _swatch(info["color"])
		b.add_theme_font_size_override(&"font_size", 20)
		b.tooltip_text = str(info["rule"])
		b.toggled.connect(func(on: bool) -> void: set_ticked(id, on))
		grid.add_child(b)
		game_buttons[id] = b

	var bottom := MenuUI.hbox(14)
	page.add_child(bottom)
	practice_button = MenuUI.button("Practice...", &"BigButton", 220)
	practice_button.tooltip_text = "Play one game, no score, then back to the lobby"
	practice_button.pressed.connect(show_page.bind(true))
	bottom.add_child(practice_button)
	var help := MenuUI.label("Practice: one game with everyone here. No points, no coins.", &"ScrimLabel")
	help.add_theme_font_size_override(&"font_size", 16)
	help.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	help.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bottom.add_child(help)


func _build_practice_page(page: VBoxContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	page.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override(&"h_separation", 10)
	grid.add_theme_constant_override(&"v_separation", 8)
	scroll.add_child(grid)
	var pg := ButtonGroup.new()
	for id in MinigameCatalog.playable():
		var info := MinigameCatalog.info(id)
		var b := MenuUI.button("%s\n%s · %d-%d players" % [info["name"], info["kind_name"], info["min"], info["max"]], &"ChipButton", GAME_BUTTON_W)
		b.toggle_mode = true
		b.button_group = pg
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.icon = _swatch(info["color"], 26)
		b.add_theme_font_size_override(&"font_size", 18)
		b.custom_minimum_size = Vector2(GAME_BUTTON_W, 66)
		b.tooltip_text = str(info["rule"])
		b.toggled.connect(func(on: bool) -> void:
			if on:
				practice_id = id
				_sync_buttons())
		grid.add_child(b)
		practice_buttons[id] = b

	var mrow := _row(page, "Mutator")
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override(&"h_separation", 6)
	flow.add_theme_constant_override(&"v_separation", 6)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mrow.add_child(flow)
	var mg := ButtonGroup.new()
	var ids: Array[StringName] = [&""]
	ids.append_array(Mutators.IDS)
	for mid in ids:
		var b := _chip("None" if mid == &"" else Mutators.display_name(mid), mg, 0)
		b.add_theme_font_size_override(&"font_size", 17)
		b.toggled.connect(func(on: bool) -> void:
			if on:
				practice_mutator = mid)
		flow.add_child(b)
		practice_mutator_buttons[mid] = b
	practice_mutator_buttons[&""].button_pressed = true

	var bottom := MenuUI.hbox(14)
	page.add_child(bottom)
	back_button = MenuUI.button("Back", &"SecondaryButton", 120)
	back_button.pressed.connect(show_page.bind(false))
	bottom.add_child(back_button)
	practice_hint = MenuUI.label("", &"ScrimLabel")
	practice_hint.add_theme_font_size_override(&"font_size", 17)
	practice_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	practice_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	practice_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bottom.add_child(practice_hint)
	start_practice_button = MenuUI.button("Start practice", &"PrimaryButton", 240)
	start_practice_button.pressed.connect(func() -> void:
		if practice_id != &"" and MinigameCatalog.fits(practice_id, _player_count):
			practice_requested.emit(practice_id, practice_mutator))
	bottom.add_child(start_practice_button)


func _row(parent: Control, text: String) -> HBoxContainer:
	var row := MenuUI.hbox(10)
	parent.add_child(row)
	var l := MenuUI.label(text, &"ScrimLabel")
	l.add_theme_font_size_override(&"font_size", 22)
	l.custom_minimum_size = Vector2(120, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	return row


func _chip(text: String, group: ButtonGroup, width: float) -> Button:
	var b := MenuUI.button(text, &"ChipButton", width)
	b.toggle_mode = true
	b.button_group = group
	return b


## A small round swatch in `c` for a game button's icon.
static func _swatch(c: Color, px: int = 20) -> Texture2D:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	var r := px * 0.5
	for y in px:
		for x in px:
			var d := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			if d <= r - 0.5:
				img.set_pixel(x, y, MenuUI.CHARCOAL if d > r - 2.5 else c)
	return ImageTexture.create_from_image(img)


# --- State -> buttons --------------------------------------------------------------------------

func _changed() -> void:
	_sync_buttons()
	save_setup()
	setup_changed.emit(rounds, order, ticked(), mutator_mode)


func _sync_buttons() -> void:
	if round_buttons.is_empty():
		return
	for r: int in round_buttons:
		round_buttons[r].set_pressed_no_signal(r == rounds)
	for i in order_buttons.size():
		order_buttons[i].set_pressed_no_signal(i == order)
	for i in mutator_buttons.size():
		mutator_buttons[i].set_pressed_no_signal(i == mutator_mode)
	var shuffle := order == GameModes.Order.SHUFFLE
	for id: StringName in game_buttons:
		var b := game_buttons[id]
		var on := not excluded.has(id)
		b.set_pressed_no_signal(on)
		b.modulate.a = 1.0 if (on and not shuffle) else 0.55
		var fits := MinigameCatalog.fits(id, _player_count)
		b.text = MinigameCatalog.display_name(id) + ("" if fits else "  (%d+)" % MinigameCatalog.min_players(id))
	var n := ticked().size()
	if shuffle:
		games_note.text = "Shuffle plays every game. Ticks count for Playlist and Vote."
	elif n == 0:
		games_note.text = "Tick at least one game."
	else:
		games_note.text = "%d of %d games ticked." % [n, game_buttons.size()]
	for id: StringName in practice_buttons:
		var b := practice_buttons[id]
		b.set_pressed_no_signal(id == practice_id)
		b.modulate.a = 1.0 if MinigameCatalog.fits(id, _player_count) else 0.5
	var fits_practice := practice_id != &"" and MinigameCatalog.fits(practice_id, _player_count)
	start_practice_button.disabled = not fits_practice
	if practice_id == &"":
		practice_hint.text = "Pick a game."
	elif not fits_practice:
		practice_hint.text = "%s needs %d+ players." % [MinigameCatalog.display_name(practice_id), MinigameCatalog.min_players(practice_id)]
	else:
		practice_hint.text = MinigameCatalog.display_name(practice_id)
	_refresh_focus()


func _selected_practice_button() -> Control:
	return practice_buttons.get(practice_id, null)


func _refresh_focus() -> Array[Control]:
	if not is_inside_tree() or setup_page == null:
		return []
	var rows: Array = [done_button]
	if setup_page.visible:
		rows.append(round_buttons.values())
		rows.append(order_buttons)
		rows.append(mutator_buttons)
		rows.append([all_button, none_button])
		_append_grid(rows, game_buttons.values())
		rows.append(practice_button)
	else:
		_append_grid(rows, practice_buttons.values())
		rows.append(practice_mutator_buttons.values())
		rows.append([back_button, start_practice_button])
	return MenuUI.chain_grid(rows)


static func _append_grid(rows: Array, buttons: Array) -> void:
	var row: Array = []
	for b: Variant in buttons:
		row.append(b)
		if row.size() == GRID_COLUMNS:
			rows.append(row)
			row = []
	if not row.is_empty():
		rows.append(row)


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"pause"):
		if practice_page.visible:
			show_page(false)
		else:
			close()
		get_viewport().set_input_as_handled()
