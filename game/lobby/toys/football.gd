extends Node3D
## Lobby toy: a 0.8 m football with two small goals against the side walls of the hall and a
## scoreboard on the back wall that counts the balls in each goal tonight.
##
## Physics: the shared deterministic `BallSim` (res://shared/ball_sim.gd, also Blob Ball's), with
## no pitch: the hall's own solids are its obstacles (walls, furniture, the stair ramp, the toys;
## the see-saw plank moves with the see-saw), so the ball never leaves the hall. Belt and braces:
## a ball that is somehow outside the hall box (or not finite) goes back to the spot.
##
## Netcode (Blob Ball's scheme, through the lobby root's RPCs):
## - The HOST owns the ball: steps it every physics frame, resolves contacts with the blobs it
##   simulates (its own and the bots), and sends (pos, vel, spin) ~20 Hz unreliable plus every
##   accepted kick reliably.
## - Every CLIENT steps the same integrator between updates, with contacts against every blob it
##   sees; on an update it adopts the host state and keeps the jump as a visual offset that
##   decays (~0.1 s).
## - A client is authoritative for touches and shoves of ITS OWN blob: it applies them to its
##   prediction at once and reports them (`touch`, `kick_request`); the host checks the reported
##   position against its copy and the reach (with a LAN tolerance), applies the same response and
##   broadcasts the kick. For a moment after its own touch or kick a client ignores updates.
## - Goals are decided on the host: `goal` (reliable, every peer) bumps the counts, confetti and
##   a cheer; after `celebrate_time` the host sends `reset` and the ball is back on the spot.
## Counts survive lobby reloads (static, "tonight"): the host's are the truth, joiners get them
## in the toy snapshot.

signal goal_scored(goal: int, counts: Array)
signal ball_kicked(slot: int)
signal ball_reset

const BALL_MODEL := "res://assets/models/props/toy_football.glb"
const GOAL_MODEL := "res://assets/models/props/toy_goal.glb"
const BOARD_MODEL := "res://assets/models/props/toy_scoreboard.glb"
const RADIUS := 0.4
## Where the ball starts and comes back to after a goal (front middle of the hall, off the
## spawn arc).
const SPOT := Vector3(0.0, RADIUS, 3.6)
## Goals: mouths at x = +-GOAL_X facing the middle, centred on z = GOAL_Z.
const GOAL_X := 10.85
const GOAL_Z := 2.0
const GOAL_HALF_W := 1.1
const GOAL_H := 1.2
const GOAL_DEPTH := 0.9
const GOAL_COLORS: Array[Color] = [Color("#e0483e"), Color("#3f86e0")]
const GOAL_NAMES: Array[String] = ["RED", "BLUE"]
## The board on the back wall (origin bottom centre, back against the wall).
const BOARD_POS := Vector3(-5.6, 2.7, -8.84)
## A ball resting with its centre above this (and not on the stair landing) is out of reach.
const STRANDED_Y := 1.6
## Hall box the ball must stay in (else it is returned).
const HALL_MIN := Vector3(-11.9, -1.0, -8.95)
const HALL_MAX := Vector3(11.9, 12.0, 8.95)

## Balls in each goal tonight (host truth; clients mirror it). [red goal, blue goal]
static var tonight: Array[int] = [0, 0]

@export var touch_bounce: float = 0.5
@export var kick_reach: float = 0.8
@export var kick_window: float = 0.15
@export var celebrate_time: float = 1.2
@export var state_rate: float = 20.0
@export var blend_rate: float = 14.0
@export var snap_distance: float = 3.0
@export var own_touch_hold: float = 0.12
@export var report_tolerance: float = 3.0
@export var reach_tolerance: float = 0.9
## Seconds a ball may lie out of reach before it comes back to the spot.
@export var stranded_time: float = 3.0

var lobby: MansionLobby = null
var sim: BallSim = BallSim.new()
var ball: BallSim.State = BallSim.State.new()
## Every peer: "goal:red-blue" per goal, in order (network check).
var goal_log: Array[String] = []
## Every peer: slots of every accepted kick, in order.
var kick_log: Array[int] = []
## Client: prediction error (m) at each host update: count, sum, max, > 0.5 m.
var net_error: Dictionary = {"n": 0, "sum": 0.0, "max": 0.0, "over": 0}

