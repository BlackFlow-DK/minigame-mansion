class_name Wardrobe
extends Control
## The wardrobe: pick your blob's colours and items and your name. Owner: wardrobe UI.
##
## Open it by instancing `res://ui/wardrobe/wardrobe.tscn` anywhere (it is a full-rect Control:
## put it under a CanvasLayer above whatever is showing). It reads the saved profile on open,
## and on Done (button, Esc, gamepad B) saves it (`Cosmetics.save_profile`), hands it to
## `Net.set_local_profile` and emits `closed`. The opener frees it on `closed`.
## It never touches anything outside itself: no pausing, no scene changes, no global input
## state; it consumes the GUI input that reaches it (a full-screen overlay).
##
## Layout is designed at 1280x720 and scaled uniformly to its own size.
## Keys: arrows/Tab move, Enter/Space pick, Q/E turn the blob, Esc done.
## Pad: stick/d-pad move, A pick, LB/RB tabs, right stick or triggers turn, B done.

signal closed
## Every change of the loadout being edited (not saved yet).
signal loadout_changed(loadout: Dictionary)

const THEME_PATH := "res://ui/theme/mansion_theme.tres"
const DESIGN_SIZE := Vector2(1280, 720)
const TABS: Array[StringName] = [&"colour", &"hat", &"face", &"neck", &"back"]
const TAB_TITLES: Dictionary = {&"colour": "Colour", &"hat": "Hat", &"face": "Face", &"neck": "Neck", &"back": "Back"}
const GRID_COLUMNS := 5
const SWATCH_COLUMNS := 8
const TILE_SIZE := Vector2(108, 138)
const SWATCH_SIZE := 60.0
const GAP := 14
## Turn speed for keys / stick / triggers (radians per second).
const TURN_SPEED := 2.6
const STICK_DEADZONE := 0.25
## Chance a slot gets an item when randomising (the rest: nothing).
const RANDOM_CHANCE: Dictionary = {&"hat": 0.9, &"face": 0.5, &"neck": 0.5, &"back": 0.45}

const PLUM := Color("#6d4a7c")
const TEAL := Color("#2fa7a0")
const CREAM := Color("#f3e6c8")
const GOLD := Color("#e8b33a")
const CHARCOAL := Color("#2e2a33")
const PAPER := Color("#fffaf0")

var player_name: String = ""
## The loadout being edited (always sanitized).
var loadout: Dictionary = {}
var current_tab: StringName = &"colour"

var preview: WardrobePreview
var thumbs: WardrobeThumbs
var name_edit: LineEdit
var randomise_button: Button
var reset_button: Button
var done_button: Button
var tab_buttons: Dictionary = {}   # tab -> Button
var pages: Dictionary = {}         # tab -> Control
## &"primary" / &"secondary" -> Array of WardrobeSwatch (palette order).
var swatches: Dictionary = {}
## slot -> Array of tile Buttons (catalog order, "None" first). Meta: &"slot", &"id".
var tiles: Dictionary = {}

var _frame: Control
var _thumb_rects: Dictionary = {}  # "slot:id" -> TextureRect
var _closing: bool = false
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	name = "Wardrobe"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = load(THEME_PATH) as Theme
	_rng.randomize()

	var profile := Cosmetics.load_profile()
	player_name = Cosmetics.sanitize_name(profile.get("name", ""))
	loadout = Cosmetics.sanitize(profile.get("loadout", {}))

	thumbs = WardrobeThumbs.new()
	thumbs.name = "Thumbs"
	add_child(thumbs)
	thumbs.thumb_ready.connect(_on_thumb_ready)

	_build()
	name_edit.text = player_name
	preview.show_loadout(loadout)
	_sync_selection()
	open_tab(&"colour")
	resized.connect(_apply_scale)
	_apply_scale()
	Sfx.attach_ui(self)
	thumbs.render_all()
	_focus_default.call_deferred()


# --- Public API ------------------------------------------------------------------------------

