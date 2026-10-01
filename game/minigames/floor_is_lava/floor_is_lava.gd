class_name FloorIsLava
extends Minigame
## Floor Is Lava: a field of hexagonal stone tiles over a lake of lava. A tile a grounded
## player stays on for `touch_time` starts cracking and falls `crack_delay` later, for good. From
## `collapse_start` on, untouched tiles crack by themselves (outer rings first, faster and
## faster), so a round always ends well inside the time limit. Falling into the lava knocks
## you out; the last blob standing wins. Shoving as usual.
##
## Networking: the host decides every crack and fall and tells every peer through the
## reliable `call_local` RPCs `_rpc_crack` / `_rpc_fall`; each peer removes the tile's
## collider itself when told, so tile collisions match everywhere. Knock-outs go through
## Player.eliminate (host), which reaches every peer by itself.
##
## Tiles are numbered in a fixed axial order over MAX_RINGS rings (identical on every peer);
## `_setup` removes the rings the player count does not need (see rings_for).
##
## Spawns: the `Spawns` markers (tile centres, not an even ring) only place the players
## at load. In `_setup` the host picks a random turn and sends it with the round order
## (`_rpc_spawn_layout`); every peer then places the N players evenly around a circle of
## SPAWN_RADIUS (`spawn_layout`), each facing the centre, so no seat starts beside another
## pair's face-off (balance: 3 players' slot 2 won 46 % with the markers).

## Every peer, when a tile starts cracking / falls (its collider is gone by then).
signal tile_cracked(index: int)
signal tile_fell(index: int)
## Every peer, once the host's spawn layout is applied: the turn (radians) and the slots in
## layout order.
signal spawn_layout_applied(turn: float, slots: PackedInt32Array)

enum TileState { SOLID, CRACKING, FALLEN }

const TILE_SCENE: PackedScene = preload("res://assets/models/props/hex_tile.glb")
const TILE_CRACKED_SCENE: PackedScene = preload("res://assets/models/props/hex_tile_cracked.glb")
const ROCK_SCENES: Array[PackedScene] = [
	preload("res://assets/models/props/lava_rock_a.glb"),
	preload("res://assets/models/props/lava_rock_b.glb"),
	preload("res://assets/models/props/lava_rock_c.glb"),
]
const STALAGMITE_SCENE: PackedScene = preload("res://assets/models/props/cave_stalagmite.glb")
const WALL_SCENE: PackedScene = preload("res://assets/models/props/cave_wall_chunk.glb")

## Rings around the centre tile in the full field (8 players).
const MAX_RINGS := 5
## Tile circumradius (flat-top hexagon), metres.
const TILE_RADIUS := 1.0
## Centre spacing factor: > 1 leaves a thin dark seam between tiles so each reads alone.
const SPACING := 1.06
const TILE_THICKNESS := 0.4
## Lava surface height (tile tops are at y = 0).
const LAVA_Y := -1.5
const SQRT3 := 1.7320508
## A grounded player whose centre is over a hole still cracks a solid neighbour holding
## them up: its hex, grown by the capsule radius (hex metric, see `_hex_metric`).
const SUPPORT_REACH := SQRT3 * 0.5 * TILE_RADIUS + 0.4
## Radius (m) of the spawn circle: about the third ring of tiles (the markers sit at 4.9-5.5).
const SPAWN_RADIUS := 5.2
## Seconds a falling tile keeps sinking (it passes under the lava surface) before it is freed.
const FALL_TIME := 1.4
const AXIAL_DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1),
]

@export_group("Rules")
## Seconds a grounded player must stay on one tile before it cracks. Running across tiles
## never cracks them; standing still is fatal in about touch_time + crack_delay + 0.3 s.
@export var touch_time: float = 1.0
## Seconds from "cracking" to "falls".
@export var crack_delay: float = 0.7
## Seconds after GO before tiles react to players.
@export var grace_time: float = 1.5
## Seconds after GO when untouched tiles start collapsing by themselves.
@export var collapse_start: float = 20.0
## Tiles per second at `collapse_start`...
@export var collapse_rate: float = 0.8
## ...plus this many tiles per second for every second after it.
@export var collapse_accel: float = 0.5
## A player whose origin (feet) drops below this height is in the lava.
@export var knockout_y: float = -1.2
## Host RNG seed (collapse order, bot goals); 0 = random.
@export var rng_seed: int = 0

