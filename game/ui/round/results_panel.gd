class_name RoundResults
extends Control
## Results after a round: first the round's ranking with points gained (revealed last
## place first), then an animated bar race of total scores (bars in player colours,
## counting up and re-sorting live). Owner: round UI.

## Seconds the ranking shows before the bar race.
const RANKING_SECONDS := 3.2
## Seconds at the start of the ranking while only the dim fades in (the round's final moment,
## e.g. a knockout slow-motion, stays visible), then the card pops in. Taken out of the
## ranking's hold, so the total timing is unchanged.
const LEAD_IN := 0.9
const SWAP_SECONDS := 0.3
const RACE_SECONDS := 2.2
## Seconds from play() until the bar race has settled.
const TOTAL_SECONDS := RANKING_SECONDS + SWAP_SECONDS + RACE_SECONDS + 0.6

const ROW_H := 54.0
const NAME_W := 200.0
const BAR_X := 262.0
const BAR_MAX := 560.0
const RACE_W := 960.0


## One row of the bar race (positioned by hand so it can move while re-sorting).
class RaceRow extends Control:
	var slot: int = -1
	var from_value: int = 0
	var to_value: int = 0
	var shown_value: int = 0
	var bar: Panel
	var value_label: Label
	var gain_label: Label
	## 0..1 bump of the number when it ticks (decays in RoundResults._process).
	var kick: float = 0.0

	func _init(p_slot: int, p_from: int, p_to: int) -> void:
		slot = p_slot
		from_value = p_from
		to_value = p_to
		shown_value = p_from
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size = Vector2(RACE_W, ROW_H)
		var color := RoundStyle.player_color(slot)
		var blob := RoundBlobIcon.new(color, 42.0)
		blob.position = Vector2(0, (ROW_H - 42.0) * 0.5)
		blob.size = Vector2(42, 42)
		add_child(blob)
		var name_label := RoundStyle.label(RoundStyle.player_name(slot), 26, RoundStyle.CREAM, 6)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.clip_text = true
		name_label.position = Vector2(52, 0)
		name_label.size = Vector2(NAME_W, ROW_H)
		add_child(name_label)
		bar = Panel.new()
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.add_theme_stylebox_override(&"panel", RoundStyle.box(color, RoundStyle.CHARCOAL, 3, 12))
		bar.position = Vector2(BAR_X, 8)
		bar.size = Vector2(24, ROW_H - 16)
		add_child(bar)
		value_label = RoundStyle.label(str(p_from), 30, RoundStyle.GOLD, 8)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		value_label.size = Vector2(70, ROW_H)
		add_child(value_label)
		var gain := p_to - p_from
		gain_label = RoundStyle.label("+%d" % gain, 22, RoundStyle.TEAL, 6)
		gain_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		gain_label.size = Vector2(60, ROW_H)
		gain_label.visible = gain > 0
		add_child(gain_label)

	func set_progress(t: float, max_value: int) -> void:
		var v := roundi(lerpf(float(from_value), float(to_value), t))
		if v != shown_value:
			kick = 1.0
		shown_value = v
		value_label.text = str(shown_value)
		var w := 24.0 + BAR_MAX * float(shown_value) / float(maxi(max_value, 1))
		bar.size.x = w
		value_label.position.x = BAR_X + w + 12.0
		gain_label.position.x = value_label.position.x + 16.0 + 18.0 * value_label.text.length()


var _dim: ColorRect
## Bottom centre: "+N coins" the local player earned this round (hidden when none).
var _coins_pill: PanelContainer
var _coins_label: Label
## Coins shown on the pill by the last play().
var coins_shown: int = 0
var _ranking_view: CenterContainer
var _ranking_list: VBoxContainer
var _race_view: CenterContainer
var _race_area: Control
var _rows: Dictionary[int, RaceRow] = {}
## The ranking lines' texts, top first (see get_row_texts).
var _row_texts: Array[String] = []
var _seq: Tween
var _dim_tween: Tween
var _max_value: int = 1
## 0..1 progress of the count-up.
var race_progress: float = 0.0:
	set(value):
		race_progress = value
		for r: RaceRow in _rows.values():
			r.set_progress(race_progress, _max_value)
