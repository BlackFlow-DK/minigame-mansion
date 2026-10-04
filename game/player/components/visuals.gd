class_name VisualsComponent
extends PlayerComponent
## Shows the player blob (`res://assets/models/character/blob.glb`) and animates it entirely
## in code, on every peer. Owner: character animator.
##
## It only READS replicated state (global position -> a velocity estimate, `facing`, `alive`,
## `slot`) and LISTENS to the player events (jumped, landed, shove_started, shove_hit, got_hit,
## stunned, eliminated, respawned, emote). It never writes gameplay state and ignores
## `intent`, so a remote copy animates exactly like the authority's.
##
## Nodes built under this component:
##   Pivot         yaw: the smoothed `facing`
##     Motion      lean, twist, bob, breathing, visual hops (feet are counter-planted against it)
##       <model>   the blob.glb root: squash-and-stretch only (volume-preserving, from the
##                 feet), identity at rest; face parts, sockets and hats follow it
## Layers, lowest first:
##   locomotion  steps tied to model-space distance (so footfalls match every body size),
##               opposite arm swing, lean into acceleration, bob; a push-off hop on run start;
##               a skid (back-lean, braced feet, dust) on a hard stop or reversal; banking with
##               arms out in turns; a panic flail for a while after a knock (or `set_panic`);
##               a backpedal when moving away from where it faces
##   air         take-off stretch, arms up while rising, a tuck at the apex, legs reaching down
##               on the way down, a spin on big knockbacks; landing squash (two-stage with a
##               wobble when heavy); a teeter with windmilling arms at a ledge edge
##   idle        breathing with a weight shift, a look-around (other blobs, the fastest thing
##               nearby, `set_interest_point`, now and then the camera) with the body turning
##               a little, fidgets on a per-slot personality timer (stretch, yawn, scratch, hat
##               adjust, foot tap, wrist look), nodding off with "zzz" after SLEEP_AFTER s in
##               the lobby
##   reactions   shove, hit (hit-stop), stun, pop-in; social: a duck when a shove whiffs past,
##               a gloat after landing one, a wince when a blob nearby is knocked out
##   overlays    carry poses and the throw, then fidget/social actions, then emotes
##               (player emotes, podium poses, minigame emotes); see BlobPose
## The face eases between BlobExpressions presets, blinks, and looks at what the body looks at.
##
## Hit feel (visual only, every peer): a landed shove (attacker) and a hit (victim) freeze the
## blob in its impact pose for HIT_STOP seconds while physics, sync and gameplay timers run on;
## the victim shivers and flashes white (material_overlay), then the model catches up with
## its body. The animation clock runs on FeelTime.scale (knockout slow-motion).
##
## Comfort and cost: `Settings.reduced_motion` halves the big amplitudes, drops the spins and
## spaces fidgets out; at LOW quality a blob further than LOD_DISTANCE from the camera skips
## fidgets, "zzz" and the face. NPC extras run a reduced set (no fidgets, sleep or teeter).
##
## Materials: this component never colours the blob. It gives the model the house toon look
## once when it instances it (`BlobToon.apply`: shared Look toon materials); the cosmetics
## component tints the player materials, attaches items under the sockets and re-applies the
## toon to what it changed. A flash goes through `material_overlay`.
##
## Public API (other systems):
##   get_model_root() -> Node3D           the blob.glb instance. Sockets HatSocket, FaceSocket,
##                                        NeckSocket, BackSocket and the PlayerPrimary /
##                                        PlayerSecondary materials live under it and stay put.
##   play_emote(name, loop := false) -> bool   EMOTES; false if unknown
##   stop_emote()
##   play_result_pose(place, total) -> StringName   podium/results pose by placement
##   set_carry_pose(kind) -> bool         &"overhead", &"front", &"none"
##   play_throw()                         a throw (ends the carry pose)
##   get_carry_point() -> Vector3         world point where a carried thing sits
##   set_interest_point(point, strength := 1.0)   something worth watching (fades in ~0.6 s)
##   set_panic(seconds)                   panic-run arms for a while (hazards)
##   set_look_target(target)              Node3D or world Vector3 to look at; null = glance around
##   set_expression(name, seconds := -1.0)     force a BlobExpressions preset; &"" releases it
##   get_reaction() / get_expression() / get_emote() / get_action() / get_carry_pose()

## Emote name -> seconds. Player emotes (EmoteComponent): wave, dance, taunt, cry. Podium
## poses (play_result_pose): victory, clap_nod, clap, sulk. Older minigame ones: cheer, sad.
const EMOTES: Dictionary = {
	&"cheer": 1.8, &"wave": 1.8, &"sad": 2.2, &"dance": 2.0, &"taunt": 1.8, &"cry": 2.4,
	&"victory": 2.4, &"clap_nod": 1.2, &"clap": 1.0, &"sulk": 3.0,
}
## Short overlay actions -> seconds: fidgets, social reactions, the throw.
const ACTIONS: Dictionary = {
	&"stretch": 2.2, &"yawn": 2.0, &"scratch": 1.6, &"hat": 1.4, &"tap": 1.8, &"wrist": 1.6,
	&"flinch": 0.6, &"wince": 0.8, &"gloat": 0.9, &"throw": 0.5,
}
const FIDGETS: Array[StringName] = [&"stretch", &"yawn", &"scratch", &"hat", &"tap", &"wrist"]
const CARRY_KINDS: Array[StringName] = [&"none", &"overhead", &"front"]
## Every visuals component is in this group (social reactions find their neighbours with it).
const GROUP := &"blob_visuals"

const SHOVE_TIME := 0.4
const HIT_TIME := 0.3
const LAND_TIME := 0.32
const RESPAWN_TIME := 0.6
const BLINK_TIME := 0.14
const SKID_TIME := 0.38
const SPIN_TIME := 0.7
## Seconds of stillness in the lobby before a blob nods off.
const SLEEP_AFTER := 20.0
## LOW quality: blobs further than this from the camera skip fidgets and the face (m).
const LOD_DISTANCE := 14.0
## Social reactions: a knockout within this distance makes a blob wince; a shove makes a blob
## in front of the shover within FLINCH_RANGE duck (m).
const SOCIAL_RANGE := 7.0
const FLINCH_RANGE := 2.8
## Horizontal deceleration that starts a skid (m/s^2, model space) and the minimum speed.
const SKID_DECEL := 20.0
const SKID_SPEED := 2.2
## A knockback impulse at least this strong spins the blob while it flies.
const BIG_HIT := 9.0
## Seconds the blob holds its impact pose on a hit (victim) / landed shove (attacker).
const HIT_STOP := 0.055
const HIT_STOP_ATTACKER := 0.045
## Metres the victim shivers during the hit-stop.
const HIT_SHIVER := 0.035
const FLASH_TIME := 0.08
## Palms forward, fingers up (left hand); the right hand uses the X-mirrored rotation.
const PALM_FORWARD_L := BlobPose.PALM_FORWARD_L
## The body as an ellipsoid (model space) and the hands' clearance from it (m).
const BODY_CENTRE_Y := 0.45
const BODY_RX := 0.41
const BODY_RY := 0.55
const HAND_CLEARANCE := 0.06
const FOOT_HALF_HEIGHT := 0.058
const FOOT_HALF_LENGTH := 0.1

## How fast the model turns to `facing` (1/s, exponential).
@export var turn_sharpness: float = 18.0
## Metres travelled per step at a walk (model space); grows with speed (see stride).
@export var base_step_length: float = 0.32
## Furthest a foot reaches forward/back from its rest spot while stepping (m).
@export var max_foot_reach: float = 0.19

var _pivot: Node3D
var _motion: Node3D
var _rig: BlobRig
var _rng := RandomNumberGenerator.new()
var _clock: float = 0.0

# Rest data, cached once ([left, right]).
var _hands: Array[Node3D] = [null, null]
var _feet: Array[Node3D] = [null, null]
var _hand_rest: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _foot_rest: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _palm: Array[Quaternion] = [Quaternion.IDENTITY, Quaternion.IDENTITY]
var _hat_rest: Vector3 = Vector3(0.0, 1.0, 0.0)
## The worn hat, measured (root space) when a pose needs it: top, brim height, brim radius.
var _hat_top: float = 1.0
var _hat_brim: float = 1.0
var _hat_radius: float = 0.0
var _hat_grip: Vector3 = Vector3(0.22, 1.02, 0.32)
var _pupil_rest: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])

# Personality (from the slot seed).
var _tempo: float = 1.0
var _sway_amount: float = 1.0
var _posture: float = 0.0
var _fidget_rate: float = 1.0
var _phase0: float = 0.0
var _fidget_bias: PackedFloat32Array = PackedFloat32Array([1, 1, 1, 1, 1, 1])
var _camera_glancer: float = 0.12

# Context and level of detail.
var _lite: bool = false  # NPC extra: reduced set
var _far: bool = false
var _calm: float = 1.0
var _lod_in: float = 0.0
var _cam_pos: Vector3 = Vector3.INF
var _settings: Node = null

# Motion estimated from the replicated position (works the same on every peer).
var _vel: Vector3 = Vector3.ZERO
var _accel: Vector3 = Vector3.ZERO
var _inst_accel: Vector3 = Vector3.ZERO  # unsmoothed (skid detection)
var _raw_speed: float = 0.0  # horizontal speed from the last tick's position change
var _last_pos: Vector3 = Vector3.ZERO
var _has_last: bool = false
var _grounded: bool = true
var _event_air: bool = false
var _size_k: float = 1.0

var _yaw: float = 0.0
var _step_phase: float = 0.0
var _step_weight: float = 0.0
var _step_dir: Vector3 = Vector3.MODEL_FRONT
var _air_weight: float = 0.0
var _emote_weight: float = 0.0

var _squash := AnimSpring.new(1.0, 330.0, 15.0)      # vertical stretch factor
var _dir_squash := AnimSpring.new(1.0, 260.0, 12.0)  # stretch factor along _dir_axis
var _dir_axis: Vector3 = Vector3.MODEL_FRONT         # unit, horizontal, model space
var _lean_x := AnimSpring.new(0.0, 170.0, 12.0)      # + tips the top forward (+Z)
var _lean_z := AnimSpring.new(0.0, 170.0, 12.0)      # + tips the top toward -X (the blob's right)
var _pop := AnimSpring.new(1.0, 240.0, 13.0)         # uniform scale (respawn pop-in)