@export_group("Bots")
## Hex distance range (tiles) of a bot's goal from its current tile.
@export var bot_goal_min: int = 2
@export var bot_goal_max: int = 4
## `is_safe` is false this close (m) to a hole or the rim, so bots keep off the edges.
@export var bot_edge_margin: float = 0.3

## Rings in play this round (set in `_setup` from the player count).
var rings: int = MAX_RINGS
## Seconds since GO (host only).
var elapsed: float = 0.0

var _axial: Array[Vector2i] = []
var _index: Dictionary[Vector2i, int] = {}
var _state: PackedInt32Array = PackedInt32Array()
var _bodies: Array[StaticBody3D] = []
var _shapes: Array[CollisionShape3D] = []
var _visuals: Array[Node3D] = []
var _solid_models: Array[Node3D] = []
var _cracked_models: Array[Node3D] = []
## Seconds since this tile cracked / fell (every peer; drives the animation).
var _anim_time: PackedFloat32Array = PackedFloat32Array()
var _fall_speed: PackedFloat32Array = PackedFloat32Array()
var _animating: Array[int] = []
## Host: `elapsed` when the tile cracked.
var _cracked_at: PackedFloat32Array = PackedFloat32Array()
## Host: slot -> [tile index, seconds on it without leaving].
var _stay: Dictionary = {}
var _collapse_budget: float = 0.0
var _rng := RandomNumberGenerator.new()
var _toon_cache: Dictionary = {}
var _tile_shape: ConvexPolygonShape3D = null
var _camera_timer: float = 0.0

@onready var _tiles_root: Node3D = $Tiles
@onready var _decor_root: Node3D = $Decor
@onready var _camera: ArenaCamera = $ArenaCamera


func _ready() -> void:
	_calm_lava()
	_build_tiles()


# --- Minigame flow --------------------------------------------------------------------------

func _setup(round_players: Array[Player]) -> void:
	rings = rings_for(round_players.size())
	for i in _axial.size():
		if _ring(i) > rings:
			_remove_tile(i)
	_build_decor()
	for p in round_players:
		p.eliminated.connect(_on_player_eliminated.bind(p))
	if multiplayer.is_server():
		var slots := PackedInt32Array()
		for p in round_players:
			slots.append(p.slot)
		_rpc_spawn_layout.rpc(randf() * TAU, slots)
	_frame_camera(true)


func _start() -> void:
	elapsed = 0.0
	_collapse_budget = -1.0
	_rng.seed = rng_seed if rng_seed != 0 else randi()
	RoundUI.push_banner("Keep moving!", 2.0)


func _host_tick(delta: float) -> void:
	if is_finished():
		return
	elapsed += delta
	# Same-tick falls go out lowest first, so the highest of them places best (never by slot).
	var fallers: Array[Player] = []
	for p in players:
		if is_instance_valid(p) and p.alive and to_local(p.global_position).y < knockout_y:
			fallers.append(p)
	fallers.sort_custom(func(a: Player, b: Player) -> bool: return a.global_position.y < b.global_position.y)
	for p in fallers:
		knock_out(p, &"lava")  # the reason makes the effects splash
	if is_finished():
		return
	# Time is up: under Session its backstop ends the round and ranks survivors equally;
	# alone (tests, sandbox) the round ends here.
	if time_limit > 0.0 and elapsed >= time_limit and not _session_drives():
		_finish_on_time()
		return

	var to_fall := PackedInt32Array()
	for i in _axial.size():
		if _state[i] == TileState.CRACKING and elapsed - _cracked_at[i] >= crack_delay:
			to_fall.append(i)
	var to_crack := PackedInt32Array()
	if elapsed >= grace_time:
		for p in players:
			if not is_instance_valid(p) or not p.alive or not _is_grounded(p):
				continue
			var i := _contact_tile(to_local(p.global_position))
			if i < 0:
				continue
			# Only an unbroken stay counts: stepping onto another tile starts over. Time in
			# the air neither counts nor resets (hopping in place does not save you).
			var stay: Array = _stay.get(p.slot, [-1, 0.0])
			stay = [i, (float(stay[1]) + delta) if stay[0] == i else delta]
			_stay[p.slot] = stay
			if float(stay[1]) >= touch_time - 0.0001 and not to_crack.has(i):
				to_crack.append(i)
	if elapsed >= collapse_start:
		if _collapse_budget < 0.0:
			_collapse_budget = 1.0  # the first tile goes right at collapse_start
		_collapse_budget += (collapse_rate + collapse_accel * (elapsed - collapse_start)) * delta
		while _collapse_budget >= 1.0:
			_collapse_budget -= 1.0
			var pick := _pick_collapse_tile(to_crack)
			if pick < 0:
				break
			to_crack.append(pick)
	if not to_fall.is_empty():
		_rpc_fall.rpc(to_fall)
	if not to_crack.is_empty():
		for i in to_crack:
			_cracked_at[i] = elapsed
		_rpc_crack.rpc(to_crack)


