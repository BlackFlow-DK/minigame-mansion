class_name RisingTide
extends Minigame
## Rising Tide: a flooded ruined tower seen from the side-front. The water rises (slowly, then
## faster, with two short breathers); climb the stone shelves, crates, ladders, crumbling blocks,
## swaying hanging platforms and bouncy awnings (TideTower has the layout). A blob whose centre stays
## under water for `drown_time` s drowns (knocked out, reason `drowned`). Last blob dry wins; when
## the water reaches its top the survivors are ranked: whoever touched the summit flag first, then
## the others on the roof by when they got there, then by height; the drowned by how late they went.
##
## Networking (docs/contract.md "Networking rules for minigames"):
## - The host sends the seed and the start time (`_rpc_begin`); every peer runs its own round clock,
##   so the water height and the hanging platforms' sway are pure functions of it, never synced.
## - The host decides crumbles (a grounded player on a crumbling block -> it falls `crumble_delay` s
##   later -> regrows after `crumble_regrow` s when nobody is in the way), drownings, roof arrivals
##   and the summit, and tells every peer with reliable call_local RPCs; colliders change on every
##   peer when the RPC lands. Drownings are `eliminate()`s, which reach every peer by themselves.
## - Awnings launch the players this peer simulates (their own authority), like the dash's hazards.
##
## Bots: `get_bot_goal` walks a route graph section by section: along the walkway (front lane) past
## the stairs, into the chosen route's lane beyond its low end, then up it (the bot brain hops onto
## every step it walks into: steps are at most 0.9 m with no gap). The route (main stairs or the
## section's alt: awning, crumble, hanging) is picked per bot and section from its skill and the
## alt's risk, and re-planned when a crumble closes it. `is_safe` = over a platform (within a hop up
## or a short drop) whose top keeps a blob's centre above the water a moment from now, not inside a
## wall, not on a crumbling or fallen block, and over a hanging platform now and in a moment.

## Every peer: the round clock started (host-sent seed and start time).
signal round_began(seed_value: int, start_time: float)
## Every peer: crumble block `index` started cracking / fell (collider gone) / grew back.
signal crumble_cracked(index: int)
signal crumble_fell(index: int)
signal crumble_regrew(index: int)
## Every peer: `slot` drowned (from its `eliminated` event).
signal drowned(slot: int)
## Every peer: `slot` first set foot on the roof at round time `time` (host-decided).
signal roof_reached(slot: int, time: float)
## Every peer: `slot` touched the summit flag first (host-decided).
signal summit_reached(slot: int)
## On the peer that simulates the player: an awning launched it.
signal launched(slot: int)

enum CrumbleState { SOLID, CRACKING, FALLEN }

const SHELF_SCENE: PackedScene = preload("res://assets/models/props/tide_shelf.glb")
const ROOF_SCENE: PackedScene = preload("res://assets/models/props/tide_roof.glb")
const FLOOR_SCENE: PackedScene = preload("res://assets/models/props/tide_floor.glb")
const WALL_SCENES: Array[PackedScene] = [
	preload("res://assets/models/props/tide_wall.glb"),
	preload("res://assets/models/props/tide_wall_b.glb"),
]
const PILLAR_SCENE: PackedScene = preload("res://assets/models/props/tide_pillar.glb")
const PILLAR_TOP_SCENE: PackedScene = preload("res://assets/models/props/tide_pillar_top.glb")
const CRATE_SCENE: PackedScene = preload("res://assets/models/props/tide_crate.glb")
const CRACKED_SCENE: PackedScene = preload("res://assets/models/props/tide_block_cracked.glb")
const LADDER_SCENE: PackedScene = preload("res://assets/models/props/tide_ladder.glb")
const AWNING_SCENE: PackedScene = preload("res://assets/models/props/tide_awning.glb")
const HANGING_SCENE: PackedScene = preload("res://assets/models/props/tide_hanging.glb")
const CHAIN_SCENE: PackedScene = preload("res://assets/models/props/tide_chain.glb")
const BEAM_SCENE: PackedScene = preload("res://assets/models/props/tide_beam.glb")
const TORCH_SCENE: PackedScene = preload("res://assets/models/props/tide_torch.glb")
const FLAG_SCENE: PackedScene = preload("res://assets/models/props/tide_flag.glb")
const WATER_MATERIAL: Material = preload("res://look/materials/water.tres")
const SPLASH_PATH := "res://minigames/rising_tide/audio/tide_splash.wav"
const BOING_PATH := "res://minigames/rising_tide/audio/tide_boing.wav"
const RUMBLE_PATH := "res://minigames/rising_tide/audio/tide_rumble.wav"
const WATER_COLOR := Color(0.55, 0.88, 0.95)

## Bots: a platform must keep a blob's centre this far above the water this many seconds from now.
const SAFE_WATER_MARGIN := 0.15
const SAFE_WATER_AHEAD := 1.0
## Bots: hanging platforms must still be under a point this many seconds from now.
const HANG_AHEAD := 0.3
## Host: seconds between routine bot rethinks.
const RETHINK_INTERVAL := 0.4
## Camera: the pack is framed whole up to this vertical spread (m), then biased to the local player.
const CAM_SPREAD := 10.0
const CAM_MIN_DISTANCE := 14.0
const CAM_MAX_DISTANCE := 30.0
## Camera: the water line is kept in view when it is this close below the framed blobs (m).
const CAM_WATER_NEAR := 4.0

@export_group("Rules")
## Seconds a blob's centre may stay under water.
@export var drown_time: float = 0.6
## Seconds from a crumble block starting to crack to its fall.
@export var crumble_delay: float = 0.8
## Seconds a fallen crumble block stays gone (then it grows back when nobody is in the way).
@export var crumble_regrow: float = 9.0
## Metres an awning launches a blob above its top (whatever the gravity).
@export var awning_apex: float = 4.2

@export_group("Test")
## Test-only: multiplies the round clock (water, sway, crumbles, the time limit).
@export var time_scale: float = 1.0
## Seed of the round (spawn order, sway phase, bot tastes); -1 = random (host).
@export var tower_seed: int = -1
## Round clock at the start (host). Dev: `--tide-start=SEC`.
@export var start_time: float = 0.0

## Mutators that break the climb: heavy blobs cannot jump a 0.9 m step; giant ones jam the lanes
## and bump the shelves overhead.
var mutator_blocklist: Array[StringName] = [&"heavy", &"giant"]
## Bot brain hint: bots shove a bit less than in the brawls (they have to climb).
var bot_aggression_scale: float = 0.8

## Every peer: crumble block state by crumble index (CrumbleState).
var crumble_state: PackedInt32Array = PackedInt32Array()
## Every peer: slot -> round time of its first step onto the roof (host-decided).
var roof_times: Dictionary[int, float] = {}
## Every peer: the slot that touched the flag first (-1 none).
var summit_slot: int = -1
## Host: groups of slots that drowned in the same tick, first out first.
var drown_groups: Array = []
## Host: slot -> round time it drowned.
var drown_times: Dictionary[int, float] = {}

