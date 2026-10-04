class_name HideAndSneak
extends Minigame
## Hide and Sneak: prop hunt in a cluttered parlour. 1 seeker (2 with 6+ players); everyone
## else is a hider disguised as a piece of furniture (the blob model is hidden and the prop
## model rides on the player, on every peer; no name tag, no blob shadow).
##
## HIDE (12 s): seekers wait in the closet behind the back wall, frozen, their screen blacked
##   out ("No peeking!", their own peer only). Hiders shuffle into place at 35 % speed, no jump,
##   no shove; `action` cycles their disguise to the next kind.
## SEEK (60 s): seekers burst out of the closet door at 110 % speed; `action` is a POKE (short
##   reach, 0.8 s cooldown) the host resolves against synced positions. A disguised hider is
##   revealed (prop pops off, blob, yelp) and caught: `knock_out` reason `found`. A real prop
##   jiggles and costs one poke (budget per seeker: poke_base + poke_per_hider * hiders); out of
##   pokes, one comes back every refill_time s. Every rustle_interval s every hider shivers and
##   rustles (sound at its spot); in the last glow_time s hiders glow faintly through walls on
##   the seekers' screens. A moving prop wobbles: that is the tell.
## HUD counter: pokes left for seekers, seconds survived for hiders.
##
## RANKING (finish(groups, 2.0), tied groups):
##   1. hiders never found (survivors) share first place, one tied group;
##   2. then the seekers, by finds (most first; equal finds = one tied group);
##   3. then the caught hiders, by seconds survived (longest first; equal = tied).
##   So a seeker who finds every hider (no survivors) ranks above everyone. The round ends at
##   time-out, when the last hider is found, or when no seeker is left.
##
## Roles rotate: the host remembers (static, app lifetime) who sought last time and how often
## each slot has sought, and picks the least-used slots, never last round's seekers if avoidable.
##
## Host decides everything and tells every peer through reliable call_local RPCs (layout seed,
## roles, disguise kinds, phases, pokes, reveals, rustles, glow, the end); presentation and
## tuning run on every peer from that state. Clients send their own `action` presses to the
## host (`_rpc_action`). Bots: hiders walk to a spot beside furniture of their own kind and
## keep still (rare shuffles); seekers keep a noisy suspicion per prop (movement they saw,
## rustles they heard, hunches, the glow) and poke the most suspicious one in reach.
## Dev args (after `--`): `--hide-seekers=a,b` force seekers, `--hide-seed=<n>` layout,
## `--hide-time-scale=<x>` host clocks, `--hide-time=<s>` HIDE length, `--hide-reveal-at=<s>`
## reveal the hider nearest to a seeker at SEEK second s (screenshots). Quality: `--quality=`.

signal phase_changed(phase: int)
signal disguise_changed(slot: int, kind: int)
## Every peer: seeker `slot` poked. `target` PokeTarget, `id` furniture id or hider slot.
signal poked(slot: int, target: int, id: int)
## Every peer: `slot` was found by `seeker_slot` after `survived` seconds of SEEK.
signal revealed(slot: int, seeker_slot: int, survived: float)
## Every peer: the hiders rustled (`index`: 1, 2, ...).
signal rustled(index: int)

enum Phase { SETUP, HIDE, SEEK, OVER }
enum PokeTarget { NONE, FURNITURE, HIDER }

const SEEK_TRACK := &"lava_drums"
## Hider bots keep at least this far from each other's spots (their personal space is 1.8 m).
const SPOT_SPACING := 1.9

# --- Rules (host) ----------------------------------------------------------------------------
@export var hide_time: float = 12.0
@export var seek_time: float = 60.0
## Speed factors on the base movement speed.
@export var hider_speed: float = 0.35
@export var seeker_speed: float = 1.1
## A poke reaches this far past the target's footprint (m), within POKE_CONE of the aim.
@export var poke_reach: float = 0.9
@export var poke_cooldown: float = 0.8
## Pokes per seeker: poke_base + poke_per_hider * hiders / seekers (rounded up): two seekers
## share the per-hider part.
@export var poke_base: int = 3
@export var poke_per_hider: int = 2
@export var refill_time: float = 10.0
@export var rustle_interval: float = 15.0
@export var glow_time: float = 10.0
## Seconds the revealed blob stands there before it is knocked out.
@export var reveal_delay: float = 0.7
const POKE_CONE_DEG := 75.0

## Round music: the calm hall jazz, ducked to a murmur while hiding; SEEK cross-fades to
## SEEK_TRACK itself.
var music_track := &"vault_jazz"
## How far the music is ducked during HIDE (0..1 of its volume).
const HIDE_DUCK := 0.75
## Bots never chase or shove here (BotBrain hint).
var bot_aggression_scale: float = 0.0

## Test/dev: multiplies the host's clocks (phases, cooldowns, refills).
var time_scale: float = 1.0
## Host randomness (layout seed, roles, kinds). Tests may seed it.
var rng := RandomNumberGenerator.new()
## Host randomness of the bots (spots, suspicion noise). Tests may seed it.
var bot_rng := RandomNumberGenerator.new()
## Test/dev: the host AI also pokes for human seekers (bot-only test rounds).
var ai_humans: bool = false

# --- State (every peer, from the host's RPCs) ------------------------------------------------
var phase: Phase = Phase.SETUP
var seekers: Array[int] = []
## Hiders of this round (found or not).
var hider_slots: Array[int] = []
## slot -> disguise kind, for every hider still disguised.
var disguises: Dictionary[int, int] = {}
var pokes_left: Dictionary[int, int] = {}
var finds: Dictionary[int, int] = {}
## Found hiders: slot -> seconds of SEEK they survived.
var caught_time: Dictionary[int, float] = {}
var glow_on: bool = false
var rustle_count: int = 0

