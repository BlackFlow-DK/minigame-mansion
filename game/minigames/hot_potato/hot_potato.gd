class_name HotPotato
extends Minigame
## Hot Potato. One blob carries a lit bomb with a hidden fuse; touching another blob (or
## landing a shove on them) passes it. When it blows, the holder is out; after a short
## pause a random survivor gets the next bomb. Last blob standing wins. No time limit:
## the bombs end the round (fuses shrink with more players and as players drop out).
##
## Host decides everything: the holder, the fuse (known only to the host), passes and
## explosions. Every peer learns it through the reliable call_local RPCs below and only
## ever sees a coarse urgency level (0..3), never the fuse time. Presentation (the bomb
## rig, sounds, banners) and the holder's speed tuning run on every peer.
## Arena: the night courtyard, built in code in _ready (identical on every peer).
## Dev args (after `--`): `--potato-fuse=<s>` forces the first fuse (screenshots),
## `--potato-time-scale=<x>` speeds up fuses and pauses (network check).

## Every peer: a new bomb went to `slot`.
signal bomb_given(slot: int)
## Every peer: the bomb went from `from_slot` to `to_slot` (`kind`: PassKind).
signal bomb_passed(from_slot: int, to_slot: int, kind: int)
## Every peer: the bomb blew up on `slot`.
signal bomb_exploded(slot: int)
## Every peer: the coarse urgency level changed.
signal urgency_changed(level: int)

enum PassKind { TOUCH, SHOVE }

const BombRig := preload("res://minigames/hot_potato/bomb_rig.gd")
const PROPS := "res://assets/models/props/"

# --- Arena -------------------------------------------------------------------------------
## Centre line of the fence ring; its collider's inner face is at FENCE_RADIUS - 0.2.
const FENCE_RADIUS := 8.2
const FENCE_SEGMENTS := 26
## Blob centres can never get further out than this (fence inner face minus blob radius).
const PLAY_RADIUS := 7.6
## Bots treat everything inside this as safe (a margin inside PLAY_RADIUS).
const SAFE_RADIUS := 7.3
const LANTERN_RADIUS := 9.3
## Obstacles: [kind, angle deg (0 = +Z, toward +X), radius, tangent offset, height offset, yaw].
## Crates 0.9 m cubes, barrels 0.75 m tall; stacks you can hop up.
const OBSTACLES: Array = [
	["crate", 22.5, 3.0, -0.5, 0.0, 10.0], ["crate", 22.5, 3.0, 0.45, 0.0, -5.0], ["crate", 22.5, 3.0, -0.5, 0.9, 25.0],
	["barrel", 112.5, 3.0, -0.4, 0.0, 0.0], ["barrel", 112.5, 3.0, 0.4, 0.0, 40.0], ["barrel", 112.5, 3.4, 0.0, 0.0, 15.0],
	["crate", 202.5, 3.0, 0.5, 0.0, -12.0], ["crate", 202.5, 3.0, -0.45, 0.0, 8.0], ["crate", 202.5, 3.0, 0.5, 0.9, -30.0],
	["barrel", 292.5, 3.0, -0.45, 0.0, 0.0], ["crate", 292.5, 3.0, 0.5, 0.0, 20.0],
	["barrel", 67.5, 6.3, -0.35, 0.0, 0.0], ["barrel", 67.5, 6.3, 0.4, 0.0, 30.0],
	["crate", 157.5, 6.3, 0.0, 0.0, 35.0],
	["barrel", 247.5, 6.3, 0.0, 0.0, 0.0], ["barrel", 247.5, 6.6, 0.6, 0.0, 50.0],
	["crate", 337.5, 6.3, 0.0, 0.0, -20.0],
]

