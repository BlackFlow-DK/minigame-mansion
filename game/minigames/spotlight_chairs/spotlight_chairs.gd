class_name SpotlightChairs
extends Minigame
## Spotlight Chairs: musical chairs in the mansion ballroom. With N blobs alive there are
## N-1 glowing pads, each under a spotlight. A waltz plays while everyone mills about; after
## a random 6-12 s (the host alone knows) the music winds down: a WARN_TIME warning (lights
## flicker, beeps), then the check. Every pad keeps one blob: the one that has stood on it
## the longest (the first on it). Everyone else is knocked out (`no_seat`). Shoving blobs off
## pads during the warning is the whole game: a blob shoved off before the check is out.
## Then a pause (winners cheer, everyone frozen), the pads sink and rise elsewhere (one fewer)
## and the music resumes. Last blob standing wins. Nobody on any pad: nobody is out, again.
##
## Host decides everything (music length, pad layouts, owners, who is out) and tells every
## peer through the reliable `call_local` RPCs below; `frozen` is set on every peer by those
## RPCs. Visuals (pad colours, sinking, flicker, the music itself) run on every peer from the
## state those RPCs set. The first layout is a symmetric ring built in _setup on every peer
## (visible during the countdown); later layouts are random, host-chosen and sent as positions.
## Time-out: under Session its backstop ends the round; without one (tests, sandbox) the
## minigame finishes itself at time_limit.
## Dev args (after `--`): `--chairs-time-scale=<x>` speeds up the host's music, warning and
## pause clocks (network check); `--chairs-music=<s>` forces the first music length (screenshots).

## Every peer: the music (re)started for round `index` (0-based).
signal music_started(index: int)
## Every peer: the music stopped, the warning runs.
signal music_stopped(index: int)
## Every peer: the check of round `index`: `owners[i]` is the slot kept by pad i (-1 = empty),
## `out_slots` are knocked out right after (farthest from a pad first).
signal checked(index: int, owners: Array, out_slots: Array)
## Every peer: the pads for round `index` moved to `positions`.
signal layout_changed(index: int, positions: Array)
## Every peer: pad owners changed (ownership shows as the pad's colour).
signal owners_changed(owners: Array)

enum Phase { IDLE, MUSIC, WARNING, PAUSE }

const PAD_SCENE: PackedScene = preload("res://assets/models/props/chairs_pad.glb")
const STAGE_SCENE: PackedScene = preload("res://assets/models/props/chairs_stage.glb")
const GRAMOPHONE_SCENE: PackedScene = preload("res://assets/models/props/chairs_gramophone.glb")
const ENV_DIR := "res://assets/models/env/"
const MUSIC_PATH := "res://audio/sfx/chairs_waltz_loop.wav"
const CONE_SHADER: Shader = preload("res://minigames/spotlight_chairs/spot_cone.gdshader")

# --- Room ----------------------------------------------------------------------------------
const HALF_X := 10.0
const BACK_Z := -8.0
const FRONT_Z := 8.0
## Stage deck: 7 m x 2.4 m, 0.5 m high, against the back wall.
const STAGE_POS := Vector3(0.0, 0.0, -6.65)
const STAGE_SIZE := Vector3(7.0, 0.5, 2.4)
## Blob centres stay inside this (walls minus blob radius and a margin); bots treat it as safe.
const SAFE_HALF_X := 9.0
const SAFE_BACK_Z := -7.2
const SAFE_FRONT_Z := 7.3
## Pads go inside this rectangle (x, z), shrunk toward PAD_CENTER for small counts.
const PAD_CENTER := Vector3(0.0, 0.0, 0.9)
const PAD_HALF := Vector2(7.4, 5.0)
const PAD_MIN_GAP := 2.6
## A new pad keeps this far from every old pad position when it can (so a shuffle shows).
const PAD_MOVE_MIN := 1.5
## Radius of the first (ring) layout.
const RING_RADIUS := 3.1
const MAX_PADS := 7
## A blob whose centre is within this flat distance of a pad centre (and not high above it)
## stands on it. The pad disc is 1.1 m across, a blob 0.8 m: at 0.7 a third of the blob is on it.
const ON_PAD_RADIUS := 0.7
const ON_PAD_MAX_Y := 0.8
## Players below this are out (nothing to fall off, but just in case).
const FALL_Y := -5.0

# --- Rules (host) ----------------------------------------------------------------------------
## Music length range (s) of the first round; later rounds are snappier: the max drops by
## MUSIC_MAX_SHRINK per round down to MUSIC_MAX_FLOOR (keeps 8 players inside the 90 s limit).
@export var music_range: Vector2 = Vector2(6.0, 12.0)
@export var music_max_shrink: float = 1.0
@export var music_max_floor: float = 8.0
## Seconds between the music stopping and the check.
@export var warn_time: float = 0.8
## Seconds from the check to the music resuming; the pads shuffle during its last part.
@export var pause_time: float = 2.0
@export var shuffle_time: float = 0.9
## Bots guess the music ends somewhere in this range (s after it started) and head for a pad.
@export var bot_guess_range: Vector2 = Vector2(4.0, 7.5)
## Bot brain hint (BotBrain reads it): calm while the music plays (no chasing, no shoving),
## a scramble once it stops. Set by the phase RPCs (only the host's bots read it).
var bot_aggression_scale: float = 0.0
## The hint per phase: music, warning.
const BOT_AGGRESSION_MUSIC := 0.0
const BOT_AGGRESSION_WARNING := 0.25

