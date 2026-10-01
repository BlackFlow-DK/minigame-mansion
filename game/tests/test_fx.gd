extends GameTest
## Look and effects: the Fx autoload pool, the player fx component, Look.apply_toon,
## the quality switch, StageLook presets and the blob shadow.

const STAGE_LOOK: PackedScene = preload("res://look/stage_look.tscn")

var _fx: Node


func before_each() -> void:
	_fx = get_node(^"/root/Fx")
	_fx.clear()


func after_each() -> void:
	_fx.set(&"headless_spawn", false)
	_fx.clear()
	Look.set_quality(Look.Quality.HIGH)


# --- Fx autoload -------------------------------------------------------------------------

func test_every_effect_spawns_plays_and_pools() -> void:
	_fx.set(&"headless_spawn", true)
	var first: Dictionary = {}
	var longest := 0.0
	for effect: StringName in FxLibrary.NAMES:
		var node := _fx.call(&"play", effect, Vector3(1, 0.5, -2), Look.RED) as FxEffect
		if not assert_true(node != null, "%s spawned" % effect):
			continue
		assert_true(node.is_inside_tree(), "%s in tree" % effect)
		assert_true(node.playing and node.visible, "%s playing" % effect)
		assert_near(node.global_position, Vector3(1, 0.5, -2), 0.001, "%s position" % effect)
		first[effect] = node
		longest = maxf(longest, node.duration)
	assert_eq(_fx.call(&"live_count"), FxLibrary.NAMES.size(), "all live")
	await step(ceili(longest * 60.0) + 10)
	assert_eq(_fx.call(&"live_count"), 0, "all finished")
	for effect: StringName in FxLibrary.NAMES:
		assert_eq(_fx.call(&"idle_count", effect), 1, "%s back in the pool" % effect)
		var again := _fx.call(&"play", effect, Vector3.ZERO) as FxEffect
		assert_true(again == first.get(effect), "%s reused from the pool" % effect)
	_fx.call(&"stop_all")
	assert_eq(_fx.call(&"live_count"), 0, "stop_all")


func test_pool_is_capped() -> void:
	_fx.set(&"headless_spawn", true)
	for i in 25:
		_fx.call(&"play", &"dust_puff", Vector3.ZERO)
	var cap: int = _fx.get(&"POOL_MAX")
	assert_eq(_fx.call(&"live_count", &"dust_puff"), cap, "live dust puffs")
	assert_eq(_fx.get_child_count(), cap, "nodes built")


func test_unknown_effect_warns_and_plays_nothing() -> void:
	_fx.set(&"headless_spawn", true)
	var played := watch(_fx, &"played")
	assert_true(_fx.call(&"play", &"no_such_effect", Vector3.ZERO) == null, "null for unknown")
	assert_true(_fx.call(&"play", &"no_such_effect", Vector3.ZERO) == null, "still null")
	assert_eq(played.size(), 0, "no played signal")
	assert_eq(_fx.get_child_count(), 0, "no node")


func test_headless_default_is_a_noop_that_still_signals() -> void:
	var played := watch(_fx, &"played")
	assert_true(_fx.call(&"play", &"explosion", Vector3.ONE, Look.GOLD) == null, "no node headless")
	assert_eq(_fx.get_child_count(), 0, "nothing spawned")
	assert_eq(played.size(), 1, "played raised")
	if played.size() == 1:
		assert_eq(played[0][0], &"explosion", "effect")
		assert_eq(played[0][2], Look.GOLD, "color")


func test_stun_swirl_holds_and_follows() -> void:
	_fx.set(&"headless_spawn", true)
	var target := Node3D.new()
	add_child(target)
	var swirl := _fx.call(&"play", &"stun_swirl", Vector3.ZERO) as FxEffect
	swirl.hold(3.0, target, Vector3.UP)
	target.position = Vector3(2, 0, 1)
	await step(150)  # 2.5 s: past the default 1.5 s, inside the hold
	assert_true(swirl.playing, "still playing while held")
	assert_near(swirl.global_position, Vector3(2, 1, 1), 0.001, "follows the target")
	target.queue_free()
	await step(2)
	assert_false(swirl.playing, "stops when the target goes")


# --- Player fx component -------------------------------------------------------------------

