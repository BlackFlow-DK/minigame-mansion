class_name MinigameRegistry
extends RefCounted
## The minigames in the game. Orchestrator-owned.

## Minigame ids; each lives in `game/minigames/<id>/<id>.tscn`.
const IDS: Array[StringName] = [&"floor_is_lava", &"bumper_sumo", &"hot_potato", &"coin_scramble", &"cannon_alley", &"paint_splat", &"spotlight_chairs", &"crown_keeper"]


## `res://` path of the scene for `id`.
static func scene_path(id: StringName) -> String:
	return "res://minigames/%s/%s.tscn" % [id, id]


static func has(id: StringName) -> bool:
	return IDS.has(id)
