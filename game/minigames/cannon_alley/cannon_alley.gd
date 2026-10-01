class_name CannonAlley
extends Minigame
## Cannon Alley: a cobbled courtyard lane between two rows of cannons. Cannonballs roll
## across in patterns that get faster and thicker (singles, pairs, alternating fire, volleys,
## sweeping rows, crossfire, slow walls). Dodge sideways, jump the slow ones, shove others
## into the path. First hit: big knockback, 1.2 s stun and a plaster on your head; second hit:
## out (reason `cannon`). Last blob standing wins; 60 s cap.
##
## Networking (docs/contract.md "Networking rules for minigames"):
## - The schedule is `CannonSchedule.build(seed)`, the host sends only the seed and the start
##   time (`_rpc_begin`); every peer runs the round clock from there and computes every ball
##   position with `CannonSchedule.ball_position`, so balls are never synced.
## - Each peer tests the balls against its own authority players only and applies the hit
##   there (knockback + stun through `apply_impulse`, so the usual got_hit/stunned events,
##   stars and bonk play everywhere). It then reports the hit to the host (`_rpc_report_hit`).
## - The host decides: it checks the sender owns the player and that the reported position was
##   plausibly on that ball's path around now (`CannonSchedule.plausible_hit`), counts the
##   hit, tells every peer (`_rpc_hit`: plaster, lives counter) and knocks out on the second.
##
## Bots: `get_bot_goal` = a lane point off every ball path the bots can see (fuse burning or
## ball flying) for the next GOAL_HORIZON s, preferring mid-lane and elbow room; `is_safe` =
## inside the lane and not where a fast ball will be within SAFE_HORIZON s. A slow ball only
## makes its own footprint unsafe, so a bot whose goal lies beyond it runs at it and the bot
## brain's gap jump hops it (well-timed for sharp bots, out of reach for clumsy ones).

## Every peer: the round clock started (host-sent seed and start time).
signal round_began(seed_value: int, start_time: float)
## Every peer: a cannon fired shot `id`.
signal shot_fired(id: int)
## Every peer, on the peer that owns the player: a ball hit it (before the host confirms).
signal local_hit(slot: int, shot_id: int)
## Every peer: the host counted a hit on `slot` (its `count`-th).
signal hit_confirmed(slot: int, count: int)

const CANNON_SCENE: PackedScene = preload("res://assets/models/props/cannon_cannon.glb")
const BALL_SCENE: PackedScene = preload("res://assets/models/props/cannon_ball.glb")
const WALL_SCENE: PackedScene = preload("res://assets/models/props/cannon_wall.glb")
const PARAPET_SCENE: PackedScene = preload("res://assets/models/props/cannon_parapet.glb")
const BARREL_SCENE: PackedScene = preload("res://assets/models/props/barrel.glb")
const CRATE_SCENE: PackedScene = preload("res://assets/models/props/crate.glb")

## Bots: seconds of visible ball paths a goal keeps clear of.
const GOAL_HORIZON := 1.5
## Bots: seconds ahead a fast ball makes its path unsafe.
const SAFE_HORIZON := 0.9
## Bots: a slow ball makes only its own footprint (plus this many seconds) unsafe.
const SLOW_LOOKAHEAD := 0.06
## Half width (x) of a ball path that bots keep off, and its reach along z.
const STRIP_HALF := CannonSchedule.HIT_RADIUS + 0.25
const SLOW_REACH := CannonSchedule.HIT_RADIUS + 0.1
## Bots stay this far inside the lane walls.
const SAFE_X := CannonSchedule.LANE_HALF_X - 0.7
const SAFE_Z := CannonSchedule.LANE_HALF_Z - 0.6
## Seconds (host) between batched bot rethinks.
const RETHINK_INTERVAL := 0.2
## Host: a second confirmed hit on the same player needs this much round time in between.
const HOST_HIT_GRACE := 0.5
const FALL_Y := -3.0
## Warning lanes: blue for slow (jumpable) balls, red for fast ones; a flying ball's lane shows
## this many seconds of travel ahead of it.
const SLOW_COLOR := Color(0.22, 0.5, 1.0)
const FAST_COLOR := Color(0.95, 0.2, 0.12)
const STRIP_AHEAD := 1.0
## Round-clock times of the banners (every peer shows them from its own clock).
const BANNERS: Array = [[20.0, "Faster!"], [34.0, "Barrage!"]]