# --- Host state ------------------------------------------------------------------------------
var _clock: float = 0.0
var _seek_clock: float = 0.0
var _cooldown: Dictionary[int, float] = {}
var _refill: Dictionary[int, float] = {}
var _pending: Array[Array] = []        # [slot, seconds left] reveals waiting for their knock-out
var _forced_seekers: Array[int] = []
var _forced_seed: int = -1
var _forced_reveal_at: float = -1.0
var _grid: AStarGrid2D = null
var _spots: Dictionary[int, Vector3] = {}
var _shuffle_at: Dictionary[int, float] = {}
var _minds: Dictionary[int, SeekerMind] = {}
var _last_poke_id: int = -1

# --- Every peer: presentation / tuning ---------------------------------------------------------
var _base: Dictionary[int, Dictionary] = {}   # slot -> {speed, jump, shove}
var _phase_age: float = 0.0
var _local_seek: float = 0.0
var _shown_seconds: Dictionary[int, int] = {}
var _room: HideRoom = null
var _blackout: CanvasLayer = null
var _blackout_label: Label = null

## Tests: when >= 0, the next instance seeds `rng` / `bot_rng` from it in _ready (before
## _setup draws the layout and the roles), then it resets to -1.
static var test_seed: int = -1
## App lifetime: who sought last time this minigame ran, and how often each slot has sought.
static var _last_seekers: Array[int] = []
static var _seek_count: Dictionary = {}


## A seeker bot's memory (host).
class SeekerMind:
	var suspicion: Dictionary = {}   # candidate key -> float
	var known: Dictionary = {}       # furniture id -> true (poked: real)
	var last_seen: Dictionary = {}   # hider slot -> Vector3
	var target: int = -1             # candidate key, -1 none
	var patrol: Vector3 = Vector3.INF
	var patrol_left: float = 0.0
	var observe_left: float = 0.0


func _ready() -> void:
	rng.randomize()
	bot_rng.randomize()
	if test_seed >= 0:
		rng.seed = test_seed
		bot_rng.seed = test_seed * 7919 + 1
		test_seed = -1
	_room = HideRoom.new()
	_room.name = "Room"
	add_child(_room)
	_build_blackout()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hide-seekers="):
			for s in arg.trim_prefix("--hide-seekers=").split(",", false):
				_forced_seekers.append(int(s))
		elif arg.begins_with("--hide-seed="):
			_forced_seed = int(arg.trim_prefix("--hide-seed="))
		elif arg.begins_with("--hide-time-scale="):
			time_scale = maxf(arg.trim_prefix("--hide-time-scale=").to_float(), 0.01)
		elif arg.begins_with("--hide-time="):
			hide_time = maxf(arg.trim_prefix("--hide-time=").to_float(), 0.2)
		elif arg.begins_with("--hide-reveal-at="):
			_forced_reveal_at = arg.trim_prefix("--hide-reveal-at=").to_float()


func _exit_tree() -> void:
	for p in players:
		if is_instance_valid(p):
			_undisguise(p, false)
			_restore_tuning(p)
			_set_tags(p, true)


# --- Flow ----------------------------------------------------------------------------------------

func _setup(setup_players: Array[Player]) -> void:
	_base.clear()
	for p in setup_players:
		var move := p.get_component(&"movement") as MovementComponent
		var jump := p.get_component(&"jump") as JumpComponent
		var shove := p.get_component(&"shove") as ShoveComponent
		_base[p.slot] = {
			"speed": move.max_speed if move else 6.0,
			"jump": jump.jump_enabled if jump else true,
			"shove": shove.enabled if shove else true,
		}
	if not _is_host():
		return
	var slots: Array[int] = []
	for p in setup_players:
		slots.append(p.slot)
	var chosen := _forced_pick(slots)
	if chosen.is_empty():
		chosen = pick_seekers(slots, rng)
	var hiders: Array[int] = []
	for s in slots:
		if not chosen.has(s):
			hiders.append(s)
	var seed_value := _forced_seed if _forced_seed >= 0 else rng.randi()
	var layout := HideLayout.generate(seed_value)
	var kinds: Array[int] = []
	for s in hiders:
		kinds.append(_pick_kind(layout))
	_rpc_setup.rpc(seed_value, chosen, hiders, kinds)
	for s in chosen:
		set_role_text(s, "You are the SEEKER: poke the furniture that isn't!")
	for s in hiders:
		set_role_text(s, "You HIDE: you are furniture now. Keep still!")
	_plan_bots()


func _start() -> void:
	# Session just unfroze everyone: the seekers stay shut in the closet.
	for p in players:
		if is_instance_valid(p) and seekers.has(p.slot):
			p.frozen = true
	if _is_host():
		_clock = 0.0
		_rpc_phase.rpc(Phase.HIDE)
		if hider_slots.is_empty() or seekers.is_empty():
			_end_round()


func _host_tick(delta: float) -> void:
	if is_finished():
		return
	var dt := delta * time_scale
	_clock += dt
	match phase:
		Phase.HIDE:
			if _clock >= hide_time:
				_clock = 0.0
				_seek_clock = 0.0
				_rpc_phase.rpc(Phase.SEEK)
				_begin_seek_minds()
				request_bot_rethink()
		Phase.SEEK:
			_seek_clock = _clock
			_tick_seek(dt)


func _tick_seek(dt: float) -> void:
	for s: int in _cooldown.keys():
		_cooldown[s] = _cooldown[s] - dt
	for s: int in _refill.keys():
		_refill[s] = _refill[s] - dt
		if _refill[s] <= 0.0:
			_refill.erase(s)
			_set_pokes(s, pokes_left.get(s, 0) + 1)
	if rustle_interval > 0.0 and _seek_clock >= rustle_interval * (rustle_count + 1) and _seek_clock < seek_time - 0.5:
		_rpc_rustle.rpc(rustle_count + 1)
		_minds_hear_rustle()
	if not glow_on and _seek_clock >= seek_time - glow_time:
		_rpc_glow.rpc()
	if _forced_reveal_at >= 0.0 and _seek_clock >= _forced_reveal_at:
		_forced_reveal_at = -1.0
		_force_reveal()
	_tick_hider_bots()
	_tick_seeker_bots(dt)
	if is_finished():
		return
	if _seek_clock >= seek_time:
		_end_round()
		return
	var seeker_left := false
	for s in seekers:
		var p := _player(s)
		if p and p.alive:
			seeker_left = true
	if not seeker_left or _hiders_left().is_empty():
		_end_round()


