class_name MansionLobby
extends Minigame
## The mansion hall players run around in between sessions. A Minigame that never
## finishes (no time limit, never calls finish()), so Stage loads it and spawns players at
## $Spawns like any minigame (docs/contract.md "Stage and minigames").
##
## The hall is assembled in code from the mansion kit (res://assets/models/env/), the same
## way on every peer: parquet floor, back and side walls (the front is open for the
## camera), the grand staircase with the glowing portal arch on its landing, a fireplace
## corner, a piano corner, decor, and simple box collision on the world layer.
##
## Toys. All of them are derived locally from the (synced) player positions, so nothing
## here needs its own RPCs:
##   - sofa and armchair cushions throw a blob that lands on them back up; the bounce is
##     applied by that blob's own authority (`landed` signal + its slide collisions)
##   - a floor keyboard in front of the piano lights the key a blob stands on
##     (`piano_key_pressed` fires for the audio system to pick up later)
##   - the portal glows brighter and pulses faster the more blobs gather before it
## Host only: a player that falls below KILL_Y is respawned at its spawn point.
##
## Look: when the shared rig res://look/stage_look.tscn exists it is instanced with preset
## WARM_HALL and the fallback $Look (WorldEnvironment + moon) is removed. The practical
## lights (fire, chandeliers, candles, portal, moonlight through the windows) always stay.

## A key of the floor keyboard started being stood on (local, every peer).
signal piano_key_pressed(index: int)
## A blob bounced off a cushion (raised on the bouncing blob's authority).
signal cushion_bounced(slot: int)

const ENV_DIR := "res://assets/models/env/"
const SHARED_LOOK_PATH := "res://look/stage_look.tscn"
const SHARED_LOOK_PRESET := "WARM_HALL"

## Side wall centre lines are at x = +-HALF_X, the back wall at BACK_Z; the front is open at FRONT_Z.
const HALF_X := 12.0
const BACK_Z := -9.0
const FRONT_Z := 9.0
## Collision height of the walls and the invisible front barrier (nobody jumps out).
const BARRIER_H := 14.0
## Below this a player is respawned (host).
const KILL_Y := -10.0
## is_safe(): the walkable interior, a little inside the wall faces.
const SAFE_MIN := Vector2(-11.4, -8.45)
const SAFE_MAX := Vector2(11.4, 8.5)

## Staircase origin: 6 m wide, 10 steps of 0.2 x 0.45 m, landing at y=2 against the back wall.
const STAIRS_POS := Vector3(0.0, 0.0, -5.85)
const LANDING_Y := 2.0
const STAIR_FOOT := Vector3(0.0, 0.0, -1.2)
const PORTAL_POS := Vector3(0.0, 2.0, -8.45)
## The arch is 4.2 m tall at full size; scaled down it stays under the 5 m walls.
const PORTAL_SCALE := 0.75

const KEY_COUNT := 8
const KEY_W := 0.55
const KEY_LEN := 1.8
const KEYS_CENTER := Vector3(8.8, 0.0, -3.4)
const KEY_HUES: Array[float] = [0.0, 0.08, 0.15, 0.33, 0.5, 0.6, 0.75, 0.88]

## Hung off to the sides: from the gameplay camera a chandelier hides the floor ~3 m behind
## it and reads as a wheel, so none hangs over the centre, the stairs or the keyboard.
const CHANDELIERS: Array[Vector3] = [
	Vector3(-9.3, 5.0, 6.0), Vector3(9.3, 5.0, 6.0), Vector3(-7.0, 5.0, -5.0), Vector3(6.5, 5.0, -5.5),
]
## Emission energy per kit emissive material (the imports come in at 1.0).
const EMIT_ENERGY: Dictionary[String, float] = {
	"EmitMoon": 1.1, "EmitFire": 3.0, "EmitCandle": 3.2, "EmitPortal": 2.4, "EmitPortalDeep": 1.5,
}
const FIRE_ENERGY := 3.2

