extends RefCounted
## Ghost Tag map: the attic loop as data, identical on every peer (no randomness).
##
## Layout (metres, x -12..12, z -9..9; the camera looks from +Z, so -Z is "north"):
##   a 2.5 m wide ring corridor inside the outer walls, a 2 m vertical and a 2 m horizontal
##   cross-passage through the middle, and four 7 x 4 m rooms in the quadrants between them.
##   NE and SW rooms have two doors (a short cut through the room); NW and SE rooms have one
##   door (dead ends: bots never flee into them with a ghost near). 180-degree symmetric.
## Everything is a 0.5 m grid: SOLID (wall), FLOOR, CLUTTER (floor under a crate/sofa: blocked).
## Bots: `nav` cells are floor whose 8 neighbours are floor too (a blob centre fits), searched
## with a 4-neighbour BFS; `has_los` checks a blob-wide straight line; `is_safe` = on floor.

const CELL := 0.5
const X0 := -12.0
const Z0 := -9.0
const NX := 48
const NZ := 36

const SOLID := 0
const FLOOR := 1
const CLUTTER := 2

## Floor rectangles: Rect2(x, z, width, depth) in metres (all on the 0.5 m grid).
const FLOOR_RECTS: Array[Rect2] = [
	Rect2(-11.5, -8.5, 23.0, 2.5),   # ring: north strip
	Rect2(-11.5, 6.0, 23.0, 2.5),    # ring: south strip
	Rect2(-11.5, -8.5, 2.5, 17.0),   # ring: west strip
	Rect2(9.0, -8.5, 2.5, 17.0),     # ring: east strip
	Rect2(-1.0, -6.0, 2.0, 12.0),    # vertical cross-passage
	Rect2(-9.0, -1.0, 18.0, 2.0),    # horizontal cross-passage
	Rect2(1.5, -5.5, 7.0, 4.0),      # room NE (through)
	Rect2(-8.5, 1.5, 7.0, 4.0),      # room SW (through)
	Rect2(-8.5, -5.5, 7.0, 4.0),     # room NW (dead end)
	Rect2(1.5, 1.5, 7.0, 4.0),       # room SE (dead end)
	# doors (1.5 m) through the 0.5 m walls
	Rect2(5.5, -6.0, 1.5, 0.5),      # NE -> north strip
	Rect2(3.0, -1.5, 1.5, 0.5),      # NE -> horizontal passage
	Rect2(-7.0, 5.5, 1.5, 0.5),      # SW -> south strip
	Rect2(-4.5, 1.0, 1.5, 0.5),      # SW -> horizontal passage
	Rect2(-9.0, -4.5, 0.5, 1.5),     # NW -> west strip
	Rect2(8.5, 3.0, 0.5, 1.5),       # SE -> east strip
]
## Dead-end rooms (with their doors): bots avoid them while a ghost is near.
const DEAD_ENDS: Array[Rect2] = [Rect2(-9.0, -5.5, 7.5, 4.0), Rect2(1.5, 1.5, 7.5, 4.0)]
## Rooms (for the look: rugs, dust).
const ROOMS: Array[Rect2] = [Rect2(1.5, -5.5, 7.0, 4.0), Rect2(-8.5, 1.5, 7.0, 4.0),
	Rect2(-8.5, -5.5, 7.0, 4.0), Rect2(1.5, 1.5, 7.0, 4.0)]

