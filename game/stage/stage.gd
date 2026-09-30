class_name Stage
extends Node3D
## Loads one minigame scene and spawns one Player per `Net.roster` entry at its spawn
## points. Runs the same way on every peer, so node paths match across peers:
## players are `Players/P<slot>`. Find it with `get_tree().get_first_node_in_group(&"stage")`.
## Orchestrator-owned.
## Offline for now: spawning follows the local roster; no network replication.

signal players_spawned(players: Array[Player])

const PLAYER_SCENE: PackedScene = preload("res://player/player.tscn")

## The loaded minigame, or null.
var minigame: Minigame = null
## slot -> Player, for the loaded minigame.
var players: Dictionary[int, Player] = {}

@onready var _players_root: Node3D = $Players


func _enter_tree() -> void:
	add_to_group(&"stage")


## Frees the current minigame and players, loads minigame `id` (see MinigameRegistry)
## and spawns the players. Returns the minigame, or null if the id is unknown.
func load_minigame(id: StringName) -> Minigame:
	if not MinigameRegistry.has(id):
		push_error("Stage.load_minigame: unknown minigame '%s'" % id)
		return null
	return load_minigame_scene(load(MinigameRegistry.scene_path(id)) as PackedScene)


## Like load_minigame, from a scene whose root extends Minigame (dev arenas, tests).
func load_minigame_scene(scene: PackedScene) -> Minigame:
	clear()
	minigame = scene.instantiate() as Minigame
	if minigame == null:
		push_error("Stage.load_minigame_scene: scene root does not extend Minigame")
		return null
	minigame.name = "Minigame"
	add_child(minigame)
	spawn_players()
	return minigame


## Spawns one frozen Player per roster entry (sorted by slot) at the minigame's spawn
## points, sets `minigame.players`, emits `players_spawned`. Whoever starts play unfreezes them.
func spawn_players() -> Array[Player]:
	var spawned: Array[Player] = []
	var points: Array[Transform3D] = minigame.get_spawn_points() if minigame else []
	var slots: Array[int] = []
	slots.assign(Net.roster.keys())
	slots.sort()
	for i in slots.size():
		var info: PlayerInfo = Net.roster[slots[i]]
		var p := PLAYER_SCENE.instantiate() as Player
		p.name = "P%d" % info.slot
		p.slot = info.slot
		p.display_name = info.name
		p.is_bot = info.is_bot
		p.loadout = info.loadout
		p.frozen = true
		p.set_multiplayer_authority(info.peer_id)
		_players_root.add_child(p)
		if not points.is_empty():
			p.place_at(points[i % points.size()])
		players[info.slot] = p
		spawned.append(p)
	if minigame:
		minigame.players = spawned
	players_spawned.emit(spawned)
	return spawned


## The player in `slot`, or null.
func get_player(slot: int) -> Player:
	return players.get(slot) as Player


## Frees the minigame and all players.
func clear() -> void:
	for p: Player in players.values():
		_players_root.remove_child(p)
		p.queue_free()
	players.clear()
	if minigame:
		remove_child(minigame)
		minigame.queue_free()
		minigame = null
