class_name FxEffect
extends Node3D
## One pooled, re-playable effect: a few one-shot CPUParticles3D bursts plus optional
## orbiting meshes, a light flash and a popping text tag ("OUT!").
## Runs on FeelTime (visual slow-motion): its clock and its particles follow FeelTime.scale. Built by FxLibrary, owned and recycled by the `Fx`
## autoload. The node is top level in world space; `hold()` makes it follow a target.
## Owner: look and effects.

## Raised when the effect has run its course (or was stopped); Fx returns it to the pool.
signal done(effect: FxEffect)

## The library name this node was built for.
var effect_name: StringName = &""
## Seconds until the effect is over (covers the longest particle lifetime).
var duration: float = 1.0

## Text tags (add_tag): metres per font pixel (the name tags' size), the height they pop in at,
## and their render priority (below the name tags' 10).
const TAG_PIXEL_SIZE := 0.0065
const TAG_BASE_HEIGHT := 0.95
const TAG_RENDER_PRIORITY := 8
## Increments on every play(); lets holders tell their play apart from a later reuse.
var serial: int = 0
var playing: bool = false

var _emitters: Array[CPUParticles3D] = []
var _tinted: Array[bool] = []
var _base_colors: Array[Color] = []
var _orbit: Node3D = null
var _orbit_speed: float = 0.0
var _orbit_meshes: Array[MeshInstance3D] = []
var _orbit_tinted: bool = false
var _orbit_color: Color = Color.WHITE
var _light: OmniLight3D = null
var _light_energy: float = 0.0
var _light_time: float = 0.2
var _time: float = 0.0
var _end: float = 1.0
var _follow: Node3D = null
var _following: bool = false
var _follow_offset: Vector3 = Vector3.ZERO
var _speed: float = 1.0
var _tag: Label3D = null
var _tag_color: Color = Color.WHITE
var _tag_rise: float = 0.5
## The tag's own clock: real time, so it reads for `duration` seconds even in slow-motion.
var _tag_time: float = 0.0


func _init() -> void:
	top_level = true
	visible = false
	set_process(false)


## Adds a burst emitter. `tint`: the colour passed to play() replaces its colour.
func add_emitter(p: CPUParticles3D, tint: bool = false) -> CPUParticles3D:
	p.one_shot = true
	p.emitting = false
	p.local_coords = true
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	_emitters.append(p)
	_tinted.append(tint)
	_base_colors.append(p.color)
	return p


## Adds meshes that circle around the local Y axis at `radius`, turning `speed` rad/s.
func add_orbit(meshes: Array[MeshInstance3D], radius: float, speed: float, tint: bool = false,
		base_color: Color = Color.WHITE) -> void:
	_orbit_color = base_color
	_orbit = Node3D.new()
	_orbit.name = "Orbit"
	add_child(_orbit)
	_orbit_speed = speed
	_orbit_tinted = tint
	for i in meshes.size():
		var m := meshes[i]
		var a := TAU * float(i) / float(meshes.size())
		m.position = Vector3(cos(a) * radius, 0.0, sin(a) * radius)
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_orbit.add_child(m)
		_orbit_meshes.append(m)


## A short light flash (skipped on LOW quality).
func add_flash(color: Color, energy: float, radius: float, seconds: float) -> void:
	_light = OmniLight3D.new()
	_light.light_color = color
	_light.omni_range = radius
	_light.shadow_enabled = false
	_light.light_energy = 0.0
	_light.visible = false
	_light_energy = energy
	_light_time = seconds
	add_child(_light)


## Adds a camera-facing text tag that pops in at TAG_BASE_HEIGHT, rises `rise` metres and fades
## out after `duration` seconds of real time (FeelTime slow-motion does not stretch it).
## `tint`: the play() colour replaces its text colour. Drawn on top of the world but under the
## name tags (render priority 10/9), so a name is never hidden by it.
func add_tag(text: String, color: Color, font: Font, font_size: int = 96, rise: float = 0.5) -> Label3D:
	_tag = Label3D.new()
	_tag.name = "Tag"
	_tag.text = text
	_tag.font = font
	_tag.font_size = font_size
	_tag.outline_size = maxi(8, int(font_size * 0.25))
	_tag.modulate = color
	_tag.outline_modulate = Look.CHARCOAL
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.no_depth_test = true
	_tag.fixed_size = false
	_tag.pixel_size = TAG_PIXEL_SIZE
	_tag.render_priority = TAG_RENDER_PRIORITY
	_tag.outline_render_priority = TAG_RENDER_PRIORITY - 1
	_tag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tag_color = color
	_tag_rise = rise
	add_child(_tag)
	return _tag