## Clutter: [piece, x, z, yaw degrees, footprint width (x), footprint depth (z), collider height].
## Footprints are in metres before yaw (yaw is 0 or 180 here, so they stay axis aligned).
## Every piece stands flush against a wall or at least 1.2 m clear of walls and other pieces:
## no blob-sized pockets a fleeing blob could wedge itself into out of a ghost's reach.
const CLUTTER_PIECES: Array = [
	# NE room (through): sofa on the north wall, crate stack, covered chair
	["ghost_covered_sofa", 3.0, -5.0, 0.0, 2.0, 0.9, 0.9],
	["crate_stack", 8.0, -2.0, 0.0, 0.9, 0.9, 1.8],
	["ghost_covered_chair", 7.95, -5.05, -90.0, 0.8, 0.8, 1.1],
	# SW room (through): the same, rotated 180
	["ghost_covered_sofa", -3.0, 5.0, 180.0, 2.0, 0.9, 0.9],
	["crate_stack", -8.0, 2.0, 0.0, 0.9, 0.9, 1.8],
	["ghost_covered_chair", -7.95, 5.05, 90.0, 0.8, 0.8, 1.1],
	# NW room (dead end): covered wardrobe, trunk, crate
	["ghost_covered_wardrobe", -3.2, -5.05, 0.0, 1.3, 0.8, 2.0],
	["ghost_trunk", -5.5, -1.95, 180.0, 1.0, 0.6, 0.7],
	["crate", -2.0, -2.0, 15.0, 0.9, 0.9, 0.9],
	# SE room (dead end)
	["ghost_covered_wardrobe", 3.2, 5.05, 180.0, 1.3, 0.8, 2.0],
	["ghost_trunk", 5.5, 1.95, 0.0, 1.0, 0.6, 0.7],
	["crate", 2.0, 2.0, -15.0, 0.9, 0.9, 0.9],
	# ring: a crate in every outer corner, barrels along the long walls
	["crate", 11.0, -8.0, 8.0, 0.9, 0.9, 0.9],
	["crate", -11.0, 8.0, 8.0, 0.9, 0.9, 0.9],
	["crate", -11.0, -8.0, -12.0, 0.9, 0.9, 0.9],
	["crate", 11.0, 8.0, -12.0, 0.9, 0.9, 0.9],
	["barrel", 5.0, -8.1, 0.0, 0.75, 0.75, 0.75],
	["barrel", -5.0, 8.1, 0.0, 0.75, 0.75, 0.75],
	["barrel", -5.0, -8.1, 30.0, 0.75, 0.75, 0.75],
	["barrel", 5.0, 8.1, 30.0, 0.75, 0.75, 0.75],
]

## Junctions: where three or four ways meet (passage ends, the middle cross, through-room
## doors). A fleeing blob near one can break either way; the ring's corners are the opposite.
const JUNCTIONS: Array[Vector2] = [Vector2(0, -7.25), Vector2(0, 7.25), Vector2(-10.25, 0), Vector2(10.25, 0),
	Vector2(0, 0), Vector2(6.25, -6.0), Vector2(3.75, -1.0), Vector2(-6.25, 6.0), Vector2(-3.75, 1.0)]
const CORNERS: Array[Vector2] = [Vector2(-10.25, -7.25), Vector2(10.25, -7.25), Vector2(-10.25, 7.25), Vector2(10.25, 7.25)]

## Spawns on the ring (the first four are the corners: spread out for small rounds); each
## faces along the loop, counter-clockwise seen from above.
const SPAWNS: Array[Vector3] = [
	Vector3(-9.9, 0.0, -6.9), Vector3(9.9, 0.0, 6.9), Vector3(9.9, 0.0, -6.9), Vector3(-9.9, 0.0, 6.9),
	Vector3(0.0, 0.0, -7.25), Vector3(0.0, 0.0, 7.25), Vector3(-10.25, 0.0, 0.0), Vector3(10.25, 0.0, 0.0),
]

## cells[i + j * NX]: SOLID / FLOOR / CLUTTER.
var cells := PackedByteArray()
## nav[i + j * NX]: 1 where a blob centre fits (floor with 8 floor neighbours).
var nav := PackedByteArray()
## dead[i + j * NX]: 1 inside a dead-end room.
var dead := PackedByteArray()
## Indices of every nav cell.
var nav_cells := PackedInt32Array()
## openness[i + j * NX]: + near a junction (up to 1), - in a ring corner (down to -1).
var openness := PackedFloat32Array()


func _init() -> void:
	cells.resize(NX * NZ)
	cells.fill(SOLID)
	for r in FLOOR_RECTS:
		_fill(r, FLOOR)
	for c: Array in CLUTTER_PIECES:
		# cells whose centre is within 0.1 m of the footprint: a blob (radius 0.4) pressed
		# against the piece still stands on FLOOR
		var w := float(c[4]) + 0.2
		var d := float(c[5]) + 0.2
		_fill_clutter(Rect2(float(c[1]) - w * 0.5, float(c[2]) - d * 0.5, w, d))
	nav.resize(NX * NZ)
	dead.resize(NX * NZ)
	for j in NZ:
		for i in NX:
			var k := i + j * NX
			dead[k] = 0
			for r in DEAD_ENDS:
				if r.has_point(center_of(k)):
					dead[k] = 1
			nav[k] = 0
			if cells[k] != FLOOR:
				continue
			var ok := true
			for dj in range(-1, 2):
				for di in range(-1, 2):
					if cell_at(i + di, j + dj) != FLOOR:
						ok = false
			if ok:
				nav[k] = 1
				nav_cells.append(k)
	openness.resize(NX * NZ)
	for k in NX * NZ:
		var c := center_of(k)
		var o := 0.0
		for jn in JUNCTIONS:
			o = maxf(o, 1.0 - clampf(c.distance_to(jn) / 4.0, 0.0, 1.0))
		for cn in CORNERS:
			o -= 1.0 - clampf(c.distance_to(cn) / 3.0, 0.0, 1.0)
		openness[k] = o


