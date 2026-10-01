class_name RoundPodium
extends Control
## End-of-session podium: final standings on three blocks (2nd, 1st, 3rd), everyone else
## in a row below, the winner celebrated with a bouncing blob and confetti, and a
## "Back to lobby" button that RoundUI reveals. Owner: round UI.

signal back_pressed

## Designed for 1280x720; the stage area is centred at any size.
const STAGE_SIZE := Vector2(1280, 720)
const FLOOR_Y := 590.0
const BLOCK_W := 250.0
const BLOCK_H: Array[float] = [210.0, 160.0, 120.0]
const COLUMN_X: Array[float] = [640.0, 355.0, 925.0]
const BLOCK_COLOR: Array[Color] = [RoundStyle.GOLD, RoundStyle.TEAL, RoundStyle.PLUM]
## Seconds each block takes to rise, and the gap before it.
const RISE := 0.42
const RISE_GAP := 0.1
## Seconds until (at the latest) the winner is announced and confetti starts.
const CELEBRATE_AT := 3.0 * (RISE + RISE_GAP)
## The winner banner stays this wide (it wobbles), clear of the "Back to lobby" button in the
## top-right corner; long names get a smaller font instead of running under the button.
const WINNER_MAX_W := 660.0
const WINNER_FONT_SIZE := 72
## Seconds the balance takes to count up on the coins card.
const COINS_COUNT_SECONDS := 1.3

var _dim: ColorRect
var _stage: Control
var _title: Label
var _winner: Label
var _others: HBoxContainer
var _confetti: Array[CPUParticles2D] = []
var _back: Button
var _seq: Tween
var _loops: Array[Tween] = []
## Final ranking last shown (slots, best first). Read by tests.
var final_ranking: Array[int] = []
## Mansion Coins card (top-left): the session bonus and the new balance counting up.
var _coins_card: PanelContainer
var _coins_bonus_label: Label
var _coins_total_label: Label
## Session bonus shown by the last play() (0: no card).
var coins_bonus: int = 0
## The balance number on the card right now (counts up to `Progression.coins`).
var coins_total_shown: int = 0:
	set(value):
		if value != coins_total_shown and _coins_tick_sound and is_visible_in_tree():
			_coin_ticks += 1
			if _coin_ticks % 4 == 0:
				Sfx.play(&"coin", Vector3.INF, -6.0, 1.0 + 0.004 * float(_coin_ticks))
		coins_total_shown = value
		if _coins_total_label:
			_coins_total_label.text = "Total  %d" % value
