class_name MasqDisguise
extends Node
## Masquerade's disguise, on every peer: every blob it holds shows the one shared MASQUERADE
## look (same colours, no items, the masq_mask on its FaceSocket, normal size) and no name tag,
## until it is released. Owner: masquerade minigame. Child of the minigame; when it leaves the
## tree (round over, stage cleared) it releases everyone itself, so no exit path leaks a look.
##
## Only public APIs, never `player.loadout` (replicated roster data):
## - Look: `Cosmetics.apply(model_root, LOOK)` + `BlobToon.apply` on the model root from
##   `VisualsComponent.get_model_root()`, exactly what the cosmetics component does with the
##   real loadout. The component only re-applies when `player.loadout` changes or the model is
##   swapped; this node checks every frame and re-dresses if anything put the real look back.
##   Release: `CosmeticsComponent.refresh()` re-applies the real loadout.
## - Size: SizeComponent scales the `visuals` node from `loadout.size` every frame (no override
##   hook exists), so this node runs after it (process_priority) and writes scale 1 back while
##   it holds the blob. Visual only; gameplay size factors are neutralised by the minigame.
## - Name tag: the player's `NameTag` child stops processing and hides (it re-shows itself
##   when released: its own _process sets `visible = player.alive`).
## - `flash(p, seconds)`: shows `p`'s true colours (not its items) for a while, then the
##   disguise again.

const MASK_SCENE: PackedScene = preload("res://assets/models/props/masq_mask.glb")
const MASK_NODE := "MasqMask"
## The one look everybody wears: ivory body, lilac accents (both off the wardrobe palette, so no
## real loadout ever equals it), no items, normal size.
const LOOK: Dictionary = {"primary": "#ece2cf", "secondary": "#b7a3d9", "hat": "", "face": "", "neck": "",
	"back": "", "size": "normal"}
const ITEM_SLOTS: Array[StringName] = [&"hat", &"face", &"neck", &"back"]
const META_COLOURS := &"cosmetic_colours"  # what Cosmetics.apply stamps on the model root

## Seconds between two full checks of one blob (staggered over the crowd; the scale of a
## small or big blob is fixed every frame).
const CHECK_EVERY := 0.25

## Blobs held now (players and extras).
var blobs: Array[Player] = []
## Player -> seconds of true colours left (see flash).
var _flash: Dictionary = {}
var _tags_hidden: Dictionary = {}  # Player -> NameTag node hidden by us
var _check_in: Dictionary = {}     # Player -> seconds until its next full check
var _resized: Dictionary = {}      # Player -> its visuals node, for blobs not of normal size
var _look_key: Array = []


func _init() -> void:
	name = "Disguise"
	# After every SizeComponent._process (priority 0), so our scale write is the one rendered.
	process_priority = 100
	_look_key = colour_key(LOOK)


## Puts `p` in the masquerade look (idempotent).
func hold(p: Player) -> void:
	if p == null or not is_instance_valid(p) or blobs.has(p):
		return
	blobs.append(p)
	_check_in[p] = CHECK_EVERY * float(blobs.size() % 8) / 8.0
	_dress(p)


## Gives `p` its own look back (idempotent).
func release(p: Player) -> void:
	if not is_instance_valid(p):
		return
	blobs.erase(p)
	_flash.erase(p)
	_check_in.erase(p)
	_resized.erase(p)
	if not is_instance_valid(p) or p.is_queued_for_deletion():
		_tags_hidden.erase(p)
		return
	var root := model_root(p)
	if root:
		var mask := _mask_of(root)
		if mask:
			mask.get_parent().remove_child(mask)
			mask.queue_free()
	var cosmetics := p.get_component(&"cosmetics")
	if cosmetics and cosmetics.has_method(&"refresh"):
		cosmetics.call(&"refresh")
	var tag: Node = _tags_hidden.get(p)
	_tags_hidden.erase(p)
	if tag and is_instance_valid(tag):
		tag.process_mode = Node.PROCESS_MODE_INHERIT
		(tag as Node3D).visible = p.alive


## Releases every held blob that is not an NPC extra (extras keep their mask: their real
## loadout is the disguise).
func release_players() -> void:
	for v: Variant in blobs.duplicate():
		if is_instance_valid(v) and not (v as Player).is_extra:
			release(v as Player)


func release_all() -> void:
	for v: Variant in blobs.duplicate():
		if is_instance_valid(v):
			release(v as Player)
	blobs.clear()


func holds(p: Player) -> bool:
	return blobs.has(p)


## Shows `p`'s true colours for `seconds` (still masked, no items), then the disguise again.
func flash(p: Player, seconds: float) -> void:
	if not blobs.has(p):
		return
	_flash[p] = seconds
	_dress(p)


func is_flashing(p: Player) -> bool:
	return _flash.has(p)


func _exit_tree() -> void:
	release_all()


func _process(delta: float) -> void:
	# Untyped: a blob freed under us (a leaver) must not be assigned to a typed variable.
	var gone: Array = []
	for v: Variant in blobs:
		if not is_instance_valid(v) or (v as Node).is_queued_for_deletion():
			gone.append(v)
			continue
		var p := v as Player
		var check := float(_check_in.get(p, 0.0)) - delta
		if _flash.has(p):
			_flash[p] = float(_flash[p]) - delta
			if float(_flash[p]) <= 0.0:
				_flash.erase(p)
				check = 0.0
		if check <= 0.0:
			check += CHECK_EVERY
			_dress(p)
		_check_in[p] = check
	# A small or big blob: SizeComponent writes its scale every frame; this runs after it.
	for v: Variant in _resized.values():
		if is_instance_valid(v) and (v as Node3D).scale != Vector3.ONE:
			(v as Node3D).scale = Vector3.ONE
	for v: Variant in gone:
		blobs.erase(v)
		_flash.erase(v)
		_check_in.erase(v)
		_resized.erase(v)
		_tags_hidden.erase(v)


