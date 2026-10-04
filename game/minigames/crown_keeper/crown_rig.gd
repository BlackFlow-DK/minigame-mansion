extends Node3D
## Crown Keeper presentation: the crown and everything that marks its wearer, on every peer.
## Pure presentation: the minigame says where the crown is (`show_throne`, `show_worn`,
## `launch`, `show_loose`, `celebrate`); this node only animates it.
##   On the throne: hovers over the seat, slowly turning, glowing.
##   Worn: sits on the wearer's head ABOVE any hat (it reads the hat's height under the
##     HatSocket each frame it is put on, so it follows squash, lean and body size), plus a
##     golden light pillar, a floor ring, a sparkle trail and (not on LOW) a warm light.
##   Flying: follows `arc_pos` (a pure function of the host-sent launch, identical on every
##     peer), spinning, with a ring on the floor where it will come to rest.
## Quality: in group Look.QUALITY_GROUP; LOW drops the light and thins the sparkles.

const CROWN_SCENE: PackedScene = preload("res://assets/models/props/crown_royal.glb")

enum Mode { HIDDEN, THRONE, WORN, FLYING, LOOSE }

## Crown scale on a head (the model is 0.47 m across; a blob head is ~0.8 m).
const WORN_SCALE := 1.6
## Crown scale on the throne and on the floor (bigger: it is the prize).
const PRIZE_SCALE := 1.45
## Without a hat the crown sinks this much onto the head top (HatSocket units).
const BARE_SINK := -0.07
## Peak heights (m) of the knock-off arc and of its bounce, above the straight line.
const ARC_PEAK := 1.0
const BOUNCE_PEAK := 0.35
const GOLD := Color(1.0, 0.78, 0.25)
## The wearer's light pillar: height (m) from the feet up.
const BEAM_HEIGHT := 4.2
const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 color : source_color = vec4(1.0, 0.7, 0.12, 1.0);
uniform float strength = 0.6;
uniform float height = 3.0;
varying float h;
void vertex() {
	h = clamp(VERTEX.y / height + 0.5, 0.0, 1.0);
}
void fragment() {
	float rim = 1.0 - abs(dot(NORMAL, VIEW));
	float fade = pow(1.0 - h, 0.9) * mix(0.3, 1.0, smoothstep(0.12, 0.34, h)) * smoothstep(0.0, 0.05, h);
	ALBEDO = mix(color.rgb, vec3(1.0, 0.97, 0.8), 0.35 * (1.0 - rim));
	ALPHA = clamp(strength * fade * (0.35 + 0.65 * rim), 0.0, 1.0);
}
"""

var mode: Mode = Mode.HIDDEN
## The wearer (Mode.WORN), or null.
var target: Player = null
## Where the crown rests on the throne (base of the crown), set by the minigame.
var throne_pos: Vector3 = Vector3.ZERO
## True in the double-points finale: everything glows a bit more.
var finale: bool = false

var _crown: Node3D
var _glow: MeshInstance3D
var _glow_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _marker: MeshInstance3D
var _beam: MeshInstance3D
var _beam_mat: ShaderMaterial
var _sparkles: CPUParticles3D
var _light: OmniLight3D
var _spot: SpotLight3D
var _time: float = 0.0
var _hat_lift: float = BARE_SINK
var _pop: float = 0.0
# Flight (every peer, from the host's launch).
var _from: Vector3
var _l1: Vector3
var _l2: Vector3
var _t1: float = 0.55
var _t2: float = 0.28
var _flight_t: float = 0.0
var _clock_scale: float = 1.0
var _rest_yaw: float = 0.0


## Crown position at `t` seconds after a knock: an arc from `from` (the wearer's head) to
## `l1`, then a small bounce to `l2`, then at rest. Pure, so every peer that knows the
## host's launch (from, l1, l2, t1, t2) puts the crown at the same place at the same time.
static func arc_pos(from: Vector3, l1: Vector3, l2: Vector3, t1: float, t2: float, t: float) -> Vector3:
	if t <= 0.0:
		return from
	if t < t1:
		var u := t / t1
		var p := from.lerp(l1, u)
		p.y += 4.0 * ARC_PEAK * u * (1.0 - u)
		return p
	if t < t1 + t2:
		var u := (t - t1) / t2
		var p := l1.lerp(l2, u)
		p.y += 4.0 * BOUNCE_PEAK * u * (1.0 - u)
		return p
	return l2


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	add_to_group(Look.QUALITY_GROUP)
	_crown = CROWN_SCENE.instantiate() as Node3D
	_crown.name = "Crown"
	add_child(_crown)
	Look.apply_toon(_crown)

	_glow = MeshInstance3D.new()
	_glow.name = "Glow"
	var sphere := SphereMesh.new()
	sphere.radius = 0.42
	sphere.height = 0.62
	sphere.radial_segments = 16
	sphere.rings = 8
	_glow.mesh = sphere
	_glow.position.y = 0.16
	_glow_mat = _additive(Color(1.0, 0.7, 0.2, 0.25))
	_glow.material_override = _glow_mat
	_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_crown.add_child(_glow)

	_ring = _flat_ring("Ring", 0.6, 0.95)
	_ring_mat = _ring.material_override as StandardMaterial3D
	add_child(_ring)
	_marker = _flat_ring("LandingMarker", 0.3, 0.42)
	(_marker.material_override as StandardMaterial3D).albedo_color = Color(1.0, 0.85, 0.35, 0.7)
	add_child(_marker)

	_beam = MeshInstance3D.new()
	_beam.name = "Beam"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.68
	cyl.height = BEAM_HEIGHT
	cyl.radial_segments = 20
	cyl.rings = 4
	cyl.cap_top = false
	cyl.cap_bottom = false
	_beam.mesh = cyl
	var shader := Shader.new()
	shader.code = BEAM_SHADER
	_beam_mat = ShaderMaterial.new()
	_beam_mat.shader = shader
	_beam_mat.set_shader_parameter(&"height", cyl.height)
	_beam.material_override = _beam_mat
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beam)

	_sparkles = CPUParticles3D.new()
	_sparkles.name = "Sparkles"
	_sparkles.local_coords = false
	_sparkles.lifetime = 0.9
	_sparkles.explosiveness = 0.0
	_sparkles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_sparkles.emission_sphere_radius = 0.28
	_sparkles.direction = Vector3.UP
	_sparkles.spread = 70.0
	_sparkles.initial_velocity_min = 0.3
	_sparkles.initial_velocity_max = 0.9
	_sparkles.gravity = Vector3(0.0, -1.2, 0.0)
	_sparkles.scale_amount_min = 0.6
	_sparkles.scale_amount_max = 1.3
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	_sparkles.scale_amount_curve = curve
	var dot := SphereMesh.new()
	dot.radius = 0.035
	dot.height = 0.07
	dot.radial_segments = 6
	dot.rings = 3
	dot.material = _additive(Color(1.0, 0.85, 0.35, 0.95))
	_sparkles.mesh = dot
	add_child(_sparkles)

	_light = OmniLight3D.new()
	_light.name = "Light"
	_light.light_color = Color(1.0, 0.8, 0.4)
	_light.omni_range = 4.5
	_light.light_energy = 1.6
	_light.shadow_enabled = false
	add_child(_light)

	_spot = SpotLight3D.new()
	_spot.name = "WinnerSpot"
	_spot.light_color = Color(1.0, 0.9, 0.65)
	_spot.light_energy = 0.0
	_spot.spot_range = 12.0
	_spot.spot_angle = 16.0
	_spot.shadow_enabled = false
	add_child(_spot)
	apply_quality()
	_apply_mode()


## Look quality switch (also live).
func apply_quality() -> void:
	var low := Look.is_low()
	if _sparkles:
		_sparkles.amount = 10 if low else 28
	if _light:
		_light.visible = not low and mode != Mode.HIDDEN


func show_throne(pos: Vector3) -> void:
	throne_pos = pos
	target = null
	mode = Mode.THRONE
	_pop = 1.0
	_apply_mode()


## Puts the crown on `p`'s head.
func show_worn(p: Player) -> void:
	target = p
	mode = Mode.WORN if p else Mode.HIDDEN
	_hat_lift = _measure_hat_lift(p)
	_pop = 1.0
	_apply_mode()
	_follow()


## Starts the knock-off flight (see arc_pos). `clock_scale`: the host's game-clock rate.
func launch(from: Vector3, l1: Vector3, l2: Vector3, t1: float, t2: float, clock_scale: float = 1.0) -> void:
	target = null
	_from = from
	_l1 = l1
	_l2 = l2
	_t1 = t1
	_t2 = t2
	_flight_t = 0.0
	_clock_scale = maxf(clock_scale, 0.001)
	_rest_yaw = atan2(l2.x - from.x, l2.z - from.z)
	mode = Mode.FLYING
	_apply_mode()
	_follow()


## Dev (screenshots): freezes the current flight at `t` seconds.
func hold_at(t: float) -> void:
	_flight_t = t
	_clock_scale = 0.0


## The crown lies at `pos` (where a flight ended).
func show_loose(pos: Vector3) -> void:
	target = null
	_l2 = pos
	mode = Mode.LOOSE
	_apply_mode()


## End of the round: the crown on the winner, a spotlight on them.
func celebrate(winner: Player) -> void:
	show_worn(winner)
	finale = true
	if _spot:
		_spot.light_energy = 9.0


## World position of the crown's base now.
func crown_position() -> Vector3:
	return _crown.global_position if _crown else global_position


func crown_node() -> Node3D:
	return _crown


## Seconds into the current flight (every peer's own clock; tests).
func flight_time() -> float:
	return _flight_t


func _physics_process(delta: float) -> void:
	if mode == Mode.FLYING:
		_flight_t += delta * _clock_scale
		if _flight_t >= _t1 + _t2:
			mode = Mode.LOOSE
			_apply_mode()


func _process(delta: float) -> void:
	_time += delta
	_pop = maxf(_pop - delta * 3.0, 0.0)
	if mode == Mode.WORN and (target == null or not is_instance_valid(target) or not target.alive):
		# The wearer left: hide until the minigame says where the crown went.
		mode = Mode.HIDDEN
		_apply_mode()
	if mode == Mode.HIDDEN:
		return
	_follow()
	var pulse := 0.5 + 0.5 * sin(_time * (7.0 if finale else 4.0))
	var boost := 1.35 if finale else 1.0
	_glow_mat.albedo_color = Color(1.0, 0.7, 0.2, (0.12 + 0.12 * pulse + 0.3 * _pop) * boost)
	_glow.scale = Vector3.ONE * (1.0 + 0.6 * _pop)
	var rc := Color(1.0, 0.72, 0.12, minf((0.7 + 0.3 * pulse) * boost, 1.0))
	_ring_mat.albedo_color = rc
	var rs := 1.0 + 0.12 * pulse + 0.5 * _pop
	_ring.scale = Vector3(rs, 0.2, rs)
	_beam_mat.set_shader_parameter(&"strength", (0.95 + 0.25 * pulse) * boost)
	if _light.visible:
		_light.light_energy = (1.3 + 0.6 * pulse) * boost
	_marker.rotation.y = _time * 2.5


func _follow() -> void:
	var at := Vector3.ZERO
	match mode:
		Mode.THRONE:
			at = throne_pos + Vector3.UP * (0.12 + 0.05 * sin(_time * 2.2))
			_crown.global_transform = Transform3D(Basis(Vector3.UP, _time * 0.8).scaled(Vector3.ONE * PRIZE_SCALE), at)
			_ring.global_position = Vector3(at.x, throne_pos.y + 0.02, at.z)
		Mode.WORN:
			_crown.global_transform = _head_transform()
			at = _crown.global_position
			var feet := target.global_position
			_ring.global_position = feet + Vector3.UP * 0.04
			_beam.global_position = feet + Vector3.UP * (BEAM_HEIGHT * 0.5 + 0.05)
		Mode.FLYING:
			at = arc_pos(_from, _l1, _l2, _t1, _t2, _flight_t)
			var spin := Basis(Vector3.UP, _rest_yaw + _flight_t * 9.0) * Basis(Vector3.RIGHT, sin(_flight_t * 11.0) * 0.6)
			_crown.global_transform = Transform3D(spin.scaled(Vector3.ONE * PRIZE_SCALE), at)
			_marker.global_position = _l2 + Vector3.UP * 0.03
			_ring.global_position = Vector3(at.x, _l2.y + 0.03, at.z)
		Mode.LOOSE:
			at = _l2
			var tilt := Basis(Vector3.UP, _rest_yaw) * Basis(Vector3.RIGHT, 0.32)
			var bob := 0.03 * sin(_time * 3.0)
			_crown.global_transform = Transform3D(tilt.scaled(Vector3.ONE * PRIZE_SCALE), at + Vector3.UP * (0.07 + bob))
			_ring.global_position = _l2 + Vector3.UP * 0.03
	_sparkles.global_position = _crown.global_position + Vector3.UP * 0.2
	_light.global_position = _crown.global_position + Vector3.UP * 0.6
	if _spot and _spot.light_energy > 0.0 and target and is_instance_valid(target):
		var above := target.global_position + Vector3(0.0, 7.0, 1.5)
		_spot.look_at_from_position(above, target.global_position + Vector3.UP * 0.6, Vector3.UP)


## The crown on the wearer's head: under HatSocket's transform (squash, lean, body size),
## lifted over whatever hat is there.
func _head_transform() -> Transform3D:
	var socket := _hat_socket(target)
	if socket and socket.is_inside_tree():
		var wobble := Basis(Vector3.FORWARD, 0.05 * sin(_time * 5.0))
		var lift := Transform3D(wobble.scaled(Vector3.ONE * WORN_SCALE * (1.0 + 0.35 * _pop)), Vector3(0.0, _hat_lift, 0.0))
		return socket.global_transform * lift
	return Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * WORN_SCALE), target.global_position + Vector3.UP * 0.95)


static func _hat_socket(p: Player) -> Node3D:
	if p == null or not is_instance_valid(p):
		return null
	var vis := p.get_component(&"visuals") as VisualsComponent
	var root := vis.get_model_root() if vis else null
	if root == null:
		return null
	return root.find_child("HatSocket", true, false) as Node3D


## Top of the worn hat in HatSocket space (0.92 of it: the crown nests a little), or
## BARE_SINK without a hat.
static func _measure_hat_lift(p: Player) -> float:
	var socket := _hat_socket(p)
	if socket == null:
		return BARE_SINK
	var hat := socket.get_node_or_null(^"Cosmetic_hat") as Node3D
	if hat == null:
		return BARE_SINK
	var top := -INF
	var inv := socket.global_transform.affine_inverse()
	for n in hat.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_inside_tree():
			continue
		var box := (inv * mi.global_transform) * mi.get_aabb()
		top = maxf(top, box.end.y)
	if top == -INF:
		return BARE_SINK
	return maxf(top * 0.92, BARE_SINK)


func _apply_mode() -> void:
	if _crown == null:
		return
	var shown := mode != Mode.HIDDEN
	_crown.visible = shown
	_ring.visible = shown
	_sparkles.emitting = shown
	_beam.visible = mode == Mode.WORN
	_marker.visible = mode == Mode.FLYING
	_light.visible = shown and not Look.is_low()
	if not shown and _spot:
		_spot.light_energy = 0.0


func _flat_ring(ring_name: String, inner: float, outer: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = ring_name
	var torus := TorusMesh.new()
	torus.inner_radius = inner
	torus.outer_radius = outer
	torus.rings = 32
	torus.ring_segments = 6
	mi.mesh = torus
	mi.scale = Vector3(1.0, 0.2, 1.0)
	var m := _additive(GOLD)
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX  # reads on the cream tiles too
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _additive(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = color
	m.disable_receive_shadows = true
	return m
