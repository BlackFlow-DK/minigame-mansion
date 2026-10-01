extends Minigame
## Paint Splat. Owner: the paint_splat minigame agent.
## A walled studio floor of GRID x GRID one-metre tiles. Running over a tile paints it your
## colour; most tiles after `time_limit` (45 s) wins, ties by who reached that count first.
## Shoving stuns as usual, and while a blob is stunned the tiles under it (and around it, in
## `stun_paint_radius`) go to whoever shoved it: shoving is how you take territory. Every
## `bomb_interval` seconds a splash bomb (a paint bucket) drops at a random spot; the first
## blob to touch it paints every tile within `splash_radius` in their colour. At the end the
## floor freezes for `final_freeze` seconds ("final splat") before the ranking goes out.
##
## Networking (docs/contract.md "Networking rules for minigames"):
## - The host decides all paint from synced positions. Each tick it gathers the tiles that
##   change (contested tiles, claimed by two blobs in the same tick, stay as they are, so
##   no slot wins ties by order) and sends only those in one reliable `call_local` RPC
##   (`_rpc_paint`: tile indices + slots). Every peer applies the batches in order, so
##   `owners` (tile -> slot) and `counts` are identical everywhere.
## - Splash bombs: the host picks the spot (`_rpc_bomb`) and who claims it (`_rpc_splash`);
##   the splash tiles follow in the same tick's `_rpc_paint`. The fall is cosmetic.
## - The end (`_rpc_end`) carries the host's ranking and counts; every peer freezes all
##   players for the final splat, the host calls finish() `final_freeze` seconds later.
##
## Rendering: one MultiMeshInstance3D holds every tile (the paint_tile mesh: a grout body
## plus the `PaintTop` surface). PaintTop gets one shared toon material that takes its
## colour from the per-instance colour, so repainting a tile is `set_instance_color`: no
## per-tile materials, one draw call for the whole floor. Player colours are the loadout
## primaries as-is.
##
## Bots: `get_bot_goal` = the best nearby cluster of tiles not in the bot's colour (a 3x3
## window, weighted by distance), sometimes avoiding the leader's shove range; a splash bomb
## the bot can reach first wins. `is_safe` = inside the walls.

## Every peer, after a paint batch was applied (only tiles that really changed).
signal tiles_painted(tiles: PackedInt32Array, slots: PackedInt32Array)
## Every peer, whenever a player's tile count changes (also 0 at round start).
signal counts_changed(slot: int, count: int)
## Every peer: a splash bomb started falling toward `pos`.
signal bomb_spawned(id: int, pos: Vector3)
## Every peer: `slot` grabbed bomb `id`.
signal bomb_claimed(id: int, slot: int)
## Every peer: the round is over with this ranking (slots, best first).
signal round_over(ranking: Array[int])

const TILE_SCENE: PackedScene = preload("res://assets/models/props/paint_tile.glb")
const BUCKET_SCENE: PackedScene = preload("res://assets/models/props/paint_bucket.glb")
const WALL_SCENE: PackedScene = preload("res://assets/models/props/paint_wall.glb")
const EASEL_SCENE: PackedScene = preload("res://assets/models/props/paint_easel.glb")
const CANS_SCENE: PackedScene = preload("res://assets/models/props/paint_cans.glb")
const ARROW_SCENE: PackedScene = preload("res://assets/models/props/arrow_marker.glb")

## Tiles per side, tile size (m); the floor spans -HALF..HALF on X and Z, tile tops at y = 0.
const GRID := 14
const TILE := 1.0
const HALF := GRID * TILE * 0.5
const TILE_COUNT := GRID * GRID
const UNPAINTED := -1
## Claim marker for a tile two blobs want in the same tick.
const CONTESTED := -2
const BLOB_RADIUS := 0.4
const WALL_HEIGHT := 3.0
## Bots keep this far inside the walls.
const SAFE_MARGIN := 0.5
## Colour of an unpainted tile.
const FLOOR_COLOR := Color("#d8d0c2")
## Tile pop when it changes colour: seconds, lift (m).
const POP_TIME := 0.28
const POP_LIFT := 0.07
const BUCKET_SCALE := 1.25
const ARROW_HEIGHT := 2.6
const RING_COLOR := Color(1.0, 0.86, 0.3, 0.9)