# Local collision boxes of the furniture, pairs of (centre, size) in the piece's own frame.
const SOFA_BOXES: Array[Vector3] = [
	Vector3(0, 0.21, 0), Vector3(2.2, 0.42, 0.95),
	Vector3(0, 0.55, -0.36), Vector3(2.2, 1.1, 0.24),
	Vector3(-1.01, 0.39, 0), Vector3(0.18, 0.78, 0.95),
	Vector3(1.01, 0.39, 0), Vector3(0.18, 0.78, 0.95),
]
const SOFA_CUSHION: Array[Vector3] = [Vector3(0, 0.49, 0.1), Vector3(1.84, 0.14, 0.75)]
const ARMCHAIR_BOXES: Array[Vector3] = [
	Vector3(0, 0.21, 0), Vector3(1.0, 0.42, 1.0),
	Vector3(0, 0.57, -0.38), Vector3(1.0, 1.14, 0.24),
]
const ARMCHAIR_CUSHION: Array[Vector3] = [Vector3(0, 0.49, 0.11), Vector3(1.0, 0.14, 0.78)]
const TABLE_BOXES: Array[Vector3] = [Vector3(0, 0.38, 0), Vector3(0.62, 0.76, 0.62)]
const SHELF_BOXES: Array[Vector3] = [Vector3(0, 1.31, 0.025), Vector3(2.1, 2.62, 0.55)]
const PIANO_BOXES: Array[Vector3] = [
	Vector3(0.04, 0.5, -0.15), Vector3(1.64, 1.0, 1.9),
	Vector3(0, 0.41, 0.8), Vector3(1.32, 0.82, 0.4),
	Vector3(0, 0.27, 1.45), Vector3(0.54, 0.54, 0.54),
]
const FIREPLACE_BOXES: Array[Vector3] = [Vector3(0, 2.5, 0), Vector3(3.0, 5.0, 1.04)]
const CLOCK_BOXES: Array[Vector3] = [Vector3(0, 1.2, 0), Vector3(0.74, 2.4, 0.54)]
const ARMOUR_BOXES: Array[Vector3] = [Vector3(0, 1.05, 0), Vector3(0.8, 2.1, 0.68)]
const PLANT_BOXES: Array[Vector3] = [Vector3(0, 0.6, 0), Vector3(0.8, 1.2, 0.8)]
const CANDELABRA_BOXES: Array[Vector3] = [Vector3(0, 0.75, 0), Vector3(0.4, 1.5, 0.4)]
const PILLAR_BOXES: Array[Vector3] = [Vector3(0, 2.5, 0), Vector3(1.04, 5.0, 1.04)]
const PORTAL_BOXES: Array[Vector3] = [Vector3(0, 1.575, 0), Vector3(2.62, 3.15, 0.63)]

## Where bots like to hang out (get_bot_goal picks one, plus some jitter).
const POINTS_OF_INTEREST: Array[Vector3] = [
	Vector3(0.0, 2.0, -7.5),     # before the portal, on the landing
	Vector3(0.0, 0.0, 0.8),      # the gathering arc at the foot of the stairs
	Vector3(-8.3, 0.0, -3.0),    # fireside rug
	Vector3(-5.9, 0.56, -3.0),   # on the fireside sofa (bots hop up when blocked)
	Vector3(8.8, 0.0, -3.4),     # floor keyboard
	Vector3(10.9, 0.56, 1.0),    # window sofa
	Vector3(-5.0, 0.0, -7.6),    # grandfather clock
	Vector3(0.0, 0.0, 4.5),      # centre rug
	Vector3(-8.0, 0.0, 5.5),     # front left
	Vector3(8.0, 0.0, 5.5),      # front right
	Vector3(-4.5, 0.0, 2.0),
	Vector3(4.5, 0.0, 2.0),
]

## Upward speed (m/s) a cushion gives a blob that lands on it (a normal jump is ~7.4).
@export var cushion_bounce_speed: float = 9.5
## Cap on the bounce when a blob lands hard.
@export var cushion_bounce_max: float = 11.0
## Read by the bot brain: 0 = bots never chase or shove in the hall (no shoving scrum).
@export_range(0.0, 1.0) var bot_aggression_scale: float = 0.0

## The shared look rig when it was found, else null (the fallback $Look is used).
var shared_look: Node = null

