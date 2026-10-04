class_name SnowYard
extends RefCounted
## Snowball Fight: the courtyard layout as plain data (every peer, identical) plus the scene build.
## A walled yard (HALF_X x HALF_Z inner faces), six low snow walls, two cover snowmen and two pines,
## all point-symmetric about the centre so no spawn is favoured. Snowballs are blocked by simple
## shapes (boxes for walls, cylinders for snowmen and pines, the yard walls, the ground) through
## `ball_blocked`, so the ball maths never touch the physics server and are the same everywhere.

const SNOW_WALL: PackedScene = preload("res://assets/models/props/snow_wall.glb")
const SNOW_MAN: PackedScene = preload("res://assets/models/props/snow_man.glb")
const SNOW_PINE: PackedScene = preload("res://assets/models/props/snow_pine.glb")
const SNOW_LANTERN: PackedScene = preload("res://assets/models/props/snow_lantern.glb")
const SNOW_DRIFT: PackedScene = preload("res://assets/models/props/snow_drift.glb")
const YARD_WALL: PackedScene = preload("res://assets/models/props/snow_yard_wall.glb")

## Inner faces of the courtyard walls (m).
const HALF_X := 10.0
const HALF_Z := 7.0
## Cover walls: centres on XZ, and whether each runs along Z (else along X).
const WALLS: Array[Vector2] = [Vector2(-2.4, -3.4), Vector2(2.4, 3.4), Vector2(2.4, -3.4), Vector2(-2.4, 3.4),
	Vector2(-5.4, 0.0), Vector2(5.4, 0.0), Vector2(-7.7, -4.3), Vector2(7.7, 4.3)]
const WALL_ALONG_Z: Array[bool] = [false, false, false, false, true, true, false, false]
const WALL_LEN := 2.4
const WALL_THICK := 0.6
const WALL_H := 1.1
## Cover snowmen and pines (none inside the yard now; kept for the shapes): centres, blocking radius and height.
const SNOWMEN: Array[Vector2] = [Vector2(-7.4, 4.4), Vector2(7.4, -4.4)]
const SNOWMAN_R := 0.55
const SNOWMAN_H := 1.95
const PINES: Array[Vector2] = []
const PINE_R := 0.8
const PINE_H := 3.7
## Pines only collide with their trunk and lower boughs (players).
const PINE_BODY_R := 0.55
## The ammo pile's spot.
const PILE_AT := Vector3.ZERO

## Lantern posts (outside the yard walls) and how many of them get a light above LOW.
const LANTERNS: Array[Vector2] = [Vector2(-6.0, -7.9), Vector2(6.0, -7.9), Vector2(-10.9, 3.0), Vector2(10.9, -3.0)]


## Half extents of cover wall `i` (x, y, z); its box centre is at (WALLS[i].x, WALL_H / 2, WALLS[i].y).
static func wall_half(i: int) -> Vector3:
	if WALL_ALONG_Z[i]:
		return Vector3(WALL_THICK * 0.5, WALL_H * 0.5, WALL_LEN * 0.5)
	return Vector3(WALL_LEN * 0.5, WALL_H * 0.5, WALL_THICK * 0.5)


## What a ball of radius `r` centred at `p` runs into: 0 nothing, 1 cover, 2 the ground, 3 a yard wall.
static func ball_blocked(p: Vector3, r: float) -> int:
	if p.y < r * 0.5:
		return 2
	if absf(p.x) > HALF_X - r or absf(p.z) > HALF_Z - r:
		return 3
	if p.y < WALL_H + r:
		for i in WALLS.size():
			var h := wall_half(i)
			var c := WALLS[i]
			if absf(p.x - c.x) < h.x + r and absf(p.z - c.y) < h.z + r and absf(p.y - h.y) < h.y + r:
				return 1
	var flat := Vector2(p.x, p.z)
	if p.y < SNOWMAN_H + r:
		for c in SNOWMEN:
			if flat.distance_squared_to(c) < (SNOWMAN_R + r) * (SNOWMAN_R + r):
				return 1
	if p.y < PINE_H + r:
		for c in PINES:
			if flat.distance_squared_to(c) < (PINE_R + r) * (PINE_R + r):
				return 1
	return 0


## Ground a blob can stand on: inside the yard (`margin` from the walls) and clear of every cover
## piece by `margin`. Bots treat everything else as unsafe, so they walk around cover.
static func walkable(p: Vector3, margin: float = 0.55) -> bool:
	if absf(p.x) > HALF_X - margin or absf(p.z) > HALF_Z - margin:
		return false
	for i in WALLS.size():
		var h := wall_half(i)
		var c := WALLS[i]
		if absf(p.x - c.x) < h.x + margin and absf(p.z - c.y) < h.z + margin:
			return false
	var flat := Vector2(p.x, p.z)
	for c in SNOWMEN:
		if flat.distance_to(c) < SNOWMAN_R + margin:
			return false
	for c in PINES:
		if flat.distance_to(c) < PINE_BODY_R + margin:
			return false
	return true


## Every cover piece as [centre (XZ), half size along X, half size along Z] (round pieces: radius twice).
static func cover_pieces() -> Array[Array]:
	var out: Array[Array] = []
	for i in WALLS.size():
		var h := wall_half(i)
		out.append([WALLS[i], h.x, h.z])
	for c in SNOWMEN:
		out.append([c, SNOWMAN_R, SNOWMAN_R])
	for c in PINES:
		out.append([c, PINE_BODY_R, PINE_BODY_R])
	return out


