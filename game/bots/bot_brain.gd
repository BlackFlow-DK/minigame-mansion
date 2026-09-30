class_name BotBrain
extends Node
## The bot brain: fills the same PlayerIntent a human controller would.
## The bot's ControllerComponent instances this script as its child `BotBrain` and calls
## `fill_intent` every tick on the authority (docs/contract.md "Bot brain").
##
## It knows nothing about specific minigames. It reads the world only through the Player
## API (positions, `alive`, `facing`, `velocity`, `is_on_floor`, the `got_hit` signal) and
## the generic Minigame hooks `get_bot_goal(player)` and `is_safe(pos)`.
##
## A small state machine: GOAL (walk to the minigame's goal and stop there), WANDER, CHASE
## (the nearest player), RECOVER (after a knock or when standing on unsafe ground). On top,
## every tick: a safety filter samples `is_safe` ahead and steers away from unsafe ground
## (or jumps a small gap), a shove check presses `action` when a player is in front within
## range, and a jump check hops when the bot is stuck against something.
##
## Human-like imperfection: decisions are only re-made every "think" (a random interval,
## slower for low skill), which is also the perception delay for chase targets; aim error
## per think; a reaction delay before shoving; a per-bot personality from the seed.
## Deterministic for a given seed: all randomness comes from its own RandomNumberGenerator.

enum State { NONE, GOAL, WANDER, CHASE, RECOVER }

# --- Tunables ---------------------------------------------------------------------------
# Pairs are (low skill, high skill); a bot lerps between them by `skill`.

## Seconds between decisions (also the perception delay for chase targets).
const THINK_INTERVAL := Vector2(0.9, 0.25)
## Seconds before the very first decision (countdown just ended), scaled by jitter.
const START_DELAY := Vector2(0.45, 0.1)
## Max aim error in degrees, rolled per think.
const AIM_ERROR_DEG := Vector2(24.0, 3.0)
## Seconds an enemy must be in front before the bot shoves.
const SHOVE_REACTION := Vector2(0.4, 0.1)
## Metres the safety filter looks ahead (plus speed * LOOKAHEAD_PER_SPEED).
const LOOKAHEAD := Vector2(0.9, 1.8)
const LOOKAHEAD_PER_SPEED := 0.25
## Chance per think to wander instead of going to the goal (scaled by 1 - skill).
const WANDER_CHANCE := 0.35
## Chance per think to stand still for one think (scaled by 1 - skill).
const HESITATE_CHANCE := 0.12

## Within this distance of the goal the bot stops (m).
const ARRIVE_RADIUS := 0.6
## Within this distance of the goal the bot slows down (m).
const SLOW_RADIUS := 1.6
## Wandering further than this from the goal pulls the bot back (m).
const WANDER_LEASH := 5.0
## Seconds between goal refreshes (random in range).
const GOAL_REFRESH := Vector2(2.0, 5.0)

## Players nearer than this (m, scaled by 0.5 + aggression) may be chased.
const CHASE_RADIUS := 6.0
## Shove when an enemy is within this distance (m, centre to centre)...
const SHOVE_RANGE := 1.3
## ...and within this angle of `facing` (degrees).
const SHOVE_CONE_DEG := 35.0
## Seconds between the bot's own shove presses (random in range; the shove component has its own cooldown too).
const SHOVE_COOLDOWN := Vector2(0.7, 1.4)

## Horizontal speed (m/s) above which the bot treats itself as knocked.
const KNOCK_SPEED := 7.0
## Seconds spent recovering after a knock (random in range).
const RECOVER_TIME := Vector2(0.5, 1.0)

## Moving but slower than this (m/s) on the floor for BLOCKED_TIME seconds = stuck: jump.
const BLOCKED_SPEED := 0.3
const BLOCKED_TIME := 0.35
## Widest unsafe gap (m) the bot will try to jump across.
const GAP_JUMP_MAX := 2.0
## Seconds the jump button stays held after a press.
const JUMP_HOLD := 0.25
## Seconds between jump presses.
const JUMP_COOLDOWN := 0.5

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

