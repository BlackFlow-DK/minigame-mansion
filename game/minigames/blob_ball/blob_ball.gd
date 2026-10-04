class_name BlobBall
extends Minigame
## Blob Ball. Two teams, one huge light beach ball, two goals. Walk into the ball to nudge
## it, shove it to launch it. First to 3 goals wins, else most goals at 90 s; a draw then goes
## to a 20 s golden goal, and if nobody scores it is a tie (everyone one tied group).
##
## Teams: `assign_teams(2)` in `_setup` (host). Team 0 (ORANGE) defends the left goal (x < 0)
## and attacks +X; team 1 (BLUE) the other way. With an odd player count the smaller team's
## shoves launch the ball `small_team_kick_bonus` times harder.
## The pitch scales with the player count (2-3: 16 x 10 m, 4-5: 19 x 11.5 m, 6-8: 22 x 13 m).
##
## Ball netcode (BlobBallSim is a pure deterministic integrator, run by every peer):
## - The HOST owns the ball. It steps it every physics frame, resolves contacts with the blobs
##   it simulates (its own and the bots), and broadcasts (pos, vel, spin, round clock) ~20 Hz
##   unreliable (`_rpc_state`) plus every kick reliably (`_rpc_kicked`).
## - Every CLIENT steps the same integrator between updates, with contacts against every blob
##   it sees (so the ball never sinks into anyone on its screen). On an update it adopts the
##   host state for physics and keeps the difference as a visual offset that decays in ~0.1 s
##   (no rubber-banding; goals and kick-offs snap).
## - A client is authoritative for touches and shoves of ITS OWN blob: it applies them to its
##   prediction at once and reports them (`_rpc_touch`: blob position and velocity;
##   `_rpc_kick_request`: blob position and facing at shove time). The host checks that the
##   reported position is near its copy of that blob and the ball is within reach (with a
##   tolerance for LAN latency), then applies the same response and broadcasts the kick. For a
##   moment after its own touch or kick a client ignores unreliable updates (they predate it).
## - A fast ball bumps blobs: each peer applies that to its own authority players only, via
##   `apply_impulse` (as Coin Scramble's bumpers do).
## Goals, scores, time, golden goal and the end are decided on the host and announced with
## reliable call_local RPCs. Dev args: `--ball-goal-at=<s>` makes ORANGE score at that round
## time (screenshots).

## Every peer: a goal. `scorer_slot` -1 = nobody credited (own goal or no recent touch).
signal goal_scored(team: int, score0: int, score1: int, scorer_slot: int)
## Every peer: the host accepted a shove on the ball by `slot`.
signal ball_kicked(slot: int)
## Every peer: the ball went back to the centre spot.
signal kickoff_reset
## Every peer: the match is decided (`winner_team` -1 = tie).
signal match_over(winner_team: int)

enum Phase { WAIT, PLAY, CELEBRATE, KICKOFF, OVER }
enum Role { CHASE, KEEPER, SUPPORT }

const Pitch := preload("res://minigames/blob_ball/pitch.gd")
const Scoreboard := preload("res://minigames/blob_ball/scoreboard.gd")
const BALL_MODEL := "res://assets/models/props/ball_beach.glb"
const R := BlobBallSim.RADIUS

## Kick-off formations per team size, for team 0 on a 22 x 13 m pitch (x < 0 is its half).
const FORMATIONS: Array = [
	[],
	[Vector2(-3.4, 0.0)],
	[Vector2(-3.2, -2.2), Vector2(-3.2, 2.2)],
	[Vector2(-2.8, -2.8), Vector2(-2.8, 2.8), Vector2(-6.2, 0.0)],
	[Vector2(-2.6, -3.0), Vector2(-2.6, 3.0), Vector2(-5.2, 0.0), Vector2(-8.3, 0.0)],
]

# --- Rules -----------------------------------------------------------------------------------
@export var match_time: float = 90.0
@export var goals_to_win: int = 3
@export var golden_goal_time: float = 20.0
## Seconds everyone is frozen after a goal (the celebration), then the kick-off reset.
@export var celebrate_time: float = 2.0
## Seconds frozen at the kick-off spots before play resumes.
@export var kickoff_time: float = 1.0
## Session end grace after the deciding goal / the final whistle.
@export var end_grace: float = 2.0
## A goal is credited to the scoring team's last toucher if that touch is this recent (s).
@export var credit_window: float = 10.0

