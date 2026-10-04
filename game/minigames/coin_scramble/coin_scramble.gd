extends Minigame
## Coin Scramble. Owner: the coin_scramble minigame agent.
## Coins rain into a round bank vault; grab the most in `time_limit` (45 s). A hit makes the
## victim drop coins (a shove up to 3, a spinner hit up to 5) that scatter around them. A
## padded bar sweeps the floor (jump it or get swept) and four pinball bumpers bounce you.
##
## Networking (docs/contract.md "Networking rules for minigames"):
## - The host decides everything that matters: where and when coins fall, who collects
##   which coin (first come first served, host distance checks against synced positions
##   every tick), drops on `got_hit`, the end and the ranking. Every peer learns it through
##   the reliable `call_local` RPCs below, which carry coin ids, so `coins` (slot -> count)
##   is identical on every peer.
## - The spinner angle is `spinner_angle(t, dir, speed)`: a pure function of the round
##   clock and the host-sent profile (`_rpc_begin`), computed identically on every peer.
## - Each peer applies the bar and bumper hits to its own authority players only (via
##   `apply_impulse`, so the normal knockback/stun path and events run); remote copies are
##   kinematic. Bumper flashes are cosmetic and run on every peer for every player.
##
## Bots: `get_bot_goal` = the best nearby coin (value / distance), avoiding coins the bar is
## about to sweep; `is_safe` = inside the vault, off the bumpers and out of the bar's next
## ~0.3 s of sweep (so the bot brain's gap-jump makes bots hop the bar now and then).

## Every peer, whenever a player's coin count changes (also at round start).
signal coins_changed(slot: int, count: int)
## Every peer: a coin appeared (rain or drop).
signal coin_spawned(id: int)
## Every peer: `slot` collected coin `id`.
signal coin_collected(id: int, slot: int)
## Every peer: the round is over with this ranking (slots, best first).
signal round_over(ranking: Array[int])

const CoinPiece := preload("res://minigames/coin_scramble/coin_piece.gd")

# --- Arena geometry (metres; matches the props in assets/models/props/) ---------------------

## Inner face of the vault wall.
const WALL_RADIUS := 9.4
## Wall collision height (the model is 1.5 m; the collider is taller so nobody is flung out).
const WALL_HEIGHT := 3.0
## Bots treat everything beyond this as unsafe.
const SAFE_RADIUS := 8.7
## Coins land within this radius, and outside RAIN_MIN_RADIUS (the post).
const RAIN_RADIUS := 8.2
const RAIN_MIN_RADIUS := 0.9
## Rain starts this high.
const RAIN_HEIGHT := 8.0
const BLOB_RADIUS := 0.4
const BUMPER_RADIUS := 0.47
const BUMPER_HEIGHT := 0.88
const POST_RADIUS := 0.3
const POST_HEIGHT := 1.12
const CHEST_SIZE := Vector3(0.94, 1.0, 1.1)
## The bar: 6 m long through the post, 0.42 m thick, top 0.71 m above the floor.
const BAR_HALF_LENGTH := 3.0
const BAR_HALF_WIDTH := 0.21
const BAR_TOP := 0.71
## Spinner angle at t = 0 (radians around +Y; 0 = bar along X).
const SPIN_START_ANGLE := 0.35
## Speed profile (t seconds, rad/s), linear between keys, constant after the last:
## ramps up, speeds up at 14 s, reverses at 26 s, speeds up again at 35 s.
const SPIN_KEYS: Array[Vector2] = [
	Vector2(0.0, 0.0), Vector2(1.0, 1.0), Vector2(14.0, 1.0), Vector2(15.0, 1.45),
	Vector2(26.0, 1.45), Vector2(27.5, -1.45), Vector2(35.0, -1.45), Vector2(36.0, -2.0),
]
const GOLD := Color(1.0, 0.8, 0.25)
## Seconds (host, Session-scaled) between batched request_bot_rethink calls.
const RETHINK_INTERVAL := 0.25
const BUMPER_NOTES: Array[StringName] = [&"piano_c", &"piano_e", &"piano_g", &"piano_b"]
## Presentation (every peer): a coin burst (a blob's coins flying out, a big coin falling) is
## worth watching this long (s); blobs within INTEREST_RANGE (m) turn to the nearest one,
## updated every INTEREST_EVERY s.
const BURST_LIFE := 1.4
const INTEREST_RANGE := 9.0
const INTEREST_EVERY := 0.2