var _t: float = 0.0
var _t_vis: float = 0.0
var _prev_t: float = 0.0
var _running: bool = false
var _seed: int = 0
var _phase: float = 0.0
var _freeze_at: float = INF
var _place_level: int = -1
var _anim: float = 0.0
# host
var _under: Dictionary[int, float] = {}
var _crumble_t: PackedFloat32Array = PackedFloat32Array()
var _rethink_cd: float = 0.0
# every peer
var _launch_cd: Dictionary[int, float] = {}
var _boing_cd: Dictionary[int, float] = {}
var _route_alt: Dictionary[int, bool] = {}
var _banner_step: int = 0
var _hud_cd: float = 0.0
var _heights: Dictionary[int, int] = {}
# pieces
var _crumble_ids: Array[int] = []
var _hang_ids: Array[int] = []
var _awning_ids: Array[int] = []
var _buckets: Array = []  # floor index -> Array of piece ids near that height
# nodes
var _crumble_bodies: Array[StaticBody3D] = []
var _crumble_shapes: Array[CollisionShape3D] = []
var _crumble_vis: Array[Node3D] = []
var _crumble_anim: PackedFloat32Array = PackedFloat32Array()
var _hang_bodies: Array[AnimatableBody3D] = []
var _hang_vis: Array[Node3D] = []
var _chains: Array[Node3D] = []  # two per hanging platform
var _chain_anchor: Array[Vector3] = []
var _awning_vis: Array[Node3D] = []
var _awning_pop: PackedFloat32Array = PackedFloat32Array()
var _water: MeshInstance3D = null
var _flag_cloth: MeshInstance3D = null
var _flag_mat: StandardMaterial3D = null
var _flag_pop: float = 0.0
var _splash: AudioStreamPlayer3D = null
var _boing: AudioStreamPlayer3D = null
var _rumble: AudioStreamPlayer3D = null
var _audible: bool = true

@onready var _camera: ArenaCamera = $ArenaCamera as ArenaCamera


func _ready() -> void:
	_audible = DisplayServer.get_name() != "headless"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tide-freeze="):
			_freeze_at = arg.trim_prefix("--tide-freeze=").to_float()
		elif arg.begins_with("--tide-place="):
			_place_level = arg.trim_prefix("--tide-place=").to_int()
	_index_pieces()
	_build_static()
	_build_crumbles()
	_build_hanging()
	_build_awnings()
	_build_decor()
	# Perf: repeated static pieces (crates, shelves, wall storeys, pillars, torches) as one
	# MultiMesh each, the rest merged per 8 m of tower; the flag waves (skipped).
	for n: Node3D in [$Tower, $Decor]:
		StaticMerge.batch(n)
		StaticMerge.merge(n, [], 8.0)
	_build_water()
	_build_audio()
	_update_movers(0.0)
	if _camera:
		_camera.fixed_focus = Vector3(0.0, 2.6, -0.6)
		_camera.fixed_distance = 18.0
		_camera.snap()


func _exit_tree() -> void:
	for p: AudioStreamPlayer3D in [_splash, _boing, _rumble]:
		if p:
			p.stop()
			p.stream = null


# --- Minigame flow --------------------------------------------------------------------------

func _setup(setup_players: Array[Player]) -> void:
	roof_times.clear()
	summit_slot = -1
	drown_groups.clear()
	drown_times.clear()
	_route_alt.clear()
	_heights.clear()
	for p in setup_players:
		p.eliminated.connect(_on_player_eliminated.bind(p))
	if multiplayer.is_server():
		if tower_seed < 0:
			tower_seed = randi() % 1000000
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--tide-seed="):
				tower_seed = arg.trim_prefix("--tide-seed=").to_int()
		var slots := PackedInt32Array()
		for p in setup_players:
			slots.append(p.slot)
		_rpc_spawn_layout.rpc(spawn_order(slots, tower_seed))


func _start() -> void:
	if not multiplayer.is_server():
		return
	var t0 := start_time
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tide-start="):
			t0 = arg.trim_prefix("--tide-start=").to_float()
	begin(tower_seed if tower_seed >= 0 else randi() % 1000000, t0)
	if not finished.is_connected(_on_finished):
		finished.connect(_on_finished)
	if _place_level >= 0:
		_place_all_at(_place_level)


## Host: (re)starts the round clock on every peer at `t0` with the seed `seed_value`.
func begin(seed_value: int, t0: float = 0.0) -> void:
	_rpc_begin.rpc(seed_value, t0)