@export_group("Hits")
## Confirmed hits that knock a player out.
@export var hits_to_knock_out: int = 2
## Knockback of a ball hit (horizontal, m/s) and its lift.
@export var knockback: float = 11.0
@export var knockback_lift: float = 6.0
## Stun of a ball hit, seconds.
@export var hit_stun: float = 1.2
## Seconds after a hit during which balls pass through that player (on its own peer).
@export var hit_grace: float = 1.0

@export_group("Test")
## Test-only: multiplies the round clock (balls, schedule, time limit).
@export var time_scale: float = 1.0
## Seed for the schedule; -1 = random (host).
@export var schedule_seed: int = -1
## Round clock at the start (host). Dev: `--cannon-start=SEC` on the command line.
@export var start_time: float = 0.0
## When false the host starts with an empty schedule (tests fire shots with `inject_shot`).
@export var auto_schedule: bool = true

## slot -> hits the host confirmed, identical on every peer.
var hits: Dictionary[int, int] = {}
## The shots of this round, sorted by fire time (every peer, same content).
var shots: Array[CannonSchedule.Shot] = []
## Host: hit reports from other peers it accepted / refused (the network check reads these).
var accepted_remote_reports: int = 0
var rejected_reports: int = 0

var _seed: int = 0
var _t: float = 0.0
var _t_vis: float = 0.0
## Dev only (--cannon-freeze=SEC): the round clock stops here, for screenshots.
var _freeze_at: float = INF
var _running: bool = false
var _shot_by_id: Dictionary[int, CannonSchedule.Shot] = {}
var _first: int = 0
var _next_inject_id: int = 100000
## slot -> seconds of ball grace left (this peer's own players).
var _grace: Dictionary[int, float] = {}
## (slot, shot id) pairs this peer already hit.
var _hit_seen: Dictionary[Vector2i, bool] = {}
var _host_seen: Dictionary[Vector2i, bool] = {}
## slot -> round time of the host's last confirmed hit.
var _host_last_hit: Dictionary[int, float] = {}
var _rethink_pending: bool = false
var _rethink_cd: float = 0.0
var _banner_next: int = 0
var _shake_frame: int = -1
var _anim: float = 0.0
var _seg_cache_t: float = -1.0
var _safe_x := PackedFloat32Array()
var _safe_lo := PackedFloat32Array()
var _safe_hi := PackedFloat32Array()

var _barrels: Array[Node3D] = []
var _barrel_rest: Array[Vector3] = []
var _fuses: Array[Node3D] = []
var _flashes: Array[Node3D] = []
var _fuse_at: Array[float] = []
var _last_fire: Array[float] = []
var _balls: Dictionary[int, Node3D] = {}
var _ball_pool: Array[Node3D] = []
var _strips: Dictionary[int, MeshInstance3D] = {}
var _strip_pool: Array[MeshInstance3D] = []
var _marks: Dictionary[int, Node3D] = {}
var _strip_texture: ImageTexture

