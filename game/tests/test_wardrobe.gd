extends GameTest
## Wardrobe UI: opens with the saved profile, swatches / tiles change the preview, items land
## under the right socket, Randomise is valid, Done / Esc save and close, the name is
## sanitised, every catalog item gets a thumbnail, keyboard/pad focus and tab switching.

const SCENE_PATH := "res://ui/wardrobe/wardrobe.tscn"
const TEST_PROFILE := "user://test_wardrobe_profile.json"
const SOCKETS := {&"hat": "HatSocket", &"face": "FaceSocket", &"neck": "NeckSocket", &"back": "BackSocket"}

var w: Wardrobe


func before_each() -> void:
	Net.leave()
	Cosmetics.profile_path = TEST_PROFILE
	_remove_profile()


func after_each() -> void:
	if is_instance_valid(w):
		remove_child(w)
		w.queue_free()
	Net.leave()
	Cosmetics.profile_path = Cosmetics.PROFILE_PATH
	_remove_profile()


func _remove_profile() -> void:
	if FileAccess.file_exists(TEST_PROFILE):
		DirAccess.remove_absolute(TEST_PROFILE)


func _open() -> Wardrobe:
	w = (load(SCENE_PATH) as PackedScene).instantiate() as Wardrobe
	add_child(w)
	await step(2)
	return w


func _look(primary: String, secondary: String, hat := "", face := "", neck := "", back := "") -> Dictionary:
	return {"primary": primary, "secondary": secondary, "hat": hat, "face": face, "neck": neck, "back": back, "size": "normal"}


## The albedo shown on the Body surface that uses `material_name`.
func _body_colour(model: Node3D, material_name: String) -> Color:
	var mi := model.get_node("Body") as MeshInstance3D
	for i in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(i)
		if src and src.resource_name == material_name:
			return (mi.get_active_material(i) as BaseMaterial3D).albedo_color
	fail("Body has no %s surface" % material_name)
	return Color.BLACK


func _assert_colour(actual: Color, expected: Color, message: String) -> void:
	assert_near(Vector3(actual.r, actual.g, actual.b), Vector3(expected.r, expected.g, expected.b), 0.003, message)


func _neighbor(c: Control, side: StringName) -> Node:
	var p: NodePath = c.get(side)
	return c.get_node_or_null(p) if not p.is_empty() else null


func _press_action(action: StringName) -> void:
	var down := InputEventAction.new()
	down.action = action
	down.pressed = true
	Input.parse_input_event(down)
	await step(2)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await step(2)


# --- Opening -------------------------------------------------------------------------------

func test_opens_with_saved_profile() -> void:
	var primary: String = Cosmetics.palette(&"primary")[4]
	var secondary: String = Cosmetics.palette(&"secondary")[7]
	var saved := _look(primary, secondary, "crown", "monocle", "scarf", "cape")
	Cosmetics.save_profile("Mia", saved)
	await _open()
	assert_eq(w.player_name, "Mia", "name")
	assert_eq(w.name_edit.text, "Mia", "name field")
	assert_eq(w.loadout, saved, "loadout")
	assert_eq(w.preview.loadout, saved, "preview loadout")
	var model := w.preview.get_model_root()
	for slot: StringName in SOCKETS:
		var node := Cosmetics.get_item_node(model, slot)
		assert_true(node != null, "%s item on the preview" % slot)
		if node:
			assert_eq(String(node.get_meta(Cosmetics.META_ID)), saved[String(slot)], "%s id" % slot)
	_assert_colour(_body_colour(model, "PlayerPrimary"), Color(primary), "body colour")
	assert_true(w.get_tile(&"hat", "crown").button_pressed, "crown tile selected")
	assert_false(w.get_tile(&"hat", "").button_pressed, "None tile not selected")
	assert_true(w.get_swatch(&"primary", primary).button_pressed, "primary swatch selected")
	assert_true(w.get_swatch(&"secondary", secondary).button_pressed, "secondary swatch selected")
	assert_eq(w.current_tab, &"colour", "opens on Colour")


func test_opens_with_defaults_without_profile() -> void:
	await _open()
	assert_eq(w.player_name, Cosmetics.DEFAULT_NAME, "default name")
	assert_eq(w.loadout, Cosmetics.default_loadout(0), "default loadout")


