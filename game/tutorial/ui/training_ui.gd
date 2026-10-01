class_name TrainingUI
extends CanvasLayer
## The Training Room's screen: a station card that slides up from the bottom (plum title, one
## instruction line, an optional tip, and the controls drawn as keycaps and pad buttons), a
## checklist of every station in the top-left corner with the current one highlighted, an
## Esc / Start hint in the top-right corner, and the "You're ready!" panel at the finish.
## The glyphs of the last used input device (keyboard or gamepad) come first; the other set
## follows, dimmed. Laid out at 1280x720 and scaled uniformly to the window, like the menus.
## Created by TrainingRoom (child `TrainingUI`); it only listens to the room's signals and
## calls `room.request_exit()` from the finish buttons.

enum Device { KEYBOARD, GAMEPAD }

const THEME_PATH := "res://ui/theme/mansion_theme.tres"
const DESIGN_SIZE := Vector2(1280, 720)
const CARD_WIDTH := 660.0
const CARD_MARGIN := 22.0
## How far below its spot the card waits while hidden (design px).
const CARD_HIDDEN := 320.0
## Seconds the green check shows before the next card replaces it.
const DONE_HOLD := 0.85

const CHARCOAL := Color("#2e2a33")
const CREAM := Color("#f3e6c8")
const PAPER := Color("#fffaf0")
const PLUM := Color("#6d4a7c")
const TEAL := Color("#2fa7a0")
const GOLD := Color("#e8b33a")
const GREEN := Color("#58b368")
const MUTED := Color("#5e5263")

## Last device anyone used in a Training Room run (kept between runs; -1 = not known yet).
static var last_device: int = -1

var room: TrainingRoom = null
var device: Device = Device.KEYBOARD
## Index of the station the card shows (-1: none yet).
var shown_station: int = -1
## True while the card shows its green check.
var card_done: bool = false

var root: Control
var card: PanelContainer
var checklist: PanelContainer
var esc_hint: PanelContainer
var finish_panel: Control
var play_button: Button
var title_button: Button

## Card offset below its resting place (design px): 0 = fully in.
var card_offset: float = CARD_HIDDEN:
	set(v):
		card_offset = v
		_layout_card()

var _card_style: StyleBoxFlat
var _card_done_style: StyleBoxFlat
var _step_label: Label
var _title_label: Label
var _line_label: Label
var _tip_label: Label
var _progress_chip: PanelContainer
var _progress_label: Label
var _check: TrainingGlyph
var _glyph_row: HBoxContainer
var _rows: Array[PanelContainer] = []
var _row_icons: Array[Control] = []
var _row_labels: Array[Label] = []
var _row_box: VBoxContainer
var _finish_box: PanelContainer
var _finish_time_label: Label
var _finish_reward_label: Label
var _queued: int = -1
var _switching: bool = false
var _player: Player = null


func _init() -> void:
	layer = 5


func _ready() -> void:
	if last_device >= 0:
		device = last_device as Device
	elif not Input.get_connected_joypads().is_empty():
		device = Device.GAMEPAD
	root = Control.new()
	root.name = "Root"
	root.theme = load(THEME_PATH) as Theme
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_checklist()
	_build_card()
	_build_esc_hint()
	_build_finish()
	Sfx.attach_ui(root)
	get_viewport().size_changed.connect(_apply_scale)
	_apply_scale()
	if room:
		room.station_started.connect(_on_station_started)
		room.station_completed.connect(_on_station_completed)
		room.progress_changed.connect(_on_progress)
		room.course_finished.connect(_on_course_finished)
	_refresh_checklist()


## The human player (for the device switch, nothing else yet).
func bind(p: Player) -> void:
	_player = p


func set_device(d: Device) -> void:
	last_device = d
	if d == device:
		return
	device = d
	if shown_station >= 0:
		_fill_glyphs(room.stations[shown_station].glyphs)
	_fill_esc_glyphs()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed:
		set_device(Device.KEYBOARD)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		set_device(Device.KEYBOARD)
	elif event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		set_device(Device.GAMEPAD)
	elif event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.4:
		set_device(Device.GAMEPAD)