@export_group("Paint")
## Feet higher than this (mid-jump) do not paint.
@export var paint_height: float = 0.45
## While stunned, the tiles whose centre is this close to the victim go to the shover.
@export var stun_paint_radius: float = 0.85
## Round-clock seconds after a shove hit during which the victim may still become stunned
## (a remote victim's `control_locked` can arrive a tick after the hit).
@export var stun_window: float = 0.3

@export_group("Splash bomb")
@export var bomb_interval: float = 15.0
## Round-clock seconds from the drop until it lands (it can be grabbed from then on).
@export var bomb_fall_time: float = 1.1
@export var bomb_height: float = 9.0
## Tiles whose centre is within this distance of the bomb are splashed.
@export var splash_radius: float = 3.0
## Horizontal reach (m) from the bomb centre to a blob centre for a grab.
@export var bomb_reach: float = 0.85
## The bomb lands on a tile centre within +-this on X and Z, and at least
## `bomb_player_clearance` from every blob when it can.
@export var bomb_extent: float = 4.5
@export var bomb_player_clearance: float = 2.0

@export_group("End")
## Seconds the finished floor stays frozen on screen before the ranking goes out.
@export var final_freeze: float = 2.0

@export_group("Bots")
## Share of goal picks that stay out of the leader's shove range.
@export var bot_avoid_leader: float = 0.5
## Bots avoid goals this close (m) to the leader when they do.
@export var bot_leader_range: float = 2.2

@export_group("Test")
## Test-only: multiplies the round clock (bombs, time limit, freeze). The clock also follows
## Session.time_scale, so it agrees with Session's backstop.
@export var time_scale: float = 1.0
## Test-only: when false no bombs drop by themselves (tests call spawn_bomb).
@export var bombs_enabled: bool = true
## Seed for the host's RNG (bomb spots); -1 = random.
@export var rng_seed: int = -1

# --- State (every peer, changed only by the host's RPCs) ------------------------------------

## tile index -> owner slot (UNPAINTED = -1). Index = iz * GRID + ix.
var owners: PackedInt32Array = PackedInt32Array()
## slot -> tiles owned.
var counts: Dictionary[int, int] = {}
## The ranking of the finished round (empty until then).
var final_ranking: Array[int] = []

var _slots: Array[int] = []
var _colors: Dictionary[int, Color] = {}
## slot -> {count: round time it was first reached} (tie-break).
var _first_reached: Dictionary = {}
var _running: bool = false
var _over: bool = false
var _t: float = 0.0
var _rng := RandomNumberGenerator.new()
## Host: victim slot -> [shover slot, round time of the hit, seen stunned].
var _stun_by: Dictionary[int, Array] = {}
## id -> {pos: Vector3, t0: float, node: Node3D, arrow: Node3D, ring: Node3D}
var _bombs: Dictionary[int, Dictionary] = {}
var _next_bomb_id: int = 1
var _next_bomb_t: float = 0.0
## Host: round time at which the frozen floor hands over to Session.
var _finish_at: float = INF
## Host: goal picks per bot (drives the "sometimes" of leader avoidance).
var _goal_calls: Dictionary[int, int] = {}
## tile -> seconds since its colour changed (pop animation), every peer.
var _pops: Dictionary[int, float] = {}
var _multimesh: MultiMesh = null

## Built once and shared by every Paint Splat (never freed with the nodes; see Look).
static var _tile_mesh: Mesh = null
static var _ring_material: StandardMaterial3D = null
static var _ring_mesh: PlaneMesh = null
static var _shadow_material: StandardMaterial3D = null

@onready var _bombs_root: Node3D = $Bombs
@onready var _camera: ArenaCamera = $ArenaCamera


func _ready() -> void:
	owners.resize(TILE_COUNT)
	owners.fill(UNPAINTED)
	_build_floor()
	_build_walls()
	_build_decor()
	_build_colliders()


# --- Minigame flow ------------------------------------------------------------------------

