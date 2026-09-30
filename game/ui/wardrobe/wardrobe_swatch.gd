class_name WardrobeSwatch
extends Button
## One colour choice in the wardrobe: a fat round swatch. Selected = a thick gold ring and a
## check mark; focused = the house plum focus ring. Toggle button (use a ButtonGroup).
## Owner: wardrobe UI.

const CHARCOAL := Color("#2e2a33")
const GOLD := Color("#e8b33a")
const PLUM := Color("#6d4a7c")
const PAPER := Color("#fffaf0")

var colour: Color = Color.WHITE
## "#rrggbb" this swatch stands for.
var hex: String = ""


func _init(swatch_hex: String = "#ffffff", swatch_size: float = 60.0) -> void:
	hex = swatch_hex
	colour = Color(swatch_hex)
	toggle_mode = true
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = Vector2(swatch_size, swatch_size)
	tooltip_text = swatch_hex
	for s: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"focus", &"disabled"]:
		add_theme_stylebox_override(s, StyleBoxEmpty.new())
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	toggled.connect(func(_on: bool) -> void: queue_redraw())


func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5 - 7.0
	var hovered := is_hovered()
	if button_pressed:
		draw_circle(c, r + 7.0, CHARCOAL)
		draw_circle(c, r + 4.5, GOLD)
		draw_circle(c, r + 0.5, CHARCOAL)
	else:
		draw_circle(c + Vector2(0, 3), r, Color(CHARCOAL, 0.35))
		draw_circle(c, r + (1.5 if hovered else 0.0), CHARCOAL)
	var inner := r - 3.0 + (1.5 if hovered and not button_pressed else 0.0)
	draw_circle(c, inner, colour)
	# A soft highlight so they read as glossy buttons.
	draw_circle(c + Vector2(-inner * 0.35, -inner * 0.38), inner * 0.22, Color(1, 1, 1, 0.28))
	if button_pressed:
		var mark := CHARCOAL if colour.get_luminance() > 0.55 else PAPER
		var w := maxf(3.0, r * 0.2)
		var pts := PackedVector2Array([
			c + Vector2(-r * 0.42, 0.0), c + Vector2(-r * 0.1, r * 0.32), c + Vector2(r * 0.45, -r * 0.34)])
		draw_polyline(pts, mark, w, true)
	if has_focus():
		draw_arc(c, r + 11.0, 0.0, TAU, 48, PLUM, 5.0, true)
