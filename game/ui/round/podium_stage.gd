class_name RoundPodiumStage
extends Node3D
## The 3D podium behind the PODIUM panel (owner: round UI). RoundUI builds one on every peer
## when the session ends, as a child of the Stage's last minigame (so it goes with the stage),
## OFFSET above that minigame's origin, clear of any arena. It holds three stepped blocks (2nd,
## 1st, 3rd: the columns of the 2D panel, whose name/points captions line up under them), a
## curtain backdrop, a floor, a fill light and its own camera, which it makes current.
##
## Network: the host alone decides where everyone stands: `place_players()` respawns the top
## three onto their blocks (dropping in, 3rd first, the winner last) and everyone else beside
## the podium, through `Player.respawn_at` (reaches every peer). Clients only build the scenery
## and see the respawns. Players stay frozen (Session froze them); gravity settles them.
##
## Poses (every peer, local): `pose_players()` calls `play_result_pose(place, total)` on each
## player for its FINAL place. Ties (same total AND same round wins: the only things Session
## ranks by before the slot) share the group's place, so a tied group strikes the same pose; a
## tied last group (of two or more groups) sulks together. `stop_poses()` ends them.

const OFFSET := Vector3(0.0, 60.0, 0.0)
const BLOCK_W := 1.9
const BLOCK_D := 1.5
## Block heights by place (index 0 = 1st).
const BLOCK_H: Array[float] = [1.0, 0.72, 0.5]
## Block centres on X by place: 1st centre, 2nd left, 3rd right (the 2D panel's COLUMN_X).
const COLUMN_X: Array[float] = [0.0, -2.23, 2.23]
const BLOCK_COLOR: Array[Color] = [RoundStyle.GOLD, RoundStyle.TEAL, RoundStyle.PLUM]
## Where 4th place and below stand (local, on the floor), in order.
const OTHER_SPOTS: Array[Vector3] = [
	Vector3(3.6, 0.0, 0.45), Vector3(-3.6, 0.0, 0.45), Vector3(4.3, 0.0, -0.3),
	Vector3(-4.3, 0.0, -0.3), Vector3(3.9, 0.0, -1.2), Vector3(-3.9, 0.0, -1.2),
	Vector3(3.3, 0.0, -1.4),
]
## Respawns start this high over the spot and fall in.
const DROP_HEIGHT := 2.2
## Host: seconds after place_players() each block's player drops in (index = place - 1);
## everyone else lands at once.
const DROP_DELAY: Array[float] = [0.95, 0.45, 0.0]
const CAMERA_POS := Vector3(0.0, 2.63, 8.0)
const CAMERA_TARGET := Vector3(0.0, 1.2, 0.0)
const CAMERA_FOV := 38.7

var camera: Camera3D
## slot -> the place passed to play_result_pose (read by tests).
var posed: Dictionary[int, int] = {}
var _stage: Stage = null
var _hidden: Array[WeakRef] = []


## The tied groups of a final `ranking` (slots, best first): neighbours with the same total
## (`totals`) and the same round wins (`wins`) share a group.
static func final_groups(ranking: Array, totals: Dictionary, wins: Dictionary) -> Array:
	var groups: Array = []
	var prev_key := Vector2i(-1, -1)
	for s: Variant in ranking:
		var slot := int(s)
		var key := Vector2i(int(totals.get(slot, 0)), int(wins.get(slot, 0)))
		if groups.is_empty() or key != prev_key:
			groups.append([slot] as Array[int])
		else:
			(groups.back() as Array).append(slot)
		prev_key = key
	return groups


## slot -> the place to pose for: the group's tied place (1, 1, 3), except that a last group
## (of two or more groups) gets `total`, so all of it sulks.
static func pose_places(ranking: Array, totals: Dictionary, wins: Dictionary) -> Dictionary[int, int]:
	var groups := final_groups(ranking, totals, wins)
	var total := ranking.size()
	var out: Dictionary[int, int] = {}
	var place := 1
	for gi in groups.size():
		var g: Array = groups[gi]
		var p := total if gi == groups.size() - 1 and groups.size() >= 2 else place
		for s: Variant in g:
			out[int(s)] = p
		place += g.size()
	return out


## Local spot (feet) of the player at `index` (0-based) of the final ranking.
static func spot_for(index: int) -> Vector3:
	if index < 3:
		return Vector3(COLUMN_X[index], BLOCK_H[index], 0.0)
	return OTHER_SPOTS[(index - 3) % OTHER_SPOTS.size()]


func setup(stage: Stage) -> void:
	_stage = stage
	_hide_arena()
	_build()


## The last minigame's own 3D dressing (a crown rig, hit marks, lights) would follow its blobs
## up here: every sibling Node3D is hidden while the podium stands, except whatever holds
## the lighting (a StageLook, a WorldEnvironment or a sun). Shown again when it goes.
func _hide_arena() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for c in parent.get_children():
		var n := c as Node3D
		if n == null or n == self or not n.visible or _holds_lighting(n):
			continue
		n.visible = false
		_hidden.append(weakref(n))