## Shows the page `tab` (&"colour", &"hat", &"face", &"neck", &"back").
func open_tab(tab: StringName) -> void:
	if not pages.has(tab):
		return
	current_tab = tab
	for t: StringName in TABS:
		(pages[t] as Control).visible = t == tab
		(tab_buttons[t] as Button).set_pressed_no_signal(t == tab)
	_link_focus()


## Sets the body (`kind` = &"primary") or accent (&"secondary") colour. Returns false if `hex`
## is not in that palette.
func select_colour(kind: StringName, hex: String) -> bool:
	if not Cosmetics.palette(kind).has(hex):
		return false
	if loadout[String(kind)] == hex:
		return true
	loadout[String(kind)] = hex
	_loadout_updated(&"colour")
	return true


## Wears `id` in `slot` ("" = nothing). Returns false for an id that is not in the catalog.
func select_item(slot: StringName, id: String) -> bool:
	if not Cosmetics.SLOTS.has(slot) or not Cosmetics.is_valid_item(slot, id):
		return false
	if loadout[String(slot)] == id:
		return true
	loadout[String(slot)] = id
	_loadout_updated(slot)
	return true


## A random look: palette colours and a random item in most slots.
func randomise() -> void:
	var next := loadout
	for attempt in 6:
		next = _random_loadout()
		if next != loadout:
			break
	loadout = next
	_loadout_updated(&"random")
	Sfx.play(&"respawn")


## Back to the default look for this player's slot (the name is kept).
func reset() -> void:
	loadout = Cosmetics.default_loadout(maxi(Net.local_slot(), 0))
	_loadout_updated(&"random")


## Saves the profile, tells Net, emits `closed` (once).
func done() -> void:
	if _closing:
		return
	_closing = true
	player_name = Cosmetics.sanitize_name(name_edit.text)
	name_edit.text = player_name
	Cosmetics.save_profile(player_name, loadout)
	Net.set_local_profile(player_name, loadout)
	closed.emit()


func get_tile(slot: StringName, id: String) -> Button:
	for b: Button in tiles.get(slot, []):
		if String(b.get_meta(&"id")) == id:
			return b
	return null


func get_swatch(kind: StringName, hex: String) -> WardrobeSwatch:
	for s: WardrobeSwatch in swatches.get(kind, []):
		if s.hex == hex:
			return s
	return null


## The picture shown on the tile of `id` in `slot` (null while rendering or for "None").
func get_tile_texture(slot: StringName, id: String) -> Texture2D:
	var r: TextureRect = _thumb_rects.get(WardrobeThumbs.key_of(slot, id))
	return r.texture if r else null


# --- Changes ---------------------------------------------------------------------------------

func _loadout_updated(kind: StringName) -> void:
	loadout = Cosmetics.sanitize(loadout)
	preview.show_loadout(loadout)
	preview.react(kind)
	_sync_selection()
	if kind != &"random":
		Sfx.play(&"jump", Vector3.INF, -6.0, 1.15)
	loadout_changed.emit(loadout.duplicate())


func _random_loadout() -> Dictionary:
	var primary := Cosmetics.palette(&"primary")
	var secondary := Cosmetics.palette(&"secondary")
	var l := {
		"primary": primary[_rng.randi_range(0, primary.size() - 1)],
		"secondary": secondary[_rng.randi_range(0, secondary.size() - 1)],
	}
	for slot: StringName in Cosmetics.SLOTS:
		var items := Cosmetics.catalog(slot).slice(1)
		var id := ""
		if not items.is_empty() and _rng.randf() < float(RANDOM_CHANCE.get(slot, 0.5)):
			id = items[_rng.randi_range(0, items.size() - 1)]["id"]
		l[String(slot)] = id
	return Cosmetics.sanitize(l)


## Marks the chosen swatches and tiles (exactly one per group).
func _sync_selection() -> void:
	for kind: StringName in swatches:
		for s: WardrobeSwatch in swatches[kind]:
			s.set_pressed_no_signal(s.hex == loadout[String(kind)])
			s.queue_redraw()
	for slot: StringName in tiles:
		for b: Button in tiles[slot]:
			b.set_pressed_no_signal(String(b.get_meta(&"id")) == loadout[String(slot)])