var _racing: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim = RoundStyle.dim(0.6)
	add_child(_dim)

	_ranking_view = RoundStyle.centered()
	add_child(_ranking_view)
	var card := RoundStyle.panel(_card_style(RoundStyle.TEAL))
	card.custom_minimum_size = Vector2(760, 0)
	_ranking_view.add_child(card)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 6)
	card.add_child(vbox)
	vbox.add_child(RoundStyle.label("ROUND RESULTS", 46, RoundStyle.GOLD, 12))
	_ranking_list = VBoxContainer.new()
	_ranking_list.add_theme_constant_override(&"separation", 4)
	vbox.add_child(_ranking_list)

	_race_view = RoundStyle.centered()
	add_child(_race_view)
	var race_card := RoundStyle.panel(_card_style(RoundStyle.GOLD))
	_race_view.add_child(race_card)
	var race_box := VBoxContainer.new()
	race_box.add_theme_constant_override(&"separation", 8)
	race_card.add_child(race_box)
	race_box.add_child(RoundStyle.label("STANDINGS", 46, RoundStyle.GOLD, 12))
	_race_area = Control.new()
	_race_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	race_box.add_child(_race_area)
	_race_view.visible = false
	_build_coins_pill()


func _process(delta: float) -> void:
	if _rows.is_empty():
		return
	var order := get_bar_order()
	var k := 1.0 - exp(-12.0 * delta)
	var decay := exp(-14.0 * delta)
	for i in order.size():
		var row := _rows[order[i]]
		var target := i * ROW_H
		row.position.y = target if absf(row.position.y - target) < 0.5 else lerpf(row.position.y, target, k)
		# The number bounces each time it ticks up (squash-and-stretch, from its left edge).
		row.kick = row.kick * decay if row.kick > 0.01 else 0.0
		row.value_label.pivot_offset = Vector2(0.0, ROW_H * 0.5)
		row.value_label.scale = Vector2(1.0 + 0.22 * row.kick, 1.0 + 0.32 * row.kick)