func is_finish_shown() -> bool:
	return finish_panel != null and finish_panel.visible


## The glyph groups currently on the card: [[primary glyph kinds...], ...] (tests).
func card_glyph_texts() -> Array[String]:
	var out: Array[String] = []
	if _glyph_row == null:
		return out
	for g in _glyph_row.find_children("*", "TrainingGlyph", true, false):
		var tg := g as TrainingGlyph
		out.append(tg.text)
	return out


# --- Signals ---------------------------------------------------------------------------------

func _on_station_started(index: int) -> void:
	_queued = index
	_refresh_checklist()
	if not _switching:
		_switch()


func _on_station_completed(index: int) -> void:
	_refresh_checklist()
	if index == shown_station:
		_show_check()


func _on_progress(index: int, text: String) -> void:
	if index != shown_station:
		return
	_progress_label.text = text
	_progress_chip.visible = text != ""


func _on_course_finished(seconds: float) -> void:
	_refresh_checklist()
	_queued = -1
	var tw := create_tween()
	tw.tween_interval(DONE_HOLD)
	tw.tween_property(self, ^"card_offset", CARD_HIDDEN, 0.25).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tw.tween_callback(_show_finish.bind(seconds))


# --- Card ----------------------------------------------------------------------------------------

func _switch() -> void:
	_switching = true
	var tw := create_tween()
	if shown_station >= 0:
		if card_done:
			tw.tween_interval(DONE_HOLD)
		tw.tween_property(self, ^"card_offset", CARD_HIDDEN, 0.22).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(func() -> void:
		if _queued >= 0:
			_fill_card(_queued))
	tw.tween_property(self, ^"card_offset", 0.0, 0.45).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_callback(func() -> void:
		_switching = false
		if _queued >= 0 and _queued != shown_station:
			_switch())


func _fill_card(index: int) -> void:
	var st := room.stations[index]
	shown_station = index
	card_done = st.done
	_step_label.text = "%d / %d" % [index + 1, room.stations.size()]
	_title_label.text = st.card_title
	_line_label.text = st.card_line
	_tip_label.text = st.card_tip
	_tip_label.visible = st.card_tip != ""
	_progress_label.text = ""
	_progress_chip.visible = false
	_check.visible = st.done
	_check.scale = Vector2.ONE
	card.add_theme_stylebox_override(&"panel", _card_done_style if st.done else _card_style)
	_fill_glyphs(st.glyphs)
	card.reset_size()
	_layout_card()


func _show_check() -> void:
	card_done = true
	_check.visible = true
	_check.pivot_offset = _check.size * 0.5
	_check.scale = Vector2(0.2, 0.2)
	var tw := create_tween()
	tw.tween_property(_check, ^"scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	card.add_theme_stylebox_override(&"panel", _card_done_style)
	_progress_chip.visible = false


func _layout_card() -> void:
	if card == null or root == null:
		return
	var w := root.size.x
	var h := root.size.y
	card.position = Vector2((w - card.size.x) * 0.5, h - card.size.y - CARD_MARGIN + card_offset)


func _build_card() -> void:
	card = PanelContainer.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(CARD_WIDTH, 0.0)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_style = _panel_style(CREAM, CHARCOAL, 5, 24)
	_card_style.content_margin_left = 26
	_card_style.content_margin_right = 26
	_card_style.content_margin_top = 16
	_card_style.content_margin_bottom = 18
	_card_done_style = _card_style.duplicate() as StyleBoxFlat
	_card_done_style.border_color = GREEN.darkened(0.15)
	_card_done_style.bg_color = Color("#eef3d6")
	card.add_theme_stylebox_override(&"panel", _card_style)
	root.add_child(card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 6)
	card.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override(&"separation", 12)
	col.add_child(head)
	var step := PanelContainer.new()
	step.add_theme_stylebox_override(&"panel", _chip_style(PLUM))
	step.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_step_label = _label("1 / 9", 15, CREAM, 3)
	step.add_child(_step_label)
	head.add_child(step)
	_title_label = _label("", 32, PLUM, 0)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title_label)
	_progress_chip = PanelContainer.new()
	_progress_chip.add_theme_stylebox_override(&"panel", _chip_style(TEAL))
	_progress_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_progress_label = _label("", 17, PAPER, 4)
	_progress_chip.add_child(_progress_label)
	_progress_chip.visible = false
	head.add_child(_progress_chip)
	_check = TrainingGlyph.dot(TrainingGlyph.Kind.CHECK, "", 40.0)
	_check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_check.visible = false
	head.add_child(_check)

	_line_label = _label("", 22, CHARCOAL, 0)
	_line_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_line_label)
	_tip_label = _label("", 17, MUTED, 0)
	_tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_tip_label)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 2)
	col.add_child(gap)
	_glyph_row = HBoxContainer.new()
	_glyph_row.name = "Glyphs"
	_glyph_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_glyph_row.add_theme_constant_override(&"separation", 34)
	col.add_child(_glyph_row)
	card_offset = CARD_HIDDEN


