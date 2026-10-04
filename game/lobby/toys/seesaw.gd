extends Node3D
## Lobby toy: a see-saw (a plank on a pivot, along X). Host-simulated single-angle physics: the
## blobs standing on the plank push their end down by their weight (small 0.7, normal 1.0,
## big 1.5) times their distance from the pivot; with nobody on it the plank drifts back level.
## The host sends (angle, angular speed) ~10 Hz unreliable; every other peer eases its own
## plank toward that (extrapolated) angle, the same exponential easing everywhere, so the plank
## is a smooth moving platform on every peer.
## Catapult: a blob that lands hard on the HIGH end slams it down and throws the blobs on the
## low end up. The host decides (it sees every `landed` event); each thrown blob is launched by
## its own authority (`launch`, reliable, to that peer only).

signal catapulted(jumper_slot: int, launched: Array)
signal hit_stop(side: int)

const MODEL := "res://assets/models/props/toy_seesaw.glb"
const PIVOT_Y := 0.5
const HALF_LEN := 2.1
const HALF_WIDTH := 0.35
## Plank top above the pivot (local y).
const TOP_Y := 0.18
const PLANK_SIZE := Vector3(4.2, 0.14, 0.7)
## The ends touch the floor at this tilt.
const MAX_TILT := 0.235
const SIZE_WEIGHT := {"small": 0.7, "normal": 1.0, "big": 1.5}

## Angular acceleration per (weight x metre) of imbalance (rad/s^2).
@export var torque_gain: float = 2.4
@export var damping: float = 3.0
## Pull back to level with nobody on it.
@export var level_spring: float = 5.0
## Bounce off the floor stops (fraction of the angular speed kept, reversed).
@export var stop_bounce: float = 0.25
## Catapult: the jumper's landing speed (m/s) needed, the plank's slam speed (rad/s), the
## throw height (m) for a normal-weight jumper landing at `catapult_speed`, and the cap.
@export var catapult_speed: float = 3.0
@export var slam_speed: float = 3.2
@export var throw_height: float = 2.8
@export var throw_max: float = 4.0
## Host updates per second, client easing rate (1/s).
@export var state_rate: float = 10.0
@export var ease_rate: float = 12.0

var lobby: MansionLobby = null
## The plank's tilt about Z (rad): + lifts the +X end. On clients the eased one.
var angle: float = 0.0
var ang_vel: float = 0.0
## Every peer: catapults seen (network check).
var catapult_count: int = 0

var _plank_vis: Node3D = null
var _plank_body: AnimatableBody3D = null
var _target_angle: float = 0.0
var _target_vel: float = 0.0
var _target_age: float = 0.0
var _send_accum: float = 0.0
var _at_stop: int = 0


func setup(p_lobby: MansionLobby, pos: Vector3) -> void:
	lobby = p_lobby
	position = pos
	var scene := load(MODEL) as PackedScene
	if scene:
		var m := scene.instantiate() as Node3D
		add_child(m)
		Look.apply_toon(m)
		_plank_vis = m.get_node_or_null(^"Plank") as Node3D
	var base := lobby.make_static_body("SeesawBase")
	lobby.add_solid_box(base, Transform3D(Basis(), pos + Vector3(0.0, 0.25, 0.0)), Vector3(0.9, 0.5, 0.7), 0.6)
	_plank_body = AnimatableBody3D.new()
	_plank_body.name = "SeesawPlank"
	_plank_body.collision_layer = 1
	_plank_body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = PLANK_SIZE
	cs.shape = box
	cs.position = Vector3(0.0, TOP_Y - PLANK_SIZE.y * 0.5, 0.0)
	_plank_body.add_child(cs)
	# In place before it enters the world: a platform that jumps there from the origin on its
	# first physics step would carry whoever stands at the origin along (the lobby sits at the
	# world origin, so its local frame is the world).
	_plank_body.transform = pivot_xform()
	lobby.add_child(_plank_body)


## World transform of the pivot, tilted by `angle` (the plank's frame: +X along the plank,
## top surface at local y = TOP_Y).
func pivot_xform(a: float = INF) -> Transform3D:
	var t := angle if a == INF else a
	return Transform3D(Basis(Vector3.BACK, t), position + Vector3.UP * PIVOT_Y)


## The plank as a solid box for the ball.
func plank_box_xform() -> Transform3D:
	return pivot_xform() * Transform3D(Basis(), Vector3(0.0, TOP_Y - PLANK_SIZE.y * 0.5, 0.0))


## Where a blob at world `pos` stands on the plank: Vector3(x along the plank, height above the
## top, z across), or Vector3.INF when it is not over the plank.
func plank_local(pos: Vector3) -> Vector3:
	var l := pivot_xform().affine_inverse() * pos
	if absf(l.x) > HALF_LEN + 0.15 or absf(l.z) > HALF_WIDTH + 0.25:
		return Vector3.INF
	return Vector3(l.x, l.y - TOP_Y, l.z)


