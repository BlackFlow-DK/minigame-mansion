extends Node
## Autoload `Cosmetics`: the cosmetic catalog, colour palettes, the local profile and applying a
## loadout to a blob model. Owner: cosmetics system. Data lives in `catalog.gd`.
##
## Loadout: `{ "primary": "#rrggbb", "secondary": "#rrggbb", "hat": id, "face": id, "neck": id, "back": id,
## "size": "small" | "normal" | "big" }` ("" = nothing in that slot). Anything that arrives from the
## network goes through `sanitize()`. The size itself is applied by the `size` player component.
## Dev: user arg `--sizes=mixed` gives default loadouts a size by slot (normal, small, big, ...).

const CatalogData := preload("res://cosmetics/catalog.gd")
const Spinner := preload("res://cosmetics/spinner.gd")

## Item slots, in the order the wardrobe shows them.
const SLOTS: Array[StringName] = CatalogData.SLOTS
const PROFILE_PATH := "user://profile.json"
const NAME_MAX := 16
const DEFAULT_NAME := "Player"
const MODEL_DIR := "res://assets/models/cosmetics/"
## Name of the attached item node under its socket: "Cosmetic_hat" etc.
const ITEM_NODE_PREFIX := "Cosmetic_"
const META_ID := &"cosmetic_id"
const META_COLOURS := &"cosmetic_colours"
const MAT_PRIMARY := "PlayerPrimary"
const MAT_SECONDARY := "PlayerSecondary"

## Where the profile is saved. Tests point this elsewhere so they never touch the real profile.
var profile_path: String = PROFILE_PATH

## slot (StringName) -> Array of entries in catalog order (without the "None" entry).
var _by_slot: Dictionary = {}
## slot (StringName) -> { id (String) -> entry }.
var _index: Dictionary = {}
## Model path -> PackedScene (loaded on first use).
var _scenes: Dictionary = {}
## "<source material id>|<hex>" -> tinted copy, shared by every blob wearing that colour.
var _tinted: Dictionary = {}
## Warning keys already printed (warn once per bad id / colour).
var _warned: Dictionary = {}
## -1 not read yet, 0/1: the `--sizes=mixed` dev arg.
var _mixed_sizes: int = -1


func _init() -> void:
	for slot in SLOTS:
		_by_slot[slot] = []
		_index[slot] = {}
	for raw: Dictionary in CatalogData.ITEMS:
		var slot := StringName(raw["slot"])
		var entry := raw.duplicate(true)
		entry["slot"] = slot
		if not entry.has("model"):
			entry["model"] = "%s%s_%s.glb" % [MODEL_DIR, slot, raw["id"]]
		(_by_slot[slot] as Array).append(entry)
		(_index[slot] as Dictionary)[String(raw["id"])] = entry


# --- Catalog -------------------------------------------------------------------------------

## The choices for `slot` (&"hat", &"face", &"neck", &"back"), first the "None" choice (id "").
## Each entry: `{id, slot, name, model, offset, rotation, scale}` plus optional flags
## (`spin_child`, `spin_speed`). Copies: changing them does not change the catalog.
func catalog(slot: StringName) -> Array:
	if not _by_slot.has(slot):
		return []
	var out: Array = [{"id": "", "slot": slot, "name": "None", "model": "",
		"offset": Vector3.ZERO, "rotation": Vector3.ZERO, "scale": Vector3.ONE}]
	for entry: Dictionary in _by_slot[slot]:
		out.append(entry.duplicate(true))
	return out


## The catalog entry for `id` in `slot` (a copy), or {} if there is none.
func item(slot: StringName, id: String) -> Dictionary:
	var entry: Dictionary = (_index.get(slot, {}) as Dictionary).get(id, {})
	return entry.duplicate(true)


## True if `id` is "" or a catalog item of `slot`.
func is_valid_item(slot: StringName, id: String) -> bool:
	return id == "" or (_index.get(slot, {}) as Dictionary).has(id)


## The curated colours as "#rrggbb": `&"primary"` (16, body) or `&"secondary"` (12, belly,
## hands, feet). The first eight primaries are the defaults of slots 0..7.
func palette(kind: StringName) -> Array[String]:
	match kind:
		&"primary":
			return CatalogData.PRIMARY.duplicate()
		&"secondary":
			return CatalogData.SECONDARY.duplicate()
	return []


## The loadout a player in roster slot `slot_index` gets when they have not chosen one:
## a distinct colour pair and hat for each of the 8 slots, normal size (see `--sizes=mixed`).
func default_loadout(slot_index: int) -> Dictionary:
	var d: Array = CatalogData.DEFAULTS[posmod(slot_index, CatalogData.DEFAULTS.size())]
	return {
		"primary": CatalogData.PRIMARY[d[0]],
		"secondary": CatalogData.SECONDARY[d[1]],
		"hat": d[2], "face": "", "neck": "", "back": "",
		"size": _default_size(slot_index),
	}