## Shows the round's `ranking` (slots, best first) with `points` (slot -> points this
## round), then races total scores from `totals - points` up to `totals` (slot -> total).
## `coins`: Mansion Coins this player earned this round, popped in under the ranking (0: none).
## `groups`: the ranking as tied groups (Session.round_groups; empty = one slot each): a tied
## group shares one line and its place. `teams` (slot -> team): a group that is exactly one
## team's players shows as "TEAM ORANGE" in the team colour.
func play(ranking: Array, points: Dictionary, totals: Dictionary, coins: int = 0,
		groups: Array = [], teams: Dictionary = {}) -> void:
	stop()
	if groups.is_empty():
		for s: Variant in ranking:
			groups.append([int(s)])
	_build_ranking(groups, points, teams)
	_build_race(ranking, points, totals)
	_ranking_view.visible = true
	_ranking_view.modulate.a = 0.0
	_ranking_view.pivot_offset = _ranking_view.size * 0.5
	_ranking_view.scale = Vector2(0.8, 0.8)
	_race_view.visible = false
	_race_view.modulate.a = 0.0
	coins_shown = maxi(0, coins)
	_coins_label.text = "+%d coin%s" % [coins_shown, "" if coins_shown == 1 else "s"]
	_coins_pill.visible = false

	var rows := _ranking_list.get_children()
	_dim.modulate.a = 0.0
	_dim_tween = create_tween()
	_dim_tween.tween_interval(LEAD_IN * 0.5)
	_dim_tween.tween_property(_dim, ^"modulate:a", 1.0, LEAD_IN * 0.5 + 0.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_seq = create_tween()
	_seq.tween_interval(LEAD_IN)
	_seq.tween_property(_ranking_view, ^"modulate:a", 1.0, 0.12)
	_seq.parallel().tween_property(_ranking_view, ^"scale", Vector2.ONE, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# Reveal from last place up to the winner.
	for i in range(rows.size() - 1, -1, -1):
		var row := rows[i] as Control
		row.modulate.a = 0.0
		_seq.tween_callback(_pop_row.bind(row))
		_seq.tween_interval(0.12 if i > 2 else 0.3)
	if coins_shown > 0:
		_seq.tween_callback(_pop_coins)
	_seq.tween_interval(maxf(0.1, RANKING_SECONDS - LEAD_IN - 0.32 - _seq_duration_estimate(rows.size())))
	_seq.tween_property(_ranking_view, ^"modulate:a", 0.0, SWAP_SECONDS * 0.5)
	_seq.tween_callback(_ranking_view.hide)
	_seq.tween_callback(_race_view.show)
	_seq.tween_property(_race_view, ^"modulate:a", 1.0, SWAP_SECONDS * 0.5)
	_seq.tween_callback(func() -> void: _racing = true)
	# Quick start, long ease into the finish line (bars still re-sort live).
	_seq.tween_property(self, ^"race_progress", 1.0, RACE_SECONDS).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	_seq.tween_callback(_punch_leader)


func stop() -> void:
	if _seq and _seq.is_valid():
		_seq.kill()
	if _dim_tween and _dim_tween.is_valid():
		_dim_tween.kill()
	_dim.modulate.a = 1.0
	_ranking_view.modulate.a = 1.0
	_ranking_view.scale = Vector2.ONE
	_racing = false


## Slots in bar-race order: current shown value, then final total (desc), then slot.
func get_bar_order() -> Array[int]:
	var order: Array[int] = []
	order.assign(_rows.keys())
	order.sort_custom(func(a: int, b: int) -> bool:
		var ra := _rows[a]
		var rb := _rows[b]
		if ra.shown_value != rb.shown_value:
			return ra.shown_value > rb.shown_value
		if ra.to_value != rb.to_value:
			return ra.to_value > rb.to_value
		return a < b)
	return order


## The number the bar of `slot` shows right now (-1 if no bar).
func get_bar_value(slot: int) -> int:
	return _rows[slot].shown_value if _rows.has(slot) else -1


## Slots top to bottom by the rows' on-screen position.
func get_bar_screen_order() -> Array[int]:
	var order: Array[int] = []
	order.assign(_rows.keys())
	order.sort_custom(func(a: int, b: int) -> bool: return _rows[a].position.y < _rows[b].position.y)
	return order


func is_coins_shown() -> bool:
	return _coins_pill.visible


func is_race_done() -> bool:
	return _racing and race_progress >= 1.0


func is_race_shown() -> bool:
	return _race_view.visible


func _seq_duration_estimate(count: int) -> float:
	return 0.12 * maxi(0, count - 3) + 0.3 * mini(count, 3)


func _pop_row(row: Control) -> void:
	row.pivot_offset = Vector2(0, row.size.y * 0.5)
	row.scale = Vector2(0.6, 0.6)
	var t := create_tween()
	t.tween_property(row, ^"modulate:a", 1.0, 0.12)
	t.parallel().tween_property(row, ^"scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## The race is over: the leading row gives a little hop.
func _punch_leader() -> void:
	var order := get_bar_order()
	if order.is_empty():
		return
	var row := _rows[order[0]]
	row.kick = 1.6
	row.pivot_offset = Vector2(0.0, ROW_H * 0.5)
	var t := create_tween()
	t.tween_property(row, ^"scale", Vector2(1.06, 1.06), 0.09).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(row, ^"scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _pop_coins() -> void:
	_coins_pill.visible = true
	_coins_pill.pivot_offset = _coins_pill.size * 0.5
	_coins_pill.scale = Vector2(0.3, 0.3)
	_coins_pill.rotation_degrees = -8.0
	var t := create_tween()
	t.tween_property(_coins_pill, ^"scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(_coins_pill, ^"rotation_degrees", 0.0, 0.5).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	Sfx.play(&"coin")


func _build_coins_pill() -> void:
	var holder := CenterContainer.new()
	holder.name = "Coins"
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.anchor_left = 0.0
	holder.anchor_right = 1.0
	holder.anchor_top = 1.0
	holder.anchor_bottom = 1.0
	holder.offset_top = -82.0
	holder.offset_bottom = -18.0
	add_child(holder)
	var style := RoundStyle.box(Color(RoundStyle.CHARCOAL, 0.96), RoundStyle.GOLD, 4, 30)
	style.content_margin_left = 14.0
	style.content_margin_right = 24.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	_coins_pill = RoundStyle.panel(style)
	holder.add_child(_coins_pill)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_coins_pill.add_child(row)
	row.add_child(CoinIcon.make(38))
	_coins_label = RoundStyle.label("+0 coins", 32, RoundStyle.GOLD, 8)
	row.add_child(_coins_label)
	_coins_pill.visible = false


## One line per tied group (most are a single slot), best first.
func _build_ranking(groups: Array, points: Dictionary, teams: Dictionary = {}) -> void:
	for c in _ranking_list.get_children():
		_ranking_list.remove_child(c)
		c.queue_free()
	_row_texts.clear()
	var big := groups.size() <= 6
	var row_h := 52.0 if big else 46.0
	var place := 1
	for g: Variant in groups:
		var members: Array = g if g is Array else [g]
		if members.is_empty():
			continue
		if members.size() == 1:
			_add_player_row(int(members[0]), place, points, big, row_h)
		else:
			_add_group_row(members, place, points, teams, big, row_h)
		place += members.size()


## The ranking lines as shown, top first: a player's name, "TEAM ORANGE", or tied names
## joined with " & ". Read by tests.
func get_row_texts() -> Array[String]:
	return _row_texts.duplicate()


func _add_player_row(slot: int, place: int, points: Dictionary, big: bool, row_h: float) -> void:
	var who := RoundStyle.player_name(slot)
	_row_texts.append(who)
	var row := _begin_row(place, row_h)
	var blob := RoundBlobIcon.new(RoundStyle.player_color(slot), row_h - 8.0)
	blob.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(blob)
	var name_label := RoundStyle.label(who, 30 if big else 26, RoundStyle.CREAM, 7)
	_fit_name_label(name_label)
	row.add_child(name_label)
	_end_row(row, int(points.get(slot, 0)), big, false)


## A tied group on one line: overlapping blobs, then "TEAM ORANGE" (when the group is exactly
## one team) over the members' names, or the names joined; the points every member got.
func _add_group_row(members: Array, place: int, points: Dictionary, teams: Dictionary, big: bool, row_h: float) -> void:
	var team := _team_of_group(members, teams)
	var names: Array[String] = []
	for s: Variant in members:
		names.append(RoundStyle.player_name(int(s)))
	var joined := " & ".join(names)
	_row_texts.append(RoundStyle.team_title(team) if team >= 0 else joined)
	var row := _begin_row(place, row_h)
	var blob_size := row_h - 8.0
	var step := blob_size * 0.55
	var blobs := Control.new()
	blobs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blobs.custom_minimum_size = Vector2(blob_size + step * (members.size() - 1), blob_size)
	blobs.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for i in members.size():
		var blob := RoundBlobIcon.new(RoundStyle.player_color(int(members[i])), blob_size)
		blob.position = Vector2(step * i, 0)
		blob.size = Vector2(blob_size, blob_size)
		blobs.add_child(blob)
	row.add_child(blobs)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", -6)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.custom_minimum_size = Vector2(240, 0)
	if team >= 0:
		var title := RoundStyle.label(RoundStyle.team_title(team), 30 if big else 26, Minigame.team_color(team), 7)
		_fit_name_label(title)
		col.add_child(title)
		var sub := RoundStyle.label(joined, 17, RoundStyle.CREAM, 4)
		_fit_name_label(sub)
		col.add_child(sub)
	else:
		var label := RoundStyle.label(joined, 26 if big else 22, RoundStyle.CREAM, 7)
		_fit_name_label(label)
		col.add_child(label)
	row.add_child(col)
	_end_row(row, int(points.get(int(members[0]), 0)), big, true)


## The team every member of `members` is on when they are exactly that team's players; else -1.
func _team_of_group(members: Array, teams: Dictionary) -> int:
	if teams.is_empty():
		return -1
	var team := int(teams.get(int(members[0]), -1))
	if team < 0:
		return -1
	var team_size := 0
	for s: Variant in teams:
		if int(teams[s]) == team:
			team_size += 1
	for s: Variant in members:
		if int(teams.get(int(s), -1)) != team:
			return -1
	return team if team_size == members.size() else -1


func _begin_row(place: int, row_h: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	row.custom_minimum_size = Vector2(0, row_h)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var badge_style := RoundStyle.box(RoundStyle.place_color(place), RoundStyle.CHARCOAL, 3, 12, false)
	badge_style.set_content_margin_all(0.0)
	var badge := RoundStyle.panel(badge_style)
	badge.custom_minimum_size = Vector2(76, row_h - 6)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.add_child(RoundStyle.label(RoundStyle.ordinal(place), 26, RoundStyle.CHARCOAL, 0))
	row.add_child(badge)
	return row


## Points on the right ("+4", or "+4 each" for a tied group), then the row joins the list.
func _end_row(row: HBoxContainer, gained: int, big: bool, each: bool) -> void:
	var color := RoundStyle.GOLD if gained > 0 else RoundStyle.GREY
	var box := HBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	box.alignment = BoxContainer.ALIGNMENT_END
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.custom_minimum_size = Vector2(90, 0)
	var pts := RoundStyle.label("+%d" % gained, 34 if big else 30, color, 8)
	pts.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(pts)
	if each:
		var each_label := RoundStyle.label("EACH", 16, color, 4)
		each_label.size_flags_vertical = Control.SIZE_SHRINK_END
		box.add_child(each_label)
	row.add_child(box)
	_ranking_list.add_child(row)


func _fit_name_label(l: Label) -> void:
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.clip_text = true
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size = Vector2(300, 0)


func _build_race(ranking: Array, points: Dictionary, totals: Dictionary) -> void:
	for r in _rows.values():
		_race_area.remove_child(r)
		r.queue_free()
	_rows.clear()
	var slots: Array[int] = RoundStyle.roster_slots()
	for s: Variant in ranking:
		if not slots.has(int(s)):
			slots.append(int(s))
	for s: Variant in totals:
		if not slots.has(int(s)):
			slots.append(int(s))
	_max_value = 1
	for slot in slots:
		var to := int(totals.get(slot, points.get(slot, 0)))
		var from := maxi(0, to - int(points.get(slot, 0)))
		_max_value = maxi(_max_value, to)
		var row := RaceRow.new(slot, from, to)
		_race_area.add_child(row)
		_rows[slot] = row
	_race_area.custom_minimum_size = Vector2(RACE_W, ROW_H * slots.size())
	race_progress = 0.0
	# Start already sorted by the old totals.
	var order := get_bar_order()
	for i in order.size():
		_rows[order[i]].position = Vector2(0, i * ROW_H)


func _card_style(border: Color) -> StyleBoxFlat:
	var s := RoundStyle.box(Color(RoundStyle.CHARCOAL, 0.96), border, 6, 28)
	s.set_content_margin_all(26.0)
	s.content_margin_top = 16.0
	return s
