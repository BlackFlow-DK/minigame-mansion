extends RefCounted
## Builds Blob Ball's pitch under a root node from the ball sim's geometry: grass stripes
## (each half tinted toward its team's colour), white lines, team-tinted goal areas, low padded
## walls (team-coloured cushions per half), the two goals (frames in the defending team's
## colour), colliders for the blobs, and on MEDIUM/HIGH a sand path and a hedge around it all.
## Deterministic: every peer builds the same thing from the same numbers.

const GOAL_SCENE := "res://assets/models/props/ball_goal.glb"
## The goal model's mouth half-width (posts' centres); scaled to the sim's goal width.
const GOAL_MODEL_HALF_W := 2.0

const GRASS_LIGHT := Color("#74c45f")
const GRASS_DARK := Color("#5fb04f")
const LINE := Color("#f7f4ec")
const WALL := Color("#f3eee2")
const PATH := Color("#c4a877")
const LAWN := Color("#3f7a3b")
const HEDGE := Color("#3d7a3c")
const HEDGE_TOP := Color("#4d9147")

## Half tint toward the team colour (grass) and the goal-area tint.
const HALF_TINT := 0.13
const AREA_TINT := 0.32
const STRIPES := 12
const WALL_HEIGHT := 0.62
const WALL_THICK := 0.32
const CAP_HEIGHT := 0.16
## Player colliders: tall so nobody hops out.
const COLLIDER_HEIGHT := 3.0
const CORNER_STEPS := 10