## Tuning applied to every player on every peer in _setup.
const SHOVE_COOLDOWN := 0.5

## Test/dev only: multiplies how fast the host's music, warning and pause clocks run.
var time_scale: float = 1.0
## Host randomness (music lengths, layouts, loser tie order). Tests may seed it.
var rng := RandomNumberGenerator.new()
## Host randomness for bot goals and guesses. Tests may seed it.
var bot_rng := RandomNumberGenerator.new()

## Every peer: the phase and the round (index of the current music, -1 before the first).
var phase: Phase = Phase.IDLE
var round_index: int = -1
## Every peer: where the pads are (the active ones; its size is the pad count).
var pad_positions: Array[Vector3] = []
## Every peer: slot owning each active pad (-1 = free), as last sent by the host.
var pad_owners: Array[int] = []
## Host: seconds (scaled) since the music started this round.
var music_elapsed: float = 0.0
## Host: real seconds of play since _start (for the time limit).
var elapsed: float = 0.0

# Host state.
var _clock: float = 0.0
var _music_len: float = 0.0
var _phase_left: float = 0.0
var _shuffled: bool = false
var _on_pad: Dictionary[int, int] = {}      # slot -> pad index it stands on (-1)
var _on_since: Dictionary[int, float] = {}  # slot -> _clock when it stepped on that pad
var _bot_guess: Dictionary[int, float] = {}
var _guess_told: Dictionary[int, bool] = {}
var _forced_music: float = -1.0

# Every peer: presentation.
var _anim_time: float = 0.0
var _phase_time: float = 0.0        # _anim_time when the current phase began
var _pads: Array[Node3D] = []
var _pad_models: Array[Node3D] = []
var _pad_rings: Array[StandardMaterial3D] = []
var _pad_spots: Array[SpotLight3D] = []
var _pad_cones: Array[MeshInstance3D] = []
var _cone_mats: Array[ShaderMaterial] = []
var _pad_state: Array[Dictionary] = []   # {shown, target_shown, pos, next, sink_t}
var _lamps: Array[OmniLight3D] = []
var _lamp_energy: Array[float] = []
var _stage_spots: Array[SpotLight3D] = []
var _horn: Node3D = null
var _music: AudioStreamPlayer = null
var _music_tween: Tween = null
var _audible: bool = true
var _second_beep: bool = false

@onready var _camera: ArenaCamera = get_node_or_null(^"ArenaCamera") as ArenaCamera


func _ready() -> void:
	rng.randomize()
	bot_rng.randomize()
	_audible = DisplayServer.get_name() != "headless"
	_build_room()
	_build_pads()
	_music = AudioStreamPlayer.new()
	_music.name = "Music"
	_music.bus = &"Sfx" if AudioServer.get_bus_index(&"Sfx") >= 0 else &"Master"
	_music.volume_db = -7.0
	if ResourceLoader.exists(MUSIC_PATH):
		# A path-less copy, like Sfx: a cached stream still playing at quit logs an error.
		var s := load(MUSIC_PATH) as AudioStream
		_music.stream = s.duplicate() as AudioStream if s else null
	add_child(_music)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--chairs-time-scale="):
			time_scale = maxf(arg.trim_prefix("--chairs-time-scale=").to_float(), 0.01)
		elif arg.begins_with("--chairs-music="):
			_forced_music = arg.trim_prefix("--chairs-music=").to_float()


func _exit_tree() -> void:
	if _music:
		_music.stop()
		_music.stream = null


# --- Minigame flow ---------------------------------------------------------------------------

func _setup(setup_players: Array[Player]) -> void:
	for p in setup_players:
		var shove := p.get_component(&"shove") as ShoveComponent
		if shove:
			shove.cooldown = SHOVE_COOLDOWN
	# The first layout: a ring around the middle, the same on every peer, shown at once.
	_apply_layout(ring_layout(maxi(setup_players.size() - 1, 1)), true)


func _start() -> void:
	elapsed = 0.0
	if multiplayer.is_server() and not finished.is_connected(_on_finished):
		finished.connect(_on_finished)


