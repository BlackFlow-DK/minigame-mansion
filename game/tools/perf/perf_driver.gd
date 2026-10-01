extends Node
## Profiling driver for tools/perf-run.ps1. Run it windowed (headless cannot render):
##
##   godot --path game --windowed --resolution 1280x720 res://tools/perf/perf_driver.tscn --
##     --perf-target=title|lobby|sandbox [--minigame=<id> --players=8] [--quality=low|medium|high]
##     [--perf-seconds=10] [--perf-warmup=3] [--perf-out=<abs .csv>] [--perf-label=x] [--perf-shot=<abs .png>]
##     --fps=0   (a Settings/MainApp dev arg: no settings file, no profile, uncapped)
##
## It puts a PerfProbe on the root (it outlives scene changes) and then switches to the target:
##   title    res://main/main.tscn as is (the live hall behind the title)
##   lobby    res://main/main.tscn; pass --offline --bots=7 --name=Perf for the 8-player hall
##   sandbox  res://dev/sandbox.tscn (reads --minigame / --players itself)
## The probe warms up, measures, appends one CSV row, optionally saves a PNG and quits.

const PROBE := preload("res://tools/perf/perf_probe.gd")
const TARGETS := {
	"title": "res://main/main.tscn",
	"lobby": "res://main/main.tscn",
	"sandbox": "res://dev/sandbox.tscn",
}


func _ready() -> void:
	# engine + autoloads are up here; the probe's startup_ms adds the target scene's load
	print("perf: driver ready at %d ms (engine + autoloads)" % Time.get_ticks_msec())
	var cfg := parse_args(OS.get_cmdline_user_args())
	cfg["engine-ms"] = str(Time.get_ticks_msec())
	var target := str(cfg.get("perf-target", "sandbox"))
	if not TARGETS.has(target):
		printerr("perf: unknown --perf-target=%s" % target)
		get_tree().quit(3)
		return
	var probe: Node = PROBE.new()
	probe.name = "PerfProbe"
	probe.set(&"config", cfg)
	get_tree().root.add_child.call_deferred(probe)
	get_tree().change_scene_to_file.call_deferred(TARGETS[target])


## `--key=value` / `--flag` -> {key: value | ""}.
static func parse_args(args: PackedStringArray) -> Dictionary:
	var out := {}
	for arg in args:
		if arg.begins_with("--"):
			var kv := arg.trim_prefix("--").split("=", true, 1)
			out[kv[0]] = kv[1] if kv.size() > 1 else ""
	return out
