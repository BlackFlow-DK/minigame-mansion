class_name Mutators
extends RefCounted
## The mutator catalog and how one is put on / taken off players. Owner: modes.
##
## A mutator rides on the player's `size` component as the modifier `SOURCE`
## (`SizeComponent.set_modifier`), so it multiplies with the body size and with whatever a
## minigame set in `_setup` (the size component's base x factor bookkeeping), is 1 while the
## player is frozen, and `remove_from` restores every value exactly. Session applies it on every
## peer through one RPC (`Session.round_mutator`); the body scale shows on remote copies too.
## `mirror` swaps the `move_left` / `move_right` input events on this peer (humans only: bots
## never read the input map), restored by `set_mirror(false)`.

## Modifier name on the size component.
const SOURCE := &"mutator"

## Settings for how often a round gets a mutator (host choice, Session.mutator_mode).
enum Mode { OFF, SOMETIMES, ALWAYS }
const MODE_NAMES: Array[String] = ["Off", "Sometimes", "Always"]
## SOMETIMES: chance per round.
const SOMETIMES_CHANCE := 0.25

## Ids in display order.
const IDS: Array[StringName] = [&"low_gravity", &"giant", &"tiny", &"turbo", &"slippery", &"super_shove", &"heavy", &"mirror"]

## Low gravity: gravity x0.45 with a 1.6x higher jump (gravity = 2h / t^2, so t_apex grows by
## sqrt(1.6 / 0.45)).
const LOW_GRAVITY_TIME := 1.8856181

static var _catalog: Dictionary = {}
static var _mirrored: bool = false


## Every mutator, by id (built once).
static func catalog() -> Dictionary:
	if _catalog.is_empty():
		for m: Mutator in [
			Mutator.make(&"low_gravity", "Low gravity", "Low gravity!", Color("#7fb8ff"), {
				"jump:jump_height": 1.6, "jump:time_to_apex": LOW_GRAVITY_TIME,
				"jump:terminal_velocity": 0.7, "movement:air_accel": 1.3}),
			Mutator.make(&"giant", "Giant blobs", "Giant blobs!", Color("#e69f00"), {
				"shove:reach": 1.3, "shove:width": 1.3}, 1.35),
			Mutator.make(&"tiny", "Tiny blobs", "Tiny blobs!", Color("#cc79a7"), {
				"shove:reach": 0.8, "shove:width": 0.8}, 0.7),
			Mutator.make(&"turbo", "Turbo", "Turbo speed!", Color("#d9483b"), {
				"movement:max_speed": 1.35, "movement:ground_accel": 1.3, "movement:turn_accel": 1.3}),
			Mutator.make(&"slippery", "Slippery floor", "Slippery floor!", Color("#56b4e9"), {
				"movement:ground_accel": 0.22, "movement:ground_friction": 0.08, "movement:turn_accel": 0.15,
				"movement:overspeed_decel": 0.35, "movement:locked_friction": 0.4}),
			Mutator.make(&"super_shove", "Super shove", "Super shove!", Color("#e8b33a"), {
				"shove:force": 1.8, "shove:lift": 1.4}),
			Mutator.make(&"heavy", "Heavy blobs", "Heavy blobs!", Color("#8a8590"), {
				"jump:jump_height": 0.6, "status:knockback_multiplier": 0.6}),
			Mutator.make(&"mirror", "Mirror", "Mirror controls! Left is right!", Color("#009e73"), {}, 1.0, true),
		]:
			_catalog[m.id] = m
	return _catalog


## The mutator `id`, or null (also for &"").
static func get_mutator(id: StringName) -> Mutator:
	return catalog().get(id, null)


static func has(id: StringName) -> bool:
	return catalog().has(id)


## "Low gravity" for `id` ("" for none / unknown).
static func display_name(id: StringName) -> String:
	var m := get_mutator(id)
	return m.display_name if m else ""


## The title-card line after "MUTATOR: " ("Low gravity!"; "" for none).
static func card_line(id: StringName) -> String:
	var m := get_mutator(id)
	return m.card_line if m else ""


## The mutators a minigame with `blocklist` allows, in IDS order.
static func allowed(blocklist: Array = []) -> Array[StringName]:
	var out: Array[StringName] = []
	for id in IDS:
		if not blocklist.has(id) and not blocklist.has(String(id)):
			out.append(id)
	return out


## The `mutator_blocklist` of `minigame` (Array[StringName], optional var), [] without one.
static func blocklist_of(minigame: Object) -> Array:
	if minigame == null or not is_instance_valid(minigame):
		return []
	var v: Variant = minigame.get(&"mutator_blocklist")
	return v as Array if v is Array else []


## This round's mutator (&"" = none). `mode`: Mode. `forced` (a practice pick, `--mutator=`)
## wins over the mode when the minigame allows it. `avoid` (last round's) is skipped when
## another is allowed.
static func roll(mode: int, blocklist: Array, rng: RandomNumberGenerator, forced: StringName = &"",
		avoid: StringName = &"", chance: float = SOMETIMES_CHANCE) -> StringName:
	var pool := allowed(blocklist)
	if forced != &"":
		return forced if pool.has(forced) else &""
	if pool.is_empty():
		return &""
	match mode:
		Mode.OFF:
			return &""
		Mode.SOMETIMES:
			if rng.randf() >= chance:
				return &""
	if avoid != &"" and pool.size() > 1:
		pool.erase(avoid)
	return pool[rng.randi_range(0, pool.size() - 1)]


## Puts mutator `id` on `player` (replacing any other; &"" / unknown = remove).
static func apply_to(player: Player, id: StringName) -> void:
	var size := player.get_component(&"size") as SizeComponent if is_instance_valid(player) else null
	if size == null:
		return
	var m := get_mutator(id)
	if m == null:
		size.clear_modifier(SOURCE)
	else:
		size.set_modifier(SOURCE, m.stats, m.body_scale)


## Takes any mutator off `player` (values back to base x size factor).
static func remove_from(player: Player) -> void:
	apply_to(player, &"")


## True while a mutator is on `player`. Tests and smokes read it.
static func applied_to(player: Player) -> bool:
	var size := player.get_component(&"size") as SizeComponent if is_instance_valid(player) else null
	return size != null and size.has_modifier(SOURCE)


## Swaps (on) or restores (off) the `move_left` / `move_right` input events on this peer.
static func set_mirror(on: bool) -> void:
	if on == _mirrored:
		return
	if not InputMap.has_action(&"move_left") or not InputMap.has_action(&"move_right"):
		return
	var left := InputMap.action_get_events(&"move_left")
	var right := InputMap.action_get_events(&"move_right")
	InputMap.action_erase_events(&"move_left")
	InputMap.action_erase_events(&"move_right")
	for e in right:
		InputMap.action_add_event(&"move_left", e)
	for e in left:
		InputMap.action_add_event(&"move_right", e)
	_mirrored = on


static func is_mirrored() -> bool:
	return _mirrored
