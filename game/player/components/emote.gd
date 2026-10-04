class_name EmoteComponent
extends PlayerComponent
## Player emotes (keys 1-4 / d-pad: wave, dance, taunt, cry). Owner: character animator.
##
## Authority only: ticked right after the controller (before `frozen` clears the intent), it
## reads `intent.emote` (1..4 on the tick the key went down) and raises the player event
## `emote(id)` through `Player.emit_event`, so every peer plays it (the host relays it like any
## event and does not validate it). The visuals component on every peer listens to `emote`
## and plays the pose; movement, a jump, a shove or a knockback cancels it there.
## Rules here: at most one emote per `cooldown` seconds; none while stunned or dead; none while
## `frozen`, except in the lobby and on the podium (Session LOBBY / PODIUM), where emoting is
## encouraged.
## "The lobby" (is_lobby): Session in LOBBY and the player's Stage following the roster (the
## lobby hall), or no Stage at all (dev scenes); not the sandbox or tests.
## Bots (not extras) emote now and then in the lobby, and the round winner sometimes does a
## victory emote; a bot stands still while its emote plays.

## Emote ids in the `emote` event -> visuals emote names.
const NAMES: Dictionary = {1: &"wave", 2: &"dance", 3: &"taunt", 4: &"cry"}
## How long a bot stands still for each emote (s).
const BOT_HOLD: Dictionary = {1: 1.8, 2: 3.2, 3: 1.8, 4: 2.4}

## Minimum seconds between two emotes of this player.
@export var cooldown: float = 0.8
## Bots emote by themselves (lobby, after a round win).
@export var bot_emotes: bool = true
## Seconds between a bot's lobby emotes (random in this range, per slot).
@export var bot_interval: Vector2 = Vector2(9.0, 24.0)

var _since: float = 99.0
var _rng := RandomNumberGenerator.new()
var _bot_in: float = 0.0
var _bot_hold: float = 0.0
var _bot_win_in: float = -1.0
var _session: Node = null


## The emote name for event id `id`, or &"" if unknown.
static func name_of(id: int) -> StringName:
	return NAMES.get(id, &"")


func _ready() -> void:
	if player == null:
		return
	_rng.seed = hash(player.slot) * 31 + 17
	_bot_in = _rng.randf_range(4.0, bot_interval.y)
	_session = get_node_or_null(^"/root/Session")
	if _session and player.is_bot and not player.is_extra and _session.has_signal(&"round_finished"):
		_session.connect(&"round_finished", _on_round_finished)


## Authority: asks for emote `id` (1..4). Raises the `emote` event and returns true when the
## rules allow it (see the class notes), false otherwise.
func request(id: int) -> bool:
	return _try(id, false)


## `force` skips the cooldown and the frozen rule (a bot's victory emote during the results).
func _try(id: int, force: bool) -> bool:
	if player == null or not player.is_authority() or not player.alive or not NAMES.has(id):
		return false
	if not force and (_since < cooldown or player.control_locked):
		return false
	if not force and player.frozen and not frozen_emotes_allowed():
		return false
	_since = 0.0
	player.emit_event(&"emote", [id])
	return true


## True in the lobby hall: Session LOBBY and the Stage follows the roster (or there is no Stage).
static func is_lobby(p: Player) -> bool:
	if p == null or not p.is_inside_tree():
		return false
	var session := p.get_tree().root.get_node_or_null(^"Session")
	if session and int(session.get(&"state")) != 0:  # Session.State.LOBBY
		return false
	var n := p.get_parent()
	while n != null and not (n is Stage):
		n = n.get_parent()
	return n == null or (n as Stage).follow_roster


## True in the phases where a frozen player may still emote (lobby, podium).
func frozen_emotes_allowed() -> bool:
	if _session == null:
		return true
	var state: int = _session.get(&"state")
	return state == 0 or state == 4  # Session.State.LOBBY, Session.State.PODIUM


## Seconds until the next emote is allowed (0 = now).
func cooldown_left() -> float:
	return maxf(cooldown - _since, 0.0)


func physics_tick(delta: float) -> void:
	_since += delta
	var id := player.intent.emote
	if id != 0:
		request(id)
	if player.is_bot and not player.is_extra and bot_emotes:
		_bot_tick(delta)


func _bot_tick(delta: float) -> void:
	if _bot_hold > 0.0:
		_bot_hold -= delta
		player.intent.move = Vector2.ZERO
		player.intent.action_pressed = false
		player.intent.jump_pressed = false
	if _bot_win_in >= 0.0:
		_bot_win_in -= delta
		if _bot_win_in < 0.0:
			var id: int = [2, 3, 1][_rng.randi() % 3]
			if _try(id, true):
				_bot_hold = BOT_HOLD[id]
		return
	if not is_lobby(player):
		return
	_bot_in -= delta
	if _bot_in > 0.0:
		return
	_bot_in = _rng.randf_range(bot_interval.x, bot_interval.y)
	var pick := _rng.randi_range(1, 4)
	if request(pick):
		_bot_hold = BOT_HOLD[pick]


func _on_round_finished(ranking: Array, _points: Dictionary) -> void:
	if player == null or not player.is_authority() or ranking.is_empty():
		return
	if int(ranking[0]) == player.slot and _rng.randf() < 0.75:
		_bot_win_in = _rng.randf_range(1.0, 1.8)
