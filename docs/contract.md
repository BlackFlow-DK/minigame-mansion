# Minigame Mansion: build contract

The shared interfaces every agent builds against. One agent owns one system; systems only talk through what is written here. If you need something that is not here, do not invent a cross-system API: report it to the orchestrator.

Design spec: `docs/superpowers/specs/2026-09-30-minigame-mansion-design.md`.

## Working rules for every agent

- Work in your own git worktree and branch (your brief names them). Commit there. Never merge, never touch `main`, never touch another worktree.
- Edit only the files your brief lists as yours. `game/project.godot`, `game/player/player.tscn`, `game/player/player.gd`, `art/scripts/artlib.py`, `tools/`, `CLAUDE.md` and this file belong to the orchestrator: if you need a change there, report it, do not make it.
- Done means: `godot-check` passes, `godot-test` passes (including your new tests), and you looked at a screenshot if your work is visible.
- GDScript: static typing everywhere, `class_name` for shared types, tabs, snake_case files.

## World conventions

- Metres. Godot +Y up. Characters face +Z (`Vector3.MODEL_FRONT`). Origin of every model at its base centre.
- Player blob: 1.0 m tall, about 0.8 m wide. Collision capsule radius 0.4, height 1.0.
- Physics layers: 1 world, 2 players, 3 hazards and kill zones (Area3D), 4 pickups (Area3D).
- Input actions: `move_left`, `move_right`, `move_forward`, `move_back`, `jump`, `action`, `pause` (keyboard and gamepad).
- Player slots are 0..7. A slot is the stable identity of a player for the whole session (humans and bots).

## Player

`game/player/player.tscn`, root `Player` (`CharacterBody3D`, `class_name Player`). It owns shared state and the tick order; it contains no mechanic logic. Each mechanic is a component: its own scene `game/player/components/<name>.tscn` plus script, instanced under `Player/Components`, extending `PlayerComponent`.

```gdscript
class_name PlayerComponent extends Node3D
var player: Player                      # set by Player before _ready of the component
func physics_tick(_delta: float) -> void: pass   # called by Player, authority only, in tick order
```

### Shared state on Player

| Member | Meaning |
|---|---|
| `slot: int`, `display_name: String`, `is_bot: bool`, `loadout: Dictionary` | identity, set at spawn |
| `intent: PlayerIntent` | what the controller wants this tick: `move: Vector2` (world X,Z, length 0..1), `jump_pressed`, `jump_held`, `action_pressed` |
| `stats: PlayerStats` | tuning Resource (run speed, acceleration, jump velocity, gravity, shove force, ...). Each mechanic adds its own exported fields to its OWN stats resource, see below |
| `velocity` | built-in; components add to or set their axis of it |
| `facing: Vector3` | unit vector on XZ the blob looks along |
| `frozen: bool` | set by the minigame (countdown, round over): no movement, no actions |
| `control_locked: bool` | set by the status component while stunned: intent is ignored, physics still runs |
| `alive: bool` | false after `eliminate()` until `respawn_at()` |
| `is_authority() -> bool` | true on the peer that simulates this player (owner peer; host for bots) |

Tuning: a component keeps its numbers in exported vars on its own component script (not in a shared file), and exposes them through `player.get_component(&"name")` so a minigame can change them, for example `player.get_component(&"shove").force = 14.0`.

### Tick order (authority only, inside `Player._physics_process`)

`controller` (human input or bot brain fills `intent`) -> `status` -> `movement` -> `jump` -> `shove` -> `move_and_slide()` -> `post_tick` on every component.

Remote copies do not tick; the `sync` component moves them.

### Player API (callable by any system)

```gdscript
func get_component(name: StringName) -> PlayerComponent
func apply_impulse(impulse: Vector3, source: Player = null) -> void  # routed to the authority; handled by status
func eliminate(reason: StringName = &"") -> void                      # host only
func respawn_at(xform: Transform3D) -> void                           # host only
func emit_event(event: StringName, args: Array = []) -> void          # emits the matching signal on every peer
```

### Player events (signals; always raise them with `emit_event`)

| Signal | Raised by | Args |
|---|---|---|
| `jumped` | jump | |
| `landed` | jump | `impact_speed: float` |
| `shove_started` | shove | |
| `shove_hit` | shove | `victim_slot: int` |
| `got_hit` | status | `impulse: Vector3`, `source_slot: int` (-1 if none) |
| `stunned` | status | `duration: float` |
| `eliminated` | Player | `reason: StringName` |
| `respawned` | Player | |

Visuals, effects and sound never get called by mechanics. They listen to these signals and read the shared state.

### Components

| Name | Owner system | Job |
|---|---|---|
| `controller` | skeleton (human), bot agent (bot brain) | fill `intent` |
| `status` | knockback | impulses, stun, `control_locked` |
| `movement` | run | horizontal velocity and `facing` from `intent.move` |
| `jump` | jump | gravity, jump, coyote time, landing |
| `shove` | shove | the action: hit detection, cooldown, calls `victim.apply_impulse` |
| `visuals` | character animator | shows the blob model, procedural animation |
| `cosmetics` | cosmetics system | applies `loadout` to the model |
| `fx` | look and effects | particles on events |
| `sfx` | audio | sounds on events |
| `sync` | player sync | replicates state and events to other peers |

## Character model and cosmetics