func _physics_process(delta: float) -> void:
	# Tuning on every peer (only the authority's copy matters).
	for p in players:
		if is_instance_valid(p):
			_apply_tuning(p)
	# This peer's own players: `action` goes to the host (cycle disguise / poke).
	if phase == Phase.HIDE or phase == Phase.SEEK:
		for p in players:
			if not is_instance_valid(p) or not p.alive or p.frozen or not p.is_authority():
				continue
			var c := p.get_component(&"controller") as ControllerComponent
			if p.is_bot and not (c and c.scripted):
				continue
			if p.intent.action_pressed:
				_request_action(p.slot)
	if _is_host():
		_tick_pending(delta * time_scale)


func _process(delta: float) -> void:
	_phase_age += delta
	if phase == Phase.SEEK:
		_local_seek += delta * time_scale
	if _blackout and _blackout.visible and _blackout_label:
		var left := maxi(0, int(ceil(hide_time / maxf(time_scale, 0.01) - _phase_age)))
		_blackout_label.text = "No peeking!\nThe others are hiding... %d" % left
	# Hiders' counters: whole seconds survived.
	if phase == Phase.SEEK:
		for s in hider_slots:
			if caught_time.has(s):
				continue
			var sec := int(_local_seek)
			if _shown_seconds.get(s, -1) != sec:
				_shown_seconds[s] = sec
				RoundUI.push_counter(s, sec)


## Host: ends the round with the ranking rule (see the header) after revealing everyone.
func _end_round() -> void:
	if is_finished():
		return
	var survivors := _hiders_left()
	var ranking := compute_ranking(survivors, seekers, finds, caught_time)
	finish(ranking, 2.0)


## Every exit through finish (ours, or Session's time-limit backstop): reveal everyone first.
func finish(ranking: Array, grace: float = 0.0) -> void:
	if is_finished():
		return
	if _is_host():
		_rpc_end.rpc()
	super(ranking, grace)


# --- Rules (static, tested) -------------------------------------------------------------------------

## Seekers for `count` players: 1 for up to 5, 2 for 6 and more.
static func seeker_count(count: int) -> int:
	return 2 if count >= 6 else 1


## Host: picks the seekers among `slots`: the slots that sought least often this app session,
## avoiding last time's seekers when possible, random among equals. Remembers the pick.
static func pick_seekers(slots: Array[int], r: RandomNumberGenerator) -> Array[int]:
	var n := mini(seeker_count(slots.size()), slots.size())
	var order: Array[int] = slots.duplicate()
	var roll: Dictionary = {}
	for s in order:
		roll[s] = r.randf()
	order.sort_custom(func(a: int, b: int) -> bool:
		var ca: int = _seek_count.get(a, 0)
		var cb: int = _seek_count.get(b, 0)
		if ca != cb:
			return ca < cb
		var la := _last_seekers.has(a)
		var lb := _last_seekers.has(b)
		if la != lb:
			return lb
		return roll[a] < roll[b])
	var out: Array[int] = order.slice(0, n)
	out.sort()
	remember_seekers(out)
	return out


static func remember_seekers(chosen: Array[int]) -> void:
	_last_seekers = chosen.duplicate()
	for s in chosen:
		_seek_count[s] = int(_seek_count.get(s, 0)) + 1


## Tests: forget the rotation.
static func reset_rotation() -> void:
	_last_seekers.clear()
	_seek_count.clear()


static func last_seekers() -> Array[int]:
	return _last_seekers.duplicate()


## The round's ranking as tied groups (see the header): survivors, seekers by finds, caught
## hiders by seconds survived.
static func compute_ranking(survivors: Array[int], seeker_slots: Array[int], seeker_finds: Dictionary,
		caught: Dictionary) -> Array:
	var groups: Array = []
	var top: Array[int] = survivors.duplicate()
	top.sort()
	if not top.is_empty():
		groups.append(top)
	var by_finds: Array[int] = seeker_slots.duplicate()
	by_finds.sort_custom(func(a: int, b: int) -> bool:
		var fa: int = seeker_finds.get(a, 0)
		var fb: int = seeker_finds.get(b, 0)
		return fa > fb if fa != fb else a < b)
	_group_by(groups, by_finds, func(s: int) -> float: return float(seeker_finds.get(s, 0)))
	var by_time: Array[int] = []
	for s: int in caught:
		if not survivors.has(s) and not seeker_slots.has(s):
			by_time.append(s)
	by_time.sort_custom(func(a: int, b: int) -> bool:
		var ta: float = caught[a]
		var tb: float = caught[b]
		return ta > tb if absf(ta - tb) > 0.001 else a < b)
	_group_by(groups, by_time, func(s: int) -> float: return float(caught[s]))
	return groups


static func _group_by(groups: Array, ordered: Array[int], value: Callable) -> void:
	var current: Array[int] = []
	var current_v := 0.0
	for s in ordered:
		var v: float = value.call(s)
		if not current.is_empty() and absf(v - current_v) > 0.001:
			groups.append(current)
			current = []
		if current.is_empty():
			current_v = v
		current.append(s)
	if not current.is_empty():
		groups.append(current)


## Starting pokes of each seeker for `hiders` hiders and `seeker_total` seekers.
func poke_budget(hiders: int, seeker_total: int = 1) -> int:
	return poke_base + int(ceil(float(poke_per_hider * hiders) / maxi(seeker_total, 1)))


# --- Host: actions -----------------------------------------------------------------------------

func _request_action(slot: int) -> void:
	if _is_host():
		_handle_action(slot)
	else:
		_rpc_action.rpc_id(1, slot)


