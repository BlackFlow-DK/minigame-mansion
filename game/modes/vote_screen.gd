class_name VoteScreen
extends Control
## The VOTE phase on this peer: three minigame cards, every player's marker (a blob in their
## colour) under the card it picked, a gold ring once locked; the local player moves with
## left/right and locks with action (or clicks a card). Reads Session only (every peer has the
## same vote state through Session's RPCs). Owner: modes.

const CARD_SIZE := Vector2(330, 392)
const CARD_GAP := 34.0
const MARKER_PX := 34.0
const PAPER := Color("#fffaf0")

## The candidate the local marker is on (shown at once, sent to the host; -1 = none yet).
var cursor: int = -1


## A new vote: the local marker starts on the middle card (not a vote until moved or locked).
func reset_cursor() -> void:
	cursor = -1

var _title: Label
var _round_pill: Label
var _timer: Label
var _hint: Label
var _cards: Array[PanelContainer] = []
var _card_styles: Array[StyleBoxFlat] = []
var _card_names: Array[Label] = []
var _card_counts: Array[Label] = []
var _card_markers: Array[HFlowContainer] = []
var _card_you: Array[Label] = []
var _card_tabs: Array[PanelContainer] = []
var _row: HBoxContainer
var _pop: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(RoundStyle.dim(0.86))

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override(&"separation", 14)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_theme_constant_override(&"separation", 18)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(head)
	var pill_style := RoundStyle.box(RoundStyle.TEAL, RoundStyle.CHARCOAL, 4, 16, false)
	pill_style.set_content_margin_all(6.0)
	pill_style.content_margin_left = 18.0
	pill_style.content_margin_right = 18.0
	var pill := RoundStyle.panel(pill_style)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_round_pill = RoundStyle.label("ROUND 1", 22, RoundStyle.CREAM, 6)
	pill.add_child(_round_pill)
	head.add_child(pill)
	_title = RoundStyle.label("VOTE FOR THE NEXT GAME!", 50, RoundStyle.GOLD, 14)
	head.add_child(_title)
	var timer_style := RoundStyle.box(RoundStyle.CHARCOAL, RoundStyle.GOLD, 4, 30, false)
	timer_style.set_content_margin_all(2.0)
	var timer_panel := RoundStyle.panel(timer_style)
	timer_panel.custom_minimum_size = Vector2(60, 60)
	timer_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_timer = RoundStyle.label("8", 32, RoundStyle.GOLD, 6)
	timer_panel.add_child(_timer)
	head.add_child(timer_panel)

	_row = HBoxContainer.new()
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override(&"separation", int(CARD_GAP))
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_row)
	for i in GameModes.VOTE_CANDIDATES:
		_build_card(i)

	_hint = RoundStyle.label("Left / Right: choose   ·   E / X: lock in", 22, RoundStyle.CREAM, 6)
	col.add_child(_hint)
	visible = false


## Shows the vote that Session holds now (call on vote_started, vote_updated, vote_decided).
func refresh() -> void:
	var cands: Array[StringName] = Session.vote_candidates
	var me := Net.local_slot()
	var locked := Session.vote_locked.has(me)
	if locked and Session.vote_marks.has(me):
		cursor = Session.vote_marks[me]  # the host's word is final once locked
	elif cursor < 0 or cursor >= cands.size():
		cursor = (cands.size() >> 1) if not cands.is_empty() else -1
	var decided := Session.vote_winner >= 0
	_round_pill.text = "ROUND %d OF %d" % [Session.vote_index + 1, Session.round_count] if Session.round_count > 0 \
		else "ROUND %d" % (Session.vote_index + 1)
	if decided and Session.vote_winner < cands.size():
		_title.text = "%s WINS!" % MinigameCatalog.display_name(cands[Session.vote_winner]).to_upper()
	else:
		_title.text = "VOTE FOR THE NEXT GAME!"
	_hint.text = "Locked in! Waiting for the others..." if locked and not decided else \
		("Left / Right: choose   ·   E / X: lock in" if not decided else "")
	var counts := GameModes.counts(Session.vote_marks, cands.size())
	var my_color := RoundStyle.player_color(me)
	for i in _cards.size():
		var card := _cards[i]
		card.visible = i < cands.size()
		if not card.visible:
			continue
		var info := MinigameCatalog.info(cands[i])
		_fill_card(i, info)
		var style := _card_styles[i]
		var is_mine := i == cursor and me >= 0
		style.border_color = RoundStyle.CHARCOAL
		style.set_border_width_all(4)
		if decided:
			if i == Session.vote_winner:
				style.border_color = RoundStyle.GOLD
				style.set_border_width_all(10)
			card.modulate.a = 1.0 if i == Session.vote_winner else 0.35
		else:
			card.modulate.a = 1.0
			if is_mine:
				style.border_color = my_color
				style.set_border_width_all(9)
		_card_tabs[i].visible = is_mine and not decided
		_card_you[i].text = "YOU: LOCKED" if locked else "YOU"
		(_card_tabs[i].get_theme_stylebox(&"panel") as StyleBoxFlat).bg_color = my_color
		_card_tabs[i].reset_size()
		_card_counts[i].text = "%d vote%s" % [counts[i], "" if counts[i] == 1 else "s"]
		var want: Array[int] = []
		for s: int in RoundStyle.roster_slots():
			if Session.vote_marks.get(s, -1) == i:
				want.append(s)
		_set_markers(_card_markers[i], want)
		var target := Vector2.ONE * (1.08 if decided and i == Session.vote_winner else (1.03 if is_mine else 1.0))
		card.pivot_offset = CARD_SIZE * 0.5
		card.scale = target