static func _holds_lighting(n: Node) -> bool:
	if n is StageLook or n is WorldEnvironment or n is DirectionalLight3D:
		return true
	for c in n.get_children():
		if _holds_lighting(c):
			return true
	return false


## Host only: respawns every ranked player onto its spot (facing the camera).
func place_players(ranking: Array) -> void:
	if not Net.is_host() or _stage == null:
		return
	for i in ranking.size():
		var p := _stage.get_player(int(ranking[i]))
		if p == null or not is_instance_valid(p):
			continue
		var at := global_transform * (spot_for(i) + Vector3.UP * DROP_HEIGHT)
		var xform := Transform3D(Basis.IDENTITY, at)
		var delay := DROP_DELAY[i] if i < DROP_DELAY.size() else 0.0
		if delay <= 0.0:
			p.respawn_at(xform)
		else:
			get_tree().create_timer(delay).timeout.connect(_respawn_later.bind(weakref(p), xform))


func _respawn_later(ref: WeakRef, xform: Transform3D) -> void:
	var p := ref.get_ref() as Player
	if p and is_instance_valid(p) and is_inside_tree():
		p.respawn_at(xform)


## Every peer: each ranked player strikes its result pose.
func pose_players(ranking: Array, totals: Dictionary, wins: Dictionary) -> void:
	posed = pose_places(ranking, totals, wins)
	var total := ranking.size()
	for slot: int in posed:
		var v := _visuals(slot)
		if v:
			v.play_result_pose(posed[slot], total)


func stop_poses() -> void:
	for slot: int in posed:
		var v := _visuals(slot)
		if v:
			v.stop_emote()
	posed.clear()


func _visuals(slot: int) -> VisualsComponent:
	if _stage == null or not is_instance_valid(_stage):
		return null
	var p := _stage.get_player(slot)
	if p == null or not is_instance_valid(p):
		return null
	return p.get_component(&"visuals") as VisualsComponent


func _exit_tree() -> void:
	stop_poses()
	for ref in _hidden:
		var n := ref.get_ref() as Node3D
		if n and is_instance_valid(n) and not n.is_queued_for_deletion():
			n.visible = true
	_hidden.clear()


# --- Scenery -------------------------------------------------------------------------------

func _build() -> void:
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var wood := Look.toon_material(Look.DARK_WOOD, 0.8, false)
	_box(body, "Floor", Vector3(16.0, 0.4, 7.0), Vector3(0.0, -0.2, 0.5), wood)
	var curtain := Look.toon_material(RoundStyle.PLUM.darkened(0.25), 0.9, false)
	_box(null, "Backdrop", Vector3(18.0, 8.0, 0.3), Vector3(0.0, 3.6, -3.0), curtain)
	var trim := Look.toon_material(Look.GOLD, 0.4)
	_box(null, "Rail", Vector3(18.0, 0.12, 0.12), Vector3(0.0, 0.06, -2.8), trim)
	var font := RoundStyle.get_theme().default_font
	for i in 3:
		var h := BLOCK_H[i]
		_box(body, "Block%d" % (i + 1), Vector3(BLOCK_W, h, BLOCK_D), Vector3(COLUMN_X[i], h * 0.5, 0.0),
			Look.toon_material(BLOCK_COLOR[i], 0.7))
		_box(null, "Trim%d" % (i + 1), Vector3(BLOCK_W + 0.04, 0.07, BLOCK_D + 0.04),
			Vector3(COLUMN_X[i], h - 0.035, 0.0), trim)
		var num := Label3D.new()
		num.name = "Place%d" % (i + 1)
		num.text = str(i + 1)
		if font:
			num.font = font
		num.font_size = 160 if i == 0 else 128
		num.pixel_size = 0.004
		num.outline_size = 28
		num.modulate = RoundStyle.CREAM if i == 2 else RoundStyle.CHARCOAL
		num.outline_modulate = RoundStyle.CHARCOAL if i == 2 else RoundStyle.CREAM.lerp(BLOCK_COLOR[i], 0.4)
		num.shaded = false
		num.position = Vector3(COLUMN_X[i], h * 0.5, BLOCK_D * 0.5 + 0.01)
		add_child(num)
	var fill := OmniLight3D.new()
	fill.name = "Fill"
	fill.position = Vector3(0.0, 4.2, 4.5)
	fill.omni_range = 14.0
	fill.light_energy = 1.3
	fill.light_color = Color(1.0, 0.94, 0.85)
	fill.shadow_enabled = false
	add_child(fill)
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = CAMERA_FOV
	add_child(camera)
	camera.look_at_from_position(global_transform * CAMERA_POS, global_transform * CAMERA_TARGET, Vector3.UP)
	camera.make_current()


func _box(body: StaticBody3D, node_name: String, size: Vector3, at: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	add_child(mi)
	if body:
		var cs := CollisionShape3D.new()
		cs.name = node_name
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		cs.position = at
		body.add_child(cs)