# --- Host -> every peer ---------------------------------------------------------------------

## The host's spawn layout: `slots[i]` goes to point i of `spawn_layout(slots.size(), turn)`.
## Sent from `_setup` (players are frozen until the countdown ends), so it lands before play.
@rpc("authority", "call_local", "reliable")
func _rpc_spawn_layout(turn: float, slots: PackedInt32Array) -> void:
	var points := spawn_layout(slots.size(), turn)
	for i in slots.size():
		for p in players:
			if is_instance_valid(p) and p.slot == slots[i]:
				p.place_at(global_transform * points[i])
	spawn_layout_applied.emit(turn, slots)


@rpc("authority", "call_local", "reliable")
func _rpc_crack(ids: PackedInt32Array) -> void:
	for i in ids:
		if i < 0 or i >= _axial.size() or _state[i] != TileState.SOLID:
			continue
		_state[i] = TileState.CRACKING
		_anim_time[i] = 0.0
		if _solid_models[i]:
			_solid_models[i].visible = false
		if _cracked_models[i]:
			_cracked_models[i].visible = true
		if not _animating.has(i):
			_animating.append(i)
		var at := get_tile_position(i)
		Fx.play(&"dust_puff", at + Vector3.UP * 0.05, Color(0.55, 0.45, 0.4))
		Sfx.play(&"platform_crack", at)
		tile_cracked.emit(i)


@rpc("authority", "call_local", "reliable")
func _rpc_fall(ids: PackedInt32Array) -> void:
	for i in ids:
		if i < 0 or i >= _axial.size() or _state[i] == TileState.FALLEN:
			continue
		_state[i] = TileState.FALLEN
		_disable_collider(i)
		_anim_time[i] = 0.0
		_fall_speed[i] = 0.0
		if not _animating.has(i):
			_animating.append(i)
		Sfx.play(&"platform_fall", get_tile_position(i))
		tile_fell.emit(i)


# --- Public queries -------------------------------------------------------------------------

## Rounds with fewer players than this play without the outer ring. Balance pass
## (docs/balance.md): the smaller fields (2 players 3 rings, 3-4 players 4) ended 2-player
## rounds in ~13 s and 4-player rounds in ~27 s, mostly by shoves off the rim; on the full
## field the late collapse sets the pace (2 players ~25 s, 3-4 players ~30-36 s, like 8).
const FULL_FIELD_PLAYERS := 2


## Rings of tiles for `count` players.
static func rings_for(count: int) -> int:
	if count < FULL_FIELD_PLAYERS:
		return MAX_RINGS - 1
	return MAX_RINGS


## Spawn points (local to the minigame) for `count` players: evenly around a circle of
## SPAWN_RADIUS, point i at angle `turn + TAU * i / count` from +Z, each facing the centre.
static func spawn_layout(count: int, turn: float) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in count:
		var a := turn + TAU * i / count
		out.append(Transform3D(Basis(Vector3.UP, a + PI), Vector3(sin(a), 0.0, cos(a)) * SPAWN_RADIUS))
	return out


## Number of tile slots (every ring up to MAX_RINGS, including removed ones).
func tile_count() -> int:
	return _axial.size()


## Index of the tile whose area contains `global_pos` (horizontal only), -1 off the grid.
## The tile may have fallen: check `get_tile_state`.
func tile_at(global_pos: Vector3) -> int:
	return _index.get(_axial_round(to_local(global_pos)), -1)