## The spawn point index of every slot (in `slots` order), shuffled by the seed so no slot always
## starts nearest the stairs.
static func spawn_order(slots: PackedInt32Array, seed_value: int) -> PackedInt32Array:
	var idx: Array[int] = []
	for i in slots.size():
		idx.append(i)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 31 + 17
	for i in range(idx.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := idx[i]
		idx[i] = idx[j]
		idx[j] = tmp
	var out := PackedInt32Array()
	for slot_i in slots.size():
		out.append(slots[slot_i])
		out.append(idx[slot_i])
	return out


func _host_tick(delta: float) -> void:
	if not _running or is_finished():
		return
	var dt := maxf(_t - _prev_t, 0.0)
	_prev_t = _t
	var h := TideTower.water_height(_t)
	# drowning: same-tick drownings share a place
	var sinking: Array[Player] = []
	for p in players:
		if not _live(p):
			continue
		if _centre_y(p) < h:
			_under[p.slot] = _under.get(p.slot, 0.0) + dt
			if _under[p.slot] >= drown_time - 0.0001:
				sinking.append(p)
		else:
			_under[p.slot] = 0.0
	if not sinking.is_empty():
		_drown(sinking)
		if is_finished():
			return
	# roof arrivals and the summit
	for p in players:
		if not _live(p):
			continue
		var pos := p.global_position
		if TideTower.on_roof(pos) and not roof_times.has(p.slot):
			_rpc_roof.rpc(p.slot, _t)
		if summit_slot < 0 and TideTower.touches_flag(pos):
			_rpc_summit.rpc(p.slot)
	_tick_crumbles()
	_rethink_cd -= delta
	if _rethink_cd <= 0.0:
		_rethink_cd = RETHINK_INTERVAL
		request_bot_rethink()
	if _t >= TideTower.water_end_time() or (time_limit > 0.0 and _t >= time_limit):
		finish(current_ranking(), 2.0)


func _drown(sinking: Array[Player]) -> void:
	var group: Array[int] = []
	for p in sinking:
		group.append(p.slot)
		drown_times[p.slot] = _t
		knocked_out.append(p.slot)
		p.eliminate(&"drowned")
	group.sort()
	drown_groups.append(group)
	var alive := 0
	for p in players:
		if _live(p):
			alive += 1
	if alive == 0 or (alive == 1 and players.size() > 1):
		finish(current_ranking(), 2.0)


## Host: the ranking right now (see the class doc).
func current_ranking() -> Array:
	var survivors: Dictionary = {}
	for p in players:
		if not _live(p):
			continue
		var pos := p.global_position
		survivors[p.slot] = {
			"height": pos.y,
			"roof_t": roof_times.get(p.slot, -1.0) if TideTower.on_roof(pos) else -1.0,
		}
	var summit := summit_slot if survivors.has(summit_slot) else -1
	return TideTower.rank(survivors, summit, drown_groups)


func _on_finished(_ranking: Array[int]) -> void:
	if finish_groups.is_empty():
		return
	var top: Array = finish_groups[0]
	for s: Variant in top:
		var p := _player(int(s))
		if p and p.alive:
			_rpc_celebrate.rpc(int(s))


func _physics_process(delta: float) -> void:
	if not _running:
		return
	_t = minf(_t + delta * _clock_scale(), _freeze_at)
	_update_movers(_t)
	if not is_finished():
		_awning_launches(delta)
	_update_banners()


## Seconds on the round clock (every peer).
func round_time() -> float:
	return _t


func seed_value() -> int:
	return _seed


func is_running() -> bool:
	return _running


## Water surface height now (every peer).
func water_y() -> float:
	return TideTower.water_height(_t)


## Hanging platform `index`'s centre-top position at round time `t`.
func hanging_position(index: int, t: float) -> Vector3:
	var pc: TideTower.Piece = TideTower.piece(_hang_ids[index])
	var c := pc.center()
	return Vector3(c.x + TideTower.sway(pc.section, t, _phase), pc.top, c.z)


# --- Crumbles (host decides, every peer applies) ---------------------------------------------------

func _tick_crumbles() -> void:
	var crack := PackedInt32Array()
	var fall := PackedInt32Array()
	var regrow := PackedInt32Array()
	for i in _crumble_ids.size():
		var pc: TideTower.Piece = TideTower.piece(_crumble_ids[i])
		match crumble_state[i]:
			CrumbleState.SOLID:
				for p in players:
					if _live(p) and _stands_on(p, pc):
						crack.append(i)
						break
			CrumbleState.CRACKING:
				if _t - _crumble_t[i] >= crumble_delay - 0.0001:
					fall.append(i)
			CrumbleState.FALLEN:
				if _t - _crumble_t[i] >= crumble_regrow and not _blocked(pc):
					regrow.append(i)
	if not crack.is_empty():
		for i in crack:
			_crumble_t[i] = _t
		_rpc_crumble.rpc(crack)
	if not fall.is_empty():
		for i in fall:
			_crumble_t[i] = _t
		_rpc_crumble_fall.rpc(fall)
	if not regrow.is_empty():
		_rpc_crumble_regrow.rpc(regrow)


## True when `p` stands (grounded) on top of piece `pc`.
func _stands_on(p: Player, pc: TideTower.Piece) -> bool:
	var pos := p.global_position
	if absf(pos.y - pc.top) > 0.2 or not pc.covers(pos.x, pos.z, -0.3):
		return false
	return _is_grounded(p)


## True when a living player's body overlaps piece `pc` (a block must not grow back into anyone).
func _blocked(pc: TideTower.Piece) -> bool:
	for p in players:
		if not _live(p):
			continue
		var pos := p.global_position
		if pc.covers(pos.x, pos.z, -0.5) and pos.y < pc.top + 0.05 and pos.y + 1.3 > pc.bottom:
			return true
	return false


func _is_grounded(p: Player) -> bool:
	if p.is_authority():
		return p.is_on_floor()
	var sync := p.get_component(&"sync") as SyncComponent
	return sync != null and sync.is_grounded()


@rpc("authority", "call_local", "reliable")
func _rpc_crumble(ids: PackedInt32Array) -> void:
	for i in ids:
		if i < 0 or i >= crumble_state.size() or crumble_state[i] != CrumbleState.SOLID:
			continue
		crumble_state[i] = CrumbleState.CRACKING
		_crumble_anim[i] = 0.0
		var at := TideTower.piece(_crumble_ids[i]).center()
		Fx.play(&"dust_puff", at + Vector3.UP * 0.4, Color(0.75, 0.65, 0.5))
		Sfx.play(&"platform_crack", at)
		crumble_cracked.emit(i)
	request_bot_rethink()


@rpc("authority", "call_local", "reliable")
func _rpc_crumble_fall(ids: PackedInt32Array) -> void:
	for i in ids:
		if i < 0 or i >= crumble_state.size() or crumble_state[i] == CrumbleState.FALLEN:
			continue
		crumble_state[i] = CrumbleState.FALLEN
		_crumble_anim[i] = 0.0
		_crumble_shapes[i].disabled = true
		_crumble_bodies[i].collision_layer = 0
		var at := TideTower.piece(_crumble_ids[i]).center()
		Fx.play(&"dust_puff", at, Color(0.8, 0.7, 0.55))
		_play3d(_rumble, at)
		crumble_fell.emit(i)
	request_bot_rethink()


@rpc("authority", "call_local", "reliable")
func _rpc_crumble_regrow(ids: PackedInt32Array) -> void:
	for i in ids:
		if i < 0 or i >= crumble_state.size() or crumble_state[i] != CrumbleState.FALLEN:
			continue
		crumble_state[i] = CrumbleState.SOLID
		_crumble_anim[i] = 0.0
		_crumble_shapes[i].disabled = false
		_crumble_bodies[i].collision_layer = 1
		var vis := _crumble_vis[i]
		vis.visible = true
		vis.position = Vector3.ZERO
		vis.rotation = Vector3.ZERO
		vis.scale = Vector3.ONE * 0.2
		Fx.play(&"respawn_sparkle", TideTower.piece(_crumble_ids[i]).center(), Color(0.95, 0.85, 0.6))
		crumble_regrew.emit(i)
	request_bot_rethink()


## True while crumble block `index` has a collider (SOLID or CRACKING).
func crumble_has_collider(index: int) -> bool:
	return index >= 0 and index < _crumble_shapes.size() and not _crumble_shapes[index].disabled \
			and _crumble_bodies[index].collision_layer != 0


## Crumble index of piece id `id`, -1 if it is not a crumble block.
func crumble_index_of(id: int) -> int:
	return _crumble_ids.find(id)


# --- Other RPCs ---------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_begin(seed_value_: int, t0: float) -> void:
	_seed = seed_value_
	_phase = TideTower.sway_phase(seed_value_)
	_t = t0
	_t_vis = t0
	_prev_t = t0
	_running = true
	_banner_step = 0
	_under.clear()
	_route_alt.clear()
	crumble_state.fill(CrumbleState.SOLID)
	_crumble_t.fill(0.0)
	for i in _crumble_vis.size():
		_crumble_shapes[i].disabled = false
		_crumble_bodies[i].collision_layer = 1
		_crumble_vis[i].visible = true
		_crumble_vis[i].position = Vector3.ZERO
		_crumble_vis[i].rotation = Vector3.ZERO
		_crumble_vis[i].scale = Vector3.ONE
	_update_movers(_t)
	round_began.emit(seed_value_, t0)


@rpc("authority", "call_local", "reliable")
func _rpc_spawn_layout(pairs: PackedInt32Array) -> void:
	for k in range(0, pairs.size() - 1, 2):
		var p := _player(pairs[k])
		if p:
			p.place_at(global_transform * TideTower.spawn_xform(pairs[k + 1]))


@rpc("authority", "call_local", "reliable")
func _rpc_roof(slot: int, time: float) -> void:
	if roof_times.has(slot):
		return
	roof_times[slot] = time
	var p := _player(slot)
	if p:
		Fx.play(&"respawn_sparkle", p.global_position + Vector3.UP * 0.5, _player_color(slot))
	if roof_times.size() == 1:
		RoundUI.push_banner("%s reached the roof!" % _name_of(slot), 1.6)
	roof_reached.emit(slot, time)


@rpc("authority", "call_local", "reliable")
func _rpc_summit(slot: int) -> void:
	if summit_slot >= 0:
		return
	summit_slot = slot
	if _flag_mat:
		_flag_mat.albedo_color = _player_color(slot)
	_flag_pop = 1.0
	var at := global_transform * TideTower.FLAG_POS + Vector3.UP * 2.6
	Fx.play(&"confetti", at, _player_color(slot))
	Sfx.play(&"coin_big", at)
	RoundUI.push_banner("%s claims the summit!" % _name_of(slot), 2.0)
	summit_reached.emit(slot)


@rpc("authority", "call_local", "reliable")
func _rpc_celebrate(slot: int) -> void:
	var p := _player(slot)
	if p == null:
		return
	var visuals := p.get_component(&"visuals") as VisualsComponent
	if visuals:
		visuals.play_emote(&"cheer", true)
	Fx.play(&"confetti", p.global_position + Vector3.UP * 1.4, _player_color(slot))
	_flag_pop = 1.0
	Sfx.play(&"round_win_jingle")


func _on_player_eliminated(reason: StringName, p: Player) -> void:
	if not String(reason).contains("drown"):
		return
	var at := p.global_position
	var surface := Vector3(at.x, maxf(water_y(), at.y), at.z)
	var fx := Fx.play(&"splash_lava", surface, WATER_COLOR)
	if fx:
		fx.scale = Vector3.ONE * 1.3
	Fx.play(&"dust_puff", surface + Vector3.UP * 0.1, Color(0.85, 0.97, 1.0))
	_play3d(_splash, surface)
	if _camera and p.slot == Net.local_slot():
		_camera.add_shake(0.3)
	drowned.emit(p.slot)


# --- Awnings (every peer, own players) --------------------------------------------------------------

func _awning_launches(delta: float) -> void:
	for s: int in _launch_cd:
		_launch_cd[s] -= delta
	for s: int in _boing_cd:
		_boing_cd[s] -= delta
	for p in players:
		if not _live(p) or p.frozen:
			continue
		var pos := p.global_position
		for k in _awning_ids.size():
			var pc: TideTower.Piece = TideTower.piece(_awning_ids[k])
			if not pc.covers(pos.x, pos.z, -0.3) or pos.y < pc.top - 0.25 or pos.y > pc.top + 1.6:
				continue
			if p.is_authority() and pos.y <= pc.top + 0.3 and p.velocity.y <= 1.0 and _launch_cd.get(p.slot, 0.0) <= 0.0:
				_launch_cd[p.slot] = 0.35
				p.velocity.y = launch_speed(p)
				launched.emit(p.slot)
			if p.velocity.y > 6.0 and _boing_cd.get(p.slot, 0.0) <= 0.0:
				_boing_cd[p.slot] = 0.5
				_awning_pop[k] = 1.0
				_play3d(_boing, Vector3(pos.x, pc.top, pos.z))
				Fx.play(&"dust_puff", Vector3(pos.x, pc.top, pos.z), Color(0.95, 0.75, 0.7))


## Upward speed an awning gives `p` so it rises `awning_apex` m under its own gravity.
func launch_speed(p: Player) -> float:
	var jump := p.get_component(&"jump") as JumpComponent
	var g := jump.get_gravity_strength() if jump else 21.2
	return sqrt(2.0 * g * awning_apex)


# --- Bots -----------------------------------------------------------------------------------------

## The next waypoint for `player` up the tower (see the class doc).
func get_bot_goal(player: Player) -> Vector3:
	if player == null:
		return Vector3.ZERO
	var pos := player.global_position
	var n := TideTower.level_of(pos.y)
	if n >= TideTower.SECTIONS:
		if summit_slot < 0:
			return TideTower.FLAG_POS
		var taste := _hash01(player.slot * 7919 + int(_t / 4.0) * 104729 + _seed)
		var taste2 := _hash01(player.slot * 131 + int(_t / 4.0) * 7 + _seed * 3)
		return Vector3(lerpf(TideTower.ROOF_X0 + 0.6, TideTower.ROOF_X1 - 0.6, taste), TideTower.ROOF_Y, lerpf(TideTower.Z_BACK + 0.6, TideTower.Z_FRONT - 0.6, taste2))
	var s := n
	var d := TideTower.dir(s)
	var e := TideTower.edge_x(s)
	var xl := TideTower.low_x(s)
	var y := TideTower.floor_y(s)
	var alt := wants_alt(player, s)
	var lane := TideTower.LANE_MID if alt else TideTower.LANE_BACK
	var top_x := e + d * 1.6
	if s == TideTower.SECTIONS - 1:
		top_x = clampf(top_x, TideTower.ROOF_X0 + 0.5, TideTower.ROOF_X1 - 0.5)
	var on := support_piece(pos)
	var pc: TideTower.Piece = TideTower.piece(on) if on >= 0 else null
	if pc and pc.section == s and pc.kind != TideTower.Kind.FLOOR and pc.kind != TideTower.Kind.ROOF:
		if pc.kind == TideTower.Kind.CRUMBLE and not _route_intact_above(pc):
			# the next block fell: over to the main stairs beside it
			return Vector3(pos.x, y + TideTower.STEP_H * (pc.step + 1), TideTower.LANE_BACK)
		var lz := TideTower.LANE_BACK if pc.kind == TideTower.Kind.STEP else TideTower.LANE_MID
		return Vector3(top_x, y + TideTower.LEVEL, lz)
	if player.velocity.y > 8.0 and pos.y < y + TideTower.LEVEL + 0.2:
		return pos  # launched by an awning: rise straight up the column until clear of the edge
	var u := (pos.x - xl) * d
	var path: Array[Vector3] = []
	var top := Vector3(top_x, y + TideTower.LEVEL, lane)
	if alt and TideTower.ALT_KIND[s] == TideTower.Alt.AWNING:
		var aw := TideTower.piece(_awning_ids[_awning_index(s)]).center()
		if u > TideTower.LEVEL + 0.15 and absf(pos.z - TideTower.LANE_MID) > 0.35:
			path.append(Vector3(xl + d * (TideTower.LEVEL + 0.55), y, TideTower.LANE_MID))
		path.append(Vector3(aw.x, y + TideTower.AWNING_H, TideTower.LANE_MID))
		path.append(top)
	elif absf(pos.z - lane) <= 0.5 and u < 0.3:
		path.append(top)  # in the route's lane at its foot: up
	elif u < -0.3:
		path.append(Vector3(xl - d * 1.0, y, lane))  # past the low end: into the route's lane
		path.append(top)
	else:
		if pos.z < -0.05:
			# step out to the walkway first (never cut diagonally through the stairs)
			var span := TideTower.floor_span(s)
			var x := pos.x + d * 0.2 if u > TideTower.LEVEL - 0.05 else pos.x - d * 0.3
			path.append(Vector3(clampf(x, span.x + 0.6, span.y - 0.6), y, TideTower.LANE_FRONT))
		path.append(Vector3(xl - d * 1.15, y, TideTower.LANE_FRONT))
		path.append(Vector3(xl - d * 1.0, y, lane))
		path.append(top)
	# the first waypoint the bot has not reached yet (the brain stops within ~0.6 m of a goal)
	for w in path:
		if Vector2(w.x - pos.x, w.z - pos.z).length() > 0.75:
			return w
	return path[path.size() - 1]


## True when the bot `player` takes section `s`'s alt route (picked once per section from its skill
## and the alt's risk; never a crumble route with a block missing).
func wants_alt(player: Player, s: int) -> bool:
	var key := player.slot * 16 + s
	if not _route_alt.has(key):
		var skill := 0.6
		var brain := BotBrain.of(player)
		if brain:
			skill = brain.skill
		var risk: int = TideTower.ALT_RISK[TideTower.ALT_KIND[s]]
		var chance := clampf(0.55 - 0.15 * risk + 0.4 * skill, 0.05, 0.85)
		_route_alt[key] = _hash01(_seed * 37 + player.slot * 7717 + s * 131) < chance
	if not _route_alt[key]:
		return false
	return TideTower.ALT_KIND[s] != TideTower.Alt.CRUMBLE or _crumbles_intact(s)


## Test hook: forces `player`'s route in section `s` (true = the alt).
func force_route(player: Player, s: int, alt: bool) -> void:
	_route_alt[player.slot * 16 + s] = alt


func _crumbles_intact(s: int) -> bool:
	for i in _crumble_ids.size():
		if TideTower.piece(_crumble_ids[i]).section == s and crumble_state[i] != CrumbleState.SOLID:
			return false
	return true


func _route_intact_above(pc: TideTower.Piece) -> bool:
	for i in _crumble_ids.size():
		var other: TideTower.Piece = TideTower.piece(_crumble_ids[i])
		if other.section == pc.section and other.step > pc.step and crumble_state[i] == CrumbleState.FALLEN:
			return false
	return true


func _awning_index(s: int) -> int:
	for k in _awning_ids.size():
		if TideTower.piece(_awning_ids[k]).section == s:
			return k
	return 0


## Id of the piece a blob with feet at `pos` stands on or just above (the highest whose top is at
## most a little above the feet), -1 over nothing.
func support_piece(pos: Vector3, inset: float = -0.1) -> int:
	var best := -1
	var best_top := -INF
	for id: int in _bucket(pos.y):
		var pc: TideTower.Piece = TideTower.piece(id)
		if pc.top > pos.y + 0.25 or pc.top <= best_top:
			continue
		if not _piece_solid(pc):
			continue
		if not _covers_now(pc, pos.x, pos.z, inset, _t):
			continue
		best = id
		best_top = pc.top
	return best


func is_safe(pos: Vector3) -> bool:
	# the walls are no danger (no drop, nothing to fall in): judge points past them where a blob
	# pressed against the wall would stand, so goals in the back lane do not look unsafe
	pos.x = clampf(pos.x, -TideTower.HALF_W + 0.35, TideTower.HALF_W - 0.35)
	pos.z = clampf(pos.z, TideTower.Z_BACK + 0.35, TideTower.Z_FRONT - 0.35)
	var best_top := -INF
	var best: TideTower.Piece = null
	for id: int in _bucket(pos.y):
		var pc: TideTower.Piece = TideTower.piece(id)
		if pc.top > pos.y + 1.05:
			if pc.bottom < pos.y + 1.0 and _piece_solid(pc) and _covers_now(pc, pos.x, pos.z, 0.12, _t):
				return false  # inside a wall
			continue
		# grown a hair, so neighbouring steps leave no seam between them
		if not _covers_now(pc, pos.x, pos.z, -0.03, _t):
			continue
		if pc.top < pos.y - 2.2 or pc.top <= best_top:
			continue
		if not _piece_solid(pc):
			continue
		best_top = pc.top
		best = pc
	if best == null:
		return false
	if best.kind == TideTower.Kind.CRUMBLE and crumble_state[_crumble_ids.find(best.id)] != CrumbleState.SOLID:
		return false
	if best.kind == TideTower.Kind.HANGING and not _covers_now(best, pos.x, pos.z, 0.12, _t + HANG_AHEAD * _clock_scale()):
		return false
	return best_top + 0.5 > TideTower.water_height(_t + SAFE_WATER_AHEAD * _clock_scale()) + SAFE_WATER_MARGIN


func _piece_solid(pc: TideTower.Piece) -> bool:
	if pc.kind != TideTower.Kind.CRUMBLE:
		return true
	var i := _crumble_ids.find(pc.id)
	return i < 0 or crumble_state[i] != CrumbleState.FALLEN


func _covers_now(pc: TideTower.Piece, x: float, z: float, inset: float, t: float) -> bool:
	if pc.kind == TideTower.Kind.HANGING:
		x -= TideTower.sway(pc.section, t, _phase)
	return pc.covers(x, z, inset)


func _bucket(y: float) -> Array:
	var k := clampi(floori(y / TideTower.LEVEL), 0, _buckets.size() - 1)
	return _buckets[k]


func _index_pieces() -> void:
	_crumble_ids = TideTower.ids_of(TideTower.Kind.CRUMBLE)
	_hang_ids = TideTower.ids_of(TideTower.Kind.HANGING)
	_awning_ids = TideTower.ids_of(TideTower.Kind.AWNING)
	crumble_state.resize(_crumble_ids.size())
	crumble_state.fill(CrumbleState.SOLID)
	_crumble_t.resize(_crumble_ids.size())
	_crumble_anim.resize(_crumble_ids.size())
	_awning_pop.resize(_awning_ids.size())
	_buckets.clear()
	for k in TideTower.SECTIONS + 1:
		var lo := k * TideTower.LEVEL - 2.5
		var hi := (k + 1) * TideTower.LEVEL + 1.5
		var ids: Array[int] = []
		for pc: TideTower.Piece in TideTower.pieces():
			if pc.top >= lo and pc.bottom <= hi:
				ids.append(pc.id)
		_buckets.append(ids)


# --- Presentation (every peer) ------------------------------------------------------------------------

func _process(delta: float) -> void:
	_anim += delta
	if _running:
		var frac := Engine.get_physics_interpolation_fraction()
		_t_vis = minf(_t + frac / float(Engine.physics_ticks_per_second) * _clock_scale(), _freeze_at)
	if _water:
		_water.position.y = TideTower.water_height(_t_vis)
	_animate(delta)
	_update_camera()
	_hud_cd -= delta
	if _hud_cd <= 0.0:
		_hud_cd = 0.25
		_update_hud()


func _update_hud() -> void:
	for p in players:
		if not _live(p):
			continue
		var hgt := maxi(0, roundi(p.global_position.y))
		if _heights.get(p.slot, -1) != hgt:
			_heights[p.slot] = hgt
			RoundUI.push_counter(p.slot, hgt)


## Banners from the round clock (every peer computes the same moments).
func _update_banners() -> void:
	var b0 := TideTower.breather_start(0)
	var b1 := TideTower.breather_start(1)
	var steps: Array[float] = [0.2, b0, b0 + TideTower.BREATHER_TIME, b1, b1 + TideTower.BREATHER_TIME]
	var texts: Array[String] = ["The water is rising!", "Breather!", "The water is rising!", "Breather!", "The water is rising!"]
	while _banner_step < steps.size() and _t >= steps[_banner_step]:
		if _t < steps[_banner_step] + 1.0:
			RoundUI.push_banner(texts[_banner_step], 1.6)
			if _banner_step % 2 == 1:
				request_bot_rethink()
		_banner_step += 1


## Moves the hanging platforms to round time `t` (physics frames).
func _update_movers(t: float) -> void:
	for i in _hang_bodies.size():
		var body := _hang_bodies[i]
		var at := hanging_position(i, t)
		body.position = at
		_hang_vis[i].rotation.z = -TideTower.sway(TideTower.piece(_hang_ids[i]).section, t, _phase) * 0.12
		for c in 2:
			var chain := _chains[i * 2 + c]
			var anchor := _chain_anchor[i * 2 + c]
			var tip := at + Vector3(-0.35 if c == 0 else 0.35, 0.16, 0.0)
			var v := tip - anchor
			chain.position = anchor
			chain.rotation = Vector3(0.0, 0.0, atan2(v.x, -v.y))
			chain.scale = Vector3(1.0, v.length(), 1.0)


func _animate(delta: float) -> void:
	for i in _crumble_vis.size():
		var vis := _crumble_vis[i]
		_crumble_anim[i] += delta
		var a := _crumble_anim[i]
		match crumble_state[i]:
			CrumbleState.CRACKING:
				var k := clampf(a / maxf(crumble_delay, 0.01), 0.0, 1.0)
				var amp := 0.02 + 0.06 * k
				vis.rotation = Vector3(sin(a * 31.0 + i) * amp, 0.0, cos(a * 27.0 + i) * amp)
				vis.position = Vector3(sin(a * 43.0) * 0.02, -0.03 * k, 0.0)
			CrumbleState.FALLEN:
				if vis.visible:
					vis.position.y -= (2.0 + 14.0 * a) * delta
					vis.rotation.x += delta * 0.8
					vis.rotation.z += delta * 0.5 * (1.0 if i % 2 == 0 else -1.0)
					if a > 1.4:
						vis.visible = false
			CrumbleState.SOLID:
				if vis.scale.x < 1.0:
					vis.scale = Vector3.ONE * minf(vis.scale.x + delta * 3.0, 1.0)
				vis.rotation = Vector3.ZERO
				vis.position = Vector3.ZERO
	for k in _awning_vis.size():
		_awning_pop[k] = maxf(_awning_pop[k] - delta * 3.0, 0.0)
		var pop := _awning_pop[k]
		_awning_vis[k].scale = Vector3(1.0 + 0.15 * pop, 1.0 - 0.45 * pop * cos(_anim * 30.0), 1.0 + 0.15 * pop)
	if _flag_cloth:
		_flag_pop = maxf(_flag_pop - delta * 0.8, 0.0)
		_flag_cloth.rotation.y = 0.25 * sin(_anim * 3.0) + _flag_pop * sin(_anim * 16.0) * 0.5


func _update_camera() -> void:
	if _camera == null or players.is_empty():
		return
	var pts: Array[Vector3] = []
	var ys: Array[float] = []
	var h := TideTower.water_height(_t_vis)
	for p in players:
		if not _live(p):
			continue
		var at := p.global_position
		at.x = clampf(at.x, -TideTower.HALF_W, TideTower.HALF_W)
		at.y = maxf(at.y, h - 0.5) + _camera.target_height
		at.z = clampf(at.z, TideTower.Z_BACK, TideTower.Z_FRONT)
		pts.append(at)
		ys.append(at.y)
	if pts.is_empty():
		pts.append(Vector3(0.0, maxf(h, 0.0) + 1.5, TideTower.LANE_MID))
		ys.append(pts[0].y)
	var lo: float = ys.min()
	var hi: float = ys.max()
	if hi - lo > CAM_SPREAD:
		var me := _player(Net.local_slot())
		var anchor := INF
		if _live(me):
			anchor = me.global_position.y + _camera.target_height
		var best_top := hi
		var best_count := -1
		for top: float in ys:
			if anchor != INF and (anchor > top + 0.01 or anchor < top - CAM_SPREAD):
				continue
			var count := 0
			for y: float in ys:
				if y <= top + 0.01 and y >= top - CAM_SPREAD:
					count += 1
			if count > best_count or (count == best_count and top > best_top):
				best_count = count
				best_top = top
		if best_count < 0:
			best_top = anchor + CAM_SPREAD * 0.5
		var window: Array[Vector3] = []
		for p3 in pts:
			if p3.y <= best_top + 0.01 and p3.y >= best_top - CAM_SPREAD:
				window.append(p3)
		if window.is_empty():
			window.append(Vector3(0.0, best_top, TideTower.LANE_MID))
		pts = window
		lo = INF
		for p3 in pts:
			lo = minf(lo, p3.y)
	var mid := 0.0
	for p3 in pts:
		mid += p3.y
	mid /= pts.size()
	# the whole tower width always, and the water line when it is close below
	pts.append(Vector3(-TideTower.HALF_W - 0.4, mid, TideTower.Z_FRONT))
	pts.append(Vector3(TideTower.HALF_W + 0.4, mid, TideTower.Z_FRONT))
	if h > lo - CAM_WATER_NEAR:
		pts.append(Vector3(0.0, h - 0.6, TideTower.Z_FRONT + 1.0))
	var tan_v := tan(deg_to_rad(_camera.fov) * 0.5)
	var vp := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(16.0, 9.0)
	var aspect := vp.x / vp.y if vp.y > 0.0 else 16.0 / 9.0
	var framed := ArenaCamera.frame_points(pts, _camera.view_basis(), tan_v, aspect, _camera.margin)
	var focus: Vector3 = framed[0]
	focus.x = clampf(focus.x, -1.5, 1.5)
	_camera.fixed_focus = focus
	_camera.fixed_distance = clampf(float(framed[1]), CAM_MIN_DISTANCE, CAM_MAX_DISTANCE)


# --- Build ----------------------------------------------------------------------------------------------

func _build_static() -> void:
	var body := StaticBody3D.new()
	body.name = "Colliders"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var root := $Tower as Node3D
	for pc: TideTower.Piece in TideTower.pieces():
		if pc.kind == TideTower.Kind.FLOOR or pc.kind == TideTower.Kind.ROOF or pc.kind == TideTower.Kind.STEP:
			_add_box(body, pc.size(), pc.center())
	# walls: back, sides, an invisible front (nobody leaves the tower)
	var hgt := 34.0
	var cy := TideTower.BED_Y + hgt * 0.5
	var depth := TideTower.Z_FRONT - TideTower.Z_BACK
	_add_box(body, Vector3(2.0 * TideTower.HALF_W + 4.0, hgt, 1.0), Vector3(0.0, cy, TideTower.Z_BACK - 0.5))
	_add_box(body, Vector3(2.0 * TideTower.HALF_W + 4.0, hgt, 1.0), Vector3(0.0, cy, TideTower.Z_FRONT + 0.5))
	for s: float in [-1.0, 1.0]:
		_add_box(body, Vector3(1.0, hgt, depth + 2.0), Vector3(s * (TideTower.HALF_W + 0.5), cy, (TideTower.Z_BACK + TideTower.Z_FRONT) * 0.5))
	# visuals: floors, shelves, roof
	var zc := (TideTower.Z_BACK + TideTower.Z_FRONT) * 0.5
	for pc: TideTower.Piece in TideTower.pieces():
		var c := pc.center()
		if pc.kind == TideTower.Kind.FLOOR:
			if pc.section == 0:
				_place(root, FLOOR_SCENE, Vector3(0.0, -TideTower.FLOOR_THICK, zc), 0.0)
			else:
				_place(root, SHELF_SCENE, Vector3(c.x, pc.top - TideTower.FLOOR_THICK, zc), 0.0)
		elif pc.kind == TideTower.Kind.ROOF:
			_place(root, ROOF_SCENE, Vector3(c.x, pc.top - TideTower.FLOOR_THICK, zc), 0.0)
	# main routes
	for s in TideTower.SECTIONS:
		var y := TideTower.floor_y(s)
		var e := TideTower.edge_x(s)
		var d := TideTower.dir(s)
		if TideTower.MAIN_KIND[s] == TideTower.Main.LADDER:
			_place(root, LADDER_SCENE, Vector3(e, y, TideTower.LANE_BACK), 0.0 if d < 0.0 else PI)
		else:
			for pc: TideTower.Piece in TideTower.pieces():
				if pc.section != s or pc.kind != TideTower.Kind.STEP:
					continue
				for k in pc.step:
					var crate := _place(root, CRATE_SCENE, Vector3(pc.center().x, y + TideTower.STEP_H * k, TideTower.LANE_BACK), PI * 0.5 * ((k + pc.step + s) % 2))
					crate.name = "Crate%d_%d_%d" % [s, pc.step, k]


func _build_crumbles() -> void:
	var root := $Crumbles as Node3D
	for i in _crumble_ids.size():
		var pc: TideTower.Piece = TideTower.piece(_crumble_ids[i])
		var body := StaticBody3D.new()
		body.name = "Crumble%d" % i
		body.collision_layer = 1
		body.collision_mask = 0
		var c := pc.center()
		body.position = Vector3(c.x, pc.bottom, c.z)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = pc.size()
		shape.shape = box
		shape.position = Vector3(0.0, pc.size().y * 0.5, 0.0)
		body.add_child(shape)
		var vis := Node3D.new()
		vis.name = "Visual"
		body.add_child(vis)
		for k in pc.step:
			var block := CRACKED_SCENE.instantiate() as Node3D
			block.position = Vector3(0.0, TideTower.STEP_H * k, 0.0)
			block.rotation.y = PI * 0.5 * ((k + i) % 2)
			vis.add_child(block)
		Look.apply_toon(vis)
		root.add_child(body)
		_crumble_bodies.append(body)
		_crumble_shapes.append(shape)
		_crumble_vis.append(vis)


func _build_hanging() -> void:
	var root := $Hanging as Node3D
	for i in _hang_ids.size():
		var pc: TideTower.Piece = TideTower.piece(_hang_ids[i])
		var body := AnimatableBody3D.new()
		body.name = "Hang%d" % i
		body.collision_layer = 1
		body.collision_mask = 0
		body.sync_to_physics = true
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = pc.size()
		shape.shape = box
		shape.position = Vector3(0.0, -TideTower.HANG_THICK * 0.5, 0.0)
		body.add_child(shape)
		var vis := HANGING_SCENE.instantiate() as Node3D
		body.add_child(vis)
		Look.apply_toon(vis)
		body.position = Vector3(pc.center().x, pc.top, pc.center().z)
		root.add_child(body)
		_hang_bodies.append(body)
		_hang_vis.append(vis)
		# chains up to the shelf two floors up (or the top beam)
		var anchor_y := TideTower.floor_y(pc.section + 2) - TideTower.FLOOR_THICK
		if pc.section + 2 > TideTower.SECTIONS - 1:
			anchor_y = TideTower.ROOF_Y + 2.6
		for c in 2:
			var chain := CHAIN_SCENE.instantiate() as Node3D
			Look.apply_toon(chain, false)
			root.add_child(chain)
			_chains.append(chain)
			_chain_anchor.append(Vector3(pc.center().x + (-0.35 if c == 0 else 0.35), anchor_y, pc.center().z))
	# the beam the last section's chains hang from
	for s in TideTower.SECTIONS:
		if TideTower.ALT_KIND[s] == TideTower.Alt.HANGING and s + 2 > TideTower.SECTIONS - 1:
			var e := TideTower.edge_x(s)
			var d := TideTower.dir(s)
			_place(root, BEAM_SCENE, Vector3(e - d * 2.0, TideTower.ROOF_Y + 2.75, TideTower.LANE_MID), 0.0)


func _build_awnings() -> void:
	var root := $Awnings as Node3D
	for k in _awning_ids.size():
		var pc: TideTower.Piece = TideTower.piece(_awning_ids[k])
		var body := StaticBody3D.new()
		body.name = "Awning%d" % k
		body.collision_layer = 1
		body.collision_mask = 0
		var c := pc.center()
		body.position = Vector3(c.x, pc.bottom, c.z)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = pc.size()
		shape.shape = box
		shape.position = Vector3(0.0, pc.size().y * 0.5, 0.0)
		body.add_child(shape)
		var vis := AWNING_SCENE.instantiate() as Node3D
		body.add_child(vis)
		Look.apply_toon(vis)
		root.add_child(body)
		_awning_vis.append(vis)


func _build_decor() -> void:
	var root := $Decor as Node3D
	# back wall, storey by storey, from the water's bed to above the roof
	var y := TideTower.BED_Y
	var k := 0
	while y < TideTower.ROOF_Y + 3.0:
		_place(root, WALL_SCENES[k % 2], Vector3(0.0, y, TideTower.Z_BACK), 0.0, false)
		y += TideTower.LEVEL
		k += 1
	# side walls (dark, plain) and the cut-away front corner columns
	var side_mat := Look.toon_material(Color("#3d3b4a"), 0.9, false)
	for s: float in [-1.0, 1.0]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.6, y - TideTower.BED_Y, TideTower.Z_FRONT - TideTower.Z_BACK + 0.6)
		mi.mesh = bm
		mi.material_override = side_mat
		mi.position = Vector3(s * (TideTower.HALF_W + 0.3), (y + TideTower.BED_Y) * 0.5, (TideTower.Z_BACK + TideTower.Z_FRONT) * 0.5 - 0.3)
		root.add_child(mi)
		var py := TideTower.BED_Y
		var col_top := y - 1.2 + (0.6 if s > 0.0 else -1.4)
		while py + TideTower.LEVEL <= col_top:
			_place(root, PILLAR_SCENE, Vector3(s * (TideTower.HALF_W + 0.5), py, TideTower.Z_FRONT + 0.2), 0.0)
			py += TideTower.LEVEL
		_place(root, PILLAR_TOP_SCENE, Vector3(s * (TideTower.HALF_W + 0.5), py, TideTower.Z_FRONT + 0.2), 0.3 * s)
	# torches on the back wall (clear of the stairs) with a warm light every floor
	for n in TideTower.SECTIONS + 1:
		var fy := TideTower.floor_y(n)
		for tx: float in [-6.3, 6.3, 0.0]:
			if n == TideTower.SECTIONS and absf(tx) > 3.0:
				continue
			if tx == 0.0 and n == 0:
				continue
			_place(root, TORCH_SCENE, Vector3(tx, fy + 2.0, TideTower.Z_BACK + 0.02), 0.0, false)
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.72, 0.42)
		light.light_energy = 1.3
		light.omni_range = 7.5
		light.shadow_enabled = false
		light.position = Vector3(-3.5 if n % 2 == 0 else 3.5, fy + 2.6, TideTower.Z_BACK + 1.0)
		root.add_child(light)
	# the summit flag
	var flag := _place(root, FLAG_SCENE, TideTower.FLAG_POS, 0.0)
	flag.set_meta(StaticMerge.SKIP_META, true)  # the cloth waves
	_flag_cloth = flag.find_child("Flag", true, false) as MeshInstance3D
	if _flag_cloth:
		var src := _flag_cloth.get_active_material(0) as StandardMaterial3D
		if src:
			_flag_mat = src.duplicate() as StandardMaterial3D
			_flag_cloth.set_surface_override_material(0, _flag_mat)


