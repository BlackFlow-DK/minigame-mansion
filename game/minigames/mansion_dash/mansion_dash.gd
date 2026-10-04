class_name MansionDash
extends Minigame
## Mansion Dash: a 70 m obstacle race through the mansion gardens. Hedge slalom, swinging
## hammers, logs rolling down a ramp, moving rafts over a pond (fall in: back to the last
## checkpoint after 1 s), a turntable with a sweeper bar, a bumper sprint. First across the
## finish line wins; the round ends when everyone is through, FINISH_WINDOW s after the first
## finisher, or at `time_limit`; unfinished blobs are ranked by checkpoint, then distance.
##
## Networking (docs/contract.md "Networking rules for minigames"):
## - Every moving hazard is `DashCourse.*(layout, t)`: the host sends only the seed and the start
##   time (`_rpc_begin`); every peer builds the same `DashCourse.Layout` and runs its own round
##   clock, so hammers, logs, rafts, the turntable and the sweeper are never synced.
## - Each peer applies hammer, log, sweeper and bumper hits to its own authority players only
##   (`apply_impulse`: the normal got_hit/stunned events and effects run everywhere).
## - The host decides checkpoints, falls/respawns and the finish order from the synced player
##   positions it sees: a player whose feet sink into the pond (or leave the course) is
##   respawned by the host (`respawn_at`) at its last host-recorded checkpoint after
##   `respawn_delay` s. Clients never report anything, so no client can move another player.
## - Finish: the host interpolates the crossing time of the finish plane between its last two
##   observations of each player; same-tick ties go to whoever is further past the line.
##   `_rpc_finished` tells every peer (HUD place, confetti, flags).
##
## Bots: `get_bot_goal` walks a lane graph section by section (slalom gaps, hammer lanes timed
## against the swing, log lanes with the fewest logs coming, the raft of the next row that will
## line up, sprint lanes between the bumpers), with a per-bot taste so they do not all run the
## same line; `is_safe` = on the course, off hedges and bumpers, over a raft (now and in a
## moment) when above water, not in a hammer's next SAFE_HORIZON s sweep, not in a log's or the
## sweeper's footprint (plus a short look ahead, so the bot brain's gap jump hops them).

## Every peer: the round clock started (host-sent seed and start time).
signal round_began(seed_value: int, start_time: float)
## Every peer: `slot` reached checkpoint `index` (0..2), decided by the host.
signal checkpoint_reached(slot: int, index: int)
## Every peer: `slot` crossed the finish line in `place` (1-based) at round time `time`.
signal player_finished(slot: int, place: int, time: float)
## Every peer: the host saw `slot` fall in (it respawns after `respawn_delay`).
signal fell(slot: int)
## On the peer that owns the player: a hazard (`hammer`, `log`, `sweeper`, `bumper`) hit it.
signal local_hit(slot: int, kind: StringName)

const COURSE_SCENE: PackedScene = preload("res://assets/models/props/dash_course.glb")
const BORDER_SCENE: PackedScene = preload("res://assets/models/props/dash_border.glb")
const HEDGE_SCENE: PackedScene = preload("res://assets/models/props/dash_hedge.glb")
const FRAME_SCENE: PackedScene = preload("res://assets/models/props/dash_hammer_frame.glb")
const HAMMER_SCENE: PackedScene = preload("res://assets/models/props/dash_hammer.glb")
const LOG_SCENE: PackedScene = preload("res://assets/models/props/dash_log.glb")
const PLATFORM_SCENE: PackedScene = preload("res://assets/models/props/dash_platform.glb")
const FLAG_SCENE: PackedScene = preload("res://assets/models/props/dash_flag.glb")
const GATE_SCENE: PackedScene = preload("res://assets/models/props/dash_start_gate.glb")
const ARCH_SCENE: PackedScene = preload("res://assets/models/props/dash_finish_arch.glb")
const DISC_SCENE: PackedScene = preload("res://assets/models/props/dash_disc.glb")
const SWEEPER_SCENE: PackedScene = preload("res://assets/models/props/dash_sweeper.glb")
const BUMPER_SCENE: PackedScene = preload("res://assets/models/props/bumper_post.glb")
const PLANT_SCENE: PackedScene = preload("res://assets/models/env/potted_plant.glb")
const WALL_SCENE: PackedScene = preload("res://assets/models/env/wall_window.glb")
const DOOR_SCENE: PackedScene = preload("res://assets/models/env/minigame_door_arch.glb")
const PILLAR_SCENE: PackedScene = preload("res://assets/models/env/pillar.glb")
const WATER_MATERIAL: Material = preload("res://look/materials/water.tres")

## Bots: seconds of a hammer's swing that make ground unsafe.
const SAFE_HORIZON := 0.4
## Bots: seconds of look-ahead on the sweeper (short, so bots hop it).
const HOP_HORIZON := 0.12
## Bots: a log makes unsafe its own footprint (pad LOG_PAD) plus the ground it covers in the next
## LOG_LOOKAHEAD s: narrow enough for the bot brain's gap jump, and its near edge meets a running
## bot just when a jump clears the log.
const LOG_LOOKAHEAD := 0.28
const LOG_PAD := 0.1
## Bots: rafts must still be under a point this many seconds from now.
const RAFT_HORIZON := 0.3
## Host: seconds between routine bot rethinks (hazards move all the time).
const RETHINK_INTERVAL := 0.35
## Host: after a respawn, no fall check for this long (the synced position catches up).
const RESPAWN_GRACE := 1.0
## Host: crossing times this close count as a tie (broken by distance past the line).
const TIE_TIME := 0.001
## Feet this low anywhere = off the course.
const LOST_Y := -3.0
## Camera: the pack is framed whole up to this spread along the course (m); beyond it the
## camera frames the window of this length around the local player with the most blobs in it.
const CAM_SPREAD := 18.0
const CAM_MIN_DISTANCE := 15.0
## Camera, stretched pack: metres of course ahead of the local player kept in view.
const CAM_AHEAD := 6.0
const CAM_MAX_DISTANCE := 27.0
## The hammer alley's rail is invisible nearer than FADE_NEAR m to the camera, solid beyond FADE_FAR.
const FADE_NEAR := 9.0
const FADE_FAR := 13.0
const ORDINALS: Array[String] = ["1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th"]

@export_group("Hits")
@export var hammer_push: float = 15.0
@export var hammer_lift: float = 6.0
@export var hammer_stun: float = 1.0
@export var log_push: float = 7.0
@export var log_lift: float = 5.0
@export var log_stun: float = 0.7
@export var sweeper_push: float = 11.0
@export var sweeper_lift: float = 5.0
@export var sweeper_stun: float = 0.7
@export var bumper_push: float = 9.0
@export var bumper_lift: float = 3.0
## Seconds after a hazard hit during which hazards pass through that player (its own peer).
@export var hit_grace: float = 0.6
@export var bumper_cooldown: float = 0.4

@export_group("Round")
## Seconds a fallen player waits (in the water) before the host respawns it.
@export var respawn_delay: float = 1.0
## Seconds the round goes on after the first finisher.
@export var finish_window: float = 12.0

