class_name GhostTag
extends Minigame
## Ghost Tag: infection tag in the mansion attic at night, 60 s.
##
## Rules (the host decides, every peer is told by reliable call_local RPCs):
## - One random player starts as THE GHOST (two with 7-8 players). The others get a 3 s head
##   start: the ghost is frozen ("The ghost wakes in 3...").
## - A ghost touching a living blob (flat centre distance under `touch_distance`) or landing a
##   shove on one CATCHES it: both freeze for a 0.6 s "boo!", then the victim is a ghost too and
##   rises for `rise_time` (1 s, still frozen) before it can hunt.
## - Ghosts run 6 % faster. Living blobs can shove each other; a living shove on a ghost only
##   pushes it a little (`ghost_knockback`) and stuns it `ghost_shove_stun` s, during which it
##   cannot catch: a defence, not a kill.
## - The round ends at 60 s, or as soon as nobody is left alive (end grace 2 s).
##
## Ranking (`rank_groups`, every player gets a "time" and the higher time ranks better):
## - survivors: the full round (60 s): they share first place (one tied group);
## - caught players: the round time at which they were caught (longer = better);
## - the ORIGINAL ghost(s): placed as if they had survived `credit / (players - 1)` of the
##   round, where `credit` counts every catch the ghosts made (the starting ghosts' own count 1, the turned ghosts' `chain_credit`;
##   with two starting ghosts both get the team's credit). Ghosts that caught everyone rank
##   first; ghosts that caught nobody rank last.
## - equal times share a place (tied group).
## HUD counter: living blobs show the seconds survived (caught blobs keep theirs), the original
## ghosts show their credited catches.
##
## Presentation (every peer): `ghost_looks.gd` (lanterns, ghost look, lights, the night veil);
## the attic is built in code from `ghost_map.gd` in _ready (identical everywhere).
## Bots (host): living bots flee through the loop from the ghosts they notice (never into a
## dead-end room with a ghost near, preferring junctions, away from each other), ghosts chase
## the nearest living blob they can sense by path, else prowl; both steer by a 0.5 m grid
## (ghost_map.gd). The sense ranges are the bot balance knobs (test_ghost_tag_bots.gd).
## Dev args (after `--`): `--ghost-time-scale=<x>` (round clock), `--ghost-pose=mid|late`
## (screenshots: more ghosts at the start).

## Every peer: `slot` became a ghost; `from_slot` -1 = a starting ghost.
signal ghost_made(slot: int, from_slot: int)
## Every peer: `ghost_slot` caught `victim_slot` at round time `at` (ghost_slot -1: left the game).
signal caught(ghost_slot: int, victim_slot: int, at: float)
## Every peer: the boo is over, `slot` is a ghost now.
signal converted(slot: int)
## Every peer: the head start is over.
signal ghosts_woke
## Every peer: the round is decided (flat ranking, best first).
signal round_over(ranking: Array[int])

const GhostMap := preload("res://minigames/ghost_tag/ghost_map.gd")
const GhostLooks := preload("res://minigames/ghost_tag/ghost_looks.gd")
const PROPS := "res://assets/models/props/"

# --- Rules -----------------------------------------------------------------------------------
## Seconds the starting ghost stays frozen after GO.
@export var head_start: float = 3.0
## Seconds of the "boo!" freeze (ghost and victim) before the victim turns.
@export var boo_time: float = 0.6
## Seconds a freshly turned ghost stays frozen after its boo while it rises (its sheet grows),
## so a huddle can scatter before the next catch (balance: without it 8-player rounds were
## a chain-reaction wipe-out in ~25 s).
@export var rise_time: float = 1.0
## Ghost and living centres closer than this (m, flat) = a catch (blobs touch at 0.8).
@export var touch_distance: float = 1.0
## Ghost speed over the living.
@export var ghost_speed_bonus: float = 1.06
## A ghost's knockback multiplier (living shoves only nudge it).
@export var ghost_knockback: float = 0.35
## Stun (s) a ghost gets from any hit.
@export var ghost_shove_stun: float = 0.4
## Seconds the end is held (frozen) before the results.
@export var end_grace: float = 2.0
## How much a catch by a ghost's chain counts for the original ghost (its own catches count 1).
@export var chain_credit: float = 1.0
## Bots: how much a fleeing bot prefers junctions over ring corners (cells of ghost distance).
@export var flee_open_weight: float = 8.0
## Bots: a lone ghost bot senses living blobs within this path distance (m), or in plain sight
## within 1.4x that (lanterns in the dark); otherwise it prowls the loop.
@export var bot_sense_range: float = 12.0
## Bots: with N >= 2 ghosts each senses this / N (a big pack hunts no faster than a small one).
@export var bot_pack_sense: float = 14.0
## Bots: a living bot notices ghosts within this path distance (m) or in plain sight within
## 1.4x that; ghosts further away do not worry it yet (it holds a junction). 0 = sees all.
@export var bot_living_sense: float = 8.0

## The round music (an existing track; the night jazz suits a sneaky chase).
var music_track: StringName = &"vault_jazz"
## Test/dev only: multiplies the round clock on the host (head start, boos, time limit).
var time_scale: float = 1.0
## Host randomness (who starts as the ghost).
var rng := RandomNumberGenerator.new()
## Tests: seeds the next instance's rng in _ready (before _setup draws the ghosts); -1 = random.
static var seed_next: int = -1
## The attic layout (every peer).
var map: GhostMap = GhostMap.new()

