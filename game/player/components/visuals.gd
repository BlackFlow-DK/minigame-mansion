class_name VisualsComponent
extends PlayerComponent
## Shows the player blob (`res://assets/models/character/blob.glb`) and animates it entirely
## in code, on every peer. Owner: character animator.
##
## It only READS replicated state (global position -> a velocity estimate, `facing`, `alive`,
## `slot`, `loadout`) and LISTENS to the player events (jumped, landed, shove_started,
## shove_hit, got_hit, stunned, eliminated, respawned). It never writes gameplay state and
## ignores `intent`, so a remote copy animates exactly like the authority's.
##
## Nodes built under this component:
##   Pivot         yaw: the smoothed `facing`
##     Motion      lean, bob, breathing, visual hops (feet are counter-planted against it)
##       <model>   the blob.glb root: squash-and-stretch only (volume-preserving, from the
##                 feet), identity at rest; face parts, sockets and hats follow it
## Layers, lowest first: locomotion (steps tied to distance travelled, opposite arm swing,
## lean into acceleration, bob) -> air (anticipation stretch, tuck, flail) -> reactions
## (landing squash, shove, hit, stun, pop-in) -> emotes. The face eases between
## BlobExpressions presets, blinks, and glances around or at the nearest other player.
##
## Public API (other systems):
##   get_model_root() -> Node3D           the blob.glb instance. Sockets HatSocket, FaceSocket,
##                                        NeckSocket, BackSocket and the PlayerPrimary /
##                                        PlayerSecondary materials live under it and stay put.
##   apply_tint(primary, secondary)       recolour the player materials (cosmetics can take over)
##   play_emote(name, loop := false) -> bool   &"cheer", &"wave", &"sad"; false if unknown
##   stop_emote()
##   set_look_target(target)              Node3D or world Vector3 to look at; null = glance around
##   set_expression(name, seconds := -1.0)     force a BlobExpressions preset; &"" releases it
##   get_reaction() / get_expression() / get_emote()   what is showing now (tests, debugging)

## Default primary colour per slot when `loadout` has none (secondary: DEFAULT_SECONDARY).
const DEFAULT_PRIMARY: Array[String] = [
	"#ff5a5f", "#3fa9f5", "#62c370", "#ffc93c", "#a26bff", "#ff8c42", "#2ec4b6", "#f7f7f7",
]
const DEFAULT_SECONDARY := "#fff4e6"
const EMOTES: Dictionary = {&"cheer": 1.8, &"wave": 1.8, &"sad": 2.2}  # name -> seconds

const SHOVE_TIME := 0.4
const HIT_TIME := 0.3
const LAND_TIME := 0.32
const RESPAWN_TIME := 0.6
const BLINK_TIME := 0.14
## Palms forward, fingers up (left hand); the right hand uses the X-mirrored rotation.
const PALM_FORWARD_L := Basis(Vector3(0, 0, -1), Vector3(0, -1, 0), Vector3(-1, 0, 0))

## How fast the model turns to `facing` (1/s, exponential).
@export var turn_sharpness: float = 18.0
## Metres travelled per step at a walk; grows with speed (see _step_length).
@export var base_step_length: float = 0.32
## Furthest a foot reaches forward/back from its rest spot while stepping (m).
@export var max_foot_reach: float = 0.19

var _pivot: Node3D
var _motion: Node3D
var _rig: BlobRig
var _rng := RandomNumberGenerator.new()
var _clock: float = 0.0

# Motion estimated from the replicated position (works the same on every peer).
var _vel: Vector3 = Vector3.ZERO
var _accel: Vector3 = Vector3.ZERO
var _last_pos: Vector3 = Vector3.ZERO
var _has_last: bool = false
var _grounded: bool = true
var _event_air: bool = false

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
var _since_shove: float = 99.0
var _since_hit: float = 99.0
var _hit_dir: Vector3 = Vector3.ZERO  # model space
var _stun_left: float = 0.0
var _stun_total: float = 0.0
var _since_respawn: float = 99.0
var _dead: bool = false