## Client -> host: player `slot` pressed action. Only the peer simulating that slot may send it.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_action(slot: int) -> void:
	if not _is_host():
		return
	var info: Variant = Net.roster.get(slot)
	if info == null or (info as PlayerInfo).peer_id != multiplayer.get_remote_sender_id():
		return
	_handle_action(slot)


func _handle_action(slot: int) -> void:
	if is_finished():
		return
	if phase == Phase.HIDE and disguises.has(slot):
		cycle_disguise(slot)
	elif phase == Phase.SEEK and seekers.has(slot):
		poke(slot)


## Host: hider `slot` switches to the next disguise kind (HIDE only).
func cycle_disguise(slot: int) -> void:
	if phase != Phase.HIDE or not disguises.has(slot):
		return
	_rpc_kind.rpc(slot, (disguises[slot] + 1) % HideLayout.kind_count())


## Host: seeker `slot` pokes toward `aim` (a world point; INF = along its facing). Returns the
## PokeTarget it hit (NONE also when it may not poke now: cooldown, no pokes left, wrong phase).
func poke(slot: int, aim: Vector3 = Vector3.INF) -> int:
	var p := _player(slot)
	if is_finished() or phase != Phase.SEEK or not seekers.has(slot) or p == null or not p.alive or p.frozen:
		return PokeTarget.NONE
	if _cooldown.get(slot, 0.0) > 0.0 or pokes_left.get(slot, 0) <= 0:
		return PokeTarget.NONE
	_cooldown[slot] = poke_cooldown
	var hit := resolve_poke(p.global_position, _aim_dir(p, aim))
	var target: int = hit[0]
	var id: int = hit[1]
	var at: Vector3 = hit[2]
	_last_poke_id = id
	_rpc_poke.rpc(slot, target, id, at)
	if target == PokeTarget.FURNITURE:
		_set_pokes(slot, pokes_left.get(slot, 0) - 1)
		if pokes_left[slot] <= 0:
			_refill[slot] = refill_time
	elif target == PokeTarget.HIDER:
		_reveal(id, slot)
	return target


func _aim_dir(p: Player, aim: Vector3) -> Vector3:
	var dir := p.facing
	if aim != Vector3.INF:
		dir = aim - p.global_position
	dir.y = 0.0
	return dir.normalized() if dir.length_squared() > 0.0001 else Vector3.BACK


## Host: what a poke from `from` along `dir` hits: [PokeTarget, furniture id / hider slot, point].
## Disguised hiders (synced positions) and furniture within poke_reach of their footprint and
## POKE_CONE_DEG of `dir`; the nearest (angle-weighted) wins.
func resolve_poke(from: Vector3, dir: Vector3) -> Array:
	var best: Array = [PokeTarget.NONE, -1, from + dir * 1.0]
	var best_score := INF
	var cone := deg_to_rad(POKE_CONE_DEG)
	for s: int in disguises:
		var h := _player(s)
		if h == null or not h.alive or caught_time.has(s):
			continue
		var sc := _poke_score(from, dir, h.global_position, 0.42, cone)
		if sc < best_score:
			best_score = sc
			best = [PokeTarget.HIDER, s, h.global_position]
	for i in _room.furniture.size():
		var f := _room.furniture[i]
		var pos: Vector3 = f["pos"]
		var sc := _poke_score(from, dir, pos, HideLayout.kind_radius(int(f["kind"])), cone)
		if sc < best_score:
			best_score = sc
			best = [PokeTarget.FURNITURE, i, pos]
	return best


func _poke_score(from: Vector3, dir: Vector3, at: Vector3, radius: float, cone: float) -> float:
	var to := Vector3(at.x - from.x, 0.0, at.z - from.z)
	var edge := to.length() - radius
	if edge > poke_reach:
		return INF
	var ang := 0.0 if to.length() < 0.05 else dir.angle_to(to.normalized())
	if ang > cone:
		return INF
	return maxf(edge, 0.0) + ang * 0.6


func _set_pokes(slot: int, value: int) -> void:
	_rpc_pokes.rpc(slot, maxi(value, 0))


## Host: hider `slot` is found by `seeker_slot`.
func _reveal(slot: int, seeker_slot: int) -> void:
	if caught_time.has(slot):
		return
	var survived := _seek_clock
	_rpc_reveal.rpc(slot, seeker_slot, survived, finds.get(seeker_slot, 0) + 1)
	_pending.append([slot, reveal_delay])
	for m: SeekerMind in _minds.values():
		m.suspicion.erase(_hider_key(slot))
		if m.target == _hider_key(slot):
			m.target = -1
	request_bot_rethink()
	if _hiders_left().is_empty():
		_end_round()


## Host: revealed hiders are knocked out after their moment on stage.
func _tick_pending(dt: float) -> void:
	for i in range(_pending.size() - 1, -1, -1):
		_pending[i][1] = float(_pending[i][1]) - dt
		if float(_pending[i][1]) > 0.0:
			continue
		var p := _player(int(_pending[i][0]))
		_pending.remove_at(i)
		if p == null or not p.alive:
			continue
		if is_finished():
			# The round is decided already (knock_out would ignore it): just take the blob out.
			if not knocked_out.has(p.slot):
				knocked_out.append(p.slot)
			p.eliminate(&"found")
		else:
			knock_out(p, &"found")


## Dev: reveal the hider nearest to a seeker (screenshots).
func _force_reveal() -> void:
	for s in seekers:
		var sp := _player(s)
		if sp == null:
			continue
		var best := -1
		var best_d := INF
		for h: int in _hiders_left():
			var hp := _player(h)
			if hp:
				var d := hp.global_position.distance_to(sp.global_position)
				if d < best_d:
					best_d = d
					best = h
		if best >= 0:
			_rpc_poke.rpc(s, PokeTarget.HIDER, best, _player(best).global_position)
			_reveal(best, s)
			return