func _setup(round_players: Array[Player]) -> void:
	counts.clear()
	_first_reached.clear()
	_slots.clear()
	_colors.clear()
	for p in round_players:
		_slots.append(p.slot)
		counts[p.slot] = 0
		_first_reached[p.slot] = {0: 0.0}
		_colors[p.slot] = Look.parse_color(p.loadout.get("primary", ""), Color.WHITE)
		p.got_hit.connect(_on_got_hit.bind(p.slot))


func _start() -> void:
	if not Net.is_host():
		return
	if rng_seed >= 0:
		_rng.seed = rng_seed
	else:
		_rng.randomize()
	_rpc_begin.rpc()


func _host_tick(_delta: float) -> void:
	if not _running:
		return
	if _over:
		if _t >= _finish_at:
			finish(final_ranking)
		return
	_rescue_fallen()
	var claims: Dictionary[int, int] = {}
	for p in players:
		if not _live(p) or p.frozen:
			continue
		var feet := p.global_position
		if feet.y > paint_height or feet.y < -0.5:
			continue
		var shover := _stunner(p)
		if shover >= 0:
			for i in tiles_within(feet, stun_paint_radius):
				_claim(claims, i, shover)
		elif not p.control_locked:
			var i := tile_at(feet)
			if i >= 0:
				_claim(claims, i, p.slot)
	if bombs_enabled and _t >= _next_bomb_t:
		_next_bomb_t += bomb_interval
		if time_limit <= 0.0 or _t + bomb_fall_time + 1.0 < time_limit:
			spawn_bomb(_pick_bomb_spot())
	_grab_bombs(claims)
	_flush(claims)
	if time_limit > 0.0 and _t >= time_limit:
		end_round()


func _physics_process(delta: float) -> void:
	if _running:
		_t += delta * _clock_scale()


func _process(delta: float) -> void:
	_animate_pops(delta)
	_animate_bombs()


## Host: ends the round now with the tile ranking (also called at the time limit). The floor
## stays frozen for `final_freeze` before finish().
func end_round() -> void:
	if _over or is_finished():
		return
	var ranking := rank_by_tiles(_slots, counts, _reach_times())
	var n := PackedInt32Array()
	for s in ranking:
		n.append(counts.get(s, 0))
	_finish_at = _t + final_freeze * _clock_scale()
	_rpc_end.rpc(PackedInt32Array(ranking), n)


## Seconds on the round clock since play started (every peer).
func round_time() -> float:
	return _t


# --- Tiles (pure queries) ------------------------------------------------------------------

## The tile under `pos` (horizontal), or -1 off the floor.
static func tile_at(pos: Vector3) -> int:
	var ix := floori((pos.x + HALF) / TILE)
	var iz := floori((pos.z + HALF) / TILE)
	if ix < 0 or iz < 0 or ix >= GRID or iz >= GRID:
		return -1
	return iz * GRID + ix


## Top centre of tile `i`.
static func tile_center(i: int) -> Vector3:
	return Vector3((float(i % GRID) + 0.5) * TILE - HALF, 0.0, (float(i / GRID) + 0.5) * TILE - HALF)