## Builds the colliders and the decor under `root`. `low`: Look quality LOW (fewer extras).
static func build(root: Node3D, low: bool) -> Dictionary:
	var body := StaticBody3D.new()
	body.name = "Colliders"
	body.collision_layer = 1
	body.collision_mask = 0
	root.add_child(body)
	# Yard walls (tall enough that nobody hops out).
	for s: float in [-1.0, 1.0]:
		_box(body, Vector3(2.0 * HALF_X + 2.0, 4.0, 1.0), Vector3(0.0, 2.0, s * (HALF_Z + 0.5)))
		_box(body, Vector3(1.0, 4.0, 2.0 * HALF_Z + 2.0), Vector3(s * (HALF_X + 0.5), 2.0, 0.0))
	var decor := Node3D.new()
	decor.name = "Decor"
	root.add_child(decor)
	for i in WALLS.size():
		var c := WALLS[i]
		var h := wall_half(i)
		_box(body, h * 2.0, Vector3(c.x, h.y, c.y))
		_place(decor, SNOW_WALL, Vector3(c.x, 0.0, c.y), PI * 0.5 if WALL_ALONG_Z[i] else 0.0)
	for c in SNOWMEN:
		_cyl(body, SNOWMAN_R, SNOWMAN_H, Vector3(c.x, 0.0, c.y))
		_place(decor, SNOW_MAN, Vector3(c.x, 0.0, c.y), atan2(-c.x, -c.y))
	for c in PINES:
		_cyl(body, PINE_BODY_R, 2.0, Vector3(c.x, 0.0, c.y))
		_place(decor, SNOW_PINE, Vector3(c.x, 0.0, c.y), c.x * 0.3)
	# The courtyard walls: 5 segments (4.2 m) along X, 4 along Z (corners overlap).
	# The near wall (toward the camera) is kept low so it never hides a blob.
	for k in 5:
		var x := -8.4 + 4.2 * k
		_place(decor, YARD_WALL, Vector3(x, 0.0, -(HALF_Z + 0.25)), 0.0)
		var near := _place(decor, YARD_WALL, Vector3(-x, 0.0, HALF_Z + 0.25), PI)
		near.scale = Vector3(1.0, 0.5, 1.0)
	for k in 4:
		var z := -5.48 + 3.654 * k
		var left := _place(decor, YARD_WALL, Vector3(-(HALF_X + 0.25), 0.0, z), PI * 0.5)
		var right := _place(decor, YARD_WALL, Vector3(HALF_X + 0.25, 0.0, -z), -PI * 0.5)
		left.scale = Vector3(0.87, 1.0, 1.0)
		right.scale = Vector3(0.87, 1.0, 1.0)
	# Pines and drifts outside the walls (the camera sees the far side and the flanks).
	var outside: Array[Vector3] = [Vector3(-9.0, 0, -9.6), Vector3(-4.2, 0, -10.4), Vector3(1.4, 0, -9.8),
		Vector3(6.6, 0, -10.2), Vector3(11.0, 0, -9.0), Vector3(-12.6, 0, -6.0), Vector3(12.8, 0, -4.4),
		Vector3(-12.4, 0, 1.6), Vector3(12.6, 0, 3.0)]
	for i in outside.size():
		if low and i % 2 == 1:
			continue
		var at := outside[i]
		var tree := _place(decor, SNOW_PINE, at, float(i) * 1.7)
		tree.scale = Vector3.ONE * (1.0 + 0.12 * float((i * 7) % 4))
	var drifts: Array[Vector3] = [Vector3(-7.0, 0, -8.6), Vector3(3.6, 0, -8.7), Vector3(-11.4, 0, -2.0),
		Vector3(11.5, 0, 0.8), Vector3(-9.0, 0, 6.35), Vector3(9.0, 0, -6.35), Vector3(-0.2, 0, 6.4), Vector3(0.2, 0, -6.4)]
	for i in drifts.size():
		var d := _place(decor, SNOW_DRIFT, drifts[i], float(i) * 2.3)
		if absf(drifts[i].x) < HALF_X and absf(drifts[i].z) < HALF_Z:
			d.scale = Vector3(0.7, 0.7, 0.5)  # inside the yard: flat against the wall
	var lights: Array[OmniLight3D] = []
	for i in LANTERNS.size():
		var c := LANTERNS[i]
		_place(decor, SNOW_LANTERN, Vector3(c.x, 0.0, c.y), 0.0)
		var light := OmniLight3D.new()
		light.position = Vector3(c.x, 2.0, c.y)
		light.light_color = Color(1.0, 0.78, 0.5)
		light.light_energy = 1.4
		light.omni_range = 5.0
		light.shadow_enabled = false
		decor.add_child(light)
		lights.append(light)
	return {"lights": lights}


static func _place(parent: Node3D, scene: PackedScene, at: Vector3, yaw: float) -> Node3D:
	var n := scene.instantiate() as Node3D
	n.position = at
	n.rotation.y = yaw
	parent.add_child(n)
	Look.apply_toon(n)
	return n


static func _box(body: StaticBody3D, size: Vector3, at: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var cs := CollisionShape3D.new()
	cs.shape = box
	cs.position = at
	body.add_child(cs)


static func _cyl(body: StaticBody3D, radius: float, height: float, base: Vector3) -> void:
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	var cs := CollisionShape3D.new()
	cs.shape = cyl
	cs.position = base + Vector3(0.0, height * 0.5, 0.0)
	body.add_child(cs)
