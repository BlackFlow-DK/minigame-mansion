class_name TideTower
extends RefCounted
## Rising Tide's tower: layout data and pure functions (identical on every peer, no nodes).
##
## Seen from the front (+Z), the tower is HALF_W * 2 = 14 m wide (x), Z_BACK..Z_FRONT = 3.6 m deep
## (three 1.2 m lanes: back, middle, front) and climbs in SECTIONS of LEVEL = 3.6 m:
##   floor n (n = 0..5) tops out at n * LEVEL: the ground (n = 0) is full width, odd floors are
##   stone shelves over x in [-7, 1], even floors over [-1, 7]; the roof (n = 6) is a small slab
##   over [-1, 2.6] with the summit flag.
## Section s (floor s -> floor s + 1) climbs toward its EDGE e = -dir * 1 (dir = -1 for even s, +1 for
## odd s: the stairs rise in direction `dir` and the next floor continues past the edge in that direction).
## Every section has:
##   - a MAIN route in the back lane: three crate stacks (0.9 m steps, 1.2 wide) or a step-ladder of
##     five 0.6 m treads; its high end touches the edge, its low end lies 3.6 m back from it;
##   - an ALT route in the middle lane: a bouncy AWNING at the high end (launches you onto the next
##     floor), three CRUMBLE blocks (0.9 m steps that fall 0.8 s after someone stands on them), or
##     three HANGING platforms on chains (0.9 m steps that sway together along x);
##   - the front lane free at floor level: the walkway from the arrival edge past the stairs to their
##     low end, where the climb turns back.
## Every mandatory move is a step up of at most 0.9 m with no gap (the hanging ones: a gap of at most
## 0.75 m); headroom over every walkable surface is at least 2.7 m.
##
## Water: rises from WATER_START at WATER_RATE0 m/s, accelerating linearly to WATER_RATE1 over
## WATER_ACCEL_TIME s of rising, pausing BREATHER_TIME s at each BREATHERS height, stopping at WATER_TOP.

enum Main { CRATES, LADDER }
enum Alt { AWNING, CRUMBLE, HANGING }
enum Kind { FLOOR, ROOF, STEP, AWNING, CRUMBLE, HANGING }

const HALF_W := 7.0
const Z_BACK := -2.4
const Z_FRONT := 1.2
const LANE_W := 1.2
## Lane centres (z): back, middle, front.
const LANE_BACK := -1.8
const LANE_MID := -0.6
const LANE_FRONT := 0.6
const LEVEL := 3.6
const SECTIONS := 6
const FLOOR_THICK := 0.9
const STEP_H := 0.9
const STEP_W := 1.2
const TREAD_H := 0.6
const TREAD_W := 0.72
const AWNING_H := 0.45
const HANG_W := 1.0
const HANG_THICK := 0.3
## Hanging platforms: centres from the edge (m along -dir) and the sway.
const HANG_OFFSETS: Array[float] = [3.1, 2.0, 0.9]
const SWAY_AMP := 0.35
const SWAY_PERIOD := 3.2
const ROOF_Y := 21.6
const ROOF_X0 := -1.0
const ROOF_X1 := 2.6
## Summit flag (feet level on the roof).
const FLAG_POS := Vector3(1.9, ROOF_Y, -1.8)
const FLAG_REACH := 0.85
const MAIN_KIND: Array[int] = [Main.CRATES, Main.LADDER, Main.CRATES, Main.CRATES, Main.LADDER, Main.CRATES]
const ALT_KIND: Array[int] = [Alt.AWNING, Alt.CRUMBLE, Alt.HANGING, Alt.AWNING, Alt.CRUMBLE, Alt.HANGING]
## Bots: how risky each alt route is (0 safe .. 3 risky); the main routes are 0 (crates) / 0 (ladder).
const ALT_RISK: Array[int] = [2, 2, 3]

const WATER_START := -2.0
const WATER_RATE0 := 0.18
const WATER_RATE1 := 0.5
const WATER_ACCEL_TIME := 45.0
const BREATHERS: Array[float] = [6.6, 13.8]
const BREATHER_TIME := 2.0
const WATER_TOP := 20.9
## Below this the tower's floor slab and walls go on (the water's bed).
const BED_Y := -4.0

