extends GameTest
## Body size (loadout key `size`): the loadout data, the `size` player component (looks,
## capsule, tuning multipliers stacked on the minigame's base values), remote copies.

const CatalogData := preload("res://cosmetics/catalog.gd")
const DEV_ARENA := "res://dev/dev_arena.tscn"


func _size_of(p: Player) -> SizeComponent:
	return p.get_component(&"size") as SizeComponent


func _set_size(p: Player, id: String) -> void:
	var l := p.loadout.duplicate()
	l["size"] = id
	p.loadout = l


func _capsule(p: Player) -> CapsuleShape3D:
	return (p.get_node(^"CollisionShape3D") as CollisionShape3D).shape as CapsuleShape3D


# --- Loadout ---------------------------------------------------------------------------------

func test_loadout_size_key() -> void:
	assert_eq(Cosmetics.default_loadout(3)["size"], "normal", "default size")
	assert_eq(Cosmetics.sanitize({"size": "big"})["size"], "big", "valid size kept")
	assert_eq(Cosmetics.sanitize({"size": "huge"})["size"], "normal", "unknown size -> fallback")
	assert_eq(Cosmetics.sanitize({"size": 3})["size"], "normal", "non-string size -> fallback")
	assert_eq(Cosmetics.sanitize({})["size"], "normal", "missing size -> fallback")
	var ids: Array = Cosmetics.sizes().map(func(e: Dictionary) -> String: return e["id"])
	assert_eq(ids, ["small", "normal", "big"], "wardrobe order")
	for e: Dictionary in Cosmetics.sizes():
		assert_true(String(e["blurb"]) != "", "%s has a trade-off line" % e["id"])
	assert_eq(Cosmetics.size_info("nope")["id"], "normal", "unknown -> normal")
	var normal := Cosmetics.size_info("normal")
	for key in ["scale", "speed", "jump", "shove", "reach", "knockback"]:
		assert_eq(float(normal[key]), 1.0, "normal %s is 1" % key)


# --- Component ---------------------------------------------------------------------------------

func test_normal_size_changes_nothing() -> void:
	var ps := spawn_arena(1)
	await step(2)
	var p := ps[0]
	assert_eq((p.get_component(&"movement") as MovementComponent).max_speed, 6.0, "speed untouched")
	assert_eq((p.get_component(&"status") as StatusComponent).knockback_multiplier, 1.0, "knockback untouched")
	assert_eq(p.get_component(&"visuals").scale, Vector3.ONE, "visual scale 1")
	assert_near(_capsule(p).radius, 0.4, 0.0001, "capsule radius")


func test_sizes_scale_looks_capsule_and_tuning() -> void:
	var ps := spawn_arena(3)
	_set_size(ps[1], "small")
	_set_size(ps[2], "big")
	await step(30)
	for i in [1, 2]:
		var p := ps[i]
		var e := Cosmetics.size_info(p.loadout["size"])
		var s: float = e["scale"]
		assert_near(p.get_component(&"visuals").scale, Vector3.ONE * s, 0.001, "%s visual scale" % e["id"])
		assert_near(_capsule(p).radius, 0.4 * s, 0.0001, "%s capsule radius" % e["id"])
		assert_near(_capsule(p).height, 1.0 * s, 0.0001, "%s capsule height" % e["id"])
		assert_near((p.get_node(^"CollisionShape3D") as Node3D).position.y, 0.5 * s, 0.0001, "%s capsule feet on the floor" % e["id"])
		assert_near((p.get_component(&"movement") as MovementComponent).max_speed, 6.0 * e["speed"], 0.0001, "speed")
		assert_near((p.get_component(&"jump") as JumpComponent).jump_height, 1.3 * e["jump"], 0.0001, "jump")
		assert_near((p.get_component(&"shove") as ShoveComponent).force, 10.0 * SizeComponent.effective(e, "shove"), 0.0001, "shove force")
		assert_near((p.get_component(&"shove") as ShoveComponent).reach, 1.3 * e["reach"], 0.0001, "reach")
		assert_near((p.get_component(&"status") as StatusComponent).knockback_multiplier, SizeComponent.effective(e, "knockback"), 0.0001, "knockback")
		assert_near((p.get_component(&"fx") as FxComponent).head_height, 1.12 * s, 0.0001, "fx head height")
		assert_near(_size_of(p).base_of(&"movement", &"max_speed"), 6.0, 0.0001, "base kept")
	# The shared scene capsule is never touched.
	assert_near(_capsule(ps[0]).radius, 0.4, 0.0001, "normal player keeps the scene capsule")
	# Back to normal: the base values come back exactly.
	_set_size(ps[2], "normal")
	await step(30)
	assert_eq((ps[2].get_component(&"movement") as MovementComponent).max_speed, 6.0, "base restored")
	assert_eq((ps[2].get_component(&"status") as StatusComponent).knockback_multiplier, 1.0, "base restored")
	assert_near(_capsule(ps[2]).radius, 0.4, 0.0001, "capsule restored")


