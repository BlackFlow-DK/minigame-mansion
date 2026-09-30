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
