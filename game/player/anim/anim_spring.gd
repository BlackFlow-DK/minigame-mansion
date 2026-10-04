class_name AnimSpring
extends RefCounted
## A damped spring on one float for procedural animation (squash, lean, pop).
## Stepped in fixed sub-steps, so it behaves the same at any frame rate.
## Kick it by writing `value` or `velocity`; `step()` pulls it back toward a target.

const MAX_SUBSTEP := 1.0 / 240.0
## Longer frames (hitches) are clamped to this, so one bad frame cannot explode the spring.
const MAX_DELTA := 0.1

var value: float
var velocity: float = 0.0
## Pull toward the target (1/s^2). Higher is faster.
var stiffness: float
## Velocity damping (1/s). Below 2*sqrt(stiffness) the spring overshoots (jiggles).
var damping: float


func _init(start: float = 0.0, spring_stiffness: float = 200.0, spring_damping: float = 14.0) -> void:
	value = start
	stiffness = spring_stiffness
	damping = spring_damping


## Advances the spring by `delta` seconds toward `target`; returns the new value.
func step(target: float, delta: float) -> float:
	if value == target and velocity == 0.0:
		return value  # at rest: nothing to integrate
	var left := clampf(delta, 0.0, MAX_DELTA)
	while left > 0.0:
		var h := minf(left, MAX_SUBSTEP)
		velocity += (stiffness * (target - value) - damping * velocity) * h
		value += velocity * h
		left -= h
	# Snap when at rest so a settled pose is exact (e.g. scale back to exactly 1).
	if absf(value - target) < 0.0001 and absf(velocity) < 0.001:
		value = target
		velocity = 0.0
	return value


## Jumps to `v` with no motion.
func snap(v: float) -> void:
	value = v
	velocity = 0.0