## The blobs standing on the plank (on the ground, feet within a few cm of the top).
func riders(live: Array[Player]) -> Array[Player]:
	var out: Array[Player] = []
	for p in live:
		var l := plank_local(p.global_position)
		if l == Vector3.INF or l.y < -0.15 or l.y > 0.2:
			continue
		var sync := p.get_component(&"sync") as SyncComponent
		var grounded := sync.is_grounded() if sync else p.is_on_floor()
		if grounded:
			out.append(p)
	return out


static func weight_of(p: Player) -> float:
	var size: String = str(p.loadout.get("size", "normal")) if p.loadout else "normal"
	return float(SIZE_WEIGHT.get(size, 1.0))


## +1 when the +X end is up, -1 when the -X end is up, 0 level.
func high_side() -> int:
	if absf(angle) < 0.03:
		return 0
	return 1 if angle > 0.0 else -1


# --- Host ------------------------------------------------------------------------------------------

func host_tick(delta: float, live: Array[Player]) -> void:
	var on := riders(live)
	var torque := 0.0
	for p in on:
		torque -= weight_of(p) * plank_local(p.global_position).x
	var acc := torque_gain * torque - damping * ang_vel
	if on.is_empty():
		acc -= level_spring * angle
	ang_vel += acc * delta
	_integrate(delta)
	_send_accum += delta
	var interval := 1.0 / maxf(state_rate, 1.0)
	if _send_accum >= interval:
		_send_accum = minf(_send_accum - interval, interval)
		lobby.send_toys(&"_rpc_seesaw_state", [angle, ang_vel])


func _integrate(delta: float) -> void:
	angle += ang_vel * delta
	if absf(angle) > MAX_TILT:
		angle = signf(angle) * MAX_TILT
		if ang_vel * angle > 0.0:
			ang_vel = -ang_vel * stop_bounce


## Host: a blob landed (any blob; the host sees every `landed`). On the high end, hard enough:
## the plank slams and the blobs on the low end fly. Returns the launched slots.
func host_landed(jumper: Player, impact_speed: float, live: Array[Player]) -> Array[int]:
	var launched: Array[int] = []
	var l := plank_local(jumper.global_position)
	var side := high_side()
	# A remote blob's copy here trails its true position (interpolation): when its `landed`
	# arrives the copy may still be above the plank.
	var max_above := 0.4 if jumper.is_authority() else 2.5
	if l == Vector3.INF or side == 0 or impact_speed < catapult_speed or l.y > max_above or l.y < -0.3:
		return launched
	if signf(l.x) != float(side) or absf(l.x) < 0.7:
		return launched
	var power := clampf(impact_speed / 7.0, 0.6, 1.4) * clampf(weight_of(jumper), 0.7, 1.5)
	ang_vel = -float(side) * slam_speed * power
	for p in live:
		if p == jumper:
			continue
		var q := plank_local(p.global_position)
		if q == Vector3.INF or q.y < -0.15 or q.y > 0.35 or signf(q.x) == float(side) or absf(q.x) < 0.6:
			continue
		var h := clampf(throw_height * power / sqrt(weight_of(p)), 1.5, throw_max)
		# a little push toward the pivot side's far end, so they arc off the plank
		var out := Vector3(float(-side) * 0.8, 0.0, 0.0)
		lobby.launch_player(p, h, out)
		launched.append(p.slot)
	lobby.send_toys(&"_rpc_seesaw_fling", [jumper.slot, launched])
	apply_fling(jumper.slot, launched)
	return launched


# --- Every peer ----------------------------------------------------------------------------------

## Client: the host's plank (unreliable).
func apply_state(a: float, w: float) -> void:
	_target_angle = clampf(a, -MAX_TILT, MAX_TILT)
	_target_vel = w
	_target_age = 0.0


func apply_fling(jumper_slot: int, launched: Array) -> void:
	catapult_count += 1
	var end := pivot_xform() * Vector3(float(-high_side()) * HALF_LEN, TOP_Y, 0.0)
	Sfx.play(&"toy_sproing", end)
	Fx.play(&"dust_puff", end)
	catapulted.emit(jumper_slot, launched)


func _physics_process(delta: float) -> void:
	if lobby == null:
		return
	if not lobby.is_host():
		_target_age += delta
		var aim := clampf(_target_angle + _target_vel * minf(_target_age, 0.15), -MAX_TILT, MAX_TILT)
		var prev := angle
		angle += (aim - angle) * (1.0 - exp(-ease_rate * delta))
		ang_vel = (angle - prev) / maxf(delta, 0.0001)
	# The floor stops: a thunk when an end arrives there with some speed.
	var stop := int(signf(angle)) if absf(angle) >= MAX_TILT - 0.004 else 0
	if stop != 0 and stop != _at_stop and absf(ang_vel) > 0.4:
		var end := pivot_xform() * Vector3(float(-stop) * HALF_LEN, 0.0, 0.0)
		Sfx.play(&"toy_thunk", end)
		hit_stop.emit(stop)
	_at_stop = stop
	_plank_body.transform = pivot_xform()
	if _plank_vis:
		_plank_vis.rotation = Vector3(0.0, 0.0, angle)
