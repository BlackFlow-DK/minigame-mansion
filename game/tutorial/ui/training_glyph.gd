class_name TrainingGlyph
extends Control
## A little drawn input glyph for the Training Room cards: a chunky keyboard keycap ([W],
## [Space]), a coloured gamepad face button ((A), (X)), the left stick, or a checklist dot
## (pending number, current number, green check). Drawn in code, no textures.

enum Kind { KEY, KEY_DARK, PAD, STICK, CHECK, PENDING, CURRENT }

const CHARCOAL := Color("#2e2a33")
const PAPER := Color("#fffaf0")
const CREAM := Color("#f3e6c8")
const PLUM := Color("#6d4a7c")
const GREEN := Color("#58b368")
const GREY := Color("#a79ca8")
const PAD_GREEN := Color("#58b368")
const PAD_BLUE := Color("#3f7fd9")
const STICK_GREY := Color("#5e5263")
## Keycap: height and the dark lip under the face.
const KEY_H := 34.0
const LIP := 5.0

var kind: Kind = Kind.KEY
var text: String = ""
var tint: Color = PAD_GREEN
var font_size: int = 17

var _base := StyleBoxFlat.new()
var _face := StyleBoxFlat.new()


static func key(label: String) -> TrainingGlyph:
	return TrainingGlyph.new(Kind.KEY, label)


static func key_dark(label: String) -> TrainingGlyph:
	return TrainingGlyph.new(Kind.KEY_DARK, label)


static func pad(letter: String, color: Color) -> TrainingGlyph:
	var g := TrainingGlyph.new(Kind.PAD, letter)
	g.tint = color
	return g


static func stick(letter: String = "L") -> TrainingGlyph:
	return TrainingGlyph.new(Kind.STICK, letter)


static func dot(k: Kind, label: String = "", diameter: float = 24.0) -> TrainingGlyph:
	var g := TrainingGlyph.new(k, label)
	g.font_size = 13
	g.custom_minimum_size = Vector2(diameter, diameter)
	return g


func _init(k: Kind = Kind.KEY, label: String = "") -> void:
	kind = k
	text = label
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_base.bg_color = CHARCOAL
	_base.set_corner_radius_all(8)
	_base.anti_aliasing = true
	_face.bg_color = PAPER if k != Kind.KEY_DARK else Color("#4a4350")
	_face.border_color = CHARCOAL
	_face.set_border_width_all(2)
	_face.set_corner_radius_all(7)
	_face.anti_aliasing = true
	match k:
		Kind.KEY, Kind.KEY_DARK:
			custom_minimum_size = Vector2(maxf(KEY_H, 13.0 * label.length() + 18.0), KEY_H)
		Kind.PAD:
			custom_minimum_size = Vector2(KEY_H, KEY_H)
		Kind.STICK:
			custom_minimum_size = Vector2(KEY_H + 4.0, KEY_H + 4.0)


func _ready() -> void:
	if kind == Kind.KEY or kind == Kind.KEY_DARK:
		var font := get_theme_default_font()
		if font:
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			custom_minimum_size.x = maxf(KEY_H, w + 20.0)


func _draw() -> void:
	var font := get_theme_default_font()
	var r := Rect2(Vector2.ZERO, size)
	var c := size * 0.5
	match kind:
		Kind.KEY, Kind.KEY_DARK:
			draw_style_box(_base, r)
			var face := Rect2(Vector2.ZERO, Vector2(size.x, size.y - LIP))
			draw_style_box(_face, face)
			_text(font, face, CHARCOAL if kind == Kind.KEY else CREAM, 0)
		Kind.PAD:
			var rad := minf(size.x, size.y - 3.0) * 0.5
			var cc := Vector2(c.x, rad)
			draw_circle(cc + Vector2(0.0, 3.0), rad, CHARCOAL)
			draw_circle(cc, rad - 0.5, tint)
			draw_arc(cc, rad - 1.2, 0.0, TAU, 40, CHARCOAL, 2.5, true)
			_text(font, Rect2(cc - Vector2(rad, rad), Vector2(rad, rad) * 2.0), Color.WHITE, 5)
		Kind.STICK:
			var rad := minf(size.x, size.y - 3.0) * 0.5
			var cc := Vector2(c.x, rad)
			draw_circle(cc + Vector2(0.0, 3.0), rad, CHARCOAL)
			draw_circle(cc, rad - 0.5, STICK_GREY)
			draw_arc(cc, rad - 1.2, 0.0, TAU, 40, CHARCOAL, 2.5, true)
			# Four little direction ticks on the rim.
			for k in 4:
				var a := k * PI * 0.5
				var dir := Vector2(cos(a), sin(a))
				var tip := cc + dir * (rad - 3.0)
				var side := Vector2(-dir.y, dir.x) * 3.2
				draw_colored_polygon(PackedVector2Array([tip, tip - dir * 4.5 + side, tip - dir * 4.5 - side]), CREAM)
			draw_circle(cc, rad * 0.5, Color("#8a7f8e"))
			draw_arc(cc, rad * 0.5, 0.0, TAU, 32, CHARCOAL, 2.0, true)
			_text(font, Rect2(cc - Vector2(rad, rad), Vector2(rad, rad) * 2.0), Color.WHITE, 4, 13)
		Kind.CHECK:
			var rad := minf(size.x, size.y) * 0.5
			draw_circle(c, rad, GREEN)
			draw_arc(c, rad - 1.0, 0.0, TAU, 32, CHARCOAL, 2.0, true)
			var s := rad * 0.5
			draw_polyline(PackedVector2Array([c + Vector2(-s, 0.05 * s), c + Vector2(-0.3 * s, 0.7 * s), c + Vector2(s, -0.6 * s)]), Color.WHITE, maxf(2.5, rad * 0.28), true)
		Kind.PENDING:
			var rad := minf(size.x, size.y) * 0.5
			draw_circle(c, rad, PAPER)
			draw_arc(c, rad - 1.2, 0.0, TAU, 32, GREY, 2.5, true)
			_text(font, r, GREY.darkened(0.2), 0)
		Kind.CURRENT:
			var rad := minf(size.x, size.y) * 0.5
			draw_circle(c, rad, PLUM)
			draw_arc(c, rad - 1.0, 0.0, TAU, 32, CHARCOAL, 2.0, true)
			_text(font, r, Color.WHITE, 0)


func _text(font: Font, area: Rect2, color: Color, outline: int, fs: int = -1) -> void:
	if font == null or text == "":
		return
	var size_px := fs if fs > 0 else font_size
	var asc := font.get_ascent(size_px)
	var desc := font.get_descent(size_px)
	var pos := Vector2(area.position.x, area.position.y + (area.size.y + asc - desc) * 0.5)
	if outline > 0:
		draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, area.size.x, size_px, outline, CHARCOAL)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_CENTER, area.size.x, size_px, color)
