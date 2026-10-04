extends Node3D
## Lobby toy: a big brass bell on a wooden frame. Shoving it (or running into it) rings it.
## Host-validated: a shove is checked on the host (the shover's reported position against its
## copy, the reach, the cooldown); a bump is seen by the host from the synced positions and
## velocities. A ring goes to every peer (`ring`, reliable) and each one plays the same damped
## swing from its arrival, plus `toy_bell`. `cooldown` keeps it from being spammed into noise.

signal rung(strength: float)

const MODEL := "res://assets/models/props/toy_bell.glb"
const PIVOT_Y := 1.7
const BELL_RADIUS := 0.47
const BELL_BOTTOM := 0.75
const POST_X := 0.85

## Seconds after a ring before the bell rings again (host).
@export var cooldown: float = 1.6
## Shove reach from the blob's surface to the bell's (m), and the facing cone.
@export var reach: float = 0.85
@export var cone_deg: float = 75.0
## A blob moving into the bell faster than this (m/s) rings it softly.
@export var bump_speed: float = 2.2
## Swing: peak angle (rad) for a full ring, decay (1/s), period (s).
@export var swing_angle: float = 0.42
@export var swing_decay: float = 1.1
@export var swing_period: float = 1.25

var lobby: MansionLobby = null
## Every peer: the strength of every ring, in order (network check).
var ring_log: Array[float] = []

var _bell: Node3D = null
var _cooldown_left: float = 0.0
var _swing_t: float = 99.0
var _swing_amp: float = 0.0
var _swing_dir: float = 1.0


func setup(p_lobby: MansionLobby, pos: Vector3) -> void:
	lobby = p_lobby
	position = pos
	var scene := load(MODEL) as PackedScene
	if scene:
		var m := scene.instantiate() as Node3D
		add_child(m)
		Look.apply_toon(m)
		_bell = m.get_node_or_null(^"Bell") as Node3D
	var body := lobby.make_static_body("BellBody")
	var xf := Transform3D(Basis(), pos)
	for sx: float in [-1.0, 1.0]:
		lobby.add_solid_box(body, xf * Transform3D(Basis(), Vector3(sx * POST_X, 0.98, 0.0)), Vector3(0.2, 1.95, 0.2), 0.6)
		lobby.add_solid_box(body, xf * Transform3D(Basis(), Vector3(sx * POST_X, 0.08, 0.0)), Vector3(0.26, 0.16, 0.9), 0.6)
	lobby.add_solid_cylinder(body, pos + Vector3.UP * BELL_BOTTOM, BELL_RADIUS, PIVOT_Y - BELL_BOTTOM, 0.5)


## World point of the bell's waist (where a blob hits it).
func target() -> Vector3:
	return position + Vector3.UP * 1.1


## True when a blob at `p_pos` facing `facing` can shove the bell (`extra`: host tolerance).
func in_reach(p_pos: Vector3, facing: Vector3, extra: float = 0.0) -> bool:
	return MansionLobby.reach_check(p_pos, facing, target(), BELL_RADIUS, reach + extra, cone_deg + extra * 20.0, 0.0, 2.0)


func can_ring() -> bool:
	return _cooldown_left <= 0.0


## Host: rings the bell if it is off cooldown. `push`: the direction it was hit along.
func host_ring(strength: float, push: Vector3) -> bool:
	if not can_ring():
		return false
	_cooldown_left = cooldown
	var dir := 1.0 if push.z >= 0.0 else -1.0
	lobby.send_toys(&"_rpc_bell_ring", [strength, dir])
	apply_ring(strength, dir)
	return true


## Every peer: start the swing and the sound.
func apply_ring(strength: float, dir: float) -> void:
	ring_log.append(snappedf(strength, 0.01))
	var envelope := _swing_amp * exp(-swing_decay * _swing_t)
	_swing_amp = maxf(swing_angle * strength, envelope)
	_swing_dir = dir
	_swing_t = 0.0
	Sfx.play(&"toy_bell", target(), linear_to_db(clampf(strength, 0.3, 1.0)))
	rung.emit(strength)


## Host, every physics frame: blobs running into the bell ring it softly.
func host_tick(delta: float, live: Array[Player]) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	if not can_ring():
		return
	for p in live:
		var q := p.global_position
		if q.y > PIVOT_Y or q.y + 1.0 < BELL_BOTTOM:
			continue
		var to := Vector2(position.x - q.x, position.z - q.z)
		var d := to.length()
		if d > BELL_RADIUS + 0.55 or d < 0.001:
			continue
		var v := Vector2(p.velocity.x, p.velocity.z)
		if v.dot(to / d) > bump_speed:
			host_ring(0.55, Vector3(to.x, 0.0, to.y))
			return


## Current swing angle (rad, about X).
func swing() -> float:
	return _swing_dir * _swing_amp * exp(-swing_decay * _swing_t) * sin(TAU * _swing_t / swing_period)


func _process(delta: float) -> void:
	_swing_t += delta
	if _bell:
		_bell.rotation.x = swing()
		_bell.rotation.z = 0.25 * swing() * sin(_swing_t * 3.1)
