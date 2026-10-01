# Minigame Mansion: build contract

The shared interfaces every agent builds against. One agent owns one system; systems only talk through what is written here. If you need something that is not here, do not invent a cross-system API: report it to the orchestrator.

Design spec: `docs/superpowers/specs/2026-09-30-minigame-mansion-design.md`.

## Working rules for every agent

- Work in your own git worktree and branch (your brief names them). Commit there. Never merge, never touch `main`, never touch another worktree.
- Edit only the files your brief lists as yours. The orchestrator owns `game/project.godot`, `game/player/player.tscn`, `game/player/player.gd`, `game/player/player_component.gd`, `game/player/player_intent.gd`, `game/minigames/minigame.gd`, `game/minigames/registry.gd`, `game/stage/`, `game/dev/`, `game/tests/harness.gd`, `game/tests/run_tests.gd`, `game/tests/test_skeleton.gd`, `game/tools/`, `art/scripts/artlib.py`, `tools/`, `CLAUDE.md` and this file: if you need a change there, report it, do not make it.
- Done means: `godot-check` passes, `godot-test` passes (including your new tests), and you looked at a screenshot if your work is visible.
- GDScript: static typing everywhere, `class_name` for shared types, tabs, snake_case files.

## World conventions

- Metres. Godot +Y up. Characters face +Z (`Vector3.MODEL_FRONT`). Origin of every model at its base centre.
- Player blob: 1.0 m tall, about 0.8 m wide. Collision capsule radius 0.4, height 1.0.
- Physics layers (named in project.godot): 1 `world`, 2 `players`, 3 `hazards` (kill zones, Area3D), 4 `pickups` (Area3D). Player body: layer 2, mask 1+2 (world and other players).
- Input actions: `move_left`, `move_right`, `move_forward`, `move_back` (WASD, arrows, left stick), `jump` (Space, A), `action` (E, left mouse, X), `pause` (Esc, Start).
- Player slots are 0..7. A slot is the stable identity of a player for the whole session (humans and bots).

## Player

`game/player/player.tscn`, root `Player` (`CharacterBody3D`, `class_name Player`) with a `CollisionShape3D` and a `Components` node. It owns shared state and the tick order; it contains no mechanic logic. Each mechanic is a component: its own scene `game/player/components/<name>.tscn` plus script `<name>.gd`, instanced under `Player/Components` with node name `<name>`, extending `PlayerComponent`. You own your component's scene and script and may add child nodes to its scene.

```gdscript
class_name PlayerComponent extends Node3D
var player: Player                                 # set by Player (in its _enter_tree) before the component's _ready
func physics_tick(_delta: float) -> void: pass     # authority only, in tick order; only the 6 ticked components get it
func post_tick(_delta: float) -> void: pass        # authority only, every component, after move_and_slide()
```

The Player root never rotates (identity basis); `facing` says where the blob looks and `visuals` turns the model to it. Player nodes are named `P<slot>`.

### Shared state on Player

| Member | Meaning |
|---|---|
| `slot: int`, `display_name: String`, `is_bot: bool`, `loadout: Dictionary` | identity, set at spawn |
| `intent: PlayerIntent` | what the controller wants this tick: `move: Vector2` (world X,Z, length 0..1), `jump_pressed`, `jump_held`, `action_pressed` (bools; `*_pressed` true only on the first tick), `clear()` |
| `velocity` | built-in; components add to or set their axis of it |
| `facing: Vector3` | unit vector on XZ the blob looks along |
| `frozen: bool` | set by the minigame/session (countdown, round over): no movement, no actions. Player clears `intent` every tick while set |
| `control_locked: bool` | set by the status component while stunned: Player clears `intent` after the status tick; physics still runs |
| `alive: bool` | false after `eliminate()` until `respawn_at()`. A dead player is hidden, has collision disabled and does not tick |
| `is_authority() -> bool` | true on the peer that simulates this player (owner peer; host for bots) |

Tuning: a component keeps its numbers in exported vars on its own component script (there is no shared stats resource), so a minigame can change them through a cast, for example `(player.get_component(&"shove") as ShoveComponent).force = 14.0`.

