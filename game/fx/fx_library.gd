class_name FxLibrary
extends RefCounted
## Builds every named effect in code (no textures, shared meshes and materials).
## Sizes in metres for a 1 m blob. Owner: look and effects.

const NAMES: Array[StringName] = [
	&"dust_puff", &"land_thud", &"shove_whoosh", &"hit_stars", &"stun_swirl", &"poof",
	&"respawn_sparkle", &"coin_pickup", &"explosion", &"confetti", &"splash_lava",
]

const LIT_SHADER := preload("res://fx/materials/fx_lit.gdshader")
const GLOW_SHADER := preload("res://fx/materials/fx_glow.gdshader")
const SOFT_SHADER := preload("res://fx/materials/fx_soft.gdshader")
const STAR_SHADER := preload("res://fx/materials/fx_star.gdshader")

const DUST := Color(0.95, 0.90, 0.82)
const SMOKE := Color(0.90, 0.88, 0.93)

static var _cache: Dictionary = {}


static func has(effect: StringName) -> bool:
	return effect in NAMES


## A new, idle FxEffect for `effect`, or null if the name is unknown.
static func build(effect: StringName) -> FxEffect:
	var fx := FxEffect.new()
	fx.effect_name = effect
	fx.name = String(effect)
	match effect:
		&"dust_puff": _dust_puff(fx)
		&"land_thud": _land_thud(fx)
		&"shove_whoosh": _shove_whoosh(fx)
		&"hit_stars": _hit_stars(fx)
		&"stun_swirl": _stun_swirl(fx)
		&"poof": _poof(fx)
		&"respawn_sparkle": _respawn_sparkle(fx)
		&"coin_pickup": _coin_pickup(fx)
		&"explosion": _explosion(fx)
		&"confetti": _confetti(fx)
		&"splash_lava": _splash_lava(fx)
		_:
			fx.free()
			return null
	return fx


# --- Effects -----------------------------------------------------------------------------

static func _dust_puff(fx: FxEffect) -> void:
	fx.duration = 0.8
	var p := _emitter(8, 0.55, _mesh(&"puff"), _lit(), DUST)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.15
	p.direction = Vector3.UP
	p.spread = 75.0
	p.flatness = 0.5
	p.initial_velocity_min = 0.8
	p.initial_velocity_max = 1.7
	p.gravity = Vector3(0, 0.8, 0)
	p.damping_min = 2.5
	p.damping_max = 3.5
	p.scale_amount_min = 0.2
	p.scale_amount_max = 0.34
	p.scale_amount_curve = _curve(&"puff")
	p.lifetime_randomness = 0.3
	p.position.y = 0.05
	fx.add_emitter(p, true)


static func _land_thud(fx: FxEffect) -> void:
	fx.duration = 1.0
	var ring := _emitter(14, 0.6, _mesh(&"puff"), _lit(), DUST)
	ring.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	ring.emission_ring_axis = Vector3.UP
	ring.emission_ring_radius = 0.4
	ring.emission_ring_inner_radius = 0.3
	ring.emission_ring_height = 0.0
	ring.direction = Vector3.UP
	ring.spread = 20.0
	ring.initial_velocity_min = 0.3
	ring.initial_velocity_max = 0.8
	ring.radial_accel_min = 7.0
	ring.radial_accel_max = 10.0
	ring.damping_min = 6.0
	ring.damping_max = 8.0
	ring.scale_amount_min = 0.2
	ring.scale_amount_max = 0.34
	ring.scale_amount_curve = _curve(&"puff")
	ring.position.y = 0.08
	fx.add_emitter(ring, true)
	var wave := _emitter(1, 0.35, _mesh(&"ring"), _soft(), Color(1, 1, 1))
	wave.color_ramp = _gradient(&"fade")
	wave.scale_amount_min = 1.5
	wave.scale_amount_max = 1.5
	wave.scale_amount_curve = _curve(&"grow")
	wave.position.y = 0.04
	fx.add_emitter(wave, false)
	var pebbles := _emitter(5, 0.6, _mesh(&"chunk"), _lit(), Color(0.80, 0.72, 0.62))
	pebbles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	pebbles.emission_sphere_radius = 0.3
	pebbles.direction = Vector3.UP
	pebbles.spread = 50.0
	pebbles.initial_velocity_min = 2.0
	pebbles.initial_velocity_max = 3.2
	pebbles.gravity = Vector3(0, -14, 0)
	pebbles.particle_flag_rotate_y = true
	pebbles.angular_velocity_min = -540.0
	pebbles.angular_velocity_max = 540.0
	pebbles.scale_amount_min = 0.06
	pebbles.scale_amount_max = 0.1
	pebbles.scale_amount_curve = _curve(&"late_shrink")
	fx.add_emitter(pebbles, false)


