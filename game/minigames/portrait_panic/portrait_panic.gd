class_name PortraitPanic
extends Minigame
## Portrait Panic: the mansion gallery. A floating floor of GRID x GRID picture tiles, each
## showing one of eight bold symbols (shape AND colour differ). Every loop:
##   SHUFFLE  the tiles flip to a new layout (`shuffle_time` s to look at it);
##   SHOW     the huge portrait on the back wall (and the HUD banner) shows the target
##            symbol; `show_len` s to get onto a tile showing it (shoving allowed);
##   DROP     every other tile drops away for `drop_time` s (colliders off on every peer at
##            the same moment): blobs on them fall and are out (`fell`). Then they rise again.
## Over the loops the target tiles get fewer (8 -> 2), the symbols more (4 -> 8) and SHOW
## shorter (4.5 s -> 2.0 s). From loop `twist_from_loop` + 1 each loop draws a twist:
##   MEMORY  1 s into SHOW the tiles flip face down: remember where the target was;
##   DECOY   the portrait shows a first symbol, then flips to the second: only that counts;
##   SWAP    during SHOW two rows of tiles dive under the floor, slide past each other and
##           come up in each other's places (tiles never rise through a blob, nor do flips).
## Last blob standing wins. Everyone who falls in the same DROP ties for that place (a tied
## group, ordered by nothing); at `time_limit` the survivors tie for first.
##
## Networking (docs/contract.md "Networking rules for minigames"): the host runs the phase
## clock and decides everything. Each loop it sends the whole layout, target, twist, decoy and
## swap rows in one reliable call_local RPC (`_rpc_loop`), then one RPC per event (`_rpc_show`,
## `_rpc_hide`, `_rpc_reveal`, `_rpc_swap`, `_rpc_drop` with the exact cells, `_rpc_end`). Every
## peer applies them the same way (colliders, layout, visuals), so the floor matches
## everywhere. Knock-outs go through Player.eliminate on the host.
##
## Rendering: one MultiMeshInstance3D holds every tile (a code-built box whose top face shows
## the picture and bottom face the card back); one ShaderMaterial draws the symbols as signed
## distance fields from the per-instance custom data (symbol, glow, fade), so there are no
## per-tile materials and no textures, and the symbols stay crisp at any resolution. A flip is
## a turn of the instance transform about X. The big portrait and the HUD icon use the same
## symbol shapes (portrait_symbols.gdshaderinc).
##
## Bots: `get_bot_goal` during SHOW is a target tile picked per bot (nearest, spread over the
## target tiles), after a skill-based reading delay; under MEMORY and DECOY (and, rarely, from
## loop 3 on any loop) a bot may get it wrong (lower skill, more often), and then believes its
## wrong tile is safe. `is_safe` is "over a tile that will not drop": during SHOW (once read)
## the target tiles plus the centre of each wrongly believed tile, otherwise any tile still
## there; never the rim. `bot_aggression_scale`: no shoving while shuffling, dropping or in
## the first two loops, then a growing scrum. `request_bot_rethink` at every phase.
##
## Dev args (after `--`): `--portrait-time-scale=<x>` speeds up the host's phase clock;
## `--portrait-twist=memory[,decoy,swap...]` forces those twists on the first loops, in order
## (screenshots, the network check).

## Every peer: a loop began (SHUFFLE) with this layout (one symbol per cell), target and twist.
signal loop_started(index: int, layout: PackedByteArray, target: int, twist: int)
## Every peer: SHOW began; `shown_symbol` is what the portrait shows first (the decoy under DECOY).
signal show_started(index: int, shown_symbol: int)
## Every peer: MEMORY turned every tile face down.
signal faces_hidden(index: int)
## Every peer: DECOY flipped the portrait to the real target.
signal decoy_revealed(index: int, target: int)
## Every peer: SWAP traded rows `row_a` and `row_b` (the layout already changed).
signal rows_swapped(index: int, row_a: int, row_b: int)
## Every peer: these cells dropped (colliders already off).
signal dropped(index: int, cells: PackedInt32Array)
## Host: `slot` fell during loop `index` (knocked out right after).
signal player_fell(slot: int, index: int)
## Every peer, once the host's spawn layout is applied.
signal spawn_layout_applied(turn: float, slots: PackedInt32Array)
## Every peer: the round is over; `winners` are the survivors (empty if the last ones fell together).
signal round_over(winners: PackedInt32Array)

enum Phase { IDLE, SHUFFLE, SHOW, DROP, OVER }
enum Twist { NONE, MEMORY, DECOY, SWAP }

const FRAME_SCENE: PackedScene = preload("res://assets/models/props/portrait_frame_big.glb")
const TILE_SHADER: Shader = preload("res://minigames/portrait_panic/portrait_tile.gdshader")
const CANVAS_SHADER: Shader = preload("res://minigames/portrait_panic/portrait_canvas.gdshader")
const ICON_SHADER: Shader = preload("res://minigames/portrait_panic/portrait_icon.gdshader")
const WALL_SHADER: Shader = preload("res://minigames/portrait_panic/portrait_wall.gdshader")
const ENV_DIR := "res://assets/models/env/"

## Cells per side; a cell index is row * GRID + col (row along +Z, col along +X).
const GRID := 7
const CELLS := GRID * GRID
## Tile size and the gap between tiles (m); tile tops at y = 0.
const TILE := 1.6
const GAP := 0.12
const PITCH := TILE + GAP
const HALF := GRID * PITCH * 0.5
const THICK := 0.24
## SWAP: seconds a row takes to slide home, and how deep (m) the upper of the two rows dives
## (the other goes a tile deeper), below every tile in between.
const SLIDE_TIME := 0.9
const SLIDE_DEPTH := THICK + 0.12
const SYMBOL_COUNT := 8
const SYMBOL_NAMES: Array[String] = [
	"RED CIRCLE", "BLUE SQUARE", "YELLOW TRIANGLE", "GREEN STAR",
	"PURPLE DIAMOND", "ORANGE MOON", "WHITE CROSS", "TEAL HEART",
]
## HUD colours of the symbol names (sRGB, as in portrait_symbols.gdshaderinc).
const SYMBOL_COLORS: Array[Color] = [
	Color(0.925, 0.2, 0.18), Color(0.3, 0.58, 1.0), Color(1.0, 0.83, 0.13), Color(0.3, 0.84, 0.35),
	Color(0.8, 0.52, 1.0), Color(1.0, 0.56, 0.1), Color(0.975, 0.965, 0.94), Color(0.12, 0.85, 0.8),
]
const TWIST_NAMES: Array[String] = ["", "MEMORY", "DECOY", "SWAP"]
const TWIST_HINTS: Array[String] = [
	"", "The tiles hide 1 s after the portrait shows!", "Only the SECOND symbol counts!",
	"Two rows will swap places!",
]
## Spawn ring radius (m): two tiles out from the centre.
const SPAWN_RADIUS := 3.4
## Positions inside a tile where several bots heading for it stand (m).
const SPOTS: Array[Vector3] = [
	Vector3.ZERO, Vector3(0.38, 0.0, 0.38), Vector3(-0.38, 0.0, -0.38), Vector3(0.38, 0.0, -0.38),
	Vector3(-0.38, 0.0, 0.38),
]

# --- Room ----------------------------------------------------------------------------------
const WALL_Z := -9.6
const SIDE_X := 13.5
const VOID_Y := -16.0
## The portrait: frame origin (bottom centre of its back) and the canvas (its opening).
const PORTRAIT_POS := Vector3(0.0, 1.7, WALL_Z)
const CANVAS_SIZE := Vector2(6.2, 4.0)
const CANVAS_CENTER := Vector3(0.0, 2.5, 0.07)