# --- Every peer (from the host's RPCs) ---------------------------------------------------------
## slot -> true for every ghost (starting and turned; not a victim still in its boo).
var ghosts: Dictionary[int, bool] = {}
## The starting ghosts.
var original_ghosts: Array[int] = []
## slot -> round time it was caught at.
var caught_at: Dictionary[int, float] = {}
## original ghost slot -> credited catches (own + chain_credit x chain).
var credit: Dictionary[int, float] = {}
## ghost slot -> catches it made itself.
var own_catches: Dictionary[int, int] = {}
## ghost slot -> the starting ghost whose chain it belongs to.
var lineage: Dictionary[int, int] = {}
var awake: bool = false
var over: bool = false
## Host and every peer after the end: the ranking as tied groups.
var final_groups: Array = []

# Host state.
var _t: float = 0.0
var _running: bool = false
var _boos: Array = []          # [ghost_slot, victim_slot, seconds left]
var _rises: Array = []         # [new ghost slot, seconds left]
var _second: int = 0
var _rethink_ghosts: float = 0.0
var _rethink_living: float = 0.0
var _ghost_field := PackedInt32Array()
var _ghost_field_frame: int = -1000
var _dev_pose: String = ""

# Every peer.
var _slots: Array[int] = []
var _started: bool = false
var _base_speed: Dictionary[int, float] = {}
var _base_knock: Dictionary[int, float] = {}
var _base_stun: Dictionary[int, Vector2] = {}
var _looks: GhostLooks = null
var _wake_clock: float = -1.0
var _wake_shown: int = 0

@onready var _camera: ArenaCamera = get_node_or_null(^"ArenaCamera") as ArenaCamera


func _ready() -> void:
	rng.randomize()
	if seed_next >= 0:
		rng.seed = seed_next
		seed_next = -1
	_build_arena()
	_looks = GhostLooks.new()
	_looks.name = "Looks"
	add_child(_looks)
	var windows: Array[Vector4] = []
	for x in WINDOW_XS:
		windows.append(Vector4(x, -7.2, 2.6, 0.5))
	_looks.set_static_holes(windows)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ghost-time-scale="):
			time_scale = maxf(arg.trim_prefix("--ghost-time-scale=").to_float(), 0.01)
		elif arg.begins_with("--ghost-pose="):
			_dev_pose = arg.trim_prefix("--ghost-pose=")


func _setup(round_players: Array[Player]) -> void:
	_slots.clear()
	for p in round_players:
		_slots.append(p.slot)
		_base_speed[p.slot] = (p.get_component(&"movement") as MovementComponent).max_speed
		var status := p.get_component(&"status") as StatusComponent
		if status:
			_base_knock[p.slot] = status.knockback_multiplier
			_base_stun[p.slot] = Vector2(status.stun_min, status.stun_max)
		if not p.shove_hit.is_connected(_on_shove_hit):
			p.shove_hit.connect(_on_shove_hit.bind(p))
		RoundUI.push_counter(p.slot, 0)
	_slots.sort()
	_looks.track(round_players)
	if Net.is_host():
		var picks := pick_ghosts(_slots, rng)
		_rpc_ghosts.rpc(PackedInt32Array(picks))
		for s in _slots:
			set_role_text(s, "You are the GHOST" if picks.has(s) else "Run!")


func _start() -> void:
	_started = true
	if not awake:
		for s in original_ghosts:
			_freeze(s, true)
		var who := "The ghosts wake" if original_ghosts.size() > 1 else "The ghost wakes"
		_wake_shown = ceili(head_start)
		_wake_clock = 0.0
		RoundUI.push_banner("%s in %d..." % [who, _wake_shown], 1.0)
	if not Net.is_host():
		return
	_t = 0.0
	_second = 0
	_running = true
	if _dev_pose == "mid" or _dev_pose == "late":
		_rpc_wake.rpc()
		var living := _living_slots()
		var turn := 2 if _dev_pose == "mid" else maxi(living.size() - 2, 0)
		for i in turn:
			var v: int = living[i]
			var g: int = original_ghosts[i % original_ghosts.size()]
			_rpc_catch.rpc(g, v, 0.0, living.size() - i - 1)
			_rpc_convert.rpc(v, g)


## How many start as the ghost: 2 with 7-8 players, else 1.
static func ghost_count_for(player_count: int) -> int:
	return 2 if player_count >= 7 else 1


## Host: the starting ghosts, drawn from `slots` with `r`.
static func pick_ghosts(slots: Array[int], r: RandomNumberGenerator) -> Array[int]:
	var pool := slots.duplicate()
	var out: Array[int] = []
	for i in mini(ghost_count_for(slots.size()), pool.size()):
		var k := r.randi() % pool.size()
		out.append(pool[k])
		pool.remove_at(k)
	out.sort()
	return out


# --- Host: the round -------------------------------------------------------------------------

func _host_tick(delta: float) -> void:
	if not _running or over or is_finished():
		return
	var dt := delta * time_scale
	_t += dt
	if not awake and _t >= head_start:
		_rpc_wake.rpc()
	# boos run out: the victim turns (and rises a moment later)
	var i := 0
	while i < _boos.size():
		_boos[i][2] -= dt
		if _boos[i][2] <= 0.0:
			var b: Array = _boos[i]
			_boos.remove_at(i)
			_rpc_convert.rpc(b[1], b[0], rise_time <= 0.0)
			if rise_time > 0.0:
				_rises.append([b[1], rise_time])
		else:
			i += 1
	i = 0
	while i < _rises.size():
		_rises[i][1] -= dt
		if _rises[i][1] <= 0.0:
			_rpc_rise.rpc(_rises[i][0])
			_rises.remove_at(i)
		else:
			i += 1
	# players who left the game count as caught (no credit)
	for s in _living_slots():
		var p := _player(s)
		if p == null or not p.alive:
			_rpc_catch.rpc(-1, s, _t, _living_slots().size() - 1)
	if awake:
		_check_touches()
	var sec := int(_t)
	if sec != _second:
		_second = sec
		_rpc_second.rpc(sec)
	_bot_cadence(dt)
	if _living_slots().is_empty() and not caught_at.is_empty():
		end_round()
	elif time_limit > 0.0 and _t >= time_limit:
		end_round()


