extends GameTest
## Arena camera: framing maths, bounds, modes, stability and shake (headless, no rendering).

const CAMERA_SCENE: PackedScene = preload("res://camera/arena_camera.tscn")
const DT := 1.0 / 60.0


## A camera in the tree that only moves when the test calls update_camera().
func _make_camera() -> ArenaCamera:
	var cam := CAMERA_SCENE.instantiate() as ArenaCamera
	add_child(cam)
	cam.set_process(false)
	return cam


func _free_camera(cam: ArenaCamera) -> void:
	remove_child(cam)
	cam.queue_free()


func _place(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))


## Puts the players evenly on a ring of `radius` around `center`.
func _ring(ps: Array[Player], radius: float, center: Vector3 = Vector3.ZERO) -> void:
	for i in ps.size():
		var a := TAU * i / ps.size()
		_place(ps[i], center + Vector3(cos(a), 0.0, sin(a)) * radius)


func _settle(cam: ArenaCamera, seconds: float = 6.0) -> void:
	for i in int(seconds / DT):
		cam.update_camera(DT)


func _raw_distance(cam: ArenaCamera) -> float:
	var f := ArenaCamera.frame_points(cam.get_framed_points(), cam.view_basis(), tan(deg_to_rad(cam.fov) * 0.5), 16.0 / 9.0, cam.margin)
	return f[1]


func test_distance_grows_when_players_spread() -> void:
	var ps := spawn_arena(4)
	var cam := _make_camera()
	cam.min_distance = 0.1
	cam.max_distance = 1000.0
	_ring(ps, 1.0)
	var near := cam.compute_target()[1] as float
	_ring(ps, 4.0)
	var mid := cam.compute_target()[1] as float
	_ring(ps, 9.0)
	var far := cam.compute_target()[1] as float
	assert_true(near < mid and mid < far, "distance grows with spread: %f < %f < %f" % [near, mid, far])
	assert_true(_raw_distance(cam) > mid, "static frame_points agrees")
	_free_camera(cam)


func test_distance_stays_within_min_max() -> void:
	var ps := spawn_arena(4)
	var cam := _make_camera()
	cam.min_distance = 10.0
	cam.max_distance = 14.0
	_ring(ps, 0.5)
	assert_near(cam.compute_target()[1] as float, 10.0, 0.0001, "clustered players clamp to min_distance")
	_ring(ps, 9.5)
	assert_near(cam.compute_target()[1] as float, 14.0, 0.0001, "spread players clamp to max_distance")
	_settle(cam)
	assert_true(cam.distance >= 10.0 - 0.001 and cam.distance <= 14.0 + 0.001, "settled distance %f in range" % cam.distance)
	assert_near(cam.global_position.distance_to(cam.focus), cam.distance, 0.001, "camera sits `distance` from focus")
	_free_camera(cam)


func test_ignores_dead_players() -> void:
	var ps := spawn_arena(4)
	var cam := _make_camera()
	cam.max_distance = 1000.0
	_ring(ps.slice(0, 3), 2.0)
	_place(ps[3], Vector3(9.0, 0.0, -9.0))
	var with_all := cam.compute_target()
	ps[3].eliminate()
	assert_eq(cam.get_framed_points().size(), 3, "framed points after one death")
	var without := cam.compute_target()
	assert_true((without[1] as float) < (with_all[1] as float), "distance shrinks once the far player is dead")
	for p: Player in ps.slice(0, 3):
		p.eliminate()
	assert_true(cam.compute_target().is_empty(), "no target when everyone is dead")
	_free_camera(cam)


func test_zero_players_holds_position() -> void:
	var cam := _make_camera()
	cam.update_camera(DT)
	var start := cam.global_transform
	_settle(cam, 1.0)
	assert_eq(cam.global_transform, start, "no stage: camera holds")
	_free_camera(cam)
	var ps := spawn_arena(2)
	cam = _make_camera()
	_settle(cam, 2.0)
	var framed := cam.global_transform
	for p in ps:
		p.eliminate()
	_settle(cam, 2.0)
	assert_eq(cam.global_transform, framed, "all dead: camera holds its last framing")
	_free_camera(cam)