func _on_thumb_ready(slot: StringName, id: String, texture: Texture2D) -> void:
	var r: TextureRect = _thumb_rects.get(WardrobeThumbs.key_of(slot, id))
	if r:
		r.texture = texture


# --- Input -----------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _closing:
		return
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		done()
		return
	if event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		var j := event as InputEventJoypadButton
		if j.button_index == JOY_BUTTON_LEFT_SHOULDER or j.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			_cycle_tab(-1 if j.button_index == JOY_BUTTON_LEFT_SHOULDER else 1)
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_visible_in_tree() or preview == null:
		return
	var axis := 0.0
	if not _typing():
		if Input.is_physical_key_pressed(KEY_Q):
			axis -= 1.0
		if Input.is_physical_key_pressed(KEY_E):
			axis += 1.0
	for dev in Input.get_connected_joypads():
		var x := Input.get_joy_axis(dev, JOY_AXIS_RIGHT_X)
		if absf(x) > STICK_DEADZONE:
			axis += x
		axis += Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_RIGHT) - Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_LEFT)
	if axis != 0.0:
		preview.turn(clampf(axis, -1.5, 1.5) * TURN_SPEED * delta)


func _typing() -> bool:
	return name_edit != null and name_edit.has_focus()


func _cycle_tab(step: int) -> void:
	var i := TABS.find(current_tab)
	var next := TABS[posmod(i + step, TABS.size())]
	var focus_in_tabs := false
	var f := get_viewport().gui_get_focus_owner()
	for b: Button in tab_buttons.values():
		if b == f:
			focus_in_tabs = true
	open_tab(next)
	if focus_in_tabs:
		(tab_buttons[next] as Button).grab_focus()
	else:
		var target := _page_focus_target()
		if target:
			target.grab_focus()


func _focus_default() -> void:
	if is_inside_tree() and tab_buttons.has(current_tab):
		(tab_buttons[current_tab] as Button).grab_focus()


# --- Focus -----------------------------------------------------------------------------------

## The control on the current page that should take focus when entering it: the chosen item.
func _page_focus_target() -> Control:
	var groups := _page_groups(current_tab)
	for group: Array in groups:
		for b: BaseButton in group:
			if b.button_pressed:
				return b
	return groups[0][0] if not groups.is_empty() and not (groups[0] as Array).is_empty() else null


## The focusable grids of a page, top to bottom.
func _page_groups(tab: StringName) -> Array:
	if tab == &"colour":
		return [swatches[&"primary"], swatches[&"secondary"]]
	return [tiles[tab]]


