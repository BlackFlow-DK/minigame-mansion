class_name DashCourse
extends RefCounted
## Mansion Dash's course as pure functions: the geometry, and where every moving hazard is at
## any round time for a given `Layout` (built from a seed). Every peer builds the same layout
## from the host-sent seed and computes the same hammer, log, platform, disc and sweeper
## positions from its own round clock, so nothing that moves is ever synced.
##
## Geometry (metres): the course runs along -Z from the start pen (z 36.5) to the finish pen
## (z -44.5); x in [-HALF_W, HALF_W]; ground top y = 0 except the log ramp. Sections:
##   start      spawns z 34, start line z 32.5
##   slalom     hedge rows at z 29 (middle choke), 26.3 (side gaps), 23.6 (two gaps), 20.9 (choke)
##   hammers    walkway |x| < 2.6 between hedge walls, z 18.4 .. 7.6, pendulums at z 17 / 14.2 / 11.4 / 8.6
##   CP 0       z 6.6
##   logs       ramp z 5 -> -5 up to 1.2 m, flat top to -7.5, down to 0 at -10.5; logs roll down
##   CP 1       z -11.1 (pond bank)
##   pond       water z -11.6 .. -21.4, three rows of two moving rafts; fall in = back to CP 1
##   CP 2       z -22.4 (far bank)
##   spinner    turntable r 3.9 at z -27.4 with a counter-rotating sweeper bar
##   sprint     bumpers, finish line z -38, finish pen to z -44.5

const HALF_W := 4.5
const BLOB_RADIUS := 0.4
## Blob capsule core (feet-relative): radius 0.4, height 1.0 (docs/contract.md).
const CORE_LO := 0.4
const CORE_HI := 0.6

const SPAWN_Z := 34.0
const START_Z := 32.5
const PEN_BACK_Z := 36.5
const FINISH_Z := -38.0
## Half width of the finish arch opening (the course is wall to wall here anyway).
const FINISH_HALF_X := 4.8
const PEN_END_Z := -44.5
const CHECKPOINT_Z: Array[float] = [6.6, -11.1, -22.4]
## Where a player who falls respawns, per checkpoint (just before the line, clear of hazards).
const RESPAWN_Z: Array[float] = [7.0, -10.85, -22.15]
## Total race length start line -> finish line.
const TOTAL := START_Z - FINISH_Z

# --- Slalom and walls ---------------------------------------------------------------------
## Hedge footprints as Rect2(x0, z0, width, depth) on the XZ plane (z0 = smaller z).
const HEDGES: Array[Rect2] = [
	Rect2(-4.5, 28.5, 3.2, 1.0), Rect2(1.3, 28.5, 3.2, 1.0),
	Rect2(-2.3, 25.8, 4.6, 1.0),
	Rect2(-4.5, 23.1, 1.9, 1.0), Rect2(-0.55, 23.1, 1.1, 1.0), Rect2(2.6, 23.1, 1.9, 1.0),
	Rect2(-4.5, 20.4, 3.3, 1.0), Rect2(1.2, 20.4, 3.3, 1.0),
	Rect2(-4.5, 7.6, 1.9, 10.8), Rect2(2.6, 7.6, 1.9, 10.8),
]
const HEDGE_HEIGHT := 1.3
## Slalom gap centres (bot lanes): [row z, gap xs...].
const SLALOM_GAPS: Array = [[29.0, [0.0]], [26.3, [-3.4, 3.4]], [23.6, [-1.58, 1.58]], [20.9, [0.0]]]

# --- Hammers --------------------------------------------------------------------------------
const HAMMER_Z: Array[float] = [17.0, 14.2, 11.4, 8.6]
const WALKWAY_HALF := 2.6
const PIVOT_Y := 6.4
const ARM := 5.6
const HAMMER_AMP := 0.92  # radians (~53 degrees)
## Head: a capsule along the swing tangent, core half-length and radius.
const HEAD_HALF := 0.27
const HEAD_R := 0.48
const HAMMER_PERIOD := Vector2(3.3, 3.9)

