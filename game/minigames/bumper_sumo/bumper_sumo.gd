class_name BumperSumo
extends Minigame
## Bumper Sumo: a round wrestling platform floating in the sky. Shove everyone else off.
## The platform is a core disc (radius 3 m) plus three rings out to 5, 7 and 9 m (tops at
## y = 0). Every DROP_INTERVAL seconds the outermost remaining ring warns (flash, shake,
## `platform_crack`, banner) for WARN_TIME seconds, then drops (`platform_fall`): its
## collider goes away on every peer when the host's reliable RPC arrives. The core never
## drops. A player below FALL_Y is knocked out (reason `fell`). Last blob standing wins.
## Start radius 9 m; rounds of SMALL_ROUND_PLAYERS or fewer start on 7 m (ring 3 absent).
##
## Collision: each ring's StaticBody3D carries a flat cylinder (built in _ready) of the
## ring's OUTER radius. Rings drop from the outside in, so the union of the present
## cylinders is always exactly the present platform, with no seams for a blob to snag on.
##
## Host decides (ring schedule, knock-outs, the end); clients learn it through the
## `call_local` RPCs below. Visuals (flash, shake, fall, clouds, lanterns) run on every peer
## in `_process` from the ring states those RPCs set.
## Spawns: in `_setup` the host picks a random turn and sends it with the round order
## (`_rpc_spawn_layout`); every peer places the N players evenly around the spawn circle
## (`spawn_layout`), each facing the centre. 8 players use the `Spawns` markers (already an
## even 45-degree ring of 4.5 m) turned the same way; fewer use SPAWN_RADIUS = that ring's
## radius. Balance: with the markers, 3 players' slot 2 started beside the 0-vs-1 face-off.
## Time-out: under Session the backstop ends the round and ranks survivors equally; without
## a Session driving this round (tests, sandbox) the minigame finishes itself at time_limit.

## A ring's warning started (every peer). `index` 1..3.
signal ring_warned(index: int)
## A ring dropped and its collider is gone (every peer). `index` 1..3.
signal ring_dropped(index: int)
## Every peer, once the host's spawn layout is applied: the turn (radians) and the slots in
## layout order.
signal spawn_layout_applied(turn: float, slots: PackedInt32Array)

enum RingState { PRESENT, WARNING, DROPPED }

## Outer radius of the core (index 0) and of rings 1..3, metres.
const RING_RADII: Array[float] = [3.0, 5.0, 7.0, 9.0]
## Seconds between ring drops (the k-th drop happens at k * DROP_INTERVAL after the start).
const DROP_INTERVAL := 12.0
## Seconds of warning (flash + shake) before a drop.
const WARN_TIME := 2.5
## Players below this height are out.
const FALL_Y := -6.0
## Radius (m) of the spawn circle for fewer than 8 players (the markers' ring).
const SPAWN_RADIUS := 4.5
## Bots keep this far inside the edge of the safe platform (m).
const SAFE_MARGIN := 1.2
## Bot goals are random points within this fraction of the safe radius (plus a floor).
const GOAL_SPREAD := 0.3
const GOAL_MIN_RADIUS := 1.1

## Tuning applied to every player on every peer in _setup. Balance pass (docs/balance.md):
## force 10 x knockback 1.05 rang blobs out from mid-platform, so 4-bot rounds lasted
## ~22 s; 8.5 x 1.0 makes the shrinking rings the finisher (4 bots ~33 s, 8 bots ~38 s).
const SHOVE_FORCE := 8.5
const SHOVE_COOLDOWN := 0.45
const KNOCKBACK_MULTIPLIER := 1.0
## Rounds with this many players or fewer start without ring 3 (on the 7 m platform).
## 0: every round starts on the full 9 m platform (balance pass: with the softer shove,
## 2-3 player rounds on 7 m were over in ~17 s; on 9 m they last ~27-30 s).
const SMALL_ROUND_PLAYERS := 0

const LANTERN_SCENE: PackedScene = preload("res://assets/models/props/sumo_lantern.glb")
const CLOUD_SCENE: PackedScene = preload("res://assets/models/props/cloud_puff.glb")

## Thickness of the platform colliders (m).
const THICKNESS := 0.6

## Seed for the bot goal picks (host). Tests may set it before _start.
var goal_seed: int = -1

## Ring states, index 0 (core, always PRESENT) .. 3.
var ring_states: Array[RingState] = [RingState.PRESENT, RingState.PRESENT, RingState.PRESENT, RingState.PRESENT]
## Seconds of play since _start (host: advanced by _host_tick).
var elapsed: float = 0.0

var _drops_done: int = 0
var _goal_rng := RandomNumberGenerator.new()
var _warn_time: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _drop_time: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _flash_materials: Array[StandardMaterial3D] = []
var _clouds: Array[Node3D] = []
var _cloud_base: Array[Vector3] = []
var _lanterns: Array[Node3D] = []
var _anim_time: float = 0.0