func _host_tick(delta: float) -> void:
	if is_finished():
		return
	elapsed += delta
	var dt := delta * time_scale
	_clock += dt
	for p in players:
		if is_instance_valid(p) and p.alive and p.global_position.y < FALL_Y:
			knock_out(p, &"fell")
	if is_finished():
		return
	match phase:
		Phase.IDLE:
			_begin_music()
		Phase.MUSIC:
			music_elapsed += dt
			_track_pads()
			_tell_bots_their_guess()
			if music_elapsed >= _music_len:
				_rpc_stop.rpc(round_index)
				_phase_left = warn_time
				_rethink_unseated()
		Phase.WARNING:
			music_elapsed += dt
			_phase_left -= dt
			_track_pads()
			if _phase_left <= 0.0:
				_check()
		Phase.PAUSE:
			_phase_left -= dt
			if not _shuffled and _phase_left <= shuffle_time:
				_shuffle()
			if _phase_left <= 0.0:
				_begin_music()
	if is_finished():
		return
	# Time limit without a Session driving this round (tests, sandbox). Under Session its
	# backstop finishes the round a moment later and ranks the survivors equally.
	if time_limit > 0.0 and elapsed >= time_limit and not _session_drives():
		var ranking := _alive_slots()
		for i in range(knocked_out.size() - 1, -1, -1):
			if not ranking.has(knocked_out[i]):
				ranking.append(knocked_out[i])
		finish(ranking)


# --- Host: rounds ------------------------------------------------------------------------------

func _begin_music() -> void:
	var next := round_index + 1
	var hi := maxf(music_range.y - music_max_shrink * next, maxf(music_max_floor, music_range.x))
	_music_len = rng.randf_range(music_range.x, hi)
	if _forced_music > 0.0:
		_music_len = _forced_music
		_forced_music = -1.0
	_bot_guess.clear()
	_guess_told.clear()
	for p in _alive():
		_bot_guess[p.slot] = bot_rng.randf_range(bot_guess_range.x, bot_guess_range.y)
	_on_pad.clear()
	_on_since.clear()
	_rpc_music.rpc(next)


## Host, tests: the music stops at the next tick.
func stop_music_now() -> void:
	if phase == Phase.MUSIC:
		_music_len = music_elapsed


## Host: seconds (scaled) the current music plays in total (tests; never sent to clients).
func music_length() -> float:
	return _music_len


## Host: who stands on which pad, and the resulting owners (the earliest arrival per pad).
func _track_pads() -> void:
	for p in players:
		if not is_instance_valid(p):
			continue
		var idx := pad_under(p.global_position) if p.alive else -1
		if idx != _on_pad.get(p.slot, -1):
			_on_pad[p.slot] = idx
			_on_since[p.slot] = _clock
	var owners := compute_owners()
	if owners != pad_owners:
		_rpc_owners.rpc(owners)
		if phase == Phase.WARNING:
			_rethink_unseated()


## Host: owner per active pad from the current standings (-1 = nobody on it).
func compute_owners() -> Array[int]:
	var owners: Array[int] = []
	var best_t: Array[float] = []
	var best_d: Array[float] = []
	for i in pad_positions.size():
		owners.append(-1)
		best_t.append(INF)
		best_d.append(INF)
	for p in players:
		if not is_instance_valid(p) or not p.alive:
			continue
		var idx: int = _on_pad.get(p.slot, -1)
		if idx < 0 or idx >= pad_positions.size():
			continue
		var t: float = _on_since.get(p.slot, 0.0)
		var d := _flat_dist(p.global_position, pad_positions[idx])
		if t < best_t[idx] or (t == best_t[idx] and d < best_d[idx]):
			owners[idx] = p.slot
			best_t[idx] = t
			best_d[idx] = d
	return owners


func _check() -> void:
	_track_pads()
	var owners := compute_owners()
	var out: Array[Player] = []
	var any_safe := false
	for o in owners:
		if o >= 0:
			any_safe = true
	if any_safe:
		for p in _alive():
			if not owners.has(p.slot):
				out.append(p)
	# Farthest from any pad goes out first (ranks lowest); exact ties by a host coin flip.
	var dist: Dictionary[int, float] = {}
	var tie: Dictionary[int, float] = {}
	for p in out:
		dist[p.slot] = _nearest_pad_dist(p.global_position)
		tie[p.slot] = rng.randf()
	out.sort_custom(func(a: Player, b: Player) -> bool:
		if dist[a.slot] != dist[b.slot]:
			return dist[a.slot] > dist[b.slot]
		return tie[a.slot] < tie[b.slot])
	var out_slots: Array[int] = []
	for p in out:
		out_slots.append(p.slot)
	_phase_left = pause_time
	_shuffled = false
	_rpc_check.rpc(round_index, owners, out_slots)
	for p in out:
		knock_out(p, &"no_seat")


func _shuffle() -> void:
	_shuffled = true
	var count := _alive().size() - 1
	if count < 1:
		return
	_rpc_layout.rpc(round_index + 1, random_layout(count, pad_positions))
	request_bot_rethink()


## Host: bots without a pad re-plan (to the nearest free pad). Seated bots are left alone: a
## re-plan would re-roll their mood and could send them off their pad.
func _rethink_unseated() -> void:
	for p in _alive():
		if not pad_owners.has(p.slot):
			request_bot_rethink(p.slot)


## Host: once the music has run past a bot's personal guess, that bot re-plans (to a pad).
func _tell_bots_their_guess() -> void:
	for slot: int in _bot_guess:
		if not _guess_told.get(slot, false) and music_elapsed >= _bot_guess[slot]:
			_guess_told[slot] = true
			request_bot_rethink(slot)


