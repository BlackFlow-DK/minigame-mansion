extends TrainingStation
## Station 1, Move: walk onto the glowing mat a few steps ahead.

const MAT := Vector3(0.0, 0.0, -5.5)
const MAT_RADIUS := 1.1

var _ring: MeshInstance3D


func _init() -> void:
	checklist_name = "Move"
	card_title = "Move"
	card_line = "Walk onto the glowing mat."
	card_tip = "The camera follows you. Forward is always up the screen."
	glyphs = [&"move"]
	length = 10.0


func build() -> void:
	add_ground(3.0, -length)
	add_disc(MAT + Vector3.UP * 0.045, MAT_RADIUS, 0.04, CREAM)
	_ring = add_ring_marker(MAT, MAT_RADIUS + 0.05)


## Where the player starts the course.
func spawn() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, PI), to_global(Vector3(0.0, 0.05, -1.2)))


func target() -> Vector3:
	return to_global(MAT)


func tick(_delta: float) -> void:
	if live(player) and player.global_position.y < 1.0 and flat_dist(player.global_position, to_global(MAT)) < MAT_RADIUS:
		set_ring_done(_ring)
		complete()