func test_respects_radius_bounds() -> void:
	var ps := spawn_arena(3)
	var cam := _make_camera()
	cam.bounds_mode = ArenaCamera.BoundsMode.RADIUS
	cam.bounds_radius = 8.0
	_ring(ps.slice(0, 2), 2.0)
	_place(ps[2], Vector3(0.0, -40.0, 30.0))  # flung off and falling into the void
	for pt in cam.get_framed_points():
		assert_true(Vector2(pt.x, pt.z).length() <= 8.0 + 0.001 and pt.y >= -0.001, "framed point %s inside the cylinder" % pt)
	_settle(cam)
	var f := cam.focus
	assert_true(Vector2(f.x, f.z).length() <= 8.0 + 0.001, "focus %s inside radius" % f)
	assert_true(f.y >= -0.001, "focus never below the arena floor (%f)" % f.y)
	cam.bounds_mode = ArenaCamera.BoundsMode.NONE
	assert_true(cam.compute_target()[1] as float > cam.distance, "unbounded it would chase the falling player")
	_free_camera(cam)


func test_respects_box_bounds() -> void:
	var ps := spawn_arena(2)
	var cam := _make_camera()
	cam.bounds_mode = ArenaCamera.BoundsMode.BOX
	cam.bounds_box = AABB(Vector3(-5.0, 0.0, -5.0), Vector3(10.0, 4.0, 10.0))
	_place(ps[0], Vector3(40.0, -20.0, 0.0))
	_place(ps[1], Vector3(-40.0, 0.0, 0.0))
	_settle(cam)
	assert_true(cam.bounds_box.grow(0.001).has_point(cam.focus), "focus %s inside the box" % cam.focus)
	for pt in cam.get_framed_points():
		assert_true(cam.bounds_box.grow(0.001).has_point(pt), "framed point %s inside the box" % pt)
	_free_camera(cam)


func test_all_players_project_inside_viewport() -> void:
	var ps := spawn_arena(8)
	var positions: Array[Vector3] = [
		Vector3(-8.5, 0, -8.0), Vector3(8.0, 0, -6.5), Vector3(-7.0, 0, 8.5), Vector3(8.5, 0, 8.0),
		Vector3(0, 0, 0), Vector3(2.0, 1.5, -3.0), Vector3(-3.0, 0, 3.0), Vector3(5.0, 0, 1.0)]
	for i in ps.size():
		_place(ps[i], positions[i])
	var rect := get_viewport().get_visible_rect()
	assert_true(rect.size.x > 0.0 and rect.size.y > 0.0, "viewport has a size")
	for yaw: float in [0.0, 35.0, -120.0]:
		for pitch: float in [50.0, 30.0, 70.0]:
			var cam := _make_camera()
			cam.yaw_degrees = yaw
			cam.pitch_degrees = pitch
			cam.max_distance = 200.0
			_settle(cam)
			for p in ps:
				var pt := p.global_position + Vector3.UP * cam.target_height
				assert_false(cam.is_position_behind(pt), "slot %d in front (yaw %s, pitch %s)" % [p.slot, yaw, pitch])
				var sp := cam.unproject_position(pt)
				assert_true(rect.has_point(sp), "slot %d at %s on screen %s (yaw %s, pitch %s)" % [p.slot, sp, rect.size, yaw, pitch])
			_free_camera(cam)


func test_group_is_centred_and_tight() -> void:
	var ps := spawn_arena(4)
	_ring(ps, 6.0, Vector3(3.0, 0.0, -2.0))
	var cam := _make_camera()
	cam.min_distance = 0.1
	cam.max_distance = 1000.0
	_settle(cam)
	var rect := get_viewport().get_visible_rect()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in ps:
		var sp := cam.unproject_position(p.global_position + Vector3.UP * cam.target_height)
		lo = lo.min(sp)
		hi = hi.max(sp)
	var mid := (lo + hi) * 0.5
	var center := rect.size * 0.5
	# Tight on one axis means the group spans most of that axis (margin eats the rest).
	var fill := maxf((hi.x - lo.x) / rect.size.x, (hi.y - lo.y) / rect.size.y)
	assert_true(fill > 0.5, "group fills the view (%f)" % fill)
	assert_true(absf(mid.x - center.x) < rect.size.x * 0.1, "horizontally centred (%s vs %s)" % [mid, center])
	assert_true(absf(mid.y - center.y) < rect.size.y * 0.15, "vertically centred (%s vs %s)" % [mid, center])
	_free_camera(cam)