var _emote: StringName = &""
var _emote_time: float = 0.0
var _emote_loop: bool = false

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
var _look_target: Variant = null
var _glance: Vector2 = Vector2.ZERO
var _glance_in: float = 0.5
var _pupil: Vector2 = Vector2.ZERO
var _nearest: Player = null
var _nearest_in: float = 0.0
var _reaction: StringName = &"idle"


func _ready() -> void:
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
	if player == null:
		return
	_rng.seed = hash(player.slot) + 7919
	_blink_in = _rng.randf_range(0.5, 3.0)
	_tint_from_loadout()
	_snap_to_player()
	player.jumped.connect(_on_jumped)
	player.landed.connect(_on_landed)
	player.shove_started.connect(_on_shove_started)
	player.shove_hit.connect(_on_shove_hit)
	player.got_hit.connect(_on_got_hit)
	player.stunned.connect(_on_stunned)
	player.eliminated.connect(_on_eliminated)
	player.respawned.connect(_on_respawned)
	_dead = not player.alive


# --- Public API ------------------------------------------------------------------------

## The blob.glb instance. Cosmetics tint its PlayerPrimary/PlayerSecondary materials and
## attach items to its HatSocket/FaceSocket/NeckSocket/BackSocket children; both stay stable.
## Its own transform is animated (squash-and-stretch), so attach under the sockets, not beside it.
func get_model_root() -> Node3D:
	return _rig.root if _rig else null


## Recolours this blob's PlayerPrimary / PlayerSecondary surfaces with per-instance copies
## (the shared imported materials, and their names, are left untouched).
func apply_tint(primary: Color, secondary: Color) -> void:
	if _rig == null:
		return
	for mi in _rig.meshes():
		for i in mi.mesh.get_surface_count():
			var base := mi.mesh.surface_get_material(i) as BaseMaterial3D
			if base == null:
				continue
			var colour: Color
			if base.resource_name == "PlayerPrimary":
				colour = primary
			elif base.resource_name == "PlayerSecondary":
				colour = secondary
			else:
				continue
			var copy := base.duplicate() as BaseMaterial3D
			copy.albedo_color = colour
			mi.set_surface_override_material(i, copy)


## Plays `emote` (&"cheer", &"wave", &"sad") on top of whatever the blob is doing.
## `loop` keeps it going until stop_emote() or another emote. Returns false if unknown.
func play_emote(emote: StringName, loop: bool = false) -> bool:
	if not EMOTES.has(emote):
		return false
	_emote = emote
	_emote_time = 0.0
	_emote_loop = loop
	return true


func stop_emote() -> void:
	_emote = &""


## The emote playing now, or &"".
func get_emote() -> StringName:
	return _emote


## Where the eyes should look: a Node3D (followed), a world-space Vector3, or null to go
## back to glancing around / at the nearest other player.
func set_look_target(target: Variant) -> void:
	if target is Node3D or target is Vector3:
		_look_target = target
	else:
		_look_target = null


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


## The dominant animation layer now: &"eliminated", &"respawn", &"stunned", &"hit", &"shove",
## &"land", &"air", &"emote", &"run" or &"idle".
func get_reaction() -> StringName:
	return _reaction


# --- Tint --------------------------------------------------------------------------------

## Colours from `player.loadout` (`primary`/`secondary` hex), else a per-slot default.
## The one place the visuals colour the blob; the cosmetics system may take this over.
func _tint_from_loadout() -> void:
	var slot_primary := Color(DEFAULT_PRIMARY[posmod(player.slot, DEFAULT_PRIMARY.size())])
	var primary := Color.from_string(str(player.loadout.get("primary", "")), slot_primary)
	var secondary := Color.from_string(str(player.loadout.get("secondary", "")), Color(DEFAULT_SECONDARY))
	apply_tint(primary, secondary)


# --- Events ------------------------------------------------------------------------------

func _on_jumped() -> void:
	_event_air = true
	# Anticipation: a quick squash that springs straight into a take-off stretch.
	_squash.value = minf(_squash.value, 0.84)
	_squash.velocity = 9.0
	_lean_x.velocity -= 1.5