# --- Layouts ---------------------------------------------------------------------------------------

## The first layout: `count` pads evenly on a ring around PAD_CENTER (one pad: the centre).
static func ring_layout(count: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if count <= 1:
		out.append(PAD_CENTER)
		return out
	var r := RING_RADIUS if count > 2 else RING_RADIUS * 0.8
	for i in count:
		# Offset by half a step so no pad sits straight in line with spawn 0 (+Z).
		var a := TAU * (i + 0.5) / count
		out.append(PAD_CENTER + Vector3(sin(a), 0.0, cos(a)) * r)
	return out


## Host: `count` pads at random in the pad area (smaller area for few pads), at least
## PAD_MIN_GAP apart and, when possible, PAD_MOVE_MIN away from every `old` position.
func random_layout(count: int, old: Array[Vector3] = []) -> Array[Vector3]:
	var k := clampf(float(count - 1) / 5.0, 0.0, 1.0)
	var half := PAD_HALF * lerpf(0.55, 1.0, k)
	var gap := PAD_MIN_GAP
	var avoid_old := true
	for attempt in 60:
		var out: Array[Vector3] = []
		var tries := 0
		while out.size() < count and tries < 400:
			tries += 1
			var p := PAD_CENTER + Vector3(rng.randf_range(-half.x, half.x), 0.0, rng.randf_range(-half.y, half.y))
			var ok := true
			for q in out:
				if _flat_dist(p, q) < gap:
					ok = false
					break
			if ok and avoid_old:
				for q in old:
					if _flat_dist(p, q) < PAD_MOVE_MIN:
						ok = false
						break
			if ok:
				out.append(p)
		if out.size() == count:
			return out
		# Crowded: relax the constraints a little and try again.
		if attempt % 10 == 9:
			if avoid_old:
				avoid_old = false
			else:
				gap *= 0.9
	return ring_layout(count)


## Index of the active pad under `pos` (flat distance <= ON_PAD_RADIUS, not high above), or -1.
func pad_under(pos: Vector3) -> int:
	if pos.y > ON_PAD_MAX_Y:
		return -1
	var best := -1
	var best_d := ON_PAD_RADIUS
	for i in pad_positions.size():
		var d := _flat_dist(pos, pad_positions[i])
		if d <= best_d:
			best_d = d
			best = i
	return best


func _nearest_pad_dist(pos: Vector3) -> float:
	var best := INF
	for q in pad_positions:
		best = minf(best, _flat_dist(pos, q))
	return best


# --- Bots ---------------------------------------------------------------------------------------

## Music playing and the bot's personal guess not yet reached: wander near a pad. Past the
## guess, during the warning: the nearest pad nobody else holds (its own pad if it has one;
## if every pad is held, the nearest one: go and shove). Paused: stay put.
func get_bot_goal(player: Player) -> Vector3:
	if player == null or not player.alive or pad_positions.is_empty():
		return super.get_bot_goal(player)
	match phase:
		Phase.WARNING:
			return _seat_goal(player)
		Phase.MUSIC:
			if music_elapsed >= _bot_guess.get(player.slot, INF):
				return _seat_goal(player)
			return _wander_goal()
	return player.global_position


## Inside the room. During the warning only the pads count as safe: a seated bot's safety
## filter keeps it on its pad, and a bot caught off a pad runs for the nearest one.
func is_safe(pos: Vector3) -> bool:
	if absf(pos.x) >= SAFE_HALF_X or pos.z <= SAFE_BACK_Z or pos.z >= SAFE_FRONT_Z:
		return false
	if phase == Phase.WARNING:
		return _nearest_pad_dist(pos) <= ON_PAD_RADIUS - 0.1
	return true


func _seat_goal(player: Player) -> Vector3:
	var mine := pad_owners.find(player.slot)
	if mine >= 0 and mine < pad_positions.size():
		return pad_positions[mine]
	var best := -1
	var best_d := INF
	var fallback := -1
	var fallback_d := INF
	for i in pad_positions.size():
		var d := _flat_dist(player.global_position, pad_positions[i])
		var own: int = pad_owners[i] if i < pad_owners.size() else -1
		if own < 0 and d < best_d:
			best_d = d
			best = i
		if d < fallback_d:
			fallback_d = d
			fallback = i
	return pad_positions[best if best >= 0 else fallback]


func _wander_goal() -> Vector3:
	var c := pad_positions[bot_rng.randi() % pad_positions.size()]
	var a := bot_rng.randf() * TAU
	var r := bot_rng.randf_range(1.4, 2.6)
	var p := c + Vector3(sin(a), 0.0, cos(a)) * r
	p.x = clampf(p.x, -SAFE_HALF_X + 0.8, SAFE_HALF_X - 0.8)
	p.z = clampf(p.z, SAFE_BACK_Z + 1.6, SAFE_FRONT_Z - 0.8)
	return p


# --- RPCs (host -> every peer) -------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_music(index: int) -> void:
	round_index = index
	phase = Phase.MUSIC
	music_elapsed = 0.0
	bot_aggression_scale = BOT_AGGRESSION_MUSIC
	_phase_time = _anim_time
	_second_beep = false
	var none: Array[int] = []
	none.resize(pad_positions.size())
	none.fill(-1)
	pad_owners = none
	for p in players:
		if is_instance_valid(p) and p.alive:
			p.frozen = false
	_play_music()
	if index > 0:
		RoundUI.push_banner("Music!", 1.0)
	music_started.emit(index)


@rpc("authority", "call_local", "reliable")
func _rpc_stop(index: int) -> void:
	if phase != Phase.MUSIC:
		return
	phase = Phase.WARNING
	bot_aggression_scale = BOT_AGGRESSION_WARNING
	_phase_time = _anim_time
	_stop_music()
	Sfx.play(&"countdown_beep")
	RoundUI.push_banner("Grab a pad!", warn_time + 0.2)
	if _camera:
		_camera.add_shake(0.12)
	music_stopped.emit(index)


@rpc("authority", "call_local", "reliable")
func _rpc_owners(owners: Array) -> void:
	var typed: Array[int] = []
	for o: Variant in owners:
		typed.append(int(o))
	pad_owners = typed
	owners_changed.emit(owners)


@rpc("authority", "call_local", "reliable")
func _rpc_check(index: int, owners: Array, out_slots: Array) -> void:
	phase = Phase.PAUSE
	_phase_time = _anim_time
	_rpc_owners(owners)
	var stage := _stage()
	for p in players:
		if is_instance_valid(p):
			p.frozen = true
	var names: Array[String] = []
	for s: Variant in out_slots:
		var p: Player = stage.get_player(int(s)) if stage else null
		if p:
			names.append(_name_of(p))
	if out_slots.is_empty():
		RoundUI.push_banner("Nobody sat down! Again!", 1.6)
	elif names.size() == 1:
		RoundUI.push_banner("%s is out!" % names[0], 1.6)
	elif names.size() > 1:
		RoundUI.push_banner("%d out!" % names.size(), 1.6)
	if _camera and not out_slots.is_empty():
		_camera.add_shake(0.3)
	# Blobs on a pad cheer.
	for o: Variant in owners:
		var p: Player = stage.get_player(int(o)) if stage and int(o) >= 0 else null
		if p == null or not is_instance_valid(p) or not p.alive:
			continue
		var visuals := p.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"cheer")
	checked.emit(index, owners, out_slots)


