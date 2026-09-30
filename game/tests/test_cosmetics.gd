extends GameTest
## Cosmetics autoload + component: catalog, palettes, defaults, apply(), sanitize, profile.

const BLOB := preload("res://assets/models/character/blob.glb")
const PLAYER_SCENE := preload("res://player/player.tscn")
const TEST_PROFILE := "user://test_cosmetics_profile.json"
const EXPECTED_COUNTS := {&"hat": 12, &"face": 6, &"neck": 5, &"back": 5}
const SOCKETS := {&"hat": "HatSocket", &"face": "FaceSocket", &"neck": "NeckSocket", &"back": "BackSocket"}

var _blobs: Array[Node3D] = []


func after_each() -> void:
	for b in _blobs:
		if is_instance_valid(b):
			b.free()
	_blobs.clear()
	Cosmetics.profile_path = Cosmetics.PROFILE_PATH
	if FileAccess.file_exists(TEST_PROFILE):
		DirAccess.remove_absolute(TEST_PROFILE)


func _blob() -> Node3D:
	var b := BLOB.instantiate() as Node3D
	_blobs.append(b)
	return b


func _loadout(primary: String, secondary: String, hat := "", face := "", neck := "", back := "") -> Dictionary:
	return {"primary": primary, "secondary": secondary, "hat": hat, "face": face, "neck": neck, "back": back}


## The albedo shown on `part`'s surface that uses `material_name` (override if any, else the mesh's).
func _shown_colour(blob: Node3D, part: String, material_name: String) -> Color:
	var mi := blob.get_node(part) as MeshInstance3D
	for i in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(i)
		if src and src.resource_name == material_name:
			var shown := mi.get_surface_override_material(i)
			if shown == null:
				shown = src
			return (shown as BaseMaterial3D).albedo_color
	fail("%s has no %s surface" % [part, material_name])
	return Color.BLACK


func _imported_colour(blob: Node3D, part: String, material_name: String) -> Color:
	var mi := blob.get_node(part) as MeshInstance3D
	for i in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(i)
		if src and src.resource_name == material_name:
			return (src as BaseMaterial3D).albedo_color
	return Color.BLACK


func _item_ids(blob: Node3D) -> Array[String]:
	var out: Array[String] = []
	for slot: StringName in SOCKETS:
		var socket := blob.get_node(SOCKETS[slot])
		for child in socket.get_children():
			out.append("%s:%s" % [slot, child.get_meta(Cosmetics.META_ID, "?")])
	return out


# --- Catalog / palette / defaults ------------------------------------------------------

func test_catalog_has_all_items_and_a_none_choice() -> void:
	for slot: StringName in EXPECTED_COUNTS:
		var entries := Cosmetics.catalog(slot)
		assert_eq(entries.size(), EXPECTED_COUNTS[slot] + 1, "%s entries (incl. None)" % slot)
		assert_eq(entries[0]["id"], "", "%s first entry is None" % slot)
		assert_eq(entries[0]["name"], "None")
		var ids := {}
		for e: Dictionary in entries:
			for key in ["id", "slot", "name", "model", "offset", "rotation", "scale"]:
				assert_true(e.has(key), "%s entry %s has %s" % [slot, e.get("id"), key])
			assert_false(ids.has(e["id"]), "duplicate id %s" % e["id"])
			ids[e["id"]] = true
	assert_eq(Cosmetics.catalog(&"shoes"), [], "unknown slot")
	# Catalog entries are copies.
	Cosmetics.catalog(&"hat")[1]["name"] = "Hacked"
	assert_true(Cosmetics.catalog(&"hat")[1]["name"] != "Hacked", "catalog returns copies")


