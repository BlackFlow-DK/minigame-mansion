extends Node
## Balance batches: whole bot-only rounds of one minigame, played through the real Session
## flow (scoring table, time-limit backstop with tied survivors), measured per slot.
## Used by `balance_batch.tscn` (tools/balance-batch.ps1) and by tests/test_balance*.gd.
##
## Every slot, slot 0 too, is a bot with the normal controller-owned BotBrain. Bot
## personalities (skill, aggression) are rotated over the slots in blocks of `players`
## rounds (a Latin square), so over a batch every slot plays every personality equally
## often and a slot's win rate measures only its seat: spawn point, slot-ordered rules.
## Rounds run at 60 physics ticks per game second (no time scaling: the lengths are real);
## headless with --fixed-fps 60 that is as fast as the CPU allows.
##
##   var runner := preload("res://tools/balance/balance_runner.gd").new()
##   add_child(runner)
##   var stats: Dictionary = await runner.run_batch(&"hot_potato", 4, 30, 1)
##   print(runner.report(stats))

const STAGE_SCENE: PackedScene = preload("res://stage/stage.tscn")
## A round still running this long after its time limit (or after NO_LIMIT_CAP s without
## one) is counted as "never ends" and abandoned.
const NEVER_ENDS_AFTER := 15.0
const NO_LIMIT_CAP := 240.0
## Coin Scramble style games: the in-round leader is sampled at this fraction of the limit.
const LEADER_SAMPLE := 0.6
## A knock-out this soon after a hit from another player counts as "shoved out".
const SHOVED_WINDOW := 2.0
const LEAN_PAUSED: Array[StringName] = [&"visuals", &"fx", &"sfx", &"cosmetics"]

## Prints one line per round while running.
var verbose: bool = false
## Experiments without editing files: "<target>.<property>" -> value, applied every round
## after the minigame's `_setup` (so they win over its tuning) and before `_start`.
## Target `minigame`, or a player component name (`shove`, `movement`, `jump`, `status`).
var overrides: Dictionary = {}
## Speed: pause the players' presentation components (LEAN_PAUSED). They only listen and
## draw, so the rounds play out identically (same seed, same rankings), just faster.
var lean: bool = true

var _stage: Stage = null
var _saved: Dictionary = {}

# Per-round scratch, filled by signal handlers.
var _round: Dictionary = {}


# --- Batches ------------------------------------------------------------------------------

## Plays `rounds` rounds of `id` with `players` bots. Returns the stats Dictionary that
## `report` prints (see `_new_stats` for the fields).
func run_batch(id: StringName, players: int, rounds: int, seed_value: int) -> Dictionary:
	var scene := load(MinigameRegistry.scene_path(id)) as PackedScene
	var stats := _new_stats(id, players, rounds, seed_value)
	if scene == null:
		push_error("balance: no scene for '%s'" % id)
		return stats
	_begin()
	var personalities: Array[int] = []
	var block_rng := RandomNumberGenerator.new()
	for r in rounds:
		if r % players == 0:
			block_rng.seed = hash([seed_value, id, players, floori(float(r) / players)])
			personalities.clear()
			for s in players:
				personalities.append(block_rng.randi())
		var brain_seeds: Array[int] = []
		for s in players:
			brain_seeds.append(personalities[(s + r) % players])
		var round_seed: int = hash([seed_value, id, players, r, "round"])
		var result: Dictionary = await _play_round(scene, players, round_seed, brain_seeds)
		_add_round(stats, result)
		if verbose:
			print("  %s p=%d r=%d: %.1f s, ranking %s, winners %s%s" % [id, players, r,
				result["seconds"], str(result["ranking"]), str(result["winners"]),
				" (never ended)" if result["never"] else (" (time limit)" if result["timeout"] else "")])
	_end()
	return stats


func _new_stats(id: StringName, players: int, rounds: int, seed_value: int) -> Dictionary:
	var places: Array = []
	for s in players:
		var row: Array[int] = []
		row.resize(players)
		row.fill(0)
		places.append(row)
	var zeros_f: Array[float] = []
	zeros_f.resize(players)
	zeros_f.fill(0.0)
	var zeros_i: Array[int] = []
	zeros_i.resize(players)
	zeros_i.fill(0)
	return {
		"id": String(id), "players": players, "rounds": 0, "requested": rounds, "seed": seed_value,
		"time_limit": 0.0,
		"lengths": [] as Array[float],       # seconds per round
		"timeouts": 0,                       # rounds ended by the time limit (normal for timed games)
		"never": 0,                          # rounds abandoned: still running well past the limit
		"wins": zeros_f.duplicate(),         # per slot; tied winners share one win
		"places": places,                    # [slot][place index] -> count
		"points": zeros_i.duplicate(),       # per slot, Session's points table
		"round_points": [] as Array,         # per round: slot -> points
		"ko_times": [] as Array[float],      # every knock-out, seconds into the round
		"ko_shoved": 0,                      # knock-outs within SHOVED_WINDOW of a player's hit
		"first_ko": [] as Array[float],      # per round with a knock-out
		"leader_samples": 0,                 # rounds where a leader was sampled (coin games)
		"leader_held": 0.0,                  # ...and how often that leader won (shared)
		"holds": [] as Array[float],         # hot potato: seconds each bomb was held
		"explode_holds": [] as Array[float], # hot potato: bomb age at explosion from the last hand-over
	}