@export_group("Rules")
## Seconds of SHUFFLE (the new layout flips in; look at it).
@export var shuffle_time: float = 2.0
## SHOW length of the first loop, the shrink per loop and the floor (s).
@export var show_start: float = 4.5
@export var show_step: float = 0.35
@export var show_min: float = 2.0
## Extra SHOW seconds under a twist (MEMORY, DECOY, SWAP), so it stays fair.
@export var twist_bonus: Vector3 = Vector3(0.5, 0.8, 0.8)
## Seconds the non-target tiles stay away.
@export var drop_time: float = 2.0
## Target tiles in loop 0, fewer by one per loop down to `targets_min`.
@export var targets_start: int = 8
@export var targets_min: int = 2
## Symbols in play in loop 0, one more per loop up to 8.
@export var symbols_start: int = 4
## Loop index (0-based) from which every loop draws a twist.
@export var twist_from_loop: int = 3
## MEMORY: seconds into SHOW when the tiles flip face down.
@export var memory_hide_at: float = 1.0
## DECOY: share of SHOW the first (wrong) symbol stays on the portrait.
@export var decoy_share: float = 0.38
## SWAP: share of SHOW when the rows start sliding.
@export var swap_share: float = 0.3
## A player whose feet drop below this (m, local) is out.
@export var fall_y: float = -2.5
## Seconds the finished floor stays on screen (Session's end grace).
@export var end_grace: float = 2.0
## Host RNG seed (layouts, targets, twists); 0 = random. Tests may also reseed `rng`.
@export var rng_seed: int = 0

@export_group("Bots")
## Seconds into SHOW (and after a DECOY reveal) during which every tile counts as safe for
## bots: they are still reading the portrait.
@export var bot_read_time: float = 0.5
## Chance (low skill, high skill) that a bot gets MEMORY / DECOY wrong.
@export var bot_error: Vector2 = Vector2(0.55, 0.1)
## Chance (low skill, high skill) that a bot misreads a plain loop (picks a tile next to a
## target); none in the first two loops, full from loop 5.
@export var bot_misread: Vector2 = Vector2(0.2, 0.04)
## A tile a bot wrongly believes in counts as safe only this close (m) to its centre: is_safe
## has no per-bot view, and a whole "safe" wrong tile drew neighbouring bots onto it too.
@export var bot_belief_radius: float = 0.45
## Seconds (low skill, high skill) before a bot heads for its tile.
@export var bot_react: Vector2 = Vector2(1.0, 0.3)
## Metres a tile already picked by another bot counts extra (spreads bots over targets).
@export var bot_crowd_penalty: float = 2.4

## Round music for the music director.
var music_track: StringName = &"vault_jazz"
## Bot brain hint (BotBrain reads it): no chasing or shoving while the floor shuffles or
## drops (a crowd walking about), a scrum during SHOW. Set by the phase RPCs.
var bot_aggression_scale: float = 0.0
## The SHOW hint: 0 (no shoving) for the first BOT_CALM_LOOPS loops, then BOT_AGGRESSION_STEP
## more per loop up to BOT_AGGRESSION_MAX: early loops are about finding the tile, late ones
## (fewer, smaller targets) about holding it. Bots shove hard: a scrum on a rim tile sends
## blobs off the floor, so too much of it early ends rounds before the floor gets hard.
const BOT_CALM_LOOPS := 2
const BOT_AGGRESSION_STEP := 0.15
const BOT_AGGRESSION_MAX := 0.6
## Test/dev only: multiplies the host's phase clock (not the walking).
var time_scale: float = 1.0
## Host: layouts, targets, twists. Seeded in `_start` (from `rng_seed`); tests may reseed it.
var rng := RandomNumberGenerator.new()
## Host: bot choices (spread order, errors, reaction times, shuffle goals).
var bot_rng := RandomNumberGenerator.new()
## Host, tests/dev: when >= 0 the next loop uses this twist (then it resets).
var next_twist: int = -1

# --- Every peer (set by the host's RPCs) ----------------------------------------------------
var phase: Phase = Phase.IDLE
## Loop index (0-based; -1 before the first).
var loop_index: int = -1
## The symbol on every cell (CELLS bytes).
var layout: PackedByteArray = PackedByteArray()
var target: int = 0
var twist: Twist = Twist.NONE
## DECOY: the first (wrong) symbol; -1 otherwise.
var decoy: int = -1
## SWAP: the two rows; (-1, -1) otherwise.
var swap_rows: Vector2i = Vector2i(-1, -1)
## SHOW seconds this loop.
var show_len: float = 4.5
## MEMORY: the tiles are face down.
var faces_down: bool = false
## DECOY: the portrait still shows the first (wrong) symbol.
var decoy_showing: bool = false
## SWAP: the rows have traded places this loop.
var swapped: bool = false
## Cells whose tile is away (dropped), 1 = gone.
var gone: PackedByteArray = PackedByteArray()

# --- Host -----------------------------------------------------------------------------------
## Seconds since GO (round clock, for the time limit).
var elapsed: float = 0.0
## Seconds (scaled by `time_scale`) since the current phase began.
var phase_clock: float = 0.0
## Out groups so far (each an Array[int]), first out first.
var out_groups: Array = []
var _drop_group: Array[int] = []
var _last_target: int = -1
var _last_twist: int = -1
## Bot plans this SHOW: slot -> {cell, spot, react, told}.
var _plans: Dictionary[int, Dictionary] = {}
## Per cell, for bots once they have read the portrait this SHOW: 1 = a target tile (safe),
## 2 = a tile some bot wrongly believes in (safe near its centre only), 0 = unsafe. Built once
## per plan: bots call is_safe hundreds of times a tick.
var _show_safe: PackedByteArray = PackedByteArray()
## SHUFFLE goals per slot (a cell near the middle).
var _shuffle_goal: Dictionary[int, int] = {}
## Host, dev: twists forced on the next loops, in order (`--portrait-twist=`).
var _twist_queue: Array[int] = []
## `phase_clock` until which bots are still reading (every tile counts as safe).
var _bot_read_until: float = 0.0

# --- Presentation (every peer) ---------------------------------------------------------------
var _t: float = 0.0
var _phase_t0: float = 0.0
var _multimesh: MultiMesh = null
var _shapes: Array[CollisionShape3D] = []
## Per tile: the flip (angle from -> to, start time incl. delay, duration).
var _flip_from: PackedFloat32Array = PackedFloat32Array()
var _flip_to: PackedFloat32Array = PackedFloat32Array()
var _flip_t0: PackedFloat32Array = PackedFloat32Array()
var _flip_dur: PackedFloat32Array = PackedFloat32Array()
## Per tile: the symbol drawn on the top face, and the one it takes once its top is hidden.
var _face_sym: PackedInt32Array = PackedInt32Array()
var _pending_sym: PackedInt32Array = PackedInt32Array()
## Per tile: fall / rise / slide start times (-1 = none), slide offset (z) and arc sign.
var _fall_t0: PackedFloat32Array = PackedFloat32Array()
var _rise_t0: PackedFloat32Array = PackedFloat32Array()
var _slide_t0: PackedFloat32Array = PackedFloat32Array()
var _slide_dz: PackedFloat32Array = PackedFloat32Array()
var _slide_arc: PackedFloat32Array = PackedFloat32Array()
var _glow: PackedFloat32Array = PackedFloat32Array()
var _canvas_mat: ShaderMaterial = null
var _portrait_symbol: int = -1
var _portrait_flash: float = 0.0
var _beeps: int = 0
var _quality_lights: Array[Light3D] = []
# HUD
var _hud: CanvasLayer = null
var _hud_panel: PanelContainer = null
var _hud_lead: Label = null
var _hud_icon: ColorRect = null
var _hud_icon_mat: ShaderMaterial = null
var _hud_name: Label = null
var _hud_sub: Label = null
var _hud_bar: ColorRect = null
var _hud_bar_bg: ColorRect = null

@onready var _camera: ArenaCamera = get_node_or_null(^"ArenaCamera") as ArenaCamera


func _ready() -> void:
	add_to_group(Look.QUALITY_GROUP)
	layout = make_layout(1, symbols_start, targets_start, 3)
	gone.resize(CELLS)
	gone.fill(0)
	_init_tile_state()
	_build_floor()
	_build_room()
	_build_hud()
	apply_quality()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--portrait-time-scale="):
			time_scale = maxf(arg.trim_prefix("--portrait-time-scale=").to_float(), 0.01)
		elif arg.begins_with("--portrait-twist="):
			for word in arg.trim_prefix("--portrait-twist=").split(",", false):
				var tw := TWIST_NAMES.find(word.strip_edges().to_upper())
				if tw > 0:
					_twist_queue.append(tw)


# --- Minigame flow ---------------------------------------------------------------------------

