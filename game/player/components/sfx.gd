class_name SfxComponent
extends PlayerComponent
## Sounds on player events. Owner: audio.
##
## Runs on every peer: it listens to the Player events (relayed to remote copies by sync)
## and reads shared state and the position, never `intent`, so remote players sound the
## same as local ones. Never changes gameplay state.
## Footsteps: one `step` every `stride` metres travelled while grounded (grounded = between
## `landed` and the next `jumped`, and not moving vertically). Landings get louder with
## `impact_speed`.

## Test seam: every sound this component asks for, before it reaches `Sfx`.
signal requested(sound: StringName, at: Vector3, volume_db: float)

## When false the component still emits `requested` but does not call `Sfx` (tests).
@export var output_enabled: bool = true
## Metres between footsteps.
@export var stride: float = 1.1
## Landings slower than this (m/s) are silent (stepping off a curb).
@export var min_land_speed: float = 2.5
## Landings at or above this (m/s) use `land_hard`.
@export var hard_land_speed: float = 12.0
## Vertical speed (m/s) above which the blob counts as airborne for footsteps.
@export var airborne_vertical_speed: float = 1.5
## A position jump larger than this in one frame is a teleport, not walking.
@export var teleport_distance: float = 1.5

var _grounded: bool = true
var _last_pos: Vector3 = Vector3.ZERO
var _has_last: bool = false
var _travel: float = 0.0


func _ready() -> void:
	if player == null:
		return
	player.jumped.connect(_on_jumped)
	player.landed.connect(_on_landed)
	player.shove_started.connect(_on_shove_started)
	player.shove_hit.connect(_on_shove_hit)
	player.got_hit.connect(_on_got_hit)
	player.stunned.connect(_on_stunned)
	player.eliminated.connect(_on_eliminated)
	player.respawned.connect(_on_respawned)


func _physics_process(delta: float) -> void:
	if player == null or not player.is_inside_tree():
		return
	var pos := player.global_position
	if not _has_last:
		_last_pos = pos
		_has_last = true
		return
	var d := pos - _last_pos
	_last_pos = pos
	if not player.alive or delta <= 0.0:
		_travel = 0.0
		return
	var flat := Vector2(d.x, d.z).length()
	if flat > teleport_distance:
		_travel = 0.0
		return
	if not _grounded or absf(d.y / delta) > airborne_vertical_speed:
		_travel = 0.0
		return
	_travel += flat
	if _travel >= stride:
		_travel = fmod(_travel, stride)
		_request(&"step", pos)


func _on_jumped() -> void:
	_grounded = false
	_request(&"jump", _pos())


func _on_landed(impact_speed: float) -> void:
	_grounded = true
	_travel = 0.0
	if impact_speed < min_land_speed:
		return
	if impact_speed >= hard_land_speed:
		var over := clampf((impact_speed - hard_land_speed) / hard_land_speed, 0.0, 1.0)
		_request(&"land_hard", _pos(), lerpf(-3.0, 0.0, over))
	else:
		var t := clampf((impact_speed - min_land_speed) / (hard_land_speed - min_land_speed), 0.0, 1.0)
		_request(&"land_soft", _pos(), lerpf(-10.0, 0.0, t))


func _on_shove_started() -> void:
	_request(&"shove_whoosh", _pos())


func _on_shove_hit(_victim_slot: int) -> void:
	_request(&"hit_bonk", _pos())


## Shoves already bonk through the shover's `shove_hit`; only sourceless hits
## (bumpers, explosions) bonk here, a little softer.
func _on_got_hit(_impulse: Vector3, source_slot: int) -> void:
	if source_slot < 0:
		_request(&"hit_bonk", _pos(), -4.0)


func _on_stunned(_duration: float) -> void:
	_request(&"stun_wobble", _pos())


func _on_eliminated(_reason: StringName) -> void:
	_request(&"eliminated_pop", _pos())


func _on_respawned(xform: Transform3D) -> void:
	_grounded = true
	_travel = 0.0
	_has_last = false
	_request(&"respawn", xform.origin)


func _pos() -> Vector3:
	return player.global_position if player.is_inside_tree() else player.position


func _request(sound: StringName, at: Vector3, volume_db: float = 0.0) -> void:
	requested.emit(sound, at, volume_db)
	if output_enabled:
		Sfx.play(sound, at, volume_db)