# --- Ball feel -----------------------------------------------------------------------------
## Fraction of the closing speed the ball bounces off a walking blob with.
@export var touch_bounce: float = 0.45
## Shove reach: ball surface to blob surface (m).
@export var kick_reach: float = 0.85
## Seconds after a shove starts in which the ball may still come into reach.
@export var kick_window: float = 0.15
## Shoves of the smaller team (odd player counts) launch the ball this much harder.
@export var small_team_kick_bonus: float = 1.15
## A ball coming in faster than this (m/s) bumps the blob it hits.
@export var bump_speed: float = 6.0
@export var bump_scale: float = 0.55
@export var bump_max: float = 8.0
@export var bump_lift: float = 2.5
@export var bump_cooldown: float = 0.5

# --- Netcode -------------------------------------------------------------------------------
## Host ball updates per second (unreliable).
@export var state_rate: float = 20.0
## Visual offset decay after a correction (1/s).
@export var blend_rate: float = 14.0
## Corrections larger than this snap (m).
@export var snap_distance: float = 3.0
## Client: seconds unreliable updates are ignored after its own touch or kick.
@export var own_touch_hold: float = 0.12
## Host: how far a client's reported blob position may be from the host's copy (m).
@export var report_tolerance: float = 3.0
## Host: extra reach allowed for a client's reported shove or touch (m).
@export var reach_tolerance: float = 0.9

var music_track: StringName = &"sky_sumo"

var sim: BlobBallSim = BlobBallSim.new()
## The ball as this peer simulates it (host: the truth).
var ball: BlobBallSim.State = BlobBallSim.State.new()
## Goals per team, every peer.
var score: Array[int] = [0, 0]
## slot -> goals credited, every peer.
var goals_by_slot: Dictionary[int, int] = {}
var phase: Phase = Phase.WAIT
var golden: bool = false
## Round seconds of play (paused during celebrations and kick-offs). Host-owned; clients follow.
var clock: float = 0.0
## Every peer: "team:s0-s1" per goal, in order (network check).
var goal_log: Array[String] = []
## Every peer: slots of every accepted kick, in order.
var kick_log: Array[int] = []
## Client: prediction error (m) at each host update (network check): count, sum, max, >0.5 m.
var net_error: Dictionary = {"n": 0, "sum": 0.0, "max": 0.0, "over": 0}

var _running: bool = false
var _phase_left: float = 0.0
var _seq: int = 0
var _last_seq: int = -1
var _send_accum: float = 0.0
var _hold_states: float = 0.0
var _render_offset: Vector3 = Vector3.ZERO
var _ball_basis: Basis = Basis.IDENTITY
var _kick_open: Dictionary[int, float] = {}
var _bump_cd: Dictionary[int, float] = {}
var _touch_cd: Dictionary[int, float] = {}
var _kick_req_cd: Dictionary[int, float] = {}
## Host: per team [slot, clock] of its last touch.
var _last_touch: Array = [[-1, -INF], [-1, -INF]]
var _rethink_left: float = 0.0
var _rethink_ball: Vector3 = Vector3.INF
var _rethink_frame: int = -1
var _rethink_slot: int = -2
var _forced_goal_at: float = -1.0
var _built: bool = false

var _pitch_root: Node3D = null
var _ball_node: Node3D = null
var _shadow: MeshInstance3D = null
var _shadow_mat: StandardMaterial3D = null
var _scoreboard: CanvasLayer = null
var _goals: Array = []

@onready var _camera: ArenaCamera = get_node_or_null(^"ArenaCamera") as ArenaCamera


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ball-goal-at="):
			_forced_goal_at = arg.trim_prefix("--ball-goal-at=").to_float()
	# A floor at once (the walls follow in _setup, once the player count is known).
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60.0, 1.0, 60.0)
	cs.shape = box
	cs.position.y = -0.5
	floor_body.add_child(cs)
	add_child(floor_body)
	_build_ball()


# --- Flow ----------------------------------------------------------------------------------

func _setup(p_players: Array[Player]) -> void:
	configure_pitch(p_players.size())
	ball = sim.kickoff_state()
	_render_offset = Vector3.ZERO
	_update_ball_visual(0.0)
	for p in p_players:
		if not p.shove_started.is_connected(_on_shove_started):
			p.shove_started.connect(_on_shove_started.bind(p))
	if not teams_changed.is_connected(_on_teams_changed):
		teams_changed.connect(_on_teams_changed)
	if _scoreboard == null:
		_scoreboard = Scoreboard.new()
		_scoreboard.name = "Scoreboard"
		add_child(_scoreboard)
	_refresh_scoreboard()
	if _is_host():
		assign_teams(2)
		place_formation()
		for p in p_players:
			var t := team_of(p.slot)
			if t >= 0:
				set_role_text(p.slot, "Shove the ball into the %s goal!" % team_name(1 - t))