var _cache: Dictionary[String, PackedScene] = {}
var _hall: Node3D = null
var _body: StaticBody3D = null
var _cushions: StaticBody3D = null
var _cushion_tops: Array[Vector3] = []
var _emit: Dictionary[String, StandardMaterial3D] = {}
var _pendulums: Array[Node3D] = []
var _fire_lights: Array[OmniLight3D] = []
var _candle_lights: Array[OmniLight3D] = []
var _candle_energy: PackedFloat32Array = []
var _portal_light: OmniLight3D = null
var _key_mats: Array[StandardMaterial3D] = []
var _key_glow: PackedFloat32Array = []
var _key_down: Array[bool] = []
var _portal_heat: float = 0.0
var _portal_phase: float = 0.0
var _portal_crowd: int = 0
var _time: float = 0.0
var _tracked: Dictionary[int, bool] = {}
var _bot_plans: Dictionary[int, Vector3] = {}
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20260930
	_hall = _group("Hall", self)
	_body = _static_body("HallCollision")
	_cushions = _static_body("Cushions")
	_build_shell()
	_build_stairs()
	_build_furniture()
	_build_decor()
	_build_piano_keys()
	_collect_emissives()
	_build_lights()
	_apply_look()


# --- Minigame ------------------------------------------------------------------------------

func _setup(p_players: Array[Player]) -> void:
	for p in p_players:
		_track(p)


## Bots mill about between the points of interest; a bot bound for the landing is sent to
## the foot of the stairs first so it walks up instead of into the side of the staircase.
func get_bot_goal(player: Player) -> Vector3:
	if player == null:
		return STAIR_FOOT
	var pos := player.global_position
	var plan: Vector3 = _bot_plans.get(player.slot, Vector3.INF)
	if plan == Vector3.INF or _flat(plan - pos).length() < 1.3 or _rng.randf() < 0.25:
		plan = _new_plan(pos)
		_bot_plans[player.slot] = plan
	if plan.y > 1.0 and pos.y < 1.0 and _flat(pos - STAIR_FOOT).length() > 1.5:
		return STAIR_FOOT
	return plan


## Inside the hall, off the walls.
func is_safe(pos: Vector3) -> bool:
	return pos.y > -1.0 and pos.x > SAFE_MIN.x and pos.x < SAFE_MAX.x and pos.z > SAFE_MIN.y and pos.z < SAFE_MAX.y


# --- Public helpers (tests, UI) ----------------------------------------------------------------

## Players standing before the portal on the landing right now.
func get_portal_crowd() -> int:
	return _portal_crowd


## 0..1, how excited the portal is (follows the crowd, smoothed).
func get_portal_heat() -> float:
	return _portal_heat


## World position of the centre of key `index` of the floor keyboard.
func get_key_position(index: int) -> Vector3:
	var x0 := KEYS_CENTER.x - KEY_W * KEY_COUNT * 0.5
	return Vector3(x0 + KEY_W * (index + 0.5), 0.0, KEYS_CENTER.z)


## True while someone stands on key `index` (or it is still fading out).
func is_key_lit(index: int) -> bool:
	return index >= 0 and index < _key_glow.size() and _key_glow[index] > 0.0


## World centres of the tops of the bouncy cushions.
func get_cushion_tops() -> Array[Vector3]:
	return _cushion_tops.duplicate()


# --- Per frame ---------------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	for p in _live_players():
		_track(p)
	if not multiplayer.is_server():
		return
	for p in _live_players():
		if p.global_position.y < KILL_Y:
			var points := get_spawn_points()
			if points.is_empty():
				return
			var xform := points[maxi(p.slot, 0) % points.size()]
			xform.origin += Vector3.UP * 0.3
			p.respawn_at(xform)


func _process(delta: float) -> void:
	_time += delta
	for pendulum in _pendulums:
		pendulum.rotation.z = 0.2 * sin(_time * PI)
	var flicker := 1.0 + 0.16 * sin(_time * 9.3) + 0.1 * sin(_time * 23.1 + 1.3) + 0.08 * sin(_time * 4.1 + 0.4)
	for l in _fire_lights:
		l.light_energy = FIRE_ENERGY * flicker
	if _emit.has("EmitFire"):
		_emit["EmitFire"].emission_energy_multiplier = EMIT_ENERGY["EmitFire"] * flicker
	for i in _candle_lights.size():
		_candle_lights[i].light_energy = _candle_energy[i] * (1.0 + 0.05 * sin(_time * 7.0 + i * 1.7))
	var live := _live_players()
	_update_portal(delta, live)
	_update_keys(delta, live)


