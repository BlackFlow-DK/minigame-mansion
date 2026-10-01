class_name CoinBalance
extends PanelContainer
## A small pill showing the Mansion Coin balance: coin icon + number on a dark rounded chip with
## a gold edge (reads on light and dark backgrounds). Follows `Progression.coins_changed`
## and counts up / down when it changes, with a little bump. Owner: progression.

const INK := Color("#2e2a33")
const GOLD := Color("#e8b33a")
const CREAM := Color("#f3e6c8")

## Seconds a change takes to count to the new value.
const COUNT_SECONDS := 0.6

var icon: CoinIcon
var label: Label
## The number on screen right now (animates towards `Progression.coins`).
var shown_value: int = 0:
	set(value):
		shown_value = value
		if label:
			label.text = str(value)

var _follow: bool = true
var _tween: Tween


## A balance pill: `font_size` for the number (the icon is sized to match). `follow`: track the
## live balance; false: call `set_value` yourself.
static func make(font_size: int = 22, follow: bool = true) -> CoinBalance:
	var b := CoinBalance.new()
	b._follow = follow
	b._build(font_size)
	return b


func _build(font_size: int) -> void:
	name = "CoinBalance"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	tooltip_text = "Mansion Coins: earn them by playing, spend them in the wardrobe"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(INK, 0.94)
	style.border_color = GOLD
	style.set_border_width_all(maxi(2, font_size / 9))
	style.set_corner_radius_all(64)
	style.corner_detail = 10
	style.anti_aliasing = true
	style.content_margin_left = font_size * 0.3
	style.content_margin_right = font_size * 0.65
	style.content_margin_top = font_size * 0.16
	style.content_margin_bottom = font_size * 0.16
	add_theme_stylebox_override(&"panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", int(font_size * 0.3))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	icon = CoinIcon.make(font_size * 1.25)
	row.add_child(icon)
	label = Label.new()
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", CREAM)
	label.add_theme_color_override(&"font_outline_color", INK)
	label.add_theme_constant_override(&"outline_size", maxi(2, font_size / 5))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	shown_value = shown_value


func _ready() -> void:
	if label == null:
		_build(22)
	if _follow:
		shown_value = Progression.coins
		Progression.coins_changed.connect(_on_coins_changed)


func _exit_tree() -> void:
	if _follow and Progression.coins_changed.is_connected(_on_coins_changed):
		Progression.coins_changed.disconnect(_on_coins_changed)


func _enter_tree() -> void:
	if _follow and is_node_ready() and not Progression.coins_changed.is_connected(_on_coins_changed):
		Progression.coins_changed.connect(_on_coins_changed)
		set_value(Progression.coins, false)


## Shows `value`; counts to it (and bumps) when `animate`.
func set_value(value: int, animate: bool = true) -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	if not animate or not is_inside_tree():
		shown_value = value
		return
	_tween = create_tween()
	_tween.tween_property(self, ^"shown_value", value, COUNT_SECONDS).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	pivot_offset = size * 0.5
	scale = Vector2(1.18, 1.18)
	_tween.parallel().tween_property(self, ^"scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_coins_changed(total: int) -> void:
	set_value(total, is_visible_in_tree())