func _setup(round_players: Array[Player]) -> void:
	for p in round_players:
		p.eliminated.connect(_on_player_eliminated.bind(p))
	if multiplayer.is_server():
		var slots := PackedInt32Array()
		for p in round_players:
			slots.append(p.slot)
		_rpc_spawn_layout.rpc(randf() * TAU, slots)
	_hud_show_text("GET READY", "Watch the portrait, stand on its symbol!", Color(0.95, 0.9, 0.8))


func _start() -> void:
	elapsed = 0.0
	if not multiplayer.is_server():
		return
	rng.seed = rng_seed if rng_seed != 0 else randi()
	bot_rng.seed = rng.seed * 31 + 7


func _host_tick(delta: float) -> void:
	if is_finished() or phase == Phase.OVER:
		return
	elapsed += delta
	var dt := delta * time_scale
	phase_clock += dt
	_check_falls()
	if is_finished():
		return
	match phase:
		Phase.IDLE:
			_begin_loop()
		Phase.SHUFFLE:
			if phase_clock >= shuffle_time:
				_begin_show()
		Phase.SHOW:
			_tick_show()
		Phase.DROP:
			if phase_clock >= drop_time:
				_close_drop_group()
				if _alive_count() <= _end_count():
					_end_round()
					return
				_begin_loop()
	if is_finished():
		return
	if time_limit > 0.0 and elapsed >= time_limit:
		_end_round()


# --- Pure rules (static, testable) --------------------------------------------------------------

## The numbers of loop `index` (0-based): {symbols, targets, show (s, before a twist bonus)}.
static func loop_params(index: int, sym_start: int = 4, tgt_start: int = 8, tgt_min: int = 2,
		show0: float = 4.5, step: float = 0.35, show_floor: float = 2.0) -> Dictionary:
	return {
		"symbols": clampi(sym_start + index, 2, SYMBOL_COUNT),
		"targets": maxi(tgt_min, tgt_start - index),
		"show": maxf(show_floor, show0 - step * index),
	}


## A layout from `seed_value`: `symbol_count` symbols in play (the target among them), the
## target on exactly `target_count` cells spread over the floor, one other symbol on as many
## cells (so the rarest symbol is no tell), the rest shared evenly. Deterministic.
static func make_layout(seed_value: int, symbol_count: int, target_count: int, target_symbol: int) -> PackedByteArray:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	symbol_count = clampi(symbol_count, 2, SYMBOL_COUNT)
	target_count = clampi(target_count, 1, CELLS / symbol_count)
	var others: Array[int] = []
	for s in SYMBOL_COUNT:
		if s != target_symbol:
			others.append(s)
	_shuffle_ints(others, r)
	others.resize(symbol_count - 1)
	var cells: Array[int] = []
	for i in CELLS:
		cells.append(i)
	_shuffle_ints(cells, r)
	# Targets: greedily at least two cells apart (Chebyshev) while possible.
	var targets: Array[int] = []
	for c in cells:
		if targets.size() >= target_count:
			break
		var ok := true
		for t in targets:
			if maxi(absi(c / GRID - t / GRID), absi(c % GRID - t % GRID)) < 2:
				ok = false
				break
		if ok:
			targets.append(c)
	for c in cells:
		if targets.size() >= target_count:
			break
		if not targets.has(c):
			targets.append(c)
	var out := PackedByteArray()
	out.resize(CELLS)
	out.fill(255)
	for c in targets:
		out[c] = target_symbol
	var rest: Array[int] = []
	for c in cells:
		if out[c] == 255:
			rest.append(c)
	# Counts: others[0] as rare as the target, the remainder spread evenly.
	var counts: Array[int] = []
	var left := rest.size()
	for k in others.size():
		if k == 0 and others.size() > 1:
			counts.append(target_count)
		else:
			var n_left := others.size() - k
			counts.append(int(ceil(float(left) / n_left)))
		left -= counts[k]
	var idx := 0
	for k in others.size():
		for n in counts[k]:
			if idx < rest.size():
				out[rest[idx]] = others[k]
				idx += 1
	return out


## `lay` with rows `a` and `b` traded (a new array).
static func swap_layout_rows(lay: PackedByteArray, a: int, b: int) -> PackedByteArray:
	var out := lay.duplicate()
	if a < 0 or b < 0 or a >= GRID or b >= GRID or a == b:
		return out
	for c in GRID:
		out[a * GRID + c] = lay[b * GRID + c]
		out[b * GRID + c] = lay[a * GRID + c]
	return out