## A TileState value.
func get_tile_state(index: int) -> int:
	return _state[index]


## Top centre of tile `index`, global.
func get_tile_position(index: int) -> Vector3:
	return to_global(_tile_local(_axial[index]))


## True while tile `index` still collides (SOLID or CRACKING).
func tile_has_collider(index: int) -> bool:
	var body := _bodies[index]
	var shape := _shapes[index]
	return body != null and is_instance_valid(body) and body.is_inside_tree() \
			and body.collision_layer != 0 and shape != null and not shape.disabled


## Indices of the tiles still SOLID.
func solid_tiles() -> Array[int]:
	var out: Array[int] = []
	for i in _axial.size():
		if _state[i] == TileState.SOLID:
			out.append(i)
	return out


## Bots: only over a solid (not cracking) tile, and not within `bot_edge_margin` of a
## hole or the rim.
func is_safe(pos: Vector3) -> bool:
	var local := to_local(pos)
	var a := _axial_round(local)
	var i: int = _index.get(a, -1)
	if i < 0 or _state[i] != TileState.SOLID:
		return false
	if bot_edge_margin <= 0.0:
		return true
	var off := local - _tile_local(a)
	var flat := Vector2(off.x, off.z)
	var inradius := SQRT3 * 0.5 * TILE_RADIUS * SPACING
	for dir in AXIAL_DIRS:
		var j: int = _index.get(a + dir, -1)
		if j >= 0 and _state[j] == TileState.SOLID:
			continue
		var c := _tile_local(dir)
		var n := Vector2(c.x, c.z).normalized()
		if inradius - flat.dot(n) < bot_edge_margin:
			return false
	return true


## Bots: a solid tile a few tiles away, preferring well-supported ones away from others.
## Random each call, so bots keep moving.
func get_bot_goal(player: Player) -> Vector3:
	if player == null:
		return global_position
	var here := _axial_round(to_local(player.global_position))
	var best := -1
	var best_score := -INF
	var fallback := -1
	var fallback_d := 1 << 30
	for i in _axial.size():
		if _state[i] != TileState.SOLID:
			continue
		var d := _hex_distance(here, _axial[i])
		if d > 0 and d < fallback_d:
			fallback_d = d
			fallback = i
		if d < bot_goal_min or d > bot_goal_max:
			continue
		var score := float(_solid_neighbours(i)) + _rng.randf() * 3.0 - 0.2 * _ring(i)
		var at := get_tile_position(i)
		for other in players:
			if other != player and is_instance_valid(other) and other.alive \
					and Vector2(other.global_position.x - at.x, other.global_position.z - at.z).length() < 2.0:
				score -= 1.5
		if score > best_score:
			best_score = score
			best = i
	if best < 0:
		best = fallback
	return get_tile_position(best) if best >= 0 else player.global_position


# --- Host rules -----------------------------------------------------------------------------

func _is_grounded(p: Player) -> bool:
	if absf(to_local(p.global_position).y) > 0.35:
		return false
	if p.is_authority():
		return p.is_on_floor()
	var sync := p.get_component(&"sync") as SyncComponent
	return sync != null and sync.is_grounded()


## The SOLID tile a grounded player at `local` cracks, or -1: the tile under the centre;
## when that one is already gone, the solid neighbour whose edge is holding them up.
func _contact_tile(local: Vector3) -> int:
	var a := _axial_round(local)
	var i: int = _index.get(a, -1)
	if i >= 0 and _state[i] == TileState.SOLID:
		return i
	if i >= 0 and _state[i] == TileState.CRACKING:
		return -1
	var best := -1
	var best_m := SUPPORT_REACH
	for dir in AXIAL_DIRS:
		var n: int = _index.get(a + dir, -1)
		if n < 0 or _state[n] != TileState.SOLID:
			continue
		var c := _tile_local(_axial[n])
		var m := _hex_metric(local.x - c.x, local.z - c.z)
		if m <= best_m:
			best_m = m
			best = n
	return best


## An untouched tile for the late-game collapse: outer rings first, a little shuffled.
func _pick_collapse_tile(exclude: PackedInt32Array) -> int:
	var best := -1
	var best_score := -INF
	for i in _axial.size():
		if _state[i] != TileState.SOLID or exclude.has(i):
			continue
		var score := float(_ring(i)) + _rng.randf() * 1.3
		if score > best_score:
			best_score = score
			best = i
	return best


