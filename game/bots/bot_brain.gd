class_name BotBrain
extends Node
## The bot brain: fills the same PlayerIntent a human controller would.
## The bot's ControllerComponent instances this script as its child `BotBrain` and calls
## `fill_intent` every tick on the authority (docs/contract.md "Bot brain").
##
## It knows nothing about specific minigames. It reads the world only through the Player
## API (positions, `alive`, `facing`, `velocity`, `is_on_floor`, the `got_hit` signal), the
## player's own jump / movement tuning and collision capsule, physics ray probes against the
## world layer, and the generic Minigame hooks `get_bot_goal(player)`, `is_safe(pos)` and the
## optional `bot_rethink_requested` signal (raised by `Minigame.request_bot_rethink`).
##
## A small state machine: GOAL (walk to the minigame's goal), WANDER, CHASE (a player near
## the goal or in the way), RECOVER (after a knock, or when the ground underfoot turned
## unsafe). On top, every tick: a safety filter samples `is_safe` ahead (from where the
## bot's momentum takes it) and steers along the safe boundary, jumps a small gap, or runs
## for a safe spot found in a widening search (never freezes); personal space keeps bots
## from piling up; a shove check presses `action` when a player is in front within range; a
## jump check hops when the bot is stuck against something. A bot that sees the ground
## turn unsafe right under its feet a few times learns the floor wears out and hops along.
##
## Jumps (physics probes, every PROBE_INTERVAL while running on the floor): a ray at knee height
## finds a wall ahead and a ray down onto it finds its top. A ledge up to the jump apex (from the
## player's own `jump.jump_height` / `time_to_apex`, so size and mutators count) with safe ground
## on top is jumped onto from a running take-off timed to clear it (held for full height); a
## higher one is not hopped at (the bot side-steps and re-plans). Rays down ahead find holes the
## minigame's `is_safe` says nothing about: one the bot can clear at its speed (the far side up to
## the apex, the width up to its jump range) is jumped from its edge; a wider one stops the bot at
## the edge. Low skill: later probes, take-off timing error, a short (missed) jump now and then.
##
## Goals: the bot keeps its goal until it is reached, turns unsafe, gets stale (a few
## seconds), or the minigame calls `request_bot_rethink` (after the bot's reaction delay).
## `get_bot_goal` is called only then, so a goal function may be random or stateful.
##
## Human-like imperfection: decisions are only re-made every "think" (a random interval,
## slower for low skill), which is also the perception delay for chase targets and goals;
## aim error per think; reaction delays before shoving and before reacting to unsafe
## ground; a per-bot personality from the seed. Rolled skills land in `skill_range(difficulty)`
## (`BotBrain.difficulty`, host-wide, 0.5 by default).
## Deterministic for a given seed: all randomness comes from its own RandomNumberGenerators.
##
## Optional minigame hint: a minigame may declare `var bot_aggression_scale: float` (0..1,
## default 1). It scales how often bots chase, and at 0 they never shove (the lobby: calm).
## Optional hint `var bot_reaction_scale: float` (default 1): multiplies the hold and action
## reaction delays (a minigame whose clock runs faster in tests).
## Optional hint `var bot_skill_scale: float` (0..1, default 1): the skill every bot plays this
## minigame with is `skill` x this (an unforgiving course: more mistakes, not slower legs).
## Optional minigame hook: `func bot_should_hold(player: Player) -> bool`, polled every tick by
## every brain (bots, extras, test brains). While the brain holds it fills an EMPTY intent: no
## move, jump or action, no wandering, personal-space nudges, hops or shoves (status knockback
## still moves the blob). A change of the answer is noticed after this bot's hold reaction
## (HOLD_STOP / HOLD_GO by skill, plus jitter): it is late to stop and late to go again; the
## first answer after `configure` / `configure_extra` applies at once. Released: a fresh plan.
## Optional action hooks (see "Action hooks" below): `bot_wants_action(player) -> bool`,
## `bot_aim(player) -> Vector3`, `bot_action_cooldown() -> float`, `bot_action_reach() -> float`.
## A minigame that has `bot_wants_action` decides every press: the default shove is off there.
## `Minigame.is_ally(a, b)` (teams): bots never chase an ally and never shove while one is in
## front of them.
## Bots ignore NPC extras (not in `Minigame.players`); a shove may still hit one in passing.
##
## NPC extras (`Stage.spawn_extras`) use a cheap separate mode instead of the state machine:
## `configure_extra(mode, seed, center)` with mode `wander` (walk between random safe points
## within `wander_radius` of home, pausing in between), `dance` (loose circles around `center`,
## or home: give a group the same centre for a crowd dance) or `idle` (stand, still reacting
## to knocks). Extras never shove or jump, keep a little space, re-plan after a knock, and are
## deterministic for a seed. The action hooks are not polled for `is_extra` blobs unless the
## minigame declares `var bot_extra_hooks := true`; a real player's brain in an extra mode (a
## bot posing as an NPC) does poll them, every EXTRA_THINK.
##
## Action hooks. Each think (EXTRA_THINK in the extra modes) the brain asks
## `bot_wants_action(player)`. On a yes it starts an act: after its action reaction
## (ACTION_REACTION by skill, x jitter, x bot_reaction_scale) it presses `action` for one tick.
## While the act runs it asks `bot_aim(player)` every tick: a world point to face before the
## press (Vector3.ZERO = no preference: press as soon as the reaction is over). The bot turns to
## it by steering a short stick toward it (facing follows movement), with an aim error rolled
## per act (ACT_AIM_ERROR_DEG by skill), and presses once its facing has held within
## AIM_TOLERANCE_DEG of that (erroneous) direction for AIM_SETTLE (by skill). With
## `bot_action_reach()` > 0 the bot first walks to within that distance (centre to the aim
## point; an extra-mode stroller at a brisk stroll). A no at a later think, a knock, a stun or
## ACT_TIMEOUT (+ ACT_APPROACH_TIMEOUT with a reach) ends the act without a press. After a press
## the hook is not acted on again for `bot_action_cooldown()` (at least ACT_COOLDOWN) x 1..1.25.

enum State { NONE, GOAL, WANDER, CHASE, RECOVER }

# --- Tunables ---------------------------------------------------------------------------
# Pairs are (low skill, high skill); a bot lerps between them by `skill`.

## Seconds between decisions (also the perception delay for chase targets and goals).
const THINK_INTERVAL := Vector2(0.8, 0.25)
## Seconds before the very first decision (countdown just ended), scaled by jitter.
const START_DELAY := Vector2(0.45, 0.1)
## Max aim error in degrees, rolled per think.
const AIM_ERROR_DEG := Vector2(20.0, 3.0)
## Seconds an enemy must be in front before the bot shoves.
const SHOVE_REACTION := Vector2(0.4, 0.1)
## Seconds standing on unsafe ground before the bot reacts (also the rethink reaction).
const DANGER_REACTION := Vector2(0.3, 0.06)
## Metres the safety filter looks ahead (plus speed * LOOKAHEAD_PER_SPEED).
const LOOKAHEAD := Vector2(0.9, 1.6)
const LOOKAHEAD_PER_SPEED := 0.2
## Seconds of momentum the safety filter assumes before a new direction takes hold.
const DRIFT_TIME := Vector2(0.1, 0.07)
## Chance per think to wander instead of going to the goal (scaled by 1 - skill).
const WANDER_CHANCE := 0.3
## Chance per think to stand still for one think (scaled by 1 - skill).
const HESITATE_CHANCE := 0.1

## Within this distance of the goal the bot counts it as reached (m).
const ARRIVE_RADIUS := 0.6
## Within this distance of the goal the bot slows down (m).
const SLOW_RADIUS := 1.0
## Wandering further than this from the goal pulls the bot back (m).
const WANDER_LEASH := 5.0
## Seconds a goal is kept at most without a reason to re-ask (random in range).
const GOAL_REFRESH := Vector2(2.0, 4.0)

## Players nearer than this (m, scaled by 0.5 + aggression) may be chased...
const CHASE_RADIUS := 6.0
## ...if they are this close to the bot's goal (m)...
const CHASE_NEAR_GOAL := 3.0
## ...or within this angle (degrees) of the way to the goal.
const CHASE_ON_THE_WAY_DEG := 50.0
## Personal space (m) around players the bot is not chasing, and how hard it steers off them.
const SPACE_RADIUS := 1.8
const SPACE_WEIGHT := 1.2
## Shove when an enemy is within this distance (m, centre to centre)...
const SHOVE_RANGE := 1.3
## ...and within this angle of `facing` (degrees).
const SHOVE_CONE_DEG := 35.0
## Seconds between the bot's own shove presses (random in range; the shove component has its own cooldown too).
const SHOVE_COOLDOWN := Vector2(0.7, 1.4)

## Horizontal speed (m/s) above which the bot treats itself as knocked.
const KNOCK_SPEED := 7.0
## While recovering from a knock the bot pushes against its slide until below this speed (m/s).
const KNOCK_BRAKE_SPEED := 4.0
## Seconds spent recovering after a knock (random in range).
const RECOVER_TIME := Vector2(0.5, 1.0)