## Faces local +Z: Fx callers turn the returned node toward the shove.
static func _shove_whoosh(fx: FxEffect) -> void:
	fx.duration = 0.5
	var streaks := _emitter(7, 0.26, _mesh(&"streak"), _soft(), Color(1, 1, 1, 0.9))
	streaks.color_ramp = _gradient(&"fade")
	streaks.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	streaks.emission_box_extents = Vector3(0.38, 0.28, 0.05)
	streaks.position = Vector3(0, 0.5, 0.2)
	streaks.direction = Vector3(0, 0, 1)
	streaks.spread = 6.0
	streaks.initial_velocity_min = 7.0
	streaks.initial_velocity_max = 10.0
	streaks.damping_min = 14.0
	streaks.damping_max = 18.0
	streaks.particle_flag_align_y = true
	streaks.scale_amount_min = 0.8
	streaks.scale_amount_max = 1.2
	streaks.scale_amount_curve = _curve(&"shrink")
	fx.add_emitter(streaks, false)
	var puffs := _emitter(6, 0.4, _mesh(&"puff"), _lit(), Color(1, 1, 1))
	puffs.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	puffs.emission_sphere_radius = 0.15
	puffs.position = Vector3(0, 0.45, 0.45)
	puffs.direction = Vector3(0, 0.1, 1)
	puffs.spread = 35.0
	puffs.initial_velocity_min = 2.5
	puffs.initial_velocity_max = 4.0
	puffs.damping_min = 8.0
	puffs.damping_max = 10.0
	puffs.scale_amount_min = 0.1
	puffs.scale_amount_max = 0.18
	puffs.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(puffs, true)


static func _hit_stars(fx: FxEffect) -> void:
	fx.duration = 0.9
	var flash := _emitter(1, 0.14, _mesh(&"sparkle"), _glow(1.6), Color(1, 0.95, 0.85))
	flash.scale_amount_min = 0.9
	flash.scale_amount_max = 0.9
	flash.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(flash, false)
	var stars := _emitter(6, 0.75, _mesh(&"star"), _star(0.45), Look.GOLD)
	stars.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	stars.emission_sphere_radius = 0.1
	stars.direction = Vector3.UP
	stars.spread = 100.0
	stars.initial_velocity_min = 3.0
	stars.initial_velocity_max = 4.5
	stars.gravity = Vector3(0, -7, 0)
	stars.damping_min = 1.5
	stars.damping_max = 2.5
	stars.angular_velocity_min = -360.0
	stars.angular_velocity_max = 360.0
	stars.scale_amount_min = 0.3
	stars.scale_amount_max = 0.42
	stars.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(stars, true)
	var sparks := _emitter(10, 0.22, _mesh(&"streak"), _glow(2.5), Color(1, 0.9, 0.6))
	sparks.color_ramp = _gradient(&"fade")
	sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	sparks.emission_sphere_radius = 0.05
	sparks.spread = 180.0
	sparks.initial_velocity_min = 5.0
	sparks.initial_velocity_max = 8.0
	sparks.damping_min = 12.0
	sparks.damping_max = 16.0
	sparks.particle_flag_align_y = true
	sparks.scale_amount_min = 0.35
	sparks.scale_amount_max = 0.5
	sparks.scale_amount_curve = _curve(&"shrink")
	fx.add_emitter(sparks, true)


