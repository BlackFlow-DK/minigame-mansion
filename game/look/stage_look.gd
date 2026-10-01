class_name StageLook
extends Node3D
## The house look in one node: sky gradient, ambient, tonemap, glow, SSAO, fog, a key sun
## with soft shadows sized for a 20-30 m arena, and a shadowless fill. Instance
## `res://look/stage_look.tscn` in a minigame or the lobby, pick `preset`, and delete the
## scene's own WorldEnvironment and sun (only one WorldEnvironment may be active).
## `Look.set_quality()` re-applies every StageLook: HIGH everything; MEDIUM drops SSAO and
## lightens the shadows; LOW also drops glow and fog and keeps one low-res sun shadow split. Each
## apply also sets the resolution / AA of the viewport the look renders into (Look.apply_viewport).
## Owner: look and effects.

enum Preset { WARM_HALL, BRIGHT_DAY, LAVA_CAVE, NIGHT_PARTY }

## The mood. Changing it at runtime re-applies at once.
@export var preset: Preset = Preset.WARM_HALL:
	set(value):
		preset = value
		if is_node_ready():
			apply()
## Turns the key and fill lights around Y (degrees) to suit the arena's camera.
@export var light_yaw: float = 0.0:
	set(value):
		light_yaw = value
		if is_node_ready():
			apply()
## Distance from the camera that still gets sun shadows.
@export var shadow_distance: float = 48.0

## Preset tables (sRGB colours).
const PRESETS := {
	Preset.WARM_HALL: {
		"sky_top": Color(0.30, 0.19, 0.30), "sky_horizon": Color(0.80, 0.56, 0.42),
		"ground_horizon": Color(0.62, 0.41, 0.30), "ground_bottom": Color(0.24, 0.15, 0.13),
		"ambient_energy": 0.75,
		"key_color": Color(1.0, 0.88, 0.72), "key_energy": 1.55, "key_pitch": -52.0, "key_yaw": 35.0,
		"fill_color": Color(0.62, 0.55, 0.85), "fill_energy": 0.35, "fill_pitch": -25.0, "fill_yaw": -150.0,
		"glow": 0.55, "fog_color": Color(0.55, 0.36, 0.30), "fog_density": 0.006,
		"exposure": 1.0, "saturation": 1.1, "contrast": 1.05,
	},
	Preset.BRIGHT_DAY: {
		"sky_top": Color(0.33, 0.60, 0.92), "sky_horizon": Color(0.80, 0.90, 0.97),
		"ground_horizon": Color(0.75, 0.82, 0.78), "ground_bottom": Color(0.35, 0.45, 0.38),
		"ambient_energy": 0.7,
		"key_color": Color(1.0, 0.95, 0.86), "key_energy": 1.45, "key_pitch": -58.0, "key_yaw": 30.0,
		"fill_color": Color(0.60, 0.75, 1.0), "fill_energy": 0.3, "fill_pitch": -30.0, "fill_yaw": -150.0,
		"glow": 0.4, "fog_color": Color(0.75, 0.86, 0.96), "fog_density": 0.004,
		"exposure": 1.0, "saturation": 1.12, "contrast": 1.04,
	},
	Preset.LAVA_CAVE: {
		"sky_top": Color(0.10, 0.07, 0.10), "sky_horizon": Color(0.42, 0.13, 0.08),
		"ground_horizon": Color(0.45, 0.14, 0.07), "ground_bottom": Color(0.12, 0.05, 0.05),
		"ambient_energy": 0.55,
		"key_color": Color(1.0, 0.80, 0.62), "key_energy": 1.25, "key_pitch": -60.0, "key_yaw": 20.0,
		# fill from below: lava light on the undersides
		"fill_color": Color(1.0, 0.42, 0.14), "fill_energy": 0.55, "fill_pitch": 35.0, "fill_yaw": -160.0,
		"glow": 0.6, "fog_color": Color(0.35, 0.10, 0.06), "fog_density": 0.012,
		"exposure": 1.0, "saturation": 1.08, "contrast": 1.08,
	},
	Preset.NIGHT_PARTY: {
		"sky_top": Color(0.07, 0.06, 0.17), "sky_horizon": Color(0.36, 0.20, 0.42),
		"ground_horizon": Color(0.30, 0.17, 0.36), "ground_bottom": Color(0.07, 0.05, 0.12),
		"ambient_energy": 0.7,
		"key_color": Color(0.72, 0.76, 1.0), "key_energy": 1.1, "key_pitch": -55.0, "key_yaw": -30.0,
		"fill_color": Color(1.0, 0.45, 0.72), "fill_energy": 0.6, "fill_pitch": -20.0, "fill_yaw": 140.0,
		"glow": 0.9, "fog_color": Color(0.20, 0.12, 0.30), "fog_density": 0.01,
		"exposure": 1.1, "saturation": 1.15, "contrast": 1.06,
	},
}