@onready var _bodies: Array[StaticBody3D] = [$Platform/Core, $Platform/Ring1, $Platform/Ring2, $Platform/Ring3]
@onready var _camera: ArenaCamera = $ArenaCamera as ArenaCamera


func _ready() -> void:
	for i in _bodies.size():
		var body := _bodies[i]
		var shape_node := body.get_node(^"Shape") as CollisionShape3D
		shape_node.shape = _disc(RING_RADII[i])
		shape_node.position = Vector3(0.0, -THICKNESS * 0.5, 0.0)
		var model := body.get_node(^"Model") as Node3D
		Look.apply_toon(model)
		var flash := StandardMaterial3D.new()
		flash.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flash.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		flash.albedo_color = Color(1.0, 0.55, 0.2, 0.0)
		flash.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		flash.render_priority = 1
		_flash_materials.append(flash)
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_overlay = flash
	_build_decor()


# --- Minigame flow --------------------------------------------------------------------------

func _setup(setup_players: Array[Player]) -> void:
	for p in setup_players:
		var shove := p.get_component(&"shove") as ShoveComponent
		if shove:
			shove.force = SHOVE_FORCE
			shove.cooldown = SHOVE_COOLDOWN
		var status := p.get_component(&"status") as StatusComponent
		if status:
			status.knockback_multiplier = KNOCKBACK_MULTIPLIER
	# Small rounds (SMALL_ROUND_PLAYERS) start on the 7 m platform: ring 3 is simply not there.
	if setup_players.size() <= SMALL_ROUND_PLAYERS:
		ring_states[3] = RingState.DROPPED
		_set_solid(3, false)
		(_bodies[3].get_node(^"Model") as Node3D).visible = false
	if multiplayer.is_server():
		var slots := PackedInt32Array()
		for p in setup_players:
			slots.append(p.slot)
		_rpc_spawn_layout.rpc(randf() * TAU, slots)
	_update_camera_bounds()


func _start() -> void:
	elapsed = 0.0
	if goal_seed >= 0:
		_goal_rng.seed = goal_seed
	else:
		_goal_rng.randomize()
	if multiplayer.is_server() and not finished.is_connected(_on_finished):
		finished.connect(_on_finished)


func _host_tick(delta: float) -> void:
	if is_finished():
		return
	elapsed += delta
	# Falls first: a blob below FALL_Y is out (lowest first, so a simultaneous fall leaves
	# the highest one standing).
	var fallers: Array[Player] = []
	for p in players:
		if is_instance_valid(p) and p.alive and p.global_position.y < FALL_Y:
			fallers.append(p)
	fallers.sort_custom(func(a: Player, b: Player) -> bool: return a.global_position.y < b.global_position.y)
	for p in fallers:
		knock_out_fell(p)
	if is_finished():
		return

	# Ring schedule.
	var outer := outermost_ring()
	if outer > 0:
		var drop_at := DROP_INTERVAL * (_drops_done + 1)
		if ring_states[outer] == RingState.PRESENT and elapsed >= drop_at - WARN_TIME:
			_rpc_ring_warn.rpc(outer)
		elif ring_states[outer] == RingState.WARNING and elapsed >= drop_at:
			_drops_done += 1
			_rpc_ring_drop.rpc(outer)

	# Time limit without a Session driving this round (tests, sandbox). Under Session its
	# backstop finishes the round a moment later and ranks the survivors equally.
	if time_limit > 0.0 and elapsed >= time_limit and not _session_drives():
		var ranking := _alive_slots()
		for i in range(knocked_out.size() - 1, -1, -1):
			if not ranking.has(knocked_out[i]):
				ranking.append(knocked_out[i])
		finish(ranking)


## Host: like knock_out, with the reason `fell`.
func knock_out_fell(player: Player) -> void:
	if is_finished() or player == null or not player.alive:
		return
	knocked_out.append(player.slot)
	player.eliminate(&"fell")
	var alive_slots := _alive_slots()
	if alive_slots.size() <= 1:
		var ranking: Array[int] = alive_slots.duplicate()
		for i in range(knocked_out.size() - 1, -1, -1):
			ranking.append(knocked_out[i])
		finish(ranking)


# --- Bots -----------------------------------------------------------------------------------

## A random point near the middle of the safe platform, different per call, so bots brawl
## around the centre instead of all standing on one spot.
func get_bot_goal(_player: Player) -> Vector3:
	var r_max := maxf(safe_radius() * GOAL_SPREAD, GOAL_MIN_RADIUS)
	var r := r_max * sqrt(_goal_rng.randf())
	var a := _goal_rng.randf() * TAU
	return global_position + Vector3(cos(a) * r, 0.0, sin(a) * r)