## Stars circling a head. Default 1.5 s; the fx component hold()s it for the stun.
static func _stun_swirl(fx: FxEffect) -> void:
	fx.duration = 1.5
	var meshes: Array[MeshInstance3D] = []
	for i in 3:
		var m := MeshInstance3D.new()
		m.mesh = _mesh(&"star")
		m.material_override = _star_mesh_mat()
		m.scale = Vector3.ONE * 0.26
		meshes.append(m)
	fx.add_orbit(meshes, 0.42, 4.5, true, Look.GOLD)
	var glints := _emitter(6, 0.5, _mesh(&"sparkle"), _glow(2.0), Color(1, 0.92, 0.6))
	glints.color_ramp = _gradient(&"fade")
	glints.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	glints.emission_ring_axis = Vector3.UP
	glints.emission_ring_radius = 0.38
	glints.emission_ring_inner_radius = 0.3
	glints.emission_ring_height = 0.05
	glints.one_shot = false
	glints.explosiveness = 0.0
	glints.initial_velocity_min = 0.1
	glints.initial_velocity_max = 0.3
	glints.gravity = Vector3.ZERO
	glints.scale_amount_min = 0.05
	glints.scale_amount_max = 0.08
	glints.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(glints, false)
	glints.one_shot = false


static func _poof(fx: FxEffect) -> void:
	fx.duration = 1.3
	var flash := _emitter(1, 0.16, _mesh(&"sparkle"), _glow(1.4), Color(1, 1, 1))
	flash.scale_amount_min = 1.4
	flash.scale_amount_max = 1.4
	flash.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(flash, false)
	var smoke := _emitter(16, 0.9, _mesh(&"puff"), _lit(), SMOKE)
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	smoke.emission_sphere_radius = 0.35
	smoke.spread = 180.0
	smoke.initial_velocity_min = 2.0
	smoke.initial_velocity_max = 3.8
	smoke.gravity = Vector3(0, 1.2, 0)
	smoke.damping_min = 4.0
	smoke.damping_max = 6.0
	smoke.scale_amount_min = 0.32
	smoke.scale_amount_max = 0.55
	smoke.scale_amount_curve = _curve(&"puff")
	smoke.lifetime_randomness = 0.3
	fx.add_emitter(smoke, false)
	var bits := _emitter(16, 1.1, _mesh(&"chunk"), _lit(0.2), Color(1, 1, 1))
	bits.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	bits.emission_sphere_radius = 0.2
	bits.direction = Vector3.UP
	bits.spread = 70.0
	bits.initial_velocity_min = 4.0
	bits.initial_velocity_max = 6.5
	bits.gravity = Vector3(0, -12, 0)
	bits.damping_min = 1.0
	bits.damping_max = 2.0
	bits.particle_flag_rotate_y = true
	bits.angular_velocity_min = -720.0
	bits.angular_velocity_max = 720.0
	bits.scale_amount_min = 0.07
	bits.scale_amount_max = 0.12
	bits.scale_amount_curve = _curve(&"late_shrink")
	fx.add_emitter(bits, true)


static func _respawn_sparkle(fx: FxEffect) -> void:
	fx.duration = 1.2
	var pillar := _emitter(1, 0.55, _mesh(&"pillar"), _glow(0.9), Color(1, 0.95, 0.85))
	pillar.color_ramp = _gradient(&"fade")
	pillar.scale_amount_min = 1.0
	pillar.scale_amount_max = 1.0
	pillar.scale_amount_curve = _curve(&"pillar")
	fx.add_emitter(pillar, true)
	var wave := _emitter(1, 0.5, _mesh(&"ring"), _glow(2.2), Color(1, 0.95, 0.8))
	wave.color_ramp = _gradient(&"fade")
	wave.scale_amount_min = 1.5
	wave.scale_amount_max = 1.5
	wave.scale_amount_curve = _curve(&"grow")
	wave.position.y = 0.05
	fx.add_emitter(wave, true)
	var rise := _emitter(28, 1.0, _mesh(&"sparkle"), _glow(2.6), Color(1, 0.95, 0.8))
	rise.color_ramp = _gradient(&"fade")
	rise.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	rise.emission_ring_axis = Vector3.UP
	rise.emission_ring_radius = 0.55
	rise.emission_ring_inner_radius = 0.2
	rise.emission_ring_height = 0.3
	rise.direction = Vector3.UP
	rise.spread = 10.0
	rise.explosiveness = 0.7
	rise.initial_velocity_min = 1.8
	rise.initial_velocity_max = 3.6
	rise.damping_min = 1.0
	rise.damping_max = 2.0
	rise.scale_amount_min = 0.08
	rise.scale_amount_max = 0.14
	rise.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(rise, true)
	var stars := _emitter(5, 1.0, _mesh(&"star"), _star(0.8), Look.CREAM)
	stars.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	stars.emission_sphere_radius = 0.35
	stars.position.y = 0.6
	stars.direction = Vector3.UP
	stars.spread = 40.0
	stars.initial_velocity_min = 1.4
	stars.initial_velocity_max = 2.4
	stars.damping_min = 1.0
	stars.damping_max = 1.5
	stars.angular_velocity_min = -300.0
	stars.angular_velocity_max = 300.0
	stars.scale_amount_min = 0.16
	stars.scale_amount_max = 0.24
	stars.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(stars, false)