func _check_touches() -> void:
	for g in _slots:
		if not ghosts.get(g, false):
			continue
		var gp := _player(g)
		# frozen (head start, boo, rising) or stunned by a shove: no catching
		if gp == null or not gp.alive or gp.frozen or gp.control_locked or _in_boo(g):
			continue
		var best: Player = null
		var best_d := touch_distance
		for v in _living_slots():
			var vp := _player(v)
			if vp == null or not vp.alive:
				continue
			var to := vp.global_position - gp.global_position
			if absf(to.y) > 1.0:
				continue
			var d := Vector2(to.x, to.z).length()
			if d < best_d:
				best_d = d
				best = vp
		if best:
			catch(gp, best)


## Host: `ghost` catches `victim` now (touch, shove, or a test).
func catch(ghost: Player, victim: Player) -> void:
	if over or is_finished() or ghost == null or victim == null:
		return
	if not ghosts.get(ghost.slot, false) or not is_living(victim.slot):
		return
	var left := _living_slots().size() - 1
	_rpc_catch.rpc(ghost.slot, victim.slot, _t, left)
	_boos.append([ghost.slot, victim.slot, boo_time])
	if left <= 0:
		end_round()


func _on_shove_hit(victim_slot: int, shover: Player) -> void:
	if not Net.is_host() or over or not awake or not _running:
		return
	if not ghosts.get(shover.slot, false) or not is_living(victim_slot):
		return
	if shover.frozen or _in_boo(shover.slot):
		return
	catch(shover, _player(victim_slot))


## Host: ends the round now with the ranking rule (also called at the time limit).
func end_round() -> void:
	if over or is_finished():
		return
	var groups := rank_groups(_slots, original_ghosts, caught_at, credit, time_limit)
	var sizes := PackedInt32Array()
	for g: Array in groups:
		sizes.append(g.size())
	_rpc_end.rpc(PackedInt32Array(flatten_groups(groups)), sizes)
	finish(groups, end_grace)


## The ranking rule (see the header): tied groups, best first.
## `caught`: slot -> round time caught; `credits`: original ghost -> credited catches;
## `round_len`: the full round (survivors' time).
static func rank_groups(slots: Array[int], originals: Array[int], caught: Dictionary, credits: Dictionary,
		round_len: float) -> Array:
	var denom := maxi(1, slots.size() - 1)
	var score: Dictionary = {}
	for s in slots:
		if originals.has(s):
			score[s] = round_len * clampf(float(credits.get(s, 0.0)) / float(denom), 0.0, 1.0)
		elif caught.has(s):
			score[s] = minf(float(caught[s]), round_len)
		else:
			score[s] = round_len
	var order := slots.duplicate()
	order.sort_custom(func(a: int, b: int) -> bool:
		if absf(float(score[a]) - float(score[b])) > 0.0005:
			return float(score[a]) > float(score[b])
		return a < b)
	var groups: Array = []
	var last := INF
	for s in order:
		var v := float(score[s])
		if groups.is_empty() or absf(v - last) > 0.0005:
			groups.append([s] as Array[int])
			last = v
		else:
			(groups[groups.size() - 1] as Array[int]).append(s)
	return groups


## Round time on the host (tests).
func round_time() -> float:
	return _t


## True while `slot` is alive, not a ghost and not caught.
func is_living(slot: int) -> bool:
	return _slots.has(slot) and not ghosts.get(slot, false) and not caught_at.has(slot)


func is_ghost(slot: int) -> bool:
	return ghosts.get(slot, false)


## The looks node (tests: ghost looks, lights).
func looks() -> GhostLooks:
	return _looks


# --- RPCs (host -> every peer) ---------------------------------------------------------------

## Host: replaces the starting ghosts before they wake (tests, dev); roles follow.
func set_starting_ghosts(slots: Array[int]) -> void:
	if not Net.is_host() or awake or over:
		return
	var sorted := slots.duplicate()
	sorted.sort()
	_rpc_ghosts.rpc(PackedInt32Array(sorted))
	for s in _slots:
		set_role_text(s, "You are the GHOST" if sorted.has(s) else "Run!")


@rpc("authority", "call_local", "reliable")
func _rpc_ghosts(slots: PackedInt32Array) -> void:
	for old in original_ghosts:
		ghosts.erase(old)
		lineage.erase(old)
		credit.erase(old)
		own_catches.erase(old)
		_looks.set_ghost(_player(old), false)
		_restore_tuning(old)
		_freeze(old, false)
	original_ghosts.clear()
	for s in slots:
		original_ghosts.append(s)
		ghosts[s] = true
		lineage[s] = s
		credit[s] = 0.0
		own_catches[s] = 0
		var p := _player(s)
		_looks.set_ghost(p, true)
		_apply_tuning(s)
		if p:
			var vis := p.get_component(&"visuals") as VisualsComponent
			if vis:
				vis.set_expression(BlobExpressions.HAPPY)
		if _started and not awake:
			_freeze(s, true)
		ghost_made.emit(s, -1)


