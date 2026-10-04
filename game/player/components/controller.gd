class_name ControllerComponent
extends PlayerComponent
## Fills `player.intent` every tick. Owner: skeleton (human input), bot agent (bot brain).
##
## Human: reads the input actions; `move` is relative to the active camera's yaw, so
## "forward" always points away from the camera. Pressed flags are edges of the held state.
## Bot (`player.is_bot`): if `res://bots/bot_brain.gd` exists, one instance becomes a child
## of this component and fills the intent: `func fill_intent(intent: PlayerIntent, delta: float) -> void`.
## Without a brain a bot stands still.
## Human input is ignored while a UI control has keyboard/pad focus or a node of group
## INPUT_BLOCKER_GROUP (the pause menu) is visible: Space / A then press the focused button
## instead of also jumping, and the blob stays put while a menu is being used.

const BOT_BRAIN_PATH := "res://bots/bot_brain.gd"
## Visible CanvasItems in this group take the human's input away from the blob.
const INPUT_BLOCKER_GROUP := &"blocks_player_input"
## Emote keys (1-4 / d-pad), in emote id order 1..4.
const EMOTE_ACTIONS: Array[StringName] = [&"emote_1", &"emote_2", &"emote_3", &"emote_4"]

## Tests: when true the controller leaves `player.intent` alone so a test can write it.
var scripted: bool = false
## The bot brain node (bots only; null until the bot agent ships one).
var brain: Node = null

var _jump_was_held: bool = false
var _action_was_held: bool = false
var _emotes_held: int = 0  # bit i: EMOTE_ACTIONS[i] held last tick


func _ready() -> void:
	if player and player.is_bot and ResourceLoader.exists(BOT_BRAIN_PATH):
		var script := load(BOT_BRAIN_PATH) as Script
		brain = script.new() as Node
		brain.set(&"player", player)
		brain.name = "BotBrain"
		add_child(brain)


func physics_tick(delta: float) -> void:
	if scripted:
		return
	if player.is_bot:
		if brain:
			brain.call(&"fill_intent", player.intent, delta)
		else:
			player.intent.clear()
		return
	_read_human_input()


func _read_human_input() -> void:
	var intent := player.intent
	var jump := Input.is_action_pressed(&"jump")
	var action := Input.is_action_pressed(&"action")
	if ui_has_input(get_viewport()):
		# Track the held state so a press that started on a menu never becomes a jump/shove.
		intent.clear()
		_jump_was_held = jump
		_action_was_held = action
		_emotes_held = _read_emotes()
		return
	var raw := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	intent.move = _camera_relative(raw)
	intent.jump_pressed = jump and not _jump_was_held
	intent.jump_held = jump
	intent.action_pressed = action and not _action_was_held
	_jump_was_held = jump
	_action_was_held = action
	var emotes := _read_emotes()
	intent.emote = 0
	for i in EMOTE_ACTIONS.size():
		if (emotes & (1 << i)) != 0 and (_emotes_held & (1 << i)) == 0:
			intent.emote = i + 1
			break
	_emotes_held = emotes


## Bit i set while EMOTE_ACTIONS[i] is held (actions missing from the input map count as up).
func _read_emotes() -> int:
	var bits := 0
	for i in EMOTE_ACTIONS.size():
		if InputMap.has_action(EMOTE_ACTIONS[i]) and Input.is_action_pressed(EMOTE_ACTIONS[i]):
			bits |= 1 << i
	return bits


## True while the UI owns the human's input: a visible control has focus, or a node of
## INPUT_BLOCKER_GROUP is visible.
static func ui_has_input(viewport: Viewport) -> bool:
	if viewport == null:
		return false
	var focus := viewport.gui_get_focus_owner()
	if focus != null and focus.is_visible_in_tree():
		return true
	for n: Node in viewport.get_tree().get_nodes_in_group(INPUT_BLOCKER_GROUP):
		var ci := n as CanvasItem
		if ci != null and ci.is_visible_in_tree():
			return true
	return false


## Maps stick/keys (x right, y down = back) to world XZ using the active camera's yaw.
func _camera_relative(raw: Vector2) -> Vector2:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return raw.limit_length(1.0)
	# -Z and +Y of a camera both project to "screen up" on the ground, whatever its pitch.
	var fwd := -cam.global_basis.z + cam.global_basis.y
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return raw.limit_length(1.0)
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var world := right * raw.x - fwd * raw.y
	return Vector2(world.x, world.z).limit_length(1.0)
