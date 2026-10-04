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
- Input actions: `move_left`, `move_right`, `move_forward`, `move_back` (WASD, arrows, left stick), `jump` (Space, A), `action` (E, left mouse, X), `pause` (Esc, Start), `emote_1`..`emote_4` (keys 1-4, d-pad up / right / down / left).
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
| `is_extra: bool` | an NPC extra (see "NPC extras"): slot >= 100, not a player |
| `intent: PlayerIntent` | what the controller wants this tick: `move: Vector2` (world X,Z, length 0..1), `jump_pressed`, `jump_held`, `action_pressed` (bools; `*_pressed` true only on the first tick), `emote: int` (1..4 on the tick an emote key went down, else 0; consumed by the emote component, NOT reset by `clear()`), `clear()` |
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
func set_presentation_hidden(hidden: bool, tags := true, shadow := true) -> void  # this peer only: forwards to FxComponent.set_presentation_hidden (name tag / blob shadow)
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
| `emote` | emote | `id: int` (1 wave, 2 dance, 3 taunt, 4 cry; `EmoteComponent.name_of(id)`); cosmetic, relayed like any event, the host does not validate it |

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
| `team` | `TeamComponent` | teams (Minigame) | team ring under the blob; `set_team(team, color)` (-1 hides), set by `Minigame.assign_teams` on every peer |
| `emote` | `EmoteComponent` | character animator | emote keys -> `emote` event (see "Emotes") |

Controller (human): reads the input actions; `intent.move` is camera-relative (forward = away from the active camera, projected on XZ), expressed in world X,Z. `*_pressed` are edges of the held state. `scripted: bool` (tests): when true the controller leaves `intent` alone. The human controller in `controller.gd` belongs to the skeleton; the bot agent does not edit it.