@rpc("authority", "call_local", "reliable")
func _rpc_wake() -> void:
	if awake:
		return
	awake = true
	_wake_clock = -1.0
	if not over:
		for s in original_ghosts:
			_freeze(s, false)
	RoundUI.push_banner("BOO! The ghost%s %s awake!" % ["s" if original_ghosts.size() > 1 else "",
		"are" if original_ghosts.size() > 1 else "is"], 1.4)
	Sfx.play(&"stun_wobble")
	for s in original_ghosts:
		var p := _player(s)
		if p:
			Fx.play(&"poof", p.global_position + Vector3.UP * 0.6, GhostLooks.GHOST_COLOR)
	request_bot_rethink()
	ghosts_woke.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_catch(ghost_slot: int, victim_slot: int, at: float, living_left: int) -> void:
	caught_at[victim_slot] = at
	var victim := _player(victim_slot)
	RoundUI.push_counter(victim_slot, int(at))
	if ghost_slot >= 0:
		own_catches[ghost_slot] = int(own_catches.get(ghost_slot, 0)) + 1
		var origin: int = lineage.get(ghost_slot, ghost_slot)
		lineage[victim_slot] = origin
		# every starting ghost is credited with every catch the ghosts make (the ghosts are one
		# team); a catch by a turned ghost counts chain_credit, the starting ghosts' own count 1
		var worth := 1.0 if original_ghosts.has(ghost_slot) else chain_credit
		for o in original_ghosts:
			credit[o] = float(credit.get(o, 0.0)) + worth
			RoundUI.push_counter(o, int(floor(float(credit[o]) + 0.001)))
		var gp := _player(ghost_slot)
		if not over:
			_freeze(ghost_slot, true)
			_freeze(victim_slot, true)
		if gp and victim:
			var mid := (gp.global_position + victim.global_position) * 0.5 + Vector3.UP * 0.8
			Fx.play(&"stun_swirl", victim.global_position + Vector3.UP * 1.0, GhostLooks.GHOST_COLOR)
			Fx.play(&"hit_stars", mid, Color(0.75, 0.88, 1.0))
			Sfx.play(&"hit_bonk", mid)
			var gv := gp.get_component(&"visuals") as VisualsComponent
			if gv:
				gv.set_expression(BlobExpressions.CHEER, boo_time + 0.3)
			var vv := victim.get_component(&"visuals") as VisualsComponent
			if vv:
				vv.set_expression(BlobExpressions.HURT, boo_time + 0.2)
		if _camera:
			_camera.add_shake(0.25)
	var who := _name_of(victim) if victim else "Player %d" % (victim_slot + 1)
	if living_left > 0:
		RoundUI.push_banner("%s was caught! %d left" % [who, living_left], 1.6)
	else:
		RoundUI.push_banner("%s was caught! Nobody left!" % who, 2.0)
	if Net.is_host():
		request_bot_rethink()
	caught.emit(ghost_slot, victim_slot, at)


@rpc("authority", "call_local", "reliable")
func _rpc_convert(victim_slot: int, ghost_slot: int, rise_now: bool = true) -> void:
	ghosts[victim_slot] = true
	if not lineage.has(victim_slot):
		lineage[victim_slot] = lineage.get(ghost_slot, ghost_slot)
	var p := _player(victim_slot)
	if p:
		_looks.set_ghost(p, true, 0.0 if rise_now else rise_time)
		Fx.play(&"poof", p.global_position + Vector3.UP * 0.6, GhostLooks.GHOST_COLOR)
		Sfx.play(&"eliminated_pop", p.global_position)
		var vis := p.get_component(&"visuals") as VisualsComponent
		if vis:
			vis.set_expression(BlobExpressions.HAPPY)
	_apply_tuning(victim_slot)
	if not over:
		if rise_now:
			_freeze(victim_slot, false)
		if ghost_slot >= 0 and not _in_boo(ghost_slot):
			_freeze(ghost_slot, false)
	if Net.is_host():
		request_bot_rethink()
	converted.emit(victim_slot)


## A freshly turned ghost rises (unfreezes) after `rise_time`.
@rpc("authority", "call_local", "reliable")
func _rpc_rise(slot: int) -> void:
	if not over:
		_freeze(slot, false)


@rpc("authority", "call_local", "reliable")
func _rpc_second(sec: int) -> void:
	for s in _slots:
		if is_living(s):
			RoundUI.push_counter(s, sec)


@rpc("authority", "call_local", "reliable")
func _rpc_end(ranking: PackedInt32Array, sizes: PackedInt32Array) -> void:
	over = true
	_wake_clock = -1.0
	var flat: Array[int] = []
	for s in ranking:
		flat.append(s)
	final_groups = groups_from(flat, sizes)
	var survivors: Array[int] = []
	for s in _slots:
		if is_living(s):
			survivors.append(s)
			RoundUI.push_counter(s, int(time_limit))
	# the curse lifts: every ghost turns back into a blob, lanterns go out of hand
	for s in _slots:
		var p := _player(s)
		if p and ghosts.get(s, false):
			Fx.play(&"poof", p.global_position + Vector3.UP * 0.6, GhostLooks.GHOST_COLOR)
	_restore_everyone(true)
	if survivors.is_empty():
		RoundUI.push_banner("The ghosts got everyone!", end_grace)
	else:
		var names: Array[String] = []
		for s in survivors:
			names.append(_name_of(_player(s)))
			var p := _player(s)
			if p:
				var vis := p.get_component(&"visuals") as VisualsComponent
				if vis:
					vis.play_emote(&"cheer")
		var line := "%s survived the night!" % names[0] if names.size() == 1 \
			else "%d survived the night!" % names.size()
		RoundUI.push_banner(line, end_grace)
		Sfx.play(&"round_win_jingle")
	round_over.emit(flat)


static func groups_from(flat: Array[int], sizes: PackedInt32Array) -> Array:
	var out: Array = []
	var k := 0
	for n in sizes:
		var g: Array[int] = []
		for i in n:
			if k < flat.size():
				g.append(flat[k])
				k += 1
		out.append(g)
	return out


# --- Every peer ------------------------------------------------------------------------------