## True only on a ring that is present and not warning, SAFE_MARGIN inside its edge.
func is_safe(pos: Vector3) -> bool:
	var flat := Vector2(pos.x - global_position.x, pos.z - global_position.z)
	return flat.length() <= safe_radius() - SAFE_MARGIN


# --- Queries --------------------------------------------------------------------------------

## Index of the outermost ring that has not dropped (0 = only the core is left).
func outermost_ring() -> int:
	for i in range(RING_RADII.size() - 1, 0, -1):
		if ring_states[i] != RingState.DROPPED:
			return i
	return 0


## Radius of the platform that is present and not warning.
func safe_radius() -> float:
	for i in range(RING_RADII.size() - 1, 0, -1):
		if ring_states[i] == RingState.PRESENT:
			return RING_RADII[i]
	return RING_RADII[0]


## Radius of the platform that still has collision.
func platform_radius() -> float:
	return RING_RADII[outermost_ring()]


## True while ring `index` has an enabled collider.
func is_ring_solid(index: int) -> bool:
	var shape := _bodies[index].get_node(^"Shape") as CollisionShape3D
	return not shape.disabled and _bodies[index].collision_layer != 0


## Spawn points (local to the minigame) for `count` players, turned by `turn` radians about
## the centre, each facing the centre: the 8 markers when there are as many players (they
## are an even ring), else point i at angle `turn + TAU * i / count` from +Z on SPAWN_RADIUS.
func spawn_layout(count: int, turn: float) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var turned := Transform3D(Basis(Vector3.UP, turn), Vector3.ZERO)
	var markers := get_spawn_points()
	if count == markers.size():
		var to_local := global_transform.affine_inverse()
		for m in markers:
			out.append(turned * (to_local * m))
		return out
	for i in count:
		var a := TAU * i / count
		out.append(turned * Transform3D(Basis(Vector3.UP, a + PI), Vector3(sin(a), 0.0, cos(a)) * SPAWN_RADIUS))
	return out


# --- RPCs (host -> every peer) ----------------------------------------------------------------

## The host's spawn layout: `slots[i]` goes to point i of `spawn_layout(slots.size(), turn)`.
## Sent from `_setup` (players are frozen until the countdown ends), so it lands before play.
@rpc("authority", "call_local", "reliable")
func _rpc_spawn_layout(turn: float, slots: PackedInt32Array) -> void:
	var points := spawn_layout(slots.size(), turn)
	for i in slots.size():
		for p in players:
			if is_instance_valid(p) and p.slot == slots[i]:
				p.place_at(global_transform * points[i])
	spawn_layout_applied.emit(turn, slots)


@rpc("authority", "call_local", "reliable")
func _rpc_ring_warn(index: int) -> void:
	if index <= 0 or index >= RING_RADII.size() or ring_states[index] != RingState.PRESENT:
		return
	ring_states[index] = RingState.WARNING
	_warn_time[index] = _anim_time
	RoundUI.push_banner("Ring dropping!", 2.0)
	Sfx.play(&"platform_crack", global_position + Vector3(0.0, 0.0, RING_RADII[index] - 1.0))
	if _camera:
		_camera.add_shake(0.2)
	ring_warned.emit(index)


@rpc("authority", "call_local", "reliable")
func _rpc_ring_drop(index: int) -> void:
	if index <= 0 or index >= RING_RADII.size() or ring_states[index] == RingState.DROPPED:
		return
	ring_states[index] = RingState.DROPPED
	_drop_time[index] = _anim_time
	_set_solid(index, false)
	_update_camera_bounds()
	Sfx.play(&"platform_fall", global_position + Vector3(0.0, 0.0, RING_RADII[index] - 1.0))
	if _camera:
		_camera.add_shake(0.45)
	if outermost_ring() == 0:
		RoundUI.push_banner("Last stand!", 2.0)
	ring_dropped.emit(index)


@rpc("authority", "call_local", "reliable")
func _rpc_celebrate(slots: Array) -> void:
	var stage := get_tree().get_first_node_in_group(&"stage") as Stage if is_inside_tree() else null
	if stage == null:
		return
	for s: Variant in slots:
		var p := stage.get_player(int(s))
		if p == null or not is_instance_valid(p) or not p.alive:
			continue
		Fx.play(&"confetti", p.global_position + Vector3.UP * 1.2)
		var visuals := p.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"cheer", true)


# --- Internals ------------------------------------------------------------------------------

func _on_finished(ranking: Array[int]) -> void:
	var winners: Array = []
	for s in _alive_slots():
		if ranking.has(s):
			winners.append(s)
	if not winners.is_empty():
		_rpc_celebrate.rpc(winners)