## Every frame while visible: the seconds left.
func _process(_delta: float) -> void:
	if visible:
		_timer.text = str(ceili(Session.phase_time_left)) if Session.vote_winner < 0 else "!"


func _unhandled_input(event: InputEvent) -> void:
	if not visible or Session.state != Session.State.VOTE or Session.vote_winner >= 0:
		return
	var me := Net.local_slot()
	if me < 0 or Session.vote_locked.has(me) or Session.vote_candidates.is_empty():
		return
	var n := Session.vote_candidates.size()
	if event.is_action_pressed(&"ui_left") or event.is_action_pressed(&"move_left"):
		move_cursor(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_right") or event.is_action_pressed(&"move_right"):
		move_cursor(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"action") or event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"jump"):
		Session.vote(clampi(cursor, 0, n - 1), true)
		get_viewport().set_input_as_handled()


## Moves the local marker by `step` (wraps) and tells Session.
func move_cursor(step: int) -> void:
	var n := Session.vote_candidates.size()
	if n == 0:
		return
	cursor = posmod((cursor if cursor >= 0 else n >> 1) + step, n)
	Session.vote(cursor, false)
	refresh()
	if _pop and _pop.is_valid():
		_pop.kill()
	if cursor < _cards.size() and not UiMotion.reduced_motion():
		var card := _cards[cursor]
		_pop = create_tween()
		_pop.tween_property(card, ^"scale", Vector2.ONE * 1.07, 0.07)
		_pop.tween_property(card, ^"scale", Vector2.ONE * 1.03, 0.12)


## The card nodes (tests).
func cards() -> Array[PanelContainer]:
	return _cards


## Blob markers under card `i` (tests): slots in order.
func marker_slots(i: int) -> Array[int]:
	var out: Array[int] = []
	for m in _card_markers[i].get_children():
		out.append(int(m.get_meta(&"slot", -1)))
	return out


func get_title() -> String:
	return _title.text


