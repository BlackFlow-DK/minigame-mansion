class_name SnowballFight
extends Minigame
## Snowball Fight: the mansion's snowy courtyard. The shove is off this round; action is the snowball:
## press (on the ground) to scoop one (0.35 s, slowed), press again to throw it along your facing
## (a little auto-aim toward a blob within 12 degrees). Carrying a ball slows you to 90 %. A hit
## knocks the blob back (8 m/s) with a short stun and scores +1 for the thrower; the third hit
## taken snows a blob in for 3 s (frozen inside a snowman, then 1 s of invulnerability, counter
## reset). Walls, snowmen and pines stop balls. Every 20 s a giant snowball pile appears in the
## middle: 3 balls at once for whoever touches it first. The last 10 s are the BLIZZARD: double
## points. Ranking by points, ties by fewer times snowed in, then the earlier last hit; 60 s.
##
## Networking (docs/contract.md "Networking rules for minigames"):
## - Two clocks start on every peer from the host's `_rpc_begin`: the round clock `_t` (time
##   limit, piles, blizzard; scaled by time_scale) and the sim clock `_sim` (real seconds: balls,
##   scoops, snow-ins).
## - A press is read on the presser's authority (its own players only). Scoop and throw are
##   requests to the host (`_rpc_req_scoop` / `_rpc_req_throw` with origin and direction); the host
##   checks the sender owns the blob, it has a ready ball, the throw cooldown and that the origin is
##   near where it sees the blob, then broadcasts the launch (`_rpc_launch`: id, thrower, origin,
##   direction, sim time). Every peer runs the same SnowArc from it, including where it ends.
## - Each peer tests the balls against its own authority blobs only, applies the knockback there
##   (`apply_impulse`, so got_hit/stunned events and effects play everywhere) and reports to the
##   host (`_rpc_report_hit`), which checks ownership and that the reported feet were on that ball's
##   path around now, scores once per ball and broadcasts (`_rpc_hit`). Snow-ins and releases,
##   the pile and the round end are host decisions sent the same way. `frozen` is set on every peer.
##
## Bots: SnowBot (perception and goals, on the blob's authority) answers get_bot_goal and the
## BotBrain hooks bot_wants_action / bot_aim; the brain presses action like a human does.

## Every peer: the clocks (re)started at round time `start_time`.
signal round_began(start_time: float)
## Every peer: ball `id` was thrown by `slot`.
signal ball_launched(id: int, slot: int)
## Every peer: ball `id` ran into something (SnowArc.End) without hitting a blob on this peer.
signal ball_ended(id: int, kind: int)
## The peer that owns `slot`: one of its blobs was hit by ball `ball_id` (before the host confirms).
signal local_hit(slot: int, ball_id: int)
## Every peer: the host counted ball `ball_id` from `thrower` hitting `victim` for `points`.
signal hit_confirmed(ball_id: int, thrower: int, victim: int, points: int)
## Every peer: `slot` started a scoop.
signal scooped(slot: int)
## Every peer: `slot` is snowed in / free again.
signal snowed_in(slot: int)
signal released(slot: int)
## Every peer: the ammo pile appeared (active) or was taken by `slot` (-1 when it appeared).
signal pile_changed(active: bool, slot: int)
## Every peer, from its own round clock.
signal blizzard_started

const SHELL_SCENE: PackedScene = preload("res://assets/models/props/snow_man_shell.glb")
const PILE_SCENE: PackedScene = preload("res://assets/models/props/snow_pile.glb")

const FALL_Y := -3.0
## A request in flight blocks further presses of that blob this long (s) unless answered.
const PENDING_TIME := 0.3
## Touch radius of the ammo pile (m, on XZ).
const PILE_RADIUS := 1.25
## Host hit check: the reported feet must touch the ball's path within this window around now (s)
## and with this much slack (m); the host must see the blob within POS_SLACK of the report.
const HOST_HIT_PAST := 0.45
const HOST_HIT_AHEAD := 0.15
const HOST_HIT_SLACK := 0.3
const HOST_POS_SLACK := 3.5
## Host throw check: the origin must be this near the release point it sees (m).
const HOST_ORIGIN_SLACK := 2.5
## Visuals.
const BALL_MESH_R := 0.24
const TRAIL := 4
const TRAIL_GAP := 0.024
const CARRY_Y := 1.32
const BALL_COLOR := Color(0.97, 0.99, 1.0)
const TRAIL_COLOR := Color(0.62, 0.84, 1.0)


## One thrown snowball (every peer, same data from the launch RPC).
class Ball:
	var id: int
	var thrower: int
	var origin: Vector3
	var dir: Vector3
	var t0: float
	var t_end: float
	var end_kind: int
	## This peer: the ball is gone (ran into something or hit someone).
	var done: bool = false
	## Host: it already scored.
	var host_used: bool = false
	## This peer's own blobs it already hit.
	var hit_slots: Dictionary = {}
	var nodes: Array[MeshInstance3D] = []

	func position(s: float) -> Vector3:
		return SnowArc.position(origin, dir, s)


