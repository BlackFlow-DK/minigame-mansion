class_name CrownKeeper
extends Minigame
## Crown Keeper (keep-away of a good thing, 60 s). One golden crown starts on the throne in
## the middle of an octagonal throne room. Touch it to wear it; while you wear it you score
## a point per second (two in the last 15 s, the CORONATION). A landed shove on the wearer
## knocks it off: it arcs 2-3 m along the shove, bounces once, and anyone may grab it after
## 0.4 s, except the previous wearer for 1.2 s. The wearer runs 8 % slower and cannot shove.
## Left alone for 5 s, the crown returns to the throne. Most points wins; ties go to whoever
## wore the crown last.
##
## Networking (docs/contract.md "Networking rules for minigames"):
## - The host decides everything: who picks the crown up (distance checks against synced
##   positions every tick), knock-offs (on `shove_hit`), the landing spots, the returns,
##   the points and the end. Every peer learns it through the reliable `call_local` RPCs
##   below. Points travel as a full snapshot (every slot) whenever one changes (about once a
##   second), so a late packet can never leave a peer with a wrong total.
## - The crown's flight is not simulated per peer: the host computes the launch point and
##   both landing points (clamped inside the room, off the pillars and the throne) and sends
##   them; every peer draws `CrownRig.arc_pos(from, l1, l2, t1, t2, t)`, a pure function.
## - The wearer's speed and shove switch are tuning, set on every peer in _physics_process
##   (only the authority's copy matters).
##
## Bots: the wearer flees (away from the chasers, round the pillars and the dais); the rest
## chase the wearer (leading it a little) or run for the loose crown's landing spot or the
## throne. `request_bot_rethink` on every pickup, knock-off and return, and every 0.5 s while
## someone wears it (a moving target).
##
## Dev args (after `--`): `--crown-time-scale=<x>` (round clock; network check),
## `--crown-pose=worn|flying|throne` (screenshots: slot 1 wears it from the start, or the
## crown hangs mid-flight for a while).

## Every peer: `slot` put the crown on (`from_throne`: picked off the throne).
signal crown_taken(slot: int, from_throne: bool)
## Every peer: the crown was knocked off `slot`; it will come to rest at `land`.
signal crown_knocked(slot: int, land: Vector3)
## Every peer: the crown went back to the throne (left alone, or its wearer left).
signal crown_returned
## Every peer: a points snapshot arrived (slot -> points).
signal scores_changed(scores: Dictionary)
## Every peer: the double-points finale began.
signal coronation_started
## Every peer: the round is over with this ranking.
signal round_over(ranking: Array[int])

enum CrownState { THRONE, WORN, LOOSE }

const CrownRig := preload("res://minigames/crown_keeper/crown_rig.gd")
const PROPS := "res://assets/models/props/"
const ENV := "res://assets/models/env/"

# --- Room geometry (metres; matches assets/models/props/crown_*) ------------------------------
## Distance from the centre to the inner face of each of the 8 walls (a face toward +Z).
const APOTHEM := 9.5
## Blob centres stay inside this octagon (wall face minus blob radius).
const PLAY_APOTHEM := 9.1
## Bots treat everything outside this octagon as unsafe.
const SAFE_APOTHEM := 8.6
## The crown always comes to rest inside this octagon.
const LAND_APOTHEM := 8.3
## Dais: lower step radius/top, upper step radius/top.
const DAIS_R1 := 3.0
const DAIS_H1 := 0.25
const DAIS_R2 := 2.1
const DAIS_H2 := 0.5
## Throne origin (its base centre, on the upper step); it faces +Z.
const THRONE_POS := Vector3(0.0, DAIS_H2, -0.25)
## Throne footprint (x half-width, z min/max relative to THRONE_POS) and seat top.
const THRONE_HALF_X := 0.73
const THRONE_Z_MIN := -0.5
const THRONE_Z_MAX := 0.53
const THRONE_SEAT := 0.575
## Where the crown's base rests on the throne seat.
const THRONE_REST := Vector3(0.0, DAIS_H2 + THRONE_SEAT, -0.2)
const PILLARS: Array[Vector3] = [Vector3(3.9, 0, 3.9), Vector3(-3.9, 0, 3.9), Vector3(-3.9, 0, -3.9), Vector3(3.9, 0, -3.9)]
## Pillar collider half size (the kit pillar's base is 1 m square).
const PILLAR_HALF := 0.5
const BLOB_RADIUS := 0.4
## Height above the crown's base that counts as its centre (pickups).
const CROWN_CENTRE := 0.18
const GOLD := Color(1.0, 0.8, 0.25)
## The wearer's name tag rises this much (m) to clear the royal crown.
const WEARER_TAG_RAISE := 0.5
## Blobs within this distance (m) of the crown turn to watch it (presentation, every peer).
const INTEREST_RANGE := 10.0
## Seconds between interest-point updates (the visuals fade one ~0.6 s after the last call).
const INTEREST_EVERY := 0.2

