class_name Mutator
extends Resource
## One per-round twist (game modes, owner: modes). Pure data: the catalog is `Mutators.CATALOG`;
## `Mutators.apply_to` puts it on a player (through the size component's modifiers, so it
## composes with body size and a minigame's `_setup` tuning and comes off exactly).

@export var id: StringName = &""
## Short name ("Low gravity").
@export var display_name: String = ""
## The title-card line ("Low gravity!").
@export var card_line: String = ""
## "<component>:<property>" -> multiplier, e.g. {"movement:max_speed": 1.35}.
@export var stats: Dictionary = {}
## Body scale multiplier (looks and collision capsule).
@export var body_scale: float = 1.0
## Left/right swapped for humans (this peer's input map; bots are unaffected).
@export var mirror: bool = false
## Badge / sticker colour.
@export var color: Color = Color("#2fa7a0")


static func make(p_id: StringName, p_name: String, p_line: String, p_color: Color, p_stats: Dictionary = {},
		p_scale: float = 1.0, p_mirror: bool = false) -> Mutator:
	var m := Mutator.new()
	m.id = p_id
	m.display_name = p_name
	m.card_line = p_line
	m.color = p_color
	m.stats = p_stats
	m.body_scale = p_scale
	m.mirror = p_mirror
	return m