func test_component_reacts_to_every_event() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	p.loadout["primary"] = "#d9483b"
	ps[1].loadout["primary"] = "#3f7fd9"
	var played := watch(_fx, &"played")
	var before_velocity := p.velocity
	var cases: Array = [
		[&"jumped", [], [&"dust_puff"]],
		[&"landed", [14.0], [&"land_thud"]],
		[&"landed", [4.0], [&"dust_puff"]],
		[&"landed", [1.0], []],
		[&"shove_started", [], [&"shove_whoosh"]],
		[&"got_hit", [Vector3(6, 0, 0), 1], [&"hit_stars"]],
		[&"got_hit", [Vector3(0, 0, 6), -1], [&"hit_stars"]],
		[&"stunned", [1.2], [&"stun_swirl"]],
		[&"eliminated", [&"fell"], [&"poof", &"shockwave", &"ko_tag"]],
		[&"eliminated", [&"lava"], [&"splash_lava", &"poof", &"shockwave", &"ko_tag"]],
		[&"eliminated", [&"cannon"], [&"explosion", &"poof", &"shockwave", &"ko_tag"]],
		[&"respawned", [Transform3D(Basis.IDENTITY, Vector3(3, 0, 3))], [&"respawn_sparkle", &"shockwave"]],
	]
	for c: Array in cases:
		played.clear()
		p.emit_event(c[0], c[1])
		var names: Array = played.map(func(a: Array) -> StringName: return a[0])
		assert_eq(names, c[2], "effects for %s%s" % [c[0], c[1]])
	# colours: own colour on the shove, the attacker's on the hit, gold when nobody hit
	played.clear()
	p.emit_event(&"shove_started")
	p.emit_event(&"got_hit", [Vector3(6, 0, 0), 1])
	p.emit_event(&"got_hit", [Vector3(6, 0, 0), -1])
	assert_true((played[0][2] as Color).is_equal_approx(Look.RED), "shove in own colour")
	assert_true((played[1][2] as Color).is_equal_approx(Look.BLUE), "hit in attacker colour")
	assert_true((played[2][2] as Color).is_equal_approx(Look.GOLD), "hit without attacker")
	# never touches gameplay state
	assert_eq(p.velocity, before_velocity, "velocity untouched")
	assert_true(p.alive and not p.frozen and not p.control_locked, "state untouched")


func test_component_puffs_dust_while_running() -> void:
	var ps := spawn_arena(1)
	var p := ps[0]
	var played := watch(_fx, &"played")
	await step(90, func(_i: int) -> void:
		p.intent.move = Vector2.RIGHT
		p.velocity = Vector3(5, -1, 0))
	var dust := played.filter(func(a: Array) -> bool: return a[0] == &"dust_puff")
	assert_true(dust.size() >= 3, "footstep dust while running (%d)" % dust.size())
	played.clear()
	await step(60, func(_i: int) -> void:
		p.intent.move = Vector2.ZERO
		p.velocity = Vector3(0, -1, 0))
	assert_eq(played.size(), 0, "no dust standing still")


# --- Look ----------------------------------------------------------------------------------