## Explicit neighbours everywhere, so keyboard and pad never get lost:
##   tabs (left/right wrap; down = the chosen item) -> page grids (rows; up from the top row =
##   the tab, down from the bottom row = the bottom bar) -> bottom bar (name, Randomise,
##   Reset, Done; up = the chosen item). Tab / Shift+Tab walk the same order.
func _link_focus() -> void:
	if name_edit == null:
		return
	var tab_row: Array[Control] = []
	for t: StringName in TABS:
		tab_row.append(tab_buttons[t])
	var active: Control = tab_buttons[current_tab]
	var target := _page_focus_target()
	var bar: Array[Control] = [name_edit, randomise_button, reset_button, done_button]
	for i in tab_row.size():
		var b := tab_row[i]
		_set_n(b, &"focus_neighbor_left", tab_row[posmod(i - 1, tab_row.size())])
		_set_n(b, &"focus_neighbor_right", tab_row[posmod(i + 1, tab_row.size())])
		_set_n(b, &"focus_neighbor_top", b)
		_set_n(b, &"focus_neighbor_bottom", target if target else bar[0])
	for i in bar.size():
		var c := bar[i]
		_set_n(c, &"focus_neighbor_left", bar[posmod(i - 1, bar.size())])
		_set_n(c, &"focus_neighbor_right", bar[posmod(i + 1, bar.size())])
		_set_n(c, &"focus_neighbor_top", target if target else active)
		_set_n(c, &"focus_neighbor_bottom", c)
	# Grids.
	var groups := _page_groups(current_tab)
	var columns := SWATCH_COLUMNS if current_tab == &"colour" else GRID_COLUMNS
	var order: Array[Control] = []
	order.append_array(tab_row)
	for gi in groups.size():
		var group: Array = groups[gi]
		var n := group.size()
		var above: Array = groups[gi - 1] if gi > 0 else []
		var below: Array = groups[gi + 1] if gi < groups.size() - 1 else []
		for i in n:
			var c: Control = group[i]
			var col := i % columns
			var row := i / columns
			var rows := (n + columns - 1) / columns
			_set_n(c, &"focus_neighbor_left", group[i - 1] if col > 0 else c)
			_set_n(c, &"focus_neighbor_right", group[i + 1] if col < columns - 1 and i + 1 < n else c)
			var up: Control
			if row > 0:
				up = group[i - columns]
			elif not above.is_empty():
				var above_rows := (above.size() + columns - 1) / columns
				up = above[mini((above_rows - 1) * columns + col, above.size() - 1)]
			else:
				up = active
			var down: Control
			if row < rows - 1:
				down = group[mini(i + columns, n - 1)]
			elif not below.is_empty():
				down = below[mini(col, below.size() - 1)]
			else:
				down = done_button
			_set_n(c, &"focus_neighbor_top", up)
			_set_n(c, &"focus_neighbor_bottom", down)
			order.append(c)
	order.append_array(bar)
	for i in order.size():
		_set_n(order[i], &"focus_next", order[(i + 1) % order.size()])
		_set_n(order[i], &"focus_previous", order[posmod(i - 1, order.size())])


static func _set_n(c: Control, property: StringName, to: Control) -> void:
	c.set(property, c.get_path_to(to))


# --- Layout ----------------------------------------------------------------------------------

func _apply_scale() -> void:
	if _frame == null:
		return
	var s := clampf(minf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y), 0.25, 4.0)
	_frame.scale = Vector2(s, s)
	_frame.position = Vector2.ZERO
	_frame.size = size / s


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.name = "Scrim"
	scrim.color = Color(0.13, 0.08, 0.17, 0.55)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)

	_frame = Control.new()
	_frame.name = "Frame"
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_frame)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.add_child(center)
	var margin := MarginContainer.new()
	margin.custom_minimum_size = DESIGN_SIZE
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side: StringName in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	center.add_child(margin)
	var col := _vbox(GAP)
	margin.add_child(col)

	var main := _hbox(20)
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(main)
	main.add_child(_build_preview())
	main.add_child(_build_panel())
	col.add_child(_build_bottom_bar())


func _build_preview() -> Control:
	var frame := Panel.new()
	frame.name = "PreviewFrame"
	frame.custom_minimum_size = Vector2(540, 0)
	frame.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	var bg := StyleBoxFlat.new()
	bg.bg_color = CHARCOAL
	bg.set_corner_radius_all(26)
	bg.corner_detail = 12
	frame.add_theme_stylebox_override(&"panel", bg)

	preview = WardrobePreview.new()
	preview.name = "Preview"
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(preview)

	var title := Label.new()
	title.text = "Wardrobe"
	title.theme_type_variation = &"TitleLabel"
	title.add_theme_font_size_override(&"font_size", 54)
	title.add_theme_constant_override(&"outline_size", 16)
	title.add_theme_constant_override(&"shadow_offset_y", 5)
	title.add_theme_constant_override(&"shadow_outline_size", 16)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.position = Vector2(26, 12)
	frame.add_child(title)

	var hint := PanelContainer.new()
	hint.theme_type_variation = &"DarkPanel"
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hint_label := Label.new()
	hint_label.text = "Turn:  Q / E  ·  right stick  ·  drag"
	hint_label.theme_type_variation = &"LightLabel"
	hint_label.add_theme_font_size_override(&"font_size", 15)
	hint_label.add_theme_constant_override(&"outline_size", 6)
	hint.add_child(hint_label)
	hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 14)
	hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	frame.add_child(hint)

	var border := Panel.new()
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	border.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var ring := StyleBoxFlat.new()
	ring.draw_center = false
	ring.border_color = CHARCOAL
	ring.set_border_width_all(6)
	ring.set_corner_radius_all(26)
	ring.corner_detail = 12
	border.add_theme_stylebox_override(&"panel", ring)
	frame.add_child(border)
	return frame