## Moving but slower than this (m/s) on the floor for BLOCKED_TIME seconds = stuck: jump.
const BLOCKED_SPEED := 0.6
const BLOCKED_TIME := 0.3
## Farthest landing point (m) of a gap jump (low skill, high skill).
const GAP_JUMP_REACH := Vector2(1.8, 3.0)
## Jump a gap only when its near edge is this close (m) and the bot runs this fast (m/s).
const GAP_TAKEOFF := 0.45
const GAP_MIN_SPEED := 3.5
## Take-off point error (m, about this much, by skill) on those gap jumps: early or late.
const GAP_TIMING_ERROR := Vector2(0.3, 0.04)
## Seconds the jump button stays held after a press (a full jump; at least time_to_apex + 0.05).
const JUMP_HOLD := 0.4
## Seconds between jump presses.
const JUMP_COOLDOWN := 0.5
## The ground turning unsafe right under the bot this many times (low skill, high skill)
## within CRUMBLE_WINDOW seconds teaches it the floor wears out: it hops from then on.
const CRUMBLE_EVENTS := Vector2(3.0, 2.0)
const CRUMBLE_WINDOW := 6.0
## Hopping: chance to take each chance to hop, min speed, and the assumed air time (s).
const HOP_WILL := Vector2(0.6, 0.95)
const HOP_MIN_SPEED := 2.5
const HOP_AIR_TIME := 0.6

# Jump probes (physics).
## Seconds between probes while running on the floor (low skill, high skill).
const PROBE_INTERVAL := Vector2(0.16, 0.08)
## Physics layer mask the probes see (1 = world).
const PROBE_MASK := 1
## Feet must clear a ledge top by this much (m): ledges up to apex - LEDGE_CLEARANCE are jumpable.
const LEDGE_CLEARANCE := 0.15
## Lowest step (m) that counts as a ledge (lower ones the capsule rides over).
const LEDGE_MIN := 0.2
## Ground this far below the feet (m) still counts as floor (a step down), deeper is a hole.
const MAX_DROP := 1.6
## Take-off timing error (s, about this much, by skill) and the chance of a short, missed jump.
const JUMP_TIMING_ERROR := Vector2(0.06, 0.012)
const JUMP_MISS_CHANCE := Vector2(0.12, 0.01)
## Share of its real jump range a bot believes it has (low skill is more careful).
const JUMP_RANGE_TRUST := Vector2(0.8, 0.95)
## Seconds pressed against a wall too high to jump before the bot side-steps and re-plans.
const HIGH_WALL_GIVE_UP := 0.6

# Hold and action hooks.
## Seconds to notice a hold coming on (stop) / going off (go): by skill, plus random jitter.
const HOLD_STOP := Vector2(1.04, 0.15)
const HOLD_STOP_JITTER := 0.4
const HOLD_GO := Vector2(0.8, 0.25)
const HOLD_GO_JITTER := 0.25
## Seconds from the action hook's yes (seen at a think) to the press, x 0.8..1.25.
const ACTION_REACTION := Vector2(0.4, 0.1)
## Aim error of an act (degrees, triangular distribution of about this width).
const ACT_AIM_ERROR_DEG := Vector2(18.0, 2.5)
## Facing must be within this of the act's aim direction for AIM_SETTLE seconds.
const AIM_TOLERANCE_DEG := 7.0
const AIM_SETTLE := Vector2(0.2, 0.04)
## Stick length while turning to face the aim (facing follows movement), and near danger.
const AIM_STICK := 0.3
## The same for a bot posing as an NPC (an extra mode): a stroller's slow turn.
const AIM_STICK_STROLL := 0.2
const AIM_STICK_MIN := 0.1
## An act without a press ends after this long (s); a reach adds ACT_APPROACH_TIMEOUT.
const ACT_TIMEOUT := 1.2
const ACT_APPROACH_TIMEOUT := 6.0
## Least seconds between two hook presses.
const ACT_COOLDOWN := 0.25

# Difficulty: where rolled skills land.
const SKILL_EASY := Vector2(0.05, 0.55)
const SKILL_NORMAL := Vector2(0.35, 0.95)
const SKILL_HARD := Vector2(0.7, 1.0)

# Extras.
const EXTRA_MODES: Array[StringName] = [&"wander", &"dance", &"idle"]
## Seconds between an extra's crowd checks (personal space).
const EXTRA_THINK := 0.3
## Seconds an extra pauses between wander walks (random in range).
const EXTRA_PAUSE := Vector2(0.8, 3.0)
## Seconds an extra walks toward one point before giving up (blocked by someone).
const EXTRA_WALK_MAX := 6.0
## Stick length an extra walks at (random in range per extra): a stroll, not a run.
const EXTRA_SPEED := Vector2(0.3, 0.55)
## Personal space of an extra (m) and how hard it steers off others.
const EXTRA_SPACE := 1.1
const EXTRA_SPACE_WEIGHT := 0.8
## Dance circle radius (m, random in range per extra).
const DANCE_RADIUS := Vector2(1.2, 2.6)

## Host-wide bot difficulty 0..1 (no UI yet): rolled skills land in `skill_range(difficulty)`,
## 0.5 = the normal spread. Brains read it when they configure (set it before a round).
static var difficulty: float = 0.5

# --- Configuration ----------------------------------------------------------------------

## The player this brain drives (set by the controller before it enters the tree).
var player: Player = null
## Minigame to read goals and safety from; null = the Stage's current minigame.
var minigame: Minigame = null
## 0 = clumsy, 1 = sharp. Rolled from the seed unless given to `configure`.
var skill: float = 0.6
## 0 = never chases, 1 = chases whenever someone is near. Rolled from the seed.
var aggression: float = 0.5
## The seed this brain was configured with.
var rng_seed: int = 0
## Extras only (see configure_extra): &"wander", &"dance", &"idle"; &"" = a normal bot.
var extra_mode: StringName = &""
## Extras, wander: metres a target may lie from home (where the extra was at its first tick).
var wander_radius: float = 4.0
## Stats (tests): presses made for the action hook, physics-planned jumps taken.
var acts: int = 0
var planned_jumps: int = 0

var _rng := RandomNumberGenerator.new()
var _rng_b := RandomNumberGenerator.new()  # hooks and jump probes: keeps `_rng`'s sequence as it was
var _configured: bool = false
var _speed_scale: float = 1.0
var _strafe_bias: float = 0.0   # radians; approach angle when chasing from afar
var _turn_sign: float = 1.0     # which way the bot tries first when steering around danger
var _danger_reaction: float = 0.15

# --- Runtime state ------------------------------------------------------------------------

var state: State = State.NONE
var _think_timer: float = 0.0
var _goal_timer: float = 0.0
var _recover_timer: float = 0.0
var _goal: Vector3 = Vector3.ZERO
var _has_goal: bool = false
var _arrived: bool = false   # reached the current goal (asked for the next one)
var _rethink: bool = false   # the minigame asked: take the next answer
var _recover_ground: bool = false  # recovering from unsafe ground (not from a knock)
var _target: Player = null
var _target_seen: Vector3 = Vector3.ZERO
var _wander_dir: Vector2 = Vector2.ZERO
var _aim_error: float = 0.0
var _move_scale: float = 1.0
var _shove_reaction: float = 0.2
var _shove_seen: float = 0.0
var _shove_cooldown: float = 0.0
var _unsafe_time: float = 0.0
var _last_safe: Vector3 = Vector3.INF
var _safe_spot: Vector3 = Vector3.INF  # where the bot is running to get off unsafe ground
var _prev_pos: Vector3 = Vector3.INF
var _clock: float = 0.0
var _crumbles: Array[float] = []   # _clock times the ground turned unsafe right under the bot
var _floor_crumbles: bool = false  # learned this round: lingering loses the floor, so hop
var _hop_pause: float = 0.0
var _air_dir: Vector2 = Vector2.ZERO  # direction held through a jump until landing
var _air_time: float = 0.0
var _blocked_time: float = 0.0
var _jump_hold: float = 0.0
var _jump_cooldown: float = 0.0
var _gap_jump: bool = false
var _gap_err: float = 0.0          # this bot's take-off error for the next gap jump (m)
var _gap_edge: float = 0.0         # near edge (m ahead) of the gap _gap_check last approved
# Budget (see "Budget").
var _heavy_t: float = 0.0          # seconds until this bot's next full safety pass is due
var _filt_valid: bool = false      # a cached detour / gap run is in force
var _filt_in: Vector2 = Vector2.ZERO
var _filt_dir: Vector2 = Vector2.ZERO
var _filt_gap: bool = false
var _filt_wait: int = 0             # ticks a needed full pass was put off by the frame budget
var _seen_frame: int = -1
var _solo: bool = false             # driven several times per physics frame (a test): no shared budget or cache
var _plan_speed: float = 0.0       # least speed along the plan for a planned gap jump
var _radius_cache: float = 0.0
var _pass_samples: int = 0
var _hooked: Minigame = null
# Hooks (looked up once per minigame).
var _hooks_game: Minigame = null
var _hook_hold: bool = false
var _hook_action: bool = false
var _hook_aim: bool = false
var _hook_cooldown: bool = false
var _hook_reach: bool = false
var _extra_hooks: bool = false
var _skill_scale: float = 1.0      # the minigame's bot_skill_scale hint
var _held: bool = false
var _hold_known: bool = false     # the first answer after configure applies at once
var _hold_switch: float = -1.0    # seconds until a changed hold answer is noticed (-1 none)
# Acts (action hook).
var _act: bool = false
var _act_time: float = 0.0
var _act_delay: float = 0.0
var _act_err: float = 0.0
var _act_settle: float = 0.0
var _act_reach: float = 0.0
var _act_cd: float = 0.0
var _act_fire: bool = false
var _act_facing: bool = false
var _act_followup: bool = false   # after a press: ask again as soon as the cooldown is over
# Jump probes.
var _ray: PhysicsRayQueryParameters3D = null
var _probe_timer: float = 0.0
var _plan_at: Vector3 = Vector3.INF   # take-off point of a planned ledge / gap jump
var _plan_dir: Vector2 = Vector2.ZERO
var _plan_hold: float = 0.0
var _hole_edge: Vector3 = Vector3.INF # near edge of a hole too wide to jump
var _hole_dir: Vector2 = Vector2.ZERO
var _wall_high: bool = false          # the wall ahead is higher than this blob can jump
# Extras.
var _home: Vector3 = Vector3.INF
var _dance_center: Vector3 = Vector3.INF
var _dance_radius: float = 1.8
var _dance_dir: float = 1.0
var _dance_angle: float = 0.0
var _x_target: Vector3 = Vector3.INF
var _x_pause: float = 0.0
var _x_walk: float = 0.0
var _x_speed: float = 0.45
var _x_think: float = 0.0
var _x_push: Vector2 = Vector2.ZERO
var _stage_ref: Stage = null


