extends SceneTree
## Generates res://ui/theme/mansion_theme.tres, the shared UI theme (menu UI owns it).
## Re-run after editing, then commit the .tres:
##   godot_console --headless --path game --script res://ui/theme/make_theme.gd
##
## Look: chunky party game. Cream panels with thick charcoal outlines, fat rounded buttons
## with a hard drop "lip", plum focus ring, outlined text.
##
## Type variations (set `theme_type_variation` on a node):
##   Label:          TitleLabel, SubtitleLabel, HeaderLabel, LightLabel, MutedLabel, ErrorLabel, ChipLabel,
##                   ScrimLabel, ScrimHeader (cream on the dark lobby scrims)
##   Button:         PrimaryButton (gold), BigButton (large teal), SecondaryButton (small teal), SecondaryDangerButton,
##                   DangerButton (red), SmallButton, ChipButton (toggle), RowButton, CopyButton (scrim)
##   PanelContainer: RowPanel, ErrorPanel, ChipPanel, DarkPanel, ScrimRow
##   HSlider:        teal fill, gold grabber (settings volumes)
## Focus: every focusable type uses FocusRingStyle (focus_ring.gd): a gold ring with a charcoal
## rim, readable on cream, dark and plum alike.

const OUT := "res://ui/theme/mansion_theme.tres"

const PLUM := Color("#6d4a7c")
const TEAL := Color("#2fa7a0")
const CREAM := Color("#f3e6c8")
const GOLD := Color("#e8b33a")
const RED := Color("#d9483b")
const CHARCOAL := Color("#2e2a33")
const PAPER := Color("#fffaf0")
const MUTED := Color("#5e5263")
const DISABLED := Color("#a79ca8")
const FOCUS_RING := preload("res://ui/theme/focus_ring.gd")


func _initialize() -> void:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Segoe UI Black", "Segoe UI", "Arial Rounded MT Bold", "Arial"])
	font.font_weight = 900
	t.default_font = font
	t.default_font_size = 22

	_panels(t)
	_labels(t)
	_buttons(t)
	_line_edit(t)
	_slider(t)
	_misc(t)

	var err := ResourceSaver.save(t, OUT)
	if err != OK:
		printerr("make_theme: save failed: %s" % error_string(err))
		quit(1)
		return
	print("make_theme: wrote %s" % OUT)
	quit(0)