# --- Rules (host) -------------------------------------------------------------------------
## Fuse seconds for 4 players with everyone alive; scaled up for 2-3 players, down for
## crowds and as players drop out (see fuse_range_for).
@export var fuse_range: Vector2 = Vector2(9.0, 16.0)
@export var min_fuse: float = 3.5
## Holder and victim centres closer than this (m, flat) = a touch (blobs touch at 0.8).
@export var touch_distance: float = 1.0
## The new holder cannot pass straight back to the giver for this long.
@export var pass_back_block: float = 0.8
## Seconds a new bomb cannot be passed at all.
@export var new_bomb_grace: float = 1.0
## Seconds between an explosion and the next bomb.
@export var explosion_pause: float = 2.0
## The new holder is slowed for this long after a pass, to this fraction of its speed.
@export var gotcha_slow_time: float = 0.3
@export var gotcha_slow_factor: float = 0.4
## The holder runs this much faster than everyone else.
@export var holder_speed_bonus: float = 1.12
## Explosion push on nearby blobs (harmless, just fun).
@export var blast_radius: float = 3.5
@export var blast_force: float = 9.0
@export var blast_lift: float = 4.0
## Largest fuse scale for small rounds (2 players: 4.5 / 2.5 = 1.8).
const SMALL_ROUND_FUSE_SCALE := 1.8
## Fraction of the fuse burnt at which the urgency level steps up (level = steps passed).
const URGENCY_STEPS: Array[float] = [0.45, 0.72, 0.9]

## Test/dev only: multiplies how fast fuses, grace and pauses run on the host.
var time_scale: float = 1.0
## Host randomness (holders, fuses). Tests may seed it.
var rng := RandomNumberGenerator.new()

## Every peer: slot holding the bomb, -1 while none (pause between bombs).
var holder_slot: int = -1
## Every peer: coarse urgency 0..3 of the current bomb.
var urgency: int = 0
## Every peer: passes so far this round.
var pass_count: int = 0

# Host state.
var _fuse_total: float = 0.0
var _fuse_left: float = 0.0
var _grace_left: float = 0.0
var _pause_left: float = 0.0
var _blocked_slot: int = -1
var _block_left: float = 0.0
var _forced_fuse: float = -1.0

# Every peer.
var _base_speed: Dictionary[int, float] = {}
var _slow_slot: int = -1
var _slow_left: float = 0.0
var _rig: BombRig = null
var _obstacle_spots: Array[Vector3] = []
var _rethink_frame: int = -1
var _rethink_slot: int = -2
## Every obstacle piece's base position (tests, bots).
var obstacle_positions: Array[Vector3] = []

@onready var _camera: ArenaCamera = get_node_or_null(^"ArenaCamera") as ArenaCamera


func _ready() -> void:
	rng.randomize()
	_build_arena()
	_rig = BombRig.new()
	_rig.name = "BombRig"
	add_child(_rig)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--potato-fuse="):
			_forced_fuse = arg.trim_prefix("--potato-fuse=").to_float()
		elif arg.begins_with("--potato-time-scale="):
			time_scale = maxf(arg.trim_prefix("--potato-time-scale=").to_float(), 0.01)


func _setup(p_players: Array[Player]) -> void:
	_base_speed.clear()
	for p in p_players:
		var move := p.get_component(&"movement") as MovementComponent
		if move:
			_base_speed[p.slot] = move.max_speed
		if not p.shove_hit.is_connected(_on_shove_hit):
			p.shove_hit.connect(_on_shove_hit.bind(p))


# --- Host --------------------------------------------------------------------------------------

func _host_tick(delta: float) -> void:
	if is_finished():
		return
	var dt := delta * time_scale
	if holder_slot < 0:
		_pause_left -= dt
		if _pause_left <= 0.0:
			_new_bomb()
		return
	var h := _player(holder_slot)
	if h == null or not h.alive:
		# The holder left the game (knocked out by Stage): the bomb fizzles.
		_rpc_drop.rpc()
		_pause_left = explosion_pause * 0.5
		return
	_fuse_left -= dt
	_grace_left -= dt
	_block_left -= dt
	var level := urgency_for(1.0 - _fuse_left / maxf(_fuse_total, 0.001))
	if level != urgency:
		_rpc_urgency.rpc(level)
	if _fuse_left <= 0.0:
		_explode(h)
		return
	if _grace_left <= 0.0:
		var victim := _touching(h)
		if victim:
			_pass(h, victim, PassKind.TOUCH)