func _ready() -> void:
	if player and not player.got_hit.is_connected(_on_got_hit):
		player.got_hit.connect(_on_got_hit)


## Where rolled skills land for difficulty `d` (0 easy, 0.5 normal, 1 hard): (min, max).
static func skill_range(d: float) -> Vector2:
	d = clampf(d, 0.0, 1.0)
	if d <= 0.5:
		return SKILL_EASY.lerp(SKILL_NORMAL, d / 0.5)
	return SKILL_NORMAL.lerp(SKILL_HARD, (d - 0.5) / 0.5)


## Seeds the brain and rolls its personality. `skill`/`aggression` < 0 = roll from the seed
## (skill within `skill_range(difficulty)`).
## Without a call, the first `fill_intent` configures with a random seed.
func configure(seed_value: int, skill_value: float = -1.0, aggression_value: float = -1.0) -> void:
	rng_seed = seed_value
	_rng.seed = seed_value
	_rng_b.seed = hash(seed_value) ^ 0x5bd1e995
	extra_mode = &""
	var r := skill_range(difficulty)
	skill = clampf(skill_value, 0.0, 1.0) if skill_value >= 0.0 else _rng.randf_range(r.x, r.y)
	aggression = clampf(aggression_value, 0.0, 1.0) if aggression_value >= 0.0 else _rng.randf_range(0.2, 0.85)
	_speed_scale = _rng.randf_range(0.9, 1.0)
	_strafe_bias = _rng.randf_range(-0.4, 0.4)
	_turn_sign = 1.0 if _rng.randf() < 0.5 else -1.0
	_danger_reaction = _lerp_skill(DANGER_REACTION) * _rng.randf_range(0.8, 1.25)
	_configured = true
	_hold_known = false
	_act_cd = 0.0
	acts = 0
	planned_jumps = 0
	_reset()


## The brain driving `p` (bots and extras; null for humans or without a brain).
static func of(p: Player) -> BotBrain:
	var c := p.get_component(&"controller") as ControllerComponent if p else null
	return c.brain as BotBrain if c else null


## Makes this brain an NPC extra's: `mode` &"wander" | &"dance" | &"idle" (unknown = wander),
## everything random from `seed_value`. `center`: the dance's centre (INF = where the extra
## stands at its next tick). Call again any time to switch mode.
func configure_extra(mode: StringName, seed_value: int, center: Vector3 = Vector3.INF) -> void:
	extra_mode = mode if EXTRA_MODES.has(mode) else &"wander"
	rng_seed = seed_value
	_rng.seed = seed_value
	_rng_b.seed = hash(seed_value) ^ 0x5bd1e995
	skill = 0.5
	aggression = 0.0
	_x_speed = _rng.randf_range(EXTRA_SPEED.x, EXTRA_SPEED.y)
	_dance_radius = _rng.randf_range(DANCE_RADIUS.x, DANCE_RADIUS.y)
	_dance_dir = 1.0 if _rng.randf() < 0.5 else -1.0
	_dance_angle = _rng.randf() * TAU
	_dance_center = center
	_home = Vector3.INF
	_x_target = Vector3.INF
	_x_pause = _rng.randf_range(0.0, 1.5)  # staggered start: a crowd does not move in lockstep
	_x_walk = 0.0
	_x_think = 0.0
	_x_push = Vector2.ZERO
	_clock = 0.0
	state = State.NONE
	_configured = true
	_hold_known = false
	_end_act()


## Profiling (tests, perf): when true every brain adds its fill_intent time (us) per physics frame.
static var profile: bool = false
static var profile_frames: Dictionary = {}   # physics frame -> summed us
static var profile_calls: Dictionary = {}    # physics frame -> is_safe calls made (cache misses)
## Off: every brain runs without the frame budget, the shared cache and the sample cap (A/B).
static var budget_enabled: bool = true


## Fills `intent` for this tick. Dead or frozen: empty intent.
## (Action hook: besides each think, the brain asks again once right after a press's cooldown.)
func fill_intent(intent: PlayerIntent, delta: float) -> void:
	if not profile:
		_fill(intent, delta)
		return
	var t0 := Time.get_ticks_usec()
	_fill(intent, delta)
	var f := Engine.get_physics_frames()
	profile_frames[f] = int(profile_frames.get(f, 0)) + Time.get_ticks_usec() - t0


func _fill(intent: PlayerIntent, delta: float) -> void:
	_pass_samples = 0
	if not _configured:
		configure(randi())
	_frame_begin()
	var game := _game()
	_lookup_hooks(game)
	_act_cd -= delta
	if _update_hold(game, delta):
		intent.clear()
		_end_act()
		return
	if extra_mode != &"":
		_fill_extra(intent, delta)
		return
	if player == null or not player.alive or player.frozen:
		intent.clear()
		if state != State.NONE:
			_reset()
		return
	_hook(game)
	if player.control_locked:
		intent.clear()
		_enter_recover()
		return

	_think_timer -= delta
	_goal_timer -= delta
	_recover_timer -= delta
	_shove_cooldown -= delta
	_jump_cooldown -= delta

	var pos := player.global_position
	var hvel := Vector2(player.velocity.x, player.velocity.z)
	if hvel.length() > KNOCK_SPEED and state != State.RECOVER:
		_enter_recover()
	_clock += delta
	_air_time += delta
	if _air_dir != Vector2.ZERO:
		var landing := pos + _to3(hvel * maxf(HOP_AIR_TIME - _air_time, 0.1))
		if (player.is_on_floor() and _air_time > 0.15) or state == State.RECOVER \
				or (game and not _safe(game, landing)):
			_air_dir = Vector2.ZERO  # landed, knocked, or the landing went bad: steer normally
		else:
			# Mid-jump toward a safe landing: hold the line (turning back over a gap is how you fall in).
			intent.move = _air_dir
			intent.jump_pressed = false
			intent.jump_held = _jump_hold > 0.0
			intent.action_pressed = false
			_jump_hold -= delta
			_prev_pos = pos
			return
	# Ground underfoot turned unsafe (a tile cracking, a ring warning): react quickly.
	if game and not _safe(game, pos):
		if _unsafe_time == 0.0 and _prev_pos != Vector3.INF and not _safe(game, _prev_pos):
			_note_crumble()
		_unsafe_time += delta
		if _unsafe_time >= _danger_reaction and state != State.RECOVER and state != State.NONE:
			_enter_recover(false)
	else:
		_unsafe_time = 0.0
		if game:
			_last_safe = pos
			_safe_spot = Vector3.INF
		if state == State.RECOVER and _recover_ground:
			# Back on safe ground: carry on at once, with a fresh plan (the old one led here).
			state = State.GOAL
			_rethink = true
			_think_timer = 0.0
	if _think_timer <= 0.0 and _take_budget(true):
		_think(game, pos)
	elif _act_followup and _act_cd <= 0.0:
		# A press usually leads straight to the next one (a scoop to a throw): ask again now.
		_act_followup = false
		_poll_action(game)

	var move := _desired_move(game, pos)
	if state != State.RECOVER and move.length_squared() > 0.0001:
		move = move.rotated(_aim_error)
	_act_fire = false
	_act_facing = false
	if _act:
		move = _act_move(game, pos, move, delta, maxf(_move_scale, 0.6), AIM_STICK)
	_gap_jump = false
	if not _act_facing:
		if state != State.RECOVER and state != State.NONE:
			move = _keep_space(game, pos, move)
		move = _filter(game, pos, move, hvel, delta)
		move = _probe_ahead(game, pos, move, hvel, delta)
	intent.move = move.limit_length(1.0)

	_fill_jump(intent, delta, hvel, game, pos)
	intent.action_pressed = _act_fire if _hook_action else _want_shove(delta, pos, game)
	_prev_pos = pos


## True while the minigame's `bot_should_hold` held this brain at its last tick (after the
## bot's hold reaction).
func is_held() -> bool:
	return _held


## This bot's own reaction delay (s), from its skill and personality: how late it acts on a
## change it has to notice (unsafe ground, a rethink).
func reaction_time() -> float:
	return _danger_reaction


## True while an act (action hook) is under way: reacting, approaching or aiming.
func is_acting() -> bool:
	return _act