func _process(delta: float) -> void:
	# "The ghost wakes in 3... 2... 1..." (cosmetic, local clock; the host's wake RPC ends it)
	if _wake_clock >= 0.0 and not awake:
		_wake_clock += delta
		var n := ceili(head_start - _wake_clock)
		if n != _wake_shown and n >= 1:
			_wake_shown = n
			RoundUI.push_banner("%s in %d..." % ["The ghosts wake" if original_ghosts.size() > 1
				else "The ghost wakes", n], 1.0)


func _physics_process(_delta: float) -> void:
	# Tuning on every peer (only the authority's copy matters): ghosts run a little faster.
	if over:
		return
	for p in players:
		if not is_instance_valid(p) or not _base_speed.has(p.slot):
			continue
		var move := p.get_component(&"movement") as MovementComponent
		if move:
			move.max_speed = _base_speed[p.slot] * (ghost_speed_bonus if ghosts.get(p.slot, false) else 1.0)


## Ghost knockback and stun on `slot` (every peer).
func _apply_tuning(slot: int) -> void:
	var p := _player(slot)
	if p == null:
		return
	var status := p.get_component(&"status") as StatusComponent
	if status and _base_knock.has(slot):
		status.knockback_multiplier = _base_knock[slot] * ghost_knockback
		status.stun_min = ghost_shove_stun
		status.stun_max = ghost_shove_stun


## Every look, tuning and freeze of ours back to normal (round end, leaving the tree).
func _restore_everyone(keep_lights: bool) -> void:
	if _looks:
		_looks.restore_all(keep_lights)
	for s in _slots:
		_restore_tuning(s)
		var p := _player(s)
		var vis := p.get_component(&"visuals") as VisualsComponent if p else null
		if vis:
			vis.set_expression(&"")


func _restore_tuning(slot: int) -> void:
	var p := _player(slot)
	if p == null:
		return
	var move := p.get_component(&"movement") as MovementComponent
	if move and _base_speed.has(slot):
		move.max_speed = _base_speed[slot]
	var status := p.get_component(&"status") as StatusComponent
	if status and _base_knock.has(slot):
		status.knockback_multiplier = _base_knock[slot]
		status.stun_min = _base_stun[slot].x
		status.stun_max = _base_stun[slot].y


func _exit_tree() -> void:
	_restore_everyone(false)


func _freeze(slot: int, on: bool) -> void:
	var p := _player(slot)
	if p:
		p.frozen = on


func _in_boo(slot: int) -> bool:
	for b: Array in _boos:
		if b[0] == slot or b[1] == slot:
			return true
	for r: Array in _rises:
		if r[0] == slot:
			return true
	return false


# --- Bots ------------------------------------------------------------------------------------

## Bots are told to re-plan often: chasers every 0.35 s, living blobs with a ghost within 8 m
## every 0.25 s (the brains add their own reaction delay).
func _bot_cadence(dt: float) -> void:
	_rethink_ghosts -= dt
	_rethink_living -= dt
	if _rethink_ghosts <= 0.0:
		_rethink_ghosts = 0.35
		for s in _slots:
			if ghosts.get(s, false):
				request_bot_rethink(s)
	if _rethink_living <= 0.0:
		_rethink_living = 0.25
		for s in _living_slots():
			var p := _player(s)
			if p and _nearest_ghost_distance(p.global_position) < 8.0:
				request_bot_rethink(s)


func get_bot_goal(player: Player) -> Vector3:
	if player == null or not player.alive or over:
		return player.global_position if player else Vector3.ZERO
	if ghosts.get(player.slot, false):
		return _chase_goal(player)
	if is_living(player.slot):
		return _flee_goal(player)
	return player.global_position


func is_safe(pos: Vector3) -> bool:
	return map.is_floor(pos)


## Bots: ghosts never chase ghosts and only chase what they can see (no running into walls).
## Living bots never chase or shove anyone: running is all that saves them (humans may still
## shove a friend into a ghost's arms, or a ghost away).
func is_ally(a: Player, b: Player) -> bool:
	if a == null or b == null:
		return false
	var ga := is_ghost(a.slot) or caught_at.has(a.slot)
	var gb := is_ghost(b.slot) or caught_at.has(b.slot)
	if ga and not gb:
		return not map.has_los(a.global_position, b.global_position, 0.3)
	return true


## Ghost: the nearest living blob it can sense (by path; a little less keen on one another ghost
## is already closer to), walked along the grid path; straight through it once in sight and
## close. Senses nobody: prowls toward the loop point furthest from the other ghosts.
func _chase_goal(me: Player) -> Vector3:
	var start := map.nearest_nav(me.global_position)
	if start < 0:
		return me.global_position
	var field := map.bfs(PackedInt32Array([start]))
	var best: Player = null
	var best_cost := INF
	var best_cell := -1
	var n_ghosts := _ghost_count()
	var sense_m := bot_sense_range if n_ghosts <= 1 else bot_pack_sense / float(n_ghosts)
	var sense := sense_m / GhostMap.CELL
	for s in _living_slots():
		var p := _player(s)
		if p == null or not p.alive:
			continue
		var cell := map.nearest_nav(p.global_position)
		if cell < 0 or field[cell] < 0:
			continue
		var cost := float(field[cell])
		var flat := p.global_position - me.global_position
		flat.y = 0.0
		if cost > sense and not (flat.length() < sense_m * 1.4 and map.has_los(me.global_position, p.global_position, 0.3)):
			continue
		for g in _slots:
			if g == me.slot or not ghosts.get(g, false):
				continue
			var gp := _player(g)
			if gp and gp.global_position.distance_to(p.global_position) < me.global_position.distance_to(p.global_position):
				cost += 6.0
		if cost < best_cost:
			best_cost = cost
			best = p
			best_cell = cell
	if best == null:
		return _prowl_goal(me, field)
	var to := best.global_position - me.global_position
	to.y = 0.0
	if to.length() < 5.0 and map.has_los(me.global_position, best.global_position):
		var aim := best.global_position + best.velocity * 0.25
		var dir := aim - me.global_position
		dir.y = 0.0
		if dir.length() > 0.01:
			aim += dir.normalized() * 0.9  # run through them, not up to them
		aim.y = 0.0
		return aim if map.is_clear(aim, 0.3) else Vector3(best.global_position.x, 0.0, best.global_position.z)
	return map.steer_point(me.global_position, map.path_to(field, best_cell))