## One group per action: caption, this device's glyphs, "or", the other device's (dimmed).
func _fill_glyphs(actions: Array[StringName]) -> void:
	for c in _glyph_row.get_children():
		_glyph_row.remove_child(c)
		c.queue_free()
	_glyph_row.visible = not actions.is_empty()
	var first := device
	var second := Device.GAMEPAD if device == Device.KEYBOARD else Device.KEYBOARD
	for action in actions:
		var group := HBoxContainer.new()
		group.add_theme_constant_override(&"separation", 8)
		group.alignment = BoxContainer.ALIGNMENT_CENTER
		var caption := _label(_caption(action), 18, PLUM, 0)
		caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		group.add_child(caption)
		group.add_child(_glyphs_for(action, first))
		var orl := _label("or", 15, MUTED, 0)
		orl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		group.add_child(orl)
		var other := _glyphs_for(action, second)
		other.modulate = Color(1, 1, 1, 0.55)
		group.add_child(other)
		_glyph_row.add_child(group)


static func _caption(action: StringName) -> String:
	match action:
		&"move":
			return "Move"
		&"jump":
			return "Jump"
		&"shove":
			return "Shove"
		&"pause":
			return "Pause"
	return str(action).capitalize()


## The glyphs of `action` on device `d` (a small container, vertically centred).
func _glyphs_for(action: StringName, d: Device) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override(&"separation", 4)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	if d == Device.KEYBOARD:
		match action:
			&"move":
				# The classic cluster: W on top of A S D.
				var cluster := VBoxContainer.new()
				cluster.add_theme_constant_override(&"separation", 3)
				var top := HBoxContainer.new()
				top.alignment = BoxContainer.ALIGNMENT_CENTER
				top.add_child(TrainingGlyph.key("W"))
				cluster.add_child(top)
				var bottom := HBoxContainer.new()
				bottom.add_theme_constant_override(&"separation", 3)
				for k: String in ["A", "S", "D"]:
					bottom.add_child(TrainingGlyph.key(k))
				cluster.add_child(bottom)
				box.add_child(cluster)
			&"jump":
				box.add_child(TrainingGlyph.key("Space"))
			&"shove":
				box.add_child(TrainingGlyph.key("E"))
			&"pause":
				box.add_child(TrainingGlyph.key("Esc"))
	else:
		match action:
			&"move":
				box.add_child(TrainingGlyph.stick("L"))
			&"jump":
				box.add_child(TrainingGlyph.pad("A", TrainingGlyph.PAD_GREEN))
			&"shove":
				box.add_child(TrainingGlyph.pad("X", TrainingGlyph.PAD_BLUE))
			&"pause":
				box.add_child(TrainingGlyph.key_dark("Start"))
	return box


