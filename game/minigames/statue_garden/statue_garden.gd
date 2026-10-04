class_name StatueGarden
extends Minigame
## Statue Garden: red light, green light on a long formal lawn. A giant stone butler stands
## on a plinth at the far end. GREEN: it has its back turned and a jaunty tune plays; walk.
## WARNING (WARN_TIME): the tune stops, the head creaks round over its shoulder, the eyes
## light up. RED: it stares; after RED_GRACE anyone still moving (walking, sliding from a
## shove, jumping) is CAUGHT: an eye-beam zaps them back to their spot on the start line
## (`respawn_at`), never eliminated. The first blob to touch the plinth wins (a 2 s
## celebration as end grace); everyone else ranks by distance to the plinth. At `time_limit`
## everyone ranks by distance. A shove that lands in WARNING slides its victim into RED:
## the victim is caught, the shover (standing still by then) is not.
##
## Host decides everything: phase lengths (its own rng), who moved, who touched the plinth,
## the ranking. Phases, catches, the win and the lane order reach every peer through the
## reliable `call_local` RPCs below; the statue, lights, sounds and HUD run on every peer
## from the phase those RPCs set.
##
## Movement test (host, from the positions it sees): a blob is moving when its displacement
## over the last MOVE_WINDOW seconds exceeds MOVE_SPEED (flat) or MOVE_VSPEED (vertical) in
## m/s. Fairness: the host sees a client's blob `view_lag` late (the sync interpolation delay
## plus the round trip: the client hears RED half a trip late, the host sees its reaction
## half a trip later), so each blob's RED is judged on a window shifted by its own lag: only
## motion measured wholly after RED start + RED_GRACE + lag (+ LAG_TOLERANCE), and up to
## RED end + lag - LAG_TOLERANCE, counts. Host-simulated blobs (the host's own, bots) have
## lag 0. Stopping from full speed takes ~0.1 s, so the grace is generous everywhere.
##
## Dev args (after `--`): `--statue-time-scale=<x>` speeds up the host's phase clock (network
## check); `--statue-hold=green|warning|red` holds that phase once reached (screenshots);
## `--statue-advance=<m>` starts every blob that much further up the lawn (screenshots).

## Every peer: a phase began. `index` counts phases from 0; `duration` in (scaled) seconds.
signal phase_changed(phase: int, index: int, duration: float)
## Every peer: `slot` was caught moving in the RED of phase `index` (it is back at the start).
signal caught(slot: int, index: int)
## Every peer: `slot` touched the plinth and won (-1: time ran out).
signal won(slot: int)

enum Phase { IDLE, GREEN, WARNING, RED, OVER }

const STATUE_SCENE: PackedScene = preload("res://assets/models/props/statue_butler.glb")
const HEDGE_SCENE: PackedScene = preload("res://assets/models/props/statue_hedge.glb")
const TOPIARY_SCENE: PackedScene = preload("res://assets/models/props/statue_topiary.glb")
const URN_SCENE: PackedScene = preload("res://assets/models/props/statue_urn.glb")
const BENCH_SCENE: PackedScene = preload("res://assets/models/props/statue_bench.glb")
const FOUNTAIN_SCENE: PackedScene = preload("res://assets/models/props/statue_fountain.glb")
const TUNE_PATH := "res://minigames/statue_garden/audio/statue_tune_loop.wav"
const CREAK_PATH := "res://minigames/statue_garden/audio/statue_creak.wav"
const ZAP_PATH := "res://minigames/statue_garden/audio/statue_zap.wav"
const VIGNETTE_SHADER: Shader = preload("res://minigames/statue_garden/vignette.gdshader")

# --- Garden ----------------------------------------------------------------------------------
## Blob centres stay inside |x| <= SAFE_HALF_X (the hedges' inner faces are at 7.15).
const SAFE_HALF_X := 6.5
const LANE_HALF_WIDTH := 6.4
## The start line (blobs spawn and respawn here, facing the statue) and the hedge behind it.
const START_Z := 13.6
const START_LINE_Z := 12.9
const BACK_HEDGE_Z := 15.7
## The statue: plinth centre and the model's scale (the art is 5.4 m tall at scale 1);
## half extents of the plinth's foot (x, z) and its cap top, scaled (art: 1.8, 1.4, 1.03).
const STATUE_POS := Vector3(0.0, 0.0, -14.0)
const STATUE_SCALE := 1.2
const PLINTH_HALF := Vector2(1.8 * STATUE_SCALE, 1.4 * STATUE_SCALE)
const PLINTH_TOP := 1.03 * STATUE_SCALE
## Head pivot height above the plinth top (art: HEAD_PIVOT_Z - PLINTH_TOP) and eye offset
## from the pivot along the face direction.
const HEAD_PIVOT := Vector3(0.0, 3.12, 0.0)
const EYE_OFFSET := Vector3(0.0, 0.665, 0.53)
## A blob whose centre is this close (flat) to the plinth's foot touches it.
const TOUCH_DIST := 0.55
## The far hedge behind the statue.
const FAR_HEDGE_Z := -17.6
## Lawn obstacles: {kind, pos} (benches and hedge blocks run along X). `circles` below
## are the bot/safety footprint, colliders are built from the same table.
const OBSTACLES: Array[Dictionary] = [
	{"kind": &"fountain", "pos": Vector3(0.0, 0.0, 1.5)},
	{"kind": &"bench", "pos": Vector3(-3.7, 0.0, 6.6)},
	{"kind": &"bench", "pos": Vector3(3.7, 0.0, 6.6)},
	{"kind": &"urn", "pos": Vector3(-2.6, 0.0, -4.6)},
	{"kind": &"urn", "pos": Vector3(2.6, 0.0, -4.6)},
	{"kind": &"hedge", "pos": Vector3(-4.9, 0.0, -7.6)},
	{"kind": &"hedge", "pos": Vector3(4.9, 0.0, -7.6)},
]
## Below this a blob fell out of the garden: back to the start.
const FALL_Y := -4.0

