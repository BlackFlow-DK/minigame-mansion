extends GameTest
## Performance levels: Look LOW / MEDIUM / HIGH (environment, shadows, viewport scale and AA,
## outlines), the Fx caps, the lobby's light budget and the first-run GPU auto-detect.

const STAGE_LOOK: PackedScene = preload("res://look/stage_look.tscn")
const LOBBY_PATH := "res://lobby/lobby.tscn"

var _fx: Node


func before_each() -> void:
	_fx = get_node(^"/root/Fx")
	_fx.clear()
	Look.set_quality(Look.Quality.HIGH)


func after_each() -> void:
	_fx.set(&"headless_spawn", false)
	_fx.clear()
	Look.set_quality(Look.Quality.HIGH)


func test_quality_names_round_trip() -> void:
	assert_eq(Look.quality_from_name("low"), Look.Quality.LOW)
	assert_eq(Look.quality_from_name("Medium"), Look.Quality.MEDIUM)
	assert_eq(Look.quality_from_name("high"), Look.Quality.HIGH)
	assert_eq(Look.quality_from_name("ultra"), -1, "unknown")
	assert_eq(Settings.QUALITIES.size(), 3, "Settings offers three levels")
	for q: String in Settings.QUALITIES:
		assert_true(Look.quality_from_name(q) >= 0, "%s is a Look level" % q)


func test_three_levels_switch_environment_shadows_and_outline_live() -> void:
	var look := STAGE_LOOK.instantiate() as StageLook
	add_child(look)
	var m := Look.toon_material(Look.TEAL)
	var env := func() -> Environment: return look.world_environment.environment

	Look.set_quality(Look.Quality.MEDIUM)
	assert_false((env.call() as Environment).ssao_enabled, "MEDIUM: no SSAO")
	assert_true((env.call() as Environment).glow_enabled, "MEDIUM: glow")
	assert_true(m.next_pass == Look.outline_material(), "MEDIUM: outline")
	assert_true(look.key_light.shadow_enabled, "MEDIUM: sun shadow")
	assert_eq(look.key_light.directional_shadow_mode, DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, "MEDIUM: 2 splits")
	assert_true(Look.is_high(), "MEDIUM keeps the full effect set")

	Look.set_quality(Look.Quality.LOW)
	assert_false((env.call() as Environment).ssao_enabled, "LOW: no SSAO")
	assert_false((env.call() as Environment).glow_enabled, "LOW: no glow")
	assert_false((env.call() as Environment).fog_enabled, "LOW: no fog")
	assert_true(m.next_pass == null, "LOW: no outline")
	assert_true(look.key_light.shadow_enabled, "LOW: still one sun shadow")
	assert_eq(look.key_light.directional_shadow_mode, DirectionalLight3D.SHADOW_ORTHOGONAL, "LOW: one split")
	assert_true(Look.is_low() and not Look.is_high(), "LOW flags")

	Look.set_quality(Look.Quality.HIGH)
	assert_true((env.call() as Environment).ssao_enabled, "HIGH: SSAO back")
	assert_true((env.call() as Environment).glow_enabled, "HIGH: glow back")
	assert_true(m.next_pass == Look.outline_material(), "HIGH: outline back")
	look.queue_free()


func test_viewport_scale_and_aa_follow_the_level() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 36)
	vp.msaa_3d = Viewport.MSAA_2X
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var look := STAGE_LOOK.instantiate() as StageLook
	vp.add_child(look)  # a StageLook configures the viewport it renders into
	assert_near(vp.scaling_3d_scale, 1.0, 0.001, "HIGH: full scale")
	assert_eq(vp.msaa_3d, Viewport.MSAA_2X, "HIGH: the viewport's own MSAA")

	Look.set_quality(Look.Quality.LOW)
	assert_near(vp.scaling_3d_scale, 0.75, 0.001, "LOW: 0.75 scale")
	assert_eq(vp.msaa_3d, Viewport.MSAA_DISABLED, "LOW: no MSAA")
	assert_eq(vp.screen_space_aa, Viewport.SCREEN_SPACE_AA_FXAA, "LOW: FXAA")

	vp.set_meta(&"look_scale_factor", 0.5)
	Look.set_quality(Look.Quality.MEDIUM)
	assert_near(vp.scaling_3d_scale, 0.5, 0.001, "MEDIUM: scale factor of the viewport")
	assert_eq(vp.msaa_3d, Viewport.MSAA_DISABLED, "MEDIUM: no MSAA")

	Look.set_quality(Look.Quality.HIGH)
	assert_near(vp.scaling_3d_scale, 1.0, 0.001, "HIGH ignores the factor")
	assert_eq(vp.msaa_3d, Viewport.MSAA_2X, "HIGH restores MSAA")
	assert_eq(vp.screen_space_aa, Viewport.SCREEN_SPACE_AA_DISABLED, "HIGH restores AA")
	vp.queue_free()