# --- Rules (host) ---------------------------------------------------------------------------------
@export_group("Rules")
## Points per second while wearing the crown (doubled in the finale).
@export var points_per_second: float = 1.0
## The last this-many seconds score double.
@export var double_window: float = 15.0
## The wearer's run speed, as a fraction of a NORMAL-size blob's, whatever its own size: the
## crown weighs every wearer down to the same pace (balance: with the body size's speed on top,
## a small wearer outran normal chasers and small blobs won 47 % of 4-player rounds, big 8 %).
@export var wearer_speed_factor: float = 0.92
## Share of the body size's speed factor that non-wearers keep here (1 = all of it, 0 = every
## size runs at normal speed; shove, reach, jump and knockback still follow the size). A pure
## chase: speed decides almost everything. Balance (4 / 8 players, mixed sizes, 48 rounds each,
## wins small / normal / big): share 1 with a neutral wearer 30/31/14 % and 20/9/8 %; share 0.5
## 31/19/25 % and 17/13/7 % (big still last on mean place); share 0 27/30/19 % and 15/7/16 %,
## mean places within 0.04 of each other.
@export var size_speed_share: float = 0.0
## Crown centre to the blob's capsule core (m) that counts as a touch.
@export var pickup_reach: float = 0.95
## On the throne: anyone on the upper step within this flat distance (m) of the crown takes it.
@export var throne_reach: float = 1.7
## Seconds after a knock-off before anyone may grab the crown, and before its last wearer may.
@export var pickup_delay: float = 0.4
@export var rewear_block: float = 1.2
## Seconds after a pickup during which a shove does not knock the crown off (no double knocks).
@export var wear_shield: float = 0.35
## Seconds a loose crown may lie untouched before it returns to the throne.
@export var idle_return: float = 5.0
## How far a knock-off sends the crown (m, random in range), and its flight/bounce times (s).
@export var knock_distance: Vector2 = Vector2(2.0, 3.0)
@export var flight_time: float = 0.55
@export var bounce_time: float = 0.28
## The bounce covers this last fraction of the knock distance.
@export var bounce_share: float = 0.25
## Bots: seconds between the chasers' re-aims at a moving wearer.
@export var chase_rethink: float = 0.5
## Bots: how far past the wearer a chaser aims (m), so it runs into shove range.
@export var chase_overshoot: float = 1.3
## Seconds the round stays on screen (everyone frozen) for the winner's moment.
@export var end_grace: float = 2.0

@export_group("Test")
## Test/dev: multiplies the round clock (points, windows, time limit) on the host.
@export var time_scale: float = 1.0

## Host randomness (knock distances). Tests may seed it.
var rng := RandomNumberGenerator.new()

# --- Every peer -----------------------------------------------------------------------------
## Slot wearing the crown, -1 if nobody.
var holder_slot: int = -1
var crown_state: CrownState = CrownState.THRONE
## slot -> points (only ever set from the host's snapshots).
var scores: Dictionary[int, int] = {}
## Pickups so far this round.
var crown_changes: int = 0
## True from the start of the double-points finale.
var double_time: bool = false
## The ranking the round ended with (empty until then).
var final_ranking: Array[int] = []

var _slots: Array[int] = []
var _base_speed: Dictionary[int, float] = {}
var _rig: CrownRig = null
var _rethink_frame: int = -1
var _rethink_slot: int = -2
var _lamps: Array[OmniLight3D] = []

# --- Host -------------------------------------------------------------------------------------
var _running: bool = false
var _over: bool = false
## Round clock (s, host; scaled by time_scale and, under Session, Session.time_scale).
var _t: float = 0.0
## slot -> worn time weighted by the points rate (points = floor of it).
var _wear_acc: Dictionary[int, float] = {}
## slot -> round time that slot last wore the crown (tie-break), -1 never.
var _last_worn: Dictionary[int, float] = {}
var _shield_left: float = 0.0
var _loose_t: float = 0.0
var _launch_from: Vector3 = Vector3.ZERO
var _launch_l1: Vector3 = Vector3.ZERO
var _launch_l2: Vector3 = Vector3.ZERO
var _blocked_slot: int = -1
var _rethink_cd: float = 0.0
var _dev_pose: String = ""
var _dev_hold: float = 0.0
## Every peer: slots whose own hat is hidden (a look override) while they wear the royal crown.
var _hat_hidden: Dictionary[int, bool] = {}
var _interest_cd: float = 0.0
## Host: per-round salt of the bots' chase tastes, drawn from `rng` at the first chase (so a
## test that seeds `rng` after _start still replays the same round); -1 until then.
var _taste_salt: int = -1

@onready var _camera: ArenaCamera = get_node_or_null(^"ArenaCamera") as ArenaCamera


func _ready() -> void:
	rng.randomize()
	_build_room()
	_rig = CrownRig.new()
	_rig.name = "CrownRig"
	add_child(_rig)
	_rig.show_throne(THRONE_REST)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--crown-time-scale="):
			time_scale = maxf(arg.trim_prefix("--crown-time-scale=").to_float(), 0.01)
		elif arg.begins_with("--crown-pose="):
			_dev_pose = arg.trim_prefix("--crown-pose=")


func _setup(round_players: Array[Player]) -> void:
	_slots.clear()
	scores.clear()
	_base_speed.clear()
	for p in round_players:
		_slots.append(p.slot)
		scores[p.slot] = 0
		_wear_acc[p.slot] = 0.0
		_last_worn[p.slot] = -1.0
		var move := p.get_component(&"movement") as MovementComponent
		if move:
			_base_speed[p.slot] = move.max_speed
		if not p.shove_hit.is_connected(_on_shove_hit):
			p.shove_hit.connect(_on_shove_hit.bind(p))
		RoundUI.push_counter(p.slot, 0)
	_set_faces()


func _start() -> void:
	_running = true
	_t = 0.0
	if not Net.is_host():
		return
	match _dev_pose:
		"worn":
			give_crown(1 if _slots.has(1) else _slots[0])
		"flying":
			var p := _player(1 if _slots.has(1) else _slots[0])
			if p:
				knock_off(p, Vector3(1.0, 0.0, 0.6).normalized())
				_dev_hold = INF
				if _rig:
					_rig.hold_at(0.3)