## Prowling: the loop point (spawn markers, passage ends) furthest from the other ghosts and
## not where this ghost already is; walked along the grid path.
func _prowl_goal(me: Player, field: PackedInt32Array) -> Vector3:
	var best := -1
	var best_score := -INF
	for pt: Vector3 in GhostMap.SPAWNS + PROWL_POINTS:
		var k := map.nearest_nav(pt)
		if k < 0 or field[k] < 0:
			continue
		var d := float(field[k])
		if d < 6.0:
			continue
		var score := -0.3 * d
		for g in _slots:
			if g == me.slot or not ghosts.get(g, false):
				continue
			var gp := _player(g)
			if gp:
				score += minf(gp.global_position.distance_to(pt), 12.0)
		# a little per-ghost taste so two prowlers do not pick the same point
		score += float((me.slot * 7 + k) % 5) * 0.5
		if score > best_score:
			best_score = score
			best = k
	if best < 0:
		return me.global_position
	return map.steer_point(me.global_position, map.path_to(field, best))


## Living: the reachable spot furthest from every ghost, through cells this blob reaches
## before any ghost could (so the route never runs into one), away from the other living blobs
## (a huddle is a chain catch waiting to happen). Dead-end rooms are a last resort, and out of
## the question while a ghost is within ~10 m. Cornered: whatever gains the most distance nearby.
func _flee_goal(me: Player) -> Vector3:
	var start := map.nearest_nav(me.global_position)
	if start < 0:
		return me.global_position
	var gf := _ghost_distances()
	if gf.is_empty():
		return me.global_position
	var here := gf[start]
	var ghost_near := here >= 0 and here < 20
	if bot_living_sense > 0.0 and (here < 0 or float(here) * GhostMap.CELL > bot_living_sense) 			and not _ghost_in_sight(me, bot_living_sense * 1.4):
		return _hold_goal(me, start)
	var safe := map.bfs(PackedInt32Array([start]), gf, ghost_speed_bonus, 2.0)
	var crowd := _crowd_map(me)
	var best := -1
	var best_score := -INF
	for k in map.nav_cells:
		var md := safe[k]
		if md < 0:
			continue
		var gd := gf[k]
		var score := minf(float(gd if gd >= 0 else 60), 36.0) - 0.2 * float(md) - 4.0 * float(crowd[k]) 			+ flee_open_weight * map.openness[k]
		if map.dead[k] == 1:
			score -= 40.0 if ghost_near else 12.0
		if score > best_score:
			best_score = score
			best = k
	if best == start and not ghost_near:
		return me.global_position  # already the best spot there is
	var field := safe
	if best < 0 or best == start:
		# cornered: the nearby cell that gains the most on the ghosts
		field = map.bfs(PackedInt32Array([start]))
		best_score = -INF
		for k in map.nav_cells:
			var md := field[k]
			if md < 0 or md > 14:
				continue
			var gd := gf[k]
			var score := float(gd) - float(md) * ghost_speed_bonus
			if ghost_near and map.dead[k] == 1:
				score -= 30.0
			if score > best_score:
				best_score = score
				best = k
	if best < 0:
		return me.global_position
	return map.steer_point(me.global_position, map.path_to(field, best))


## Per cell: how many other living blobs stand within ~1.75 m of it.
func _crowd_map(me: Player) -> PackedByteArray:
	var crowd := PackedByteArray()
	crowd.resize(GhostMap.NX * GhostMap.NZ)
	crowd.fill(0)
	for s in _living_slots():
		var p := _player(s)
		if p == null or p == me:
			continue
		var k := map.index_of(p.global_position)
		if k < 0:
			continue
		var ci := k % GhostMap.NX
		var cj := k / GhostMap.NX
		for dj in range(-3, 4):
			for di in range(-3, 4):
				var i := ci + di
				var j := cj + dj
				if i >= 0 and j >= 0 and i < GhostMap.NX and j < GhostMap.NZ:
					crowd[i + j * GhostMap.NX] = mini(crowd[i + j * GhostMap.NX] + 1, 255)
	return crowd


## True when a ghost is within `range_m` in a straight line of sight of `me`.
func _ghost_in_sight(me: Player, range_m: float) -> bool:
	for s in _slots:
		if not ghosts.get(s, false):
			continue
		var gp := _player(s)
		if gp == null:
			continue
		var to := gp.global_position - me.global_position
		to.y = 0.0
		if to.length() < range_m and map.has_los(me.global_position, gp.global_position, 0.3):
			return true
	return false


## No ghost noticed: stay put near a junction (room to break either way), away from the others.
func _hold_goal(me: Player, start: int) -> Vector3:
	if map.openness[start] > 0.3:
		return me.global_position
	var field := map.bfs(PackedInt32Array([start]))
	var crowd := _crowd_map(me)
	var best := -1
	var best_score := -INF
	for k in map.nav_cells:
		var md := field[k]
		if md < 0 or md > 24:
			continue
		var score := 8.0 * map.openness[k] - 0.15 * float(md) - 4.0 * float(crowd[k]) - (12.0 if map.dead[k] == 1 else 0.0)
		if score > best_score:
			best_score = score
			best = k
	if best < 0 or best == start:
		return me.global_position
	return map.steer_point(me.global_position, map.path_to(field, best))