var _rng := RandomNumberGenerator.new()
var _configured: bool = false
var _speed_scale: float = 1.0
var _strafe_bias: float = 0.0   # radians; approach angle when chasing from afar
var _turn_sign: float = 1.0     # which way the bot tries first when steering around danger

# --- Runtime state ------------------------------------------------------------------------

var state: State = State.NONE
var _think_timer: float = 0.0
var _goal_timer: float = 0.0
var _recover_timer: float = 0.0
var _goal: Vector3 = Vector3.ZERO
var _has_goal: bool = false
var _target: Player = null
var _target_seen: Vector3 = Vector3.ZERO
var _wander_dir: Vector2 = Vector2.ZERO
var _aim_error: float = 0.0
var _move_scale: float = 1.0
var _shove_reaction: float = 0.2
var _shove_seen: float = 0.0
var _shove_cooldown: float = 0.0
var _blocked_time: float = 0.0
var _jump_hold: float = 0.0
var _jump_cooldown: float = 0.0
var _gap_jump: bool = false


func _ready() -> void:
	if player and not player.got_hit.is_connected(_on_got_hit):
		player.got_hit.connect(_on_got_hit)


## Seeds the brain and rolls its personality. `skill`/`aggression` < 0 = roll from the seed.
## Without a call, the first `fill_intent` configures with a random seed.
func configure(seed_value: int, skill_value: float = -1.0, aggression_value: float = -1.0) -> void:
	rng_seed = seed_value
	_rng.seed = seed_value
	skill = clampf(skill_value, 0.0, 1.0) if skill_value >= 0.0 else _rng.randf_range(0.35, 0.95)
	aggression = clampf(aggression_value, 0.0, 1.0) if aggression_value >= 0.0 else _rng.randf_range(0.2, 0.85)
	_speed_scale = _rng.randf_range(0.85, 1.0)
	_strafe_bias = _rng.randf_range(-0.4, 0.4)
	_turn_sign = 1.0 if _rng.randf() < 0.5 else -1.0
	_configured = true
	_reset()


## Fills `intent` for this tick. Dead or frozen: empty intent.
func fill_intent(intent: PlayerIntent, delta: float) -> void:
	if not _configured:
		configure(randi())
	if player == null or not player.alive or player.frozen:
		intent.clear()
		if state != State.NONE:
			_reset()
		return
	if player.control_locked:
		intent.clear()
		_enter_recover()
		return

	_think_timer -= delta
	_goal_timer -= delta
	_recover_timer -= delta
	_shove_cooldown -= delta
	_jump_cooldown -= delta

	var game := _game()
	var pos := player.global_position
	var hvel := Vector2(player.velocity.x, player.velocity.z)
	if hvel.length() > KNOCK_SPEED and state != State.RECOVER:
		_enter_recover()
	if _think_timer <= 0.0:
		_think(game, pos)

	var move := _desired_move(game, pos)
	if state != State.RECOVER and move.length_squared() > 0.0001:
		move = move.rotated(_aim_error)
	_gap_jump = false
	move = _safety_filter(game, pos, move, hvel)
	intent.move = move.limit_length(1.0)

	_fill_jump(intent, delta, hvel)
	intent.action_pressed = _want_shove(delta, pos)


# --- Decisions ------------------------------------------------------------------------------