## The body sizes in wardrobe order: `{id, name, blurb, scale, speed, jump, shove, reach, knockback}`
## (see catalog.gd). Copies.
func sizes() -> Array:
	var out: Array = []
	for entry: Dictionary in CatalogData.SIZES:
		out.append(entry.duplicate())
	return out


## The size entry for `id` (a copy); the normal size for anything unknown.
func size_info(id: Variant) -> Dictionary:
	return CatalogData.size_entry(id).duplicate()


## True if `id` is one of the size ids.
func is_valid_size(id: Variant) -> bool:
	for entry: Dictionary in CatalogData.SIZES:
		if entry["id"] == id:
			return true
	return false


## A clean loadout from anything (e.g. received over the network): exactly the seven keys,
## colours as lowercase "#rrggbb" (missing or bad ones replaced by `default_loadout(fallback_slot)`'s),
## item ids that are not in the catalog for their slot replaced by "", a size that is not a
## size id replaced by the fallback's. Not a Dictionary at all: `default_loadout(fallback_slot)`.
func sanitize(loadout: Variant, fallback_slot: int = 0) -> Dictionary:
	var fallback := default_loadout(fallback_slot)
	if not (loadout is Dictionary):
		return fallback
	var src: Dictionary = loadout
	var out := {}
	for key: String in ["primary", "secondary"]:
		var hex := _hex(src.get(key))
		out[key] = hex if hex != "" else fallback[key]
	for slot in SLOTS:
		var value: Variant = src.get(String(slot), "")
		var id: String = value if value is String else ""
		out[String(slot)] = id if is_valid_item(slot, id) else ""
	var size_id: Variant = src.get("size")
	out["size"] = size_id if size_id is String and is_valid_size(size_id) else fallback["size"]
	return out


## A display name: control characters removed, trimmed, at most 16 characters, never empty.
func sanitize_name(player_name: Variant) -> String:
	var raw: String = player_name if player_name is String else ""
	var clean := ""
	for i in raw.length():
		if raw.unicode_at(i) >= 32 and raw.unicode_at(i) != 127:
			clean += raw[i]
	clean = clean.strip_edges().left(NAME_MAX).strip_edges()
	return clean if clean != "" else DEFAULT_NAME


# --- Profile -------------------------------------------------------------------------------

## The saved local profile `{ "name": String, "loadout": Dictionary }`. A missing or corrupt
## file gives the default name and `default_loadout(0)`; the loadout is always sanitized.
func load_profile() -> Dictionary:
	var fallback := {"name": DEFAULT_NAME, "loadout": default_loadout(0)}
	if not FileAccess.file_exists(profile_path):
		return fallback
	var text := FileAccess.get_file_as_string(profile_path)
	var json := JSON.new()
	if text == "" or json.parse(text) != OK or not (json.data is Dictionary):
		_warn_once("profile:" + profile_path, "Cosmetics: profile %s is unreadable, using defaults" % profile_path)
		return fallback
	var data: Dictionary = json.data
	return {"name": sanitize_name(data.get("name", DEFAULT_NAME)), "loadout": sanitize(data.get("loadout", {}))}