func _session_drives() -> bool:
	return Session.current_minigame == self and Session.state == Session.State.PLAYING


## Time is up without a Session (tests, sandbox): survivors by slot first. Under Session its
## backstop finishes instead, with the survivors sharing first place.
func _finish_on_time() -> void:
	var alive_slots: Array[int] = []
	for p in players:
		if is_instance_valid(p) and p.alive:
			alive_slots.append(p.slot)
	alive_slots.sort()
	finish(_ranking_with(alive_slots))


func _ranking_with(top: Array[int]) -> Array[int]:
	var ranking: Array[int] = top.duplicate()
	for k in range(knocked_out.size() - 1, -1, -1):
		if not ranking.has(knocked_out[k]):
			ranking.append(knocked_out[k])
	return ranking


# --- Presentation (every peer) --------------------------------------------------------------

func _on_player_eliminated(reason: StringName, p: Player) -> void:
	if not String(reason).contains("lava"):
		return
	var at := p.global_position
	Sfx.play(&"lava_sizzle", Vector3(at.x, global_position.y + LAVA_Y, at.z))
	if _camera:
		_camera.add_shake(0.3)


func _process(delta: float) -> void:
	_animate_tiles(delta)
	_camera_timer -= delta
	if _camera_timer <= 0.0:
		_camera_timer = 0.5
		_frame_camera(false)


func _animate_tiles(delta: float) -> void:
	var done: Array[int] = []
	for i in _animating:
		_anim_time[i] += delta
		var t := _anim_time[i]
		var visual := _visuals[i]
		if visual == null or not is_instance_valid(visual):
			done.append(i)
			continue
		if _state[i] == TileState.CRACKING:
			# Wobble that grows toward the fall.
			var k := clampf(t / maxf(crack_delay, 0.01), 0.0, 1.0)
			var amp := 0.02 + 0.07 * k
			var ph := float(i) * 1.7
			visual.rotation = Vector3(sin(t * 31.0 + ph) * amp, 0.0, cos(t * 27.0 + ph) * amp)
			visual.position = Vector3(0.0, -0.04 * k + sin(t * 43.0 + ph) * 0.015, 0.0)
		elif _state[i] == TileState.FALLEN:
			_fall_speed[i] += 14.0 * delta
			visual.position.y -= _fall_speed[i] * delta
			visual.rotation.x += delta * 0.6
			visual.rotation.z += delta * 0.35 * (1.0 if i % 2 == 0 else -1.0)
			# Sinks through the lava surface (which hides it) while shrinking a little.
			visual.scale = Vector3.ONE * lerpf(1.0, 0.6, clampf(t / FALL_TIME, 0.0, 1.0))
			if t >= FALL_TIME:
				done.append(i)
				_free_tile(i)
	for i in done:
		_animating.erase(i)


## Points the fixed camera at the solid tiles plus the living players.
func _frame_camera(snap: bool) -> void:
	if _camera == null or not is_inside_tree():
		return
	var points: Array[Vector3] = []
	for i in _axial.size():
		if _state[i] != TileState.FALLEN and _ring(i) <= rings:
			points.append(get_tile_position(i))
	for p in players:
		if is_instance_valid(p) and p.alive and p.global_position.y > knockout_y:
			points.append(p.global_position + Vector3.UP * 0.5)
	if points.is_empty():
		return
	var size := get_viewport().get_visible_rect().size
	var aspect := size.x / size.y if size.y > 0.0 else 16.0 / 9.0
	var framed := ArenaCamera.frame_points(points, _camera.view_basis(), tan(deg_to_rad(_camera.fov) * 0.5), aspect, 1.6)
	_camera.fixed_focus = framed[0]
	_camera.fixed_distance = clampf(framed[1], _camera.min_distance, _camera.max_distance)
	if snap:
		_camera.snap()


# --- Tiles ----------------------------------------------------------------------------------