@rpc("authority", "call_local", "reliable")
func _rpc_layout(index: int, positions: Array) -> void:
	var typed: Array[Vector3] = []
	for v: Variant in positions:
		typed.append(v as Vector3)
	_apply_layout(typed, false)
	layout_changed.emit(index, positions)


@rpc("authority", "call_local", "reliable")
func _rpc_celebrate(slots: Array) -> void:
	var stage := _stage()
	if stage == null:
		return
	for s: Variant in slots:
		var p := stage.get_player(int(s))
		if p == null or not is_instance_valid(p) or not p.alive:
			continue
		Fx.play(&"confetti", p.global_position + Vector3.UP * 1.2)
		var visuals := p.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"cheer", true)


# --- Internals ------------------------------------------------------------------------------------

func _on_finished(ranking: Array[int]) -> void:
	var winners: Array = []
	for s in _alive_slots():
		if ranking.has(s):
			winners.append(s)
	if not winners.is_empty():
		_rpc_celebrate.rpc(winners)


func _session_drives() -> bool:
	return Session.current_minigame == self and Session.state == Session.State.PLAYING


func _stage() -> Stage:
	return get_tree().get_first_node_in_group(&"stage") as Stage if is_inside_tree() else null


func _alive() -> Array[Player]:
	var out: Array[Player] = []
	for p in players:
		if is_instance_valid(p) and p.alive:
			out.append(p)
	return out


func _alive_slots() -> Array[int]:
	var out: Array[int] = []
	for p in _alive():
		out.append(p.slot)
	out.sort()
	return out


func _name_of(p: Player) -> String:
	return p.display_name if p.display_name != "" else "Player %d" % (p.slot + 1)


static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# --- Music -------------------------------------------------------------------------------------------

func _play_music() -> void:
	if _music_tween:
		_music_tween.kill()
	_music.pitch_scale = 1.0
	_music.volume_db = -30.0
	if _audible and _music.stream:
		_music.play(0.0)
	_music_tween = create_tween()
	_music_tween.tween_property(_music, ^"volume_db", -7.0, 0.15)


## Winds the music down like a gramophone losing its spring: pitch and volume sag, then stop.
func _stop_music() -> void:
	if _music_tween:
		_music_tween.kill()
	_music_tween = create_tween().set_parallel()
	_music_tween.tween_property(_music, ^"pitch_scale", 0.45, 0.4).set_ease(Tween.EASE_IN)
	_music_tween.tween_property(_music, ^"volume_db", -40.0, 0.4).set_ease(Tween.EASE_IN)
	_music_tween.chain().tween_callback(_music.stop)