## Host. Hands a new bomb to `slot`. `fuse` < 0 rolls one; `grace` < 0 uses new_bomb_grace.
func give_bomb(slot: int, fuse: float = -1.0, grace: float = -1.0) -> void:
	var p := _player(slot)
	if p == null or not p.alive or is_finished():
		return
	_fuse_total = fuse if fuse > 0.0 else roll_fuse(_alive().size())
	_fuse_left = _fuse_total
	_grace_left = grace if grace >= 0.0 else new_bomb_grace
	_blocked_slot = -1
	_block_left = 0.0
	_rpc_bomb.rpc(slot, -1, -1, 0)


## Host. Seconds left on the current fuse (tests; never sent to clients).
func fuse_left() -> float:
	return _fuse_left


## Fuse min/max for a bomb when `alive_count` of this round's players are alive.
func fuse_range_for(alive_count: int) -> Vector2:
	var n := players.size()
	# Balance pass: the cap was 1.0, so a 2-player round was one 9-16 s fuse (~12.5 s) and a
	# 3-player round ~24 s; up to SMALL_ROUND_FUSE_SCALE they last ~22 s and ~30 s.
	var crowd := clampf(4.5 / (n + 0.5), 0.5, SMALL_ROUND_FUSE_SCALE)
	var t := 1.0 if n <= 2 else clampf(float(alive_count - 2) / float(n - 2), 0.0, 1.0)
	var f := crowd * lerpf(0.75, 1.0, t)
	return Vector2(maxf(fuse_range.x * f, min_fuse), maxf(fuse_range.y * f, min_fuse + 1.0))


func roll_fuse(alive_count: int) -> float:
	var r := fuse_range_for(alive_count)
	return rng.randf_range(r.x, r.y)


## Urgency level (0..3) for a fuse `burnt` fraction.
static func urgency_for(burnt: float) -> int:
	var level := 0
	for step in URGENCY_STEPS:
		if burnt >= step:
			level += 1
	return level


func _new_bomb() -> void:
	var alive := _alive()
	if alive.size() <= 1:
		# Nobody left to pass to (e.g. the others left the game): the round is decided.
		var ranking: Array[int] = []
		for q in alive:
			ranking.append(q.slot)
		for k in range(knocked_out.size() - 1, -1, -1):
			if not ranking.has(knocked_out[k]):
				ranking.append(knocked_out[k])
		finish(ranking)
		return
	var p := alive[rng.randi() % alive.size()]
	var fuse := -1.0
	if _forced_fuse > 0.0:
		fuse = _forced_fuse
		_forced_fuse = -1.0
	give_bomb(p.slot, fuse)


func _touching(h: Player) -> Player:
	var best: Player = null
	var best_d := touch_distance
	for p in players:
		if p == h or not is_instance_valid(p) or not p.alive:
			continue
		if p.slot == _blocked_slot and _block_left > 0.0:
			continue
		var to := p.global_position - h.global_position
		if absf(to.y) > 1.0:
			continue
		var d := Vector2(to.x, to.z).length()
		if d < best_d:
			best_d = d
			best = p
	return best


func _on_shove_hit(victim_slot: int, shover: Player) -> void:
	if not Net.is_host() or is_finished() or holder_slot < 0 or shover.slot != holder_slot:
		return
	if _grace_left > 0.0 or (victim_slot == _blocked_slot and _block_left > 0.0):
		return
	var victim := _player(victim_slot)
	if victim and victim.alive and shover.alive:
		_pass(shover, victim, PassKind.SHOVE)


func _pass(from: Player, to: Player, kind: int) -> void:
	_blocked_slot = from.slot
	_block_left = pass_back_block
	_rpc_bomb.rpc(to.slot, from.slot, kind, urgency)