# --- RPCs (host -> every peer) -------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_setup(seed_value: int, seeker_list: Array, hiders: Array, kinds: Array) -> void:
	_room.build_furniture(seed_value)
	seekers.clear()
	for s: Variant in seeker_list:
		seekers.append(int(s))
	hider_slots.clear()
	disguises.clear()
	for i in hiders.size():
		hider_slots.append(int(hiders[i]))
	var budget := poke_budget(hider_slots.size(), seekers.size())
	for i in seekers.size():
		var p := _player(seekers[i])
		pokes_left[seekers[i]] = budget
		finds[seekers[i]] = 0
		RoundUI.push_counter(seekers[i], budget)
		if p:
			var spot := HideLayout.CLOSET_SPOTS[i % HideLayout.CLOSET_SPOTS.size()]
			p.place_at(Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP, true), spot))
			p.frozen = true
	for i in hider_slots.size():
		var p := _player(hider_slots[i])
		var kind: int = int(kinds[i]) if i < kinds.size() else 0
		if p:
			_disguise(p, kind)
		RoundUI.push_counter(hider_slots[i], 0)


@rpc("authority", "call_local", "reliable")
func _rpc_phase(new_phase: int) -> void:
	phase = new_phase as Phase
	_phase_age = 0.0
	var mine := _local_slot()
	match phase:
		Phase.HIDE:
			for s in seekers:
				var p := _player(s)
				if p:
					p.frozen = true
			Music.duck(HIDE_DUCK, hide_time / maxf(time_scale, 0.01))
			if seekers.has(mine):
				_blackout.visible = true
			elif hider_slots.has(mine):
				RoundUI.push_banner("Hide! Blend in with the furniture (action: change disguise)", 3.0)
		Phase.SEEK:
			_local_seek = 0.0
			_blackout.visible = false
			for i in seekers.size():
				var p := _player(seekers[i])
				if p == null or not p.alive:
					continue
				var spot := HideLayout.DOOR_SPOTS[i % HideLayout.DOOR_SPOTS.size()]
				p.place_at(Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP, true), spot))
				p.frozen = false
				Fx.play(&"dust_puff", spot + Vector3.UP * 0.3, Color.WHITE)
			Sfx.play(&"hit_bonk", Vector3(0.0, 1.0, HideLayout.BACK_Z))
			RoundUI.push_banner("Ready or not, here they come!", 2.0)
			Music.cancel_duck()
			Music.play(SEEK_TRACK, 1.5)
	phase_changed.emit(phase)


@rpc("authority", "call_local", "reliable")
func _rpc_kind(slot: int, kind: int) -> void:
	var p := _player(slot)
	if p == null or not disguises.has(slot):
		return
	disguises[slot] = kind
	var d := _disguise_node(p)
	if d:
		d.set_kind(kind)
	if slot == _local_slot():
		RoundUI.push_banner("You are a %s" % HideLayout.kind_name(kind), 1.2)
		Sfx.play(&"ui_move")
	disguise_changed.emit(slot, kind)


@rpc("authority", "call_local", "reliable")
func _rpc_poke(slot: int, target: int, id: int, at: Vector3) -> void:
	var p := _player(slot)
	if p:
		var from := p.global_position
		var dir := Vector3(at.x - from.x, 0.0, at.z - from.z)
		var fx := Fx.play(&"shove_whoosh", from, Look.parse_color(p.loadout.get("primary", ""), Color.WHITE))
		if fx and dir.length_squared() > 0.0001:
			fx.basis = Basis.looking_at(-dir.normalized(), Vector3.UP)
		Sfx.play(&"shove_whoosh", from)
	if target == PokeTarget.FURNITURE:
		_room.jiggle(id)
		Sfx.play(&"land_soft", at)
		Fx.play(&"dust_puff", at + Vector3.UP * 0.5, Color.WHITE)
	poked.emit(slot, target, id)


@rpc("authority", "call_local", "reliable")
func _rpc_pokes(slot: int, left: int) -> void:
	pokes_left[slot] = left
	RoundUI.push_counter(slot, left)
	if left == 0 and slot == _local_slot():
		RoundUI.push_banner("Out of pokes! One more in %d s" % int(refill_time), 1.6)


@rpc("authority", "call_local", "reliable")
func _rpc_reveal(slot: int, seeker_slot: int, survived: float, seeker_finds: int) -> void:
	caught_time[slot] = survived
	finds[seeker_slot] = seeker_finds
	var p := _player(slot)
	if p:
		_undisguise(p, true)
		p.frozen = true
		var v := p.get_component(&"visuals") as VisualsComponent
		if v:
			v.set_expression(BlobExpressions.HURT, reveal_delay + 0.3)
		Sfx.play(&"hit_bonk", p.global_position)
		var seeker := _player(seeker_slot)
		RoundUI.push_banner("%s found %s!" % [_name_of(seeker), _name_of(p)], 1.6)
	RoundUI.push_counter(slot, int(survived))
	_shown_seconds[slot] = int(survived)
	revealed.emit(slot, seeker_slot, survived)


@rpc("authority", "call_local", "reliable")
func _rpc_rustle(index: int) -> void:
	rustle_count = index
	for s: int in disguises:
		var p := _player(s)
		if p == null or not p.alive:
			continue
		var d := _disguise_node(p)
		if d:
			d.rustle()
		Sfx.play(&"stun_wobble", p.global_position, -4.0, 0.75)
	rustled.emit(index)


@rpc("authority", "call_local", "reliable")
func _rpc_glow() -> void:
	glow_on = true
	if seekers.has(_local_slot()):
		for s: int in disguises:
			var p := _player(s)
			var d := _disguise_node(p) if p else null
			if d:
				d.set_glow(true)
		RoundUI.push_banner("They glow! Last %d seconds" % int(glow_time), 1.6)


## The round is over: every hider still in disguise pops out and cheers.
@rpc("authority", "call_local", "reliable")
func _rpc_end() -> void:
	phase = Phase.OVER
	_blackout.visible = false
	for s: int in disguises.keys():
		var p := _player(s)
		if p and p.alive:
			_undisguise(p, true)
			var v := p.get_component(&"visuals") as VisualsComponent
			if v:
				v.play_emote(&"cheer")
	for p in players:
		if is_instance_valid(p):
			_restore_tuning(p)
			_set_tags(p, true)
	phase_changed.emit(phase)