var _coins_tick_sound: bool = false
var _coin_ticks: int = 0
var _coins_from: int = 0
var _coins_to: int = 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim = RoundStyle.dim(0.95)
	add_child(_dim)

	_stage = Control.new()
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.anchor_left = 0.5
	_stage.anchor_right = 0.5
	_stage.anchor_top = 0.5
	_stage.anchor_bottom = 0.5
	_stage.offset_left = -STAGE_SIZE.x * 0.5
	_stage.offset_right = STAGE_SIZE.x * 0.5
	_stage.offset_top = -STAGE_SIZE.y * 0.5
	_stage.offset_bottom = STAGE_SIZE.y * 0.5
	add_child(_stage)

	_title = RoundStyle.label("FINAL STANDINGS", 40, RoundStyle.CREAM, 10)
	_title.position = Vector2(0, 14)
	_title.size = Vector2(STAGE_SIZE.x, 56)
	_stage.add_child(_title)

	_winner = RoundStyle.label("", WINNER_FONT_SIZE, RoundStyle.GOLD, 18)
	_winner.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_winner.clip_text = true
	_winner.position = Vector2((STAGE_SIZE.x - WINNER_MAX_W) * 0.5, 66)
	_winner.size = Vector2(WINNER_MAX_W, 96)
	_winner.pivot_offset = _winner.size * 0.5
	_stage.add_child(_winner)

	_others = HBoxContainer.new()
	_others.alignment = BoxContainer.ALIGNMENT_CENTER
	_others.add_theme_constant_override(&"separation", 10)
	_others.position = Vector2(0, FLOOR_Y + 22.0)
	_others.size = Vector2(STAGE_SIZE.x, 90)
	_others.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(_others)

	var texture := _confetti_texture()
	for side in 2:
		var p := CPUParticles2D.new()
		p.texture = texture
		p.amount = 90
		p.lifetime = 4.5
		p.emitting = false
		p.position = Vector2(STAGE_SIZE.x * (0.25 + 0.5 * side), -30)
		p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
		p.emission_rect_extents = Vector2(STAGE_SIZE.x * 0.27, 10)
		p.direction = Vector2(0, 1)
		p.spread = 30.0
		p.gravity = Vector2(0, 260)
		p.initial_velocity_min = 60.0
		p.initial_velocity_max = 220.0
		p.angular_velocity_min = -400.0
		p.angular_velocity_max = 400.0
		p.angle_min = 0.0
		p.angle_max = 360.0
		p.scale_amount_min = 1.0
		p.scale_amount_max = 1.9
		p.damping_min = 10.0
		p.damping_max = 40.0
		var ramp := Gradient.new()
		ramp.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
		ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.4, 0.6, 0.8])
		ramp.colors = PackedColorArray([RoundStyle.GOLD, RoundStyle.TEAL, RoundStyle.RED, RoundStyle.CREAM, RoundStyle.PLUM.lightened(0.3)])
		p.color_initial_ramp = ramp
		_stage.add_child(p)
		_confetti.append(p)

	_back = Button.new()
	_back.text = "Back to lobby"
	_back.add_theme_font_size_override(&"font_size", 28)
	_back.anchor_left = 1.0
	_back.anchor_right = 1.0
	_back.offset_left = -300.0
	_back.offset_right = -24.0
	_back.offset_top = 20.0
	_back.offset_bottom = 84.0
	_back.visible = false
	_back.pressed.connect(func() -> void: back_pressed.emit())
	add_child(_back)
	_build_coins_card()


## Shows the final standings for `ranking` (slots, best first) with `totals` (slot -> points).
## `coins_bonus`: this player's Mansion Coin session bonus; once the winner is celebrated a card
## pops in with "+N coins" and the balance counting up to `Progression.coins` (0: no card).
func play(ranking: Array, totals: Dictionary, p_coins_bonus: int = 0) -> void:
	stop()
	final_ranking.assign(ranking)
	coins_bonus = maxi(0, p_coins_bonus)
	_coins_card.visible = false
	_back.visible = false
	for c in _stage.get_children():
		if c.has_meta(&"podium_piece"):
			_stage.remove_child(c)
			c.queue_free()
	for c in _others.get_children():
		_others.remove_child(c)
		c.queue_free()
	for p in _confetti:
		p.emitting = false

	var winner_slot := int(ranking[0]) if not ranking.is_empty() else -1
	_winner.text = ("%s WINS!" % RoundStyle.player_name(winner_slot).to_upper()) if winner_slot >= 0 else "WHAT A PARTY!"
	_fit_winner_font()
	_winner.modulate.a = 0.0
	_winner.scale = Vector2(0.3, 0.3)

	_seq = create_tween()
	var placements := mini(3, ranking.size())
	# Rise order: 3rd, 2nd, then 1st.
	for place_i in range(placements - 1, -1, -1):
		var slot := int(ranking[place_i])
		var piece := _build_column(place_i, slot, int(totals.get(slot, 0)))
		var target_y := piece.position.y
		piece.position.y = STAGE_SIZE.y + 40.0
		_seq.tween_property(piece, ^"position:y", target_y, RISE).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).set_delay(RISE_GAP)
	for i in range(3, ranking.size()):
		var slot := int(ranking[i])
		_others.add_child(_build_other(i + 1, slot, int(totals.get(slot, 0))))
	_others.modulate.a = 0.0
	_seq.parallel().tween_property(_others, ^"modulate:a", 1.0, 0.3)
	_seq.tween_callback(_celebrate)
	_seq.tween_property(_winner, ^"modulate:a", 1.0, 0.15)
	_seq.parallel().tween_property(_winner, ^"scale", Vector2.ONE, 0.5).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	if coins_bonus > 0:
		_seq.tween_interval(0.35)
		_seq.tween_callback(_show_coins)
		_seq.tween_interval(0.35)
		_seq.tween_callback(func() -> void: _coins_tick_sound = true)
		_seq.tween_method(_set_coins_total, 0.0, 1.0, COINS_COUNT_SECONDS).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_seq.tween_callback(_coins_done)


