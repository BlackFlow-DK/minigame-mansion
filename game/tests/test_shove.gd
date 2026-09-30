extends GameTest
## Shove component: hit detection, one impulse per victim per shove, cooldown, gates.
## Every player's `status` is swapped for a recording stand-in, so these tests only see
## what the shover hands to `apply_impulse` (the knockback system decides what it does).


## Records every impulse the Player hands to its status component; never moves the player.
class RecordingStatus extends StatusComponent:
	var impulses: Array[Vector3] = []
	var sources: Array[Player] = []

	func receive_impulse(impulse: Vector3, source: Player) -> void:
		impulses.append(impulse)
		sources.append(source)


var _rec: Dictionary[Player, RecordingStatus] = {}


## Four players; slot 0 shoves from the origin facing +X. The other three stand far away
## unless a test places them. Every status is a RecordingStatus.
func _arena() -> Array[Player]:
	var ps := spawn_arena(4)
	for p in ps:
		_rec[p] = _swap_status(p)
	# Players are added at the origin and then placed; teleporting one back to the origin in
	# that same frame collides with stale broadphase ghosts. One physics step clears them.
	await step(1)
	ps[0].place_at(Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP, true), Vector3.ZERO))
	ps[1].place_at(Transform3D(Basis.IDENTITY, Vector3(0, 0, 8)))
	ps[2].place_at(Transform3D(Basis.IDENTITY, Vector3(0, 0, -8)))
	ps[3].place_at(Transform3D(Basis.IDENTITY, Vector3(-8, 0, 8)))
	return ps


func _swap_status(p: Player) -> RecordingStatus:
	var parent := p.get_parent()
	var holder := p.get_node(^"Components")
	var old := holder.get_node(^"status")
	var index := old.get_index()
	parent.remove_child(p)
	holder.remove_child(old)
	old.free()
	var rec := RecordingStatus.new()
	rec.name = "status"
	holder.add_child(rec)
	holder.move_child(rec, index)
	parent.add_child(p)  # Player re-collects its components in _enter_tree
	return rec


func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, pos))


## Steps `frames` ticks, pressing action on the listed frame indices only.
func _press(p: Player, frames: int, press_on: Array = [0]) -> void:
	await step(frames, func(i: int) -> void: p.intent.action_pressed = press_on.has(i))


func test_victim_in_front_gets_one_impulse() -> void:
	var ps: Array[Player] = await _arena()
	var shover := ps[0]
	_put(ps[1], Vector3(1.0, 0, 0))
	var started := watch(shover, &"shove_started")
	var hits := watch(shover, &"shove_hit")
	await _press(shover, 30)
	assert_eq(started.size(), 1, "one shove_started")
	assert_eq(hits, [[1]], "shove_hit with the victim's slot")
	var rec := _rec[ps[1]]
	if assert_eq(rec.impulses.size(), 1, "exactly one impulse"):
		var shove := shover.get_component(&"shove") as ShoveComponent
		assert_near(rec.impulses[0], Vector3(shove.force, shove.lift, 0), 0.01, "impulse along facing plus lift")
		assert_true(rec.impulses[0].y > 0.0 and rec.impulses[0].y < absf(rec.impulses[0].x), "mostly horizontal")
		assert_eq(rec.sources[0], shover, "source is the shover")
	assert_eq(_rec[shover].impulses.size(), 0, "shover not hit")
	assert_eq(_rec[ps[2]].impulses.size() + _rec[ps[3]].impulses.size(), 0, "far players not hit")


func test_behind_side_and_out_of_range_not_hit() -> void:
	var ps: Array[Player] = await _arena()
	_put(ps[1], Vector3(-1.0, 0, 0))   # behind
	_put(ps[2], Vector3(2.5, 0, 0))    # too far ahead
	_put(ps[3], Vector3(0.2, 0, 1.2))  # beside
	var hits := watch(ps[0], &"shove_hit")
	await _press(ps[0], 30)
	assert_eq(hits.size(), 0, "no shove_hit")
	for i in [1, 2, 3]:
		assert_eq(_rec[ps[i]].impulses.size(), 0, "slot %d not hit" % i)