var _celebrate_left: float = -1.0
var _stranded: float = 0.0
var _seq: int = 0
var _last_seq: int = -1
var _send_accum: float = 0.0
var _hold_states: float = 0.0
var _render_offset: Vector3 = Vector3.ZERO
var _ball_basis: Basis = Basis.IDENTITY
var _kick_open: Dictionary[int, float] = {}
var _touch_cd: Dictionary[int, float] = {}
var _kick_req_cd: Dictionary[int, float] = {}
var _moving: Array = []  # [obstacle index, Callable -> Transform3D]
var _ball_node: Node3D = null
var _shadow: MeshInstance3D = null
var _shadow_mat: StandardMaterial3D = null
var _count_labels: Array[Label3D] = []


## Builds the goals and the board (collision for blobs and the ball), the ball, and the sim's
## obstacles from the hall's solids. Call after every other solid exists.
func setup(p_lobby: MansionLobby) -> void:
	lobby = p_lobby
	sim.radius = RADIUS
	sim.pitch_enabled = false
	sim.goals_enabled = false
	sim.kick_speed = 11.0
	sim.kick_lift = 3.0
	sim.max_speed = 18.0
	sim.roll_decel = 1.4
	var body := lobby.make_static_body("GoalCollision")
	for i in 2:
		_build_goal(i, body)
	for s: Array in lobby.ball_solids:
		if s[0] == &"box":
			sim.add_box(s[1], s[2], s[3])
		else:
			sim.add_cylinder(s[1], s[2], s[3], s[4])
	_build_board()
	_build_ball()
	reset_ball()


## Keeps obstacle `index` at `source.call()` every physics frame (the see-saw plank).
func track_moving(xform: Transform3D, size: Vector3, bounce: float, source: Callable) -> void:
	var i := sim.add_box(xform, size, bounce)
	_moving.append([i, source])


## World transform of goal `i` (0 = red, left; 1 = blue, right): origin at the mouth centre on
## the floor, +Z out of the mouth.
static func goal_xform(i: int) -> Transform3D:
	var side := -1.0 if i == 0 else 1.0
	return Transform3D(Basis(Vector3.UP, -side * PI * 0.5), Vector3(side * GOAL_X, 0.0, GOAL_Z))


## Goal index the ball centre is in (inside the box behind the mouth, under the bar), or -1.
static func goal_of(pos: Vector3) -> int:
	if absf(pos.z - GOAL_Z) >= GOAL_HALF_W - 0.05 or pos.y >= GOAL_H:
		return -1
	if pos.x < -(GOAL_X + 0.2):
		return 0
	if pos.x > GOAL_X + 0.2:
		return 1
	return -1


func is_celebrating() -> bool:
	return _celebrate_left >= 0.0


# --- Every peer: the ball ------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if lobby == null:
		return
	for d: Dictionary in [_touch_cd, _kick_req_cd]:
		for s: int in d:
			d[s] -= delta
	_hold_states = maxf(0.0, _hold_states - delta)
	for m: Array in _moving:
		sim.move_obstacle(m[0], (m[1] as Callable).call())
	step_ball(delta)
	if lobby.is_host():
		_host_step(delta)


## One physics step of the ball on this peer: integrate, blob contacts, shoves.
func step_ball(delta: float) -> void:
	sim.step(ball, delta)
	var host := lobby.is_host()
	for p in lobby.live_players():
		var local := p.is_authority()
		if host and not local:
			continue  # a client reports its own blob's touches
		var cap := BallSim.blob_capsule(p)
		var res := sim.contact(ball, p.global_position, p.velocity, cap.x, cap.y, cap.z, touch_bounce)
		if res.x > 0.0 and local:
			_on_local_touch(p)
	sim.collide_bounds(ball)
	_process_kicks(delta)