# --- Checklist --------------------------------------------------------------------------------------

func _build_checklist() -> void:
	checklist = PanelContainer.new()
	checklist.name = "Checklist"
	checklist.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := _panel_style(CREAM, CHARCOAL, 4, 18)
	style.content_margin_left = 14
	style.content_margin_right = 16
	style.content_margin_top = 10
	style.content_margin_bottom = 12
	checklist.add_theme_stylebox_override(&"panel", style)
	checklist.position = Vector2(18, 18)
	root.add_child(checklist)
	_row_box = VBoxContainer.new()
	_row_box.add_theme_constant_override(&"separation", 3)
	checklist.add_child(_row_box)
	_row_box.add_child(_label("TRAINING ROOM", 15, PLUM, 0))
	if room == null:
		return
	for i in room.stations.size():
		var row := PanelContainer.new()
		row.add_theme_stylebox_override(&"panel", StyleBoxEmpty.new())
		var h := HBoxContainer.new()
		h.add_theme_constant_override(&"separation", 8)
		row.add_child(h)
		var icon := Control.new()
		icon.custom_minimum_size = Vector2(22, 22)
		h.add_child(icon)
		var l := _label(room.stations[i].checklist_name, 16, CHARCOAL, 0)
		h.add_child(l)
		_row_box.add_child(row)
		_rows.append(row)
		_row_icons.append(icon)
		_row_labels.append(l)


func _refresh_checklist() -> void:
	if room == null:
		return
	var current_style := _chip_style(GOLD)
	current_style.content_margin_left = 4
	current_style.content_margin_right = 10
	for i in _rows.size():
		var st := room.stations[i]
		var holder := _row_icons[i]
		for c in holder.get_children():
			holder.remove_child(c)
			c.queue_free()
		var kind := TrainingGlyph.Kind.PENDING
		if st.done:
			kind = TrainingGlyph.Kind.CHECK
		elif i == room.current:
			kind = TrainingGlyph.Kind.CURRENT
		var g := TrainingGlyph.dot(kind, "" if st.done else str(i + 1), 22.0)
		holder.add_child(g)
		var is_current := i == room.current and not st.done
		_rows[i].add_theme_stylebox_override(&"panel", current_style if is_current else _empty_row())
		_row_labels[i].add_theme_color_override(&"font_color", CHARCOAL if is_current else (MUTED if st.done else CHARCOAL.lightened(0.15)))


func _empty_row() -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = 4
	s.content_margin_right = 10
	s.content_margin_top = 1
	s.content_margin_bottom = 1
	return s


## True when row `index` of the checklist is highlighted as the current station (tests).
func is_row_current(index: int) -> bool:
	return index >= 0 and index < _rows.size() and _rows[index].get_theme_stylebox(&"panel") is StyleBoxFlat


# --- Esc hint -----------------------------------------------------------------------------------------

func _build_esc_hint() -> void:
	esc_hint = PanelContainer.new()
	esc_hint.name = "EscHint"
	esc_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := _panel_style(PLUM, CHARCOAL, 4, 16)
	style.content_margin_left = 12
	style.content_margin_right = 14
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	esc_hint.add_theme_stylebox_override(&"panel", style)
	root.add_child(esc_hint)
	_fill_esc_glyphs()


func _fill_esc_glyphs() -> void:
	if esc_hint == null:
		return
	for c in esc_hint.get_children():
		esc_hint.remove_child(c)
		c.queue_free()
	var h := HBoxContainer.new()
	h.add_theme_constant_override(&"separation", 8)
	esc_hint.add_child(h)
	h.add_child(_glyphs_for(&"pause", device))
	h.add_child(_label("Pause / Skip tutorial", 16, CREAM, 4))
	esc_hint.reset_size()
	_layout_corners()


func _layout_corners() -> void:
	if esc_hint and root:
		esc_hint.position = Vector2(root.size.x - esc_hint.size.x - 18, 18)


