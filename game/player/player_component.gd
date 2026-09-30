class_name PlayerComponent
extends Node3D
## Base class for one player mechanic or presentation layer.
## Each component is its own scene under `Player/Components`, named after the component
## (`controller`, `status`, ...). See docs/contract.md for the tick order.

## The owning player. Set by Player in its _enter_tree, before this component's _ready.
var player: Player


## Called by Player on the authority only, in tick order, before move_and_slide().
## Only `controller`, `status`, `movement`, `jump` and `shove` get this call.
func physics_tick(_delta: float) -> void:
	pass


## Called by Player on the authority only, on every component, after move_and_slide().
func post_tick(_delta: float) -> void:
	pass