# --- Host: the round -------------------------------------------------------------------------------

func _host_tick(delta: float) -> void:
	if not _running or _over or is_finished():
		return
	var dt := delta * time_scale
	_t += dt
	_rescue_fallen()
	match crown_state:
		CrownState.WORN:
			var h := _player(holder_slot)
			if not _live(h):
				_rpc_return.rpc()  # the wearer left the game: back to the throne
			else:
				_shield_left -= dt
				_last_worn[holder_slot] = _t
				var before := int(_wear_acc[holder_slot])
				_wear_acc[holder_slot] += dt * points_per_second * (2.0 if is_double_time() else 1.0)
				if int(_wear_acc[holder_slot]) != before:
					_rpc_scores.rpc(_score_snapshot())
		CrownState.LOOSE:
			if _dev_hold > 0.0:
				_dev_hold -= delta  # screenshot pose: the crown hangs mid-flight
			else:
				_loose_t += dt
			if _loose_t >= idle_return:
				_rpc_return.rpc()
			else:
				_try_pickup()
		CrownState.THRONE:
			_try_pickup()
	if not double_time and is_double_time():
		_rpc_coronation.rpc()
	_rethink_cd -= dt
	if crown_state == CrownState.WORN and _rethink_cd <= 0.0:
		# The chasers re-aim at the moving wearer; the wearer keeps its own plan a while.
		_rethink_cd = chase_rethink
		for s in _slots:
			if s != holder_slot:
				request_bot_rethink(s)
	if time_limit > 0.0 and _t >= time_limit:
		end_round()


## Host: ends the round now with the points ranking (also called at the time limit, and when a
## leaver leaves one player): ties as groups, players who left the round last (latest first).
func end_round() -> void:
	if _over or is_finished():
		return
	var staying: Array[int] = []
	for s in _slots:
		if not knocked_out.has(s):
			staying.append(s)
	var groups := rank_by_points(staying, _points_now(), _last_worn)
	for i in range(knocked_out.size() - 1, -1, -1):
		groups.append([knocked_out[i]])
	_rpc_end.rpc(PackedInt32Array(Minigame.flatten_groups(groups)), _score_snapshot())
	finish(groups, end_grace)


## Host: a player left (Stage knocks it out): recorded as out, and with one player (or none)
## left the round ends through `end_round` (banner, celebration and points on every peer), not
## the base class's flat ranking. A wearer who leaves sends the crown home (`_host_tick`).
func knock_out(player: Player, reason: StringName = &"") -> void:
	if is_finished() or _over or player == null or not player.alive or player.is_extra:
		super(player, reason)
		return
	knocked_out.append(player.slot)
	player.eliminate(reason if reason != &"" else &"knocked_out")
	var alive := 0
	for p in players:
		if is_instance_valid(p) and p.alive and not p.is_extra:
			alive += 1
	if alive <= 1:
		end_round()


## Host: puts the crown on `slot` now (tests, dev poses; normal play picks up by touch).
func give_crown(slot: int) -> void:
	var p := _player(slot)
	if not _live(p) or _over:
		return
	_shield_left = wear_shield
	_rpc_wear.rpc(slot, crown_state == CrownState.THRONE)


## Host: knocks the crown off `wearer` toward `dir` (XZ). Picks the distance, clamps both
## landing points inside the room and off the pillars and the throne, and tells every peer.
func knock_off(wearer: Player, dir: Vector3) -> void:
	if wearer == null or _over:
		return
	dir.y = 0.0
	dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.FORWARD
	var feet := wearer.global_position
	var from := feet + Vector3.UP * 1.3
	var dist := rng.randf_range(knock_distance.x, knock_distance.y)
	var l2 := clamp_landing(Vector3(feet.x, 0.0, feet.z) + dir * dist)
	var l1 := clamp_landing(Vector3(feet.x, 0.0, feet.z).lerp(l2, 1.0 - bounce_share))
	l1.y = ground_height(l1)
	l2.y = ground_height(l2)
	_rpc_knock.rpc(wearer.slot, from, l1, l2, _clock_scale())


## Seconds on the host's round clock.
func round_time() -> float:
	return _t


## Host (tests): jumps the round clock to `t`.
func set_round_time(t: float) -> void:
	_t = t


func is_double_time() -> bool:
	return time_limit > 0.0 and _t >= time_limit - double_window


## Host: seconds since the last knock-off (only meaningful while the crown is loose).
func loose_time() -> float:
	return _loose_t


## Host: where the crown's base is now (throne, the wearer's head, or on its arc).
func crown_position() -> Vector3:
	match crown_state:
		CrownState.THRONE:
			return THRONE_REST
		CrownState.WORN:
			var h := _player(holder_slot)
			return h.global_position + Vector3.UP * 1.1 if h else THRONE_REST
	return CrownRig.arc_pos(_launch_from, _launch_l1, _launch_l2, flight_time, bounce_time, _loose_t)


## Where a loose crown comes (or came) to rest.
func landing_spot() -> Vector3:
	return _launch_l2


## Host: the slot that may not re-grab the loose crown yet (-1 none).
func blocked_slot() -> int:
	return _blocked_slot if crown_state == CrownState.LOOSE and _loose_t < rewear_block else -1