# --- Logs -------------------------------------------------------------------------------------
const RAMP_Z0 := 5.0
const RAMP_Z1 := -5.0
const TOP_Z1 := -7.5
const DOWN_Z1 := -10.5
const RAMP_H := 1.2
const LOG_LANES: Array[float] = [-3.0, 0.0, 3.0]
const LOG_HALF := 1.3
const LOG_R := 0.32
const LOG_SPEED := 4.2
## A log appears on the crest (and rocks there for LOG_WOBBLE s), then rolls down to LOG_Z_END.
const LOG_Z_RELEASE := -5.6
const LOG_Z_END := 5.6
const LOG_WOBBLE := 0.45
const LOG_START := 0.8
const LOG_GAP := Vector2(0.75, 1.15)
const LOG_DOUBLE_CHANCE := 0.35
const LOG_END_TIME := 120.0

# --- Pond ---------------------------------------------------------------------------------------
const POND_Z0 := -11.6
const POND_Z1 := -21.4
const WATER_Y := -0.45
const POND_FLOOR := -1.8
## Feet below this inside the pond = in the water.
const SINK_Y := -0.7
const ROW_Z: Array[float] = [-13.1, -16.5, -19.9]
const PLAT_HALF_X := 1.4
const PLAT_HALF_Z := 1.15
const PLAT_THICK := 0.5
const ROW_PERIOD := Vector2(3.8, 4.8)

# --- Spinner ------------------------------------------------------------------------------------
const DISC_Z := -27.4
const DISC_R := 3.9
const DISC_TOP := 0.06
const DISC_RATE := 0.6
const SWEEP_RATE := 1.8
const SWEEP_HALF_LEN := 3.7
const SWEEP_HALF_W := 0.18
const SWEEP_TOP := 0.66
const POST_R := 0.35

# --- Sprint -------------------------------------------------------------------------------------
const BUMPERS: Array[Vector2] = [Vector2(-2.4, -33.2), Vector2(2.4, -33.2), Vector2(0.0, -35.1),
		Vector2(-3.2, -36.6), Vector2(3.2, -36.6)]
const BUMPER_R := 0.47
const BUMPER_H := 0.88


## The seeded part of a round: hammer timing, log releases, raft rhythm, spin direction.
class Layout:
	extends RefCounted
	var seed_value: int = 0
	var hammer_period := PackedFloat32Array()
	var hammer_phase := PackedFloat32Array()
	var row_period := PackedFloat32Array()
	var row_phase := PackedFloat32Array()
	## Log release times (sorted) and their lanes (index into LOG_LANES).
	var log_t := PackedFloat32Array()
	var log_lane := PackedInt32Array()
	var spin_dir: float = 1.0
	var sweep_phase: float = 0.0


## The layout of `seed_value`. Same seed, same layout on every peer.
static func build(seed_value: int) -> Layout:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var l := Layout.new()
	l.seed_value = seed_value
	var base := rng.randf() * TAU
	for k in HAMMER_Z.size():
		l.hammer_period.append(rng.randf_range(HAMMER_PERIOD.x, HAMMER_PERIOD.y))
		# spread the three phases so the walkway is never fully open or fully closed
		l.hammer_phase.append(fposmod(base + TAU * k * 0.37 + rng.randf_range(-0.5, 0.5), TAU))
	for r in ROW_Z.size():
		l.row_period.append(rng.randf_range(ROW_PERIOD.x, ROW_PERIOD.y))
		l.row_phase.append(rng.randf() * TAU)
	l.spin_dir = 1.0 if rng.randf() < 0.5 else -1.0
	l.sweep_phase = rng.randf() * TAU
	var t := LOG_START + rng.randf_range(0.0, 0.4)
	while t < LOG_END_TIME:
		var a := rng.randi_range(0, LOG_LANES.size() - 1)
		l.log_t.append(t)
		l.log_lane.append(a)
		if rng.randf() < LOG_DOUBLE_CHANCE:
			var b := (a + rng.randi_range(1, LOG_LANES.size() - 1)) % LOG_LANES.size()
			l.log_t.append(t)
			l.log_lane.append(b)
		t += rng.randf_range(LOG_GAP.x, LOG_GAP.y)
	return l


# --- Ground ---------------------------------------------------------------------------------