@export_group("Rules")
@export var scoop_time: float = 0.35
@export var throw_cooldown: float = 0.3
## Max speed while carrying, and while scooping (fractions of the blob's own).
@export var carry_speed: float = 0.9
@export var scoop_speed: float = 0.45
## Knockback of a hit (horizontal m/s along the ball's flight) and its lift.
@export var knockback: float = 8.0
@export var knockback_lift: float = 2.5
@export var hits_to_snow: int = 3
@export var snowed_time: float = 3.0
@export var release_invuln: float = 1.0
## Round-clock times the ammo pile appears, and what it gives.
@export var pile_times: PackedFloat32Array = PackedFloat32Array([20.0, 40.0])
@export var pile_balls: int = 3
@export var max_ammo: int = 4
## The last this-many seconds are the blizzard (double points).
@export var blizzard_time: float = 10.0
## Human throws: snap to a blob within this angle of the facing and this range.
@export var aim_assist_deg: float = 12.0
@export var aim_assist_range: float = 12.0
@export var end_grace: float = 2.0

@export_group("Test")
## Test-only: multiplies the round clock (time limit, piles, blizzard); balls keep real speed.
@export var time_scale: float = 1.0
## Seed of the thrower AIs (-1 = random).
@export var ai_seed: int = -1
## False: no thrower AI at all (unit tests drive every press themselves).
@export var ai_enabled: bool = true
## Round clock at the start (host). Dev: `--snow-start=SEC`.
@export var start_time: float = 0.0

## Mutators that make no sense here (the shove is off).
var mutator_blocklist: Array[StringName] = [&"super_shove"]
## BotBrain hint: never chase; the walking goals and the presses come from SnowBot's answers.
var bot_aggression_scale: float = 0.0
## Tests / dev / network check: human slots driven by the thrower AI on their authority peer.
var ai_slots: Array[int] = []

## Every peer, replicated by the host's RPCs.
var scores: Dictionary[int, int] = {}
var hits_taken: Dictionary[int, int] = {}
var snowed_count: Dictionary[int, int] = {}
## slot -> round time of its last scoring hit (absent = none).
var last_hit_time: Dictionary[int, float] = {}
var ammo: Dictionary[int, int] = {}
## slot -> sim time its carried ball is ready (the scoop's end).
var ready_at: Dictionary[int, float] = {}
var snowed: Dictionary[int, bool] = {}
var throws: Dictionary[int, int] = {}
var hits_landed: Dictionary[int, int] = {}
var pile_active: bool = false
## Host: requests and reports from other peers it accepted / refused as implausible / ignored
## (late or duplicate: already scored, snowed in, invulnerable).
var accepted_remote_throws: int = 0
var accepted_remote_hits: int = 0
var rejected_reports: int = 0
var ignored_reports: int = 0

var _t: float = 0.0
var _sim: float = 0.0
var _sim_vis: float = 0.0
var _running: bool = false
var _ended: bool = false
var _blizzard: bool = false
var _balls: Dictionary[int, Ball] = {}
var _active: Array[int] = []
var _bots: Dictionary[int, SnowBot] = {}
var _ai_base_seed: int = 0
var _pending_until: Dictionary[int, float] = {}
var _last_throw: Dictionary[int, float] = {}
var _invuln_until: Dictionary[int, float] = {}
var _base_speed: Dictionary[int, float] = {}
var _speed_factor: Dictionary[int, float] = {}
var _carry_kind: Dictionary[int, StringName] = {}
# Host only.
var _next_ball: int = 1
var _pile_next: int = 0
var _host_last_throw: Dictionary[int, float] = {}
var _host_snowed_until: Dictionary[int, float] = {}
var _host_invuln_until: Dictionary[int, float] = {}
var _dev_snow_slot: int = -1
# Visuals.
var _ball_pool: Array = []
var _ball_mat: StandardMaterial3D
var _trail_mats: Array[StandardMaterial3D] = []
var _carry: Dictionary[int, Node3D] = {}
var _shells: Dictionary[int, Node3D] = {}
var _shields: Dictionary[int, MeshInstance3D] = {}
var _pile: Node3D
var _snow: CPUParticles3D
var _storm: CPUParticles3D
var _lights: Array[OmniLight3D] = []
var _anim: float = 0.0

@onready var _camera: ArenaCamera = $ArenaCamera as ArenaCamera
@onready var _balls_root: Node3D = $Balls
@onready var _fx_root: Node3D = $Effects


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--snow-start="):
			start_time = arg.trim_prefix("--snow-start=").to_float()
		elif arg.begins_with("--snow-snowed="):
			_dev_snow_slot = arg.trim_prefix("--snow-snowed=").to_int()
		elif arg.begins_with("--snow-time-scale="):
			time_scale = maxf(arg.trim_prefix("--snow-time-scale=").to_float(), 0.01)
	var built := SnowYard.build($Yard as Node3D, Look.is_low())
	_lights.assign(built["lights"])
	_ball_mat = Look.toon_material(BALL_COLOR, 0.5).duplicate() as StandardMaterial3D
	_ball_mat.emission_enabled = true
	_ball_mat.emission = Color(0.55, 0.78, 1.0)
	_ball_mat.emission_energy_multiplier = 0.35
	for k in TRAIL:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(TRAIL_COLOR.r, TRAIL_COLOR.g, TRAIL_COLOR.b, 0.6 * pow(0.62, k))
		_trail_mats.append(m)
	_pile = PILE_SCENE.instantiate() as Node3D
	_pile.name = "Pile"
	_pile.position = SnowYard.PILE_AT
	_pile.visible = false
	add_child(_pile)
	Look.apply_toon(_pile)
	_build_snowfall()
	add_to_group(Look.QUALITY_GROUP)
	apply_quality()