func _try_pickup() -> void:
	var on_throne := crown_state == CrownState.THRONE
	if not on_throne and _loose_t < pickup_delay:
		return
	var centre := crown_position() + Vector3.UP * CROWN_CENTRE
	var best: Player = null
	var best_d := INF
	for p in players:
		if not _live(p):
			continue
		if not on_throne and p.slot == _blocked_slot and _loose_t < rewear_block:
			continue
		# Measured to the blob's surface (normal-size equivalent): nearest wins a contested grab,
		# and a big body cannot get its centre as close as a small one (balance: big blobs won
		# 16 % of 4-player rounds, small 30 %, with run speeds already size-neutral).
		var grow := _body_grow(p)
		var d := touch_distance(p.global_position, centre) - grow
		var ok := d <= pickup_reach
		if on_throne and not ok and p.global_position.y >= DAIS_H2 - 0.1:
			var flat := Vector2(p.global_position.x - centre.x, p.global_position.z - centre.z).length() - grow
			ok = flat <= throne_reach
			d = flat
		if ok and d < best_d:
			best_d = d
			best = p
	if best:
		give_crown(best.slot)


func _on_shove_hit(victim_slot: int, shover: Player) -> void:
	if not Net.is_host() or not _running or _over or crown_state != CrownState.WORN:
		return
	if victim_slot != holder_slot or _shield_left > 0.0 or shover.slot == victim_slot:
		return
	var victim := _player(victim_slot)
	if not _live(victim):
		return
	var to := victim.global_position - shover.global_position
	to.y = 0.0
	var face := shover.facing
	face.y = 0.0
	var dir := face.normalized() * 2.0 if face.length_squared() > 0.0001 else Vector3.ZERO
	if to.length_squared() > 0.0001:
		dir += to.normalized()
	knock_off(victim, dir)


func _rescue_fallen() -> void:
	var points := get_spawn_points()
	for i in players.size():
		var p := players[i]
		if _live(p) and p.global_position.y < -3.0 and not points.is_empty():
			p.respawn_at(points[i % points.size()])


func _points_now() -> Dictionary:
	var out: Dictionary = {}
	for s in _slots:
		out[s] = int(_wear_acc.get(s, 0.0))
	return out


## Every slot's points, indexed by slot (0..7).
func _score_snapshot() -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(Net.MAX_PLAYERS)
	for s in _slots:
		if s >= 0 and s < arr.size():
			arr[s] = int(_wear_acc.get(s, 0.0))
	return arr


func _clock_scale() -> float:
	return time_scale * Session.time_scale


## Asks bots to re-plan; a repeat in the same physics frame is dropped (as in Hot Potato).
func request_bot_rethink(slot: int = -1) -> void:
	var frame := Engine.get_physics_frames()
	if frame == _rethink_frame and (_rethink_slot == -1 or _rethink_slot == slot):
		return
	_rethink_frame = frame
	_rethink_slot = slot
	super(slot)


# --- RPCs (host -> every peer, host included) --------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_wear(slot: int, from_throne: bool) -> void:
	var p := _player(slot)
	holder_slot = slot
	crown_state = CrownState.WORN
	crown_changes += 1
	_blocked_slot = -1
	_set_faces()  # first: the wearer's hat comes off, so the crown sits on the bare head
	if _rig:
		_rig.show_worn(p)
	request_bot_rethink()
	if p:
		var at := p.global_position + Vector3.UP * 1.3
		Fx.play(&"coin_pickup", at, GOLD)
		Sfx.play(&"coin_big", at)
		if crown_changes == 1:
			RoundUI.push_banner("%s has the crown!" % _name_of(p), 1.6)
	crown_taken.emit(slot, from_throne)


@rpc("authority", "call_local", "reliable")
func _rpc_knock(slot: int, from: Vector3, l1: Vector3, l2: Vector3, clock_scale: float) -> void:
	holder_slot = -1
	crown_state = CrownState.LOOSE
	_launch_from = from
	_launch_l1 = l1
	_launch_l2 = l2
	_loose_t = 0.0
	_blocked_slot = slot
	if _rig:
		_rig.launch(from, l1, l2, flight_time, bounce_time, clock_scale)
	_set_faces()
	request_bot_rethink()
	Fx.play(&"hit_stars", from, GOLD)
	Sfx.play(&"hit_bonk", from)
	Sfx.play(&"coin", from, 0.0, 0.8)
	crown_knocked.emit(slot, l2)


@rpc("authority", "call_local", "reliable")
func _rpc_return() -> void:
	var was := _rig.crown_position() if _rig else THRONE_REST
	holder_slot = -1
	crown_state = CrownState.THRONE
	_blocked_slot = -1
	_loose_t = 0.0
	if _rig:
		_rig.show_throne(THRONE_REST)
	_set_faces()
	request_bot_rethink()
	Fx.play(&"poof", was + Vector3.UP * 0.2, GOLD)
	Fx.play(&"respawn_sparkle", THRONE_REST + Vector3.UP * 0.2, GOLD)
	Sfx.play(&"respawn", THRONE_REST)
	crown_returned.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_scores(snapshot: PackedInt32Array) -> void:
	_apply_snapshot(snapshot)