## Looks the optional hooks up once per minigame.
func _lookup_hooks(game: Minigame) -> void:
	if game == _hooks_game:
		return
	_hooks_game = game
	var ok := game != null and is_instance_valid(game)
	_hook_hold = ok and game.has_method(&"bot_should_hold")
	_hook_action = ok and game.has_method(&"bot_wants_action")
	_hook_aim = ok and game.has_method(&"bot_aim")
	_hook_cooldown = ok and game.has_method(&"bot_action_cooldown")
	_hook_reach = ok and game.has_method(&"bot_action_reach")
	_extra_hooks = ok and game.get(&"bot_extra_hooks") == true
	var ss: Variant = game.get(&"bot_skill_scale") if ok else null
	_skill_scale = clampf(float(ss), 0.0, 1.0) if ss is float or ss is int else 1.0
	_end_act()


## The minigame's optional `bot_should_hold(player)` answer, noticed after the hold reaction:
## true while this brain holds.
func _update_hold(game: Minigame, delta: float) -> bool:
	var want: bool = _hook_hold and player != null and is_instance_valid(game) \
		and game.call(&"bot_should_hold", player) == true
	if not _hold_known:
		_hold_known = true
		_held = want
		_hold_switch = -1.0
		return _held
	if want == _held:
		_hold_switch = -1.0
		return _held
	if _hold_switch < 0.0:
		var base := _lerp_skill(HOLD_STOP) + _rng_b.randf() * HOLD_STOP_JITTER if want \
			else _lerp_skill(HOLD_GO) + _rng_b.randf() * HOLD_GO_JITTER
		_hold_switch = base * _reaction_scale(game)
	_hold_switch -= delta
	if _hold_switch <= 0.0:
		_held = want
		_hold_switch = -1.0
		if not _held:
			# Going again: with a fresh plan, as soon as it has thought about where to.
			_rethink = true
			_think_timer = minf(_think_timer, _danger_reaction * _rng_b.randf_range(1.0, 2.0))
	return _held


# --- Decisions ------------------------------------------------------------------------------

func _think(game: Minigame, pos: Vector3) -> void:
	_think_timer = _lerp_skill(THINK_INTERVAL) * _rng.randf_range(0.7, 1.3)
	_aim_error = deg_to_rad(_lerp_skill(AIM_ERROR_DEG)) * _rng.randf_range(-1.0, 1.0)
	_move_scale = _speed_scale * _rng.randf_range(0.9, 1.0)
	_shove_reaction = _lerp_skill(SHOVE_REACTION) * _rng.randf_range(0.8, 1.25)
	if _rng.randf() < HESITATE_CHANCE * (1.0 - _skill()) and not _floor_crumbles:
		_move_scale = 0.0
	_update_goal(game, pos)
	_poll_action(game)

	# Perception snapshot: chase targets are only seen at think time (reaction delay).
	_target = _chase_candidate(game, pos)
	if _target:
		_target_seen = _target.global_position

	if state == State.RECOVER and (_recover_timer > 0.0 or _unsafe_time > 0.0):
		return
	if game and not _safe(game, pos):
		_enter_recover(false)
		return
	var roll := _rng.randf()
	if _target and roll < aggression * _aggression_scale(game):
		state = State.CHASE
	elif _rng.randf() < WANDER_CHANCE * (1.0 - _skill()):
		state = State.WANDER
		if _wander_dir == Vector2.ZERO or _rng.randf() < 0.6:
			_wander_dir = Vector2.RIGHT.rotated(_rng.randf() * TAU)
	else:
		state = State.GOAL


## Asks for a new goal when there is none, it was reached, it turned unsafe, it is stale,
## or the minigame asked for a rethink. Otherwise the bot sticks to its plan.
func _update_goal(game: Minigame, pos: Vector3) -> void:
	if game == null:
		_goal = pos
		_has_goal = true
		return
	var reached := _has_goal and _flat(_goal - pos).length() < ARRIVE_RADIUS
	if not _has_goal or _rethink or reached or _goal_timer <= 0.0 or not _safe(game, _goal):
		_goal = game.get_bot_goal(player)
		_has_goal = true
		_rethink = false
		_arrived = false
		_goal_timer = _rng.randf_range(GOAL_REFRESH.x, GOAL_REFRESH.y)


func _desired_move(game: Minigame, pos: Vector3) -> Vector2:
	match state:
		State.GOAL:
			return _toward_goal(pos) * _move_scale
		State.WANDER:
			var to_goal := _flat(_goal - pos)
			if to_goal.length() > WANDER_LEASH:
				return (_wander_dir + to_goal.normalized()).normalized() * 0.7 * _move_scale
			return _wander_dir * 0.6 * _move_scale
		State.CHASE:
			if _target == null or not is_instance_valid(_target) or not _target.alive:
				return _toward_goal(pos) * _move_scale
			var to := _flat(_target_seen - pos)
			var d := to.length()
			if d < 0.05:
				return Vector2.ZERO
			var bias := _strafe_bias * clampf((d - 1.5) / 3.0, 0.0, 1.0)
			return to.normalized().rotated(bias) * _move_scale
		State.RECOVER:
			return _recover_move(game, pos)
	return Vector2.ZERO


## Personal space: steer off players the bot is not after, so bots do not pile up.
func _keep_space(game: Minigame, pos: Vector3, move: Vector2) -> Vector2:
	var push := Vector2.ZERO
	for other in _others(game):
		if state == State.CHASE and other == _target:
			continue
		var away := _flat(pos - other.global_position)
		var d := away.length()
		if d < SPACE_RADIUS and d > 0.01:
			push += away / d * (1.0 - d / SPACE_RADIUS)
	if push == Vector2.ZERO:
		return move
	return (move + push * SPACE_WEIGHT).limit_length(maxf(move.length(), 0.6))


func _toward_goal(pos: Vector3) -> Vector2:
	if not _has_goal:
		return Vector2.ZERO
	var to := _flat(_goal - pos)
	var d := to.length()
	if d < ARRIVE_RADIUS:
		# Reached: ask for the next goal right away (once; the answer may be "stay here").
		if not _arrived:
			_arrived = true
			_think_timer = minf(_think_timer, _danger_reaction)
		return Vector2.ZERO
	return to.normalized() * clampf(d / SLOW_RADIUS, 0.5, 1.0)


func _recover_move(game: Minigame, pos: Vector3) -> Vector2:
	if game and not _safe(game, pos):
		return _toward_safety(game, pos)
	var hvel := Vector2(player.velocity.x, player.velocity.z)
	var home := _flat(_goal - pos).normalized() if _has_goal else Vector2.ZERO
	if hvel.length() > KNOCK_BRAKE_SPEED:
		return (-hvel.normalized() * 1.5 + home).normalized()
	return home


## Knocked: fight the knock for a while. Not knocked (the ground turned unsafe): only until safe.
func _enter_recover(knocked: bool = true) -> void:
	state = State.RECOVER
	_recover_ground = not knocked
	_recover_timer = _rng.randf_range(RECOVER_TIME.x, RECOVER_TIME.y) if knocked else 0.0
	_think_timer = minf(_think_timer, _recover_timer)
	_end_act()
	_clear_plan()


func _on_got_hit(_impulse: Vector3, _source_slot: int) -> void:
	if player == null or not player.alive:
		return
	if extra_mode != &"":
		# Knocked: stand dazed a moment, then pick a fresh point from wherever it landed.
		_x_target = Vector3.INF
		_x_pause = maxf(_x_pause, _rng.randf_range(0.4, 1.0))
		_end_act()
		return
	_enter_recover()


func _on_rethink_requested(slot: int) -> void:
	if player == null or (slot >= 0 and slot != player.slot):
		return
	_rethink = true
	_think_timer = minf(_think_timer, _danger_reaction * _rng.randf_range(1.0, 2.0))


## Connects to the minigame's optional rethink signal once per minigame.
func _hook(game: Minigame) -> void:
	if game == _hooked:
		return
	if _hooked and is_instance_valid(_hooked) and _hooked.bot_rethink_requested.is_connected(_on_rethink_requested):
		_hooked.bot_rethink_requested.disconnect(_on_rethink_requested)
	_hooked = game
	if game:
		game.bot_rethink_requested.connect(_on_rethink_requested)


# --- Action hooks -----------------------------------------------------------------------------

## At a think: asks `bot_wants_action`; a yes starts an act (unless one runs, the cooldown is on
## or the bot is recovering), a no ends the act under way.
func _poll_action(game: Minigame) -> void:
	if not _hook_action or game == null or player == null:
		return
	var want: bool = game.call(&"bot_wants_action", player) == true
	if _act:
		if not want:
			_end_act()
		return
	if not want or _act_cd > 0.0 or state == State.RECOVER:
		return
	_act = true
	_act_time = 0.0
	_act_settle = 0.0
	_act_delay = _lerp_skill(ACTION_REACTION) * _rng_b.randf_range(0.8, 1.25) * _reaction_scale(game)
	var e := deg_to_rad(_lerp_skill(ACT_AIM_ERROR_DEG))
	_act_err = e * (_rng_b.randf_range(-1.0, 1.0) + _rng_b.randf_range(-1.0, 1.0)) * 0.5
	_act_reach = maxf(float(game.call(&"bot_action_reach")), 0.0) if _hook_reach else 0.0