## Every cell of `lay` not showing `symbol` (what DROP takes away).
static func drop_cells_of(lay: PackedByteArray, symbol: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in lay.size():
		if lay[i] != symbol:
			out.append(i)
	return out


## Cells of `lay` showing `symbol`.
static func cells_with(lay: PackedByteArray, symbol: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in lay.size():
		if lay[i] == symbol:
			out.append(i)
	return out


## Top centre of cell `i`, local to the minigame.
static func cell_center(i: int) -> Vector3:
	return Vector3((i % GRID - (GRID - 1) * 0.5) * PITCH, 0.0, (i / GRID - (GRID - 1) * 0.5) * PITCH)


## The cell whose square (tile plus half the gap around it) holds `local` (horizontal), -1 off.
static func cell_at_local(local: Vector3) -> int:
	var col := floori(local.x / PITCH + GRID * 0.5)
	var row := floori(local.z / PITCH + GRID * 0.5)
	if col < 0 or row < 0 or col >= GRID or row >= GRID:
		return -1
	return row * GRID + col


## Spawn points (local) for `count` players: evenly around SPAWN_RADIUS, facing the centre.
static func spawn_layout(count: int, turn: float) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in count:
		var a := turn + TAU * i / count
		out.append(Transform3D(Basis(Vector3.UP, a + PI), Vector3(sin(a), 0.0, cos(a)) * SPAWN_RADIUS))
	return out


static func _shuffle_ints(arr: Array[int], r: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := r.randi_range(0, i)
		var tmp := arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


# --- Public queries ----------------------------------------------------------------------------

## The cell under `global_pos`, -1 off the floor.
func cell_at(global_pos: Vector3) -> int:
	return cell_at_local(to_local(global_pos))


## Top centre of cell `i`, global.
func get_cell_position(i: int) -> Vector3:
	return to_global(cell_center(i))


## True while cell `i` has its collider.
func cell_has_collider(i: int) -> bool:
	return i >= 0 and i < _shapes.size() and not _shapes[i].disabled


## True when the top face (the symbol) of tile `i` faces up right now (not face down, not mid-flip).
func face_visible(i: int) -> bool:
	return cos(_angle_at(i)) > 0.7


## The target cells of the current layout.
func target_cells() -> PackedInt32Array:
	return cells_with(layout, target)


## What the portrait shows now (-1 = the card back).
func portrait_symbol() -> int:
	return _portrait_symbol


# --- Host: loop ----------------------------------------------------------------------------------

func _begin_loop() -> void:
	var idx := loop_index + 1
	var lp := loop_params(idx, symbols_start, targets_start, targets_min, show_start, show_step, show_min)
	var tgt := rng.randi_range(0, SYMBOL_COUNT - 1)
	if tgt == _last_target:
		tgt = (tgt + 1 + rng.randi_range(0, SYMBOL_COUNT - 2)) % SYMBOL_COUNT
	_last_target = tgt
	var lay := make_layout(rng.randi(), int(lp["symbols"]), int(lp["targets"]), tgt)
	var tw: int = Twist.NONE
	if next_twist > 0:
		tw = next_twist
		next_twist = -1
	elif not _twist_queue.is_empty():
		tw = _twist_queue.pop_front()
	elif idx >= twist_from_loop:
		var options: Array[int] = [Twist.MEMORY, Twist.DECOY, Twist.SWAP]
		options.erase(_last_twist)
		tw = options[rng.randi_range(0, options.size() - 1)]
	_last_twist = tw
	var dec := -1
	if tw == Twist.DECOY:
		var present: Array[int] = []
		for s in SYMBOL_COUNT:
			if s != tgt and lay.has(s):
				present.append(s)
		dec = present[rng.randi_range(0, present.size() - 1)]
	var rows := Vector2i(-1, -1)
	if tw == Twist.SWAP:
		rows = _pick_swap_rows(lay, tgt)
	var show := float(lp["show"])
	if tw > 0:
		show += twist_bonus[tw - 1]
	_shuffle_goal.clear()
	_plans.clear()
	phase_clock = 0.0
	_rpc_loop.rpc(idx, lay, tgt, tw, dec, rows, show)
	request_bot_rethink()


## SWAP rows: one holding a target tile, the other at least two rows away when possible.
func _pick_swap_rows(lay: PackedByteArray, tgt: int) -> Vector2i:
	var with_target: Array[int] = []
	for r in GRID:
		for c in GRID:
			if lay[r * GRID + c] == tgt:
				with_target.append(r)
				break
	var a: int = with_target[rng.randi_range(0, with_target.size() - 1)] if not with_target.is_empty() else rng.randi_range(0, GRID - 1)
	var far: Array[int] = []
	for r in GRID:
		if absi(r - a) >= 2:
			far.append(r)
	var b: int = far[rng.randi_range(0, far.size() - 1)]
	return Vector2i(mini(a, b), maxi(a, b))


func _begin_show() -> void:
	phase_clock = 0.0
	_rpc_show.rpc(loop_index)
	_bot_read_until = bot_read_time
	_plan_bots()
	request_bot_rethink()


func _tick_show() -> void:
	if twist == Twist.MEMORY and not faces_down and phase_clock >= memory_hide_at:
		_rpc_hide.rpc(loop_index)
	elif twist == Twist.DECOY and decoy_showing and phase_clock >= show_len * decoy_share:
		_rpc_reveal.rpc(loop_index)
		_bot_read_until = phase_clock + bot_read_time
		_plan_bots()
		request_bot_rethink()
	elif twist == Twist.SWAP and not swapped and phase_clock >= show_len * swap_share:
		_rpc_swap.rpc(loop_index)
		_bot_read_until = phase_clock + bot_read_time
		_plan_bots()
		request_bot_rethink()
	for slot: int in _plans:
		var plan: Dictionary = _plans[slot]
		if not plan["told"] and phase_clock >= float(plan["react"]):
			plan["told"] = true
			request_bot_rethink(slot)
	if phase_clock >= show_len:
		_begin_drop()


func _begin_drop() -> void:
	phase_clock = 0.0
	_drop_group.clear()
	_rpc_drop.rpc(loop_index, drop_cells_of(layout, target))
	request_bot_rethink()


# --- Host: falls and the end ----------------------------------------------------------------------

func _check_falls() -> void:
	var group: Array[int] = []
	for p in players:
		if is_instance_valid(p) and p.alive and to_local(p.global_position).y < fall_y:
			group.append(p.slot)
	if group.is_empty():
		return
	group.sort()
	for s in group:
		var p := _player(s)
		knocked_out.append(s)
		player_fell.emit(s, loop_index)
		p.eliminate(&"fell")
	if phase == Phase.DROP:
		# Everyone who falls in one DROP shares a place: the group closes when the DROP ends.
		_drop_group.append_array(group)
		if _alive_count() == 0:
			_close_drop_group()
			_end_round()
		return
	out_groups.append(group)
	if _alive_count() <= _end_count():
		_end_round()


func _close_drop_group() -> void:
	if _drop_group.is_empty():
		return
	var g: Array[int] = _drop_group.duplicate()
	g.sort()
	out_groups.append(g)
	_drop_group.clear()


## Host: a player who left mid-round (Stage knocks them out, then removes them). Recorded as
## the earliest out (they rank last) and out as in the base, but when that leaves one player
## (or none) the round ends through `_end_round`: the tied DROP groups keep their places and
## every peer gets the end RPC (winner banner, freeze), unlike the base's flat finish.
func knock_out(player: Player, reason: StringName = &"") -> void:
	if is_finished() or player == null or not player.alive or player.is_extra:
		super(player, reason)
		return
	knocked_out.append(player.slot)
	var g: Array[int] = [player.slot]
	out_groups.insert(0, g)
	player.eliminate(reason if reason != &"" else &"knocked_out")
	if _alive_count() <= _end_count():
		_end_round()


## Players alive at which the round ends: 1, or 0 when playing alone.
func _end_count() -> int:
	return 1 if players.size() > 1 else 0


## Host: the survivors (a tied group if several) first, then the out groups, last out first.
func _end_round() -> void:
	if is_finished():
		return
	_close_drop_group()
	var alive := _alive_slots()
	var groups: Array = []
	if not alive.is_empty():
		groups.append(alive)
	for i in range(out_groups.size() - 1, -1, -1):
		groups.append(out_groups[i])
	_rpc_end.rpc(PackedInt32Array(alive))
	finish(groups, end_grace)


# --- Host -> every peer ------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_spawn_layout(turn: float, slots: PackedInt32Array) -> void:
	var points := spawn_layout(slots.size(), turn)
	for i in slots.size():
		var p := _player(slots[i])
		if p:
			p.place_at(global_transform * points[i])
	spawn_layout_applied.emit(turn, slots)


@rpc("authority", "call_local", "reliable")
func _rpc_loop(index: int, lay: PackedByteArray, tgt: int, tw: int, dec: int, rows: Vector2i, show: float) -> void:
	loop_index = index
	layout = lay.duplicate()
	target = tgt
	twist = tw as Twist
	decoy = dec
	swap_rows = rows
	show_len = show
	phase = Phase.SHUFFLE
	bot_aggression_scale = 0.0
	faces_down = false
	decoy_showing = false
	swapped = false
	_phase_t0 = _t
	_beeps = 0
	var rose := false
	for i in CELLS:
		_glow[i] = 0.0
		_slide_t0[i] = -1.0
		var delay := 0.04 * float(i / GRID + i % GRID)
		if gone[i] != 0:
			gone[i] = 0
			_set_collider(i, true)
			_fall_t0[i] = -1.0
			_rise_t0[i] = _t
			rose = true
			delay += 0.35
		_pending_sym[i] = layout[i]
		_start_flip(i, TAU if _is_face_up(i) else PI, delay, 0.5)
	_set_portrait(-1)
	if tw > 0:
		_hud_show_text("LOOP %d  -  TWIST: %s" % [index + 1, TWIST_NAMES[tw]], TWIST_HINTS[tw], Color(1.0, 0.8, 0.35))
		RoundUI.push_banner("TWIST: %s!" % TWIST_NAMES[tw], 1.4)
	else:
		_hud_show_text("LOOP %d" % (index + 1), "Look at the floor...", Color(0.95, 0.9, 0.8))
	Sfx.play(&"piano_e")
	if rose:
		Sfx.play(&"respawn")
	loop_started.emit(index, layout, target, tw)


@rpc("authority", "call_local", "reliable")
func _rpc_show(index: int) -> void:
	phase = Phase.SHOW
	bot_aggression_scale = clampf(BOT_AGGRESSION_STEP * (index - BOT_CALM_LOOPS + 1), 0.0, BOT_AGGRESSION_MAX)
	_phase_t0 = _t
	_beeps = 0
	decoy_showing = twist == Twist.DECOY and decoy >= 0
	var shown := decoy if decoy_showing else target
	_set_portrait(shown)
	_hud_show_symbol(shown, "STAND ON" if not decoy_showing else "STAND ON...?", _show_hint())
	Sfx.play(&"piano_g")
	show_started.emit(index, shown)


@rpc("authority", "call_local", "reliable")
func _rpc_hide(index: int) -> void:
	faces_down = true
	for i in CELLS:
		if gone[i] == 0:
			_start_flip(i, PI, 0.025 * float(i / GRID + i % GRID), 0.35)
	_hud_sub.text = "REMEMBER WHERE IT WAS!"
	Sfx.play(&"piano_b")
	faces_hidden.emit(index)


@rpc("authority", "call_local", "reliable")
func _rpc_reveal(index: int) -> void:
	decoy_showing = false
	_set_portrait(target)
	_hud_show_symbol(target, "NO! STAND ON", "The second one counts!")
	Sfx.play(&"piano_c")
	if _camera:
		_camera.add_shake(0.1)
	decoy_revealed.emit(index, target)


@rpc("authority", "call_local", "reliable")
func _rpc_swap(index: int) -> void:
	var a := swap_rows.x
	var b := swap_rows.y
	layout = swap_layout_rows(layout, a, b)
	swapped = true
	var dz := float(b - a) * PITCH
	for c in GRID:
		var ia := a * GRID + c
		var ib := b * GRID + c
		var sa := _face_sym[ia]
		_face_sym[ia] = _face_sym[ib]
		_face_sym[ib] = sa
		_pending_sym[ia] = layout[ia]
		_pending_sym[ib] = layout[ib]
		# Each tile's picture now starts where it came from and slides home.
		_slide_t0[ia] = _t + 0.02 * c
		_slide_dz[ia] = dz
		_slide_arc[ia] = 1.0
		_slide_t0[ib] = _t + 0.02 * c
		_slide_dz[ib] = -dz
		_slide_arc[ib] = -1.0
	_hud_sub.text = "ROWS SWAPPED!"
	Sfx.play(&"shove_whoosh")
	rows_swapped.emit(index, a, b)


@rpc("authority", "call_local", "reliable")
func _rpc_drop(index: int, cells: PackedInt32Array) -> void:
	phase = Phase.DROP
	bot_aggression_scale = 0.0
	_phase_t0 = _t
	faces_down = false
	decoy_showing = false
	for i in CELLS:
		if not _is_face_up(i):
			_start_flip(i, PI, 0.0, 0.25)
	for i in cells:
		if i < 0 or i >= CELLS or gone[i] != 0:
			continue
		gone[i] = 1
		_set_collider(i, false)
		_fall_t0[i] = _t
	for i in CELLS:
		if gone[i] == 0:
			_glow[i] = 1.0
	_set_portrait(target)
	_hud_show_text("DROP!", "", Color(1.0, 0.45, 0.35))
	Sfx.play(&"platform_fall")
	if _camera:
		_camera.add_shake(0.22)
	dropped.emit(index, cells)


@rpc("authority", "call_local", "reliable")
func _rpc_end(winners: PackedInt32Array) -> void:
	phase = Phase.OVER
	for p in players:
		if is_instance_valid(p):
			p.frozen = true
	for s in winners:
		var p := _player(s)
		if p and p.alive:
			Fx.play(&"confetti", p.global_position + Vector3.UP * 1.2)
			var vis := p.get_component(&"visuals") as VisualsComponent
			if vis:
				vis.play_emote(&"cheer")
	if winners.size() == 1 and _player(winners[0]):
		_hud_show_text("%s WINS!" % _name_of(_player(winners[0])), "", Color(1.0, 0.85, 0.4))
	elif winners.is_empty():
		_hud_show_text("NOBODY LEFT!", "The last ones fell together", Color(1.0, 0.85, 0.4))
	else:
		_hud_show_text("TIME!", "%d survivors share the win" % winners.size(), Color(1.0, 0.85, 0.4))
	round_over.emit(winners)


# --- Bots ----------------------------------------------------------------------------------------

## Host: who heads for which tile this SHOW (or after a DECOY reveal / SWAP). Bots in a
## random order each take the target tile closest to them, with tiles already picked counting
## `bot_crowd_penalty` metres further per bot. Under MEMORY (and at a DECOY reveal) a bot may
## err (`bot_error` by skill): it heads for a wrong tile and believes it is safe.
func _plan_bots() -> void:
	_plans.clear()
	_show_safe.resize(CELLS)
	for i in CELLS:
		_show_safe[i] = 1 if layout[i] == target else 0
	var sym := decoy if decoy_showing else target
	var cells := cells_with(layout, sym)
	if cells.is_empty():
		return
	var order := _alive_players()
	for i in range(order.size() - 1, 0, -1):
		var j := bot_rng.randi_range(0, i)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	var claims: Dictionary[int, int] = {}
	for p in order:
		var pos := to_local(p.global_position)
		var best := -1
		var best_score := INF
		for c in cells:
			var score := _flat_dist(cell_center(c), pos) + bot_crowd_penalty * float(claims.get(c, 0))
			if score < best_score:
				best_score = score
				best = c
		var skill := _skill_of(p)
		var err := lerpf(bot_error.x, bot_error.y, skill)
		var goal_cell := best
		var wrong := -1
		if twist == Twist.MEMORY and not decoy_showing and bot_rng.randf() < err:
			wrong = _wrong_neighbour(best, pos)
		elif twist == Twist.DECOY and not decoy_showing and bot_rng.randf() < err:
			wrong = _nearest_cell_with(decoy, pos)
		elif twist == Twist.NONE and bot_rng.randf() < lerpf(bot_misread.x, bot_misread.y, skill) * clampf((loop_index - 1) / 3.0, 0.0, 1.0):
			wrong = _wrong_neighbour(best, pos)
		if wrong >= 0:
			goal_cell = wrong
			if _show_safe[wrong] == 0:
				_show_safe[wrong] = 2
		var spot: int = claims.get(goal_cell, 0) if wrong < 0 else 0
		claims[goal_cell] = spot + 1
		var react := phase_clock + lerpf(bot_react.x, bot_react.y, skill) * bot_rng.randf_range(0.8, 1.25)
		_plans[p.slot] = {"cell": goal_cell, "spot": spot, "react": react, "told": false}


## A non-target cell next to `cell` (the closest to `pos`), or -1.
func _wrong_neighbour(cell: int, pos: Vector3) -> int:
	var best := -1
	var best_d := INF
	var r := cell / GRID
	var c := cell % GRID
	for dr in range(-1, 2):
		for dc in range(-1, 2):
			var rr := r + dr
			var cc := c + dc
			if (dr == 0 and dc == 0) or rr < 0 or cc < 0 or rr >= GRID or cc >= GRID:
				continue
			var n := rr * GRID + cc
			if layout[n] == target:
				continue
			var d := _flat_dist(cell_center(n), pos) + bot_rng.randf() * 0.8
			if d < best_d:
				best_d = d
				best = n
	return best


func _nearest_cell_with(symbol: int, pos: Vector3) -> int:
	var best := -1
	var best_d := INF
	for c in cells_with(layout, symbol):
		var d := _flat_dist(cell_center(c), pos)
		if d < best_d:
			best_d = d
			best = c
	return best


## SHOW: the bot's planned tile once it has read the portrait (until then: stay). SHUFFLE: a
## tile near the middle. DROP: stay on safe ground.
func get_bot_goal(player: Player) -> Vector3:
	if player == null:
		return global_position
	var pos := to_local(player.global_position)
	match phase:
		Phase.SHOW:
			var plan: Dictionary = _plans.get(player.slot, {})
			if plan.is_empty():
				var near := _nearest_cell_with(target, pos)
				return get_cell_position(near) if near >= 0 else player.global_position
			if phase_clock < float(plan["react"]):
				return player.global_position
			return to_global(cell_center(int(plan["cell"])) + SPOTS[int(plan["spot"]) % SPOTS.size()])
		Phase.SHUFFLE:
			if not _shuffle_goal.has(player.slot):
				# A free cell in the middle 5 x 5, so the crowd spreads out.
				var mid := (GRID - 1) / 2
				var pick := -1
				for attempt in 12:
					var cell := (mid + bot_rng.randi_range(-2, 2)) * GRID + mid + bot_rng.randi_range(-2, 2)
					pick = cell
					if not _shuffle_goal.values().has(cell):
						break
				_shuffle_goal[player.slot] = pick
			return get_cell_position(_shuffle_goal[player.slot])
	if is_safe(player.global_position):
		return player.global_position
	var near_cell := _nearest_cell_with(target, pos)
	return get_cell_position(near_cell) if near_cell >= 0 else player.global_position


## Over a tile that will not drop: during SHOW (once read) the target tiles and the tiles a bot
## wrongly believes in; otherwise any tile that is there. Never the outer rim.
func is_safe(pos: Vector3) -> bool:
	var local := to_local(pos)
	if absf(local.x) > HALF - 0.45 or absf(local.z) > HALF - 0.45:
		return false
	var cell := floori(local.z / PITCH + GRID * 0.5) * GRID + floori(local.x / PITCH + GRID * 0.5)
	if phase == Phase.SHOW and not decoy_showing and phase_clock >= _bot_read_until and _show_safe.size() == CELLS:
		var k := _show_safe[cell]
		if k == 2:
			var c := cell_center(cell)
			return Vector2(local.x - c.x, local.z - c.z).length_squared() <= bot_belief_radius * bot_belief_radius
		return k != 0
	return gone[cell] == 0


func _skill_of(p: Player) -> float:
	var brain := BotBrain.of(p)
	return brain.skill if brain else 0.6


# --- Presentation: tiles (every peer) ----------------------------------------------------------------

func _init_tile_state() -> void:
	# Packed arrays are values: resize each one itself.
	_flip_from.resize(CELLS)
	_flip_to.resize(CELLS)
	_flip_t0.resize(CELLS)
	_flip_dur.resize(CELLS)
	_fall_t0.resize(CELLS)
	_rise_t0.resize(CELLS)
	_slide_t0.resize(CELLS)
	_slide_dz.resize(CELLS)
	_slide_arc.resize(CELLS)
	_glow.resize(CELLS)
	_flip_from.fill(0.0)
	_flip_to.fill(0.0)
	_flip_t0.fill(-10.0)
	_flip_dur.fill(0.5)
	_fall_t0.fill(-1.0)
	_rise_t0.fill(-1.0)
	_slide_t0.fill(-1.0)
	_slide_dz.fill(0.0)
	_slide_arc.fill(0.0)
	_glow.fill(0.0)
	_face_sym.resize(CELLS)
	_pending_sym.resize(CELLS)
	for i in CELLS:
		_face_sym[i] = layout[i]
		_pending_sym[i] = layout[i]


## Starts a flip of tile `i` from its current angle to the next multiple of `turn` (PI: half
## turn, TAU: full turn) after `delay` seconds, taking `duration`.
func _start_flip(i: int, turn: float, delay: float, duration: float) -> void:
	var a := fposmod(_angle_at(i), TAU)
	_flip_from[i] = a
	_flip_to[i] = a + turn
	_flip_t0[i] = _t + delay
	_flip_dur[i] = duration


func _angle_at(i: int) -> float:
	var k := clampf((_t - _flip_t0[i]) / maxf(_flip_dur[i], 0.01), 0.0, 1.0)
	k = k * k * (3.0 - 2.0 * k)
	return lerpf(_flip_from[i], _flip_to[i], k)


func _is_face_up(i: int) -> bool:
	return cos(_flip_to[i]) > 0.0


## How far (m) a tile turned `angle` about X sinks, so its top stays at or below the floor
## (y = 0): its half height grows from THICK / 2 flat to TILE / 2 on edge.
static func flip_sink(angle: float) -> float:
	return TILE * 0.5 * absf(sin(angle)) + THICK * 0.5 * absf(cos(angle)) - THICK * 0.5


## SWAP slide offset at progress `k` (0..1) of a tile that starts `dz` from home: it dives
## below the floor (row `arc` +1 to SLIDE_DEPTH, -1 deeper, so the two rows pass each other
## and under every row in between), slides home down there, and rises into place. Its top
## never comes above the floor, so it never passes through a blob.
static func slide_offset(k: float, dz: float, arc: float) -> Vector3:
	var depth := SLIDE_DEPTH if arc >= 0.0 else SLIDE_DEPTH + THICK + 0.1
	var dive := smoothstep(0.0, 0.22, k) * (1.0 - smoothstep(0.78, 1.0, k))
	var travel := smoothstep(0.2, 0.8, k)
	return Vector3(0.0, -depth * dive, dz * (1.0 - travel))


func _set_collider(i: int, on: bool) -> void:
	if i >= 0 and i < _shapes.size():
		_shapes[i].disabled = not on


func _process(delta: float) -> void:
	_t += delta
	_update_tiles()
	_update_portrait(delta)
	_update_hud()


func _update_tiles() -> void:
	if _multimesh == null:
		return
	var pulse := 0.65 + 0.35 * sin(_t * 9.0)
	for i in CELLS:
		var a := _angle_at(i)
		if cos(a) < 0.0:
			_face_sym[i] = _pending_sym[i]
		var off := Vector3.ZERO
		var alpha := 1.0
		var tumble := Basis.IDENTITY
		if _fall_t0[i] >= 0.0:
			var ft := maxf(_t - _fall_t0[i], 0.0)
			off.y = -0.5 * 16.0 * ft * ft - 0.4 * ft
			var spin := ft * (0.9 + 0.25 * float(i % 3))
			tumble = Basis(Vector3(0.6, 0.0, 0.8 if i % 2 == 0 else -0.8).normalized(), spin)
			alpha = 1.0 - clampf((ft - 0.45) / 0.6, 0.0, 1.0)
		elif _rise_t0[i] >= 0.0:
			var rt := clampf((_t - _rise_t0[i]) / 0.45, 0.0, 1.0)
			off.y = lerpf(-3.0, 0.0, 1.0 - pow(1.0 - rt, 3.0))
			alpha = clampf(rt * 2.0, 0.0, 1.0)
			if rt >= 1.0:
				_rise_t0[i] = -1.0
		if _slide_t0[i] >= 0.0:
			var sk := clampf((_t - _slide_t0[i]) / SLIDE_TIME, 0.0, 1.0)
			off += slide_offset(sk, _slide_dz[i], _slide_arc[i])
			if sk >= 1.0:
				_slide_t0[i] = -1.0
		# A flip turns about the tile's middle; it sinks as it turns so no edge ever rises
		# above the floor (through a blob standing on it).
		off.y -= flip_sink(a)
		var centre := cell_center(i) + Vector3(0.0, -THICK * 0.5, 0.0) + off
		var xform := Transform3D(tumble * Basis(Vector3.RIGHT, a), centre) * Transform3D(Basis.IDENTITY, Vector3(0.0, THICK * 0.5, 0.0))
		_multimesh.set_instance_transform(i, xform)
		var glow := _glow[i] * pulse if phase == Phase.DROP else 0.0
		_multimesh.set_instance_custom_data(i, Color(float(_face_sym[i]), 0.0, glow, alpha))


func _build_floor() -> void:
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_custom_data = true
	_multimesh.mesh = _make_tile_mesh()
	_multimesh.instance_count = CELLS
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "TileField"
	mmi.multimesh = _multimesh
	var mat := ShaderMaterial.new()
	mat.shader = TILE_SHADER
	mmi.material_override = mat
	# The tiles fall far below: keep them from being culled by a stale bounding box.
	mmi.custom_aabb = AABB(Vector3(-HALF - 1.0, -8.0, -HALF - 1.0), Vector3(HALF * 2.0 + 2.0, 10.0, HALF * 2.0 + 2.0))
	add_child(mmi)
	var body := StaticBody3D.new()
	body.name = "TileBodies"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var box := BoxShape3D.new()
	box.size = Vector3(TILE, THICK, TILE)
	for i in CELLS:
		var cs := CollisionShape3D.new()
		cs.name = "C%d" % i
		cs.shape = box
		cs.position = cell_center(i) + Vector3(0.0, -THICK * 0.5, 0.0)
		body.add_child(cs)
		_shapes.append(cs)
	_update_tiles()


## The tile: a TILE x THICK x TILE box, top face at y = 0 with UVs over the picture, bottom
## face with UVs that read upright once the tile has turned half about X (the card back).
static func _make_tile_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := TILE * 0.5
	var mid := Vector3(0.0, -THICK * 0.5, 0.0)
	var uv_std: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	_face(st, Vector3.ZERO, Vector3.UP, Vector3.FORWARD, h, h, uv_std)
	var uv_back: Array[Vector2] = [Vector2(1, 1), Vector2(0, 1), Vector2(0, 0), Vector2(1, 0)]
	_face(st, Vector3(0.0, -THICK, 0.0), Vector3.DOWN, Vector3.FORWARD, h, h, uv_back)
	for n: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
		_face(st, mid + n * h, n, Vector3.UP, h, THICK * 0.5, uv_std)
	return st.commit()


static func _face(st: SurfaceTool, center: Vector3, n: Vector3, up: Vector3, half_w: float, half_h: float, uvs: Array[Vector2]) -> void:
	var right := (-n).cross(up)
	var corners: Array[Vector3] = [
		center - right * half_w + up * half_h, center + right * half_w + up * half_h,
		center + right * half_w - up * half_h, center - right * half_w - up * half_h,
	]
	for k: int in [0, 1, 2, 0, 2, 3]:
		st.set_normal(n)
		st.set_uv(uvs[k])
		st.add_vertex(corners[k])


# --- Presentation: portrait and HUD -------------------------------------------------------------

func _set_portrait(symbol: int) -> void:
	if symbol != _portrait_symbol:
		_portrait_flash = 0.8
	_portrait_symbol = symbol


func _update_portrait(delta: float) -> void:
	_portrait_flash = maxf(0.0, _portrait_flash - delta * 4.0)
	if _canvas_mat == null:
		return
	_canvas_mat.set_shader_parameter(&"symbol", _portrait_symbol)
	_canvas_mat.set_shader_parameter(&"flash", _portrait_flash)
	var progress := -1.0
	if phase == Phase.SHOW:
		progress = clampf(1.0 - _show_elapsed() / maxf(show_len, 0.01), 0.0, 1.0)
	_canvas_mat.set_shader_parameter(&"progress", progress)
	var pips := 0
	if twist == Twist.DECOY and (phase == Phase.SHOW or phase == Phase.DROP):
		pips = 1 if decoy_showing else 2
	_canvas_mat.set_shader_parameter(&"pips", pips)
	_canvas_mat.set_shader_parameter(&"glow", 1.0 if phase == Phase.DROP else 0.0)


## Seconds of SHOW this peer has seen (host time scale applies on the host only; clients
## follow the host's events, this only drives the countdown ring and beeps).
func _show_elapsed() -> float:
	return (_t - _phase_t0) * time_scale


func _show_hint() -> String:
	match twist:
		Twist.MEMORY:
			return "The tiles will hide - remember!"
		Twist.DECOY:
			return "Wait for the second symbol!"
		Twist.SWAP:
			return "Watch the rows!"
	return ""


func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "PortraitHud"
	_hud.layer = 2
	add_child(_hud)
	# Top left, under the round pill: the top centre is the portrait's.
	var anchor := Control.new()
	anchor.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	anchor.offset_left = 20.0
	anchor.offset_top = 74.0
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(anchor)
	_hud_panel = PanelContainer.new()
	_hud_panel.name = "Banner"
	_hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.09, 0.15, 0.88)
	style.border_color = Color(0.91, 0.7, 0.23)
	style.set_border_width_all(3)
	style.set_corner_radius_all(16)
	style.content_margin_left = 22.0
	style.content_margin_right = 22.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 8.0
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
	style.shadow_size = 6
	_hud_panel.add_theme_stylebox_override(&"panel", style)
	anchor.add_child(_hud_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_panel.add_child(col)
	_hud_lead = _label(20, Color(0.95, 0.9, 0.8))
	col.add_child(_hud_lead)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)
	_hud_icon = ColorRect.new()
	_hud_icon.custom_minimum_size = Vector2(64, 64)
	_hud_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_icon_mat = ShaderMaterial.new()
	_hud_icon_mat.shader = ICON_SHADER
	_hud_icon.material = _hud_icon_mat
	row.add_child(_hud_icon)
	_hud_name = _label(34, Color.WHITE)
	_hud_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_hud_name)
	_hud_sub = _label(18, Color(1.0, 0.8, 0.4))
	col.add_child(_hud_sub)
	_hud_bar_bg = ColorRect.new()
	_hud_bar_bg.color = Color(0.0, 0.0, 0.0, 0.45)
	_hud_bar_bg.custom_minimum_size = Vector2(0, 7)
	_hud_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_hud_bar_bg)
	_hud_bar = ColorRect.new()
	_hud_bar.color = Color(0.91, 0.7, 0.23)
	_hud_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_bar_bg.add_child(_hud_bar)