func _box(bg: Color, border: Color, border_w: int, radius: int, margin_h: float, margin_v: float, lip: float = 0.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(radius)
	s.corner_detail = 10
	s.anti_aliasing = true
	s.content_margin_left = margin_h
	s.content_margin_right = margin_h
	s.content_margin_top = margin_v
	s.content_margin_bottom = margin_v
	if lip > 0.0:
		s.shadow_color = CHARCOAL
		s.shadow_size = 1
		s.shadow_offset = Vector2(0, lip)
	return s


## The shared focus ring, sized for a control with corner `radius`.
func _focus(radius: int) -> StyleBox:
	var f: StyleBox = FOCUS_RING.new()
	f.set(&"radius", radius)
	return f


func _panels(t: Theme) -> void:
	var panel := _box(CREAM, CHARCOAL, 5, 24, 28, 22)
	panel.shadow_color = Color(CHARCOAL, 0.45)
	panel.shadow_size = 2
	panel.shadow_offset = Vector2(0, 10)
	t.set_stylebox(&"panel", &"PanelContainer", panel)
	t.set_stylebox(&"panel", &"Panel", panel)

	for v: StringName in [&"RowPanel", &"ErrorPanel", &"ChipPanel", &"DarkPanel", &"ScrimRow"]:
		t.set_type_variation(v, &"PanelContainer")
	t.set_stylebox(&"panel", &"RowPanel", _box(PAPER, CHARCOAL, 3, 14, 12, 6))
	t.set_stylebox(&"panel", &"ErrorPanel", _box(Color("#fbe0dc"), RED, 4, 14, 14, 8))
	t.set_stylebox(&"panel", &"ChipPanel", _box(TEAL, CHARCOAL, 2, 10, 8, 1))
	var dark := _box(PLUM, CHARCOAL, 5, 20, 20, 12, 6)
	t.set_stylebox(&"panel", &"DarkPanel", dark)
	t.set_stylebox(&"panel", &"ScrimRow", _box(Color(CHARCOAL, 0.62), Color(CREAM, 0.18), 2, 12, 10, 3))


func _labels(t: Theme) -> void:
	t.set_color(&"font_color", &"Label", CHARCOAL)
	t.set_color(&"font_outline_color", &"Label", CHARCOAL)
	t.set_color(&"font_shadow_color", &"Label", Color(0, 0, 0, 0))
	t.set_constant(&"outline_size", &"Label", 0)

	_label_variation(t, &"TitleLabel", 96, GOLD, 26, Vector2(0, 9))
	_label_variation(t, &"SubtitleLabel", 72, CREAM, 22, Vector2(0, 8))
	_label_variation(t, &"LightLabel", 24, CREAM, 9, Vector2.ZERO)
	_label_variation(t, &"HeaderLabel", 34, PLUM, 0, Vector2.ZERO)
	_label_variation(t, &"MutedLabel", 18, MUTED, 0, Vector2.ZERO)
	_label_variation(t, &"ErrorLabel", 20, Color("#a8281d"), 0, Vector2.ZERO)
	_label_variation(t, &"ChipLabel", 14, PAPER, 4, Vector2.ZERO)
	_label_variation(t, &"ScrimLabel", 19, CREAM, 6, Vector2.ZERO)
	_label_variation(t, &"ScrimHeader", 30, CREAM, 9, Vector2(0, 3))


func _label_variation(t: Theme, v: StringName, size: int, color: Color, outline: int, shadow: Vector2) -> void:
	t.set_type_variation(v, &"Label")
	t.set_font_size(&"font_size", v, size)
	t.set_color(&"font_color", v, color)
	t.set_constant(&"outline_size", v, outline)
	t.set_color(&"font_outline_color", v, CHARCOAL)
	if shadow != Vector2.ZERO:
		t.set_color(&"font_shadow_color", v, CHARCOAL)
		t.set_constant(&"shadow_offset_x", v, int(shadow.x))
		t.set_constant(&"shadow_offset_y", v, int(shadow.y))
		t.set_constant(&"shadow_outline_size", v, outline)


func _buttons(t: Theme) -> void:
	# Default: teal, cream text with a charcoal outline.
	_button_type(t, &"Button", TEAL, CREAM, 8, 26, 16, 22, 12, 4, 6)
	for v: StringName in [&"PrimaryButton", &"BigButton", &"SecondaryButton", &"SecondaryDangerButton", &"DangerButton", &"SmallButton",
			&"ChipButton", &"RowButton", &"CopyButton"]:
		t.set_type_variation(v, &"Button")
	_button_type(t, &"PrimaryButton", GOLD, CHARCOAL, 0, 30, 18, 26, 14, 5, 7)
	_button_type(t, &"BigButton", TEAL, CREAM, 9, 28, 18, 26, 13, 5, 7)
	_button_type(t, &"SecondaryButton", TEAL, CREAM, 7, 19, 14, 14, 7, 4, 5)
	_button_type(t, &"SecondaryDangerButton", RED, CREAM, 7, 19, 14, 14, 7, 4, 5)
	_button_type(t, &"CopyButton", Color(CHARCOAL, 0.45), CREAM, 7, 24, 12, 12, 4, 2, 0)
	for st: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed"]:
		var cb := t.get_stylebox(st, &"CopyButton") as StyleBoxFlat
		cb.border_color = Color(CREAM, 0.35 if st == &"normal" else 0.8)
		cb.bg_color = Color(CHARCOAL, 0.45) if st == &"normal" else Color(TEAL, 0.45)
	_button_type(t, &"DangerButton", RED, CREAM, 8, 26, 16, 22, 12, 4, 6)
	_button_type(t, &"SmallButton", RED, CREAM, 6, 18, 12, 12, 4, 3, 3)
	_button_type(t, &"RowButton", PAPER, CHARCOAL, 0, 22, 14, 16, 10, 3, 4)
	_button_type(t, &"ChipButton", PAPER, CHARCOAL, 0, 24, 14, 18, 8, 4, 4)
	# Chips are toggles: "pressed" means selected, so it is gold rather than pushed-in.
	var sel := _box(GOLD, CHARCOAL, 4, 14, 18, 8, 2)
	t.set_stylebox(&"pressed", &"ChipButton", sel)
	t.set_stylebox(&"hover_pressed", &"ChipButton", sel)
	t.set_color(&"font_pressed_color", &"ChipButton", CHARCOAL)
	t.set_color(&"font_hover_pressed_color", &"ChipButton", CHARCOAL)
	t.set_stylebox(&"hover", &"RowButton", _box(Color("#d9f0ed"), CHARCOAL, 3, 14, 16, 10, 4))


func _button_type(t: Theme, type: StringName, bg: Color, fg: Color, outline: int, font_size: int,
		radius: int, margin_h: float, margin_v: float, border: int, lip: float) -> void:
	var normal := _box(bg, CHARCOAL, border, radius, margin_h, margin_v, lip)
	var hover := _box(bg.lightened(0.18), CHARCOAL, border, radius, margin_h, margin_v, lip)
	var pressed := _box(bg.darkened(0.18), CHARCOAL, border, radius, margin_h, margin_v, maxf(1.0, lip * 0.3))
	var disabled := _box(DISABLED, Color(CHARCOAL, 0.55), border, radius, margin_h, margin_v, maxf(1.0, lip * 0.5))
	disabled.shadow_color = Color(CHARCOAL, 0.45)
	t.set_stylebox(&"normal", type, normal)
	t.set_stylebox(&"hover", type, hover)
	t.set_stylebox(&"pressed", type, pressed)
	t.set_stylebox(&"hover_pressed", type, pressed)
	t.set_stylebox(&"disabled", type, disabled)
	t.set_stylebox(&"focus", type, _focus(radius))
	t.set_font_size(&"font_size", type, font_size)
	for c: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_hover_pressed_color", &"font_focus_color"]:
		t.set_color(c, type, fg)
	t.set_color(&"font_disabled_color", type, Color(CREAM, 0.85) if outline > 0 else Color(CHARCOAL, 0.5))
	t.set_color(&"font_outline_color", type, CHARCOAL)
	t.set_constant(&"outline_size", type, outline)
	t.set_constant(&"h_separation", type, 10)


func _line_edit(t: Theme) -> void:
	t.set_stylebox(&"normal", &"LineEdit", _box(PAPER, CHARCOAL, 4, 14, 16, 10))
	t.set_stylebox(&"read_only", &"LineEdit", _box(CREAM, Color(CHARCOAL, 0.5), 4, 14, 16, 10))
	t.set_stylebox(&"focus", &"LineEdit", _focus(14))
	t.set_font_size(&"font_size", &"LineEdit", 24)
	t.set_color(&"font_color", &"LineEdit", CHARCOAL)
	t.set_color(&"font_placeholder_color", &"LineEdit", Color(PLUM, 0.55))
	t.set_color(&"caret_color", &"LineEdit", PLUM)
	t.set_color(&"selection_color", &"LineEdit", Color(TEAL, 0.4))
	t.set_color(&"font_selected_color", &"LineEdit", CHARCOAL)
	t.set_constant(&"caret_width", &"LineEdit", 3)


func _slider(t: Theme) -> void:
	var track := _box(Color(CHARCOAL, 0.22), CHARCOAL, 3, 10, 0, 7)
	var fill := _box(TEAL, CHARCOAL, 3, 10, 0, 7)
	t.set_stylebox(&"slider", &"HSlider", track)
	t.set_stylebox(&"grabber_area", &"HSlider", fill)
	t.set_stylebox(&"grabber_area_highlight", &"HSlider", _box(TEAL.lightened(0.15), CHARCOAL, 3, 10, 0, 7))
	t.set_stylebox(&"focus", &"HSlider", _focus(14))
	t.set_icon(&"grabber", &"HSlider", _knob(GOLD, 30))
	t.set_icon(&"grabber_highlight", &"HSlider", _knob(GOLD.lightened(0.25), 30))
	t.set_icon(&"grabber_disabled", &"HSlider", _knob(DISABLED, 30))
	t.set_icon(&"tick", &"HSlider", ImageTexture.create_from_image(Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)))
	t.set_constant(&"center_grabber", &"HSlider", 0)
	t.set_constant(&"grabber_offset", &"HSlider", 0)


