class_name Stage
extends Node3D
## Loads one minigame scene and spawns one Player per `Net.roster` entry at its spawn
## points, on every peer, so node paths match: players are `Players/P<slot>`, each with
## multiplayer authority = its `PlayerInfo.peer_id` (bots: the host). Find it with
## `get_tree().get_first_node_in_group(&"stage")`. The Stage must sit at the same node path
## on every peer (it is part of the main scene): its RPCs and those of its `SyncHub` child
## (player sync transport, game/net/sync/) are addressed by path.
##
## Networking (host-authoritative, explicit RPCs, no MultiplayerSpawner):
## - Any peer's `load_minigame*` loads locally. Session calls it on every peer in the same
##   reliable RPC stream as the roster, so every peer spawns the same players.
## - After each load (and after every change to the player set) the host sends a manifest:
##   load id, scene path, `follow_roster`, and the exact players (PlayerInfo + spawn point).
##   A client adopts it: it reconciles the players it spawned itself, or loads the scene
##   from the manifest when it did not load it (host-only loads, late joiners).
## - Clients never add or remove players from their own roster; only host manifests do.
## - `clear()` on the host clears every peer.
## - Normal rounds: a slot that leaves the roster is knocked out (`Minigame.knock_out`, host)
##   so rankings stay right, then removed on every peer. `follow_roster` (lobby): players
##   are added and removed as the roster changes, no knock-outs.
## Offline everything is local, exactly as before.

signal players_spawned(players: Array[Player])

const PLAYER_SCENE: PackedScene = preload("res://player/player.tscn")
const NAME_TAG_PATH := "res://ui/round/name_tag.tscn"

## Lobby mode: spawn/remove players as `Net.roster` changes (host decides; clients follow the
## host's manifest). Set it before or after loading; the host resends the manifest.
## Players spawn frozen, as always: the lobby unfreezes them (listen to `players_spawned`).
@export var follow_roster: bool = false:
	set(value):
		if follow_roster == value:
			return
		follow_roster = value
		if is_inside_tree() and minigame and not _is_client():
			_on_roster_changed()
			_send_manifest()
## Give each spawned player a floating NameTag (never when headless).
@export var name_tags: bool = true

## The loaded minigame, or null.
var minigame: Minigame = null
## slot -> Player, for the loaded minigame.
var players: Dictionary[int, Player] = {}
## Id of the current load as numbered by the host (same on every peer once a client has
## the host's manifest; -1 while unknown or nothing is loaded). Sync traffic is tagged with it.
var net_load_id: int = -1
## Player sync transport (child `SyncHub`).
var sync_hub: SyncHub = null

var _load_counter: int = 0
var _scene_path: String = ""
## slot -> spawn point index used for that player.
var _spawn_index: Dictionary[int, int] = {}

@onready var _players_root: Node3D = $Players


func _enter_tree() -> void:
	add_to_group(&"stage")
	if not Net.roster_changed.is_connected(_on_roster_changed):
		Net.roster_changed.connect(_on_roster_changed)
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)


func _exit_tree() -> void:
	if Net.roster_changed.is_connected(_on_roster_changed):
		Net.roster_changed.disconnect(_on_roster_changed)
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)


func _ready() -> void:
	sync_hub = SyncHub.new()
	sync_hub.name = "SyncHub"
	sync_hub.stage = self
	add_child(sync_hub)


## Frees the current minigame and players, loads minigame `id` (see MinigameRegistry)
## and spawns the players. Returns the minigame, or null if the id is unknown.
func load_minigame(id: StringName) -> Minigame:
	if not MinigameRegistry.has(id):
		push_error("Stage.load_minigame: unknown minigame '%s'" % id)
		return null
	return load_minigame_scene(load(MinigameRegistry.scene_path(id)) as PackedScene)


## Like load_minigame, from a scene whose root extends Minigame (dev arenas, tests).
func load_minigame_scene(scene: PackedScene) -> Minigame:
	_clear_local()
	if not _instance_scene(scene):
		return null
	if not _is_client():
		_load_counter += 1
		net_load_id = _load_counter
	spawn_players()
	_send_manifest()
	return minigame