func _add_round(stats: Dictionary, r: Dictionary) -> void:
	stats["rounds"] += 1
	stats["time_limit"] = r["time_limit"]
	(stats["lengths"] as Array).append(r["seconds"])
	if r["timeout"]:
		stats["timeouts"] += 1
	if r["never"]:
		stats["never"] += 1
	var winners: Array = r["winners"]
	for w: int in winners:
		stats["wins"][w] += 1.0 / winners.size()
	var ranking: Array = r["ranking"]
	var places: Array = stats["places"]
	for i in ranking.size():
		var s: int = ranking[i]
		# Tied winners all count as first place.
		var place := 0 if winners.has(s) else i
		if s < places.size():
			places[s][mini(place, stats["players"] - 1)] += 1
	var pts: Dictionary = r["points"]
	for s: int in pts:
		if s < stats["points"].size():
			stats["points"][s] += int(pts[s])
	(stats["round_points"] as Array).append(pts)
	(stats["ko_times"] as Array).append_array(r["ko_times"])
	stats["ko_shoved"] += int(r["ko_shoved"])
	if not (r["ko_times"] as Array).is_empty():
		(stats["first_ko"] as Array).append((r["ko_times"] as Array).min())
	if r["leader"] != []:
		stats["leader_samples"] += 1
		var shared := 0.0
		for l: int in r["leader"]:
			if winners.has(l):
				shared += 1.0 / (r["leader"] as Array).size()
		stats["leader_held"] += shared
	(stats["holds"] as Array).append_array(r["holds"])
	(stats["explode_holds"] as Array).append_array(r["explode_holds"])


# --- One round ------------------------------------------------------------------------------

func _play_round(scene: PackedScene, count: int, round_seed: int, brain_seeds: Array[int]) -> Dictionary:
	seed(round_seed)
	Net.start_offline()
	for i in count - 1:
		Net.add_bot()
	(Net.roster[0] as PlayerInfo).is_bot = true  # the host's seat is a bot like the rest
	Session.scene_override = scene
	_round = {
		"seconds": 0.0, "ranking": [], "points": {}, "winners": [], "timeout": false, "never": false,
		"time_limit": 0.0, "ko_times": [] as Array[float], "leader": [], "holds": [] as Array[float],
		"explode_holds": [] as Array[float], "ko_shoved": 0, "done": false, "start_frame": -1, "brain_seeds": brain_seeds,
		"round_seed": round_seed, "last_hand": -1.0, "leader_taken": false,
	}
	var on_intro := func(_info: Dictionary, _index: int) -> void: _on_intro()
	var on_start := func() -> void: _round["start_frame"] = Engine.get_physics_frames()
	var on_finish := func(ranking: Array[int], points: Dictionary) -> void: _on_finished(ranking, points)
	Session.round_intro.connect(on_intro)
	Session.round_started.connect(on_start)
	Session.round_finished.connect(on_finish)
	Session.start_session(1)
	var cap := 0.0
	var tick := 1.0 / Engine.physics_ticks_per_second
	while not _round["done"]:
		await get_tree().physics_frame
		var mg := Session.current_minigame
		if _round["start_frame"] < 0 or not is_instance_valid(mg):
			if Session.state == Session.State.LOBBY:
				break  # the session ended without a result (should not happen)
			continue
		var t := _now()
		if cap == 0.0:
			cap = (mg.time_limit + NEVER_ENDS_AFTER) if mg.time_limit > 0.0 else NO_LIMIT_CAP
			_round["time_limit"] = mg.time_limit
		_sample_leader(mg, t)
		if t > cap:
			_round["never"] = true
			_round["seconds"] = t
			break
	Session.round_intro.disconnect(on_intro)
	Session.round_started.disconnect(on_start)
	Session.round_finished.disconnect(on_finish)
	Session.abort_session()
	await get_tree().physics_frame
	Net.leave()
	return _round.duplicate()


## Seconds of play in the current round.
func _now() -> float:
	return float(Engine.get_physics_frames() - int(_round["start_frame"])) / Engine.physics_ticks_per_second