@export_group("Test")
## Test-only: multiplies the round clock (hazards and the time limit).
@export var time_scale: float = 1.0
## Seed of the layout; -1 = random (host).
@export var course_seed: int = -1
## Round clock at the start (host). Dev: `--dash-start=SEC`.
@export var start_time: float = 0.0

## Bot brain hint: bots shove a little less than in the brawls (a race, and rafts are slippery).
var bot_aggression_scale: float = 0.7
## Bot brain hint: bots race with this share of their skill (they run flat out, but misjudge
## more: late to see a hammer coming, a stale line, a mistimed raft jump), so a decent human
## beats them and they do not all arrive together.
var bot_skill_scale: float = 0.4
## The layout of this round (every peer, from the host-sent seed).
var layout: DashCourse.Layout = DashCourse.build(0)
## slot -> highest checkpoint reached (-1 none), identical on every peer (host-sent).
var checkpoints: Dictionary[int, int] = {}
## Slots in finish order and their crossing times, identical on every peer.
var finish_order: Array[int] = []
var finish_times: Dictionary[int, float] = {}
## Host: falls it decided (the network check reads it).
var falls: int = 0

var _t: float = 0.0
var _t_vis: float = 0.0
var _running: bool = false
var _seed: int = 0
var _freeze_at: float = INF
var _anim: float = 0.0
# host
var _prev_pos: Dictionary[int, Vector3] = {}
var _prev_t: float = 0.0
var _sink_until: Dictionary[int, float] = {}
var _no_fall_until: Dictionary[int, float] = {}
var _first_finish_t: float = -1.0
var _rethink_cd: float = 0.0
# every peer, own players
var _grace: Dictionary[int, float] = {}
var _bump_cd: Dictionary[int, float] = {}
# bot caches (refreshed once per round-clock value)
var _cache_t: float = -1.0
var _cache_heads: Array[PackedVector3Array] = []
var _cache_logs := PackedVector4Array()  # x, y, z_lo, z_hi of each log's footprint ahead
var _cache_sweep := PackedFloat32Array()
var _cache_rafts := PackedFloat32Array()  # row*2+i -> x now; +6 -> x at RAFT_HORIZON
# visuals
var _hammers: Array[Node3D] = []
var _rafts: Array[AnimatableBody3D] = []
var _disc: AnimatableBody3D = null
var _sweeper_bar: Node3D = null
var _logs: Dictionary[int, Node3D] = {}
var _log_pool: Array[Node3D] = []
var _log_first: int = 0
var _flags: Array[Node3D] = []
var _flag_mats: Array[StandardMaterial3D] = []
var _flag_pop: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
var _hud_cd: float = 0.0
var _places: Dictionary[int, int] = {}
var _strip: Control = null
var _dots: Dictionary[int, Control] = {}
var _dash_at: float = INF
var _fade_mats: Dictionary = {}

@onready var _camera: ArenaCamera = $ArenaCamera as ArenaCamera


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dash-freeze="):
			_freeze_at = arg.trim_prefix("--dash-freeze=").to_float()
		elif arg.begins_with("--dash-at="):
			_dash_at = arg.trim_prefix("--dash-at=").to_float()
	_build_course()
	_build_colliders()
	_build_movers()
	_build_decor()
	# Repeated static pieces (hedge blocks, borders, bumpers, plants, wall and pillar kit) as
	# one MultiMesh per piece (docs/performance.md); the flags wave, the movers move: not batched.
	for n: Node3D in [$Course, $Hedges, $Decor]:
		StaticMerge.batch(n)
	_update_movers(0.0)
	_update_visuals(0.0)
	if _camera:
		_camera.fixed_focus = Vector3(0.0, 0.5, DashCourse.SPAWN_Z - 3.0)
		_camera.fixed_distance = 17.0
		_camera.snap()


# --- Minigame flow --------------------------------------------------------------------------

func _setup(setup_players: Array[Player]) -> void:
	checkpoints.clear()
	finish_order.clear()
	finish_times.clear()
	_places.clear()
	for p in setup_players:
		checkpoints[p.slot] = -1
		_places[p.slot] = 0
	_build_strip(setup_players)


func _start() -> void:
	if not multiplayer.is_server():
		return
	var t0 := start_time
	var seed_value := course_seed if course_seed >= 0 else randi() % 1000000
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dash-start="):
			t0 = arg.trim_prefix("--dash-start=").to_float()
		elif arg.begins_with("--dash-seed="):
			seed_value = arg.trim_prefix("--dash-seed=").to_int()
	begin(seed_value, t0)
	if not finished.is_connected(_on_finished):
		finished.connect(_on_finished)
	if _dash_at != INF:
		_place_all_at(_dash_at)


## Host: (re)starts the round clock on every peer at `t0` with the layout of `seed_value`.
func begin(seed_value: int, t0: float = 0.0) -> void:
	_rpc_begin.rpc(seed_value, t0)


func _host_tick(delta: float) -> void:
	if not _running or is_finished():
		return
	var dt := _t - _prev_t
	var crossers: Array = []
	for p in players:
		if not _live(p):
			continue
		var slot := p.slot
		var pos := p.global_position
		if _sink_until.has(slot):
			if _t >= _sink_until[slot]:
				_respawn(p)
			continue
		if not finish_times.has(slot):
			var k := DashCourse.checkpoint_at(pos)
			if k > checkpoints.get(slot, -1) and pos.y > DashCourse.SINK_Y:
				_rpc_checkpoint.rpc(slot, k)
				request_bot_rethink(slot)
			if _prev_pos.has(slot) and dt > 0.0:
				var tc := DashCourse.finish_crossing(_prev_pos[slot], pos, _prev_t, dt)
				if tc >= 0.0:
					crossers.append([slot, tc, DashCourse.FINISH_Z - pos.z])
		if _t >= _no_fall_until.get(slot, -1.0) and _fallen(pos):
			_sink_until[slot] = _t + respawn_delay
			falls += 1
			_rpc_fell.rpc(slot, Vector3(pos.x, DashCourse.WATER_Y, pos.z))
		_prev_pos[slot] = pos
	_prev_t = _t
	if not crossers.is_empty():
		crossers.sort_custom(func(a: Array, b: Array) -> bool:
			if absf(float(a[1]) - float(b[1])) > TIE_TIME:
				return a[1] < b[1]
			return a[2] > b[2])
		for c: Array in crossers:
			_rpc_finished.rpc(int(c[0]), finish_order.size() + 1, float(c[1]))
		if _first_finish_t < 0.0:
			_first_finish_t = float(crossers[0][1])
	_rethink_cd -= delta
	if _rethink_cd <= 0.0:
		_rethink_cd = RETHINK_INTERVAL
		request_bot_rethink()
	_check_end()


func _check_end() -> void:
	var racing := 0
	for p in players:
		if _live(p) and not finish_times.has(p.slot):
			racing += 1
	if racing == 0 and not finish_order.is_empty():
		_end(2.0)
	elif _first_finish_t >= 0.0 and _t >= _first_finish_t + finish_window:
		_end(1.5)
	elif time_limit > 0.0 and _t >= time_limit:
		_end(1.0)