func test_apply_toon_keeps_surface_colours() -> void:
	var root := Node3D.new()
	add_child(root)
	# two surfaces with mesh materials, as imported from a glb
	var arr := ArrayMesh.new()
	var box := BoxMesh.new()
	var colours: Array[Color] = [Color("#58b368"), Color("#f08fb0")]
	for i in 2:
		arr.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
		var m := StandardMaterial3D.new()
		m.albedo_color = colours[i]
		m.resource_name = "PlayerPrimary" if i == 0 else "Eyes"
		m.roughness = 1.0
		arr.surface_set_material(i, m)
	var multi := MeshInstance3D.new()
	multi.mesh = arr
	root.add_child(multi)
	# one with a material_override, one unshaded (left alone)
	var over := MeshInstance3D.new()
	over.mesh = SphereMesh.new()
	var om := StandardMaterial3D.new()
	om.albedo_color = Color("#3f7fd9")
	over.material_override = om
	root.add_child(over)
	var flat := MeshInstance3D.new()
	flat.mesh = SphereMesh.new()
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flat.material_override = fm
	multi.add_child(flat)

	assert_eq(Look.apply_toon(root), 3, "surfaces changed")
	for i in 2:
		var m := multi.get_active_material(i) as StandardMaterial3D
		if not assert_true(m != null, "surface %d still a StandardMaterial3D" % i):
			continue
		assert_eq(m.albedo_color, colours[i], "surface %d colour" % i)
		assert_eq(m.diffuse_mode, BaseMaterial3D.DIFFUSE_TOON, "surface %d toon" % i)
		assert_true(m.rim_enabled, "surface %d rim" % i)
		assert_true(m.next_pass == Look.outline_material(), "surface %d outline" % i)
		assert_true(m != arr.surface_get_material(i), "surface %d is a copy" % i)
	assert_eq((multi.get_active_material(0) as StandardMaterial3D).resource_name, "PlayerPrimary", "name kept")
	assert_eq((over.material_override as StandardMaterial3D).albedo_color, Color("#3f7fd9"), "override colour")
	assert_true(flat.material_override == fm, "unshaded left alone")
	assert_eq(Look.apply_toon(root), 0, "idempotent")

	# another system recolours later: in place ...
	var active := multi.get_active_material(0) as StandardMaterial3D
	active.albedo_color = Color("#e8b33a")
	assert_eq((multi.get_active_material(0) as StandardMaterial3D).albedo_color, Color("#e8b33a"), "recolour in place")
	assert_eq((multi.get_active_material(0) as StandardMaterial3D).diffuse_mode, BaseMaterial3D.DIFFUSE_TOON, "still toon")
	# ... or through a recoloured copy
	var copy := active.duplicate() as StandardMaterial3D
	copy.albedo_color = Color("#2fa7a0")
	multi.set_surface_override_material(0, copy)
	var now := multi.get_active_material(0) as StandardMaterial3D
	assert_eq(now.albedo_color, Color("#2fa7a0"), "recoloured copy")
	assert_eq(now.diffuse_mode, BaseMaterial3D.DIFFUSE_TOON, "copy still toon")
	assert_true(now.next_pass == Look.outline_material(), "copy keeps the outline")
	assert_eq(Look.apply_toon(root), 0, "copy counts as toon")
	# a brand-new material gets the look back from a second apply_toon, colour intact
	var fresh := StandardMaterial3D.new()
	fresh.albedo_color = Color("#6d4a7c")
	multi.set_surface_override_material(1, fresh)
	Look.apply_toon(root)
	var back := multi.get_active_material(1) as StandardMaterial3D
	assert_eq(back.albedo_color, Color("#6d4a7c"), "fresh colour kept")
	assert_eq(back.diffuse_mode, BaseMaterial3D.DIFFUSE_TOON, "fresh made toon")
	root.queue_free()


func test_outline_mesh_is_smoothed_cached_and_opts_out_thin_parts() -> void:
	# a hard-edged box: 24 vertices, 3 normals per corner; one shared baked copy per source
	var box := BoxMesh.new()
	box.size = Vector3(0.4, 0.4, 0.4)
	var mat := StandardMaterial3D.new()
	mat.resource_name = "PlayerPrimary"
	box.material = mat
	var a := MeshInstance3D.new()
	a.mesh = box
	var b := MeshInstance3D.new()
	b.mesh = box
	add_child(a)
	add_child(b)
	assert_eq(Look.prepare_outline(a), 1.0, "solid box outlined")
	Look.prepare_outline(b)
	assert_true(a.mesh != box and a.mesh == b.mesh, "one cached copy per source mesh")
	assert_eq(Look.prepare_outline(a), 1.0, "idempotent")
	assert_true(a.mesh.surface_get_material(0) == mat, "surface material kept (tinting by name still works)")
	var arrays := a.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var custom: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	assert_eq(custom.size(), verts.size() * 4, "CUSTOM0 per vertex")
	# every copy of a corner pushes the same way: along the corner diagonal, no tearing
	for i in verts.size():
		var n := Vector3(custom[i * 4], custom[i * 4 + 1], custom[i * 4 + 2])
		var diag := verts[i].sign().normalized()
		assert_near(n, diag, 0.01, "smoothed normal at %s" % verts[i])
		assert_eq(custom[i * 4 + 3], 1.0, "weight")
	# thin plate (a lid, a cheek, cloth) and tiny part (a pupil): no hull
	var plate := MeshInstance3D.new()
	var thin := BoxMesh.new()
	thin.size = Vector3(0.5, 0.01, 0.5)
	plate.mesh = thin
	add_child(plate)
	assert_eq(Look.prepare_outline(plate), 0.0, "thin plate opts out")
	var dot := MeshInstance3D.new()
	var tiny := SphereMesh.new()
	tiny.radius = 0.02
	tiny.height = 0.04
	dot.mesh = tiny
	add_child(dot)
	assert_eq(Look.prepare_outline(dot), 0.0, "tiny part opts out")
	# node scale counts: the same plate scaled up 10x is thick enough
	var big := MeshInstance3D.new()
	big.mesh = thin
	big.scale = Vector3.ONE * 10.0
	add_child(big)
	assert_eq(Look.prepare_outline(big), 1.0, "scaled-up plate outlined")
	for n: Node in [a, b, plate, dot, big]:
		n.queue_free()