func _on_landed(impact_speed: float) -> void:
	_event_air = false
	_since_land = 0.0
	_land_strength = clampf(impact_speed / 13.0, 0.15, 1.0)
	_squash.value = minf(_squash.value, 1.0 - 0.42 * _land_strength)
	_squash.velocity = 0.0
	_lean_x.velocity += 2.0 * _land_strength


func _on_shove_started() -> void:
	_since_shove = 0.0
	_lean_x.velocity += 7.5
	_dir_axis = Vector3.MODEL_FRONT
	_dir_squash.value = maxf(_dir_squash.value, 1.0)
	_dir_squash.velocity += 5.0


func _on_shove_hit(_victim_slot: int) -> void:
	_lean_x.velocity -= 2.5
	_squash.velocity -= 1.5


func _on_got_hit(impulse: Vector3, _source_slot: int) -> void:
	_since_hit = 0.0
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


func _on_stunned(duration: float) -> void:
	_stun_left = maxf(_stun_left, duration + 0.05)
	_stun_total = maxf(_stun_total, _stun_left)


func _on_eliminated(_reason: StringName) -> void:
	_dead = true
	_stun_left = 0.0
	_emote = &""
	_spawn_pop_ghost()


func _on_respawned(_xform: Transform3D) -> void:
	_dead = false
	_since_respawn = 0.0
	_since_land = 99.0
	_since_shove = 99.0
	_since_hit = 99.0
	_stun_left = 0.0
	_event_air = false
	_squash.snap(1.0)
	_dir_squash.snap(1.0)
	_lean_x.snap(0.0)
	_lean_z.snap(0.0)
	_pop.snap(0.0)
	_pop.velocity = 2.0
	_snap_to_player()


