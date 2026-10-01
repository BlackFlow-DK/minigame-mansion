class_name CannonSchedule
extends RefCounted
## Cannon Alley's clockwork, as pure functions: where the cannons stand, which cannon fires
## when and how fast (a deterministic function of a seed), and where every ball is at any
## round time. Every peer builds the same schedule from the host-sent seed and computes the
## same ball positions from its own round clock, so no ball is ever synced.
##
## Geometry (metres): the lane is x in [-LANE_HALF_X, LANE_HALF_X], z in [-LANE_HALF_Z,
## LANE_HALF_Z], floor top y = 0. The far row of cannons stands on the deck behind z = -5 and
## fires +Z; the near row behind z = +5 fires -Z. The rows are offset by half a spacing, so
## together they cover a column every 1.25 m: one side's volley leaves gaps exactly where the
## other side's cannons aim, both sides together leave none (then you jump or get lucky).

const LANE_HALF_X := 9.5
const LANE_HALF_Z := 5.0
## Gun deck height; cannons stand on it.
const DECK_H := 0.35
const BALL_RADIUS := 0.35
## Centre height of a ball leaving the muzzle (deck + trunnion height of cannon_cannon.glb).
const MUZZLE_Y := DECK_H + 0.62
## Centre height of a rolling ball (it sits on the floor).
const ROLL_Y := BALL_RADIUS
## Gravity on a ball dropping from the muzzle to the floor (m/s^2), and its one bounce.
const BALL_GRAVITY := 22.0
const BOUNCE := 0.28
## Blob capsule (docs/contract.md): radius 0.4, height 1.0, so its core runs 0.4..0.6 m up.
const BLOB_RADIUS := 0.4
## A hit needs the ball centre this close to the blob's capsule core (a hair under touching).
const HIT_RADIUS := BALL_RADIUS + BLOB_RADIUS - 0.05
## Seconds a cannon's fuse burns before it fires.
const TELEGRAPH := 0.6
## At or below this speed a ball is "slow": jumpable (yellow warning, bots jump it).
const SLOW_SPEED := 6.0
const MIN_SPEED := 5.0
const MAX_SPEED := 9.0
## Cannon x positions: far row (fires +Z), near row (fires -Z).
const FAR_X: Array[float] = [-7.5, -5.0, -2.5, 0.0, 2.5, 5.0, 7.5]
const NEAR_X: Array[float] = [-8.75, -6.25, -3.75, -1.25, 1.25, 3.75, 6.25, 8.75]
## Where a cannon's origin stands (its muzzle is 0.95 m in front of it, on the lane edge).
const CANNON_Z := LANE_HALF_Z + 0.95

## Schedule shape: first shot, seconds to full intensity, when the schedule stops.
const START_DELAY := 2.0
const RAMP_TIME := 40.0
const END_TIME := 80.0
## From here on the finale: volleys, crossfire and two-sided slow walls in quick succession,
## so a round rarely reaches the 60 s cap.
const FINALE_TIME := 46.0
## A cannon fires at most once per this many seconds (fuse + recoil).
const CANNON_REST := 0.9

enum Pattern { SINGLE, DOUBLE, ALTERNATE, VOLLEY, SWEEP, CROSSFIRE, SLOW_WALL }


## One shot. `t` is the fire time on the round clock; the fuse burns from t - TELEGRAPH.
class Shot:
	extends RefCounted
	var id: int = 0
	var t: float = 0.0
	var cannon: int = 0
	var speed: float = 6.0
	var pattern: int = 0
	## Per-peer bookkeeping of the minigame (0 waiting, 1 fuse burning, 2 flying, 3 done).
	var phase: int = 0

	func _init(id_: int = 0, t_: float = 0.0, cannon_: int = 0, speed_: float = 6.0, pattern_: int = 0) -> void:
		id = id_
		t = t_
		cannon = cannon_
		speed = speed_
		pattern = pattern_


# --- Cannons -----------------------------------------------------------------------------

static func cannon_count() -> int:
	return FAR_X.size() + NEAR_X.size()


static func is_far(cannon: int) -> bool:
	return cannon < FAR_X.size()


static func cannon_x(cannon: int) -> float:
	return FAR_X[cannon] if is_far(cannon) else NEAR_X[cannon - FAR_X.size()]


## +1 when the cannon fires toward +Z (far row), -1 for the near row.
static func cannon_dir(cannon: int) -> float:
	return 1.0 if is_far(cannon) else -1.0


## Where cannon `cannon` stands (origin, on the deck) and the way it faces.
static func cannon_transform(cannon: int) -> Transform3D:
	var d := cannon_dir(cannon)
	var basis := Basis.IDENTITY if d > 0.0 else Basis(Vector3.UP, PI)
	return Transform3D(basis, Vector3(cannon_x(cannon), DECK_H, -d * CANNON_Z))