# --- Tuning -----------------------------------------------------------------------------------

@export_group("Coins")
## Most coins on the floor (and falling) at once; rain pauses at the cap.
@export var coin_cap: int = 40
## Seconds between rain coins at the start and just before the gold rush (linear ramp).
@export var rain_interval_start: float = 0.95
@export var rain_interval_end: float = 0.38
## The last seconds of the round are a gold rush: rain every `rush_interval` seconds.
@export var gold_rush_time: float = 8.0
@export var rush_interval: float = 0.14
## Chance a rain coin is a big one (worth 5), normally and in the gold rush.
@export var big_chance: float = 0.07
@export var rush_big_chance: float = 0.18
## Coins dropped at once when play starts.
@export var opening_coins: int = 6
## Extra reach (m) beyond blob radius + coin radius for a pickup.
@export var pickup_margin: float = 0.18

@export_group("Drops")
## Coins lost to a shove, and to a big hit (the spinner).
@export var drop_shove: int = 3
@export var drop_big: int = 5
## A sourceless hit at least this strong counts as a big (spinner) hit; weaker sourceless
## hits (bumpers) drop nothing.
@export var big_hit_impulse: float = 11.5
## Seconds a dropped coin hops before it lands (nobody can grab it before ~80% of it).
@export var drop_flight: float = 0.55
## Seconds before the victim can pick up their own dropped coins.
@export var victim_delay: float = 1.5
## Round-clock seconds after a drop during which the same player drops nothing more
## (no chain-robbing a stunned blob).
@export var drop_cooldown: float = 2.0
## How far dropped coins scatter (m, random in range).
@export var drop_distance: Vector2 = Vector2(1.3, 2.6)

@export_group("Hazards")
@export var bar_push: float = 11.5
@export var bar_lift: float = 6.0
@export var bar_hit_cooldown: float = 0.7
@export var bumper_push: float = 8.5
@export var bumper_lift: float = 3.0
@export var bumper_cooldown: float = 0.35

@export_group("Test")
## Test-only: multiplies the round clock (rain, spinner, time limit). The per-peer clock
## (spinner, time limit) also follows Session.time_scale, so it agrees with Session's
## backstop; the host's rain uses `_host_tick`'s delta, which Session already scales.
@export var time_scale: float = 1.0
## Test-only: when false the host rains no coins (tests place coins with spawn_rain_coin).
@export var rain_enabled: bool = true
## Seed for the host's coin RNG; -1 = random.
@export var rng_seed: int = -1

# --- State ---------------------------------------------------------------------------------

## slot -> coins, identical on every peer (only changed by the host's RPCs).
var coins: Dictionary[int, int] = {}
## The ranking of the finished round on every peer (empty until then).
var final_ranking: Array[int] = []

## slot -> {count: round time it was first reached} (tie-break), every peer.
var _first_reached: Dictionary = {}
var _slots: Array[int] = []
## id -> CoinPiece, in spawn order.
var _pieces: Dictionary[int, Node3D] = {}
var _running: bool = false
var _over: bool = false
## Round clock (seconds, scaled), every peer, from _rpc_begin.
var _t: float = 0.0
var _dir: float = 1.0
var _speed: float = 1.0
var _rng := RandomNumberGenerator.new()
var _next_id: int = 1
var _rain_timer: float = 0.0
var _opening_left: int = 0
var _rush_announced: bool = false
## Host: the coins changed since the bots last re-planned; batched to one request per
## RETHINK_INTERVAL so a rain burst does not spam.
var _rethink_pending: bool = false
var _rethink_cd: float = 0.0
## slot -> round time of that player's last drop (host).
var _last_drop: Dictionary[int, float] = {}
## slot -> seconds until that player can be hit by the bar / a bumper again (local players).
var _hit_cd: Dictionary[int, float] = {}
var _bump_cd: Dictionary[int, float] = {}
var _bumper_pos: Array[Vector3] = []
var _bumper_nodes: Array[Node3D] = []
var _bumper_mats: Array[BaseMaterial3D] = []
var _flash_cd: Array[float] = []
var _chest_pos: Array[Vector3] = []
## Every peer: live coin bursts, xyz = where the coins land, w = seconds left (presentation).
var bursts: Array[Vector4] = []
var _interest_cd: float = 0.0

@onready var _bar: Node3D = $Spinner/Bar
@onready var _coins_root: Node3D = $Coins