# Seconds since each reaction started (large = inactive).
var _since_land: float = 99.0
var _land_strength: float = 0.0
var _land_stage2: bool = true
var _since_shove: float = 99.0
var _since_hit: float = 99.0
var _hit_dir: Vector3 = Vector3.ZERO  # model space
var _stun_left: float = 0.0
var _stun_total: float = 0.0
var _since_respawn: float = 99.0
var _dead: bool = false

# Locomotion extras.
var _prev_speed: float = 0.0
var _since_start: float = 99.0
var _since_skid: float = 99.0
var _skid_dir: Vector3 = Vector3.BACK  # model space, the direction it was sliding
var _skid_puffed: int = 0
var _heading: float = 0.0
var _turn_rate: float = 0.0
var _bank: float = 0.0  # + = turning toward the blob's left
var _panic_left: float = 0.0
var _panic_w: float = 0.0
var _bp_w: float = 0.0
var _edge: Vector3 = Vector3.ZERO  # model space, toward a ledge edge (zero = none)
var _edge_in: float = 0.0
var _teeter_w: float = 0.0
var _ray: PhysicsRayQueryParameters3D = null

# Air extras.
var _spin_t: float = 99.0
var _spin_sign: float = 1.0
var _spin_armed: float = 0.0
var _tuck_w: float = 0.0
var _reach_w: float = 0.0

# Idle life.
var _idle_time: float = 0.0
var _sleep_w: float = 0.0
var _zzz: Label3D = null
var _fidget_in: float = 5.0
var _twist: float = 0.0

# Overlay actions (fidgets, social, throw) and emotes.
var _act: StringName = &""
var _act_t: float = 0.0
var _act_len: float = 0.0
var _act_w: float = 0.0
var _act_pose := BlobPose.new()
var _emote_pose := BlobPose.new()
var _flinch_lean: Vector2 = Vector2.ZERO
var _gloat_in: float = -1.0

var _emote: StringName = &""
var _emote_time: float = 0.0
var _emote_loop: bool = false
var _emote_cancellable: bool = false
var _emote_move: float = 0.0
var _resume_emote: StringName = &""
var _tears: CPUParticles3D = null
static var _tear_mesh: SphereMesh = null

# Carry.
var _carry: StringName = &"none"
var _carry_shown: StringName = &"none"
var _carry_w: float = 0.0

# Face.
var _expression: StringName = BlobExpressions.NEUTRAL
var _forced_expression: StringName = &""
var _forced_left: float = -1.0
var _lid: float = 0.0
var _mouth: Vector2 = Vector2(0.95, 0.7)
var _cheek: float = 1.0
var _pupil_scale: float = 1.0
var _blink_in: float = 2.0
var _blink_t: float = -1.0
## Look target: a world point, or a node held weakly (a player that leaves must not dangle).
var _look_point: Variant = null
var _look_node: WeakRef = null
var _glance: Vector2 = Vector2.ZERO
var _glance_in: float = 0.5
var _pupil: Vector2 = Vector2.ZERO
var _nearest: WeakRef = null
var _fastest: WeakRef = null
var _nearest_in: float = 0.0
var _cam_look_left: float = 0.0
var _interest: Vector3 = Vector3.ZERO
var _interest_strength: float = 0.0
var _interest_age: float = 99.0
## World point the blob is looking at this frame (INF = none) and how much the body turns to it.
var _look_world: Vector3 = Vector3.INF
var _look_body: float = 0.0
var _reaction: StringName = &"idle"
# Last values written to the nodes: unchanged parts are not written again (every transform
# write notifies the node and its renderer instance).
var _w_lid: Vector2 = Vector2(-1.0, -1.0)
var _w_mouth: Vector2 = Vector2(-1.0, -1.0)
var _w_cheek: float = -1.0
var _w_pupils: Vector4 = Vector4(9.0, 9.0, 9.0, 9.0)
var _w_pupil_scale: float = -1.0
var _w_root: Basis = Basis.FLIP_X
var _w_yaw: float = INF

# Hit feel.
var _stop_left: float = 0.0
var _stop_shiver: float = 0.0
var _stop_hold: Vector3 = Vector3.ZERO
var _catch: Vector3 = Vector3.ZERO  # pivot offset easing back to zero after a hit-stop
var _flash_left: float = 0.0
var _flashed: Array[GeometryInstance3D] = []
static var _flash_material: StandardMaterial3D = null


func _ready() -> void:
	add_to_group(GROUP)
	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)
	_motion = Node3D.new()
	_motion.name = "Motion"
	_pivot.add_child(_motion)
	_rig = BlobRig.instantiate()
	if _rig == null:
		return
	_rig.root.name = "Blob"
	_motion.add_child(_rig.root)
	BlobToon.apply(_rig.root)
	_hands = [_rig.hand_l, _rig.hand_r]
	_feet = [_rig.foot_l, _rig.foot_r]
	_hand_rest = PackedVector3Array([_rig.rest_of(&"HandL"), _rig.rest_of(&"HandR")])
	_foot_rest = PackedVector3Array([_rig.rest_of(&"FootL"), _rig.rest_of(&"FootR")])
	_pupil_rest = PackedVector3Array([_rig.rest_of(&"PupilL"), _rig.rest_of(&"PupilR")])
	_palm = [BlobPose.palm(1.0), BlobPose.palm(-1.0)]
	var hat := _rig.root.get_node_or_null(^"HatSocket") as Node3D
	if hat:
		_hat_rest = hat.position
	_settings = get_node_or_null(^"/root/Settings")
	if player == null:
		return
	_lite = player.is_extra
	_rng.seed = hash(player.slot) + 7919
	_blink_in = _rng.randf_range(0.5, 3.0)
	_roll_personality()
	_snap_to_player()
	player.jumped.connect(_on_jumped)
	player.landed.connect(_on_landed)
	player.shove_started.connect(_on_shove_started)
	player.shove_hit.connect(_on_shove_hit)
	player.got_hit.connect(_on_got_hit)
	player.stunned.connect(_on_stunned)
	player.eliminated.connect(_on_eliminated)
	player.respawned.connect(_on_respawned)
	if player.has_signal(&"emote"):
		player.connect(&"emote", _on_emote)
	_dead = not player.alive


## Per-slot personality: breathing tempo, sway, posture, how fidgety, favourite fidgets.
func _roll_personality() -> void:
	var r := RandomNumberGenerator.new()
	r.seed = hash(player.slot) * 92821 + 3
	_tempo = r.randf_range(0.85, 1.2)
	_sway_amount = r.randf_range(0.5, 1.3)
	_posture = r.randf_range(-0.035, 0.045)
	_fidget_rate = r.randf_range(0.75, 1.35)
	_phase0 = r.randf() * TAU
	_camera_glancer = r.randf_range(0.05, 0.25)
	for i in _fidget_bias.size():
		_fidget_bias[i] = r.randf_range(0.4, 1.0)
	_fidget_bias[r.randi() % _fidget_bias.size()] += 2.0  # a favourite
	_fidget_in = r.randf_range(3.5, 8.0) * _fidget_rate


# --- Public API ------------------------------------------------------------------------

## The blob.glb instance. The cosmetics component tints its PlayerPrimary/PlayerSecondary
## materials and attaches items to its HatSocket/FaceSocket/NeckSocket/BackSocket children;
## both stay stable (the visuals never replace them).
## Its own transform is animated (squash-and-stretch), so attach under the sockets, not beside it.
func get_model_root() -> Node3D:
	return _rig.root if _rig else null


## Plays `emote` (see EMOTES) on top of whatever the blob is doing. `loop` keeps it going
## until stop_emote() or another emote. Returns false if unknown. Not cancelled by movement
## (player emotes from the `emote` event are).
func play_emote(emote: StringName, loop: bool = false) -> bool:
	if not EMOTES.has(emote):
		return false
	_start_emote(emote, loop, false)
	return true


func stop_emote() -> void:
	_emote = &""
	_emote_cancellable = false
	_resume_emote = &""
	_set_tears(false)


## The emote playing now, or &"".
func get_emote() -> StringName:
	return _emote


## Results/podium pose for finishing `place` (1-based) of `total`: 1st a cheering loop with
## jumps and spins (&"victory"), last (of 2+) a sulk (&"sulk"), 2nd/3rd clap and nod
## (&"clap_nod"), anyone else a polite clap (&"clap"). Loops until stop_emote() or another
## emote. `place` < 1 stops it. Returns the pose name (&"" when stopped). Local only: call it
## on every peer.
func play_result_pose(place: int, total: int) -> StringName:
	if place < 1:
		stop_emote()
		return &""
	var pose := &"clap"
	if place == 1:
		pose = &"victory"
	elif place == total and total >= 2:
		pose = &"sulk"
	elif place <= 3:
		pose = &"clap_nod"
	_start_emote(pose, true, false)
	return pose


## Holding pose for minigames: &"overhead" (both hands up, palms up), &"front" (hands in
## front of the belly), &"none". Stays until changed (or play_throw). False if unknown.
func set_carry_pose(kind: StringName) -> bool:
	if not CARRY_KINDS.has(kind):
		return false
	_carry = kind
	if kind != &"none":
		_carry_shown = kind
		_measure_hat()
	return true


func get_carry_pose() -> StringName:
	return _carry


## A throw: wind up overhead, fling forward, follow through (ACTIONS throw). Ends the carry pose.
func play_throw() -> void:
	_carry = &"none"
	_start_action(&"throw")


## World position where a carried thing sits for the current carry pose (above the head for
## overhead, in front of the belly otherwise), following the animation.
func get_carry_point() -> Vector3:
	if _rig == null or not _rig.root.is_inside_tree():
		return player.global_position + Vector3.UP if player else Vector3.ZERO
	var local := Vector3(0.0, _overhead_y() + 0.2, 0.04) if _carry_shown == &"overhead" else Vector3(0.0, 0.5, 0.6)
	return _rig.root.to_global(local)


## Something worth watching at world `point` (a flying crown, a ball). `strength` 0..1 beats
## the blob's own glances; feed it every frame or so, it fades out ~0.6 s after the last call.
func set_interest_point(point: Vector3, strength: float = 1.0) -> void:
	if not point.is_finite():
		return
	_interest = point
	_interest_strength = clampf(strength, 0.0, 1.0)
	_interest_age = 0.0


## Panic-run arms (and face) for `seconds` while running, e.g. near a hazard.
func set_panic(seconds: float) -> void:
	_panic_left = maxf(_panic_left, seconds)


