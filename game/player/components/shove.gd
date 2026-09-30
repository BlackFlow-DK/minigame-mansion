class_name ShoveComponent
extends PlayerComponent
## The default action: on `intent.action_pressed`, a short shove along `facing`.
## A brief active window with a hitbox in front of the blob; every other living player
## caught in it gets `victim.apply_impulse(impulse, player)` once per shove. The shover
## lunges forward a little. Raises `shove_started` and `shove_hit(victim_slot)`.
## What the victim does with the impulse is the status component's business.
## Owner: shove.

## Physics layer 2 (`players`).
const PLAYERS_MASK: int = 1 << 1
## Victims whose centre is more than this far above/below the shover's are missed.
const MAX_HEIGHT_DIFF: float = 1.0
## Height of the hitbox centre above the player origin (the blob is 1 m tall).
const HITBOX_HEIGHT: float = 0.5

## False: action presses are ignored (a minigame replaces or disables the action).
@export var enabled: bool = true
## Horizontal part of the impulse given to a victim (m/s).
@export var force: float = 10.0
## Upward part of the impulse given to a victim (m/s).
@export var lift: float = 3.0
## How far ahead of the shover's centre a victim's centre may be (m). Touching blobs are 0.8 m apart.
@export var reach: float = 1.3
## Full sideways width of the hitbox, measured on victim centres (m).
@export var width: float = 1.4
## Seconds from one shove's start until the next may start.
@export var cooldown: float = 0.6
## Seconds the hitbox stays live after the press.
@export var active_time: float = 0.12
## Extra distance the shover lunges forward over the active window (m).
@export var lunge: float = 0.3

var _cooldown_left: float = 0.0
var _active_left: float = 0.0
var _dir: Vector3 = Vector3.MODEL_FRONT
var _hit: Array[Player] = []
var _lunge_added: float = 0.0
var _query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
var _query_shape: SphereShape3D = SphereShape3D.new()


func _ready() -> void:
	_query.shape = _query_shape
	_query.collision_mask = PLAYERS_MASK
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	if player:
		player.eliminated.connect(func(_reason: StringName) -> void: _cancel())


## True while the hitbox of the current shove is live.
func is_active() -> bool:
	return _active_left > 0.0


## True if a press this tick would start a shove.
func can_shove() -> bool:
	return enabled and player.alive and not player.frozen and not player.control_locked \
		and _cooldown_left <= 0.0


func physics_tick(delta: float) -> void:
	_cooldown_left = maxf(_cooldown_left - delta, 0.0)
	if is_active() and (player.frozen or player.control_locked or not enabled):
		_cancel()
	if player.intent.action_pressed and can_shove():
		_start()
	if not is_active():
		return
	if active_time > 0.0 and lunge > 0.0:
		_lunge_added = lunge / active_time
		player.velocity += _dir * _lunge_added
	_hit_victims()
	_active_left -= delta


func post_tick(_delta: float) -> void:
	# Take the lunge back out after move_and_slide so it never compounds with the movement model.
	if _lunge_added <= 0.0:
		return
	var along := player.velocity.dot(_dir)
	player.velocity -= _dir * minf(_lunge_added, maxf(along, 0.0))
	_lunge_added = 0.0


func _start() -> void:
	var f := player.facing
	f.y = 0.0
	_dir = f.normalized() if f.length_squared() > 0.0001 else Vector3.MODEL_FRONT
	_cooldown_left = cooldown
	# At least one tick, so the press itself always checks the hitbox.
	_active_left = maxf(active_time, 0.0001)
	_hit.clear()
	player.emit_event(&"shove_started")


func _cancel() -> void:
	_active_left = 0.0
	_hit.clear()


func _hit_victims() -> void:
	var space := player.get_world_3d().direct_space_state if player.is_inside_tree() else null
	if space == null:
		return
	var origin := player.global_position
	_query_shape.radius = Vector2(reach, width * 0.5).length() + 0.5
	_query.transform = Transform3D(Basis.IDENTITY, origin + Vector3.UP * HITBOX_HEIGHT)
	_query.exclude = [player.get_rid()]
	for result: Dictionary in space.intersect_shape(_query, 32):
		var victim := result.get("collider") as Player
		if victim == null or victim == player or not victim.alive or _hit.has(victim):
			continue
		var to := victim.global_position - origin
		if absf(to.y) > MAX_HEIGHT_DIFF:
			continue
		to.y = 0.0
		var ahead := to.dot(_dir)
		var side := (to - _dir * ahead).length()
		if ahead <= 0.0 or ahead > reach or side > width * 0.5:
			continue
		_hit.append(victim)
		victim.apply_impulse(_impulse_for(to), player)
		player.emit_event(&"shove_hit", [victim.slot])


## Mostly along the shove, bent toward the victim so side hits push outward, plus lift.
func _impulse_for(to_victim: Vector3) -> Vector3:
	var away := to_victim.normalized() if to_victim.length_squared() > 0.0001 else _dir
	var horizontal := (_dir * 2.0 + away).normalized()
	return horizontal * force + Vector3.UP * lift