## Every round: seed the minigame and the brains, hook the per-round measurements.
func _on_intro() -> void:
	var mg := Session.current_minigame
	if mg == null:
		return
	var s: int = _round["round_seed"]
	if &"rng_seed" in mg:
		mg.set(&"rng_seed", absi(s) % 1000000 + 1)  # 0 / -1 mean random in the minigames
	if &"goal_seed" in mg:
		mg.set(&"goal_seed", absi(s) % 1000000 + 1)
	var rng: Variant = mg.get(&"rng")
	if rng is RandomNumberGenerator:
		(rng as RandomNumberGenerator).seed = s
	for key: String in overrides:
		var parts := key.split(".", true, 1)
		if parts[0] == "minigame":
			mg.set(StringName(parts[1]), overrides[key])
		else:
			for p in mg.players:
				var comp := p.get_component(StringName(parts[0]))
				if comp:
					comp.set(StringName(parts[1]), overrides[key])
	if lean:
		for p in mg.players:
			for comp_name in LEAN_PAUSED:
				var comp := p.get_component(comp_name)
				if comp:
					comp.process_mode = Node.PROCESS_MODE_DISABLED
	var seeds: Array[int] = _round["brain_seeds"]
	for p in mg.players:
		var c := p.get_component(&"controller") as ControllerComponent
		if c and c.brain and c.brain.has_method(&"configure"):
			c.brain.call(&"configure", seeds[p.slot % seeds.size()])
		var last_hit := [-INF]
		p.got_hit.connect(func(_impulse: Vector3, source_slot: int) -> void:
			if source_slot >= 0:
				last_hit[0] = _now())
		p.eliminated.connect(func(reason: StringName) -> void:
			if int(_round["start_frame"]) >= 0:
				var t := _now()
				(_round["ko_times"] as Array).append(t)
				if t - float(last_hit[0]) <= SHOVED_WINDOW:
					_round["ko_shoved"] = int(_round["ko_shoved"]) + 1
				if verbose:
					print("    out: slot %d at %.1f s (%s%s)" % [p.slot, t, reason,
						", shoved %.1f s before" % (t - float(last_hit[0])) if t - float(last_hit[0]) <= SHOVED_WINDOW else ""]))
	if mg.has_signal(&"bomb_given"):
		mg.connect(&"bomb_given", func(_slot: int) -> void: _round["last_hand"] = _now())
		mg.connect(&"bomb_passed", func(_f: int, _t: int, _k: int) -> void:
			(_round["holds"] as Array).append(_now() - float(_round["last_hand"]))
			_round["last_hand"] = _now())
		mg.connect(&"bomb_exploded", func(_slot: int) -> void:
			(_round["explode_holds"] as Array).append(_now() - float(_round["last_hand"])))


func _on_finished(ranking: Array[int], points: Dictionary) -> void:
	_round["ranking"] = ranking.duplicate()
	_round["points"] = points.duplicate()
	var winners: Array[int] = []
	for s: int in Session.round_wins:
		if Session.round_wins[s] > 0:
			winners.append(s)
	winners.sort()
	_round["winners"] = winners
	var t := _now()
	_round["seconds"] = t
	var limit: float = _round["time_limit"]
	if limit <= 0.0 and is_instance_valid(Session.current_minigame):
		limit = Session.current_minigame.time_limit
		_round["time_limit"] = limit
	_round["timeout"] = limit > 0.0 and t >= limit - 0.05
	_round["done"] = true


## Games with a per-slot score (`coins`): who leads at LEADER_SAMPLE of the time limit.
func _sample_leader(mg: Minigame, t: float) -> void:
	if _round["leader_taken"] or mg.time_limit <= 0.0 or t < mg.time_limit * LEADER_SAMPLE:
		return
	_round["leader_taken"] = true
	var score: Variant = mg.get(&"coins")
	if not score is Dictionary or (score as Dictionary).is_empty():
		return
	var best := -1
	var lead: Array[int] = []
	for s: int in score:
		var v: int = score[s]
		if v > best:
			best = v
			lead = [s]
		elif v == best:
			lead.append(s)
	if best > 0:
		_round["leader"] = lead


# --- Setup / teardown -------------------------------------------------------------------------

func _begin() -> void:
	Session.abort_session()
	for k in [&"intro_time", &"countdown_time", &"results_time", &"podium_time", &"time_scale", &"order_seed"]:
		_saved[k] = Session.get(k)
	_saved[&"scene_override"] = Session.scene_override
	Session.intro_time = 0.0
	Session.countdown_time = 0.0
	Session.results_time = 0.0
	Session.podium_time = 0.0
	Session.time_scale = 1.0
	Session.order_seed = 1
	_stage = STAGE_SCENE.instantiate() as Stage
	_stage.name_tags = false
	add_child(_stage)


func _end() -> void:
	Session.abort_session()
	for k: StringName in _saved:
		Session.set(k, _saved[k])
	_saved.clear()
	if _stage:
		_stage.clear()
		remove_child(_stage)
		_stage.queue_free()
		_stage = null
	Net.leave()


