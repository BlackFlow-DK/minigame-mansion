class_name BotBrain
extends Node
## The bot brain: fills the same PlayerIntent a human controller would.
## The bot's ControllerComponent instances this script as its child `BotBrain` and calls
## `fill_intent` every tick on the authority (docs/contract.md "Bot brain").
##
## It knows nothing about specific minigames. It reads the world only through the Player
## API (positions, `alive`, `facing`, `velocity`, `is_on_floor`, the `got_hit` signal) and
## the generic Minigame hooks `get_bot_goal(player)`, `is_safe(pos)` and the optional
## `bot_rethink_requested` signal (raised by `Minigame.request_bot_rethink`).
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
## Goals: the bot keeps its goal until it is reached, turns unsafe, gets stale (a few
## seconds), or the minigame calls `request_bot_rethink` (after the bot's reaction delay).
## `get_bot_goal` is called only then, so a goal function may be random or stateful.
##
## Human-like imperfection: decisions are only re-made every "think" (a random interval,
## slower for low skill), which is also the perception delay for chase targets and goals;
## aim error per think; reaction delays before shoving and before reacting to unsafe
## ground; a per-bot personality from the seed.
## Deterministic for a given seed: all randomness comes from its own RandomNumberGenerator.
##
## Optional minigame hint: a minigame may declare `var bot_aggression_scale: float` (0..1,
## default 1). It scales how often bots chase, and at 0 they never shove (the lobby: calm).
## `Minigame.is_ally(a, b)` (teams): bots never chase an ally and never shove while one is in
## front of them.
## Bots ignore NPC extras (not in `Minigame.players`); a shove may still hit one in passing.
##
## NPC extras (`Stage.spawn_extras`) use a cheap separate mode instead of the state machine:
## `configure_extra(mode, seed, center)` with mode `wander` (walk between random safe points
## within `wander_radius` of home, pausing in between), `dance` (loose circles around `center`,
## or home: give a group the same centre for a crowd dance) or `idle` (stand, still reacting
## to knocks). Extras never shove or jump, keep a little space, re-plan after a knock, and are
## deterministic for a seed.

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
## Seconds the jump button stays held after a press (a full jump).
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

var _rng := RandomNumberGenerator.new()
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
var _hooked: Minigame = null
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


## Seeds the brain and rolls its personality. `skill`/`aggression` < 0 = roll from the seed.
## Without a call, the first `fill_intent` configures with a random seed.
func configure(seed_value: int, skill_value: float = -1.0, aggression_value: float = -1.0) -> void:
	rng_seed = seed_value
	_rng.seed = seed_value
	extra_mode = &""
	skill = clampf(skill_value, 0.0, 1.0) if skill_value >= 0.0 else _rng.randf_range(0.35, 0.95)
	aggression = clampf(aggression_value, 0.0, 1.0) if aggression_value >= 0.0 else _rng.randf_range(0.2, 0.85)
	_speed_scale = _rng.randf_range(0.9, 1.0)
	_strafe_bias = _rng.randf_range(-0.4, 0.4)
	_turn_sign = 1.0 if _rng.randf() < 0.5 else -1.0
	_danger_reaction = _lerp_skill(DANGER_REACTION) * _rng.randf_range(0.8, 1.25)
	_configured = true
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


## Fills `intent` for this tick. Dead or frozen: empty intent.
func fill_intent(intent: PlayerIntent, delta: float) -> void:
	if not _configured:
		configure(randi())
	if extra_mode != &"":
		_fill_extra(intent, delta)
		return
	if player == null or not player.alive or player.frozen:
		intent.clear()
		if state != State.NONE:
			_reset()
		return
	var game := _game()
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
				or (game and not game.is_safe(landing)):
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
	if game and not game.is_safe(pos):
		if _unsafe_time == 0.0 and _prev_pos != Vector3.INF and not game.is_safe(_prev_pos):
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
	if _think_timer <= 0.0:
		_think(game, pos)

	var move := _desired_move(game, pos)
	if state != State.RECOVER and move.length_squared() > 0.0001:
		move = move.rotated(_aim_error)
	if state != State.RECOVER and state != State.NONE:
		move = _keep_space(game, pos, move)
	_gap_jump = false
	move = _safety_filter(game, pos, move, hvel)
	intent.move = move.limit_length(1.0)

	_fill_jump(intent, delta, hvel, game, pos)
	intent.action_pressed = _want_shove(delta, pos, game)
	_prev_pos = pos


