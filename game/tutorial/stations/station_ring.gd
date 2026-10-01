extends TrainingStation
## Station 6, Shrinking ring taster: a small copy of the Bumper Sumo platform (the real core
## and first ring, scaled down) in a garden pond. Step onto the ring and it starts flashing;
## a moment later it drops. Be on the core when it goes. The ring rises back afterwards.

enum RingState { IDLE, WARNING, DROPPED, RISING }

const SCALE := 0.6
const CORE_RADIUS := 3.0 * SCALE
const RING_RADIUS := 5.0 * SCALE
const TOP := 0.05
const THICKNESS := 0.6
## Near edge of the pond (local z).
const POND_NEAR := -2.2
const WARN_TIME := 2.2
## After the drop: seconds until we check who is on the core, and until the ring is back.
const CHECK_AFTER := 0.45
const RISE_AFTER := 1.8
const RISE_TIME := 0.8

var state: RingState = RingState.IDLE
var centre: Vector3 = Vector3(0.0, 0.0, POND_NEAR - RING_RADIUS)

var _ring_body: StaticBody3D
var _ring_shape: CollisionShape3D
var _ring_model: Node3D
var _flash: StandardMaterial3D
var _t: float = 0.0
## Rest height of the ring model in its body's frame.
var _model_y: float = 0.0


func _init() -> void:
	checklist_name = "Shrinking ring"
	card_title = "Shrinking ring"
	card_line = "Step onto the ring. It drops soon: get to the middle!"
	card_tip = "In Bumper Sumo the outer rings fall one by one."
	glyphs = [&"move"]
	length = 12.0


func build() -> void:
	add_ground(0.0, POND_NEAR + 0.25)
	add_ground(centre.z - RING_RADIUS + 0.25, -length)
	add_liquid(POND_NEAR + 0.25, centre.z - RING_RADIUS + 0.25, -0.8)
	var core := _disc_body(CORE_RADIUS, "Core")
	add_model("res://assets/models/props/sumo_core.glb", centre + Vector3.UP * TOP, 0.0, SCALE, core)
	_ring_body = _disc_body(RING_RADIUS, "Ring")
	_ring_shape = _ring_body.get_child(0) as CollisionShape3D
	_ring_model = add_model("res://assets/models/props/sumo_ring_1.glb", centre + Vector3.UP * TOP, 0.0, SCALE, _ring_body)
	if _ring_model:
		_model_y = _ring_model.position.y
	_flash = StandardMaterial3D.new()
	_flash.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash.albedo_color = Color(1.0, 0.55, 0.2, 0.0)
	_flash.render_priority = 1
	_own_materials.append(_flash)
	if _ring_model:
		for mi in _ring_model.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_overlay = _flash
	add_model("res://assets/models/props/sumo_lantern.glb", Vector3(-3.3, 0.0, POND_NEAR + 1.0), 0.0, 0.8)
	add_model("res://assets/models/props/sumo_lantern.glb", Vector3(3.3, 0.0, POND_NEAR + 1.0), 0.0, 0.8)


func target() -> Vector3:
	return to_global(centre + Vector3.UP * TOP)


func begin() -> void:
	_set_ring(true)


func tick(delta: float) -> void:
	if not live(player):
		return
	var d := flat_dist(player.global_position, to_global(centre))
	match state:
		RingState.IDLE:
			if not done and d < RING_RADIUS and player.global_position.y > -0.2:
				state = RingState.WARNING
				_t = 0.0
				set_progress("Ring dropping!")
				Sfx.play(&"platform_crack", to_global(centre + Vector3(0.0, 0.0, RING_RADIUS - 0.6)))
		RingState.WARNING:
			if _t >= WARN_TIME:
				state = RingState.DROPPED
				_t = 0.0
				_set_ring(false)
				Sfx.play(&"platform_fall", to_global(centre + Vector3(0.0, 0.0, RING_RADIUS - 0.6)))
				if room and room.camera:
					room.camera.add_shake(0.35)
		RingState.DROPPED:
			if _t >= CHECK_AFTER and not done and d < CORE_RADIUS + 0.2 and player.global_position.y > -0.3:
				set_progress("")
				complete()


func reset() -> void:
	state = RingState.IDLE
	_t = 0.0
	set_progress("")
	_set_ring(true)
	if _ring_model:
		_ring_model.position.y = _model_y
		_ring_model.visible = true


## Timers run here, so the ring comes back up even after the station is done.
func _physics_process(delta: float) -> void:
	match state:
		RingState.WARNING:
			_t += delta
		RingState.DROPPED:
			_t += delta
			var far := not live(player) or flat_dist(player.global_position, to_global(centre)) > RING_RADIUS + 0.3
			if (done and _t >= RISE_AFTER * 0.5) or (_t >= RISE_AFTER and far):
				_rise()


## Every frame: the warning flash and the drop / rise animation.
func _process(delta: float) -> void:
	if _ring_model == null:
		return
	match state:
		RingState.IDLE:
			_flash.albedo_color.a = 0.0
		RingState.WARNING:
			var k := clampf(_t / WARN_TIME, 0.0, 1.0)
			_flash.albedo_color.a = (0.5 + 0.5 * sin(_t * TAU * lerpf(4.0, 11.0, k))) * lerpf(0.5, 1.0, k)
			_ring_model.position.y = _model_y + sin(_t * 47.0) * 0.015 * k
		RingState.DROPPED:
			_flash.albedo_color.a = 0.0
			_ring_model.position.y = _model_y - 0.5 * 9.0 * _t * _t
			_ring_model.visible = _t < 1.2
		RingState.RISING:
			_t += delta
			var k := clampf(_t / RISE_TIME, 0.0, 1.0)
			_ring_model.visible = true
			_ring_model.position.y = lerpf(_model_y - 1.2, _model_y, ease(k, 0.4))
			if k >= 1.0:
				state = RingState.IDLE
				_set_ring(true)


func _rise() -> void:
	state = RingState.RISING
	_t = 0.0


func _set_ring(solid: bool) -> void:
	if _ring_body == null:
		return
	_ring_body.collision_layer = 1 if solid else 0
	_ring_shape.set_deferred(&"disabled", not solid)


func _disc_body(radius: float, body_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = centre + Vector3(0.0, TOP - THICKNESS * 0.5, 0.0)
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = THICKNESS
	cs.shape = cyl
	body.add_child(cs)
	add_child(body)
	return body
