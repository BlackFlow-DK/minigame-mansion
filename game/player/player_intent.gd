class_name PlayerIntent
extends RefCounted
## What a player's controller wants this tick. Filled by the `controller` component
## (human input or bot brain), read by the mechanic components.
## Player clears it while the player is `frozen` or `control_locked`.

## Desired move direction on the world XZ plane (x = world X, y = world Z), length 0..1.
var move: Vector2 = Vector2.ZERO
## True only on the tick the jump button went down.
var jump_pressed: bool = false
## True while the jump button is down.
var jump_held: bool = false
## True only on the tick the action button went down.
var action_pressed: bool = false


## Resets to "no input".
func clear() -> void:
	move = Vector2.ZERO
	jump_pressed = false
	jump_held = false
	action_pressed = false
