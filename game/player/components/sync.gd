class_name SyncComponent
extends PlayerComponent
## Replicates player state and events to other peers. Owner: player sync.
## Transport: the Stage's SyncHub (game/net/sync/sync_hub.gd). Offline it does nothing.
##
## Authority: the hub sends `pack_state()` about 30 times a second (unreliable): position,
## velocity, facing, on-floor, control_locked / alive / frozen, a respawn count and a
## teleport count (bumped when the body jumps more than `teleport_distance` in one tick,
## e.g. place_at).
## Remote copies do not tick (Player skips them). This component moves them in its own
## _physics_process: samples are buffered and played back `interp_delay` seconds behind
## the sender's clock, interpolated (short extrapolation when late, snap on teleports and
## respawns). It writes `player.global_position`, `player.velocity`, `player.facing` and
## `player.control_locked`, and keeps `grounded`: read `is_grounded()` for animation on any
## peer (`is_on_floor()` means nothing on a remote copy). `alive` and `frozen` are not
## written from state: events (eliminated/respawned) and Session set them on every peer;
## the replicated copies are `remote_alive` / `remote_frozen`.
## Collisions: a remote copy is a kinematic obstacle. It stays a CharacterBody3D on the
## players layer (move_and_slide and shove queries of local authorities see it) but never
## moves itself; it is placed each tick, so it is never pushed and never pushes back.

## Seconds remote copies lag behind the sender (covers LAN jitter at 30 Hz).
@export var interp_delay: float = 0.1
## Seconds a remote copy may run ahead of its newest sample along its velocity.
@export var max_extrapolation: float = 0.15
## Authority: a move longer than this in one physics tick counts as a teleport (m).
@export var teleport_distance: float = 1.5

const BUFFER_MAX := 20

## On the floor. Authority: live `is_on_floor()`; remote: replicated.
var grounded: bool = true
## Remote copies: the authority's `alive` / `frozen` as last received.
var remote_alive: bool = true
var remote_frozen: bool = false

var _hub: SyncHub = null
## Respawns seen here (every peer counts the same ones: `respawned` is raised once per peer).
var _respawns: int = 0
## Authority: teleports detected.
var _teleports: int = 0
var _last_pos: Vector3 = Vector3.INF
# Remote side.
var _buf: Array[Dictionary] = []  # {t, pos, vel, facing, flags}, oldest first
var _last_seq: int = -1
var _seen_respawns: int = -1
var _seen_teleports: int = -1


func _ready() -> void:
	if player == null:
		return
	player.respawned.connect(_on_respawned)
	var n := player.get_parent()
	while n != null and not (n is Stage):
		n = n.get_parent()
	if n:
		_hub = (n as Stage).sync_hub


## On the floor, on every peer (use this for animation, not `is_on_floor()`).
func is_grounded() -> bool:
	if player and player.is_authority() and player.is_inside_tree():
		return player.is_on_floor()
	return grounded


## Called by Player.emit_event after the local emit. Delivers to every other peer, which
## calls `player.receive_event(event, args)` (that does not relay again).
func relay_event(event: StringName, args: Array) -> void:
	if _hub:
		_hub.send_event(player, event, args)


## Called by Player.apply_impulse on a peer that is not the authority. Delivers to the
## authority, which calls `player.apply_impulse(impulse, source)`.
func relay_impulse(impulse: Vector3, source: Player) -> void:
	if _hub:
		_hub.send_impulse(player, impulse, source)


func _physics_process(_delta: float) -> void:
	if player == null or not player.is_inside_tree():
		return
	if player.is_authority():
		var pos := player.global_position
		if _last_pos != Vector3.INF and pos.distance_to(_last_pos) > teleport_distance:
			_teleports += 1
		_last_pos = pos
		grounded = player.is_on_floor()
		return
	_play_back()


# --- Wire format ---------------------------------------------------------------------------