## Height of the walkable ground at `z` (the ramp; 0 elsewhere, the pond aside).
static func ground_y(z: float) -> float:
	if z >= RAMP_Z0:
		return 0.0
	if z >= RAMP_Z1:
		return RAMP_H * (RAMP_Z0 - z) / (RAMP_Z0 - RAMP_Z1)
	if z >= TOP_Z1:
		return RAMP_H
	if z >= DOWN_Z1:
		return RAMP_H * (z - DOWN_Z1) / (TOP_Z1 - DOWN_Z1)
	return 0.0


static func in_pond(pos: Vector3) -> bool:
	return pos.z < POND_Z0 and pos.z > POND_Z1


static func in_hedge(pos: Vector3, pad: float = 0.0) -> bool:
	for r in HEDGES:
		if pos.x > r.position.x - pad and pos.x < r.end.x + pad and pos.z > r.position.y - pad and pos.z < r.end.y + pad:
			return true
	return false


## Metres along the course from the start line (0) to the finish line (TOTAL).
static func progress(pos: Vector3) -> float:
	return clampf(START_Z - pos.z, 0.0, TOTAL)


## Spawn `i` of 8: one even row behind the start line, facing down the course (-Z).
static func spawn_xform(i: int) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, PI), Vector3(-3.85 + 1.1 * i, 0.0, SPAWN_Z))


## Where `slot` respawns after a fall with `checkpoint` reached (-1: the start).
static func respawn_xform(checkpoint: int, slot: int) -> Transform3D:
	if checkpoint < 0:
		return spawn_xform(slot % 8)
	var z: float = RESPAWN_Z[mini(checkpoint, RESPAWN_Z.size() - 1)]
	return Transform3D(Basis(Vector3.UP, PI), Vector3(-3.15 + 0.9 * (slot % 8), ground_y(z) + 0.05, z))


## Highest checkpoint index whose line `pos` is past (-1: none).
static func checkpoint_at(pos: Vector3) -> int:
	var k := -1
	for i in CHECKPOINT_Z.size():
		if pos.z < CHECKPOINT_Z[i]:
			k = i
	return k


## Round time a player moving from `prev` (at `t_prev`) to `cur` (at `t_prev + dt`) crossed the
## finish line, or -1 when it did not cross this step (interpolated along the step).
static func finish_crossing(prev: Vector3, cur: Vector3, t_prev: float, dt: float) -> float:
	if not (prev.z > FINISH_Z and cur.z <= FINISH_Z):
		return -1.0
	var frac := (prev.z - FINISH_Z) / maxf(prev.z - cur.z, 0.0001)
	var x := lerpf(prev.x, cur.x, frac)
	if absf(x) > FINISH_HALF_X:
		return -1.0
	return t_prev + frac * dt


## Final ranking: finishers in finish order, then everyone else by checkpoint, then distance
## along the course (then slot, for a stable order), then the knocked-out (last out last).
static func rank(finishers: Array[int], others: Array[int], checkpoints: Dictionary, progress_by_slot: Dictionary,
		knocked: Array[int] = []) -> Array[int]:
	var out: Array[int] = finishers.duplicate()
	var rest := others.duplicate()
	rest.sort_custom(func(a: int, b: int) -> bool:
		var ca: int = checkpoints.get(a, -1)
		var cb: int = checkpoints.get(b, -1)
		if ca != cb:
			return ca > cb
		var pa: float = progress_by_slot.get(a, 0.0)
		var pb: float = progress_by_slot.get(b, 0.0)
		if pa != pb:
			return pa > pb
		return a < b)
	for s: int in rest:
		if not out.has(s):
			out.append(s)
	for i in range(knocked.size() - 1, -1, -1):
		if not out.has(knocked[i]):
			out.append(knocked[i])
	return out


# --- Blob contact -----------------------------------------------------------------------------

## Squared distance between the blob core (feet-relative segment) and segment a..b.
static func core_dist2(feet: Vector3, a: Vector3, b: Vector3) -> float:
	var c0 := feet + Vector3(0.0, CORE_LO, 0.0)
	var c1 := feet + Vector3(0.0, CORE_HI, 0.0)
	var pts := Geometry3D.get_closest_points_between_segments(c0, c1, a, b)
	return pts[0].distance_squared_to(pts[1])


# --- Hammers ------------------------------------------------------------------------------------

