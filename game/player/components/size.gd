class_name SizeComponent
extends PlayerComponent
## Body size from the replicated `player.loadout["size"]` (small / normal / big), on every peer.
## Owner: cosmetics system. Numbers: `SIZES` in res://cosmetics/catalog.gd.
##
## Looks: scales the `visuals` component node, the parent of the blob model, so the visuals'
## own squash-and-stretch on the model root, the hats and the worn items all follow; the
## collision capsule (radius, height, centre); the NameTag height; the fx head height.
## Remote copies read the same loadout, so they show the size from their first frame and
## follow a lobby change.
##
## Gameplay: multiplies other components' exported tuning (STATS) by the size's factors,
## without losing the base value a minigame set. Per value it remembers what it wrote last;
## a value it did not write (a minigame's `_setup`, or a per-frame retune like Hot Potato's
## speed) becomes the new base, and it writes `base * factor` back. While the player is
## `frozen` every factor is 1 (bases restored), so `_setup` and `_start` always read and write
## base values. It is ticked first on the authority (so a retune made earlier in the frame is
## scaled before movement/shove use it); remote copies do it in `_process`.
## Rule for minigames: set tuning to absolute values (from what you read in `_setup`/`_start`),
## never `*=` mid-round, or the size factor compounds.
##
## Size override (minigame hook): `set_size_override(id)` makes this blob that size for looks,
## capsule AND tuning factors, whatever its loadout says (`player.loadout` stays untouched);
## `clear_size_override()` goes back to the loadout size. Per peer: set it on every peer.
##
## Modifiers (game modes' mutators, `set_modifier`): extra multipliers that compose with the
## size through the same bookkeeping, so a mutator, the size and a minigame's `_setup` tuning
## multiply instead of fighting: value = base * size factor * every modifier's factor. A
## modifier may scale any float property of any component ("jump:time_to_apex"), not only
## STATS, and the body (`scale`: looks and capsule). Like the size factors, stat multipliers
## are 1 while `frozen`; the body scale is not. `clear_modifier` restores the base exactly.
##
## Order: loadout size -> size override (replaces the loadout size while set) -> modifiers
## (multiply on top, override or not). Body scale = size scale * modifier scales; a stat =
## base * size factor * modifier factors. Any set / clear order restores exactly.

const CatalogData := preload("res://cosmetics/catalog.gd")

## Gameplay tuning scaled by the size: [component, property, factor key in CatalogData.SIZES,
## bookkeeping key].
const STATS: Array[Array] = [
	[&"movement", &"max_speed", "speed", "movement:max_speed"],
	[&"jump", &"jump_height", "jump", "jump:jump_height"],
	[&"shove", &"force", "shove", "shove:force"],
	[&"shove", &"reach", "reach", "shove:reach"],
	[&"shove", &"width", "reach", "shove:width"],
	[&"status", &"knockback_multiplier", "knockback", "status:knockback_multiplier"],
]
## Factors given in felt push distance (applied as their square root to the impulse).
const CURVED: Array[String] = ["shove", "knockback"]
## How fast the shown scale follows a size change (1/s, exponential). Spawn snaps.
const SCALE_SHARPNESS := 16.0

## The size id in effect ("small", "normal", "big").
var size_id: String = CatalogData.DEFAULT_SIZE
## The size's body scale (the collision capsule uses it at once).
var body_scale: float = 1.0
## The scale the model shows now (eases toward `body_scale`).
var shown_scale: float = 1.0
## Size id forced on this blob ("" = none, the loadout decides). Set it through set_size_override.
var size_override: String = ""

