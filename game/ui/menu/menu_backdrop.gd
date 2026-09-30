class_name MenuBackdrop
extends Control
## Opaque playful background for the title and join screens (nothing 3D exists yet there):
## plum with soft diagonal stripes and slowly drifting confetti dots.

const DOT_COUNT := 38
const DOT_COLOURS: Array[Color] = [MenuUI.TEAL, MenuUI.GOLD, MenuUI.RED, MenuUI.CREAM]

var _dots: Array[Dictionary] = []
var _t: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in DOT_COUNT:
		_dots.append({
			"pos": Vector2(rng.randf(), rng.randf()),
			"r": rng.randf_range(6.0, 26.0),
			"speed": rng.randf_range(0.004, 0.018),
			"phase": rng.randf() * TAU,
			"colour": DOT_COLOURS[i % DOT_COLOURS.size()],
		})


func _process(delta: float) -> void:
	if is_visible_in_tree():
		_t += delta
		queue_redraw()


func _draw() -> void:
	var s := size
	draw_rect(Rect2(Vector2.ZERO, s), MenuUI.PLUM)
	var stripe := Color(MenuUI.CHARCOAL, 0.09)
	var w := 70.0
	var x := -s.y
	while x < s.x:
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, s.y), Vector2(x + w, s.y), Vector2(x + w + s.y, 0), Vector2(x + s.y, 0)]), stripe)
		x += w * 2.0
	for d in _dots:
		var p: Vector2 = d["pos"]
		var yy := fposmod(p.y - _t * float(d["speed"]), 1.0)
		var xx := p.x + sin(_t * 0.6 + float(d["phase"])) * 0.01
		var c: Color = d["colour"]
		var r: float = d["r"]
		var at := Vector2(xx * s.x, yy * (s.y + 60.0) - 30.0)
		draw_circle(at, r + 3.0, Color(MenuUI.CHARCOAL, 0.25))
		draw_circle(at, r, Color(c, 0.55))
	# Darken the bottom edge a little so panels pop.
	var shade := PackedColorArray([Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(MenuUI.CHARCOAL, 0.45), Color(MenuUI.CHARCOAL, 0.45)])
	draw_polygon(PackedVector2Array([Vector2(0, s.y * 0.6), Vector2(s.x, s.y * 0.6), Vector2(s.x, s.y), Vector2(0, s.y)]), shade)