func _build_tiles() -> void:
	_tile_shape = _make_tile_shape()
	for q in range(-MAX_RINGS, MAX_RINGS + 1):
		for r in range(maxi(-MAX_RINGS, -q - MAX_RINGS), mini(MAX_RINGS, -q + MAX_RINGS) + 1):
			var a := Vector2i(q, r)
			var i := _axial.size()
			_axial.append(a)
			_index[a] = i
			_add_tile_nodes(i)
	var n := _axial.size()
	_state.resize(n)
	_state.fill(TileState.SOLID)
	_anim_time.resize(n)
	_fall_speed.resize(n)
	_cracked_at.resize(n)


func _add_tile_nodes(i: int) -> void:
	var body := StaticBody3D.new()
	body.name = "T%d" % i
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = _tile_local(_axial[i])
	var shape := CollisionShape3D.new()
	shape.shape = _tile_shape
	body.add_child(shape)
	var visual := Node3D.new()
	visual.name = "Visual"
	body.add_child(visual)
	# A little yaw variety: the hexagon is symmetric under 60 degree turns.
	var yaw := deg_to_rad(60.0 * (posmod(_axial[i].x * 7 + _axial[i].y * 3, 6)))
	var solid := TILE_SCENE.instantiate() as Node3D
	solid.rotation.y = yaw
	_toon(solid)
	visual.add_child(solid)
	var cracked := TILE_CRACKED_SCENE.instantiate() as Node3D
	cracked.rotation.y = yaw
	cracked.visible = false
	_toon(cracked, true)
	visual.add_child(cracked)
	_tiles_root.add_child(body)
	_bodies.append(body)
	_shapes.append(shape)
	_visuals.append(visual)
	_solid_models.append(solid)
	_cracked_models.append(cracked)


## Hexagonal prism, flat-top, top face at y = 0.
func _make_tile_shape() -> ConvexPolygonShape3D:
	var pts := PackedVector3Array()
	for k in 6:
		var ang := deg_to_rad(60.0 * k)
		var v := Vector3(cos(ang) * TILE_RADIUS, 0.0, sin(ang) * TILE_RADIUS)
		pts.append(v)
		pts.append(v + Vector3.DOWN * TILE_THICKNESS)
	var s := ConvexPolygonShape3D.new()
	s.points = pts
	return s


## Tile removed before play (outside this round's rings): gone at once, no animation.
func _remove_tile(i: int) -> void:
	_state[i] = TileState.FALLEN
	_disable_collider(i)
	_free_tile(i)


func _disable_collider(i: int) -> void:
	var body := _bodies[i]
	if body and is_instance_valid(body):
		body.collision_layer = 0
	var shape := _shapes[i]
	if shape and is_instance_valid(shape):
		shape.disabled = true


func _free_tile(i: int) -> void:
	var body := _bodies[i]
	if body and is_instance_valid(body):
		body.queue_free()
	_bodies[i] = null
	_shapes[i] = null
	_visuals[i] = null
	_solid_models[i] = null
	_cracked_models[i] = null


## Toon look with materials shared between all tiles (one duplicate per source material).
## `cracked`: darker, warmer stone and hotter glowing cracks, so a doomed tile reads at once.
func _toon(root: Node3D, cracked: bool = false) -> void:
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s)
			if src == null:
				continue
			var key: Array = [src, cracked]
			if not _toon_cache.has(key):
				var m := Look.toon_from(src)
				if cracked and m is StandardMaterial3D:
					var sm := (m as StandardMaterial3D).duplicate() as StandardMaterial3D
					if sm.emission_enabled:
						sm.emission_energy_multiplier *= 3.0
					else:
						sm.albedo_color = sm.albedo_color.darkened(0.3).lerp(Color(0.5, 0.16, 0.1), 0.3)
					m = sm
				_toon_cache[key] = m
			mi.set_surface_override_material(s, _toon_cache[key])


## Our own copy of the house lava, calmer: plates larger than a tile (so the lake never
## reads as more tiles) and a little less glow.
func _calm_lava() -> void:
	var lava := get_node_or_null(^"Lava") as MeshInstance3D
	if lava == null:
		return
	var m := lava.get_surface_override_material(0) as ShaderMaterial
	if m == null:
		return
	m = m.duplicate() as ShaderMaterial
	m.set_shader_parameter(&"cell_size", 3.6)
	m.set_shader_parameter(&"crust_amount", 0.55)
	m.set_shader_parameter(&"emission_strength", 1.2)
	lava.set_surface_override_material(0, m)


# --- Decor ----------------------------------------------------------------------------------

