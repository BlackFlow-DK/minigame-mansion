extends GameTest
## Visuals component: the real blob model, a reaction for every player event, squash that
## settles back to identity, emotes and look target, and remote (non-authority) copies that
## animate from replicated position/facing and relayed events alone.


func _vis(p: Player) -> VisualsComponent:
	return p.get_component(&"visuals") as VisualsComponent


func _root_basis(p: Player) -> Basis:
	return _vis(p).get_model_root().transform.basis


## True when the model root is back at identity (scale 1,1,1, no squash).
func _at_rest(p: Player) -> bool:
	var b := _root_basis(p)
	return (b.x - Vector3.RIGHT).length() < 0.002 and (b.y - Vector3.UP).length() < 0.002 \
		and (b.z - Vector3.BACK).length() < 0.002


func _rest_of(part: String) -> Vector3:
	var model := BlobRig.SCENE.instantiate() as Node3D
	var pos := (model.get_node(part) as Node3D).position
	model.free()
	return pos


func _hold_jump(p: Player) -> Callable:
	return func(i: int) -> void:
		p.intent.jump_pressed = i == 0
		p.intent.jump_held = true


func test_model_has_all_parts_and_sockets() -> void:
	var p := spawn_arena(1)[0]
	var vis := _vis(p)
	var root := vis.get_model_root()
	if not assert_true(root != null, "model root exists"):
		return
	assert_true(root.is_ancestor_of(root.get_node("Body")), "model is under the root")
	for n in BlobRig.PARTS:
		assert_true(root.get_node_or_null(NodePath(String(n))) is Node3D, "part %s" % n)
	var sockets := {
		"HatSocket": Vector3(0.0, 1.0, 0.0), "FaceSocket": Vector3(0.0, 0.68, 0.37),
		"NeckSocket": Vector3(0.0, 0.40, 0.0), "BackSocket": Vector3(0.0, 0.50, -0.37),
	}
	for s: String in sockets:
		var node := root.get_node_or_null(s) as Node3D
		if assert_true(node != null, "socket %s" % s):
			assert_near(node.position, sockets[s], 0.001, "socket %s position" % s)
	assert_true(vis.find_child("Placeholder", true, false) == null, "placeholder capsule is gone")


## The surface of `mesh` that uses `material_name` as shown now (override or mesh material).
func _shown(mesh: MeshInstance3D, material_name: String) -> BaseMaterial3D:
	for i in mesh.mesh.get_surface_count():
		var src := mesh.mesh.surface_get_material(i)
		if src and src.resource_name == material_name:
			return mesh.get_active_material(i) as BaseMaterial3D
	return null


## Every surface under `node` shows a toon material.
func _all_toon(node: Node) -> bool:
	var meshes: Array[Node] = node.find_children("*", "MeshInstance3D", true, false)
	if node is MeshInstance3D:
		meshes.append(node)
	for n in meshes:
		var mi := n as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var m := mi.get_active_material(i)
			if m is BaseMaterial3D and not m.has_meta(Look.TOON_META):
				return false
	return meshes.size() > 0


func test_cosmetics_dress_the_model_toon_shaded() -> void:
	var p := spawn_arena(2)[0]
	await step(2)
	var root := _vis(p).get_model_root()
	var body := root.get_node("Body") as MeshInstance3D
	var primary := _shown(body, "PlayerPrimary")
	assert_true(primary.albedo_color.is_equal_approx(Color(str(p.loadout["primary"]))), "loadout colour shown")
	assert_true(primary.has_meta(Look.TOON_META), "tinted body is toon")
	var hat := root.get_node_or_null("HatSocket/Cosmetic_hat")
	if assert_true(hat != null, "default hat worn"):
		assert_true(_all_toon(hat), "hat is toon")
	assert_true(_all_toon(root), "whole dressed blob is toon")
	# Wardrobe/lobby change later: new colour and new items, still toon everywhere.
	var loadout := p.loadout.duplicate()
	loadout["primary"] = "#26306b"
	loadout["hat"] = "crown"
	loadout["face"] = "round_glasses"
	loadout["neck"] = "scarf"
	loadout["back"] = "cape"
	p.loadout = loadout
	await step(3)
	assert_true(_shown(body, "PlayerPrimary").albedo_color.is_equal_approx(Color("#26306b")), "new colour")
	for item: String in ["HatSocket/Cosmetic_hat", "FaceSocket/Cosmetic_face", "NeckSocket/Cosmetic_neck", "BackSocket/Cosmetic_back"]:
		assert_true(root.get_node_or_null(item) != null, "%s worn" % item)
	assert_true(_all_toon(root), "still toon after the change")