static func hammer_angle(l: Layout, k: int, t: float) -> float:
	return HAMMER_AMP * sin(TAU * t / l.hammer_period[k] + l.hammer_phase[k])


## Angular speed (rad/s) of hammer `k` at `t`.
static func hammer_rate(l: Layout, k: int, t: float) -> float:
	var w := TAU / l.hammer_period[k]
	return HAMMER_AMP * w * cos(w * t + l.hammer_phase[k])


## Centre of hammer `k`'s head at `t`.
static func hammer_head(l: Layout, k: int, t: float) -> Vector3:
	var a := hammer_angle(l, k, t)
	return Vector3(ARM * sin(a), PIVOT_Y - ARM * cos(a), HAMMER_Z[k])


static func hammer_touches(l: Layout, k: int, t: float, feet: Vector3, pad: float = 0.0) -> bool:
	if absf(feet.z - HAMMER_Z[k]) > HEAD_R + BLOB_RADIUS + pad:
		return false
	var a := hammer_angle(l, k, t)
	var c := Vector3(ARM * sin(a), PIVOT_Y - ARM * cos(a), HAMMER_Z[k])
	var axis := Vector3(cos(a), sin(a), 0.0) * HEAD_HALF
	var reach := HEAD_R + BLOB_RADIUS - 0.04 + pad
	return core_dist2(feet, c - axis, c + axis) < reach * reach


## Knockback direction of hammer `k` at `t` (sideways, the way the head swings).
static func hammer_dir(l: Layout, k: int, t: float, feet: Vector3) -> float:
	var w := hammer_rate(l, k, t)
	if absf(w) < 0.3:
		return signf(feet.x - hammer_head(l, k, t).x) if absf(feet.x - hammer_head(l, k, t).x) > 0.01 else 1.0
	return signf(w)


## True when hammer `k` touches a blob at `feet` at any time in [t, t + horizon].
static func hammer_threat(l: Layout, k: int, t: float, feet: Vector3, horizon: float, pad: float = 0.0) -> bool:
	if absf(feet.z - HAMMER_Z[k]) > HEAD_R + BLOB_RADIUS + pad:
		return false
	var n := maxi(1, ceili(horizon / 0.04))
	for i in n + 1:
		if hammer_touches(l, k, t + horizon * i / n, feet, pad):
			return true
	return false


# --- Logs ---------------------------------------------------------------------------------------

static func log_travel_time() -> float:
	return (LOG_Z_END - LOG_Z_RELEASE) / LOG_SPEED


## True while log `i` is on the course at `t` (rocking on the crest or rolling).
static func log_active(l: Layout, i: int, t: float) -> bool:
	return t >= l.log_t[i] - LOG_WOBBLE and t < l.log_t[i] + log_travel_time()


static func log_z(l: Layout, i: int, t: float) -> float:
	return LOG_Z_RELEASE + LOG_SPEED * clampf(t - l.log_t[i], 0.0, log_travel_time())


## Log centre at `t` (only meaningful while `log_active`).
static func log_position(l: Layout, i: int, t: float) -> Vector3:
	var z := log_z(l, i, t)
	return Vector3(LOG_LANES[l.log_lane[i]], ground_y(z) + LOG_R, z)


## Radians the log has rolled about +X by `t`.
static func log_roll(l: Layout, i: int, t: float) -> float:
	return (log_z(l, i, t) - LOG_Z_RELEASE) / LOG_R


static func log_touches(l: Layout, i: int, t: float, feet: Vector3, pad: float = 0.0) -> bool:
	var c := log_position(l, i, t)
	var reach := LOG_R + BLOB_RADIUS - 0.04 + pad
	if absf(feet.z - c.z) > reach or absf(feet.x - c.x) > LOG_HALF + reach:
		return false
	return core_dist2(feet, c - Vector3(LOG_HALF, 0.0, 0.0), c + Vector3(LOG_HALF, 0.0, 0.0)) < reach * reach


## Index range [first, last) of logs that may be active at some time in [t0, t1].
static func log_window(l: Layout, t0: float, t1: float) -> Vector2i:
	var travel := log_travel_time()
	var first := l.log_t.bsearch(t0 - travel - 0.001)
	var last := l.log_t.bsearch(t1 + LOG_WOBBLE + 0.001, false)
	return Vector2i(first, last)


