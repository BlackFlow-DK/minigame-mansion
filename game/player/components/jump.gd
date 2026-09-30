class_name JumpComponent
extends PlayerComponent
## Gravity, jump, coyote time, jump buffering, landing (`jumped`, `landed`). Owner: jump.
## Owns only the vertical axis of `player.velocity`. Upward velocity added by others
## (status impulses) is never cancelled; it just falls back under gravity.
## `frozen`/`control_locked`: Player clears `intent`, so no jump starts; gravity still applies,
## so a frozen or stunned blob settles on the ground instead of hanging in the air.

## A minigame can switch jumping off; gravity keeps working.
@export var jump_enabled: bool = true
## Apex height of a full (held) jump, metres.
@export var jump_height: float = 1.3
## Seconds from take-off to the apex of a full jump. Gravity and take-off speed derive from this.
@export var time_to_apex: float = 0.35
## Gravity multiplier while falling (faster fall than rise).
@export var fall_gravity_multiplier: float = 1.6
## Gravity multiplier while still rising after jump was released early (short hop).
@export var release_gravity_multiplier: float = 3.0
## Maximum downward speed, m/s.
@export var terminal_velocity: float = 20.0
## Seconds after walking off a ledge in which a jump still works.
@export var coyote_time: float = 0.1
## Seconds a jump press is remembered before landing.
@export var jump_buffer_time: float = 0.1

var _coyote_left: float = 0.0
var _buffer_left: float = 0.0
## True from take-off until the rise ends; only this rise is shortened by releasing jump.
var _jump_rising: bool = false
## Latched once jump is let go during that rise: the rest of the rise uses release gravity.
var _jump_cut: bool = false
var _was_on_floor: bool = true
var _vertical_before_slide: float = 0.0


func _ready() -> void:
	if player:
		player.respawned.connect(_on_respawned)


## Rise gravity in m/s^2 (positive), derived from jump_height and time_to_apex.
func get_gravity_strength() -> float:
	return 2.0 * jump_height / (time_to_apex * time_to_apex)


## Take-off speed in m/s of a jump, derived from jump_height and time_to_apex.
func get_jump_velocity() -> float:
	return 2.0 * jump_height / time_to_apex


func physics_tick(delta: float) -> void:
	var on_floor := player.is_on_floor()
	var intent := player.intent

	if on_floor and player.velocity.y <= 0.0:
		_coyote_left = coyote_time
		_jump_rising = false
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)

	if intent.jump_pressed:
		_buffer_left = jump_buffer_time
	else:
		_buffer_left = maxf(_buffer_left - delta, 0.0)

	if not jump_enabled or player.frozen or player.control_locked:
		_buffer_left = 0.0
	if player.control_locked:
		_jump_rising = false  # a stun mid-jump keeps whatever upward push it came with

	var can_jump := player.velocity.y <= 0.0 and (on_floor or _coyote_left > 0.0)
	if _buffer_left > 0.0 and can_jump:
		_start_jump(delta)
		return

	if not on_floor or player.velocity.y > 0.0:
		_apply_gravity(delta, intent.jump_held)
	_vertical_before_slide = player.velocity.y


func post_tick(_delta: float) -> void:
	var on_floor := player.is_on_floor()
	if on_floor and not _was_on_floor:
		player.emit_event(&"landed", [maxf(-_vertical_before_slide, 0.0)])
	_was_on_floor = on_floor


func _start_jump(delta: float) -> void:
	_buffer_left = 0.0
	_coyote_left = 0.0
	_jump_rising = true
	_jump_cut = false
	# The take-off tick moves at full speed with no gravity; half a tick of gravity off the
	# launch speed makes the discrete arc peak at jump_height instead of overshooting it.
	player.velocity.y = get_jump_velocity() - get_gravity_strength() * delta * 0.5
	_vertical_before_slide = player.velocity.y
	player.emit_event(&"jumped")


func _apply_gravity(delta: float, jump_held: bool) -> void:
	var g := get_gravity_strength()
	if player.velocity.y <= 0.0:
		_jump_rising = false
		g *= fall_gravity_multiplier
	else:
		if _jump_rising and not jump_held:
			_jump_cut = true
		if _jump_rising and _jump_cut:
			g *= release_gravity_multiplier
	player.velocity.y = maxf(player.velocity.y - g * delta, -terminal_velocity)


func _on_respawned(_xform: Transform3D) -> void:
	_coyote_left = 0.0
	_buffer_left = 0.0
	_jump_rising = false
	_was_on_floor = true
	_vertical_before_slide = 0.0