Bot brain (bot agent): `game/bots/bot_brain.gd`, `extends Node`, `var player: Player` (set before it enters the tree), `func fill_intent(intent: PlayerIntent, delta: float) -> void`. When that file exists, the controller of every bot instances it as its child `BotBrain` and calls `fill_intent` each tick on the authority (the host). Without it bots stand still. The brain reads the world through the Player API (including the player's own `jump` / `movement` tuning and capsule), ray probes against the `world` layer, and `Minigame.get_bot_goal` / `is_safe`, plus the optional minigame hints and hooks in "Bot hooks" below. `ControllerComponent.scripted` is a test seam only (a test or dev check driving a human slot with its own brain); minigames never set it.

### Bot hooks (all optional, duck-typed on the Minigame; looked up once per minigame)

| Hook / hint | Polled | Meaning |
|---|---|---|
| `var bot_aggression_scale: float` (0..1, 1) | each think | how often bots chase; 0 = never shove by default |
| `var bot_skill_scale: float` (0..1, 1) | per minigame | bots play this minigame with `skill` x this: more misjudgements (late probes, aim and take-off errors, stale lines), not slower legs |
| `var bot_reaction_scale: float` (1) | each roll | multiplies the hold and action reaction delays (a clock that runs faster in tests) |
| `var bot_extra_hooks: bool` (false) | per minigame | NPC extras (`is_extra`) poll the action hooks too; otherwise extras never do |
| `func bot_should_hold(player) -> bool` | every tick, every brain | true: the brain fills an EMPTY intent. A change of the answer is noticed after the bot's hold reaction (`BotBrain.HOLD_STOP` / `HOLD_GO` by skill + jitter): late to stop, late to go; the first answer after `configure` applies at once. Released: a fresh plan |
| `func bot_wants_action(player) -> bool` | each think (+ once right after a press's cooldown) | yes = start an act: after the action reaction (`ACTION_REACTION` by skill) press `action` for one tick. **Present = it decides every press**: the default shove (enemy in front, in range, never with an ally in front) only runs for minigames without this hook. A no at a later think ends the act |
| `func bot_aim(player) -> Vector3` | every tick of an act | world point to face before the press (`Vector3.ZERO` = no preference). The brain steers a short stick toward it (facing follows movement), with an aim error per act (`ACT_AIM_ERROR_DEG` by skill), and presses once the facing held within `AIM_TOLERANCE_DEG` for `AIM_SETTLE` |
| `func bot_action_reach() -> float` | per act | > 0: first walk to within this distance of the aim point (an extra-mode stroller at a brisk stroll) |
| `func bot_action_cooldown() -> float` | per press | no new act for this long (at least 0.25 s) x 1..1.25 |

Jumps need no hook: the brain probes ahead while running and jumps onto ledges up to its apex (minus 0.15 m) with safe ground on top and across holes `is_safe` says nothing about when the far side is in range, holds for full height, does not hop at walls it cannot clear and stops at holes it cannot jump. `is_safe`-marked gaps keep the older gap jump (with a skill-based take-off error).

Skill: `BotBrain.difficulty` (static, 0.5 default; host-wide, no UI yet) maps onto the range rolled skills land in (`skill_range`: 0 -> 0.05..0.55, 0.5 -> 0.35..0.95, 1 -> 0.7..1.0); an explicit `configure(seed, skill)` keeps its skill. `BotBrain.of(p)`: `is_held()`, `reaction_time()`, `is_acting()`, `skill`.

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
- Modifiers (game modes): `set_modifier(source, stats: Dictionary, body_scale := 1.0)` / `clear_modifier(source)` / `has_modifier(source)` add multipliers that compose with the size factor through the same base bookkeeping (`stats` keys `"<component>:<property>"`, any float property, e.g. `"jump:time_to_apex"`); like size factors they are 1 while `frozen`, the body scale is not; clearing restores the base exactly. Mutators use the source `&"mutator"`.
- Tuning: multiplies `movement.max_speed`, `jump.jump_height`, `shove.force`, `shove.reach`, `shove.width`, `status.knockback_multiplier` (the catalog gives shove/knockback as felt slide distance; the impulse gets the square root). It remembers the value it wrote; any other value (a minigame's write) becomes the new base, then `base * factor` is written back. Factors are 1 while `frozen`, so `_setup`/`_start` read and write base values. `SizeComponent.base_of(component, property)` gives the base.
- Minigames: set tuning to absolute values (from what you read in `_setup`/`_start`), per frame if you like; never `*=` mid-round (the factor would compound).
- Override: `set_size_override(id: String, snap := false)` / `clear_size_override(snap := false)`, `size_override` ("" = none): the blob is that size for looks, capsule AND tuning factors until cleared (`player.loadout` untouched; set it on every peer). Order: loadout size -> override (replaces the loadout size while set) -> modifiers (multiply on top, also under an override: Masquerade under `giant` = everyone identical and giant); body scale = size scale x modifier scales, a stat = base x size factor x modifier factors; any set / clear order restores exactly. See "Minigame hooks".
- Art scripts: `art/scripts/character/`, `art/scripts/cosmetics/`, `art/scripts/env/`, `art/scripts/props/`, all through `artlib` (multi-part: `finalize`, `empty`, `set_parent`, `from_godot`, `export_glb(name, family="character")`).

## Autoloads

| Name | Owner | API (signals in italics) |
|---|---|---|
| `Net` | net | `host_game(game_name: String) -> Error`, `join_game(address: String) -> Error`, `start_offline()`, `leave()`, `start_discovery()`, `stop_discovery()`, `is_host() -> bool`, `local_slot() -> int` (-1 if none), `roster: Dictionary[int, PlayerInfo]` (slot -> `PlayerInfo{slot, peer_id, name, is_bot, loadout}`, `game/net/player_info.gd`; `peer_id` is the simulating peer: the owner, or the host (1) for bots), `add_bot() -> int` (slot, -1 if full), `remove_bot(slot)`, `set_local_profile(player_name, loadout)`, `MAX_PLAYERS = 8`, `DEFAULT_PORT = 24565`; *`roster_changed`*, *`games_found(games: Array)`*, *`join_failed(reason: String)`*, *`server_closed`*. Offline: this peer is 1 and the local human is slot 0 |
| `Session` | session | `start_session(rounds: int)` (host), `state: State`, `scores: Dictionary[int, int]` (slot -> points), `round_index` (0-based, -1 before the first), `round_count`, `current_minigame: Minigame`, `round_groups: Array` (last round's tied groups); *`state_changed(state: State)`*, *`round_intro(info: Dictionary, index: int)`* (info: `{id, title, rule_text}`), *`round_started`*, *`round_finished(ranking: Array[int], points: Dictionary)`* (flat), *`round_ranked(groups: Array, points: Dictionary)`* (right after, as tied groups), *`session_finished(final_ranking: Array[int])`*. `enum State { LOBBY, INTRO, PLAYING, RESULTS, PODIUM, VOTE }` (VOTE: game modes, see "Game modes") |
| `Cosmetics` | cosmetics system | `catalog(slot: StringName) -> Array`, `default_loadout(slot_index: int) -> Dictionary`, `load_profile() -> Dictionary` (`{name, loadout}`), `save_profile(player_name, loadout)`, `apply(model_root: Node3D, loadout: Dictionary)` (items and colours; not the size), `sizes() -> Array`, `size_info(id) -> Dictionary`, `sanitize(loadout, fallback_slot)` |
| `Fx` | look and effects | `play(effect: StringName, at: Vector3, color := Color.WHITE)` |
| `Sfx` | audio | `play(sound: StringName, at := Vector3.INF)` |
| `Music` | audio | `play(track: StringName, fade := 1.0)` (cross-fade; same track = no-op), `stop(fade := 1.0)`, `play_sting(track)` (one-shot over the music), `duck(amount: float, seconds: float)`, `set_volume(linear)` / `get_volume()` (bus `Music`), `current`; *`track_changed(track)`*. Tracks `Music.TRACKS` (`res://audio/music/*.ogg`). `game/audio/music_director.gd` (instanced in the main scene) picks them: title, lobby, round by the minigame's StageLook preset, results sting, podium. Any minigame may declare `var music_track: StringName` (`&"none"` = silence from GO: the title card still gets its StageLook preset's track; for minigames whose own sound is the round music); VOTE plays `lobby_waltz` ducked with a `countdown_beep` on each of the last 3 s or call `Music.stop()` / `play()` from `_start()` on; the director only acts again at the next phase (RESULTS) |
| `Progression` | progression | Mansion Coins of the local player, saved in its own profile; every peer pays itself from the Session signals (nothing networked; bots never earn; half rate offline and with fewer than 2 humans: `is_half_rate()`). `coins`, `stats`, `award(reason: StringName, amount: int, once := true) -> int` (one-time per reason by default, e.g. the tutorial's `award(&"tutorial", 20)`), `is_unlocked(slot, id)` (wardrobe gate only), `unlock(slot, id) -> bool`, `price(slot, id)`, `dev_unlock_all()` / `--unlock-all` (testing); *`coins_changed(total)`*, *`awarded(reason, amount, total)`*, *`unlocks_changed(slot, id)`* |
| `Settings` | UI polish (`game/ui/settings/settings.gd`; screen `settings.tscn`) | The player's options, `user://settings.json`, applied at startup: `master_volume`, `music_volume`, `sfx_volume`, `ui_volume` (0..1 -> buses Master / Music / Sfx / Ui), `fullscreen`, `window_size`, `quality` ("low"/"medium"/"high" -> `Look.set_quality`; auto-detected from the GPU on first run, `--quality=` overrides), `show_fps`, and the comfort flags **`screen_shake: bool`** (false: no camera shake) and **`reduced_motion: bool`** (calmer animations); `set_value(key, value)`, *`changed(key)`*. Other systems read the flags without a hard dependency: `get_tree().root.get_node_or_null(^"Settings")` then `.screen_shake` / `.reduced_motion` |

`Net` details (added after wave 1):
- `join_game` accepts `"ip"` or `"ip:port"`. `join_failed` reasons are exactly `timeout`, `full`, `in progress`, `version mismatch`, `could not connect`.
- `games_found` entries: `{id, address ("ip:port", pass it to join_game), ip, port, game_name, host_name, players, max_players, in_lobby, version, compatible}`.
- `session_in_progress: bool` (host sets, clients receive) and `accept_late_joiners: bool` (default false: joins during a session are refused with `in progress`). `Session` sets `session_in_progress` at session start and clears it when it returns to LOBBY.

`Session` details (added after wave 1): also public `abort_session()`, `round_wins`, `phase_duration`, `phase_time_left` (UI derives countdowns from these), `end_grace` (seconds left of a minigame's end grace, 0 = none; see `finish`). Each transition emits `state_changed` first, then its event signal. On time-out survivors share first place (one tied group). Returning to LOBBY clears the stage.

`Session` ties (v0.3): `round_finished(ranking, points)` is unchanged and keeps the FLAT order (tied groups flattened, best first). Right after it, *`round_ranked(groups: Array, points: Dictionary)`* carries the same ranking as tied groups (Array of `Array[int]`, best first), and `round_groups` holds them on every peer from RESULTS until the next round's intro (empty in LOBBY). Scoring: every member of a group scores the group's best place (`place_points`), the next group's place counts the tied players (1, 1, 3); every member of the first group gets a round win; the final ranking is unchanged (total, wins, slot). Static helpers: `points_for_groups(groups, player_count := -1)`, `points_for_ranking(ranking, tied_top := 1, player_count := -1)` (same code path), `groups_from_sizes(flat, sizes)`. `Progression.round_place(ranking, points, slot, groups := [])` pays the tied place (it reads `Session.round_groups` itself).

Autoload scripts (paths fixed by project.godot; the owner edits the file, never the path): `game/net/net.gd`, `game/session/session.gd`, `game/cosmetics/cosmetics.gd`, `game/fx/fx.gd`, `game/audio/sfx.gd`, `game/audio/music.gd`, `game/progression/progression.gd`, `game/ui/settings/settings.gd`. Plain `extends Node` scripts without `class_name`; add child nodes from code if needed. `AgentScreenshot` (`game/tools/screenshot.gd`) is tooling.

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
signal finished(ranking: Array[int])          # slots, best first (tied groups flattened)
var players: Array[Player]                     # set by Stage before _setup
var knocked_out: Array[int]                    # slots in knock-out order (knock_out)
func get_spawn_points() -> Array[Transform3D]  # Marker3D children of $Spawns; the marker's +Z is the facing
func _setup(players: Array[Player]) -> void    # every peer, players are frozen
func _start() -> void                          # every peer, after the countdown, players unfrozen
func _host_tick(delta: float) -> void          # host only, each physics frame while playing
func finish(ranking: Array, grace := 0.0) -> void  # host only; later calls ignored. Entries: a slot or an Array of slots (a tied group), e.g. [3, [1, 2], 0]. grace > 0: Session holds PLAYING, every player frozen on every peer, for `grace` s (Session.end_grace) before RESULTS
func is_finished() -> bool
func knock_out(player: Player) -> void         # host only helper: eliminates and records order; when <= 1 is left, finishes with the survivor first, then reverse knock-out order
func get_bot_goal(player: Player) -> Vector3   # where a bot should want to be (default: a random spawn point)
func is_safe(pos: Vector3) -> bool             # bots avoid unsafe positions (default: true)
```

Flow (Session drives it; the sandbox and the test harness do the same offline): Stage spawns frozen players -> `_setup(players)` -> countdown -> `frozen = false` on every player, `_start()` -> `_host_tick(delta)` on the host until `finished`.

A minigame lives in `game/minigames/<id>/` (scene `<id>.tscn` whose root script `<id>.gd` `extends Minigame`, plus its own assets). The placeholder has `WorldEnvironment`, `Sun`, `Camera3D` (fixed, current), `Ground` (20 m, top at y=0) and `Spawns` (8 markers on a 5 m ring, the first four spread out); replace anything but keep `Spawns` with 8 markers. Ids in v1 (`MinigameRegistry.IDS` in `game/minigames/registry.gd`): `floor_is_lava`, `bumper_sumo`, `hot_potato`, `coin_scramble`. A minigame may change player component tuning in `_setup` and must not reach into other systems beyond this contract. The host decides everything that matters (who is out, scores); clients learn it through the minigame's own RPCs.

### Teams, ties and roles (v0.3, on `Minigame`)

```gdscript
var finish_groups: Array                       # host: what finish() got, normalised: Array of Array[int] groups, best first
static func normalize_ranking(ranking: Array) -> Array    # slots / slot Arrays -> groups (repeats keep their first place, empty groups dropped)
static func flatten_groups(groups: Array) -> Array[int]
static func group_place(groups: Array, slot: int) -> int  # 1-based tied place (1, 1, 3), 0 if absent
signal teams_changed                           # every peer, when an assignment arrives
var teams: Dictionary[int, int]                # slot -> team (0-based), every peer; empty = no teams
var team_count: int                            # 0 = no teams
func assign_teams(team_count := 2) -> void     # host only (ignored elsewhere): living players, random, sizes differ by <= 1 (the odd ones land on random teams), 2..4 teams; one reliable call_local RPC to every peer
static func split_teams(slots: Array[int], count: int) -> Dictionary[int, int]  # the pure split
func has_teams() -> bool
func team_of(slot: int) -> int                 # -1 if none
func team_slots(team: int) -> Array[int]       # ascending
static func team_color(team: int) -> Color     # 0 orange #e69f00, 1 sky blue #56b4e9, 2 green #009e73, 3 pink #cc79a7 (Okabe-Ito; not player colours)
static func team_name(team: int) -> String     # "ORANGE", "BLUE", "GREEN", "PINK"
func finish_teams(team_order: Array[int], grace := 0.0) -> void  # host: each team is one tied group, best first; unlisted teams follow by index, then players without a team as one group
func is_ally(a: Player, b: Player) -> bool     # same team (false without teams)
signal role_changed(slot: int, text: String)   # every peer
var roles: Dictionary[int, String]             # slot -> role line, every peer
func set_role_text(slot: int, text: String) -> void  # host only: the full line that player sees, e.g. "You are the SEEKER" ("" clears); reliable call_local RPC
func role_of(slot: int) -> String
```

- Call `assign_teams` / `set_role_text` on the host in `_setup` (or later; clients get them a moment after the intro starts, the UI follows). Teams and roles live on the minigame instance: the next round's minigame starts without, and the team rings clear when the minigame leaves the tree.
- Shown automatically: a ring in the team colour under each blob (`team` player component, `TeamComponent`, `game/player/components/team.*`), the HUD strip grouped in team-coloured boxes, "TEAM ORANGE" plus the role line on the local player's intro card, the role line as a banner ~1 s after GO!, and on the results a team (or any tied group) on one line with its shared place and "+N EACH".
- Bots: the bot brain must not shove allies: before shoving, skip a target when `minigame.is_ally(player, target)` (owner: bot brain; `game/bots/` is not wired yet).
- Roles themselves (who seeks, what each role may do) are the minigame's own business.

## Game modes (v0.3, A3/A4; owner: modes, `game/modes/`)

Host setup, replicated to every peer (lobby too, and to joiners): `Session.configure(rounds, order, ticked: Array, mutators)` -> `setup_rounds`, `order_mode` (`GameModes.Order` SHUFFLE / PLAYLIST / VOTE), `playlist: Array[StringName]` (ticked ids; Playlist and Vote draw from them; empty = all), `mutator_mode` (`Mutators.Mode` OFF / SOMETIMES (25 %) / ALWAYS); *`setup_changed`*. `start_session(rounds)` uses it. Every mode only draws minigames that fit the player count (`MinigameCatalog` min/max). The lobby's Game setup panel (`game/ui/menu/game_setup_panel.gd`) drives it and saves the host's choice in `user://game_setup.json`. Dev args: `--order=`, `--playlist=a,b`, `--mutators=`, `--mutator=<id>`.

- `MinigameCatalog` (`game/modes/minigame_catalog.gd`): `info(id) -> {id, name, kind, kind_name, min, max, rule, color, known}` without loading scenes; unknown ids fall back (name from the id, kind `party`, 2-8). Add a new minigame's row there (or it still works with the fallback).
- VOTE: before each round Session enters `State.VOTE` (players frozen): `vote_candidates` (3), `vote_marks` (slot -> card), `vote_locked`, `vote_index`, `vote_winner`; *`vote_started(candidates, index)`*, *`vote_updated`*, *`vote_decided(winner, id)`*, then the winner's INTRO. Any peer: `Session.vote(index, lock := false)` for its own player (the host validates); bots vote at random; most marks win, ties random; `vote_time` (8 s, ends early when all locked) + `vote_reveal_time`. The cards are `ModesOverlay` (a CanvasLayer Session adds on every peer).
- Mutators (`Mutators`, `Mutator` resource: `id`, `display_name`, `card_line`, `stats`, `body_scale`, `mirror`, `color`): `low_gravity`, `giant`, `tiny`, `turbo`, `slippery`, `super_shove`, `heavy`, `mirror`. The host rolls one per round from the minigame's allowed set and sends it with the INTRO; every peer applies it to every player (size component modifier; `mirror` swaps this peer's `move_left`/`move_right` events) and takes it off at RESULTS. `Session.round_mutator`, *`mutator_changed(id)`*, `round_intro` info gains `mutator`, `mutator_line` and `practice`. Shown on the intro card (sticker) and as a HUD badge.
- Minigame side: optional `var mutator_blocklist: Array[StringName] = [...]` declared in the minigame script (NOT on the base class; Session reads the script default before the round, so do not compute it in `_setup`). `Minigame.active_mutator` (every peer) and the virtual `_mutator_changed(id)` (every peer) for minigames with their own physics. Tuning set in `_setup` composes automatically (it becomes the base).
- Practice: `Session.start_practice(id, mutator := &"")` (host, LOBBY): one round through INTRO / PLAYING / RESULTS with `Session.practice = true` on every peer, all points 0, totals unchanged, no coins or stats (Progression skips practice rounds), then straight back to LOBBY (no PODIUM).
- Late joiners: `_rpc_snapshot` carries `snapshot_extra()` (practice, mutator, vote state); players a client spawns after the INTRO get the round's mutator.

## Networking rules for minigames (added after player sync landed)

- `Stage` sits at the same node path on every peer; the loaded minigame is `Stage/Minigame` everywhere. `Stage.follow_roster` (lobby: players come and go with the roster) and `Stage.name_tags`. `clear()` on the host clears every client. A player who leaves mid-round is knocked out, then removed, on all peers.
- Decide on the host. `knock_out` / `eliminate` / `respawn_at` called on the host reach every peer by themselves.
- Send any other minigame state (scores, timers, which platform fell, who holds the bomb) with `@rpc("authority", "call_local", "reliable")` functions on the minigame root, called from the host. Moving scenery must be deterministic from a host-sent start time or seed, not simulated separately per peer.
- Tuning changes and visuals go in `_setup` / `_start`, which run on every peer. Never set `frozen`, position or tuning of a client's player on the host only.
- Remote player copies are kinematic obstacles; read `velocity`, `facing`, `control_locked` and `SyncComponent.is_grounded()` on them, never `is_on_floor()`.
- In the lobby, players spawn frozen: whoever loads the lobby unfreezes them on `Stage.players_spawned`.

## NPC extras (v0.3, A2)

Bot-driven blobs that are not players, for crowds and dummies. Full `Player` scenes with `is_extra = true` and `is_bot = true`, slots `Stage.EXTRA_SLOT_BASE` (100) and up, nodes `Stage/Extras/X<slot>`, authority the host. They are NOT in `Net.roster`, `Stage.players`, `Minigame.players` or `players_spawned`, so nothing that counts players sees them: Session (it also drops non-roster slots from any ranking), HUD, results, Progression, Feel, the arena camera and name tags.

```gdscript
# Stage
const EXTRA_SLOT_BASE := 100
const MAX_EXTRAS := 256
signal extras_spawned(extras: Array[Player])   # every peer (host: spawn_extras, once per call / batched run; clients: manifest, once its new extras are built)
var extras: Array[Player]                      # slot order
@export var extra_name_tags := false           # extras get a NameTag too (set before spawning)
func spawn_extras(count: int, loadouts: Array[Dictionary] = [], spawn_xforms: Array[Transform3D] = [], batch := 0) -> Array[Player]
func flush_extras() -> Array[Player]           # host: builds what a batched run still has queued, now
func is_spawning_extras() -> bool              # a batched run (host) or manifest extras (client) still building
func despawn_extras() -> void
func get_extra(slot: int) -> Player            # null if none
func get_body(slot: int) -> Player             # player or extra by slot (use it for slots from events)
static func is_extra_slot(slot: int) -> bool
static func default_extra_loadout(slot: int) -> Dictionary
func default_extra_xform(index: int, total: int) -> Transform3D
```

- `spawn_extras` / `despawn_extras`: host (or offline) only; on a client they do nothing (`[]`). Call `spawn_extras` from `_setup` (it runs on every peer; clients get the extras from the host's manifest a moment later, `extras_spawned` tells them). Missing `loadouts[i]` = a muted crowd colour, missing `spawn_xforms[i]` = a sunflower spiral 2.5-8 m around the minigame origin. Slots continue after the existing (and queued) extras. Extras are freed with the stage (`clear()`, the next load).
- Batches: building ~20 blobs in one frame stalls a peer ~0.7 s (enough to drop ENet clients while a round loads). `batch > 0` builds that many per frame (the first batch at once), returns `[]`, emits `extras_spawned` once with all of them and only then sends the manifest; configure brains in `extras_spawned`. `batch` 0 (default) builds all now and returns them. If play must start before a run is done (very short intro, tests), call `flush_extras()` in `_start`. Clients build manifest extras that arrive over the network `Stage.CLIENT_EXTRA_BATCH` (4) per frame. `despawn_extras` / `clear` drop a queued run.
- Extras spawn **unfrozen** and Session never freezes or unfreezes them (they mill about through the countdown and the end grace). A minigame that wants them still sets `frozen` on the host. A frozen blob ignores impulses.
- Brains: `BotBrain.of(x).configure_extra(mode, seed, center := Vector3.INF)`, `mode` `&"wander"` (default: walk between random safe points within `wander_radius` (4 m) of where it stood, pausing 0.8-3 s), `&"dance"` (loose circles around `center`; give a group one centre) or `&"idle"`. Deterministic per seed (default seed `slot * 7919 + load id`); extras never shove or jump, keep a little personal space, avoid `is_safe() == false` ground, pause after a knock. Host only (it simulates them).
- Hits: extras are normal shove targets (knockback, stun, `got_hit`, `shove_hit(victim_slot >= 100)`). What a hit on an extra means is the minigame's business: check `victim.is_extra` / `Stage.is_extra_slot(slot)`. The host may `eliminate()` / `respawn_at()` an extra; `knock_out(extra)` only eliminates it (never recorded in `knocked_out`, never ends the round). Hit effects (`FxComponent.slot_color`) use the extra's own colour; RoundUI hides opted-in extra tags with the players' during results.
- Bots ignore extras (they are not in `Minigame.players`), though a shove may hit one in passing.
- Camera: `ArenaCamera.include_extras` (default false) adds living extras to FRAME_ALL.
- Name tags: none by default (`Stage.extra_name_tags` opts in; `NameTag.show_extras`).
- Sync: one compact unreliable packet per tick from the host with every extra (26 bytes each, `SyncHub.pack_extras`; 20 extras = 520 bytes, about 14 KB/s per client measured), played back exactly like a bot. Events and impulses as for players.
- Cost (8 players + 20 extras, dev arena, 1280x720): about 0.12 ms (Low) to 0.19 ms (High) of frame time and 5-9 draw calls per wandering extra, close to a player's ~0.17 ms. `game/stage/dev/run_extras_perf.ps1` measures it; `res://stage/dev/extras_sandbox.tscn -- --players=8 --extras=20 [--extras-mode=dance] [--minigame=<id>] [--extras-camera]` shows it.

Bots and teams: `Minigame.is_ally(a: Player, b: Player) -> bool` (override it for custom alliances): bots never chase an ally and never shove while an ally is in front of them. Feel celebrates every member of a tied winning group (`Session.round_groups[0]`, e.g. a team) under one widened spotlight.

## Presentation APIs a minigame may call (all safe headless)

- `RoundUI.push_counter(slot, value)`, `RoundUI.push_banner(text, seconds)` (this peer only: call on every peer, e.g. inside your `call_local` RPC).
- `Fx.play(name, at, color)`: `dust_puff`, `land_thud`, `shove_whoosh`, `hit_stars`, `stun_swirl`, `poof`, `respawn_sparkle`, `coin_pickup`, `explosion`, `confetti`, `splash_lava`.
- `Sfx.play(name, at)`, `Sfx.play_loop(name, at) -> id`, `Sfx.stop_loop(id)`: `coin`, `coin_big`, `bomb_tick`, `bomb_fuse_loop`, `explosion`, `platform_crack`, `platform_fall`, `lava_sizzle`, `round_win_jingle`, and the rest in `game/audio/sfx.gd`.
- Look: instance `res://look/stage_look.tscn` and set its `preset`; `Look.apply_toon(model)`; materials in `res://look/materials/` (`lava`, `water`, `void_fade`).
- Camera: instance `res://camera/arena_camera.tscn` (`ArenaCamera`), set bounds; `add_shake(amount)`; `include_extras` to frame NPC extras too.
- Player visuals: see "Player visuals API" below.

### Player visuals API (`VisualsComponent`, `player.get_component(&"visuals")`; local to the peer that calls it, safe headless)

```gdscript
func play_emote(emote: StringName, loop := false) -> bool  # VisualsComponent.EMOTES: cheer, wave, sad, dance, taunt, cry, victory, clap_nod, clap, sulk
func stop_emote() -> void
func get_emote() -> StringName
func play_result_pose(place: int, total: int) -> StringName  # 1st victory (jumps, spins), last of 2+ sulk, 2nd/3rd clap_nod, others clap; loops; place < 1 stops
func set_carry_pose(kind: StringName) -> bool               # &"overhead", &"front", &"none"; stays until changed
func get_carry_pose() -> StringName
func play_throw() -> void                                    # wind up, fling, follow through; ends the carry pose
func get_carry_point() -> Vector3                            # world point where the carried thing sits (follows the animation and the hat)
func set_interest_point(point: Vector3, strength := 1.0) -> void  # eyes and body turn to it; feed it every frame or so, fades ~0.6 s after the last call
func set_panic(seconds: float) -> void                       # panic-run arms while running (a hazard nearby)
func set_look_target(target: Variant) -> void                # Node3D, world Vector3 or null
func set_expression(name: StringName, seconds := -1.0) -> bool  # BlobExpressions preset; &"" releases
func get_reaction() -> StringName / get_expression() / get_action()  # what shows now (tests)
```

- Podium / results (done, nothing to call): on PODIUM the round UI puts up a 3D podium (`RoundPodiumStage`, `game/ui/round/podium_stage.gd`) on every peer as a child of the Stage's last minigame, 60 m above it, with its own camera; the host respawns the top three onto its blocks and everyone else beside it (`respawn_at`, players stay frozen), and every peer calls `play_result_pose(place, total)` for each blob's FINAL place (players with the same total and round wins share the group's place and pose; a tied last group sulks together), `stop_emote()` when the podium closes. On RESULTS Feel cheers the round winners (`Session.round_groups[0]`) and makes the last group sulk, and stops both when the phase moves on.
- Carrying: a minigame calls `set_carry_pose` / `play_throw` on every peer (inside its `call_local` RPC) and may place the item at `get_carry_point()`.
- Automatic (nothing to call): run starts, skids (`Fx.play(&"dust_puff")`), banking, panic after a knock, backpedal, apex tuck, knockback spin, heavy landings, ledge teeter, idle fidgets, sleeping after 20 s in the lobby, flinch / gloat / wince, looking at the fastest blob nearby. `Settings.reduced_motion` calms them; at LOW quality blobs further than 14 m from the camera skip fidgets and the face; NPC extras run a reduced set.

### Emotes

`EmoteComponent` (`game/player/components/emote.*`), in its post_tick on the authority: `intent.emote` (1..4, consumed) -> `player.emit_event(&"emote", [id])` -> every peer's visuals play it. Rules on the authority: one emote per 0.8 s (`cooldown`); none while stunned (`control_locked`) or dead; none while `frozen`, except in the lobby and on the podium (`Session.State.LOBBY` / `PODIUM`). The visuals cancel a player emote on movement, a jump, a shove or a knockback (an emote started with `play_emote` is not cancelled by movement, and a looping one resumes after a player emote). `request(id) -> bool` asks from code. Bots (not extras) emote now and then while standing still in the lobby hall (`EmoteComponent.is_lobby(player)`: Session LOBBY and the Stage `follow_roster`) and sometimes after winning a round.

## Minigame hooks (disguises, stuns, crowds, holds, silence)

Use these instead of reaching for node names, rewriting other components' output every frame or swapping tuning. Presentation hooks act on the peer they are called on: call them on every peer (`_setup`, `_start`, a `call_local` RPC). Every one is undone by its clear call, and each minigame clears what it set on every exit path (round over, stage clear: a child node's `_exit_tree` is a safe place).

```gdscript
# CosmeticsComponent (cosmetics): show another look; player.loadout and the roster stay untouched
func set_look_override(look: Dictionary) -> void   # a loadout dict (colours, items; `size` ignored); {} clears
func clear_look_override() -> void                 # the real loadout comes back
func has_look_override() -> bool
func shown_look() -> Dictionary                    # override if set, else player.loadout
# SizeComponent (size): force a size for looks, capsule and tuning factors
func set_size_override(id: String, snap := false) -> void   # "small" | "normal" | "big"; "" clears; snap: no scale ease
func clear_size_override(snap := false) -> void
# NameTag (round UI)
var suppressed: bool                               # hidden on purpose; shows again (if alive) when cleared
var raise: float                                   # extra metres above the head for something carried over it (Hot Potato's bomb, Crown Keeper's crown); 0 = none
static func of(p: Player) -> NameTag               # the tag over p, found by class (null if none)
# FxComponent (look and effects)
var shadow_hidden: bool                            # blob shadow hidden on purpose
static func set_presentation_hidden(p: Player, hidden: bool, tag := true, shadow := true) -> void
static func shown_look(p: Player) -> Dictionary
# StatusComponent (knockback): authority only, no-op elsewhere
func stun(seconds: float, source: Player = null) -> void
func stun_source() -> Player
# BotBrain (bot brain)
func is_held() -> bool
func reaction_time() -> float                      # this bot's skill-based reaction delay (s)
```

- Disguise colours: the fx component tints whooshes, poofs, rings and the hit stars a blob causes with its shown look (`FxComponent.primary_color()`, `slot_color(slot)`), so a disguised player's shove looks exactly like an NPC extra's whose loadout is the same look (an NPC fakes a shove with a plain `emit_event(&"shove_started")`).
- Stun: locks control for exactly `seconds` (extends a running stun, never shortens it, not capped by `stun_chain_max`), raises `stunned(seconds)` through `emit_event`, so every peer sees it. Ignored while invulnerable, frozen or dead. To knock and stun: `stun()` first, then `apply_impulse()`: the impulse's own shorter stun is absorbed and `stunned` comes once.
- Bot hold: a minigame may define `func bot_should_hold(player: Player) -> bool`; every brain (bots, extras, test brains) polls it each tick and, once it has noticed the answer (its own skill-based hold reaction; see "Bot hooks"), fills an empty intent while held (no move, jump or action: no wandering, personal-space nudges, hops or shoves; knockback still moves the blob). Answer with the plain rule (Statue Garden: WARNING or RED); do not add reflex delays of your own. On release the brain re-plans by itself.
- Silence: any minigame may declare `var music_track := &"none"` (the director plays the StageLook preset's track under the title card, so no intro is silent, and fades it out within 0.4 s at GO: nothing through PLAYING); do not take the music over in `_start` just to silence it.
- Special actions are hooks too: a minigame never drives a bot's intent itself. Masquerade's hunts, Snowball Fight's scoops and throws and Hide and Sneak's pokes answer `bot_wants_action` / `bot_aim` (/ `bot_action_reach`), and the press reaches the minigame exactly like a human's `action`.

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
| `game/modes/`, `game/ui/menu/game_setup_panel.*` | game modes |
| `game/assets/models/<family>/`, `art/scripts/<family>/` | that art family |
| `game/tests/test_<system>*.gd` | that system |
| everything listed as orchestrator-owned under "Working rules" | orchestrator |