static func _coin_pickup(fx: FxEffect) -> void:
	fx.duration = 0.8
	var ring := _emitter(1, 0.35, _mesh(&"ring"), _glow(2.0), Look.GOLD)
	ring.color_ramp = _gradient(&"fade")
	ring.scale_amount_min = 1.0
	ring.scale_amount_max = 1.0
	ring.scale_amount_curve = _curve(&"grow")
	ring.particle_flag_rotate_y = false
	fx.add_emitter(ring, true)
	var glints := _emitter(12, 0.5, _mesh(&"sparkle"), _glow(2.6), Color(1, 0.85, 0.4))
	glints.color_ramp = _gradient(&"fade")
	glints.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	glints.emission_sphere_radius = 0.1
	glints.direction = Vector3.UP
	glints.spread = 70.0
	glints.initial_velocity_min = 2.0
	glints.initial_velocity_max = 3.5
	glints.gravity = Vector3(0, -3, 0)
	glints.damping_min = 3.0
	glints.damping_max = 4.0
	glints.scale_amount_min = 0.07
	glints.scale_amount_max = 0.12
	glints.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(glints, true)
	var stars := _emitter(3, 0.6, _mesh(&"star"), _star(0.7), Look.GOLD)
	stars.direction = Vector3.UP
	stars.spread = 30.0
	stars.initial_velocity_min = 1.8
	stars.initial_velocity_max = 2.6
	stars.damping_min = 2.0
	stars.damping_max = 3.0
	stars.angular_velocity_min = -300.0
	stars.angular_velocity_max = 300.0
	stars.scale_amount_min = 0.18
	stars.scale_amount_max = 0.24
	stars.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(stars, true)


static func _explosion(fx: FxEffect) -> void:
	fx.duration = 1.7
	fx.add_flash(Color(1.0, 0.6, 0.25), 4.0, 8.0, 0.4)
	var flash := _emitter(1, 0.12, _mesh(&"sparkle"), _glow(0.9), Color(1, 0.8, 0.45))
	flash.scale_amount_min = 1.8
	flash.scale_amount_max = 1.8
	flash.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(flash, true)
	var fire := _emitter(16, 1.0, _mesh(&"puff"), _lit(0.9), Color(1, 1, 1))
	fire.color_ramp = _gradient(&"fire")
	fire.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	fire.emission_sphere_radius = 0.5
	fire.spread = 180.0
	fire.initial_velocity_min = 3.0
	fire.initial_velocity_max = 6.0
	fire.gravity = Vector3(0, 2.5, 0)
	fire.damping_min = 5.0
	fire.damping_max = 7.0
	fire.scale_amount_min = 0.55
	fire.scale_amount_max = 0.95
	fire.scale_amount_curve = _curve(&"puff")
	fire.lifetime_randomness = 0.35
	fx.add_emitter(fire, false)
	var debris := _emitter(12, 1.3, _mesh(&"chunk"), _lit(), Look.CHARCOAL)
	debris.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	debris.emission_sphere_radius = 0.3
	debris.direction = Vector3.UP
	debris.spread = 75.0
	debris.initial_velocity_min = 6.0
	debris.initial_velocity_max = 10.0
	debris.gravity = Vector3(0, -20, 0)
	debris.damping_min = 0.5
	debris.damping_max = 1.0
	debris.particle_flag_rotate_y = true
	debris.angular_velocity_min = -720.0
	debris.angular_velocity_max = 720.0
	debris.scale_amount_min = 0.1
	debris.scale_amount_max = 0.2
	debris.scale_amount_curve = _curve(&"late_shrink")
	fx.add_emitter(debris, false)
	var sparks := _emitter(18, 0.45, _mesh(&"streak"), _glow(2.2), Color(1, 0.7, 0.3))
	sparks.color_ramp = _gradient(&"fade")
	sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	sparks.emission_sphere_radius = 0.3
	sparks.direction = Vector3.UP
	sparks.spread = 110.0
	sparks.initial_velocity_min = 8.0
	sparks.initial_velocity_max = 13.0
	sparks.gravity = Vector3(0, -9, 0)
	sparks.damping_min = 4.0
	sparks.damping_max = 6.0
	sparks.particle_flag_align_y = true
	sparks.scale_amount_min = 0.4
	sparks.scale_amount_max = 0.6
	sparks.scale_amount_curve = _curve(&"shrink")
	fx.add_emitter(sparks, true)
	var wave := _emitter(1, 0.45, _mesh(&"ring"), _soft(), Color(1, 0.93, 0.8, 0.8))
	wave.color_ramp = _gradient(&"fade")
	wave.scale_amount_min = 4.0
	wave.scale_amount_max = 4.0
	wave.scale_amount_curve = _curve(&"grow")
	wave.position.y = 0.1
	fx.add_emitter(wave, false)