## Look quality switch (also live): LOW drops the falling snow and the lantern lights.
func apply_quality() -> void:
	var low := Look.is_low()
	for l in _lights:
		l.visible = not low
	if _snow:
		_snow.visible = not low
		_snow.emitting = not low
	if _storm:
		_storm.visible = not low and _blizzard
		_storm.emitting = not low and _blizzard


# --- Minigame flow --------------------------------------------------------------------------

func _setup(setup_players: Array[Player]) -> void:
	for d: Dictionary in [scores, hits_taken, snowed_count, last_hit_time, ammo, ready_at, snowed, throws, hits_landed]:
		d.clear()
	for p in setup_players:
		scores[p.slot] = 0
		hits_taken[p.slot] = 0
		snowed_count[p.slot] = 0
		ammo[p.slot] = 0
		throws[p.slot] = 0
		hits_landed[p.slot] = 0
		var shove := p.get_component(&"shove") as ShoveComponent
		if shove:
			shove.enabled = false
		var mv := p.get_component(&"movement") as MovementComponent
		if mv:
			_base_speed[p.slot] = mv.max_speed  # players are frozen: this is the base (size factor 1)
		_speed_factor[p.slot] = 1.0


func _start() -> void:
	if not multiplayer.is_server():
		return
	_ai_base_seed = ai_seed if ai_seed >= 0 else randi() % 1000000
	begin(start_time)


## Host: (re)starts both clocks on every peer, the round clock at `t0`.
func begin(t0: float = 0.0) -> void:
	_pile_next = 0
	while _pile_next < pile_times.size() and pile_times[_pile_next] < t0:
		_pile_next += 1
	_rpc_begin.rpc(t0)


func _host_tick(_delta: float) -> void:
	if not _running or is_finished():
		return
	for p in players:
		if _live(p) and p.global_position.y < FALL_Y:
			var points := get_spawn_points()
			p.respawn_at(points[p.slot % points.size()])
	for slot: int in _host_snowed_until.keys():
		if _sim >= _host_snowed_until[slot]:
			_host_snowed_until.erase(slot)
			_host_invuln_until[slot] = _sim + release_invuln
			_rpc_release.rpc(slot)
	if _dev_snow_slot >= 0 and _sim >= 1.0:
		if _player(_dev_snow_slot) != null:
			_host_snow(_dev_snow_slot)
		_dev_snow_slot = -1
	if _pile_next < pile_times.size() and _t >= pile_times[_pile_next]:
		_pile_next += 1
		if not pile_active:
			_rpc_pile.rpc()
	if pile_active:
		var best: Player = null
		var best_d := PILE_RADIUS
		for p in players:
			if not _live(p) or p.frozen or is_snowed(p.slot):
				continue
			var d := Vector2(p.global_position.x - SnowYard.PILE_AT.x, p.global_position.z - SnowYard.PILE_AT.z).length()
			if d < best_d and p.global_position.y < 1.5:
				best_d = d
				best = p
		if best:
			_rpc_pile_taken.rpc(best.slot, mini(ammo_of(best.slot) + pile_balls, max_ammo))
	if time_limit > 0.0 and _t >= time_limit:
		end_round()


## Host: ends the round now: winners cheer on every peer, finish with the tied groups.
func end_round() -> void:
	if is_finished():
		return
	var groups := ranking_groups()
	var winners: Array = []
	if not groups.is_empty() and scores.get(int(groups[0][0]), 0) > 0:
		winners = groups[0].duplicate()
	_rpc_end.rpc(winners)
	finish(groups, end_grace)


## The ranking as tied groups: points (more first), then fewer snow-ins, then the earlier last
## hit; blobs equal on all three share a place.
func ranking_groups() -> Array:
	var slots: Array[int] = []
	for p in players:
		if is_instance_valid(p) and not p.is_extra:
			slots.append(p.slot)
	slots.sort_custom(func(a: int, b: int) -> bool:
		var c := _compare(a, b)
		return c < 0 if c != 0 else a < b)
	var groups: Array = []
	for s in slots:
		if not groups.is_empty() and _compare(int(groups[-1][0]), s) == 0:
			groups[-1].append(s)
		else:
			var g: Array[int] = [s]
			groups.append(g)
	return groups


## -1 when `a` ranks before `b`, 1 after, 0 tied.
func _compare(a: int, b: int) -> int:
	var sa: int = scores.get(a, 0)
	var sb: int = scores.get(b, 0)
	if sa != sb:
		return -1 if sa > sb else 1
	var na: int = snowed_count.get(a, 0)
	var nb: int = snowed_count.get(b, 0)
	if na != nb:
		return -1 if na < nb else 1
	var la: float = last_hit_time.get(a, INF)
	var lb: float = last_hit_time.get(b, INF)
	if la != lb:
		return -1 if la < lb else 1
	return 0


# --- Queries (every peer) ------------------------------------------------------------------------