## Starts (or restarts) the effect where the node is. `color` tints the tintable parts;
## WHITE keeps the effect's own colours.
func play(color: Color = Color.WHITE) -> void:
	serial += 1
	playing = true
	_time = 0.0
	_end = duration
	_follow = null
	_following = false
	visible = true
	set_process(true)
	var use_tint := color != Color.WHITE
	for i in _emitters.size():
		var p := _emitters[i]
		p.color = color if (use_tint and _tinted[i]) else _base_colors[i]
		p.restart()
	if _orbit:
		_orbit.rotation = Vector3.ZERO
		_orbit.scale = Vector3.ONE * 0.01
		for m in _orbit_meshes:
			m.set_instance_shader_parameter(&"tint", color if (use_tint and _orbit_tinted) else _orbit_color)
	if _light:
		_light.visible = Look.is_high()
		_light.light_energy = _light_energy
	if _tag:
		_tag_time = 0.0
		_tag.modulate = color if use_tint else _tag_color
		_update_tag()
	_apply_speed(true)


## Keeps the effect alive for `seconds` from now, following `target` (at `offset`) if given.
func hold(seconds: float, target: Node3D = null, offset: Vector3 = Vector3.ZERO) -> void:
	if not playing:
		return
	_end = _time + maxf(seconds, 0.0)
	_follow = target
	_following = target != null
	_follow_offset = offset
	_update_follow()


## Ends the effect now and hands it back to the pool.
func stop() -> void:
	if not playing:
		return
	playing = false
	_follow = null
	_following = false
	visible = false
	set_process(false)
	for p in _emitters:
		p.emitting = false
	if _light:
		_light.visible = false
	done.emit(self)


func _process(delta: float) -> void:
	_apply_speed(false)
	_tag_time += delta
	delta *= _speed
	_time += delta
	_update_follow()
	if _orbit:
		_orbit.rotate_y(_orbit_speed * delta)
		# pop in, bob, shrink away in the last 0.25 s
		var s := minf(_time / 0.15, 1.0) * clampf((_end - _time) / 0.25, 0.0, 1.0)
		_orbit.scale = Vector3.ONE * maxf(s, 0.01)
		_orbit.position.y = sin(_time * 5.0) * 0.04
	if _light and _light.visible:
		_light.light_energy = _light_energy * clampf(1.0 - _time / _light_time, 0.0, 1.0)
	if _tag:
		_update_tag()
	if _time >= _end:
		stop()


func _apply_speed(force: bool) -> void:
	var s := FeelTime.scale
	if not force and is_equal_approx(s, _speed):
		return
	_speed = s
	for p in _emitters:
		p.speed_scale = s


## Tag: overshooting pop (0..0.22 s), slow rise, fade over the last 0.3 s.
func _update_tag() -> void:
	var t := _tag_time
	var end := duration
	var s: float
	if t < 0.1:
		s = lerpf(0.2, 1.35, t / 0.1)
	elif t < 0.22:
		s = lerpf(1.35, 1.0, (t - 0.1) / 0.12)
	else:
		s = 1.0
	_tag.scale = Vector3.ONE * s
	var life := clampf(t / maxf(end, 0.01), 0.0, 1.0)
	_tag.position = Vector3(0.0, TAG_BASE_HEIGHT + _tag_rise * (1.0 - pow(1.0 - life, 2.0)), 0.0)
	var a := clampf((end - t) / 0.3, 0.0, 1.0)
	_tag.modulate.a = a
	_tag.outline_modulate.a = a


func _update_follow() -> void:
	if not _following:
		return
	if not is_instance_valid(_follow) or not _follow.is_inside_tree() or not _follow.is_visible_in_tree():
		stop()
		return
	global_position = _follow.global_position + _follow_offset