func test_pop_copy_keeps_tint_and_items() -> void:
	var p := spawn_arena(2)[0]
	await step(3)
	var colour := Color(str(p.loadout["primary"]))
	var before := p.get_parent().get_children()
	p.eliminate(&"test")
	await step(1)
	var ghost: Node3D = null
	for n in p.get_parent().get_children():
		if not before.has(n):
			ghost = n as Node3D
	if not assert_true(ghost != null, "pop copy exists"):
		return
	var body := ghost.get_node("Body") as MeshInstance3D
	assert_true(_shown(body, "PlayerPrimary").albedo_color.is_equal_approx(colour), "copy keeps the tint")
	assert_true(ghost.get_node_or_null("HatSocket/Cosmetic_hat") != null, "copy keeps the hat")
	assert_true(_all_toon(ghost), "copy is toon")


func test_idle_settles_at_rest_scale() -> void:
	var p := spawn_arena(1)[0]
	await step(90)
	assert_true(_at_rest(p), "idle model root at identity, got %s" % _root_basis(p))
	assert_eq(_vis(p).get_reaction(), &"idle", "reaction")
	assert_eq(_vis(p).get_expression(), &"neutral", "expression")


func test_jump_stretches_then_land_squashes_then_settles() -> void:
	var p := spawn_arena(1)[0]
	var vis := _vis(p)
	await step(20)
	var landed := watch(p, &"landed")
	var max_stretch := [0.0]
	await step(10, func(i: int) -> void:
		_hold_jump(p).call(i)
		max_stretch[0] = maxf(max_stretch[0], _root_basis(p).y.y))
	assert_eq(vis.get_reaction(), &"air", "airborne after take-off")
	assert_true(max_stretch[0] > 1.05, "take-off stretch (max y scale %f)" % max_stretch[0])
	# Hands go up while rising.
	assert_true(vis.get_model_root().get_node("HandL").position.y > 0.45, "hands up while rising")
	for i in 120:
		await step(1, func(_i: int) -> void: p.intent.jump_held = true)
		if landed.size() > 0:
			break
	assert_eq(landed.size(), 1, "landed")
	await step(1)  # step() returns after the physics tick; the visuals' _process runs a frame later
	assert_eq(vis.get_reaction(), &"land", "landing reaction")
	assert_true(_root_basis(p).y.y < 0.9, "landing squash (y scale %f)" % _root_basis(p).y.y)
	await step(90)
	assert_true(_at_rest(p), "scale back to (1,1,1) after landing, got %s" % _root_basis(p))


func test_shove_thrusts_hands_and_shouts() -> void:
	var p := spawn_arena(1)[0]
	var vis := _vis(p)
	await step(10)
	await step(6, func(i: int) -> void: p.intent.action_pressed = i == 0)
	assert_eq(vis.get_reaction(), &"shove", "shove reaction")
	assert_eq(vis.get_expression(), &"effort", "effort face")
	var root := vis.get_model_root()
	for hand: String in ["HandL", "HandR"]:
		assert_true((root.get_node(hand) as Node3D).position.z > 0.3, "%s thrust forward" % hand)
	assert_true((root.get_node("Mouth") as Node3D).scale.y > 1.3, "shout mouth")
	await step(90)
	assert_true(_at_rest(p), "scale back to (1,1,1) after the shove, got %s" % _root_basis(p))


func test_hit_then_stun_then_recovers() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var vis := _vis(p)
	await step(10)
	var got_hit := watch(p, &"got_hit")
	var stunned := watch(p, &"stunned")
	var toward_centre := -Vector3(p.global_position.x, 0.0, p.global_position.z).normalized()
	p.apply_impulse(toward_centre * 8.0 + Vector3.UP * 2.0, ps[1])
	await step(6)
	assert_eq(got_hit.size(), 1, "got_hit raised")
	assert_eq(stunned.size(), 1, "stunned raised")
	assert_eq(vis.get_reaction(), &"hit", "hit reaction")
	assert_eq(vis.get_expression(), &"hurt", "hurt face")
	var root := vis.get_model_root()
	assert_true((root.get_node("LidL") as Node3D).rotation.x > 1.4, "eyes squeezed shut")
	assert_false(_at_rest(p), "squashed by the hit")
	await step(16)
	assert_eq(vis.get_reaction(), &"stunned", "stun reaction")
	assert_eq(vis.get_expression(), &"dizzy", "dizzy face")
	await step(150)
	assert_true(vis.get_reaction() != &"stunned" and vis.get_reaction() != &"hit", "recovered (%s)" % vis.get_reaction())
	assert_true(_at_rest(p), "scale back to (1,1,1) after the stun, got %s" % _root_basis(p))