## Spawns one frozen Player per roster entry (sorted by slot) at the minigame's spawn
## points, sets `minigame.players`, emits `players_spawned`. Whoever starts play unfreezes them.
## Spawn point: the i-th player gets point i (with `follow_roster`: point `slot`).
func spawn_players() -> Array[Player]:
	var spawned: Array[Player] = []
	var slots: Array[int] = []
	slots.assign(Net.roster.keys())
	slots.sort()
	for i in slots.size():
		var info: PlayerInfo = Net.roster[slots[i]]
		spawned.append(_spawn(info, info.slot if follow_roster else i))
	if minigame:
		minigame.players = spawned.duplicate()
	players_spawned.emit(spawned)
	return spawned


## The player in `slot`, or null.
func get_player(slot: int) -> Player:
	return players.get(slot) as Player


## Frees the minigame and all players. On the host, every client clears too.
func clear() -> void:
	_clear_local()
	if _is_host_net():
		_rpc_clear.rpc()


# --- Spawning ----------------------------------------------------------------------------

func _instance_scene(scene: PackedScene) -> bool:
	minigame = scene.instantiate() as Minigame if scene else null
	if minigame == null:
		push_error("Stage.load_minigame_scene: scene root does not extend Minigame")
		return false
	_scene_path = scene.resource_path
	minigame.name = "Minigame"
	add_child(minigame)
	return true


func _spawn(info: PlayerInfo, point_index: int) -> Player:
	var p := PLAYER_SCENE.instantiate() as Player
	p.name = "P%d" % info.slot
	p.slot = info.slot
	p.display_name = info.name
	p.is_bot = info.is_bot
	p.loadout = info.loadout
	p.frozen = true
	p.set_multiplayer_authority(info.peer_id)
	_players_root.add_child(p)
	var points: Array[Transform3D] = minigame.get_spawn_points() if minigame else []
	if not points.is_empty():
		p.place_at(points[point_index % points.size()])
	players[info.slot] = p
	_spawn_index[info.slot] = point_index
	_attach_name_tag(p)
	return p


func _attach_name_tag(p: Player) -> void:
	if not name_tags or DisplayServer.get_name() == "headless" or not ResourceLoader.exists(NAME_TAG_PATH):
		return
	var scene := load(NAME_TAG_PATH) as PackedScene
	var tag := scene.instantiate() if scene else null
	if tag == null:
		return
	tag.name = "NameTag"
	p.add_child(tag)
	if tag.has_method(&"setup"):
		tag.call(&"setup", p)


func _remove_player(slot: int) -> void:
	var p: Player = players.get(slot)
	players.erase(slot)
	_spawn_index.erase(slot)
	if not is_instance_valid(p):
		return
	if minigame:
		minigame.players.erase(p)
	if p.get_parent() == _players_root:
		_players_root.remove_child(p)
	p.queue_free()


func _clear_local() -> void:
	for p: Player in players.values():
		if is_instance_valid(p):
			if p.get_parent() == _players_root:
				_players_root.remove_child(p)
			p.queue_free()
	players.clear()
	_spawn_index.clear()
	if minigame:
		remove_child(minigame)
		minigame.queue_free()
		minigame = null
	_scene_path = ""
	net_load_id = -1


# --- Roster changes (host / offline) -------------------------------------------------------

func _on_roster_changed() -> void:
	if not is_inside_tree() or minigame == null or _is_client():
		return
	var changed := false
	for slot: int in players.keys():
		if not players.has(slot):
			continue  # removed while knocking out another one
		var info: PlayerInfo = Net.roster.get(slot)
		var p: Player = players[slot]
		if info != null and is_instance_valid(p) and info.peer_id == p.get_multiplayer_authority():
			continue
		if not follow_roster and is_instance_valid(p) and not minigame.is_finished():
			minigame.knock_out(p)  # host decision: may finish the round
		_remove_player(slot)
		changed = true
	var added: Array[Player] = []
	if follow_roster and minigame:
		var slots: Array[int] = []
		slots.assign(Net.roster.keys())
		slots.sort()
		for slot in slots:
			var info: PlayerInfo = Net.roster[slot]
			var p: Player = players.get(slot)
			if p == null:
				var np := _spawn(info, slot)
				minigame.players.append(np)
				added.append(np)
			elif p.display_name != info.name or p.loadout != info.loadout:
				p.display_name = info.name
				p.loadout = info.loadout
				changed = true
	if not added.is_empty():
		players_spawned.emit(added)
	if changed or not added.is_empty():
		_send_manifest()


