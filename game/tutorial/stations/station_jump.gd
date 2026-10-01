extends TrainingStation
## Station 2, Jump: two pond gaps (a stepping-stone lawn between them), then a raised terrace
## to climb. Done when the player stands on top of the terrace.

const GAP1 := Vector2(-2.5, -3.7)      # z_near, z_far (a tapped jump clears 1.2 m easily)
const GAP2 := Vector2(-7.5, -8.7)
const LEDGE := Vector2(-10.5, -12.8)
const LEDGE_TOP := 0.8


func _init() -> void:
	checklist_name = "Jump"
	card_title = "Jump"
	card_line = "Hop over the two gaps, then jump up onto the ledge."
	card_tip = "Hold jump for a higher hop."
	glyphs = [&"move", &"jump"]
	length = 14.5


func build() -> void:
	add_ground(0.0, GAP1.x)
	add_ground(GAP1.y, GAP2.x)
	add_ground(GAP2.y, LEDGE.x)
	add_ground(LEDGE.x, LEDGE.y, LEDGE_TOP)
	add_ground(LEDGE.y, -length)
	add_liquid(GAP1.x, GAP2.y, -0.75)
	# Stone edging on the terrace front, so the step reads from the camera.
	add_box(Vector3(0.0, LEDGE_TOP - 0.06, LEDGE.x + 0.08), Vector3(HALF_W * 2.0, 0.14, 0.18), STONE)
	# Lily pads for charm.
	for p: Vector3 in [Vector3(-2.6, -0.72, -3.2), Vector3(2.9, -0.72, -8.1), Vector3(1.2, -0.72, -3.5)]:
		add_disc(p, 0.35, 0.03, Color("#5aa45a"))


func target() -> Vector3:
	return to_global(Vector3(0.0, LEDGE_TOP, (LEDGE.x + LEDGE.y) * 0.5))


func tick(_delta: float) -> void:
	if not live(player):
		return
	var local := to_local(player.global_position)
	if local.y > LEDGE_TOP - 0.2 and local.z < LEDGE.x - 0.3 and local.z > LEDGE.y and player.is_on_floor():
		complete()