## Tiles whose centre is within `radius` of `pos` (horizontal); radius 0 gives the tile under it.
static func tiles_within(pos: Vector3, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	if radius <= 0.0:
		var i := tile_at(pos)
		if i >= 0:
			out.append(i)
		return out
	var r2 := radius * radius
	var x0 := maxi(0, floori((pos.x - radius + HALF) / TILE))
	var x1 := mini(GRID - 1, floori((pos.x + radius + HALF) / TILE))
	var z0 := maxi(0, floori((pos.z - radius + HALF) / TILE))
	var z1 := mini(GRID - 1, floori((pos.z + radius + HALF) / TILE))
	for iz in range(z0, z1 + 1):
		for ix in range(x0, x1 + 1):
			var i := iz * GRID + ix
			var c := tile_center(i)
			if Vector2(c.x - pos.x, c.z - pos.z).length_squared() <= r2:
				out.append(i)
	if out.is_empty():
		var i := tile_at(pos)
		if i >= 0:
			out.append(i)
	return out


## Owner slot of tile `i` (UNPAINTED = -1).
func tile_owner(i: int) -> int:
	return owners[i]


## Paint colour of `slot` (its loadout primary).
func slot_color(slot: int) -> Color:
	return _colors.get(slot, FLOOR_COLOR)


# --- Host: paint ------------------------------------------------------------------------------

func _claim(claims: Dictionary[int, int], tile: int, slot: int) -> void:
	var cur: int = claims.get(tile, UNPAINTED)
	if cur == UNPAINTED:
		claims[tile] = slot
	elif cur != slot:
		claims[tile] = CONTESTED


## Sends this tick's real changes (if any) in one batch.
func _flush(claims: Dictionary[int, int]) -> void:
	var tiles := PackedInt32Array()
	var slots := PackedInt32Array()
	for i: int in claims:
		var s: int = claims[i]
		if s >= 0 and owners[i] != s:
			tiles.append(i)
			slots.append(s)
	if not tiles.is_empty():
		_rpc_paint.rpc(tiles, slots)


## The shover a stunned `p` paints for, or -1. Host.
func _stunner(p: Player) -> int:
	if not _stun_by.has(p.slot):
		return -1
	var e: Array = _stun_by[p.slot]
	if p.control_locked:
		e[2] = true
		return int(e[0])
	if bool(e[2]) or _t - float(e[1]) > stun_window * _clock_scale():
		_stun_by.erase(p.slot)
	return -1


func _on_got_hit(_impulse: Vector3, source_slot: int, slot: int) -> void:
	if not Net.is_host() or not _running or _over:
		return
	if source_slot >= 0 and source_slot != slot and _slots.has(source_slot):
		_stun_by[slot] = [source_slot, _t, false]


func _rescue_fallen() -> void:
	var points := get_spawn_points()
	for i in players.size():
		var p := players[i]
		if _live(p) and p.global_position.y < -3.0 and not points.is_empty():
			p.respawn_at(points[i % points.size()])


# --- Host: splash bombs -------------------------------------------------------------------------

## Host: drops a splash bomb onto (pos.x, pos.z). Returns its id.
func spawn_bomb(pos: Vector3) -> int:
	var id := _next_bomb_id
	_next_bomb_id += 1
	_rpc_bomb.rpc(id, Vector3(pos.x, 0.0, pos.z))
	request_bot_rethink()
	return id


## Ids of the bombs on the floor or falling.
func bomb_ids() -> Array[int]:
	var out: Array[int] = []
	out.assign(_bombs.keys())
	return out


func get_bomb_position(id: int) -> Vector3:
	return (_bombs[id]["pos"] as Vector3) if _bombs.has(id) else Vector3.INF


func bomb_landed(id: int) -> bool:
	return _bombs.has(id) and _t - float(_bombs[id]["t0"]) >= bomb_fall_time


## First come first served: each landed bomb goes to the nearest blob touching it.
func _grab_bombs(claims: Dictionary[int, int]) -> void:
	for id in bomb_ids():
		if not bomb_landed(id):
			continue
		var pos := get_bomb_position(id)
		var best := -1
		var best_d := INF
		for p in players:
			if not _live(p) or p.frozen:
				continue
			var feet := p.global_position
			var d := Vector2(feet.x - pos.x, feet.z - pos.z).length()
			if d <= bomb_reach and feet.y < 1.2 and d < best_d:
				best_d = d
				best = p.slot
		if best < 0:
			continue
		_rpc_splash.rpc(id, best)
		for i in tiles_within(pos, splash_radius):
			claims[i] = best  # a splash beats this tick's footsteps
		request_bot_rethink()


## A tile centre near the middle, clear of every blob when possible.
func _pick_bomb_spot() -> Vector3:
	var n := int(bomb_extent / TILE)
	var best := Vector3.ZERO
	var best_clear := -INF
	for attempt in 16:
		var c := Vector3((_rng.randi_range(-n, n - 1) + 0.5) * TILE, 0.0, (_rng.randi_range(-n, n - 1) + 0.5) * TILE)
		var clear := INF
		for p in players:
			if _live(p):
				clear = minf(clear, Vector2(p.global_position.x - c.x, p.global_position.z - c.z).length())
		if clear >= bomb_player_clearance:
			return c
		if clear > best_clear:
			best_clear = clear
			best = c
	return best


# --- Replicated (host -> every peer, host included) --------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_begin() -> void:
	_t = 0.0
	_running = true
	_over = false
	_next_bomb_t = bomb_interval
	for s in _slots:
		_set_count(s, counts.get(s, 0))
	RoundUI.push_banner("Paint the floor!", 1.6)


@rpc("authority", "call_local", "reliable")
func _rpc_paint(tiles: PackedInt32Array, slots: PackedInt32Array) -> void:
	var changed := PackedInt32Array()
	var changed_slots := PackedInt32Array()
	var touched: Dictionary[int, bool] = {}
	for k in mini(tiles.size(), slots.size()):
		var i := tiles[k]
		var s := slots[k]
		if i < 0 or i >= TILE_COUNT or owners[i] == s:
			continue
		var old := owners[i]
		owners[i] = s
		if old >= 0:
			counts[old] = counts.get(old, 0) - 1
			touched[old] = true
		counts[s] = counts.get(s, 0) + 1
		touched[s] = true
		changed.append(i)
		changed_slots.append(s)
		_pops[i] = 0.0
		if _multimesh:
			_multimesh.set_instance_color(i, _tile_color(i).lightened(0.45))
	for s: int in touched:
		_set_count(s, counts[s])
	if not changed.is_empty():
		tiles_painted.emit(changed, changed_slots)


@rpc("authority", "call_local", "reliable")
func _rpc_bomb(id: int, pos: Vector3) -> void:
	var root := Node3D.new()
	root.name = "Bomb%d" % id
	_bombs_root.add_child(root)
	var bucket := BUCKET_SCENE.instantiate() as Node3D
	bucket.scale = Vector3.ONE * BUCKET_SCALE
	Look.apply_toon(bucket)
	root.add_child(bucket)
	bucket.position = pos + Vector3.UP * bomb_height
	var arrow := ARROW_SCENE.instantiate() as Node3D
	arrow.scale = Vector3.ONE * 1.3
	Look.apply_toon(arrow)
	root.add_child(arrow)
	arrow.position = pos + Vector3.UP * ARROW_HEIGHT
	var ring := MeshInstance3D.new()
	ring.mesh = _get_ring_mesh()
	ring.material_override = _ring_material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.scale = Vector3(splash_radius * 2.0 + 1.0, 1.0, splash_radius * 2.0 + 1.0)
	root.add_child(ring)
	ring.position = pos + Vector3.UP * 0.03
	var shadow := MeshInstance3D.new()
	shadow.mesh = _ring_mesh
	shadow.material_override = _shadow_material
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(shadow)
	shadow.position = pos + Vector3.UP * 0.04
	_bombs[id] = {"pos": pos, "t0": _t, "node": root, "bucket": bucket, "arrow": arrow, "ring": ring,
		"shadow": shadow, "landed": false}
	RoundUI.push_banner("SPLASH BOMB!", 1.5)
	Sfx.play(&"bomb_tick", pos)
	bomb_spawned.emit(id, pos)


@rpc("authority", "call_local", "reliable")
func _rpc_splash(id: int, slot: int) -> void:
	var b: Dictionary = _bombs.get(id, {})
	_bombs.erase(id)
	var pos: Vector3 = b.get("pos", Vector3.ZERO)
	var node := b.get("node") as Node3D
	if node and is_instance_valid(node):
		node.queue_free()
	var col := slot_color(slot)
	Fx.play(&"explosion", pos + Vector3.UP * 0.4, col)
	Sfx.play(&"explosion", pos, -9.0, 1.3)
	if _camera:
		_camera.add_shake(0.25)
	bomb_claimed.emit(id, slot)


@rpc("authority", "call_local", "reliable")
func _rpc_end(ranking: PackedInt32Array, tile_counts: PackedInt32Array) -> void:
	_over = true
	# Keep Session's time-limit backstop (time_limit + its grace) behind the frozen final splat.
	if time_limit > 0.0:
		time_limit += final_freeze + 0.5
	final_ranking.clear()
	for k in ranking.size():
		final_ranking.append(ranking[k])
		if k < tile_counts.size() and counts.get(ranking[k], -1) != tile_counts[k]:
			_set_count(ranking[k], tile_counts[k])
	for p in players:
		if is_instance_valid(p):
			p.frozen = true
	for id in bomb_ids():
		var node := _bombs[id].get("node") as Node3D
		if node and is_instance_valid(node):
			var arrow := _bombs[id].get("arrow") as Node3D
			if arrow:
				arrow.visible = false
	RoundUI.push_banner("FINAL SPLAT!", final_freeze)
	if not final_ranking.is_empty():
		var winner := _player(final_ranking[0])
		if winner and winner.alive:
			var vis := winner.get_component(&"visuals") as VisualsComponent
			if vis:
				vis.play_emote(&"cheer")
			Fx.play(&"confetti", winner.global_position + Vector3.UP * 1.2)
	round_over.emit(final_ranking.duplicate())


# --- Ranking ------------------------------------------------------------------------------------

## `slots` by tiles (desc), then by who first reached that count (earlier first), then slot.
static func rank_by_tiles(slots: Array[int], tile_counts: Dictionary, reached_at: Dictionary) -> Array[int]:
	var out: Array[int] = slots.duplicate()
	out.sort_custom(func(a: int, b: int) -> bool:
		var ca: int = tile_counts.get(a, 0)
		var cb: int = tile_counts.get(b, 0)
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
		out[s] = float(hist.get(counts.get(s, 0), 0.0))
	return out


# --- Bots ----------------------------------------------------------------------------------------

## A reachable splash bomb first; else the best 3x3 cluster of tiles not in the bot's colour,
## nearer is better, with a little personal taste; about half the picks stay out of the
## leader's shove range.
func get_bot_goal(player: Player) -> Vector3:
	if player == null:
		return Vector3.ZERO
	var pos := player.global_position
	var me := player.slot
	# Splash bomb: go if nobody is clearly closer.
	var bomb_best := Vector3.INF
	var bomb_d := INF
	for id in bomb_ids():
		var bp := get_bomb_position(id)
		var d := Vector2(bp.x - pos.x, bp.z - pos.z).length()
		var closer := false
		for o in players:
			if o != player and _live(o) and Vector2(bp.x - o.global_position.x, bp.z - o.global_position.z).length() + 1.5 < d:
				closer = true
				break
		if not closer and d < bomb_d:
			bomb_d = d
			bomb_best = bp
	if bomb_best != Vector3.INF:
		return bomb_best
	var calls: int = _goal_calls.get(me, 0) + 1
	_goal_calls[me] = calls
	var leader := _leader(me)
	var avoid := leader != null and _hash01(me * 7919 + calls * 104729) < bot_avoid_leader
	var best := -1
	var best_score := -INF
	for i in TILE_COUNT:
		var c := tile_center(i)
		var d := Vector2(c.x - pos.x, c.z - pos.z).length()
		if d < 0.9:
			continue
		var n := 0.0
		var ix := i % GRID
		var iz := i / GRID
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var jx := ix + dx
				var jz := iz + dz
				if jx < 0 or jz < 0 or jx >= GRID or jz >= GRID:
					continue
				var o := owners[jz * GRID + jx]
				if o == me:
					continue
				n += 1.0 if o == UNPAINTED else 1.15
		if n <= 0.0:
			continue
		var score := n / (d + 2.5) * (1.0 + 0.25 * _hash01(me * 31337 + i * 7727 + calls))
		if avoid and Vector2(c.x - leader.global_position.x, c.z - leader.global_position.z).length() < bot_leader_range:
			score *= 0.25
		if score > best_score:
			best_score = score
			best = i
	if best >= 0:
		return tile_center(best)
	var a := TAU * float(me) / 8.0 + _t * 0.3
	return Vector3(sin(a), 0.0, cos(a)) * 4.0


## Inside the walls.
func is_safe(pos: Vector3) -> bool:
	return absf(pos.x) <= HALF - SAFE_MARGIN and absf(pos.z) <= HALF - SAFE_MARGIN


## The living leader other than `me` (most tiles), or null.
func _leader(me: int) -> Player:
	var best: Player = null
	var best_n := 0
	for p in players:
		if p.slot == me or not _live(p):
			continue
		var n: int = counts.get(p.slot, 0)
		if n > best_n:
			best_n = n
			best = p
	return best


# --- Presentation (every peer) --------------------------------------------------------------------

func _tile_color(i: int) -> Color:
	var s := owners[i]
	return FLOOR_COLOR if s < 0 else slot_color(s)


func _animate_pops(delta: float) -> void:
	if _pops.is_empty() or _multimesh == null:
		return
	var done: Array[int] = []
	for i: int in _pops:
		var age: float = _pops[i] + delta
		_pops[i] = age
		var k := clampf(age / POP_TIME, 0.0, 1.0)
		var lift := sin(k * PI) * POP_LIFT
		var s := 1.0 + sin(k * PI) * 0.05
		_multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(s, 1.0, s)), tile_center(i) + Vector3.UP * lift))
		_multimesh.set_instance_color(i, _tile_color(i).lightened(0.45 * (1.0 - k)))
		if k >= 1.0:
			done.append(i)
	for i in done:
		_pops.erase(i)