func test_every_catalog_model_exists_and_loads() -> void:
	for slot in Cosmetics.SLOTS:
		for e: Dictionary in Cosmetics.catalog(slot):
			if e["id"] == "":
				continue
			var path: String = e["model"]
			assert_true(ResourceLoader.exists(path), "model exists: %s" % path)
			var scene := load(path) as PackedScene
			assert_true(scene != null, "loads as PackedScene: %s" % path)
			if scene == null:
				continue
			var inst := scene.instantiate() as Node3D
			assert_true(inst != null, "root is Node3D: %s" % path)
			if inst:
				assert_true(inst.find_children("*", "MeshInstance3D", true, false).size() > 0 or inst is MeshInstance3D, "has meshes: %s" % path)
				if e.has("spin_child"):
					assert_true(inst.find_child(e["spin_child"], true, false) != null, "spin child in %s" % path)
				inst.free()


func test_palettes_are_valid_and_distinct() -> void:
	var primary := Cosmetics.palette(&"primary")
	var secondary := Cosmetics.palette(&"secondary")
	assert_eq(primary.size(), 16)
	assert_eq(secondary.size(), 12)
	for list: Array[String] in [primary, secondary]:
		var seen := {}
		for hex in list:
			assert_true(hex.length() == 7 and hex.begins_with("#") and Color.html_is_valid(hex), "valid colour %s" % hex)
			assert_false(seen.has(hex), "duplicate colour %s" % hex)
			seen[hex] = true
	assert_eq(Cosmetics.palette(&"nope"), [] as Array[String])
	# The first 8 primaries (slot defaults) must be far apart in colour.
	for i in 8:
		for j in range(i + 1, 8):
			var a := Color(primary[i])
			var b := Color(primary[j])
			var d := Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
			assert_true(d > 0.25, "default primaries %s and %s too close (%.2f)" % [primary[i], primary[j], d])


func test_default_loadouts_are_distinct_for_8_slots() -> void:
	var primaries := {}
	var pairs := {}
	var hats := {}
	for s in 8:
		var lo := Cosmetics.default_loadout(s)
		assert_eq(lo, Cosmetics.sanitize(lo), "default %d is clean" % s)
		assert_true(lo["hat"] != "", "slot %d has a hat" % s)
		primaries[lo["primary"]] = true
		pairs["%s/%s" % [lo["primary"], lo["secondary"]]] = true
		hats[lo["hat"]] = true
	assert_eq(primaries.size(), 8, "distinct primaries")
	assert_eq(pairs.size(), 8, "distinct colour pairs")
	assert_eq(hats.size(), 8, "distinct hats")


# --- apply() ------------------------------------------------------------------------------

func test_apply_tints_only_that_instance() -> void:
	var a := _blob()
	var b := _blob()
	var imported := _imported_colour(a, "Body", "PlayerPrimary")
	Cosmetics.apply(a, _loadout("#e8453c", "#fff1c1"))
	Cosmetics.apply(b, _loadout("#2f7fe0", "#cde8ff"))
	assert_eq(_shown_colour(a, "Body", "PlayerPrimary"), Color("#e8453c"), "a body")
	assert_eq(_shown_colour(b, "Body", "PlayerPrimary"), Color("#2f7fe0"), "b body")
	assert_eq(_shown_colour(a, "Body", "PlayerSecondary"), Color("#fff1c1"), "a belly")
	for part in ["LidL", "LidR", "Mouth"]:
		assert_eq(_shown_colour(a, part, "PlayerPrimary"), Color("#e8453c"), "a %s follows primary" % part)
	for part in ["HandL", "HandR", "FootL", "FootR"]:
		assert_eq(_shown_colour(b, part, "PlayerSecondary"), Color("#cde8ff"), "b %s follows secondary" % part)
	# The shared imported material is untouched; a fresh blob still shows it.
	assert_eq(_imported_colour(a, "Body", "PlayerPrimary"), imported, "imported material unchanged")
	var fresh := _blob()
	assert_eq(_shown_colour(fresh, "Body", "PlayerPrimary"), imported, "untinted blob shows the imported colour")
	# Other materials are never overridden.
	var eye := a.get_node("EyeL") as MeshInstance3D
	for i in eye.mesh.get_surface_count():
		assert_true(eye.get_surface_override_material(i) == null, "eye white not overridden")