func _build_panel() -> Control:
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var col := _vbox(10)
	panel.add_child(col)

	var tab_row := _hbox(10)
	tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(tab_row)
	for t: StringName in TABS:
		var b := Button.new()
		b.name = "Tab_%s" % t
		b.text = TAB_TITLES[t]
		b.theme_type_variation = &"ChipButton"
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_ALL
		b.custom_minimum_size = Vector2(108, 0)
		b.set_meta(&"sfx_press", &"ui_click")
		b.pressed.connect(_on_tab_pressed.bind(t))
		b.focus_entered.connect(_on_tab_focused.bind(t))
		tab_row.add_child(b)
		tab_buttons[t] = b
	col.add_child(HSeparator.new())

	var stack := Control.new()
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(stack)
	var colour_page := _build_colour_page()
	pages[&"colour"] = colour_page
	stack.add_child(colour_page)
	for slot: StringName in Cosmetics.SLOTS:
		var page := _build_item_page(slot)
		pages[slot] = page
		stack.add_child(page)
	for p: Control in pages.values():
		p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return panel


func _build_colour_page() -> Control:
	var page := _vbox(8)
	page.name = "Page_colour"
	page.add_theme_constant_override(&"separation", 8)
	var sections := [
		[&"primary", "Body colour"],
		[&"secondary", "Accent colour  (belly, hands, feet)"],
	]
	for si in sections.size():
		var kind: StringName = sections[si][0]
		if si > 0:
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(0, 6)
			page.add_child(gap)
		var head := Label.new()
		head.text = sections[si][1]
		head.theme_type_variation = &"HeaderLabel"
		head.add_theme_font_size_override(&"font_size", 24)
		page.add_child(head)
		var grid := GridContainer.new()
		grid.columns = SWATCH_COLUMNS
		grid.add_theme_constant_override(&"h_separation", 14)
		grid.add_theme_constant_override(&"v_separation", 14)
		var pad := MarginContainer.new()
		for side: StringName in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
			pad.add_theme_constant_override(side, 6)
		pad.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		pad.add_child(grid)
		page.add_child(pad)
		var list: Array = []
		for hex in Cosmetics.palette(kind):
			var s := WardrobeSwatch.new(hex, SWATCH_SIZE)
			s.name = "Swatch_%s_%s" % [kind, hex.trim_prefix("#")]
			s.pressed.connect(_on_swatch_pressed.bind(kind, hex))
			grid.add_child(s)
			list.append(s)
		swatches[kind] = list
	return page


func _build_item_page(slot: StringName) -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = "Page_%s" % slot
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: StringName in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		pad.add_theme_constant_override(side, 8)
	scroll.add_child(pad)
	var grid := GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	grid.add_theme_constant_override(&"h_separation", GAP)
	grid.add_theme_constant_override(&"v_separation", GAP)
	pad.add_child(grid)
	var list: Array = []
	for entry: Dictionary in Cosmetics.catalog(slot):
		var tile := _make_tile(slot, entry)
		grid.add_child(tile)
		list.append(tile)
	tiles[slot] = list
	return scroll