## A round slider knob: `fill` with a charcoal rim, antialiased.
func _knob(fill: Color, px: int) -> ImageTexture:
	var img := Image.create_empty(px, px, false, Image.FORMAT_RGBA8)
	var c := Vector2(px, px) * 0.5
	var r := px * 0.5 - 0.5
	for y in px:
		for x in px:
			var d := (Vector2(x, y) + Vector2(0.5, 0.5)).distance_to(c)
			var a := clampf(r - d + 0.5, 0.0, 1.0)
			if a <= 0.0:
				continue
			var col := CHARCOAL if d > r - 3.5 else fill
			if d <= r - 3.5 and d > r - 4.5:
				col = CHARCOAL.lerp(fill, clampf(r - 3.5 - d + 1.0, 0.0, 1.0))
			img.set_pixel(x, y, Color(col, a))
	return ImageTexture.create_from_image(img)


func _misc(t: Theme) -> void:
	t.set_constant(&"separation", &"VBoxContainer", 14)
	t.set_constant(&"separation", &"HBoxContainer", 12)
	t.set_stylebox(&"panel", &"ScrollContainer", StyleBoxEmpty.new())

	var track := _box(Color(CHARCOAL, 0.12), Color(0, 0, 0, 0), 0, 8, 5, 5)
	var grab := _box(PLUM, Color(0, 0, 0, 0), 0, 8, 5, 5)
	t.set_stylebox(&"scroll", &"VScrollBar", track)
	t.set_stylebox(&"grabber", &"VScrollBar", grab)
	t.set_stylebox(&"grabber_highlight", &"VScrollBar", _box(PLUM.lightened(0.2), Color(0, 0, 0, 0), 0, 8, 5, 5))
	t.set_stylebox(&"grabber_pressed", &"VScrollBar", _box(PLUM.darkened(0.2), Color(0, 0, 0, 0), 0, 8, 5, 5))

	var sep := StyleBoxLine.new()
	sep.color = Color(CHARCOAL, 0.25)
	sep.thickness = 3
	t.set_stylebox(&"separator", &"HSeparator", sep)
	t.set_constant(&"separation", &"HSeparator", 10)

	t.set_stylebox(&"panel", &"TooltipPanel", _box(CHARCOAL, CHARCOAL, 0, 10, 12, 8))
	t.set_color(&"font_color", &"TooltipLabel", CREAM)
	t.set_font_size(&"font_size", &"TooltipLabel", 18)