func test_eliminated_pops_and_respawn_pops_in() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var vis := _vis(p)
	await step(10)
	var siblings_before := p.get_parent().get_child_count()
	p.eliminate(&"test")
	await step(2)
	assert_eq(vis.get_reaction(), &"eliminated", "eliminated reaction")
	assert_eq(p.get_parent().get_child_count(), siblings_before + 1, "a pop copy is left in the world")
	await step(40)
	assert_eq(p.get_parent().get_child_count(), siblings_before, "pop copy frees itself")
	p.respawn_at(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	await step(2)
	assert_eq(vis.get_reaction(), &"respawn", "respawn reaction")
	assert_true(_root_basis(p).y.y < 0.9, "pops in from small (y scale %f)" % _root_basis(p).y.y)
	var peak := [0.0]
	await step(30, func(_i: int) -> void: peak[0] = maxf(peak[0], _root_basis(p).y.y))
	assert_true(peak[0] > 1.03, "pop-in overshoots (peak %f)" % peak[0])
	await step(90)
	assert_true(_at_rest(p), "scale back to (1,1,1) after respawn, got %s" % _root_basis(p))


func test_emotes_and_look_target() -> void:
	var p := spawn_arena(1)[0]
	var vis := _vis(p)
	await step(10)
	assert_false(vis.play_emote(&"moonwalk"), "unknown emote refused")
	assert_true(vis.play_emote(&"cheer"), "cheer accepted")
	await step(15)
	assert_eq(vis.get_reaction(), &"emote", "emote reaction")
	assert_eq(vis.get_expression(), &"cheer", "cheer face")
	var root := vis.get_model_root()
	assert_true((root.get_node("HandL") as Node3D).position.y > 0.6, "hands up for cheer")
	await step(120)
	assert_eq(vis.get_emote(), &"", "one-shot emote ends")
	assert_true(vis.play_emote(&"wave", true), "looping wave")
	await step(150)
	assert_eq(vis.get_emote(), &"wave", "looping emote keeps going")
	vis.stop_emote()
	assert_true(vis.play_emote(&"sad"), "sad accepted")
	await step(20)
	assert_eq(vis.get_expression(), &"sad", "sad face")
	vis.stop_emote()
	# Look far to the blob's own left (+X in model space): the pupils slide toward +X.
	var left := root.global_basis.x.normalized()
	vis.set_look_target(root.global_position + left * 6.0 + Vector3.UP * 0.66)
	await step(30)
	var slide := (root.get_node("PupilL") as Node3D).position.x - _rest_of("PupilL").x
	assert_true(slide > 0.012 and slide <= BlobRig.PUPIL_RANGE + 0.0001, "pupils look left (slide %f)" % slide)
	vis.set_look_target(null)
	await step(120)
	assert_true(_at_rest(p), "scale back to (1,1,1) after emotes, got %s" % _root_basis(p))


func test_remote_copy_animates_from_replicated_state() -> void:
	var ps := spawn_arena(2)
	var r := ps[1]
	r.set_multiplayer_authority(2)
	assert_false(r.is_authority(), "remote copy")
	var vis := _vis(r)
	var root := vis.get_model_root()
	var foot := root.get_node("FootL") as Node3D
	var foot_rest := _rest_of("FootL")
	await step(5)
	# Moved only by position and facing, the way the sync component would.
	r.facing = Vector3.RIGHT
	var start := r.global_position
	var foot_travel := [0.0]
	await step(40, func(i: int) -> void:
		r.global_position = start + Vector3(0.1 * i, 0.0, 0.0)
		foot_travel[0] = maxf(foot_travel[0], foot.position.distance_to(foot_rest)))
	assert_eq(vis.get_reaction(), &"run", "runs from position deltas")
	assert_true(root.global_basis.z.normalized().dot(Vector3.RIGHT) > 0.9, "turned to the replicated facing")
	assert_true(foot_travel[0] > 0.05, "feet step (moved %f)" % foot_travel[0])
	await step(20)
	# Relayed events drive the same reactions as on the authority.
	r.receive_event(&"jumped")
	await step(3)
	assert_eq(vis.get_reaction(), &"air", "remote jump")
	r.receive_event(&"landed", [9.0])
	await step(2)
	assert_eq(vis.get_reaction(), &"land", "remote landing")
	r.receive_event(&"shove_started")
	await step(2)
	assert_eq(vis.get_reaction(), &"shove", "remote shove")
	r.receive_event(&"got_hit", [Vector3(-6.0, 2.0, 0.0), 0])
	r.receive_event(&"stunned", [0.5])
	await step(2)
	assert_eq(vis.get_reaction(), &"hit", "remote hit")
	await step(20)
	assert_eq(vis.get_reaction(), &"stunned", "remote stun")
	await step(150)
	assert_eq(vis.get_reaction(), &"idle", "remote back to idle")
	assert_true(_at_rest(r), "remote scale back to (1,1,1), got %s" % _root_basis(r))
	r.receive_event(&"eliminated", [&"test"])
	await step(2)
	assert_eq(vis.get_reaction(), &"eliminated", "remote eliminated")
	r.receive_event(&"respawned", [Transform3D(Basis.IDENTITY, Vector3(2.0, 0.0, 0.0))])
	await step(2)
	assert_eq(vis.get_reaction(), &"respawn", "remote respawn")