## Where the eyes should look: a Node3D (followed), a world-space Vector3, or null to go
## back to glancing around / at the nearest other player.
func set_look_target(target: Variant) -> void:
	_look_point = null
	_look_node = null
	if target is Vector3:
		_look_point = target
	elif target is Node3D and is_instance_valid(target):
		_look_node = weakref(target)


## Forces the face preset `expression` (see BlobExpressions) for `seconds` (-1 = until
## released). &"" releases it. Returns false for an unknown preset.
func set_expression(expression: StringName, seconds: float = -1.0) -> bool:
	if expression == &"":
		_forced_expression = &""
		return true
	if not BlobExpressions.has(expression):
		return false
	_forced_expression = expression
	_forced_left = seconds
	return true


## The face preset showing now.
func get_expression() -> StringName:
	return _expression


## The overlay action playing now (a fidget, &"flinch", &"wince", &"gloat", &"throw") or &"".
func get_action() -> StringName:
	return _act


## Seconds of hit-stop left (0 = animating normally). Tests, debugging.
func get_hit_stop() -> float:
	return maxf(_stop_left, 0.0)


## The dominant animation layer now: &"eliminated", &"respawn", &"hit", &"stunned", &"shove",
## &"throw", &"land", &"air", &"emote", &"flinch", &"wince", &"gloat", &"skid", &"teeter",
## &"sleep", &"panic", &"backpedal", &"run", &"fidget" or &"idle".
func get_reaction() -> StringName:
	return _reaction


## Starts the fidget `fidget` now (tests, the showcase). False if unknown.
func play_fidget(fidget: StringName) -> bool:
	if not FIDGETS.has(fidget):
		return false
	_start_action(fidget)
	return true


## 0..1: how asleep the blob is (lobby idle).
func get_sleep() -> float:
	return _sleep_w


# --- Events ------------------------------------------------------------------------------

func _on_jumped() -> void:
	_event_air = true
	_wake()
	_cancel_player_emote()
	# Anticipation: a quick squash that springs straight into a take-off stretch.
	_squash.value = minf(_squash.value, 0.84)
	_squash.velocity = 9.0
	_lean_x.velocity -= 1.5


func _on_landed(impact_speed: float) -> void:
	_event_air = false
	_since_land = 0.0
	_land_strength = clampf(impact_speed / 13.0, 0.15, 1.0)
	_land_stage2 = _land_strength < 0.55
	_squash.value = minf(_squash.value, 1.0 - 0.42 * _land_strength)
	_squash.velocity = 0.0
	_lean_x.velocity += 2.0 * _land_strength
	if _spin_t < SPIN_TIME:
		_spin_t = maxf(_spin_t, SPIN_TIME * 0.75)  # finish the spin quickly on the ground


func _on_shove_started() -> void:
	_since_shove = 0.0
	_wake()
	_cancel_player_emote()
	_end_action_unless(&"throw")
	_lean_x.velocity += 7.5
	_dir_axis = Vector3.MODEL_FRONT
	_dir_squash.value = maxf(_dir_squash.value, 1.0)
	_dir_squash.velocity += 5.0
	if _pivot and _pivot.is_inside_tree():
		_tell_neighbours(&"shove", FLINCH_RANGE)


func _on_shove_hit(_victim_slot: int) -> void:
	_lean_x.velocity -= 2.5
	_squash.velocity -= 1.5
	_hit_stop(HIT_STOP_ATTACKER, 0.0)
	_gloat_in = SHOVE_TIME - 0.08


func _on_got_hit(impulse: Vector3, _source_slot: int) -> void:
	_since_hit = 0.0
	_wake()
	_cancel_player_emote()
	_end_action_unless(&"")
	_gloat_in = -1.0
	var local := Basis(Vector3.UP, -_yaw) * Vector3(impulse.x, 0.0, impulse.z)
	var strength := clampf(impulse.length() / 12.0, 0.35, 1.2)
	if local.length_squared() > 0.0001:
		_hit_dir = local.normalized()
		_dir_axis = _hit_dir
		# Squashed along the push, the top whips back against it.
		_dir_squash.snap(1.0 - 0.2 * strength)
		_lean_x.velocity -= _hit_dir.z * 7.0 * strength
		_lean_z.velocity += _hit_dir.x * 7.0 * strength
	# A splat: flattened, bulging sideways, before it springs back.
	_squash.snap(minf(_squash.value, 1.0 - 0.16 * strength))
	_panic_left = maxf(_panic_left, 2.0)
	if impulse.length() >= BIG_HIT:
		_spin_armed = 0.35
		_spin_sign = -1.0 if _hit_dir.x > 0.0 else 1.0
	_hit_stop(HIT_STOP, HIT_SHIVER)
	_flash(FLASH_TIME)


func _on_stunned(duration: float) -> void:
	_stun_left = maxf(_stun_left, duration + 0.05)
	_stun_total = maxf(_stun_total, _stun_left)
	_cancel_player_emote()


func _on_eliminated(_reason: StringName) -> void:
	if _pivot and _pivot.is_inside_tree():
		_tell_neighbours(&"knockout", SOCIAL_RANGE)
	_dead = true
	_stun_left = 0.0
	_emote = &""
	_emote_cancellable = false
	_resume_emote = &""
	_act = &""
	_carry = &"none"
	_set_tears(false)
	_show_zzz(false)
	_end_hit_stop()
	_clear_flash()
	_spawn_pop_ghost()


func _on_respawned(_xform: Transform3D) -> void:
	_dead = false
	_since_respawn = 0.0
	_since_land = 99.0
	_since_shove = 99.0
	_since_hit = 99.0
	_since_skid = 99.0
	_spin_t = 99.0
	_spin_armed = 0.0
	_stun_left = 0.0
	_panic_left = 0.0
	_event_air = false
	_act = &""
	_idle_time = 0.0
	_sleep_w = 0.0
	_squash.snap(1.0)
	_dir_squash.snap(1.0)
	_lean_x.snap(0.0)
	_lean_z.snap(0.0)
	_pop.snap(0.0)
	_pop.velocity = 2.0
	_end_hit_stop()
	_snap_to_player()


## A player emote (EmoteComponent, every peer): cancelled by movement, a jump, a shove or a
## knockback. A looping minigame emote (a winner's cheer) resumes after a one-shot ends.
func _on_emote(id: int) -> void:
	var emote_name := EmoteComponent.name_of(id)
	if emote_name == &"" or _dead:
		return
	var resume := _emote if (_emote != &"" and _emote_loop and not _emote_cancellable) else _resume_emote
	_start_emote(emote_name, emote_name == &"dance", true)
	_resume_emote = resume


func _start_emote(emote: StringName, loop: bool, cancellable: bool) -> void:
	_emote = emote
	_emote_time = 0.0
	_emote_loop = loop
	_emote_cancellable = cancellable
	_emote_move = 0.0
	_resume_emote = &""
	_wake()
	if _act != &"throw":
		_act = &""


func _cancel_player_emote() -> void:
	if _emote != &"" and _emote_cancellable:
		_emote = &""
		_emote_cancellable = false
		_resume_emote = &""
		_set_tears(false)


func _start_action(action: StringName) -> void:
	if action == &"hat" or action == &"throw":
		_measure_hat()
	_act = action
	_act_t = 0.0
	_act_len = ACTIONS[action]


## Ends the current overlay action (except `keep`), fading it out.
func _end_action_unless(keep: StringName) -> void:
	if _act != &"" and _act != keep:
		_act = &""


## Measures the worn hat (HatSocket/Cosmetic_hat meshes, in HatSocket space, so squash and
## body size cancel out): its top, brim height and radius, and where a hand grips the brim.
func _measure_hat() -> void:
	_hat_top = _hat_rest.y
	_hat_brim = _hat_rest.y
	_hat_radius = 0.0
	_hat_grip = _hat_rest + Vector3(0.22, 0.02, 0.32)
	var socket := _rig.root.get_node_or_null(^"HatSocket") as Node3D if _rig else null
	var hat := socket.get_node_or_null(^"Cosmetic_hat") as Node3D if socket else null
	if hat == null or not hat.is_inside_tree():
		return
	var inv := socket.global_transform.affine_inverse()
	var meshes: Array[Node] = hat.find_children("*", "MeshInstance3D", true, false)
	if hat is MeshInstance3D:
		meshes.append(hat)
	var box := AABB()
	var first := true
	for n in meshes:
		var mi := n as MeshInstance3D
		var b := (inv * mi.global_transform) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first:
		return
	_hat_top = _hat_rest.y + box.end.y
	_hat_brim = _hat_rest.y + box.position.y
	_hat_radius = maxf(maxf(-box.position.x, box.end.x), maxf(-box.position.z, box.end.z))
	var d := Vector3(0.55, 0.0, 0.83).normalized()
	_hat_grip = Vector3(0.0, _hat_brim + 0.03, 0.0) + d * (_hat_radius + 0.05)


## Height of the hands holding something overhead: above the head, beside a tall hat's top.
func _overhead_y() -> float:
	return maxf(1.16, minf(_hat_top - 0.05, 1.5))


func _wake() -> void:
	_idle_time = 0.0


## Social reactions: tells the blobs within `range_m` that this one shoved / was knocked out.
func _tell_neighbours(what: StringName, range_m: float) -> void:
	var here := _pivot.global_position
	var fwd := Vector3(sin(_yaw), 0.0, cos(_yaw))
	for n in get_tree().get_nodes_in_group(GROUP):
		var other := n as VisualsComponent
		if other == null or other == self or other._dead or other.player == null or not other.is_inside_tree():
			continue
		var d := other.player.global_position - here
		d.y = 0.0
		if d.length_squared() > range_m * range_m:
			continue
		other._on_neighbour(what, here, fwd)


func _on_neighbour(what: StringName, at: Vector3, their_facing: Vector3) -> void:
	if _since_hit < HIT_TIME or _stun_left > 0.0 or _act == &"throw":
		return
	var d := player.global_position - at
	d.y = 0.0
	match what:
		&"shove":
			# Only a blob in front of the shover ducks; one that actually gets hit reacts to
			# the hit instead (got_hit ends the duck).
			if d.length_squared() < 0.0001 or their_facing.dot(d.normalized()) < 0.35:
				return
			var away := Basis(Vector3.UP, -_yaw) * d.normalized()
			_flinch_lean = Vector2(away.z, -away.x) * 0.22
			_start_action(&"flinch")
		&"knockout":
			_start_action(&"wince")
			_panic_left = maxf(_panic_left, 1.2)