# --- Disguises (every peer) ----------------------------------------------------------------------

func _disguise(p: Player, kind: int) -> void:
	disguises[p.slot] = kind
	var d := _disguise_node(p)
	if d == null:
		d = HideDisguise.new(p, kind, p.slot == _local_slot())
		p.add_child(d)
	else:
		d.set_kind(kind)
	var v := p.get_component(&"visuals") as VisualsComponent
	var model := v.get_model_root() if v else null
	if model:
		model.visible = false
	_set_tags(p, false)


## Takes the disguise off `p` (restores the blob). `pop`: with a poof (reveal, round end).
func _undisguise(p: Player, pop: bool) -> void:
	disguises.erase(p.slot)
	var d := _disguise_node(p)
	if d:
		p.remove_child(d)
		d.queue_free()
		if pop:
			Fx.play(&"poof", p.global_position + Vector3.UP * 0.6, Look.parse_color(p.loadout.get("primary", ""), Color.WHITE))
	var v := p.get_component(&"visuals") as VisualsComponent
	var model := v.get_model_root() if v else null
	if model:
		model.visible = true
	_set_tags(p, true)


func _disguise_node(p: Player) -> HideDisguise:
	return p.get_node_or_null(NodePath(String(HideDisguise.NODE_NAME))) as HideDisguise


## Name tag and blob shadow of `p` on/off (a disguised hider has neither).
func _set_tags(p: Player, on: bool) -> void:
	var nodes: Array[Node] = [p.get_node_or_null(^"NameTag")]
	var fx := p.get_component(&"fx")
	if fx:
		nodes.append(fx.get_node_or_null(^"BlobShadow"))
	for n in nodes:
		if n == null:
			continue
		n.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
		if not on and n is Node3D:
			(n as Node3D).visible = false


## Every peer, every frame: role tuning (absolute values from the bases read in _setup).
func _apply_tuning(p: Player) -> void:
	if not _base.has(p.slot) or phase == Phase.OVER:
		return
	var b := _base[p.slot]
	var move := p.get_component(&"movement") as MovementComponent
	var jump := p.get_component(&"jump") as JumpComponent
	var shove := p.get_component(&"shove") as ShoveComponent
	var speed: float = b["speed"]
	if seekers.has(p.slot):
		speed *= seeker_speed
		if shove:
			shove.enabled = false
	elif hider_slots.has(p.slot):
		speed *= hider_speed
		if jump:
			jump.jump_enabled = false
		if shove:
			shove.enabled = false
	if move:
		move.max_speed = speed


func _restore_tuning(p: Player) -> void:
	if not _base.has(p.slot):
		return
	var b := _base[p.slot]
	var move := p.get_component(&"movement") as MovementComponent
	var jump := p.get_component(&"jump") as JumpComponent
	var shove := p.get_component(&"shove") as ShoveComponent
	if move:
		move.max_speed = b["speed"]
	if jump:
		jump.jump_enabled = b["jump"]
	if shove:
		shove.enabled = b["shove"]


# --- Blackout (the seeker's own peer) --------------------------------------------------------------

func _build_blackout() -> void:
	_blackout = CanvasLayer.new()
	_blackout.name = "Blackout"
	_blackout.layer = 60
	_blackout.visible = false
	add_child(_blackout)
	var rect := ColorRect.new()
	rect.color = Color(0.02, 0.015, 0.03, 1.0)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blackout.add_child(rect)
	_blackout_label = Label.new()
	_blackout_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blackout_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_blackout_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_blackout_label.add_theme_font_size_override(&"font_size", 54)
	_blackout_label.add_theme_color_override(&"font_color", Color(1.0, 0.9, 0.7))
	var theme := RoundStyle.get_theme()
	if theme and theme.default_font:
		_blackout_label.add_theme_font_override(&"font", theme.default_font)
	_blackout_label.text = "No peeking!"
	_blackout.add_child(_blackout_label)


## True when this peer's screen is blacked out (its player seeks and the hiders are hiding).
func blackout_visible() -> bool:
	return _blackout != null and _blackout.visible


# --- Bots (host) ---------------------------------------------------------------------------------

## Disguise kinds are dealt in proportion to how much of each the room holds (a hider should
## have company).
func _pick_kind(layout: Array[Dictionary]) -> int:
	if layout.is_empty():
		return rng.randi_range(0, HideLayout.kind_count() - 1)
	return int(layout[rng.randi_range(0, layout.size() - 1)]["kind"])


func _plan_bots() -> void:
	_grid = HideLayout.build_grid(_room.furniture)
	_spots.clear()
	_shuffle_at.clear()
	_minds.clear()
	for s in hider_slots:
		_spots[s] = _pick_spot(s, disguises.get(s, 0))
		_shuffle_at[s] = bot_rng.randf_range(BOT_SHUFFLE.x, BOT_SHUFFLE.y)
	for s in seekers:
		_minds[s] = SeekerMind.new()
	for p in players:
		var brain := BotBrain.of(p)
		if brain:
			# Hiders: sharp (no wandering off, no dithering), never aggressive.
			brain.configure(bot_rng.randi(), 1.0 if hider_slots.has(p.slot) else 0.85, 0.0)