# --- Ball motion (pure) ---------------------------------------------------------------------

## Metres a ball rolls from the muzzle (lane edge) until it touches the opposite deck.
static func travel_distance() -> float:
	return 2.0 * LANE_HALF_Z - BALL_RADIUS


static func flight_time(shot: Shot) -> float:
	return travel_distance() / shot.speed


## True while the ball of `shot` is out of the muzzle and has not reached the far side.
static func is_flying(shot: Shot, t: float) -> bool:
	return t >= shot.t and t < shot.t + flight_time(shot)


## Ball centre z at round time `t` (clamped to its flight).
static func ball_z(shot: Shot, t: float) -> float:
	var d := cannon_dir(shot.cannon)
	var s := clampf((t - shot.t) * shot.speed, 0.0, travel_distance())
	return -d * LANE_HALF_Z + d * s


## Ball centre height `tau` seconds after firing: it drops off the deck, bounces once, rolls.
static func ball_height(tau: float) -> float:
	var drop := MUZZLE_Y - ROLL_Y
	var t_land := sqrt(2.0 * drop / BALL_GRAVITY)
	if tau < t_land:
		return MUZZLE_Y - 0.5 * BALL_GRAVITY * tau * tau
	var v := BALL_GRAVITY * t_land * BOUNCE
	var u := tau - t_land
	if u < 2.0 * v / BALL_GRAVITY:
		return ROLL_Y + v * u - 0.5 * BALL_GRAVITY * u * u
	return ROLL_Y


## Ball centre at round time `t` (only meaningful while `is_flying`).
static func ball_position(shot: Shot, t: float) -> Vector3:
	return Vector3(cannon_x(shot.cannon), ball_height(maxf(t - shot.t, 0.0)), ball_z(shot, t))


## Radians the ball has rolled about its travel axis by round time `t`.
static func ball_roll(shot: Shot, t: float) -> float:
	return clampf((t - shot.t) * shot.speed, 0.0, travel_distance()) / BALL_RADIUS * cannon_dir(shot.cannon)


## True when a ball centred at `ball` touches a blob standing with its feet at `feet`
## (sphere against the blob's capsule core).
static func touches(ball: Vector3, feet: Vector3, radius: float = HIT_RADIUS) -> bool:
	var core_y := clampf(ball.y, feet.y + BLOB_RADIUS, feet.y + 1.0 - BLOB_RADIUS)
	return ball.distance_squared_to(Vector3(feet.x, core_y, feet.z)) < radius * radius


## Host plausibility check for a client's hit report: were `feet` within reach of the ball's
## path at some time in [t_now - back, t_now + ahead]? Generous on purpose (the client's
## clock lags the host by a network trip), strict enough to refuse nonsense.
static func plausible_hit(shot: Shot, feet: Vector3, t_now: float, back: float = 1.0, ahead: float = 0.3) -> bool:
	if feet.y > 1.8 or absf(feet.x - cannon_x(shot.cannon)) > HIT_RADIUS + 0.45:
		return false
	var t0 := maxf(t_now - back, shot.t)
	var t1 := minf(t_now + ahead, shot.t + flight_time(shot))
	if t1 < t0:
		return false
	var z0 := ball_z(shot, t0)
	var z1 := ball_z(shot, t1)
	var slack := HIT_RADIUS + 0.6
	return feet.z >= minf(z0, z1) - slack and feet.z <= maxf(z0, z1) + slack


# --- Schedule -----------------------------------------------------------------------------------

## The whole round's shots for `seed_value`, sorted by fire time, ids 0..n-1. Same seed,
## same shots, on every peer. Patterns get denser, faster and nastier over RAMP_TIME:
## singles and pairs first, then volleys, sweeps, crossfire and slow walls (jump them).
static func build(seed_value: int) -> Array[Shot]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var shots: Array[Shot] = []
	var rest: Array[float] = []
	rest.resize(cannon_count())
	rest.fill(-1000.0)
	var t := START_DELAY
	while t < END_TIME:
		var k := intensity(t)
		var pattern := _pick_pattern(rng, t)
		var end_t := _emit(pattern, t, k, rng, shots, rest)
		# Late on, a stray single shot lands in the middle of the pause.
		var gap := lerpf(2.1, 0.55, k) * rng.randf_range(0.85, 1.15)
		if t >= FINALE_TIME:
			gap *= 0.75
		if k > 0.5 and rng.randf() < (k - 0.5) * 1.6:
			_add(shots, rest, end_t + gap * 0.5, rng.randi_range(0, cannon_count() - 1), _speed(k, rng), Pattern.SINGLE)
		t = end_t + gap
	shots.sort_custom(func(a: Shot, b: Shot) -> bool: return a.t < b.t or (a.t == b.t and a.cannon < b.cannon))
	for i in shots.size():
		shots[i].id = i
	return shots