static func _confetti(fx: FxEffect) -> void:
	fx.duration = 2.6
	var bits := _emitter(70, 2.4, _mesh(&"confetti"), _lit(0.15), Color(1, 1, 1))
	bits.color_initial_ramp = _gradient(&"party")
	bits.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	bits.emission_sphere_radius = 0.3
	bits.direction = Vector3.UP
	bits.spread = 35.0
	bits.initial_velocity_min = 7.0
	bits.initial_velocity_max = 11.0
	bits.gravity = Vector3(0, -6, 0)
	bits.damping_min = 2.5
	bits.damping_max = 3.5
	bits.particle_flag_rotate_y = true
	bits.angular_velocity_min = -900.0
	bits.angular_velocity_max = 900.0
	bits.scale_amount_min = 0.8
	bits.scale_amount_max = 1.2
	bits.scale_amount_curve = _curve(&"late_shrink")
	bits.lifetime_randomness = 0.25
	fx.add_emitter(bits, true)
	var glints := _emitter(14, 0.8, _mesh(&"sparkle"), _glow(2.4), Color(1, 0.95, 0.8))
	glints.color_ramp = _gradient(&"fade")
	glints.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	glints.emission_sphere_radius = 0.3
	glints.direction = Vector3.UP
	glints.spread = 40.0
	glints.initial_velocity_min = 5.0
	glints.initial_velocity_max = 8.0
	glints.damping_min = 4.0
	glints.damping_max = 5.0
	glints.scale_amount_min = 0.05
	glints.scale_amount_max = 0.09
	glints.scale_amount_curve = _curve(&"pop")
	fx.add_emitter(glints, false)


static func _splash_lava(fx: FxEffect) -> void:
	fx.duration = 1.4
	fx.add_flash(Look.LAVA, 3.0, 5.0, 0.4)
	var drops := _emitter(16, 0.9, _mesh(&"puff"), _lit(1.1), Color(1, 1, 1))
	drops.color_ramp = _gradient(&"lava")
	drops.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	drops.emission_sphere_radius = 0.3
	drops.direction = Vector3.UP
	drops.spread = 35.0
	drops.initial_velocity_min = 4.0
	drops.initial_velocity_max = 7.5
	drops.gravity = Vector3(0, -16, 0)
	drops.damping_min = 0.5
	drops.damping_max = 1.0
	drops.scale_amount_min = 0.12
	drops.scale_amount_max = 0.26
	drops.scale_amount_curve = _curve(&"late_shrink")
	fx.add_emitter(drops, false)
	var wave := _emitter(1, 0.5, _mesh(&"ring"), _glow(1.6), Look.LAVA)
	wave.color_ramp = _gradient(&"fade")
	wave.scale_amount_min = 1.6
	wave.scale_amount_max = 1.6
	wave.scale_amount_curve = _curve(&"grow")
	wave.position.y = 0.05
	fx.add_emitter(wave, false)
	var smoke := _emitter(7, 1.3, _mesh(&"puff"), _lit(), Color(0.33, 0.27, 0.3))
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	smoke.emission_sphere_radius = 0.35
	smoke.direction = Vector3.UP
	smoke.spread = 25.0
	smoke.initial_velocity_min = 1.2
	smoke.initial_velocity_max = 2.2
	smoke.gravity = Vector3(0, 0.8, 0)
	smoke.damping_min = 1.5
	smoke.damping_max = 2.5
	smoke.scale_amount_min = 0.3
	smoke.scale_amount_max = 0.5
	smoke.scale_amount_curve = _curve(&"puff")
	fx.add_emitter(smoke, false)


