class_name StatusComponent
extends PlayerComponent
## The victim's side of a hit: knockback and stun. Owner: knockback.
## An impulse is added to `velocity` (scaled by `knockback_multiplier`) and locks control
## for a stun that scales with the hit's strength. Velocity is never zeroed here, so the
## blob slides and tumbles on its own physics. Raises `got_hit` and `stunned`.

## Scales the velocity change of every impulse. Minigames raise it (sumo).
@export var knockback_multiplier: float = 1.0
## Stun of the weakest hit, seconds.
@export var stun_min: float = 0.25
## Stun of a hit at or above `stun_full_impulse`, seconds.
@export var stun_max: float = 0.6
## Impulse length (before `knockback_multiplier`) that earns `stun_max`.
@export var stun_full_impulse: float = 12.0
## Cap on one unbroken stun chain, seconds: re-hits past it still push but no longer extend the stun.
@export var stun_chain_max: float = 1.2
## After a hit, further impulses are ignored this long, so one shove registers once.
@export var immunity_time: float = 0.2
## When true every impulse is ignored.
@export var invulnerable: bool = false

var _stun_left: float = 0.0
var _chain_time: float = 0.0
var _immune_left: float = 0.0


func _ready() -> void:
	if player:
		player.respawned.connect(_on_respawned)
		player.eliminated.connect(_on_eliminated)


## Called by Player.apply_impulse on the authority.
func receive_impulse(impulse: Vector3, source: Player) -> void:
	if player == null or invulnerable or player.frozen or not player.alive:
		return
	if _immune_left > 0.0:
		return
	var applied := impulse * knockback_multiplier
	player.velocity += applied
	_immune_left = immunity_time
	var source_slot := source.slot if source != null else -1
	player.emit_event(&"got_hit", [applied, source_slot])
	var duration := _stun_for(impulse.length())
	if _stun_left > 0.0:
		# Re-hit during a stun: extend to the new hit's stun, never past the chain cap.
		duration = minf(duration, maxf(stun_chain_max - _chain_time, 0.0))
		if duration <= _stun_left:
			return
	else:
		_chain_time = 0.0
	if duration <= 0.0:
		return
	_stun_left = duration
	player.control_locked = true
	player.emit_event(&"stunned", [duration])


## True while this component holds `control_locked`.
func is_stunned() -> bool:
	return _stun_left > 0.0


func physics_tick(delta: float) -> void:
	if _immune_left > 0.0:
		_immune_left = maxf(_immune_left - delta, 0.0)
	if _stun_left > 0.0:
		_stun_left -= delta
		_chain_time += delta
		if _stun_left <= 0.0:
			_stun_left = 0.0
			_chain_time = 0.0
			player.control_locked = false


func _stun_for(strength: float) -> float:
	var t := 1.0
	if stun_full_impulse > 0.0:
		t = clampf(strength / stun_full_impulse, 0.0, 1.0)
	return lerpf(stun_min, stun_max, t)


func _clear() -> void:
	_stun_left = 0.0
	_chain_time = 0.0
	_immune_left = 0.0
	if player:
		player.control_locked = false


func _on_respawned(_xform: Transform3D) -> void:
	_clear()


func _on_eliminated(_reason: StringName) -> void:
	_clear()