# --- Pads (every peer) -----------------------------------------------------------------------------

func _build_pads() -> void:
	var root := Node3D.new()
	root.name = "Pads"
	add_child(root)
	for i in MAX_PADS:
		var pad := Node3D.new()
		pad.name = "Pad%d" % i
		pad.visible = false
		root.add_child(pad)
		var model := PAD_SCENE.instantiate() as Node3D
		model.name = "Model"
		pad.add_child(model)
		Look.apply_toon(model)
		var ring: StandardMaterial3D = null
		for mi_node in model.find_children("*", "MeshInstance3D", true, false):
			var mi := mi_node as MeshInstance3D
			for s in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(s) as StandardMaterial3D
				if mat and mat.resource_name == "EmitPadRing":
					ring = mat.duplicate() as StandardMaterial3D
					ring.emission_enabled = true
					mi.set_surface_override_material(s, ring)
		if ring == null:
			ring = StandardMaterial3D.new()
		_pad_rings.append(ring)
		_pad_models.append(model)
		# The light pool and the visible beam from above.
		var spot := SpotLight3D.new()
		spot.name = "Spot"
		spot.position = Vector3(0.0, 6.5, 0.0)
		spot.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		spot.spot_range = 8.0
		spot.spot_angle = 10.0
		spot.spot_angle_attenuation = 0.6
		spot.spot_attenuation = 0.4
		spot.light_energy = 6.0
		spot.shadow_enabled = false
		pad.add_child(spot)
		_pad_spots.append(spot)
		var cone := MeshInstance3D.new()
		cone.name = "Beam"
		var cm := CylinderMesh.new()
		cm.top_radius = 0.1
		cm.bottom_radius = 0.72
		cm.height = 6.2
		cm.radial_segments = 24
		cm.rings = 1
		cm.cap_top = false
		cm.cap_bottom = false
		cone.mesh = cm
		cone.position = Vector3(0.0, 3.1 + 0.02, 0.0)
		cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var sm := ShaderMaterial.new()
		sm.shader = CONE_SHADER
		cone.material_override = sm
		pad.add_child(cone)
		_pad_cones.append(cone)
		_cone_mats.append(sm)
		_pad_state.append({"shown": 0.0, "target": false, "pos": Vector3.ZERO, "next": Vector3.ZERO, "moving": false})
	_update_pad_visuals()


## Every peer: the pads go to `positions`. `instant`: no sink/rise animation.
func _apply_layout(positions: Array[Vector3], instant: bool) -> void:
	pad_positions = positions.duplicate()
	var none: Array[int] = []
	none.resize(pad_positions.size())
	none.fill(-1)
	pad_owners = none
	for i in MAX_PADS:
		var st := _pad_state[i]
		var want := i < positions.size()
		if want:
			st["next"] = positions[i]
		st["target"] = want
		if instant:
			st["shown"] = 1.0 if want else 0.0
			if want:
				st["pos"] = positions[i]
			st["moving"] = false
		else:
			# A pad that moves sinks first, then rises at its new spot.
			st["moving"] = want and float(st["shown"]) > 0.0 and (st["pos"] as Vector3) != positions[i]
			if want and float(st["shown"]) <= 0.0:
				st["pos"] = positions[i]
	_update_pad_visuals()


func _process(delta: float) -> void:
	_anim_time += delta
	var rate := delta / maxf(shuffle_time * 0.5 / maxf(time_scale, 0.01), 0.05)
	for i in MAX_PADS:
		var st := _pad_state[i]
		var shown: float = st["shown"]
		if st["moving"]:
			shown -= rate
			if shown <= 0.0:
				shown = 0.0
				st["pos"] = st["next"]
				st["moving"] = false
		elif st["target"]:
			shown = minf(shown + rate, 1.0)
		else:
			shown = maxf(shown - rate, 0.0)
		st["shown"] = shown
	if phase == Phase.WARNING and not _second_beep and _anim_time - _phase_time >= warn_time * 0.5:
		_second_beep = true
		Sfx.play(&"countdown_beep", Vector3.INF, 0.0, 1.26)
	_update_pad_visuals()
	_animate_room()