func test_stacks_on_bumper_sumo_tuning() -> void:
	var ps := spawn_arena(4, &"bumper_sumo")
	_set_size(ps[1], "big")
	_set_size(ps[2], "small")
	await step(2)
	var big := CatalogData.size_entry("big")
	var small := CatalogData.size_entry("small")
	assert_near((ps[1].get_component(&"status") as StatusComponent).knockback_multiplier,
		BumperSumo.KNOCKBACK_MULTIPLIER * SizeComponent.effective(big, "knockback"), 0.0001, "sumo knockback x big")
	assert_near((ps[1].get_component(&"shove") as ShoveComponent).force,
		BumperSumo.SHOVE_FORCE * SizeComponent.effective(big, "shove"), 0.0001, "sumo shove force x big")
	assert_near((ps[2].get_component(&"status") as StatusComponent).knockback_multiplier,
		BumperSumo.KNOCKBACK_MULTIPLIER * SizeComponent.effective(small, "knockback"), 0.0001, "sumo knockback x small")
	assert_eq((ps[1].get_component(&"shove") as ShoveComponent).cooldown, BumperSumo.SHOVE_COOLDOWN, "unscaled tuning untouched")
	# A later absolute retune becomes the new base and is scaled again.
	(ps[1].get_component(&"status") as StatusComponent).knockback_multiplier = 2.0
	await step(1)
	assert_near((ps[1].get_component(&"status") as StatusComponent).knockback_multiplier, 2.0 * SizeComponent.effective(big, "knockback"), 0.0001, "retune rescaled")
	assert_near(_size_of(ps[1]).base_of(&"status", &"knockback_multiplier"), 2.0, 0.0001, "new base")


func test_per_frame_retune_is_scaled_before_movement() -> void:
	# Hot Potato style: the minigame writes an absolute speed every frame, earlier in the frame
	# than the players tick. Movement must still run at speed x factor.
	var ps := spawn_arena(1)
	_set_size(ps[0], "small")
	var move := ps[0].get_component(&"movement") as MovementComponent
	var used: Array[float] = []
	await step(20, func(_i: int) -> void:
		move.max_speed = 7.0
		ps[0].intent.move = Vector2.RIGHT)
	used.append(ps[0].velocity.length())
	var small: float = CatalogData.size_entry("small")["speed"]
	assert_near(used[0], 7.0 * small, 0.05, "runs at the retuned speed x small")
	assert_near(move.max_speed, 7.0 * small, 0.0001, "no compounding")


func test_frozen_restores_base_values() -> void:
	# While frozen (a minigame's _setup, the countdown) every factor is 1.
	var ps := spawn_arena(1)
	_set_size(ps[0], "big")
	await step(2)
	var status := ps[0].get_component(&"status") as StatusComponent
	assert_near(status.knockback_multiplier, SizeComponent.effective(CatalogData.size_entry("big"), "knockback"), 0.0001, "scaled while playing")
	ps[0].frozen = true
	await step(30)
	assert_eq(status.knockback_multiplier, 1.0, "base while frozen")
	assert_near(ps[0].get_component(&"visuals").scale, Vector3.ONE * 1.22, 0.001, "still looks big while frozen")
	ps[0].frozen = false
	await step(2)
	assert_near(status.knockback_multiplier, SizeComponent.effective(CatalogData.size_entry("big"), "knockback"), 0.0001, "scaled again")