## Sizes the pitch for `count` players and builds it (every peer, once).
func configure_pitch(count: int) -> void:
	if _built:
		return
	_built = true
	if count <= 3:
		sim.configure(16.0, 10.0, 3.6)
	elif count <= 5:
		sim.configure(19.0, 11.5, 3.8)
	else:
		sim.configure(22.0, 13.0, 4.0)
	_pitch_root = Node3D.new()
	_pitch_root.name = "Pitch"
	add_child(_pitch_root)
	var colors: Array[Color] = [team_color(0), team_color(1)]
	_goals = Pitch.build(_pitch_root, sim, colors, Look.is_low())["goals"]
	if _camera:
		_camera.mode = ArenaCamera.Mode.FIXED
		_camera.fixed_focus = Vector3(0.0, 0.0, 0.6)
		_camera.fixed_distance = 11.0 + sim.half_length * 1.05
		_camera.distance = _camera.fixed_distance


func _start() -> void:
	_running = true
	phase = Phase.PLAY
	clock = 0.0
	golden = false
	score = [0, 0]
	goals_by_slot.clear()
	for p in players:
		if is_instance_valid(p):
			goals_by_slot[p.slot] = 0
			RoundUI.push_counter(p.slot, 0)
	_reset_ball()
	_refresh_scoreboard()
	if _is_host():
		_send_state()
		request_bot_rethink()


func _host_tick(delta: float) -> void:
	if not _running or is_finished():
		return
	for s: int in _kick_req_cd:
		_kick_req_cd[s] -= delta
	match phase:
		Phase.PLAY:
			clock += delta
			if _forced_goal_at >= 0.0 and clock >= _forced_goal_at:
				_forced_goal_at = -1.0
				ball.pos = Vector3(sim.half_length - 1.0, R, 0.0)
				ball.vel = Vector3(9.0, 0.0, 0.0)
				_send_state()
			var side := sim.goal_side(ball)
			if side >= 0:
				_score(1 - side)
				return
			if _team_gone():
				return
			var end_t := match_time + (golden_goal_time if golden else 0.0)
			if clock >= end_t:
				if not golden and score[0] == score[1]:
					_rpc_golden.rpc(clock)
				else:
					_end_by_time()
				return
			_rethink_cadence(delta)
		Phase.CELEBRATE:
			_phase_left -= delta
			if _phase_left <= 0.0:
				_start_kickoff()
		Phase.KICKOFF:
			_phase_left -= delta
			if _phase_left <= 0.0:
				_rpc_resume.rpc(clock)


## Host: transforms every player to its kick-off spot (respawn_at reaches every peer).
func place_formation() -> void:
	for t in 2:
		var slots := team_slots(t)
		for i in slots.size():
			var p := _player(slots[i])
			if p and is_instance_valid(p):
				p.respawn_at(formation(t, i, slots.size()))


## Kick-off spot `i` of `count` for `team`, facing the centre.
func formation(team: int, i: int, count: int) -> Transform3D:
	var spots: Array = FORMATIONS[clampi(count, 1, FORMATIONS.size() - 1)]
	var f: Vector2 = spots[i % spots.size()]
	var att := attack_dir(team)
	var pos := Vector3(f.x * sim.half_length / 11.0 * att, 0.0, f.y * sim.half_width / 6.5)
	var face := Vector3(att, 0.0, 0.0)
	return Transform3D(Basis(Vector3.UP, atan2(face.x, face.z)), pos)


## +1 when `team` attacks the +X goal (team 0), -1 otherwise.
static func attack_dir(team: int) -> float:
	return 1.0 if team == 0 else -1.0


func _score(team: int) -> void:
	var credit := -1
	var mine: Array = _last_touch[team]
	var theirs: Array = _last_touch[1 - team]
	if int(mine[0]) >= 0 and clock - float(mine[1]) <= credit_window and float(mine[1]) >= float(theirs[1]):
		credit = int(mine[0])
	var s: Array[int] = score.duplicate()
	s[team] += 1
	var final: bool = s[team] >= goals_to_win or golden
	_rpc_goal.rpc(team, s[0], s[1], credit, final)
	if final:
		finish_teams([team, 1 - team] as Array[int], end_grace)
	else:
		_phase_left = celebrate_time


