extends Node
## Autoload `Fx`: one-shot visual effects in the world. Owner: look and effects.
##
##   Fx.play(&"hit_stars", pos, attacker_colour)
##
## Effects (FxLibrary.NAMES): dust_puff, land_thud, shove_whoosh, hit_stars, stun_swirl,
## poof, respawn_sparkle, coin_pickup, explosion, confetti, splash_lava, shockwave, ko_tag.
## `color` tints the effect's tintable parts (WHITE keeps its own colours). Nodes are pooled
## per effect and recycled; an unknown name warns once and plays nothing.
## play() returns the FxEffect node (valid until it finishes; check `serial`) so a caller
## may turn it (shove_whoosh faces its local +Z), scale it, or `hold()` it on a target.
## Headless (tests, servers) it only raises `played` and returns null, unless
## `headless_spawn` is set.

## Raised on every successful play() call, also headless. Tests and tools listen to it.
signal played(effect: StringName, at: Vector3, color: Color)

## Most live nodes per effect (HIGH quality); past it the oldest one is restarted.
const POOL_MAX := 10
## Look quality (LOW, MEDIUM, HIGH) -> most live nodes per effect, particle count factor.
const POOL_MAX_BY_QUALITY: Array[int] = [4, 8, POOL_MAX]
const AMOUNT_BY_QUALITY: Array[float] = [0.5, 0.75, 1.0]

## Master switch (a settings menu may turn effects off).
var enabled: bool = true
## Spawn nodes even under the headless display server (tests).
var headless_spawn: bool = false

var _headless: bool = DisplayServer.get_name() == "headless"
var _idle: Dictionary[StringName, Array] = {}
var _live: Dictionary[StringName, Array] = {}
var _warned: Dictionary[StringName, bool] = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(Look.QUALITY_GROUP)


## Look quality switch: idle nodes built for another quality are rebuilt on their next use.
func apply_quality() -> void:
	for k: StringName in _idle:
		var keep: Array = []
		for v: Variant in _idle[k]:
			if not is_instance_valid(v):
				continue
			var fx := v as FxEffect
			if int(fx.get_meta(&"fx_quality", -1)) == Look.get_quality():
				keep.append(fx)
			else:
				fx.queue_free()
		_idle[k] = keep


## Most live nodes per effect at the current quality.
func pool_max() -> int:
	return POOL_MAX_BY_QUALITY[Look.get_quality()]


## Plays `effect` at world position `at`, tinted `color`. Returns the node, or null.
func play(effect: StringName, at: Vector3, color: Color = Color.WHITE) -> FxEffect:
	if not FxLibrary.has(effect):
		if not _warned.has(effect):
			_warned[effect] = true
			push_warning("Fx.play: unknown effect '%s'" % effect)
		return null
	played.emit(effect, at, color)
	if not enabled or (_headless and not headless_spawn):
		return null
	var fx := _take(effect)
	if fx == null:
		return null
	fx.transform = Transform3D(Basis.IDENTITY, at)
	fx.play(color)
	return fx


## Number of nodes of `effect` playing right now (all effects when empty).
func live_count(effect: StringName = &"") -> int:
	if effect != &"":
		return (_live.get(effect, []) as Array).size()
	var n := 0
	for k: StringName in _live:
		n += (_live[k] as Array).size()
	return n


## Number of pooled idle nodes of `effect`.
func idle_count(effect: StringName) -> int:
	return (_idle.get(effect, []) as Array).size()


## Stops every playing effect (they go back to the pool).
func stop_all() -> void:
	for k: StringName in _live.keys():
		for fx: FxEffect in (_live[k] as Array).duplicate():
			fx.stop()


## Stops everything and frees every pooled node.
func clear() -> void:
	stop_all()
	for k: StringName in _idle:
		for fx: FxEffect in _idle[k]:
			if is_instance_valid(fx):
				fx.queue_free()
	_idle.clear()
	_live.clear()


func _take(effect: StringName) -> FxEffect:
	var idle: Array = _idle.get_or_add(effect, [])
	var live: Array = _live.get_or_add(effect, [])
	var fx: FxEffect = null
	while fx == null and not idle.is_empty():
		fx = idle.pop_back() as FxEffect
		if not is_instance_valid(fx):
			fx = null
		elif int(fx.get_meta(&"fx_quality", -1)) != Look.get_quality():
			fx.queue_free()  # built for another quality
			fx = null
	if fx == null and live.size() >= pool_max():
		fx = live.pop_front() as FxEffect
		fx.stop()  # goes to idle through _on_done
		idle.erase(fx)
	if fx == null:
		fx = FxLibrary.build(effect)
		if fx == null:
			return null
		_cap_particles(fx)
		fx.done.connect(_on_done)
		add_child(fx)
	live.append(fx)
	return fx


## Scales every emitter's particle count for the current quality (LOW: half).
func _cap_particles(fx: FxEffect) -> void:
	var q := Look.get_quality()
	fx.set_meta(&"fx_quality", q)
	var k := AMOUNT_BY_QUALITY[q]
	if k >= 1.0:
		return
	for p in fx.find_children("*", "CPUParticles3D", true, false):
		var e := p as CPUParticles3D
		e.amount = maxi(1, ceili(e.amount * k))


func _on_done(fx: FxEffect) -> void:
	var live: Array = _live.get(fx.effect_name, [])
	live.erase(fx)
	var idle: Array = _idle.get_or_add(fx.effect_name, [])
	if not idle.has(fx):
		idle.append(fx)
