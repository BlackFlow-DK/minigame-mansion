extends Node
## Autoload `Cosmetics`: the cosmetic catalog, local profile and applying loadouts to a model.
## Owner: cosmetics system.
## Stub: empty catalog; default loadouts are distinct colours with no items.

## Placeholder palette (primary colour per slot index).
const _STUB_COLOURS: Array[String] = ["#e63946", "#457b9d", "#2a9d8f", "#e9c46a", "#9b5de5", "#f4a261", "#00bbf9", "#8ac926"]


## Item ids available in `slot` (`&"hat"`, `&"face"`, `&"neck"`, `&"back"`).
func catalog(_slot: StringName) -> Array:
	return []


## The loadout a player in roster slot `slot_index` gets when they have not chosen one.
func default_loadout(slot_index: int) -> Dictionary:
	return {
		"primary": _STUB_COLOURS[posmod(slot_index, _STUB_COLOURS.size())],
		"secondary": "#f1faee",
		"hat": "", "face": "", "neck": "", "back": "",
	}


## The saved local profile: `{ "name": String, "loadout": Dictionary }`.
func load_profile() -> Dictionary:
	return {"name": "Player", "loadout": default_loadout(0)}


func save_profile(_player_name: String, _loadout: Dictionary) -> void:
	pass


## Recolours `model_root` (a blob.glb instance) and attaches the loadout's items to its sockets.
func apply(_model_root: Node3D, _loadout: Dictionary) -> void:
	pass
