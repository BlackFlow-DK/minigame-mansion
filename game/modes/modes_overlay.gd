class_name ModesOverlay
extends CanvasLayer
## The game modes' own screen layer (Session adds it as a child, on every peer): the vote cards
## during VOTE and a small "MUTATOR · LOW GRAVITY" badge (top right) while a round has a mutator.
## Driven by Session's signals only. Designed at 1280x720 and scaled to the window like the menus.
## Owner: modes.

## Above the menus (10) and the round UI (11).
const LAYER := 12

var root: Control
var vote_screen: VoteScreen
var badge: PanelContainer
var _badge_style: StyleBoxFlat
var _badge_label: Label


func _init() -> void:
	name = "ModesOverlay"
	layer = LAYER


func _ready() -> void:
	root = Control.new()
	root.name = "Root"
	root.theme = load(MenuUI.THEME_PATH) as Theme
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	vote_screen = VoteScreen.new()
	vote_screen.name = "Vote"
	root.add_child(vote_screen)
	_build_badge()
	get_viewport().size_changed.connect(_apply_scale)
	_apply_scale()
	Session.state_changed.connect(func(_s: int) -> void: _refresh())
	Session.vote_started.connect(func(_c: Array, _i: int) -> void:
		vote_screen.reset_cursor()
		_refresh()
		if vote_screen.visible:
			UiMotion.enter(vote_screen))
	Session.vote_updated.connect(_refresh)
	Session.vote_decided.connect(func(_w: int, _id: StringName) -> void: _refresh())
	Session.mutator_changed.connect(func(_id: StringName) -> void: _refresh())
	_refresh()


## Shows what Session holds now.
func _refresh() -> void:
	var voting := Session.state == Session.State.VOTE
	vote_screen.visible = voting
	if voting:
		vote_screen.refresh()
	var m := Mutators.get_mutator(Session.round_mutator)
	var show := m != null and (Session.state == Session.State.INTRO or Session.state == Session.State.PLAYING)
	if show:
		_badge_label.text = "MUTATOR · %s" % m.display_name.to_upper()
		_badge_style.bg_color = m.color
		var dark := m.color.get_luminance() > 0.6
		_badge_label.add_theme_color_override(&"font_color", RoundStyle.CHARCOAL if dark else RoundStyle.CREAM)
		_badge_label.add_theme_constant_override(&"outline_size", 0 if dark else 6)
	badge.visible = show


## The badge text ("" when hidden). Tests read it.
func badge_text() -> String:
	return _badge_label.text if badge.visible else ""


func _build_badge() -> void:
	_badge_style = RoundStyle.box(RoundStyle.TEAL, RoundStyle.CHARCOAL, 4, 14)
	_badge_style.set_content_margin_all(6.0)
	_badge_style.content_margin_left = 16.0
	_badge_style.content_margin_right = 16.0
	badge = RoundStyle.panel(_badge_style)
	badge.name = "MutatorBadge"
	badge.anchor_left = 1.0
	badge.anchor_right = 1.0
	badge.offset_top = 14.0
	badge.offset_right = -18.0
	badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_badge_label = RoundStyle.label("", 20, RoundStyle.CREAM, 6)
	badge.add_child(_badge_label)
	badge.visible = false
	root.add_child(badge)


func _apply_scale() -> void:
	var vs := get_viewport().get_visible_rect().size
	var s := clampf(minf(vs.x / MenuUI.DESIGN_SIZE.x, vs.y / MenuUI.DESIGN_SIZE.y), 0.5, 4.0)
	scale = Vector2(s, s)
	root.position = Vector2.ZERO
	root.size = vs / s
