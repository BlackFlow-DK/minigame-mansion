class_name MenuIcon
extends Control
## Tiny drawn icons for the roster (no glyph/font dependency): a player-colour blob and a host crown.

enum Kind { BLOB, CROWN }

var kind: Kind = Kind.BLOB
var colour: Color = MenuUI.TEAL


static func blob(c: Color, px: float = 30.0) -> MenuIcon:
	var i := MenuIcon.new()
	i.kind = Kind.BLOB
	i.colour = c
	i.custom_minimum_size = Vector2(px, px)
	return i


static func crown(px: float = 26.0) -> MenuIcon:
	var i := MenuIcon.new()
	i.kind = Kind.CROWN
	i.colour = MenuUI.GOLD
	i.custom_minimum_size = Vector2(px, px)
	i.tooltip_text = "Host"
	return i


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


func _draw() -> void:
	var s := size
	var ink := MenuUI.CHARCOAL
	match kind:
		Kind.BLOB:
			var r := minf(s.x, s.y) * 0.5 - 2.0
			var c := s * 0.5
			draw_circle(c, r + 2.0, ink)
			draw_circle(c, r, colour)
			var eye := r * 0.22
			for sx: float in [-0.35, 0.35]:
				var e := c + Vector2(sx * r, -0.12 * r)
				draw_circle(e, eye, Color.WHITE)
				draw_circle(e + Vector2(0, eye * 0.2), eye * 0.55, ink)
		Kind.CROWN:
			var w := s.x
			var h := s.y
			var pts := PackedVector2Array([
				Vector2(w * 0.08, h * 0.82), Vector2(w * 0.04, h * 0.28), Vector2(w * 0.3, h * 0.52),
				Vector2(w * 0.5, h * 0.14), Vector2(w * 0.7, h * 0.52), Vector2(w * 0.96, h * 0.28),
				Vector2(w * 0.92, h * 0.82)])
			draw_colored_polygon(pts, colour)
			var outline := pts.duplicate()
			outline.append(pts[0])
			draw_polyline(outline, ink, 2.5, true)
			draw_circle(Vector2(w * 0.5, h * 0.62), w * 0.08, MenuUI.RED)