## The real blob is hidden the moment a player is eliminated (Player hides itself), so the
## shrink-pop plays on a copy of the model left behind in the world, which frees itself.
## A plain node-by-node copy (no re-instancing from blob.glb), so it keeps the tint, the toon
## materials and the worn items exactly as they are on the player.
func _spawn_pop_ghost() -> void:
	if _rig == null or not is_inside_tree() or player.get_parent() == null:
		return
	var ghost := _rig.root.duplicate(Node.DUPLICATE_SIGNALS | Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS) as Node3D
	player.get_parent().add_child(ghost)
	ghost.name = "%sPop" % player.name
	ghost.global_transform = _rig.root.global_transform
	for n in ghost.find_children("*", "CPUParticles3D", true, false):
		n.free()  # tears stay with the blob
	var s := ghost.scale
	var tw := ghost.create_tween()
	tw.tween_property(ghost, "scale", s * Vector3(1.3, 0.7, 1.3), 0.06).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(ghost, "scale", s * Vector3(0.8, 1.35, 0.8), 0.07).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(ghost, "scale", s * 0.01, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(ghost.queue_free)
	# Knockout slow-motion (FeelTime) re-times this tween while it runs.
	ghost.add_to_group(FeelTime.GROUP)
	ghost.set_meta(FeelTime.TWEEN_META, tw)
	FeelTime.retime(ghost)


## Hit-stop: hold the impact pose (and world position) for `seconds`, shivering `shiver` m.
func _hit_stop(seconds: float, shiver: float) -> void:
	if _dead or _rig == null or _pivot == null or not _pivot.is_inside_tree():
		return
	if _stop_left <= 0.0:
		_stop_hold = _pivot.global_position
	_stop_left = maxf(_stop_left, seconds)
	_stop_shiver = maxf(_stop_shiver, shiver)


func _end_hit_stop() -> void:
	_stop_left = 0.0
	_stop_shiver = 0.0
	_catch = Vector3.ZERO
	if _pivot:
		_pivot.position = Vector3.ZERO


## Holds the pivot during a hit-stop, then eases it back onto the body.
func _place_pivot(real_delta: float, frozen: bool) -> void:
	if frozen:
		var shiver := Vector3(sin(_stop_left * 190.0), 0.0, cos(_stop_left * 150.0)) * _stop_shiver
		_pivot.global_position = _stop_hold + shiver
		_catch = _pivot.position
		if _stop_left <= 0.0:
			_stop_shiver = 0.0
		return
	if _catch == Vector3.ZERO:
		return
	_catch = _catch.lerp(Vector3.ZERO, 1.0 - exp(-30.0 * real_delta))
	if _catch.length_squared() < 0.000004:
		_catch = Vector3.ZERO
	_pivot.position = _catch


## A white flash over the whole blob (and what it wears) for `seconds`, via material_overlay.
func _flash(seconds: float) -> void:
	if _dead or _rig == null:
		return
	if _flash_material == null:
		_flash_material = StandardMaterial3D.new()
		_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_flash_material.albedo_color = Color(1.0, 0.98, 0.94, 0.7)
	if _flash_left <= 0.0:
		_flashed.clear()
		for n in _rig.root.find_children("*", "GeometryInstance3D", true, false):
			var g := n as GeometryInstance3D
			if g.material_overlay == null and g is MeshInstance3D:
				g.material_overlay = _flash_material
				_flashed.append(g)
	_flash_left = maxf(_flash_left, seconds)


func _tick_flash(real_delta: float) -> void:
	if _flash_left <= 0.0:
		return
	_flash_left -= real_delta
	if _flash_left <= 0.0:
		_clear_flash()


func _clear_flash() -> void:
	_flash_left = 0.0
	for g in _flashed:
		if is_instance_valid(g) and g.material_overlay == _flash_material:
			g.material_overlay = null
	_flashed.clear()


# --- Per frame ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if player == null or not is_inside_tree() or delta <= 0.0:
		return
	var pos := player.global_position
	var raw := Vector3.ZERO
	if _has_last and pos.distance_to(_last_pos) < 2.0:  # a longer jump is a teleport
		raw = (pos - _last_pos) / delta
	_last_pos = pos
	_has_last = true
	_raw_speed = Vector2(raw.x, raw.z).length()
	var v := _vel.lerp(raw, 1.0 - exp(-30.0 * delta))
	_inst_accel = (v - _vel) / delta
	_accel = _accel.lerp(_inst_accel, 1.0 - exp(-14.0 * delta))
	_vel = v
	if player.is_authority():
		_grounded = player.is_on_floor()
	else:
		# Remote copies never run move_and_slide: airborne from `jumped` until `landed`, or
		# whenever the replicated position is clearly moving vertically (fell off a ledge).
		_grounded = not _event_air and absf(_vel.y) < 1.5
	_probe_edge(delta)


## Ledge check for the teeter, a few rays now and then while standing still: `_edge` points
## (model space) toward the side(s) with no floor.
func _probe_edge(delta: float) -> void:
	if _lite or _far or _dead or not _grounded or Vector2(_vel.x, _vel.z).length_squared() > 0.09:
		_edge = Vector3.ZERO
		_edge_in = 0.0
		return
	_edge_in -= delta
	if _edge_in > 0.0:
		return
	_edge_in = 0.25
	var world := player.get_world_3d()
	if world == null:
		return
	var space := world.direct_space_state
	if space == null:
		return
	if _ray == null:
		_ray = PhysicsRayQueryParameters3D.new()
		_ray.collision_mask = 1
	var pos := player.global_position
	var f := player.facing
	var r := Vector3(f.z, 0.0, -f.x)  # the blob's left
	var reach := 0.42 * _size_k
	var e := Vector3.ZERO
	var dirs: Array[Vector3] = [f, -f, r, -r]
	var local: Array[Vector3] = [Vector3.BACK, Vector3.FORWARD, Vector3.RIGHT, Vector3.LEFT]
	for i in 4:
		_ray.from = pos + dirs[i] * reach + Vector3.UP * 0.3
		_ray.to = pos + dirs[i] * reach + Vector3.DOWN * 0.45
		if space.intersect_ray(_ray).is_empty():
			e += local[i]
	_edge = e.normalized() if e.length_squared() > 0.01 else Vector3.ZERO


func _process(delta: float) -> void:
	if player == null or _rig == null:
		return
	var real := minf(delta, 0.1)
	_tick_flash(real)
	var frozen := _stop_left > 0.0
	if frozen:
		_stop_left -= real
	# Hit-stop: pose with zero time (holds the impact frame); otherwise the visual clock.
	delta = 0.0 if frozen else real * FeelTime.scale
	if not _dead:
		_place_pivot(real, frozen)
	_clock += delta
	_advance_timers(delta)
	if _dead:
		_reaction = &"eliminated"
		return
	_refresh_lod(real)

	# Facing.
	var f := player.facing
	if f.length_squared() > 0.0001:
		_yaw = lerp_angle(_yaw, atan2(f.x, f.z), 1.0 - exp(-turn_sharpness * delta))
	if _yaw != _w_yaw:
		_w_yaw = _yaw
		_pivot.transform = Transform3D(Basis(Vector3.UP, _yaw), _pivot.position)

	var to_local := Basis(Vector3.UP, -_yaw)
	var hv := Vector3(_vel.x, 0.0, _vel.z)
	# Model space (the size component scales this node): steps, bob and reach follow the body.
	_size_k = maxf(scale.x, 0.05)
	var v_loc := to_local * hv / _size_k
	var a_loc := to_local * Vector3(_accel.x, 0.0, _accel.z) / _size_k
	var speed := v_loc.length()
	var stunned := _stun_left > 0.0
	var e_stun := 0.0
	if stunned:
		e_stun = smoothstep(0.0, 0.1, _stun_total - _stun_left) * smoothstep(0.0, 0.25, _stun_left)
	_detect(delta, v_loc, a_loc, speed, stunned)

	# Weights of the big layers.
	var k10 := 1.0 - exp(-10.0 * delta)
	_air_weight = lerpf(_air_weight, 0.0 if _grounded else 1.0, 1.0 - exp(-16.0 * delta))
	var e_skid := _envelope(_since_skid, 0.04, 0.1, SKID_TIME - 0.14) if _grounded else 0.0
	var step_target := 0.0 if (not _grounded or stunned) else clampf(speed / 1.2, 0.0, 1.0) * (1.0 - e_skid)
	_step_weight = lerpf(_step_weight, step_target, k10)
	_emote_weight = lerpf(_emote_weight, 1.0 if _emote != &"" else 0.0, k10)
	_carry_w = lerpf(_carry_w, 1.0 if _carry != &"none" else 0.0, 1.0 - exp(-12.0 * delta))
	_act_w = _action_weight(delta)
	var w := _step_weight
	if speed > 0.3:
		_step_dir = _step_dir.slerp(v_loc.normalized(), 1.0 - exp(-12.0 * delta)).normalized()
	var e_shove := _envelope(_since_shove, 0.04, 0.12, SHOVE_TIME - 0.16)
	var e_hit := _envelope(_since_hit, 0.02, 0.1, HIT_TIME - 0.12)
	var e_land := _envelope(_since_land, 0.02, 0.04, LAND_TIME - 0.06) * _land_strength
	var rise := clampf(0.65 + _vel.y / 5.0, 0.0, 1.0)  # 1 rising, 0 falling
	var vy := _vel.y / _size_k
	_tuck_w = (1.0 - clampf(absf(vy) / 2.6, 0.0, 1.0)) * _air_weight
	_reach_w = clampf(-vy / 6.0, 0.0, 1.0) * _air_weight * (1.0 - _tuck_w)
	var idle_w := (1.0 - w) * (1.0 - _air_weight)
	_teeter_w = lerpf(_teeter_w, 1.0 if (_edge != Vector3.ZERO and speed < 0.4 and _grounded \
		and _emote == &"" and _act == &"" and _carry == &"none") else 0.0, 1.0 - exp(-6.0 * delta))

	# Overlay poses (rewritten in place).
	if _act != &"":
		_act_pose.fill(_act, _act_t, _act_len, _clock, _hand_rest[0], _hand_rest[1], _hat_grip)
		if _act == &"flinch":
			_act_pose.lean = _flinch_lean
	if _emote != &"":
		_emote_pose.fill(_emote, _emote_time, EMOTES[_emote], _clock, _hand_rest[0], _hand_rest[1], _hat_grip)
		if _emote_pose.tears != (_tears != null and _tears.emitting):
			_set_tears(_emote_pose.tears and not _far)

	# Step cycle: the phase advances with distance travelled (one step per stride).
	var stride := base_step_length + 0.075 * speed
	if _grounded and not stunned:
		_step_phase = fposmod(_step_phase + speed * delta * PI / stride, TAU)
	var reach := minf(stride * 0.5, max_foot_reach)
	var lift := minf(0.05 + 0.012 * speed, 0.12)
	var c0 := _foot_cycle(_step_phase, reach, lift)
	var c1 := _foot_cycle(_step_phase + PI, reach, lift)
	var s2 := sin(_step_phase) * sin(_step_phase)
	var calm := _calm

	# Body offsets from the overlays and the extras.
	var e_act := _act_w
	var e_em := _emote_weight
	var hop := _act_pose.hop * e_act + _emote_pose.hop * e_em * calm
	var start_hop := 0.045 * sin(PI * clampf(_since_start / 0.22, 0.0, 1.0)) * calm
	hop += start_hop
	var e_sleep := _sleep_w
	var nod := 0.0
	if e_sleep > 0.001:
		var n := fposmod(_clock / 3.6 + _phase0, 1.0)
		nod = smoothstep(0.0, 0.8, n) if n < 0.85 else 1.0 - smoothstep(0.85, 0.93, n)
	var shift := sin(_clock * TAU / (5.0 * _tempo) + _phase0) * idle_w * _sway_amount * calm

	# Lean: into acceleration, forward with speed, banking, skids, sway over the stance foot,
	# stun wobble, then the overlays.
	var lean_target := Vector2(
		clampf(v_loc.z * 0.034 + a_loc.z * 0.0045, -0.26, 0.34),
		clampf(-a_loc.x * 0.0045, -0.3, 0.3) - _bank * calm)
	lean_target.y = clampf(lean_target.y, -0.4, 0.4)
	if not _grounded:
		lean_target *= 0.4
	lean_target.x += _posture * idle_w + 0.24 * nod * e_sleep
	lean_target.y += 0.025 * shift
	if e_skid > 0.001:
		lean_target = lean_target.lerp(Vector2(-_skid_dir.z, _skid_dir.x) * 0.36 * calm, e_skid)
	if _bp_w > 0.001:
		lean_target.x = lerpf(lean_target.x, -0.12, _bp_w)
	if _teeter_w > 0.001:
		var wob := (0.13 + 0.1 * sin(_clock * 7.0)) * calm
		lean_target = lean_target.lerp(Vector2(_edge.z, -_edge.x) * wob, _teeter_w)
	if e_act > 0.001:
		lean_target = lean_target.lerp(_act_pose.lean * calm, e_act * _act_pose.lean_w)
	if e_em > 0.001:
		lean_target = lean_target.lerp(_emote_pose.lean * calm, e_em * _emote_pose.lean_w)
	_lean_x.step(lean_target.x, delta)
	_lean_z.step(lean_target.y, delta)
	var wobble := Vector2(sin(_clock * 9.0), cos(_clock * 9.0)) * 0.14 * e_stun
	var sway := -0.05 * w * sin(_step_phase)

	# Vertical squash-and-stretch target.
	var sq_target := 1.0 + 0.035 * w * (s2 - 0.5)
	if not _grounded:
		sq_target += clampf(vy * 0.022, -0.06, 0.12) - 0.04 * _tuck_w
	sq_target -= 0.05 * e_stun + 0.03 * e_sleep
	sq_target += (_act_pose.squash * e_act + _emote_pose.squash * e_em) * calm
	_squash.step(sq_target, delta)
	_dir_squash.step(1.0, delta)
	_pop.step(1.0, delta)

	# Twist toward what it looks at, plus overlay twists and the spins.
	var twist_target := 0.0
	if _look_world != Vector3.INF and _look_body > 0.001:
		var lp := to_local * (_look_world - player.global_position)
		twist_target = clampf(atan2(lp.x, lp.z), -0.6, 0.6) * _look_body
	twist_target = lerpf(twist_target, _act_pose.twist, e_act)
	twist_target = lerpf(twist_target, _emote_pose.twist, e_em)
	_twist = lerpf(_twist, twist_target * calm, 1.0 - exp(-6.0 * delta))
	var spin := _emote_pose.spin * e_em if calm >= 1.0 else 0.0
	if _spin_t < SPIN_TIME:
		var su := _spin_t / SPIN_TIME
		spin += _spin_sign * TAU * (1.0 - pow(1.0 - su, 3.0))

	# Motion node: bob, hop, sway, lunge, lean, twist, breathing.
	var breath := 1.0 + 0.016 * sin(_clock * TAU / (2.8 * _tempo) + _phase0) * (1.0 - w)
	var bob := (0.02 + 0.006 * speed) * w * s2
	var sway_x := 0.016 * shift + (_act_pose.sway * e_act + _emote_pose.sway * e_em) * calm
	var mrot := Vector3(_lean_x.value + wobble.x, _twist + spin, _lean_z.value + sway + wobble.y)
	var inv_b := 1.0 / sqrt(breath)
	var motion_xf := Transform3D(Basis.from_euler(mrot) * Basis.from_scale(Vector3(inv_b, breath, inv_b)),
		Vector3(sway_x, bob + hop, 0.07 * e_shove))
	_motion.transform = motion_xf

	# Model root: squash-and-stretch only, volume preserving, from the feet.
	var root_basis := _squash_basis(clampf(_squash.value, 0.45, 1.7), clampf(_dir_squash.value, 0.5, 1.6))
	root_basis = root_basis.scaled(Vector3.ONE * maxf(_pop.value, 0.01))
	if root_basis != _w_root:
		_w_root = root_basis
		_rig.root.transform = Transform3D(root_basis, Vector3.ZERO)

	_pose_hands(c0.x, c1.x, reach, rise, e_shove, e_hit, e_land, e_stun, e_skid, idle_w)
	_pose_feet(c0, c1, rise, e_land, e_stun, e_skid, hop, shift, motion_xf, mrot, root_basis)
	_update_zzz(e_sleep, nod)
	if _far:
		_look_body = 0.0
	else:
		_pose_face(real * FeelTime.scale if frozen else delta, e_stun, v_loc, e_skid, nod)
	_reaction = _pick_reaction(e_stun > 0.0 or stunned, speed, e_skid)


## Every half second: camera distance (LOW-quality LOD) and the reduced-motion flag.
func _refresh_lod(real_delta: float) -> void:
	_lod_in -= real_delta
	if _lod_in > 0.0:
		return
	_lod_in = 0.5
	_calm = 0.5 if (_settings and bool(_settings.get(&"reduced_motion"))) else 1.0
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	_cam_pos = cam.global_position if cam else Vector3.INF
	_far = Look.get_quality() == Look.Quality.LOW and cam != null \
		and _cam_pos.distance_to(player.global_position) > LOD_DISTANCE


## Run starts, skids, banking, panic, backpedal, idle time, sleep, fidgets, spins, emote
## cancelling: everything that reads the motion and starts or ends something.
func _detect(delta: float, v_loc: Vector3, a_loc: Vector3, speed: float, stunned: bool) -> void:
	var k := 1.0 - exp(-8.0 * delta)
	# Run start: a push-off hop and a forward kick when it sets off from standing.
	if _grounded and speed > 0.9 and _prev_speed <= 0.9 and _step_weight < 0.35 and _since_start > 0.4:
		_since_start = 0.0
		var dir := v_loc.normalized()
		_lean_x.velocity += dir.z * 3.0 * _calm
		_lean_z.velocity -= dir.x * 3.0 * _calm
		_squash.velocity -= 1.2 * _calm
	_prev_speed = speed
	# Skid: a hard brake or reversal while running fast.
	if _grounded and speed > SKID_SPEED and _since_skid > 0.45 and not stunned:
		var a_now := Basis(Vector3.UP, -_yaw) * Vector3(_inst_accel.x, 0.0, _inst_accel.z) / _size_k
		var decel := -a_now.dot(v_loc / speed)
		if decel > SKID_DECEL:
			_since_skid = 0.0
			_skid_dir = v_loc / speed
			_skid_puffed = 0
			_lean_x.velocity -= _skid_dir.z * 4.0 * _calm
			_lean_z.velocity += _skid_dir.x * 4.0 * _calm
	if _since_skid < SKID_TIME and _skid_puffed < 2 and _since_skid >= 0.12 * _skid_puffed:
		_skid_puffed += 1
		_skid_dust()
	# Banking: how fast the heading turns, times the speed.
	var bank_target := 0.0
	if speed > 1.5 and _grounded:
		var heading := atan2(_vel.x, _vel.z)
		if delta > 0.0:
			var rate := angle_difference(_heading, heading) / delta
			_turn_rate = lerpf(_turn_rate, clampf(rate, -12.0, 12.0), 1.0 - exp(-10.0 * delta))
		_heading = heading
		bank_target = clampf(_turn_rate * speed * 0.011, -0.32, 0.32)
	else:
		_turn_rate = 0.0
		_heading = atan2(_vel.x, _vel.z)
	_bank = lerpf(_bank, bank_target, k)
	# Panic run, backpedal.
	_panic_w = lerpf(_panic_w, (1.0 if _panic_left > 0.0 else 0.0) * _step_weight, k)
	var bp := 0.0
	if speed > 0.8 and _grounded:
		bp = clampf((-v_loc.z / speed - 0.3) / 0.5, 0.0, 1.0)
	_bp_w = lerpf(_bp_w, bp, k)
	# Knockback spin, once airborne.
	if _spin_armed > 0.0:
		_spin_armed -= delta
		if not _grounded and _calm >= 1.0:
			_spin_armed = 0.0
			_spin_t = 0.0
	# Heavy landing, second stage: a smaller squash after the rebound, and a wobble.
	if not _land_stage2 and _since_land > 0.13:
		_land_stage2 = true
		_squash.velocity -= 3.5 * _land_strength
		_lean_z.velocity += 4.0 * _land_strength * (1.0 if _rng.randf() < 0.5 else -1.0)
		_lean_x.velocity -= 2.0 * _land_strength
	# Gloat after landing a shove.
	if _gloat_in >= 0.0:
		_gloat_in -= delta
		if _gloat_in < 0.0 and _since_hit > 0.5 and _emote == &"":
			_start_action(&"gloat")
	# Emotes from the emote key end when the blob moves off.
	if _emote_cancellable and _emote != &"":
		_emote_move = _emote_move + delta if speed > 1.2 else 0.0
		if _emote_move > 0.12:
			_cancel_player_emote()
	# Fidgets fade out as soon as it moves.
	if _act != &"" and FIDGETS.has(_act) and (speed > 0.5 or not _grounded):
		_act_t = maxf(_act_t, _act_len - 0.2)
	# Idle time, sleep, fidgets.
	var still := speed < 0.25 and _grounded and not stunned and _emote == &"" and _carry == &"none" \
		and _since_hit > 1.0 and _since_shove > 1.0 and _since_land > 0.5
	_idle_time = _idle_time + delta if still else 0.0
	var sleepy := not _lite and _idle_time > SLEEP_AFTER and (_sleep_w > 0.01 or _in_lobby())
	_sleep_w = lerpf(_sleep_w, 1.0 if sleepy else 0.0, 1.0 - exp(-(0.8 if sleepy else 8.0) * delta))
	if sleepy and _act != &"" and FIDGETS.has(_act):
		_act = &""
	if still and not _lite and not _far and _act == &"" and not sleepy and _idle_time > 2.0:
		_fidget_in -= delta
		if _fidget_in <= 0.0:
			_fidget_in = _rng.randf_range(5.0, 11.0) * _fidget_rate * (2.5 if _calm < 1.0 else 1.0)
			_start_action(_pick_fidget())


func _pick_fidget() -> StringName:
	var has_hat := _rig.root.get_node_or_null(^"HatSocket/Cosmetic_hat") != null
	var total := 0.0
	for i in FIDGETS.size():
		if FIDGETS[i] != &"hat" or has_hat:
			total += _fidget_bias[i]
	var roll := _rng.randf() * total
	for i in FIDGETS.size():
		if FIDGETS[i] == &"hat" and not has_hat:
			continue
		roll -= _fidget_bias[i]
		if roll <= 0.0:
			return FIDGETS[i]
	return &"stretch"


func _in_lobby() -> bool:
	return EmoteComponent.is_lobby(player)


## Dust under the feet when a skid starts (and once more a moment later), while the body
## really still slides (not when it was stopped dead, e.g. teleported or pinned).
func _skid_dust() -> void:
	if not is_inside_tree() or _raw_speed < 1.5 * _size_k:
		return
	var back := Basis(Vector3.UP, _yaw) * _skid_dir
	Fx.play(&"dust_puff", player.global_position + back * 0.18 * _size_k + Vector3.UP * 0.03, Color.WHITE)


## 0..1 weight of the overlay action: eases in and out over its length.
func _action_weight(delta: float) -> float:
	if _act == &"":
		return lerpf(_act_w, 0.0, 1.0 - exp(-14.0 * delta))
	var fade_in := 0.05 if (_act == &"flinch" or _act == &"throw") else 0.2
	return smoothstep(0.0, fade_in, _act_t) * (1.0 - smoothstep(_act_len - 0.22, _act_len, _act_t))


func _advance_timers(delta: float) -> void:
	_since_land += delta
	_since_shove += delta
	_since_hit += delta
	_since_respawn += delta
	_since_start += delta
	_since_skid += delta
	_spin_t += delta
	_interest_age += delta
	if _panic_left > 0.0:
		_panic_left = maxf(_panic_left - delta, 0.0)
	if _stun_left > 0.0:
		_stun_left = maxf(_stun_left - delta, 0.0)
		if _stun_left == 0.0:
			_stun_total = 0.0
	if _act != &"":
		_act_t += delta
		if _act_t >= _act_len:
			_act = &""
	if _emote != &"":
		_emote_time += delta
		var length: float = EMOTES[_emote]
		if _emote_time >= length:
			if _emote_loop:
				_emote_time = fmod(_emote_time, length)
			else:
				var resume := _resume_emote
				stop_emote()
				if resume != &"":
					_start_emote(resume, true, false)
	if _forced_expression != &"" and _forced_left >= 0.0:
		_forced_left -= delta
		if _forced_left < 0.0:
			_forced_expression = &""


func _pick_reaction(stunned: bool, speed: float, e_skid: float) -> StringName:
	if _since_respawn < RESPAWN_TIME:
		return &"respawn"
	if _since_hit < HIT_TIME:
		return &"hit"
	if stunned:
		return &"stunned"
	if _since_shove < SHOVE_TIME:
		return &"shove"
	if _act == &"throw":
		return &"throw"
	if _since_land < LAND_TIME:
		return &"land"
	if not _grounded:
		return &"air"
	if _emote != &"":
		return &"emote"
	if _act == &"flinch" or _act == &"wince" or _act == &"gloat":
		return _act
	if e_skid > 0.3:
		return &"skid"
	if _teeter_w > 0.5:
		return &"teeter"
	if _sleep_w > 0.5:
		return &"sleep"
	if speed > 0.5:
		if _panic_w > 0.3:
			return &"panic"
		if _bp_w > 0.5:
			return &"backpedal"
		return &"run"
	if _act != &"":
		return &"fidget"
	return &"idle"


# --- Limbs -------------------------------------------------------------------------------

## One foot's step at phase `psi`: (along the step direction, lift, toe pitch).
## First half: planted, sliding back at constant speed (no skating when reach covers the
## stride). Second half: an eased swing forward with a lift arc.
func _foot_cycle(psi: float, reach: float, lift: float) -> Vector3:
	psi = fposmod(psi, TAU)
	if psi < PI:
		return Vector3(reach * (1.0 - 2.0 * psi / PI), 0.0, 0.0)
	var u := (psi - PI) / PI
	return Vector3(-reach * cos(PI * u), lift * sin(PI * u), 0.45 * sin(TAU * u))


func _pose_hands(cx0: float, cx1: float, reach: float, rise: float, e_shove: float, e_hit: float,
		e_land: float, e_stun: float, e_skid: float, idle_w: float) -> void:
	var w := _step_weight
	var calm := _calm
	var heavy := e_land * clampf((_land_strength - 0.45) / 0.4, 0.0, 1.0)
	var pump := 1.0 + 0.5 * clampf((w - 0.5) * 2.0, 0.0, 1.0)
	var droop := 0.05 * _sleep_w
	for i in 2:
		var hand := _hands[i]
		if hand == null:
			continue
		var sgn := 1.0 if i == 0 else -1.0
		var rest := _hand_rest[i]
		var palm := _palm[i]
		# Locomotion: swing opposite to the same-side foot; idle breathing.
		var cx := cx0 if i == 0 else cx1
		var swing := -cx / maxf(reach, 0.01) * 0.13 * w * pump
		var pos := rest + Vector3(sgn * 0.015 * w, 0.03 * w + 0.12 * maxf(swing, 0.0) - droop, swing)
		pos.y += 0.007 * sin(_clock * TAU / (2.8 * _tempo) + _phase0) * idle_w
		var rot := Quaternion(Vector3.RIGHT, -swing * 3.2)
		# Banking: arms out like wings, the outer one higher.
		var b := absf(_bank) / 0.32
		if b > 0.01:
			var outer := 1.0 if (sgn < 0.0) == (_bank > 0.0) else 0.0
			pos += Vector3(sgn * 0.13, 0.12 + 0.1 * outer, -0.03) * b * calm
			rot = rot.slerp(Quaternion(Vector3.BACK, sgn * 0.6), b * 0.7)
		# Backpedal: arms forward, paddling for balance.
		if _bp_w > 0.001:
			var paddle := rest + Vector3(sgn * 0.02, 0.2 + 0.06 * sin(_clock * 14.0 + sgn), 0.22)
			pos = pos.lerp(paddle, _bp_w)
		# Panic: arms flailing over the head in time with the steps.
		if _panic_w > 0.001:
			var ph := _step_phase * 2.0 + (0.0 if sgn > 0.0 else PI)
			var flail := rest + Vector3(sgn * 0.06, 0.5 + 0.12 * sin(ph) * calm, 0.05 * cos(ph))
			pos = pos.lerp(flail, _panic_w)
			rot = rot.slerp(Quaternion(Vector3.BACK, sgn * 0.9 * sin(ph) * calm), _panic_w)
		# Air: hands up while rising, in at the apex (tuck), flailing on the way down.
		if _air_weight > 0.001:
			var ph := _clock * 21.0 + sgn * 1.7
			var up := rest + Vector3(sgn * 0.1, 0.42, -0.04)
			var flail := rest + Vector3(sgn * 0.13, 0.3 + 0.13 * sin(ph) * calm, 0.07 * cos(_clock * 17.0 + sgn))
			var air_rot := Quaternion(Vector3.BACK, sgn * 0.8 * sin(ph) * calm).slerp(Quaternion.IDENTITY.slerp(palm, 0.6), rise)
			var air_pos := flail.lerp(up, rise).lerp(Vector3(sgn * 0.36, 0.56, 0.18), _tuck_w)
			pos = pos.lerp(air_pos, _air_weight)
			rot = rot.slerp(air_rot.slerp(Quaternion(Vector3.RIGHT, -0.5), _tuck_w), _air_weight)
		# Teeter: windmilling arms.
		if _teeter_w > 0.001:
			var ph := _clock * 11.0 + (0.0 if sgn > 0.0 else PI)
			var mill := Vector3(sgn * 0.5, 0.62 + 0.2 * sin(ph) * calm, 0.05 + 0.2 * cos(ph) * calm)
			pos = pos.lerp(mill, _teeter_w)
			rot = rot.slerp(Quaternion(Vector3.RIGHT, ph), _teeter_w)
		# Skid: arms thrown up and forward along the slide.
		if e_skid > 0.001:
			var brace := rest + Vector3(sgn * 0.1, 0.3, 0.0) + _skid_dir * 0.12
			pos = pos.lerp(brace, e_skid)
			rot = rot.slerp(Quaternion.IDENTITY.slerp(palm, 0.5), e_skid)
		# Carrying.
		if _carry_w > 0.001:
			var bob := 0.012 * sin(_step_phase * 2.0) * w
			var cp: Vector3
			var cr: Quaternion
			if _carry_shown == &"overhead":
				cp = Vector3(sgn * 0.28, _overhead_y() + bob, 0.04)
				cr = BlobPose.palm_up(sgn)
			else:
				cp = Vector3(sgn * 0.25, 0.5 + bob, 0.42)
				cr = BlobPose.mirror(Quaternion(Vector3.RIGHT, -0.25), sgn)
			pos = pos.lerp(cp, _carry_w)
			rot = rot.slerp(cr, _carry_w)
		if e_land > 0.001:
			pos += Vector3(sgn * (0.04 + 0.08 * heavy), 0.1 - 0.14 * heavy, 0.0) * e_land
		if e_stun > 0.001:
			var stun_droop := rest + Vector3(-sgn * 0.04, -0.13 + 0.025 * sin(_clock * 6.0 + sgn), 0.04)
			pos = pos.lerp(stun_droop, e_stun)
			rot = rot.slerp(Quaternion(Vector3.RIGHT, 0.4), e_stun)
		if e_hit > 0.001:
			var flung := rest + Vector3(sgn * 0.08, 0.16, 0.0) - _hit_dir * 0.12
			pos = pos.lerp(flung, e_hit)
			rot = rot.slerp(Quaternion(Vector3.BACK, sgn * 0.6), e_hit)
		if e_shove > 0.001:
			pos = pos.lerp(Vector3(sgn * 0.21, 0.45, 0.5), e_shove)
			rot = rot.slerp(Quaternion.IDENTITY.slerp(palm, 0.85), e_shove)
		if _act_w > 0.001 and _act_pose.hands > 0.0:
			pos = pos.lerp(_act_pose.hand_pos[i], _act_w)
			rot = rot.slerp(_act_pose.hand_rot[i], _act_w)
		if _emote_weight > 0.001 and _emote_pose.hands > 0.0:
			pos = pos.lerp(_emote_pose.hand_pos[i], _emote_weight)
			rot = rot.slerp(_emote_pose.hand_rot[i], _emote_weight)
		hand.transform = Transform3D(Basis(rot.normalized()), _keep_out(pos, sgn))


## Pushes a hand centre out of the body ellipsoid (blends between two good poses can cut
## through the belly).
func _keep_out(p: Vector3, sgn: float) -> Vector3:
	var dy := (p.y - BODY_CENTRE_Y) / BODY_RY
	if dy >= 1.0 or dy <= -1.0:
		return p
	var r := BODY_RX * sqrt(1.0 - dy * dy) + HAND_CLEARANCE
	var l2 := p.x * p.x + p.z * p.z
	if l2 >= r * r:
		return p
	if l2 < 0.000001:
		return Vector3(sgn * r, p.y, p.z)
	var s := r / sqrt(l2)
	return Vector3(p.x * s, p.y, p.z * s)


func _pose_feet(c0: Vector3, c1: Vector3, rise: float, e_land: float, e_stun: float, e_skid: float,
		hop: float, shift: float, motion_xf: Transform3D, mrot: Vector3, root_basis: Basis) -> void:
	var w := _step_weight
	# Feet stay planted against the Motion node's lean/bob/hop while on the ground.
	var plant := (1.0 - _air_weight) * (1.0 - clampf(hop / 0.05, 0.0, 1.0))
	var root_inv := root_basis.inverse()
	var motion_inv := motion_xf.affine_inverse()
	var counter := mrot * plant
	var e_act := _act_w
	var e_em := _emote_weight
	for i in 2:
		var foot := _feet[i]
		if foot == null:
			continue
		var sgn := 1.0 if i == 0 else -1.0
		var rest := _foot_rest[i]
		var c := c0 if i == 0 else c1
		var pos := rest + (_step_dir * c.x + Vector3.UP * c.y) * w
		var pitch := c.z * w * signf(_step_dir.z + 0.001)
		# Idle weight shift: the unweighted foot lifts its heel.
		pitch += 0.15 * maxf(0.0, -sgn * shift)
		if _air_weight > 0.001:
			var ph := _clock * 18.0 + sgn * 1.6
			var tuck := rest + Vector3(0.0, 0.08, -0.03)
			var dangle := rest + Vector3(sgn * 0.02, 0.01 + 0.03 * sin(ph), 0.05 * sin(ph))
			var air := dangle.lerp(tuck, rise).lerp(rest + Vector3(0.0, 0.15, 0.05), _tuck_w)
			air = air.lerp(rest + Vector3(sgn * 0.01, -0.07, 0.06), _reach_w)
			pos = pos.lerp(air, _air_weight)
			var air_pitch := lerpf(0.3 * sin(ph), 0.35, rise)
			air_pitch = lerpf(lerpf(air_pitch, 0.5, _tuck_w), 0.35, _reach_w)
			pitch = lerpf(pitch, air_pitch, _air_weight)
		if hop > 0.001:
			pos.y += 0.05 * clampf(hop / 0.16, 0.0, 1.0)
			pitch += 0.3 * clampf(hop / 0.16, 0.0, 1.0)
		if e_skid > 0.001:
			pos += (_skid_dir * (0.09 if i == 0 else 0.05)) * e_skid
			pitch = lerpf(pitch, -0.35, e_skid)
		if e_act > 0.001:
			pos += Vector3(0.0, _act_pose.foot_lift[i], _act_pose.foot_fwd[i]) * e_act
			pitch += _act_pose.foot_pitch[i] * e_act
		if e_em > 0.001:
			pos += Vector3(0.0, _emote_pose.foot_lift[i], _emote_pose.foot_fwd[i]) * e_em
			pitch += _emote_pose.foot_pitch[i] * e_em
		pos.x += sgn * 0.035 * e_land
		pos += Vector3(0.0, 0.0, 0.02 * sin(_clock * 7.0 + sgn)) * e_stun
		if plant > 0.001:
			# Keep the sole above the floor when the toe or heel tips.
			var ap := absf(pitch)
			pos.y = maxf(pos.y, lerpf(pos.y, FOOT_HALF_HEIGHT * cos(ap) + FOOT_HALF_LENGTH * sin(ap), plant))
			var planted := root_inv * (motion_inv * (root_basis * pos))
			pos = pos.lerp(planted, plant)
		foot.transform = Transform3D(Basis.from_euler(Vector3(pitch - counter.x, -counter.y, -counter.z)), pos)


## Vertical stretch `s` (the rest bulges evenly) and a horizontal stretch `k` along
## _dir_axis (the other horizontal axis bulges by 1/k, height unchanged); both keep volume.
func _squash_basis(s: float, k: float) -> Basis:
	var inv := 1.0 / sqrt(s)
	var b := Basis.from_scale(Vector3(inv, s, inv))
	if absf(k - 1.0) > 0.0001:
		var d := _dir_axis
		var e := Vector3(-d.z, 0.0, d.x)  # horizontal, perpendicular to d
		var a := k - 1.0
		var c := 1.0 / k - 1.0
		var m := Basis(
			Vector3(1, 0, 0) + d * (a * d.x) + e * (c * e.x),
			Vector3(0, 1, 0),
			Vector3(0, 0, 1) + d * (a * d.z) + e * (c * e.z))
		b = m * b
	return b


# --- Props: tears and zzz ----------------------------------------------------------------

func _set_tears(on: bool) -> void:
	if not on:
		if _tears:
			_tears.emitting = false
		return
	if _tears == null:
		_tears = _make_tears()
		_rig.root.add_child(_tears)
	_tears.emitting = true


## Two comic arcs of tear drops from the outer eye corners (world-space particles).
func _make_tears() -> CPUParticles3D:
	if _tear_mesh == null:
		_tear_mesh = SphereMesh.new()
		_tear_mesh.radius = 0.03
		_tear_mesh.height = 0.06
		_tear_mesh.radial_segments = 8
		_tear_mesh.rings = 4
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0.55, 0.85, 1.0)
		_tear_mesh.material = m
	var p := CPUParticles3D.new()
	p.name = "Tears"
	p.emitting = false
	p.amount = 18
	p.lifetime = 0.55
	p.local_coords = false
	p.mesh = _tear_mesh
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_DIRECTED_POINTS
	var eye_l := _rig.rest_of(&"EyeL") + Vector3(0.07, 0.0, 0.08)
	p.emission_points = PackedVector3Array([eye_l, Vector3(-eye_l.x, eye_l.y, eye_l.z)])
	p.emission_normals = PackedVector3Array([Vector3(0.85, 0.5, 0.2).normalized(), Vector3(-0.85, 0.5, 0.2).normalized()])
	p.direction = Vector3(1, 0, 0)
	p.spread = 8.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 1.9
	p.gravity = Vector3(0.0, -7.0, 0.0)
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.1
	return p