func _end_by_time() -> void:
	if score[0] == score[1]:
		_rpc_over.rpc(-1, score[0], score[1])
		var all: Array[int] = []
		for p in players:
			if is_instance_valid(p):
				all.append(p.slot)
		all.sort()
		finish([all], end_grace)
	else:
		var w := 0 if score[0] > score[1] else 1
		_rpc_over.rpc(w, score[0], score[1])
		finish_teams([w, 1 - w] as Array[int], end_grace)


## Host: a team with nobody left loses at once (players can leave mid-round).
func _team_gone() -> bool:
	if not has_teams():
		return false
	for t in 2:
		var any := false
		for s in team_slots(t):
			if _live(_player(s)):
				any = true
				break
		if not any:
			_rpc_over.rpc(1 - t, score[0], score[1])
			finish_teams([1 - t, t] as Array[int], end_grace)
			return true
	return false


func _start_kickoff() -> void:
	_rpc_kickoff.rpc(clock)
	place_formation()
	_phase_left = kickoff_time


func _rethink_cadence(delta: float) -> void:
	_rethink_left -= delta
	if _rethink_left > 0.0:
		return
	_rethink_left = 0.35
	if _rethink_ball == Vector3.INF or _rethink_ball.distance_to(ball.pos) > 0.8:
		_rethink_ball = ball.pos
		request_bot_rethink()


## Asks bots to re-plan; repeats within one physics frame are dropped.
func request_bot_rethink(slot: int = -1) -> void:
	var frame := Engine.get_physics_frames()
	if frame == _rethink_frame and (_rethink_slot == -1 or _rethink_slot == slot):
		return
	_rethink_frame = frame
	_rethink_slot = slot
	super(slot)


# --- Every peer: the ball ------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not _running:
		return
	for d: Dictionary in [_bump_cd, _touch_cd]:
		for s: int in d:
			d[s] -= delta
	_hold_states = maxf(0.0, _hold_states - delta)
	step_ball(delta)
	if not _is_host() and phase == Phase.PLAY:
		clock += delta * Session.time_scale
	if _is_host():
		_send_accum += delta
		var interval := 1.0 / maxf(state_rate, 1.0)
		if _send_accum >= interval:
			_send_accum = minf(_send_accum - interval, interval)
			_send_state()
	_refresh_scoreboard()


## One physics step of the ball on this peer: integrate, blob contacts, shoves.
func step_ball(delta: float) -> void:
	sim.step(ball, delta)
	var host := _is_host()
	for p in players:
		if not _live(p):
			continue
		var local := p.is_authority()
		if host and not local:
			continue  # a client reports its own blob's touches
		var cap := capsule_of(p)
		var res := sim.contact(ball, p.global_position, p.velocity, cap.x, cap.y, cap.z, touch_bounce)
		if res.x < 0.0 or not local:
			continue
		if res.x > 0.0:
			_on_local_touch(p)
		if res.y > bump_speed and _bump_cd.get(p.slot, 0.0) <= 0.0 and not p.frozen:
			_bump_cd[p.slot] = bump_cooldown
			var away := Vector3(p.global_position.x - ball.pos.x, 0.0, p.global_position.z - ball.pos.z)
			away = away.normalized() if away.length_squared() > 0.0001 else Vector3.RIGHT
			p.apply_impulse(away * minf(res.y * bump_scale, bump_max) + Vector3.UP * bump_lift)
	sim.collide_bounds(ball)
	_process_kicks(delta)


## Blob capsule as (radius, axis bottom, axis top) above its origin, from its collision shape.
func capsule_of(p: Player) -> Vector3:
	var cs := p.get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	if cs and cs.shape is CapsuleShape3D:
		var cap := cs.shape as CapsuleShape3D
		var r := cap.radius * absf(cs.scale.x)
		var half := cap.height * 0.5 * absf(cs.scale.y)
		var c := cs.position.y
		return Vector3(r, c - half + r, c + half - r)
	return Vector3(0.4, 0.4, 0.6)


func _on_local_touch(p: Player) -> void:
	if _is_host():
		_note_touch(p.slot)
		return
	_hold_states = own_touch_hold
	if _touch_cd.get(p.slot, 0.0) <= 0.0:
		_touch_cd[p.slot] = 0.03
		_rpc_touch.rpc_id(1, p.slot, p.global_position, p.velocity)