func _build_water() -> void:
	_water = MeshInstance3D.new()
	_water.name = "Water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(44.0, 30.0)
	plane.subdivide_width = 16
	plane.subdivide_depth = 10
	_water.mesh = plane
	# the house water with finer, calmer highlight lines (the default bands read as rivers at this size)
	var m := WATER_MATERIAL.duplicate() as ShaderMaterial
	if m:
		m.set_shader_parameter(&"band_scale", 1.6)
		m.set_shader_parameter(&"foam_color", Color(0.5, 0.8, 0.78))
		m.set_shader_parameter(&"wave_height", 0.09)
		m.set_shader_parameter(&"foam_width", 0.45)
		_water.material_override = m
	else:
		_water.material_override = WATER_MATERIAL
	_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_water.position = Vector3(0.0, TideTower.water_height(0.0), TideTower.Z_BACK + 15.0)
	add_child(_water)


func _build_audio() -> void:
	_splash = _make_player("Splash", SPLASH_PATH, 2.0)
	_boing = _make_player("Boing", BOING_PATH, -2.0)
	_rumble = _make_player("Rumble", RUMBLE_PATH, 0.0)


func _make_player(node_name: String, path: String, volume: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.name = node_name
	p.bus = &"Sfx" if AudioServer.get_bus_index(&"Sfx") >= 0 else &"Master"
	p.stream = _load_stream(path)
	p.unit_size = 30.0
	p.volume_db = volume
	p.max_polyphony = 3
	add_child(p)
	return p


func _play3d(p: AudioStreamPlayer3D, at: Vector3) -> void:
	if p == null or not _audible or p.stream == null or not p.is_inside_tree():
		return
	p.global_position = at
	p.play()


## A path-less copy, like Sfx does: a cached stream still playing at quit logs an error.
static func _load_stream(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		return null
	var s := load(path) as AudioStream
	return s.duplicate() as AudioStream if s else null


func _place(parent: Node, scene: PackedScene, at: Vector3, yaw: float, outline: bool = true) -> Node3D:
	var n := scene.instantiate() as Node3D
	n.position = at
	n.rotation.y = yaw
	parent.add_child(n)
	Look.apply_toon(n, outline)
	return n


func _add_box(body: StaticBody3D, size: Vector3, at: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var cs := CollisionShape3D.new()
	cs.shape = box
	cs.position = at
	body.add_child(cs)


# --- Helpers ---------------------------------------------------------------------------------------------

## Dev (`--tide-place=N`): spreads every player over floor N's walkway (host, after _start).
func _place_all_at(n: int) -> void:
	n = clampi(n, 0, TideTower.SECTIONS)
	var span := TideTower.floor_span(n)
	for i in players.size():
		var p := players[i]
		var x := lerpf(span.x + 0.8, span.y - 0.8, float(i) / maxf(players.size() - 1, 1))
		var z: float = [TideTower.LANE_FRONT, TideTower.LANE_MID][i % 2]
		if n < TideTower.SECTIONS and i % 3 == 2:
			# a few already on the stairs
			var pc: TideTower.Piece = TideTower.piece(TideTower.route(n, false)[1])
			p.place_at(Transform3D(Basis.IDENTITY, Vector3(pc.center().x, pc.top + 0.05, TideTower.LANE_BACK)))
			continue
		p.place_at(Transform3D(Basis.IDENTITY, Vector3(x, TideTower.floor_y(n) + 0.05, z)))


func _centre_y(p: Player) -> float:
	var size := p.get_component(&"size") as SizeComponent
	var sc := size.body_scale if size else 1.0
	return p.global_position.y + 0.5 * sc


func _player_color(slot: int) -> Color:
	var p := _player(slot)
	if p and p.loadout.has("primary"):
		return Look.parse_color(p.loadout["primary"], Look.CREAM)
	return Look.CREAM


func _name_of(slot: int) -> String:
	var p := _player(slot)
	if p and p.display_name != "":
		return p.display_name
	return "P%d" % (slot + 1)


func _clock_scale() -> float:
	return time_scale * Session.time_scale


func _player(slot: int) -> Player:
	for p in players:
		if is_instance_valid(p) and p.slot == slot:
			return p
	return null


func _live(p: Player) -> bool:
	return p != null and is_instance_valid(p) and p.is_inside_tree() and p.alive


static func _hash01(n: int) -> float:
	var h := (n * 2654435761) & 0xffffffff
	h = ((h >> 16) ^ h) * 0x45d9f3b & 0xffffffff
	h = ((h >> 16) ^ h) & 0xffffffff
	return float(h % 10007) / 10007.0
