extends TrainingStation
## Station 3, Shove: a dummy blob stands on a low round pad; shove it off.
## Done once the dummy is off the pad.

const PAD := Vector3(0.0, 0.0, -5.5)
const PAD_RADIUS := 1.3
## Low enough to walk onto (a blob steps up about 0.1 m).
const PAD_TOP := 0.1

var _ring: MeshInstance3D
var _knocked_time: float = 0.0
var _since_done: float = -1.0


func _init() -> void:
	checklist_name = "Shove"
	card_title = "Shove"
	card_line = "Walk up to the dummy and shove it off its pad."
	card_tip = "You shove the way you are facing."
	glyphs = [&"move", &"shove"]
	length = 10.0


func build() -> void:
	add_ground(0.0, -length)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = PAD + Vector3(0.0, PAD_TOP * 0.5, 0.0)
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = PAD_RADIUS
	cyl.height = PAD_TOP
	cs.shape = cyl
	body.add_child(cs)
	add_child(body)
	add_disc(PAD + Vector3.UP * PAD_TOP, PAD_RADIUS, PAD_TOP, STONE)
	add_disc(PAD + Vector3.UP * (PAD_TOP + 0.015), PAD_RADIUS - 0.18, 0.03, Color("#d9483b"))
	_ring = add_ring_marker(PAD + Vector3.UP * PAD_TOP, PAD_RADIUS + 0.02)


func dummy_posts() -> Array[Transform3D]:
	return [Transform3D(Basis(), to_global(PAD + Vector3.UP * (PAD_TOP + 0.02)))]


func target() -> Vector3:
	var d := dummy(0)
	return d.global_position if d and not done else to_global(PAD)


## Once done, the dummy hops back onto its pad (out of the way of the course).
func idle_tick(delta: float) -> void:
	if not done or _since_done < 0.0:
		return
	_since_done += delta
	if _since_done >= 1.2:
		_since_done = -1.0
		var d := dummy(0)
		if d:
			d.respawn_at(dummy_posts()[0])


func tick(delta: float) -> void:
	var d := dummy(0)
	if d == null:
		complete()  # nothing to shove: never block the course
		return
	var off := flat_dist(d.global_position, to_global(PAD)) > PAD_RADIUS + 0.15
	_knocked_time = _knocked_time + delta if off else 0.0
	if _knocked_time > 0.15:
		set_ring_done(_ring)
		var visuals := d.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"sad")
		_since_done = 0.0
		complete()