func test_stable_when_players_stand_still() -> void:
	var ps := spawn_arena(6)
	_ring(ps, 5.0)
	var cam := CAMERA_SCENE.instantiate() as ArenaCamera
	add_child(cam)  # real _process, real physics
	await step(360)
	var last := cam.global_transform
	var worst := 0.0
	for i in 60:
		await step(1)
		worst = maxf(worst, cam.global_position.distance_to(last.origin))
		last = cam.global_transform
	assert_true(worst < 0.0005, "settled camera moves < 0.5 mm per frame (worst %f)" % worst)
	assert_eq(cam.global_basis, cam.view_basis(), "orientation stays fixed")
	_free_camera(cam)


func test_smoothing_moves_gradually() -> void:
	var ps := spawn_arena(2)
	_ring(ps, 1.0)
	var cam := _make_camera()
	_settle(cam)
	var before := cam.focus
	_ring(ps, 1.0, Vector3(6.0, 0.0, 0.0))
	cam.update_camera(DT)
	var moved := cam.focus.x - before.x
	assert_true(moved > 0.0 and moved < 1.0, "one frame moves only part of the way (%f)" % moved)
	_settle(cam)
	assert_near(cam.focus.x, before.x + 6.0, 0.01, "arrives after settling")
	_free_camera(cam)


func test_follow_local_and_fixed_modes() -> void:
	var ps := spawn_arena(3)
	_place(ps[0], Vector3(4.0, 0.0, -3.0))  # slot 0 is the local human offline
	_place(ps[1], Vector3(-8.0, 0.0, 8.0))
	var cam := _make_camera()
	cam.mode = ArenaCamera.Mode.FOLLOW_LOCAL
	cam.snap()
	assert_near(cam.focus, Vector3(4.0, cam.target_height, -3.0), 0.05, "follows the local player")
	assert_near(cam.distance, cam.follow_distance, 0.0001, "at follow_distance")
	cam.mode = ArenaCamera.Mode.FIXED
	cam.fixed_focus = Vector3(1.0, 0.0, 2.0)
	cam.fixed_distance = 20.0
	cam.snap()
	assert_near(cam.global_position, Vector3(1.0, 0.0, 2.0) + cam.view_basis().z * 20.0, 0.0001, "fixed placement")
	_free_camera(cam)


func test_focus_on_overrides_then_returns() -> void:
	var ps := spawn_arena(4)
	_ring(ps, 6.0)
	_place(ps[2], Vector3(2.0, 0.0, 7.0))
	var cam := _make_camera()
	_settle(cam)
	var framed_focus := cam.focus
	cam.focus_on(ps[2], 3.0)
	assert_true(cam.is_focusing(), "focusing")
	_settle(cam, 2.9)
	assert_near(cam.focus, ps[2].global_position + Vector3.UP * cam.target_height, 0.05, "looks at the node")
	assert_near(cam.distance, cam.close_up_distance, 0.05, "close-up distance")
	_settle(cam, 6.0)
	assert_false(cam.is_focusing(), "override expired")
	assert_near(cam.focus, framed_focus, 0.01, "back to framing all")
	_free_camera(cam)


func test_shake_decays_to_zero() -> void:
	var cam := _make_camera()
	cam.add_shake(0.5)
	cam.add_shake(0.8)
	assert_near(cam.trauma, 1.0, 0.0001, "trauma caps at 1")
	var peak := 0.0
	for i in 10:
		cam.update_camera(DT)
		peak = maxf(peak, Vector2(cam.h_offset, cam.v_offset).length())
	assert_true(peak > 0.01, "shake offsets the view (%f)" % peak)
	assert_eq(cam.global_basis, cam.view_basis(), "shake never rotates the camera")
	_settle(cam, 1.5)
	assert_eq(cam.trauma, 0.0, "trauma decayed")
	assert_eq(cam.h_offset, 0.0, "h_offset back to zero")
	assert_eq(cam.v_offset, 0.0, "v_offset back to zero")
	_free_camera(cam)


func test_shake_off_in_settings_is_a_no_op() -> void:
	var settings := get_node(^"/root/Settings")
	var was: bool = settings.get(&"screen_shake")
	var cam := _make_camera()
	settings.set(&"screen_shake", false)
	cam.add_shake(0.8)
	assert_eq(cam.trauma, 0.0, "Screen shake off: no trauma")
	cam.update_camera(DT)
	assert_eq(cam.h_offset, 0.0, "no offset")
	settings.set(&"screen_shake", true)
	cam.add_shake(0.5)
	assert_near(cam.trauma, 0.5, 0.0001, "Screen shake on: shakes")
	settings.set(&"screen_shake", was)
	_free_camera(cam)