func _label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override(&"font_size", size)
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_color_override(&"font_outline_color", Color(0.04, 0.02, 0.05, 0.9))
	l.add_theme_constant_override(&"outline_size", 8)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _hud_show_text(title: String, sub: String, color: Color) -> void:
	if _hud_panel == null:
		return
	_hud_lead.text = ""
	_hud_lead.visible = false
	_hud_icon.visible = false
	_hud_name.text = title
	_hud_name.add_theme_color_override(&"font_color", color)
	_hud_sub.text = sub
	_hud_sub.visible = sub != ""
	_hud_bar_bg.visible = false
	_hud_panel.visible = true
	_hud_panel.reset_size()


func _hud_show_symbol(symbol: int, lead: String, sub: String) -> void:
	if _hud_panel == null or symbol < 0:
		return
	_hud_lead.text = lead
	_hud_lead.visible = true
	_hud_icon.visible = true
	_hud_icon_mat.set_shader_parameter(&"symbol", symbol)
	_hud_name.text = SYMBOL_NAMES[symbol]
	_hud_name.add_theme_color_override(&"font_color", SYMBOL_COLORS[symbol])
	_hud_sub.text = sub
	_hud_sub.visible = sub != ""
	_hud_bar_bg.visible = true
	_hud_panel.visible = true
	_hud_panel.reset_size()