func _ready() -> void:
	_build_colliders()
	Look.apply_toon($Floor/Model, false)
	for n: Node3D in [$Walls, $Spinner, $Bumpers, $Chests]:
		Look.apply_toon(n)
	for b in $Bumpers.get_children():
		var bn := b as Node3D
		_bumper_nodes.append(bn)
		_bumper_pos.append(bn.position)
		_flash_cd.append(0.0)
		_bumper_mats.append(_own_emit_material(bn))
	for c in $Chests.get_children():
		_chest_pos.append((c as Node3D).position)
	_bar.rotation.y = spinner_angle(0.0, 1.0, 1.0)


# --- Minigame flow ------------------------------------------------------------------------

func _setup(round_players: Array[Player]) -> void:
	coins.clear()
	_first_reached.clear()
	_slots.clear()
	for p in round_players:
		_slots.append(p.slot)
		coins[p.slot] = 0
		_first_reached[p.slot] = {0: 0.0}
		p.got_hit.connect(_on_got_hit.bind(p.slot))


func _start() -> void:
	if not Net.is_host():
		return
	if rng_seed >= 0:
		_rng.seed = rng_seed
	else:
		_rng.randomize()
	var dir := 1.0 if _rng.randf() < 0.5 else -1.0
	_rpc_begin.rpc(dir, _rng.randf_range(0.92, 1.08))


func _host_tick(delta: float) -> void:
	if not _running or _over:
		return
	_rescue_fallen()
	if rain_enabled:
		_rain(delta * time_scale)  # Session already scales _host_tick's delta
	_collect()
	_rethink_cd -= delta
	if _rethink_pending and _rethink_cd <= 0.0:
		_rethink_pending = false
		_rethink_cd = RETHINK_INTERVAL
		request_bot_rethink()
	if time_limit > 0.0 and _t >= time_limit:
		end_round()


func _physics_process(delta: float) -> void:
	for i in _flash_cd.size():
		_flash_cd[i] -= delta
	if not _running:
		return
	_t += delta * _clock_scale()
	_bar.rotation.y = spinner_angle(_t, _dir, _speed)
	if not _over:
		_local_hazards(delta)


## Host: ends the round now with the coin ranking (also called at the time limit).
func end_round() -> void:
	if _over or is_finished():
		return
	var ranking := rank_by_coins(_slots, coins, _reach_times())
	var counts := PackedInt32Array()
	for s in ranking:
		counts.append(coins.get(s, 0))
	_rpc_end.rpc(PackedInt32Array(ranking), counts)
	finish(ranking)


## Seconds on the round clock since play started (every peer).
func round_time() -> float:
	return _t


func is_gold_rush() -> bool:
	return _running and _t >= _rush_start()


# --- Host: coins ------------------------------------------------------------------------------

## Host: drops a coin of `value` from `height` above (pos.x, pos.z). Returns its id.
func spawn_rain_coin(pos: Vector3, value: int = 1, height: float = RAIN_HEIGHT) -> int:
	var id := _next_id
	_next_id += 1
	_rpc_rain.rpc(id, value, Vector3(pos.x, height, pos.z))
	return id


## The coin `id` (a CoinPiece), or null.
func get_coin(id: int) -> Node3D:
	return _pieces.get(id)


## Ids of every coin on the floor or in the air, oldest first.
func coin_ids() -> Array[int]:
	var out: Array[int] = []
	out.assign(_pieces.keys())
	return out


func _rain(dt: float) -> void:
	while _opening_left > 0:
		_opening_left -= 1
		spawn_rain_coin(_random_floor_point(), 1)
	var rush := _t >= _rush_start()
	if rush and not _rush_announced:
		_rush_announced = true
		_rpc_gold_rush.rpc()
	_rain_timer -= dt
	if _rain_timer > 0.0:
		return
	if rush:
		_rain_timer = rush_interval
	else:
		_rain_timer = lerpf(rain_interval_start, rain_interval_end, clampf(_t / maxf(_rush_start(), 0.01), 0.0, 1.0))
	if _pieces.size() >= coin_cap:
		return
	var value := 5 if _rng.randf() < (rush_big_chance if rush else big_chance) else 1
	spawn_rain_coin(_random_floor_point(), value)


