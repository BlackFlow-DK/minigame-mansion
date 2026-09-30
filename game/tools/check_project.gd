extends SceneTree
## Headless project validation, driven by tools/godot-check.ps1:
##   godot --headless --path game --script res://tools/check_project.gd
## Parses every .gd script and loads every .tscn/.scn scene under res://.
## Exit 0 when everything loads, 1 otherwise. Godot prints the actual errors.

const SKIP_DIRS := [".godot", ".import"]


func _initialize() -> void:
	var scripts: Array[String] = []
	var scenes: Array[String] = []
	_collect("res://", scripts, scenes)
	var failed: Array[String] = []
	for path in scripts:
		if path == get_script().resource_path:
			continue  # reloading the running script with CACHE_MODE_IGNORE crashes Godot
		var s := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
		if s == null or not (s.can_instantiate() or s.is_abstract()):
			failed.append(path)
	for path in scenes:
		var p := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if p == null or not p.can_instantiate():
			failed.append(path)
	print("check: %d script(s), %d scene(s), %d failed" % [scripts.size(), scenes.size(), failed.size()])
	for path in failed:
		printerr("check: FAILED %s" % path)
	quit(1 if failed.size() > 0 else 0)


func _collect(dir: String, scripts: Array[String], scenes: Array[String]) -> void:
	for sub in DirAccess.get_directories_at(dir):
		if sub.begins_with(".") or sub in SKIP_DIRS:
			continue
		_collect(dir.path_join(sub), scripts, scenes)
	for f in DirAccess.get_files_at(dir):
		var ext := f.get_extension()
		if ext == "gd":
			scripts.append(dir.path_join(f))
		elif ext == "tscn" or ext == "scn":
			scenes.append(dir.path_join(f))