func _update_pad_visuals() -> void:
	var stage := _stage()
	var t := _anim_time - _phase_time
	var beat := 0.5 + 0.5 * cos(TAU * _anim_time * 3.0)  # 180 bpm pulse
	for i in MAX_PADS:
		var st := _pad_state[i]
		var shown: float = st["shown"]
		var pad := _pads_node(i)
		pad.visible = shown > 0.001
		if not pad.visible:
			continue
		var up := shown * shown * (3.0 - 2.0 * shown)
		pad.position = (st["pos"] as Vector3) + Vector3(0.0, lerpf(-0.35, 0.0, up), 0.0)
		var own: int = pad_owners[i] if i < pad_owners.size() and st["target"] else -1
		var color := Color(1.0, 0.86, 0.55)
		if own >= 0 and stage:
			var p := stage.get_player(own)
			if p:
				color = Look.parse_color(p.loadout.get("primary", ""), color)
		var energy := 1.6
		var beam := 1.0
		match phase:
			Phase.MUSIC:
				energy = 1.4 + 0.8 * beat
				beam = 0.75 + 0.25 * beat
			Phase.WARNING:
				var flick := 0.5 + 0.5 * signf(sin(t * TAU * 7.0))
				energy = lerpf(0.6, 3.2, flick)
				beam = lerpf(0.35, 1.3, flick)
			Phase.PAUSE:
				energy = 2.6 if own >= 0 else 0.8
				beam = 1.2 if own >= 0 else 0.4
		var ring := _pad_rings[i]
		ring.albedo_color = color
		ring.emission = color
		ring.emission_energy_multiplier = energy
		var light_color := color.lerp(Color(1.0, 0.95, 0.85), 0.55 if own < 0 else 0.25)
		_pad_spots[i].light_color = light_color
		_pad_spots[i].light_energy = 6.0 * beam * up
		_cone_mats[i].set_shader_parameter(&"color", light_color)
		_cone_mats[i].set_shader_parameter(&"strength", 0.4 * beam * up)


func _pads_node(i: int) -> Node3D:
	if _pads.size() != MAX_PADS:
		_pads.clear()
		var root := get_node(^"Pads")
		for k in MAX_PADS:
			_pads.append(root.get_child(k) as Node3D)
	return _pads[i]


# --- Room (every peer, built in code; identical everywhere) -----------------------------------------

