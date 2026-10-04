extends Node
## Measures frame times and render stats for perf_driver.gd, then writes one CSV row.
## Lives on the root next to the current scene (survives the scene change). Process ALWAYS.
##
## Per frame: wall-clock frame time (between _process calls; vsync off, uncapped), the
## renderer's measured CPU and GPU time summed over every rendering viewport (the title's hall
## lives in a SubViewport), draw calls / primitives / objects. At the end: averages, the 99th
## percentile and the "1 % low" (mean of the worst 1 % of frames), video/texture/buffer
## memory, static memory, node count and startup (engine ticks at the probe's first frame).
##
## `--perf-wait=podium|vote`: the warm-up starts only once Session reaches that state; the
## probe then slows Session.time_scale to 0.001 so the phase outlasts the measurement.
## `--perf-transitions`: no frame-time row; instead, for every round of the running session,
## the time from the last frame before the round's stage load (Session.round_intro fires right
## after the synchronous load) to the first frame drawn after it, and the worst frame of the
## next 2 s (shader-compile hitches), one row per round in `--perf-load-out=<abs .csv>`; quits
## at PODIUM.

##
## Frame breakdown (last columns): the probe brackets every callback list with a twin node at
## the opposite priority, so per frame it knows: physics ticks run, physics scripts
## (_physics_process of every node: movement, bots, minigame host ticks), physics total (scripts
## + the physics server step), process scripts (_process: visuals, minigame dressing, UI) and
## the rest (rendering submit, sync, OS). `w_*` are the same means over the worst 1 % frames.
const HEADER := "label,target,minigame,quality,players,frames,avg_ms,p99_ms,low1_ms,max_ms,fps,cpu_render_ms,gpu_ms,process_ms,physics_ms,draw_calls,primitives,objects,vram_mb,tex_mb,buf_mb,static_mb,static_peak_mb,engine_ms,startup_ms,nodes,scale,adapter,gpu_p50_ms,ticks,phys_script_ms,phys_total_ms,proc_script_ms,rest_ms,w_ticks,w_phys_script_ms,w_phys_total_ms,w_proc_script_ms,w_rest_ms"

## Twin node at the end of both callback lists.
class Tail extends Node:
	var proc_end: int = 0
	var phys_end: int = 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 100000
		process_physics_priority = 100000

	func _process(_d: float) -> void:
		proc_end = Time.get_ticks_usec()

	func _physics_process(_d: float) -> void:
		phys_end = Time.get_ticks_usec()

var _tail: Tail
var _tick_count: int = 0
var _first_phys_us: int = 0
var _phys_script_us: int = 0
var _phys_start_us: int = 0
var _prev_proc_end: int = 0
## per measured frame: [ticks, phys_script, phys_total, proc_script, rest] in ms
var _breakdown: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]

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
## Session state to wait for (-1 = none); Session.State PODIUM = 4, VOTE = 5.
var _wait_state: int = -1
var _transitions: bool = false
## Transitions: finished rounds [id, load_ms, first_frame_ms, hitch_ms] and the open one.
var _loads: Array = []
var _open: Dictionary = {}
var _timeout_s: float = 600.0

const WAIT_STATES := {"podium": 4, "vote": 5}
const HITCH_WINDOW_S := 2.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -100000
	process_physics_priority = -100000
	_tail = Tail.new()
	_tail.name = "PerfTail"
	add_child(_tail)
	_warmup = maxf(0.5, float(config.get("perf-warmup", "3")))
	_seconds = maxf(1.0, float(config.get("perf-seconds", "10")))
	_wait_state = int(WAIT_STATES.get(str(config.get("perf-wait", "")), -1))
	_transitions = config.has("perf-transitions")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	if _transitions:
		var session := _session()
		if session:
			session.connect(&"round_intro", _on_round_intro)
	print("perf: %s on %s (%s), warmup %.1f s, measure %.1f s" % [config.get("perf-target", "?"),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_method(), _warmup, _seconds])


func _session() -> Node:
	return get_tree().root.get_node_or_null(^"Session")


func _process(delta: float) -> void:
	if _done:
		return
	var now := Time.get_ticks_usec()
	var scene := get_tree().current_scene
	if _startup_ms < 0 and scene != null and scene.name != &"PerfDriver":
		_startup_ms = Time.get_ticks_msec()  # the target's first frame
	if _transitions:
		_track_transitions(now)
		return
	if _wait_state >= 0:
		var session := _session()
		if session == null or int(session.get(&"state")) != _wait_state:
			_last_us = now
			return
		session.set(&"time_scale", 0.001)
		print("perf: reached state %d at %d ms" % [_wait_state, Time.get_ticks_msec()])
		_wait_state = -1
		_t = 0.0
		_last_us = now
		return
	_t += delta
	if not _measuring:
		if _t >= _warmup:
			_begin()
		_last_us = now
		_tick_count = 0
		_phys_script_us = 0
		_phys_start_us = 0
		_prev_proc_end = now
		return
	var ms := float(now - _last_us) / 1000.0
	_last_us = now
	_frame_ms.append(ms)
	# breakdown: this frame's physics ticks, the previous frame's process scripts, the rest
	_close_tick()
	var phys_total := float(now - _first_phys_us) / 1000.0 if _tick_count > 0 else 0.0
	var proc_script := float(_tail.proc_end - _prev_proc_end) / 1000.0 if _prev_proc_end > 0 and _tail.proc_end > _prev_proc_end else 0.0
	_breakdown[0].append(_tick_count)
	_breakdown[1].append(float(_phys_script_us) / 1000.0)
	_breakdown[2].append(phys_total)
	_breakdown[3].append(proc_script)
	_breakdown[4].append(maxf(ms - phys_total - proc_script, 0.0))
	_tick_count = 0
	_phys_script_us = 0
	_prev_proc_end = now
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