## Builds everything under `root`. `team_colors[0]` defends the left goal (x < 0), `[1]` the
## right one. Returns {"goals": [left, right] Node3D}.
static func build(root: Node3D, sim: BlobBallSim, team_colors: Array[Color], low: bool) -> Dictionary:
	var hx := sim.half_length
	var hz := sim.half_width
	var rc := sim.corner_radius
	var gw := sim.goal_half_width

	# --- Ground ------------------------------------------------------------------------------
	var field := _rounded_rect(hx, hz, rc)
	var grass_poly := field
	for side: float in [-1.0, 1.0]:
		var box := PackedVector2Array([
			Vector2(side * (hx - 0.5), -gw), Vector2(side * (hx + sim.goal_depth), -gw),
			Vector2(side * (hx + sim.goal_depth), gw), Vector2(side * (hx - 0.5), gw)])
		var best := 0.0
		for m in Geometry2D.merge_polygons(grass_poly, box):
			var area := absf(_area(m))
			if area > best:
				best = area
				grass_poly = m
	var st_surfaces: Array = []  # [color, Array[PackedVector2Array]]
	var stripe_w := 2.0 * (hx + sim.goal_depth) / STRIPES
	for i in STRIPES:
		var x0 := -(hx + sim.goal_depth) + stripe_w * i
		var x1 := x0 + stripe_w
		var rect := PackedVector2Array([Vector2(x0, -hz - 1.0), Vector2(x1, -hz - 1.0), Vector2(x1, hz + 1.0), Vector2(x0, hz + 1.0)])
		var base := GRASS_LIGHT if i % 2 == 0 else GRASS_DARK
		var team := 0 if (x0 + x1) * 0.5 < 0.0 else 1
		var col := base.lerp(team_colors[team], HALF_TINT)
		st_surfaces.append([col, Geometry2D.intersect_polygons(grass_poly, rect)])
	_add_flat(root, "Grass", st_surfaces, 0.0)

	# Goal areas (in front of each goal and inside the box), stronger tint.
	var areas: Array = []
	var area_depth := 2.4 if hx > 9.0 else 1.9
	for side: float in [-1.0, 1.0]:
		var t := 0 if side < 0.0 else 1
		var a := PackedVector2Array([
			Vector2(side * (hx - area_depth), -(gw + 1.1)), Vector2(side * (hx + sim.goal_depth), -(gw + 1.1)),
			Vector2(side * (hx + sim.goal_depth), gw + 1.1), Vector2(side * (hx - area_depth), gw + 1.1)])
		if side < 0.0:
			a.reverse()
		var c := GRASS_LIGHT.lerp(team_colors[t], AREA_TINT)
		areas.append([c, Geometry2D.intersect_polygons(grass_poly, a)])
	_add_flat(root, "GoalAreas", areas, 0.012)

	# Lines.
	var lines: Array[PackedVector2Array] = []
	var outer := _rounded_rect(hx - 0.32, hz - 0.32, rc - 0.32)
	var inner := _rounded_rect(hx - 0.45, hz - 0.45, rc - 0.45)
	lines.append_array(_ring_quads(outer, inner))
	lines.append(_rect(-0.065, -(hz - 0.45), 0.065, hz - 0.45))
	var cr := 2.2 if hx > 9.0 else 1.7
	lines.append_array(_ring_quads(_circle(cr + 0.065, 48), _circle(cr - 0.065, 48)))
	lines.append(_circle(0.2, 16))
	for side: float in [-1.0, 1.0]:
		var xa := side * (hx - area_depth)
		var xb := side * (hx - 0.4)
		lines.append(_rect(minf(xa, xb), gw + 1.1 - 0.065, maxf(xa, xb), gw + 1.1 + 0.065))
		lines.append(_rect(minf(xa, xb), -(gw + 1.1) - 0.065, maxf(xa, xb), -(gw + 1.1) + 0.065))
		lines.append(_rect(xa - 0.065, -(gw + 1.1), xa + 0.065, gw + 1.1))
	var line_surf: Array = [[LINE, lines]]
	_add_flat(root, "Lines", line_surf, 0.024, false)

	var path_out := _rounded_rect(hx + 2.3, hz + 2.3, rc + 2.3)
	var path_in := _rounded_rect(hx + WALL_THICK, hz + WALL_THICK, rc + WALL_THICK)
	var ring: Array = [[PATH, _ring_quads(path_out, path_in)]]
	_add_flat(root, "Path", ring, -0.005)
	if not low:
		_add_hedge(root, _rounded_rect(hx + 2.3, hz + 2.3, rc + 2.3), _rounded_rect(hx + 3.3, hz + 3.3, rc + 3.3))
	var lawn := MeshInstance3D.new()
	lawn.name = "Lawn"
	var plane := PlaneMesh.new()
	plane.size = Vector2(90.0, 90.0)
	lawn.mesh = plane
	lawn.material_override = Look.toon_material(LAWN if not low else LAWN.lerp(PATH, 0.15), 0.95, false)
	lawn.position.y = -0.03
	root.add_child(lawn)

	# --- Walls -------------------------------------------------------------------------------
	var polylines := _wall_polylines(hx, hz, rc, gw)
	_add_walls(root, polylines, team_colors)
	var body := StaticBody3D.new()
	body.name = "WallColliders"
	body.collision_mask = 0
	root.add_child(body)
	for pl: Array in polylines:
		for i in pl.size() - 1:
			var a: Vector2 = pl[i][0]
			var b: Vector2 = pl[i + 1][0]
			var n: Vector2 = ((pl[i][1] as Vector2) + (pl[i + 1][1] as Vector2)).normalized()
			_box_collider(body, a, b, n, 0.5)
	# Goal boxes: side nets, back net, posts.
	for side: float in [-1.0, 1.0]:
		var back := side * (hx + sim.goal_depth)
		_box_collider(body, Vector2(back, -gw - 0.3), Vector2(back, gw + 0.3), Vector2(side, 0.0), 0.4)
		for sz: float in [-1.0, 1.0]:
			_box_collider(body, Vector2(side * hx, sz * gw), Vector2(back, sz * gw), Vector2(0.0, sz), 0.3)
			var post := CollisionShape3D.new()
			var cyl := CylinderShape3D.new()
			cyl.radius = sim.post_radius
			cyl.height = COLLIDER_HEIGHT
			post.shape = cyl
			post.position = Vector3(side * hx, COLLIDER_HEIGHT * 0.5, sz * gw)
			body.add_child(post)

	# --- Goals -------------------------------------------------------------------------------
	var goals: Array[Node3D] = []
	var scene := load(GOAL_SCENE) as PackedScene
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var g: Node3D = scene.instantiate() as Node3D if scene else Node3D.new()
		g.name = "GoalLeft" if i == 0 else "GoalRight"
		g.position = Vector3(side * hx, 0.0, 0.0)
		g.rotation.y = -side * PI * 0.5
		g.scale = Vector3(gw / GOAL_MODEL_HALF_W, 1.0, 1.0)
		root.add_child(g)
		Look.apply_toon(g)
		tint_goal(g, team_colors[i])
		goals.append(g)
	return {"goals": goals}


