extends Node3D
## One coin on the vault floor (or on its way there), on every peer. Owner: coin_scramble.
## Pure presentation plus a deterministic path: `current_pos()` depends only on the launch
## data and `age`, so the host's pickup checks and every peer's visuals agree. The minigame
## decides everything else (who collects it, when it goes away).
##
## Paths: FALL (rain: drops from `start` straight down under gravity) and ARC (a dropped coin:
## hops from the victim to `land` in `flight` seconds). Then it rests: spins and bobs.

enum Path { FALL, ARC }

const COIN_SCENE: PackedScene = preload("res://assets/models/props/coin.glb")
const BIG_SCENE: PackedScene = preload("res://assets/models/props/coin_big.glb")

## Rain fall acceleration (m/s^2).
const FALL_GRAVITY := 16.0
## Peak height of a drop hop above the straight line (m).
const ARC_HEIGHT := 1.3
## Models are scaled up so coins read from the arena camera.
const MODEL_SCALE := 1.85
## Coin radius (m, after scaling) for value 1 / a big coin.
const RADIUS := 0.175 * MODEL_SCALE
const RADIUS_BIG := 0.3 * MODEL_SCALE
## Resting centre height of a coin of value 1 / a big coin (m above the floor).
const REST_Y := RADIUS + 0.14
const REST_Y_BIG := RADIUS_BIG + 0.14
## Idle spin (rad/s) and bob (m, Hz).
const SPIN_SPEED := 2.6
const BOB_AMPLITUDE := 0.06
const BOB_FREQ := 0.9
## Emission multiplier on the coin materials: a warm glow that stays readable.
const GLOW_ENERGY := 2.4

## Toon + glow materials per model, built once and shared by every coin.
static var _materials: Dictionary = {}
## The additive gold pool of light under a coin (marks where a falling coin will land).
static var _pool_mesh: PlaneMesh
static var _pool_material: StandardMaterial3D

var id: int = -1
var value: int = 1
var path: Path = Path.FALL
var start: Vector3 = Vector3.ZERO
## Resting centre of the coin.
var land: Vector3 = Vector3.ZERO
## Seconds from launch to rest.
var flight: float = 0.0
## Seconds since launch (advanced in _physics_process, times `time_scale`).
var age: float = 0.0
var time_scale: float = 1.0
## Nobody can collect it before this age.
var grab_delay: float = 0.0
## This slot (the player who dropped it) cannot collect it before `victim_delay`.
var no_grab_slot: int = -1
var victim_delay: float = 0.0

var _model: Node3D
var _pool: MeshInstance3D
var _spin: float = 0.0
var _landed_shown: bool = false
var _squash: float = 0.0


## Rain: falls from `from` down to the floor under (from.x, from.z).
func setup_fall(coin_id: int, coin_value: int, from: Vector3) -> void:
	id = coin_id
	value = coin_value
	path = Path.FALL
	start = from
	land = Vector3(from.x, rest_height(coin_value), from.z)
	flight = sqrt(2.0 * maxf(start.y - land.y, 0.0) / FALL_GRAVITY)


## Drop: hops from `from` to the floor at (to.x, to.z) in `seconds`.
func setup_arc(coin_id: int, coin_value: int, from: Vector3, to: Vector3, seconds: float) -> void:
	id = coin_id
	value = coin_value
	path = Path.ARC
	start = from
	land = Vector3(to.x, rest_height(coin_value), to.z)
	flight = maxf(seconds, 0.01)


static func rest_height(coin_value: int) -> float:
	return REST_Y_BIG if coin_value > 1 else REST_Y


## Where the coin is at `at_age` (defaults to now). Deterministic.
func current_pos(at_age: float = -1.0) -> Vector3:
	var a := age if at_age < 0.0 else at_age
	if a >= flight:
		return land
	match path:
		Path.FALL:
			return Vector3(land.x, maxf(land.y, start.y - 0.5 * FALL_GRAVITY * a * a), land.z)
		_:
			var k := a / flight
			var p := start.lerp(land, k)
			p.y += ARC_HEIGHT * 4.0 * k * (1.0 - k)
			return p


func has_landed() -> bool:
	return age >= flight