func _animate_bombs() -> void:
	for id: int in _bombs:
		var b: Dictionary = _bombs[id]
		var pos: Vector3 = b["pos"]
		var age := _t - float(b["t0"])
		var k := clampf(age / maxf(bomb_fall_time, 0.01), 0.0, 1.0)
		var bucket := b["bucket"] as Node3D
		var shadow := b["shadow"] as Node3D
		var ring := b["ring"] as Node3D
		var arrow := b["arrow"] as Node3D
		if bucket == null or not is_instance_valid(bucket):
			continue
		if k < 1.0:
			bucket.position = pos + Vector3.UP * bomb_height * (1.0 - k * k)
			bucket.rotation.y = age * 5.0
		else:
			if not bool(b["landed"]):
				b["landed"] = true
				Fx.play(&"land_thud", pos, Color(1.0, 0.9, 0.6))
				Sfx.play(&"land_hard", pos)
				if _camera:
					_camera.add_shake(0.12)
			var wob := sin(age * 7.0) * 0.06
			bucket.position = pos
			bucket.rotation = Vector3(wob, age * 1.2, -wob * 0.6)
		var sk := lerpf(0.4, 1.2, k)
		shadow.scale = Vector3(sk, 1.0, sk)
		var pulse := 1.0 + 0.04 * sin(age * 6.0)
		var rs := splash_radius * 2.0 + 1.0
		ring.scale = Vector3(rs * pulse, 1.0, rs * pulse)
		arrow.position = pos + Vector3.UP * (ARROW_HEIGHT + 0.15 * sin(age * 4.0))
		arrow.rotation.y = age * 2.0