## Ground spawns: (x, z) on floor 0, the first four spread across the lanes.
const SPAWNS: Array[Vector2] = [
	Vector2(-5.8, LANE_BACK), Vector2(-0.4, LANE_FRONT), Vector2(-4.0, LANE_FRONT), Vector2(-2.2, LANE_MID),
	Vector2(-5.8, LANE_MID), Vector2(-0.4, LANE_BACK), Vector2(-4.0, LANE_BACK), Vector2(-2.2, LANE_FRONT),
]


## One solid piece of the tower: a box from `bottom` to `top` over [x0, x1] x [z0, z1].
class Piece:
	var id: int = 0
	var kind: int = Kind.FLOOR
	## Section the piece climbs in (floors: the floor index; the roof: SECTIONS).
	var section: int = 0
	## Step index within its route (1 = lowest); 0 for floors.
	var step: int = 0
	var x0: float = 0.0
	var x1: float = 0.0
	var z0: float = 0.0
	var z1: float = 0.0
	var bottom: float = 0.0
	var top: float = 0.0
	## Index among the crumble blocks / hanging platforms (-1 for others).
	var index: int = -1

	func center() -> Vector3:
		return Vector3((x0 + x1) * 0.5, (bottom + top) * 0.5, (z0 + z1) * 0.5)

	func size() -> Vector3:
		return Vector3(x1 - x0, top - bottom, z1 - z0)

	## True when (x, z) is over the piece, shrunk by `inset` on every side (negative grows it).
	func covers(x: float, z: float, inset: float = 0.0) -> bool:
		return x >= x0 + inset and x <= x1 - inset and z >= z0 + inset and z <= z1 - inset


static var _pieces: Array = []


# --- Layout -----------------------------------------------------------------------------------

## Height of floor `n` (0 = ground, SECTIONS = the roof).
static func floor_y(n: int) -> float:
	return LEVEL * n


## Direction the stairs of section `s` rise in (-1: toward -x).
static func dir(s: int) -> float:
	return -1.0 if s % 2 == 0 else 1.0


## x of section `s`'s edge: where its stairs meet floor s + 1.
static func edge_x(s: int) -> float:
	return -dir(s)


## x of the low end of section `s`'s stairs.
static func low_x(s: int) -> float:
	return edge_x(s) - dir(s) * LEVEL


## [x0, x1] of floor `n`.
static func floor_span(n: int) -> Vector2:
	if n == 0:
		return Vector2(-HALF_W, HALF_W)
	if n >= SECTIONS:
		return Vector2(ROOF_X0, ROOF_X1)
	return Vector2(-HALF_W, 1.0) if n % 2 == 1 else Vector2(-1.0, HALF_W)


## Every solid piece, built once (ids are indices). Hanging platforms at their rest position.
static func pieces() -> Array:
	if _pieces.is_empty():
		_build()
	return _pieces


static func _build() -> void:
	var out: Array = []
	var crumble_i := 0
	var hang_i := 0
	for n in SECTIONS + 1:
		var span := floor_span(n)
		var top := floor_y(n)
		var bottom := BED_Y if n == 0 else top - FLOOR_THICK
		_add(out, Kind.ROOF if n == SECTIONS else Kind.FLOOR, n, 0, span.x, span.y, Z_BACK, Z_FRONT, bottom, top)
	for s in SECTIONS:
		var y := floor_y(s)
		var e := edge_x(s)
		var d := dir(s)
		var back := Vector2(Z_BACK, Z_BACK + LANE_W)
		var mid := Vector2(Z_BACK + LANE_W, Z_BACK + 2.0 * LANE_W)
		if MAIN_KIND[s] == Main.CRATES:
			for i in range(1, 4):
				var a := e - d * STEP_W * (4 - i)
				var b := e - d * STEP_W * (3 - i)
				_add(out, Kind.STEP, s, i, minf(a, b), maxf(a, b), back.x, back.y, y, y + STEP_H * i)
		else:
			for j in range(1, 6):
				var a := e - d * TREAD_W * (6 - j)
				var b := e - d * TREAD_W * (5 - j)
				_add(out, Kind.STEP, s, j, minf(a, b), maxf(a, b), back.x, back.y, y, y + TREAD_H * j)
		match ALT_KIND[s]:
			Alt.AWNING:
				var a := e - d * STEP_W
				_add(out, Kind.AWNING, s, 1, minf(a, e), maxf(a, e), mid.x, mid.y, y, y + AWNING_H)
			Alt.CRUMBLE:
				for i in range(1, 4):
					var a := e - d * STEP_W * (4 - i)
					var b := e - d * STEP_W * (3 - i)
					var p := _add(out, Kind.CRUMBLE, s, i, minf(a, b), maxf(a, b), mid.x, mid.y, y, y + STEP_H * i)
					p.index = crumble_i
					crumble_i += 1
			Alt.HANGING:
				for i in range(1, 4):
					var c := e - d * HANG_OFFSETS[i - 1]
					var t := y + STEP_H * i
					var p := _add(out, Kind.HANGING, s, i, c - HANG_W * 0.5, c + HANG_W * 0.5, mid.x, mid.y, t - HANG_THICK, t)
					p.index = hang_i
					hang_i += 1
	_pieces = out


