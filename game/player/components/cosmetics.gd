class_name CosmeticsComponent
extends PlayerComponent
## Applies `player.loadout` to the blob model shown by the `visuals` component, on every peer.
## Owner: cosmetics system.
##
## The model comes from `visuals.get_model_root() -> Node3D` (the instanced blob.glb). Until the
## visuals component offers that method (or while it returns null) this does nothing. It applies
## at spawn, whenever `player.loadout` changes (watched every frame, a cheap dictionary compare)
## and whenever visuals swaps its model. `refresh()` forces a re-apply right away.

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
	if _dirty or root_id != _root_id or player.loadout != _applied:
		_apply(root)


## Re-applies `player.loadout` now (the lobby calls this after changing it).
func refresh() -> void:
	_dirty = true
	if player != null:
		_apply(get_model_root())


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
	_applied = player.loadout.duplicate(true)
	_dirty = false
	if root == null:
		return
	# Looked up at runtime: this script is compiled by --script tools before autoloads exist.
	var cosmetics := get_node_or_null(^"/root/Cosmetics")
	if cosmetics != null:
		cosmetics.call(&"apply", root, player.loadout)
	# Tinted copies and fresh items are plain materials: give them the house toon look again
	# (idempotent and shared per material; untouched surfaces keep the toon from the visuals).
	BlobToon.apply(root)