## The real blob is hidden the moment a player is eliminated (Player hides itself), so the
## shrink-pop plays on a copy of the model left behind in the world, which frees itself.
func _spawn_pop_ghost() -> void:
	if _rig == null or not is_inside_tree() or player.get_parent() == null:
		return
	var ghost := _rig.root.duplicate() as Node3D
	player.get_parent().add_child(ghost)
	ghost.name = "%sPop" % player.name
	ghost.global_transform = _rig.root.global_transform
	var s := ghost.scale
	var tw := ghost.create_tween()
	tw.tween_property(ghost, "scale", s * Vector3(1.3, 0.7, 1.3), 0.06).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(ghost, "scale", s * Vector3(0.8, 1.35, 0.8), 0.07).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(ghost, "scale", s * 0.01, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(ghost.queue_free)


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
	var v := _vel.lerp(raw, 1.0 - exp(-30.0 * delta))
	_accel = _accel.lerp((v - _vel) / delta, 1.0 - exp(-14.0 * delta))
	_vel = v
	if player.is_authority():
		_grounded = player.is_on_floor()
	else:
		# Remote copies never run move_and_slide: airborne from `jumped` until `landed`, or
		# whenever the replicated position is clearly moving vertically (fell off a ledge).
		_grounded = not _event_air and absf(_vel.y) < 1.5


func _process(delta: float) -> void:
	if player == null or _rig == null:
		return
	delta = minf(delta, 0.1)
	_clock += delta
	_advance_timers(delta)
	if _dead:
		_reaction = &"eliminated"
		return

	# Facing.
	var f := player.facing
	if f.length_squared() > 0.0001:
		_yaw = lerp_angle(_yaw, atan2(f.x, f.z), 1.0 - exp(-turn_sharpness * delta))
	_pivot.rotation = Vector3(0.0, _yaw, 0.0)

	var to_local := Basis(Vector3.UP, -_yaw)
	var hv := Vector3(_vel.x, 0.0, _vel.z)
	var v_loc := to_local * hv
	var a_loc := to_local * Vector3(_accel.x, 0.0, _accel.z)
	var speed := hv.length()
	var stunned := _stun_left > 0.0
	var e_stun := 0.0
	if stunned:
		e_stun = smoothstep(0.0, 0.1, _stun_total - _stun_left) * smoothstep(0.0, 0.25, _stun_left)

	# Weights of the big layers.
	_air_weight = lerpf(_air_weight, 0.0 if _grounded else 1.0, 1.0 - exp(-16.0 * delta))
	var step_target := 0.0 if (not _grounded or stunned) else clampf(speed / 1.2, 0.0, 1.0)
	_step_weight = lerpf(_step_weight, step_target, 1.0 - exp(-10.0 * delta))
	_emote_weight = lerpf(_emote_weight, 1.0 if _emote != &"" else 0.0, 1.0 - exp(-10.0 * delta))
	var w := _step_weight
	if speed > 0.3:
		_step_dir = _step_dir.slerp(v_loc.normalized(), 1.0 - exp(-12.0 * delta)).normalized()
	var e_shove := _envelope(_since_shove, 0.04, 0.12, SHOVE_TIME - 0.16)
	var e_hit := _envelope(_since_hit, 0.02, 0.1, HIT_TIME - 0.12)
	var e_land := _envelope(_since_land, 0.02, 0.04, LAND_TIME - 0.06) * _land_strength
	var rise := clampf(0.65 + _vel.y / 5.0, 0.0, 1.0)  # 1 rising, 0 falling

	# Step cycle: the phase advances with distance travelled (one step per stride).
	var stride := base_step_length + 0.075 * speed
	if _grounded and not stunned:
		_step_phase = fposmod(_step_phase + speed * delta * PI / stride, TAU)
	var reach := minf(stride * 0.5, max_foot_reach)
	var lift := minf(0.05 + 0.012 * speed, 0.12)
	var foot_cycle: Array[Vector3] = [
		_foot_cycle(_step_phase, reach, lift), _foot_cycle(_step_phase + PI, reach, lift)]
	var s2 := sin(_step_phase) * sin(_step_phase)

	# Emote-driven body motion.
	var hop := 0.0
	var emote_lean := Vector2.ZERO
	var emote_squash := 0.0
	var e_em := _emote_weight
	match _emote:
		&"cheer":
			var b := absf(sin(PI * _emote_time / 0.45))
			hop = 0.16 * b
			emote_squash = 0.08 * b - 0.14 * pow(1.0 - b, 4.0)
		&"wave":
			emote_lean = Vector2(0.0, 0.07 + 0.03 * sin(_clock * 5.5))
		&"sad":
			emote_lean = Vector2(0.24, 0.0)
			emote_squash = -0.1

	# Lean: into acceleration, forward with speed, sway over the stance foot, stun wobble.
	var lean_target := Vector2(
		clampf(v_loc.z * 0.034 + a_loc.z * 0.0045, -0.26, 0.34),
		clampf(-a_loc.x * 0.0045, -0.3, 0.3))
	if not _grounded:
		lean_target *= 0.4
	lean_target = lean_target.lerp(emote_lean, e_em)
	_lean_x.step(lean_target.x, delta)
	_lean_z.step(lean_target.y, delta)
	var wobble := Vector2(sin(_clock * 9.0), cos(_clock * 9.0)) * 0.14 * e_stun
	var sway := -0.05 * w * sin(_step_phase)

	# Vertical squash-and-stretch target.
	var sq_target := 1.0 + 0.035 * w * (s2 - 0.5)
	if not _grounded:
		sq_target += clampf(_vel.y * 0.022, -0.06, 0.12)
	sq_target -= 0.05 * e_stun
	sq_target += emote_squash * e_em
	_squash.step(sq_target, delta)
	_dir_squash.step(1.0, delta)
	_pop.step(1.0, delta)

	# Motion node: bob, hop, lunge, lean, breathing.
	var breath := 1.0 + 0.016 * sin(_clock * TAU / 2.8) * (1.0 - w)
	var bob := (0.02 + 0.006 * speed) * w * s2
	_motion.position = Vector3(0.0, bob + hop * e_em, 0.07 * e_shove)
	_motion.rotation = Vector3(_lean_x.value + wobble.x, 0.0, _lean_z.value + sway + wobble.y)
	_motion.scale = Vector3(1.0 / sqrt(breath), breath, 1.0 / sqrt(breath))

	# Model root: squash-and-stretch only, volume preserving, from the feet.
	var root_basis := _squash_basis(clampf(_squash.value, 0.45, 1.7), clampf(_dir_squash.value, 0.5, 1.6))
	_rig.root.transform = Transform3D(root_basis.scaled(Vector3.ONE * maxf(_pop.value, 0.01)), Vector3.ZERO)

	_pose_hands(foot_cycle, reach, rise, e_shove, e_hit, e_land, e_stun)
	_pose_feet(foot_cycle, rise, e_land, e_stun, hop * e_em)
	_pose_face(delta, e_stun, v_loc)
	_reaction = _pick_reaction(e_stun > 0.0 or stunned, speed)


func _advance_timers(delta: float) -> void:
	_since_land += delta
	_since_shove += delta
	_since_hit += delta
	_since_respawn += delta
	if _stun_left > 0.0:
		_stun_left = maxf(_stun_left - delta, 0.0)
		if _stun_left == 0.0:
			_stun_total = 0.0
	if _emote != &"":
		_emote_time += delta
		var length: float = EMOTES[_emote]
		if _emote_time >= length:
			if _emote_loop:
				_emote_time = fmod(_emote_time, length)
			else:
				_emote = &""
	if _forced_expression != &"" and _forced_left >= 0.0:
		_forced_left -= delta
		if _forced_left < 0.0:
			_forced_expression = &""


func _pick_reaction(stunned: bool, speed: float) -> StringName:
	if _since_respawn < RESPAWN_TIME:
		return &"respawn"
	if _since_hit < HIT_TIME:
		return &"hit"
	if stunned:
		return &"stunned"
	if _since_shove < SHOVE_TIME:
		return &"shove"
	if _since_land < LAND_TIME:
		return &"land"
	if not _grounded:
		return &"air"
	if _emote != &"":
		return &"emote"
	if speed > 0.5:
		return &"run"
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


func _pose_hands(cycle: Array[Vector3], reach: float, rise: float, e_shove: float, e_hit: float,
		e_land: float, e_stun: float) -> void:
	var hands: Array[Node3D] = [_rig.hand_l, _rig.hand_r]
	var w := _step_weight
	for i in 2:
		var hand := hands[i]
		if hand == null:
			continue
		var sgn := 1.0 if i == 0 else -1.0
		var rest := _rig.rest_of(&"HandL" if i == 0 else &"HandR")
		var palm := _palm_forward(sgn)
		# Locomotion: swing opposite to the same-side foot; idle breathing.
		var swing := -cycle[i].x / maxf(reach, 0.01) * 0.13 * w
		var pos := rest + Vector3(sgn * 0.015 * w, 0.03 * w + 0.12 * maxf(swing, 0.0), swing)
		pos.y += 0.007 * sin(_clock * TAU / 2.8) * (1.0 - w)
		var rot := Quaternion(Vector3.RIGHT, -swing * 3.2)
		# Air: hands up while rising, flailing while falling.
		if _air_weight > 0.001:
			var ph := _clock * 21.0 + sgn * 1.7
			var up := rest + Vector3(sgn * 0.1, 0.42, -0.04)
			var flail := rest + Vector3(sgn * 0.13, 0.3 + 0.13 * sin(ph), 0.07 * cos(_clock * 17.0 + sgn))
			var air_rot := Quaternion(Vector3.BACK, sgn * 0.8 * sin(ph)).slerp(Quaternion.IDENTITY.slerp(palm, 0.6), rise)
			pos = pos.lerp(flail.lerp(up, rise), _air_weight)
			rot = rot.slerp(air_rot, _air_weight)
		if e_land > 0.001:
			pos += Vector3(sgn * 0.04, 0.1, 0.0) * e_land
		if e_stun > 0.001:
			var droop := rest + Vector3(-sgn * 0.04, -0.13 + 0.025 * sin(_clock * 6.0 + sgn), 0.04)
			pos = pos.lerp(droop, e_stun)
			rot = rot.slerp(Quaternion(Vector3.RIGHT, 0.4), e_stun)
		if e_hit > 0.001:
			var flung := rest + Vector3(sgn * 0.08, 0.16, 0.0) - _hit_dir * 0.12
			pos = pos.lerp(flung, e_hit)
			rot = rot.slerp(Quaternion(Vector3.BACK, sgn * 0.6), e_hit)
		if e_shove > 0.001:
			pos = pos.lerp(Vector3(sgn * 0.21, 0.45, 0.5), e_shove)
			rot = rot.slerp(Quaternion.IDENTITY.slerp(palm, 0.85), e_shove)
		if _emote_weight > 0.001:
			var ep := pos
			var er := rot
			match _emote:
				&"cheer":
					ep = Vector3(sgn * 0.52, 0.74 + 0.07 * sin(_clock * 13.0 + sgn * 0.9), 0.07)
					er = palm
				&"wave":
					if i == 1:
						ep = Vector3(-0.56, 0.8, 0.1)
						er = Quaternion(Vector3.BACK, 0.55 * sin(_clock * 11.0)) * palm
					else:
						ep = rest + Vector3(0.0, -0.02, 0.05)
				&"sad":
					ep = rest + Vector3(-sgn * 0.07, -0.11, 0.08)
					er = Quaternion(Vector3.RIGHT, 0.25)
			pos = pos.lerp(ep, _emote_weight)
			rot = rot.slerp(er, _emote_weight)
		hand.transform = Transform3D(Basis(rot.normalized()), pos)


func _pose_feet(cycle: Array[Vector3], rise: float, e_land: float, e_stun: float, hop: float) -> void:
	var feet: Array[Node3D] = [_rig.foot_l, _rig.foot_r]
	var w := _step_weight
	# Feet stay planted against the Motion node's lean/bob/hop while on the ground.
	var plant := (1.0 - _air_weight) * (1.0 - clampf(hop / 0.05, 0.0, 1.0))
	var root_basis := _rig.root.transform.basis
	var root_inv := root_basis.inverse()
	var motion_inv := _motion.transform.affine_inverse()
	for i in 2:
		var foot := feet[i]
		if foot == null:
			continue
		var sgn := 1.0 if i == 0 else -1.0
		var rest := _rig.rest_of(&"FootL" if i == 0 else &"FootR")
		var c := cycle[i]
		var pos := rest + (_step_dir * c.x + Vector3.UP * c.y) * w
		var pitch := c.z * w * signf(_step_dir.z + 0.001)
		if _air_weight > 0.001:
			var ph := _clock * 18.0 + sgn * 1.6
			var tuck := rest + Vector3(0.0, 0.08, -0.03)
			var dangle := rest + Vector3(sgn * 0.02, 0.01 + 0.03 * sin(ph), 0.05 * sin(ph))
			pos = pos.lerp(dangle.lerp(tuck, rise), _air_weight)
			pitch = lerpf(pitch, lerpf(0.3 * sin(ph), 0.35, rise), _air_weight)
		if hop > 0.001:
			pos.y += 0.05 * clampf(hop / 0.16, 0.0, 1.0)
			pitch += 0.3 * clampf(hop / 0.16, 0.0, 1.0)
		pos.x += sgn * 0.035 * e_land
		pos += Vector3(0.0, 0.0, 0.02 * sin(_clock * 7.0 + sgn)) * e_stun
		if plant > 0.001:
			var planted := root_inv * (motion_inv * (root_basis * pos))
			pos = pos.lerp(planted, plant)
		var counter := _motion.rotation * plant
		foot.transform = Transform3D(Basis.from_euler(Vector3(pitch - counter.x, 0.0, -counter.z)), pos)


func _palm_forward(sgn: float) -> Quaternion:
	var q := PALM_FORWARD_L.get_rotation_quaternion()
	return q if sgn > 0.0 else Quaternion(q.x, -q.y, -q.z, q.w)


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


# --- Face --------------------------------------------------------------------------------

func _pose_face(delta: float, e_stun: float, v_loc: Vector3) -> void:
	_expression = _pick_expression(e_stun)
	var preset := BlobExpressions.get_preset(_expression)
	var k := 1.0 - exp(-18.0 * delta)
	_lid = lerpf(_lid, preset["lid"], 1.0 - exp(-26.0 * delta))
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
	if _rig.lid_l:
		_rig.lid_l.rotation = Vector3(lid_l, 0.0, 0.0)
	if _rig.lid_r:
		_rig.lid_r.rotation = Vector3(lid_r, 0.0, 0.0)

	# Mouth: pants a little when running, wobbles when dizzy.
	var mouth := _mouth * Vector2(1.0, 1.0 + 0.3 * _step_weight)
	mouth.x += 0.1 * sin(_clock * 11.0) * e_stun
	if _rig.mouth:
		_rig.mouth.scale = Vector3(mouth.x, clampf(mouth.y, BlobRig.MOUTH_CLOSED, BlobRig.MOUTH_SHOUT), 1.0)
	for cheek in [_rig.cheek_l, _rig.cheek_r]:
		if cheek:
			(cheek as Node3D).scale = Vector3.ONE * _cheek

	# Pupils: look target / nearest player / glances, dizzy circles when stunned.
	var look := _look_offset(delta, v_loc)
	_pupil = _pupil.lerp(look, 1.0 - exp(-22.0 * delta))
	var circle := Vector2(cos(_clock * 12.0), sin(_clock * 12.0)) * 0.017
	var pl := _pupil.lerp(circle, e_stun)
	var pr := _pupil.lerp(Vector2(-circle.x, circle.y), e_stun)
	if _rig.pupil_l:
		_rig.pupil_l.position = _rig.rest_of(&"PupilL") + Vector3(pl.x, pl.y, 0.0)
		_rig.pupil_l.scale = Vector3.ONE * _pupil_scale
	if _rig.pupil_r:
		_rig.pupil_r.position = _rig.rest_of(&"PupilR") + Vector3(pr.x, pr.y, 0.0)
		_rig.pupil_r.scale = Vector3.ONE * _pupil_scale


func _pick_expression(e_stun: float) -> StringName:
	if _forced_expression != &"":
		return _forced_expression
	if _since_hit < HIT_TIME:
		return BlobExpressions.HURT
	if e_stun > 0.0 or _stun_left > 0.0:
		return BlobExpressions.DIZZY
	if _since_shove < SHOVE_TIME:
		return BlobExpressions.EFFORT
	match _emote:
		&"cheer":
			return BlobExpressions.CHEER
		&"wave":
			return BlobExpressions.HAPPY
		&"sad":
			return BlobExpressions.SAD
	if _since_respawn < RESPAWN_TIME * 2.0 or not _grounded:
		return BlobExpressions.HAPPY
	return BlobExpressions.NEUTRAL


## Pupil offset (model x/y, metres) toward the look target, else the nearest other player,
## else a random glance that changes every second or two.
func _look_offset(delta: float, v_loc: Vector3) -> Vector2:
	_glance_in -= delta
	if _glance_in <= 0.0:
		_glance_in = _rng.randf_range(0.7, 2.4)
		_glance = Vector2.ZERO if _rng.randf() < 0.3 else \
			Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(0.006, 0.017)
	_nearest_in -= delta
	if _nearest_in <= 0.0:
		_nearest_in = 0.5
		_nearest = _find_nearest(5.0)
	var point: Variant = null
	if _look_target is Vector3:
		point = _look_target
	elif _look_target is Node3D and is_instance_valid(_look_target):
		point = (_look_target as Node3D).global_position
	elif _nearest != null and is_instance_valid(_nearest) and _nearest.alive:
		point = _nearest.global_position + Vector3.UP * 0.6
	var ahead := Vector2(clampf(v_loc.x * 0.003, -0.01, 0.01), 0.0)
	if point == null or not _pivot.is_inside_tree():
		return (_glance + ahead).limit_length(BlobRig.PUPIL_RANGE)
	var d: Vector3 = _pivot.to_local(point) - _rig.eye_centre
	if d.length_squared() < 0.0001:
		return _glance
	var dir := d.normalized()
	var off := Vector2(dir.x, dir.y) * 0.03 + _glance * 0.25
	return off.limit_length(BlobRig.PUPIL_RANGE)


func _find_nearest(max_distance: float) -> Player:
	var parent := player.get_parent()
	if parent == null or not player.is_inside_tree():
		return null
	var best: Player = null
	var best_d := max_distance * max_distance
	for child in parent.get_children():
		var other := child as Player
		if other == null or other == player or not other.alive:
			continue
		var d := other.global_position.distance_squared_to(player.global_position)
		if d < best_d:
			best_d = d
			best = other
	return best


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