func round_time() -> float:
	return _t


func sim_time() -> float:
	return _sim


func is_running() -> bool:
	return _running


func is_blizzard() -> bool:
	return _blizzard


func ammo_of(slot: int) -> int:
	return ammo.get(slot, 0)


func is_snowed(slot: int) -> bool:
	return snowed.get(slot, false)


## True while `slot` is scooping (its ball is not ready yet).
func is_scooping(slot: int) -> bool:
	return ammo_of(slot) > 0 and _sim < ready_at.get(slot, 0.0)


## True when `slot` could throw now (as far as this peer knows).
func can_throw(slot: int) -> bool:
	return _running and ammo_of(slot) > 0 and not is_snowed(slot) and _sim >= ready_at.get(slot, 0.0) \
		and _sim - _last_throw.get(slot, -100.0) >= throw_cooldown and _sim >= _pending_until.get(slot, -1.0)


func is_invulnerable(slot: int) -> bool:
	return _sim < _invuln_until.get(slot, -1.0)


func get_ball(id: int) -> Ball:
	return _balls.get(id)


## Ids of the balls still flying on this peer.
func active_balls() -> Array[int]:
	return _active.duplicate()


# --- Presses (on the blob's authority) -------------------------------------------------------------

## `p` pressed action (its authority): scoop when empty-handed, else throw along its facing (aim
## assist). Returns true when a request went to the host.
func press(p: Player) -> bool:
	if not _can_act(p):
		return false
	if ammo_of(p.slot) <= 0:
		return _try_scoop(p)
	return throw_at(p, aim_assist(p, p.facing))


## Authority: throw `p`'s ball along `dir` (no aim assist). Returns true when requested.
func throw_at(p: Player, dir: Vector3) -> bool:
	if not _can_act(p) or not can_throw(p.slot):
		return false
	var flat := SnowArc.flat_dir(dir)
	var origin := SnowArc.release_point(p.global_position, flat)
	_pending_until[p.slot] = _sim + PENDING_TIME
	if multiplayer.is_server():
		_host_throw(p.slot, origin, flat, multiplayer.get_unique_id())
	else:
		_rpc_req_throw.rpc_id(1, p.slot, origin, flat)
	return true


## The throw direction for a human facing `facing`: straight at the nearest-in-angle blob within
## aim_assist_deg and aim_assist_range, else the facing itself.
func aim_assist(p: Player, facing: Vector3) -> Vector3:
	var f := SnowArc.flat_dir(facing)
	var best := f
	var best_angle := deg_to_rad(aim_assist_deg)
	var me := p.global_position
	for o in players:
		if o == p or not _live(o) or is_snowed(o.slot):
			continue
		var to := Vector3(o.global_position.x - me.x, 0.0, o.global_position.z - me.z)
		var d := to.length()
		if d < 0.3 or d > aim_assist_range:
			continue
		var angle := f.angle_to(to / d)
		if angle < best_angle:
			best_angle = angle
			best = to / d
	return best


func _can_act(p: Player) -> bool:
	return _running and _live(p) and p.is_authority() and not p.frozen and not p.control_locked \
		and not is_snowed(p.slot) and _sim >= _pending_until.get(p.slot, -1.0)


func _try_scoop(p: Player) -> bool:
	if ammo_of(p.slot) > 0 or not p.is_on_floor():
		return false
	_pending_until[p.slot] = _sim + PENDING_TIME
	if multiplayer.is_server():
		_host_scoop(p.slot, multiplayer.get_unique_id())
	else:
		_rpc_req_scoop.rpc_id(1, p.slot)
	return true


# --- Host decisions --------------------------------------------------------------------------------

func _host_can_act(p: Player, sender: int) -> bool:
	return _running and not is_finished() and p != null and _live(p) \
		and sender == p.get_multiplayer_authority() and not is_snowed(p.slot)


func _host_scoop(slot: int, sender: int) -> void:
	var p := _player(slot)
	if not _host_can_act(p, sender) or ammo_of(slot) > 0 or p.global_position.y > 0.8:
		return
	_rpc_scoop.rpc(slot, _sim + scoop_time)


func _host_throw(slot: int, origin: Vector3, dir: Vector3, sender: int) -> void:
	var p := _player(slot)
	if not _host_can_act(p, sender):
		if p != null and _live(p) and sender != p.get_multiplayer_authority():
			rejected_reports += 1
		return
	if ammo_of(slot) <= 0 or _sim + 0.1 < ready_at.get(slot, 0.0) \
			or _sim - _host_last_throw.get(slot, -100.0) < throw_cooldown - 0.05:
		ignored_reports += 1
		return
	var flat := Vector3(dir.x, 0.0, dir.z)
	if not origin.is_finite() or not flat.is_finite() or flat.length() < 0.5:
		rejected_reports += 1
		return
	flat = flat.normalized()
	if origin.distance_to(SnowArc.release_point(p.global_position, flat)) > HOST_ORIGIN_SLACK:
		rejected_reports += 1
		print_verbose("snowball_fight: refused throw of slot %d at %s" % [slot, origin])
		return
	if sender != multiplayer.get_unique_id():
		accepted_remote_throws += 1
	_host_last_throw[slot] = _sim
	var id := _next_ball
	_next_ball += 1
	_rpc_launch.rpc(id, slot, origin, flat, _sim, ammo_of(slot) - 1)