## First come first served: each coin goes to the nearest living player touching it this tick.
func _collect() -> void:
	var got: Array[Vector2i] = []
	for id: int in _pieces:
		var c := _pieces[id] as CoinPiece
		var cpos := c.current_pos()
		var reach := BLOB_RADIUS + coin_radius(c.value) + pickup_margin
		var best := -1
		var best_d := INF
		for p in players:
			if not _live(p) or not c.can_grab(p.slot):
				continue
			var d := touch_distance(p.global_position, cpos)
			if d <= reach and d < best_d:
				best_d = d
				best = p.slot
		if best >= 0:
			got.append(Vector2i(id, best))
	for g in got:
		var c := _pieces.get(g.x) as CoinPiece
		if c:
			_rpc_collect.rpc(g.x, g.y, coins.get(g.y, 0) + c.value)


func _on_got_hit(impulse: Vector3, source_slot: int, slot: int) -> void:
	if not Net.is_host() or not _running or _over:
		return
	var n := 0
	if source_slot >= 0:
		n = drop_shove
	elif impulse.length() >= big_hit_impulse:
		n = drop_big
	n = mini(n, coins.get(slot, 0))
	if n <= 0 or _t - _last_drop.get(slot, -INF) < drop_cooldown:
		return
	_last_drop[slot] = _t
	var p := _player(slot)
	if p == null:
		return
	var from := p.global_position + Vector3(0.0, 0.6, 0.0)
	var ids := PackedInt32Array()
	var targets := PackedVector3Array()
	var base := _rng.randf() * TAU
	for i in n:
		var a := base + TAU * float(i) / float(n) + _rng.randf_range(-0.35, 0.35)
		var d := _rng.randf_range(drop_distance.x, drop_distance.y)
		var to := _clamp_to_floor(from + Vector3(cos(a) * d, 0.0, sin(a) * d))
		ids.append(_next_id)
		_next_id += 1
		targets.append(to)
	_rpc_drop.rpc(slot, coins.get(slot, 0) - n, from, ids, targets)


func _rescue_fallen() -> void:
	var points := get_spawn_points()
	for i in players.size():
		var p := players[i]
		if _live(p) and p.global_position.y < -3.0 and not points.is_empty():
			p.respawn_at(points[i % points.size()])


# --- Replicated (host -> every peer, host included) --------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_begin(dir: float, speed: float) -> void:
	_dir = dir
	_speed = speed
	_t = 0.0
	_running = true
	_over = false
	_opening_left = opening_coins
	_rain_timer = rain_interval_start
	for s in _slots:
		_set_count(s, coins.get(s, 0))


@rpc("authority", "call_local", "reliable")
func _rpc_rain(id: int, value: int, from: Vector3) -> void:
	var c := CoinPiece.new()
	c.setup_fall(id, value, from)
	_add_coin(c)
	if value > 1:
		_add_burst(Vector3(from.x, 0.3, from.z))


@rpc("authority", "call_local", "reliable")
func _rpc_collect(id: int, slot: int, new_count: int) -> void:
	var c := _pieces.get(id) as CoinPiece
	var at := Vector3.ZERO
	var value := 1
	if c:
		at = c.global_position
		value = c.value
		_pieces.erase(id)
		c.queue_free()
		_rethink_pending = true
	else:
		var p := _player(slot)
		if p:
			at = p.global_position + Vector3.UP * 0.5
	_set_count(slot, new_count)
	Fx.play(&"coin_pickup", at, GOLD)
	Sfx.play(&"coin_big" if value > 1 else &"coin", at)
	if value > 1:
		_float_text("+%d" % value, at + Vector3.UP * 0.6, GOLD)
	coin_collected.emit(id, slot)


@rpc("authority", "call_local", "reliable")
func _rpc_drop(slot: int, new_count: int, from: Vector3, ids: PackedInt32Array, targets: PackedVector3Array) -> void:
	_set_count(slot, new_count)
	for i in mini(ids.size(), targets.size()):
		var c := CoinPiece.new()
		c.setup_arc(ids[i], 1, from, targets[i], drop_flight)
		c.grab_delay = drop_flight * 0.8
		c.no_grab_slot = slot
		c.victim_delay = victim_delay
		_add_coin(c)
	_float_text("-%d" % ids.size(), from + Vector3.UP * 0.9, Color(1.0, 0.35, 0.3))
	Sfx.play(&"coin", from, -2.0, 0.75)
	if not targets.is_empty():
		var mid := Vector3.ZERO
		for t in targets:
			mid += t
		_add_burst(mid / float(targets.size()) + Vector3.UP * 0.3)