@onready var _camera: ArenaCamera = $ArenaCamera as ArenaCamera
@onready var _balls_root: Node3D = $Balls
@onready var _strips_root: Node3D = $Strips


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cannon-freeze="):
			_freeze_at = arg.trim_prefix("--cannon-freeze=").to_float()
	Look.apply_toon($Floor/Model, false)
	_build_colliders()
	_build_decor()
	_build_cannons()
	var img := Image.create(16, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		var along := pow(1.0 - y / 63.0, 0.7)
		for x in 16:
			var u := x / 15.0
			var across := smoothstep(0.0, 0.3, u) * smoothstep(1.0, 0.7, u)
			img.set_pixel(x, y, Color(1, 1, 1, across * along))
	_strip_texture = ImageTexture.create_from_image(img)


# --- Minigame flow --------------------------------------------------------------------------

func _setup(setup_players: Array[Player]) -> void:
	hits.clear()
	for p in setup_players:
		hits[p.slot] = 0
		_marks[p.slot] = _make_mark()


func _start() -> void:
	if not multiplayer.is_server():
		return
	var t0 := start_time
	var seed_value := schedule_seed if schedule_seed >= 0 else randi() % 1000000
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cannon-start="):
			t0 = arg.trim_prefix("--cannon-start=").to_float()
		elif arg.begins_with("--cannon-seed="):
			seed_value = arg.trim_prefix("--cannon-seed=").to_int()
	begin(seed_value, t0, auto_schedule)
	if not finished.is_connected(_on_finished):
		finished.connect(_on_finished)


## Host: (re)starts the round clock on every peer at `t0` with the schedule of `seed_value`
## (or none when `scheduled` is false).
func begin(seed_value: int, t0: float = 0.0, scheduled: bool = true) -> void:
	_rpc_begin.rpc(seed_value, t0, scheduled)


## Host: adds one shot (cannon `cannon` fires at round time `at`) on every peer. Returns its id.
func inject_shot(cannon: int, at: float, speed: float) -> int:
	var id := _next_inject_id
	_next_inject_id += 1
	_rpc_shot.rpc(id, at, cannon, speed)
	return id


func _host_tick(delta: float) -> void:
	if not _running or is_finished():
		return
	for p in players:
		if _live(p) and p.global_position.y < FALL_Y:
			var points := get_spawn_points()
			p.respawn_at(points[p.slot % points.size()])
	_rethink_cd -= delta
	if _rethink_pending and _rethink_cd <= 0.0:
		_rethink_pending = false
		_rethink_cd = RETHINK_INTERVAL
		request_bot_rethink()
	# Time limit without a Session driving the round (tests, sandbox). Under Session its
	# backstop finishes a moment later and ranks the survivors equally.
	if time_limit > 0.0 and _t >= time_limit and not _session_drives():
		finish(time_up_ranking())


func _physics_process(delta: float) -> void:
	if not _running:
		return
	_t = minf(_t + delta * _clock_scale(), _freeze_at)
	_advance_shots()
	while _banner_next < BANNERS.size() and _t >= float(BANNERS[_banner_next][0]):
		RoundUI.push_banner(String(BANNERS[_banner_next][1]), 1.5)
		_banner_next += 1
	_local_hits(delta)


## Seconds on the round clock (every peer).
func round_time() -> float:
	return _t


## The seed of this round's schedule (every peer).
func schedule_seed_value() -> int:
	return _seed


## Hits `slot` can still take (every peer).
func lives_left(slot: int) -> int:
	return maxi(hits_to_knock_out - hits.get(slot, 0), 0)


## Host: the ranking at the time limit: survivors by fewest hits (then the one hit latest),
## then the knocked-out, last out first.
func time_up_ranking() -> Array[int]:
	var alive: Array[int] = []
	for p in players:
		if _live(p):
			alive.append(p.slot)
	alive.sort_custom(func(a: int, b: int) -> bool:
		var ha: int = hits.get(a, 0)
		var hb: int = hits.get(b, 0)
		if ha != hb:
			return ha < hb
		var la: float = _host_last_hit.get(a, -1.0)
		var lb: float = _host_last_hit.get(b, -1.0)
		if la != lb:
			return la > lb
		return a < b)
	var ranking: Array[int] = alive
	for i in range(knocked_out.size() - 1, -1, -1):
		if not ranking.has(knocked_out[i]):
			ranking.append(knocked_out[i])
	return ranking


# --- Shots (every peer) ------------------------------------------------------------------------

func _advance_shots() -> void:
	var i := _first
	while i < shots.size():
		var s := shots[i]
		if s.t - CannonSchedule.TELEGRAPH > _t:
			break
		if s.phase == 0:
			s.phase = 1
			_on_telegraph(s)
		if s.phase == 1 and _t >= s.t:
			s.phase = 2
			_on_fire(s)
		if s.phase == 2 and _t >= s.t + CannonSchedule.flight_time(s):
			s.phase = 3
			_on_land(s)
		i += 1
	while _first < shots.size() and shots[_first].phase == 3:
		_first += 1


func _on_telegraph(s: CannonSchedule.Shot) -> void:
	_fuse_at[s.cannon] = s.t
	Sfx.play(&"bomb_tick", _muzzle(s.cannon), -6.0, 1.15)
	_rethink_pending = true


func _on_fire(s: CannonSchedule.Shot) -> void:
	_last_fire[s.cannon] = s.t
	var at := _muzzle(s.cannon)
	Sfx.play(&"explosion", at, -11.0, 1.35)
	Fx.play(&"dust_puff", at + Vector3(0.0, -0.3, CannonSchedule.cannon_dir(s.cannon) * 0.3))
	if _camera and _shake_frame != Engine.get_physics_frames():
		_shake_frame = Engine.get_physics_frames()
		_camera.add_shake(0.07)
	_take_ball(s)
	shot_fired.emit(s.id)


func _on_land(s: CannonSchedule.Shot) -> void:
	var end := CannonSchedule.ball_position(s, s.t + CannonSchedule.flight_time(s))
	Fx.play(&"dust_puff", end + Vector3(0.0, -0.2, 0.0))
	Sfx.play(&"land_soft", end, -8.0, 0.6)
	_release_ball(s.id)
	_release_strip(s.id)


func _local_hits(delta: float) -> void:
	for slot: int in _grace:
		_grace[slot] -= delta
	for i in range(_first, shots.size()):
		var s := shots[i]
		if s.t > _t:
			break
		if s.phase != 2:
			continue
		var ball := CannonSchedule.ball_position(s, _t)
		for p in players:
			if not _live(p) or not p.is_authority() or p.frozen or _grace.get(p.slot, 0.0) > 0.0:
				continue
			var key := Vector2i(p.slot, s.id)
			if _hit_seen.has(key) or not CannonSchedule.touches(ball, p.global_position):
				continue
			_hit_seen[key] = true
			_local_hit(p, s, ball)


## This peer's own player `p` was hit by shot `s`: knock it now, tell the host.
func _local_hit(p: Player, s: CannonSchedule.Shot, ball: Vector3) -> void:
	_grace[p.slot] = hit_grace
	var side := p.global_position.x - ball.x
	if absf(side) < 0.05:
		side = 1.0 if p.slot % 2 == 0 else -1.0
	var dir := Vector3(signf(side) * 0.6, 0.0, CannonSchedule.cannon_dir(s.cannon)).normalized()
	_push(p, dir * knockback + Vector3.UP * knockback_lift)
	var feet := p.global_position
	local_hit.emit(p.slot, s.id)
	if multiplayer.is_server():
		_host_hit(p.slot, s.id, feet, multiplayer.get_unique_id())
	else:
		_rpc_report_hit.rpc_id(1, p.slot, s.id, feet)


## Applies a ball hit's impulse with the ball's own stun (hit_stun): the status tuning is
## swapped for this one impulse only, so shoves keep their normal stun.
func _push(p: Player, impulse: Vector3) -> void:
	var status := p.get_component(&"status") as StatusComponent
	if status == null:
		p.apply_impulse(impulse)
		return
	var saved_max := status.stun_max
	var saved_full := status.stun_full_impulse
	var saved_chain := status.stun_chain_max
	status.stun_max = hit_stun
	status.stun_full_impulse = impulse.length()
	status.stun_chain_max = maxf(saved_chain, hit_stun * 2.5)
	p.apply_impulse(impulse)
	status.stun_max = saved_max
	status.stun_full_impulse = saved_full
	status.stun_chain_max = saved_chain


# --- Host: hits ----------------------------------------------------------------------------------

## Host: a hit on `slot` by shot `shot_id`, reported by peer `sender` with the player's feet.
func _host_hit(slot: int, shot_id: int, feet: Vector3, sender: int) -> void:
	if is_finished() or not _running:
		return
	var p := _player(slot)
	if p == null or not p.alive:
		return
	var s: CannonSchedule.Shot = _shot_by_id.get(shot_id)
	var ok := s != null and sender == p.get_multiplayer_authority() \
			and CannonSchedule.plausible_hit(s, feet, _t) and feet.distance_to(p.global_position) < 3.5
	if not ok:
		rejected_reports += 1
		print_verbose("cannon_alley: refused hit report slot %d shot %d from peer %d" % [slot, shot_id, sender])
		return
	var key := Vector2i(slot, shot_id)
	if _host_seen.has(key) or _t - _host_last_hit.get(slot, -100.0) < HOST_HIT_GRACE:
		return
	_host_seen[key] = true
	_host_last_hit[slot] = _t
	if sender != multiplayer.get_unique_id():
		accepted_remote_reports += 1
	var n: int = hits.get(slot, 0) + 1
	_rpc_hit.rpc(slot, n)
	if n >= hits_to_knock_out:
		knock_out(p, &"cannon")


func _on_finished(ranking: Array[int]) -> void:
	var winners: Array = []
	for p in players:
		if _live(p) and ranking.has(p.slot):
			winners.append(p.slot)
	if not winners.is_empty():
		_rpc_celebrate.rpc(winners)


# --- RPCs ------------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_begin(seed_value: int, t0: float, scheduled: bool) -> void:
	_seed = seed_value
	for s in shots:
		_release_ball(s.id)
		_release_strip(s.id)
	shots.clear()
	if scheduled:
		shots = CannonSchedule.build(seed_value)
	_seg_cache_t = -1.0
	_shot_by_id.clear()
	for s in shots:
		_shot_by_id[s.id] = s
		var flight := CannonSchedule.flight_time(s)
		if s.t + flight <= t0:
			s.phase = 3
		elif s.t <= t0:
			s.phase = 2
			_take_ball(s)
		elif s.t - CannonSchedule.TELEGRAPH <= t0:
			s.phase = 1
			_fuse_at[s.cannon] = s.t
	_first = 0
	while _first < shots.size() and shots[_first].phase == 3:
		_first += 1
	_t = t0
	_t_vis = t0
	_banner_next = 0
	while _banner_next < BANNERS.size() and t0 >= float(BANNERS[_banner_next][0]):
		_banner_next += 1
	_running = true
	for slot: int in hits:
		RoundUI.push_counter(slot, lives_left(slot))
	round_began.emit(seed_value, t0)


@rpc("authority", "call_local", "reliable")
func _rpc_shot(id: int, at: float, cannon: int, speed: float) -> void:
	var s := CannonSchedule.Shot.new(id, at, cannon, clampf(speed, CannonSchedule.MIN_SPEED, CannonSchedule.MAX_SPEED), -1)
	var idx := shots.bsearch_custom(s, func(a: CannonSchedule.Shot, b: CannonSchedule.Shot) -> bool: return a.t < b.t, false)
	shots.insert(idx, s)
	_shot_by_id[id] = s
	_first = mini(_first, idx)
	_seg_cache_t = -1.0


@rpc("any_peer", "call_remote", "reliable")
func _rpc_report_hit(slot: int, shot_id: int, feet: Vector3) -> void:
	if multiplayer.is_server():
		_host_hit(slot, shot_id, feet, multiplayer.get_remote_sender_id())


@rpc("authority", "call_local", "reliable")
func _rpc_hit(slot: int, count: int) -> void:
	hits[slot] = count
	var p := _player(slot)
	if p:
		Sfx.play(&"platform_crack", p.global_position + Vector3.UP * 0.5, -3.0, 1.2)
		if _camera:
			_camera.add_shake(0.25)
	RoundUI.push_counter(slot, lives_left(slot))
	hit_confirmed.emit(slot, count)


@rpc("authority", "call_local", "reliable")
func _rpc_celebrate(slots: Array) -> void:
	for s: Variant in slots:
		var p := _player(int(s))
		if p == null or not p.alive:
			continue
		Fx.play(&"confetti", p.global_position + Vector3.UP * 1.2)
		var visuals := p.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"cheer", true)