func _build_room() -> void:
	var room := Node3D.new()
	room.name = "Room"
	add_child(room)
	var body := StaticBody3D.new()
	body.name = "RoomBody"
	body.collision_mask = 0
	room.add_child(body)
	# Floor: 5 x 4 parquet tiles cover x -10..10, z -8..8.
	for ix in 5:
		for iz in 4:
			_place(room, "floor_tile_4x4", Vector3(-8.0 + 4.0 * ix, 0.0, -6.0 + 4.0 * iz), 0.0)
	_box(body, Vector3(0.0, -0.25, 0.0), Vector3(2.0 * HALF_X + 0.6, 0.5, FRONT_Z - BACK_Z + 0.6))
	# A dark surround beyond the open front so the camera never sees under the room.
	var surround := MeshInstance3D.new()
	surround.name = "Surround"
	var plane := PlaneMesh.new()
	plane.size = Vector2(90.0, 90.0)
	surround.mesh = plane
	surround.material_override = Look.toon_material(Color("#1b1424"), 0.9, false)
	surround.position = Vector3(0.0, -0.2, 0.0)
	room.add_child(surround)

	# Walls: back and both sides; the front is open (a low plinth, an invisible barrier).
	var back: Array[String] = ["wall_window", "wall_4m", "wall_4m", "wall_4m", "wall_window"]
	for i in back.size():
		_place(room, back[i], Vector3(-8.0 + 4.0 * i, 0.0, BACK_Z), 0.0)
	var side: Array[String] = ["wall_4m", "wall_window", "wall_4m", "wall_window"]
	for i in side.size():
		var z := -6.0 + 4.0 * i
		_place(room, side[i], Vector3(-HALF_X, 0.0, z), 90.0)
		_place(room, side[3 - i], Vector3(HALF_X, 0.0, z), -90.0)
	for sx: float in [-1.0, 1.0]:
		_place(room, "wall_corner", Vector3(sx * HALF_X, 0.0, BACK_Z), 0.0)
		_place(room, "wall_corner", Vector3(sx * HALF_X, 0.0, FRONT_Z), 0.0)
	var plinth := MeshInstance3D.new()
	plinth.name = "FrontPlinth"
	var pm := BoxMesh.new()
	pm.size = Vector3(2.0 * HALF_X, 0.3, 0.3)
	plinth.mesh = pm
	plinth.material_override = Look.toon_material(Color("#5b3a29"), 0.7)
	plinth.position = Vector3(0.0, 0.15, FRONT_Z)
	room.add_child(plinth)
	var trim := MeshInstance3D.new()
	trim.name = "FrontTrim"
	var tm := BoxMesh.new()
	tm.size = Vector3(2.0 * HALF_X, 0.04, 0.34)
	trim.mesh = tm
	trim.material_override = Look.toon_material(Look.GOLD, 0.35)
	trim.position = Vector3(0.0, 0.3, FRONT_Z)
	room.add_child(trim)
	var wall_h := 3.0
	var depth := FRONT_Z - BACK_Z
	_box(body, Vector3(0.0, wall_h * 0.5, BACK_Z), Vector3(2.0 * HALF_X + 0.6, wall_h, 0.3))
	_box(body, Vector3(0.0, wall_h * 0.5, FRONT_Z), Vector3(2.0 * HALF_X + 0.6, wall_h, 0.3))
	for sx: float in [-1.0, 1.0]:
		_box(body, Vector3(sx * HALF_X, wall_h * 0.5, 0.0), Vector3(0.3, wall_h, depth + 0.6))

	# The band stage with its curtain, a gramophone playing the tune, candelabras either side.
	var stage := STAGE_SCENE.instantiate() as Node3D
	stage.name = "BandStage"
	stage.position = STAGE_POS
	room.add_child(stage)
	Look.apply_toon(stage)
	_box(body, STAGE_POS + Vector3(0.0, STAGE_SIZE.y * 0.5, 0.0), STAGE_SIZE)
	var gram := GRAMOPHONE_SCENE.instantiate() as Node3D
	gram.name = "Gramophone"
	gram.position = STAGE_POS + Vector3(-1.9, STAGE_SIZE.y, 0.1)
	gram.rotation_degrees.y = 18.0
	gram.scale = Vector3.ONE * 1.25
	room.add_child(gram)
	Look.apply_toon(gram)
	_horn = gram
	for sx: float in [-1.0, 1.0]:
		_place(room, "candelabra", STAGE_POS + Vector3(sx * 3.0, STAGE_SIZE.y, 0.2), 0.0)
	var piano := _place(room, "piano", STAGE_POS + Vector3(1.7, STAGE_SIZE.y, -0.1), -15.0)
	piano.scale = Vector3.ONE * 0.8

	# Pillars and plants along the side walls (colliders: 1 m boxes).
	for sx: float in [-1.0, 1.0]:
		for z: float in [-4.0, 3.0]:
			_place(room, "pillar", Vector3(sx * (HALF_X - 0.75), 0.0, z), 0.0)
			_box(body, Vector3(sx * (HALF_X - 0.75), 1.5, z), Vector3(1.0, 3.0, 1.0))
		_place(room, "potted_plant", Vector3(sx * (HALF_X - 0.8), 0.0, BACK_Z + 0.9), 0.0)
		_box(body, Vector3(sx * (HALF_X - 0.8), 0.6, BACK_Z + 0.9), Vector3(0.9, 1.2, 0.9))
	for z: float in [-0.5, 5.5]:
		_place(room, "portrait_frame_a" if z < 0.0 else "portrait_frame_c", Vector3(-HALF_X + 0.17, 2.4, z), 90.0)
		_place(room, "portrait_frame_b", Vector3(HALF_X - 0.17, 2.4, z), -90.0)

	# Warm light: chandeliers over the back half (out of the camera's way), stage washes.
	var lights := Node3D.new()
	lights.name = "Lights"
	room.add_child(lights)
	# The middle lamp has no chandelier model: from the camera it would hide the floor.
	for pos: Vector3 in [Vector3(-5.5, 6.4, -3.5), Vector3(5.5, 6.4, -3.5), Vector3(0.0, 6.8, 1.0)]:
		if pos.x != 0.0:
			var ch := _place(room, "chandelier", pos, 0.0)
			for n: Node in ch.find_children("*", "GeometryInstance3D", true, false):
				(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.78, 0.5)
		lamp.light_energy = 2.4
		lamp.omni_range = 13.0
		lamp.omni_attenuation = 1.0
		lamp.position = pos + Vector3(0.0, -1.5, 0.0)
		lights.add_child(lamp)
		_lamps.append(lamp)
		_lamp_energy.append(lamp.light_energy)
	for sx: float in [-1.0, 1.0]:
		var s := SpotLight3D.new()
		s.light_color = Color(1.0, 0.55, 0.6)
		s.light_energy = 4.0
		s.spot_range = 9.0
		s.spot_angle = 32.0
		s.shadow_enabled = false
		lights.add_child(s)
		s.look_at_from_position(STAGE_POS + Vector3(sx * 2.5, 0.3, 3.5), STAGE_POS + Vector3(sx * 1.2, 2.2, 0.9), Vector3.UP)
		_stage_spots.append(s)


func _animate_room() -> void:
	var t := _anim_time - _phase_time
	var k := 1.0
	match phase:
		Phase.WARNING:
			# Flicker: a nervous stutter of the chandeliers.
			k = 0.35 + 0.65 * (0.5 + 0.5 * signf(sin(t * TAU * 9.0 + sin(t * 23.0) * 2.0)))
		Phase.PAUSE:
			k = 0.85
	for i in _lamps.size():
		_lamps[i].light_energy = _lamp_energy[i] * k
	if _horn:
		# The gramophone bobs to the beat while the music plays.
		var bob := 0.0
		if phase == Phase.MUSIC:
			bob = absf(sin(_anim_time * PI * 3.0))
		_horn.scale = Vector3(1.25, 1.25 * (1.0 + 0.05 * bob), 1.25)


func _place(parent: Node3D, piece: String, pos: Vector3, yaw_deg: float) -> Node3D:
	var scene := load(ENV_DIR + piece + ".glb") as PackedScene
	if scene == null:
		push_error("spotlight_chairs: missing kit piece %s" % piece)
		return Node3D.new()
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation_degrees.y = yaw_deg
	parent.add_child(n)
	Look.apply_toon(n)
	return n


func _box(body: StaticBody3D, center: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = center
	body.add_child(cs)