## A spot next to furniture of `kind` (else any kind), clear of other furniture and of the other
## hiders' spots, reachable.
func _pick_spot(slot: int, kind: int) -> Vector3:
	var best := Vector3.INF
	var best_score := -INF
	for pass_kind in 2:
		for i in _room.furniture.size():
			var f := _room.furniture[i]
			if pass_kind == 0 and int(f["kind"]) != kind:
				continue
			var fp: Vector3 = f["pos"]
			var r := HideLayout.kind_radius(int(f["kind"])) + 0.55
			for k in 8:
				var a := TAU * k / 8.0 + bot_rng.randf() * 0.3
				var p := fp + Vector3(cos(a), 0.0, sin(a)) * r
				if not _spot_ok(p, slot):
					continue
				var score := bot_rng.randf() * 0.6
				for g in _room.furniture:
					var d := _flat(p - (g["pos"] as Vector3))
					if d < 2.6 and int(g["kind"]) == kind:
						score += 1.0
				if score > best_score:
					best_score = score
					best = p
		if best != Vector3.INF:
			return best
	var pl := _player(slot)
	return pl.global_position if pl else HideLayout.CLEAR_CENTER


func _spot_ok(p: Vector3, slot: int) -> bool:
	if absf(p.x) > HideLayout.PLAY_HALF_X - 0.2 or p.z < HideLayout.PLAY_BACK_Z + 0.2 or p.z > HideLayout.PLAY_FRONT_Z - 0.4:
		return false
	if HideLayout.DOOR_ZONE.has_point(Vector2(p.x, p.z)):
		return false
	for f in _room.furniture:
		if _flat(p - (f["pos"] as Vector3)) < HideLayout.kind_radius(int(f["kind"])) + 0.45:
			return false
	for d: Array in HideLayout.DECOR:
		var rect: Array = d[3]
		if p.x > float(rect[0]) - 0.45 and p.x < float(rect[2]) + 0.45 and p.z > float(rect[1]) - 0.45 and p.z < float(rect[3]) + 0.45:
			return false
	for s: int in _spots:
		if s != slot and _flat(p - _spots[s]) < SPOT_SPACING:
			return false
	return _grid == null or not _grid.is_point_solid(HideLayout.cell_of(p))


## Hider bots: the odd small shuffle to a spot nearby.
func _tick_hider_bots() -> void:
	for s: int in _shuffle_at.keys():
		if not disguises.has(s) or _seek_clock < _shuffle_at[s]:
			continue
		_shuffle_at[s] = _seek_clock + bot_rng.randf_range(BOT_SHUFFLE.x, BOT_SHUFFLE.y)
		var here: Vector3 = _spots.get(s, Vector3.ZERO)
		for attempt in 8:
			var a := bot_rng.randf() * TAU
			var p := here + Vector3(cos(a), 0.0, sin(a)) * bot_rng.randf_range(0.4, 0.8)
			if _spot_ok(p, s):
				_spots[s] = p
				request_bot_rethink(s)
				break


func _begin_seek_minds() -> void:
	for s: int in _minds:
		var m := _minds[s]
		for h in _hiders_left():
			var hp := _player(h)
			if hp == null:
				continue
			m.last_seen[h] = hp.global_position
			# A hunch: "that one was not there before".
			if bot_rng.randf() < BOT_HUNCH_CHANCE:
				_suspect(m, hp.global_position + _noise(BOT_HUNCH_NOISE), 0.7)


## Seeker bots' perception (all noisy): movement they see, rustles they hear, a hunch at the
## start, the glow at the end. Suspicion lands on whatever candidate (furniture or disguised
## hider) is nearest to the noisy point; they poke the most suspicious one they can reach.
const BOT_OBSERVE := 0.5
## Seconds between a hider bot's small shuffles (random in range).
const BOT_SHUFFLE := Vector2(25.0, 45.0)
const BOT_MOVE_SEEN := 0.22
const BOT_SEE_CHANCE := 0.4
const BOT_MOVE_NOISE := 1.0
const BOT_HUNCH_CHANCE := 0.12
const BOT_HUNCH_NOISE := 1.1
const BOT_HEAR_CHANCE := 0.35
const BOT_HEAR_NOISE := 1.8
const BOT_GLOW_CHANCE := 0.15
const BOT_GLOW_NOISE := 0.8
const BOT_ACT := 0.7
const BOT_EXPLORE_CHANCE := 0.04
const BOT_DECAY := 25.0


func _tick_seeker_bots(dt: float) -> void:
	for s: int in _minds:
		var p := _player(s)
		if p == null or not p.alive or not _ai_drives(p):
			continue
		var m := _minds[s]
		m.observe_left -= dt
		m.patrol_left -= dt
		if m.observe_left <= 0.0:
			m.observe_left = BOT_OBSERVE
			_observe(m)
			_choose_target(m, p)
		if m.target == -1:
			continue
		var tp := _key_pos(m.target)
		if tp == Vector3.INF:
			m.target = -1
			continue
		var edge := _flat(tp - p.global_position) - _key_radius(m.target)
		if edge <= poke_reach - 0.1 and _cooldown.get(s, 0.0) <= 0.0 and pokes_left.get(s, 0) > 0:
			var key := m.target
			var hit := poke(s, tp)
			if hit == PokeTarget.FURNITURE:
				m.known[_last_poke_id] = true
				m.suspicion.erase(_last_poke_id)
			m.suspicion.erase(key)
			m.target = -1
			request_bot_rethink(s)


func _ai_drives(p: Player) -> bool:
	if p.is_bot:
		var c := p.get_component(&"controller") as ControllerComponent
		return c == null or not c.scripted
	return ai_humans


func _observe(m: SeekerMind) -> void:
	var decay := exp(-BOT_OBSERVE / BOT_DECAY)
	for k: int in m.suspicion.keys():
		m.suspicion[k] = float(m.suspicion[k]) * decay
	for h in _hiders_left():
		var hp := _player(h)
		if hp == null:
			continue
		var pos := hp.global_position
		var last: Vector3 = m.last_seen.get(h, pos)
		m.last_seen[h] = pos
		var moved := _flat(pos - last)
		if moved > BOT_MOVE_SEEN and bot_rng.randf() < BOT_SEE_CHANCE:
			_suspect(m, pos + _noise(BOT_MOVE_NOISE), 0.8 + moved)
		if glow_on and bot_rng.randf() < BOT_GLOW_CHANCE * BOT_OBSERVE:
			_suspect(m, pos + _noise(BOT_GLOW_NOISE), 0.9)


