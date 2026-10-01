class_name PadlockIcon
extends Control
## A padlock drawn in code (no texture): charcoal body with a cream keyhole and a steel shackle.
## Scales with the control (square, centred). Owner: progression.

const BODY := Color("#2e2a33")
const SHACKLE := Color("#c9c3cf")
const KEYHOLE := Color("#f3e6c8")
const EDGE := Color("#fffaf0")

## 0 = closed, 1 = shackle popped open (the unlock animation drives it).
var open_amount: float = 0.0:
	set(value):
		open_amount = value
		queue_redraw()


static func make(px: float) -> PadlockIcon:
	var i := PadlockIcon.new()
	i.custom_minimum_size = Vector2(px, px)
	i.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return i


func _draw() -> void:
	var s := minf(size.x, size.y)
	if s <= 2.0:
		return
	var o := (size - Vector2(s, s)) * 0.5
	var body := Rect2(o + Vector2(0.14, 0.44) * s, Vector2(0.72, 0.5) * s)
	# Shackle: an upside-down U standing in the body, lifted and swung when opening.
	var lift := open_amount * 0.16 * s
	var sr := 0.21 * s
	var sc := o + Vector2(0.5 * s, 0.34 * s - lift * 0.5)
	var w := maxf(2.0, 0.11 * s)
	var legs_bottom := body.position.y + w * 0.5
	var shackle := PackedVector2Array()
	shackle.append(Vector2(sc.x - sr, legs_bottom))  # this leg stays in the body when opening
	for k in 17:
		var a := PI + PI * k / 16.0
		shackle.append(sc + Vector2(cos(a), sin(a)) * sr)
	shackle.append(Vector2(sc.x + sr, legs_bottom - lift))
	draw_polyline(shackle, BODY, w + maxf(2.0, 0.06 * s), true)
	draw_polyline(shackle, SHACKLE, w, true)
	var box := StyleBoxFlat.new()
	box.bg_color = BODY
	box.border_color = EDGE
	box.set_border_width_all(int(maxf(1.0, s * 0.045)))
	box.set_corner_radius_all(int(s * 0.12))
	box.corner_detail = 6
	box.anti_aliasing = true
	draw_style_box(box, body)
	var kc := body.get_center() - Vector2(0, body.size.y * 0.08)
	draw_circle(kc, s * 0.075, KEYHOLE, true, -1.0, true)
	draw_colored_polygon(PackedVector2Array([kc + Vector2(-0.04, 0.0) * s, kc + Vector2(0.04, 0.0) * s,
		kc + Vector2(0.055, 0.16) * s, kc + Vector2(-0.055, 0.16) * s]), KEYHOLE)