# --- Rules (host) ---------------------------------------------------------------------------
@export var green_range: Vector2 = Vector2(1.8, 4.5)
## The first GREEN after the countdown is never short.
@export var first_green_min: float = 3.0
@export var warn_time: float = 0.45
@export var red_range: Vector2 = Vector2(1.5, 3.0)
## Seconds at the start of RED in which a blob may still skid to a stop.
@export var red_grace: float = 0.25
## Seconds the winner's celebration holds the round (Minigame.finish grace).
@export var win_grace: float = 2.0
@export var time_up_grace: float = 1.5
## Movement test: window (s) and speed limits (m/s).
const MOVE_WINDOW := 0.2
const MOVE_SPEED := 0.6
const MOVE_VSPEED := 1.0
## Fairness slack for remote blobs (s): starts this much later, ends this much earlier.
const LAG_TOLERANCE := 0.05
## Most network lag (s) the shift allows for.
const MAX_VIEW_LAG := 0.35

## Tuning applied to every player on every peer in _setup: a tiptoe pace (the 26 m lawn at
## full speed would be crossed in two greens; at this pace it takes three or four).
const WALK_SPEED := 2.2
const SHOVE_COOLDOWN := 0.5

## Bots: per-bot reflex rolled per round; stop delay after WARNING starts (s) = lerp of this
## range by reflex (+ a little jitter), before the bot's own reaction time.
const BOT_STOP_DELAY := Vector2(0.7, 0.12)
const BOT_STOP_JITTER := 0.4
## Bots: seconds after GREEN starts before a bot sets off again (it watches the statue turn
## away first), by reflex, plus jitter.
const BOT_GO_DELAY := Vector2(0.5, 0.1)
const BOT_GO_JITTER := 0.25
## Bots walk to a point this far ahead in their lane, curving to the plinth at the end.
const BOT_LOOKAHEAD := 5.0
## Bot hint read by BotBrain (0..1, how often bots chase and whether they shove), per phase:
## a little mischief in GREEN, the shove-before-RED trick in WARNING, never in RED.
var bot_aggression_scale: float = 0.0
const BOT_AGGRESSION := {Phase.GREEN: 0.35, Phase.WARNING: 0.6}

## Music: no director track once play starts (the director plays the look's track under the
## title card and goes silent at GO); the statue's own tune (below) is the round's music: its
## stopping is the cue.
var music_track := &"none"

## Test/dev only: multiplies how fast the host's phase clock runs.
var time_scale: float = 1.0
## Host randomness (phase lengths, lane order, ties). Tests may seed it.
var rng := RandomNumberGenerator.new()
## Host randomness for the bots' reflexes. Tests may seed it.
var bot_rng := RandomNumberGenerator.new()

## Every peer: the phase, its index (0-based, -1 before the first) and length (scaled s).
var phase: Phase = Phase.IDLE
var phase_index: int = -1
var phase_length: float = 0.0
## Every peer: lane index per slot (set by the host's lane order).
var lane_of: Dictionary[int, int] = {}
var lane_count: int = 0
## Every peer: catches per slot this round.
var catches: Dictionary[int, int] = {}
## Host: real seconds of play since _start.
var elapsed: float = 0.0

# Host state.
var _phase_left: float = 0.0
var _red_start: float = INF
var _red_end: float = INF
var _history: Dictionary[int, Array] = {}     # slot -> [[t, pos], ...] oldest first
var _caught_now: Dictionary[int, bool] = {}   # slot -> caught in the current RED
var _bot_reflex: Dictionary[int, float] = {}
var _bot_stop_at: Dictionary[int, float] = {}
var _bot_stopped: Dictionary[int, bool] = {}
var _bot_go_at: Dictionary[int, float] = {}
var _hold: Phase = Phase.IDLE
var _circles: Array[Array] = obstacle_circles()
var _lanes_received: bool = false
var _advance: float = 0.0

# Every peer: presentation.
var _anim_time: float = 0.0
var _phase_time: float = 0.0
var _statue: Node3D = null
var _statue_body: Node3D = null
var _statue_head: Node3D = null
var _eye_mats: Array[StandardMaterial3D] = []
var _eye_light: OmniLight3D = null
var _dread: DirectionalLight3D = null
var _vignette: ShaderMaterial = null
var _vignette_layer: CanvasLayer = null
var _lamp: PanelContainer = null
var _lamp_label: Label = null
var _lamp_style: StyleBoxFlat = null
var _body_yaw: float = PI
var _head_yaw: float = 0.0
var _eye_glow: float = 0.0
var _dread_k: float = 0.0
var _winner: int = -1
var _beams: Array[Dictionary] = []   # {node, mat, t}
var _tune: AudioStreamPlayer = null
var _tune_pos: float = 0.0
var _tune_tween: Tween = null
var _creak: AudioStreamPlayer3D = null
var _zap: AudioStreamPlayer3D = null
var _audible: bool = true
var _counter_clock: float = 0.0
var _counters: Dictionary[int, int] = {}

@onready var _camera: ArenaCamera = get_node_or_null(^"ArenaCamera") as ArenaCamera


func _ready() -> void:
	rng.randomize()
	bot_rng.randomize()
	_audible = DisplayServer.get_name() != "headless"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--statue-time-scale="):
			time_scale = maxf(arg.trim_prefix("--statue-time-scale=").to_float(), 0.01)
		elif arg.begins_with("--statue-hold="):
			match arg.trim_prefix("--statue-hold="):
				"green": _hold = Phase.GREEN
				"warning": _hold = Phase.WARNING
				"red": _hold = Phase.RED
		elif arg.begins_with("--statue-advance="):
			_advance = arg.trim_prefix("--statue-advance=").to_float()
	_build_garden()
	_build_statue()
	_build_mood()
	_build_audio()


func _exit_tree() -> void:
	for p: Node in [_tune, _creak, _zap]:
		if p:
			p.call(&"stop")
			p.set(&"stream", null)


# --- Minigame flow ---------------------------------------------------------------------------

func _setup(setup_players: Array[Player]) -> void:
	for p in setup_players:
		var move := p.get_component(&"movement") as MovementComponent
		if move:
			move.max_speed = WALK_SPEED
		var shove := p.get_component(&"shove") as ShoveComponent
		if shove:
			shove.cooldown = SHOVE_COOLDOWN
	lane_count = setup_players.size()
	# The countdown layout: slot order, the same on every peer; the host's shuffle follows.
	var slots := PackedInt32Array()
	for p in setup_players:
		slots.append(p.slot)
	if not _lanes_received:
		_apply_lanes(slots)
	if multiplayer.is_server():
		shuffle_lanes()