func _on_shove_started(p: Player) -> void:
	if not _running or not is_instance_valid(p) or not p.is_authority():
		return
	_kick_open[p.slot] = kick_window


func _process_kicks(delta: float) -> void:
	if _kick_open.is_empty():
		return
	for slot: int in _kick_open.keys():
		_kick_open[slot] -= delta
		var p := _player(slot)
		if not _live(p) or not p.is_authority() or phase != Phase.PLAY or p.frozen:
			_kick_open.erase(slot)
			continue
		if sim.in_kick_reach(ball, p.global_position, p.facing, kick_reach):
			_kick_open.erase(slot)
			if _is_host():
				_host_kick(slot, p.facing)
			else:
				sim.kick(ball, p.facing, kick_power(slot))
				_hold_states = own_touch_hold
				_rpc_kick_request.rpc_id(1, slot, p.global_position, p.facing)
		elif _kick_open[slot] <= 0.0:
			_kick_open.erase(slot)


## Shove strength factor of `slot` (the smaller team's shoves are a bit stronger).
func kick_power(slot: int) -> float:
	var t := team_of(slot)
	if t < 0:
		return 1.0
	return small_team_kick_bonus if team_slots(t).size() < team_slots(1 - t).size() else 1.0


## Host: a shove on the ball by `slot` along `facing`.
func _host_kick(slot: int, facing: Vector3) -> void:
	sim.kick(ball, facing, kick_power(slot))
	_note_touch(slot)
	_rpc_kicked.rpc(slot, ball.pos, ball.vel, ball.spin, clock)
	request_bot_rethink()


func _note_touch(slot: int) -> void:
	var t := team_of(slot)
	if t >= 0:
		_last_touch[t] = [slot, clock]


func _send_state() -> void:
	if not SyncHub.is_networked(multiplayer) or multiplayer.get_peers().is_empty():
		return
	_seq += 1
	_rpc_state.rpc(_seq, clock, ball.pos, ball.vel, ball.spin)


## Client: takes the host's ball. The jump between the drawn ball and the new state becomes a
## visual offset that decays; `snap` (goals, kick-offs) or a huge jump drops it.
func _adopt(pos: Vector3, vel: Vector3, spin: Vector3, snap: bool) -> void:
	var drawn := ball.pos + _render_offset
	_render_offset = Vector3.ZERO if snap or drawn.distance_to(pos) > snap_distance else drawn - pos
	ball.pos = pos
	ball.vel = vel
	ball.spin = spin


func _reset_ball() -> void:
	ball = sim.kickoff_state()
	_render_offset = Vector3.ZERO
	_kick_open.clear()
	_hold_states = 0.0
	_rethink_ball = Vector3.INF
	_update_ball_visual(0.0)


# --- RPCs: host -> every peer --------------------------------------------------------------------

@rpc("authority", "call_remote", "unreliable")
func _rpc_state(seq: Variant, t: Variant, pos: Variant, vel: Variant, spin: Variant) -> void:
	if typeof(seq) != TYPE_INT or typeof(t) != TYPE_FLOAT or typeof(pos) != TYPE_VECTOR3 \
			or typeof(vel) != TYPE_VECTOR3 or typeof(spin) != TYPE_VECTOR3:
		return
	if seq <= _last_seq:
		return
	_last_seq = seq
	clock = t
	if not _running:
		return
	var err := ball.pos.distance_to(pos)
	net_error["n"] = int(net_error["n"]) + 1
	net_error["sum"] = float(net_error["sum"]) + err
	net_error["max"] = maxf(float(net_error["max"]), err)
	if err > 0.5:
		net_error["over"] = int(net_error["over"]) + 1
	if _hold_states > 0.0:
		return
	_adopt(pos, vel, spin, false)


@rpc("authority", "call_local", "reliable")
func _rpc_kicked(slot: int, pos: Vector3, vel: Vector3, spin: Vector3, t: float) -> void:
	if not _is_host():
		_adopt(pos, vel, spin, false)
		_hold_states = 0.0
		clock = t
	kick_log.append(slot)
	Sfx.play(&"hit_bonk", pos)
	Fx.play(&"dust_puff", Vector3(pos.x, 0.05, pos.z))
	ball_kicked.emit(slot)
	request_bot_rethink()