func _update_hud() -> void:
	if _hud_panel == null:
		return
	if phase == Phase.SHOW:
		var left := clampf(1.0 - _show_elapsed() / maxf(show_len, 0.01), 0.0, 1.0)
		_hud_bar.size = Vector2(_hud_bar_bg.size.x * left, _hud_bar_bg.size.y)
		_hud_bar.color = Color(0.91, 0.7, 0.23) if left > 0.3 else Color(0.95, 0.3, 0.22)
		var secs_left := int(ceil(show_len - _show_elapsed()))
		if secs_left <= 3 and secs_left >= 1 and _beeps < 4 - secs_left:
			_beeps = 4 - secs_left
			Sfx.play(&"countdown_beep")
	if phase == Phase.DROP and _t - _phase_t0 > 1.2:
		_hud_sub.visible = false


# --- Presentation: the gallery (every peer, built in code; identical everywhere) -------------------

func _build_room() -> void:
	var room := Node3D.new()
	room.name = "Gallery"
	add_child(room)
	var wall := ShaderMaterial.new()
	wall.shader = WALL_SHADER
	var wall_low := Look.toon_material(Color("#2a1d2c"), 0.9, false)
	var cream := Look.toon_material(Color("#a88f6a"), 0.8)
	var gold := Look.toon_material(Look.GOLD, 0.4)
	var dark_wood := Look.toon_material(Look.DARK_WOOD, 0.7)
	var top := 9.0
	var low := VOID_Y
	# Back wall and side walls: damask red above the cornice, dark stone going down into the void.
	_box(room, Vector3(SIDE_X * 2.0 + 1.0, top + 0.6, 0.4), Vector3(0.0, (top - 0.6) * 0.5, WALL_Z - 0.2), wall)
	_box(room, Vector3(SIDE_X * 2.0 + 1.0, -0.6 - low, 0.4), Vector3(0.0, (low - 0.6) * 0.5, WALL_Z - 0.2), wall_low)
	for sx: float in [-1.0, 1.0]:
		var depth := 9.0 - WALL_Z
		var zc := (WALL_Z + 9.0) * 0.5
		_box(room, Vector3(0.4, top + 0.6, depth), Vector3(sx * (SIDE_X + 0.2), (top - 0.6) * 0.5, zc), wall)
		_box(room, Vector3(0.4, -0.6 - low, depth), Vector3(sx * (SIDE_X + 0.2), (low - 0.6) * 0.5, zc), wall_low)
		# cornice along the side wall
		_box(room, Vector3(0.5, 0.3, depth), Vector3(sx * (SIDE_X - 0.05), -0.55, zc), cream)
		_box(room, Vector3(0.36, 0.12, depth), Vector3(sx * (SIDE_X + 0.0), -0.34, zc), gold)
		# dado rail and picture rail
		_box(room, Vector3(0.12, 0.14, depth), Vector3(sx * (SIDE_X - 0.02), 1.1, zc), dark_wood)
		_box(room, Vector3(0.1, 0.1, depth), Vector3(sx * (SIDE_X - 0.02), 6.4, zc), gold)
		# pilasters on the side walls
		for z: float in [-4.5]:
			_pilaster(room, Vector3(sx * (SIDE_X - 0.15), 0.0, z), cream, gold, true)
		# gilt panel mouldings between the pilasters
		for zr: Vector2 in [Vector2(WALL_Z + 0.6, -5.1), Vector2(-3.9, 2.9), Vector2(4.1, 8.6)]:
			_panel(room, Vector3(sx * (SIDE_X - 0.03), 3.5, (zr.x + zr.y) * 0.5), Vector2(zr.y - zr.x, 4.2), true, gold)
		# small portraits between the pilasters
		var kinds: Array[String] = ["portrait_frame_a", "portrait_frame_b", "portrait_frame_c"]
		var k := 0
		for z: float in [-0.5, 6.5]:
			var n := _place(room, kinds[(k + (1 if sx > 0 else 0)) % 3], Vector3(sx * (SIDE_X - 0.12), 2.8, z), -90.0 * sx)
			n.scale = Vector3.ONE * 1.5
			k += 1
	# Back wall trims: cornice, dado and picture rail, pilasters either side of the portrait.
	_box(room, Vector3(SIDE_X * 2.0, 0.3, 0.5), Vector3(0.0, -0.55, WALL_Z + 0.05), cream)
	_box(room, Vector3(SIDE_X * 2.0, 0.12, 0.36), Vector3(0.0, -0.34, WALL_Z + 0.0), gold)
	_box(room, Vector3(SIDE_X * 2.0, 0.14, 0.12), Vector3(0.0, 1.1, WALL_Z + 0.02), dark_wood)
	_box(room, Vector3(SIDE_X * 2.0, 0.1, 0.1), Vector3(0.0, 8.7, WALL_Z + 0.02), gold)
	for x: float in [-11.5, -5.0, 5.0, 11.5]:
		_pilaster(room, Vector3(x, 0.0, WALL_Z + 0.15), cream, gold, false)
	for sx: float in [-1.0, 1.0]:
		_panel(room, Vector3(sx * 8.25, 3.5, WALL_Z + 0.03), Vector2(5.4, 4.2), false, gold)
	for x: float in [-7.2, 7.2]:
		var n := _place(room, "portrait_frame_b" if x < 0.0 else "portrait_frame_a", Vector3(x * 1.13, 2.9, WALL_Z + 0.12), 0.0)
		n.scale = Vector3.ONE * 1.4
	# The big portrait (the big screen).
	var frame := FRAME_SCENE.instantiate() as Node3D
	frame.name = "PortraitFrame"
	frame.position = PORTRAIT_POS
	room.add_child(frame)
	Look.apply_toon(frame)
	var canvas := MeshInstance3D.new()
	canvas.name = "Canvas"
	var quad := QuadMesh.new()
	quad.size = CANVAS_SIZE
	canvas.mesh = quad
	_canvas_mat = ShaderMaterial.new()
	_canvas_mat.shader = CANVAS_SHADER
	_canvas_mat.set_shader_parameter(&"aspect", CANVAS_SIZE.x / CANVAS_SIZE.y)
	canvas.material_override = _canvas_mat
	canvas.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	canvas.position = PORTRAIT_POS + CANVAS_CENTER
	room.add_child(canvas)
	# The void below: dark, far down.
	var void_plane := MeshInstance3D.new()
	void_plane.name = "Void"
	var plane := PlaneMesh.new()
	plane.size = Vector2(80.0, 80.0)
	void_plane.mesh = plane
	void_plane.material_override = Look.toon_material(Color("#100b13"), 0.95, false)
	void_plane.position = Vector3(0.0, VOID_Y, 0.0)
	room.add_child(void_plane)
	# Lights: sconces by the portrait and a picture light on it (MEDIUM/HIGH only).
	for x: float in [-5.0, 5.0]:
		var sconce := _box(room, Vector3(0.3, 0.5, 0.3), Vector3(x, 4.6, WALL_Z + 0.45), gold)
		sconce.name = "Sconce"
		var flame := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.12
		sphere.height = 0.3
		flame.mesh = sphere
		var fm := StandardMaterial3D.new()
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fm.albedo_color = Color(1.0, 0.8, 0.45)
		fm.emission_enabled = true
		fm.emission = Color(1.0, 0.7, 0.35)
		fm.emission_energy_multiplier = 1.2
		flame.material_override = fm
		flame.position = Vector3(x, 5.0, WALL_Z + 0.45)
		room.add_child(flame)
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.72, 0.45)
		lamp.light_energy = 0.9
		lamp.omni_range = 5.0
		lamp.position = Vector3(x, 5.1, WALL_Z + 0.9)
		room.add_child(lamp)
		_quality_lights.append(lamp)
	var picture_light := SpotLight3D.new()
	picture_light.name = "PictureLight"
	picture_light.light_color = Color(1.0, 0.9, 0.75)
	picture_light.light_energy = 0.7
	picture_light.spot_range = 14.0
	picture_light.spot_angle = 34.0
	picture_light.shadow_enabled = false
	room.add_child(picture_light)
	picture_light.look_at_from_position(Vector3(0.0, 9.5, WALL_Z + 5.0), PORTRAIT_POS + Vector3(0.0, 2.4, 0.0), Vector3.UP)
	_quality_lights.append(picture_light)