func test_toon_copies_are_shared_and_freeing_models_logs_nothing() -> void:
	# The dummy renderer logs "material is null" when a material dies with its node; toon
	# copies are cached per source material, so freeing toon'd models is silent (the harness
	# fails this test on any engine error).
	var blob := load("res://assets/models/character/blob.glb") as PackedScene
	var models: Array[Node3D] = []
	for i in 3:
		var m := blob.instantiate() as Node3D
		add_child(m)
		Look.apply_toon(m)
		models.append(m)
	var a := models[0].find_child("PupilR", true, false) as MeshInstance3D
	var b := models[1].find_child("PupilR", true, false) as MeshInstance3D
	assert_true(a.get_active_material(0).has_meta(Look.TOON_META), "toon applied")
	assert_true(a.get_active_material(0) == b.get_active_material(0), "one toon copy per source material")
	assert_true(Look.toon_material(Look.RED) == Look.toon_material(Look.RED), "toon_material shared per colour")
	for m in models:
		m.queue_free()
	await step(4)


func test_quality_switch_drops_outline_and_post() -> void:
	var look := STAGE_LOOK.instantiate() as StageLook
	add_child(look)
	var m := Look.toon_material(Look.PINK)
	assert_true(m.next_pass != null, "outline on HIGH")
	assert_true(look.world_environment.environment.ssao_enabled, "SSAO on HIGH")
	assert_true(look.world_environment.environment.glow_enabled, "glow on HIGH")
	Look.set_quality(Look.Quality.LOW)
	assert_true(m.next_pass == null, "outline off on LOW")
	assert_false(look.world_environment.environment.ssao_enabled, "SSAO off on LOW")
	assert_false(look.world_environment.environment.glow_enabled, "glow off on LOW")
	assert_true(Look.toon_material(Look.PINK).next_pass == null, "new materials LOW")
	Look.set_quality(Look.Quality.HIGH)
	assert_true(m.next_pass == Look.outline_material(), "outline back on HIGH")
	assert_true(look.world_environment.environment.ssao_enabled, "SSAO back")
	look.queue_free()


func test_stage_look_presets_apply() -> void:
	var look := STAGE_LOOK.instantiate() as StageLook
	add_child(look)
	var seen: Dictionary = {}
	for preset: int in StageLook.Preset.values():
		look.preset = preset as StageLook.Preset
		var env := look.world_environment.environment
		assert_true(env != null and env.sky != null, "environment for preset %d" % preset)
		assert_true(look.key_light.shadow_enabled, "key shadows for preset %d" % preset)
		assert_false(look.fill_light.shadow_enabled, "fill has no shadows")
		seen[(env.sky.sky_material as ProceduralSkyMaterial).sky_top_color] = true
	assert_eq(seen.size(), StageLook.Preset.size(), "each preset has its own sky")
	look.queue_free()


func test_blob_shadow_lands_under_its_parent() -> void:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10, 1, 10)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	var hopper := Node3D.new()
	add_child(hopper)
	hopper.position = Vector3(1, 0.0, 2)
	var shadow := BlobShadow.new()
	hopper.add_child(shadow)
	await step(3)
	assert_true(shadow.visible, "visible on the floor")
	assert_near(shadow.global_position, Vector3(1, 0.015, 2), 0.01, "on the floor under the parent")
	var near_size := shadow.global_basis.get_scale().x
	hopper.position.y = 3.0
	await step(3)
	assert_near(shadow.global_position, Vector3(1, 0.015, 2), 0.01, "stays on the floor while in the air")
	assert_true(shadow.global_basis.get_scale().x < near_size, "smaller when high")
	hopper.position = Vector3(40, 1, 0)
	await step(3)
	assert_false(shadow.visible, "hidden over nothing")
	hopper.queue_free()
	floor_body.queue_free()
