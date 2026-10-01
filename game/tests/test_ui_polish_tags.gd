extends GameTest
## Name tags in a crowd: bunched-up blobs' names step up (or dim) instead of piling on top of
## each other; spread-out blobs keep their tags at the normal height.

const NAME_TAG_SCENE: PackedScene = preload("res://ui/round/name_tag.tscn")

var _cam: Camera3D


func after_each() -> void:
	if is_instance_valid(_cam):
		_cam.queue_free()


func _tags_for(ps: Array[Player]) -> Array[NameTag]:
	var out: Array[NameTag] = []
	for p in ps:
		var tag := NAME_TAG_SCENE.instantiate() as NameTag
		p.add_child(tag)
		tag.setup(p)
		out.append(tag)
	return out


func _camera_on(at: Vector3) -> void:
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.make_current()
	_cam.global_position = at + Vector3(0, 5, 7)
	_cam.look_at(at + Vector3.UP, Vector3.UP)


func test_bunched_tags_do_not_overlap() -> void:
	var ps := spawn_arena(4)
	for i in ps.size():
		ps[i].place_at(Transform3D(Basis.IDENTITY, Vector3(0.25 * i, 0, 0.1 * i)))
		ps[i].display_name = "Blobby %d" % i
	var tags := _tags_for(ps)
	_camera_on(Vector3.ZERO)
	await step(40)
	var rects: Array[Rect2] = []
	var lifted := 0
	for t in tags:
		if t.lift > 0.05:
			lifted += 1
		if t.crowd_alpha < 1.0:
			continue
		rects.append(t.screen_rect(_cam, t.lift))
	assert_true(lifted >= 1, "some tags stepped up (%d)" % lifted)
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			assert_false(rects[i].grow(-1.0).intersects(rects[j].grow(-1.0)), "names %d and %d do not overlap" % [i, j])
	var dimmed := 0
	for t in tags:
		if t.crowd_alpha < 1.0:
			dimmed += 1
	assert_eq(rects.size() + dimmed, tags.size(), "every tag is either clear or dimmed")


func test_spread_out_tags_stay_put() -> void:
	var ps := spawn_arena(3)
	for i in ps.size():
		ps[i].place_at(Transform3D(Basis.IDENTITY, Vector3(-4.0 + 4.0 * i, 0, 0)))
	var tags := _tags_for(ps)
	_camera_on(Vector3.ZERO)
	await step(20)
	for t in tags:
		assert_near(t.lift, 0.0, 0.001, "no lift when apart")
		assert_near(t.crowd_alpha, 1.0, 0.001, "not dimmed")
		assert_near(t.global_position, t.player.global_position + Vector3.UP * t.height, 0.01, "at the normal height")