@rpc("authority", "call_local", "reliable")
func _rpc_gold_rush() -> void:
	RoundUI.push_banner("GOLD RUSH!", 2.0)
	Sfx.play(&"coin_big")
	for i in _bumper_nodes.size():
		_flash_bumper(i, false)


@rpc("authority", "call_local", "reliable")
func _rpc_end(ranking: PackedInt32Array, counts: PackedInt32Array) -> void:
	_over = true
	final_ranking.clear()
	for i in ranking.size():
		final_ranking.append(ranking[i])
		if i < counts.size() and coins.get(ranking[i], -1) != counts[i]:
			_set_count(ranking[i], counts[i])
	if not final_ranking.is_empty():
		var winner := _player(final_ranking[0])
		if winner and winner.alive:
			var vis := winner.get_component(&"visuals") as VisualsComponent
			if vis:
				vis.play_emote(&"cheer")
			Fx.play(&"confetti", winner.global_position + Vector3.UP * 1.2)
	round_over.emit(final_ranking.duplicate())


# --- Every peer: interest (presentation) ------------------------------------------------------

func _add_burst(at: Vector3) -> void:
	bursts.append(Vector4(at.x, at.y, at.z, BURST_LIFE))


## A few times a second: every living blob within INTEREST_RANGE of a live burst turns to the
## nearest one (nearer = stronger). Local only; nothing networked.
func _process(delta: float) -> void:
	for i in range(bursts.size() - 1, -1, -1):
		bursts[i].w -= delta
		if bursts[i].w <= 0.0:
			bursts.remove_at(i)
	_interest_cd -= delta
	if _interest_cd > 0.0 or bursts.is_empty():
		return
	_interest_cd = INTEREST_EVERY
	for p in players:
		if not _live(p):
			continue
		var best := Vector3.INF
		var best_d := INTEREST_RANGE
		for b in bursts:
			var at := Vector3(b.x, b.y, b.z)
			var d := Vector2(at.x - p.global_position.x, at.z - p.global_position.z).length()
			if d < best_d:
				best_d = d
				best = at
		if best.is_finite():
			var v := p.get_component(&"visuals") as VisualsComponent
			if v:
				v.set_interest_point(best, clampf(1.2 - best_d / INTEREST_RANGE, 0.35, 1.0))


# --- Every peer: hazards ----------------------------------------------------------------------

func _local_hazards(delta: float) -> void:
	for s: int in _hit_cd:
		_hit_cd[s] -= delta
	for s: int in _bump_cd:
		_bump_cd[s] -= delta
	var a := spinner_angle(_t, _dir, _speed)
	var w := spinner_rate(_t, _dir, _speed)
	for p in players:
		if not _live(p):
			continue
		var pos := p.global_position
		var local := p.is_authority() and not p.frozen
		for i in _bumper_pos.size():
			var off := Vector2(pos.x - _bumper_pos[i].x, pos.z - _bumper_pos[i].z)
			if off.length() > BUMPER_RADIUS + BLOB_RADIUS + 0.08 or pos.y > BUMPER_HEIGHT:
				continue
			if _flash_cd[i] <= 0.0:
				_flash_bumper(i, true)
			if local and _bump_cd.get(p.slot, 0.0) <= 0.0:
				_bump_cd[p.slot] = bumper_cooldown
				var away := off.normalized() if off.length() > 0.01 else Vector2.RIGHT
				p.apply_impulse(Vector3(away.x * bumper_push, bumper_lift, away.y * bumper_push))
		if local and _hit_cd.get(p.slot, 0.0) <= 0.0 and bar_overlaps(a, pos, BLOB_RADIUS):
			_hit_cd[p.slot] = bar_hit_cooldown
			p.apply_impulse(bar_impulse(a, w, pos, bar_push, bar_lift))