func _session_drives() -> bool:
	return Session.current_minigame == self and Session.state == Session.State.PLAYING


func _alive_slots() -> Array[int]:
	var out: Array[int] = []
	for p in players:
		if is_instance_valid(p) and p.alive:
			out.append(p.slot)
	out.sort()
	return out


## A flat cylinder collider with its top at y = 0.
static func _disc(radius: float) -> CylinderShape3D:
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = THICKNESS
	return shape


func _set_solid(index: int, solid: bool) -> void:
	var body := _bodies[index]
	var shape := body.get_node(^"Shape") as CollisionShape3D
	shape.disabled = not solid
	body.collision_layer = 1 if solid else 0


func _update_camera_bounds() -> void:
	if _camera:
		_camera.bounds_radius = maxf(platform_radius() - 1.5, 2.0)


func _process(delta: float) -> void:
	_anim_time += delta
	_animate_rings()
	_animate_decor()


func _animate_rings() -> void:
	for i in range(1, RING_RADII.size()):
		var model := _bodies[i].get_node(^"Model") as Node3D
		var flash := _flash_materials[i]
		match ring_states[i]:
			RingState.PRESENT:
				model.position = Vector3.ZERO
				flash.albedo_color.a = 0.0
			RingState.WARNING:
				var t := _anim_time - _warn_time[i]
				var k := clampf(t / WARN_TIME, 0.0, 1.0)
				var freq := lerpf(5.0, 12.0, k)
				flash.albedo_color.a = (0.5 + 0.5 * sin(t * TAU * freq)) * lerpf(0.6, 1.0, k)
				var amp := lerpf(0.02, 0.09, k)
				model.position = Vector3(sin(t * 53.0), sin(t * 41.0) * 0.5, cos(t * 47.0)) * amp
			RingState.DROPPED:
				flash.albedo_color.a = 0.0
				if not model.visible:
					continue
				var t := _anim_time - _drop_time[i]
				model.position = Vector3(0.0, -0.5 * 16.0 * t * t, 0.0)
				model.rotation = Vector3(0.12 * t * (1.0 if i % 2 == 0 else -1.0), 0.15 * t, 0.08 * t)
				if model.position.y < -60.0:
					model.visible = false


# --- Decor ------------------------------------------------------------------------------------

func _build_decor() -> void:
	var decor := $Decor as Node3D
	# Lanterns on little clouds floating just outside the rim.
	for i in 4:
		var a := deg_to_rad(45.0 + 90.0 * i)
		var holder := Node3D.new()
		holder.name = "LanternCloud%d" % i
		holder.position = Vector3(cos(a), 0.0, sin(a)) * 11.2 + Vector3(0.0, -1.1, 0.0)
		decor.add_child(holder)
		var cloud := CLOUD_SCENE.instantiate() as Node3D
		cloud.scale = Vector3.ONE * 0.75
		cloud.rotation.y = a
		holder.add_child(cloud)
		Look.apply_toon(cloud, false)
		var lantern := LANTERN_SCENE.instantiate() as Node3D
		lantern.position = Vector3(0.0, 0.75, 0.0)
		holder.add_child(lantern)
		Look.apply_toon(lantern)
		_lanterns.append(holder)
	# Drifting clouds below and around the platform.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7331
	for i in 16:
		var a := TAU * i / 16.0 + rng.randf_range(-0.2, 0.2)
		var r := rng.randf_range(13.0, 30.0)
		var y := rng.randf_range(-14.0, -3.5) if i % 4 != 0 else rng.randf_range(-2.0, 1.0)
		if y > -3.0:
			r += 8.0
		var cloud := CLOUD_SCENE.instantiate() as Node3D
		cloud.name = "Cloud%d" % i
		cloud.position = Vector3(cos(a) * r, y, sin(a) * r)
		cloud.rotation.y = rng.randf() * TAU
		cloud.scale = Vector3.ONE * rng.randf_range(1.6, 3.2)
		decor.add_child(cloud)
		Look.apply_toon(cloud, false)
		_clouds.append(cloud)
		_cloud_base.append(cloud.position)


func _animate_decor() -> void:
	var t := _anim_time
	for i in _clouds.size():
		var base := _cloud_base[i]
		# Slow drift around the platform plus a gentle bob.
		var ang := t * (0.012 + 0.004 * (i % 3))
		var p := base.rotated(Vector3.UP, ang)
		p.y += sin(t * 0.5 + i * 1.7) * 0.3
		_clouds[i].position = p
	for i in _lanterns.size():
		var holder := _lanterns[i]
		holder.position.y = -1.1 + sin(t * 0.9 + i * 1.3) * 0.18
		holder.rotation = Vector3(sin(t * 1.3 + i) * 0.06, 0.0, sin(t * 1.1 + i * 2.1) * 0.07)