### Tick order (authority only, inside `Player._physics_process`)

`size` (scales the others' tuning) -> `controller` (human input or bot brain fills `intent`) -> [`intent` cleared if `frozen`] -> `status` -> [`intent` cleared if `frozen` or `control_locked`] -> `movement` -> `jump` -> `shove` -> `move_and_slide()` -> `post_tick` on every component (child order). Nothing ticks while `alive` is false.

Remote copies do not tick; the `sync` component moves them. Anything that must run on every peer (visuals, sound, the sync itself) uses its own `_process`/`_physics_process`, not the ticks.

### Player API (callable by any system)

```gdscript
func is_authority() -> bool
func get_component(component_name: StringName) -> PlayerComponent   # null if absent
func apply_impulse(impulse: Vector3, source: Player = null) -> void  # authority: status.receive_impulse(); elsewhere: sync.relay_impulse()
func eliminate(reason: StringName = &"") -> void                      # host only
func respawn_at(xform: Transform3D) -> void                           # host only; origin + facing from xform
func place_at(xform: Transform3D) -> void                             # teleport without events (Stage uses it at spawn)
func emit_event(event: StringName, args: Array = []) -> void          # emits locally, then sync.relay_event() for the other peers
func receive_event(event: StringName, args: Array = []) -> void       # sync only: an event from another peer; applies eliminated/respawned state, emits locally, does not relay
```

Networking seams, so `player.gd` never needs editing: `SyncComponent.relay_event(event, args)`, `SyncComponent.relay_impulse(impulse, source)` and `StatusComponent.receive_impulse(impulse, source)`. Stubs today: the relays do nothing; `receive_impulse` adds the impulse to `velocity`.

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
| `respawned` | Player | `xform: Transform3D` |

Visuals, effects and sound never get called by mechanics. They listen to these signals and read the shared state.

### Components

| Name | Class | Owner system | Job |
|---|---|---|---|
| `controller` | `ControllerComponent` | skeleton (human), bot agent (bot brain) | fill `intent` |
| `status` | `StatusComponent` | knockback | impulses, stun, `control_locked` |
| `movement` | `MovementComponent` | run | horizontal velocity and `facing` from `intent.move` |
| `jump` | `JumpComponent` | jump | gravity, jump, coyote time, landing |
| `shove` | `ShoveComponent` | shove | the action: hit detection, cooldown, calls `victim.apply_impulse` |
| `visuals` | `VisualsComponent` | character animator | shows the blob model, procedural animation (stub: capsule with eyes) |
| `cosmetics` | `CosmeticsComponent` | cosmetics system | applies `loadout` to the model |
| `size` | `SizeComponent` | cosmetics system | body size from `loadout.size`: scale, capsule, tuning multipliers |
| `fx` | `FxComponent` | look and effects | particles on events |
| `sfx` | `SfxComponent` | audio | sounds on events |
| `sync` | `SyncComponent` | player sync | replicates state and events to other peers |

Controller (human): reads the input actions; `intent.move` is camera-relative (forward = away from the active camera, projected on XZ), expressed in world X,Z. `*_pressed` are edges of the held state. `scripted: bool` (tests): when true the controller leaves `intent` alone. The human controller in `controller.gd` belongs to the skeleton; the bot agent does not edit it.

Bot brain (bot agent): `game/bots/bot_brain.gd`, `extends Node`, `var player: Player` (set before it enters the tree), `func fill_intent(intent: PlayerIntent, delta: float) -> void`. When that file exists, the controller of every bot instances it as its child `BotBrain` and calls `fill_intent` each tick on the authority (the host). Without it bots stand still. The brain reads the world through the Player API and `Minigame.get_bot_goal` / `is_safe`.

## Character model and cosmetics

`game/assets/models/character/blob.glb`, separate named objects so code can animate them without a skeleton:

`Body`, `EyeL`, `EyeR`, `PupilL`, `PupilR`, `LidL`, `LidR`, `Mouth`, `CheekL`, `CheekR`, `HandL`, `HandR`, `FootL`, `FootR`, plus empties `HatSocket`, `FaceSocket`, `NeckSocket`, `BackSocket`.

- Hands and feet float (not attached by limbs); each has its origin at its own centre.
- Materials named `PlayerPrimary` and `PlayerSecondary` are recoloured per player. All other materials keep their colour.
- Socket positions (Godot space): `HatSocket` (0, 1.00, 0) top of head; `FaceSocket` (0, 0.68, 0.37) between the eyes on the surface; `NeckSocket` (0, 0.40, 0) where the body is 0.40 m in radius; `BackSocket` (0, 0.50, -0.37).
- Cosmetic models are authored with their origin at the socket they attach to, sized for the numbers above: `game/assets/models/cosmetics/<slot>_<id>.glb`, slots `hat`, `face`, `neck`, `back`.
- Loadout dictionary: `{ "primary": "#rrggbb", "secondary": "#rrggbb", "hat": id, "face": id, "neck": id, "back": id, "size": "small" | "normal" | "big" }`; an empty string means nothing in that slot; a missing or unknown `size` is `normal`. Anything that sanitizes a loadout must keep `size`.

### Body size (`size` component, owner: cosmetics system)

`game/player/components/size.*` (`SizeComponent`) reads `player.loadout["size"]` on every peer (numbers: `SIZES` in `game/cosmetics/catalog.gd`; `Cosmetics.sizes()`, `size_info(id)`).
- Looks: scales the `visuals` component node (the model root's parent: squash, hats and items follow), gives the player its own collision capsule scaled (feet stay at y=0), scales `NameTag.height` and `FxComponent.head_height`.
- Tuning: multiplies `movement.max_speed`, `jump.jump_height`, `shove.force`, `shove.reach`, `shove.width`, `status.knockback_multiplier` (the catalog gives shove/knockback as felt slide distance; the impulse gets the square root). It remembers the value it wrote; any other value (a minigame's write) becomes the new base, then `base * factor` is written back. Factors are 1 while `frozen`, so `_setup`/`_start` read and write base values. `SizeComponent.base_of(component, property)` gives the base.
- Minigames: set tuning to absolute values (from what you read in `_setup`/`_start`), per frame if you like; never `*=` mid-round (the factor would compound).
- Art scripts: `art/scripts/character/`, `art/scripts/cosmetics/`, `art/scripts/env/`, `art/scripts/props/`, all through `artlib` (multi-part: `finalize`, `empty`, `set_parent`, `from_godot`, `export_glb(name, family="character")`).

## Autoloads

| Name | Owner | API (signals in italics) |
|---|---|---|
| `Net` | net | `host_game(game_name: String) -> Error`, `join_game(address: String) -> Error`, `start_offline()`, `leave()`, `start_discovery()`, `stop_discovery()`, `is_host() -> bool`, `local_slot() -> int` (-1 if none), `roster: Dictionary[int, PlayerInfo]` (slot -> `PlayerInfo{slot, peer_id, name, is_bot, loadout}`, `game/net/player_info.gd`; `peer_id` is the simulating peer: the owner, or the host (1) for bots), `add_bot() -> int` (slot, -1 if full), `remove_bot(slot)`, `set_local_profile(player_name, loadout)`, `MAX_PLAYERS = 8`, `DEFAULT_PORT = 24565`; *`roster_changed`*, *`games_found(games: Array)`*, *`join_failed(reason: String)`*, *`server_closed`*. Offline: this peer is 1 and the local human is slot 0 |
| `Session` | session | `start_session(rounds: int)` (host), `state: State`, `scores: Dictionary[int, int]` (slot -> points), `round_index` (0-based, -1 before the first), `round_count`, `current_minigame: Minigame`; *`state_changed(state: State)`*, *`round_intro(info: Dictionary, index: int)`* (info: `{id, title, rule_text}`), *`round_started`*, *`round_finished(ranking: Array[int], points: Dictionary)`*, *`session_finished(final_ranking: Array[int])`*. `enum State { LOBBY, INTRO, PLAYING, RESULTS, PODIUM }` |
| `Cosmetics` | cosmetics system | `catalog(slot: StringName) -> Array`, `default_loadout(slot_index: int) -> Dictionary`, `load_profile() -> Dictionary` (`{name, loadout}`), `save_profile(player_name, loadout)`, `apply(model_root: Node3D, loadout: Dictionary)` (items and colours; not the size), `sizes() -> Array`, `size_info(id) -> Dictionary`, `sanitize(loadout, fallback_slot)` |
| `Fx` | look and effects | `play(effect: StringName, at: Vector3, color := Color.WHITE)` |
| `Sfx` | audio | `play(sound: StringName, at := Vector3.INF)` |
| `Progression` | progression | Mansion Coins of the local player, saved in its own profile; every peer pays itself from the Session signals (nothing networked; bots never earn; half rate offline and with fewer than 2 humans: `is_half_rate()`). `coins`, `stats`, `award(reason: StringName, amount: int, once := true) -> int` (one-time per reason by default, e.g. the tutorial's `award(&"tutorial", 20)`), `is_unlocked(slot, id)` (wardrobe gate only), `unlock(slot, id) -> bool`, `price(slot, id)`, `dev_unlock_all()` / `--unlock-all` (testing); *`coins_changed(total)`*, *`awarded(reason, amount, total)`*, *`unlocks_changed(slot, id)`* |
| `Settings` | UI polish (`game/ui/settings/settings.gd`; screen `settings.tscn`) | The player's options, `user://settings.json`, applied at startup: `master_volume`, `music_volume`, `sfx_volume`, `ui_volume` (0..1 -> buses Master / Music / Sfx / Ui), `fullscreen`, `window_size`, `quality` ("high"/"low" -> `Look.set_quality`), `show_fps`, and the comfort flags **`screen_shake: bool`** (false: no camera shake) and **`reduced_motion: bool`** (calmer animations); `set_value(key, value)`, *`changed(key)`*. Other systems read the flags without a hard dependency: `get_tree().root.get_node_or_null(^"Settings")` then `.screen_shake` / `.reduced_motion` |

`Net` details (added after wave 1):
- `join_game` accepts `"ip"` or `"ip:port"`. `join_failed` reasons are exactly `timeout`, `full`, `in progress`, `version mismatch`, `could not connect`.
- `games_found` entries: `{id, address ("ip:port", pass it to join_game), ip, port, game_name, host_name, players, max_players, in_lobby, version, compatible}`.
- `session_in_progress: bool` (host sets, clients receive) and `accept_late_joiners: bool` (default false: joins during a session are refused with `in progress`). `Session` sets `session_in_progress` at session start and clears it when it returns to LOBBY.

`Session` details (added after wave 1): also public `abort_session()`, `round_wins`, `phase_duration`, `phase_time_left` (UI derives countdowns from these), `end_grace` (seconds left of a minigame's end grace, 0 = none; see `finish`). Each transition emits `state_changed` first, then its event signal. On time-out survivors share first place. Returning to LOBBY clears the stage.

Autoload scripts (paths fixed by project.godot; the owner edits the file, never the path): `game/net/net.gd`, `game/session/session.gd`, `game/cosmetics/cosmetics.gd`, `game/fx/fx.gd`, `game/audio/sfx.gd`, `game/progression/progression.gd`, `game/ui/settings/settings.gd`. Plain `extends Node` scripts without `class_name`; add child nodes from code if needed. `AgentScreenshot` (`game/tools/screenshot.gd`) is tooling.

## Stage and minigames

`Stage` (`game/stage/stage.tscn`, in the main scene) loads a minigame scene and spawns one `Player` per roster entry at the minigame's spawn points, on every peer. Offline today; the same calls on every peer give matching node paths. It is in group `stage`: `get_tree().get_first_node_in_group(&"stage") as Stage`.

```gdscript
class_name Stage extends Node3D
signal players_spawned(players: Array[Player])
var minigame: Minigame                                   # the loaded one, or null
var players: Dictionary[int, Player]                     # slot -> Player
func load_minigame(id: StringName) -> Minigame           # clear(), instance the registry scene as child "Minigame", spawn_players()
func load_minigame_scene(scene: PackedScene) -> Minigame # same, from any scene whose root extends Minigame
func spawn_players() -> Array[Player]                    # one per Net.roster entry sorted by slot, as Players/P<slot>, FROZEN, authority = PlayerInfo.peer_id, i-th player on spawn point i; sets minigame.players
func get_player(slot: int) -> Player
func clear() -> void
```

```gdscript
class_name Minigame extends Node3D
@export var title: String
@export var rule_text: String                  # one line for the title card
@export var time_limit: float = 60.0           # shown by the round UI; 0 = none. The minigame calls finish() itself when time is up (count it in _host_tick)
signal finished(ranking: Array[int])          # slots, best first
var players: Array[Player]                     # set by Stage before _setup
var knocked_out: Array[int]                    # slots in knock-out order (knock_out)
func get_spawn_points() -> Array[Transform3D]  # Marker3D children of $Spawns; the marker's +Z is the facing
func _setup(players: Array[Player]) -> void    # every peer, players are frozen
func _start() -> void                          # every peer, after the countdown, players unfrozen
func _host_tick(delta: float) -> void          # host only, each physics frame while playing
func finish(ranking: Array[int], grace := 0.0) -> void  # host only; later calls ignored. grace > 0: Session holds PLAYING, every player frozen on every peer, for `grace` s (Session.end_grace) before RESULTS
func is_finished() -> bool
func knock_out(player: Player) -> void         # host only helper: eliminates and records order; when <= 1 is left, finishes with the survivor first, then reverse knock-out order
func get_bot_goal(player: Player) -> Vector3   # where a bot should want to be (default: a random spawn point)
func is_safe(pos: Vector3) -> bool             # bots avoid unsafe positions (default: true)
```

Flow (Session drives it; the sandbox and the test harness do the same offline): Stage spawns frozen players -> `_setup(players)` -> countdown -> `frozen = false` on every player, `_start()` -> `_host_tick(delta)` on the host until `finished`.

A minigame lives in `game/minigames/<id>/` (scene `<id>.tscn` whose root script `<id>.gd` `extends Minigame`, plus its own assets). The placeholder has `WorldEnvironment`, `Sun`, `Camera3D` (fixed, current), `Ground` (20 m, top at y=0) and `Spawns` (8 markers on a 5 m ring, the first four spread out); replace anything but keep `Spawns` with 8 markers. Ids in v1 (`MinigameRegistry.IDS` in `game/minigames/registry.gd`): `floor_is_lava`, `bumper_sumo`, `hot_potato`, `coin_scramble`. A minigame may change player component tuning in `_setup` and must not reach into other systems beyond this contract. The host decides everything that matters (who is out, scores); clients learn it through the minigame's own RPCs.

## Networking rules for minigames (added after player sync landed)

- `Stage` sits at the same node path on every peer; the loaded minigame is `Stage/Minigame` everywhere. `Stage.follow_roster` (lobby: players come and go with the roster) and `Stage.name_tags`. `clear()` on the host clears every client. A player who leaves mid-round is knocked out, then removed, on all peers.
- Decide on the host. `knock_out` / `eliminate` / `respawn_at` called on the host reach every peer by themselves.
- Send any other minigame state (scores, timers, which platform fell, who holds the bomb) with `@rpc("authority", "call_local", "reliable")` functions on the minigame root, called from the host. Moving scenery must be deterministic from a host-sent start time or seed, not simulated separately per peer.
- Tuning changes and visuals go in `_setup` / `_start`, which run on every peer. Never set `frozen`, position or tuning of a client's player on the host only.
- Remote player copies are kinematic obstacles; read `velocity`, `facing`, `control_locked` and `SyncComponent.is_grounded()` on them, never `is_on_floor()`.
- In the lobby, players spawn frozen: whoever loads the lobby unfreezes them on `Stage.players_spawned`.

## Presentation APIs a minigame may call (all safe headless)

- `RoundUI.push_counter(slot, value)`, `RoundUI.push_banner(text, seconds)` (this peer only: call on every peer, e.g. inside your `call_local` RPC).
- `Fx.play(name, at, color)`: `dust_puff`, `land_thud`, `shove_whoosh`, `hit_stars`, `stun_swirl`, `poof`, `respawn_sparkle`, `coin_pickup`, `explosion`, `confetti`, `splash_lava`.
- `Sfx.play(name, at)`, `Sfx.play_loop(name, at) -> id`, `Sfx.stop_loop(id)`: `coin`, `coin_big`, `bomb_tick`, `bomb_fuse_loop`, `explosion`, `platform_crack`, `platform_fall`, `lava_sizzle`, `round_win_jingle`, and the rest in `game/audio/sfx.gd`.
- Look: instance `res://look/stage_look.tscn` and set its `preset`; `Look.apply_toon(model)`; materials in `res://look/materials/` (`lava`, `water`, `void_fade`).
- Camera: instance `res://camera/arena_camera.tscn` (`ArenaCamera`), set bounds; `add_shake(amount)`.
- Player visuals: `VisualsComponent.play_emote(&"cheer" | &"wave" | &"sad")`, `set_expression`.

## Tests

`tools/godot-test.ps1 [-Filter text]` runs every `test_*` method of every `game/tests/test_*.gd` headless at a fixed 60 ticks/s (deterministic step, as fast as the CPU allows). A test file `extends GameTest` (`game/tests/harness.gd`); each test method gets a fresh instance and may `await`. It fails on a failed assert, any engine/script error or `push_error` during the test, or a 60 s timeout.

```gdscript
func spawn_arena(count := 4, minigame_id := &"", scripted := true) -> Array[Player]  # offline roster (slot 0 human, rest bots), dev arena when no id; runs _setup, unfreezes, _start; the harness then calls _host_tick every physics frame
func step(frames := 1, each_frame := Callable()) -> void   # await it; each_frame(i) runs right before tick i (write intents there)
func run_until_finished(max_frames := 5400) -> bool         # await it; true if the minigame finished (then see `ranking`)
func watch(obj: Object, signal_name: StringName) -> Array   # live list of emitted arg arrays
func assert_true / assert_false / assert_eq / assert_near / fail
var stage: Stage; var players: Array[Player]; var ranking: Array[int]
func get_minigame() -> Minigame; func physics_delta() -> float; func before_each() / after_each()  # last two virtual
```

With `scripted = true` (default) controllers leave `intent` alone, so write `player.intent` in `each_frame`. Pass `false` to test human input (`Input.action_press`) or bot brains. Every mechanic ships tests that prove its behaviour through the Player API and events only. `game/dev/sandbox.tscn` (main scene for now) plays offline: `-- --players=N --minigame=<id>`.

## File ownership

| Path | Owner |
|---|---|
| `game/player/components/<name>.*` | that component's system |
| `game/net/` | net, player sync (`game/net/sync/`) |
| `game/session/` | session |
| `game/ui/menu/`, `game/ui/round/`, `game/ui/wardrobe/` | menu UI, round UI, wardrobe UI |
| `game/ui/settings/`, `game/ui/theme/` (theme, `UiMotion`, focus ring) | UI polish |
| `game/cosmetics/` | cosmetics system |
| `game/progression/` | progression (coins, unlocks; `CoinIcon`, `PadlockIcon`, `CoinBalance` for any UI) |
| `game/look/`, `game/fx/` | look and effects |
| `game/audio/` | audio |
| `game/camera/` | arena camera |
| `game/bots/` | bot brain |
| `game/minigames/<id>/` | that minigame |
| `game/lobby/` | lobby |
| `game/assets/models/<family>/`, `art/scripts/<family>/` | that art family |
| `game/tests/test_<system>*.gd` | that system |
| everything listed as orchestrator-owned under "Working rules" | orchestrator |