func _flash_bumper(i: int, with_sound: bool) -> void:
	_flash_cd[i] = 0.25
	var node := _bumper_nodes[i]
	var tw := node.create_tween()
	tw.tween_property(node, ^"scale", Vector3(1.15, 0.9, 1.15), 0.06)
	tw.tween_property(node, ^"scale", Vector3.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var m := _bumper_mats[i]
	if m:
		var tm := node.create_tween()
		tm.tween_property(m, ^"emission_energy_multiplier", 6.0, 0.05)
		tm.tween_property(m, ^"emission_energy_multiplier", 1.0, 0.35)
	if with_sound:
		Sfx.play(BUMPER_NOTES[i % BUMPER_NOTES.size()], node.global_position, -4.0)


# --- Spinner (pure; identical on every peer) --------------------------------------------------

## Angular speed (rad/s) at round time `t` for a host-sent `dir` (+1/-1) and `speed` factor.
static func spinner_rate(t: float, dir: float = 1.0, speed: float = 1.0) -> float:
	return dir * speed * _profile_rate(t)


## Bar angle (radians around +Y) at round time `t`: the exact integral of spinner_rate.
static func spinner_angle(t: float, dir: float = 1.0, speed: float = 1.0) -> float:
	var total := 0.0
	if t > SPIN_KEYS[0].x:
		for i in range(1, SPIN_KEYS.size()):
			var k0 := SPIN_KEYS[i - 1]
			var k1 := SPIN_KEYS[i]
			if t <= k0.x:
				break
			var t1 := minf(t, k1.x)
			var w1 := lerpf(k0.y, k1.y, (t1 - k0.x) / (k1.x - k0.x))
			total += (k0.y + w1) * 0.5 * (t1 - k0.x)
		var last := SPIN_KEYS[SPIN_KEYS.size() - 1]
		if t > last.x:
			total += last.y * (t - last.x)
	return SPIN_START_ANGLE + dir * speed * total


static func _profile_rate(t: float) -> float:
	if t <= SPIN_KEYS[0].x:
		return SPIN_KEYS[0].y
	for i in range(1, SPIN_KEYS.size()):
		var k1 := SPIN_KEYS[i]
		if t < k1.x:
			var k0 := SPIN_KEYS[i - 1]
			return lerpf(k0.y, k1.y, (t - k0.x) / (k1.x - k0.x))
	return SPIN_KEYS[SPIN_KEYS.size() - 1].y


## True when a body of `radius` standing with its feet at `feet` is inside the bar at
## angle `a`. Feet at or above the bar's top clear it (a jump).
static func bar_overlaps(a: float, feet: Vector3, radius: float) -> bool:
	if feet.y >= BAR_TOP - 0.03 or feet.y < -1.0:
		return false
	var u := Vector2(cos(a), -sin(a))
	var rel := Vector2(feet.x, feet.z)
	var along := clampf(rel.dot(u), -BAR_HALF_LENGTH, BAR_HALF_LENGTH)
	return (rel - u * along).length() < BAR_HALF_WIDTH + radius


## The push of the bar at angle `a` turning at `w` on a player at `feet`: along the bar's
## motion at that point, a little outward, plus lift.
static func bar_impulse(a: float, w: float, feet: Vector3, push: float, lift: float) -> Vector3:
	var u := Vector2(cos(a), -sin(a))
	var rel := Vector2(feet.x, feet.z)
	var along := rel.dot(u)
	var radial := rel.normalized() if rel.length() > 0.05 else u
	var h := radial
	if absf(w) > 0.05 and absf(along) > 0.05:
		h = Vector2(-sin(a), -cos(a)) * signf(w * along) + radial * 0.35
	h = h.normalized() * push
	return Vector3(h.x, lift, h.y)


# --- Ranking ------------------------------------------------------------------------------------

## `slots` by coins (desc), then by who first reached that count (earlier first), then slot.
static func rank_by_coins(slots: Array[int], counts: Dictionary, reached_at: Dictionary) -> Array[int]:
	var out: Array[int] = slots.duplicate()
	out.sort_custom(func(a: int, b: int) -> bool:
		var ca: int = counts.get(a, 0)
		var cb: int = counts.get(b, 0)
		if ca != cb:
			return ca > cb
		var ta: float = reached_at.get(a, 0.0)
		var tb: float = reached_at.get(b, 0.0)
		if ta != tb:
			return ta < tb
		return a < b)
	return out


## slot -> round time the player first reached their current count.
func _reach_times() -> Dictionary:
	var out: Dictionary = {}
	for s in _slots:
		var hist: Dictionary = _first_reached.get(s, {})
		out[s] = float(hist.get(coins.get(s, 0), 0.0))
	return out


# --- Bots ----------------------------------------------------------------------------------------

## The best coin for `player`: value over distance, less if someone else is clearly closer,
## much less if the bar will sweep it before the bot gets there. No coins: a spot on the ring.
func get_bot_goal(player: Player) -> Vector3:
	if player == null:
		return Vector3.ZERO
	var pos := player.global_position
	var best: Vector3 = Vector3.INF
	var best_score := -INF
	for id: int in _pieces:
		var c := _pieces[id] as CoinPiece
		if c.no_grab_slot == player.slot and c.age < c.victim_delay - 0.3:
			continue
		var target := Vector3(c.land.x, 0.0, c.land.z)
		var d := Vector2(target.x - pos.x, target.z - pos.z).length()
		var score := float(c.value) / (d + 1.5)
		for o in players:
			if o != player and _live(o):
				var od := Vector2(target.x - o.global_position.x, target.z - o.global_position.z).length()
				if od + 0.8 < d:
					score *= 0.5
					break
		if bar_threatens(target, d / 5.5 + 0.6):
			score *= 0.2
		# A little personal taste so bots do not all herd to the same coin.
		score *= 1.0 + 0.3 * _hash01(player.slot * 7919 + id * 104729)
		if score > best_score:
			best_score = score
			best = target
	if best != Vector3.INF:
		return best
	var a := TAU * float(player.slot) / 8.0 + _t * 0.2
	return Vector3(sin(a), 0.0, cos(a)) * 5.0


## Inside the vault, off the bumpers and the post, and not where the bar will be in the
## next ~0.3 s.
func is_safe(pos: Vector3) -> bool:
	var r := Vector2(pos.x, pos.z).length()
	if r > SAFE_RADIUS or r < POST_RADIUS + 0.5:
		return false
	for b in _bumper_pos:
		if Vector2(pos.x - b.x, pos.z - b.z).length() < BUMPER_RADIUS + 0.5:
			return false
	if _running and not _over and r < BAR_HALF_LENGTH + 0.6:
		var k_scale := _clock_scale()
		for k in 4:
			var a := spinner_angle(_t + 0.1 * k * k_scale, _dir, _speed)
			if bar_overlaps(a, Vector3(pos.x, 0.0, pos.z), 0.45):
				return false
	return true


## True when the bar passes over `target` within the next `seconds` (round-clock seconds).
func bar_threatens(target: Vector3, seconds: float) -> bool:
	if not _running or Vector2(target.x, target.z).length() > BAR_HALF_LENGTH + 0.6:
		return false
	var k_scale := _clock_scale()
	var steps := clampi(int(seconds / 0.1), 1, 30)
	for k in steps + 1:
		var a := spinner_angle(_t + 0.1 * k * k_scale, _dir, _speed)
		if bar_overlaps(a, Vector3(target.x, 0.0, target.z), 0.5):
			return true
	return false


# --- Helpers --------------------------------------------------------------------------------------

## Distance from a coin centre to the blob (a capsule whose core runs 0.4..0.6 m above `feet`).
static func touch_distance(feet: Vector3, coin_pos: Vector3) -> float:
	var y := clampf(coin_pos.y, feet.y + 0.4, feet.y + 0.6)
	return coin_pos.distance_to(Vector3(feet.x, y, feet.z))


static func coin_radius(value: int) -> float:
	return CoinPiece.RADIUS_BIG if value > 1 else CoinPiece.RADIUS


func _clock_scale() -> float:
	return time_scale * Session.time_scale


func _rush_start() -> float:
	if time_limit <= 0.0:
		return INF
	return maxf(time_limit - gold_rush_time, 0.0)


func _set_count(slot: int, count: int) -> void:
	count = maxi(count, 0)
	coins[slot] = count
	var hist: Dictionary = _first_reached.get(slot, {})
	if not hist.has(count):
		hist[count] = _t
	_first_reached[slot] = hist
	RoundUI.push_counter(slot, count)
	coins_changed.emit(slot, count)


func _add_coin(c: Node3D) -> void:
	var piece := c as CoinPiece
	piece.time_scale = _clock_scale()
	piece.name = "Coin%d" % piece.id
	_pieces[piece.id] = piece
	_rethink_pending = true
	_coins_root.add_child(piece)
	coin_spawned.emit(piece.id)


func _player(slot: int) -> Player:
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _live(p: Player) -> bool:
	return is_instance_valid(p) and p.is_inside_tree() and p.alive


func _random_floor_point() -> Vector3:
	var pt := Vector3.ZERO
	for attempt in 10:
		var r := sqrt(_rng.randf_range(RAIN_MIN_RADIUS * RAIN_MIN_RADIUS, RAIN_RADIUS * RAIN_RADIUS))
		var a := _rng.randf() * TAU
		pt = Vector3(cos(a) * r, 0.0, sin(a) * r)
		if _clear_of_props(pt):
			return pt
	return pt


func _clear_of_props(pt: Vector3) -> bool:
	for b in _bumper_pos:
		if Vector2(pt.x - b.x, pt.z - b.z).length() < BUMPER_RADIUS + 0.45:
			return false
	for c in _chest_pos:
		if Vector2(pt.x - c.x, pt.z - c.z).length() < 1.1:
			return false
	return true


## Keeps a drop target on open floor: inside RAIN_RADIUS, off the post, bumpers and chests.
func _clamp_to_floor(pt: Vector3) -> Vector3:
	var flat := Vector2(pt.x, pt.z)
	if flat.length() > RAIN_RADIUS:
		flat = flat.normalized() * RAIN_RADIUS
	if flat.length() < RAIN_MIN_RADIUS:
		flat = (flat.normalized() if flat.length() > 0.01 else Vector2.RIGHT) * RAIN_MIN_RADIUS
	var out := Vector3(flat.x, 0.0, flat.y)
	for b in _bumper_pos:
		var off := Vector2(out.x - b.x, out.z - b.z)
		var min_d := BUMPER_RADIUS + 0.45
		if off.length() < min_d:
			off = (off.normalized() if off.length() > 0.01 else Vector2.RIGHT) * min_d
			out = Vector3(b.x + off.x, 0.0, b.z + off.y)
	for c in _chest_pos:
		var off := Vector2(out.x - c.x, out.z - c.z)
		if off.length() < 1.1:
			off = (-Vector2(c.x, c.z)).normalized() * 1.1
			out = Vector3(c.x + off.x, 0.0, c.z + off.y)
	return out


func _float_text(text: String, at: Vector3, color: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.font_size = 72
	l.outline_size = 18
	l.modulate = color
	l.outline_modulate = Color(0.18, 0.1, 0.05)
	l.pixel_size = 0.006
	add_child(l)
	l.global_position = at
	var tw := l.create_tween().set_parallel(true)
	tw.tween_property(l, ^"position:y", l.position.y + 1.0, 0.8).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(l, ^"modulate:a", 0.0, 0.8).set_delay(0.3)
	tw.tween_property(l, ^"outline_modulate:a", 0.0, 0.8).set_delay(0.3)
	tw.chain().tween_callback(l.queue_free)


static func _hash01(n: int) -> float:
	var h := (n * 2654435761) & 0xffffffff
	h = ((h >> 16) ^ h) * 0x45d9f3b & 0xffffffff
	h = ((h >> 16) ^ h) & 0xffffffff
	return float(h % 10007) / 10007.0


## Gives this bumper its own copy of the EmitBumper material so it can flash alone.
func _own_emit_material(bumper: Node3D) -> BaseMaterial3D:
	for n in bumper.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s) as BaseMaterial3D
			if m and m.resource_name == "EmitBumper":
				var copy := m.duplicate() as BaseMaterial3D
				copy.resource_name = m.resource_name
				mi.set_surface_override_material(s, copy)
				return copy
	return null


func _build_colliders() -> void:
	var body := StaticBody3D.new()
	body.name = "Colliders"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	# Wall ring: 24 boxes whose inner faces sit on WALL_RADIUS.
	var n := 24
	var depth := 1.0
	var width := 2.0 * (WALL_RADIUS + depth) * tan(PI / n) * 1.05
	for i in n:
		var a := TAU * i / n
		var box := BoxShape3D.new()
		box.size = Vector3(width, WALL_HEIGHT, depth)
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = Vector3(sin(a), 0.0, cos(a)) * (WALL_RADIUS + depth * 0.5) + Vector3.UP * WALL_HEIGHT * 0.5
		cs.rotation.y = a
		body.add_child(cs)
	_add_cylinder(body, Vector3.ZERO, POST_RADIUS, POST_HEIGHT)
	for b in $Bumpers.get_children():
		_add_cylinder(body, (b as Node3D).position, BUMPER_RADIUS, BUMPER_HEIGHT)
	for c in $Chests.get_children():
		var chest := c as Node3D
		var box := BoxShape3D.new()
		box.size = CHEST_SIZE
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = chest.position + Vector3.UP * CHEST_SIZE.y * 0.5
		cs.rotation = chest.rotation
		body.add_child(cs)


func _add_cylinder(body: StaticBody3D, at: Vector3, radius: float, height: float) -> void:
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	var cs := CollisionShape3D.new()
	cs.shape = cyl
	cs.position = at + Vector3.UP * height * 0.5
	body.add_child(cs)