# --- Finish ------------------------------------------------------------------------------------------

func _build_finish() -> void:
	finish_panel = Control.new()
	finish_panel.name = "Finish"
	finish_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	finish_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	finish_panel.visible = false
	root.add_child(finish_panel)
	var dim := ColorRect.new()
	dim.color = Color(CHARCOAL, 0.35)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	finish_panel.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	finish_panel.add_child(center)
	_finish_box = PanelContainer.new()
	_finish_box.custom_minimum_size = Vector2(560, 0)
	center.add_child(_finish_box)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 12)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	_finish_box.add_child(col)
	var big := _label("You're ready!", 66, GOLD, 18)
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.add_theme_color_override(&"font_shadow_color", CHARCOAL)
	big.add_theme_constant_override(&"shadow_offset_y", 6)
	big.add_theme_constant_override(&"shadow_outline_size", 18)
	col.add_child(big)
	_finish_time_label = _label("", 22, CHARCOAL, 0)
	_finish_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_finish_time_label)
	_finish_reward_label = _label("", 20, PLUM, 0)
	_finish_reward_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_finish_reward_label)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	col.add_child(gap)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override(&"separation", 18)
	col.add_child(buttons)
	play_button = Button.new()
	play_button.text = "Play offline"
	play_button.theme_type_variation = &"PrimaryButton"
	title_button = Button.new()
	title_button.text = "Back to title"
	for b: Button in [play_button, title_button]:
		b.focus_mode = Control.FOCUS_ALL
		buttons.add_child(b)
	play_button.focus_neighbor_right = play_button.get_path_to(title_button)
	play_button.focus_neighbor_left = play_button.get_path_to(title_button)
	title_button.focus_neighbor_left = title_button.get_path_to(play_button)
	title_button.focus_neighbor_right = title_button.get_path_to(play_button)
	play_button.pressed.connect(func() -> void:
		if room:
			room.request_exit(true))
	title_button.pressed.connect(func() -> void:
		if room:
			room.request_exit(false))


func _show_finish(seconds: float) -> void:
	var s := int(round(seconds))
	_finish_time_label.text = "Training Room done in %d:%02d. Now go shove your friends!" % [s / 60, s % 60]
	var reward := room.reward_given if room else 0
	_finish_reward_label.text = "+%d Mansion Coins for finishing!" % reward if reward > 0 else ""
	_finish_reward_label.visible = reward > 0
	finish_panel.visible = true
	_finish_box.pivot_offset = _finish_box.size * 0.5
	_finish_box.scale = Vector2(0.75, 0.75)
	var tw := create_tween()
	tw.tween_property(_finish_box, ^"scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	(func() -> void:
		if is_instance_valid(play_button) and play_button.is_visible_in_tree():
			_finish_box.pivot_offset = _finish_box.size * 0.5
			play_button.grab_focus()).call_deferred()


# --- Helpers --------------------------------------------------------------------------------------

func _apply_scale() -> void:
	var vs := get_viewport().get_visible_rect().size
	var s := clampf(minf(vs.x / DESIGN_SIZE.x, vs.y / DESIGN_SIZE.y), 0.5, 4.0)
	scale = Vector2(s, s)
	root.position = Vector2.ZERO
	root.size = vs / s
	_layout_card()
	_layout_corners()


func _label(text: String, size: int, color: Color, outline: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", size)
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_constant_override(&"outline_size", outline)
	l.add_theme_color_override(&"font_outline_color", CHARCOAL)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func _panel_style(bg: Color, border: Color, border_w: int, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(radius)
	s.corner_detail = 10
	s.anti_aliasing = true
	s.shadow_color = Color(CHARCOAL, 0.4)
	s.shadow_size = 2
	s.shadow_offset = Vector2(0, 8)
	return s


static func _chip_style(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = CHARCOAL
	s.set_border_width_all(2)
	s.set_corner_radius_all(11)
	s.anti_aliasing = true
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 2
	s.content_margin_bottom = 3
	return s
