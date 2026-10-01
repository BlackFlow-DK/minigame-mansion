class_name RoundIntroCard
extends Control
## Title card (minigame title + one-line rule) that slides in, then parks at the top while
## a big 3-2-1 counts down. "GO!" belongs to the HUD (shown on Session.round_started).
## Owner: round UI.

const CARD_SIZE := Vector2(840, 300)
## Seconds: card slides in, holds, then moves up for the countdown.
const CARD_IN := 0.45
const CARD_HOLD := 2.2
const CARD_PARK := 0.35
## Seconds the card waits before sliding in: the stage-load wipe opens first, and a load hitch
## lands in this wait instead of skipping the slide. Taken out of CARD_HOLD (timing unchanged).
const CARD_WAIT := 0.3
## Each number of the countdown shows for this long.
const COUNT_STEP := 1.0
## Seconds from play() until the countdown has shown "1" for a full step: when
## Session.round_started is expected. An earlier round_started simply cuts it short.
const LEAD_SECONDS := CARD_IN + CARD_HOLD + CARD_PARK + 3.0 * COUNT_STEP

var _dim: ColorRect
var _card: PanelContainer
var _round_label: Label
var _title: Label
var _rule: Label
var _count: Label
var _seq: Tween
var _pop: Tween
## The number currently shown (3, 2, 1), 0 before the countdown. Read by tests.
var count_value: int = 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim = RoundStyle.dim(0.45)
	add_child(_dim)

	var center := RoundStyle.centered()
	add_child(center)
	var holder := Control.new()
	holder.custom_minimum_size = CARD_SIZE
	center.add_child(holder)

	var style := RoundStyle.box(RoundStyle.PLUM, RoundStyle.GOLD, 8, 32)
	style.set_content_margin_all(24.0)
	_card = RoundStyle.panel(style)
	_card.size = CARD_SIZE
	_card.custom_minimum_size = CARD_SIZE
	_card.pivot_offset = CARD_SIZE * 0.5
	holder.add_child(_card)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override(&"separation", 10)
	_card.add_child(vbox)

	var pill_style := RoundStyle.box(RoundStyle.TEAL, RoundStyle.CHARCOAL, 4, 16, false)
	pill_style.set_content_margin_all(6.0)
	pill_style.content_margin_left = 18.0
	pill_style.content_margin_right = 18.0
	var pill := RoundStyle.panel(pill_style)
	pill.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_round_label = RoundStyle.label("ROUND 1", 24, RoundStyle.CREAM, 6)
	pill.add_child(_round_label)
	vbox.add_child(pill)

	_title = RoundStyle.label("", 76, RoundStyle.GOLD, 16)
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.clip_text = true
	vbox.add_child(_title)

	_rule = RoundStyle.label("", 32, RoundStyle.CREAM, 8)
	_rule.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rule.custom_minimum_size = Vector2(CARD_SIZE.x - 60.0, 0)
	vbox.add_child(_rule)

	var count_center := RoundStyle.centered()
	count_center.offset_top = 140.0
	add_child(count_center)
	_count = RoundStyle.label("", 280, RoundStyle.GOLD, 28)
	_count.custom_minimum_size = Vector2(600, 380)
	_count.pivot_offset = Vector2(300, 190)
	count_center.add_child(_count)
	_count.visible = false


## Starts the title card and countdown for round `index` (0-based) of `count` (0 = unknown).
func play(title: String, rule_text: String, index: int, count: int) -> void:
	stop()
	count_value = 0
	_title.text = title.to_upper() if title != "" else "GET READY"
	_rule.text = rule_text
	_round_label.text = "ROUND %d OF %d" % [index + 1, count] if count > 0 else "ROUND %d" % (index + 1)
	_count.visible = false
	_dim.modulate.a = 1.0
	_card.modulate.a = 1.0
	_card.scale = Vector2.ONE
	_card.position = Vector2(-1600, 0)
	_card.rotation_degrees = -12.0

	_seq = create_tween()
	_seq.tween_interval(CARD_WAIT)
	_seq.tween_property(_card, ^"position:x", 0.0, CARD_IN).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_seq.parallel().tween_property(_card, ^"rotation_degrees", -2.0, CARD_IN).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_seq.tween_property(_card, ^"rotation_degrees", 0.0, 0.6).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_seq.tween_interval(CARD_HOLD - 0.6 - CARD_WAIT)
	_seq.tween_property(_card, ^"position:y", -228.0, CARD_PARK).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_seq.parallel().tween_property(_card, ^"scale", Vector2(0.62, 0.62), CARD_PARK).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_seq.parallel().tween_property(_dim, ^"modulate:a", 0.35, CARD_PARK)
	for n: int in [3, 2, 1]:
		_seq.tween_callback(_show_number.bind(n))
		_seq.tween_interval(COUNT_STEP)


func get_title() -> String:
	return _title.text


func get_rule() -> String:
	return _rule.text


func get_round_text() -> String:
	return _round_label.text


## Stops every animation (the panel is being hidden).
func stop() -> void:
	if _seq and _seq.is_valid():
		_seq.kill()
	if _pop and _pop.is_valid():
		_pop.kill()


func _show_number(n: int) -> void:
	count_value = n
	_count.text = str(n)
	var colors: Array[Color] = [RoundStyle.TEAL, RoundStyle.GOLD, RoundStyle.RED]
	_count.add_theme_color_override(&"font_color", colors[clampi(n - 1, 0, 2)])
	_count.visible = true
	_count.scale = Vector2(2.4, 2.4)
	_count.modulate.a = 0.0
	_count.rotation_degrees = 10.0 if n % 2 == 1 else -10.0
	if _pop and _pop.is_valid():
		_pop.kill()
	# Punch: slams in from big, squashes flat on impact, stretches back, settles.
	_pop = create_tween()
	_pop.tween_property(_count, ^"scale", Vector2(1.28, 0.7), 0.13).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_pop.parallel().tween_property(_count, ^"modulate:a", 1.0, 0.1)
	_pop.parallel().tween_property(_count, ^"rotation_degrees", 0.0, 0.13).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_pop.tween_property(_count, ^"scale", Vector2(0.88, 1.14), 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_pop.tween_property(_count, ^"scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pop.tween_interval(COUNT_STEP - 0.63)
	_pop.tween_property(_count, ^"scale", Vector2(0.7, 0.7), 0.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_pop.parallel().tween_property(_count, ^"modulate:a", 0.0, 0.2)