# --- Grid --------------------------------------------------------------------------------

## Cell state at grid coords (SOLID outside the grid).
func cell_at(i: int, j: int) -> int:
	if i < 0 or j < 0 or i >= NX or j >= NZ:
		return SOLID
	return cells[i + j * NX]


## Grid index of world `p` (-1 outside).
func index_of(p: Vector3) -> int:
	var i := int(floor((p.x - X0) / CELL))
	var j := int(floor((p.z - Z0) / CELL))
	if i < 0 or j < 0 or i >= NX or j >= NZ:
		return -1
	return i + j * NX


## World centre of cell `k` (y = 0) as a Vector2 (x, z).
func center_of(k: int) -> Vector2:
	return Vector2(X0 + (float(k % NX) + 0.5) * CELL, Z0 + (float(k / NX) + 0.5) * CELL)


func center3(k: int) -> Vector3:
	var c := center_of(k)
	return Vector3(c.x, 0.0, c.y)


## True when world `p` is on open floor (not a wall, not clutter).
func is_floor(p: Vector3) -> bool:
	var k := index_of(p)
	return k >= 0 and cells[k] == FLOOR


## True when a disc of `radius` around `p` is all on open floor (8 points on its rim + centre).
func is_clear(p: Vector3, radius: float) -> bool:
	if not is_floor(p):
		return false
	var dg := radius * 0.7071
	for o: Vector2 in [Vector2(radius, 0), Vector2(-radius, 0), Vector2(0, radius), Vector2(0, -radius),
			Vector2(dg, dg), Vector2(-dg, dg), Vector2(dg, -dg), Vector2(-dg, -dg)]:
		if not is_floor(p + Vector3(o.x, 0.0, o.y)):
			return false
	return true


## True when a blob (radius `radius`) can walk the straight line a -> b.
func has_los(a: Vector3, b: Vector3, radius: float = 0.42) -> bool:
	var flat := Vector2(b.x - a.x, b.z - a.z)
	var n := maxi(1, int(ceil(flat.length() / 0.25)))
	for s in n + 1:
		var t := float(s) / float(n)
		if not is_clear(Vector3(a.x + flat.x * t, 0.0, a.z + flat.y * t), radius):
			return false
	return true


## The nav cell nearest to `p` (searching outwards a few cells); -1 if none close.
func nearest_nav(p: Vector3) -> int:
	var k := index_of(p)
	if k >= 0 and nav[k] == 1:
		return k
	var ci := int(floor((p.x - X0) / CELL))
	var cj := int(floor((p.z - Z0) / CELL))
	var best := -1
	var best_d := INF
	for r in range(1, 6):
		for dj in range(-r, r + 1):
			for di in range(-r, r + 1):
				if maxi(absi(di), absi(dj)) != r:
					continue
				var i := ci + di
				var j := cj + dj
				if i < 0 or j < 0 or i >= NX or j >= NZ:
					continue
				var kk := i + j * NX
				if nav[kk] != 1:
					continue
				var d := center_of(kk).distance_squared_to(Vector2(p.x, p.z))
				if d < best_d:
					best_d = d
					best = kk
		if best >= 0:
			return best
	return -1


# --- Search ------------------------------------------------------------------------------