# --- Decisions ------------------------------------------------------------------------------

func _think(game: Minigame, pos: Vector3) -> void:
	_think_timer = _lerp_skill(THINK_INTERVAL) * _rng.randf_range(0.7, 1.3)
	_aim_error = deg_to_rad(_lerp_skill(AIM_ERROR_DEG)) * _rng.randf_range(-1.0, 1.0)
	_move_scale = _speed_scale * _rng.randf_range(0.9, 1.0)
	_shove_reaction = _lerp_skill(SHOVE_REACTION) * _rng.randf_range(0.8, 1.25)
	if _rng.randf() < HESITATE_CHANCE * (1.0 - skill) and not _floor_crumbles:
		_move_scale = 0.0
	_update_goal(game, pos)

	# Perception snapshot: chase targets are only seen at think time (reaction delay).
	_target = _chase_candidate(game, pos)
	if _target:
		_target_seen = _target.global_position

	if state == State.RECOVER and (_recover_timer > 0.0 or _unsafe_time > 0.0):
		return
	if game and not game.is_safe(pos):
		_enter_recover(false)
		return
	var roll := _rng.randf()
	if _target and roll < aggression * _aggression_scale(game):
		state = State.CHASE
	elif _rng.randf() < WANDER_CHANCE * (1.0 - skill):
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
	if not _has_goal or _rethink or reached or _goal_timer <= 0.0 or not game.is_safe(_goal):
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
	if game and not game.is_safe(pos):
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


func _on_got_hit(_impulse: Vector3, _source_slot: int) -> void:
	if player == null or not player.alive:
		return
	if extra_mode != &"":
		# Knocked: stand dazed a moment, then pick a fresh point from wherever it landed.
		_x_target = Vector3.INF
		_x_pause = maxf(_x_pause, _rng.randf_range(0.4, 1.0))
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
		if hvel.length() > 0.5 and not game.is_safe(pos + _to3(hvel * 0.3)):
			return -hvel.normalized()
		return move
	var dir := move / mag
	var look := _lerp_skill(LOOKAHEAD) + hvel.length() * LOOKAHEAD_PER_SPEED
	if _path_safe(game, pos + drift, dir, look):
		return move
	if state != State.RECOVER and game.is_safe(pos):
		var gap := _gap_check(game, pos, dir, hvel)
		if gap > 0:
			_gap_jump = gap == 2
			return dir
	for i in range(1, 10):
		for s: float in [_turn_sign, -_turn_sign]:
			var cand := dir.rotated(deg_to_rad(20.0 * i) * s)
			if _path_safe(game, pos + drift, cand, look):
				_turn_sign = s
				return cand * maxf(mag, 0.6)
	if game.is_safe(pos):
		# No fully safe way: follow the one that stays safe longest (along the boundary),
		# else jump a gap in any direction. Keep moving: lingering is how floors give way.
		var open := _most_open(game, pos, dir, look)
		if open != Vector2.ZERO:
			return open * maxf(mag, 0.6)
		if state != State.RECOVER:
			for i in 12:
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
		var cand := Vector2.RIGHT.rotated(TAU * i / 24.0)
		var run := 0.0
		var d := 0.2
		while d <= look + 0.01 and game.is_safe(pos + _to3(cand * d)):
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
	if not game.is_safe(from):
		return false
	for t: float in [0.25, 0.5, 0.75, 1.0]:
		if not game.is_safe(from + _to3(dir * look * t)):
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
		var safe := game.is_safe(pos + _to3(dir * d))
		if not safe and edge < 0.0:
			edge = d
		elif safe and edge >= 0.0:
			if not game.is_safe(pos + _to3(dir * (d + 0.5))):
				return 0
			if d - edge > reach - GAP_TAKEOFF:
				return 0
			if edge <= GAP_TAKEOFF + 0.15:
				var speed := hvel.dot(dir)
				var can_jump := player.is_on_floor() and _jump_cooldown <= 0.0
				return 2 if speed >= GAP_MIN_SPEED and can_jump else 0
			return 1
		d += 0.15
	return 0