func test_cooldown_blocks_second_shove() -> void:
	var ps: Array[Player] = await _arena()
	_put(ps[1], Vector3(1.0, 0, 0))
	var started := watch(ps[0], &"shove_started")
	await _press(ps[0], 30, [0, 12])  # 0.2 s apart, cooldown 0.6 s
	assert_eq(started.size(), 1, "second press during cooldown ignored")
	assert_eq(_rec[ps[1]].impulses.size(), 1, "one impulse")
	await _press(ps[0], 30, [10])     # 40 frames = 0.67 s after the first press
	assert_eq(started.size(), 2, "shove again after the cooldown")
	assert_eq(_rec[ps[1]].impulses.size(), 2, "hit again by the second shove")


func test_two_victims_both_hit_once() -> void:
	var ps: Array[Player] = await _arena()
	_put(ps[1], Vector3(1.0, 0, 0.45))
	_put(ps[2], Vector3(1.0, 0, -0.45))
	var hits := watch(ps[0], &"shove_hit")
	await _press(ps[0], 30)
	assert_eq(hits.size(), 2, "two shove_hit events")
	var a := _rec[ps[1]].impulses
	var b := _rec[ps[2]].impulses
	if assert_eq(a.size(), 1, "left victim one impulse") and assert_eq(b.size(), 1, "right victim one impulse"):
		assert_true(a[0].x > 0.0 and b[0].x > 0.0, "both pushed forward")
		assert_true(a[0].z > 0.0 and b[0].z < 0.0, "side victims pushed outward")


func test_disabled_does_nothing() -> void:
	var ps: Array[Player] = await _arena()
	_put(ps[1], Vector3(1.0, 0, 0))
	(ps[0].get_component(&"shove") as ShoveComponent).enabled = false
	var started := watch(ps[0], &"shove_started")
	await _press(ps[0], 30)
	assert_eq(started.size(), 0, "no shove while disabled")
	assert_eq(_rec[ps[1]].impulses.size(), 0, "no impulse while disabled")


func test_frozen_or_locked_shover_cannot_shove() -> void:
	var ps: Array[Player] = await _arena()
	_put(ps[1], Vector3(1.0, 0, 0))
	var started := watch(ps[0], &"shove_started")
	ps[0].frozen = true
	await _press(ps[0], 5)
	ps[0].frozen = false
	ps[0].control_locked = true
	await _press(ps[0], 5)
	assert_eq(started.size(), 0, "no shove while frozen or locked")
	assert_eq(_rec[ps[1]].impulses.size(), 0, "no impulse while frozen or locked")
	ps[0].control_locked = false
	await _press(ps[0], 5)
	assert_eq(started.size(), 1, "shoves once free again")


func test_dead_victim_not_hit() -> void:
	var ps: Array[Player] = await _arena()
	_put(ps[1], Vector3(1.0, 0, 0))
	ps[1].eliminate(&"test")
	await step(1)
	var hits := watch(ps[0], &"shove_hit")
	await _press(ps[0], 30)
	assert_eq(hits.size(), 0, "no shove_hit on a dead player")
	assert_eq(_rec[ps[1]].impulses.size(), 0, "dead player gets no impulse")


func test_shover_lunges_forward() -> void:
	var ps: Array[Player] = await _arena()
	var shover := ps[0]
	await _press(shover, 20)
	var moved := shover.global_position.x
	var shove := shover.get_component(&"shove") as ShoveComponent
	assert_true(moved > shove.lunge * 0.5 and moved < shove.lunge * 2.0, "lunged forward (%f m)" % moved)
	assert_near(shover.global_position.z, 0.0, 0.01, "lunge stays on the facing axis")