## One tick of the act under way: returns the move (unchanged without an aim point, toward it
## while out of reach, a short stick toward the erroneous aim direction while facing it, then
## `_act_facing` is set) and fires the press when the reaction is over and the aim has settled.
func _act_move(game: Minigame, pos: Vector3, move: Vector2, delta: float, approach_stick: float, face_stick: float) -> Vector2:
	_act_time += delta
	_act_delay -= delta
	if _act_time > ACT_TIMEOUT + (ACT_APPROACH_TIMEOUT if _act_reach > 0.0 else 0.0):
		_end_act()
		return move
	var aim := Vector3.ZERO
	if _hook_aim and game != null:
		var v: Variant = game.call(&"bot_aim", player)
		if v is Vector3:
			aim = v
	if aim == Vector3.ZERO:
		if _act_delay <= 0.0:
			_fire(game)
		return move
	var to := _flat(aim - pos)
	var d := to.length()
	if _act_reach > 0.0 and d > _act_reach:
		_act_settle = 0.0
		return to / d * approach_stick
	var face := _flat(player.facing)
	var want := (to / d if d > 0.05 else face.normalized()).rotated(_act_err)
	if face.length_squared() > 0.0001 and absf(face.angle_to(want)) <= deg_to_rad(AIM_TOLERANCE_DEG):
		_act_settle += delta
	else:
		_act_settle = 0.0
	if _act_delay <= 0.0 and _act_settle >= _lerp_skill(AIM_SETTLE):
		_fire(game)
	_act_facing = true
	var safe := game == null or _safe(game, pos + _to3(want * 0.6))
	return want * (face_stick if safe else AIM_STICK_MIN)


## The press: one tick of `action`, then the cooldown.
func _fire(game: Minigame) -> void:
	_act_fire = true
	_act = false
	_act_followup = true
	acts += 1
	var cd := ACT_COOLDOWN
	if _hook_cooldown and game != null:
		cd = maxf(cd, float(game.call(&"bot_action_cooldown")))
	_act_cd = cd * _rng_b.randf_range(1.0, 1.25)


func _end_act() -> void:
	_act = false
	_act_settle = 0.0
	_act_followup = false


# --- Safety -----------------------------------------------------------------------------

## Keeps `move` off unsafe ground. The path is checked from where momentum carries the bot:
## same direction if it is safe, a jump if a small gap can be crossed, else the nearest
## safe rotation (first trying the side it turned to last time, so it slides along an
## edge instead of dithering), else straight for the nearest safe ground.
func _safety_filter(game: Minigame, pos: Vector3, move: Vector2, hvel: Vector2) -> Vector2:
	if game == null:
		return move
	var mag := move.length()
	var drift := _to3(hvel * _lerp_skill(DRIFT_TIME))
	if mag < 0.05:
		# Standing still: do not let momentum carry us into danger.
		if hvel.length() > 0.5 and not _safe(game, pos + _to3(hvel * 0.3)):
			return -hvel.normalized()
		return move
	var dir := move / mag
	var look := _lerp_skill(LOOKAHEAD) + hvel.length() * LOOKAHEAD_PER_SPEED
	if _path_safe(game, pos + drift, dir, look):
		return move
	if state != State.RECOVER and _safe(game, pos):
		var gap := _gap_check(game, pos, dir, hvel)
		if gap > 0:
			_gap_jump = gap == 2
			return dir
	for i in range(1, 10):
		if _over_cap():
			break
		for s: float in [_turn_sign, -_turn_sign]:
			var cand := dir.rotated(deg_to_rad(20.0 * i) * s)
			if _path_safe(game, pos + drift, cand, look):
				_turn_sign = s
				return cand * maxf(mag, 0.6)
	if _safe(game, pos):
		# No fully safe way: follow the one that stays safe longest (along the boundary),
		# else jump a gap in any direction. Keep moving: lingering is how floors give way.
		var open := _most_open(game, pos, dir, look)
		if open != Vector2.ZERO:
			return open * maxf(mag, 0.6)
		if state != State.RECOVER:
			for i in 12:
				if _over_cap():
					break
				var cand := dir.rotated(TAU / 12.0 * floorf((i + 1) / 2.0) * (1.0 if i % 2 == 0 else -1.0))
				var gap := _gap_check(game, pos, cand, hvel)
				if gap > 0:
					_gap_jump = gap == 2
					return cand
	return _toward_safety(game, pos)


## The direction (of 24) whose straight path stays safe the longest, leaning toward `dir`;
## zero when none stays safe for even a short step.
func _most_open(game: Minigame, pos: Vector3, dir: Vector2, look: float) -> Vector2:
	var best := Vector2.ZERO
	var best_score := -INF
	for i in 24:
		if _over_cap():
			break
		var cand := Vector2.RIGHT.rotated(TAU * i / 24.0)
		var run := 0.0
		var d := 0.2
		while d <= look + 0.01 and _safe(game, pos + _to3(cand * d)):
			run = d
			d += 0.2
		if run < 0.6:
			continue
		var score := run + 0.4 * cand.dot(dir)
		if score > best_score:
			best_score = score
			best = cand
	return best


func _path_safe(game: Minigame, from: Vector3, dir: Vector2, look: float) -> bool:
	if not _safe(game, from):
		return false
	for t: float in [0.25, 0.5, 0.75, 1.0]:
		if not _safe(game, from + _to3(dir * look * t)):
			return false
	return true


## 0 = not a jumpable gap; 1 = a gap the bot can clear, keep running at it;
## 2 = at its near edge now, jump. Only gaps with safe ground (and room) behind them,
## within reach for this bot's skill, and only at running speed.
func _gap_check(game: Minigame, pos: Vector3, dir: Vector2, hvel: Vector2) -> int:
	var reach := _lerp_skill(GAP_JUMP_REACH)
	var edge := -1.0
	var d := 0.15
	var limit := 4.0 + reach
	while d <= limit:
		if edge >= 0.0:
			limit = minf(limit, edge + reach)
		var safe := _safe(game, pos + _to3(dir * d))
		if not safe and edge < 0.0:
			edge = d
		elif safe and edge >= 0.0:
			if not _safe(game, pos + _to3(dir * (d + 0.5))):
				return 0
			if d - edge > reach - GAP_TAKEOFF:
				return 0
			if edge <= GAP_TAKEOFF + 0.15 + _gap_err:
				var speed := hvel.dot(dir)
				var can_jump := player.is_on_floor() and _jump_cooldown <= 0.0
				_gap_edge = edge
				return 2 if speed >= GAP_MIN_SPEED and can_jump else 0
			_gap_edge = edge
			return 1
		d += 0.15
	return 0


## Direction toward safe ground. Picks a safe spot once and runs for it (no dithering) until
## it is reached or stops being safe. The spot: the nearest safe ground in a widening
## search, preferring the goal side and ground that stays safe a little further on.
## Never zero while any fallback exists: the last safe spot, then the goal.
func _toward_safety(game: Minigame, pos: Vector3) -> Vector2:
	if _safe_spot != Vector3.INF and _safe(game, _safe_spot) and _flat(_safe_spot - pos).length() > 0.15:
		return _flat(_safe_spot - pos).normalized()
	_safe_spot = Vector3.INF
	var home := _flat(_goal - pos).normalized() if _has_goal else Vector2.ZERO
	for r: float in [0.5, 1.0, 1.5, 2.0, 3.0, 4.5, 6.0, 9.0]:
		if _over_cap():
			break
		var best := Vector2.ZERO
		var best_score := -INF
		for i in 24:
			var cand := Vector2.RIGHT.rotated(TAU * i / 24.0)
			if _safe(game, pos + _to3(cand * r)):
				var score := cand.dot(home) * 0.3
				if _safe(game, pos + _to3(cand * (r + 0.6))):
					score += 1.0
				if score > best_score:
					best_score = score
					best = cand
		if best != Vector2.ZERO:
			var deeper := pos + _to3(best * (r + 0.4))
			_safe_spot = deeper if _safe(game, deeper) else pos + _to3(best * r)
			return best
	if _last_safe != Vector3.INF and _flat(_last_safe - pos).length() > 0.2:
		return _flat(_last_safe - pos).normalized()
	return home


# --- Budget ---------------------------------------------------------------------------------------
# Bots think inside physics ticks, so the brain keeps its share of a tick small. Decisions (`_think`:
# goals, chase targets, the action hook) are spread over frames: THINKS_PER_FRAME for all brains
# together, a due think waits a tick. The straight-ahead safety check runs every tick (cheap); the
# full search behind it (detours along an edge, gap checks, the widening search for safe ground) runs
# at most every SAFETY_INTERVAL per bot (by skill: 6-10 Hz) and HEAVY_PER_FRAME per frame, the bot
# follows its last detour or gap run in between, and a needed search is never put off for more than
# HEAVY_WAIT_MAX ticks (never while standing on unsafe ground). Every `is_safe` answer is shared by
# all brains for the rest of the physics frame (positions to 2 cm, heights to 10 cm). A brain driven
# several times in one physics frame (tests) skips the shared budget and cache.

const THINKS_PER_FRAME := 1
const HEAVY_PER_FRAME := 2
const SAFETY_INTERVAL := Vector2(0.16, 0.1)
const HEAVY_WAIT_MAX := 2
## The widening searches of one safety pass stop after about this many is_safe samples.
const SAMPLE_CAP := 120