## A thin gilt rectangle on a wall: `center`, `size` (along the wall, height); `side`: on a
## side wall (runs along Z) instead of the back wall (runs along X).
func _panel(parent: Node3D, center: Vector3, size: Vector2, side: bool, gold: Material) -> void:
	var t := 0.09
	var along := Vector3(0.0, 0.0, 1.0) if side else Vector3(1.0, 0.0, 0.0)
	var depth := Vector3(t, 0.0, 0.0) if side else Vector3(0.0, 0.0, t)
	var horiz := along * size.x + depth + Vector3(0.0, t, 0.0)
	var vert := along * t + depth + Vector3(0.0, size.y, 0.0)
	_box(parent, horiz, center + Vector3(0.0, size.y * 0.5, 0.0), gold)
	_box(parent, horiz, center - Vector3(0.0, size.y * 0.5, 0.0), gold)
	_box(parent, vert, center + along * size.x * 0.5, gold)
	_box(parent, vert, center - along * size.x * 0.5, gold)


func _pilaster(parent: Node3D, base: Vector3, cream: Material, gold: Material, side: bool) -> void:
	var size := Vector3(0.3, 0.0, 0.8) if side else Vector3(0.8, 0.0, 0.3)
	var shaft := size + Vector3(0.0, 9.0 - VOID_Y, 0.0)
	_box(parent, shaft, base + Vector3(0.0, (9.0 + VOID_Y) * 0.5, 0.0), cream)
	var cap := size * 1.25 + Vector3(0.0, 0.35, 0.0)
	_box(parent, cap, base + Vector3(0.0, 7.6, 0.0), gold)
	_box(parent, cap, base + Vector3(0.0, -0.45, 0.0), gold)


