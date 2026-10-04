extends Node3D
## Lobby toy: a round trampoline. A blob that lands on it is thrown up `launch_height` m; landing
## on it again within `chain_window` s adds `chain_step` m, up to `max_height`. Like the sofa
## cushions, the launch is applied by the bouncing blob's own authority (from its `landed`
## signal and its slide collisions), so it needs no RPC. Every peer squashes the mat and plays
## the boing from the (synced) `landed` events of any blob over the mat.

signal bounced(slot: int, height: float)

const MODEL := "res://assets/models/props/toy_trampoline.glb"
const RADIUS := 1.22
const TOP := 0.46

## Peak height (m) above the take-off point of a first bounce.
@export var launch_height: float = 3.0
## Extra height per chained bounce, and the cap.
@export var chain_step: float = 0.35
@export var max_height: float = 4.0
## Seconds between two landings on the mat that still count as a chain.
@export var chain_window: float = 1.6

var lobby: MansionLobby = null
var body: StaticBody3D = null

var _mat: Node3D = null
var _mat_rest: Vector3 = Vector3.ZERO
var _squash: float = 0.0
var _squash_v: float = 0.0
## slot -> [chain count, time of the last bounce]
var _chain: Dictionary[int, Array] = {}
var _time: float = 0.0


func setup(p_lobby: MansionLobby, pos: Vector3) -> void:
	lobby = p_lobby
	position = pos
	var scene := load(MODEL) as PackedScene
	if scene:
		var m := scene.instantiate() as Node3D
		add_child(m)
		Look.apply_toon(m)
		_mat = m.get_node_or_null(^"Mat") as Node3D
		if _mat:
			_mat_rest = _mat.position
	body = lobby.make_static_body("TrampolineBody")
	lobby.add_solid_cylinder(body, pos, RADIUS, TOP, 0.92)  # a lively bounce for the ball, no energy gain


## Height (m) the bounce number `chain` (0 = first) throws a blob.
func height_for_chain(chain: int) -> float:
	return minf(launch_height + chain_step * chain, max_height)


## Every peer, for every blob's `landed`. The authority of `p` launches it.
func on_landed(p: Player, impact_speed: float) -> bool:
	var q := p.global_position - position
	if Vector2(q.x, q.z).length() > RADIUS + 0.05 or q.y < TOP - 0.25 or q.y > TOP + 0.4:
		return false
	_kick_mat(clampf(impact_speed / 9.0, 0.35, 1.0))
	Sfx.play(&"toy_boing", p.global_position)
	if not p.is_authority() or not _on_top(p):
		return true
	var c: Array = _chain.get(p.slot, [0, -INF])
	var chain := int(c[0]) + 1 if _time - float(c[1]) <= chain_window else 0
	_chain[p.slot] = [chain, _time]
	var h := height_for_chain(chain)
	launch(p, h)
	bounced.emit(p.slot, h)
	return true


## Authority: sets `p`'s upward speed so it peaks `height` m above where it is.
static func launch(p: Player, height: float) -> void:
	var jump := p.get_component(&"jump") as JumpComponent
	var g := jump.get_gravity_strength() if jump else 21.0
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	p.velocity.y = sqrt(2.0 * g * height) + g * dt * 0.5


func _on_top(p: Player) -> bool:
	for i in p.get_slide_collision_count():
		var hit := p.get_slide_collision(i)
		if hit.get_collider() == body and hit.get_normal().y > 0.6:
			return true
	return false


func _kick_mat(strength: float) -> void:
	_squash_v -= 5.5 * strength


func _physics_process(delta: float) -> void:
	_time += delta


func _process(delta: float) -> void:
	# A damped spring: dips, overshoots once, settles.
	_squash_v += (-110.0 * _squash - 9.0 * _squash_v) * delta
	_squash += _squash_v * delta
	_squash = clampf(_squash, -0.22, 0.12)
	if _mat:
		_mat.position = _mat_rest + Vector3.UP * _squash
		var s := 1.0 - _squash * 0.25
		_mat.scale = Vector3(s, 1.0, s)
