class_name SnowArc
extends RefCounted
## Snowball Fight: the snowball's flight as a pure function of its launch (origin, flat direction)
## and the seconds since launch. Every peer computes the same arc from the same host-sent launch,
## including where it ends (`end_time`: the first touch of cover, a yard wall or the ground, found
## by fixed steps then bisection against SnowYard's shapes), so balls are never synced.
## A shallow throw: 14 m/s along the ground, a little lift, light gravity; about 11 m of range from
## the thrower, never higher than ~1.15 m, so the 1.1 m snow walls always stop it.

const SPEED := 14.0
const LIFT := 1.6
const GRAVITY := 7.2
## Collision radius of a ball (m); the mesh is a little smaller.
const RADIUS := 0.3
## Release point: this high above the thrower's feet and this far ahead of its centre.
const RELEASE_UP := 0.95
const RELEASE_FWD := 0.45
## A ball never flies longer than this (s).
const MAX_TIME := 1.3
const STEP := 1.0 / 120.0
## The blob as a capsule for ball hits: a segment from feet + BODY_LO to feet + BODY_HI, radius BODY_R.
const BODY_R := 0.38
const BODY_LO := 0.38
const BODY_HI := 0.62

enum End { NONE, COVER, GROUND, WALL, TIMEOUT }


## Ball centre `s` seconds after launch.
static func position(origin: Vector3, dir: Vector3, s: float) -> Vector3:
	return origin + dir * (SPEED * s) + Vector3(0.0, LIFT * s - 0.5 * GRAVITY * s * s, 0.0)


## Ball velocity `s` seconds after launch.
static func velocity(dir: Vector3, s: float) -> Vector3:
	return dir * SPEED + Vector3(0.0, LIFT - GRAVITY * s, 0.0)


## Where a blob standing at `feet` facing along `dir` lets go of a ball.
static func release_point(feet: Vector3, dir: Vector3) -> Vector3:
	return feet + flat_dir(dir) * RELEASE_FWD + Vector3(0.0, RELEASE_UP, 0.0)


## `v` on the XZ plane, unit length (MODEL_FRONT when degenerate).
static func flat_dir(v: Vector3) -> Vector3:
	var f := Vector3(v.x, 0.0, v.z)
	if f.length_squared() < 0.000001:
		return Vector3.MODEL_FRONT
	return f.normalized()


## Seconds after launch when the ball first touches cover, a wall or the ground (MAX_TIME when it
## never does), and what it hit: [time, End].
static func end_of(origin: Vector3, dir: Vector3) -> Array:
	if SnowYard.ball_blocked(origin, RADIUS) != 0:
		return [0.0, SnowYard.ball_blocked(origin, RADIUS)]
	var prev := 0.0
	var s := STEP
	while s <= MAX_TIME + 0.00001:
		var kind := SnowYard.ball_blocked(position(origin, dir, s), RADIUS)
		if kind != 0:
			var lo := prev
			var hi := s
			for i in 8:
				var mid := (lo + hi) * 0.5
				if SnowYard.ball_blocked(position(origin, dir, mid), RADIUS) != 0:
					hi = mid
				else:
					lo = mid
			return [hi, SnowYard.ball_blocked(position(origin, dir, hi), RADIUS)]
		prev = s
		s += STEP
	return [MAX_TIME, End.TIMEOUT]


## Distance from `p` to the blob capsule's axis segment for a blob standing at `feet`.
static func body_distance(p: Vector3, feet: Vector3) -> float:
	var y := clampf(p.y, feet.y + BODY_LO, feet.y + BODY_HI)
	return p.distance_to(Vector3(feet.x, y, feet.z))


## True when a ball centred at `ball` touches a blob standing at `feet` (with `slack` m extra).
static func touches(ball: Vector3, feet: Vector3, slack: float = 0.0) -> bool:
	return body_distance(ball, feet) < RADIUS + BODY_R + slack


## True when a ball launched now from `from_feet` straight at a blob standing at `to_feet` gets
## there before it runs into anything (cover, walls, the ground): a clear shot.
static func clear_shot(from_feet: Vector3, to_feet: Vector3) -> bool:
	var dir := flat_dir(to_feet - from_feet)
	var origin := release_point(from_feet, dir)
	var d := Vector2(to_feet.x - origin.x, to_feet.z - origin.z).length() - BODY_R
	var need := maxf(d, 0.0) / SPEED
	if need > MAX_TIME:
		return false
	# Coarser steps than end_of (0.23 m along the ground; the thinnest cover is 1.2 m with the
	# ball's radius), and only as far as the target.
	var s := 0.0
	while s < need:
		if SnowYard.ball_blocked(position(origin, dir, s), RADIUS) != 0:
			return false
		s += 1.0 / 60.0
	return SnowYard.ball_blocked(position(origin, dir, need), RADIUS) == 0


## Horizontal reach of a throw from flat ground (m from the release point).
static func reach() -> float:
	# y(s) = RELEASE_UP + LIFT s - G s^2 / 2 reaches RADIUS / 2 (the ground test).
	var c := RELEASE_UP - RADIUS * 0.5
	var s := (LIFT + sqrt(LIFT * LIFT + 2.0 * GRAVITY * c)) / GRAVITY
	return SPEED * s
