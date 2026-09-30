class_name ArenaCamera
extends Camera3D
## Arena camera rig: drop `res://camera/arena_camera.tscn` into a minigame or the lobby
## and make it `current`. It looks down at a fixed pitch and yaw (so "forward" on the
## controls never changes) and moves only its focus and distance:
##   FRAME_ALL     frames every living player of the Stage (default)
##   FOLLOW_LOCAL  follows this peer's own player at `follow_distance` (lobby)
##   FIXED         holds `fixed_focus` at `fixed_distance`
## `focus_on(node, seconds)` overrides the mode for intro/podium moments, and
## `add_shake(amount)` adds trauma-based screen shake (viewport offset only: the camera
## basis never shakes, so camera-relative controls stay steady).
## Players come from the Stage API (`stage` group, `Stage.players`); dead ones are ignored.
## With nothing to look at the camera holds where it is.

enum Mode { FRAME_ALL, FOLLOW_LOCAL, FIXED }
enum BoundsMode { NONE, BOX, RADIUS }

@export var mode: Mode = Mode.FRAME_ALL

@export_group("View")
## Degrees below the horizon the camera looks.
@export_range(10.0, 89.0, 0.5) var pitch_degrees: float = 50.0
## Degrees around +Y; 0 looks toward -Z (camera sits on the +Z side).
@export_range(-180.0, 180.0, 0.5) var yaw_degrees: float = 0.0
## Closest the camera gets to its focus, in metres.
@export var min_distance: float = 9.0
## Farthest the camera backs off from its focus, in metres.
@export var max_distance: float = 32.0
## Space kept around every framed player, in metres (on screen, at the player's depth).
@export var margin: float = 1.5
## Players are framed at this height above their origin (blob centre).
@export var target_height: float = 0.5
## Follow speed (1/s): higher is snappier. 0 = snap every frame.
@export var smoothing: float = 3.0

@export_group("Modes")
## FOLLOW_LOCAL: distance to the local player.
@export var follow_distance: float = 11.0
## FIXED: point looked at.
@export var fixed_focus: Vector3 = Vector3.ZERO
## FIXED: distance from `fixed_focus`; also where the camera starts before it has targets.
@export var fixed_distance: float = 18.0
## focus_on(): distance used for close-ups when no distance is passed.
@export var close_up_distance: float = 6.0

@export_group("Bounds")
## Keeps framed points and the focus inside an area, so a player flying off or falling
## into the void is not chased. RADIUS is a cylinder around `bounds_center` that also
## never looks below `bounds_center.y`.
@export var bounds_mode: BoundsMode = BoundsMode.NONE
@export var bounds_box: AABB = AABB(Vector3(-10.0, -1.0, -10.0), Vector3(20.0, 10.0, 20.0))
@export var bounds_center: Vector3 = Vector3.ZERO
@export var bounds_radius: float = 10.0

@export_group("Shake")
## Largest viewport offset at full trauma, in metres.
@export var max_shake_offset: float = 0.5
## Trauma lost per second.
@export var shake_decay: float = 1.6
## Shake noise speed.
@export var shake_frequency: float = 18.0

## Smoothed point the camera looks at.
var focus: Vector3 = Vector3.ZERO
## Smoothed distance from `focus` along the view axis.
var distance: float = 18.0
## Shake trauma 0..1; the offset scales with trauma squared.
var trauma: float = 0.0

var _has_target: bool = false
var _focus_node: Node3D = null
var _focus_time: float = 0.0
var _focus_distance: float = -1.0
var _shake_time: float = 0.0
var _noise: FastNoiseLite = FastNoiseLite.new()
var _stage: Stage = null


func _ready() -> void:
	_noise.seed = 7
	_noise.frequency = 1.0
	focus = fixed_focus
	distance = fixed_distance
	_apply_transform()


func _process(delta: float) -> void:
	update_camera(delta)


## Adds screen shake trauma (0..1 is meaningful; the total is capped at 1).
func add_shake(amount: float) -> void:
	trauma = clampf(trauma + amount, 0.0, 1.0)


## Looks at `node` from `close_up_distance` (or `at_distance` when > 0) for `seconds`,
## then returns to the mode. `seconds <= 0` holds until clear_focus(). Ends early if the
## node is freed.
func focus_on(node: Node3D, seconds: float, at_distance: float = -1.0) -> void:
	_focus_node = node
	_focus_time = seconds if seconds > 0.0 else INF
	_focus_distance = at_distance


## Ends a focus_on() override.
func clear_focus() -> void:
	_focus_node = null
	_focus_time = 0.0


## True while a focus_on() override is active.
func is_focusing() -> bool:
	return _focus_node != null


## Jumps straight to the current target (no smoothing), e.g. after a scene change.
func snap() -> void:
	var target := compute_target()
	if not target.is_empty():
		focus = target[0]
		distance = target[1]
		_has_target = true
	_apply_transform()


## Advances smoothing, focus timer and shake by `delta` seconds and places the camera.
## Called from _process; tests may disable processing and call it directly.
func update_camera(delta: float) -> void:
	if _focus_node != null:
		_focus_time -= delta
		if _focus_time <= 0.0 or not is_instance_valid(_focus_node) or not _focus_node.is_inside_tree():
			clear_focus()
	var target := compute_target()
	if not target.is_empty():
		var goal_focus: Vector3 = target[0]
		var goal_distance: float = target[1]
		if not _has_target or smoothing <= 0.0:
			focus = goal_focus
			distance = goal_distance
			_has_target = true
		else:
			var t := 1.0 - exp(-smoothing * delta)
			focus = focus.lerp(goal_focus, t)
			distance = lerpf(distance, goal_distance, t)
	_update_shake(delta)
	_apply_transform()