@rpc("authority", "call_local", "reliable")
func _rpc_goal(team: int, s0: int, s1: int, scorer: int, final: bool) -> void:
	score = [s0, s1]
	phase = Phase.OVER if final else Phase.CELEBRATE
	_kick_open.clear()
	if scorer >= 0:
		goals_by_slot[scorer] = goals_by_slot.get(scorer, 0) + 1
		RoundUI.push_counter(scorer, goals_by_slot[scorer])
	goal_log.append("%d:%d-%d" % [team, s0, s1])
	for p in players:
		if is_instance_valid(p):
			p.frozen = true
	var word := "WINS" if final else "SCORES"
	RoundUI.push_banner("%s %s! %d - %d" % [team_name(team), word, s0, s1], celebrate_time)
	var side := attack_dir(team)
	var mouth := Vector3(side * sim.half_length, 1.2, 0.0)
	var c := team_color(team)
	Fx.play(&"confetti", mouth + Vector3(-side * 0.8, 0.0, 0.0), c)
	for z: float in [-1.0, 1.0]:
		_team_burst(mouth + Vector3(-side * 1.2, -0.6, z * (sim.goal_half_width + 0.6)), c, -side)
	Sfx.play(&"round_win_jingle")
	if _camera:
		_camera.add_shake(0.35)
	_emotes(team)
	_refresh_scoreboard()
	goal_scored.emit(team, s0, s1, scorer)
	if final:
		match_over.emit(team)
	request_bot_rethink()


@rpc("authority", "call_local", "reliable")
func _rpc_kickoff(t: float) -> void:
	phase = Phase.KICKOFF
	clock = t
	_reset_ball()
	RoundUI.push_banner("KICK-OFF!", kickoff_time)
	Sfx.play(&"countdown_beep")
	kickoff_reset.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_resume(t: float) -> void:
	if phase == Phase.OVER:
		return
	phase = Phase.PLAY
	clock = t
	for p in players:
		if is_instance_valid(p):
			p.frozen = false
	Sfx.play(&"countdown_go")
	request_bot_rethink()


@rpc("authority", "call_local", "reliable")
func _rpc_golden(t: float) -> void:
	golden = true
	clock = t
	RoundUI.push_banner("GOLDEN GOAL! Next goal wins", 2.5)
	Sfx.play(&"countdown_go")
	_refresh_scoreboard()


@rpc("authority", "call_local", "reliable")
func _rpc_over(winner: int, s0: int, s1: int) -> void:
	score = [s0, s1]
	phase = Phase.OVER
	_kick_open.clear()
	if winner < 0:
		RoundUI.push_banner("DRAW! %d - %d" % [s0, s1], end_grace)
	else:
		RoundUI.push_banner("%s WINS! %d - %d" % [team_name(winner), s0, s1], end_grace)
		Fx.play(&"confetti", Vector3(0.0, 1.5, 0.0), team_color(winner))
		Sfx.play(&"round_win_jingle")
	_emotes(winner)
	_refresh_scoreboard()
	match_over.emit(winner)


# --- RPCs: client -> host --------------------------------------------------------------------------

## A client's own blob touched the ball (its reported position and velocity).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_touch(slot: Variant, ppos: Variant, pvel: Variant) -> void:
	var p := _reported_player(slot, ppos)
	if p == null or typeof(pvel) != TYPE_VECTOR3 or not (pvel as Vector3).is_finite() \
			or (pvel as Vector3).length() > 30.0:
		return
	var cap := capsule_of(p)
	var res := sim.contact(ball, ppos, pvel, cap.x, cap.y, cap.z, touch_bounce, reach_tolerance * 0.5)
	if res.x > 0.0:
		_note_touch(p.slot)
		sim.collide_bounds(ball)


## A client's own blob shoved while the ball looked in reach (its position and facing then).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_kick_request(slot: Variant, ppos: Variant, facing: Variant) -> void:
	var p := _reported_player(slot, ppos)
	if p == null or phase != Phase.PLAY or p.frozen or typeof(facing) != TYPE_VECTOR3:
		return
	var f: Vector3 = facing
	f.y = 0.0
	if not f.is_finite() or f.length_squared() < 0.25:
		return
	if _kick_req_cd.get(p.slot, 0.0) > 0.0:
		return
	if not sim.in_kick_reach(ball, ppos, f, kick_reach + reach_tolerance, 85.0, 1.0):
		return
	_kick_req_cd[p.slot] = 0.3
	_host_kick(p.slot, f.normalized())


