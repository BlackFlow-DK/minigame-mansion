class_name BlobBallSim
extends BallSim
## Blob Ball's ball: the shared deterministic ball integrator (`BallSim`,
## res://shared/ball_sim.gd) with Blob Ball's 1.4 m beach ball on its walled pitch with two
## goal boxes (`configure` sizes it per player count). All the physics live in BallSim.

## Ball radius (m). The ball is 1.4 m across.
const RADIUS := 0.7


func _init() -> void:
	radius = RADIUS