func _host_step(delta: float) -> void:
	if host_check_lost(delta):
		return
	if _celebrate_left >= 0.0:
		_celebrate_left -= delta
		if _celebrate_left < 0.0:
			_host_reset()
	else:
		var g := goal_of(ball.pos)
		if g >= 0:
			var counts: Array[int] = tonight.duplicate()
			counts[g] += 1
			_celebrate_left = celebrate_time
			lobby.send_toys(&"_rpc_ball_goal", [g, counts[0], counts[1]])
			apply_goal(g, counts[0], counts[1])
			return
	_send_accum += delta
	var interval := 1.0 / maxf(state_rate, 1.0)
	if _send_accum >= interval:
		_send_accum = minf(_send_accum - interval, interval)
		_seq += 1
		lobby.send_toys(&"_rpc_ball_state", [_seq, ball.pos, ball.vel, ball.spin])


## Host: puts the ball back on the spot when it left the hall, or has been lying out of reach
## (on top of a shelf, the piano, a goal roof...) for `stranded_time`. True if it did.
func host_check_lost(delta: float) -> bool:
	if not ball.pos.is_finite() or not ball.vel.is_finite() or not _in_hall(ball.pos):
		_host_reset()
		return true
	var out_of_reach := ball.pos.y > STRANDED_Y and not _on_landing(ball.pos)
	_stranded = _stranded + delta if out_of_reach and ball.vel.length() < 1.0 else 0.0
	if _stranded > stranded_time:
		_host_reset()
		return true
	return false


## The stair landing in front of the portal (blobs walk up there: the ball is not lost).
static func _on_landing(p: Vector3) -> bool:
	return absf(p.x) < 3.0 and p.z < -7.0 and p.y < 3.2


func _host_reset() -> void:
	_stranded = 0.0
	_celebrate_left = -1.0
	lobby.send_toys(&"_rpc_ball_reset", [])
	reset_ball()


static func _in_hall(p: Vector3) -> bool:
	return p.x > HALL_MIN.x and p.x < HALL_MAX.x and p.y > HALL_MIN.y and p.y < HALL_MAX.y \
			and p.z > HALL_MIN.z and p.z < HALL_MAX.z


func _on_local_touch(p: Player) -> void:
	if lobby.is_host():
		return
	_hold_states = own_touch_hold
	if _touch_cd.get(p.slot, 0.0) <= 0.0:
		_touch_cd[p.slot] = 0.03
		lobby.send_host(&"_rpc_ball_touch", [p.slot, p.global_position, p.velocity])


## A blob's shove started (its authority): the ball may come into reach for a moment.
func on_shove_started(p: Player) -> void:
	_kick_open[p.slot] = kick_window


func _process_kicks(delta: float) -> void:
	if _kick_open.is_empty():
		return
	for slot: int in _kick_open.keys():
		_kick_open[slot] -= delta
		var p := lobby.player_by_slot(slot)
		if p == null or not p.is_authority() or p.frozen:
			_kick_open.erase(slot)
			continue
		if sim.in_kick_reach(ball, p.global_position, p.facing, kick_reach):
			_kick_open.erase(slot)
			if lobby.is_host():
				host_kick(slot, p.facing)
			else:
				sim.kick(ball, p.facing)
				_hold_states = own_touch_hold
				lobby.send_host(&"_rpc_ball_kick_request", [slot, p.global_position, p.facing])
		elif _kick_open[slot] <= 0.0:
			_kick_open.erase(slot)


## Host: a shove on the ball by `slot` along `facing`.
func host_kick(slot: int, facing: Vector3) -> void:
	sim.kick(ball, facing)
	lobby.send_toys(&"_rpc_ball_kicked", [slot, ball.pos, ball.vel, ball.spin])
	apply_kicked(slot, ball.pos, ball.vel, ball.spin)


# --- Host side of client reports -------------------------------------------------------------------

## A client's own blob touched the ball (its reported position and velocity).
func host_touch(p: Player, ppos: Vector3, pvel: Vector3) -> void:
	if not pvel.is_finite() or pvel.length() > 30.0 or ppos.distance_to(p.global_position) > report_tolerance:
		return
	var cap := BallSim.blob_capsule(p)
	var res := sim.contact(ball, ppos, pvel, cap.x, cap.y, cap.z, touch_bounce, reach_tolerance * 0.5)
	if res.x > 0.0:
		sim.collide_bounds(ball)