func _box(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
	return mi


func _place(parent: Node3D, piece: String, pos: Vector3, yaw_deg: float) -> Node3D:
	var scene := load(ENV_DIR + piece + ".glb") as PackedScene
	if scene == null:
		push_error("portrait_panic: missing kit piece %s" % piece)
		return Node3D.new()
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation_degrees.y = yaw_deg
	parent.add_child(n)
	Look.apply_toon(n)
	return n


## Look quality switch (also live): the sconce lamps and the picture light only above LOW.
func apply_quality() -> void:
	var on := Look.is_high()
	for l in _quality_lights:
		if is_instance_valid(l):
			l.visible = on


# --- Internals ------------------------------------------------------------------------------------

func _on_player_eliminated(reason: StringName, p: Player) -> void:
	if reason != &"fell":
		return
	if _camera:
		_camera.add_shake(0.15)
	Sfx.play(&"platform_fall", p.global_position)


func _player(slot: int) -> Player:
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _alive_players() -> Array[Player]:
	var out: Array[Player] = []
	for p in players:
		if is_instance_valid(p) and p.alive:
			out.append(p)
	return out


func _alive_slots() -> Array[int]:
	var out: Array[int] = []
	for p in _alive_players():
		out.append(p.slot)
	out.sort()
	return out


func _alive_count() -> int:
	return _alive_players().size()


func _name_of(p: Player) -> String:
	return p.display_name.to_upper() if p.display_name != "" else "PLAYER %d" % (p.slot + 1)


static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