# --- Choosing ------------------------------------------------------------------------------

func test_swatch_changes_preview() -> void:
	await _open()
	var changes := watch(w, &"loadout_changed")
	var hex: String = Cosmetics.palette(&"primary")[9]
	w.get_swatch(&"primary", hex).pressed.emit()
	await step(1)
	assert_eq(w.loadout["primary"], hex, "loadout primary")
	assert_eq(w.preview.loadout["primary"], hex, "preview primary")
	_assert_colour(_body_colour(w.preview.get_model_root(), "PlayerPrimary"), Color(hex), "body recoloured")
	assert_eq(changes.size(), 1, "loadout_changed once")
	var sec: String = Cosmetics.palette(&"secondary")[10]
	w.get_swatch(&"secondary", sec).pressed.emit()
	await step(1)
	assert_eq(w.preview.loadout["secondary"], sec, "preview secondary")
	_assert_colour(_body_colour(w.preview.get_model_root(), "PlayerSecondary"), Color(sec), "belly recoloured")
	var pressed := 0
	for s: WardrobeSwatch in w.swatches[&"primary"]:
		pressed += 1 if s.button_pressed else 0
	assert_eq(pressed, 1, "exactly one primary swatch selected")
	assert_false(w.select_colour(&"primary", "#123456"), "colour outside the palette refused")


func test_item_tile_puts_item_under_socket() -> void:
	await _open()
	var model := w.preview.get_model_root()
	for slot: StringName in SOCKETS:
		w.open_tab(slot)
		var id: String = Cosmetics.catalog(slot)[2]["id"]
		w.get_tile(slot, id).pressed.emit()
		await step(1)
		assert_eq(w.loadout[String(slot)], id, "%s in loadout" % slot)
		assert_eq(w.preview.loadout[String(slot)], id, "%s in preview loadout" % slot)
		var node := Cosmetics.get_item_node(model, slot)
		assert_true(node != null, "%s item node exists" % slot)
		if node:
			assert_eq(String(node.get_parent().name), SOCKETS[slot], "%s under its socket" % slot)
			assert_eq(String(node.get_meta(Cosmetics.META_ID)), id, "%s item id" % slot)
		var selected := 0
		for b: Button in w.tiles[slot]:
			selected += 1 if b.button_pressed else 0
		assert_eq(selected, 1, "%s: exactly one tile selected" % slot)
		assert_true(w.get_tile(slot, id).button_pressed, "%s tile selected" % slot)
		# None takes it off again.
		w.get_tile(slot, "").pressed.emit()
		await step(1)
		assert_eq(w.loadout[String(slot)], "", "%s cleared" % slot)
		assert_true(Cosmetics.get_item_node(model, slot) == null, "%s item node removed" % slot)
	assert_false(w.select_item(&"hat", "no_such_hat"), "unknown item refused")


func test_equipping_a_back_item_turns_the_blob_around() -> void:
	await _open()
	var before := w.preview.get_yaw()
	w.select_item(&"back", "cape")
	assert_near(absf(wrapf(w.preview.get_yaw() - before, -PI, PI)), PI, 0.01, "turned to show the back")
	w.select_item(&"hat", "crown")
	assert_near(wrapf(w.preview.get_yaw() - WardrobePreview.REST_YAW, -PI, PI), 0.0, 0.01, "turned to the front for a hat")
	var yaw := w.preview.get_yaw()
	w.preview.turn(0.5)
	assert_near(w.preview.get_yaw(), yaw + 0.5, 0.0001, "turn() spins the turntable")


func test_randomise_gives_valid_loadouts() -> void:
	await _open()
	var seen: Dictionary = {}
	for i in 25:
		w.randomise_button.pressed.emit()
		assert_eq(Cosmetics.sanitize(w.loadout), w.loadout, "valid loadout %d" % i)
		assert_eq(w.preview.loadout, w.loadout, "preview follows %d" % i)
		seen[str(w.loadout)] = true
	await step(1)
	assert_true(seen.size() > 5, "randomise varies (%d distinct)" % seen.size())
	for slot: StringName in SOCKETS:
		var id: String = w.loadout[String(slot)]
		var node := Cosmetics.get_item_node(w.preview.get_model_root(), slot)
		assert_eq(node != null, id != "", "%s node matches the loadout" % slot)