# --- Host -> clients ------------------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	if _is_host_net() and minigame:
		_rpc_manifest.rpc_id(peer_id, net_load_id, _scene_path, follow_roster, _manifest_entries())


func _send_manifest() -> void:
	if not _is_host_net() or minigame == null or multiplayer.get_peers().is_empty():
		return
	_rpc_manifest.rpc(net_load_id, _scene_path, follow_roster, _manifest_entries())


func _manifest_entries() -> Array:
	var slots: Array[int] = []
	slots.assign(players.keys())
	slots.sort()
	var out: Array = []
	for slot in slots:
		var p: Player = players[slot]
		var d := PlayerInfo.new(slot, p.get_multiplayer_authority(), p.display_name, p.is_bot, p.loadout).to_dict()
		d["spawn"] = _spawn_index.get(slot, 0)
		out.append(d)
	return out


@rpc("authority", "call_remote", "reliable")
func _rpc_manifest(load_id: Variant, scene_path: Variant, follow: Variant, entries: Variant) -> void:
	apply_manifest(load_id, scene_path, follow, entries)


@rpc("authority", "call_remote", "reliable")
func _rpc_clear() -> void:
	_clear_local()


## Client side of the manifest (public for tests): adopt the host's load `load_id` of
## `scene_path` with exactly the players in `entries` (PlayerInfo dicts plus "spawn").
func apply_manifest(load_id: Variant, scene_path: Variant, follow: Variant, entries: Variant) -> void:
	if typeof(load_id) != TYPE_INT or typeof(scene_path) != TYPE_STRING or typeof(entries) != TYPE_ARRAY:
		return
	follow_roster = follow == true
	var wanted: Dictionary[int, Array] = {}  # slot -> [PlayerInfo, spawn index]
	for d: Variant in entries:
		var info := PlayerInfo.from_dict(d)
		if info == null or info.slot < 0 or info.slot >= Net.MAX_PLAYERS:
			continue
		wanted[info.slot] = [info, int((d as Dictionary).get("spawn", info.slot))]
	var same_load: bool = minigame != null and (net_load_id == load_id \
			or (net_load_id == -1 and _scene_path == scene_path))
	if not same_load:
		var path: String = scene_path
		if not path.begins_with("res://") or not ResourceLoader.exists(path):
			push_warning("Stage: host manifest names an unknown scene '%s'" % path)
			return
		_clear_local()
		if not _instance_scene(load(path) as PackedScene):
			return
	net_load_id = load_id
	for slot: int in players.keys():
		var keep: Array = wanted.get(slot, [])
		if keep.is_empty() or players[slot].get_multiplayer_authority() != (keep[0] as PlayerInfo).peer_id:
			_remove_player(slot)
	var slots: Array[int] = []
	slots.assign(wanted.keys())
	slots.sort()
	var added: Array[Player] = []
	for slot in slots:
		var info: PlayerInfo = wanted[slot][0]
		var p: Player = players.get(slot)
		if p == null:
			p = _spawn(info, wanted[slot][1])
			minigame.players.append(p)
			added.append(p)
		else:
			p.display_name = info.name
			p.loadout = info.loadout
	if not added.is_empty():
		players_spawned.emit(added)


# --- Helpers ---------------------------------------------------------------------------------

func _is_client() -> bool:
	return SyncHub.is_networked(multiplayer) and not multiplayer.is_server()


func _is_host_net() -> bool:
	return SyncHub.is_networked(multiplayer) and multiplayer.is_server()