## A client's own blob shoved while the ball looked in reach (its position and facing then).
func host_kick_request(p: Player, ppos: Vector3, facing: Vector3) -> void:
	var f := Vector3(facing.x, 0.0, facing.z)
	if not f.is_finite() or f.length_squared() < 0.25 or p.frozen:
		return
	if ppos.distance_to(p.global_position) > report_tolerance or _kick_req_cd.get(p.slot, 0.0) > 0.0:
		return
	if not sim.in_kick_reach(ball, ppos, f, kick_reach + reach_tolerance, 85.0, 1.0):
		return
	_kick_req_cd[p.slot] = 0.3
	host_kick(p.slot, f.normalized())


# --- Every peer: replicated events ---------------------------------------------------------------

## Client: the host's ball (unreliable, ~20 Hz).
func apply_state(seq: int, pos: Vector3, vel: Vector3, spin: Vector3) -> void:
	if seq <= _last_seq:
		return
	_last_seq = seq
	var err := ball.pos.distance_to(pos)
	net_error["n"] = int(net_error["n"]) + 1
	net_error["sum"] = float(net_error["sum"]) + err
	net_error["max"] = maxf(float(net_error["max"]), err)
	if err > 0.5:
		net_error["over"] = int(net_error["over"]) + 1
	if _hold_states > 0.0:
		return
	_adopt(pos, vel, spin, false)


func apply_kicked(slot: int, pos: Vector3, vel: Vector3, spin: Vector3) -> void:
	if not lobby.is_host():
		_adopt(pos, vel, spin, false)
		_hold_states = 0.0
	kick_log.append(slot)
	Sfx.play(&"toy_kick", pos)
	Fx.play(&"dust_puff", Vector3(pos.x, 0.05, pos.z))
	ball_kicked.emit(slot)


func apply_goal(g: int, c0: int, c1: int) -> void:
	tonight.assign([c0, c1])
	goal_log.append("%d:%d-%d" % [g, c0, c1])
	_kick_open.clear()
	var xf := goal_xform(g)
	var mouth := xf.origin + Vector3.UP * 0.8
	Fx.play(&"confetti", mouth + xf.basis.z * 0.6, GOAL_COLORS[g])
	Fx.play(&"confetti", mouth + xf.basis.z * 1.2 + Vector3.UP * 0.5, Color.WHITE)
	Sfx.play(&"toy_cheer", mouth)
	_refresh_board()
	goal_scored.emit(g, [c0, c1])


## The ball back on the spot, at rest.
func reset_ball() -> void:
	ball = sim.kickoff_state()
	ball.pos = SPOT
	_render_offset = Vector3.ZERO
	_kick_open.clear()
	_hold_states = 0.0
	_update_ball_visual(0.0)
	if is_inside_tree():
		Fx.play(&"respawn_sparkle", SPOT - Vector3.UP * RADIUS)
	ball_reset.emit()


## Client: the counts and the ball from the host's snapshot.
func apply_snapshot(c0: int, c1: int, pos: Vector3, vel: Vector3, spin: Vector3) -> void:
	tonight.assign([c0, c1])
	_adopt(pos, vel, spin, true)
	_refresh_board()


func _adopt(pos: Vector3, vel: Vector3, spin: Vector3, snap: bool) -> void:
	var drawn := ball.pos + _render_offset
	_render_offset = Vector3.ZERO if snap or drawn.distance_to(pos) > snap_distance else drawn - pos
	ball.pos = pos
	ball.vel = vel
	ball.spin = spin


# --- Presentation --------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_render_offset *= exp(-blend_rate * delta)
	_update_ball_visual(delta)