# --- Bots ------------------------------------------------------------------------------------------

## Ball paths the bots can see (fuse burning or ball flying) that sweep lane ground within the
## next `horizon` round-clock seconds, as {id, x, z0, z1, t0, t1, speed, slow}: the ball is at
## z0 at t0 and at z1 at t1.
func imminent_paths(horizon: float = GOAL_HORIZON) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _running:
		return out
	var t_end := _t + horizon
	for i in range(_first, shots.size()):
		var s := shots[i]
		if s.t - CannonSchedule.TELEGRAPH > _t:
			break
		if s.phase == 3:
			continue
		var t0 := maxf(_t, s.t)
		var t1 := minf(t_end, s.t + CannonSchedule.flight_time(s))
		if t1 < t0:
			continue
		out.append({
			"id": s.id, "x": CannonSchedule.cannon_x(s.cannon), "z0": CannonSchedule.ball_z(s, t0),
			"z1": CannonSchedule.ball_z(s, t1), "t0": t0, "t1": t1, "speed": s.speed,
			"slow": s.speed <= CannonSchedule.SLOW_SPEED,
		})
	return out


## True when `pos` is on one of `paths` (within `half_x` sideways and `reach` beyond its ends).
static func on_path(pos: Vector3, path: Dictionary, half_x: float = STRIP_HALF, reach: float = STRIP_HALF) -> bool:
	if absf(pos.x - float(path["x"])) >= half_x:
		return false
	var z0: float = path["z0"]
	var z1: float = path["z1"]
	return pos.z > minf(z0, z1) - reach and pos.z < maxf(z0, z1) + reach