# --- Building -------------------------------------------------------------------------------------

func _build_floor() -> void:
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.mesh = _get_tile_mesh()
	_multimesh.instance_count = TILE_COUNT
	for i in TILE_COUNT:
		_multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, tile_center(i)))
		_multimesh.set_instance_color(i, FLOOR_COLOR)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "TileField"
	mmi.multimesh = _multimesh
	$Tiles.add_child(mmi)
	# Studio floorboards around the tiles.
	var ground := MeshInstance3D.new()
	ground.name = "Surround"
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	ground.mesh = plane
	ground.material_override = Look.toon_material(Color("#9a6b4a"), 0.8, false)
	ground.position = Vector3(0.0, -0.05, 0.0)
	$Tiles.add_child(ground)


## The paint_tile mesh with toon materials; `PaintTop` takes the per-instance colour.
static func _get_tile_mesh() -> Mesh:
	if _tile_mesh != null:
		return _tile_mesh
	var src := TILE_SCENE.instantiate() as Node3D
	var mi: MeshInstance3D = src as MeshInstance3D
	if mi == null:
		mi = src.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var mesh := mi.mesh.duplicate() as Mesh
	for s in mesh.get_surface_count():
		var m := mesh.surface_get_material(s)
		var toon := Look.toon_from(m, false)
		if m and m.resource_name == "PaintTop":
			var paint := (toon as BaseMaterial3D).duplicate() as BaseMaterial3D
			paint.resource_name = "PaintTop"
			paint.albedo_color = Color.WHITE
			paint.vertex_color_use_as_albedo = true
			paint.vertex_color_is_srgb = true
			toon = paint
		(mesh as ArrayMesh).surface_set_material(s, toon)
	src.free()
	_tile_mesh = mesh
	return _tile_mesh