var _entry: Dictionary = CatalogData.size_entry(CatalogData.DEFAULT_SIZE)
var _base: Dictionary = {}     # "<node>:<property>" -> base value
var _written: Dictionary = {}  # "<node>:<property>" -> value this component wrote last
var _shape_node: CollisionShape3D = null
var _capsule: CapsuleShape3D = null
var _capsule_base := Vector3(0.4, 1.0, 0.5)  # radius, height, centre y at scale 1
var _capsule_scale: float = 1.0
## source -> {"stats": {"<component>:<property>": multiplier}, "scale": float}
var _modifiers: Dictionary = {}
## Every "<component>:<property>" a modifier ever touched that is not in STATS (kept in sync
## after the modifier goes, so its base comes back).
var _extra_keys: Dictionary = {}
## Hot path (`_sync_stats` runs every tick for every blob): per STATS row the component, the
## factor in effect and the base / last written value (NAN = never written), mirrored into
## `_base` / `_written`. The factors are recomputed only when the size entry, `frozen` or the
## modifiers change (`_mods_version`), not per tick.
var _stat_nodes: Array[PlayerComponent] = []
var _stat_f := PackedFloat64Array()
var _stat_base := PackedFloat64Array()
var _stat_written := PackedFloat64Array()
var _f_entry: Dictionary = {}
var _f_frozen: bool = false
var _f_mods: int = -1
var _mods_version: int = 0
## `_read_loadout` input it last resolved: [size id, modifiers version] -> entry, scale.
var _rl_id: Variant = null
var _rl_mods: int = -1
var _rl_entry: Dictionary = {}
var _rl_scale: float = 1.0
## `_apply_looks` (every frame): the visuals and fx components, looked up once.
var _looks_cached: bool = false
var _visuals: PlayerComponent = null
var _fx: PlayerComponent = null


func _ready() -> void:
	if player == null:
		return
	_shape_node = player.get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	var original := _shape_node.shape as CapsuleShape3D if _shape_node else null
	if original:
		_capsule_base = Vector3(original.radius, original.height, _shape_node.position.y)
	_read_loadout()
	shown_scale = body_scale
	_apply_looks()
	_sync_stats()


## The multiplier written for `key` ("speed", "jump", "shove", "reach", "knockback") now:
## 1 while frozen.
func factor(key: String) -> float:
	if player == null or player.frozen:
		return 1.0
	return effective(_entry, key)


## The tuning multiplier for `key` of a SIZES entry. `shove` and `knockback` are given as how
## far a push carries (a slide grows with the square of the push speed), so the impulse gets
## their square root: 1.2 means a 20% longer slide, not 44%.
static func effective(entry: Dictionary, key: String) -> float:
	var f := float(entry.get(key, 1.0))
	return sqrt(f) if CURVED.has(key) else f


## Adds (or replaces) the modifier `source`: `stats` maps "<component>:<property>" to a
## multiplier, `body_scale_factor` scales the body. Call it on every peer (looks) and on the
## authority (stats); Session does both through its mutator RPC.
func set_modifier(source: StringName, stats: Dictionary, body_scale_factor: float = 1.0) -> void:
	var clean: Dictionary = {}
	for key: Variant in stats:
		clean[str(key)] = float(stats[key])
		if not _is_size_stat(str(key)):
			_extra_keys[str(key)] = true
	_modifiers[source] = {"stats": clean, "scale": body_scale_factor}
	_mods_version += 1
	if player:
		_read_loadout()
		_sync_stats()


## Removes the modifier `source` (no-op if absent); its stats return to base * size factor.
func clear_modifier(source: StringName) -> void:
	if not _modifiers.has(source):
		return
	_modifiers.erase(source)
	_mods_version += 1
	if player:
		_read_loadout()
		_sync_stats()


func has_modifier(source: StringName) -> bool:
	return _modifiers.has(source)


## Product of every modifier's multiplier for `key` ("<component>:<property>"): 1 while frozen.
func modifier_factor(key: String) -> float:
	if player == null or player.frozen:
		return 1.0
	var f := 1.0
	for m: Dictionary in _modifiers.values():
		f *= float((m["stats"] as Dictionary).get(key, 1.0))
	return f


## Product of every modifier's body scale.
func modifier_scale() -> float:
	var f := 1.0
	for m: Dictionary in _modifiers.values():
		f *= float(m["scale"])
	return f


## The base value (before the size factor) of `component_name`'s `property`, e.g.
## `base_of(&"movement", &"max_speed")`. The current value if it is not a scaled stat.
func base_of(component_name: StringName, property: StringName) -> float:
	var key := "%s:%s" % [component_name, property]
	if _base.has(key):
		return _base[key]
	var c := player.get_component(component_name) if player else null
	return float(c.get(property)) if c else 0.0


## Forces size `id` ("small" / "normal" / "big"; "" clears) for looks, capsule and tuning.
## `snap`: the model jumps to the new scale instead of easing there.
func set_size_override(id: String, snap: bool = false) -> void:
	size_override = id
	if player == null or not is_node_ready():
		return  # _ready reads it
	_read_loadout()
	_sync_stats()
	if snap:
		shown_scale = body_scale
	_apply_looks()


## Back to the loadout size (`snap` as in set_size_override).
func clear_size_override(snap: bool = false) -> void:
	set_size_override("", snap)