func _update_ball_visual(delta: float) -> void:
	if _ball_node == null:
		return
	var ahead := 0.0
	if delta > 0.0:
		ahead = Engine.get_physics_interpolation_fraction() / float(Engine.physics_ticks_per_second)
	var drawn := ball.pos + _render_offset + ball.vel * ahead
	drawn.y = maxf(drawn.y, RADIUS)
	_ball_node.position = drawn
	var w := ball.spin.length()
	if w > 0.001 and delta > 0.0:
		_ball_basis = (Basis(ball.spin / w, w * delta) * _ball_basis).orthonormalized()
	_ball_node.basis = _ball_basis
	var h := clampf((drawn.y - RADIUS) / 4.0, 0.0, 1.0)
	_shadow.position = Vector3(drawn.x, 0.02, drawn.z)
	_shadow.scale = Vector3.ONE * lerpf(1.0, 0.55, h)
	_shadow_mat.albedo_color.a = lerpf(0.35, 0.12, h)


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
	disc.top_radius = RADIUS * 0.95
	disc.bottom_radius = RADIUS * 0.95
	disc.height = 0.01
	disc.radial_segments = 20
	disc.rings = 1
	_shadow.mesh = disc
	_shadow_mat = StandardMaterial3D.new()
	_shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shadow_mat.albedo_color = Color(0.06, 0.03, 0.08, 0.35)
	_shadow.material_override = _shadow_mat
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shadow)


func _build_goal(i: int, body: StaticBody3D) -> void:
	var xf := goal_xform(i)
	var scene := load(GOAL_MODEL) as PackedScene
	if scene:
		var m := scene.instantiate() as Node3D
		m.name = "Goal%s" % GOAL_NAMES[i].capitalize()
		m.transform = xf
		add_child(m)
		_tint(m, &"GoalFrame", GOAL_COLORS[i])
		Look.apply_toon(m)
	# Posts, crossbar, side nets and roof (the back is the wall): blobs and the ball.
	var w := GOAL_HALF_W
	var d := GOAL_DEPTH
	for sx: float in [-1.0, 1.0]:
		lobby.add_solid_box(body, xf * Transform3D(Basis(), Vector3(sx * w, GOAL_H * 0.5, 0.0)), Vector3(0.15, GOAL_H, 0.15), 0.7)
		lobby.add_solid_box(body, xf * Transform3D(Basis(), Vector3(sx * w, GOAL_H * 0.5, -d * 0.5)), Vector3(0.06, GOAL_H, d), 0.25)
	lobby.add_solid_box(body, xf * Transform3D(Basis(), Vector3(0.0, GOAL_H + 0.04, -d * 0.5 + 0.05)), Vector3(2.0 * w + 0.15, 0.08, d + 0.1), 0.3)


func _build_board() -> void:
	var scene := load(BOARD_MODEL) as PackedScene
	var board: Node3D
	if scene:
		board = scene.instantiate() as Node3D
		Look.apply_toon(board, false)
	else:
		board = Node3D.new()
	board.name = "Scoreboard"
	board.position = BOARD_POS
	add_child(board)
	for i in 2:
		var l := Label3D.new()
		l.name = "Count%s" % GOAL_NAMES[i].capitalize()
		l.font_size = 96
		l.pixel_size = 0.0055
		l.outline_size = 18
		l.modulate = Color("#fff6e0")
		l.outline_modulate = Color(0.1, 0.05, 0.1)
		l.shaded = false
		l.double_sided = false
		l.position = Vector3((-1.0 if i == 0 else 1.0) * 0.47, 0.45, 0.13)
		l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		board.add_child(l)
		_count_labels.append(l)
	var title := Label3D.new()
	title.name = "Title"
	title.text = "GOALS TONIGHT"
	title.font_size = 40
	title.pixel_size = 0.005
	title.outline_size = 10
	title.modulate = Color("#ffd98a")
	title.outline_modulate = Color(0.12, 0.06, 0.1)
	title.shaded = false
	title.position = Vector3(0.0, 0.88, 0.13)
	title.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	board.add_child(title)
	_refresh_board()


func _refresh_board() -> void:
	for i in _count_labels.size():
		_count_labels[i].text = str(tonight[i])


## Gives every surface of `root` using a material named `mat_name` a copy tinted `color`.
static func _tint(root: Node, mat_name: StringName, color: Color) -> void:
	var copy: StandardMaterial3D = null
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if mat and mat.resource_name == mat_name:
				if copy == null:
					copy = mat.duplicate() as StandardMaterial3D
					copy.albedo_color = color
				mi.set_surface_override_material(s, copy)
