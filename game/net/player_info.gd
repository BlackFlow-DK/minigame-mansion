class_name PlayerInfo
extends RefCounted
## One roster entry in `Net.roster`. Owner: net.

## Stable identity for the whole session, 0..7.
var slot: int = -1
## Multiplayer peer that simulates this player: its owner, or the host (1) for bots. 1 offline.
var peer_id: int = 1
var name: String = ""
var is_bot: bool = false
## See docs/contract.md, "Character model and cosmetics".
var loadout: Dictionary = {}


func _init(p_slot: int = -1, p_peer_id: int = 1, p_name: String = "", p_is_bot: bool = false, p_loadout: Dictionary = {}) -> void:
	slot = p_slot
	peer_id = p_peer_id
	name = p_name
	is_bot = p_is_bot
	loadout = p_loadout


## Plain data for the wire (RPC arguments carry no objects).
func to_dict() -> Dictionary:
	return {"slot": slot, "peer_id": peer_id, "name": name, "is_bot": is_bot, "loadout": loadout.duplicate()}


## Inverse of `to_dict`; null when `d` is not a valid entry.
static func from_dict(d: Variant) -> PlayerInfo:
	if typeof(d) != TYPE_DICTIONARY:
		return null
	var dict: Dictionary = d
	var s: Variant = dict.get("slot")
	var p: Variant = dict.get("peer_id")
	if typeof(s) != TYPE_INT or typeof(p) != TYPE_INT:
		return null
	var l: Variant = dict.get("loadout", {})
	return PlayerInfo.new(s, p, str(dict.get("name", "")), dict.get("is_bot", false) == true,
			(l as Dictionary).duplicate() if typeof(l) == TYPE_DICTIONARY else {})