func physics_tick(_delta: float) -> void:
	_read_loadout()
	_sync_stats()


func _process(delta: float) -> void:
	if player == null:
		return
	_read_loadout()
	shown_scale = lerpf(shown_scale, body_scale, 1.0 - exp(-SCALE_SHARPNESS * minf(delta, 0.1)))
	if absf(shown_scale - body_scale) < 0.001:
		shown_scale = body_scale
	_apply_looks()
	if not player.is_authority():
		_sync_stats()  # the authority does it in physics_tick


func _read_loadout() -> void:
	var id: Variant = size_override if size_override != "" else player.loadout.get("size", CatalogData.DEFAULT_SIZE)
	if _rl_mods != _mods_version or typeof(id) != typeof(_rl_id) or id != _rl_id:
		_rl_id = id
		_rl_mods = _mods_version
		_rl_entry = CatalogData.size_entry(id)
		_rl_scale = float(_rl_entry["scale"]) * modifier_scale()
	var entry := _rl_entry
	var want := _rl_scale
	if entry["id"] == size_id and _capsule_scale == want and body_scale == want:
		return
	size_id = entry["id"]
	_entry = entry
	body_scale = want
	_apply_capsule()


## Capsule: its own shape (the scene's is shared by every player), feet stay at y = 0.
func _apply_capsule() -> void:
	_capsule_scale = body_scale
	if _shape_node == null:
		return
	if _capsule == null:
		if is_equal_approx(body_scale, 1.0):
			return
		_capsule = CapsuleShape3D.new()
		_shape_node.shape = _capsule
	_capsule.radius = _capsule_base.x * body_scale
	_capsule.height = _capsule_base.y * body_scale
	_shape_node.position.y = _capsule_base.z * body_scale


func _apply_looks() -> void:
	if not _looks_cached:
		_looks_cached = true
		_visuals = player.get_component(&"visuals")
		var fx := player.get_component(&"fx")
		_fx = fx if fx and &"head_height" in fx else null
	if _visuals:
		var s := Vector3.ONE * shown_scale
		if _visuals.scale != s:
			_visuals.scale = s
	if _fx:
		_sync(_fx, &"head_height", "fx:head_height", body_scale)
	var tag := player.get_node_or_null(^"NameTag")
	if tag and &"height" in tag:
		_sync(tag, &"height", "NameTag:height", body_scale)


## `_sync` for every STATS row (same rule, see `_sync`), without per-tick lookups.
func _sync_stats() -> void:
	var n := STATS.size()
	if _stat_nodes.size() != n:
		_stat_nodes.clear()
		for stat: Array in STATS:
			_stat_nodes.append(player.get_component(stat[0]))
		_stat_f.resize(n)
		_stat_base.resize(n)
		_stat_written.resize(n)
		_stat_written.fill(NAN)
		_f_mods = -1
	if _f_mods != _mods_version or _f_frozen != player.frozen or not is_same(_f_entry, _entry):
		_f_mods = _mods_version
		_f_frozen = player.frozen
		_f_entry = _entry
		for i in n:
			_stat_f[i] = factor(STATS[i][2]) * modifier_factor(STATS[i][3])
	for i in n:
		var c := _stat_nodes[i]
		if c == null:
			continue
		var property: StringName = STATS[i][1]
		var v: float = c.get(property)
		if v != _stat_written[i]:  # NAN (never written) differs from everything
			_stat_base[i] = v
			_base[STATS[i][3]] = v
		var want := _stat_base[i] * _stat_f[i]
		if v != want:
			c.set(property, want)
		if want != _stat_written[i]:
			_stat_written[i] = want
			_written[STATS[i][3]] = want
	for key: String in _extra_keys:
		var parts := key.split(":", true, 1)
		var c := player.get_component(StringName(parts[0])) if parts.size() == 2 else null
		if c and StringName(parts[1]) in c:
			_sync(c, StringName(parts[1]), key, modifier_factor(key))


static func _is_size_stat(key: String) -> bool:
	for stat: Array in STATS:
		if stat[3] == key:
			return true
	return false


## Writes `base * f` to `obj.property`; a value this component did not write is the new base.
func _sync(obj: Object, property: StringName, key: String, f: float) -> void:
	var v: float = obj.get(property)
	if not _written.has(key) or v != float(_written[key]):
		_base[key] = v
	var want: float = float(_base[key]) * f
	if v != want:
		obj.set(property, want)
	_written[key] = want