func _explode(h: Player) -> void:
	var at := h.global_position
	_rpc_explode.rpc(h.slot, at)
	for p in players:
		if p == h or not is_instance_valid(p) or not p.alive:
			continue
		var to := p.global_position - at
		to.y = 0.0
		var d := to.length()
		if d >= blast_radius:
			continue
		var dir := to / d if d > 0.01 else Vector3.RIGHT.rotated(Vector3.UP, rng.randf() * TAU)
		var k := 1.0 - 0.6 * d / blast_radius
		p.apply_impulse(dir * blast_force * k + Vector3.UP * blast_lift * k)
	knock_out(h, &"bomb")
	if not is_finished():
		_pause_left = explosion_pause


## Asks bots to re-plan. A repeat request in the same physics frame (a hand-over announced
## twice, e.g. by a listener on bomb_passed) is dropped, so each bot re-plans once per event.
func request_bot_rethink(slot: int = -1) -> void:
	var frame := Engine.get_physics_frames()
	if frame == _rethink_frame and (_rethink_slot == -1 or _rethink_slot == slot):
		return
	_rethink_frame = frame
	_rethink_slot = slot
	super(slot)


# --- RPCs (host -> every peer) -----------------------------------------------------------------

## A bomb changes hands: `from_slot` -1 = a new bomb; `kind` a PassKind (or -1).
@rpc("authority", "call_local", "reliable")
func _rpc_bomb(slot: int, from_slot: int, kind: int, level: int) -> void:
	var previous := _player(holder_slot)
	holder_slot = slot
	urgency = level
	var p := _player(slot)
	request_bot_rethink()  # bots re-plan at once: the new holder chases, the rest flee
	_set_holder_face(previous, p)
	if _rig:
		_rig.show_on(p, level)
	if p == null:
		return
	var name_text := "%s has the bomb!" % _name_of(p)
	if from_slot < 0:
		_slow_slot = -1
		RoundUI.push_banner(name_text, 2.0)
		bomb_given.emit(slot)
		return
	_slow_slot = slot
	_slow_left = gotcha_slow_time
	var giver := _player(from_slot)
	var contact := p.global_position + Vector3.UP * 0.7
	if giver:
		contact = (p.global_position + giver.global_position) * 0.5 + Vector3.UP * 0.7
	Fx.play(&"hit_stars", contact, Color(1.0, 0.6, 0.2))
	if kind == PassKind.TOUCH:
		Sfx.play(&"hit_bonk", contact)
	if pass_count == 0:
		RoundUI.push_banner(name_text, 1.2)
	pass_count += 1
	bomb_passed.emit(from_slot, slot, kind)


@rpc("authority", "call_local", "reliable")
func _rpc_urgency(level: int) -> void:
	urgency = level
	if _rig:
		_rig.set_level(level)
	urgency_changed.emit(level)


@rpc("authority", "call_local", "reliable")
func _rpc_explode(slot: int, at: Vector3) -> void:
	_set_holder_face(_player(slot), null)
	holder_slot = -1
	_slow_slot = -1
	if _rig:
		_rig.hide_bomb()
	Fx.play(&"explosion", at + Vector3.UP * 0.6)
	Sfx.play(&"explosion", at)
	if _camera:
		_camera.add_shake(0.75)
	bomb_exploded.emit(slot)


## The holder left the game: the bomb just goes away.
@rpc("authority", "call_local", "reliable")
func _rpc_drop() -> void:
	_set_holder_face(_player(holder_slot), null)
	holder_slot = -1
	_slow_slot = -1
	if _rig:
		_rig.hide_bomb()


# --- Every peer ------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _slow_left > 0.0:
		_slow_left -= delta
		if _slow_left <= 0.0:
			_slow_slot = -1
	# Tuning on every peer (only the authority's copy matters): the holder runs faster,
	# a freshly tagged holder is briefly slowed.
	for p in players:
		if not is_instance_valid(p) or not _base_speed.has(p.slot):
			continue
		var move := p.get_component(&"movement") as MovementComponent
		if move == null:
			continue
		var s := _base_speed[p.slot]
		if p.slot == holder_slot:
			s *= holder_speed_bonus
			if p.slot == _slow_slot:
				s *= gotcha_slow_factor
		move.max_speed = s


