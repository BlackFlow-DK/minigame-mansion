extends TrainingStation
## Station 9, Finish: a golden mat before the mansion's garden door. Stepping on it ends the
## course: confetti, the win jingle, and the room shows the "You're ready!" panel.

const MAT := Vector3(0.0, 0.0, -4.5)
const MAT_RADIUS := 1.3

var _ring: MeshInstance3D


func _init() -> void:
	checklist_name = "Finish"
	card_title = "Finish"
	card_line = "Step onto the golden mat to finish the course."
	glyphs = [&"move"]
	length = 10.0


func build() -> void:
	add_ground(0.0, -length - 1.0)
	add_disc(MAT + Vector3.UP * 0.045, MAT_RADIUS, 0.04, Color("#f6d77a"))
	_ring = add_ring_marker(MAT, MAT_RADIUS + 0.05)
	_ring.material_override = glow_material(GOLD, 2.6)
	add_model("res://assets/models/env/minigame_door_arch.glb", Vector3(0.0, 0.0, -8.8), 0.0, 0.7)
	for sx: float in [-1.0, 1.0]:
		add_model("res://assets/models/env/potted_plant.glb", Vector3(sx * 2.4, 0.0, -8.4))
		add_model("res://assets/models/env/candelabra.glb", Vector3(sx * 3.3, 0.0, -6.0))
	add_model("res://assets/models/env/trophy_pedestal.glb", Vector3(-3.0, 0.0, -2.0), 20.0, 0.7)


func target() -> Vector3:
	return to_global(MAT)


func tick(_delta: float) -> void:
	if live(player) and player.global_position.y < 1.0 and flat_dist(player.global_position, to_global(MAT)) < MAT_RADIUS:
		set_ring_done(_ring)
		var at := to_global(MAT)
		for off: Vector3 in [Vector3(0.0, 1.6, 0.0), Vector3(-1.6, 1.2, -0.6), Vector3(1.6, 1.2, -0.6), Vector3(0.0, 1.4, -1.6)]:
			Fx.play(&"confetti", at + off)
		Sfx.play(&"round_win_jingle")
		var visuals := player.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"cheer", true)
		complete()