## Path distance (cells) from the nearest ghost, per cell; cached a few frames.
func _ghost_distances() -> PackedInt32Array:
	var frame := Engine.get_physics_frames()
	if frame - _ghost_field_frame < 12 and not _ghost_field.is_empty():
		return _ghost_field
	_ghost_field_frame = frame
	var sources := PackedInt32Array()
	for s in _slots:
		if ghosts.get(s, false):
			var p := _player(s)
			if p and p.alive:
				sources.append(map.nearest_nav(p.global_position))
	_ghost_field = map.bfs(sources) if not sources.is_empty() else PackedInt32Array()
	return _ghost_field


func _ghost_count() -> int:
	var n := 0
	for s in _slots:
		if ghosts.get(s, false):
			n += 1
	return n


func _nearest_ghost_distance(pos: Vector3) -> float:
	var best := INF
	for s in _slots:
		if ghosts.get(s, false):
			var p := _player(s)
			if p:
				best = minf(best, p.global_position.distance_to(pos))
	return best


## Re-plans are deduplicated per frame and slot (a catch is announced to many listeners).
var _rethink_frame: int = -1
var _rethink_done: Dictionary = {}


func request_bot_rethink(slot: int = -1) -> void:
	var frame := Engine.get_physics_frames()
	if frame != _rethink_frame:
		_rethink_frame = frame
		_rethink_done.clear()
	if _rethink_done.has(-1) or _rethink_done.has(slot):
		return
	_rethink_done[slot] = true
	super(slot)


# --- Helpers ---------------------------------------------------------------------------------

func _living_slots() -> Array[int]:
	var out: Array[int] = []
	for s in _slots:
		if is_living(s):
			out.append(s)
	return out


func _player(slot: int) -> Player:
	if slot < 0:
		return null
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _name_of(p: Player) -> String:
	if p == null:
		return "Someone"
	return p.display_name if p.display_name != "" else "Player %d" % (p.slot + 1)


# --- Arena -----------------------------------------------------------------------------------

const WALL_SIDE := Color("#3b3240")
const WALL_TOP := Color("#6b5f6e")
const FLOOR_COLOR := Color("#4a3a32")
const RUG_COLOR := Color("#5a2a33")
const MOON_COLOR := Color(0.55, 0.7, 1.0)
const WINDOW_XS: Array[float] = [-6.5, 0.0, 6.5]
## Extra prowling points for ghost bots: the middle and the passage ends.
const PROWL_POINTS: Array[Vector3] = [Vector3(0, 0, 0), Vector3(0, 0, -4.5), Vector3(0, 0, 4.5),
	Vector3(-7.5, 0, 0), Vector3(7.5, 0, 0)]

## Wall height by where the wall is (the camera looks from +Z: the far wall is tall and
## carries the windows, the near wall is a low kerb so it never hides anyone).
static func wall_height(r: Rect2) -> float:
	if r.end.y <= -8.5 + 0.01:
		return 2.4
	if r.position.y >= 8.5 - 0.01:
		return 0.45
	if r.end.x <= -11.5 + 0.01 or r.position.x >= 11.5 - 0.01:
		return 1.3
	return 1.0