static func _add(out: Array, kind: int, section: int, step: int, x0: float, x1: float, z0: float, z1: float, bottom: float, top: float) -> Piece:
	var p := Piece.new()
	p.id = out.size()
	p.kind = kind
	p.section = section
	p.step = step
	p.x0 = x0
	p.x1 = x1
	p.z0 = z0
	p.z1 = z1
	p.bottom = bottom
	p.top = top
	out.append(p)
	return p


static func piece(id: int) -> Piece:
	var all := pieces()
	return all[id] if id >= 0 and id < all.size() else null


## Ids of every piece of `kind`, in id order.
static func ids_of(kind: int) -> Array[int]:
	var out: Array[int] = []
	for p: Piece in pieces():
		if p.kind == kind:
			out.append(p.id)
	return out


## The pieces of section `s`'s route: main (back lane) or alt (middle lane), lowest step first.
static func route(s: int, alt: bool) -> Array[int]:
	var out: Array[int] = []
	for p: Piece in pieces():
		if p.section != s or p.kind == Kind.FLOOR or p.kind == Kind.ROOF:
			continue
		if (p.kind == Kind.STEP) != alt:
			out.append(p.id)
	return out


## Spawn transform `i` (0..7) on the ground, facing the camera (+Z).
static func spawn_xform(i: int) -> Transform3D:
	var at: Vector2 = SPAWNS[posmod(i, SPAWNS.size())]
	return Transform3D(Basis.IDENTITY, Vector3(at.x, 0.0, at.y))


# --- Moving pieces -----------------------------------------------------------------------------

## Sway (m along x) of every hanging platform of section `s` at round time `t`: all three of a
## section move together, so the gaps between them never change. `phase` comes from the host seed.
static func sway(s: int, t: float, phase: float) -> float:
	return SWAY_AMP * sin(TAU * t / SWAY_PERIOD + phase + 1.9 * s)


## Sway phase of a round from its seed.
static func sway_phase(seed_value: int) -> float:
	return float(posmod(seed_value * 7919, 6283)) / 1000.0


# --- Water -------------------------------------------------------------------------------------

## Water height after `s` seconds of rising (breathers not counted).
static func _rise(s: float) -> float:
	s = maxf(s, 0.0)
	var k := (WATER_RATE1 - WATER_RATE0) / WATER_ACCEL_TIME
	if s <= WATER_ACCEL_TIME:
		return WATER_START + WATER_RATE0 * s + 0.5 * k * s * s
	var h_acc := WATER_START + WATER_RATE0 * WATER_ACCEL_TIME + 0.5 * k * WATER_ACCEL_TIME * WATER_ACCEL_TIME
	return h_acc + WATER_RATE1 * (s - WATER_ACCEL_TIME)


## Seconds of rising until the water reaches `h` (inverse of _rise).
static func _rise_time(h: float) -> float:
	if h <= WATER_START:
		return 0.0
	var k := (WATER_RATE1 - WATER_RATE0) / WATER_ACCEL_TIME
	var h_acc := _rise(WATER_ACCEL_TIME)
	if h <= h_acc:
		# 0.5 k s^2 + r0 s - (h - start) = 0
		var c := h - WATER_START
		return (-WATER_RATE0 + sqrt(WATER_RATE0 * WATER_RATE0 + 2.0 * k * c)) / k
	return WATER_ACCEL_TIME + (h - h_acc) / WATER_RATE1