## Rocks in the lava around the rim, stalagmites further out, a broken cave wall behind.
## Deterministic (fixed seed per ring count), visual only, no collision.
func _build_decor() -> void:
	for c in _decor_root.get_children():
		c.queue_free()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 + rings
	var field_r := SQRT3 * rings * SPACING + TILE_RADIUS
	# Rocks just off the rim, at lava level (tops stay below the tiles).
	var placed := 0
	var tries := 0
	while placed < 10 + rings * 2 and tries < 400:
		tries += 1
		var ang := rng.randf() * TAU
		var d := rng.randf_range(field_r - 1.5, field_r + 3.5)
		var pos := Vector3(cos(ang) * d, LAVA_Y, sin(ang) * d)
		if _near_field(pos, 1.9):
			continue
		var s := rng.randf_range(0.8, 1.5)
		_place_decor(ROCK_SCENES[rng.randi() % ROCK_SCENES.size()], pos, rng.randf() * TAU, s)
		placed += 1
	# Stalagmites: beyond the rocks, not in front of the camera (which sits on +Z).
	placed = 0
	tries = 0
	while placed < 9 and tries < 400:
		tries += 1
		var ang := rng.randf() * TAU
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		if dir.z > 0.35:
			continue
		var d := rng.randf_range(field_r + 2.5, field_r + 7.0)
		var pos := dir * d + Vector3.UP * LAVA_Y
		if _near_field(pos, 3.0):
			continue
		_place_decor(STALAGMITE_SCENE, pos, rng.randf() * TAU, rng.randf_range(1.3, 2.4))
		placed += 1
	# Cave wall: a broken arc behind the field, facing the centre.
	var wall_r := field_r + 9.0
	for k in 11:
		var ang := deg_to_rad(-180.0 + 18.0 * k + rng.randf_range(-4.0, 4.0))
		var pos := Vector3(cos(ang) * wall_r, LAVA_Y - 0.3, sin(ang) * wall_r)
		var yaw := atan2(-pos.x, -pos.z)
		_place_decor(WALL_SCENE, pos, yaw, rng.randf_range(2.2, 2.9))


func _near_field(pos: Vector3, clearance: float) -> bool:
	for i in _axial.size():
		if _ring(i) > rings:
			continue
		var c := _tile_local(_axial[i])
		if Vector2(pos.x - c.x, pos.z - c.z).length() < clearance:
			return true
	return false


func _place_decor(scene: PackedScene, pos: Vector3, yaw: float, s: float) -> void:
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation.y = yaw
	n.scale = Vector3.ONE * s
	_toon(n)
	_decor_root.add_child(n)


# --- Hex maths ------------------------------------------------------------------------------

func _tile_local(a: Vector2i) -> Vector3:
	return Vector3(1.5 * a.x, 0.0, SQRT3 * (a.y + a.x * 0.5)) * SPACING * TILE_RADIUS


func _axial_round(local: Vector3) -> Vector2i:
	var x := local.x / (SPACING * TILE_RADIUS)
	var z := local.z / (SPACING * TILE_RADIUS)
	var qf := x / 1.5
	var rf := z / SQRT3 - qf * 0.5
	var sf := -qf - rf
	var q := roundf(qf)
	var r := roundf(rf)
	var s := roundf(sf)
	var dq := absf(q - qf)
	var dr := absf(r - rf)
	var ds := absf(s - sf)
	if dq > dr and dq > ds:
		q = -r - s
	elif dr > ds:
		r = -q - s
	return Vector2i(int(q), int(r))


static func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	var dq := a.x - b.x
	var dr := a.y - b.y
	return (absi(dq) + absi(dr) + absi(dq + dr)) / 2


func _ring(i: int) -> int:
	return _hex_distance(_axial[i], Vector2i.ZERO)


func _solid_neighbours(i: int) -> int:
	var n := 0
	for dir in AXIAL_DIRS:
		var j: int = _index.get(_axial[i] + dir, -1)
		if j >= 0 and _state[j] == TileState.SOLID:
			n += 1
	return n


## Distance-like measure from a flat-top hexagon's centre: <= inradius inside it.
static func _hex_metric(dx: float, dz: float) -> float:
	return maxf(absf(dz), (SQRT3 * absf(dx) + absf(dz)) * 0.5)
