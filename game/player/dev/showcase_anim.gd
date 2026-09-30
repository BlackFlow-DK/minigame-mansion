extends Node3D
## Animation showcase for the visuals component: real Player scenes on a floor, scripted
## through every state. Not gameplay; for eyes and screenshots.
## User args after "--":
##   --shot=<name>   play one scripted moment and FREEZE on it (the tree pauses), for screenshots:
##                   idle, run, apex, fall, land, shove, hit, stun, cheer, wave, sad, pop, respawn
##   (no --shot)     tour: loops through every shot live, a few seconds each
## Example: tools/godot-screenshot.ps1 -Scene res://player/dev/showcase_anim.tscn -Frames 240
##          -GameArgs "--shot=land" -Out build/screenshots/anim_land.png

const PLAYER_SCENE: PackedScene = preload("res://player/player.tscn")
const SHOTS: Array[StringName] = [
	&"idle", &"run", &"apex", &"fall", &"land", &"shove", &"hit", &"stun",
	&"cheer", &"wave", &"sad", &"pop", &"respawn",
]
const TOUR_FRAMES := 170
const LOADOUTS: Array[Dictionary] = [
	{"primary": "#ff5a5f", "secondary": "#ffe0c2"},
	{"primary": "#3fa9f5", "secondary": "#d6ecff"},
]

var hero: Player
var partner: Player
var _shot: StringName = &""
var _tour: bool = true
var _tour_index: int = 0
var _frame: int = 0
## Frame at which to freeze (-1 = not yet known); set by the scenario or by an event.
var _freeze_at: int = -1
var _frozen: bool = false
var _apex_seen: bool = false
var _cam_offset: Vector3 = Vector3(1.6, 1.25, 2.8)
var _cam_look: Vector3 = Vector3(0.0, 0.45, 0.0)
var _cam_follow: bool = true

@onready var _camera: Camera3D = $Camera3D
@onready var _players: Node3D = $Players


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot = StringName(arg.trim_prefix("--shot="))
			_tour = false
	hero = _spawn(0)
	partner = _spawn(1)
	hero.landed.connect(func(_s: float) -> void: _freeze_after(&"land", 1))
	hero.shove_started.connect(func() -> void: _freeze_after(&"shove", 6))
	hero.got_hit.connect(func(_i: Vector3, _s: int) -> void: _freeze_after(&"hit", 3))
	hero.stunned.connect(func(_d: float) -> void: _freeze_after(&"stun", 20))
	hero.eliminated.connect(func(_r: StringName) -> void: _freeze_after(&"pop", 9))
	hero.respawned.connect(func(_x: Transform3D) -> void: _freeze_after(&"respawn", 13))
	_start(SHOTS[0] if _tour else _shot)


func _spawn(slot: int) -> Player:
	var p := PLAYER_SCENE.instantiate() as Player
	p.slot = slot
	p.name = "P%d" % slot
	p.display_name = "Blob %d" % slot
	p.loadout = LOADOUTS[slot]
	# Spawn apart: a body teleported out from under another one would carry it like a platform.
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(-3.0 * slot, 0.0, -2.0 * slot)))
	_players.add_child(p)
	(p.get_component(&"controller") as ControllerComponent).scripted = true
	return p


func _start(shot: StringName) -> void:
	_shot = shot
	_frame = 0
	_freeze_at = -1
	_apex_seen = false
	_cam_follow = true
	for p: Player in [hero, partner]:
		p.intent.clear()
		if not p.alive:
			p.respawn_at(Transform3D.IDENTITY)
		var vis := p.get_component(&"visuals") as VisualsComponent
		vis.stop_emote()
	# Default: hero at the origin looking at the camera, partner off to the side.
	_place(hero, Vector3.ZERO, 0.0)
	_place(partner, Vector3(-3.0, 0.0, -2.0), 0.6)
	_cam_offset = Vector3(1.5, 1.2, 2.7)
	_cam_look = Vector3(0.0, 0.45, 0.0)
	match shot:
		&"run":
			_place(hero, Vector3(-4.0, 0.0, 0.0), PI * 0.5)
			_cam_offset = Vector3(2.4, 1.1, 1.7)
		&"apex", &"fall", &"land":
			_place(hero, Vector3(-1.5, 0.0, 0.0), PI * 0.5)
			_cam_offset = Vector3(2.4, 1.2, 2.2)
			_cam_look = Vector3(0.0, 0.8 if shot != &"land" else 0.45, 0.0)
		&"shove", &"hit", &"stun":
			_place(hero, Vector3.ZERO, PI * 0.5)
			_place(partner, Vector3(1.05, 0.0, 0.0), -PI * 0.5)
			_cam_offset = Vector3(0.4, 1.3, 3.0)
			_cam_look = Vector3(0.4 if shot == &"shove" else 0.0, 0.45, 0.0)


func _place(p: Player, pos: Vector3, yaw: float) -> void:
	p.place_at(Transform3D(Basis(Vector3.UP, yaw), pos))


func _freeze_after(shot: StringName, frames: int) -> void:
	if shot == _shot and _freeze_at < 0:
		_freeze_at = _frame + frames


func _physics_process(_delta: float) -> void:
	if _frozen:
		return
	var f := _frame
	hero.intent.jump_pressed = false
	hero.intent.action_pressed = false
	partner.intent.action_pressed = false
	var vis := hero.get_component(&"visuals") as VisualsComponent
	match _shot:
		&"idle":
			if f == 60:
				_freeze_at = f
		&"run":
			hero.intent.move = Vector2(1.0, 0.0)
			if f == 45:
				_freeze_at = f
		&"apex", &"fall", &"land":
			hero.intent.move = Vector2(0.45, 0.0)
			hero.intent.jump_pressed = f == 30
			hero.intent.jump_held = f >= 30
			if f > 32 and not _apex_seen and hero.velocity.y <= 0.0:
				_apex_seen = true
				if _shot == &"apex":
					_freeze_at = f
				elif _shot == &"fall":
					_freeze_at = f + 9
		&"shove":
			hero.intent.action_pressed = f == 30
		&"hit", &"stun":
			partner.intent.action_pressed = f == 30
		&"cheer":
			if f == 10:
				vis.play_emote(&"cheer", true)
			if f == 58:
				_freeze_at = f
		&"wave":
			if f == 10:
				vis.play_emote(&"wave", true)
			if f == 44:
				_freeze_at = f
		&"sad":
			if f == 10:
				vis.play_emote(&"sad", true)
			if f == 60:
				_freeze_at = f
		&"pop":
			if f == 30:
				hero.eliminate(&"showcase")
		&"respawn":
			if f == 10:
				hero.eliminate(&"showcase")
			if f == 60:
				hero.respawn_at(Transform3D.IDENTITY)
	_frame += 1
	if _tour:
		if _frame >= TOUR_FRAMES:
			_tour_index = (_tour_index + 1) % SHOTS.size()
			_start(SHOTS[_tour_index])
	elif _freeze_at >= 0 and _frame > _freeze_at:
		_frozen = true
		print("showcase_anim: frozen '%s' at frame %d, reaction=%s expression=%s" % [
			_shot, _frame, vis.get_reaction(), vis.get_expression()])
		get_tree().paused = true


func _process(_delta: float) -> void:
	if _cam_follow and hero:
		var target := hero.global_position
		_camera.position = target + _cam_offset
		_camera.look_at(target + _cam_look)
