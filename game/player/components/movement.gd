class_name MovementComponent
extends PlayerComponent
## Horizontal velocity and `facing` from `intent.move`. Owner: run.
##
## Accelerates the horizontal velocity toward `intent.move * max_speed` instead of setting it,
## so impulses from the status component (knockback) survive and bleed off over time.
## Vertical velocity belongs to the jump component and is never touched here.
## A minigame can retune this in `_setup`, e.g.
## `(player.get_component(&"movement") as MovementComponent).max_speed = 8.0`.

## Top running speed (m/s) at full stick.
@export var max_speed: float = 6.0
## Acceleration toward the target velocity on the ground while steering (m/s^2).
@export var ground_accel: float = 50.0
## Deceleration on the ground with no input (m/s^2).
@export var ground_friction: float = 35.0
## Acceleration on the ground when the input points against the current velocity (m/s^2).
@export var turn_accel: float = 90.0
## Acceleration toward the target velocity in the air (m/s^2).
@export var air_accel: float = 14.0
## Deceleration in the air with no input (m/s^2).
@export var air_friction: float = 4.0
## Cap on the acceleration while faster than `max_speed` (after a push): the excess bleeds
## off at most this fast, so knockback slides instead of vanishing (m/s^2).
@export var overspeed_decel: float = 12.0
## Deceleration while `control_locked` (stunned): intent is cleared then, so this is a slide (m/s^2).
@export var locked_friction: float = 8.0
## How fast `facing` turns toward the move direction (1/s, exponential; higher is snappier).
@export var facing_sharpness: float = 16.0

## Stick lengths below this do not turn `facing`.
const FACING_DEADZONE := 0.05


func physics_tick(delta: float) -> void:
	var v := player.velocity
	if player.frozen:
		# Contract: frozen means no movement. Kill horizontal motion; leave vertical to jump.
		player.velocity = Vector3(0.0, v.y, 0.0)
		return

	var move := player.intent.move.limit_length(1.0)
	var has_input := move.length_squared() > 0.0001
	var horizontal := Vector3(v.x, 0.0, v.z)
	var target := Vector3(move.x, 0.0, move.y) * max_speed
	var grounded := player.is_on_floor()

	var rate: float
	if player.control_locked:
		rate = locked_friction
	elif grounded:
		if not has_input:
			rate = ground_friction
		elif horizontal.dot(target) < 0.0:
			rate = turn_accel
		else:
			rate = ground_accel
	else:
		rate = air_accel if has_input else air_friction
	if horizontal.length() > max_speed + 0.001:
		rate = minf(rate, overspeed_decel)

	horizontal = horizontal.move_toward(target, rate * delta)
	player.velocity = Vector3(horizontal.x, v.y, horizontal.z)

	if move.length() > FACING_DEADZONE:
		_turn_facing(Vector3(move.x, 0.0, move.y), delta)


func _turn_facing(direction: Vector3, delta: float) -> void:
	var current := atan2(player.facing.x, player.facing.z)
	var wanted := atan2(direction.x, direction.z)
	var angle := lerp_angle(current, wanted, 1.0 - exp(-facing_sharpness * delta))
	player.facing = Vector3(sin(angle), 0.0, cos(angle))