func test_apply_twice_does_not_duplicate() -> void:
	var blob := _blob()
	var lo := _loadout("#3cb44b", "#ffd23f", "wizard", "round_glasses", "scarf", "cape")
	Cosmetics.apply(blob, lo)
	var count := blob.find_children("*", "", true, false).size()
	var hat := Cosmetics.get_item_node(blob, &"hat")
	var body := blob.get_node("Body") as MeshInstance3D
	var mat := body.get_surface_override_material(0)
	Cosmetics.apply(blob, lo)
	Cosmetics.apply(blob, lo.duplicate())
	assert_eq(blob.find_children("*", "", true, false).size(), count, "same node count")
	assert_true(Cosmetics.get_item_node(blob, &"hat") == hat, "hat node kept")
	assert_true(body.get_surface_override_material(0) == mat, "material kept")
	for slot: StringName in SOCKETS:
		assert_eq(blob.get_node(SOCKETS[slot]).get_child_count(), 1, "one item under %s" % SOCKETS[slot])


func test_switching_and_removing_items() -> void:
	var blob := _blob()
	Cosmetics.apply(blob, _loadout("#9b5de5", "#e6d6ff", "top_hat", "monocle", "bow_tie", "jetpack"))
	assert_eq(_item_ids(blob), ["hat:top_hat", "face:monocle", "neck:bow_tie", "back:jetpack"] as Array[String])
	var face := Cosmetics.get_item_node(blob, &"face")
	var neck := Cosmetics.get_item_node(blob, &"neck")
	# Change only the hat: the other items are left alone.
	Cosmetics.apply(blob, _loadout("#9b5de5", "#e6d6ff", "crown", "monocle", "bow_tie", "jetpack"))
	assert_eq(_item_ids(blob), ["hat:crown", "face:monocle", "neck:bow_tie", "back:jetpack"] as Array[String])
	assert_true(Cosmetics.get_item_node(blob, &"face") == face, "face node untouched")
	assert_true(Cosmetics.get_item_node(blob, &"neck") == neck, "neck node untouched")
	# Remove everything; missing keys also mean nothing.
	Cosmetics.apply(blob, {"primary": "#9b5de5", "secondary": "#e6d6ff", "hat": "", "face": ""})
	assert_eq(_item_ids(blob), [] as Array[String], "all removed")
	# The fit transform is applied relative to the socket.
	Cosmetics.apply(blob, _loadout("#9b5de5", "#e6d6ff", "", "clown_nose"))
	var nose := Cosmetics.get_item_node(blob, &"face")
	assert_true(nose.transform.is_equal_approx(Cosmetics.fit_transform(Cosmetics.item(&"face", "clown_nose"))), "fit transform")


func test_propeller_gets_a_spinner() -> void:
	var blob := _blob()
	add_child(blob)
	Cosmetics.apply(blob, _loadout("#1cc7c1", "#ffffff", "propeller_cap"))
	var cap := Cosmetics.get_item_node(blob, &"hat")
	var spin := cap.find_child("Spin", true, false) as Node3D
	var before := spin.basis
	await step(5)
	assert_false(spin.basis.is_equal_approx(before), "propeller turned")
	remove_child(blob)


