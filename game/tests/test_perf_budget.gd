extends GameTest
## Structural render budgets at LOW quality with 8 players, checked headless (no GPU): what each
## minigame, the lobby and the podium ask the renderer for (RenderCensus), so a regression shows
## up in the tests before anyone measures frame times. The numbers behind the budgets are in
## docs/performance.md (tools/perf-run.ps1 -Census prints the same census for a real run).
##
## Budgets (LOW):
##   - real lights (visible Omni/Spot) per minigame <= LIGHTS_MAX, none casting shadows
##   - visible mesh surfaces of the minigame's own nodes (players excluded; a MultiMesh counts its
##     surfaces once) <= SURFACES_MAX: each is a draw per pass (depth, colour, each shadow split)
##   - distinct materials <= MATERIALS_MAX (no per-tile / per-prop material copies)
##   - the lobby hall merged (StaticMerge) and within its own draw estimate
##   - blobs: crowd extras draw the low-poly LOD body at LOW

const LIGHTS_MAX := 10
const SURFACES_MAX := 320
const MATERIALS_MAX := 110
const LOBBY_SURFACES_MAX := 150
const LOBBY_PATH := "res://lobby/lobby.tscn"


func before_each() -> void:
	Look.set_quality(Look.Quality.LOW)


func after_each() -> void:
	Look.set_quality(Look.Quality.HIGH)


func test_minigames_a_within_low_budget() -> void:
	await _check_ids(0, 6)


func test_minigames_b_within_low_budget() -> void:
	await _check_ids(6, 12)


func test_minigames_c_within_low_budget() -> void:
	await _check_ids(12, 18)


func test_minigames_d_within_low_budget() -> void:
	await _check_ids(18, 24)


func test_lobby_hall_is_merged_and_within_budget() -> void:
	var lobby := (load(LOBBY_PATH) as PackedScene).instantiate() as Node3D
	add_child(lobby)
	await step(1)
	var hall := lobby.get_node_or_null(^"Hall")
	assert_true(hall != null, "lobby has its Hall")
	var merged := 0
	var loose := 0
	for n in hall.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		if str(mi.name).begins_with("HallMerged"):
			merged += 1
		elif not mi.has_meta(StaticMerge.MERGED_META):
			loose += 1
	assert_true(merged > 0, "the hall kit is merged (%d merged meshes)" % merged)
	assert_true(loose <= 8, "only moving parts stay loose (%d)" % loose)
	var c := RenderCensus.count(lobby)
	print("perf budget: lobby %s" % RenderCensus._fmt(c))
	assert_true(int(c["surfaces"]) <= LOBBY_SURFACES_MAX, "lobby LOW %d mesh surfaces <= %d" % [c["surfaces"], LOBBY_SURFACES_MAX])
	assert_true(int(c["lights"]) <= 6 and int(c["shadow_lights"]) == 0, "lobby LOW lights %d (%d with shadows)" % [c["lights"], c["shadow_lights"]])
	lobby.queue_free()
	await step(1)


func test_static_merge_keeps_materials_and_moving_parts() -> void:
	var root := Node3D.new()
	add_child(root)
	var red := Look.toon_material(Look.RED)
	var gold := Look.toon_material(Look.GOLD)
	var moving: MeshInstance3D = null
	for i in 12:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		mi.mesh = box
		mi.material_override = red if i % 2 == 0 else gold
		mi.position = Vector3(i * 1.5, 0.0, 0.0)
		mi.rotation.y = i * 0.3
		root.add_child(mi)
		if i == 11:
			moving = mi
	var stats := StaticMerge.merge(root, [moving])
	assert_eq(int(stats["sources"]), 11, "every static box merged")
	assert_eq(int(stats["meshes"]), 2, "one mesh per material")
	assert_true(moving.mesh != null, "the skipped part keeps its mesh")
	var mats: Array = []
	for n in root.get_children():
		var mi := n as MeshInstance3D
		if mi and str(mi.name).begins_with("Merged"):
			mats.append(mi.mesh.surface_get_material(0))
	assert_true(mats.has(red) and mats.has(gold), "the very same materials (outline switch, tints)")
	root.queue_free()
	await step(1)


func test_crowd_extras_use_the_lod_body_at_low() -> void:
	var lod_mesh := BlobRig.lod_mesh(&"Body")
	assert_true(lod_mesh != null, "blob_lod.glb has a Body")
	spawn_arena(8, &"masquerade")
	await step(240)
	var extras: Array[Player] = stage.extras
	assert_true(extras.size() >= 10, "masquerade spawned its crowd (%d)" % extras.size())
	var lod := 0
	for x: Variant in extras:
		var v := (x as Player).get_component(&"visuals") as VisualsComponent
		if v and v.is_lod():
			lod += 1
	assert_eq(lod, extras.size(), "every extra draws the LOD blob at LOW")
	# the swapped mesh keeps the tint and the toon look (surface overrides by index)
	var body := (extras[0] as Player).get_component(&"visuals").get_model_root().get_node(^"Body") as MeshInstance3D
	assert_true(body.mesh == lod_mesh, "the extra's Body is the LOD mesh")
	var m := body.get_active_material(0)
	assert_true(m != null and m.resource_name == "PlayerPrimary" and m.has_meta(Look.TOON_META), "LOD body keeps its toon PlayerPrimary")
	Look.set_quality(Look.Quality.HIGH)
	await step(40)
	assert_false((extras[0] as Player).get_component(&"visuals").is_lod(), "HIGH: back to the full blob")


func _check_ids(from: int, to: int) -> void:
	var ids: Array[StringName] = MinigameRegistry.IDS
	for i in range(from, mini(to, ids.size())):
		var id := ids[i]
		spawn_arena(8, id)
		await step(30)
		var mg := get_minigame()
		assert_true(mg != null, "%s loaded" % id)
		if mg == null:
			continue
		var c := RenderCensus.count(mg)
		print("perf budget: %-18s %s" % [id, RenderCensus._fmt(c)])
		assert_true(int(c["lights"]) <= LIGHTS_MAX, "%s: %d real lights at LOW (<= %d)" % [id, c["lights"], LIGHTS_MAX])
		assert_eq(int(c["shadow_lights"]), 0, "%s: no shadowed point/spot lights at LOW" % id)
		var surf := int(c["surfaces"]) + int(c["multimesh"])
		assert_true(surf <= SURFACES_MAX, "%s: %d mesh surfaces at LOW (<= %d)" % [id, surf, SURFACES_MAX])
		assert_true(int(c["materials"]) <= MATERIALS_MAX, "%s: %d materials (<= %d)" % [id, c["materials"], MATERIALS_MAX])
		await _drop_arena()


## The harness's own teardown, between two minigames of one test.
func _drop_arena() -> void:
	if stage:
		stage.clear()
		remove_child(stage)
		stage.queue_free()
		stage = null
	players.clear()
	Net.leave()
	await step(2)
