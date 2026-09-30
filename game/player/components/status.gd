class_name StatusComponent
extends PlayerComponent
## Impulses, stun and `control_locked` (`got_hit`, `stunned`). Owner: knockback.
## Stub: adds impulses straight to velocity.


## Called by Player.apply_impulse on the authority.
func receive_impulse(impulse: Vector3, _source: Player) -> void:
	player.velocity += impulse
