class_name HideLayout
extends RefCounted
## Hide and Sneak: the parlour's data. Disguise kinds, the fixed decor, the seeded furniture
## layout (pure: the same seed gives the same room on every peer) and a grid path planner for
## the bots (AStarGrid2D over the furniture footprints).
## Room: walls at x = +-HALF_X and z = BACK_Z, the front (z = FRONT_Z) open toward the camera.

const HALF_X := 10.0
const BACK_Z := -8.0
const FRONT_Z := 8.0
## Blob centres stay inside this (walls minus blob radius and a margin).
const PLAY_HALF_X := 9.35
const PLAY_BACK_Z := -7.4
const PLAY_FRONT_Z := 7.5
## The rug in the middle is kept clear of furniture: the hiders spawn there.
const CLEAR_CENTER := Vector3(0.0, 0.0, 0.8)
const CLEAR_RADIUS := 3.0
## The closet door in the back wall: kept clear so the seekers can burst out.
const DOOR_ZONE := Rect2(-2.3, -8.0, 4.6, 2.9)  # x, z, width, depth
## Seekers wait here (behind the back wall, out of the camera's sight) during HIDE...
const CLOSET_SPOTS: Array[Vector3] = [Vector3(-0.75, 0.0, -9.6), Vector3(0.75, 0.0, -9.6)]
## ...and burst out of the door here when SEEK starts.
const DOOR_SPOTS: Array[Vector3] = [Vector3(-0.75, 0.0, -6.8), Vector3(0.75, 0.0, -6.8)]

## Disguise kinds (also the furniture the room is filled with). `radius`: footprint for
## spacing, pokes and the planner; `shape`: collider ("box" size or "cyl" radius/height).
const KINDS: Array[Dictionary] = [
	{"id": &"armchair", "name": "Armchair", "path": "res://assets/models/env/armchair.glb", "scale": 0.95,
		"radius": 0.5, "shape": "box", "size": Vector3(0.95, 1.05, 0.95)},
	{"id": &"side_table", "name": "Side table", "path": "res://assets/models/env/side_table.glb", "scale": 1.0,
		"radius": 0.38, "shape": "box", "size": Vector3(0.7, 1.1, 0.7)},
	{"id": &"plant", "name": "Potted plant", "path": "res://assets/models/env/potted_plant.glb", "scale": 0.85,
		"radius": 0.42, "shape": "cyl", "size": Vector3(0.38, 1.4, 0.38)},
	{"id": &"crate", "name": "Crate", "path": "res://assets/models/props/crate.glb", "scale": 1.0,
		"radius": 0.47, "shape": "box", "size": Vector3(0.94, 0.9, 0.94)},
	{"id": &"barrel", "name": "Barrel", "path": "res://assets/models/props/barrel.glb", "scale": 1.2,
		"radius": 0.45, "shape": "cyl", "size": Vector3(0.45, 0.9, 0.45)},
	{"id": &"armour", "name": "Suit of armour", "path": "res://assets/models/env/suit_of_armour.glb", "scale": 0.7,
		"radius": 0.42, "shape": "box", "size": Vector3(0.8, 1.47, 0.46)},
	{"id": &"clock", "name": "Clock", "path": "res://assets/models/props/hide_clock.glb", "scale": 1.0,
		"radius": 0.36, "shape": "box", "size": Vector3(0.62, 1.5, 0.42)},
	{"id": &"vase", "name": "Vase", "path": "res://assets/models/props/hide_vase.glb", "scale": 1.0,
		"radius": 0.32, "shape": "box", "size": Vector3(0.5, 1.42, 0.5)},
]

## Fixed decor: [piece path, position, yaw deg, collider rect (x0, z0, x1, z1) or empty].
const DECOR: Array = [
	["res://assets/models/env/fireplace.glb", Vector3(-5.0, 0.0, -7.55), 0.0, [-6.55, -8.0, -3.45, -6.9]],
	["res://assets/models/env/piano.glb", Vector3(7.7, 0.0, -6.4), -90.0, [5.95, -7.2, 8.85, -5.5]],
	["res://assets/models/env/bookshelf.glb", Vector3(-9.5, 0.0, -4.6), 90.0, [-9.8, -5.7, -9.15, -3.5]],
	["res://assets/models/env/bookshelf.glb", Vector3(-9.5, 0.0, 4.4), 90.0, [-9.8, 3.3, -9.15, 5.5]],
	["res://assets/models/env/bookshelf.glb", Vector3(9.5, 0.0, -1.6), -90.0, [9.15, -2.7, 9.8, -0.5]],
	["res://assets/models/env/bookshelf.glb", Vector3(9.5, 0.0, 3.0), -90.0, [9.15, 1.9, 9.8, 4.1]],
	["res://assets/models/env/sofa.glb", Vector3(0.0, 0.0, -2.95), 0.0, [-1.15, -3.45, 1.15, -2.45]],
	["res://assets/models/env/sofa.glb", Vector3(0.0, 0.0, 4.65), 180.0, [-1.15, 4.15, 1.15, 5.15]],
]