## Host: the ranking right now (finishers in order, then by checkpoint and distance).
func current_ranking() -> Array[int]:
	var others: Array[int] = []
	var prog: Dictionary = {}
	for p in players:
		if not is_instance_valid(p) or finish_times.has(p.slot) or knocked_out.has(p.slot):
			continue
		if not p.alive:
			continue
		others.append(p.slot)
		prog[p.slot] = _progress_of(p)
	return DashCourse.rank(finish_order, others, checkpoints, prog, knocked_out)


func _end(grace: float) -> void:
	finish(current_ranking(), grace)


func _respawn(p: Player) -> void:
	_sink_until.erase(p.slot)
	var xf := DashCourse.respawn_xform(checkpoints.get(p.slot, -1), p.slot)
	p.respawn_at(xf)
	_prev_pos[p.slot] = xf.origin
	_no_fall_until[p.slot] = _t + RESPAWN_GRACE
	request_bot_rethink(p.slot)


## True when feet at `pos` are in the pond water or off the course.
static func _fallen(pos: Vector3) -> bool:
	if pos.y < LOST_Y or absf(pos.x) > DashCourse.HALF_W + 2.0:
		return true
	return DashCourse.in_pond(pos) and pos.y < DashCourse.SINK_Y


func _progress_of(p: Player) -> float:
	if _sink_until.has(p.slot):
		return DashCourse.progress(DashCourse.respawn_xform(checkpoints.get(p.slot, -1), p.slot).origin)
	return DashCourse.progress(p.global_position)


func _on_finished(_ranking: Array[int]) -> void:
	if not finish_order.is_empty():
		_rpc_celebrate.rpc([finish_order[0]])


func _physics_process(delta: float) -> void:
	if not _running:
		return
	_t = minf(_t + delta * _clock_scale(), _freeze_at)
	_update_movers(_t)
	if not is_finished():
		_local_hits(delta)


## Seconds on the round clock (every peer).
func round_time() -> float:
	return _t


func seed_value() -> int:
	return _seed


func is_running() -> bool:
	return _running


func has_finished(slot: int) -> bool:
	return finish_times.has(slot)


# --- Hazard hits (every peer, own players) -------------------------------------------------------

func _local_hits(delta: float) -> void:
	for s: int in _grace:
		_grace[s] -= delta
	for s: int in _bump_cd:
		_bump_cd[s] -= delta
	for p in players:
		if not _live(p) or not p.is_authority() or p.frozen:
			continue
		var feet := p.global_position
		var slot := p.slot
		if _grace.get(slot, 0.0) <= 0.0:
			var hit := _hazard_hit(feet)
			if not hit.is_empty():
				_grace[slot] = hit_grace
				_push(p, hit[1], hit[2])
				local_hit.emit(slot, hit[0])
				continue
		if _bump_cd.get(slot, 0.0) <= 0.0:
			var b := DashCourse.bumper_at(feet)
			if b >= 0:
				_bump_cd[slot] = bumper_cooldown
				var away := Vector2(feet.x, feet.z) - DashCourse.BUMPERS[b]
				away = away.normalized() if away.length() > 0.01 else Vector2(0.0, 1.0)
				p.apply_impulse(Vector3(away.x * bumper_push, bumper_lift, away.y * bumper_push))
				Sfx.play(&"hit_bonk", feet + Vector3.UP * 0.5, -4.0, 1.4)
				local_hit.emit(slot, &"bumper")


## [kind, impulse, stun] of the hazard touching feet at `feet` now, or [] when none.
func _hazard_hit(feet: Vector3) -> Array:
	var l := layout
	if feet.z < 19.0 and feet.z > 7.0:
		for k in DashCourse.HAMMER_Z.size():
			if DashCourse.hammer_touches(l, k, _t, feet):
				var dir := DashCourse.hammer_dir(l, k, _t, feet)
				return [&"hammer", Vector3(dir * hammer_push, hammer_lift, 0.0), hammer_stun]
	if feet.z < DashCourse.LOG_Z_END + 1.0 and feet.z > DashCourse.LOG_Z_RELEASE - 1.0:
		var w := DashCourse.log_window(l, _t, _t)
		for i in range(w.x, w.y):
			if DashCourse.log_active(l, i, _t) and DashCourse.log_touches(l, i, _t, feet):
				return [&"log", Vector3(0.0, log_lift, log_push), log_stun]
	if absf(feet.z - DashCourse.DISC_Z) < DashCourse.DISC_R + 0.6:
		var a := DashCourse.sweep_angle(l, _t)
		if DashCourse.sweeper_touches(a, feet):
			var d := DashCourse.sweeper_dir(l, a, feet)
			return [&"sweeper", d * sweeper_push + Vector3.UP * sweeper_lift, sweeper_stun]
	return []


## Applies a hazard impulse with its own stun (the status tuning is swapped for this one impulse,
## so shoves keep their normal stun), plus a little shake on the hit player's screen.
func _push(p: Player, impulse: Vector3, stun: float) -> void:
	var status := p.get_component(&"status") as StatusComponent
	if status == null:
		p.apply_impulse(impulse)
		return
	var saved_max := status.stun_max
	var saved_full := status.stun_full_impulse
	var saved_chain := status.stun_chain_max
	status.stun_max = stun
	status.stun_full_impulse = impulse.length()
	status.stun_chain_max = maxf(saved_chain, stun * 2.0)
	p.apply_impulse(impulse)
	status.stun_max = saved_max
	status.stun_full_impulse = saved_full
	status.stun_chain_max = saved_chain
	if _camera and p.slot == Net.local_slot():
		_camera.add_shake(0.25)


# --- RPCs ------------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_begin(seed_value_: int, t0: float) -> void:
	_seed = seed_value_
	layout = DashCourse.build(seed_value_)
	_t = t0
	_t_vis = t0
	_prev_t = t0
	_cache_t = -1.0
	for id: int in _logs.keys():
		_release_log(id)
	_log_first = 0
	_running = true
	_update_movers(_t)
	round_began.emit(seed_value_, t0)


@rpc("authority", "call_local", "reliable")
func _rpc_checkpoint(slot: int, index: int) -> void:
	checkpoints[slot] = index
	if index >= 0 and index < DashCourse.CHECKPOINT_Z.size():
		var c := _player_color(slot)
		for side in 2:
			var fi := index * 2 + side
			if fi < _flag_mats.size():
				_flag_mats[fi].albedo_color = c
				_flag_pop[fi] = 1.0
		var at := Vector3(0.0, DashCourse.ground_y(DashCourse.CHECKPOINT_Z[index]) + 0.6, DashCourse.CHECKPOINT_Z[index])
		var p := _player(slot)
		if p:
			at = p.global_position + Vector3.UP * 0.6
		Fx.play(&"respawn_sparkle", at, c)
		Sfx.play(&"coin", at, -6.0, 0.8)
		if slot == Net.local_slot():
			RoundUI.push_banner("Checkpoint!", 1.0)
	checkpoint_reached.emit(slot, index)


@rpc("authority", "call_local", "reliable")
func _rpc_fell(slot: int, at: Vector3) -> void:
	Fx.play(&"splash_lava", at, Color(0.55, 0.85, 0.95))
	Fx.play(&"dust_puff", at + Vector3.UP * 0.1, Color(0.85, 0.95, 1.0))
	Sfx.play(&"platform_fall", at, -2.0, 1.3)
	fell.emit(slot)