## Host: test helper, launches a ball for `slot` without the ammo rules. Returns its id.
func inject_launch(slot: int, origin: Vector3, dir: Vector3) -> int:
	var id := _next_ball
	_next_ball += 1
	_rpc_launch.rpc(id, slot, origin, SnowArc.flat_dir(dir), _sim, ammo_of(slot))
	return id


## Host: a hit of ball `ball_id` on `victim`, reported by peer `sender` with the victim's feet.
func _host_hit(ball_id: int, victim: int, feet: Vector3, sender: int) -> void:
	if not _running or is_finished():
		return
	var b: Ball = _balls.get(ball_id)
	var p := _player(victim)
	if b == null or p == null or not _live(p) or sender != p.get_multiplayer_authority() \
			or victim == b.thrower or not feet.is_finite() \
			or feet.distance_to(p.global_position) > HOST_POS_SLACK or not _plausible(b, feet):
		rejected_reports += 1
		print_verbose("snowball_fight: refused hit report ball %d on %d from peer %d" % [ball_id, victim, sender])
		return
	if b.host_used or is_snowed(victim) or _sim < _host_invuln_until.get(victim, -1.0) - 0.15:
		ignored_reports += 1
		return
	b.host_used = true
	if sender != multiplayer.get_unique_id():
		accepted_remote_hits += 1
	var points := 2 if time_limit > 0.0 and _t >= time_limit - blizzard_time else 1
	var total: int = scores.get(b.thrower, 0) + points
	var taken: int = hits_taken.get(victim, 0) + 1
	_rpc_hit.rpc(ball_id, b.thrower, victim, points, total, taken, _t)
	if taken >= hits_to_snow:
		_host_snow(victim)


## Host: true when a blob standing at `feet` touched ball `b`'s path within the report window.
func _plausible(b: Ball, feet: Vector3) -> bool:
	var now := _sim - b.t0
	var lo := maxf(0.0, now - HOST_HIT_PAST)
	var hi := minf(b.t_end, now + HOST_HIT_AHEAD)
	var s := lo
	while s <= hi + 0.0001:
		if SnowArc.touches(b.position(s), feet, HOST_HIT_SLACK):
			return true
		s += 1.0 / 120.0
	return false


## Host: snows `slot` in on every peer for snowed_time.
func _host_snow(slot: int) -> void:
	_host_snowed_until[slot] = _sim + snowed_time
	_rpc_snowed.rpc(slot, int(snowed_count.get(slot, 0)) + 1)


# --- Every peer: balls ------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not _running:
		if _ended:
			_sim += delta  # the balls still in the air finish their flight (no more hits)
			_advance_balls(false)
		return
	_t += delta * _clock_scale()
	_sim += delta
	if not _blizzard and time_limit > 0.0 and _t >= time_limit - blizzard_time:
		_start_blizzard()
	_advance_balls(true)
	for p in players:
		if not _live(p) or not p.is_authority() or p.is_extra:
			continue
		var bot := _ai_of(p)
		if bot:
			bot.tick(delta)
		if p.intent.action_pressed:
			press(p)
	_update_speeds()


func _advance_balls(check_hits: bool) -> void:
	var i := 0
	while i < _active.size():
		var b: Ball = _balls[_active[i]]
		if b.done:
			_active.remove_at(i)
			continue
		var s := _sim - b.t0
		if s >= b.t_end:
			_end_ball(b)
			_active.remove_at(i)
			continue
		if s >= 0.0 and check_hits:
			var at := b.position(s)
			for p in players:
				if p.slot == b.thrower or b.hit_slots.has(p.slot) or not _live(p) or not p.is_authority() \
						or p.frozen or is_snowed(p.slot) or is_invulnerable(p.slot):
					continue
				if SnowArc.touches(at, p.global_position):
					b.hit_slots[p.slot] = true
					_local_hit(p, b, at)
					break
		if b.done:
			_active.remove_at(i)
			continue
		i += 1


## This peer's own blob `p` was hit by `b`: knock it now, tell the host.
func _local_hit(p: Player, b: Ball, at: Vector3) -> void:
	b.done = true
	_release_nodes(b)
	Fx.play(&"dust_puff", at, BALL_COLOR)
	p.apply_impulse(b.dir * knockback + Vector3.UP * knockback_lift, _player(b.thrower))
	var feet := p.global_position
	local_hit.emit(p.slot, b.id)
	if multiplayer.is_server():
		_host_hit(b.id, p.slot, feet, multiplayer.get_unique_id())
	else:
		_rpc_report_hit.rpc_id(1, b.id, p.slot, feet)


## `b` ran into cover, a wall or the ground (every peer, from its own sim).
func _end_ball(b: Ball) -> void:
	b.done = true
	_release_nodes(b)
	var at := b.position(b.t_end)
	Fx.play(&"dust_puff", at, BALL_COLOR)
	Sfx.play(&"land_soft", at, -6.0, 1.4)
	ball_ended.emit(b.id, b.end_kind)