func test_unknown_ids_and_bad_colours_are_skipped() -> void:
	var blob := _blob()
	Cosmetics.apply(blob, _loadout("#e8453c", "#fff1c1", "crown"))
	Cosmetics.apply(blob, _loadout("not a colour", "#fff1c1", "banana_hat", "crown"))
	assert_eq(_item_ids(blob), [] as Array[String], "unknown hat removed the crown, crown is not a face item")
	assert_eq(_shown_colour(blob, "Body", "PlayerPrimary"), _imported_colour(blob, "Body", "PlayerPrimary"), "bad colour falls back to imported")
	assert_eq(_shown_colour(blob, "Body", "PlayerSecondary"), Color("#fff1c1"))
	Cosmetics.apply(blob, {"primary": 42, "hat": 7})  # wrong types
	assert_eq(_item_ids(blob), [] as Array[String])
	Cosmetics.apply(null, _loadout("#e8453c", "#fff1c1"))  # no crash


func test_colour_change_touches_only_colours() -> void:
	var blob := _blob()
	Cosmetics.apply(blob, _loadout("#e8453c", "#fff1c1", "viking"))
	var hat := Cosmetics.get_item_node(blob, &"hat")
	Cosmetics.apply(blob, _loadout("#ff8a1f", "#2b2d42", "viking"))
	assert_true(Cosmetics.get_item_node(blob, &"hat") == hat, "hat not rebuilt")
	assert_eq(_shown_colour(blob, "Body", "PlayerPrimary"), Color("#ff8a1f"))
	assert_eq(_shown_colour(blob, "FootL", "PlayerSecondary"), Color("#2b2d42"))


# --- sanitize ------------------------------------------------------------------------------

func test_sanitize() -> void:
	var dirty := {
		"primary": "#ABC", "secondary": "purple-ish", "hat": "crown", "face": "crown",
		"neck": 12, "back": "cape", "evil": "x", "script": "rm -rf",
	}
	var clean := Cosmetics.sanitize(dirty, 3)
	assert_eq(clean.keys().size(), 6, "exactly six keys")
	assert_false(clean.has("evil"), "unknown key dropped")
	assert_eq(clean["primary"], "#aabbcc", "short hex normalised")
	assert_eq(clean["secondary"], Cosmetics.default_loadout(3)["secondary"], "bad colour replaced by slot default")
	assert_eq(clean["hat"], "crown")
	assert_eq(clean["face"], "", "hat id in face slot cleared")
	assert_eq(clean["neck"], "", "non-string cleared")
	assert_eq(clean["back"], "cape")
	assert_eq(Cosmetics.sanitize("garbage"), Cosmetics.default_loadout(0), "non-dictionary gives defaults")
	assert_eq(Cosmetics.sanitize({"primary": "E8453C"})["primary"], "#e8453c", "hash optional")
	assert_eq(Cosmetics.sanitize({"primary": "#e8453c80"})["primary"], "#e8453c", "alpha dropped")
	assert_eq(Cosmetics.sanitize({})["hat"], "", "missing item is empty")


func test_sanitize_name() -> void:
	assert_eq(Cosmetics.sanitize_name("  Bob  "), "Bob")
	assert_eq(Cosmetics.sanitize_name("abcdefghijklmnopqrstuvwxyz"), "abcdefghijklmnop")
	assert_eq(Cosmetics.sanitize_name("a\nb\tc"), "abc")
	assert_eq(Cosmetics.sanitize_name("   "), "Player")
	assert_eq(Cosmetics.sanitize_name(null), "Player")


# --- profile -------------------------------------------------------------------------------

func test_profile_round_trip() -> void:
	Cosmetics.profile_path = TEST_PROFILE
	var lo := _loadout("#b5227f", "#ffd23f", "chef", "star_shades", "flower_lei", "angel_wings")
	assert_eq(Cosmetics.save_profile("  Sir Blobsalot the Third  ", lo), OK)
	var p := Cosmetics.load_profile()
	assert_eq(p["name"], "Sir Blobsalot th", "trimmed to 16")
	assert_eq(p["loadout"], lo, "loadout round-trips")