## A lane point off every visible ball path of the next GOAL_HORIZON s, near the bot, mid-lane
## rather than by the muzzles, away from other blobs, with a little personal taste.
func get_bot_goal(player: Player) -> Vector3:
	if player == null:
		return Vector3.ZERO
	var pos := player.global_position
	var strips := _strips_for(imminent_paths(GOAL_HORIZON * _clock_scale()), false)
	var xs: PackedFloat32Array = strips[0]
	var z_lo: PackedFloat32Array = strips[1]
	var z_hi: PackedFloat32Array = strips[2]
	var best := Vector3(clampf(pos.x, -SAFE_X, SAFE_X), 0.0, 0.0)
	var best_score := INF
	var others: Array[Vector2] = []
	for o in players:
		if o != player and _live(o):
			others.append(Vector2(o.global_position.x, o.global_position.z))
	var taste_seed := player.slot * 7919 + int(_t * 0.5) * 104729
	for ix in range(-13, 14):
		var cx := ix * 0.625
		for iz in range(-3, 4):
			var cz := iz * 1.1
			var score := Vector2(cx - pos.x, cz - pos.z).length() + 0.35 * absf(cz)
			for k in xs.size():
				if absf(cx - xs[k]) < STRIP_HALF and cz > z_lo[k] and cz < z_hi[k]:
					score += 12.0
			var c2 := Vector2(cx, cz)
			for o in others:
				if c2.distance_squared_to(o) < 1.69:
					score += 1.5
			score += 1.2 * _hash01(taste_seed + ix * 31 + iz * 17)
			if score < best_score:
				best_score = score
				best = Vector3(cx, 0.0, cz)
	return best