`game/assets/models/character/blob.glb`, separate named objects so code can animate them without a skeleton:

`Body`, `EyeL`, `EyeR`, `PupilL`, `PupilR`, `LidL`, `LidR`, `Mouth`, `CheekL`, `CheekR`, `HandL`, `HandR`, `FootL`, `FootR`, plus empties `HatSocket`, `FaceSocket`, `NeckSocket`, `BackSocket`.

- Hands and feet float (not attached by limbs); each has its origin at its own centre.
- Materials named `PlayerPrimary` and `PlayerSecondary` are recoloured per player. All other materials keep their colour.
- Socket positions (Godot space): `HatSocket` (0, 1.00, 0) top of head; `FaceSocket` (0, 0.68, 0.37) between the eyes on the surface; `NeckSocket` (0, 0.40, 0) where the body is 0.40 m in radius; `BackSocket` (0, 0.50, -0.37).
- Cosmetic models are authored with their origin at the socket they attach to, sized for the numbers above: `game/assets/models/cosmetics/<slot>_<id>.glb`, slots `hat`, `face`, `neck`, `back`.
- Loadout dictionary: `{ "primary": "#rrggbb", "secondary": "#rrggbb", "hat": id, "face": id, "neck": id, "back": id }`; an empty string means nothing in that slot.
- Art scripts: `art/scripts/character/`, `art/scripts/cosmetics/`, `art/scripts/env/`, `art/scripts/props/`, all through `artlib`.

## Autoloads

| Name | Owner | API (signals in italics) |
|---|---|---|
| `Net` | net | `host_game(name) -> Error`, `join_game(address) -> Error`, `start_offline()`, `leave()`, `start_discovery()`, `stop_discovery()`, `is_host()`, `local_slot() -> int`, `roster: Dictionary` (slot -> `PlayerInfo{slot, peer_id, name, is_bot, loadout}`), `add_bot()`, `remove_bot(slot)`, `set_local_profile(name, loadout)`; *`roster_changed`*, *`games_found(games: Array)`*, *`join_failed(reason)`*, *`server_closed`* |
| `Session` | session | `start_session(rounds: int)` (host), `state`, `scores: Dictionary` (slot -> int), `round_index`, `round_count`, `current_minigame: Minigame`; *`state_changed(state)`*, *`round_intro(info, index)`*, *`round_started`*, *`round_finished(ranking: Array[int], points: Dictionary)`*, *`session_finished(final_ranking: Array[int])`*. States: `LOBBY`, `INTRO`, `PLAYING`, `RESULTS`, `PODIUM` |
| `Cosmetics` | cosmetics system | `catalog(slot) -> Array`, `default_loadout(slot_index) -> Dictionary`, `load_profile()`, `save_profile(name, loadout)`, `apply(model_root: Node3D, loadout)` |
| `Fx` | look and effects | `play(effect: StringName, at: Vector3, color := Color.WHITE)` |
| `Sfx` | audio | `play(sound: StringName, at := Vector3.INF)` |

## Stage and minigames

`Stage` (in the main scene) loads a minigame scene and spawns one `Player` per roster entry at the minigame's spawn points, on every peer.

```gdscript
class_name Minigame extends Node3D
@export var title: String
@export var rule_text: String
@export var time_limit: float = 60.0
signal finished(ranking: Array[int])          # slots, best first
func get_spawn_points() -> Array[Transform3D]  # Marker3D children of $Spawns
func _setup(players: Array[Player]) -> void    # every peer, players are frozen
func _start() -> void                          # every peer, after the countdown
func _host_tick(delta: float) -> void          # host only, while playing
func finish(ranking: Array[int]) -> void       # host only
func knock_out(player: Player) -> void         # host only helper: eliminates and records order; last one standing finishes the round
func get_bot_goal(player: Player) -> Vector3   # where a bot should want to be (default: a random spawn point)
func is_safe(pos: Vector3) -> bool             # bots avoid unsafe positions (default: true)
```

A minigame lives in `game/minigames/<id>/` (scene `<id>.tscn`, script, its own assets). Ids in v1: `floor_is_lava`, `bumper_sumo`, `hot_potato`, `coin_scramble`. A minigame may change player component tuning in `_setup` and must not reach into other systems beyond this contract. The host decides everything that matters (who is out, scores); clients learn it through the minigame's own RPCs.

## Tests

`tools/godot-test.ps1` runs every `game/tests/test_*.gd` headless. `game/tests/harness.gd` spawns an offline arena with players whose `intent` is scripted, steps physics frames, and asserts. Every mechanic ships tests that prove its behaviour through the Player API and events only.

## File ownership

| Path | Owner |
|---|---|
| `game/player/components/<name>.*` | that component's system |
| `game/net/` | net, player sync (`game/net/sync/`) |
| `game/session/` | session |
| `game/ui/menu/`, `game/ui/round/`, `game/ui/wardrobe/` | menu UI, round UI, wardrobe UI |
| `game/cosmetics/` | cosmetics system |
| `game/look/`, `game/fx/` | look and effects |
| `game/audio/` | audio |
| `game/camera/` | arena camera |
| `game/bots/` | bot brain |
| `game/minigames/<id>/` | that minigame |
| `game/lobby/` | lobby |
| `game/assets/models/<family>/`, `art/scripts/<family>/` | that art family |
| `game/tests/test_<system>*.gd` | that system |