func _update_portal(delta: float, live: Array[Player]) -> void:
	var crowd := 0
	for p in live:
		var q := p.global_position
		if q.y > LANDING_Y - 0.6 and absf(q.x) < 3.0 and q.z < -6.3:
			crowd += 1
	_portal_crowd = crowd
	_portal_heat = move_toward(_portal_heat, clampf(crowd / 3.0, 0.0, 1.0), delta * 1.5)
	_portal_phase += delta * (1.8 + 6.0 * _portal_heat)
	var pulse := 0.5 + 0.5 * sin(_portal_phase)
	if _emit.has("EmitPortal"):
		_emit["EmitPortal"].emission_energy_multiplier = 1.6 + 1.4 * pulse + 4.0 * _portal_heat
	if _emit.has("EmitPortalDeep"):
		_emit["EmitPortalDeep"].emission_energy_multiplier = 0.9 + 1.2 * (1.0 - pulse) + 3.0 * _portal_heat
	if _portal_light:
		_portal_light.light_energy = 1.4 + 1.2 * pulse + 4.0 * _portal_heat


func _update_keys(delta: float, live: Array[Player]) -> void:
	for i in KEY_COUNT:
		var c := get_key_position(i)
		var down := false
		for p in live:
			var q := p.global_position
			if q.y < 0.35 and absf(q.x - c.x) <= KEY_W * 0.5 and absf(q.z - c.z) <= KEY_LEN * 0.5 + 0.1:
				down = true
				break
		if down and not _key_down[i]:
			piano_key_pressed.emit(i)
		_key_down[i] = down
		_key_glow[i] = 1.0 if down else maxf(_key_glow[i] - delta * 2.5, 0.0)
		_key_mats[i].emission_energy_multiplier = 2.6 * _key_glow[i]


# --- Cushions ------------------------------------------------------------------------------------

func _track(p: Player) -> void:
	if p == null or _tracked.has(p.get_instance_id()):
		return
	_tracked[p.get_instance_id()] = true
	p.landed.connect(_on_player_landed.bind(p))


func _on_player_landed(impact_speed: float, p: Player) -> void:
	if not is_instance_valid(p) or not p.alive or not p.is_authority():
		return
	for i in p.get_slide_collision_count():
		var hit := p.get_slide_collision(i)
		if hit.get_collider() == _cushions and hit.get_normal().y > 0.6:
			p.velocity.y = clampf(maxf(cushion_bounce_speed, impact_speed * 0.8), 0.0, cushion_bounce_max)
			cushion_bounced.emit(p.slot)
			return


# --- Building: shell -------------------------------------------------------------------------

func _build_shell() -> void:
	var floors := _group("Floor")
	for ix in 6:
		for iz in 5:
			# 4 rows cover z -9..7; the 5th overlaps the 4th by 2 m. The checker phase matches
			# (2 m = 4 squares), so the coplanar overlap renders identically; a lowered row
			# would show the 4th row's slab edge as a dark seam.
			var pos := Vector3(-10.0 + 4.0 * ix, 0.0, minf(-7.0 + 4.0 * iz, 7.0))
			_place("floor_tile_4x4", pos, 0.0, floors)

	var walls := _group("Walls")
	var back: Array[String] = ["wall_window", "wall_4m", "wall_4m", "wall_4m", "wall_door", "wall_window"]
	for i in back.size():
		_place(back[i], Vector3(-10.0 + 4.0 * i, 0.0, BACK_Z), 0.0, walls)
	# Side walls: 4 pieces cover z -9..7, the 5th (same piece as the 4th) overlaps it to reach the front.
	var side_z: Array[float] = [-7.0, -3.0, 1.0, 5.0, 7.0]
	var left: Array[String] = ["wall_window", "wall_4m", "wall_window", "wall_4m", "wall_4m"]
	var right: Array[String] = ["wall_4m", "wall_window", "wall_window", "wall_4m", "wall_4m"]
	for i in side_z.size():
		_place(left[i], Vector3(-HALF_X, 0.0, side_z[i]), 90.0, walls)
		_place(right[i], Vector3(HALF_X, 0.0, side_z[i]), -90.0, walls)
	for sx: float in [-1.0, 1.0]:
		_place("wall_corner", Vector3(sx * HALF_X, 0.0, BACK_Z), 0.0, walls)
		_place("wall_corner", Vector3(sx * HALF_X, 0.0, FRONT_Z), 0.0, walls)

	# The open front: a low dark plinth along the edge (the barrier above it is invisible).
	var plinth := MeshInstance3D.new()
	plinth.name = "FrontPlinth"
	var pm := BoxMesh.new()
	pm.size = Vector3(2.0 * HALF_X, 0.3, 0.3)
	pm.material = _flat_material(Color("#5b3a29"), 0.7)
	plinth.mesh = pm
	plinth.position = Vector3(0.0, 0.15, FRONT_Z)
	_hall.add_child(plinth)
	var trim := MeshInstance3D.new()
	trim.name = "FrontTrim"
	var tm := BoxMesh.new()
	tm.size = Vector3(2.0 * HALF_X, 0.04, 0.34)
	var gold := _flat_material(Color("#e8b33a"), 0.35)
	gold.metallic = 0.6
	tm.material = gold
	trim.mesh = tm
	trim.position = Vector3(0.0, 0.3, FRONT_Z)
	_hall.add_child(trim)

	var w := 2.0 * HALF_X + 0.6
	var d := FRONT_Z - BACK_Z + 0.6
	_box(_body, Transform3D(Basis(), Vector3(0.0, -0.25, 0.0)), Vector3(w, 0.5, d))
	_box(_body, Transform3D(Basis(), Vector3(0.0, BARRIER_H * 0.5, BACK_Z)), Vector3(w, BARRIER_H, 0.3))
	_box(_body, Transform3D(Basis(), Vector3(0.0, BARRIER_H * 0.5, FRONT_Z)), Vector3(w, BARRIER_H, 0.3))
	for sx: float in [-1.0, 1.0]:
		_box(_body, Transform3D(Basis(), Vector3(sx * HALF_X, BARRIER_H * 0.5, 0.0)), Vector3(0.3, BARRIER_H, d))