func test_profile_missing_or_corrupt_gives_defaults() -> void:
	Cosmetics.profile_path = TEST_PROFILE
	var fallback := {"name": "Player", "loadout": Cosmetics.default_loadout(0)}
	assert_eq(Cosmetics.load_profile(), fallback, "missing file")
	for text in ["{not json", "", "[1, 2, 3]", "\u0001garbage"]:
		var f := FileAccess.open(TEST_PROFILE, FileAccess.WRITE)
		f.store_string(text)
		f.close()
		assert_eq(Cosmetics.load_profile(), fallback, "corrupt file %s" % text.c_escape())
	var f2 := FileAccess.open(TEST_PROFILE, FileAccess.WRITE)
	f2.store_string(JSON.stringify({"name": 5, "loadout": {"primary": "zzz", "hat": "wizard", "face": "nope"}}))
	f2.close()
	var p := Cosmetics.load_profile()
	assert_eq(p["name"], "Player", "non-string name")
	assert_eq(p["loadout"]["hat"], "wizard")
	assert_eq(p["loadout"]["face"], "")
	assert_eq(p["loadout"]["primary"], Cosmetics.default_loadout(0)["primary"])


# --- component ---------------------------------------------------------------------------

## A Player whose `visuals` is a stub exposing get_model_root() (the agreed visuals API).
func _player_with_model(model: Node3D, loadout: Dictionary) -> Player:
	var stub := GDScript.new()
	stub.source_code = "extends PlayerComponent\nvar model: Node3D\nfunc get_model_root() -> Node3D:\n\treturn model\n"
	stub.reload()
	var p := PLAYER_SCENE.instantiate() as Player
	var holder := p.get_node("Components")
	var old := holder.get_node("visuals")
	var index := old.get_index()
	holder.remove_child(old)
	old.free()
	var visuals := Node3D.new()
	visuals.set_script(stub)
	visuals.name = "visuals"
	visuals.set(&"model", model)
	holder.add_child(visuals)
	holder.move_child(visuals, index)
	visuals.add_child(model)
	p.loadout = loadout
	p.frozen = true
	add_child(p)
	return p


func test_component_applies_and_follows_loadout() -> void:
	var model := BLOB.instantiate() as Node3D
	var p := _player_with_model(model, _loadout("#e8453c", "#fff1c1", "crown"))
	var comp := p.get_component(&"cosmetics") as CosmeticsComponent
	assert_true(comp.get_model_root() == model, "finds the model through visuals")
	assert_eq(_item_ids(model), ["hat:crown"] as Array[String], "applied at spawn")
	assert_eq(_shown_colour(model, "Body", "PlayerPrimary"), Color("#e8453c"))
	# Lobby changes the loadout: picked up on the next frame without any call.
	p.loadout = _loadout("#2f7fe0", "#cde8ff", "wizard", "monocle")
	await step(2)
	assert_eq(_item_ids(model), ["hat:wizard", "face:monocle"] as Array[String], "watched loadout")
	assert_eq(_shown_colour(model, "Body", "PlayerPrimary"), Color("#2f7fe0"))
	# In-place edit + refresh() applies immediately.
	p.loadout["hat"] = ""
	comp.refresh()
	assert_eq(_item_ids(model), ["face:monocle"] as Array[String], "refresh")
	# Visuals swaps its model: the new one gets dressed too.
	var model2 := BLOB.instantiate() as Node3D
	var visuals := p.get_component(&"visuals")
	visuals.add_child(model2)
	visuals.set(&"model", model2)
	await step(2)
	assert_eq(_item_ids(model2), ["face:monocle"] as Array[String], "new model dressed")
	remove_child(p)
	p.free()


func test_component_without_model_root_does_nothing() -> void:
	var ps := spawn_arena(2)
	await step(3)
	var comp := ps[0].get_component(&"cosmetics") as CosmeticsComponent
	assert_true(comp != null, "component present")
	if ps[0].get_component(&"visuals").has_method(&"get_model_root"):
		return  # visuals already provides a model (after the animator merge): covered above.
	assert_true(comp.get_model_root() == null, "no model root on the placeholder visuals")