func test_reset_gives_the_default_look() -> void:
	Cosmetics.save_profile("Zed", _look("#3b3f4c", "#2b2d42", "chef", "moustache"))
	await _open()
	w.reset_button.pressed.emit()
	assert_eq(w.loadout, Cosmetics.default_loadout(0), "default loadout")
	assert_eq(w.name_edit.text, "Zed", "name kept")


# --- Closing -------------------------------------------------------------------------------

func test_done_saves_and_emits_closed() -> void:
	Net.start_offline()
	await _open()
	var closed := watch(w, &"closed")
	w.select_colour(&"primary", "#9b5de5")
	w.select_item(&"hat", "viking")
	w.select_item(&"neck", "gold_chain")
	w.name_edit.text = "Rosa"
	var expected := w.loadout.duplicate()
	w.done_button.pressed.emit()
	await step(1)
	assert_eq(closed.size(), 1, "closed emitted once")
	var p := Cosmetics.load_profile()
	assert_eq(p["name"], "Rosa", "saved name")
	assert_eq(p["loadout"], expected, "saved loadout")
	assert_eq(expected["hat"], "viking", "hat in the saved loadout")
	var me: PlayerInfo = Net.roster.get(Net.local_slot())
	assert_true(me != null, "local roster entry")
	if me:
		assert_eq(me.name, "Rosa", "Net got the name")
		assert_eq(me.loadout, expected, "Net got the loadout")
	w.done()
	assert_eq(closed.size(), 1, "closed only once")


func test_escape_is_done() -> void:
	await _open()
	var closed := watch(w, &"closed")
	w.select_item(&"face", "clown_nose")
	await _press_action(&"ui_cancel")
	assert_eq(closed.size(), 1, "Esc / B closes")
	assert_eq(Cosmetics.load_profile()["loadout"]["face"], "clown_nose", "and saves")


func test_name_is_sanitised() -> void:
	await _open()
	w.name_edit.text = "  Bo\tb\n "
	w.done()
	assert_eq(Cosmetics.load_profile()["name"], "Bob", "control characters and spaces removed")
	assert_eq(w.player_name, "Bob", "player_name")
	assert_eq(w.name_edit.max_length, Cosmetics.NAME_MAX, "field limited to 16")


func test_empty_name_becomes_default() -> void:
	await _open()
	w.name_edit.text = "   "
	w.done()
	assert_eq(Cosmetics.load_profile()["name"], Cosmetics.DEFAULT_NAME, "empty -> default")


# --- Thumbnails ----------------------------------------------------------------------------

func test_every_catalog_item_gets_a_thumbnail() -> void:
	await _open()
	for i in 240:
		if w.thumbs.is_done():
			break
		await step(1)
	assert_true(w.thumbs.is_done(), "thumbnails finished")
	await step(1)
	for slot: StringName in Cosmetics.SLOTS:
		for entry: Dictionary in Cosmetics.catalog(slot):
			var id: String = entry["id"]
			if id == "":
				continue
			var key := WardrobeThumbs.key_of(slot, id)
			assert_true(w.thumbs.staged.has(key), "%s staged in its studio" % key)
			assert_true(w.get_tile_texture(slot, id) != null, "%s tile has a picture" % key)
	assert_eq(w.thumbs.get_child_count(), 0, "studios freed when done")


# --- Focus and input -----------------------------------------------------------------------