# --- Building: staircase and portal --------------------------------------------------------------

func _build_stairs() -> void:
	_place("grand_staircase", STAIRS_POS)
	var xf := Transform3D(Basis(), STAIRS_POS)
	# Solid block under a smooth ramp through the middle of every step (rise 0.2, run 0.45), so
	# blobs walk up without hopping: y = (3.225 - z) * 0.444 locally, reaching the landing
	# (y = 2) at z = -1.275; the landing runs to the wall at z = -3.
	var prism := ConvexPolygonShape3D.new()
	var pts := PackedVector3Array()
	for x: float in [-3.0, 3.0]:
		pts.append_array([Vector3(x, -0.2, 3.675), Vector3(x, LANDING_Y, -1.275), Vector3(x, LANDING_Y, -3.0), Vector3(x, -0.2, -3.0)])
	prism.points = pts
	_shape(_body, xf, prism)
	# Banisters: a slab along each side of the ramp, and one along each side of the landing.
	var slope := atan2(2.0, 4.5)
	var normal := Vector3(0.0, cos(slope), sin(slope))
	for sx: float in [-1.0, 1.0]:
		var c := Vector3(sx * 2.87, 1.0, 0.975) + normal * 0.35
		_box(_body, xf * Transform3D(Basis(Vector3.RIGHT, slope), c), Vector3(0.2, 1.5, 5.2))
		_box(_body, xf * Transform3D(Basis(), Vector3(sx * 2.87, LANDING_Y + 0.55, -2.15)), Vector3(0.2, 1.1, 1.8))

	_furnish("minigame_door_arch", PORTAL_POS, 0.0, PORTAL_BOXES, [], PORTAL_SCALE)
	for sx: float in [-1.0, 1.0]:
		_furnish("pillar", Vector3(sx * 3.65, 0.0, -8.3), 0.0, PILLAR_BOXES)
		_furnish("suit_of_armour", Vector3(sx * 3.9, 0.0, -2.2), 0.0, ARMOUR_BOXES)
	_place("portrait_frame_a", Vector3(-2.2, LANDING_Y + 1.15, -8.83))
	_place("portrait_frame_b", Vector3(2.2, LANDING_Y + 1.15, -8.83))


# --- Building: furniture ---------------------------------------------------------------------