## Host: a random lane order from `rng`, sent to every peer (from _setup; tests after seeding).
func shuffle_lanes() -> void:
	var order: Array[int] = []
	for p in players:
		if is_instance_valid(p):
			order.append(p.slot)
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := order[i]
		order[i] = order[j]
		order[j] = t
	_rpc_lanes.rpc(PackedInt32Array(order))


func _start() -> void:
	elapsed = 0.0
	for p in players:
		catches[p.slot] = 0
		if multiplayer.is_server():
			_bot_reflex[p.slot] = bot_rng.randf()


func _host_tick(delta: float) -> void:
	if is_finished():
		return
	elapsed += delta
	var dt := delta * time_scale
	_record_positions()
	for p in _alive():
		if p.global_position.y < FALL_Y:
			_send_back(p, false)
	match phase:
		Phase.IDLE:
			_begin(Phase.GREEN)
		Phase.GREEN, Phase.WARNING, Phase.RED:
			if phase != _hold:
				_phase_left -= dt
			if _phase_left <= 0.0:
				_begin(_next_phase(phase))
	_detect_movement()
	_tell_bots_to_stop()
	_check_touch()
	if is_finished():
		return
	if time_limit > 0.0 and elapsed >= time_limit:
		var ranking := rank_by_distance(-1)
		_rpc_over.rpc(-1)
		finish(ranking, time_up_grace)


static func _next_phase(p: Phase) -> Phase:
	match p:
		Phase.GREEN:
			return Phase.WARNING
		Phase.WARNING:
			return Phase.RED
	return Phase.GREEN


## Host: starts `next` with a fresh length and tells every peer.
func _begin(next: Phase) -> void:
	var length := warn_time
	match next:
		Phase.GREEN:
			var lo := green_range.x if phase_index >= 0 else maxf(green_range.x, first_green_min)
			length = rng.randf_range(lo, maxf(lo, green_range.y))
			if phase == Phase.RED:
				_red_end = elapsed
			_bot_go_at.clear()
			for p in _alive():
				var reflex: float = _bot_reflex.get(p.slot, 0.5)
				var delay := lerpf(BOT_GO_DELAY.x, BOT_GO_DELAY.y, reflex) + bot_rng.randf() * BOT_GO_JITTER
				_bot_go_at[p.slot] = elapsed + delay / maxf(time_scale, 0.01)
		Phase.RED:
			length = rng.randf_range(red_range.x, red_range.y)
			_red_start = elapsed
			_red_end = INF
			_caught_now.clear()
		Phase.WARNING:
			_bot_stopped.clear()  # a bot still waiting to go when GREEN ended goes now
			_bot_stop_at.clear()
			for p in _alive():
				var reflex: float = _bot_reflex.get(p.slot, 0.5)
				var delay := lerpf(BOT_STOP_DELAY.x, BOT_STOP_DELAY.y, reflex) + bot_rng.randf() * BOT_STOP_JITTER
				_bot_stop_at[p.slot] = elapsed + delay / maxf(time_scale, 0.01)
	if _hold != Phase.IDLE and next != _hold:
		length = minf(length, 0.7)  # screenshots: hurry to the held phase
	_phase_left = length
	_rpc_phase.rpc(next, phase_index + 1, length)
	request_bot_rethink()


## Host, tests: the current phase ends at the next tick.
func skip_phase() -> void:
	_phase_left = 0.0


# --- Host: movement, catches, the win ---------------------------------------------------------

func _record_positions() -> void:
	for p in players:
		if not is_instance_valid(p):
			continue
		var h: Array = _history.get(p.slot, [])
		if not p.alive:
			h.clear()
		else:
			h.append([elapsed, p.global_position])
			while h.size() > 2 and float(h[1][0]) <= elapsed - MOVE_WINDOW - 0.3:
				h.pop_front()
		_history[p.slot] = h


## The position of `slot` as recorded at (or just before) time `t`; INF when unknown.
func _position_at(slot: int, t: float) -> Vector3:
	var h: Array = _history.get(slot, [])
	var best := Vector3.INF
	for s: Array in h:
		if float(s[0]) <= t + 0.0001:
			best = s[1]
		else:
			break
	return best


## Host: speeds (flat, vertical) of `slot` over the last MOVE_WINDOW, or [-1, -1] if unknown.
func measured_speed(slot: int) -> Vector2:
	var p := _player(slot)
	var old := _position_at(slot, elapsed - MOVE_WINDOW)
	if p == null or old == Vector3.INF:
		return Vector2(-1.0, -1.0)
	var now := p.global_position
	return Vector2(Vector2(now.x - old.x, now.z - old.z).length(), absf(now.y - old.y)) / MOVE_WINDOW


## Host: seconds the host's view of `p` trails what its owner sees and does (0 for blobs
## this peer simulates): the sync interpolation delay plus a round trip.
func view_lag(p: Player) -> float:
	if p.is_authority():
		return 0.0
	var lag := 0.1
	var sync := p.get_component(&"sync")
	if sync:
		lag = float(sync.get(&"interp_delay"))
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet:
		var peer := enet.get_peer(p.get_multiplayer_authority())
		if peer:
			lag += peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) / 1000.0
	return clampf(lag, 0.0, MAX_VIEW_LAG)


## Host: is `p` judged right now (its own lag-shifted RED, past the grace)?
func is_judged(p: Player) -> bool:
	if _red_start == INF:
		return false
	var lag := view_lag(p)
	var tol := LAG_TOLERANCE if lag > 0.0 else 0.0
	if elapsed - MOVE_WINDOW < _red_start + red_grace + lag + tol - 0.0001:
		return false
	return elapsed <= _red_end + maxf(lag - tol, 0.0)


func _detect_movement() -> void:
	for p in _alive():
		if _caught_now.get(p.slot, false) or not is_judged(p):
			continue
		var v := measured_speed(p.slot)
		if v.x > MOVE_SPEED or v.y > MOVE_VSPEED:
			_caught_now[p.slot] = true
			_rpc_caught.rpc(p.slot, phase_index, p.global_position)
			_send_back(p, true)


## Host: back to its spot on the start line.
func _send_back(p: Player, _was_caught: bool) -> void:
	p.respawn_at(start_transform(p.slot))
	_history[p.slot] = []
	request_bot_rethink(p.slot)