## Cluster anchors: furniture gathers around these (the seed jitters and themes them).
const ANCHORS: Array[Vector3] = [
	Vector3(-7.4, 0, -5.6), Vector3(-2.9, 0, -5.2), Vector3(3.2, 0, -4.6), Vector3(7.2, 0, -3.4),
	Vector3(-7.4, 0, -1.2), Vector3(7.3, 0, 0.6), Vector3(-7.2, 0, 2.4), Vector3(7.2, 0, 4.8),
	Vector3(-5.0, 0, 6.0), Vector3(-1.4, 0, 6.4), Vector3(2.8, 0, 6.2), Vector3(-4.7, 0, -1.6),
	Vector3(4.7, 0, 1.9), Vector3(0.0, 0, -4.6),
]
const CLUSTERS := 11
const COUNT_RANGE := Vector2i(44, 56)
## Chance a piece takes its cluster's theme kind (the rest are random kinds).
const THEME_CHANCE := 0.62
## Extra space kept between two footprints.
const GAP := 0.32

## Planner grid.
const CELL := 0.5
const GRID_W := 40
const GRID_H := 32
## Footprints grow by this for the planner (blob radius + a margin).
const INFLATE := 0.45
## A waypoint is at least this far from the bot (more than BotBrain's arrive radius).
const MIN_STEP := 0.9


static func kind_count() -> int:
	return KINDS.size()


static func kind_radius(kind: int) -> float:
	return float(KINDS[kind]["radius"]) if kind >= 0 and kind < KINDS.size() else 0.45


static func kind_name(kind: int) -> String:
	return String(KINDS[kind]["name"]) if kind >= 0 and kind < KINDS.size() else "?"


