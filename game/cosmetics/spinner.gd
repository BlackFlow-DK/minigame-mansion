extends Node
## Spins `target` around its own Y axis (the propeller of the propeller cap). Added by
## `Cosmetics.apply()` for catalog items with a `spin_child` flag. Owner: cosmetics system.

var target: Node3D
## Radians per second.
var speed: float = 8.0


func _process(delta: float) -> void:
	if target != null and is_instance_valid(target):
		target.rotate_object_local(Vector3.UP, speed * delta)
