extends Node
## Headless balance batch driver (main scene of a run, so autoloads exist).
## Run through tools/balance-batch.ps1, or directly:
##   godot_console --headless --fixed-fps 60 --path game res://tools/balance/balance_batch.tscn --
##       --minigame=<id>|all --players=2,4,8 --rounds=30 --seed=1 [--verbose]
##       [--set=shove.force=8;minigame.collapse_start=25]   (experiments, see runner.overrides)
## Prints `balance_runner.gd`'s report per (minigame, player count) plus one BALANCE_JSON line
## each, then quits (exit 1 on bad arguments or when a round never ended).

const Runner := preload("res://tools/balance/balance_runner.gd")


func _ready() -> void:
	var ids: Array[StringName] = []
	var counts: Array[int] = [4]
	var rounds := 30
	var seed_value := 1
	var verbose := false
	var overrides := {}
	var lean := true
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		var key := kv[0]
		var value := kv[1] if kv.size() > 1 else ""
		match key:
			"minigame":
				if value == "" or value == "all":
					ids.assign(MinigameRegistry.IDS)
				else:
					for v in value.split(",", false):
						ids.append(StringName(v))
			"players":
				counts.clear()
				for v in value.split(",", false):
					counts.append(clampi(v.to_int(), 2, Net.MAX_PLAYERS))
			"rounds":
				rounds = maxi(value.to_int(), 1)
			"seed":
				seed_value = value.to_int()
			"verbose":
				verbose = true
			"full":
				lean = false
			"set":
				# "shove.force=8;minigame.collapse_start=25" (values in Godot syntax)
				for pair in value.split(";", false):
					var p := pair.split("=", true, 1)
					if p.size() == 2 and p[0].contains("."):
						overrides[p[0].strip_edges()] = str_to_var(p[1].strip_edges())
					else:
						printerr("balance: bad --set entry '%s'" % pair)
						get_tree().quit(1)
						return
	if ids.is_empty():
		ids.assign(MinigameRegistry.IDS)
	for id in ids:
		if not MinigameRegistry.has(id):
			printerr("balance: unknown minigame '%s' (ids: %s)" % [id, MinigameRegistry.IDS])
			get_tree().quit(1)
			return
	await get_tree().process_frame
	var runner := Runner.new()
	runner.verbose = verbose
	runner.overrides = overrides
	runner.lean = lean
	if not overrides.is_empty():
		print("balance: overrides %s" % str(overrides))
	add_child(runner)
	var never := 0
	for id in ids:
		for n in counts:
			var t0 := Time.get_ticks_msec()
			var stats: Dictionary = await runner.run_batch(id, n, rounds, seed_value)
			print(Runner.report(stats))
			print("   (%.0f s wall)" % ((Time.get_ticks_msec() - t0) / 1000.0))
			print(Runner.json_line(stats))
			never += int(stats["never"])
	get_tree().quit(1 if never > 0 else 0)