## Host: the player `slot` if the sender simulates it, it is in play and `ppos` is plausible.
func _reported_player(slot: Variant, ppos: Variant) -> Player:
	if not _is_host() or not _running or typeof(slot) != TYPE_INT or typeof(ppos) != TYPE_VECTOR3:
		return null
	var p := _player(slot)
	if not _live(p) or p.get_multiplayer_authority() != multiplayer.get_remote_sender_id():
		return null
	var pos: Vector3 = ppos
	if not pos.is_finite() or pos.distance_to(p.global_position) > report_tolerance:
		return null
	return p


# --- Presentation --------------------------------------------------------------------------------

func _build_ball() -> void:
	_ball_node = Node3D.new()
	_ball_node.name = "Ball"
	add_child(_ball_node)
	var scene := load(BALL_MODEL) as PackedScene
	if scene:
		var m := scene.instantiate() as Node3D
		_ball_node.add_child(m)
		Look.apply_toon(m)
	_shadow = MeshInstance3D.new()
	_shadow.name = "BallShadow"
	var disc := CylinderMesh.new()
	disc.top_radius = R * 0.95
	disc.bottom_radius = R * 0.95
	disc.height = 0.01
	disc.radial_segments = 24
	disc.rings = 1
	_shadow.mesh = disc
	_shadow_mat = StandardMaterial3D.new()
	_shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shadow_mat.albedo_color = Color(0.05, 0.12, 0.05, 0.3)
	_shadow.material_override = _shadow_mat
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shadow)
	_update_ball_visual(0.0)


## A one-shot burst of confetti in `color` (a few shades of it), thrown up and toward
## `toward_x` (the pitch). Fewer bits on LOW quality.
func _team_burst(at: Vector3, color: Color, toward_x: float) -> void:
	var p := CPUParticles3D.new()
	p.name = "TeamBurst"
	p.one_shot = true
	p.explosiveness = 0.85
	p.amount = 36 if Look.is_low() else 80
	p.lifetime = 2.2
	var bit := BoxMesh.new()
	bit.size = Vector3(0.16, 0.02, 0.1)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	bit.material = mat
	p.mesh = bit
	p.direction = Vector3(toward_x * 0.45, 1.0, 0.0)
	p.spread = 35.0
	p.initial_velocity_min = 6.0
	p.initial_velocity_max = 10.0
	p.gravity = Vector3(0.0, -7.0, 0.0)
	p.damping_min = 1.5
	p.damping_max = 3.0
	p.angular_velocity_min = -540.0
	p.angular_velocity_max = 540.0
	p.particle_flag_rotate_y = true
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.3
	mat.vertex_color_is_srgb = true
	var ramp := Gradient.new()
	ramp.set_color(0, color.darkened(0.3))
	ramp.set_color(1, color.lightened(0.35))
	ramp.add_point(0.5, color)
	p.color_initial_ramp = ramp
	p.position = at
	add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)


func _process(delta: float) -> void:
	_render_offset *= exp(-blend_rate * delta)
	_update_ball_visual(delta)


func _update_ball_visual(delta: float) -> void:
	if _ball_node == null:
		return
	var ahead := 0.0
	if _running and delta > 0.0:
		ahead = Engine.get_physics_interpolation_fraction() / float(Engine.physics_ticks_per_second)
	var drawn := ball.pos + _render_offset + ball.vel * ahead
	drawn.y = maxf(drawn.y, R)
	_ball_node.position = drawn
	var w := ball.spin.length()
	if w > 0.001 and delta > 0.0:
		_ball_basis = (Basis(ball.spin / w, w * delta) * _ball_basis).orthonormalized()
	_ball_node.basis = _ball_basis
	var h := clampf((drawn.y - R) / 5.0, 0.0, 1.0)
	_shadow.position = Vector3(drawn.x, 0.03, drawn.z)
	_shadow.scale = Vector3.ONE * lerpf(1.0, 0.55, h)
	_shadow_mat.albedo_color.a = lerpf(0.32, 0.12, h)


func _refresh_scoreboard() -> void:
	if _scoreboard == null:
		return
	_scoreboard.call(&"set_score", score[0], score[1])
	var left := (match_time + golden_goal_time - clock) if golden else (match_time - clock)
	_scoreboard.call(&"set_time", left, golden)


func _on_teams_changed() -> void:
	_refresh_scoreboard()