## Recolours a goal model's `TeamFrame` material.
static func tint_goal(goal: Node3D, color: Color) -> void:
	for n in goal.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			if m and m.resource_name == "TeamFrame":
				mi.set_surface_override_material(s, Look.toon_material(color, 0.5))


# --- Geometry ----------------------------------------------------------------------------------

## Closed rounded rectangle (x, z) around the origin, counter-clockwise in (x, z), with the
## same vertex count for any size (so two of them make a ring of quads).
static func _rounded_rect(hx: float, hz: float, rc: float) -> PackedVector2Array:
	rc = maxf(rc, 0.01)
	var pts := PackedVector2Array()
	var centres := [Vector2(hx - rc, hz - rc), Vector2(-(hx - rc), hz - rc), Vector2(-(hx - rc), -(hz - rc)), Vector2(hx - rc, -(hz - rc))]
	for c in 4:
		for k in CORNER_STEPS + 1:
			var a := PI * 0.5 * c + PI * 0.5 * k / CORNER_STEPS
			pts.append((centres[c] as Vector2) + Vector2(cos(a), sin(a)) * rc)
	return pts


static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		a += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return a * 0.5


static func _circle(r: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * i / n
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


static func _rect(x0: float, z0: float, x1: float, z1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)])


## Quads between two closed outlines with the same vertex count.
static func _ring_quads(outer: PackedVector2Array, inner: PackedVector2Array) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var n := outer.size()
	for i in n:
		var j := (i + 1) % n
		out.append(PackedVector2Array([outer[i], outer[j], inner[j], inner[i]]))
	return out


## The wall's inner face as two polylines of [point, outward normal], each running from one
## goal mouth to the other (the mouths are the gaps). Split at x = 0 so each half colours alone.
static func _wall_polylines(hx: float, hz: float, rc: float, gw: float) -> Array:
	var top: Array = [[Vector2(hx, gw), Vector2.RIGHT]]
	_arc_into(top, Vector2(hx - rc, hz - rc), rc, 0.0, PI * 0.5)
	top.append([Vector2(0.0, hz), Vector2(0.0, 1.0)])
	_arc_into(top, Vector2(-(hx - rc), hz - rc), rc, PI * 0.5, PI)
	top.append([Vector2(-hx, gw), Vector2.LEFT])
	var bottom: Array = [[Vector2(-hx, -gw), Vector2.LEFT]]
	_arc_into(bottom, Vector2(-(hx - rc), -(hz - rc)), rc, PI, PI * 1.5)
	bottom.append([Vector2(0.0, -hz), Vector2(0.0, -1.0)])
	_arc_into(bottom, Vector2(hx - rc, -(hz - rc)), rc, PI * 1.5, TAU)
	bottom.append([Vector2(hx, -gw), Vector2.RIGHT])
	return [top, bottom]


static func _arc_into(pl: Array, c: Vector2, r: float, a0: float, a1: float) -> void:
	for k in CORNER_STEPS + 1:
		var a := a0 + (a1 - a0) * k / CORNER_STEPS
		var n := Vector2(cos(a), sin(a))
		pl.append([c + n * r, n])


static func _v3(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x, y, p.y)


## Flat surfaces at height `y`: `surfaces` is an Array of [Color, Array of polygons].
static func _add_flat(root: Node3D, node_name: String, surfaces: Array, y: float, shaded: bool = true) -> void:
	var mesh := ArrayMesh.new()
	for entry: Array in surfaces:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_normal(Vector3.UP)
		var any := false
		for poly: PackedVector2Array in entry[1]:
			var idx := Geometry2D.triangulate_polygon(poly)
			for k in idx:
				st.add_vertex(_v3(poly[k], y))
				any = true
		if not any:
			continue
		var mat := Look.toon_material(entry[0], 0.95, false)
		if not shaded:
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		st.set_material(mat)
		st.commit(mesh)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