func _minds_hear_rustle() -> void:
	for m: SeekerMind in _minds.values():
		for h in _hiders_left():
			var hp := _player(h)
			if hp and bot_rng.randf() < BOT_HEAR_CHANCE:
				_suspect(m, hp.global_position + _noise(BOT_HEAR_NOISE), 0.8)


func _choose_target(m: SeekerMind, seeker: Player) -> void:
	if pokes_left.get(seeker.slot, 0) <= 0:
		m.target = -1
		return
	var best := -1
	var best_score := -INF
	for k: int in m.suspicion:
		var pos := _key_pos(k)
		if pos == Vector3.INF or m.known.has(k):
			continue
		var sc := float(m.suspicion[k]) - 0.05 * _flat(pos - seeker.global_position)
		if sc > best_score:
			best_score = sc
			best = k
	if best >= 0 and float(m.suspicion[best]) >= BOT_ACT:
		m.target = best
		return
	if m.target >= 0 and _key_pos(m.target) != Vector3.INF:
		return  # keep walking to what it picked
	# Nothing stands out: now and then poke a random nearby prop on a whim.
	if pokes_left.get(seeker.slot, 0) >= 3 and bot_rng.randf() < BOT_EXPLORE_CHANCE:
		var near: Array[int] = []
		for k in _all_keys():
			if m.known.has(k):
				continue
			if _flat(_key_pos(k) - seeker.global_position) < 4.5:
				near.append(k)
		if not near.is_empty():
			m.target = near[bot_rng.randi_range(0, near.size() - 1)]


func _suspect(m: SeekerMind, point: Vector3, amount: float) -> void:
	var best := -1
	var best_d := 2.2
	for k in _all_keys():
		if m.known.has(k):
			continue
		var d := _flat(_key_pos(k) - point)
		if d < best_d:
			best_d = d
			best = k
	if best >= 0:
		m.suspicion[best] = float(m.suspicion.get(best, 0.0)) + amount


## Candidate keys: furniture ids (0..), disguised hiders 1000 + slot.
func _all_keys() -> Array[int]:
	var out: Array[int] = []
	for i in _room.furniture.size():
		out.append(i)
	for h in _hiders_left():
		out.append(_hider_key(h))
	return out


static func _hider_key(slot: int) -> int:
	return 1000 + slot


func _key_pos(key: int) -> Vector3:
	if key >= 1000:
		var s := key - 1000
		if not disguises.has(s) or caught_time.has(s):
			return Vector3.INF
		var p := _player(s)
		return p.global_position if p and p.alive else Vector3.INF
	if key >= 0 and key < _room.furniture.size():
		return _room.furniture[key]["pos"]
	return Vector3.INF


func _key_radius(key: int) -> float:
	if key >= 1000:
		return 0.42
	return HideLayout.kind_radius(int(_room.furniture[key]["kind"])) if key >= 0 and key < _room.furniture.size() else 0.4


func _noise(sigma: float) -> Vector3:
	return Vector3(bot_rng.randfn(0.0, sigma), 0.0, bot_rng.randfn(0.0, sigma))


## Hiders: to their spot (path waypoints), then stay. Seekers: toward their target (or a patrol
## point) along the grid. On a client (no host plans): stay put.
func get_bot_goal(player: Player) -> Vector3:
	if player == null or not player.alive:
		return super.get_bot_goal(player)
	var here := player.global_position
	if _grid == null:
		return here
	if hider_slots.has(player.slot):
		if not disguises.has(player.slot):
			return here
		var spot: Vector3 = _spots.get(player.slot, here)
		return HideLayout.next_waypoint(_grid, here, spot)
	if seekers.has(player.slot) and phase == Phase.SEEK:
		var m: SeekerMind = _minds.get(player.slot)
		if m == null:
			return here
		var goal := Vector3.INF
		if m.target != -1:
			goal = _key_pos(m.target)
		if goal == Vector3.INF:
			if m.patrol == Vector3.INF or m.patrol_left <= 0.0 or _flat(m.patrol - here) < 1.0:
				m.patrol = _patrol_point()
				m.patrol_left = 6.0
			goal = m.patrol
		return HideLayout.next_waypoint(_grid, here, goal)
	return here


func _patrol_point() -> Vector3:
	if _room.furniture.is_empty():
		return HideLayout.CLEAR_CENTER
	var f := _room.furniture[bot_rng.randi_range(0, _room.furniture.size() - 1)]
	var c := HideLayout.free_cell_near(_grid, f["pos"])
	return HideLayout.cell_center(c)


func is_safe(pos: Vector3) -> bool:
	return absf(pos.x) < HideLayout.PLAY_HALF_X and pos.z > HideLayout.PLAY_BACK_Z and pos.z < HideLayout.PLAY_FRONT_Z


# --- Helpers ---------------------------------------------------------------------------------------

## Hiders still in disguise and not yet found.
func _hiders_left() -> Array[int]:
	var out: Array[int] = []
	for s in hider_slots:
		var p := _player(s)
		if p and p.alive and disguises.has(s) and not caught_time.has(s):
			out.append(s)
	return out


func _forced_pick(slots: Array[int]) -> Array[int]:
	var out: Array[int] = []
	for s in _forced_seekers:
		if slots.has(s) and not out.has(s) and out.size() < slots.size() - 1:
			out.append(s)
	if not out.is_empty():
		remember_seekers(out)
	return out


func _player(slot: int) -> Player:
	if slot < 0:
		return null
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _local_slot() -> int:
	return Net.local_slot()


func _name_of(p: Player) -> String:
	if p == null:
		return "Someone"
	return p.display_name if p.display_name != "" else "Player %d" % (p.slot + 1)


static func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


## The room node (tests, dev).
func room() -> HideRoom:
	return _room


## Host: the spot a hider bot is heading for (tests).
func spot_of(slot: int) -> Vector3:
	return _spots.get(slot, Vector3.INF)
