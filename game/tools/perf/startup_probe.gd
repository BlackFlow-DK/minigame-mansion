extends Node
## Startup breakdown of the title (tools/perf-run.ps1 does not need it; run it by hand):
##   godot --path game --windowed res://tools/perf/startup_probe.tscn -- --fps=0 --name=Perf
## Prints, in ms: engine + autoloads, load(main.tscn), instantiate, add to the tree (every
## _ready, incl. the title's hall), first two drawn frames (pipeline compiles show up here).


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	print("startup: engine + autoloads %d ms" % t0)
	var t := Time.get_ticks_usec()
	# --first=res://a.tscn,res://b.tscn: time loading these (and their dependencies) first
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--first="):
			for path in arg.trim_prefix("--first=").split(","):
				t = Time.get_ticks_usec()
				load(path)
				print("startup:   %s %.0f ms" % [path, (Time.get_ticks_usec() - t) / 1000.0])
	t = Time.get_ticks_usec()
	var ps := load("res://main/main.tscn") as PackedScene
	var t_load := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	var main := ps.instantiate()
	var t_inst := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	var t_ready := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	await RenderingServer.frame_post_draw
	var t_f1 := (Time.get_ticks_usec() - t) / 1000.0
	t = Time.get_ticks_usec()
	await RenderingServer.frame_post_draw
	var t_f2 := (Time.get_ticks_usec() - t) / 1000.0
	print("startup: load main.tscn %.0f, instantiate %.0f, enter tree + ready %.0f, frame 1 %.0f, frame 2 %.0f ms" % [
		t_load, t_inst, t_ready, t_f1, t_f2])
	print("startup: title drawn at %d ms" % Time.get_ticks_msec())
	get_tree().quit(0)
