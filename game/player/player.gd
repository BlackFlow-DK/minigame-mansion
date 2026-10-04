class_name Player
extends CharacterBody3D
## The shared player blob. Owns identity, shared state and the tick order; contains no
## mechanic logic. Mechanics are components under $Components (docs/contract.md).
## The root never rotates: `facing` says where the blob looks and the visuals turn to it.
## Orchestrator-owned: report needed changes, do not edit from a system branch.

signal jumped
signal landed(impact_speed: float)
signal shove_started
signal shove_hit(victim_slot: int)
signal got_hit(impulse: Vector3, source_slot: int)
signal stunned(duration: float)
signal eliminated(reason: StringName)
signal respawned(xform: Transform3D)
## A player emote (EmoteComponent.NAMES: 1 wave, 2 dance, 3 taunt, 4 cry); cosmetic only.
signal emote(id: int)

## Components that get physics_tick(), in this order, before move_and_slide().
## `size` goes first: it scales the others' tuning before they use it this tick.
const TICK_ORDER: Array[StringName] = [&"size", &"controller", &"status", &"movement", &"jump", &"shove"]

## Stable identity for the whole session, 0..7. Set by Stage at spawn.
var slot: int = -1
var display_name: String = ""
var is_bot: bool = false
## An NPC extra (Stage.spawn_extras): bot-driven, host-owned, slot >= 100, not in the roster,
## never scored, not in `Stage.players` or `Minigame.players`.
var is_extra: bool = false
## `{ "primary": "#rrggbb", "secondary": "#rrggbb", "hat": id, "face": id, "neck": id, "back": id }`.
var loadout: Dictionary = {}
## What the controller wants this tick.
var intent: PlayerIntent = PlayerIntent.new()
## Unit vector on XZ the blob looks along.
var facing: Vector3 = Vector3.MODEL_FRONT
## Set by the minigame/session: no movement, no actions (intent is cleared every tick).
var frozen: bool = false
## Set by the status component while stunned: intent is cleared, physics still runs.
var control_locked: bool = false
## False after eliminate() until respawn_at(). Dead players are hidden, have no collision and do not tick.
var alive: bool = true

var _components: Dictionary[StringName, PlayerComponent] = {}
var _all: Array[PlayerComponent] = []

@onready var _shape: CollisionShape3D = $CollisionShape3D


func _enter_tree() -> void:
	_collect_components()


func _physics_process(delta: float) -> void:
	if not alive or not is_authority():
		return
	_tick(&"size", delta)
	_tick(&"controller", delta)
	if frozen:
		intent.clear()
	_tick(&"status", delta)
	if frozen or control_locked:
		intent.clear()
	_tick(&"movement", delta)
	_tick(&"jump", delta)
	_tick(&"shove", delta)
	move_and_slide()
	for c in _all:
		c.post_tick(delta)


## True on the peer that simulates this player (owner peer; host for bots). Always true offline.
func is_authority() -> bool:
	return is_multiplayer_authority()


## The component node named `component_name` under $Components, or null.
func get_component(component_name: StringName) -> PlayerComponent:
	return _components.get(component_name) as PlayerComponent


## Pushes the player. On the authority the `status` component handles it; elsewhere it is
## handed to the `sync` component to deliver to the authority.
func apply_impulse(impulse: Vector3, source: Player = null) -> void:
	if not is_authority():
		var sync := get_component(&"sync") as SyncComponent
		if sync:
			sync.relay_impulse(impulse, source)
		return
	var status := get_component(&"status") as StatusComponent
	if status:
		status.receive_impulse(impulse, source)
	else:
		velocity += impulse


## Host only. Takes the player out of play and raises `eliminated`.
func eliminate(reason: StringName = &"") -> void:
	if not alive:
		return
	_set_alive(false)
	emit_event(&"eliminated", [reason])


## Host only. Puts the player back into play at `xform` and raises `respawned`.
func respawn_at(xform: Transform3D) -> void:
	place_at(xform)
	_set_alive(true)
	emit_event(&"respawned", [xform])


## Teleports without raising events: origin from `xform`, `facing` from its forward (+Z) axis.
## The root keeps an identity rotation. Stage uses this at spawn.
func place_at(xform: Transform3D) -> void:
	if is_inside_tree():
		global_position = xform.origin
	else:
		position = xform.origin
	var f := xform.basis * Vector3.MODEL_FRONT
	f.y = 0.0
	if f.length_squared() > 0.0001:
		facing = f.normalized()
	velocity = Vector3.ZERO


## Presentation hook (this peer only): hides or shows this blob's name tag and/or shadow.
## Forwards to `FxComponent.set_presentation_hidden` (see contract "Minigame hooks").
func set_presentation_hidden(hidden: bool, tags: bool = true, shadow: bool = true) -> void:
	FxComponent.set_presentation_hidden(self, hidden, tags, shadow)


## Raises the player signal `event` with `args` here, then hands it to the `sync`
## component so every other peer raises it too. Always raise player events this way.
func emit_event(event: StringName, args: Array = []) -> void:
	_emit_local(event, args)
	var sync := get_component(&"sync") as SyncComponent
	if sync:
		sync.relay_event(event, args)


## Sync component only: an event relayed from another peer. Applies the state change that
## goes with it (eliminated, respawned) and raises the signal locally, without relaying.
func receive_event(event: StringName, args: Array = []) -> void:
	match event:
		&"eliminated":
			_set_alive(false)
		&"respawned":
			if args.size() > 0 and args[0] is Transform3D:
				place_at(args[0])
			_set_alive(true)
	_emit_local(event, args)


func _emit_local(event: StringName, args: Array) -> void:
	if not has_signal(event):
		push_error("Player.emit_event: unknown event '%s'" % event)
		return
	var call_args: Array = [event]
	call_args.append_array(args)
	callv(&"emit_signal", call_args)


func _tick(component_name: StringName, delta: float) -> void:
	var c: PlayerComponent = _components.get(component_name)
	if c:
		c.physics_tick(delta)


func _set_alive(value: bool) -> void:
	alive = value
	visible = value
	if not value:
		velocity = Vector3.ZERO
		intent.clear()
	if _shape:
		_shape.set_deferred(&"disabled", not value)


func _collect_components() -> void:
	_components.clear()
	_all.clear()
	var holder := get_node_or_null(^"Components")
	if holder == null:
		return
	for child in holder.get_children():
		var c := child as PlayerComponent
		if c == null:
			continue
		c.player = self
		_components[StringName(c.name)] = c
		_all.append(c)