func _show_zzz(on: bool) -> void:
	if _zzz:
		_zzz.visible = on


## The sleeping blob's "zzz": letters rising from the head and fading, on the nod cycle.
func _update_zzz(e_sleep: float, nod: float) -> void:
	if e_sleep < 0.3 or _far:
		_show_zzz(false)
		return
	if _zzz == null:
		_zzz = Label3D.new()
		_zzz.name = "Zzz"
		_zzz.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_zzz.font_size = 56
		_zzz.outline_size = 10
		_zzz.pixel_size = 0.004
		_zzz.modulate = Color(1.0, 1.0, 1.0)
		_zzz.outline_modulate = Color(0.2, 0.25, 0.45)
		_zzz.no_depth_test = false
		_motion.add_child(_zzz)
	_zzz.visible = true
	var u := fposmod(_clock / 2.4, 1.0)
	var count := 1 + int(u * 3.0)
	var text := "z Z z".substr(0, count * 2 - 1)
	if _zzz.text != text:
		_zzz.text = text
	_zzz.position = Vector3(0.22 + 0.08 * u, 1.12 + 0.3 * u - 0.05 * nod, 0.05)
	var a := sin(PI * u) * clampf((e_sleep - 0.3) / 0.4, 0.0, 1.0)
	_zzz.modulate.a = a
	_zzz.outline_modulate.a = a