# --- Shared parts ------------------------------------------------------------------------

static func _emitter(amount: int, lifetime: float, mesh: Mesh, material: Material, color: Color) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.explosiveness = 1.0
	p.randomness = 0.5
	p.mesh = mesh
	p.material_override = material
	p.color = color
	p.gravity = Vector3.ZERO
	p.spread = 45.0
	return p


static func _lit(glow: float = 0.0) -> ShaderMaterial:
	var key := "lit_%.2f" % glow
	if not _cache.has(key):
		var m := ShaderMaterial.new()
		m.shader = LIT_SHADER
		m.set_shader_parameter(&"glow", glow)
		_cache[key] = m
	return _cache[key]


## Camera-facing star material for plain meshes (no particle colour): spins on its own,
## coloured by the per-instance tint.
static func _star_mesh_mat() -> ShaderMaterial:
	if not _cache.has("star_mesh"):
		var m := ShaderMaterial.new()
		m.shader = STAR_SHADER
		m.set_shader_parameter(&"glow", 0.6)
		m.set_shader_parameter(&"spin_speed", 4.0)
		_cache["star_mesh"] = m
	return _cache["star_mesh"]


static func _star(glow: float) -> ShaderMaterial:
	var key := "star_%.2f" % glow
	if not _cache.has(key):
		var m := ShaderMaterial.new()
		m.shader = STAR_SHADER
		m.set_shader_parameter(&"glow", glow)
		_cache[key] = m
	return _cache[key]


static func _glow(glow: float) -> ShaderMaterial:
	var key := "glow_%.2f" % glow
	if not _cache.has(key):
		var m := ShaderMaterial.new()
		m.shader = GLOW_SHADER
		m.set_shader_parameter(&"glow", glow)
		_cache[key] = m
	return _cache[key]


static func _soft() -> ShaderMaterial:
	if not _cache.has("soft"):
		var m := ShaderMaterial.new()
		m.shader = SOFT_SHADER
		_cache["soft"] = m
	return _cache["soft"]


static func _mesh(kind: StringName) -> Mesh:
	var key := "mesh_%s" % kind
	if _cache.has(key):
		return _cache[key]
	var mesh: Mesh
	match kind:
		&"puff":
			var s := SphereMesh.new()
			s.radius = 0.5
			s.height = 1.0
			s.radial_segments = 12
			s.rings = 6
			mesh = s
		&"sparkle":
			var s := SphereMesh.new()
			s.radius = 0.5
			s.height = 1.0
			s.radial_segments = 8
			s.rings = 4
			mesh = s
		&"chunk":
			var b := BoxMesh.new()
			b.size = Vector3.ONE
			mesh = b
		&"confetti":
			var b := BoxMesh.new()
			b.size = Vector3(0.14, 0.015, 0.09)
			mesh = b
		&"streak":
			var c := CapsuleMesh.new()
			c.radius = 0.035
			c.height = 0.7
			c.radial_segments = 6
			c.rings = 1
			mesh = c
		&"ring":
			var t := TorusMesh.new()
			t.inner_radius = 0.42
			t.outer_radius = 0.5
			t.rings = 32
			t.ring_segments = 6
			mesh = t
		&"star":
			mesh = _star_mesh(0.5, 0.24, 0.2)
		&"pillar":
			var c := CylinderMesh.new()
			c.top_radius = 0.3
			c.bottom_radius = 0.5
			c.height = 2.4
			c.radial_segments = 16
			c.rings = 1
			c.cap_top = false
			c.cap_bottom = false
			mesh = c
	_cache[key] = mesh
	return mesh


