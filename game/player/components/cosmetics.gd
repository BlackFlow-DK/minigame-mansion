class_name CosmeticsComponent
extends PlayerComponent
## Applies `player.loadout` to the blob model shown by the `visuals` component, on every peer.
## Owner: cosmetics system.
##
## The model comes from `visuals.get_model_root() -> Node3D` (the instanced blob.glb). Until the
## visuals component offers that method (or while it returns null) this does nothing. It applies
## at spawn, whenever `player.loadout` changes (watched every frame, a cheap dictionary compare)
## and whenever visuals swaps its model. `refresh()` forces a re-apply right away.
##
## Look override (minigame hook, visual only): `set_look_override(look)` shows `look` (a loadout
## dictionary: colours and items; its `size` is ignored, see SizeComponent.size_override)
## instead of `player.loadout`, which stays untouched (it is replicated roster data); kept
## through model swaps; `clear_look_override()` puts the real loadout back. Per peer: a minigame
## sets it on every peer (from `_setup` / a call_local RPC). `shown_look()` is what is worn now.

## The look shown instead of `player.loadout`; empty = none. Set it through set_look_override.
var look_override: Dictionary = {}

var _root_id: int = 0
var _applied: Dictionary = {}
var _dirty: bool = true


func _ready() -> void:
	refresh()


func _process(_delta: float) -> void:
	if player == null:
		return
	var root := get_model_root()
	var root_id := root.get_instance_id() if root else 0
	if _dirty or root_id != _root_id or shown_look() != _applied:
		_apply(root)


## Re-applies the shown look now (the lobby calls this after changing `player.loadout`).
func refresh() -> void:
	_dirty = true
	if player != null:
		_apply(get_model_root())


## Shows `look` instead of the player's loadout from now on (empty = clear). Visual only.
func set_look_override(look: Dictionary) -> void:
	look_override = look.duplicate(true)
	refresh()


## Back to the player's own loadout.
func clear_look_override() -> void:
	set_look_override({})


func has_look_override() -> bool:
	return not look_override.is_empty()


## The look worn now: the override if set, else `player.loadout`.
func shown_look() -> Dictionary:
	if not look_override.is_empty():
		return look_override
	return player.loadout if player else {}


## The blob model under the visuals component, or null if there is none (yet).
func get_model_root() -> Node3D:
	if player == null:
		return null
	var visuals := player.get_component(&"visuals")
	if visuals == null or not visuals.has_method(&"get_model_root"):
		return null
	return visuals.call(&"get_model_root") as Node3D


func _apply(root: Node3D) -> void:
	_root_id = root.get_instance_id() if root else 0
	var look := shown_look()
	_applied = look.duplicate(true)
	_dirty = false
	if root == null:
		return
	# Looked up at runtime: this script is compiled by --script tools before autoloads exist.
	var cosmetics := get_node_or_null(^"/root/Cosmetics")
	if cosmetics != null:
		cosmetics.call(&"apply", root, look)
	# Tinted copies and fresh items are plain materials: give them the house toon look again
	# (idempotent and shared per material; untouched surfaces keep the toon from the visuals).
	BlobToon.apply(root)