## Inside the lane, and not where a fast ball will be within SAFE_HORIZON s nor inside a slow
## ball's footprint.
func is_safe(pos: Vector3) -> bool:
	if absf(pos.x) > SAFE_X or absf(pos.z) > SAFE_Z:
		return false
	if not _running:
		return true
	if _seg_cache_t != _t:
		_refresh_safe_strips()
	for k in _safe_x.size():
		if absf(pos.x - _safe_x[k]) < STRIP_HALF and pos.z > _safe_lo[k] and pos.z < _safe_hi[k]:
			return false
	return true


func _refresh_safe_strips() -> void:
	_seg_cache_t = _t
	var strips := _strips_for(imminent_paths(SAFE_HORIZON * _clock_scale()), true)
	_safe_x = strips[0]
	_safe_lo = strips[1]
	_safe_hi = strips[2]


## [x, z_min, z_max] arrays of the ground `paths` cover (reach included). With
## `slow_footprint`, a slow ball covers only itself and a hair ahead, so bots can hop it.
func _strips_for(paths: Array[Dictionary], slow_footprint: bool) -> Array[PackedFloat32Array]:
	var xs := PackedFloat32Array()
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	for path in paths:
		var z0: float = path["z0"]
		var z1: float = path["z1"]
		var reach := STRIP_HALF
		if slow_footprint and bool(path["slow"]):
			var s: CannonSchedule.Shot = _shot_by_id[int(path["id"])]
			if not CannonSchedule.is_flying(s, _t):
				continue
			z1 = CannonSchedule.ball_z(s, minf(_t + SLOW_LOOKAHEAD, s.t + CannonSchedule.flight_time(s)))
			reach = SLOW_REACH
		xs.append(float(path["x"]))
		lo.append(minf(z0, z1) - reach)
		hi.append(maxf(z0, z1) + reach)
	return [xs, lo, hi]

# --- Visuals (every peer) -----------------------------------------------------------------------------

func _process(delta: float) -> void:
	_anim += delta
	if _running:
		var frac := Engine.get_physics_interpolation_fraction()
		_t_vis = minf(_t + frac / float(Engine.physics_ticks_per_second) * _clock_scale(), _freeze_at)
	for id: int in _balls:
		var s: CannonSchedule.Shot = _shot_by_id.get(id)
		if s == null:
			continue
		var ball := _balls[id]
		var tt := minf(_t_vis, s.t + CannonSchedule.flight_time(s))
		ball.position = CannonSchedule.ball_position(s, tt)
		ball.rotation = Vector3(CannonSchedule.ball_roll(s, tt), 0.0, 0.0)
	_update_strips()
	_update_cannons()
	_update_marks()