@rpc("authority", "call_local", "reliable")
func _rpc_coronation() -> void:
	double_time = true
	if _rig:
		_rig.finale = true
	RoundUI.push_banner("CORONATION! Double points!", 2.2)
	Sfx.play(&"coin_big")
	Sfx.play(&"round_end", Vector3.INF, -6.0, 1.25)
	for lamp in _lamps:
		lamp.light_energy *= 1.25
	coronation_started.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_end(ranking: PackedInt32Array, snapshot: PackedInt32Array) -> void:
	_over = true
	_apply_snapshot(snapshot)
	final_ranking.clear()
	for s in ranking:
		final_ranking.append(s)
	var winner := _player(final_ranking[0]) if not final_ranking.is_empty() else null
	if _live(winner):
		holder_slot = winner.slot
		crown_state = CrownState.WORN
		_set_faces()
		if _rig:
			_rig.celebrate(winner)
		var vis := winner.get_component(&"visuals") as VisualsComponent
		if vis:
			vis.play_emote(&"cheer", true)
			vis.set_expression(BlobExpressions.CHEER)
		Fx.play(&"confetti", winner.global_position + Vector3.UP * 1.4)
		Sfx.play(&"round_win_jingle")
		if _camera:
			_camera.focus_on(winner, end_grace + 0.5)
		RoundUI.push_banner("%s keeps the crown!" % _name_of(winner), end_grace)
	round_over.emit(final_ranking.duplicate())


func _apply_snapshot(snapshot: PackedInt32Array) -> void:
	for s in _slots:
		var v := snapshot[s] if s >= 0 and s < snapshot.size() else 0
		if scores.get(s, -1) != v:
			scores[s] = v
			RoundUI.push_counter(s, v)
	scores_changed.emit(scores.duplicate())


# --- Every peer ----------------------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	# Tuning on every peer (only the authority's copy matters): the wearer runs a little
	# slower and cannot shove; its action button does a royal wave instead (local only).
	for p in players:
		if not is_instance_valid(p) or not _base_speed.has(p.slot):
			continue
		var wearing := p.slot == holder_slot and crown_state == CrownState.WORN and not _over
		var move := p.get_component(&"movement") as MovementComponent
		if move:
			# The size component multiplies what is written here by the size's speed factor.
			var s := _size_speed(p)
			var k := (wearer_speed_factor if wearing else lerpf(1.0, s, size_speed_share)) / s
			move.max_speed = _base_speed[p.slot] * k
		var shove := p.get_component(&"shove") as ShoveComponent
		if shove:
			shove.enabled = not wearing
		if wearing and p.is_authority() and p.intent.action_pressed and not p.frozen:
			var vis := p.get_component(&"visuals") as VisualsComponent
			if vis and vis.get_emote() == &"":
				vis.play_emote(&"wave")


## How much further `p`'s body reaches than a normal blob's (m, negative when smaller).
func _body_grow(p: Player) -> float:
	var size := p.get_component(&"size") as SizeComponent
	return BLOB_RADIUS * (size.body_scale - 1.0) if size else 0.0


## The speed factor `p`'s body size applies now (1 while frozen).
func _size_speed(p: Player) -> float:
	var size := p.get_component(&"size") as SizeComponent
	return maxf(size.factor("speed"), 0.01) if size else 1.0


## Faces: the wearer beams; everyone else watches the crown. The wearer's own hat comes off
## (so a cosmetic crown never stacks with, or passes for, the royal one) and its name tag rises
## over the crown; both come back when the crown moves on.
func _set_faces() -> void:
	var crown := _rig.crown_node() if _rig else null
	for p in players:
		if not is_instance_valid(p):
			continue
		_set_crowned(p, p.slot == holder_slot and crown_state == CrownState.WORN)
		var v := p.get_component(&"visuals") as VisualsComponent
		if v == null:
			continue
		if p.slot == holder_slot and crown_state == CrownState.WORN:
			v.set_expression(BlobExpressions.HAPPY)
			v.set_look_target(null)
		else:
			if v.get_expression() == BlobExpressions.HAPPY:
				v.set_expression(&"")
			v.set_look_target(crown)


## Every peer: `p` wears the royal crown (`on`) or not: its own hat hidden through a look
## override (only when it has one) and its name tag raised, or both restored.
func _set_crowned(p: Player, on: bool) -> void:
	var cos := p.get_component(&"cosmetics") as CosmeticsComponent
	if cos:
		if on and not _hat_hidden.has(p.slot) and not cos.has_look_override() \
				and str(cos.shown_look().get("hat", "")) != "":
			var look := cos.shown_look().duplicate(true)
			look["hat"] = ""
			cos.set_look_override(look)
			_hat_hidden[p.slot] = true
		elif not on and _hat_hidden.has(p.slot):
			_hat_hidden.erase(p.slot)
			cos.clear_look_override()
	var tag := NameTag.of(p)
	if tag:
		tag.raise = WEARER_TAG_RAISE if on else 0.0


## True while `p`'s own hat is hidden under the royal crown (tests).
func is_hat_hidden(p: Player) -> bool:
	return p != null and _hat_hidden.has(p.slot)


## Presentation, every peer, a few times a second: blobs near the crown turn to watch it
## (the wearer and the dead excepted; nearer = stronger).
func _process(delta: float) -> void:
	if not _hat_hidden.is_empty() and Session.state == Session.State.PODIUM:
		# The podium hides the crown rig: the winner gets its own hat back.
		for p in players:
			if is_instance_valid(p) and p.is_inside_tree():
				_set_crowned(p, false)
		_hat_hidden.clear()
	_interest_cd -= delta
	if _interest_cd > 0.0 or _rig == null or _rig.mode == CrownRig.Mode.HIDDEN \
			or Session.state == Session.State.PODIUM:
		return
	_interest_cd = INTEREST_EVERY
	var at := _rig.crown_position() + Vector3.UP * CROWN_CENTRE
	for p in players:
		if not _live(p) or (p.slot == holder_slot and crown_state == CrownState.WORN):
			continue
		var d := p.global_position.distance_to(at)
		if d > INTEREST_RANGE:
			continue
		var v := p.get_component(&"visuals") as VisualsComponent
		if v:
			v.set_interest_point(at, clampf(1.2 - d / INTEREST_RANGE, 0.35, 1.0))