func _build_walls() -> void:
	var walls := $Walls as Node3D
	for side in 4:
		var rot := Basis(Vector3.UP, side * PI * 0.5)
		for half in [-1.0, 1.0]:
			var w := WALL_SCENE.instantiate() as Node3D
			w.transform = Transform3D(rot, rot * Vector3(half * HALF * 0.5, 0.0, -HALF))
			walls.add_child(w)
	Look.apply_toon(walls)


## Easels and paint cans outside the walls (visual only).
func _build_decor() -> void:
	var decor := $Decor as Node3D
	var spots: Array = [
		[EASEL_SCENE, Vector3(-4.6, 0.0, -8.3), 0.25, 1.15],
		[EASEL_SCENE, Vector3(3.2, 0.0, -8.4), -0.2, 1.1],
		[EASEL_SCENE, Vector3(-8.4, 0.0, -1.8), 1.3, 1.1],
		[EASEL_SCENE, Vector3(8.4, 0.0, 2.6), -1.4, 1.1],
		[CANS_SCENE, Vector3(0.4, 0.0, -8.2), 0.4, 1.4],
		[CANS_SCENE, Vector3(-8.2, 0.0, -6.8), 2.2, 1.4],
		[CANS_SCENE, Vector3(8.3, 0.0, -5.2), -0.9, 1.4],
		[CANS_SCENE, Vector3(-8.3, 0.0, 4.4), 1.0, 1.3],
	]
	for s: Array in spots:
		var n := (s[0] as PackedScene).instantiate() as Node3D
		n.position = s[1]
		n.rotation.y = s[2]
		n.scale = Vector3.ONE * float(s[3])
		decor.add_child(n)
	Look.apply_toon(decor)