func _update_strips() -> void:
	if not _running:
		return
	for i in range(_first, shots.size()):
		var s := shots[i]
		if s.t - CannonSchedule.TELEGRAPH > _t_vis:
			break
		if s.phase == 3 or s.phase == 0:
			continue
		var strip: MeshInstance3D = _strips.get(s.id)
		if strip == null:
			strip = _take_strip(s)
		# A warning lane that starts at the muzzle (fuse burning) or at the ball (flying) and
		# fades out ahead of it: the ground the ball is about to cover.
		var d := CannonSchedule.cannon_dir(s.cannon)
		var z_far := d * (CannonSchedule.LANE_HALF_Z - 0.1)
		var z_start := -d * CannonSchedule.LANE_HALF_Z
		var reach := 2.0 * CannonSchedule.LANE_HALF_Z
		var alpha := 0.0
		if _t_vis < s.t:
			var k := clampf((_t_vis - (s.t - CannonSchedule.TELEGRAPH)) / CannonSchedule.TELEGRAPH, 0.0, 1.0)
			alpha = (0.3 + 0.45 * k) * (0.8 + 0.2 * sin(_anim * 30.0))
		else:
			z_start = CannonSchedule.ball_z(s, _t_vis)
			reach = s.speed * STRIP_AHEAD
			alpha = 0.7
		var length := minf(absf(z_far - z_start), reach)
		if length < 0.05:
			strip.visible = false
			continue
		strip.visible = true
		strip.position = Vector3(CannonSchedule.cannon_x(s.cannon), 0.035, z_start + d * length * 0.5)
		strip.rotation.y = 0.0 if d > 0.0 else PI
		strip.scale = Vector3(1.1, 1.0, length)
		var m := strip.material_override as StandardMaterial3D
		m.albedo_color.a = alpha

func _update_cannons() -> void:
	for c in _barrels.size():
		var fuse_on := _running and _t_vis < _fuse_at[c] and _t_vis >= _fuse_at[c] - CannonSchedule.TELEGRAPH
		_fuses[c].visible = fuse_on
		if fuse_on:
			_fuses[c].scale = Vector3.ONE * (0.8 + 0.45 * absf(sin(_anim * 31.0 + c)))
			_fuses[c].rotation.y = _anim * 9.0
		var tau := _t_vis - _last_fire[c]
		var flash := tau >= 0.0 and tau < 0.1
		_flashes[c].visible = flash
		if flash:
			_flashes[c].scale = Vector3.ONE * lerpf(0.6, 1.25, tau / 0.1)
		var recoil := 0.0
		if tau >= 0.0 and tau < 0.5:
			recoil = -0.3 * (tau / 0.04 if tau < 0.04 else 1.0 - smoothstep(0.04, 0.5, tau))
		_barrels[c].position = _barrel_rest[c] + Vector3(0.0, 0.0, recoil)


func _update_marks() -> void:
	for slot: int in _marks:
		var mark := _marks[slot]
		var p := _player(slot)
		var show: bool = p != null and _live(p) and int(hits.get(slot, 0)) >= 1
		mark.visible = show
		if show:
			mark.global_position = p.global_position + Vector3(0.0, 1.12 + 0.04 * sin(_anim * 3.0 + slot), 0.0)
			mark.rotation.y = 0.35 * sin(_anim * 1.7 + slot)


# --- Pools --------------------------------------------------------------------------------------------

func _take_ball(s: CannonSchedule.Shot) -> void:
	if _balls.has(s.id):
		return
	var ball: Node3D
	if _ball_pool.is_empty():
		ball = BALL_SCENE.instantiate() as Node3D
		Look.apply_toon(ball)
		_balls_root.add_child(ball)
	else:
		ball = _ball_pool.pop_back()
	ball.visible = true
	ball.position = CannonSchedule.ball_position(s, _t)
	_balls[s.id] = ball


func _release_ball(id: int) -> void:
	var ball: Node3D = _balls.get(id)
	if ball:
		_balls.erase(id)
		ball.visible = false
		_ball_pool.append(ball)


func _take_strip(s: CannonSchedule.Shot) -> MeshInstance3D:
	var strip: MeshInstance3D
	if _strip_pool.is_empty():
		strip = MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2.ONE
		strip.mesh = plane
		strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_texture = _strip_texture
		m.render_priority = 1
		strip.material_override = m
		_strips_root.add_child(strip)
	else:
		strip = _strip_pool.pop_back()
	var mat := strip.material_override as StandardMaterial3D
	var c := SLOW_COLOR if s.speed <= CannonSchedule.SLOW_SPEED else FAST_COLOR
	mat.albedo_color = Color(c.r, c.g, c.b, 0.0)
	strip.visible = false
	_strips[s.id] = strip
	return strip


func _release_strip(id: int) -> void:
	var strip: MeshInstance3D = _strips.get(id)
	if strip:
		_strips.erase(id)
		strip.visible = false
		_strip_pool.append(strip)