@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var key_light: DirectionalLight3D = $KeyLight
@onready var fill_light: DirectionalLight3D = $FillLight


func _ready() -> void:
	add_to_group(Look.STAGE_GROUP)
	apply()


## Rebuilds the environment and lights from `preset` and the current Look quality.
func apply() -> void:
	var d: Dictionary = PRESETS[preset]
	var q := Look.get_quality()
	world_environment.environment = _build_environment(d, q)
	_setup_key(d, q)
	_setup_fill(d)
	Look.apply_shadow_settings()
	if is_inside_tree():
		Look.apply_viewport(get_viewport())


func _build_environment(d: Dictionary, q: Look.Quality) -> Environment:
	var high := q == Look.Quality.HIGH
	var low := q == Look.Quality.LOW
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = d["sky_top"]
	sky_mat.sky_horizon_color = d["sky_horizon"]
	sky_mat.sky_curve = 0.12
	sky_mat.ground_horizon_color = d["ground_horizon"]
	sky_mat.ground_bottom_color = d["ground_bottom"]
	sky_mat.ground_curve = 0.06
	sky_mat.sun_angle_max = 0.0
	sky_mat.use_debanding = true
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = d["ambient_energy"]
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = d["exposure"]
	env.tonemap_white = 6.0

	env.adjustment_enabled = true
	env.adjustment_saturation = d["saturation"]
	env.adjustment_contrast = d["contrast"]

	# Glow: only HDR (emissive: lava, coins, sparkles) blooms; lit surfaces stay crisp.
	env.glow_enabled = not low
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_hdr_threshold = 1.9
	env.glow_hdr_scale = 2.0
	env.glow_intensity = d["glow"]
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	for i in 7:
		env.set_glow_level(i, 0.0)
	env.set_glow_level(1, 0.6)
	env.set_glow_level(2, 1.0)
	env.set_glow_level(3, 0.8)
	env.set_glow_level(4, 0.5)

	# SSAO: contact shading where blobs meet the floor and props meet walls.
	env.ssao_enabled = high
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.6
	env.ssao_power = 1.4
	env.ssao_detail = 0.5
	env.ssao_horizon = 0.06
	env.ssao_sharpness = 0.98
	env.ssao_light_affect = 0.1

	# Soft distance fog for depth; the sky stays clean.
	env.fog_enabled = not low and float(d["fog_density"]) > 0.0
	env.fog_light_color = d["fog_color"]
	env.fog_light_energy = 1.0
	env.fog_density = d["fog_density"]
	env.fog_sky_affect = 0.0
	return env


func _setup_key(d: Dictionary, q: Look.Quality) -> void:
	var high := q == Look.Quality.HIGH
	var low := q == Look.Quality.LOW
	key_light.light_color = d["key_color"]
	key_light.light_energy = d["key_energy"]
	key_light.rotation_degrees = Vector3(d["key_pitch"], float(d["key_yaw"]) + light_yaw, 0.0)
	key_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	key_light.shadow_enabled = true
	# LOW: one split (one shadow pass, not two) over a shorter range
	key_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if low else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	key_light.directional_shadow_max_distance = shadow_distance if high else shadow_distance * (0.6 if low else 0.75)
	key_light.directional_shadow_split_1 = 0.35
	key_light.directional_shadow_blend_splits = high
	key_light.shadow_blur = 1.6 if high else 1.0  # 0 leaves acne rings on round shapes
	key_light.shadow_bias = 0.04
	key_light.shadow_normal_bias = 1.2
	key_light.shadow_opacity = 0.85
	key_light.light_angular_distance = 0.0


func _setup_fill(d: Dictionary) -> void:
	fill_light.light_color = d["fill_color"]
	fill_light.light_energy = d["fill_energy"]
	fill_light.rotation_degrees = Vector3(d["fill_pitch"], float(d["fill_yaw"]) + light_yaw, 0.0)
	fill_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	fill_light.shadow_enabled = false
	fill_light.light_specular = 0.2