func _update_speeds() -> void:
	for p in players:
		if not is_instance_valid(p):
			continue
		var slot := p.slot
		var a := ammo_of(slot)
		var f := 1.0
		if a > 0:
			f = scoop_speed if _sim < ready_at.get(slot, 0.0) else carry_speed
		if _speed_factor.get(slot, 1.0) != f:
			_speed_factor[slot] = f
			var mv := p.get_component(&"movement") as MovementComponent
			if mv and _base_speed.has(slot):
				mv.max_speed = _base_speed[slot] * f
		var kind: StringName = &"snowball" if a > 0 else &""
		if _carry_kind.get(slot, &"") != kind:
			_carry_kind[slot] = kind
			var vis := p.get_component(&"visuals")
			if vis and vis.has_method(&"set_carry_pose"):
				vis.call(&"set_carry_pose", kind)


func _start_blizzard() -> void:
	_blizzard = true
	RoundUI.push_banner("BLIZZARD! Double points!", 2.2)
	Sfx.play(&"shove_whoosh", Vector3.INF, -2.0, 0.55)
	apply_quality()
	blizzard_started.emit()


# --- RPCs ---------------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_begin(t0: float) -> void:
	_t = t0
	_sim = 0.0
	_sim_vis = 0.0
	_running = true
	_ended = false
	_blizzard = time_limit > 0.0 and t0 >= time_limit - blizzard_time
	apply_quality()
	for p in players:
		if is_instance_valid(p):
			RoundUI.push_counter(p.slot, scores.get(p.slot, 0))
	round_began.emit(t0)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_req_scoop(slot: int) -> void:
	if multiplayer.is_server():
		_host_scoop(slot, multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "reliable")
func _rpc_req_throw(slot: int, origin: Vector3, dir: Vector3) -> void:
	if multiplayer.is_server():
		_host_throw(slot, origin, dir, multiplayer.get_remote_sender_id())


@rpc("any_peer", "call_remote", "reliable")
func _rpc_report_hit(ball_id: int, victim: int, feet: Vector3) -> void:
	if multiplayer.is_server():
		_host_hit(ball_id, victim, feet, multiplayer.get_remote_sender_id())


@rpc("authority", "call_local", "reliable")
func _rpc_scoop(slot: int, ready: float) -> void:
	ammo[slot] = 1
	ready_at[slot] = ready
	_pending_until.erase(slot)
	var p := _player(slot)
	if p:
		Fx.play(&"dust_puff", p.global_position + Vector3(0.0, 0.05, 0.0), BALL_COLOR)
		Sfx.play(&"land_soft", p.global_position, -4.0, 0.8)
	scooped.emit(slot)


@rpc("authority", "call_local", "reliable")
func _rpc_launch(id: int, slot: int, origin: Vector3, dir: Vector3, t0: float, ammo_left: int) -> void:
	var b := Ball.new()
	b.id = id
	b.thrower = slot
	b.origin = origin
	b.dir = dir
	b.t0 = t0
	var end: Array = SnowArc.end_of(origin, dir)
	b.t_end = float(end[0])
	b.end_kind = int(end[1])
	_balls[id] = b
	_active.append(id)
	ammo[slot] = maxi(ammo_left, 0)
	throws[slot] = throws.get(slot, 0) + 1
	_last_throw[slot] = t0
	_pending_until.erase(slot)
	_take_nodes(b)
	Sfx.play(&"shove_whoosh", origin, -5.0, 1.3)
	var p := _player(slot)
	if p:
		var vis := p.get_component(&"visuals")
		if vis and vis.has_method(&"play_throw"):
			vis.call(&"play_throw")
	ball_launched.emit(id, slot)


@rpc("authority", "call_local", "reliable")
func _rpc_hit(ball_id: int, thrower: int, victim: int, points: int, total: int, taken: int, at_time: float) -> void:
	var b: Ball = _balls.get(ball_id)
	if b and not b.done:
		b.done = true
		_release_nodes(b)
		var v := _player(victim)
		if v:
			Fx.play(&"dust_puff", v.global_position + Vector3.UP * 0.6, BALL_COLOR)
	if _camera:
		_camera.add_shake(0.1 if points < 2 else 0.18)
	if b:
		b.host_used = true
	scores[thrower] = total
	hits_taken[victim] = taken
	hits_landed[thrower] = hits_landed.get(thrower, 0) + 1
	last_hit_time[thrower] = at_time
	RoundUI.push_counter(thrower, total)
	var tp := _player(thrower)
	if tp:
		Sfx.play(&"coin", tp.global_position, -7.0, 1.25 if points > 1 else 1.0)
	hit_confirmed.emit(ball_id, thrower, victim, points)