func _build_card(i: int) -> void:
	var style := RoundStyle.box(PAPER, RoundStyle.CHARCOAL, 4, 22)
	style.set_content_margin_all(16.0)
	var card := RoundStyle.panel(style)
	card.custom_minimum_size = CARD_SIZE
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(_on_card_input.bind(i))
	_row.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", 8)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(v)
	var icon_style := RoundStyle.box(RoundStyle.TEAL, RoundStyle.CHARCOAL, 3, 14, false)
	icon_style.set_content_margin_all(4.0)
	var icon := RoundStyle.panel(icon_style)
	icon.custom_minimum_size = Vector2(0, 112)
	icon.name = "Icon"
	var glyph := KindIcon.new(&"party", 100.0)
	glyph.name = "Glyph"
	glyph.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.add_child(glyph)
	v.add_child(icon)
	var name_l := RoundStyle.label("", 32, RoundStyle.PLUM, 0)
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.clip_text = true
	v.add_child(name_l)
	var chip_style := RoundStyle.box(RoundStyle.CHARCOAL, Color.TRANSPARENT, 0, 10, false)
	chip_style.set_content_margin_all(2.0)
	chip_style.content_margin_left = 12.0
	chip_style.content_margin_right = 12.0
	var chip := RoundStyle.panel(chip_style)
	chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	chip.name = "Kind"
	chip.add_child(RoundStyle.label("", 16, RoundStyle.CREAM, 0))
	v.add_child(chip)
	var rule := RoundStyle.label("", 17, RoundStyle.CHARCOAL, 0)
	rule.name = "Rule"
	rule.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rule.custom_minimum_size = Vector2(CARD_SIZE.x - 40.0, 0)
	rule.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rule.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	v.add_child(rule)
	# "YOU" tab hanging on the card's top edge in the local player's colour.
	var tab_holder := Control.new()
	tab_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(tab_holder)
	var tab_style := RoundStyle.box(RoundStyle.GOLD, RoundStyle.CHARCOAL, 4, 14, false)
	tab_style.set_content_margin_all(2.0)
	tab_style.content_margin_left = 16.0
	tab_style.content_margin_right = 16.0
	var tab := RoundStyle.panel(tab_style)
	tab.name = "YouTab"
	tab.anchor_left = 0.5
	tab.anchor_right = 0.5
	tab.offset_top = -38.0
	tab.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var you := RoundStyle.label("YOU", 20, RoundStyle.CREAM, 6)
	tab.add_child(you)
	tab_holder.add_child(tab)
	var markers := HFlowContainer.new()
	markers.alignment = FlowContainer.ALIGNMENT_CENTER
	markers.add_theme_constant_override(&"h_separation", 3)
	markers.add_theme_constant_override(&"v_separation", 3)
	markers.custom_minimum_size = Vector2(0, MARKER_PX)
	markers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(markers)
	var count := RoundStyle.label("0 votes", 18, RoundStyle.PLUM, 0)
	v.add_child(count)
	_cards.append(card)
	_card_styles.append(style)
	_card_names.append(name_l)
	_card_counts.append(count)
	_card_markers.append(markers)
	_card_you.append(you)
	_card_tabs.append(tab)


func _fill_card(i: int, info: Dictionary) -> void:
	var card := _cards[i]
	_card_names[i].text = str(info["name"])
	var icon := card.find_child("Icon", true, false) as PanelContainer
	var icon_style := icon.get_theme_stylebox(&"panel") as StyleBoxFlat
	icon_style.bg_color = info["color"]
	(icon.find_child("Glyph", true, false) as KindIcon).kind = info["kind"]
	var kind := card.find_child("Kind", true, false) as PanelContainer
	(kind.get_child(0) as Label).text = str(info["kind_name"]).to_upper()
	(card.find_child("Rule", true, false) as Label).text = str(info["rule"])


func _set_markers(holder: HFlowContainer, slots: Array[int]) -> void:
	var have: Array[int] = []
	for m in holder.get_children():
		have.append(int(m.get_meta(&"slot", -1)))
	if have != slots:
		for m in holder.get_children():
			holder.remove_child(m)
			m.queue_free()
		for s in slots:
			var holder_box := Control.new()
			holder_box.custom_minimum_size = Vector2(MARKER_PX, MARKER_PX)
			holder_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
			holder_box.set_meta(&"slot", s)
			var ring := Panel.new()
			ring.name = "Ring"
			ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var rs := StyleBoxFlat.new()
			rs.bg_color = Color.TRANSPARENT
			rs.border_color = RoundStyle.GOLD
			rs.set_border_width_all(3)
			rs.set_corner_radius_all(int(MARKER_PX * 0.5))
			ring.add_theme_stylebox_override(&"panel", rs)
			holder_box.add_child(ring)
			var blob := RoundBlobIcon.new(RoundStyle.player_color(s), MARKER_PX - 6.0)
			blob.position = Vector2(3, 3)
			blob.size = Vector2(MARKER_PX - 6.0, MARKER_PX - 6.0)
			holder_box.add_child(blob)
			holder_box.tooltip_text = RoundStyle.player_name(s)
			holder.add_child(holder_box)
	for m in holder.get_children():
		var ring := m.get_node(^"Ring") as Panel
		ring.visible = Session.vote_locked.has(int(m.get_meta(&"slot", -1)))


func _on_card_input(event: InputEvent, i: int) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		var me := Net.local_slot()
		if me < 0 or Session.vote_locked.has(me) or Session.vote_winner >= 0:
			return
		cursor = i
		Session.vote(i, true)
		accept_event()