## Hats and name tags back on every exit (round over and the stage cleared, next load).
func _exit_tree() -> void:
	for p in players:
		# Blobs leaving with the stage need nothing back (and cannot re-dress outside the tree).
		if is_instance_valid(p) and p.is_inside_tree() and not p.is_queued_for_deletion():
			_set_crowned(p, false)
	_hat_hidden.clear()


# --- Pure helpers (every peer) ----------------------------------------------------------------------------

## Floor height under (x, z): the dais steps, else 0.
static func ground_height(p: Vector3) -> float:
	var r := Vector2(p.x, p.z).length()
	if r <= DAIS_R2:
		return DAIS_H2
	if r <= DAIS_R1:
		return DAIS_H1
	return 0.0


## Distance from a point to the blob standing at `feet` (its capsule core 0.4..0.6 m up).
static func touch_distance(feet: Vector3, point: Vector3) -> float:
	var y := clampf(point.y, feet.y + 0.4, feet.y + 0.6)
	return point.distance_to(Vector3(feet.x, y, feet.z))


## Pushes `p` (XZ) inside the octagon of apothem `apo` (faces at k * 45 degrees from +Z).
static func clamp_octagon(p: Vector3, apo: float) -> Vector3:
	var out := p
	for _pass in 2:
		for k in 8:
			var a := k * PI / 4.0
			var n := Vector3(sin(a), 0.0, cos(a))
			var d := out.dot(n)
			if d > apo:
				out -= n * (d - apo)
	return out


## True when (x, z) of `p` is inside the octagon of apothem `apo`.
static func in_octagon(p: Vector3, apo: float) -> bool:
	for k in 8:
		var a := k * PI / 4.0
		if p.x * sin(a) + p.z * cos(a) > apo:
			return false
	return true


## A resting spot for the crown near `p`: inside the room, off the pillars and the throne.
static func clamp_landing(p: Vector3) -> Vector3:
	var out := clamp_octagon(Vector3(p.x, 0.0, p.z), LAND_APOTHEM)
	out = _push_off_obstacles(out, 0.45)
	return clamp_octagon(out, LAND_APOTHEM)


static func _push_off_obstacles(p: Vector3, margin: float) -> Vector3:
	var out := p
	for c in PILLARS:
		var off := Vector2(out.x - c.x, out.z - c.z)
		var min_d := PILLAR_HALF * 1.42 + margin
		if off.length() < min_d:
			off = (off.normalized() if off.length() > 0.01 else Vector2(c.x, c.z).normalized()) * min_d
			out = Vector3(c.x + off.x, 0.0, c.z + off.y)
	var lx := THRONE_HALF_X + margin
	var z0 := THRONE_POS.z + THRONE_Z_MIN - margin
	var z1 := THRONE_POS.z + THRONE_Z_MAX + margin
	if absf(out.x) < lx and out.z > z0 and out.z < z1:
		# Out through the nearest side (front, back or a flank).
		var dx := lx - absf(out.x)
		var dz0 := out.z - z0
		var dz1 := z1 - out.z
		if dx <= dz0 and dx <= dz1:
			out.x = signf(out.x if absf(out.x) > 0.001 else 1.0) * lx
		elif dz1 <= dz0:
			out.z = z1
		else:
			out.z = z0
	return out


## `slots` by points (desc), then whoever wore the crown last (later first), as groups best
## first (`Minigame.finish` form): slots equal on both (e.g. no points, never wore it) share one
## tied group, never ordered by slot (members listed in slot order).
static func rank_by_points(slots: Array[int], points: Dictionary, last_worn: Dictionary) -> Array:
	var out: Array[int] = slots.duplicate()
	var key := func(s: int) -> Vector2: return Vector2(int(points.get(s, 0)), float(last_worn.get(s, -1.0)))
	out.sort_custom(func(a: int, b: int) -> bool:
		var ka: Vector2 = key.call(a)
		var kb: Vector2 = key.call(b)
		if ka.x != kb.x:
			return ka.x > kb.x
		if ka.y != kb.y:
			return ka.y > kb.y
		return a < b)
	var groups: Array = []
	for i in out.size():
		if i > 0 and key.call(out[i]) == key.call(out[i - 1]):
			(groups[groups.size() - 1] as Array).append(out[i])
		else:
			var g: Array[int] = [out[i]]
			groups.append(g)
	return groups


# --- Bots ------------------------------------------------------------------------------------------------

## Wearer: flee. Others: chase the wearer, or run for the loose crown / the throne.
func get_bot_goal(player: Player) -> Vector3:
	if player == null or not player.alive:
		return Vector3.ZERO
	match crown_state:
		CrownState.WORN:
			var h := _player(holder_slot)
			if not _live(h):
				return _throne_goal(player)
			if h == player:
				return _flee_goal(player)
			return _chase_goal(player, h)
		CrownState.LOOSE:
			return _safe_point(_launch_l2)
	return _throne_goal(player)