func is_coins_card_shown() -> bool:
	return _coins_card.visible


func _show_coins() -> void:
	_coins_to = Progression.coins
	_coins_from = maxi(0, _coins_to - coins_bonus)
	_coin_ticks = 0
	_coins_tick_sound = false
	coins_total_shown = _coins_from
	_coins_bonus_label.text = "+%d coins" % coins_bonus
	_coins_card.visible = true
	_coins_card.pivot_offset = Vector2(0, _coins_card.size.y * 0.5)
	_coins_card.scale = Vector2(0.4, 0.4)
	_coins_card.modulate.a = 0.0
	var t := create_tween()
	t.tween_property(_coins_card, ^"modulate:a", 1.0, 0.12)
	t.parallel().tween_property(_coins_card, ^"scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	Sfx.play(&"coin_big")


func _set_coins_total(t: float) -> void:
	coins_total_shown = roundi(lerpf(float(_coins_from), float(_coins_to), t))


func _coins_done() -> void:
	_coins_tick_sound = false
	coins_total_shown = _coins_to
	Sfx.play(&"coin", Vector3.INF, 0.0, 1.3)
	_coins_total_label.pivot_offset = _coins_total_label.size * 0.5
	var t := create_tween()
	t.tween_property(_coins_total_label, ^"scale", Vector2(1.18, 1.18), 0.08)
	t.tween_property(_coins_total_label, ^"scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _build_coins_card() -> void:
	var style := RoundStyle.box(Color(RoundStyle.CHARCOAL, 0.96), RoundStyle.GOLD, 5, 24)
	style.content_margin_left = 16.0
	style.content_margin_right = 22.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 10.0
	_coins_card = RoundStyle.panel(style)
	_coins_card.name = "CoinsCard"
	_coins_card.position = Vector2(24, 20)
	_stage.add_child(_coins_card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_coins_card.add_child(row)
	row.add_child(CoinIcon.make(56))
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", -4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	_coins_bonus_label = RoundStyle.label("+0 coins", 34, RoundStyle.GOLD, 9)
	_coins_bonus_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	col.add_child(_coins_bonus_label)
	_coins_total_label = RoundStyle.label("Total  0", 22, RoundStyle.CREAM, 6)
	_coins_total_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	col.add_child(_coins_total_label)
	_coins_card.visible = false


func _fit_winner_font() -> void:
	var font := _winner.get_theme_font(&"font")
	var size := WINNER_FONT_SIZE
	if font:
		var w := font.get_string_size(_winner.text, HORIZONTAL_ALIGNMENT_LEFT, -1, WINNER_FONT_SIZE).x + 36.0
		if w > WINNER_MAX_W:
			size = maxi(32, int(WINNER_FONT_SIZE * WINNER_MAX_W / w))
	_winner.add_theme_font_size_override(&"font_size", size)


func stop() -> void:
	if _seq and _seq.is_valid():
		_seq.kill()
	for t in _loops:
		if t.is_valid():
			t.kill()
	_loops.clear()
	for p in _confetti:
		p.emitting = false


func show_back_button() -> void:
	if _back.visible:
		return
	_back.visible = true
	_back.pivot_offset = _back.size * 0.5
	_back.scale = Vector2(0.4, 0.4)
	var t := create_tween()
	t.tween_property(_back, ^"scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func is_back_button_shown() -> bool:
	return _back.visible


func is_confetti_on() -> bool:
	return not _confetti.is_empty() and _confetti[0].emitting


func _celebrate() -> void:
	for p in _confetti:
		p.emitting = true
	var blob := _stage.find_child("WinnerBlob", true, false) as Control
	if blob:
		var base_y := blob.position.y
		var t := create_tween().set_loops()
		t.tween_property(blob, ^"position:y", base_y - 26.0, 0.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.tween_property(blob, ^"position:y", base_y, 0.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_loops.append(t)
	var wobble := create_tween().set_loops()
	wobble.tween_property(_winner, ^"rotation_degrees", 2.5, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	wobble.tween_property(_winner, ^"rotation_degrees", -2.5, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_loops.append(wobble)


## One podium column: blob, name and score standing on a numbered block.
func _build_column(place_i: int, slot: int, total: int) -> Control:
	var col := Control.new()
	col.set_meta(&"podium_piece", true)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := BLOCK_H[place_i]
	var blob_size := 118.0 if place_i == 0 else 92.0
	var col_h := h + blob_size + 44.0
	col.size = Vector2(BLOCK_W, col_h)
	col.position = Vector2(COLUMN_X[place_i] - BLOCK_W * 0.5, FLOOR_Y - col_h)
	_stage.add_child(col)

	var blob := RoundBlobIcon.new(RoundStyle.player_color(slot), blob_size)
	blob.size = Vector2(blob_size, blob_size)
	blob.position = Vector2((BLOCK_W - blob_size) * 0.5, 0)
	if place_i == 0:
		blob.name = "WinnerBlob"
	col.add_child(blob)

	var name_label := RoundStyle.label(RoundStyle.player_name(slot), 30 if place_i == 0 else 26, RoundStyle.CREAM, 8)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.clip_text = true
	name_label.position = Vector2(-20, blob_size + 2.0)
	name_label.size = Vector2(BLOCK_W + 40.0, 38)
	col.add_child(name_label)

	var style := RoundStyle.box(BLOCK_COLOR[place_i], RoundStyle.CHARCOAL, 5, 18)
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	var block := RoundStyle.panel(style)
	block.position = Vector2(0, col_h - h)
	block.size = Vector2(BLOCK_W, h)
	col.add_child(block)
	var inner := VBoxContainer.new()
	inner.alignment = BoxContainer.ALIGNMENT_BEGIN
	inner.add_theme_constant_override(&"separation", -6)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	block.add_child(inner)
	var num_color := RoundStyle.CHARCOAL if place_i != 2 else RoundStyle.CREAM
	inner.add_child(RoundStyle.label(str(place_i + 1), 64 if place_i == 0 else 52, num_color, 0))
	inner.add_child(RoundStyle.label("%d pts" % total, 26, RoundStyle.CREAM, 7))
	return col


func _build_other(place: int, slot: int, total: int) -> Control:
	var style := RoundStyle.box(Color(RoundStyle.CHARCOAL, 0.95), RoundStyle.player_color(slot), 3, 14, false)
	style.set_content_margin_all(6.0)
	style.content_margin_left = 10.0
	style.content_margin_right = 12.0
	var pill := RoundStyle.panel(style)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_child(row)
	row.add_child(RoundStyle.label(RoundStyle.ordinal(place), 20, RoundStyle.CREAM, 5))
	var blob := RoundBlobIcon.new(RoundStyle.player_color(slot), 30.0)
	blob.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(blob)
	var name_label := RoundStyle.label(RoundStyle.player_name(slot), 20, RoundStyle.CREAM, 5)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.clip_text = true
	name_label.custom_minimum_size = Vector2(88, 0)
	row.add_child(name_label)
	row.add_child(RoundStyle.label(str(total), 22, RoundStyle.GOLD, 5))
	return pill


static func _confetti_texture() -> ImageTexture:
	var img := Image.create_empty(10, 5, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)
