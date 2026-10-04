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
## Order: loadout size -> override -> anything else that scales on top of what this writes
## (it treats values it did not write as new bases).

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
	var entry := CatalogData.size_entry(id)
	if entry["id"] == size_id and _capsule_scale == body_scale:
		return
	size_id = entry["id"]
	_entry = entry
	body_scale = float(entry["scale"])
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
	var visuals := player.get_component(&"visuals")
	if visuals:
		var s := Vector3.ONE * shown_scale
		if visuals.scale != s:
			visuals.scale = s
	var fx := player.get_component(&"fx")
	if fx and &"head_height" in fx:
		_sync(fx, &"head_height", "fx:head_height", body_scale)
	var tag := player.get_node_or_null(^"NameTag")
	if tag and &"height" in tag:
		_sync(tag, &"height", "NameTag:height", body_scale)


func _sync_stats() -> void:
	for stat: Array in STATS:
		var c := player.get_component(stat[0])
		if c:
			_sync(c, stat[1], stat[3], factor(stat[2]))


## Writes `base * f` to `obj.property`; a value this component did not write is the new base.
func _sync(obj: Object, property: StringName, key: String, f: float) -> void:
	var v: float = obj.get(property)
	if not _written.has(key) or v != float(_written[key]):
		_base[key] = v
	var want: float = float(_base[key]) * f
	if v != want:
		obj.set(property, want)
	_written[key] = want