## The furniture of a room for `seed`: Array of {kind: int, pos: Vector3, yaw: float (rad)}.
## Deterministic (its own RNG), 44-56 pieces in themed clusters, clear of the decor, the rug
## in the middle and the closet door.
static func generate(seed_value: int) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var anchors: Array[Vector3] = ANCHORS.duplicate()
	# Fisher-Yates with our own RNG (Array.shuffle uses the global one).
	for i in range(anchors.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := anchors[i]
		anchors[i] = anchors[j]
		anchors[j] = t
	anchors.resize(CLUSTERS)
	var themes: Array[int] = []
	for i in CLUSTERS:
		themes.append(i % KINDS.size())
	for i in range(themes.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := themes[i]
		themes[i] = themes[j]
		themes[j] = t
	for i in anchors.size():
		anchors[i] += Vector3(rng.randf_range(-0.5, 0.5), 0.0, rng.randf_range(-0.5, 0.5))
	var target := rng.randi_range(COUNT_RANGE.x, COUNT_RANGE.y)
	var out: Array[Dictionary] = []
	var tries := 0
	var c := 0
	while out.size() < target and tries < 6000:
		tries += 1
		c = (c + 1) % CLUSTERS
		var kind := themes[c] if rng.randf() < THEME_CHANCE else rng.randi_range(0, KINDS.size() - 1)
		var r := kind_radius(kind)
		var ang := rng.randf() * TAU
		var dist := sqrt(rng.randf()) * 2.4
		var pos := anchors[c] + Vector3(cos(ang), 0.0, sin(ang)) * dist
		if not fits(pos, r, out):
			continue
		out.append({"kind": kind, "pos": pos, "yaw": _yaw_for(pos, anchors[c], rng)})
	return out


## True when a footprint of radius `r` at `pos` lies in the room, off the rug, the door zone and
## the decor, and clear of every piece in `placed`.
static func fits(pos: Vector3, r: float, placed: Array[Dictionary], gap: float = GAP) -> bool:
	if absf(pos.x) > PLAY_HALF_X + 0.1 - r or pos.z < PLAY_BACK_Z - 0.1 + r or pos.z > PLAY_FRONT_Z - 0.3 - r:
		return false
	if _flat(pos - CLEAR_CENTER).length() < CLEAR_RADIUS + r:
		return false
	if _in_rect(pos, [DOOR_ZONE.position.x, DOOR_ZONE.position.y, DOOR_ZONE.end.x, DOOR_ZONE.end.y], r):
		return false
	for d: Array in DECOR:
		var rect: Array = d[3]
		if not rect.is_empty() and _in_rect(pos, rect, r + 0.15):
			return false
	for q in placed:
		if _flat(pos - (q["pos"] as Vector3)).length() < r + kind_radius(int(q["kind"])) + gap:
			return false
	return true


## Furniture faces the room: away from a nearby wall, else toward its cluster's middle, snapped
## to quarter turns with a little jitter (that is how a lived-in room looks).
static func _yaw_for(pos: Vector3, anchor: Vector3, rng: RandomNumberGenerator) -> float:
	var face := anchor - pos
	if pos.x < -HALF_X + 1.6:
		face = Vector3.RIGHT
	elif pos.x > HALF_X - 1.6:
		face = Vector3.LEFT
	elif pos.z < BACK_Z + 1.6:
		face = Vector3.BACK
	elif face.length() < 0.3:
		face = CLEAR_CENTER - pos
	var yaw := atan2(face.x, face.z)
	yaw = snappedf(yaw, PI * 0.5)
	return yaw + deg_to_rad(rng.randf_range(-9.0, 9.0))


static func _in_rect(pos: Vector3, rect: Array, margin: float) -> bool:
	return pos.x > float(rect[0]) - margin and pos.x < float(rect[2]) + margin \
		and pos.z > float(rect[1]) - margin and pos.z < float(rect[3]) + margin


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


## A stable fingerprint of a layout (network check: every peer must build the same room).
static func fingerprint(layout: Array[Dictionary]) -> String:
	var parts: PackedStringArray = []
	for f in layout:
		var p: Vector3 = f["pos"]
		parts.append("%d:%.2f,%.2f,%.2f" % [int(f["kind"]), p.x, p.z, float(f["yaw"])])
	return str(hash(",".join(parts)))


# --- Planner ----------------------------------------------------------------------------------

## An AStarGrid2D over the room: furniture and decor footprints (grown by INFLATE) are solid.
static func build_grid(layout: Array[Dictionary]) -> AStarGrid2D:
	var g := AStarGrid2D.new()
	g.region = Rect2i(0, 0, GRID_W, GRID_H)
	g.cell_size = Vector2(1, 1)
	g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	g.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	g.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	g.update()
	for x in GRID_W:
		for y in GRID_H:
			var p := cell_center(Vector2i(x, y))
			var solid := absf(p.x) > PLAY_HALF_X or p.z < PLAY_BACK_Z or p.z > PLAY_FRONT_Z
			if not solid:
				for d: Array in DECOR:
					if _in_rect(p, d[3], INFLATE - 0.1):
						solid = true
						break
			if not solid:
				for f in layout:
					if _flat(p - (f["pos"] as Vector3)).length() < kind_radius(int(f["kind"])) + INFLATE:
						solid = true
						break
			g.set_point_solid(Vector2i(x, y), solid)
	return g


static func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(clampi(int(floor((p.x + HALF_X) / CELL)), 0, GRID_W - 1),
		clampi(int(floor((p.z - BACK_Z) / CELL)), 0, GRID_H - 1))


static func cell_center(c: Vector2i) -> Vector3:
	return Vector3(-HALF_X + (c.x + 0.5) * CELL, 0.0, BACK_Z + (c.y + 0.5) * CELL)


## The free cell nearest to `p` (searching outward), or `p`'s own cell.
static func free_cell_near(g: AStarGrid2D, p: Vector3, toward: Vector3 = Vector3.INF) -> Vector2i:
	var c := cell_of(p)
	if not g.is_point_solid(c):
		return c
	var best := c
	var best_d := INF
	for r in range(1, 6):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var n := c + Vector2i(dx, dy)
				if not g.is_in_boundsv(n) or g.is_point_solid(n):
					continue
				var cp := cell_center(n)
				var d := _flat(cp - p).length()
				if toward != Vector3.INF:
					d += 0.35 * _flat(cp - toward).length()
				if d < best_d:
					best_d = d
					best = n
		if best_d < INF:
			return best
	return c


## The next waypoint from `from` toward `to` along a grid path: the furthest path point (within
## `max_step` m, at least MIN_STEP away so a bot never "arrives" where it stands) that `from`
## can walk to in a straight line; `to` itself when it is in sight.
static func next_waypoint(g: AStarGrid2D, from: Vector3, to: Vector3, max_step: float = 4.0) -> Vector3:
	var flat_to := Vector3(to.x, 0.0, to.z)
	if _flat(to - from).length() <= max_step and line_clear(g, from, to):
		return flat_to
	var a := free_cell_near(g, from)
	var b := free_cell_near(g, to, from)
	var path := g.get_id_path(a, b, true)
	if path.is_empty():
		return flat_to
	var best := Vector3.INF
	var best_i := -1
	for i in path.size():
		var p := cell_center(path[i])
		var d := _flat(p - from).length()
		if d > max_step:
			break
		if d >= MIN_STEP and line_clear(g, from, p):
			best = p
			best_i = i
	if best == Vector3.INF:
		for i in path.size():
			var p := cell_center(path[i])
			if _flat(p - from).length() >= MIN_STEP:
				return p
		return flat_to
	if best_i == path.size() - 1 and line_clear(g, best, to):
		return flat_to
	return best


## True when the straight segment crosses no solid cell (sampled every quarter cell; the cells
## right around the start and the end cell do not count: a bot may stand in a grown footprint).
static func line_clear(g: AStarGrid2D, a: Vector3, b: Vector3) -> bool:
	var d := _flat(b - a).length()
	var n := maxi(1, int(ceil(d / (CELL * 0.25))))
	var end := cell_of(b)
	for i in range(n + 1):
		var t := float(i) / n
		if t * d < 0.45:
			continue
		var c := cell_of(a.lerp(b, t))
		if c == end:
			continue
		if g.is_point_solid(c):
			return false
	return true