## Inside the walls, off the pillars and the throne.
func is_safe(pos: Vector3) -> bool:
	if not in_octagon(pos, SAFE_APOTHEM):
		return false
	for c in PILLARS:
		if Vector2(pos.x - c.x, pos.z - c.z).length() < 0.8:
			return false
	if pos.y < THRONE_POS.y + 0.4 and absf(pos.x) < THRONE_HALF_X + 0.3 \
			and pos.z > THRONE_POS.z + THRONE_Z_MIN - 0.3 and pos.z < THRONE_POS.z + THRONE_Z_MAX + 0.3:
		return false
	return true


## The upper step next to the throne, on the bot's own side (front, back or flank).
func _throne_goal(me: Player) -> Vector3:
	var flat := Vector2(me.global_position.x, me.global_position.z)
	var dir := flat.normalized() if flat.length() > 0.1 else Vector2(0.0, 1.0)
	var goal := Vector3(dir.x, 0.0, dir.y) * 1.35
	if absf(goal.x) < THRONE_HALF_X + 0.35 and goal.z < THRONE_POS.z:
		goal.z = minf(goal.z, THRONE_POS.z + THRONE_Z_MIN - 0.45)
	return _safe_point(goal)


func _chase_goal(me: Player, h: Player) -> Vector3:
	# Each bot leads the wearer by its own amount, so they come at it from different sides.
	# Salted per round: unsalted, a slot led by the same amounts every round.
	if _taste_salt < 0:
		_taste_salt = rng.randi() % 1000003
	var lead := 0.2 + 0.35 * _hash01(me.slot * 7919 + crown_changes * 104729 + _taste_salt)
	var aim := h.global_position + h.velocity * lead
	var to := aim - me.global_position
	to.y = 0.0
	if to.length() > 0.01:
		aim += to.normalized() * chase_overshoot  # run through them, not up to them
	return _safe_point(aim)


func _flee_goal(me: Player) -> Vector3:
	var threats: Array[Vector2] = []
	for p in players:
		if p != me and _live(p):
			threats.append(Vector2(p.global_position.x, p.global_position.z))
	var mine := Vector2(me.global_position.x, me.global_position.z)
	if threats.is_empty():
		return me.global_position
	var candidates: Array[Vector3] = []
	var cover: Array[bool] = []
	for ring: float in [4.6, 7.4]:
		for i in 12:
			var a := TAU * (i + (0.5 if ring < 5.0 else 0.0)) / 12.0
			candidates.append(Vector3(sin(a), 0.0, cos(a)) * ring)
			cover.append(false)
	# Behind each pillar (and the dais), seen from the nearest chaser.
	var nearest := threats[0]
	for t in threats:
		if t.distance_to(mine) < nearest.distance_to(mine):
			nearest = t
	for c in PILLARS + [Vector3.ZERO]:
		var away := Vector2(c.x, c.z) - nearest
		if away.length() < 0.1:
			continue
		var reach := 1.5 if c != Vector3.ZERO else DAIS_R1 + 0.9
		var spot := Vector2(c.x, c.z) + away.normalized() * reach
		candidates.append(Vector3(spot.x, 0.0, spot.y))
		cover.append(true)
	var best := me.global_position
	var best_score := -INF
	for i in candidates.size():
		var c3 := _safe_point(candidates[i])
		var c2 := Vector2(c3.x, c3.z)
		var closest := INF
		var sum := 0.0
		var route := 0.0
		for t in threats:
			var d := c2.distance_to(t)
			closest = minf(closest, d)
			sum += minf(d, 10.0)
			# Do not run past a chaser to get there.
			var seg := Geometry2D.get_closest_point_to_segment(t, mine, c2)
			if seg.distance_to(t) < 1.8 and c2.distance_to(mine) > 1.0 and t.distance_to(mine) < 6.0:
				route += 3.0
		var score := closest + 0.3 * sum / threats.size() - 0.3 * c2.distance_to(mine) - route
		if cover[i]:
			score += 0.8
		if score > best_score:
			best_score = score
			best = c3
	return best


## Inside the safe octagon, off the obstacles.
func _safe_point(p: Vector3) -> Vector3:
	var out := clamp_octagon(Vector3(p.x, 0.0, p.z), SAFE_APOTHEM - 0.4)
	out = _push_off_obstacles(out, 0.55)
	return clamp_octagon(out, SAFE_APOTHEM - 0.4)


static func _hash01(n: int) -> float:
	var h := (n * 2654435761) & 0xffffffff
	h = ((h >> 16) ^ h) * 0x45d9f3b & 0xffffffff
	h = ((h >> 16) ^ h) & 0xffffffff
	return float(h % 10007) / 10007.0


# --- Helpers ---------------------------------------------------------------------------------------------

func _player(slot: int) -> Player:
	if slot < 0:
		return null
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _live(p: Player) -> bool:
	return p != null and is_instance_valid(p) and p.is_inside_tree() and p.alive


func _name_of(p: Player) -> String:
	return p.display_name if p.display_name != "" else "Player %d" % (p.slot + 1)


# --- Room ---------------------------------------------------------------------------------------------------