# --- Report ---------------------------------------------------------------------------------

## Max share of wins any one slot took (0..1).
static func max_win_share(stats: Dictionary) -> float:
	var n: int = maxi(stats["rounds"], 1)
	var best := 0.0
	for w: float in stats["wins"]:
		best = maxf(best, w / n)
	return best


static func median(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var v := values.duplicate()
	v.sort()
	var m := v.size() / 2
	return float(v[m]) if v.size() % 2 == 1 else (float(v[m - 1]) + float(v[m])) * 0.5


static func mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for x in values:
		total += float(x)
	return total / values.size()


## Human-readable block for one batch.
static func report(stats: Dictionary) -> String:
	var n: int = stats["players"]
	var rounds: int = stats["rounds"]
	var lines: PackedStringArray = []
	var lengths: Array = stats["lengths"]
	lines.append("== %s  players=%d  rounds=%d  seed=%d" % [stats["id"], n, rounds, stats["seed"]])
	if rounds == 0:
		lines.append("   no rounds played")
		return "\n".join(lines)
	lines.append("   length s: mean %.1f  median %.1f  min %.1f  max %.1f  (limit %.0f; %d ended by the limit; %d never ended)" % [
		mean(lengths), median(lengths), lengths.min(), lengths.max(), stats["time_limit"], stats["timeouts"], stats["never"]])
	var win_parts: PackedStringArray = []
	var place_parts: PackedStringArray = []
	var pts_parts: PackedStringArray = []
	var totals: Array = stats["points"]
	for s in n:
		win_parts.append("%d:%4.1f%%" % [s, 100.0 * float(stats["wins"][s]) / rounds])
		var row: Array = stats["places"][s]
		var sum := 0.0
		var cnt := 0
		for p in row.size():
			sum += float(p + 1) * row[p]
			cnt += row[p]
		place_parts.append("%d:%.2f" % [s, sum / maxi(cnt, 1)])
		pts_parts.append("%d:%.2f" % [s, float(totals[s]) / rounds])
	lines.append("   win rate by slot (fair %.1f%%): %s   max %.1f%%" % [100.0 / n, "  ".join(win_parts), 100.0 * max_win_share(stats)])
	lines.append("   mean place by slot (fair %.2f): %s" % [(n + 1) * 0.5, "  ".join(place_parts)])
	lines.append("   points/round by slot: %s   total spread %d..%d" % ["  ".join(pts_parts), totals.min(), totals.max()])
	var hist: PackedStringArray = []
	for s in n:
		hist.append("%d%s" % [s, str(stats["places"][s])])
	lines.append("   places (slot[1st, 2nd, ...]): %s" % "  ".join(hist))
	var kos: Array = stats["ko_times"]
	if not kos.is_empty():
		lines.append("   knock-outs at s: first median %.1f  all median %.1f  (%d total, %d%% shoved out)" % [
			median(stats["first_ko"]), median(kos), kos.size(), roundi(100.0 * int(stats["ko_shoved"]) / kos.size())])
	if int(stats["leader_samples"]) > 0:
		lines.append("   leader at %d%% of the time wins: %.0f%% of %d rounds" % [
			int(LEADER_SAMPLE * 100.0), 100.0 * float(stats["leader_held"]) / int(stats["leader_samples"]), stats["leader_samples"]])
	var holds: Array = stats["holds"]
	if not holds.is_empty() or not (stats["explode_holds"] as Array).is_empty():
		lines.append("   bomb holds before a pass s: mean %.2f  median %.2f (%d passes); held to the blast: mean %.2f s" % [
			mean(holds), median(holds), holds.size(), mean(stats["explode_holds"])])
	return "\n".join(lines)


## One machine-readable line (prefix BALANCE_JSON) with the headline numbers.
static func json_line(stats: Dictionary) -> String:
	var rounds: int = maxi(stats["rounds"], 1)
	var win_rates: Array = []
	for w: float in stats["wins"]:
		win_rates.append(snappedf(w / rounds, 0.001))
	var lengths: Array = stats["lengths"]
	var d := {
		"id": stats["id"], "players": stats["players"], "rounds": stats["rounds"], "seed": stats["seed"],
		"len_mean": snappedf(mean(lengths), 0.1), "len_median": snappedf(median(lengths), 0.1),
		"len_min": snappedf(lengths.min() if not lengths.is_empty() else 0.0, 0.1),
		"len_max": snappedf(lengths.max() if not lengths.is_empty() else 0.0, 0.1),
		"timeouts": stats["timeouts"], "never": stats["never"], "win_rates": win_rates,
		"points": stats["points"], "places": stats["places"],
	}
	return "BALANCE_JSON " + JSON.stringify(d)
