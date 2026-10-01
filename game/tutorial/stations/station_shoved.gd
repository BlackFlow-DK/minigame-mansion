extends TrainingStation
## Station 4, Getting shoved: step onto the red mat and a dummy walks over and shoves you once.
## The card explains the stun. Done once the player was hit by the dummy and can steer again.

const MAT := Vector3(0.0, 0.0, -4.5)
const MAT_RADIUS := 1.0
const POST := Vector3(-2.6, 0.0, -4.5)
## Seconds the dummy tries before it gives the player a nudge itself (never stalls the course).
const GIVE_UP_TIME := 4.0

var _ring: MeshInstance3D
var _hit: bool = false
var _since_hit: float = 0.0
var _approach_time: float = 0.0
var _press: bool = false


func _init() -> void:
	checklist_name = "Get shoved"
	card_title = "Getting shoved"
	card_line = "Step onto the red mat and let the dummy shove you."
	card_tip = "A shoved blob is stunned: it spins and cannot steer until the stars fade."
	glyphs = [&"move"]
	length = 10.0


func build() -> void:
	add_ground(0.0, -length)
	add_disc(MAT + Vector3.UP * 0.045, MAT_RADIUS, 0.04, Color("#f08f84"))
	_ring = add_ring_marker(MAT, MAT_RADIUS + 0.05)
	_ring.material_override = glow_material(Color("#d9483b"), 2.4)
	# The dummy's corner: a little rug.
	add_disc(POST + Vector3.UP * 0.04, 0.7, 0.03, PLUM)


func dummy_posts() -> Array[Transform3D]:
	return [Transform3D(Basis(Vector3.UP, PI * 0.5), to_global(POST + Vector3.UP * 0.05))]


func target() -> Vector3:
	return to_global(MAT)


func begin() -> void:
	if player and not player.got_hit.is_connected(_on_got_hit):
		player.got_hit.connect(_on_got_hit)


func idle_tick(_delta: float) -> void:
	var d := dummy(0)
	if done and d:
		steer(d, to_global(POST), 0.6)


func reset() -> void:
	_approach_time = 0.0


func tick(delta: float) -> void:
	if not live(player):
		return
	var d := dummy(0)
	if _hit:
		_since_hit += delta
		if d:
			steer(d, to_global(POST), 0.6)
		if _since_hit > 0.3 and not player.control_locked:
			set_ring_done(_ring)
			complete()
		return
	if d == null:
		complete()
		return
	var on_mat := flat_dist(player.global_position, to_global(MAT)) < MAT_RADIUS + 0.35
	if not on_mat:
		_approach_time = 0.0
		steer(d, to_global(POST), 0.6)
		return
	_approach_time += delta
	var to_player := Vector2(player.global_position.x - d.global_position.x, player.global_position.z - d.global_position.z)
	if to_player.length() > 1.05:
		steer(d, player.global_position, 0.8)
	else:
		# Close enough: keep facing the player and press shove (edges; the shove has its own cooldown).
		d.intent.move = to_player.normalized() * 0.15
		_press = not _press
		d.intent.action_pressed = _press
	if _approach_time > GIVE_UP_TIME:
		var dir := Vector3(to_player.x, 0.0, to_player.y).normalized()
		player.apply_impulse(dir * 9.0 + Vector3.UP * 3.0, d)
		_approach_time = 0.0


func _on_got_hit(_impulse: Vector3, source_slot: int) -> void:
	var d := dummy(0)
	if active and not _hit and (d == null or source_slot == d.slot):
		_hit = true
		_since_hit = 0.0
		set_progress("Stunned! Wait for the stars to fade.")