# --- Face --------------------------------------------------------------------------------

func _pose_face(delta: float, e_stun: float, v_loc: Vector3, e_skid: float, nod: float) -> void:
	_expression = _pick_expression(e_stun, e_skid)
	var preset := BlobExpressions.get_preset(_expression)
	var k := 1.0 - exp(-18.0 * delta)
	var lid_target: float = preset["lid"]
	if _act_w > 0.5 and _act_pose.lid >= 0.0:
		lid_target = _act_pose.lid
	if _expression == BlobExpressions.SLEEPY and nod < 0.25:
		lid_target = 0.9  # jerks awake for a moment between nods
	_lid = lerpf(_lid, lid_target, 1.0 - exp(-26.0 * delta))
	_mouth = _mouth.lerp(preset["mouth"], k)
	_cheek = lerpf(_cheek, preset["cheek"], k)
	_pupil_scale = lerpf(_pupil_scale, preset["pupil"], k)

	# Blinks (not while the lids are shut or dizzy anyway).
	_blink_in -= delta
	if _blink_in <= 0.0:
		_blink_t = 0.0
		_blink_in = 0.3 if _rng.randf() < 0.15 else _rng.randf_range(1.8, 5.0)
	var blink := 0.0
	if _blink_t >= 0.0:
		_blink_t += delta
		blink = (1.0 - absf(_blink_t / BLINK_TIME * 2.0 - 1.0)) * BlobRig.LID_SHUT
		if _blink_t >= BLINK_TIME:
			_blink_t = -1.0
	var lid_l := maxf(_lid - 0.15 * e_stun, blink)
	var lid_r := maxf(_lid + 0.2 * e_stun, blink)
	if absf(lid_l - _w_lid.x) > 0.001 or absf(lid_r - _w_lid.y) > 0.001:
		_w_lid = Vector2(lid_l, lid_r)
		if _rig.lid_l:
			_rig.lid_l.rotation = Vector3(lid_l, 0.0, 0.0)
		if _rig.lid_r:
			_rig.lid_r.rotation = Vector3(lid_r, 0.0, 0.0)

	# Mouth: pants a little when running, wobbles when dizzy, buzzes for a raspberry.
	var mouth := _mouth * Vector2(1.0, 1.0 + 0.3 * _step_weight)
	mouth.x += 0.1 * sin(_clock * 11.0) * e_stun
	if _expression == BlobExpressions.RASPBERRY:
		mouth.x += 0.08 * sin(_clock * 70.0)
	elif _expression == BlobExpressions.CRY:
		mouth.y += 0.15 * sin(_clock * 9.0)
	mouth.y = clampf(mouth.y, BlobRig.MOUTH_CLOSED, BlobRig.MOUTH_SHOUT)
	if _rig.mouth and (absf(mouth.x - _w_mouth.x) > 0.001 or absf(mouth.y - _w_mouth.y) > 0.001):
		_w_mouth = mouth
		_rig.mouth.scale = Vector3(mouth.x, mouth.y, 1.0)
	if absf(_cheek - _w_cheek) > 0.001:
		_w_cheek = _cheek
		if _rig.cheek_l:
			_rig.cheek_l.scale = Vector3.ONE * _cheek
		if _rig.cheek_r:
			_rig.cheek_r.scale = Vector3.ONE * _cheek

	# Pupils: look target / interest / nearest player / glances, dizzy circles when stunned.
	var look := _look_offset(delta, v_loc)
	if _act_w > 0.001 and _act_pose.pupil_w > 0.0:
		look = look.lerp(_act_pose.pupil, _act_w * _act_pose.pupil_w)
	if _emote_weight > 0.001 and _emote_pose.pupil_w > 0.0:
		look = look.lerp(_emote_pose.pupil, _emote_weight * _emote_pose.pupil_w)
	look.y -= 0.012 * _sleep_w
	look = look.limit_length(BlobRig.PUPIL_RANGE)
	_pupil = _pupil.lerp(look, 1.0 - exp(-22.0 * delta))
	var circle := Vector2(cos(_clock * 12.0), sin(_clock * 12.0)) * 0.017
	var pl := _pupil.lerp(circle, e_stun)
	var pr := _pupil.lerp(Vector2(-circle.x, circle.y), e_stun)
	var pupils := Vector4(pl.x, pl.y, pr.x, pr.y)
	if (pupils - _w_pupils).length_squared() < 0.00000001 and absf(_pupil_scale - _w_pupil_scale) < 0.001:
		return
	_w_pupils = pupils
	_w_pupil_scale = _pupil_scale
	if _rig.pupil_l:
		_rig.pupil_l.transform = Transform3D(Basis.from_scale(Vector3.ONE * _pupil_scale),
			_pupil_rest[0] + Vector3(pl.x, pl.y, 0.0))
	if _rig.pupil_r:
		_rig.pupil_r.transform = Transform3D(Basis.from_scale(Vector3.ONE * _pupil_scale),
			_pupil_rest[1] + Vector3(pr.x, pr.y, 0.0))


