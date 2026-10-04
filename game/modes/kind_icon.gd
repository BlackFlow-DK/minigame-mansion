class_name KindIcon
extends Control
## A minigame's kind as a small flat picture (vote cards): brawl, race, team, hidden, hazard,
## score, keepaway, tag, memory, throwing, climb, party. Cream on the card's colour block,
## charcoal outlines. Owner: modes.

const INK := Color("#2e2a33")
const CREAM := Color("#fffaf0")

var kind: StringName = &"party":
	set(value):
		kind = value
		queue_redraw()


func _init(p_kind: StringName = &"party", px: float = 96.0) -> void:
	kind = p_kind
	custom_minimum_size = Vector2(px, px)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var s := minf(size.x, size.y)
	if s <= 0.0:
		return
	var c := size * 0.5
	var u := s / 100.0  # drawing units: a 100 x 100 box around the centre
	var w := maxf(2.0, 4.0 * u)
	match kind:
		&"hazard":
			var tri := PackedVector2Array([c + Vector2(0, -40) * u, c + Vector2(42, 34) * u, c + Vector2(-42, 34) * u])
			_poly(tri, Color("#f2c94c"), w)
			draw_line(c + Vector2(0, -14) * u, c + Vector2(0, 12) * u, INK, 9.0 * u, true)
			draw_circle(c + Vector2(0, 24) * u, 5.0 * u, INK, true, -1.0, true)
		&"brawl":
			_blob(c + Vector2(-20, 6) * u, 22.0 * u, w)
			_blob(c + Vector2(22, 6) * u, 22.0 * u, w)
			for a: float in [-0.9, -0.3, 0.3]:
				var d := Vector2(sin(a), -cos(a))
				draw_line(c + Vector2(0, -20) * u + d * 12.0 * u, c + Vector2(0, -20) * u + d * 26.0 * u, INK, w, true)
		&"race":
			draw_line(c + Vector2(-30, 42) * u, c + Vector2(-30, -40) * u, INK, 6.0 * u, true)
			var cell := 12.0 * u
			for i in 5:
				for j in 4:
					var col := INK if (i + j) % 2 == 0 else CREAM
					draw_rect(Rect2(c + Vector2(-28, -40) * u + Vector2(i, j) * cell, Vector2(cell, cell)), col)
			draw_rect(Rect2(c + Vector2(-28, -40) * u, Vector2(5, 4) * cell), INK, false, w * 0.6)
		&"team":
			draw_circle(c + Vector2(-16, 0) * u, 26.0 * u, Color("#e69f00"), true, -1.0, true)
			draw_circle(c + Vector2(16, 0) * u, 26.0 * u, Color("#56b4e9"), true, -1.0, true)
			draw_arc(c + Vector2(-16, 0) * u, 26.0 * u, 0, TAU, 40, INK, w, true)
			draw_arc(c + Vector2(16, 0) * u, 26.0 * u, 0, TAU, 40, INK, w, true)
		&"hidden":
			var mask := PackedVector2Array()
			for i in 33:
				var t := TAU * i / 32.0
				mask.append(c + Vector2(cos(t) * 42.0, sin(t) * 20.0 - absf(cos(t)) * 6.0) * u)
			_poly(mask, CREAM, w)
			draw_circle(c + Vector2(-17, -2) * u, 9.0 * u, INK, true, -1.0, true)
			draw_circle(c + Vector2(17, -2) * u, 9.0 * u, INK, true, -1.0, true)
		&"score":
			draw_circle(c, 36.0 * u, Color("#f2c94c"), true, -1.0, true)
			draw_arc(c, 36.0 * u, 0, TAU, 48, INK, w, true)
			draw_arc(c, 24.0 * u, 0, TAU, 40, INK, w * 0.7, true)
		&"keepaway":
			var crown := PackedVector2Array([c + Vector2(-36, 26) * u, c + Vector2(-40, -22) * u, c + Vector2(-18, 0) * u,
				c + Vector2(0, -32) * u, c + Vector2(18, 0) * u, c + Vector2(40, -22) * u, c + Vector2(36, 26) * u])
			_poly(crown, Color("#f2c94c"), w)
		&"tag":
			var ghost := PackedVector2Array()
			for i in 17:
				var t := PI + PI * i / 16.0
				ghost.append(c + Vector2(cos(t) * 30.0, -6.0 + sin(t) * 30.0) * u)
			for i in 7:
				ghost.append(c + Vector2(30.0 - i * 10.0, 36.0 - (i % 2) * 10.0) * u)
			_poly(ghost, CREAM, w)
			draw_circle(c + Vector2(-11, -8) * u, 6.0 * u, INK, true, -1.0, true)
			draw_circle(c + Vector2(11, -8) * u, 6.0 * u, INK, true, -1.0, true)
		&"memory":
			draw_rect(Rect2(c - Vector2(34, 40) * u, Vector2(68, 80) * u), Color("#d98a4e"))
			draw_rect(Rect2(c - Vector2(34, 40) * u, Vector2(68, 80) * u), INK, false, w)
			draw_rect(Rect2(c - Vector2(22, 28) * u, Vector2(44, 56) * u), CREAM)
			draw_circle(c + Vector2(0, -6) * u, 10.0 * u, INK, true, -1.0, true)
			draw_rect(Rect2(c + Vector2(-14, 8) * u, Vector2(28, 16) * u), INK)
		&"throwing":
			for k in 3:
				draw_line(c + Vector2(-44, -12 + k * 12) * u, c + Vector2(-12, -12 + k * 12) * u, INK, w, true)
			draw_circle(c + Vector2(14, 0) * u, 26.0 * u, CREAM, true, -1.0, true)
			draw_arc(c + Vector2(14, 0) * u, 26.0 * u, 0, TAU, 40, INK, w, true)
		&"climb":
			var steps := PackedVector2Array()
			for i in 4:
				steps.append(c + Vector2(-40 + i * 20, 36 - i * 20) * u)
				steps.append(c + Vector2(-20 + i * 20, 36 - i * 20) * u)
			for i in range(steps.size() - 1):
				draw_line(steps[i], steps[i + 1], INK, w * 1.4, true)
			draw_line(c + Vector2(-44, 40) * u, c + Vector2(44, 40) * u, Color("#56b4e9"), 8.0 * u, true)
		_:
			draw_circle(c + Vector2(-12, 24) * u, 14.0 * u, INK, true, -1.0, true)
			draw_line(c + Vector2(0, 24) * u, c + Vector2(0, -36) * u, INK, 7.0 * u, true)
			draw_line(c + Vector2(0, -36) * u, c + Vector2(26, -22) * u, INK, 7.0 * u, true)


func _poly(points: PackedVector2Array, fill: Color, w: float) -> void:
	draw_colored_polygon(points, fill)
	var loop := points.duplicate()
	loop.append(points[0])
	draw_polyline(loop, INK, w, true)


func _blob(at: Vector2, r: float, w: float) -> void:
	draw_circle(at, r, CREAM, true, -1.0, true)
	draw_arc(at, r, 0, TAU, 36, INK, w, true)
	draw_circle(at + Vector2(-r * 0.3, -r * 0.1), r * 0.14, INK, true, -1.0, true)
	draw_circle(at + Vector2(r * 0.3, -r * 0.1), r * 0.14, INK, true, -1.0, true)