## True when `slot` may collect it now.
func can_grab(slot: int) -> bool:
	if age < grab_delay:
		return false
	return not (slot == no_grab_slot and age < victim_delay)


func _ready() -> void:
	var scene := BIG_SCENE if value > 1 else COIN_SCENE
	_model = scene.instantiate() as Node3D
	_model.scale = Vector3.ONE * MODEL_SCALE
	add_child(_model)
	_apply_materials(_model, scene.resource_path)
	_pool = MeshInstance3D.new()
	_pool.mesh = _get_pool_mesh()
	_pool.material_override = _pool_material
	_pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pool.top_level = true
	add_child(_pool)
	_pool.global_position = Vector3(land.x, 0.02, land.z)
	_update_pool()
	_spin = float(id) * 1.37
	position = current_pos()
	_model.rotation.y = _spin


func _physics_process(delta: float) -> void:
	age += delta * time_scale
	var p := current_pos()
	if has_landed():
		if not _landed_shown:
			_landed_shown = true
			_squash = 1.0
		p.y += sin(age * TAU * BOB_FREQ + float(id)) * BOB_AMPLITUDE
	position = p
	_update_pool()


## The pool grows in as the coin comes down and breathes gently once it rests.
func _update_pool() -> void:
	if _pool == null:
		return
	var size := (RADIUS_BIG if value > 1 else RADIUS) * 4.2
	var k := 1.0
	if not has_landed():
		k = lerpf(0.35, 1.0, clampf(age / maxf(flight, 0.01), 0.0, 1.0))
	else:
		k = 1.0 + 0.08 * sin(age * TAU * BOB_FREQ + float(id))
	_pool.scale = Vector3(size * k, 1.0, size * k)


static func _get_pool_mesh() -> PlaneMesh:
	if _pool_mesh == null:
		_pool_mesh = PlaneMesh.new()
		_pool_mesh.size = Vector2.ONE
		var g := Gradient.new()
		g.set_color(0, Color(1.0, 0.78, 0.25, 0.85))
		g.set_color(1, Color(1.0, 0.6, 0.1, 0.0))
		g.add_point(0.45, Color(1.0, 0.72, 0.2, 0.35))
		var tex := GradientTexture2D.new()
		tex.gradient = g
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(1.0, 0.5)
		tex.width = 64
		tex.height = 64
		_pool_material = StandardMaterial3D.new()
		_pool_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_pool_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_pool_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_pool_material.albedo_texture = tex
		_pool_material.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
		_pool_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return _pool_mesh


func _process(delta: float) -> void:
	if _model == null:
		return
	var speed := SPIN_SPEED if has_landed() else SPIN_SPEED * 3.0
	_spin = wrapf(_spin + speed * delta, 0.0, TAU)
	_model.rotation.y = _spin
	if _squash > 0.0:
		_squash = maxf(0.0, _squash - delta * 5.0)
		var s := sin(_squash * PI) * 0.25
		_model.scale = Vector3(1.0 + s, 1.0 - s, 1.0 + s) * MODEL_SCALE


static func _apply_materials(model: Node3D, key: String) -> void:
	if not _materials.has(key):
		var built: Array = []
		Look.apply_toon(model)
		for mi: MeshInstance3D in _meshes(model):
			var mats: Array[Material] = []
			for s in mi.mesh.get_surface_count():
				var m := mi.get_active_material(s)
				var bm := m as BaseMaterial3D
				if bm and bm.emission_enabled:
					bm = bm.duplicate() as BaseMaterial3D
					bm.resource_name = m.resource_name
					bm.emission_energy_multiplier = GLOW_ENERGY
					m = bm
				mats.append(m)
			built.append(mats)
		_materials[key] = built
	var cached: Array = _materials[key]
	var meshes := _meshes(model)
	for i in mini(meshes.size(), cached.size()):
		var mats: Array = cached[i]
		for s in mats.size():
			meshes[i].set_surface_override_material(s, mats[s])


static func _meshes(model: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if model is MeshInstance3D:
		out.append(model as MeshInstance3D)
	for n in model.find_children("*", "MeshInstance3D", true, false):
		out.append(n as MeshInstance3D)
	return out