func _pick_expression(e_stun: float, e_skid: float) -> StringName:
	if _forced_expression != &"":
		return _forced_expression
	if _since_hit < HIT_TIME:
		return BlobExpressions.HURT
	if e_stun > 0.0 or _stun_left > 0.0:
		return BlobExpressions.DIZZY
	if _since_shove < SHOVE_TIME or _act == &"throw":
		return BlobExpressions.EFFORT
	if _emote != &"" and _emote_pose.expression != &"":
		return _emote_pose.expression
	if _act != &"" and _act_w > 0.3 and _act_pose.expression != &"":
		return _act_pose.expression
	if e_skid > 0.3 or _teeter_w > 0.4:
		return BlobExpressions.WORRIED
	if _panic_w > 0.3:
		return BlobExpressions.PANIC
	if _sleep_w > 0.5:
		return BlobExpressions.SLEEPY
	if _since_respawn < RESPAWN_TIME * 2.0 or not _grounded:
		return BlobExpressions.HAPPY
	return BlobExpressions.NEUTRAL


## Pupil offset (model x/y, metres) toward what the blob looks at: the look target, else an
## interest point, else the fastest thing flying by, else now and then the camera, else the
## nearest other player, else a random glance that changes every second or two. Also sets
## `_look_world` / `_look_body` for the body twist.
func _look_offset(delta: float, v_loc: Vector3) -> Vector2:
	_glance_in -= delta
	if _glance_in <= 0.0:
		_glance_in = _rng.randf_range(0.7, 2.4)
		_glance = Vector2.ZERO if _rng.randf() < 0.3 else \
			Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(0.006, 0.017)
		if not _lite and _cam_pos != Vector3.INF and _rng.randf() < _camera_glancer:
			_cam_look_left = _rng.randf_range(1.0, 1.8)
	_cam_look_left -= delta
	_nearest_in -= delta
	if _nearest_in <= 0.0:
		_nearest_in = 0.3
		_scan_neighbours(6.0)
	var idle := (1.0 - _step_weight) * (1.0 - _air_weight)
	var point: Variant = _look_point
	var body := 0.0
	if point == null and _look_node != null:
		var node := _look_node.get_ref() as Node3D
		if node != null and node.is_inside_tree():
			point = node.global_position
		elif node == null:
			_look_node = null  # freed: back to glancing around
	if point != null:
		body = 0.5 * idle
	if point == null and _interest_age < 0.6 and _interest_strength > 0.05:
		point = _interest
		body = _interest_strength * (1.0 - smoothstep(0.25, 0.6, _interest_age)) * (0.3 + 0.6 * idle)
	if point == null and _fastest != null:
		var fast := _fastest.get_ref() as Player
		if fast != null and fast.is_inside_tree() and fast.alive:
			point = fast.global_position + Vector3.UP * 0.5
			body = 0.3 + 0.5 * idle
		else:
			_fastest = null
	if point == null and _cam_look_left > 0.0 and idle > 0.5 and _cam_pos != Vector3.INF:
		point = _cam_pos
		body = 0.35 * idle
	if point == null and _nearest != null:
		var other := _nearest.get_ref() as Player
		if other != null and other.is_inside_tree() and other.alive:
			point = other.global_position + Vector3.UP * 0.6
			body = 0.4 * idle
		else:
			_nearest = null
	if _teeter_w > 0.5:
		point = player.global_position + Basis(Vector3.UP, _yaw) * (_edge * 0.9 + Vector3(0.0, -0.6, 0.0))
		body = 0.0
	_look_world = point if point != null else Vector3.INF
	_look_body = body if not _lite else 0.0
	var ahead := Vector2(clampf(v_loc.x * 0.003, -0.01, 0.01), 0.0)
	if point == null or not is_inside_tree():
		return (_glance + ahead).limit_length(BlobRig.PUPIL_RANGE)
	# Model space by yaw-space math (no global transform update): good enough for the eyes.
	var rel: Vector3 = point - player.global_position
	var d: Vector3 = Basis(Vector3.UP, -(_yaw + _twist)) * rel / _size_k - _rig.eye_centre
	if d.length_squared() < 0.0001:
		return _glance
	var dir := d.normalized()
	var off := Vector2(dir.x, dir.y) * 0.03 + _glance * 0.25
	return off.limit_length(BlobRig.PUPIL_RANGE)