func _build_room() -> void:
	var room := Node3D.new()
	room.name = "Room"
	add_child(room)
	var body := StaticBody3D.new()
	body.name = "RoomBody"
	body.collision_mask = 0
	room.add_child(body)

	# A dark surround so the camera never sees under the room past the low front rails.
	var surround := MeshInstance3D.new()
	surround.name = "Surround"
	var plane := PlaneMesh.new()
	plane.size = Vector2(90.0, 90.0)
	surround.mesh = plane
	surround.material_override = Look.toon_material(Color("#1b1424"), 0.9, false)
	surround.position.y = -0.2
	room.add_child(surround)

	_prop(room, PROPS, "crown_floor", Vector3.ZERO, 0.0, false)
	_box(body, Vector3(0.0, -0.25, 0.0), Vector3(24.0, 0.5, 24.0))

	# Walls: the five far sides are full mansion walls with banners; the three near sides
	# (toward the camera) are low rails so they never hide the floor. Colliders are 3 m tall.
	for k in 8:
		var theta := k * 45.0
		var a := deg_to_rad(theta)
		var n := Vector3(sin(a), 0.0, cos(a))
		var t := Vector3(cos(a), 0.0, -sin(a))
		var centre := n * (APOTHEM + 0.15)
		var yaw := theta + 180.0
		var near := k == 0 or k == 1 or k == 7
		var pieces: Array[String] = ["wall_4m", "wall_4m"]
		if near:
			pieces = ["balcony_rail_4m", "balcony_rail_4m"]
		elif k == 2 or k == 6:
			pieces = ["wall_4m", "wall_window"]
		elif k == 3 or k == 5:
			pieces = ["wall_window", "wall_4m"]
		for i in 2:
			_prop(room, ENV, pieces[i], centre + t * (-2.0 if i == 0 else 2.0), yaw)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(8.4, 3.0, 0.3)
		cs.shape = box
		cs.position = centre + Vector3.UP * 1.5
		cs.rotation.y = a
		body.add_child(cs)
		if not near:
			var banner := _prop(room, PROPS, "crown_banner", centre - n * 0.25 + Vector3.UP * 1.45, yaw)
			banner.name = "Banner%d" % k
	# Corner columns where full walls meet.
	var rv := (APOTHEM + 0.15) / cos(PI / 8.0)
	for k in 8:
		var a := deg_to_rad(22.5 + k * 45.0)
		if k == 0 or k == 7:
			continue  # between two rails
		_prop(room, ENV, "wall_corner", Vector3(sin(a), 0.0, cos(a)) * rv, rad_to_deg(a))

	# Dais, throne, pillars.
	_prop(room, PROPS, "crown_dais", Vector3.ZERO, 0.0)
	_cylinder(body, Vector3.ZERO, DAIS_R1, DAIS_H1)
	_cylinder(body, Vector3.ZERO, DAIS_R2, DAIS_H2)
	_prop(room, PROPS, "crown_throne", THRONE_POS, 0.0)
	_box(body, THRONE_POS + Vector3(0.0, THRONE_SEAT * 0.5, 0.0), Vector3(1.4, THRONE_SEAT, 1.0))
	for sx: float in [-1.0, 1.0]:
		_box(body, THRONE_POS + Vector3(sx * 0.63, 0.7, 0.08), Vector3(0.2, 0.26, 0.78))
	_box(body, THRONE_POS + Vector3(0.0, 1.07, -0.39), Vector3(1.4, 1.9, 0.22))
	for c in PILLARS:
		_prop(room, ENV, "pillar", c, 0.0)
		_box(body, c + Vector3.UP * 2.5, Vector3(PILLAR_HALF * 2.0, 5.0, PILLAR_HALF * 2.0))

	# Decor along the far walls: knights flanking the throne side, candelabras.
	for sx: float in [-1.0, 1.0]:
		_prop(room, ENV, "suit_of_armour", Vector3(sx * 2.6, 0.0, -APOTHEM + 0.55), 0.0)
		var side := Vector3(sx * (APOTHEM - 0.45), 0.0, -1.2)
		_prop(room, ENV, "candelabra", side, -90.0 * sx)
		_box(body, side + Vector3.UP * 0.7, Vector3(0.4, 1.4, 0.7))
		_box(body, Vector3(sx * 2.6, 1.0, -APOTHEM + 0.55), Vector3(0.8, 2.0, 0.7))

	# Light: warm lamps round the room, a gold spot on the throne.
	var lights := Node3D.new()
	lights.name = "Lights"
	room.add_child(lights)
	for pos: Vector3 in [Vector3(-6.0, 4.2, -4.0), Vector3(6.0, 4.2, -4.0), Vector3(-6.0, 4.2, 4.5), Vector3(6.0, 4.2, 4.5)]:
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.78, 0.5)
		lamp.light_energy = 1.6
		lamp.omni_range = 10.0
		lamp.position = pos
		lights.add_child(lamp)
		_lamps.append(lamp)
	var spot := SpotLight3D.new()
	spot.name = "ThroneSpot"
	spot.light_color = Color(1.0, 0.85, 0.55)
	spot.light_energy = 6.0
	spot.spot_range = 14.0
	spot.spot_angle = 18.0
	spot.shadow_enabled = false
	lights.add_child(spot)
	spot.look_at_from_position(Vector3(0.0, 9.0, 3.0), THRONE_REST, Vector3.UP)


func _prop(parent: Node3D, dir: String, piece: String, pos: Vector3, yaw_deg: float, outline: bool = true) -> Node3D:
	var scene := load(dir + piece + ".glb") as PackedScene
	if scene == null:
		push_error("crown_keeper: missing model %s" % piece)
		return Node3D.new()
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation_degrees.y = yaw_deg
	parent.add_child(n)
	Look.apply_toon(n, outline)
	return n


func _box(body: StaticBody3D, centre: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = centre
	body.add_child(cs)


func _cylinder(body: StaticBody3D, at: Vector3, radius: float, height: float) -> void:
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	var cs := CollisionShape3D.new()
	cs.shape = cyl
	cs.position = at + Vector3.UP * height * 0.5
	body.add_child(cs)