## Saves the local profile (name sanitized, loadout sanitized). Returns OK or the file error.
func save_profile(player_name: String, loadout: Dictionary) -> Error:
	var data := {"version": 1, "name": sanitize_name(player_name), "loadout": sanitize(loadout)}
	var f := FileAccess.open(profile_path, FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		push_warning("Cosmetics: cannot write profile %s (%s)" % [profile_path, error_string(err)])
		return err
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return OK


# --- Applying a loadout ----------------------------------------------------------------------

## Dresses `model_root` (a blob.glb instance: sockets and parts as its children) in `loadout`.
## Tints PlayerPrimary / PlayerSecondary on this instance only (surface override materials,
## the imported materials are never changed) and puts each item under its socket with the
## catalog fit. Idempotent and cheap to repeat: only what changed since the last call is touched.
## Unknown item ids are skipped (slot left empty) and bad colours fall back to the imported
## colour, each with one warning.
func apply(model_root: Node3D, loadout: Dictionary) -> void:
	if model_root == null or not is_instance_valid(model_root):
		return
	var colours := {
		MAT_PRIMARY: _loadout_colour(loadout, "primary"),
		MAT_SECONDARY: _loadout_colour(loadout, "secondary"),
	}
	var key := [colours[MAT_PRIMARY], colours[MAT_SECONDARY]]
	if model_root.get_meta(META_COLOURS, []) != key:
		model_root.set_meta(META_COLOURS, key)
		_tint(model_root, colours)
	for slot in SLOTS:
		_apply_item(model_root, slot, loadout.get(String(slot), ""), colours)


## The item node currently worn in `slot` on `model_root`, or null.
func get_item_node(model_root: Node3D, slot: StringName) -> Node3D:
	var parent := _socket(model_root, slot)
	if parent == null:
		parent = model_root
	return parent.get_node_or_null(NodePath(ITEM_NODE_PREFIX + String(slot))) as Node3D


func _apply_item(model_root: Node3D, slot: StringName, value: Variant, colours: Dictionary) -> void:
	var id: String = value if value is String else ""
	var entry: Dictionary = (_index[slot] as Dictionary).get(id, {})
	if id != "" and entry.is_empty():
		_warn_once("id:%s:%s" % [slot, id], "Cosmetics: unknown %s '%s', skipped" % [slot, id])
		id = ""
	var socket := _socket(model_root, slot)
	var parent: Node3D = socket if socket != null else model_root
	var base := Transform3D.IDENTITY
	if socket == null:
		_warn_once("socket:%s" % slot, "Cosmetics: model has no %s, using its contract position" % CatalogData.SOCKETS[slot][0])
		base.origin = CatalogData.SOCKETS[slot][1]
	var node_name := ITEM_NODE_PREFIX + String(slot)
	var current := parent.get_node_or_null(NodePath(node_name)) as Node3D
	if current != null:
		if String(current.get_meta(META_ID, "")) == id:
			return
		parent.remove_child(current)
		current.queue_free()
	if id == "":
		return
	var scene := _scene(String(entry["model"]))
	var inst: Node3D = scene.instantiate() as Node3D if scene else null
	if inst == null:
		_warn_once("model:" + String(entry["model"]), "Cosmetics: cannot instance %s" % entry["model"])
		return
	inst.name = node_name
	inst.set_meta(META_ID, id)
	inst.transform = base * fit_transform(entry)
	var spin_name: String = entry.get("spin_child", "")
	if spin_name != "":
		var target := inst.find_child(spin_name, true, false) as Node3D
		if target:
			var spinner := Spinner.new()
			spinner.name = "Spinner"
			spinner.target = target
			spinner.speed = float(entry.get("spin_speed", 8.0))
			inst.add_child(spinner)
	parent.add_child(inst)
	_tint(inst, colours)


## The item's transform relative to its socket (catalog offset, rotation in degrees, scale).
func fit_transform(entry: Dictionary) -> Transform3D:
	var rot: Vector3 = entry.get("rotation", Vector3.ZERO)
	var scl: Vector3 = entry.get("scale", Vector3.ONE)
	var basis := Basis.from_euler(Vector3(deg_to_rad(rot.x), deg_to_rad(rot.y), deg_to_rad(rot.z))).scaled(scl)
	return Transform3D(basis, entry.get("offset", Vector3.ZERO))


func _socket(model_root: Node3D, slot: StringName) -> Node3D:
	return model_root.get_node_or_null(NodePath(String(CatalogData.SOCKETS[slot][0]))) as Node3D


func _scene(path: String) -> PackedScene:
	if _scenes.has(path):
		return _scenes[path]
	var scene: PackedScene = null
	if ResourceLoader.exists(path):
		scene = load(path) as PackedScene
	_scenes[path] = scene
	return scene


## "" (imported colour) when missing or bad; warns once for a bad non-empty value.
func _loadout_colour(loadout: Dictionary, key: String) -> String:
	var value: Variant = loadout.get(key, "")
	var hex := _hex(value)
	if hex == "" and not (value is String and value == ""):
		_warn_once("colour:%s" % str(value), "Cosmetics: bad %s colour '%s', ignored" % [key, value])
	return hex


## Sets the tint of every PlayerPrimary / PlayerSecondary surface under `root` (root included).
## `colours`: material name -> "#rrggbb", or "" to drop the override (imported colour).
func _tint(root: Node3D, colours: Dictionary) -> void:
	var meshes: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.append(root)
	for node in meshes:
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(i)
			if src == null or not colours.has(src.resource_name):
				continue
			var hex: String = colours[src.resource_name]
			mi.set_surface_override_material(i, _tinted_material(src, hex) if hex != "" else null)


func _tinted_material(src: Material, hex: String) -> Material:
	var key := "%d|%s" % [src.get_instance_id(), hex]
	var mat: Material = _tinted.get(key)
	if mat == null:
		mat = src.duplicate() as Material
		var base := mat as BaseMaterial3D
		if base:
			base.albedo_color = Color.html(hex)
		_tinted[key] = mat
	return mat


## Lowercase "#rrggbb" for a valid colour string (#rgb, #rrggbb, #rrggbbaa, with or without #)
## or a Color; "" otherwise.
func _hex(value: Variant) -> String:
	if value is Color:
		return "#" + (value as Color).to_html(false)
	if value is String and value != "" and Color.html_is_valid(value):
		return "#" + Color.html(value).to_html(false)
	return ""


## "normal", or with the dev user arg `--sizes=mixed` normal / small / big by slot.
func _default_size(slot_index: int) -> String:
	if _mixed_sizes == -1:
		_mixed_sizes = 1 if OS.get_cmdline_user_args().has("--sizes=mixed") else 0
	if _mixed_sizes == 1:
		return ["normal", "small", "big"][posmod(slot_index, 3)]
	return CatalogData.DEFAULT_SIZE


func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(message)