func _think(game: Minigame, pos: Vector3) -> void:
	_think_timer = _lerp_skill(THINK_INTERVAL) * _rng.randf_range(0.7, 1.3)
	_aim_error = deg_to_rad(_lerp_skill(AIM_ERROR_DEG)) * _rng.randf_range(-1.0, 1.0)
	_move_scale = _speed_scale * _rng.randf_range(0.85, 1.0)
	_shove_reaction = _lerp_skill(SHOVE_REACTION) * _rng.randf_range(0.8, 1.25)
	if _rng.randf() < HESITATE_CHANCE * (1.0 - skill):
		_move_scale = 0.0
	if _goal_timer <= 0.0 or not _has_goal:
		_goal = game.get_bot_goal(player) if game else pos
		_has_goal = true
		_goal_timer = _rng.randf_range(GOAL_REFRESH.x, GOAL_REFRESH.y)

	# Perception snapshot: chase targets are only seen at think time (reaction delay).
	_target = _nearest_enemy(game, pos, CHASE_RADIUS * (0.5 + aggression))
	if _target:
		_target_seen = _target.global_position

	if state == State.RECOVER and _recover_timer > 0.0:
		return
	if game and not game.is_safe(pos):
		_enter_recover()
		return
	var roll := _rng.randf()
	if _target and roll < aggression:
		state = State.CHASE
	elif _rng.randf() < WANDER_CHANCE * (1.0 - skill):
		state = State.WANDER
		if _wander_dir == Vector2.ZERO or _rng.randf() < 0.6:
			_wander_dir = Vector2.RIGHT.rotated(_rng.randf() * TAU)
	else:
		state = State.GOAL


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


func _toward_goal(pos: Vector3) -> Vector2:
	if not _has_goal:
		return Vector2.ZERO
	var to := _flat(_goal - pos)
	var d := to.length()
	if d < ARRIVE_RADIUS:
		return Vector2.ZERO
	return to.normalized() * clampf(d / SLOW_RADIUS, 0.4, 1.0)


func _recover_move(game: Minigame, pos: Vector3) -> Vector2:
	if game and not game.is_safe(pos):
		return _toward_safety(game, pos)
	var hvel := Vector2(player.velocity.x, player.velocity.z)
	var home := _flat(_goal - pos).normalized() if _has_goal else Vector2.ZERO
	if hvel.length() > 1.0:
		return (-hvel.normalized() * 1.5 + home).normalized()
	return home


func _enter_recover() -> void:
	state = State.RECOVER
	_recover_timer = _rng.randf_range(RECOVER_TIME.x, RECOVER_TIME.y)
	_think_timer = minf(_think_timer, _recover_timer)


func _on_got_hit(_impulse: Vector3, _source_slot: int) -> void:
	if player and player.alive:
		_enter_recover()


# --- Safety -----------------------------------------------------------------------------

## Keeps `move` off unsafe ground: same direction if the path ahead is safe, a jump if a
## small gap can be crossed, else the nearest safe rotation, else back toward safe ground.
func _safety_filter(game: Minigame, pos: Vector3, move: Vector2, hvel: Vector2) -> Vector2:
	if game == null:
		return move
	var mag := move.length()
	if mag < 0.05:
		# Standing still: do not let momentum carry us into danger.
		if hvel.length() > 0.5 and not game.is_safe(pos + _to3(hvel * 0.4)):
			return -hvel.normalized()
		return move
	var dir := move / mag
	var look := _lerp_skill(LOOKAHEAD) + hvel.length() * LOOKAHEAD_PER_SPEED
	if _path_safe(game, pos, dir, look):
		return move
	if state != State.RECOVER and game.is_safe(pos) and _gap_jumpable(game, pos, dir):
		_gap_jump = true
		return dir
	for i in range(1, 7):
		for s: float in [_turn_sign, -_turn_sign]:
			var cand := dir.rotated(deg_to_rad(30.0 * i) * s)
			if _path_safe(game, pos, cand, look):
				return cand * mag
	return _toward_safety(game, pos)


func _path_safe(game: Minigame, pos: Vector3, dir: Vector2, look: float) -> bool:
	for t: float in [0.35, 0.7, 1.0]:
		if not game.is_safe(pos + _to3(dir * look * t)):
			return false
	return true


