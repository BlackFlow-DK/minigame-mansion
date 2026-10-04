extends Node
## Where a minigame's load time goes (run windowed; tools/perf-run.ps1 -LoadBreakdown runs it
## once per minigame, a fresh process each, after warming up with the lobby like a real game):
##   godot --path game --windowed res://tools/perf/load_probe.tscn -- --minigame=<id> [--quality=low]
## Prints one line: `load: <id> resource <ms> instance+ready <ms> spawn <ms> setup <ms>
## first-frame <ms> worst-next-2s <ms> total <ms>`.
##   resource      ResourceLoader.load of the scene and everything it references (glb, scripts)
##   instance      instantiate + add to the tree (every _ready: the minigame building its arena)
##   spawn         Stage spawning the players (plus extras queued per frame later)
##   setup         Minigame._setup(players)
##   first-frame   until the first frame with the minigame is drawn (pipelines, uploads)

const STAGE_SCENE := "res://stage/stage.tscn"
const LOBBY_SCENE := "res://lobby/lobby.tscn"


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var id := ""
	var players := 8
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--minigame="):
			id = arg.trim_prefix("--minigame=")
		elif arg.begins_with("--players="):
			players = int(arg.trim_prefix("--players="))
	await get_tree().process_frame
	var net := get_node(^"/root/Net")
	net.call(&"start_offline")
	for i in players - 1:
		net.call(&"add_bot")
	var stage := (load(STAGE_SCENE) as PackedScene).instantiate()
	add_child(stage)
	# warm-up like a real game: the lobby with everyone in it, a few frames (`lobby`: no warm-up,
	# times the hall itself)
	var path := LOBBY_SCENE
	if id != "lobby":
		stage.call(&"load_minigame_scene", load(LOBBY_SCENE))
		for i in 30:
			await RenderingServer.frame_post_draw
		var reg: Script = load("res://minigames/registry.gd")
		path = str(reg.call(&"scene_path", StringName(id)))
	var outline0 := Look.outline_usec
	var merge0 := StaticMerge.usec
	var t0 := Time.get_ticks_usec()
	var ps := load(path) as PackedScene
	var t1 := Time.get_ticks_usec()
	var mg: Node = stage.call(&"load_minigame_scene", ps)
	var t2 := Time.get_ticks_usec()
	var t3 := t2
	if mg:
		var ps_list: Array[Player] = []
		ps_list.assign((stage.get(&"players") as Dictionary).values())
		mg.call(&"_setup", ps_list)
	var t4 := Time.get_ticks_usec()
	await RenderingServer.frame_post_draw
	var t5 := Time.get_ticks_usec()
	var worst := 0.0
	var last := t5
	while Time.get_ticks_usec() - t5 < 2000000:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
	print("load: %s resource %.0f instance+ready+spawn %.0f (outline bake %.0f, merge %.0f) setup %.0f first-frame %.0f worst-next-2s %.0f total %.0f" % [
		id, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (Look.outline_usec - outline0) / 1000.0,
		(StaticMerge.usec - merge0) / 1000.0, (t4 - t3) / 1000.0, (t5 - t4) / 1000.0, worst, (t5 - t0) / 1000.0])
	get_tree().quit(0)