static var _budget_frame: int = -1
static var _thinks_left: int = 0
static var _heavy_left: int = 0
static var _cache_frame: int = -1
static var _cache_game: Object = null
static var _cache: Dictionary = {}


## Start of this brain's tick: notes whether it is driven twice in one frame, refills the budget.
func _frame_begin() -> void:
	var f := Engine.get_physics_frames()
	_solo = f == _seen_frame
	_seen_frame = f
	if f != _budget_frame:
		_budget_frame = f
		_thinks_left = THINKS_PER_FRAME
		_heavy_left = HEAVY_PER_FRAME


## Takes a think (`think`) or a full safety search from this frame's budget; false = wait a tick.
func _take_budget(think: bool) -> bool:
	if _solo or not budget_enabled:
		return true
	if think:
		if _thinks_left <= 0:
			return false
		_thinks_left -= 1
		return true
	if _heavy_left <= 0:
		return false
	_heavy_left -= 1
	return true


## `game.is_safe(p)`, shared by every brain for the rest of this physics frame.
func _safe(game: Minigame, p: Vector3) -> bool:
	_pass_samples += 1
	if _solo or not budget_enabled:
		_count_call()
		return game.is_safe(p)
	var f := Engine.get_physics_frames()
	if f != _cache_frame or game != _cache_game:
		_cache.clear()
		_cache_frame = f
		_cache_game = game
	var key := Vector3i(roundi(p.x * 50.0), roundi(p.y * 10.0), roundi(p.z * 50.0))
	var v: Variant = _cache.get(key)
	if v == null:
		_count_call()
		v = game.is_safe(p)
		_cache[key] = v
	return v


static func _count_call() -> void:
	if profile:
		var pf := Engine.get_physics_frames()
		profile_calls[pf] = int(profile_calls.get(pf, 0)) + 1


## This tick's widening searches have used up their samples (SAMPLE_CAP).
func _over_cap() -> bool:
	return budget_enabled and _pass_samples > SAMPLE_CAP


## The last detour / gap run is still in force and (a detour) still safe from rom.
func _cached_ok(game: Minigame, from: Vector3, look: float) -> bool:
	return _filt_valid and state != State.RECOVER and (_filt_gap or _path_safe(game, from, _filt_dir, look))


## The safety filter on a budget (see "Budget"): straight on when that path is safe, else the last
## detour or gap run while it holds, else the full `_safety_filter` when this bot's turn comes.
func _filter(game: Minigame, pos: Vector3, move: Vector2, hvel: Vector2, delta: float) -> Vector2:
	_heavy_t -= delta
	if game == null:
		return move
	var mag := move.length()
	if mag < 0.05:
		_filt_valid = false
		return _safety_filter(game, pos, move, hvel)
	var dir := move / mag
	var drift := _to3(hvel * _lerp_skill(DRIFT_TIME))
	var look := _lerp_skill(LOOKAHEAD) + hvel.length() * LOOKAHEAD_PER_SPEED
	if _heavy_t > 0.0 and dir.dot(_filt_in) > 0.97 and _cached_ok(game, pos + drift, look):
		return _filt_dir if _filt_gap else _filt_dir * maxf(mag, 0.6)
	if _path_safe(game, pos + drift, dir, look):
		_filt_valid = false
		_filt_wait = 0
		return move
	if _safe(game, pos) and _filt_wait < HEAVY_WAIT_MAX and (_heavy_t > 0.0 or not _take_budget(false)):
		# Not this bot's turn yet: keep to the last way that held, or ease off for a tick.
		_filt_wait += 1
		if _cached_ok(game, pos + drift, look):
			return _filt_dir if _filt_gap else _filt_dir * maxf(mag, 0.6)
		return _safety_filter(game, pos, Vector2.ZERO, hvel)
	_filt_wait = 0
	_heavy_t = _lerp_skill(SAFETY_INTERVAL) if budget_enabled else 0.0
	_gap_edge = -1.0
	_pass_samples = 0
	var out := _safety_filter(game, pos, move, hvel)
	var omag := out.length()
	_filt_valid = omag > 0.05 and state != State.RECOVER
	_filt_in = dir
	_filt_dir = out / omag if omag > 0.05 else Vector2.ZERO
	_filt_gap = _filt_valid and _gap_edge >= 0.0
	if _filt_gap and not _gap_jump:
		# A gap ahead to jump: take off at the edge (with this bot's error), even between passes.
		var jump := player.get_component(&"jump") as JumpComponent
		if jump:
			_plan(pos + _to3(_filt_dir * maxf(_gap_edge - GAP_TAKEOFF - 0.15 - _gap_err, 0.0)), _filt_dir, jump)
			_plan_hold = maxf(JUMP_HOLD, jump.time_to_apex + 0.05)
			_plan_speed = GAP_MIN_SPEED
	return out


# --- Jump probes (physics) ----------------------------------------------------------------------

## Probes the world ahead along `move` every PROBE_INTERVAL while running on the floor: plans a
## jump onto a ledge or across a hole within this blob's jump, stops the bot short of a hole it
## cannot clear, and notes a wall too high to jump. Returns the (possibly stopped) move.
func _probe_ahead(game: Minigame, pos: Vector3, move: Vector2, hvel: Vector2, delta: float) -> Vector2:
	_probe_timer -= delta
	var mag := move.length()
	if state == State.RECOVER or mag < 0.5 or not player.is_on_floor() or not player.is_inside_tree():
		_wall_high = _wall_high and mag >= 0.5
		return move
	var dir := move / mag
	if _plan_at != Vector3.INF and _plan_dir.dot(dir) < 0.9:
		_clear_plan()
	if _hole_edge != Vector3.INF and _hole_dir.dot(dir) < 0.7:
		_hole_edge = Vector3.INF
	if _probe_timer <= 0.0:
		_probe_timer = _lerp_skill(PROBE_INTERVAL) * _rng_b.randf_range(0.85, 1.15)
		_probe(game, pos, dir, hvel)
	if _hole_edge != Vector3.INF:
		# Never run off the edge of a hole too wide to jump: drop the part of the move into it.
		var left := _flat(_hole_edge - pos).dot(_hole_dir)
		var speed := maxf(hvel.dot(_hole_dir), 0.0)
		var stop := _radius() * 0.5 + 0.3 + speed * speed / 180.0
		if left < stop:
			var into := move.dot(_hole_dir)
			if into > 0.0:
				move -= _hole_dir * into
			if left < _radius() * 0.5 + 0.1:
				move -= _hole_dir * 0.5
	return move


func _probe(game: Minigame, pos: Vector3, dir: Vector2, hvel: Vector2) -> void:
	var jump := player.get_component(&"jump") as JumpComponent
	if jump == null:
		return
	var space := player.get_world_3d().direct_space_state if player.get_world_3d() else null
	if space == null:
		return
	if _ray == null:
		_ray = PhysicsRayQueryParameters3D.new()
		_ray.collision_mask = PROBE_MASK
		_ray.exclude = [player.get_rid()]
	var r := _radius()
	var v := maxf(hvel.dot(dir), 0.0)
	var can_jump := jump.jump_enabled
	var apex := jump.jump_height
	var max_up := apex - LEDGE_CLEARANCE
	var up := Vector3.UP
	# 1. A wall ahead at knee height: how high is its top?
	var look := r + clampf(v * 0.45, 0.6, 2.6)
	var knee := pos + up * 0.3
	var hit := _cast(space, knee, knee + _to3(dir * look))
	_wall_high = false
	if not hit.is_empty() and (hit["normal"] as Vector3).y < 0.7:
		_hole_edge = Vector3.INF
		var at: Vector3 = hit["position"]
		var top_from := Vector3(at.x, pos.y + apex + 0.6, at.z) + _to3(dir * 0.3)
		var top := _cast(space, top_from, Vector3(top_from.x, pos.y - 0.2, top_from.z))
		var h := INF
		if not top.is_empty() and (top["normal"] as Vector3).y > 0.7:
			h = (top["position"] as Vector3).y - pos.y
		if h <= LEDGE_MIN * 0.6 or h > max_up or not can_jump:
			_wall_high = true  # a ray that starts inside a tall wall finds the floor behind it
			_clear_plan()
			return
		var land := (top["position"] as Vector3) + _to3(dir * 0.2)
		if game and not _safe(game, land):
			_clear_plan()
			return
		# Take off so the feet are above the top (plus clearance) when the front reaches the wall.
		var dw := _flat(at - pos).length() - r
		var t_lo := _rise_time(jump, minf(h + LEDGE_CLEARANCE * 0.5, apex))
		var t_hi := jump.time_to_apex + sqrt(2.0 * maxf(apex - h - 0.05, 0.0) / _fall_gravity(jump))
		var t_go := lerpf(t_lo, t_hi, 0.35) + _timing_error()
		var run := dw - v * t_go if v > 1.5 else dw - 0.15
		_plan(pos + _to3(dir * maxf(run, 0.0)), dir, jump)
		return
	# 2. Floor ahead (two rays down): a hole the minigame does not mark unsafe?
	# Only where `is_safe` says yes: ground the minigame marks unsafe is the safety filter's job.
	var la := r + clampf(v * 0.4, 0.5, 2.2)
	if _floor_or_known(space, game, pos, dir, la) and _floor_or_known(space, game, pos, dir, la + 0.35):
		if _hole_edge != Vector3.INF and _flat(_hole_edge - pos).dot(dir) > la + 0.4:
			_hole_edge = Vector3.INF
		return
	var edge := -1.0
	var d := 0.25
	while d <= la + 0.36:
		if not _floor_or_known(space, game, pos, dir, d):
			edge = d
			break
		d += 0.25
	if edge < 0.0:
		return
	# The far side: floor again, no higher than the apex allows, safe to land on.
	var vmax := _max_speed()
	var t_air := jump.time_to_apex + sqrt(2.0 * apex / _fall_gravity(jump))
	var reach_max := vmax * t_air * _lerp_skill(JUMP_RANGE_TRUST)
	var far := -1.0
	var far_h := 0.0
	d = edge + 0.25
	while d <= edge + reach_max + 0.5:
		var hit_d := _floor_hit(space, pos, dir, d, apex)
		if not hit_d.is_empty():
			far = d
			far_h = (hit_d["position"] as Vector3).y - pos.y
			break
		d += 0.25
	var ok := far > 0.0 and can_jump and far_h <= max_up
	if ok:
		var t_land := jump.time_to_apex + sqrt(2.0 * maxf(apex - far_h, 0.01) / _fall_gravity(jump))
		var reach := vmax * t_land * _lerp_skill(JUMP_RANGE_TRUST)
		var landing := pos + _to3(dir * (far + r))
		ok = far + r * 0.5 - edge <= reach and (game == null or _safe(game, landing))
	if not ok:
		_clear_plan()
		_hole_edge = pos + _to3(dir * edge)
		_hole_dir = dir
		return
	_hole_edge = Vector3.INF
	var take := edge - 0.25 - v * _timing_error()
	_plan(pos + _to3(dir * maxf(take - 0.05, 0.0)), dir, jump)


