class_name MenuUI
extends RefCounted
## Small builders and focus helpers shared by the menu screens. Owner: menu UI.

const THEME_PATH := "res://ui/theme/mansion_theme.tres"
## Layout is designed for this size; MenuRoot scales it to the window.
const DESIGN_SIZE := Vector2(1280, 720)

const PLUM := Color("#6d4a7c")
const TEAL := Color("#2fa7a0")
const CREAM := Color("#f3e6c8")
const GOLD := Color("#e8b33a")
const RED := Color("#d9483b")
const CHARCOAL := Color("#2e2a33")


static func button(text: String, variation: StringName = &"", min_width: float = 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.theme_type_variation = variation
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(min_width, 0)
	return b


static func label(text: String, variation: StringName = &"", align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.horizontal_alignment = align
	return l


static func vbox(separation: int = -1) -> VBoxContainer:
	var v := VBoxContainer.new()
	if separation >= 0:
		v.add_theme_constant_override(&"separation", separation)
	return v


static func hbox(separation: int = -1) -> HBoxContainer:
	var h := HBoxContainer.new()
	if separation >= 0:
		h.add_theme_constant_override(&"separation", separation)
	return h


## Small rounded tag background ("BOT", "IN LOBBY") in `bg`.
static func chip_box(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = CHARCOAL
	s.set_border_width_all(2)
	s.set_corner_radius_all(10)
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 1
	s.content_margin_bottom = 1
	return s


static func full_rect(c: Control) -> Control:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c


## True if `c` can take keyboard/gamepad focus right now.
static func focusable(c: Control) -> bool:
	if c == null or not c.is_visible_in_tree() or c.focus_mode == Control.FOCUS_NONE:
		return false
	return not (c is BaseButton and (c as BaseButton).disabled)


## Links the usable controls of `order` top-to-bottom (up/down, tab/shift-tab), wrapping around.
## Hidden or disabled entries are skipped. Returns the linked controls.
static func chain_vertical(order: Array) -> Array[Control]:
	var live: Array[Control] = []
	for c: Variant in order:
		if c is Control and focusable(c as Control):
			live.append(c as Control)
	var n := live.size()
	for i in n:
		var c := live[i]
		var prev := live[(i - 1 + n) % n]
		var next := live[(i + 1) % n]
		c.focus_neighbor_top = c.get_path_to(prev)
		c.focus_neighbor_bottom = c.get_path_to(next)
		c.focus_previous = c.get_path_to(prev)
		c.focus_next = c.get_path_to(next)
	return live


## Links `row` left-to-right (wrapping); up/down of every entry go to `above`/`below` when given.
static func chain_horizontal(row: Array, above: Control = null, below: Control = null) -> void:
	var live: Array[Control] = []
	for c: Variant in row:
		if c is Control and focusable(c as Control):
			live.append(c as Control)
	var n := live.size()
	for i in n:
		var c := live[i]
		c.focus_neighbor_left = c.get_path_to(live[(i - 1 + n) % n])
		c.focus_neighbor_right = c.get_path_to(live[(i + 1) % n])
		if above:
			c.focus_neighbor_top = c.get_path_to(above)
		if below:
			c.focus_neighbor_bottom = c.get_path_to(below)


## Gives focus to the first usable control of `candidates`. Returns it (or null).
static func focus_first(candidates: Array) -> Control:
	for c: Variant in candidates:
		if c is Control and focusable(c as Control):
			(c as Control).grab_focus()
			return c as Control
	return null
