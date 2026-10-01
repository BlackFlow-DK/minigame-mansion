class_name CoinIcon
extends Control
## A Mansion Coin drawn in code (no texture): a gold disc with a darker rim, a little mansion
## stamped in the middle and a shine. Scales with the control (square, centred). Owner: progression.

const GOLD := Color("#f2c14e")
const RIM := Color("#c98a1c")
const STAMP := Color("#a8701a")
const SHINE := Color("#fff1b8")
const INK := Color("#2e2a33")


## A coin icon of `px` pixels.
static func make(px: float) -> CoinIcon:
	var i := CoinIcon.new()
	i.custom_minimum_size = Vector2(px, px)
	i.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	i.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return i


func _draw() -> void:
	var s := minf(size.x, size.y)
	if s <= 2.0:
		return
	var c := size * 0.5
	var r := s * 0.5
	var outline := maxf(1.5, s * 0.07)
	draw_circle(c, r, INK, true, -1.0, true)
	draw_circle(c, r - outline, RIM, true, -1.0, true)
	var face_r := (r - outline) * 0.8
	draw_circle(c - Vector2(0, s * 0.02), face_r, GOLD, true, -1.0, true)
	draw_arc(c - Vector2(0, s * 0.02), face_r, 0.0, TAU, 40, STAMP, maxf(1.0, s * 0.035), true)
	# The stamp: a tiny mansion (roof + house + door).
	var u := face_r
	var m := c + Vector2(0, u * 0.06)
	var roof := PackedVector2Array([m + Vector2(-0.62, -0.06) * u, m + Vector2(0.0, -0.6) * u, m + Vector2(0.62, -0.06) * u])
	draw_colored_polygon(roof, STAMP)
	draw_rect(Rect2(m + Vector2(-0.44, -0.08) * u, Vector2(0.88, 0.56) * u), STAMP)
	draw_rect(Rect2(m + Vector2(-0.12, 0.16) * u, Vector2(0.24, 0.32) * u), GOLD)
	# Shine on the upper left of the rim.
	draw_arc(c, r - outline * 1.6, deg_to_rad(200.0), deg_to_rad(250.0), 10, SHINE, maxf(1.0, s * 0.06), true)