@rpc("authority", "call_local", "reliable")
func _rpc_finished(slot: int, place: int, time: float) -> void:
	if finish_times.has(slot):
		return
	finish_order.append(slot)
	finish_times[slot] = time
	_places[slot] = place
	RoundUI.push_counter(slot, place)
	var p := _player(slot)
	if p:
		Fx.play(&"confetti", p.global_position + Vector3.UP * 1.2, _player_color(slot))
		var visuals := p.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"cheer", true)
	if place == 1:
		Sfx.play(&"round_win_jingle")
		RoundUI.push_banner("%s wins the dash!" % _name_of(slot), 2.0)
	elif slot == Net.local_slot():
		RoundUI.push_banner("You finished %s!" % _ordinal(place), 1.5)
	player_finished.emit(slot, place, time)


@rpc("authority", "call_local", "reliable")
func _rpc_celebrate(slots: Array) -> void:
	for s: Variant in slots:
		var p := _player(int(s))
		if p and p.alive:
			Fx.play(&"confetti", p.global_position + Vector3.UP * 1.4)


# --- Bots -------------------------------------------------------------------------------------------

## The next waypoint for `player` along the course (see the class doc).
func get_bot_goal(player: Player) -> Vector3:
	if player == null:
		return Vector3.ZERO
	var pos := player.global_position
	var slot := player.slot
	if finish_times.has(slot):
		return Vector3(-3.15 + 0.9 * (slot % 8), 0.0, DashCourse.FINISH_Z - 4.0)
	var taste := _hash01(slot * 7919 + int(_t / 5.0) * 104729)
	var z := pos.z
	if z > 20.4:
		for row: Array in DashCourse.SLALOM_GAPS:
			var rz: float = row[0]
			if z > rz - 0.3:
				var gaps: Array = row[1]
				var best: float = gaps[0]
				var best_d := INF
				for g: float in gaps:
					var d := absf(g - pos.x) + (1.5 if (taste < 0.3 and gaps.size() > 1 and absf(g - pos.x) < 1.0) else 0.0)
					if d < best_d:
						best_d = d
						best = g
				return Vector3(best, 0.0, rz - 1.2)
	if z > 7.2:
		for k in DashCourse.HAMMER_Z.size():
			var hz: float = DashCourse.HAMMER_Z[k]
			if z > hz - 0.5:
				return _hammer_goal(k, pos, taste)
		return Vector3(_log_lane_goal_x(pos, taste), 0.0, 5.2)
	if z > DashCourse.RAMP_Z1:
		return Vector3(_log_lane_goal_x(pos, taste), DashCourse.ground_y(z - 4.0), maxf(z - 4.0, DashCourse.RAMP_Z1 - 1.2))
	if z > DashCourse.ROW_Z[0] + DashCourse.PLAT_HALF_Z:
		return _raft_goal(-1, player)
	if z > DashCourse.POND_Z1:
		var r := DashCourse.row_at(z)
		if r < 0:
			r = 0
			for i in DashCourse.ROW_Z.size():
				if z < DashCourse.ROW_Z[i]:
					r = i
		return _raft_goal(r, player)
	if z > DashCourse.DISC_Z - DashCourse.DISC_R - 0.2:
		var lane := clampf(pos.x, -2.5, 2.5) * 0.5 + (taste - 0.5) * 1.6
		return Vector3(lane, 0.0, DashCourse.DISC_Z - DashCourse.DISC_R - 1.2)
	var sprint := -1.2 if (pos.x < 0.0) != (taste < 0.2) else 1.2
	return Vector3(sprint, 0.0, DashCourse.FINISH_Z - 2.5)


## Past hammer `k`'s line in a lane the head will not sweep when the bot gets there; else wait
## between the hammers.
func _hammer_goal(k: int, pos: Vector3, taste: float) -> Vector3:
	var hz: float = DashCourse.HAMMER_Z[k]
	var lanes: Array[float] = [-1.6, 0.0, 1.6]
	lanes.sort_custom(func(a: float, b: float) -> bool:
		return absf(a - pos.x) + (0.8 if a == 0.0 else 0.0) * taste < absf(b - pos.x) + (0.8 if b == 0.0 else 0.0) * taste)
	var arrive := maxf(pos.z - hz, 0.0) / 5.5
	for lane in lanes:
		var spot := Vector3(lane, 0.0, hz)
		if not DashCourse.hammer_threat(layout, k, _t + maxf(arrive - 0.1, 0.0), spot, 0.55, 0.1):
			return Vector3(lane, 0.0, hz - 1.6)
	return Vector3(clampf(pos.x, -1.8, 1.8), 0.0, hz + 1.6)


## The log lane (x) with the fewest logs about to come down on the bot.
func _log_lane_goal_x(pos: Vector3, taste: float) -> float:
	var best := pos.x
	var best_score := INF
	var w := DashCourse.log_window(layout, _t, _t + 1.5)
	for li in DashCourse.LOG_LANES.size():
		var lx: float = DashCourse.LOG_LANES[li]
		var score := absf(lx - pos.x) * 0.5 + taste * absf(lx) * 0.3
		for i in range(w.x, w.y):
			if layout.log_lane[i] != li:
				continue
			var lz := DashCourse.log_z(layout, i, _t + 0.6)
			if lz < pos.z + 0.5 and lz > pos.z - 5.0 and DashCourse.log_active(layout, i, _t + 0.6):
				score += 1.5
		if score < best_score:
			best_score = score
			best = lx
	return best


## Next raft (row `on_row` + 1) that will line up with the bot, or a wait spot on the bank /
## the current raft when none does.
func _raft_goal(on_row: int, player: Player) -> Vector3:
	var pos := player.global_position
	var next := on_row + 1
	if next >= DashCourse.ROW_Z.size():
		return Vector3(clampf(pos.x, -3.0, 3.0), 0.0, DashCourse.POND_Z1 - 1.1)
	var ahead := 0.45
	var best_x := 0.0
	var best_d := INF
	for i in 2:
		var x := DashCourse.platform_x(layout, next, i, _t + ahead)
		var d := absf(x - pos.x)
		if d < best_d:
			best_d = d
			best_x = x
	var nz: float = DashCourse.ROW_Z[next]
	var inner := DashCourse.PLAT_HALF_X - 0.55
	if on_row >= 0 and pos.z < DashCourse.ROW_Z[on_row] - 0.25 and Vector2(player.velocity.x, player.velocity.z).length() < 2.5:
		# standing at the front edge: step back for a run-up (the gap jump needs speed)
		return Vector3(pos.x, 0.0, DashCourse.ROW_Z[on_row] + 0.55)
	if best_d < DashCourse.PLAT_HALF_X - 0.25:
		# lined up: straight across (a straight run is what the gap jump wants)
		return Vector3(clampf(pos.x, best_x - inner, best_x + inner), 0.0, nz - 0.3)
	if on_row < 0:
		return Vector3(clampf(best_x, -3.6, 3.6), 0.0, DashCourse.POND_Z0 + 0.45)
	var here := 0.0
	var here_d := INF
	for i in 2:
		var x := DashCourse.platform_x(layout, on_row, i, _t + 0.3)
		if absf(x - pos.x) < here_d:
			here_d = absf(x - pos.x)
			here = x
	return Vector3(lerpf(here, best_x, 0.25), 0.0, DashCourse.ROW_Z[on_row])