func _physics_process(_delta: float) -> void:
	if not _measuring or _done:
		return
	var now := Time.get_ticks_usec()
	_close_tick()
	if _tick_count == 0:
		_first_phys_us = now
	_tick_count += 1
	_phys_start_us = now


## Adds the last physics tick's script time (probe start -> tail end).
func _close_tick() -> void:
	if _phys_start_us > 0 and _tail.phys_end >= _phys_start_us:
		_phys_script_us += _tail.phys_end - _phys_start_us
	_phys_start_us = 0


## Diagnostics: `--perf-hide=NameA,NameB` hides every node so named (and `lights` every Omni /
## Spot light) at the start of the measurement, to see what a part of a scene costs.
func _apply_hide() -> void:
	var names := str(config.get("perf-hide", ""))
	if names == "":
		return
	var scene := get_tree().current_scene
	for nm in names.split(",", false):
		if nm == "lights":
			for l in get_tree().root.find_children("*", "Light3D", true, false):
				if not l is DirectionalLight3D:
					(l as Light3D).visible = false
			continue
		for n in get_tree().root.find_children(nm, "Node3D", true, false):
			(n as Node3D).visible = false
	print("perf: hid %s in %s" % [names, scene.name if scene else "?"])


func _begin() -> void:
	_apply_hide()
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
	# breakdown: all frames, then the worst 1 % (by frame time)
	var order: Array[int] = []
	for i in n:
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return _frame_ms[a] > _frame_ms[b])
	var worst_idx := order.slice(0, worst)
	var gsort := _gpu_ms.duplicate()
	gsort.sort()
	row.append(_f(gsort[gsort.size() / 2] if not gsort.is_empty() else 0.0))  # gpu median
	for k in _breakdown.size():
		row.append(_f(_mean(_breakdown[k])))
	for k in _breakdown.size():
		var s := 0.0
		var c := 0
		for i in worst_idx:
			if i < _breakdown[k].size():
				s += _breakdown[k][i]
				c += 1
		row.append(_f(s / maxf(c, 1)))
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
	if config.has("perf-census"):
		_print_census(get_tree().current_scene, 0)
	var shot := str(config.get("perf-shot", ""))
	if shot != "":
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute(shot.get_base_dir())
		img.save_png(shot)
		print("perf: saved %s" % shot)
	get_tree().quit(0)


## RenderCensus of `n` and (three levels down) of every child worth over 40 estimated draws.
func _print_census(n: Node, depth: int) -> void:
	if n == null or depth > 3:
		return
	var census: Script = load("res://look/render_census.gd")
	for line in str(census.call(&"report", n)).split("\n"):
		print("perf: census %s%s" % ["  ".repeat(depth), line])
	for ch in n.get_children():
		if int((census.call(&"count", ch) as Dictionary)["est_draws"]) > 40:
			_print_census(ch, depth + 1)


# --- Transitions ----------------------------------------------------------------------------

## Fires inside the (physics-step) RPC right after the stage loaded the round's minigame.
func _on_round_intro(info: Dictionary, _index: int) -> void:
	_close_open()
	var now := Time.get_ticks_usec()
	_open = {"id": str(info.get("id", "?")), "t0": _last_us, "load": float(now - _last_us) / 1000.0,
		"first": -1.0, "first_us": 0, "hitch": 0.0, "prev": 0}
	await RenderingServer.frame_post_draw
	if not _open.is_empty() and _open["first"] < 0.0:
		var t := Time.get_ticks_usec()
		_open["first"] = float(t - int(_open["t0"])) / 1000.0
		_open["first_us"] = t
		_open["prev"] = t


func _track_transitions(now: int) -> void:
	_t += float(now - _last_us) / 1000000.0 if _last_us > 0 else 0.0
	_last_us = now
	if not _open.is_empty() and int(_open["first_us"]) > 0:
		var prev := int(_open["prev"])
		if prev > 0 and now > prev:
			_open["hitch"] = maxf(float(_open["hitch"]), float(now - prev) / 1000.0)
		_open["prev"] = now
		if now - int(_open["first_us"]) > int(HITCH_WINDOW_S * 1000000.0):
			_close_open()
	var session := _session()
	var state := int(session.get(&"state")) if session else -1
	if (state == 4 and _open.is_empty() and not _loads.is_empty()) or _t > _timeout_s:
		_write_loads()


func _close_open() -> void:
	if _open.is_empty():
		return
	_loads.append([_open["id"], _open["load"], _open["first"], _open["hitch"]])
	print("perf: load %s %.1f ms, first frame %.1f ms, worst next %.1f s %.1f ms" % [
		_open["id"], _open["load"], _open["first"], HITCH_WINDOW_S, _open["hitch"]])
	_open = {}


func _write_loads() -> void:
	_done = true
	_close_open()
	var label := str(config.get("perf-label", "run"))
	var quality := str(config.get("quality", "default"))
	var out := str(config.get("perf-load-out", ""))
	var lines: PackedStringArray = []
	for r: Array in _loads:
		lines.append("%s,%s,%s,%s,%s,%s" % [label, quality, r[0], _f(r[1], 1), _f(r[2], 1), _f(r[3], 1)])
		print("perf: loadrow " + lines[lines.size() - 1])
	if out != "":
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var fresh := not FileAccess.file_exists(out)
		var f := FileAccess.open(out, FileAccess.WRITE if fresh else FileAccess.READ_WRITE)
		if f:
			f.seek_end()
			if fresh:
				f.store_line("label,quality,minigame,load_ms,first_frame_ms,hitch_ms")
			for l in lines:
				f.store_line(l)
			f.close()
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