func test_fx_pools_and_particles_are_capped_on_low() -> void:
	_fx.set(&"headless_spawn", true)
	var full := _fx.call(&"play", &"explosion", Vector3.ZERO) as FxEffect
	var full_amount := _particle_total(full)
	_fx.clear()
	Look.set_quality(Look.Quality.LOW)
	var low := _fx.call(&"play", &"explosion", Vector3.ZERO) as FxEffect
	assert_true(_particle_total(low) < full_amount, "fewer particles on LOW (%d < %d)" % [_particle_total(low), full_amount])
	for i in 25:
		_fx.call(&"play", &"dust_puff", Vector3.ZERO)
	assert_eq(_fx.call(&"live_count", &"dust_puff"), _fx.call(&"pool_max"), "LOW pool cap")
	assert_true(int(_fx.call(&"pool_max")) < int(_fx.get(&"POOL_MAX")), "LOW cap below HIGH")
	await step(90)
	Look.set_quality(Look.Quality.HIGH)
	assert_eq(_fx.call(&"idle_count", &"explosion"), 0, "LOW nodes dropped from the pool on the switch")
	var again := _fx.call(&"play", &"explosion", Vector3.ZERO) as FxEffect
	assert_eq(_particle_total(again), full_amount, "HIGH particle count back")


func test_lobby_drops_small_lights_on_low() -> void:
	var lobby := (load(LOBBY_PATH) as PackedScene).instantiate() as MansionLobby
	add_child(lobby)
	var small: Array = lobby.get(&"_small_lights")
	var moon: Array = lobby.get(&"_moon_spots")
	var fire: Array = lobby.get(&"_fire_lights")
	assert_true(small.size() > 0 and moon.size() > 0 and fire.size() > 0, "lights found")
	assert_true(_all_visible(small) and _all_visible(moon), "HIGH: every light")
	assert_true((fire[0] as Light3D).shadow_enabled, "HIGH: fire shadow")
	Look.set_quality(Look.Quality.LOW)
	assert_false(_any_visible(small) or _any_visible(moon), "LOW: candelabras and moonbeams off")
	assert_false((fire[0] as Light3D).shadow_enabled, "LOW: no fire shadow")
	assert_true((fire[0] as Light3D).visible, "LOW: the fire still lights the hall")
	await step(2)
	Look.set_quality(Look.Quality.MEDIUM)
	assert_true(_all_visible(small) and _all_visible(moon), "MEDIUM: every light")
	lobby.queue_free()
	await step(1)


func test_auto_detect_picks_a_level_from_the_gpu() -> void:
	var integrated := RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU
	var discrete := RenderingDevice.DEVICE_TYPE_DISCRETE_GPU
	var cases := [
		["Intel(R) UHD Graphics 620", integrated, "low"],
		["Intel(R) Iris(R) Xe Graphics", integrated, "low"],
		["Intel(R) HD Graphics 4000", RenderingDevice.DEVICE_TYPE_OTHER, "low"],
		["AMD Radeon(TM) Graphics", integrated, "low"],
		["AMD Radeon(TM) Vega 8 Graphics", RenderingDevice.DEVICE_TYPE_OTHER, "low"],
		["llvmpipe (LLVM 15.0.7, 256 bits)", RenderingDevice.DEVICE_TYPE_CPU, "low"],
		["Microsoft Basic Render Driver", RenderingDevice.DEVICE_TYPE_OTHER, "low"],
		["Intel(R) Arc(TM) A750 Graphics", discrete, "medium"],
		["NVIDIA GeForce GTX 1050 Ti", discrete, "medium"],
		["NVIDIA GeForce MX250", discrete, "medium"],
		["AMD Radeon RX 580 Series", discrete, "medium"],
		["NVIDIA GeForce RTX 3060 Ti", discrete, "high"],
		["AMD Radeon RX 6800 XT", discrete, "high"],
		["", RenderingDevice.DEVICE_TYPE_OTHER, "medium"],
	]
	for c: Array in cases:
		assert_eq(Settings.detect_quality(c[0], c[1]), c[2], "%s" % c[0])


static func _particle_total(fx: FxEffect) -> int:
	var n := 0
	if fx == null:
		return n
	for p in fx.find_children("*", "CPUParticles3D", true, false):
		n += (p as CPUParticles3D).amount
	return n


static func _all_visible(lights: Array) -> bool:
	for l: Variant in lights:
		if not (l as Node3D).visible:
			return false
	return true


static func _any_visible(lights: Array) -> bool:
	for l: Variant in lights:
		if (l as Node3D).visible:
			return true
	return false