func is_safe(pos: Vector3) -> bool:
	if absf(pos.x) > DashCourse.HALF_W - 0.45:
		return false
	if pos.z > DashCourse.PEN_BACK_Z - 0.45 or pos.z < DashCourse.PEN_END_Z + 0.45:
		return false
	if DashCourse.in_hedge(pos, 0.45):
		return false
	if DashCourse.bumper_at(Vector3(pos.x, 0.0, pos.z), 0.35) >= 0:
		return false
	if absf(pos.z - DashCourse.DISC_Z) < 0.75 and absf(pos.x) < 0.75:
		return false  # the sweeper post
	if not _running:
		return not DashCourse.in_pond(pos)
	if _cache_t != _t:
		_refresh_cache()
	if DashCourse.in_pond(pos):
		# Over a raft now and in a moment. The narrow bank gaps count as part of the first and
		# last row (a blob walks across them); the gaps between rows have to be jumped.
		var last := DashCourse.ROW_Z.size() - 1
		for r in DashCourse.ROW_Z.size():
			var dz := pos.z - DashCourse.ROW_Z[r]
			var lim := DashCourse.PLAT_HALF_Z - 0.2
			if (r == 0 and dz > 0.0) or (r == last and dz < 0.0):
				lim = DashCourse.PLAT_HALF_Z + 0.5
			if absf(dz) > lim:
				continue
			var ok_now := false
			var ok_soon := false
			for i in 2:
				ok_now = ok_now or absf(pos.x - _cache_rafts[r * 2 + i]) < DashCourse.PLAT_HALF_X - 0.2
				ok_soon = ok_soon or absf(pos.x - _cache_rafts[6 + r * 2 + i]) < DashCourse.PLAT_HALF_X
			return ok_now and ok_soon
		return false
	var gy := DashCourse.ground_y(pos.z)
	if pos.z < 18.0 and pos.z > 8.0:
		var reach := DashCourse.HEAD_R + DashCourse.HEAD_HALF + DashCourse.BLOB_RADIUS + 0.1
		for k in _cache_heads.size():
			var heads := _cache_heads[k]
			if absf(pos.z - DashCourse.HAMMER_Z[k]) > DashCourse.HEAD_R + DashCourse.BLOB_RADIUS + 0.15:
				continue
			for c in heads:
				var dy := c.y - clampf(c.y, gy + DashCourse.CORE_LO, gy + DashCourse.CORE_HI)
				var dx := c.x - pos.x
				if dx * dx + dy * dy < reach * reach:
					return false
	if pos.z < DashCourse.LOG_Z_END + 0.8 and pos.z > DashCourse.LOG_Z_RELEASE - 0.8:
		var lr := DashCourse.LOG_R + LOG_PAD
		var side := DashCourse.LOG_HALF + DashCourse.BLOB_RADIUS
		for f in _cache_logs:
			if absf(pos.x - f.x) < side and pos.z > f.z - lr and pos.z < f.w + lr:
				return false
	if absf(pos.z - DashCourse.DISC_Z) < DashCourse.DISC_R + 0.5:
		var feet := Vector3(pos.x, 0.0, pos.z)
		for a in _cache_sweep:
			if DashCourse.sweeper_touches(a, feet, 0.12):
				return false
	return true


func _refresh_cache() -> void:
	_cache_t = _t
	var l := layout
	_cache_heads.clear()
	var n := 10
	for k in DashCourse.HAMMER_Z.size():
		var heads := PackedVector3Array()
		for i in n + 1:
			heads.append(DashCourse.hammer_head(l, k, _t + SAFE_HORIZON * _clock_scale() * i / n))
		_cache_heads.append(heads)
	_cache_logs.clear()
	var ahead := LOG_LOOKAHEAD * _clock_scale()
	var w := DashCourse.log_window(l, _t, _t + ahead)
	for i in range(w.x, w.y):
		if not (DashCourse.log_active(l, i, _t) or DashCourse.log_active(l, i, _t + ahead)):
			continue
		var z0 := DashCourse.log_z(l, i, _t)
		var z1 := DashCourse.log_z(l, i, _t + ahead)
		_cache_logs.append(Vector4(DashCourse.LOG_LANES[l.log_lane[i]], 0.0, minf(z0, z1), maxf(z0, z1)))
	_cache_sweep.clear()
	for i in 4:
		_cache_sweep.append(DashCourse.sweep_angle(l, _t + HOP_HORIZON * 1.5 * _clock_scale() * i / 3.0))
	_cache_rafts.resize(12)
	for r in DashCourse.ROW_Z.size():
		for i in 2:
			_cache_rafts[r * 2 + i] = DashCourse.platform_x(l, r, i, _t)
			_cache_rafts[6 + r * 2 + i] = DashCourse.platform_x(l, r, i, _t + RAFT_HORIZON * _clock_scale())


# --- Visuals (every peer) ------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_anim += delta
	if _running:
		var frac := Engine.get_physics_interpolation_fraction()
		_t_vis = minf(_t + frac / float(Engine.physics_ticks_per_second) * _clock_scale(), _freeze_at)
	_update_visuals(_t_vis)
	_update_camera()
	_hud_cd -= delta
	if _hud_cd <= 0.0:
		_hud_cd = 0.25
		_update_places()
	_update_strip()


## Moves the physical movers (rafts, turntable) to round time `t`. Physics frames only.
func _update_movers(t: float) -> void:
	for r in DashCourse.ROW_Z.size():
		for i in 2:
			var body := _rafts[r * 2 + i] if r * 2 + i < _rafts.size() else null
			if body:
				body.position = DashCourse.platform_position(layout, r, i, t)
	if _disc:
		_disc.rotation.y = DashCourse.disc_angle(layout, t)


func _update_visuals(t: float) -> void:
	for k in _hammers.size():
		_hammers[k].rotation.z = DashCourse.hammer_angle(layout, k, t)
	if _sweeper_bar:
		_sweeper_bar.rotation.y = DashCourse.sweep_angle(layout, t)
	_update_logs(t)
	for i in _flags.size():
		var flag := _flags[i]
		_flag_pop[i] = maxf(_flag_pop[i] - get_process_delta_time() * 1.5, 0.0)
		flag.rotation.y = 0.25 * sin(_anim * 3.1 + i) + _flag_pop[i] * sin(_anim * 18.0) * 0.6
		flag.scale = Vector3.ONE * (1.0 + 0.35 * _flag_pop[i])


func _update_logs(t: float) -> void:
	if not _running:
		return
	var l := layout
	var w := DashCourse.log_window(l, t, t)
	for id: int in _logs.keys():
		if id < w.x or id >= w.y or not DashCourse.log_active(l, id, t):
			_release_log(id)
	for i in range(w.x, w.y):
		if not DashCourse.log_active(l, i, t):
			continue
		var node: Node3D = _logs.get(i)
		if node == null:
			node = _take_log()
			_logs[i] = node
		var pos := DashCourse.log_position(l, i, t)
		var rock := 0.0
		if t < l.log_t[i]:
			rock = 0.12 * sin(_anim * 22.0 + i)
		node.position = pos
		node.rotation = Vector3(DashCourse.log_roll(l, i, t) + rock, 0.0, 0.0)
		node.scale = Vector3.ONE * clampf((t - (l.log_t[i] - DashCourse.LOG_WOBBLE)) / 0.15, 0.2, 1.0)