## The "cracked" mark: a sticking plaster cross floating on the head.
func _make_mark() -> Node3D:
	var root := Node3D.new()
	root.name = "Plaster%d" % _marks.size()
	root.visible = false
	var cream := Look.toon_material(Color(0.97, 0.9, 0.78))
	var pad := Look.toon_material(Color(0.93, 0.55, 0.55))
	for k in 2:
		var arm := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.46, 0.05, 0.14)
		arm.mesh = box
		arm.material_override = cream
		arm.rotation = Vector3(0.0, PI * 0.25 * (1 if k == 0 else -1), 0.0)
		root.add_child(arm)
	var dot := MeshInstance3D.new()
	var dbox := BoxMesh.new()
	dbox.size = Vector3(0.13, 0.07, 0.13)
	dot.mesh = dbox
	dot.material_override = pad
	dot.rotation.y = PI * 0.25
	root.add_child(dot)
	$Marks.add_child(root)
	return root


# --- Build ---------------------------------------------------------------------------------------------

func _build_cannons() -> void:
	var root := $Cannons as Node3D
	for c in CannonSchedule.cannon_count():
		var cannon := CANNON_SCENE.instantiate() as Node3D
		cannon.name = "Cannon%d" % c
		cannon.transform = CannonSchedule.cannon_transform(c)
		root.add_child(cannon)
		Look.apply_toon(cannon)
		var barrel := cannon.get_node(^"Barrel") as Node3D
		_barrels.append(barrel)
		_barrel_rest.append(barrel.position)
		var fuse := barrel.get_node(^"EmitFuse") as Node3D
		var flash := barrel.get_node(^"EmitFlash") as Node3D
		fuse.visible = false
		flash.visible = false
		for n: Node3D in [fuse, flash]:
			for mi in n.find_children("*", "MeshInstance3D", true, false):
				(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fuses.append(fuse)
		_flashes.append(flash)
		_fuse_at.append(-100.0)
		_last_fire.append(-100.0)


func _build_decor() -> void:
	var decor := $Decor as Node3D
	var far_z := -(7.4 + 0.3)
	for k in 4:
		_place(decor, WALL_SCENE, Vector3(-7.2 + 4.8 * k, 0.0, far_z), 0.0)
		_place(decor, PARAPET_SCENE, Vector3(-7.2 + 4.8 * k, 0.0, 7.4 + 0.25), PI)
	for sx: float in [-1.0, 1.0]:
		for k in 3:
			_place(decor, WALL_SCENE, Vector3(sx * (9.6 + 0.3), 0.0, -4.8 + 4.8 * k), -sx * PI * 0.5)
		_place(decor, BARREL_SCENE, Vector3(sx * 9.0, CannonSchedule.DECK_H, -6.9), 0.4 * sx)
		_place(decor, CRATE_SCENE, Vector3(sx * 8.85, CannonSchedule.DECK_H, -6.05), 0.2 * sx)


func _place(parent: Node3D, scene: PackedScene, at: Vector3, yaw: float) -> void:
	var n := scene.instantiate() as Node3D
	n.position = at
	n.rotation.y = yaw
	parent.add_child(n)
	Look.apply_toon(n)


func _build_colliders() -> void:
	var body := StaticBody3D.new()
	body.name = "Colliders"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var hx := CannonSchedule.LANE_HALF_X
	var hz := CannonSchedule.LANE_HALF_Z
	for s: float in [-1.0, 1.0]:
		_add_box(body, Vector3(2.0 * hx + 2.0, 4.0, 1.0), Vector3(0.0, 2.0, s * (hz + 0.5)))
		_add_box(body, Vector3(1.0, 4.0, 2.0 * hz + 2.0), Vector3(s * (hx + 0.5), 2.0, 0.0))


func _add_box(body: StaticBody3D, size: Vector3, at: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var cs := CollisionShape3D.new()
	cs.shape = box
	cs.position = at
	body.add_child(cs)


# --- Helpers -------------------------------------------------------------------------------------------

func _muzzle(cannon: int) -> Vector3:
	var d := CannonSchedule.cannon_dir(cannon)
	return Vector3(CannonSchedule.cannon_x(cannon), CannonSchedule.MUZZLE_Y, -d * CannonSchedule.LANE_HALF_Z)


func _clock_scale() -> float:
	return time_scale * Session.time_scale


func _session_drives() -> bool:
	return Session.current_minigame == self and Session.state == Session.State.PLAYING


func _player(slot: int) -> Player:
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _live(p: Player) -> bool:
	return is_instance_valid(p) and p.is_inside_tree() and p.alive


static func _hash01(n: int) -> float:
	var h := (n * 2654435761) & 0xffffffff
	h = ((h >> 16) ^ h) * 0x45d9f3b & 0xffffffff
	h = ((h >> 16) ^ h) & 0xffffffff
	return float(h % 10007) / 10007.0