func test_focus_links() -> void:
	Cosmetics.save_profile("Mia", _look("#2f7fe0", "#ffffff", "crown"))
	await _open()
	var tab: Button = w.tab_buttons[&"colour"]
	assert_true(tab.has_focus(), "the Colour tab has focus on open")
	var blue := w.get_swatch(&"primary", "#2f7fe0")
	assert_eq(_neighbor(tab, &"focus_neighbor_bottom"), blue, "tab down -> chosen swatch")
	var first := w.swatches[&"primary"][0] as Control
	assert_eq(_neighbor(first, &"focus_neighbor_top"), tab, "top row up -> tab")
	var sec_first := w.swatches[&"secondary"][0] as Control
	assert_eq(_neighbor(w.swatches[&"primary"][8], &"focus_neighbor_bottom"), sec_first, "body grid -> accent grid")
	var last := w.swatches[&"secondary"][11] as Control
	assert_eq(_neighbor(last, &"focus_neighbor_bottom"), w.done_button, "bottom row down -> Done")
	assert_eq(_neighbor(tab, &"focus_neighbor_right"), w.tab_buttons[&"body"], "tabs chain right")
	assert_eq(_neighbor(w.tab_buttons[&"colour"], &"focus_neighbor_left"), w.tab_buttons[&"back"], "tabs wrap")
	assert_eq(_neighbor(w.done_button, &"focus_neighbor_right"), w.name_edit, "bottom bar wraps")
	assert_eq(_neighbor(w.done_button, &"focus_neighbor_top"), blue, "bottom bar up -> chosen item")
	# Moving onto another tab switches the page; its grid links to that tab.
	w.tab_buttons[&"hat"].grab_focus()
	await step(1)
	assert_eq(w.current_tab, &"hat", "focusing a tab opens it")
	assert_true(w.pages[&"hat"].visible and not w.pages[&"colour"].visible, "hat page shown")
	var crown := w.get_tile(&"hat", "crown")
	assert_eq(_neighbor(w.tab_buttons[&"hat"], &"focus_neighbor_bottom"), crown, "hat tab down -> crown")
	assert_eq(_neighbor(w.get_tile(&"hat", ""), &"focus_neighbor_top"), w.tab_buttons[&"hat"], "tile up -> tab")
	assert_eq(_neighbor(w.get_tile(&"hat", ""), &"focus_neighbor_right"), w.tiles[&"hat"][1], "tile right")
	assert_eq(_neighbor(w.tiles[&"hat"][0], &"focus_neighbor_bottom"), w.tiles[&"hat"][Wardrobe.GRID_COLUMNS], "tile down a row")


func test_keyboard_moves_and_picks() -> void:
	await _open()
	w.open_tab(&"face")
	w.get_tile(&"face", "").grab_focus()
	await _press_action(&"ui_right")
	var focused := w.get_viewport().gui_get_focus_owner()
	assert_eq(focused, w.tiles[&"face"][1], "right moves to the next tile")
	await _press_action(&"ui_accept")
	assert_eq(w.loadout["face"], String(w.tiles[&"face"][1].get_meta(&"id")), "accept picks the focused item")


func test_shoulder_buttons_switch_tabs() -> void:
	await _open()
	var rb := InputEventJoypadButton.new()
	rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	rb.pressed = true
	Input.parse_input_event(rb)
	await step(2)
	assert_eq(w.current_tab, &"body", "RB -> next tab")
	var lb := InputEventJoypadButton.new()
	lb.button_index = JOY_BUTTON_LEFT_SHOULDER
	lb.pressed = true
	Input.parse_input_event(lb)
	await step(1)
	Input.parse_input_event(lb)
	await step(2)
	assert_eq(w.current_tab, &"back", "LB twice wraps to Back")


# --- In the title menu ---------------------------------------------------------------------

func test_opens_and_closes_from_the_title_menu() -> void:
	var menu := (load("res://ui/menu/menu_root.tscn") as PackedScene).instantiate() as MenuRoot
	add_child(menu)
	await step(1)
	assert_true(menu.title.wardrobe_button.visible, "title offers the wardrobe")
	menu.title.wardrobe_button.pressed.emit()
	await step(2)
	var opened := menu.find_child("Wardrobe", true, false) as Wardrobe
	assert_true(opened != null, "wardrobe instanced by the menu")
	if opened == null:
		menu.queue_free()
		return
	assert_eq(menu.screen, MenuRoot.WARDROBE, "menu in wardrobe screen")
	opened.select_item(&"hat", "chef")
	await _press_action(&"ui_cancel")
	await step(2)
	assert_false(is_instance_valid(opened), "wardrobe freed by the menu")
	assert_eq(menu.screen, MenuRoot.TITLE, "back on the title")
	assert_eq(Cosmetics.load_profile()["loadout"]["hat"], "chef", "saved on the way out")
	remove_child(menu)
	menu.queue_free()