## 4-neighbour BFS over nav cells from `sources` (cell indices). Returns the distance in cells
## per index (-1 = unreached). With `blocker` (a field from another search) a cell is only
## entered when `dist * ratio + margin < blocker[cell]` (reached safely before the blocker's
## sources: fleeing never plans a path a ghost gets to first).
func bfs(sources: PackedInt32Array, blocker := PackedInt32Array(), ratio := 1.0, margin := 0.0) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(NX * NZ)
	dist.fill(-1)
	var queue := PackedInt32Array()
	queue.resize(NX * NZ)
	var head := 0
	var tail := 0
	for s in sources:
		if s >= 0 and nav[s] == 1 and dist[s] < 0:
			dist[s] = 0
			queue[tail] = s
			tail += 1
	var use_blocker := blocker.size() == NX * NZ
	while head < tail:
		var k := queue[head]
		head += 1
		var nd := dist[k] + 1
		var i := k % NX
		for n: int in [k - 1 if i > 0 else -1, k + 1 if i < NX - 1 else -1, k - NX, k + NX]:
			if n < 0 or n >= NX * NZ or nav[n] != 1 or dist[n] >= 0:
				continue
			if use_blocker:
				var b := blocker[n]
				if b >= 0 and float(nd) * ratio + margin >= float(b):
					continue
			dist[n] = nd
			queue[tail] = n
			tail += 1
	return dist


## The cells from a search's source to `target` (source first), following `dist` downhill.
func path_to(dist: PackedInt32Array, target: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if target < 0 or dist[target] < 0:
		return out
	var k := target
	out.append(k)
	var guard := 0
	while dist[k] > 0 and guard < NX * NZ:
		guard += 1
		var i := k % NX
		var next := -1
		for n: int in [k - 1 if i > 0 else -1, k + 1 if i < NX - 1 else -1, k - NX, k + NX]:
			if n >= 0 and n < NX * NZ and dist[n] == dist[k] - 1:
				next = n
				break
		if next < 0:
			break
		k = next
		out.append(k)
	out.reverse()
	return out


## Where to walk next along `path` from `from`: the farthest path cell (up to `max_len` m away)
## in a straight, blob-wide line of sight (string pulling), pushed on along the same line to
## at least `min_len` m while that stays walkable (bots slow down near a goal and stop on it;
## the game re-plans long before they get there). The first cell when none is in sight.
func steer_point(from: Vector3, path: PackedInt32Array, max_len: float = 6.0, min_len: float = 2.5) -> Vector3:
	if path.is_empty():
		return from
	var best := center3(path[mini(1, path.size() - 1)])
	for idx in range(1, path.size()):
		var c := center3(path[idx])
		if Vector2(c.x - from.x, c.z - from.z).length() > max_len:
			break
		if has_los(from, c):
			best = c
	var flat := Vector3(best.x - from.x, 0.0, best.z - from.z)
	var d := flat.length()
	if d > 0.05 and d < min_len:
		var dir := flat / d
		var reach := d
		while reach + 0.25 <= min_len and has_los(from, Vector3(from.x, 0.0, from.z) + dir * (reach + 0.25)):
			reach += 0.25
		best = Vector3(from.x, 0.0, from.z) + dir * reach
	return best


# --- Building --------------------------------------------------------------------------

## SOLID cells merged into rectangles (Rect2 in metres), rows first then stacked.
func solid_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	var used := PackedByteArray()
	used.resize(NX * NZ)
	used.fill(0)
	for j in NZ:
		var i := 0
		while i < NX:
			var k := i + j * NX
			if cells[k] != SOLID or used[k] == 1:
				i += 1
				continue
			var i1 := i
			while i1 + 1 < NX and cells[i1 + 1 + j * NX] == SOLID and used[i1 + 1 + j * NX] == 0:
				i1 += 1
			var j1 := j
			while j1 + 1 < NZ:
				var full := true
				for ii in range(i, i1 + 1):
					var kk := ii + (j1 + 1) * NX
					if cells[kk] != SOLID or used[kk] == 1:
						full = false
						break
				if not full:
					break
				j1 += 1
			for jj in range(j, j1 + 1):
				for ii in range(i, i1 + 1):
					used[ii + jj * NX] = 1
			out.append(Rect2(X0 + i * CELL, Z0 + j * CELL, (i1 - i + 1) * CELL, (j1 - j + 1) * CELL))
			i = i1 + 1
	return out


func _fill(r: Rect2, value: int) -> void:
	for j in NZ:
		for i in NX:
			var k := i + j * NX
			if r.has_point(center_of(k)):
				cells[k] = value


func _fill_clutter(r: Rect2) -> void:
	for j in NZ:
		for i in NX:
			var k := i + j * NX
			if cells[k] != SOLID and r.has_point(center_of(k)):
				cells[k] = CLUTTER