## A puffy five-point star lying in the XY plane (front +Z), `depth` thick, flat shaded.
static func _star_mesh(outer: float, inner: float, depth: float) -> ArrayMesh:
	var pts: Array[Vector2] = []
	for i in 10:
		var a := PI * 0.5 + TAU * float(i) / 10.0
		var r := outer if i % 2 == 0 else inner
		pts.append(Vector2(cos(a), sin(a)) * r)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := depth * 0.5
	# the faces bulge a little toward the centre so the star reads as puffy, not cut out
	var front_c := Vector3(0, 0, h * 1.6)
	var back_c := Vector3(0, 0, -h * 1.6)
	for i in 10:
		var a := pts[i]
		var b := pts[(i + 1) % 10]
		var fa := Vector3(a.x, a.y, h)
		var fb := Vector3(b.x, b.y, h)
		var ba := Vector3(a.x, a.y, -h)
		var bb := Vector3(b.x, b.y, -h)
		var side := Vector3((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, 0.0)
		_tri(st, front_c, fa, fb, Vector3.BACK)
		_tri(st, back_c, ba, bb, Vector3.FORWARD)
		_tri(st, fa, ba, bb, side)
		_tri(st, fa, bb, fb, side)
	return st.commit()


## Adds a flat-shaded triangle facing `outward` (Godot front faces wind clockwise).
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, outward: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.dot(outward) > 0.0:
		var t := b
		b = c
		c = t
	else:
		n = -n
	st.set_normal(n.normalized())
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


static func _curve(kind: StringName) -> Curve:
	var key := "curve_%s" % kind
	if _cache.has(key):
		return _cache[key]
	var c := Curve.new()
	match kind:
		&"pop":
			c.add_point(Vector2(0.0, 0.0))
			c.add_point(Vector2(0.15, 1.0))
			c.add_point(Vector2(0.6, 0.8))
			c.add_point(Vector2(1.0, 0.0))
		&"puff":
			c.add_point(Vector2(0.0, 0.35))
			c.add_point(Vector2(0.2, 1.0))
			c.add_point(Vector2(0.65, 0.8))
			c.add_point(Vector2(1.0, 0.0))
		&"shrink":
			c.add_point(Vector2(0.0, 1.0))
			c.add_point(Vector2(1.0, 0.0))
		&"late_shrink":
			c.add_point(Vector2(0.0, 1.0))
			c.add_point(Vector2(0.75, 1.0))
			c.add_point(Vector2(1.0, 0.0))
		&"pillar":
			c.add_point(Vector2(0.0, 0.2))
			c.add_point(Vector2(0.15, 1.0))
			c.add_point(Vector2(1.0, 0.6))
		&"grow":
			c.add_point(Vector2(0.0, 0.15))
			c.add_point(Vector2(0.4, 0.8))
			c.add_point(Vector2(1.0, 1.0))
	c.bake()
	_cache[key] = c
	return c


static func _gradient(kind: StringName) -> Gradient:
	var key := "grad_%s" % kind
	if _cache.has(key):
		return _cache[key]
	var g := Gradient.new()
	match kind:
		&"fade":
			g.set_color(0, Color(1, 1, 1, 1))
			g.set_color(1, Color(1, 1, 1, 0))
			g.add_point(0.5, Color(1, 1, 1, 0.8))
		&"fire":
			g.set_color(0, Color(1.0, 0.85, 0.45))
			g.set_color(1, Color(0.22, 0.19, 0.23))
			g.add_point(0.12, Color(1.0, 0.62, 0.2))
			g.add_point(0.35, Color(0.95, 0.36, 0.14))
			g.add_point(0.6, Color(0.45, 0.2, 0.18))
		&"lava":
			g.set_color(0, Color(1.0, 0.62, 0.2))
			g.set_color(1, Color(0.4, 0.1, 0.07))
			g.add_point(0.35, Color(1.0, 0.4, 0.12))
		&"party":
			g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
			var cols: Array[Color] = [Look.RED, Look.GOLD, Look.GREEN, Look.BLUE, Look.PINK, Look.TEAL, Look.CREAM]
			g.set_color(0, cols[0])
			g.set_offset(1, 1.0 / cols.size())
			g.set_color(1, cols[1])
			for i in range(2, cols.size()):
				g.add_point(float(i) / cols.size(), cols[i])
	_cache[key] = g
	return g