## Authority: `[slot, respawns, teleports, position, velocity, facing, flags]`.
func pack_state() -> Array:
	var flags := 0
	if player.is_on_floor():
		flags |= SyncHub.FLAG_ON_FLOOR
	if player.control_locked:
		flags |= SyncHub.FLAG_CONTROL_LOCKED
	if player.alive:
		flags |= SyncHub.FLAG_ALIVE
	if player.frozen:
		flags |= SyncHub.FLAG_FROZEN
	return [player.slot, _respawns, _teleports, player.global_position, player.velocity, player.facing, flags]


## Remote: one state sample stamped `t` (sender clock) from packet `seq`. False if dropped.
func receive_state(seq: int, t: float, e: Array) -> bool:
	if e.size() < 7 or typeof(e[1]) != TYPE_INT or typeof(e[2]) != TYPE_INT \
			or typeof(e[3]) != TYPE_VECTOR3 or typeof(e[4]) != TYPE_VECTOR3 \
			or typeof(e[5]) != TYPE_VECTOR3 or typeof(e[6]) != TYPE_INT:
		return false
	if seq <= _last_seq:
		return false  # late or duplicate
	var respawns: int = e[1]
	if respawns < _respawns:
		return false  # sent before a respawn this peer has already applied
	var pos: Vector3 = e[3]
	var vel: Vector3 = e[4]
	if not pos.is_finite() or not vel.is_finite():
		return false
	_last_seq = seq
	var sample := {"t": t, "pos": pos, "vel": vel, "facing": e[5], "flags": e[6]}
	var snap: bool = _buf.is_empty() or respawns != _seen_respawns or e[2] != _seen_teleports
	_seen_respawns = respawns
	_seen_teleports = e[2]
	if snap:
		_buf.clear()
		_buf.append(sample)
		_apply(pos, vel, sample["facing"], sample["flags"])
		return true
	_buf.append(sample)
	while _buf.size() > BUFFER_MAX:
		_buf.pop_front()
	return true


# --- Remote playback -------------------------------------------------------------------------

func _play_back() -> void:
	if _buf.is_empty() or _hub == null:
		return
	var now := _hub.sender_clock(player.get_multiplayer_authority())
	var newest: Dictionary = _buf.back()
	var rt: float = (now - interp_delay) if now != -INF else float(newest["t"])
	if rt >= float(newest["t"]):
		var ahead := minf(rt - float(newest["t"]), max_extrapolation)
		var vel: Vector3 = newest["vel"]
		_apply(newest["pos"] + vel * ahead, vel, newest["facing"], newest["flags"])
		return
	if rt <= float(_buf[0]["t"]):
		var first: Dictionary = _buf[0]
		_apply(first["pos"], first["vel"], first["facing"], first["flags"])
		return
	var i := 0
	while i < _buf.size() - 2 and float(_buf[i + 1]["t"]) <= rt:
		i += 1
	# Drop what is fully behind the playback point.
	for k in i:
		_buf.pop_front()
	var a: Dictionary = _buf[0]
	var b: Dictionary = _buf[1]
	var span: float = float(b["t"]) - float(a["t"])
	var w: float = clampf((rt - float(a["t"])) / span, 0.0, 1.0) if span > 0.0 else 1.0
	var facing: Vector3 = (a["facing"] as Vector3).lerp(b["facing"], w)
	_apply((a["pos"] as Vector3).lerp(b["pos"], w), (a["vel"] as Vector3).lerp(b["vel"], w),
			facing if facing.length_squared() > 0.01 else b["facing"], a["flags"] if w < 0.5 else b["flags"])


func _apply(pos: Vector3, vel: Vector3, facing: Vector3, flags: int) -> void:
	player.global_position = pos
	player.velocity = vel
	facing.y = 0.0
	if facing.length_squared() > 0.0001:
		player.facing = facing.normalized()
	grounded = (flags & SyncHub.FLAG_ON_FLOOR) != 0
	player.control_locked = (flags & SyncHub.FLAG_CONTROL_LOCKED) != 0
	remote_alive = (flags & SyncHub.FLAG_ALIVE) != 0
	remote_frozen = (flags & SyncHub.FLAG_FROZEN) != 0


func _on_respawned(_xform: Transform3D) -> void:
	_respawns += 1
	_buf.clear()  # remote: hold at the respawn point (Player.receive_event placed it) until fresh state
	_last_pos = Vector3.INF
