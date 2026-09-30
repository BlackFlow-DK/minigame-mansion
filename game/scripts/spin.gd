extends Node3D
## Rotates this node around its Y axis. Used by the smoke-test main scene.

@export var degrees_per_second := 20.0


func _process(delta: float) -> void:
	rotate_y(deg_to_rad(degrees_per_second) * delta)