func _tell_bots_to_stop() -> void:
	if phase == Phase.GREEN:
		for slot: int in _bot_go_at:
			if _bot_stopped.get(slot, false) and elapsed >= _bot_go_at[slot]:
				_bot_stopped[slot] = false
				request_bot_rethink(slot)
		return
	if phase != Phase.WARNING and phase != Phase.RED:
		return
	for slot: int in _bot_stop_at:
		if not _bot_stopped.get(slot, false) and elapsed >= _bot_stop_at[slot]:
			_bot_stopped[slot] = true
			request_bot_rethink(slot)


## BotBrain hook (host, where bots are simulated): a stopped bot stands dead still until its go
## time in GREEN (no wandering, personal-space nudges or hops: in RED any of that is a catch).
## Shoves still move it (status impulses), so it can still be shoved into a catch. The stop
## comes after this bot's reflex delay (BOT_STOP_DELAY), so a slow bot is late to stop.
func bot_should_hold(player: Player) -> bool:
	return player != null and _bot_stopped.get(player.slot, false)


func _check_touch() -> void:
	var touching: Array[Player] = []
	for p in _alive():
		if _caught_now.get(p.slot, false) and phase == Phase.RED:
			continue
		if p.global_position.y < PLINTH_TOP + 1.3 and distance_to_statue(p.global_position) <= TOUCH_DIST:
			touching.append(p)
	if touching.is_empty():
		return
	touching.sort_custom(func(a: Player, b: Player) -> bool:
		return distance_to_statue(a.global_position) < distance_to_statue(b.global_position))
	var winner := touching[0].slot
	var ranking := rank_by_distance(winner)
	_rpc_over.rpc(winner)
	finish(ranking, win_grace)


## Host: `first` (if >= 0) then every other slot by distance to the plinth (nearest first;
## exact ties by a host coin flip); blobs no longer in the round last.
func rank_by_distance(first: int) -> Array[int]:
	var ranked: Array[Player] = []
	var gone: Array[int] = []
	var dist: Dictionary[int, float] = {}
	var tie: Dictionary[int, float] = {}
	for p in players:
		if not is_instance_valid(p) or p.slot == first:
			continue
		if not p.alive:
			gone.append(p.slot)
			continue
		ranked.append(p)
		dist[p.slot] = distance_to_statue(p.global_position)
		tie[p.slot] = rng.randf()
	ranked.sort_custom(func(a: Player, b: Player) -> bool:
		if dist[a.slot] != dist[b.slot]:
			return dist[a.slot] < dist[b.slot]
		return tie[a.slot] < tie[b.slot])
	var out: Array[int] = []
	if first >= 0:
		out.append(first)
	for p in ranked:
		out.append(p.slot)
	gone.sort()
	out.append_array(gone)
	return out


# --- Geometry --------------------------------------------------------------------------------

## Flat distance from `pos` to the plinth's foot (0 on or over it).
static func distance_to_statue(pos: Vector3) -> float:
	var dx := maxf(absf(pos.x - STATUE_POS.x) - PLINTH_HALF.x, 0.0)
	var dz := maxf(absf(pos.z - STATUE_POS.z) - PLINTH_HALF.y, 0.0)
	return Vector2(dx, dz).length()


## Lane centre x for lane `i` of `count`, evenly across the lawn.
static func lane_x(i: int, count: int) -> float:
	var n := maxi(count, 1)
	return -LANE_HALF_WIDTH + 2.0 * LANE_HALF_WIDTH * (i + 0.5) / n


## Where `slot` starts and goes back to: its lane on the start line, facing the statue.
func start_transform(slot: int) -> Transform3D:
	var x := lane_x(lane_of.get(slot, 0), lane_count)
	return Transform3D(Basis(Vector3.UP, PI), Vector3(x, 0.0, START_Z))


## Bot footprint of the obstacles: [centre, radius] circles.
static func obstacle_circles() -> Array[Array]:
	var out: Array[Array] = []
	for o: Dictionary in OBSTACLES:
		var c: Vector3 = o["pos"]
		match o["kind"]:
			&"fountain":
				out.append([c, 1.4])
			&"urn":
				out.append([c, 0.45])
			&"bench", &"hedge":
				for dx: float in [-0.6, 0.0, 0.6]:
					out.append([c + Vector3(dx, 0.0, 0.0), 0.5])
	return out


# --- Bots ------------------------------------------------------------------------------------------

## Up the lane toward the statue, around obstacles; from the moment this bot's reflex fires
## in WARNING / RED until its go delay in the next GREEN has passed (and in IDLE / OVER):
## stand still where it is (see `bot_should_hold`).
func get_bot_goal(player: Player) -> Vector3:
	if player == null or not player.alive:
		return super.get_bot_goal(player)
	match phase:
		Phase.GREEN, Phase.WARNING, Phase.RED:
			if not _bot_stopped.get(player.slot, false):
				return _lane_goal(player)
	return player.global_position


## Inside the lawn and off the obstacles.
func is_safe(pos: Vector3) -> bool:
	if absf(pos.x) > SAFE_HALF_X or pos.z > BACK_HEDGE_Z - 0.6 or pos.z < FAR_HEDGE_Z + 0.6:
		return false
	for c: Array in _circles:
		var d := Vector2(pos.x - (c[0] as Vector3).x, pos.z - (c[0] as Vector3).z).length()
		if d < float(c[1]) + 0.35:
			return false
	return true


func _lane_goal(player: Player) -> Vector3:
	var pos := player.global_position
	var front := STATUE_POS.z + PLINTH_HALF.y
	if pos.z < front + 3.5:
		# Last stretch: straight at the plinth face.
		return Vector3(clampf(pos.x, -PLINTH_HALF.x + 0.4, PLINTH_HALF.x - 0.4), 0.0, front + 0.05)
	var lx := lane_x(lane_of.get(player.slot, 0), lane_count)
	var z := maxf(pos.z - BOT_LOOKAHEAD, front + 0.05)
	# Lanes converge on the plinth over the last 10 m.
	var k := clampf((z - front) / 10.0, 0.0, 1.0)
	var goal := Vector3(lerpf(clampf(lx, -PLINTH_HALF.x + 0.4, PLINTH_HALF.x - 0.4), lx, k), 0.0, z)
	return _around_obstacles(pos, goal)