## Direction toward safe ground. Picks a safe spot once and runs for it (no dithering) until
## it is reached or stops being safe. The spot: the nearest safe ground in a widening
## search, preferring the goal side and ground that stays safe a little further on.
## Never zero while any fallback exists: the last safe spot, then the goal.
func _toward_safety(game: Minigame, pos: Vector3) -> Vector2:
	if _safe_spot != Vector3.INF and game.is_safe(_safe_spot) and _flat(_safe_spot - pos).length() > 0.15:
		return _flat(_safe_spot - pos).normalized()
	_safe_spot = Vector3.INF
	var home := _flat(_goal - pos).normalized() if _has_goal else Vector2.ZERO
	for r: float in [0.5, 1.0, 1.5, 2.0, 3.0, 4.5, 6.0, 9.0]:
		var best := Vector2.ZERO
		var best_score := -INF
		for i in 24:
			var cand := Vector2.RIGHT.rotated(TAU * i / 24.0)
			if game.is_safe(pos + _to3(cand * r)):
				var score := cand.dot(home) * 0.3
				if game.is_safe(pos + _to3(cand * (r + 0.6))):
					score += 1.0
				if score > best_score:
					best_score = score
					best = cand
		if best != Vector2.ZERO:
			var deeper := pos + _to3(best * (r + 0.4))
			_safe_spot = deeper if game.is_safe(deeper) else pos + _to3(best * r)
			return best
	if _last_safe != Vector3.INF and _flat(_last_safe - pos).length() > 0.2:
		return _flat(_last_safe - pos).normalized()
	return home


# --- Buttons ------------------------------------------------------------------------------

func _fill_jump(intent: PlayerIntent, delta: float, hvel: Vector2, game: Minigame, pos: Vector3) -> void:
	var on_floor := player.is_on_floor()
	if on_floor and intent.move.length() > 0.5 and hvel.length() < BLOCKED_SPEED:
		_blocked_time += delta
	else:
		_blocked_time = 0.0
	var want := _gap_jump or _blocked_time > BLOCKED_TIME * lerpf(1.6, 1.0, skill)
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
		_jump_hold = JUMP_HOLD
		_jump_cooldown = JUMP_COOLDOWN
		_blocked_time = 0.0
	intent.jump_held = _jump_hold > 0.0
	_jump_hold -= delta


## True when a hop at the current velocity lands (with some slack either way) on safe ground.
func _landing_safe(game: Minigame, pos: Vector3, hvel: Vector2) -> bool:
	var land := hvel * HOP_AIR_TIME
	for k: float in [0.8, 1.0, 1.2]:
		if not game.is_safe(pos + _to3(land * k)):
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
		return
	_clock += delta
	var pos := player.global_position
	if _home == Vector3.INF:
		_home = pos
		if _dance_center == Vector3.INF and extra_mode == &"dance":
			_dance_center = pos
	var game := _game()
	_x_think -= delta
	if _x_think <= 0.0:
		_x_think = EXTRA_THINK * _rng.randf_range(0.8, 1.2)
		_x_push = _crowd_push(game, pos)
	var move := Vector2.ZERO
	match extra_mode:
		&"dance":
			move = _dance_move(pos, delta)
		&"wander":
			move = _wander_move(game, pos, delta)
	if move == Vector2.ZERO:
		return
	move = (move + _x_push * EXTRA_SPACE_WEIGHT).limit_length(maxf(move.length(), _x_speed))
	if game and move.length_squared() > 0.0001 and not game.is_safe(pos + _to3(move.normalized() * 0.8)):
		# Never stroll into danger: stop and plan again from here.
		_x_target = Vector3.INF
		_x_pause = _rng.randf_range(0.2, 0.6)
		var home := _flat(_home - pos)
		move = home.normalized() * _x_speed if home.length() > 0.3 and game.is_safe(pos + _to3(home.normalized() * 0.8)) else Vector2.ZERO
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
		if game == null or game.is_safe(c):
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
	# A short, personal delay before the first decision so bots do not start in lockstep.
	_think_timer = _lerp_skill(START_DELAY) * _rng.randf_range(0.5, 1.5)


func _lerp_skill(range_: Vector2) -> float:
	return lerpf(range_.x, range_.y, skill)


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


static func _to3(v: Vector2) -> Vector3:
	return Vector3(v.x, 0.0, v.y)