func _build_arena() -> void:
	var arena := Node3D.new()
	arena.name = "Arena"
	add_child(arena)

	# floor: dark boards (and a darker void around so the camera never sees sky)
	var under := MeshInstance3D.new()
	var under_mesh := PlaneMesh.new()
	under_mesh.size = Vector2(70.0, 70.0)
	under.mesh = under_mesh
	under.material_override = Look.toon_material(Color("#120f16"), 0.95, false)
	under.position.y = -0.05
	arena.add_child(under)
	var floor_mi := MeshInstance3D.new()
	floor_mi.name = "Floor"
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(24.0, 18.0)
	floor_mi.mesh = floor_mesh
	floor_mi.material_override = Look.toon_material(FLOOR_COLOR, 0.85, false)
	arena.add_child(floor_mi)
	var floor_body := StaticBody3D.new()
	floor_body.name = "FloorBody"
	floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(26.0, 1.0, 20.0)
	floor_shape.shape = floor_box
	floor_shape.position.y = -0.5
	floor_body.add_child(floor_shape)
	arena.add_child(floor_body)

	# board seams: thin dark strips across the floor (one mesh)
	var seams := SurfaceTool.new()
	seams.begin(Mesh.PRIMITIVE_TRIANGLES)
	var z := -8.5
	while z < 8.6:
		_quad_y(seams, Rect2(-11.5, z - 0.015, 23.0, 0.03), 0.004)
		z += 0.75
	var seam_mi := MeshInstance3D.new()
	seam_mi.mesh = seams.commit()
	seam_mi.material_override = Look.toon_material(Color("#2a201d"), 0.9, false)
	seam_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arena.add_child(seam_mi)

	# rugs in the two through rooms
	for r: Rect2 in [Rect2(4.0, -4.2, 3.2, 1.8), Rect2(-7.2, 2.4, 3.2, 1.8)]:
		var rug := MeshInstance3D.new()
		var rm := PlaneMesh.new()
		rm.size = r.size
		rug.mesh = rm
		rug.material_override = Look.toon_material(RUG_COLOR, 0.95, false)
		rug.position = Vector3(r.get_center().x, 0.01, r.get_center().y)
		rug.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arena.add_child(rug)

	# walls: one mesh (sides + lighter tops) and tall colliders nobody can hop
	var side := SurfaceTool.new()
	side.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := SurfaceTool.new()
	top.begin(Mesh.PRIMITIVE_TRIANGLES)
	var walls := StaticBody3D.new()
	walls.name = "Walls"
	walls.collision_mask = 0
	arena.add_child(walls)
	for r in map.solid_rects():
		var h := wall_height(r)
		_box_sides(side, r, h)
		_quad_y(top, r, h)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(r.size.x, 3.0, r.size.y)
		cs.shape = box
		cs.position = Vector3(r.get_center().x, 1.5, r.get_center().y)
		walls.add_child(cs)
	var wall_mesh := side.commit()
	top.commit(wall_mesh)
	var wall_mi := MeshInstance3D.new()
	wall_mi.name = "WallMesh"
	wall_mi.mesh = wall_mesh
	wall_mi.set_surface_override_material(0, Look.toon_material(WALL_SIDE, 0.85, false))
	wall_mi.set_surface_override_material(1, Look.toon_material(WALL_TOP, 0.8, false))
	arena.add_child(wall_mi)

	# moonlit windows in the far wall, with pale light pools on the floor below them
	for x in WINDOW_XS:
		_place(arena, "ghost_window", Vector3(x, 0.85, -8.5), 0.0, false)
		var pool := MeshInstance3D.new()
		var pm := QuadMesh.new()
		pm.size = Vector2(2.6, 3.2)
		pm.orientation = PlaneMesh.FACE_Y
		pool.mesh = pm
		pool.material_override = _moon_pool_material()
		pool.position = Vector3(x, 0.02, -6.9)
		pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arena.add_child(pool)

	# clutter (static colliders)
	for c: Array in map.CLUTTER_PIECES:
		var piece: String = c[0]
		var pos := Vector3(float(c[1]), 0.0, float(c[2]))
		var yaw := deg_to_rad(float(c[3]))
		if piece == "crate_stack":
			_place(arena, "crate", pos, yaw)
			_place(arena, "crate", pos + Vector3(0.05, 0.9, -0.04), yaw + 0.4)
		else:
			_place(arena, piece, pos, yaw)
		var body := StaticBody3D.new()
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		var hgt := float(c[6])
		if piece == "barrel":
			var cyl := CylinderShape3D.new()
			cyl.radius = 0.36
			cyl.height = hgt
			cs.shape = cyl
		else:
			var box := BoxShape3D.new()
			box.size = Vector3(float(c[4]), hgt, float(c[5]))
			cs.shape = box
			cs.rotation.y = yaw if piece == "crate" else 0.0
		cs.position = pos + Vector3.UP * hgt * 0.5
		body.add_child(cs)
		arena.add_child(body)

	# cobwebs in the far corners of the rooms and the attic
	for w: Array in [[Vector3(-11.5, 2.35, -8.5), 45.0], [Vector3(11.5, 2.35, -8.5), -45.0],
			[Vector3(1.5, 0.98, -5.5), 45.0], [Vector3(8.5, 0.98, -5.5), -45.0],
			[Vector3(-8.5, 0.98, -5.5), 45.0], [Vector3(-1.5, 0.98, -5.5), -45.0],
			[Vector3(-8.5, 0.98, 1.5), 45.0], [Vector3(8.5, 0.98, 1.5), -45.0]]:
		var web := _place(arena, "ghost_cobweb", w[0], deg_to_rad(float(w[1])), false)
		if web:
			web.scale = Vector3.ONE * 0.9


func _moon_pool_material() -> StandardMaterial3D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_texture = tex
	m.albedo_color = Color(MOON_COLOR.r * 0.35, MOON_COLOR.g * 0.35, MOON_COLOR.b * 0.35, 1.0)
	return m


## A horizontal quad over `r` (x, z) at height `y`, facing up.
static func _quad_y(st: SurfaceTool, r: Rect2, y: float) -> void:
	var a := Vector3(r.position.x, y, r.position.y)
	var b := Vector3(r.end.x, y, r.position.y)
	var c := Vector3(r.end.x, y, r.end.y)
	var d := Vector3(r.position.x, y, r.end.y)
	st.set_normal(Vector3.UP)
	for v in [a, b, c, a, c, d]:
		st.add_vertex(v)


## The four vertical sides of a box over `r` from 0 to `h`.
static func _box_sides(st: SurfaceTool, r: Rect2, h: float) -> void:
	var x0 := r.position.x
	var x1 := r.end.x
	var z0 := r.position.y
	var z1 := r.end.y
	# [corner a, corner b, outward normal]: a -> b runs so that the face points outward
	for f: Array in [[Vector2(x0, z1), Vector2(x1, z1), Vector3.BACK], [Vector2(x1, z0), Vector2(x0, z0), Vector3.FORWARD],
			[Vector2(x1, z1), Vector2(x1, z0), Vector3.RIGHT], [Vector2(x0, z0), Vector2(x0, z1), Vector3.LEFT]]:
		var a2: Vector2 = f[0]
		var b2: Vector2 = f[1]
		var n: Vector3 = f[2]
		var a := Vector3(a2.x, 0.0, a2.y)
		var b := Vector3(b2.x, 0.0, b2.y)
		var at := a + Vector3.UP * h
		var bt := b + Vector3.UP * h
		st.set_normal(n)
		for v in [a, at, bt, a, bt, b]:  # clockwise seen from outside (Godot's front face)
			st.add_vertex(v)


func _place(parent: Node3D, piece: String, pos: Vector3, yaw: float, outline: bool = true) -> Node3D:
	var scene := load(PROPS + piece + ".glb") as PackedScene
	if scene == null:
		push_error("ghost_tag: missing prop %s" % piece)
		return null
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation.y = yaw
	parent.add_child(n)
	Look.apply_toon(n, outline)
	return n
