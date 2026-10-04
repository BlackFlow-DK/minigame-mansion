extends GameTest
## Small wiring checks: the Player presentation forwarder and the perf-run default scene list.


func test_player_set_presentation_hidden_forwards_to_fx() -> void:
	var ps := spawn_arena(2)
	var p := ps[1]
	var tag := NameTag.of(p)
	if tag == null:
		tag = (load("res://ui/round/name_tag.tscn") as PackedScene).instantiate() as NameTag
		p.add_child(tag)
		tag.setup(p)
	var fx := p.get_component(&"fx") as FxComponent
	p.set_presentation_hidden(true)
	assert_true(tag.suppressed, "tag hidden")
	assert_true(fx.shadow_hidden, "shadow hidden")
	p.set_presentation_hidden(false, true, false)
	assert_false(tag.suppressed, "tag back")
	assert_true(fx.shadow_hidden, "shadow untouched when shadow = false")
	p.set_presentation_hidden(false)
	assert_false(fx.shadow_hidden, "shadow back")
	p.set_presentation_hidden(true, false, true)
	assert_false(tag.suppressed, "tag untouched when tags = false")
	assert_true(fx.shadow_hidden, "shadow hidden alone")
	p.set_presentation_hidden(false)


## tools/perf-run.ps1 -ListScenes: title, lobby, dev_arena, then MinigameRegistry.IDS in order.
func test_perf_run_default_scenes_follow_the_registry() -> void:
	if OS.get_name() != "Windows":
		return
	var script := ProjectSettings.globalize_path("res://").path_join("../tools/perf-run.ps1").simplify_path()
	if not assert_true(FileAccess.file_exists(script), "perf-run.ps1 at %s" % script):
		return
	var out: Array = []
	var code := OS.execute("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-ListScenes"], out, true)
	assert_eq(code, 0, "perf-run -ListScenes exits 0")
	var got: Array[String] = []
	for line in str(out[0] if not out.is_empty() else "").split("\n", false):
		var s := line.strip_edges()
		if s != "":
			got.append(s)
	var want: Array[String] = ["title", "lobby", "dev_arena"]
	for id in MinigameRegistry.IDS:
		want.append(String(id))
	assert_eq(got, want, "scene list = title, lobby, dev_arena + the registry")