func test_small_is_faster_and_flies_further() -> void:
	var ps := spawn_arena(3)
	ps[0].place_at(Transform3D(Basis.IDENTITY, Vector3(-4, 0, -3)))
	ps[1].place_at(Transform3D(Basis.IDENTITY, Vector3(-4, 0, 0)))
	ps[2].place_at(Transform3D(Basis.IDENTITY, Vector3(-4, 0, 3)))
	_set_size(ps[1], "small")
	_set_size(ps[2], "big")
	await step(60, func(_i: int) -> void:
		for p in ps:
			p.intent.move = Vector2.RIGHT)
	var run := ps.map(func(p: Player) -> float: return p.global_position.x + 4.0)
	assert_true(run[1] > run[0] and run[0] > run[2], "small > normal > big in a 1 s dash (%s)" % str(run))
	# Same impulse to each (standing still): the small one slides furthest.
	for i in 3:
		ps[i].intent.move = Vector2.ZERO
		ps[i].place_at(Transform3D(Basis.IDENTITY, Vector3(-7, 0, -3 + 3 * i)))
	await step(30)
	var start := ps.map(func(p: Player) -> float: return p.global_position.x)
	for p in ps:
		p.apply_impulse(Vector3(8.0, 2.0, 0.0))
	await step(90)
	var slid := []
	for i in 3:
		slid.append(ps[i].global_position.x - float(start[i]))
	assert_true(slid[1] > slid[0] and slid[0] > slid[2], "small slides furthest, big least (%s)" % str(slid))


func test_big_reaches_further() -> void:
	# No lunge, so the reach alone decides: halfway between the normal and the big reach.
	var ps := spawn_arena(2)
	var shove := ps[0].get_component(&"shove") as ShoveComponent
	shove.lunge = 0.0
	var gap := shove.reach * (1.0 + float(CatalogData.size_entry("big")["reach"])) * 0.5
	assert_true(gap - shove.reach > 0.02, "big reach is noticeably longer")
	ps[0].place_at(Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)))
	ps[1].place_at(Transform3D(Basis.IDENTITY, Vector3(0, 0, gap)))
	await step(10)
	var hits := watch(ps[0], &"shove_hit")
	await step(1, func(_i: int) -> void: ps[0].intent.action_pressed = true)
	await step(20, func(_i: int) -> void: ps[0].intent.action_pressed = false)
	assert_eq(hits.size(), 0, "normal reach misses at %.2f m" % gap)
	_set_size(ps[0], "big")
	ps[0].place_at(Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)))
	ps[1].place_at(Transform3D(Basis.IDENTITY, Vector3(0, 0, gap)))
	await step(40)
	await step(1, func(_i: int) -> void: ps[0].intent.action_pressed = true)
	await step(20, func(_i: int) -> void: ps[0].intent.action_pressed = false)
	assert_eq(hits.size(), 1, "big reach hits at %.2f m" % gap)


# --- Every peer ---------------------------------------------------------------------------------

func test_remote_copy_sized_on_spawn_and_follows_lobby_change() -> void:
	Net.start_offline()
	stage = STAGE_SCENE.instantiate() as Stage
	add_child(stage)
	var info := PlayerInfo.new(3, 5, "Remote", false, {"size": "big"}).to_dict()
	info["spawn"] = 0
	stage.apply_manifest(7, DEV_ARENA, false, [info])
	var p := stage.get_player(3)
	assert_false(p.is_authority(), "a remote copy")
	# No frame has run yet: the size is there from the spawn.
	assert_near(p.get_component(&"visuals").scale, Vector3.ONE * 1.22, 0.001, "big on spawn")
	assert_near(_capsule(p).radius, 0.4 * 1.22, 0.0001, "big capsule on spawn")
	# The lobby changes the loadout (roster -> Stage -> Player.loadout): the copy follows.
	var changed := PlayerInfo.new(3, 5, "Remote", false, {"size": "small"}).to_dict()
	changed["spawn"] = 0
	stage.apply_manifest(7, DEV_ARENA, false, [changed])
	await step(40)
	assert_near(p.get_component(&"visuals").scale, Vector3.ONE * 0.82, 0.001, "small after the change")
	assert_near(_capsule(p).radius, 0.4 * 0.82, 0.0001, "small capsule after the change")