## True when the ground ahead is unsafe but safe again (with room to land) within GAP_JUMP_MAX.
## Low-skill bots only try narrower gaps.
func _gap_jumpable(game: Minigame, pos: Vector3, dir: Vector2) -> bool:
	var reach := GAP_JUMP_MAX * lerpf(0.6, 1.0, skill)
	var d := 0.3
	var seen_unsafe := false
	while d <= reach:
		var safe := game.is_safe(pos + _to3(dir * d))
		if not safe:
			seen_unsafe = true
		elif seen_unsafe:
			return game.is_safe(pos + _to3(dir * (d + 0.5)))
		d += 0.25
	return false


## Direction toward the nearest safe ground, preferring the goal side. Zero if none found.
func _toward_safety(game: Minigame, pos: Vector3) -> Vector2:
	var home := _flat(_goal - pos).normalized() if _has_goal else Vector2.ZERO
	for r: float in [0.75, 1.5, 3.0, 6.0]:
		var best := Vector2.ZERO
		var best_score := -INF
		for i in 16:
			var cand := Vector2.RIGHT.rotated(TAU * i / 16.0)
			if game.is_safe(pos + _to3(cand * r)):
				var score := cand.dot(home)
				if score > best_score:
					best_score = score
					best = cand
		if best != Vector2.ZERO:
			return best
	return Vector2.ZERO


# --- Buttons ------------------------------------------------------------------------------

func _fill_jump(intent: PlayerIntent, delta: float, hvel: Vector2) -> void:
	var on_floor := player.is_on_floor()
	if on_floor and intent.move.length() > 0.5 and hvel.length() < BLOCKED_SPEED:
		_blocked_time += delta
	else:
		_blocked_time = 0.0
	var want := _gap_jump or _blocked_time > BLOCKED_TIME * lerpf(1.6, 1.0, skill)
	intent.jump_pressed = false
	if want and on_floor and _jump_cooldown <= 0.0:
		intent.jump_pressed = true
		_jump_hold = JUMP_HOLD
		_jump_cooldown = JUMP_COOLDOWN
		_blocked_time = 0.0
	intent.jump_held = _jump_hold > 0.0
	_jump_hold -= delta


## Presses action (one tick) once an enemy has been in front within range for the reaction time.
func _want_shove(delta: float, pos: Vector3) -> bool:
	if _enemy_in_front(pos):
		_shove_seen += delta
	else:
		_shove_seen = 0.0
	if _shove_seen >= _shove_reaction and _shove_cooldown <= 0.0:
		_shove_seen = 0.0
		_shove_cooldown = _rng.randf_range(SHOVE_COOLDOWN.x, SHOVE_COOLDOWN.y)
		return true
	return false


func _enemy_in_front(pos: Vector3) -> bool:
	var face := _flat(player.facing)
	if face.length_squared() < 0.0001:
		return false
	face = face.normalized()
	var min_dot := cos(deg_to_rad(SHOVE_CONE_DEG))
	for other in _others(_game()):
		var to := _flat(other.global_position - pos)
		var d := to.length()
		if d <= SHOVE_RANGE and d > 0.01 and face.dot(to / d) >= min_dot:
			return true
	return false


# --- World --------------------------------------------------------------------------------

func _game() -> Minigame:
	if minigame and is_instance_valid(minigame):
		return minigame
	if not is_inside_tree():
		return null
	var stage := get_tree().get_first_node_in_group(&"stage") as Stage
	return stage.minigame if stage else null


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


func _nearest_enemy(game: Minigame, pos: Vector3, max_dist: float) -> Player:
	var best: Player = null
	var best_d := max_dist
	for other in _others(game):
		var d := _flat(other.global_position - pos).length()
		if d < best_d:
			best_d = d
			best = other
	return best


func _reset() -> void:
	state = State.NONE
	_has_goal = false
	_target = null
	_recover_timer = 0.0
	_goal_timer = 0.0
	_shove_seen = 0.0
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