## Where the camera wants to be right now: `[focus: Vector3, distance: float]`, or empty
## when there is nothing to look at (the camera then holds).
func compute_target() -> Array:
	if _focus_node != null and is_instance_valid(_focus_node):
		var d := _focus_distance if _focus_distance > 0.0 else close_up_distance
		return [_clamp_to_bounds(_focus_node.global_position + Vector3.UP * target_height), d]
	match mode:
		Mode.FIXED:
			return [fixed_focus, fixed_distance]
		Mode.FOLLOW_LOCAL:
			var me := _local_player()
			if me == null:
				return []
			return [_clamp_to_bounds(me.global_position + Vector3.UP * target_height), follow_distance]
		_:
			var points := get_framed_points()
			if points.is_empty():
				return []
			var framed := frame_points(points, view_basis(), _tan_half_v(), _aspect(), margin)
			return [_clamp_to_bounds(framed[0]), clampf(framed[1], min_distance, max_distance)]


## Framed points (bounds applied) of every living player on the Stage.
func get_framed_points() -> Array[Vector3]:
	var points: Array[Vector3] = []
	for p in get_living_players():
		points.append(_clamp_to_bounds(p.global_position + Vector3.UP * target_height))
	return points


## Living players on the Stage (empty without a Stage).
func get_living_players() -> Array[Player]:
	var out: Array[Player] = []
	var stage := _get_stage()
	if stage == null:
		return out
	for p: Player in stage.players.values():
		if is_instance_valid(p) and p.is_inside_tree() and p.alive:
			out.append(p)
	return out


## The fixed camera orientation from `yaw_degrees` and `pitch_degrees`.
func view_basis() -> Basis:
	return Basis.from_euler(Vector3(-deg_to_rad(pitch_degrees), deg_to_rad(yaw_degrees), 0.0))


## Tightest framing of `points` for a camera with orientation `basis` (vertical half-FOV
## tangent `tan_half_v`, width/height `aspect`), keeping `pad` metres around each point.
## Solves the frustum's top/bottom and left/right planes exactly, so the group is centred
## on screen. Returns `[focus, distance]`: focus is where the view axis meets the points'
## mean height, distance is the camera's distance from it along the axis (unclamped).
static func frame_points(points: Array[Vector3], basis: Basis, tan_half_v: float, aspect: float, pad: float) -> Array:
	var tv := maxf(tan_half_v, 0.01)
	var th := tv * maxf(aspect, 0.01)
	var x_axis := basis.x
	var y_axis := basis.y
	var z_axis := basis.z
	var top := -INF
	var bottom := -INF
	var right := -INF
	var left := -INF
	var mean_y := 0.0
	for p in points:
		var lx := p.dot(x_axis)
		var ly := p.dot(y_axis)
		var lz := p.dot(z_axis)
		top = maxf(top, ly + tv * lz)
		bottom = maxf(bottom, -ly + tv * lz)
		right = maxf(right, lx + th * lz)
		left = maxf(left, -lx + th * lz)
		mean_y += p.y
	mean_y /= maxf(points.size(), 1)
	top += pad
	bottom += pad
	right += pad
	left += pad
	# Camera position in the camera's own axes: the frustum planes touch the extreme points.
	var cz := maxf((top + bottom) / (2.0 * tv), (right + left) / (2.0 * th))
	var cy := (top - bottom) * 0.5
	var cx := (right - left) * 0.5
	var cam := x_axis * cx + y_axis * cy + z_axis * cz
	# Slide along the view axis to the plane of the players' mean height.
	var forward := -z_axis
	var along := 0.0
	if absf(forward.y) > 0.001:
		along = (mean_y - cam.y) / forward.y
	var at := cam + forward * along
	return [at, along]


func _apply_transform() -> void:
	var b := view_basis()
	global_transform = Transform3D(b, focus + b.z * distance)


func _update_shake(delta: float) -> void:
	trauma = maxf(trauma - shake_decay * delta, 0.0)
	if trauma <= 0.0:
		h_offset = 0.0
		v_offset = 0.0
		return
	_shake_time += delta * shake_frequency
	var amount := max_shake_offset * trauma * trauma
	h_offset = amount * _noise.get_noise_2d(_shake_time, 0.0)
	v_offset = amount * _noise.get_noise_2d(0.0, _shake_time + 100.0)


func _clamp_to_bounds(p: Vector3) -> Vector3:
	match bounds_mode:
		BoundsMode.BOX:
			return p.clamp(bounds_box.position, bounds_box.end)
		BoundsMode.RADIUS:
			var flat := Vector2(p.x - bounds_center.x, p.z - bounds_center.z).limit_length(bounds_radius)
			return Vector3(bounds_center.x + flat.x, maxf(p.y, bounds_center.y), bounds_center.z + flat.y)
	return p


func _tan_half_v() -> float:
	var t := tan(deg_to_rad(fov) * 0.5)
	return t / _aspect() if keep_aspect == KEEP_WIDTH else t


func _aspect() -> float:
	var size := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2.ZERO
	if size.y <= 0.0:
		return 16.0 / 9.0
	return size.x / size.y


func _get_stage() -> Stage:
	if _stage == null or not is_instance_valid(_stage) or not _stage.is_inside_tree():
		_stage = get_tree().get_first_node_in_group(&"stage") as Stage if is_inside_tree() else null
	return _stage


func _local_player() -> Player:
	var stage := _get_stage()
	if stage == null:
		return null
	var p := stage.get_player(Net.local_slot())
	if p == null or not is_instance_valid(p) or not p.alive:
		return null
	return p