## The first obstacle across the way from `from` to `to` turns the goal into a point beside it
## (on the side nearer the goal line).
func _around_obstacles(from: Vector3, to: Vector3) -> Vector3:
	var a := Vector2(from.x, from.z)
	var b := Vector2(to.x, to.z)
	var best_t := INF
	var hit: Array = []
	for c: Array in _circles:
		var cc := Vector2((c[0] as Vector3).x, (c[0] as Vector3).z)
		var r := float(c[1]) + 0.55
		var ab := b - a
		var t := clampf((cc - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		if (a + ab * t).distance_to(cc) < r and t < best_t:
			best_t = t
			hit = c
	if hit.is_empty():
		return to
	# Go round the whole obstacle (all its circles), on the side of the goal line.
	var centre: Vector3 = hit[0]
	var lo := INF
	var hi := -INF
	for c: Array in _circles:
		var cv: Vector3 = c[0]
		if absf(cv.z - centre.z) < 0.01 and absf(cv.x - centre.x) < 1.6:
			lo = minf(lo, cv.x - float(c[1]))
			hi = maxf(hi, cv.x + float(c[1]))
	var left := Vector3(lo - 0.8, 0.0, centre.z)
	var right := Vector3(hi + 0.8, 0.0, centre.z)
	var pick := left if absf(left.x - to.x) + absf(left.x - from.x) < absf(right.x - to.x) + absf(right.x - from.x) else right
	if not is_safe(pick):
		pick = right if pick == left else left
	return pick


# --- RPCs (host -> every peer) ----------------------------------------------------------------------

## The lane order: `slots[i]` starts in lane i. Sent from _setup (blobs frozen till the countdown ends).
@rpc("authority", "call_local", "reliable")
func _rpc_lanes(slots: PackedInt32Array) -> void:
	_lanes_received = true
	_apply_lanes(slots)


func _apply_lanes(slots: PackedInt32Array) -> void:
	lane_count = slots.size()
	lane_of.clear()
	for i in slots.size():
		lane_of[slots[i]] = i
	for p in players:
		if is_instance_valid(p) and lane_of.has(p.slot):
			var xf := start_transform(p.slot)
			xf.origin.z -= _advance
			p.place_at(global_transform * xf)


@rpc("authority", "call_local", "reliable")
func _rpc_phase(next: int, index: int, length: float) -> void:
	phase = next as Phase
	phase_index = index
	phase_length = length
	_phase_time = _anim_time
	bot_aggression_scale = float(BOT_AGGRESSION.get(phase, 0.0))
	match phase:
		Phase.GREEN:
			_play_tune()
			RoundUI.push_banner("GO!", 0.8)
			if index > 0:
				_play_creak(0.75)
		Phase.WARNING:
			_stop_tune()
			_play_creak(1.0)
			if _camera:
				_camera.add_shake(0.08)
		Phase.RED:
			RoundUI.push_banner("FREEZE!", 0.9)
			_play_creak(0.6)
	_update_lamp()
	phase_changed.emit(next, index, length)


@rpc("authority", "call_local", "reliable")
func _rpc_caught(slot: int, index: int, at: Vector3) -> void:
	catches[slot] = int(catches.get(slot, 0)) + 1
	var p := _player(slot)
	var color := Color(1.0, 0.25, 0.2)
	if p:
		color = Look.parse_color(p.loadout.get("primary", ""), color)
	Fx.play(&"poof", at + Vector3.UP * 0.5)
	Fx.play(&"hit_stars", at + Vector3.UP * 0.9, color)
	_fire_beam(at + Vector3.UP * 0.5)
	if _zap and _audible:
		_zap.global_position = at
		_zap.play()
	Sfx.play(&"eliminated_pop", at)
	if _camera:
		_camera.add_shake(0.15)
	caught.emit(slot, index)


@rpc("authority", "call_local", "reliable")
func _rpc_over(winner: int) -> void:
	phase = Phase.OVER
	_phase_time = _anim_time
	_winner = winner
	_stop_tune()
	_update_lamp()
	var p := _player(winner) if winner >= 0 else null
	if p:
		RoundUI.push_banner("%s wins!" % _name_of(p), 1.8)
		Fx.play(&"confetti", p.global_position + Vector3.UP * 1.2)
		Sfx.play(&"round_win_jingle")
		var visuals := p.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"cheer", true)
	else:
		RoundUI.push_banner("Time's up!", 1.4)
		Sfx.play(&"round_end")
	won.emit(winner)


# --- Presentation (every peer) --------------------------------------------------------------------

func _process(delta: float) -> void:
	_anim_time += delta
	var t := _anim_time - _phase_time
	# The statue: GREEN back turned; WARNING the head swivels round over the shoulder; RED the
	# body turns to face the lawn too (the head keeps staring); OVER it looks at the winner.
	var body_target := PI
	var head_target := 0.0
	var glow := 0.0
	var dread := 0.0
	var sharp := 7.0
	match phase:
		Phase.WARNING:
			var k := clampf(t / maxf(warn_time / maxf(time_scale, 0.01), 0.05), 0.0, 1.0)
			head_target = PI * (k * k * (3.0 - 2.0 * k))
			glow = 0.4 + 2.6 * k
			dread = 0.5 * k
			sharp = 30.0
		Phase.RED:
			body_target = 0.0
			head_target = 0.18 * sin(t * 1.7)
			glow = 5.0 + 1.5 * sin(t * 9.0)
			dread = 1.0
		Phase.OVER:
			body_target = 0.0
			var w := _player(_winner) if _winner >= 0 else null
			if w and _statue:
				var to := w.global_position - _statue.global_position
				head_target = clampf(atan2(to.x, to.z), -1.2, 1.2)
			glow = 1.5
	if phase == Phase.WARNING:
		_head_yaw = head_target  # exact: the turn is the warning's clock
	else:
		_body_yaw = _approach_angle(_body_yaw, body_target, sharp * 0.6, delta)
		if phase == Phase.RED:
			# The body comes round; the head counter-turns so the stare never leaves the lawn.
			head_target = wrapf(head_target - _body_yaw, -PI, PI)
		_head_yaw = _approach_angle(_head_yaw, head_target, sharp, delta)
	if _statue_body:
		_statue_body.rotation.y = _body_yaw
	if _statue_head:
		_statue_head.rotation.y = _head_yaw
	_eye_glow = move_toward(_eye_glow, glow, delta * 20.0)
	for m in _eye_mats:
		m.emission_energy_multiplier = _eye_glow
	if _eye_light:
		_eye_light.light_energy = _eye_glow * 0.6
		if _statue_head:
			_eye_light.global_position = _statue_head.global_transform * Vector3(0.0, EYE_OFFSET.y, EYE_OFFSET.z + 0.6)
	_dread_k = move_toward(_dread_k, dread, delta * 4.0)
	if _dread:
		_dread.light_energy = 0.6 * _dread_k
		_dread.visible = _dread_k > 0.01
	if _vignette:
		_vignette.set_shader_parameter(&"strength", _dread_k)
		_vignette.set_shader_parameter(&"pulse", 0.5 + 0.5 * sin(_anim_time * 6.0))
		_vignette_layer.visible = _dread_k > 0.01
	_update_beams(delta)
	_update_counters(delta)
	_update_camera()


static func _approach_angle(from: float, to: float, sharpness: float, delta: float) -> float:
	var d := wrapf(to - from, -PI, PI)
	return from + d * (1.0 - exp(-sharpness * delta))


func _update_counters(delta: float) -> void:
	_counter_clock -= delta
	if _counter_clock > 0.0:
		return
	_counter_clock = 0.2
	for p in players:
		if not is_instance_valid(p):
			continue
		var m := ceili(maxf(distance_to_statue(p.global_position) - TOUCH_DIST, 0.0))
		if _counters.get(p.slot, -1) != m:
			_counters[p.slot] = m
			RoundUI.push_counter(p.slot, m)


## Frames every living blob plus the statue (so it is always in view), lengthwise.
func _update_camera() -> void:
	if _camera == null or not _camera.is_inside_tree():
		return
	# The point high above the statue keeps it clear of the HUD's timer at the top.
	var pts: Array[Vector3] = [STATUE_POS + Vector3(0.0, 9.5, 0.0), STATUE_POS + Vector3(-2.2, 0.0, PLINTH_HALF.y),
		STATUE_POS + Vector3(2.2, 0.0, PLINTH_HALF.y)]
	for p in _alive():
		pts.append(p.global_position + Vector3.UP * 0.5)
	var vp := _camera.get_viewport()
	var size := vp.get_visible_rect().size if vp else Vector2(16.0, 9.0)
	var aspect := size.x / maxf(size.y, 1.0)
	var framed := ArenaCamera.frame_points(pts, _camera.view_basis(), tan(deg_to_rad(_camera.fov) * 0.5), aspect, 1.6)
	_camera.fixed_focus = framed[0]
	_camera.fixed_distance = clampf(framed[1], _camera.min_distance, _camera.max_distance)


func _update_lamp() -> void:
	if _lamp == null:
		return
	var text := ""
	var col := Color(0.25, 0.75, 0.35)
	match phase:
		Phase.GREEN:
			text = "GO!"
		Phase.WARNING:
			text = "FREEZE!"
			col = Color(0.95, 0.6, 0.15)
		Phase.RED:
			text = "FREEZE!"
			col = Color(0.9, 0.18, 0.15)
	_lamp.visible = text != ""
	_lamp_label.text = text
	_lamp_style.bg_color = col


func _fire_beam(to: Vector3) -> void:
	if _statue_head == null:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.12, 0.08, 0.95)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var root := Node3D.new()
	root.name = "Zap"
	add_child(root)
	for side: float in [-1.0, 1.0]:
		var from := _statue_head.global_transform * (EYE_OFFSET + Vector3(0.19 * side, 0.0, 0.0))
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.07
		cm.bottom_radius = 0.2
		cm.height = 1.0
		cm.radial_segments = 8
		cm.rings = 1
		cm.cap_top = false
		cm.cap_bottom = false
		mi.mesh = cm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
		var span := from.distance_to(to)
		var y := (from - to).normalized()
		var x := y.cross(Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		mi.global_transform = Transform3D(Basis(x, y * span, x.cross(y)), (from + to) * 0.5)
	# A flash where it hits.
	var flash := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.7
	sm.height = 1.4
	sm.radial_segments = 12
	sm.rings = 6
	flash.mesh = sm
	flash.material_override = mat
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(flash)
	flash.global_position = to
	_beams.append({"node": root, "mat": mat, "t": 0.0, "flash": flash})


func _update_beams(delta: float) -> void:
	for i in range(_beams.size() - 1, -1, -1):
		var b := _beams[i]
		b["t"] = float(b["t"]) + delta
		var k := float(b["t"]) / 0.45
		var mat := b["mat"] as StandardMaterial3D
		mat.albedo_color.a = 0.95 * (1.0 - k * k)
		(b["flash"] as Node3D).scale = Vector3.ONE * (0.4 + 0.8 * k)
		if k >= 1.0:
			(b["node"] as Node).queue_free()
			_beams.remove_at(i)


# --- Building (every peer, identical everywhere) ------------------------------------------------------

func _build_garden() -> void:
	var garden := Node3D.new()
	garden.name = "Garden"
	add_child(garden)
	var body := StaticBody3D.new()
	body.name = "GardenBody"
	body.collision_mask = 0
	garden.add_child(body)
	# Ground: one collider; mown stripes across the lawn, a gravel walk round it, meadow beyond.
	_box(body, Vector3(0.0, -0.5, 0.0), Vector3(40.0, 1.0, 48.0))
	var meadow := _plane(garden, Vector2(120.0, 120.0), Look.toon_material(Color("#5c8f45"), 0.95, false), Vector3(0.0, -0.03, 0.0))
	meadow.name = "Meadow"
	_plane(garden, Vector2(16.2, BACK_HEDGE_Z - FAR_HEDGE_Z + 1.0), Look.toon_material(Color("#d9c9a3"), 0.95, false),
		Vector3(0.0, -0.015, (BACK_HEDGE_Z + FAR_HEDGE_Z) * 0.5))
	var light_green := Look.toon_material(Color("#7cc25a"), 0.9, false)
	var dark_green := Look.toon_material(Color("#68ad4b"), 0.9, false)
	var z := BACK_HEDGE_Z - 0.45
	var i := 0
	while z > FAR_HEDGE_Z + 0.45:
		var seg := minf(2.0, z - (FAR_HEDGE_Z + 0.45))
		_plane(garden, Vector2(2.0 * 7.1, seg), light_green if i % 2 == 0 else dark_green, Vector3(0.0, 0.0, z - seg * 0.5))
		z -= seg
		i += 1
	# The start line: a white chalk strip with a gold edge.
	_plane(garden, Vector2(13.6, 0.22), Look.toon_material(Color("#f6f1e4"), 0.9, false), Vector3(0.0, 0.006, START_LINE_Z))
	# A pale gravel apron round the plinth (shows the goal).
	_plane(garden, Vector2(6.6, 5.0), Look.toon_material(Color("#e6d8b4"), 0.95, false), Vector3(STATUE_POS.x, 0.004, STATUE_POS.z + 0.5))

	# Side hedges with urns in the gaps, tall hedges behind the statue, low ones behind the start.
	for sx: float in [-1.0, 1.0]:
		var hz := BACK_HEDGE_Z + 0.4
		var n := 0
		while hz > FAR_HEDGE_Z - 0.5:
			if n % 4 == 3:
				_place(garden, URN_SCENE, Vector3(sx * 7.6, 0.0, hz - 1.0), 0.0)
			else:
				var h := _place(garden, HEDGE_SCENE, Vector3(sx * 7.6, 0.0, hz - 1.0), 90.0)
				h.scale = Vector3(1.0, 1.0 + 0.08 * float((n * 7) % 3), 1.0)
			hz -= 2.0
			n += 1
		_box(body, Vector3(sx * 7.6, 1.5, (BACK_HEDGE_Z + FAR_HEDGE_Z) * 0.5), Vector3(0.92, 3.0, BACK_HEDGE_Z - FAR_HEDGE_Z + 1.0))
	for k in 9:
		var hx := -8.0 + 2.0 * k
		var tall := _place(garden, HEDGE_SCENE, Vector3(hx, 0.0, FAR_HEDGE_Z), 0.0)
		tall.scale = Vector3(1.0, 1.9, 1.0)
		var low := _place(garden, HEDGE_SCENE, Vector3(hx, 0.0, BACK_HEDGE_Z), 0.0)
		low.scale = Vector3(1.0, 0.55, 1.0)
	_box(body, Vector3(0.0, 1.5, FAR_HEDGE_Z), Vector3(18.0, 3.0, 0.92))
	_box(body, Vector3(0.0, 1.5, BACK_HEDGE_Z), Vector3(18.0, 3.0, 0.92))
	# Topiaries flank the statue and stand guard beyond the hedges; trees of clipped balls far off.
	for sx: float in [-1.0, 1.0]:
		_place(garden, TOPIARY_SCENE, Vector3(sx * 3.3, 0.0, STATUE_POS.z - 1.6), 0.0)
		_box(body, Vector3(sx * 3.3, 0.9, STATUE_POS.z - 1.6), Vector3(0.9, 1.8, 0.9))
		for tz: float in [-12.0, -4.0, 4.0, 12.0]:
			var t := _place(garden, TOPIARY_SCENE, Vector3(sx * 9.4, 0.0, tz), 0.0)
			t.scale = Vector3.ONE * 1.25
		for tz: float in [-17.5, -8.0, 2.0, 10.0]:
			var t := _place(garden, TOPIARY_SCENE, Vector3(sx * 12.5, 0.0, tz + 1.5 * sx), 0.0)
			t.scale = Vector3.ONE * 1.9
	for tx: float in [-10.0, -5.0, 0.0, 5.0, 10.0]:
		var t := _place(garden, TOPIARY_SCENE, Vector3(tx, 0.0, FAR_HEDGE_Z - 2.2), 0.0)
		t.scale = Vector3.ONE * 2.4

	# Lawn obstacles.
	for o: Dictionary in OBSTACLES:
		var c: Vector3 = o["pos"]
		match o["kind"]:
			&"fountain":
				_place(garden, FOUNTAIN_SCENE, c, 0.0)
				_cyl(body, c + Vector3(0.0, 0.275, 0.0), 1.4, 0.55)
				_cyl(body, c + Vector3(0.0, 0.95, 0.0), 0.6, 1.9)
			&"bench":
				_place(garden, BENCH_SCENE, c, 0.0)
				_box(body, c + Vector3(0.0, 0.25, 0.0), Vector3(2.0, 0.5, 0.62))
				_box(body, c + Vector3(0.0, 0.7, -0.27), Vector3(2.0, 0.5, 0.12))
			&"urn":
				_place(garden, URN_SCENE, c, 0.0)
				_box(body, c + Vector3(0.0, 0.85, 0.0), Vector3(0.66, 1.7, 0.66))
			&"hedge":
				_place(garden, HEDGE_SCENE, c, 0.0)
				_box(body, c + Vector3(0.0, 0.6, 0.0), Vector3(2.0, 1.2, 0.92))
	# Perf: the lawn strips cast no sun shadow; repeated pieces (hedges, topiaries, urns) as one
	# MultiMesh each, the rest merged per 16 m.
	for n: Node in garden.get_children():
		if n is MeshInstance3D and (n as MeshInstance3D).mesh is PlaneMesh:
			(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	StaticMerge.batch(garden)
	StaticMerge.merge(garden, [], 16.0)


func _build_statue() -> void:
	_statue = STATUE_SCENE.instantiate() as Node3D
	_statue.name = "Statue"
	_statue.position = STATUE_POS
	_statue.scale = Vector3.ONE * STATUE_SCALE
	add_child(_statue)
	Look.apply_toon(_statue)
	_statue_body = _statue.find_child("Body", true, false) as Node3D
	_statue_head = _statue.find_child("Head", true, false) as Node3D
	for mi_node in _statue.find_children("*", "MeshInstance3D", true, false):
		var mi := mi_node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s) as StandardMaterial3D
			if mat and mat.resource_name == "EmitEyes":
				var eyes := mat.duplicate() as StandardMaterial3D
				eyes.emission_enabled = true
				eyes.emission = Color(1.0, 0.22, 0.15)
				eyes.emission_energy_multiplier = 0.0
				mi.set_surface_override_material(s, eyes)
				_eye_mats.append(eyes)
	if _statue_body:
		_statue_body.rotation.y = _body_yaw
	# Colliders: the plinth (foot and cap) and a column for the figure.
	var body := StaticBody3D.new()
	body.name = "StatueBody"
	body.collision_mask = 0
	body.position = STATUE_POS
	add_child(body)
	var k := STATUE_SCALE
	_box(body, Vector3(0.0, 0.125 * k, 0.0), Vector3(PLINTH_HALF.x * 2.0, 0.25 * k, PLINTH_HALF.y * 2.0))
	_box(body, Vector3(0.0, (0.25 * k + PLINTH_TOP) * 0.5, 0.0), Vector3(3.4 * k, PLINTH_TOP - 0.25 * k, 2.6 * k))
	_cyl(body, Vector3(0.0, PLINTH_TOP + 2.1 * k, 0.0), 0.95 * k, 4.2 * k)
	# The red glow of the eyes on the lawn.
	_eye_light = OmniLight3D.new()
	_eye_light.name = "EyeLight"
	_eye_light.light_color = Color(1.0, 0.2, 0.12)
	_eye_light.omni_range = 9.0
	_eye_light.omni_attenuation = 1.2
	_eye_light.light_energy = 0.0
	_eye_light.shadow_enabled = false
	add_child(_eye_light)


## The RED mood: a red-violet key light of our own (no shadows) and a screen vignette.
func _build_mood() -> void:
	_dread = DirectionalLight3D.new()
	_dread.name = "DreadLight"
	_dread.light_color = Color(1.0, 0.3, 0.32)
	_dread.light_energy = 0.0
	_dread.shadow_enabled = false
	_dread.visible = false
	_dread.rotation_degrees = Vector3(-35.0, 180.0, 0.0)
	add_child(_dread)
	_vignette_layer = CanvasLayer.new()
	_vignette_layer.name = "Mood"
	_vignette_layer.layer = 1
	_vignette_layer.visible = false
	add_child(_vignette_layer)
	var rect := ColorRect.new()
	rect.name = "Vignette"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette = ShaderMaterial.new()
	_vignette.shader = VIGNETTE_SHADER
	rect.material = _vignette
	_vignette_layer.add_child(rect)
	# The signal lamp: a GO! / FREEZE! pill under the top edge, always visible.
	var hud := CanvasLayer.new()
	hud.name = "SignalHud"
	hud.layer = 2
	add_child(hud)
	var anchor := Control.new()
	anchor.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	anchor.offset_left = -20.0
	anchor.offset_right = -20.0
	anchor.offset_top = 18.0
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(anchor)
	_lamp = PanelContainer.new()
	_lamp.name = "Lamp"
	_lamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lamp_style = StyleBoxFlat.new()
	_lamp_style.set_corner_radius_all(22)
	_lamp_style.content_margin_left = 26.0
	_lamp_style.content_margin_right = 26.0
	_lamp_style.content_margin_top = 4.0
	_lamp_style.content_margin_bottom = 6.0
	_lamp_style.border_color = Color("#2e2a33")
	_lamp_style.set_border_width_all(4)
	_lamp_style.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
	_lamp_style.shadow_size = 6
	_lamp.add_theme_stylebox_override(&"panel", _lamp_style)
	_lamp_label = Label.new()
	_lamp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lamp_label.add_theme_font_size_override(&"font_size", 34)
	_lamp_label.add_theme_color_override(&"font_color", Color.WHITE)
	_lamp_label.add_theme_color_override(&"font_outline_color", Color(0.0, 0.0, 0.0, 0.6))
	_lamp_label.add_theme_constant_override(&"outline_size", 8)
	_lamp.add_child(_lamp_label)
	anchor.add_child(_lamp)
	_lamp.resized.connect(func() -> void: _lamp.position.x = -_lamp.size.x)
	_update_lamp()


func _build_audio() -> void:
	_tune = AudioStreamPlayer.new()
	_tune.name = "Tune"
	_tune.bus = &"Music" if AudioServer.get_bus_index(&"Music") >= 0 else &"Master"
	_tune.volume_db = -4.0
	_tune.stream = _load_stream(TUNE_PATH)
	add_child(_tune)
	_creak = AudioStreamPlayer3D.new()
	_creak.name = "Creak"
	_creak.bus = &"Sfx" if AudioServer.get_bus_index(&"Sfx") >= 0 else &"Master"
	_creak.stream = _load_stream(CREAK_PATH)
	_creak.unit_size = 30.0
	_creak.volume_db = 2.0
	_creak.position = STATUE_POS + Vector3(0.0, 4.0, 0.0)
	add_child(_creak)
	_zap = AudioStreamPlayer3D.new()
	_zap.name = "Zap"
	_zap.bus = _creak.bus
	_zap.stream = _load_stream(ZAP_PATH)
	_zap.unit_size = 30.0
	add_child(_zap)


## A path-less copy, like Sfx does: a cached stream still playing at quit logs an error.
static func _load_stream(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		return null
	var s := load(path) as AudioStream
	return s.duplicate() as AudioStream if s else null


func _play_tune() -> void:
	if _tune_tween:
		_tune_tween.kill()
	_tune.pitch_scale = 1.0
	_tune.volume_db = -30.0
	if _audible and _tune.stream:
		_tune.play(_tune_pos)
	_tune_tween = create_tween()
	_tune_tween.tween_property(_tune, ^"volume_db", -4.0, 0.12)


## The tune drags to a halt (pitch and volume sag) and remembers where it stopped.
func _stop_tune() -> void:
	if _tune_tween:
		_tune_tween.kill()
	if _tune.playing:
		_tune_pos = _tune.get_playback_position()
	_tune_tween = create_tween().set_parallel()
	_tune_tween.tween_property(_tune, ^"pitch_scale", 0.5, 0.3).set_ease(Tween.EASE_IN)
	_tune_tween.tween_property(_tune, ^"volume_db", -40.0, 0.3).set_ease(Tween.EASE_IN)
	_tune_tween.chain().tween_callback(_tune.stop)


func _play_creak(pitch: float) -> void:
	if _creak and _audible and _creak.stream:
		_creak.pitch_scale = pitch
		_creak.play()


func _place(parent: Node3D, scene: PackedScene, pos: Vector3, yaw_deg: float) -> Node3D:
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation_degrees.y = yaw_deg
	parent.add_child(n)
	Look.apply_toon(n)
	return n


func _plane(parent: Node3D, size: Vector2, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _box(body: StaticBody3D, center: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = center
	body.add_child(cs)


func _cyl(body: StaticBody3D, center: Vector3, radius: float, height: float) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = center
	body.add_child(cs)


# --- Helpers -----------------------------------------------------------------------------------------

func _player(slot: int) -> Player:
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _alive() -> Array[Player]:
	var out: Array[Player] = []
	for p in players:
		if is_instance_valid(p) and p.alive:
			out.append(p)
	return out


func _name_of(p: Player) -> String:
	return p.display_name if p.display_name != "" else "Player %d" % (p.slot + 1)