## Seconds of rising (breathers taken out) at round time `t`.
static func _rising_time(t: float) -> float:
	var s := maxf(t, 0.0)
	for b in BREATHERS:
		var sb := _rise_time(b)
		if s <= sb:
			return s
		if s <= sb + BREATHER_TIME:
			return sb
		s -= BREATHER_TIME
	return s


## The water surface height at round time `t` (every peer computes the same).
static func water_height(t: float) -> float:
	return minf(_rise(_rising_time(t)), WATER_TOP)


## Round time at which the water reaches WATER_TOP (the round ends).
static func water_end_time() -> float:
	return _rise_time(WATER_TOP) + BREATHER_TIME * BREATHERS.size()


## Index of the breather running at round time `t` (-1 when the water is rising or done).
static func breather_at(t: float) -> int:
	var s := maxf(t, 0.0)
	for i in BREATHERS.size():
		var sb := _rise_time(BREATHERS[i])
		if s <= sb:
			return -1
		if s <= sb + BREATHER_TIME:
			return i
		s -= BREATHER_TIME
	return -1


## Round time the breather `i` starts.
static func breather_start(i: int) -> float:
	return _rise_time(BREATHERS[i]) + BREATHER_TIME * i


# --- Queries -----------------------------------------------------------------------------------

## Which floor a blob with feet at height `y` counts as being on (0..SECTIONS).
static func level_of(y: float) -> int:
	return clampi(floori((y + 0.25) / LEVEL), 0, SECTIONS)


## True when feet at `pos` stand on (or above) the roof slab.
static func on_roof(pos: Vector3) -> bool:
	return pos.y >= ROOF_Y - 0.15 and pos.x >= ROOF_X0 - 0.3 and pos.x <= ROOF_X1 + 0.3


## True when feet at `pos` touch the summit flag.
static func touches_flag(pos: Vector3) -> bool:
	return pos.y >= ROOF_Y - 0.2 and Vector2(pos.x - FLAG_POS.x, pos.z - FLAG_POS.z).length() <= FLAG_REACH


## Final ranking. `survivors`: slot -> {height: float, roof_t: float (first time on the roof now, or
## -1 when not on it)}; `summit`: the slot that touched the flag first (-1 none); `drowned`: groups of
## slots that drowned in the same tick, first out first. Survivors first: the summit holder (if alive),
## then those on the roof by when they got there, then by height (within HEIGHT_TIE m = a tie); then
## the drowned, latest first (a same-tick group shares its place).
const HEIGHT_TIE := 0.05


static func rank(survivors: Dictionary, summit: int, drowned: Array) -> Array:
	var groups: Array = []
	var roof: Array[int] = []
	var rest: Array[int] = []
	for slot: int in survivors:
		if slot == summit:
			continue
		var info: Dictionary = survivors[slot]
		if float(info.get("roof_t", -1.0)) >= 0.0:
			roof.append(slot)
		else:
			rest.append(slot)
	if summit >= 0 and survivors.has(summit):
		groups.append([summit])
	roof.sort_custom(func(a: int, b: int) -> bool:
		var ta := float(survivors[a]["roof_t"])
		var tb := float(survivors[b]["roof_t"])
		return ta < tb if ta != tb else a < b)
	for i in roof.size():
		if i > 0 and float(survivors[roof[i]]["roof_t"]) == float(survivors[roof[i - 1]]["roof_t"]):
			(groups[groups.size() - 1] as Array).append(roof[i])
		else:
			groups.append([roof[i]])
	rest.sort_custom(func(a: int, b: int) -> bool:
		var ha := float(survivors[a]["height"])
		var hb := float(survivors[b]["height"])
		return ha > hb if ha != hb else a < b)
	var last_h := INF
	for s in rest:
		var h := float(survivors[s]["height"])
		if not groups.is_empty() and last_h - h <= HEIGHT_TIE and last_h != INF:
			(groups[groups.size() - 1] as Array).append(s)
		else:
			groups.append([s])
		last_h = h
	for i in range(drowned.size() - 1, -1, -1):
		var g: Array = (drowned[i] as Array).duplicate()
		g.sort()
		groups.append(g)
	return groups