func _take_log() -> Node3D:
	var node: Node3D
	if _log_pool.is_empty():
		node = LOG_SCENE.instantiate() as Node3D
		Look.apply_toon(node)
		$Logs.add_child(node)
	else:
		node = _log_pool.pop_back()
	node.visible = true
	return node


func _release_log(id: int) -> void:
	var node: Node3D = _logs.get(id)
	if node:
		_logs.erase(id)
		node.visible = false
		_log_pool.append(node)
		if _running and DashCourse.log_z(layout, id, _t) > DashCourse.LOG_Z_END - 0.2:
			Fx.play(&"dust_puff", node.position, Color(0.8, 0.7, 0.55))


## Places, best first, on this peer's own view: finishers by finish order, the rest by
## checkpoint and distance. Pushed as the HUD counter (1 = first).
func _update_places() -> void:
	if players.is_empty():
		return
	var others: Array[int] = []
	var prog: Dictionary = {}
	for p in players:
		if _live(p) and not finish_times.has(p.slot):
			others.append(p.slot)
			prog[p.slot] = DashCourse.progress(p.global_position)
	var order := DashCourse.rank(finish_order, others, checkpoints, prog)
	for i in order.size():
		var s := order[i]
		if _places.get(s, -1) != i + 1:
			_places[s] = i + 1
			RoundUI.push_counter(s, i + 1)


## Current place of `slot` on this peer (1 = first).
func place_of(slot: int) -> int:
	return _places.get(slot, 0)


func _update_camera() -> void:
	if _camera == null or players.is_empty():
		return
	var pts: Array[Vector3] = []
	var zs: Array[float] = []
	for p in players:
		if not _live(p) or p.global_position.y < DashCourse.SINK_Y:
			continue
		var at := p.global_position
		at.x = clampf(at.x, -DashCourse.HALF_W, DashCourse.HALF_W)
		at.y = maxf(at.y, 0.0) + _camera.target_height
		at.z = clampf(at.z, DashCourse.FINISH_Z - 4.0, DashCourse.SPAWN_Z)
		pts.append(at)
		zs.append(at.z)
	if pts.is_empty():
		return
	var lo: float = zs.min()
	var hi: float = zs.max()
	if hi - lo > CAM_SPREAD:
		var me := _player(Net.local_slot())
		var anchor := INF
		if _live(me) and me.global_position.y > DashCourse.SINK_Y:
			anchor = clampf(me.global_position.z, DashCourse.FINISH_Z - 4.0, DashCourse.SPAWN_Z)
		var best_top := hi
		var best_count := -1
		for top: float in zs:
			if anchor != INF and (anchor > top + 0.01 or anchor < top - CAM_SPREAD):
				continue
			var count := 0
			for z: float in zs:
				if z <= top + 0.01 and z >= top - CAM_SPREAD:
					count += 1
			if count > best_count or (count == best_count and top < best_top):
				best_count = count
				best_top = top
		if best_count < 0:
			best_top = anchor + CAM_SPREAD * 0.5
		var window: Array[Vector3] = []
		for p3 in pts:
			if p3.z <= best_top + 0.01 and p3.z >= best_top - CAM_SPREAD:
				window.append(p3)
		if anchor != INF:
			# stretched: keep a look at the course just ahead of yourself
			window.append(Vector3(0.0, _camera.target_height, maxf(anchor - CAM_AHEAD, DashCourse.FINISH_Z - 4.0)))
		pts = window
	var tan_v := tan(deg_to_rad(_camera.fov) * 0.5)
	var vp := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(16.0, 9.0)
	var aspect := vp.x / vp.y if vp.y > 0.0 else 16.0 / 9.0
	var framed := ArenaCamera.frame_points(pts, _camera.view_basis(), tan_v, aspect, _camera.margin)
	var focus: Vector3 = framed[0]
	focus.x = clampf(focus.x, -1.2, 1.2)
	_camera.fixed_focus = focus
	_camera.fixed_distance = clampf(float(framed[1]), CAM_MIN_DISTANCE, CAM_MAX_DISTANCE)


# --- HUD strip (every peer) ----------------------------------------------------------------------------

func _build_strip(setup_players: Array[Player]) -> void:
	if _strip:
		_strip.get_parent().queue_free()
		_strip = null
	_dots.clear()
	var layer := CanvasLayer.new()
	layer.name = "ProgressStrip"
	layer.layer = 2
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_CENTER_TOP)
	root.position = Vector2(-260.0, 96.0)  # under the round timer pill
	root.size = Vector2(520.0, 14.0)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	_strip = root
	var bar := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.1, 0.16, 0.55)
	sb.set_corner_radius_all(6)
	bar.add_theme_stylebox_override(&"panel", sb)
	bar.position = Vector2(0.0, 3.0)
	bar.size = Vector2(520.0, 8.0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)
	for z: float in DashCourse.CHECKPOINT_Z:
		var tick := ColorRect.new()
		tick.color = Color(0.91, 0.7, 0.23, 0.9)
		tick.size = Vector2(3.0, 14.0)
		tick.position = Vector2(520.0 * DashCourse.progress(Vector3(0, 0, z)) / DashCourse.TOTAL - 1.5, 0.0)
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(tick)
	var fin := ColorRect.new()
	fin.color = Color(0.97, 0.95, 0.9, 0.95)
	fin.size = Vector2(4.0, 18.0)
	fin.position = Vector2(518.0, -2.0)
	fin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fin)
	for p in setup_players:
		var me := p.slot == Net.local_slot()
		var d := 16.0 if me else 11.0
		var dot := Panel.new()
		var ds := StyleBoxFlat.new()
		ds.bg_color = _player_color(p.slot)
		ds.set_corner_radius_all(int(d / 2.0))
		ds.set_border_width_all(2 if me else 1)
		ds.border_color = Color.WHITE if me else Color(0.1, 0.08, 0.12, 0.8)
		dot.add_theme_stylebox_override(&"panel", ds)
		dot.size = Vector2(d, d)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.z_index = 1 if me else 0
		root.add_child(dot)
		_dots[p.slot] = dot


func _update_strip() -> void:
	if _strip == null:
		return
	for p in players:
		var dot: Control = _dots.get(p.slot)
		if dot == null:
			continue
		dot.visible = is_instance_valid(p) and p.is_inside_tree()
		if not dot.visible:
			continue
		var f := 1.0 if finish_times.has(p.slot) else DashCourse.progress(p.global_position) / DashCourse.TOTAL
		dot.position = Vector2(520.0 * f - dot.size.x * 0.5, 7.0 - dot.size.y * 0.5)


# --- Build ----------------------------------------------------------------------------------------------