# --- Pond ---------------------------------------------------------------------------------------

## X of raft `i` (0 or 1) of row `row` at `t`. Rows 0 and 2 part and close like a door; row 1
## slides side to side as a pair.
static func platform_x(l: Layout, row: int, i: int, t: float) -> float:
	var s := sin(TAU * t / l.row_period[row] + l.row_phase[row])
	if row == 1:
		var c := 1.4 * s
		return c - 1.45 if i == 0 else c + 1.45
	var h := 1.45 + 1.5 * (0.5 + 0.5 * s)
	return -h if i == 0 else h


static func platform_position(l: Layout, row: int, i: int, t: float) -> Vector3:
	return Vector3(platform_x(l, row, i, t), 0.0, ROW_Z[row])


## Row index whose rafts span `z` (-1: none).
static func row_at(z: float) -> int:
	for r in ROW_Z.size():
		if absf(z - ROW_Z[r]) <= PLAT_HALF_Z:
			return r
	return -1


## True when `pos` is over a raft at `t`, at least `margin` inside its edge.
static func on_platform(l: Layout, t: float, pos: Vector3, margin: float = 0.0) -> bool:
	var r := row_at(pos.z)
	if r < 0 or absf(pos.z - ROW_Z[r]) > PLAT_HALF_Z - margin:
		return false
	for i in 2:
		if absf(pos.x - platform_x(l, r, i, t)) <= PLAT_HALF_X - margin:
			return true
	return false


# --- Spinner -------------------------------------------------------------------------------------

static func disc_angle(l: Layout, t: float) -> float:
	return l.spin_dir * DISC_RATE * t


static func sweep_angle(l: Layout, t: float) -> float:
	return l.sweep_phase - l.spin_dir * SWEEP_RATE * t


## Sweeper angular speed (rad/s, about +Y).
static func sweep_rate(l: Layout) -> float:
	return -l.spin_dir * SWEEP_RATE


## True when the sweeper bar at angle `a` touches a blob at `feet` (jumping over it clears it).
static func sweeper_touches(a: float, feet: Vector3, pad: float = 0.0) -> bool:
	if feet.y > SWEEP_TOP - 0.12:
		return false
	var rx := feet.x
	var rz := feet.z - DISC_Z
	var along := rx * cos(a) - rz * sin(a)
	var perp := rx * sin(a) + rz * cos(a)
	return absf(along) <= SWEEP_HALF_LEN + 0.2 + pad and absf(perp) < SWEEP_HALF_W + BLOB_RADIUS - 0.04 + pad


## Sideways shove of the sweeper on a blob at `feet`: along the bar's motion there.
static func sweeper_dir(l: Layout, a: float, feet: Vector3) -> Vector3:
	var rel := Vector3(feet.x, 0.0, feet.z - DISC_Z)
	var v := Vector3(rel.z, 0.0, -rel.x) * sweep_rate(l)
	if v.length() < 0.4:
		var n := Vector3(sin(a), 0.0, cos(a))
		return n * (1.0 if rel.dot(n) >= 0.0 else -1.0)
	return v.normalized()


## True when the sweeper touches `feet` at any time in [t, t + horizon].
static func sweeper_threat(l: Layout, t: float, feet: Vector3, horizon: float, pad: float = 0.0) -> bool:
	var rel := Vector2(feet.x, feet.z - DISC_Z)
	if rel.length() > SWEEP_HALF_LEN + 0.2 + BLOB_RADIUS + pad + 0.2:
		return false
	var n := maxi(1, ceili(horizon / 0.04))
	for i in n + 1:
		if sweeper_touches(sweep_angle(l, t + horizon * i / n), feet, pad):
			return true
	return false


# --- Bumpers --------------------------------------------------------------------------------------

## Index of the bumper a blob at `feet` touches (-1: none).
static func bumper_at(feet: Vector3, pad: float = 0.0) -> int:
	if feet.y > BUMPER_H:
		return -1
	for i in BUMPERS.size():
		if Vector2(feet.x, feet.z).distance_to(BUMPERS[i]) < BUMPER_R + BLOB_RADIUS + 0.08 + pad:
			return i
	return -1