func _make_tile(slot: StringName, entry: Dictionary) -> Button:
	var id: String = entry["id"]
	var b := Button.new()
	b.name = "Tile_%s_%s" % [slot, id if id != "" else "none"]
	b.toggle_mode = true
	b.theme_type_variation = &"ChipButton"
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = TILE_SIZE
	b.tooltip_text = entry["name"]
	b.set_meta(&"slot", slot)
	b.set_meta(&"id", id)
	b.set_meta(&"sfx_press", &"ui_click")
	b.pressed.connect(_on_tile_pressed.bind(slot, id))

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override(&"separation", 0)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 6
	box.offset_right = -6
	box.offset_top = 6
	box.offset_bottom = -6
	b.add_child(box)
	if id == "":
		var none := _NoneIcon.new()
		none.size_flags_vertical = Control.SIZE_EXPAND_FILL
		none.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(none)
	else:
		var pic := TextureRect.new()
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.size_flags_vertical = Control.SIZE_EXPAND_FILL
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.texture = thumbs.get_texture(slot, id)
		box.add_child(pic)
		_thumb_rects[WardrobeThumbs.key_of(slot, id)] = pic
	var label := Label.new()
	label.text = entry["name"]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.max_lines_visible = 2
	label.custom_minimum_size = Vector2(0, 40)
	label.add_theme_font_size_override(&"font_size", 15)
	label.add_theme_constant_override(&"line_spacing", -3)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	return b


func _build_bottom_bar() -> Control:
	var bar := _hbox(14)
	bar.custom_minimum_size = Vector2(0, 64)
	var name_panel := PanelContainer.new()
	name_panel.theme_type_variation = &"RowPanel"
	name_panel.custom_minimum_size = Vector2(540, 0)
	bar.add_child(name_panel)
	var name_row := _hbox(12)
	name_panel.add_child(name_row)
	var name_label := Label.new()
	name_label.text = "Name"
	name_label.theme_type_variation = &"HeaderLabel"
	name_label.add_theme_font_size_override(&"font_size", 24)
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_row.add_child(name_label)
	name_edit = LineEdit.new()
	name_edit.name = "NameEdit"
	name_edit.max_length = Cosmetics.NAME_MAX
	name_edit.placeholder_text = "Type your name"
	name_edit.select_all_on_focus = true
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_edit.text_submitted.connect(func(_t: String) -> void: _commit_name(); done_button.grab_focus())
	name_edit.focus_exited.connect(_commit_name)
	name_row.add_child(name_edit)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(spacer)
	randomise_button = _button("Randomise", &"", 190)
	randomise_button.pressed.connect(randomise)
	reset_button = _button("Reset", &"", 130)
	reset_button.pressed.connect(reset)
	done_button = _button("Done", &"PrimaryButton", 170)
	done_button.pressed.connect(done)
	done_button.set_meta(&"sfx_press", &"ui_back")
	for b: Button in [randomise_button, reset_button, done_button]:
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.add_child(b)
	return bar


func _commit_name() -> void:
	player_name = Cosmetics.sanitize_name(name_edit.text)
	if name_edit.text != player_name:
		name_edit.text = player_name


# --- Signals ---------------------------------------------------------------------------------

func _on_tab_pressed(tab: StringName) -> void:
	open_tab(tab)


func _on_tab_focused(tab: StringName) -> void:
	if tab != current_tab:
		open_tab(tab)


func _on_swatch_pressed(kind: StringName, hex: String) -> void:
	select_colour(kind, hex)
	_sync_selection()


func _on_tile_pressed(slot: StringName, id: String) -> void:
	select_item(slot, id)
	_sync_selection()


# --- Helpers ---------------------------------------------------------------------------------

static func _vbox(separation: int) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", separation)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v


static func _hbox(separation: int) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override(&"separation", separation)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h


static func _button(text: String, variation: StringName, min_width: float) -> Button:
	var b := Button.new()
	b.name = text.replace(" ", "")
	b.text = text
	b.theme_type_variation = variation
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(min_width, 0)
	return b


## "Nothing in this slot": a soft circle with a slash.
class _NoneIcon extends Control:
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.3
		var col := Color("#2e2a33", 0.45)
		draw_arc(c, r, 0.0, TAU, 48, col, 6.0, true)
		var d := Vector2(r, -r) * 0.7071
		draw_line(c - d, c + d, col, 6.0, true)