func _build_furniture() -> void:
	# Fireplace corner (left wall): sofa facing the fire, armchairs either side, rug.
	_furnish("fireplace", Vector3(-11.35, 0.0, -3.0), 90.0, FIREPLACE_BOXES)
	_place("portrait_frame_a", Vector3(-11.23, 2.55, -3.0), 90.0)
	_place("rug_long", Vector3(-8.4, 0.005, -3.0), 90.0)
	_furnish("sofa", Vector3(-5.9, 0.0, -3.0), -90.0, SOFA_BOXES, SOFA_CUSHION)
	_furnish("armchair", Vector3(-8.6, 0.0, -5.3), -17.0, ARMCHAIR_BOXES, ARMCHAIR_CUSHION)
	_furnish("armchair", Vector3(-8.6, 0.0, -0.7), -163.0, ARMCHAIR_BOXES, ARMCHAIR_CUSHION)
	_furnish("side_table", Vector3(-5.9, 0.0, -4.75), 0.0, TABLE_BOXES)
	_furnish("side_table", Vector3(-5.9, 0.0, -1.25), 0.0, TABLE_BOXES)
	_furnish("candelabra", Vector3(-11.45, 0.0, -5.0), 90.0, CANDELABRA_BOXES)
	_furnish("candelabra", Vector3(-11.45, 0.0, -1.0), 90.0, CANDELABRA_BOXES)
	# Back left: bookshelf, grandfather clock, plant.
	_furnish("bookshelf", Vector3(-8.2, 0.0, -8.55), 0.0, SHELF_BOXES)
	_furnish("grandfather_clock", Vector3(-5.3, 0.0, -8.55), 0.0, CLOCK_BOXES)
	_furnish("potted_plant", Vector3(-11.1, 0.0, -8.1), 0.0, PLANT_BOXES)
	# Piano corner (back right): grand piano with the floor keyboard in front of it.
	_furnish("piano", Vector3(8.8, 0.0, -6.6), 0.0, PIANO_BOXES)
	_furnish("candelabra", Vector3(4.75, 0.0, -8.5), 0.0, CANDELABRA_BOXES)
	_furnish("candelabra", Vector3(7.3, 0.0, -8.5), 0.0, CANDELABRA_BOXES)
	_furnish("potted_plant", Vector3(11.1, 0.0, -8.1), 0.0, PLANT_BOXES)
	# Right wall: a sofa under the windows, a bookshelf further forward.
	_furnish("sofa", Vector3(11.1, 0.0, -1.0), -90.0, SOFA_BOXES, SOFA_CUSHION)
	_furnish("side_table", Vector3(11.2, 0.0, 0.7), 0.0, TABLE_BOXES)
	_furnish("bookshelf", Vector3(11.6, 0.0, 4.6), -90.0, SHELF_BOXES)
	# Left front: bookshelf and a reading armchair.
	_furnish("bookshelf", Vector3(-11.6, 0.0, 4.6), 90.0, SHELF_BOXES)
	_furnish("armchair", Vector3(-9.9, 0.0, 6.4), 135.0, ARMCHAIR_BOXES, ARMCHAIR_CUSHION)
	_furnish("potted_plant", Vector3(-11.1, 0.0, 7.9), 0.0, PLANT_BOXES)
	_furnish("potted_plant", Vector3(11.1, 0.0, 7.9), 0.0, PLANT_BOXES)


func _build_decor() -> void:
	_place("rug_long", Vector3(0.0, 0.005, 3.4))
	_place("portrait_frame_c", Vector3(-6.0, 2.9, -8.83))
	_place("portrait_frame_c", Vector3(11.83, 2.4, -6.6), -90.0)
	_place("portrait_frame_b", Vector3(-11.83, 2.3, 4.6 + 2.2), 90.0)
	_place("portrait_frame_a", Vector3(11.83, 2.3, 4.6 - 2.2), -90.0)
	for pos in CHANDELIERS:
		var chandelier := _place("chandelier", pos)
		# Under the moon their shadows land on the floor as big cobweb rings.
		for n: Node in chandelier.find_children("*", "GeometryInstance3D", true, false):
			(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_piano_keys() -> void:
	var root := _group("FloorKeyboard")
	var frame := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(KEY_W * KEY_COUNT + 0.24, 0.02, KEY_LEN + 0.24)
	fm.material = _flat_material(Color("#2e2a33"), 0.5)
	frame.mesh = fm
	frame.position = KEYS_CENTER + Vector3(0.0, 0.01, 0.0)
	root.add_child(frame)
	for i in KEY_COUNT:
		var key := MeshInstance3D.new()
		key.name = "Key%d" % i
		var km := BoxMesh.new()
		km.size = Vector3(KEY_W - 0.05, 0.035, KEY_LEN)
		key.mesh = km
		var mat := _flat_material(Color("#f3e6c8"), 0.45)
		mat.emission_enabled = true
		mat.emission = Color.from_hsv(KEY_HUES[i], 0.6, 1.0)
		mat.emission_energy_multiplier = 0.0
		key.material_override = mat
		key.position = get_key_position(i) + Vector3(0.0, 0.0175, 0.0)
		root.add_child(key)
		_key_mats.append(mat)
		_key_glow.append(0.0)
		_key_down.append(false)
	var black := _flat_material(Color("#1c1a20"), 0.4)
	for i: int in [0, 1, 3, 4, 5]:
		var bk := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.28, 0.045, KEY_LEN * 0.55)
		bm.material = black
		bk.mesh = bm
		bk.position = get_key_position(i) + Vector3(KEY_W * 0.5, 0.0225, -KEY_LEN * 0.225)
		root.add_child(bk)