@rpc("authority", "call_local", "reliable")
func _rpc_snowed(slot: int, count: int) -> void:
	snowed[slot] = true
	snowed_count[slot] = count
	hits_taken[slot] = 0
	ammo[slot] = 0
	ready_at[slot] = 0.0
	var p := _player(slot)
	if p:
		p.frozen = true
		var shell := _shell_for(slot)
		shell.global_position = p.global_position
		shell.rotation.y = atan2(p.facing.x, p.facing.z)
		shell.visible = true
		shell.scale = Vector3(1.0, 0.2, 1.0)
		var tw := shell.create_tween()
		tw.tween_property(shell, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		Fx.play(&"dust_puff", p.global_position + Vector3.UP * 0.4, BALL_COLOR)
		Fx.play(&"land_thud", p.global_position, BALL_COLOR)
		Sfx.play(&"land_hard", p.global_position, -2.0, 0.8)
	if multiplayer.is_server():
		request_bot_rethink()
	snowed_in.emit(slot)


@rpc("authority", "call_local", "reliable")
func _rpc_release(slot: int) -> void:
	snowed[slot] = false
	_invuln_until[slot] = _sim + release_invuln
	var p := _player(slot)
	if p and _running:
		p.frozen = false
	var shell: Node3D = _shells.get(slot)
	if shell:
		shell.visible = false
	if p:
		Fx.play(&"dust_puff", p.global_position + Vector3.UP * 0.4, BALL_COLOR)
		Fx.play(&"respawn_sparkle", p.global_position)
		Sfx.play(&"respawn", p.global_position, -4.0)
	released.emit(slot)


@rpc("authority", "call_local", "reliable")
func _rpc_pile() -> void:
	pile_active = true
	_pile.visible = true
	_pile.scale = Vector3(1.0, 0.1, 1.0)
	var tw := _pile.create_tween()
	tw.tween_property(_pile, "scale", Vector3.ONE, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	Fx.play(&"dust_puff", SnowYard.PILE_AT + Vector3.UP * 0.3, BALL_COLOR)
	Fx.play(&"respawn_sparkle", SnowYard.PILE_AT)
	Sfx.play(&"coin_big", SnowYard.PILE_AT, -6.0, 0.8)
	RoundUI.push_banner("Snowball pile in the middle!", 1.8)
	if multiplayer.is_server():
		request_bot_rethink()
	pile_changed.emit(true, -1)


@rpc("authority", "call_local", "reliable")
func _rpc_pile_taken(slot: int, new_ammo: int) -> void:
	pile_active = false
	_pile.visible = false
	ammo[slot] = new_ammo
	ready_at[slot] = _sim
	_pending_until.erase(slot)
	Fx.play(&"dust_puff", SnowYard.PILE_AT + Vector3.UP * 0.5, BALL_COLOR)
	Sfx.play(&"coin_big", SnowYard.PILE_AT)
	var p := _player(slot)
	RoundUI.push_banner("%s grabbed the pile!" % (p.display_name if p else "Someone"), 1.5)
	if multiplayer.is_server():
		request_bot_rethink()
	pile_changed.emit(false, slot)


@rpc("authority", "call_local", "reliable")
func _rpc_end(winners: Array) -> void:
	_running = false
	_ended = true
	for s: Variant in winners:
		var p := _player(int(s))
		if p == null or not p.alive or is_snowed(p.slot):
			continue
		Fx.play(&"confetti", p.global_position + Vector3.UP * 1.2)
		var visuals := p.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"cheer", true)


# --- Bots ------------------------------------------------------------------------------------------

## The bot mind of `p` on this peer (bots, and `ai_slots`: humans a test or dev check drives with
## a BotBrain), created on first use; null otherwise.
func _ai_of(p: Player) -> SnowBot:
	if not ai_enabled or p == null or p.is_extra or not (p.is_bot or ai_slots.has(p.slot)):
		return null
	var bot: SnowBot = _bots.get(p.slot)
	if bot == null:
		var base := ai_seed if ai_seed >= 0 else _ai_base_seed
		bot = SnowBot.new(self, p, base * 131 + p.slot * 7919 + 17)
		_bots[p.slot] = bot
	return bot


## BotBrain hook: scoop or throw now (SnowBot decides; the brain adds its reaction and aim).
func bot_wants_action(player: Player) -> bool:
	var bot := _ai_of(player)
	return bot != null and _running and bot.wants_action()


## BotBrain hook: the point to face before the throw (ZERO for a scoop).
func bot_aim(player: Player) -> Vector3:
	var bot := _ai_of(player)
	return bot.aim() if bot else Vector3.ZERO


## BotBrain hook: no faster than the throw cooldown.
func bot_action_cooldown() -> float:
	return throw_cooldown


func get_bot_goal(player: Player) -> Vector3:
	var bot := _ai_of(player)
	if bot:
		return bot.goal()
	return super.get_bot_goal(player)


## Inside the yard and clear of cover (bots walk around it).
func is_safe(pos: Vector3) -> bool:
	return SnowYard.walkable(pos, 0.5)


# --- Visuals (every peer) ------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_anim += delta
	if _running:
		var frac := Engine.get_physics_interpolation_fraction()
		_sim_vis = _sim + frac / float(Engine.physics_ticks_per_second)
	for id in _active:
		var b: Ball = _balls[id]
		if b.nodes.is_empty():
			continue
		var s := clampf(_sim_vis - b.t0, 0.0, b.t_end)
		for k in b.nodes.size():
			var mi := b.nodes[k]
			var sk := s - TRAIL_GAP * k
			mi.visible = sk >= 0.0
			if sk >= 0.0:
				mi.position = b.position(sk)
	_update_carry()
	_update_shields()
	if _pile and _pile.visible:
		_pile.rotation.y = _anim * 0.6
		_pile.position.y = 0.04 * absf(sin(_anim * 3.0))


func _update_carry() -> void:
	for p in players:
		if not is_instance_valid(p):
			continue
		var slot := p.slot
		var n := mini(ammo_of(slot), 3)
		var c: Node3D = _carry.get(slot)
		if n <= 0 or not p.alive or is_snowed(slot):
			if c:
				c.visible = false
			continue
		if c == null:
			c = _make_carry(slot)
		c.visible = true
		var grow := 1.0
		if _sim_vis < ready_at.get(slot, 0.0) and scoop_time > 0.0:
			grow = clampf(1.0 - (ready_at[slot] - _sim_vis) / scoop_time, 0.15, 1.0)
		c.global_position = p.global_position + Vector3(0.0, CARRY_Y + 0.04 * sin(_anim * 5.0 + slot), 0.0)
		c.rotation.y = atan2(p.facing.x, p.facing.z)
		for k in c.get_child_count():
			var mi := c.get_child(k) as Node3D
			mi.visible = k < n
			mi.scale = Vector3.ONE * grow


func _update_shields() -> void:
	for p in players:
		if not is_instance_valid(p):
			continue
		var on := p.alive and is_invulnerable(p.slot)
		var sh: MeshInstance3D = _shields.get(p.slot)
		if not on:
			if sh:
				sh.visible = false
			continue
		if sh == null:
			sh = _make_shield(p.slot)
		sh.visible = int(_anim * 12.0) % 3 != 0
		sh.global_position = p.global_position + Vector3.UP * 0.5


func _take_nodes(b: Ball) -> void:
	var nodes: Array[MeshInstance3D]
	if _ball_pool.is_empty():
		nodes = []
		for k in TRAIL + 1:
			var mi := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			var r := BALL_MESH_R if k == 0 else BALL_MESH_R * pow(0.8, k)
			sphere.radius = r
			sphere.height = r * 2.0
			sphere.radial_segments = 16 if k == 0 else 8
			sphere.rings = 8 if k == 0 else 4
			mi.mesh = sphere
			mi.material_override = _ball_mat if k == 0 else _trail_mats[k - 1]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if k == 0 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_balls_root.add_child(mi)
			nodes.append(mi)
		Look.prepare_outline(nodes[0])
	else:
		nodes = _ball_pool.pop_back()
	for k in nodes.size():
		nodes[k].visible = false
		nodes[k].position = b.origin
	b.nodes = nodes


func _release_nodes(b: Ball) -> void:
	if b.nodes.is_empty():
		return
	for mi in b.nodes:
		mi.visible = false
	_ball_pool.append(b.nodes)
	b.nodes = []


func _make_carry(slot: int) -> Node3D:
	var root := Node3D.new()
	root.name = "Carry%d" % slot
	var offsets: Array[Vector3] = [Vector3.ZERO, Vector3(-0.2, -0.08, 0.05), Vector3(0.2, -0.08, 0.05)]
	for k in 3:
		var mi := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = BALL_MESH_R * (1.0 if k == 0 else 0.8)
		sphere.height = sphere.radius * 2.0
		sphere.radial_segments = 12
		sphere.rings = 6
		mi.mesh = sphere
		mi.material_override = _ball_mat
		mi.position = offsets[k]
		root.add_child(mi)
		Look.prepare_outline(mi)
	$Carry.add_child(root)
	_carry[slot] = root
	return root


func _make_shield(slot: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Shield%d" % slot
	var sphere := SphereMesh.new()
	sphere.radius = 0.68
	sphere.height = 1.3
	sphere.radial_segments = 16
	sphere.rings = 8
	mi.mesh = sphere
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.6, 0.85, 1.0, 0.22)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx_root.add_child(mi)
	_shields[slot] = mi
	return mi


func _shell_for(slot: int) -> Node3D:
	var shell: Node3D = _shells.get(slot)
	if shell == null:
		shell = SHELL_SCENE.instantiate() as Node3D
		shell.name = "Shell%d" % slot
		$Shells.add_child(shell)
		Look.apply_toon(shell)
		_shells[slot] = shell
	return shell


func _build_snowfall() -> void:
	_snow = _make_snow(260, 7.0, Vector3(0.35, -1.1, 0.1), 0.06)
	_snow.name = "Snowfall"
	_storm = _make_snow(560, 2.6, Vector3(3.2, -3.4, 0.6), 0.085)
	_storm.name = "Blizzard"
	_storm.emitting = false


func _make_snow(amount: int, lifetime: float, gravity: Vector3, size: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.preprocess = lifetime
	p.position = Vector3(-2.0, 8.0, 0.0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(14.0, 0.5, 10.0)
	p.direction = Vector3(0.0, -1.0, 0.0)
	p.spread = 15.0
	p.initial_velocity_min = 0.2
	p.initial_velocity_max = 0.6
	p.gravity = gravity
	p.damping_min = 0.4
	p.damping_max = 0.8
	p.local_coords = false
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad.material = m
	p.mesh = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx_root.add_child(p)
	return p


# --- Helpers -------------------------------------------------------------------------------------------

func _clock_scale() -> float:
	return time_scale * Session.time_scale


func _player(slot: int) -> Player:
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _live(p: Player) -> bool:
	return is_instance_valid(p) and p.is_inside_tree() and p.alive