func _build_course() -> void:
	var root := $Course as Node3D
	var ground := COURSE_SCENE.instantiate() as Node3D
	root.add_child(ground)
	Look.apply_toon(ground, false)
	var water := MeshInstance3D.new()
	water.name = "Water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(2.0 * DashCourse.HALF_W + 0.6, DashCourse.POND_Z0 - DashCourse.POND_Z1 + 0.3)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	water.mesh = plane
	water.material_override = WATER_MATERIAL
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water.position = Vector3(0.0, DashCourse.WATER_Y, (DashCourse.POND_Z0 + DashCourse.POND_Z1) * 0.5)
	root.add_child(water)
	# side borders, 10 m strips
	var z := DashCourse.PEN_BACK_Z
	while z > DashCourse.PEN_END_Z + 0.1:
		var len_ := minf(10.0, z - DashCourse.PEN_END_Z)
		for s: float in [-1.0, 1.0]:
			var b := _place(root, BORDER_SCENE, Vector3(s * (DashCourse.HALF_W + 0.4), 0.0, z - len_ * 0.5), 0.0)
			b.scale = Vector3(1.0, 1.0, len_ / 10.0)
		z -= len_
	# back walls of the start pen and the finish pen
	for bz: float in [DashCourse.PEN_BACK_Z + 0.4, DashCourse.PEN_END_Z - 0.4]:
		var b := _place(root, BORDER_SCENE, Vector3(0.0, 0.0, bz), PI * 0.5)
		b.scale = Vector3(1.0, 1.0, (2.0 * DashCourse.HALF_W + 1.6) / 10.0)
	# hedges: 2 x 1 blocks scaled to each footprint
	for r in DashCourse.HEDGES:
		var nx := maxi(1, roundi(r.size.x / 2.0))
		var nz := maxi(1, roundi(r.size.y / 1.0))
		if r.size.y > r.size.x:
			# a long wall along z: blocks turned 90 degrees
			nz = maxi(1, roundi(r.size.y / 2.0))
			for j in nz:
				var cz := r.position.y + r.size.y * (j + 0.5) / nz
				var h := _place($Hedges, HEDGE_SCENE, Vector3(r.get_center().x, 0.0, cz), PI * 0.5)
				h.scale = Vector3(r.size.y / nz / 2.0, 1.0, r.size.x)
			continue
		for i in nx:
			var cx := r.position.x + r.size.x * (i + 0.5) / nx
			var h := _place($Hedges, HEDGE_SCENE, Vector3(cx, 0.0, r.get_center().y), 0.0)
			h.scale = Vector3(r.size.x / nx / 2.0, 1.0, r.size.y)
	_place(root, GATE_SCENE, Vector3(0.0, 0.0, DashCourse.START_Z), 0.0)
	_place(root, ARCH_SCENE, Vector3(0.0, 0.0, DashCourse.FINISH_Z), 0.0)
	for k in DashCourse.CHECKPOINT_Z.size():
		var cz: float = DashCourse.CHECKPOINT_Z[k]
		for s: float in [-1.0, 1.0]:
			var f := _place(root, FLAG_SCENE, Vector3(s * (DashCourse.HALF_W + 0.45), DashCourse.ground_y(cz), cz), 0.0 if s < 0 else PI)
			f.set_meta(StaticMerge.SKIP_META, true)  # the cloth waves
			var cloth := f.get_node_or_null(^"Pole/Flag") as MeshInstance3D
			if cloth == null:
				cloth = f.find_child("Flag", true, false) as MeshInstance3D
			if cloth:
				var m := (cloth.get_active_material(0) as StandardMaterial3D).duplicate() as StandardMaterial3D
				cloth.set_surface_override_material(0, m)
				_flag_mats.append(m)
				_flags.append(cloth)
	for b in DashCourse.BUMPERS:
		_place(root, BUMPER_SCENE, Vector3(b.x, 0.0, b.y), 0.0)


func _build_movers() -> void:
	var first: float = DashCourse.HAMMER_Z[0]
	var last: float = DashCourse.HAMMER_Z[DashCourse.HAMMER_Z.size() - 1]
	var frame := FRAME_SCENE.instantiate() as Node3D
	frame.position = Vector3(0.0, 0.0, (first + last) * 0.5)  # rail + both gantries
	$Hammers.add_child(frame)
	_fade_near_camera(frame)
	for k in DashCourse.HAMMER_Z.size():
		var hz: float = DashCourse.HAMMER_Z[k]
		var hammer := _place($Hammers, HAMMER_SCENE, Vector3(0.0, DashCourse.PIVOT_Y, hz), 0.0)
		_hammers.append(hammer)
	for r in DashCourse.ROW_Z.size():
		for i in 2:
			var body := AnimatableBody3D.new()
			body.name = "Raft%d_%d" % [r, i]
			body.collision_layer = 1
			body.collision_mask = 0
			body.sync_to_physics = true
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(2.0 * DashCourse.PLAT_HALF_X, DashCourse.PLAT_THICK, 2.0 * DashCourse.PLAT_HALF_Z)
			shape.shape = box
			shape.position = Vector3(0.0, -DashCourse.PLAT_THICK * 0.5, 0.0)
			body.add_child(shape)
			var model := PLATFORM_SCENE.instantiate() as Node3D
			body.add_child(model)
			Look.apply_toon(model)
			body.position = DashCourse.platform_position(layout, r, i, 0.0)
			$Rafts.add_child(body)
			_rafts.append(body)
	_disc = AnimatableBody3D.new()
	_disc.name = "Disc"
	_disc.collision_layer = 1
	_disc.collision_mask = 0
	_disc.sync_to_physics = true
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = DashCourse.DISC_R
	cyl.height = 0.3
	cs.shape = cyl
	cs.position = Vector3(0.0, DashCourse.DISC_TOP - 0.15, 0.0)
	_disc.add_child(cs)
	var disc_model := DISC_SCENE.instantiate() as Node3D
	_disc.add_child(disc_model)
	Look.apply_toon(disc_model, false)
	_disc.position = Vector3(0.0, 0.0, DashCourse.DISC_Z)
	$Spinner.add_child(_disc)
	var sweeper := _place($Spinner, SWEEPER_SCENE, Vector3(0.0, DashCourse.DISC_TOP, DashCourse.DISC_Z), 0.0)
	_sweeper_bar = sweeper.get_node_or_null(^"Bar") as Node3D


func _build_decor() -> void:
	var decor := $Decor as Node3D
	# mansion facade behind the finish pen
	var fz := DashCourse.PEN_END_Z - 2.6
	for i in 7:
		var x := -12.0 + 4.0 * i
		if i == 3:
			_place(decor, DOOR_SCENE, Vector3(x, 0.0, fz), 0.0)
		else:
			_place(decor, WALL_SCENE, Vector3(x, 0.0, fz), 0.0)
	for i in 8:
		_place(decor, PILLAR_SCENE, Vector3(-14.0 + 4.0 * i, 0.0, fz + 0.3), 0.0)
	# potted plants along both sides, outside the borders
	for i in 9:
		var z := 30.0 - 9.0 * i
		for s: float in [-1.0, 1.0]:
			if z < 19.0 and z > 7.0:
				continue  # hammer frame posts stand there
			_place(decor, PLANT_SCENE, Vector3(s * 6.4, 0.0, z + (0.0 if s < 0 else 4.5)), 0.3 * i)