func _set_holder_face(old: Player, new: Player) -> void:
	if old and is_instance_valid(old) and old != new:
		var v := old.get_component(&"visuals") as VisualsComponent
		if v:
			v.set_expression(&"")
	for p in players:
		if not is_instance_valid(p):
			continue
		var v := p.get_component(&"visuals") as VisualsComponent
		if v == null:
			continue
		if p == new:
			v.set_expression(BlobExpressions.HURT)
			v.set_look_target(null)
		elif new and _rig:
			v.set_look_target(new)
		else:
			v.set_look_target(null)


# --- Bots ----------------------------------------------------------------------------------------

## Holder: chase the nearest other blob (not the one it just got the bomb from, if anyone
## else is left). Everyone else: the spot furthest from the holder, preferring cover behind
## obstacles and avoiding routes past the holder.
func get_bot_goal(player: Player) -> Vector3:
	var h := _player(holder_slot)
	if h == null or not h.alive or not player.alive:
		return super.get_bot_goal(player)
	if player == h:
		return _chase_goal(player)
	return _flee_goal(player, h.global_position)


func is_safe(pos: Vector3) -> bool:
	return Vector2(pos.x, pos.z).length() < SAFE_RADIUS


func _chase_goal(me: Player) -> Vector3:
	var best: Player = null
	var best_d := INF
	for p in _alive():
		if p == me:
			continue
		var d := p.global_position.distance_to(me.global_position)
		if p.slot == _blocked_slot and _block_left > 0.0:
			d += 100.0
		if d < best_d:
			best_d = d
			best = p
	if best == null:
		return me.global_position
	var aim := best.global_position + best.velocity * 0.3
	var to := aim - me.global_position
	to.y = 0.0
	if to.length() > 0.01:
		aim += to.normalized() * 0.9  # run through them, not up to them
	return _clamp_safe(aim)


func _flee_goal(me: Player, holder_pos: Vector3) -> Vector3:
	var candidates: Array[Vector3] = []
	var cover: Array[bool] = []
	for i in 12:
		var a := TAU * i / 12.0
		candidates.append(Vector3(sin(a), 0.0, cos(a)) * (SAFE_RADIUS - 1.0))
		cover.append(false)
	for c in _obstacle_spots:
		var away := c - holder_pos
		away.y = 0.0
		if away.length() < 0.1:
			continue
		candidates.append(_clamp_safe(c + away.normalized() * 1.5))
		cover.append(true)
	var best := me.global_position
	var best_score := -INF
	var mine := Vector2(me.global_position.x, me.global_position.z)
	var hp := Vector2(holder_pos.x, holder_pos.z)
	for i in candidates.size():
		var c2 := Vector2(candidates[i].x, candidates[i].z)
		var score := c2.distance_to(hp) - 0.35 * c2.distance_to(mine)
		if cover[i]:
			score += 1.0
		# Do not run past the holder to get there.
		var seg := Geometry2D.get_closest_point_to_segment(hp, mine, c2)
		if seg.distance_to(hp) < 2.0 and c2.distance_to(mine) > 1.0:
			score -= 5.0
		if score > best_score:
			best_score = score
			best = candidates[i]
	return best


func _clamp_safe(p: Vector3) -> Vector3:
	var flat := Vector2(p.x, p.z).limit_length(SAFE_RADIUS - 0.5)
	return Vector3(flat.x, 0.0, flat.y)


# --- Helpers -----------------------------------------------------------------------------------

func _player(slot: int) -> Player:
	if slot < 0:
		return null
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _alive() -> Array[Player]:
	var out: Array[Player] = []
	for p in players:
		if is_instance_valid(p) and p.alive:
			out.append(p)
	return out


func _name_of(p: Player) -> String:
	return p.display_name if p.display_name != "" else "Player %d" % (p.slot + 1)