# --- Building: light and look ----------------------------------------------------------------

func _collect_emissives() -> void:
	for n: Node in _hall.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.name == "Pendulum":
			_pendulums.append(mi)
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if mat == null or not mat.resource_name.begins_with("Emit"):
				continue
			if not _emit.has(mat.resource_name):
				# Own copies: the imported materials are shared with every other user of the kit.
				var copy := mat.duplicate() as StandardMaterial3D
				copy.emission_enabled = true
				copy.emission_energy_multiplier = EMIT_ENERGY.get(mat.resource_name, 1.5)
				_emit[mat.resource_name] = copy
			mi.set_surface_override_material(s, _emit[mat.resource_name])


func _build_lights() -> void:
	var lights := _group("Lights", self)
	_fire_lights.append(_omni(lights, Vector3(-10.3, 0.9, -3.0), Color(1.0, 0.52, 0.2), FIRE_ENERGY, 9.0, true))
	for pos in CHANDELIERS:
		_add_candle_light(lights, pos + Vector3(0.0, -1.45, 0.0), Color(1.0, 0.78, 0.5), 2.2, 11.0)
	for c: Node in _hall.get_children():
		if c.name.begins_with("candelabra"):
			var n3 := c as Node3D
			_add_candle_light(lights, n3.position + Vector3(0.0, 1.3, 0.0) + n3.basis.z * 0.25, Color(1.0, 0.75, 0.45), 0.9, 4.0)
	_portal_light = _omni(lights, PORTAL_POS + Vector3(0.0, 1.3, 0.9), Color(0.35, 1.0, 0.88), 2.0, 7.5, false)
	# Moonlight through the windows on the moon's side (back and left walls).
	_moon_spot(lights, Vector3(-10.0, 3.8, BACK_Z + 0.6), Vector3(-8.8, 0.0, -4.5))
	_moon_spot(lights, Vector3(10.0, 3.8, BACK_Z + 0.6), Vector3(10.5, 0.0, -4.5))
	_moon_spot(lights, Vector3(-HALF_X + 0.6, 3.8, -7.0), Vector3(-7.5, 0.0, -5.8))
	_moon_spot(lights, Vector3(-HALF_X + 0.6, 3.8, 1.0), Vector3(-7.2, 0.0, 2.4))


func _apply_look() -> void:
	if not ResourceLoader.exists(SHARED_LOOK_PATH):
		return
	var scene := load(SHARED_LOOK_PATH) as PackedScene
	if scene == null:
		return
	var look := scene.instantiate()
	_set_preset(look, SHARED_LOOK_PRESET)
	var fallback := get_node_or_null(^"Look")
	if fallback:
		remove_child(fallback)
		fallback.queue_free()
	look.name = "SharedLook"
	add_child(look)
	shared_look = look


## Sets `preset` on the look rig whether it is an exported enum (int) or a String/StringName.
static func _set_preset(look: Object, preset: String) -> void:
	for prop: Dictionary in look.get_property_list():
		if prop["name"] != "preset":
			continue
		if prop["type"] == TYPE_INT:
			var names := (prop["hint_string"] as String).split(",")
			for i in names.size():
				var parts := names[i].split(":")
				if parts[0].strip_edges().to_upper().replace(" ", "_") == preset:
					look.set(&"preset", parts[1].to_int() if parts.size() > 1 else i)
					return
			push_warning("lobby: look rig has no preset %s" % preset)
		else:
			look.set(&"preset", preset)
		return
	if look.has_method(&"apply_preset"):
		look.call(&"apply_preset", preset)