## Toon without outline, and dithered out where it comes close to the camera: the overhead rail
## and gantries of the hammer alley would otherwise cut across the view of the blobs below.
func _fade_near_camera(root: Node3D) -> void:
	Look.apply_toon(root, false)
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s) as StandardMaterial3D
			if src == null:
				continue
			var m: StandardMaterial3D = _fade_mats.get(src)
			if m == null:
				m = src.duplicate() as StandardMaterial3D
				m.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_DITHER
				m.distance_fade_min_distance = FADE_NEAR
				m.distance_fade_max_distance = FADE_FAR
				_fade_mats[src] = m
			mi.set_surface_override_material(s, m)


func _place(parent: Node, scene: PackedScene, at: Vector3, yaw: float) -> Node3D:
	var n := scene.instantiate() as Node3D
	n.position = at
	n.rotation.y = yaw
	parent.add_child(n)
	Look.apply_toon(n)
	return n


func _build_colliders() -> void:
	var body := StaticBody3D.new()
	body.name = "Colliders"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var w := 2.0 * DashCourse.HALF_W + 2.0
	# flat ground: start .. ramp foot, ramp bank .. pond, far bank .. finish pen
	_add_box(body, Vector3(w, 1.0, DashCourse.PEN_BACK_Z + 2.0 - DashCourse.RAMP_Z0), Vector3(0.0, -0.5, (DashCourse.PEN_BACK_Z + 2.0 + DashCourse.RAMP_Z0) * 0.5))
	_add_slope(body, DashCourse.RAMP_Z0, 0.0, DashCourse.RAMP_Z1, DashCourse.RAMP_H, w)
	_add_box(body, Vector3(w, 0.6, DashCourse.RAMP_Z1 - DashCourse.TOP_Z1), Vector3(0.0, DashCourse.RAMP_H - 0.3, (DashCourse.RAMP_Z1 + DashCourse.TOP_Z1) * 0.5))
	_add_slope(body, DashCourse.TOP_Z1, DashCourse.RAMP_H, DashCourse.DOWN_Z1, 0.0, w)
	_add_box(body, Vector3(w, 1.0, DashCourse.DOWN_Z1 - DashCourse.POND_Z0), Vector3(0.0, -0.5, (DashCourse.DOWN_Z1 + DashCourse.POND_Z0) * 0.5))
	_add_box(body, Vector3(w, 1.0, DashCourse.POND_Z0 - DashCourse.POND_Z1), Vector3(0.0, DashCourse.POND_FLOOR - 0.5, (DashCourse.POND_Z0 + DashCourse.POND_Z1) * 0.5))
	_add_box(body, Vector3(w, 1.0, DashCourse.POND_Z1 - DashCourse.PEN_END_Z + 2.0), Vector3(0.0, -0.5, (DashCourse.POND_Z1 + DashCourse.PEN_END_Z - 2.0) * 0.5))
	# walls: sides, start pen back, finish pen back
	var length := DashCourse.PEN_BACK_Z - DashCourse.PEN_END_Z + 2.0
	var mid := (DashCourse.PEN_BACK_Z + DashCourse.PEN_END_Z) * 0.5
	for s: float in [-1.0, 1.0]:
		_add_box(body, Vector3(1.0, 9.0, length), Vector3(s * (DashCourse.HALF_W + 0.5), 2.5, mid))
	_add_box(body, Vector3(w, 9.0, 1.0), Vector3(0.0, 2.5, DashCourse.PEN_BACK_Z + 0.5))
	_add_box(body, Vector3(w, 9.0, 1.0), Vector3(0.0, 2.5, DashCourse.PEN_END_Z - 0.5))
	for r in DashCourse.HEDGES:
		_add_box(body, Vector3(r.size.x, 3.0, r.size.y), Vector3(r.get_center().x, 1.5, r.get_center().y))
	for b in DashCourse.BUMPERS:
		_add_cylinder(body, Vector3(b.x, 0.0, b.y), DashCourse.BUMPER_R, DashCourse.BUMPER_H)
	_add_cylinder(body, Vector3(0.0, 0.0, DashCourse.DISC_Z), DashCourse.POST_R, 1.15)


func _add_box(body: StaticBody3D, size: Vector3, at: Vector3, rot_x: float = 0.0) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var cs := CollisionShape3D.new()
	cs.shape = box
	cs.position = at
	cs.rotation.x = rot_x
	body.add_child(cs)


## A ramp from (z0, y0) to (z1, y1) (z1 < z0): a box whose top face is exactly that slope.
func _add_slope(body: StaticBody3D, z0: float, y0: float, z1: float, y1: float, width: float) -> void:
	var thick := 0.6
	var dz := z0 - z1
	var dy := y1 - y0
	var length := sqrt(dz * dz + dy * dy)
	var ang := atan2(dy, dz)
	var normal := Vector3(0.0, cos(ang), sin(ang))
	var mid := Vector3(0.0, (y0 + y1) * 0.5, (z0 + z1) * 0.5) - normal * thick * 0.5
	_add_box(body, Vector3(width, thick, length + 0.05), mid, ang)


func _add_cylinder(body: StaticBody3D, at: Vector3, radius: float, height: float) -> void:
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	var cs := CollisionShape3D.new()
	cs.shape = cyl
	cs.position = at + Vector3(0.0, height * 0.5, 0.0)
	body.add_child(cs)


# --- Helpers ---------------------------------------------------------------------------------------------

## Dev (`--dash-at=Z`): spreads every player across the course at `z` (host, after _start).
func _place_all_at(z: float) -> void:
	for i in players.size():
		var p := players[i]
		var x := -3.5 + 7.0 * i / maxf(players.size() - 1, 1)
		p.place_at(Transform3D(Basis(Vector3.UP, PI), Vector3(x, DashCourse.ground_y(z) + 0.1, z + 0.6 * (i % 2))))
		var k := DashCourse.checkpoint_at(p.global_position)
		if k >= 0:
			_rpc_checkpoint.rpc(p.slot, k)


func _player_color(slot: int) -> Color:
	var p := _player(slot)
	if p and p.loadout.has("primary"):
		return Look.parse_color(p.loadout["primary"], Look.CREAM)
	var info: Variant = Net.roster.get(slot)
	if info != null and info.get(&"loadout") is Dictionary:
		return Look.parse_color((info.get(&"loadout") as Dictionary).get("primary", ""), Look.CREAM)
	return Look.CREAM


func _name_of(slot: int) -> String:
	var p := _player(slot)
	if p and p.display_name != "":
		return p.display_name
	return "P%d" % (slot + 1)


static func _ordinal(place: int) -> String:
	return ORDINALS[clampi(place - 1, 0, ORDINALS.size() - 1)]


func _clock_scale() -> float:
	return time_scale * Session.time_scale


func _player(slot: int) -> Player:
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _live(p: Player) -> bool:
	return p != null and is_instance_valid(p) and p.is_inside_tree() and p.alive


static func _hash01(n: int) -> float:
	var h := (n * 2654435761) & 0xffffffff
	h = ((h >> 16) ^ h) * 0x45d9f3b & 0xffffffff
	h = ((h >> 16) ^ h) & 0xffffffff
	return float(h % 10007) / 10007.0