## Plans a jump taking off at `at` along `dir` (held for full height, or short when missed).
func _plan(at: Vector3, dir: Vector2, jump: JumpComponent) -> void:
	_plan_speed = 0.0
	_plan_at = at
	_plan_dir = dir
	var full := maxf(JUMP_HOLD, jump.time_to_apex + 0.05)
	_plan_hold = full * 0.4 if _rng_b.randf() < _lerp_skill(JUMP_MISS_CHANCE) else full


func _clear_plan() -> void:
	_plan_at = Vector3.INF


## True on the tick the bot passes the planned take-off point.
func _plan_due(pos: Vector3) -> bool:
	if _plan_at == Vector3.INF:
		return false
	return _flat(pos - _plan_at).dot(_plan_dir) >= -0.05


func _roll_gap_err() -> void:
	_gap_err = clampf(_rng_b.randfn(0.0, _lerp_skill(GAP_TIMING_ERROR)), -0.25, 0.6)


## A random take-off timing error (s), smaller for skilled bots.
func _timing_error() -> float:
	return _rng_b.randfn(0.0, _lerp_skill(JUMP_TIMING_ERROR))


func _cast(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	_ray.from = from
	_ray.to = to
	return space.intersect_ray(_ray)


## Floor `d` m ahead, or ground the minigame marks unsafe (not the probes' business).
func _floor_or_known(space: PhysicsDirectSpaceState3D, game: Minigame, pos: Vector3, dir: Vector2, d: float) -> bool:
	if game != null and not _safe(game, pos + _to3(dir * d)):
		return true
	return _floor_at(space, pos, dir, d)


## Floor (a walkable surface no deeper than MAX_DROP, no higher than a hop) `d` m ahead.
func _floor_at(space: PhysicsDirectSpaceState3D, pos: Vector3, dir: Vector2, d: float) -> bool:
	return not _floor_hit(space, pos, dir, d, LEDGE_MIN).is_empty()


func _floor_hit(space: PhysicsDirectSpaceState3D, pos: Vector3, dir: Vector2, d: float, above: float) -> Dictionary:
	var p := pos + _to3(dir * d)
	var hit := _cast(space, p + Vector3.UP * (above + 0.3), p + Vector3.DOWN * MAX_DROP)
	if hit.is_empty() or (hit["normal"] as Vector3).y < 0.6:
		return {}
	return hit


## Seconds after take-off until the feet are `height` m up (on the way up).
static func _rise_time(jump: JumpComponent, height: float) -> float:
	var v0 := jump.get_jump_velocity()
	var g := jump.get_gravity_strength()
	return (v0 - sqrt(maxf(v0 * v0 - 2.0 * g * height, 0.0))) / g


static func _fall_gravity(jump: JumpComponent) -> float:
	return jump.get_gravity_strength() * jump.fall_gravity_multiplier


func _radius() -> float:
	if _radius_cache > 0.0:
		return _radius_cache
	var shape := player.get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	var cap := shape.shape as CapsuleShape3D if shape else null
	_radius_cache = cap.radius if cap else 0.4
	return _radius_cache


func _max_speed() -> float:
	var mv := player.get_component(&"movement") as MovementComponent
	return mv.max_speed if mv else 6.0


# --- Buttons ------------------------------------------------------------------------------

func _fill_jump(intent: PlayerIntent, delta: float, hvel: Vector2, game: Minigame, pos: Vector3) -> void:
	var on_floor := player.is_on_floor()
	if on_floor and intent.move.length() > 0.5 and hvel.length() < BLOCKED_SPEED:
		_blocked_time += delta
	else:
		_blocked_time = 0.0
	var blocked := _blocked_time > BLOCKED_TIME * lerpf(1.6, 1.0, _skill())
	if blocked and _wall_high:
		# Pressed against a wall it cannot jump: hopping is pointless. Side-step, think again.
		blocked = false
		if _blocked_time > HIGH_WALL_GIVE_UP:
			_blocked_time = 0.0
			_wall_high = false
			# Along the wall, on the side its target lies (a coin flip when straight behind it).
			var side := _flat(player.facing).orthogonal()
			var aim := _flat((_target_seen if state == State.CHASE and _target else _goal) - pos)
			var lean := side.dot(aim)
			_wander_dir = side * (signf(lean) if absf(lean) > 0.1 else (1.0 if _rng_b.randf() < 0.5 else -1.0))
			state = State.WANDER
			_rethink = true
			_think_timer = minf(_think_timer, 0.4)
	var planned := on_floor and _plan_due(pos)
	if planned and _plan_speed > 0.0 and hvel.dot(_plan_dir) < _plan_speed:
		# Too slow for the gap it planned: think again (the safety filter steers off the edge).
		planned = false
		_clear_plan()
		_filt_valid = false
		_heavy_t = 0.0
	var want := _gap_jump or blocked or planned
	var commit := want  # gap jumps and hops over obstacles hold their line in the air
	_hop_pause -= delta
	if not want and _floor_crumbles and on_floor and _jump_cooldown <= 0.0 and _hop_pause <= 0.0 \
			and intent.move.length() > 0.5 and hvel.length() >= HOP_MIN_SPEED and game:
		# A crumbling floor: hop along instead of wearing it out, landing only on safe ground.
		if _landing_safe(game, pos, hvel) and _rng.randf() < _lerp_skill(HOP_WILL):
			want = true
		else:
			_hop_pause = 0.2
	intent.jump_pressed = false
	if want and on_floor and _jump_cooldown <= 0.0:
		intent.jump_pressed = true
		_air_dir = intent.move if commit else Vector2.ZERO
		_air_time = 0.0
		var jump := player.get_component(&"jump") as JumpComponent
		_jump_hold = maxf(JUMP_HOLD, jump.time_to_apex + 0.05) if jump else JUMP_HOLD
		if _gap_jump:
			_roll_gap_err()
		if planned:
			planned_jumps += 1
			_jump_hold = _plan_hold
			_air_dir = _plan_dir
		_clear_plan()
		_jump_cooldown = JUMP_COOLDOWN
		_blocked_time = 0.0
	intent.jump_held = _jump_hold > 0.0
	_jump_hold -= delta


## True when a hop at the current velocity lands (with some slack either way) on safe ground.
func _landing_safe(game: Minigame, pos: Vector3, hvel: Vector2) -> bool:
	var land := hvel * HOP_AIR_TIME
	for k: float in [0.8, 1.0, 1.2]:
		if not _safe(game, pos + _to3(land * k)):
			return false
	return true


## The ground turned unsafe right where the bot just stood. Seen often enough, the bot
## learns this floor gives way under lingering feet and starts hopping.
func _note_crumble() -> void:
	_crumbles.append(_clock)
	while not _crumbles.is_empty() and _clock - _crumbles[0] > CRUMBLE_WINDOW:
		_crumbles.pop_front()
	if _crumbles.size() >= roundi(_lerp_skill(CRUMBLE_EVENTS)):
		_floor_crumbles = true


## Presses action (one tick) once an enemy has been in front within range for the reaction time.
func _want_shove(delta: float, pos: Vector3, game: Minigame) -> bool:
	if _aggression_scale(game) <= 0.0:
		_shove_seen = 0.0
		return false
	if _enemy_in_front(pos, game):
		_shove_seen += delta
	else:
		_shove_seen = 0.0
	if _shove_seen >= _shove_reaction and _shove_cooldown <= 0.0:
		_shove_seen = 0.0
		_shove_cooldown = _rng.randf_range(SHOVE_COOLDOWN.x, SHOVE_COOLDOWN.y)
		return true
	return false


## An enemy is in front within range and no ally is (a shove would hit the ally too).
func _enemy_in_front(pos: Vector3, game: Minigame) -> bool:
	var face := _flat(player.facing)
	if face.length_squared() < 0.0001:
		return false
	face = face.normalized()
	var min_dot := cos(deg_to_rad(SHOVE_CONE_DEG))
	var enemy := false
	for other in _others(game):
		var to := _flat(other.global_position - pos)
		var d := to.length()
		if d <= SHOVE_RANGE and d > 0.01 and face.dot(to / d) >= min_dot:
			if _is_ally(game, other):
				return false
			enemy = true
	return enemy


## True when the minigame says this bot and `other` are on the same team.
func _is_ally(game: Minigame, other: Player) -> bool:
	return game != null and game.is_ally(player, other)


# --- Extras -------------------------------------------------------------------------------

func _fill_extra(intent: PlayerIntent, delta: float) -> void:
	intent.clear()
	if player == null or not player.alive or player.frozen or player.control_locked:
		_end_act()
		return
	_clock += delta
	var pos := player.global_position
	if _home == Vector3.INF:
		_home = pos
		if _dance_center == Vector3.INF and extra_mode == &"dance":
			_dance_center = pos
	var game := _game()
	var hooks := _hook_action and (not player.is_extra or _extra_hooks)
	_x_think -= delta
	if _x_think <= 0.0:
		_x_think = EXTRA_THINK * _rng.randf_range(0.8, 1.2)
		_x_push = _crowd_push(game, pos)
		if hooks:
			_act_followup = false
			_poll_action(game)
	elif hooks and _act_followup and _act_cd <= 0.0:
		_act_followup = false
		_poll_action(game)
	var move := Vector2.ZERO
	match extra_mode:
		&"dance":
			move = _dance_move(pos, delta)
		&"wander":
			move = _wander_move(game, pos, delta)
	if hooks and _act:
		# An act (a bot posing as an NPC): close in at a brisk stroll, face, press.
		_act_fire = false
		_act_facing = false
		var act_move := _act_move(game, pos, move, delta, EXTRA_SPEED.y, AIM_STICK_STROLL)
		intent.action_pressed = _act_fire
		if _act or _act_fire or act_move != move:
			intent.move = act_move.limit_length(1.0)
			return
	if move == Vector2.ZERO:
		return
	move = (move + _x_push * EXTRA_SPACE_WEIGHT).limit_length(maxf(move.length(), _x_speed))
	if game and move.length_squared() > 0.0001 and not _safe(game, pos + _to3(move.normalized() * 0.8)):
		# Never stroll into danger: stop and plan again from here.
		_x_target = Vector3.INF
		_x_pause = _rng.randf_range(0.2, 0.6)
		var home := _flat(_home - pos)
		move = home.normalized() * _x_speed if home.length() > 0.3 and _safe(game, pos + _to3(home.normalized() * 0.8)) else Vector2.ZERO
	intent.move = move.limit_length(1.0)


func _wander_move(game: Minigame, pos: Vector3, delta: float) -> Vector2:
	if _x_pause > 0.0:
		_x_pause -= delta
		return Vector2.ZERO
	if _x_target == Vector3.INF:
		_x_target = _pick_wander_target(game)
		_x_walk = 0.0
	_x_walk += delta
	var to := _flat(_x_target - pos)
	if to.length() < 0.5 or _x_walk > EXTRA_WALK_MAX:
		_x_target = Vector3.INF
		_x_pause = _rng.randf_range(EXTRA_PAUSE.x, EXTRA_PAUSE.y)
		return Vector2.ZERO
	return to.normalized() * _x_speed * clampf(to.length() / 0.8, 0.5, 1.0)


## A random safe point within `wander_radius` of home (home itself when none is found).
func _pick_wander_target(game: Minigame) -> Vector3:
	for i in 6:
		var off := Vector2.RIGHT.rotated(_rng.randf() * TAU) * wander_radius * sqrt(_rng.randf())
		var c := _home + _to3(off)
		if game == null or _safe(game, c):
			return c
	return _home


## Loose circles: steer to a point a little ahead on a wobbling circle around the centre.
func _dance_move(pos: Vector3, delta: float) -> Vector2:
	if _x_pause > 0.0:
		_x_pause -= delta
		return Vector2.ZERO
	var speed := _x_speed * 6.0  # about the m/s this stick length walks (movement.max_speed 6)
	_dance_angle += _dance_dir * delta * speed / maxf(_dance_radius, 0.5)
	var r := _dance_radius * (1.0 + 0.15 * sin(_clock * 1.3 + float(rng_seed % 97)))
	var a := _dance_angle + _dance_dir * 0.5
	var target := _dance_center + Vector3(cos(a) * r, 0.0, sin(a) * r)
	var to := _flat(target - pos)
	if to.length() < 0.05:
		return Vector2.ZERO
	return to.normalized() * _x_speed * clampf(to.length() / 0.5, 0.4, 1.4)


## Steer-away vector from bodies (players and extras) within EXTRA_SPACE.
func _crowd_push(game: Minigame, pos: Vector3) -> Vector2:
	var push := Vector2.ZERO
	var bodies: Array[Player] = []
	if game:
		bodies.append_array(game.players)
	var stage := _stage_node()
	if stage:
		bodies.append_array(stage.extras)
	for o in bodies:
		if o == player or not is_instance_valid(o) or not o.alive:
			continue
		var away := _flat(pos - o.global_position)
		var d := away.length()
		if d < EXTRA_SPACE and d > 0.01:
			push += away / d * (1.0 - d / EXTRA_SPACE)
	return push


func _stage_node() -> Stage:
	if _stage_ref == null or not is_instance_valid(_stage_ref):
		_stage_ref = get_tree().get_first_node_in_group(&"stage") as Stage if is_inside_tree() else null
	return _stage_ref


# --- World --------------------------------------------------------------------------------

func _game() -> Minigame:
	if minigame and is_instance_valid(minigame):
		return minigame
	if not is_inside_tree():
		return null
	var stage := get_tree().get_first_node_in_group(&"stage") as Stage
	return stage.minigame if stage else null


## The minigame's optional `bot_aggression_scale` hint (1 when it has none).
static func _aggression_scale(game: Minigame) -> float:
	if game == null:
		return 1.0
	var v: Variant = game.get(&"bot_aggression_scale")
	return clampf(float(v), 0.0, 1.0) if v is float or v is int else 1.0


## The minigame's optional `bot_reaction_scale` hint (1 when it has none).
static func _reaction_scale(game: Minigame) -> float:
	if game == null or not is_instance_valid(game):
		return 1.0
	var v: Variant = game.get(&"bot_reaction_scale")
	return maxf(float(v), 0.0) if v is float or v is int else 1.0


## Other living players in this round.
func _others(game: Minigame) -> Array[Player]:
	var out: Array[Player] = []
	var pool: Array[Player] = []
	if game and not game.players.is_empty():
		pool = game.players
	elif is_inside_tree():
		var stage := get_tree().get_first_node_in_group(&"stage") as Stage
		if stage:
			pool.assign(stage.players.values())
	for p in pool:
		if p != player and is_instance_valid(p) and p.alive:
			out.append(p)
	return out


## The nearest player worth chasing: within chase range, and near the bot's goal or on the
## way to it (bots fight over what they want, they do not run away from it to brawl).
func _chase_candidate(game: Minigame, pos: Vector3) -> Player:
	var best: Player = null
	var best_d := CHASE_RADIUS * (0.5 + aggression)
	var to_goal := _flat(_goal - pos) if _has_goal else Vector2.ZERO
	var goal_far := to_goal.length() > CHASE_NEAR_GOAL
	var min_dot := cos(deg_to_rad(CHASE_ON_THE_WAY_DEG))
	for other in _others(game):
		var to := _flat(other.global_position - pos)
		var d := to.length()
		if d >= best_d or d < 0.01 or _is_ally(game, other):
			continue
		if goal_far and _flat(other.global_position - _goal).length() > CHASE_NEAR_GOAL \
				and to.normalized().dot(to_goal.normalized()) < min_dot:
			continue
		best_d = d
		best = other
	return best


func _reset() -> void:
	state = State.NONE
	_has_goal = false
	_arrived = false
	_rethink = false
	_target = null
	_recover_timer = 0.0
	_goal_timer = 0.0
	_shove_seen = 0.0
	_unsafe_time = 0.0
	_last_safe = Vector3.INF
	_safe_spot = Vector3.INF
	_prev_pos = Vector3.INF
	_crumbles.clear()
	_floor_crumbles = false
	_hop_pause = 0.0
	_air_dir = Vector2.ZERO
	_blocked_time = 0.0
	_jump_hold = 0.0
	_gap_jump = false
	_roll_gap_err()
	_end_act()
	_clear_plan()
	_hole_edge = Vector3.INF
	_wall_high = false
	_probe_timer = 0.0
	_radius_cache = 0.0
	_filt_valid = false
	_heavy_t = 0.0
	# A short, personal delay before the first decision so bots do not start in lockstep.
	_think_timer = _lerp_skill(START_DELAY) * _rng.randf_range(0.5, 1.5)


func _lerp_skill(range_: Vector2) -> float:
	return lerpf(range_.x, range_.y, _skill())


## The skill this bot plays with in this minigame: skill x the minigame's ot_skill_scale.
func _skill() -> float:
	return skill * _skill_scale


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


static func _to3(v: Vector2) -> Vector3:
	return Vector3(v.x, 0.0, v.y)
