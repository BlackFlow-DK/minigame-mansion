class_name RoundHud
extends Control
## In-round HUD: round pill (top left), time left (top centre, only with a time limit),
## a "GO!" flash on start and a compact player strip along the bottom (colour, name,
## total score, optional per-player counter, greyed with "OUT" when eliminated). With teams
## (Minigame.assign_teams) the strip groups the cards in boxes in the team colours.
## Owner: round UI.

## Seconds left at which the timer turns red and pulses.
const LOW_TIME := 10.0


## One player's card in the bottom strip.
class PlayerCard extends PanelContainer:
	var slot: int = -1
	var eliminated: bool = false
	var counter_value: int = 0
	var counter_shown: bool = false
	var _style: StyleBoxFlat
	var _blob: RoundBlobIcon
	## The name label's width; longer names are cut with "...".
	const NAME_WIDTH := 80.0
	## The player's whole name (the label may show it shortened).
	var full_name: String = ""
	var _name: Label
	var _score: Label
	var _counter_pill: PanelContainer
	var _counter: Label
	var _out: PanelContainer
	var _pop: Tween

	func _init(p_slot: int, is_local: bool) -> void:
		slot = p_slot
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var color := RoundStyle.player_color(slot)
		# Local player: gold frame all round; everyone else: a thick stripe in their colour.
		_style = RoundStyle.box(Color(RoundStyle.CHARCOAL, 0.92), RoundStyle.GOLD if is_local else color, 4 if is_local else 0, 14)
		_style.border_width_left = 10
		_style.content_margin_left = 14.0
		_style.content_margin_right = 8.0
		_style.content_margin_top = 6.0
		_style.content_margin_bottom = 6.0
		add_theme_stylebox_override(&"panel", _style)

		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 6)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)
		_blob = RoundBlobIcon.new(color, 36.0)
		_blob.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(_blob)

		var col := VBoxContainer.new()
		col.add_theme_constant_override(&"separation", -4)
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(col)
		full_name = RoundStyle.player_name(slot)
		_name = RoundStyle.label(full_name, 19, RoundStyle.CREAM, 5)
		_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_name.clip_text = true
		_name.custom_minimum_size = Vector2(NAME_WIDTH, 0)
		col.add_child(_name)

		var line := HBoxContainer.new()
		line.add_theme_constant_override(&"separation", 6)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(line)
		_score = RoundStyle.label("0", 24, RoundStyle.GOLD, 6)
		_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		line.add_child(_score)
		var pill_style := RoundStyle.box(RoundStyle.TEAL, RoundStyle.CHARCOAL, 2, 10, false)
		pill_style.set_content_margin_all(0.0)
		pill_style.content_margin_left = 8.0
		pill_style.content_margin_right = 8.0
		_counter_pill = RoundStyle.panel(pill_style)
		_counter_pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_counter = RoundStyle.label("0", 18, RoundStyle.CREAM, 4)
		_counter.pivot_offset = Vector2(8, 12)
		_counter_pill.add_child(_counter)
		_counter_pill.visible = false
		line.add_child(_counter_pill)

		# "OUT" sticker overhanging the top-right corner (anchored inside a free overlay).
		var overlay := Control.new()
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(overlay)
		var sticker_style := RoundStyle.box(RoundStyle.RED, RoundStyle.CHARCOAL, 3, 8, false)
		sticker_style.set_content_margin_all(0.0)
		sticker_style.content_margin_left = 6.0
		sticker_style.content_margin_right = 6.0
		_out = RoundStyle.panel(sticker_style)
		_out.anchor_left = 1.0
		_out.anchor_right = 1.0
		_out.offset_left = -50.0
		_out.offset_right = 4.0
		_out.offset_top = -14.0
		_out.offset_bottom = 12.0
		_out.rotation_degrees = 10.0
		_out.add_child(RoundStyle.label("OUT", 18, RoundStyle.CREAM, 4))
		_out.visible = false
		overlay.add_child(_out)

	func _ready() -> void:
		_fit_name()

	## Shortens the name with "..." to NAME_WIDTH. Done by hand: the round font (Segoe UI
	## Black) renders no glyph for the label's built-in ellipsis, so names were just cut.
	func _fit_name() -> void:
		var font := _name.get_theme_font(&"font")
		var font_size := _name.get_theme_font_size(&"font_size")
		var text := full_name
		if font and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > NAME_WIDTH:
			while text.length() > 1 and font.get_string_size(text + "...", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > NAME_WIDTH:
				text = text.left(-1)
			text = text.strip_edges() + "..."
		_name.text = text

	func get_name_text() -> String:
		return _name.text

	func set_score(value: int) -> void:
		var changed := _score.text != str(value)
		_score.text = str(value)
		if changed and is_visible_in_tree():
			_bounce(_score)

	func get_score_text() -> String:
		return _score.text

	func set_counter(value: int) -> void:
		var changed := value != counter_value or not counter_shown
		counter_value = value
		counter_shown = true
		_counter.text = str(value)
		_counter_pill.visible = true
		if changed and is_inside_tree():
			_bounce(_counter_pill)

	## A tick: squashes wide, stretches tall, settles (frame-rate independent tween).
	func _bounce(c: Control) -> void:
		if _pop and _pop.is_valid():
			_pop.kill()
			_counter_pill.scale = Vector2.ONE
			_score.scale = Vector2.ONE
		c.pivot_offset = c.size * 0.5
		c.scale = Vector2(1.45, 0.75)
		_pop = create_tween()
		_pop.tween_property(c, ^"scale", Vector2(0.9, 1.18), 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_pop.tween_property(c, ^"scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	func clear_counter() -> void:
		counter_value = 0
		counter_shown = false
		_counter_pill.visible = false

	func set_eliminated(value: bool) -> void:
		eliminated = value
		_blob.grey = value
		_out.visible = value
		self_modulate = Color(0.6, 0.6, 0.6, 0.8) if value else Color.WHITE
		var fade := Color(1, 1, 1, 0.45) if value else Color.WHITE
		_name.modulate = fade
		_score.modulate = fade
		_counter_pill.modulate = fade


var _round_label: Label
var _timer_pill: PanelContainer
var _timer_label: Label
var _strip: HBoxContainer
var _go: Label
var _go_tween: Tween
var _pulse: Tween
var _cards: Dictionary[int, PlayerCard] = {}
## Team index -> its group box in the strip (only while the round has teams).
var _team_boxes: Dictionary[int, PanelContainer] = {}
var _time_limit: float = 0.0
var _elapsed: float = 0.0
var _running: bool = false
var _last_whole: int = -1


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var round_style := RoundStyle.box(RoundStyle.PLUM, RoundStyle.CHARCOAL, 4, 18)
	round_style.content_margin_left = 20.0
	round_style.content_margin_right = 20.0
	round_style.content_margin_top = 6.0
	round_style.content_margin_bottom = 6.0
	var round_pill := RoundStyle.panel(round_style)
	round_pill.position = Vector2(20, 18)
	add_child(round_pill)
	_round_label = RoundStyle.label("ROUND 1", 28, RoundStyle.CREAM, 6)
	round_pill.add_child(_round_label)

	var top := HBoxContainer.new()
	top.alignment = BoxContainer.ALIGNMENT_CENTER
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_top = 12.0
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)
	var timer_style := RoundStyle.box(Color(RoundStyle.CHARCOAL, 0.92), RoundStyle.TEAL, 5, 22)
	timer_style.content_margin_left = 26.0
	timer_style.content_margin_right = 26.0
	timer_style.content_margin_top = 0.0
	timer_style.content_margin_bottom = 0.0
	_timer_pill = RoundStyle.panel(timer_style)
	top.add_child(_timer_pill)
	_timer_label = RoundStyle.label("60", 52, RoundStyle.CREAM, 10)
	_timer_label.custom_minimum_size = Vector2(96, 0)
	_timer_pill.add_child(_timer_label)
	_timer_pill.visible = false

	_strip = HBoxContainer.new()
	_strip.alignment = BoxContainer.ALIGNMENT_CENTER
	_strip.add_theme_constant_override(&"separation", 8)
	_strip.anchor_left = 0.0
	_strip.anchor_right = 1.0
	_strip.anchor_top = 1.0
	_strip.anchor_bottom = 1.0
	_strip.offset_top = -80.0
	_strip.offset_bottom = -14.0
	_strip.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_strip)

	var go_center := RoundStyle.centered()
	add_child(go_center)
	_go = RoundStyle.label("GO!", 240, RoundStyle.GOLD, 30)
	_go.custom_minimum_size = Vector2(800, 360)
	_go.pivot_offset = Vector2(400, 180)
	_go.visible = false
	go_center.add_child(_go)


func _process(delta: float) -> void:
	if not _running:
		return
	_elapsed += delta
	_update_timer()


## Rebuilds the strip from the roster; clears counters and eliminations. Grouped by team
## when the round's minigame has teams (see layout_teams).
func rebuild() -> void:
	for c in _cards.values():
		if c.get_parent():
			c.get_parent().remove_child(c)
		c.queue_free()
	_cards.clear()
	var local := Net.local_slot()
	for slot in RoundStyle.roster_slots():
		var card := PlayerCard.new(slot, slot == local)
		card.set_score(RoundStyle.total_score(slot))
		_cards[slot] = card
	layout_teams()
	_update_round_label()


## Lays the cards out again: one box per team in the team colour (team order, members by
## slot), then anyone without a team; a plain row without teams. Keeps counters and "OUT".
func layout_teams() -> void:
	var teams := RoundStyle.current_teams()
	for c in _cards.values():
		if c.get_parent():
			c.get_parent().remove_child(c)
	for b in _team_boxes.values():
		_strip.remove_child(b)
		b.queue_free()
	_team_boxes.clear()
	var slots: Array[int] = []
	slots.assign(_cards.keys())
	slots.sort()
	var team_ids: Array[int] = []
	for s in slots:
		var t := int(teams.get(s, -1))
		if t >= 0 and not team_ids.has(t):
			team_ids.append(t)
	team_ids.sort()
	for t in team_ids:
		var box := _make_team_box(t)
		_strip.add_child(box)
		_team_boxes[t] = box
		var row := box.get_node(^"Row") as HBoxContainer
		for s in slots:
			if int(teams.get(s, -1)) == t:
				row.add_child(_cards[s])
	for s in slots:
		if int(teams.get(s, -1)) < 0:
			_strip.add_child(_cards[s])


## Team indices in strip order (empty without teams). Read by tests.
func get_team_order() -> Array[int]:
	var out: Array[int] = []
	for child in _strip.get_children():
		for t: int in _team_boxes:
			if _team_boxes[t] == child:
				out.append(t)
	return out


## Team whose box holds the card of `slot`, -1 if none. Read by tests.
func get_card_team(slot: int) -> int:
	var card := get_card(slot)
	if card == null:
		return -1
	for t: int in _team_boxes:
		if card.get_parent() == _team_boxes[t].get_node(^"Row"):
			return t
	return -1


func _make_team_box(team: int) -> PanelContainer:
	var color := Minigame.team_color(team)
	var style := RoundStyle.box(Color(color.darkened(0.45), 0.85), color, 4, 20)
	style.set_content_margin_all(5.0)
	style.content_margin_top = 9.0
	var box := RoundStyle.panel(style)
	box.name = "Team%d" % team
	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override(&"separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)
	# Team name tab overhanging the top edge (inside a free overlay, like the "OUT" sticker).
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(overlay)
	var tab_style := RoundStyle.box(color, RoundStyle.CHARCOAL, 3, 10, false)
	tab_style.set_content_margin_all(0.0)
	tab_style.content_margin_left = 10.0
	tab_style.content_margin_right = 10.0
	var tab := RoundStyle.panel(tab_style)
	tab.anchor_left = 0.5
	tab.anchor_right = 0.5
	tab.offset_top = -26.0
	tab.offset_bottom = -2.0
	tab.grow_horizontal = Control.GROW_DIRECTION_BOTH
	tab.add_child(RoundStyle.label(Minigame.team_name(team), 17, RoundStyle.CHARCOAL, 0))
	overlay.add_child(tab)
	return box


## Called on Session.round_started: GO! flash, timer starts.
func start(time_limit: float) -> void:
	_time_limit = maxf(0.0, time_limit)
	_elapsed = 0.0
	_running = true
	_last_whole = -1
	_timer_pill.visible = _time_limit > 0.0
	_timer_label.add_theme_color_override(&"font_color", RoundStyle.CREAM)
	_update_timer()
	refresh_scores()
	_update_round_label()
	_flash_go()


## Freezes the timer (round over).
func stop() -> void:
	_running = false


func refresh_scores() -> void:
	for slot: int in _cards:
		_cards[slot].set_score(RoundStyle.total_score(slot))


func set_counter(slot: int, value: int) -> void:
	var card := get_card(slot)
	if card:
		card.set_counter(value)


func clear_counters() -> void:
	for c in _cards.values():
		(c as PlayerCard).clear_counter()


func set_eliminated(slot: int, value: bool) -> void:
	var card := get_card(slot)
	if card:
		card.set_eliminated(value)


func get_card(slot: int) -> PlayerCard:
	return _cards.get(slot) as PlayerCard


## Seconds left on the timer (0 without a time limit). Read by tests.
func get_time_left() -> float:
	return maxf(0.0, _time_limit - _elapsed) if _time_limit > 0.0 else 0.0


func is_timer_shown() -> bool:
	return _timer_pill.visible


func _update_round_label() -> void:
	var n := Session.round_index + 1
	_round_label.text = "ROUND %d / %d" % [maxi(n, 1), Session.round_count] if Session.round_count > 0 else "ROUND %d" % maxi(n, 1)


func _update_timer() -> void:
	if _time_limit <= 0.0:
		return
	var left := get_time_left()
	var whole := ceili(left)
	if whole == _last_whole:
		return
	_last_whole = whole
	_timer_label.text = str(whole)
	if left <= LOW_TIME and left > 0.0:
		_timer_label.add_theme_color_override(&"font_color", RoundStyle.RED)
		if _pulse and _pulse.is_valid():
			_pulse.kill()
		_timer_pill.pivot_offset = _timer_pill.size * 0.5
		_timer_pill.scale = Vector2(1.25, 1.25)
		_pulse = create_tween()
		_pulse.tween_property(_timer_pill, ^"scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _flash_go() -> void:
	if _go_tween and _go_tween.is_valid():
		_go_tween.kill()
	_go.visible = true
	_go.scale = Vector2(0.3, 0.3)
	_go.modulate.a = 1.0
	_go.rotation_degrees = -8.0
	_go_tween = create_tween()
	_go_tween.tween_property(_go, ^"scale", Vector2(1.15, 1.15), 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_go_tween.parallel().tween_property(_go, ^"rotation_degrees", 0.0, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_go_tween.tween_interval(0.35)
	_go_tween.tween_property(_go, ^"scale", Vector2(1.8, 1.8), 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_go_tween.parallel().tween_property(_go, ^"modulate:a", 0.0, 0.3)
	_go_tween.tween_callback(_go.hide)