# --- Wardrobe Body tab ---------------------------------------------------------------------------

const TEST_PROFILE := "user://test_size_profile.json"


func _open_wardrobe() -> Wardrobe:
	Net.leave()
	Cosmetics.profile_path = TEST_PROFILE
	for suffix: String in ["", ".bak", ".tmp", ".corrupt"]:  # the profile and its crash-safe save sidecars
		if FileAccess.file_exists(TEST_PROFILE + suffix):
			DirAccess.remove_absolute(TEST_PROFILE + suffix)
	var w := (load("res://ui/wardrobe/wardrobe.tscn") as PackedScene).instantiate() as Wardrobe
	add_child(w)
	await step(2)
	return w


func _close_wardrobe(w: Wardrobe) -> void:
	remove_child(w)
	w.queue_free()
	Net.leave()
	Cosmetics.profile_path = Cosmetics.PROFILE_PATH
	for suffix: String in ["", ".bak", ".tmp", ".corrupt"]:  # the profile and its crash-safe save sidecars
		if FileAccess.file_exists(TEST_PROFILE + suffix):
			DirAccess.remove_absolute(TEST_PROFILE + suffix)


func test_wardrobe_body_tab_picks_size() -> void:
	var w := await _open_wardrobe()
	assert_true(Wardrobe.TABS.has(&"body"), "Body tab exists")
	w.open_tab(&"body")
	assert_eq(w.size_tiles.size(), 3, "three size tiles")
	assert_true(w.get_size_tile("normal").button_pressed, "normal chosen by default")
	var changes := watch(w, &"loadout_changed")
	w.get_size_tile("big").pressed.emit()
	assert_eq(w.loadout["size"], "big", "tile picks the size")
	assert_true(w.get_size_tile("big").button_pressed and not w.get_size_tile("normal").button_pressed, "one tile chosen")
	assert_eq(changes.size(), 1, "loadout_changed")
	assert_false(w.select_size("huge"), "unknown size refused")
	await step(60)
	assert_near(w.preview.get_body_scale(), 1.22, 0.01, "preview scales live")
	w.randomise()
	assert_eq(w.loadout["size"], "big", "randomise keeps the size")
	w.reset()
	assert_eq(w.loadout["size"], "big", "reset keeps the size")
	# Keyboard/pad: the tiles are linked left/right and down to Done.
	w._link_focus()
	var small := w.get_size_tile("small")
	assert_eq(small.get_node(small.focus_neighbor_right), w.get_size_tile("normal"), "right neighbour")
	assert_eq(small.get_node(small.focus_neighbor_bottom), w.done_button, "down to Done")
	w.done()
	assert_eq(Cosmetics.load_profile()["loadout"]["size"], "big", "saved in the profile")
	_close_wardrobe(w)


func test_name_tag_height_follows_size() -> void:
	var p := (load("res://player/player.tscn") as PackedScene).instantiate() as Player
	p.loadout = {"size": "small"}
	add_child(p)
	var tag := (load("res://ui/round/name_tag.tscn") as PackedScene).instantiate() as NameTag
	tag.name = "NameTag"
	p.add_child(tag)
	tag.setup(p)
	await step(2)
	assert_near(tag.height, 1.55 * 0.82, 0.0001, "tag lowered for a small blob")
	_set_size(p, "big")
	await step(2)
	assert_near(tag.height, 1.55 * 1.22, 0.0001, "tag raised for a big blob")
	p.queue_free()
