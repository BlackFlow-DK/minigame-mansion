extends Node
## Autoload `Net`: hosting, joining, LAN discovery and the player roster. Owner: net.
## Stub: offline only. The roster works offline; network calls return ERR_UNAVAILABLE.

signal roster_changed
signal games_found(games: Array)
signal join_failed(reason: String)
signal server_closed

const MAX_PLAYERS := 8
const DEFAULT_PORT := 24565

## slot -> PlayerInfo. Every peer holds the same roster.
var roster: Dictionary[int, PlayerInfo] = {}

var _local_name: String = "Player"
var _local_loadout: Dictionary = {}


## Hosts a LAN game under `game_name`.
func host_game(_game_name: String) -> Error:
	return ERR_UNAVAILABLE


## Joins the host at `address` (IP or host name).
func join_game(_address: String) -> Error:
	return ERR_UNAVAILABLE


## Single-player session on this machine: this peer is host (id 1); the local human is slot 0.
func start_offline() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	roster.clear()
	var loadout := _local_loadout if not _local_loadout.is_empty() else Cosmetics.default_loadout(0)
	roster[0] = PlayerInfo.new(0, multiplayer.get_unique_id(), _local_name, false, loadout)
	roster_changed.emit()


## Leaves the game (or closes it when hosting) and clears the roster.
func leave() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	roster.clear()
	roster_changed.emit()


## Starts listening for LAN games; results arrive through `games_found`.
func start_discovery() -> void:
	pass


func stop_discovery() -> void:
	pass


## True on the host (and offline).
func is_host() -> bool:
	return multiplayer.is_server()


## Slot of the human on this peer, or -1.
func local_slot() -> int:
	var me := multiplayer.get_unique_id()
	for s: int in roster:
		var info := roster[s]
		if info.peer_id == me and not info.is_bot:
			return s
	return -1


## Host only. Adds a bot in the lowest free slot; returns the slot, or -1 when full.
func add_bot() -> int:
	for s in MAX_PLAYERS:
		if not roster.has(s):
			roster[s] = PlayerInfo.new(s, multiplayer.get_unique_id(), "Bot %d" % s, true, Cosmetics.default_loadout(s))
			roster_changed.emit()
			return s
	return -1


## Host only. Removes the bot in `slot` (humans are not removed).
func remove_bot(slot: int) -> void:
	if roster.has(slot) and roster[slot].is_bot:
		roster.erase(slot)
		roster_changed.emit()


## Sets this peer's name and loadout, now and for the next game.
func set_local_profile(player_name: String, loadout: Dictionary) -> void:
	_local_name = player_name
	_local_loadout = loadout
	var s := local_slot()
	if s >= 0:
		roster[s].name = player_name
		roster[s].loadout = loadout
		roster_changed.emit()