func _build_colliders() -> void:
	var body := StaticBody3D.new()
	body.name = "Colliders"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	_add_box(body, Vector3(HALF * 2.0 + 8.0, 1.0, HALF * 2.0 + 8.0), Vector3(0.0, -0.5, 0.0))
	for side in 4:
		var rot := Basis(Vector3.UP, side * PI * 0.5)
		var cs := _add_box(body, Vector3(HALF * 2.0 + 2.0, WALL_HEIGHT, 1.0), rot * Vector3(0.0, WALL_HEIGHT * 0.5, -HALF - 0.5))
		cs.basis = rot


func _add_box(body: StaticBody3D, size: Vector3, at: Vector3) -> CollisionShape3D:
	var box := BoxShape3D.new()
	box.size = size
	var cs := CollisionShape3D.new()
	cs.shape = box
	cs.position = at
	body.add_child(cs)
	return cs


## A soft ring on the floor (the splash radius) and a round shadow (where the bomb lands).
static func _get_ring_mesh() -> PlaneMesh:
	if _ring_mesh == null:
		_ring_mesh = PlaneMesh.new()
		_ring_mesh.size = Vector2.ONE
		_ring_material = _radial_material([
			[0.0, Color(1, 1, 1, 0.0)], [0.78, Color(1, 1, 1, 0.0)], [0.86, Color(1, 1, 1, 1.0)],
			[0.93, Color(1, 1, 1, 0.0)], [1.0, Color(1, 1, 1, 0.0)]], RING_COLOR, true)
		_shadow_material = _radial_material([
			[0.0, Color(0, 0, 0, 0.55)], [0.6, Color(0, 0, 0, 0.35)], [1.0, Color(0, 0, 0, 0.0)]],
			Color.WHITE, false)
	return _ring_mesh


static func _radial_material(stops: Array, tint: Color, additive: bool) -> StandardMaterial3D:
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for st: Array in stops:
		offsets.append(float(st[0]))
		colors.append(st[1] as Color)
	g.offsets = offsets
	g.colors = colors
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 128
	tex.height = 128
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_texture = tex
	m.albedo_color = tint
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return m


# --- Helpers --------------------------------------------------------------------------------------

func _clock_scale() -> float:
	return time_scale * Session.time_scale


func _set_count(slot: int, count: int) -> void:
	count = maxi(count, 0)
	counts[slot] = count
	var hist: Dictionary = _first_reached.get(slot, {})
	if not hist.has(count):
		hist[count] = _t
	_first_reached[slot] = hist
	RoundUI.push_counter(slot, count)
	counts_changed.emit(slot, count)


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