## The colours `p` should show now: the disguise, or its own while flashing.
func _wanted(p: Player) -> Dictionary:
	if not _flash.has(p):
		return LOOK
	var look := LOOK.duplicate()
	look["primary"] = p.loadout.get("primary", LOOK["primary"])
	look["secondary"] = p.loadout.get("secondary", LOOK["secondary"])
	return look


func _wanted_key(p: Player) -> Array:
	return colour_key(_wanted(p)) if _flash.has(p) else _look_key


## Brings `p` to the wanted look; cheap when it already is.
func _dress(p: Player) -> void:
	var root := model_root(p)
	if root:
		if root.get_meta(META_COLOURS, []) != _wanted_key(p) or _wears_items(root):
			var cosmetics := get_node_or_null(^"/root/Cosmetics")
			if cosmetics:
				cosmetics.call(&"apply", root, _wanted(p))
			BlobToon.apply(root)
		if _mask_of(root) == null:
			var socket := root.get_node_or_null(^"FaceSocket") as Node3D
			var mask := MASK_SCENE.instantiate() as Node3D
			mask.name = MASK_NODE
			if socket:
				socket.add_child(mask)
			else:
				mask.position = Vector3(0.0, 0.68, 0.37)
				root.add_child(mask)
			BlobToon.apply(mask, false)  # thin shell: an outline hull would collapse anyway
	var visuals := p.get_component(&"visuals") as Node3D
	if visuals and visuals.scale != Vector3.ONE:
		visuals.scale = Vector3.ONE
		_resized[p] = visuals
	var tag := p.get_node_or_null(^"NameTag") as Node3D
	if tag and tag.process_mode != Node.PROCESS_MODE_DISABLED:
		tag.process_mode = Node.PROCESS_MODE_DISABLED
		tag.visible = false
		_tags_hidden[p] = tag


## The blob model of `p` (null before the visuals made it).
static func model_root(p: Player) -> Node3D:
	var visuals := p.get_component(&"visuals") if p else null
	if visuals == null or not visuals.has_method(&"get_model_root"):
		return null
	return visuals.call(&"get_model_root") as Node3D


## The colour stamp Cosmetics.apply leaves for `look` ([primary, secondary] as "#rrggbb").
static func colour_key(look: Dictionary) -> Array:
	return [_hex(look.get("primary", "")), _hex(look.get("secondary", ""))]


static func _hex(v: Variant) -> String:
	if v is String and v != "" and Color.html_is_valid(v):
		return "#" + Color.html(v).to_html(false)
	return ""


## Item node paths per slot (socket / item, as Cosmetics.apply names them).
const ITEM_PATHS: Array[NodePath] = [^"HatSocket/Cosmetic_hat", ^"FaceSocket/Cosmetic_face",
	^"NeckSocket/Cosmetic_neck", ^"BackSocket/Cosmetic_back"]


static func _wears_items(root: Node3D) -> bool:
	for path in ITEM_PATHS:
		if root.get_node_or_null(path) != null:
			return true
	return false


static func _mask_of(root: Node3D) -> Node3D:
	var socket := root.get_node_or_null(^"FaceSocket")
	var parent: Node = socket if socket else root
	return parent.get_node_or_null(NodePath(MASK_NODE)) as Node3D


## What a viewer can see of `p`'s look, for tests and the network check: the colour stamp, the
## worn item ids, whether it wears the mask, the shown scale, the albedo of every tinted
## surface of the Body and whether it shows a name tag.
static func fingerprint(p: Player) -> Dictionary:
	var root := model_root(p)
	var out := {"colours": [], "items": [], "mask": false, "scale": 0.0, "body": [], "tag": false}
	if root == null:
		return out
	out["colours"] = root.get_meta(META_COLOURS, [])
	var items: Array = []
	for slot in ITEM_SLOTS:
		var socket_name: String = {&"hat": "HatSocket", &"face": "FaceSocket", &"neck": "NeckSocket", &"back": "BackSocket"}[slot]
		var socket := root.get_node_or_null(NodePath(socket_name))
		var parent: Node = socket if socket else root
		var item := parent.get_node_or_null(NodePath("Cosmetic_" + String(slot)))
		if item:
			items.append("%s:%s" % [slot, item.get_meta(&"cosmetic_id", "?")])
	out["items"] = items
	out["mask"] = _mask_of(root) != null
	var visuals := p.get_component(&"visuals") as Node3D
	out["scale"] = snappedf(visuals.scale.x, 0.001) if visuals else 0.0
	var body := root.get_node_or_null(^"Body") as MeshInstance3D
	var cols: Array = []
	if body and body.mesh:
		for i in body.mesh.get_surface_count():
			var m := body.get_active_material(i) as BaseMaterial3D
			cols.append(m.albedo_color.to_html(false) if m else "")
	out["body"] = cols
	var tag := p.get_node_or_null(^"NameTag") as Node3D
	out["tag"] = tag != null and tag.is_visible_in_tree()
	return out