# --- Arena ---------------------------------------------------------------------------------------

func _build_arena() -> void:
	var arena := Node3D.new()
	arena.name = "Arena"
	add_child(arena)

	# Dark lawn beyond the courtyard so the camera never sees the sky below the horizon.
	var lawn := MeshInstance3D.new()
	lawn.name = "Lawn"
	var plane := PlaneMesh.new()
	plane.size = Vector2(80.0, 80.0)
	lawn.mesh = plane
	lawn.material_override = Look.toon_material(Color("#1f2a2a"), 0.9, false)
	lawn.position.y = -0.06
	arena.add_child(lawn)

	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 10.0
	cyl.height = 1.0
	floor_shape.shape = cyl
	floor_shape.position.y = -0.5
	floor_body.add_child(floor_shape)
	arena.add_child(floor_body)
	_place(arena, "arena_floor_disc", Vector3.ZERO, 0.0)

	# Fence: a ring of 2 m segments; the collider is a 3 m tall wall so nobody hops out.
	var fence := StaticBody3D.new()
	fence.name = "Fence"
	fence.collision_mask = 0
	arena.add_child(fence)
	var wall := BoxShape3D.new()
	wall.size = Vector3(2.05, 3.0, 0.4)
	for i in FENCE_SEGMENTS:
		var a := TAU * i / FENCE_SEGMENTS
		var pos := Vector3(sin(a), 0.0, cos(a)) * FENCE_RADIUS
		_place(arena, "fence_segment_2m", pos, a)  # yaw a turns the long X axis tangent
		var cs := CollisionShape3D.new()
		cs.shape = wall
		cs.position = pos + Vector3.UP * 1.5
		cs.rotation.y = a
		fence.add_child(cs)

	# Obstacles (static colliders).
	var crate_shape := BoxShape3D.new()
	crate_shape.size = Vector3(0.9, 0.9, 0.9)
	var barrel_shape := CylinderShape3D.new()
	barrel_shape.radius = 0.36
	barrel_shape.height = 0.75
	var spots: Dictionary = {}
	for o: Array in OBSTACLES:
		var kind: String = o[0]
		var a := deg_to_rad(float(o[1]))
		var radial := Vector3(sin(a), 0.0, cos(a))
		var tangent := Vector3(cos(a), 0.0, -sin(a))
		var pos: Vector3 = radial * float(o[2]) + tangent * float(o[3]) + Vector3.UP * float(o[4])
		var yaw := deg_to_rad(float(o[5]))
		_place(arena, kind, pos, yaw)
		obstacle_positions.append(pos)
		var body := StaticBody3D.new()
		body.name = "Obstacle"
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		cs.shape = crate_shape if kind == "crate" else barrel_shape
		cs.position = pos + Vector3.UP * (0.45 if kind == "crate" else 0.375)
		cs.rotation.y = yaw
		body.add_child(cs)
		arena.add_child(body)
		var key := "%s/%s" % [o[1], o[2]]
		if not spots.has(key):
			spots[key] = radial * float(o[2])
	_obstacle_spots.clear()
	for k: String in spots:
		_obstacle_spots.append(spots[k])

	# Lanterns on the kerb outside the fence.
	for i in 8:
		var a := TAU * (i + 0.5) / 8.0
		var pos := Vector3(sin(a), 0.0, cos(a)) * LANTERN_RADIUS
		_place(arena, "sumo_lantern", pos, a)
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.78, 0.45)
		lamp.light_energy = 1.4
		lamp.omni_range = 6.0
		lamp.position = pos + Vector3.UP * 1.0
		arena.add_child(lamp)


func _place(parent: Node3D, piece: String, pos: Vector3, yaw: float) -> Node3D:
	var scene := load(PROPS + piece + ".glb") as PackedScene
	if scene == null:
		push_error("hot_potato: missing prop %s" % piece)
		return null
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation.y = yaw
	parent.add_child(n)
	Look.apply_toon(n)
	return n