## Scoring / winning team cheers, the other team droops (`team` -1: nobody).
func _emotes(team: int) -> void:
	if team < 0:
		return
	for p in players:
		if not _live(p):
			continue
		var v := p.get_component(&"visuals") as VisualsComponent
		if v:
			v.play_emote(&"cheer" if team_of(p.slot) == team else &"sad")


# --- Bots ----------------------------------------------------------------------------------------

## Chasers go behind the ball on the line from the goal they attack and run through it; one
## mate keeps goal while the ball is in their half; the rest support from behind the ball.
func get_bot_goal(player: Player) -> Vector3:
	var t := team_of(player.slot)
	if t < 0 or phase != Phase.PLAY or not _running:
		return player.global_position
	match bot_role(player, t):
		Role.KEEPER:
			return _keeper_point(t)
		Role.SUPPORT:
			return _support_point(player, t)
	return _chase_point(player, t)


func is_safe(pos: Vector3) -> bool:
	return sim.inside(pos, 0.25)


## The role of `player` on `team` right now.
func bot_role(player: Player, team: int) -> Role:
	var mates: Array[Player] = []
	for s in team_slots(team):
		var q := _player(s)
		if _live(q):
			mates.append(q)
	var n := mates.size()
	if n <= 1:
		return Role.CHASE
	var b := _flat(ball.pos)
	var approach := b - shot_dir(team) * (R + 0.6)
	mates.sort_custom(func(a: Player, c: Player) -> bool:
		return _flat(a.global_position).distance_to(approach) < _flat(c.global_position).distance_to(approach))
	var chasers := 1 if n <= 2 else 2
	var att := attack_dir(team)
	if b.x * att < 0.0:
		var own_goal := Vector3(-att * sim.half_length, 0.0, 0.0)
		var keeper: Player = null
		var best := INF
		for i in range(1, n):
			var d := _flat(mates[i].global_position).distance_to(own_goal)
			if d < best:
				best = d
				keeper = mates[i]
		if player == keeper:
			return Role.KEEPER
	return Role.CHASE if mates.find(player) < chasers else Role.SUPPORT


## Flat unit direction the ball should travel to go into the goal `team` attacks.
func shot_dir(team: int) -> Vector3:
	var att := attack_dir(team)
	var b := _flat(ball.pos)
	var aim := Vector3(att * (sim.half_length + 0.6), 0.0, clampf(b.z * 0.35, -sim.goal_half_width * 0.5, sim.goal_half_width * 0.5))
	var d := aim - b
	return d.normalized() if d.length_squared() > 0.0001 else Vector3(att, 0.0, 0.0)


func _chase_point(p: Player, team: int) -> Vector3:
	var b := _flat(ball.pos)
	var dir := shot_dir(team)
	var me := _flat(p.global_position)
	var rel := me - b
	var along := rel.dot(dir)
	var perp := Vector3(-dir.z, 0.0, dir.x)
	if along > -0.4:
		# On the goal side of the ball (or level with it): go round it, not through it.
		var s := 1.0 if rel.dot(perp) >= 0.0 else -1.0
		return sim.clamp_inside(b + perp * s * (R + 1.3) - dir * 0.9)
	var to_ball := b - me
	var dist := to_ball.length()
	if dist > 0.01 and (to_ball / dist).dot(dir) > 0.85:
		return sim.clamp_inside(b + dir * 1.8, 0.4)
	return sim.clamp_inside(b - dir * (R + 0.7))


func _keeper_point(team: int) -> Vector3:
	var att := attack_dir(team)
	var g := Vector3(-att * sim.half_length, 0.0, 0.0)
	var to := _flat(ball.pos) - g
	var dir := to.normalized() if to.length_squared() > 0.01 else Vector3(att, 0.0, 0.0)
	var p := g + dir * 1.7
	p.z = clampf(p.z, -sim.goal_half_width * 0.8, sim.goal_half_width * 0.8)
	return sim.clamp_inside(p, 0.5)


func _support_point(p: Player, team: int) -> Vector3:
	var att := attack_dir(team)
	var b := _flat(ball.pos)
	var own_x := -att * sim.half_length
	var z := b.z * 0.3 + (2.4 if p.slot % 2 == 0 else -2.4)
	return sim.clamp_inside(Vector3(lerpf(own_x, b.x, 0.55), 0.0, z), 0.8)


# --- Helpers -------------------------------------------------------------------------------------

func _player(slot: int) -> Player:
	if slot < 0:
		return null
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _live(p: Player) -> bool:
	return p != null and is_instance_valid(p) and p.alive and p.is_inside_tree()


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