## 0 at the first shot, 1 after RAMP_TIME.
static func intensity(t: float) -> float:
	return clampf((t - START_DELAY) / RAMP_TIME, 0.0, 1.0)


static func _pick_pattern(rng: RandomNumberGenerator, t: float) -> int:
	var weights: Array
	if t < 9.0:
		weights = [5, 3, 2, 0, 0, 0, 0]
	elif t < 20.0:
		weights = [2, 2, 2, 2, 2, 0, 1]
	elif t < 34.0:
		weights = [0, 1, 2, 2, 2, 2, 2]
	elif t < FINALE_TIME:
		weights = [0, 0, 2, 2, 2, 3, 3]
	else:
		weights = [0, 0, 0, 2, 1, 3, 4]
	var total := 0
	for w: int in weights:
		total += w
	var roll := rng.randi_range(0, total - 1)
	for i in weights.size():
		roll -= int(weights[i])
		if roll < 0:
			return i
	return Pattern.SINGLE


static func _speed(k: float, rng: RandomNumberGenerator) -> float:
	return clampf(lerpf(5.4, 8.0, k) + rng.randf_range(-0.6, 0.9), MIN_SPEED, MAX_SPEED)


static func _side(side_far: bool) -> Array[int]:
	var out: Array[int] = []
	if side_far:
		for i in FAR_X.size():
			out.append(i)
	else:
		for i in NEAR_X.size():
			out.append(FAR_X.size() + i)
	return out


## Adds the pattern's shots starting at `t`; returns the time of its last shot.
static func _emit(pattern: int, t: float, k: float, rng: RandomNumberGenerator, shots: Array[Shot], rest: Array[float]) -> float:
	var far := rng.randf() < 0.5
	match pattern:
		Pattern.SINGLE:
			_add(shots, rest, t, rng.randi_range(0, cannon_count() - 1), _speed(k, rng), pattern)
			return t
		Pattern.DOUBLE:
			var a: Array[int] = _side(true)
			var b: Array[int] = _side(false)
			var dt := 0.0 if rng.randf() < 0.5 else 0.3
			_add(shots, rest, t, a[rng.randi_range(0, a.size() - 1)], _speed(k, rng), pattern)
			_add(shots, rest, t + dt, b[rng.randi_range(0, b.size() - 1)], _speed(k, rng), pattern)
			return t + dt
		Pattern.ALTERNATE:
			var n := rng.randi_range(4, 6) + (1 if k > 0.7 else 0)
			var dt := lerpf(0.55, 0.32, k)
			var speed := _speed(k, rng)
			for i in n:
				var side := _side(far if i % 2 == 0 else not far)
				_add(shots, rest, t + dt * i, side[rng.randi_range(0, side.size() - 1)], speed, pattern)
			return t + dt * (n - 1)
		Pattern.VOLLEY:
			var side := _side(far)
			var skip := rng.randi_range(0, side.size() - 1) if k < 0.4 else -1
			var speed := _speed(k, rng)
			for i in side.size():
				if i != skip:
					_add(shots, rest, t, side[i], speed, pattern)
			return t
		Pattern.SWEEP:
			var side := _side(far)
			if rng.randf() < 0.5:
				side.reverse()
			var dt := lerpf(0.2, 0.13, k)
			var speed := _speed(k, rng)
			for i in side.size():
				_add(shots, rest, t + dt * i, side[i], speed, pattern)
			return t + dt * (side.size() - 1)
		Pattern.CROSSFIRE:
			var parity := rng.randi_range(0, 1)
			var speed := _speed(k, rng)
			var fs := _side(true)
			var ns := _side(false)
			for i in fs.size():
				if i % 2 == parity:
					_add(shots, rest, t, fs[i], speed, pattern)
			for i in ns.size():
				if i % 2 != parity:
					_add(shots, rest, t, ns[i], speed, pattern)
			return t
		Pattern.SLOW_WALL:
			# A slow wall of balls: step into a gap or jump it. Late on it comes from both
			# sides at once (the two walls cross mid-lane: one well-timed jump clears both).
			var both := k > 0.6 and (t >= FINALE_TIME or rng.randf() < 0.6)
			var speed := rng.randf_range(MIN_SPEED, 5.6)
			var cannons := _side(far)
			if both:
				cannons.append_array(_side(not far))
			for c in cannons:
				_add(shots, rest, t, c, speed, pattern)
			return t
	return t


static func _add(shots: Array[Shot], rest: Array[float], t: float, cannon: int, speed: float, pattern: int) -> void:
	if t - rest[cannon] < CANNON_REST:
		return
	rest[cannon] = t
	shots.append(Shot.new(0, t, cannon, clampf(speed, MIN_SPEED, MAX_SPEED), pattern))