## The low padded wall along both polylines: cream boards, a cushion in the team colour of
## that half on top and along the top of the inner face.
static func _add_walls(root: Node3D, polylines: Array, team_colors: Array[Color]) -> void:
	var tools: Array[SurfaceTool] = []
	for i in 3:  # 0 boards, 1 left cushion, 2 right cushion
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		tools.append(st)
	var h0 := WALL_HEIGHT - CAP_HEIGHT
	for pl: Array in polylines:
		for i in pl.size() - 1:
			var a: Vector2 = pl[i][0]
			var b: Vector2 = pl[i + 1][0]
			var na: Vector2 = pl[i][1]
			var nb: Vector2 = pl[i + 1][1]
			var ao := a + na * WALL_THICK
			var bo := b + nb * WALL_THICK
			var cap := tools[1] if (a.x + b.x) < 0.0 else tools[2]
			# inner face (faces the pitch: normal -n)
			_quad(tools[0], _v3(a, 0.0), _v3(b, 0.0), _v3(b, h0), _v3(a, h0), -_v3((na + nb).normalized(), 0.0))
			_quad(cap, _v3(a, h0), _v3(b, h0), _v3(b, WALL_HEIGHT), _v3(a, WALL_HEIGHT), -_v3((na + nb).normalized(), 0.0))
			# top
			_quad(cap, _v3(a, WALL_HEIGHT), _v3(b, WALL_HEIGHT), _v3(bo, WALL_HEIGHT), _v3(ao, WALL_HEIGHT), Vector3.UP)
			# outer face
			_quad(tools[0], _v3(ao, 0.0), _v3(bo, 0.0), _v3(bo, WALL_HEIGHT), _v3(ao, WALL_HEIGHT), _v3((na + nb).normalized(), 0.0))
		# end caps at the goal posts
		for end: int in [0, pl.size() - 1]:
			var p: Vector2 = pl[end][0]
			var n: Vector2 = pl[end][1]
			var po := p + n * WALL_THICK
			var t := Vector2(-n.y, n.x)
			_quad(tools[0], _v3(p, 0.0), _v3(po, 0.0), _v3(po, WALL_HEIGHT), _v3(p, WALL_HEIGHT), _v3(t, 0.0))
	var mesh := ArrayMesh.new()
	var colors := [WALL, team_colors[0], team_colors[1]]
	for i in 3:
		var mat := Look.toon_material(colors[i], 0.7, false)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		tools[i].set_material(mat)
		tools[i].commit(mesh)
	var mi := MeshInstance3D.new()
	mi.name = "Walls"
	mi.mesh = mesh
	root.add_child(mi)


static func _add_hedge(root: Node3D, inner: PackedVector2Array, outer: PackedVector2Array) -> void:
	var side := SurfaceTool.new()
	side.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := SurfaceTool.new()
	top.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := 0.95
	var n := inner.size()
	for i in n:
		var j := (i + 1) % n
		var nrm := -_v3((inner[i] + inner[j]).normalized(), 0.0)
		_quad(side, _v3(inner[i], 0.0), _v3(inner[j], 0.0), _v3(inner[j], h), _v3(inner[i], h), nrm)
		_quad(top, _v3(inner[i], h), _v3(inner[j], h), _v3(outer[j], h), _v3(outer[i], h), Vector3.UP)
	var mesh := ArrayMesh.new()
	for pair: Array in [[side, HEDGE], [top, HEDGE_TOP]]:
		var mat := Look.toon_material(pair[1], 0.95, false)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		(pair[0] as SurfaceTool).set_material(mat)
		(pair[0] as SurfaceTool).commit(mesh)
	var mi := MeshInstance3D.new()
	mi.name = "Hedge"
	mi.mesh = mesh
	root.add_child(mi)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	st.set_normal(n)
	for v in [a, b, c, a, c, d]:
		st.add_vertex(v)


## A tall box collider along a->b (x,z), pushed `thick`/2 outward along `n`.
static func _box_collider(body: StaticBody3D, a: Vector2, b: Vector2, n: Vector2, thick: float) -> void:
	var d := b - a
	var len := d.length()
	if len < 0.001:
		return
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(len + 0.12, COLLIDER_HEIGHT, thick)
	cs.shape = box
	var mid := (a + b) * 0.5 + n * thick * 0.5
	cs.position = Vector3(mid.x, COLLIDER_HEIGHT * 0.5, mid.y)
	cs.rotation.y = atan2(-d.y, d.x)
	body.add_child(cs)
