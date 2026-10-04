extends CanvasLayer
## Blob Ball's scoreboard banner, top centre: [ORANGE  2] [ 1:07 ] [1  BLUE], in the shared
## mansion theme. Pure presentation: the minigame calls `set_score` / `set_time` on every peer.

const THEME_PATH := "res://ui/theme/mansion_theme.tres"
const CHARCOAL := Color("#2e2a33")
const CREAM := Color("#f3e6c8")
const GOLD := Color("#e8b33a")

var _scores: Array[Label] = []
var _names: Array[Label] = []
var _boxes: Array[PanelContainer] = []
var _clock: Label
var _sub: Label
var _last_text: String = ""
var _hot: bool = false


func _ready() -> void:
	layer = 2
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(THEME_PATH):
		root.theme = load(THEME_PATH) as Theme
	add_child(root)
	var row := HBoxContainer.new()
	row.name = "Row"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	row.offset_top = 14.0
	row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	row.add_theme_constant_override(&"separation", -6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(row)
	for t in 2:
		_boxes.append(_team_box(t))
	row.add_child(_boxes[0])
	row.add_child(_clock_box())
	row.add_child(_boxes[1])
	set_teams(Minigame.team_color(0), Minigame.team_color(1), Minigame.team_name(0), Minigame.team_name(1))


func set_teams(c0: Color, c1: Color, n0: String, n1: String) -> void:
	var cols := [c0, c1]
	var names := [n0, n1]
	for t in 2:
		var sb := StyleBoxFlat.new()
		sb.bg_color = cols[t]
		sb.border_color = CHARCOAL
		sb.set_border_width_all(5)
		sb.set_corner_radius_all(20)
		if t == 0:
			sb.corner_radius_top_right = 0
			sb.corner_radius_bottom_right = 0
		else:
			sb.corner_radius_top_left = 0
			sb.corner_radius_bottom_left = 0
		sb.content_margin_left = 22.0
		sb.content_margin_right = 22.0
		sb.content_margin_top = 4.0
		sb.content_margin_bottom = 4.0
		sb.shadow_color = Color(0, 0, 0, 0.25)
		sb.shadow_size = 6
		sb.shadow_offset = Vector2(0, 4)
		_boxes[t].add_theme_stylebox_override(&"panel", sb)
		_names[t].text = names[t]


func set_score(s0: int, s1: int) -> void:
	_scores[0].text = str(s0)
	_scores[1].text = str(s1)


## `seconds` left on the clock; `golden` shows the golden-goal line instead.
func set_time(seconds: float, golden: bool) -> void:
	var s := maxi(0, ceili(seconds - 0.001))
	var text := "%d:%02d" % [s / 60, s % 60]
	if text != _last_text:
		_last_text = text
		_clock.text = text
	_sub.visible = golden
	var hot := golden or s <= 10
	if hot != _hot:
		_hot = hot
		_clock.add_theme_color_override(&"font_color", GOLD if hot else CREAM)


func score_text(t: int) -> String:
	return _scores[t].text


func _team_box(t: int) -> PanelContainer:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override(&"separation", 14)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(h)
	var name_label := _label("", 24, CREAM, 6)
	name_label.custom_minimum_size = Vector2(92, 0)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var score := _label("0", 50, Color.WHITE, 10)
	score.custom_minimum_size = Vector2(40, 0)
	score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if t == 0:
		h.add_child(name_label)
		h.add_child(score)
	else:
		h.add_child(score)
		h.add_child(name_label)
	_names.append(name_label)
	_scores.append(score)
	return box


func _clock_box() -> PanelContainer:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.z_index = 1
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(CHARCOAL, 0.96)
	sb.border_color = CREAM
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(16)
	sb.content_margin_left = 20.0
	sb.content_margin_right = 20.0
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 4.0
	box.add_theme_stylebox_override(&"panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", -8)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(v)
	_clock = _label("1:30", 44, CREAM, 8)
	_clock.custom_minimum_size = Vector2(118, 0)
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_clock)
	_sub = _label("GOLDEN GOAL", 16, GOLD, 4)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.visible = false
	v.add_child(_sub)
	return box


func _label(text: String, size: int, color: Color, outline: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", size)
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_color_override(&"font_outline_color", CHARCOAL)
	l.add_theme_constant_override(&"outline_size", outline)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