## The nearest other blob within `max_distance`, and the fastest-moving one (a blob sent
## flying) within it, from this blob's siblings.
func _scan_neighbours(max_distance: float) -> void:
	_nearest = null
	_fastest = null
	var parent := player.get_parent()
	if parent == null or not player.is_inside_tree():
		return
	var here := player.global_position
	var best_d := max_distance * max_distance
	var best_fast := 25.0  # (5 m/s)^2
	for child in parent.get_children():
		var other := child as Player
		if other == null or other == player or not other.alive or not other.is_inside_tree():
			continue
		var d := other.global_position.distance_squared_to(here)
		if d >= max_distance * max_distance:
			continue
		if d < best_d:
			best_d = d
			_nearest = weakref(other)
		var v2 := other.velocity.length_squared()
		if v2 > best_fast:
			best_fast = v2
			_fastest = weakref(other)


# --- Helpers -----------------------------------------------------------------------------

## 0 -> 1 over `attack`, holds, 1 -> 0 over `release`; 0 outside.
func _envelope(t: float, attack: float, hold: float, release: float) -> float:
	if t < 0.0 or t > attack + hold + release:
		return 0.0
	if t < attack:
		return smoothstep(0.0, attack, t)
	if t < attack + hold:
		return 1.0
	return 1.0 - smoothstep(0.0, release, t - attack - hold)


## Jumps the visual state to the player's current position and facing (spawn, respawn).
func _snap_to_player() -> void:
	var f := player.facing
	if f.length_squared() > 0.0001:
		_yaw = atan2(f.x, f.z)
	if _pivot:
		_pivot.rotation = Vector3(0.0, _yaw, 0.0)
	_has_last = false
	_vel = Vector3.ZERO
	_accel = Vector3.ZERO
