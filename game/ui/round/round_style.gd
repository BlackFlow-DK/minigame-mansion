class_name RoundStyle
extends RefCounted
## Palette, theme and small node builders shared by the in-round UI. Owner: round UI.
## The shared theme (`res://ui/theme/mansion_theme.tres`, owned by another system) is used
## when it exists at runtime; otherwise a minimal local theme with the same palette.

const PLUM := Color("#6d4a7c")
const TEAL := Color("#2fa7a0")
const CREAM := Color("#f3e6c8")
const GOLD := Color("#e8b33a")
const RED := Color("#d9483b")
const CHARCOAL := Color("#2e2a33")
const GREY := Color("#8a8590")

const SHARED_THEME_PATH := "res://ui/theme/mansion_theme.tres"

## Used when a slot has no roster entry or no valid `primary` colour.
const _FALLBACK_COLOURS: Array[Color] = [
	Color("#e63946"), Color("#457b9d"), Color("#2a9d8f"), Color("#e9c46a"),
	Color("#9b5de5"), Color("#f4a261"), Color("#00bbf9"), Color("#8ac926"),
]

static var _theme: Theme = null


## The shared mansion theme if present, else a local fallback. Cached.
static func get_theme() -> Theme:
	if _theme == null:
		if ResourceLoader.exists(SHARED_THEME_PATH):
			_theme = load(SHARED_THEME_PATH) as Theme
		if _theme == null:
			_theme = _make_fallback_theme()
	return _theme


static func _make_fallback_theme() -> Theme:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Segoe UI Black", "Arial Rounded MT Bold", "Arial Black", "Segoe UI"])
	font.font_weight = 800
	t.default_font = font
	t.default_font_size = 24
	t.set_color(&"font_color", &"Label", CREAM)
	t.set_color(&"font_outline_color", &"Label", CHARCOAL)
	t.set_constant(&"outline_size", &"Label", 6)
	t.set_stylebox(&"normal", &"Button", box(GOLD, CHARCOAL, 4, 18))
	t.set_stylebox(&"hover", &"Button", box(GOLD.lightened(0.15), CHARCOAL, 4, 18))
	t.set_stylebox(&"pressed", &"Button", box(GOLD.darkened(0.15), CHARCOAL, 4, 18))
	t.set_stylebox(&"focus", &"Button", box(Color.TRANSPARENT, CREAM, 4, 18, false))
	t.set_color(&"font_color", &"Button", CHARCOAL)
	t.set_color(&"font_hover_color", &"Button", CHARCOAL)
	t.set_color(&"font_pressed_color", &"Button", CHARCOAL)
	t.set_color(&"font_focus_color", &"Button", CHARCOAL)
	return t


# --- Players -----------------------------------------------------------------------

## Slots to show: every roster slot, sorted; falls back to the slots in Session.scores.
static func roster_slots() -> Array[int]:
	var slots: Array[int] = []
	slots.assign(Net.roster.keys())
	if slots.is_empty():
		slots.assign(Session.scores.keys())
	slots.sort()
	return slots


static func player_color(slot: int) -> Color:
	if Net.roster.has(slot):
		var hex: Variant = Net.roster[slot].loadout.get("primary", "")
		if hex is String and Color.html_is_valid(hex):
			return Color.html(hex)
	return _FALLBACK_COLOURS[posmod(slot, _FALLBACK_COLOURS.size())]


static func player_name(slot: int) -> String:
	if Net.roster.has(slot) and Net.roster[slot].name != "":
		return Net.roster[slot].name
	return "Player %d" % (slot + 1)


static func total_score(slot: int) -> int:
	return int(Session.scores.get(slot, 0))


# --- Teams and ties ------------------------------------------------------------------

## The minigame of the running round (Session's, else the Stage's), or null.
static func current_minigame() -> Minigame:
	if is_instance_valid(Session.current_minigame):
		return Session.current_minigame
	var tree := Engine.get_main_loop() as SceneTree
	var stage := tree.get_first_node_in_group(&"stage") as Stage if tree else null
	return stage.minigame if stage and is_instance_valid(stage.minigame) else null


## slot -> team of the running round's minigame (empty without teams).
static func current_teams() -> Dictionary:
	var m := current_minigame()
	var out: Dictionary = {}
	if m and m.has_teams():
		for s: int in m.teams:
			out[s] = m.teams[s]
	return out


## The tied groups for a round `ranking`: Session.round_groups when they match it, else one
## slot per group.
static func groups_for(ranking: Array) -> Array:
	var groups: Array = Session.round_groups
	var flat := Minigame.flatten_groups(groups)
	var same := flat.size() == ranking.size()
	if same:
		for i in flat.size():
			if flat[i] != int(ranking[i]):
				same = false
				break
	if same:
		return groups
	var out: Array = []
	for s: Variant in ranking:
		out.append([int(s)] as Array[int])
	return out


## "TEAM ORANGE" etc.
static func team_title(team: int) -> String:
	return "TEAM %s" % Minigame.team_name(team)


static func ordinal(place: int) -> String:
	match place:
		1: return "1st"
		2: return "2nd"
		3: return "3rd"
	return "%dth" % place


## Colour of a placement badge (gold, cream, bronze-ish red, then plum).
static func place_color(place: int) -> Color:
	match place:
		1: return GOLD
		2: return CREAM
		3: return Color("#d98a4e")
	return PLUM.lightened(0.25)


# --- Builders -------------------------------------------------------------------------

static func label(text: String, font_size: int, color: Color = CREAM, outline: int = 8,
		outline_color: Color = CHARCOAL) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", font_size)
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_color_override(&"font_outline_color", outline_color)
	l.add_theme_constant_override(&"outline_size", outline)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func box(bg: Color, border: Color = Color.TRANSPARENT, border_width: int = 0,
		radius: int = 18, shadow: bool = true) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_width)
	s.set_corner_radius_all(radius)
	s.corner_detail = 8
	s.anti_aliasing = true
	s.set_content_margin_all(12.0)
	if shadow:
		s.shadow_color = Color(0, 0, 0, 0.35)
		s.shadow_offset = Vector2(0, 6)
		s.shadow_size = 2
	return s


static func panel(style: StyleBox) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override(&"panel", style)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## A full-rect CenterContainer that ignores the mouse.
static func centered() -> CenterContainer:
	var c := CenterContainer.new()
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func dim(alpha: float = 0.5, color: Color = CHARCOAL) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(color, alpha)
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## Makes every Control under `node` (and itself) mouse-transparent, except Buttons.
static func ignore_mouse(node: Node) -> void:
	var c := node as Control
	if c and not (c is BaseButton):
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		ignore_mouse(child)
