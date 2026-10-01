extends Node
## Measures frame times and render stats for perf_driver.gd, then writes one CSV row.
## Lives on the root next to the current scene (survives the scene change). Process ALWAYS.
##
## Per frame: wall-clock frame time (between _process calls; vsync off, uncapped), the
## renderer's measured CPU and GPU time summed over every rendering viewport (the title's hall
## lives in a SubViewport), draw calls / primitives / objects. At the end: averages, the 99th
## percentile and the "1 % low" (mean of the worst 1 % of frames), video/texture/buffer
## memory, static memory, node count and startup (engine ticks at the probe's first frame).

const HEADER := "label,target,minigame,quality,players,frames,avg_ms,p99_ms,low1_ms,max_ms,fps,cpu_render_ms,gpu_ms,process_ms,physics_ms,draw_calls,primitives,objects,vram_mb,tex_mb,buf_mb,static_mb,static_peak_mb,engine_ms,startup_ms,nodes,scale,adapter"

var config: Dictionary = {}

var _warmup: float = 3.0
var _seconds: float = 10.0
var _t: float = 0.0
var _last_us: int = 0
var _measuring: bool = false
var _done: bool = false
var _startup_ms: int = -1
var _viewports: Array[RID] = []
var _frame_ms: PackedFloat32Array = []
var _cpu_ms: PackedFloat32Array = []
var _gpu_ms: PackedFloat32Array = []
var _proc_ms: PackedFloat32Array = []
var _phys_ms: PackedFloat32Array = []
var _draws: PackedFloat32Array = []
var _prims: PackedFloat32Array = []
var _objs: PackedFloat32Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000
	_warmup = maxf(0.5, float(config.get("perf-warmup", "3")))
	_seconds = maxf(1.0, float(config.get("perf-seconds", "10")))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("perf: %s on %s (%s), warmup %.1f s, measure %.1f s" % [config.get("perf-target", "?"),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_method(), _warmup, _seconds])


func _process(delta: float) -> void:
	if _done:
		return
	var now := Time.get_ticks_usec()
	var scene := get_tree().current_scene
	if _startup_ms < 0 and scene != null and scene.name != &"PerfDriver":
		_startup_ms = Time.get_ticks_msec()  # the target's first frame
	_t += delta
	if not _measuring:
		if _t >= _warmup:
			_begin()
		_last_us = now
		return
	var ms := float(now - _last_us) / 1000.0
	_last_us = now
	_frame_ms.append(ms)
	var cpu := RenderingServer.get_frame_setup_time_cpu()
	var gpu := 0.0
	for rid in _viewports:
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
	_cpu_ms.append(cpu)
	_gpu_ms.append(gpu)
	_proc_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_phys_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_draws.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	_prims.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	_objs.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
	if _t >= _warmup + _seconds:
		_finish()


func _begin() -> void:
	_measuring = true
	_viewports.clear()
	var root := get_tree().root
	_viewports.append(root.get_viewport_rid())
	for n in root.find_children("*", "SubViewport", true, false):
		var vp := n as SubViewport
		if vp.render_target_update_mode != SubViewport.UPDATE_DISABLED:
			_viewports.append(vp.get_viewport_rid())
	for rid in _viewports:
		RenderingServer.viewport_set_measure_render_time(rid, true)


func _finish() -> void:
	_done = true
	var n := _frame_ms.size()
	if n == 0:
		_frame_ms.append(0.0)
		n = 1
	var sorted := _frame_ms.duplicate()
	sorted.sort()
	var worst := maxi(1, ceili(n * 0.01))
	var low1 := 0.0
	for i in worst:
		low1 += sorted[n - 1 - i]
	low1 /= worst
	var avg := _mean(_frame_ms)
	var mb := 1.0 / (1024.0 * 1024.0)
	var target := str(config.get("perf-target", "sandbox"))
	var mg := str(config.get("minigame", "")) if target == "sandbox" else ""
	if target == "sandbox" and mg == "":
		mg = "dev_arena"
	var quality := str(config.get("quality", "default"))
	var players := 0
	var stage := get_tree().get_first_node_in_group(&"stage")
	if stage and stage.get(&"players") is Dictionary:
		players = (stage.get(&"players") as Dictionary).size()
	var row := [
		str(config.get("perf-label", "run")), target, mg, quality, players, n,
		_f(avg), _f(sorted[mini(n - 1, int(n * 0.99))]), _f(low1), _f(sorted[n - 1]), _f(1000.0 / maxf(avg, 0.001), 0),
		_f(_mean(_cpu_ms)), _f(_mean(_gpu_ms)), _f(_mean(_proc_ms)), _f(_mean(_phys_ms)),
		_f(_mean(_draws), 0), _f(_mean(_prims), 0), _f(_mean(_objs), 0),
		_f(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) * mb, 1),
		_f(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) * mb, 1),
		_f(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED) * mb, 1),
		_f(OS.get_static_memory_usage() * mb, 1), _f(OS.get_static_memory_peak_usage() * mb, 1),
		int(config.get("engine-ms", "-1")), _startup_ms, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		_f(get_tree().root.scaling_3d_scale), "\"%s\"" % RenderingServer.get_video_adapter_name(),
	]
	var cells: PackedStringArray = []
	for v: Variant in row:
		cells.append(str(v))
	var line := ",".join(cells)
	print("perf: " + HEADER)
	print("perf: " + line)
	var out := str(config.get("perf-out", ""))
	if out != "":
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var fresh := not FileAccess.file_exists(out)
		var f := FileAccess.open(out, FileAccess.WRITE if fresh else FileAccess.READ_WRITE)
		if f == null:
			printerr("perf: cannot write %s" % out)
		else:
			f.seek_end()
			if fresh:
				f.store_line(HEADER)
			f.store_line(line)
			f.close()
	var shot := str(config.get("perf-shot", ""))
	if shot != "":
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute(shot.get_base_dir())
		img.save_png(shot)
		print("perf: saved %s" % shot)
	get_tree().quit(0)


static func _mean(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


static func _f(v: float, digits: int = 2) -> String:
	return String.num(v, digits)