# --- Helpers ---------------------------------------------------------------------------------

func _group(group_name: String, parent: Node = null) -> Node3D:
	var n := Node3D.new()
	n.name = group_name
	(parent if parent != null else _hall).add_child(n)
	return n


func _static_body(body_name: String) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = body_name
	b.collision_layer = 1
	b.collision_mask = 0
	add_child(b)
	return b


func _place(piece: String, pos: Vector3, yaw_deg: float = 0.0, parent: Node = null, scale_by: float = 1.0) -> Node3D:
	if not _cache.has(piece):
		var scene := load(ENV_DIR + piece + ".glb") as PackedScene
		if scene == null:
			push_error("lobby: missing kit piece %s" % piece)
			return null
		_cache[piece] = scene
	var node := _cache[piece].instantiate() as Node3D
	node.name = piece
	node.position = pos
	node.rotation_degrees.y = yaw_deg
	node.scale = Vector3.ONE * scale_by
	(parent if parent != null else _hall).add_child(node, true)
	return node


## Places a kit piece with its collision boxes (and bouncy cushion boxes) in its own frame.
func _furnish(piece: String, pos: Vector3, yaw_deg: float, boxes: Array[Vector3], cushion: Array[Vector3] = [], scale_by: float = 1.0) -> Node3D:
	var node := _place(piece, pos, yaw_deg, null, scale_by)
	var xf := Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), pos)
	for i in range(0, boxes.size() - 1, 2):
		_box(_body, xf * Transform3D(Basis(), boxes[i]), boxes[i + 1])
	for i in range(0, cushion.size() - 1, 2):
		_box(_cushions, xf * Transform3D(Basis(), cushion[i]), cushion[i + 1])
		_cushion_tops.append(xf * (cushion[i] + Vector3(0.0, cushion[i + 1].y * 0.5, 0.0)))
	return node


func _box(body: StaticBody3D, xform: Transform3D, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	_shape(body, xform, shape)


func _shape(body: StaticBody3D, xform: Transform3D, shape: Shape3D) -> void:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = xform
	body.add_child(cs)


func _omni(parent: Node, pos: Vector3, color: Color, energy: float, range_m: float, shadows: bool) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = range_m
	l.omni_attenuation = 1.2
	l.shadow_enabled = shadows
	parent.add_child(l)
	return l


func _add_candle_light(parent: Node, pos: Vector3, color: Color, energy: float, range_m: float) -> void:
	_candle_lights.append(_omni(parent, pos, color, energy, range_m, false))
	_candle_energy.append(energy)


func _moon_spot(parent: Node, from: Vector3, to: Vector3) -> void:
	var s := SpotLight3D.new()
	s.light_color = Color(0.6, 0.72, 1.0)
	s.light_energy = 3.0
	s.spot_range = 9.0
	s.spot_angle = 24.0
	s.spot_attenuation = 0.6
	s.shadow_enabled = false
	parent.add_child(s)
	s.look_at_from_position(from, to, Vector3.UP)


func _flat_material(color: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m


func _new_plan(pos: Vector3) -> Vector3:
	var goal: Vector3
	if _rng.randf() < 0.3 and pos.y < 1.0:
		goal = pos + Vector3(_rng.randf_range(-2.5, 2.5), 0.0, _rng.randf_range(-2.5, 2.5))
		goal.y = 0.0
	else:
		goal = POINTS_OF_INTEREST[_rng.randi() % POINTS_OF_INTEREST.size()]
		var jitter := 0.4 if goal.y > 0.0 else 1.3
		goal += Vector3(_rng.randf_range(-jitter, jitter), 0.0, _rng.randf_range(-jitter, jitter))
	goal.x = clampf(goal.x, SAFE_MIN.x + 0.3, SAFE_MAX.x - 0.3)
	goal.z = clampf(goal.z, SAFE_MIN.y + 0.3, SAFE_MAX.y - 0.3)
	return goal


func _live_players() -> Array[Player]:
	var out: Array[Player] = []
	for p in players:
		if is_instance_valid(p) and p.is_inside_tree() and p.alive:
			out.append(p)
	return out


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)
