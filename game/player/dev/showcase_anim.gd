extends Node3D
## Animation showcase for the visuals component: real Player scenes on a floor (plus a ledge),
## scripted through every behaviour. Not gameplay; for eyes and screenshots.
## User args after "--":
##   --capture=<dir>   play every shot (or --only=a,b) once and save one 2x2 contact sheet per
##                     shot, `<dir>/<shot>.png` (4 frames, left-right then top-bottom), then quit.
##                     Run with --fixed-fps 60 so the frames are deterministic:
##                     godot_console --path game --fixed-fps 60 --resolution 1280x720
##                       res://player/dev/showcase_anim.tscn -- --capture=<abs dir>
##   --only=a,b        limit --capture (or the tour) to these shots
##   --shot=<name>     play one shot and FREEZE on its last capture frame (the tree pauses),
##                     for tools/godot-screenshot.ps1 -Scene res://player/dev/showcase_anim.tscn
##                     -Frames 300 -GameArgs "--shot=skid"
##   --reduced         Settings.reduced_motion on for the run
##   (none)            tour: loops through every shot live
## Shots: see SHOTS.

const PLAYER_SCENE: PackedScene = preload("res://player/player.tscn")
const SHOTS: Array[StringName] = [
	&"run_start", &"skid", &"reverse", &"bank", &"panic", &"backpedal",
	&"jump", &"heavy_land", &"knock_spin", &"teeter",
	&"fidget_stretch", &"fidget_yawn", &"fidget_scratch", &"fidget_hat", &"fidget_tap", &"fidget_wrist",
	&"sleep", &"look", &"flinch", &"gloat", &"wince",
	&"emote_wave", &"emote_dance", &"emote_taunt", &"emote_cry",
	&"pose_victory", &"pose_clap_nod", &"pose_clap", &"pose_sulk",
	&"carry", &"throw", &"sizes", &"sizes_emote", &"crowd",
]
const ALL_ITEMS := {"hat": "top_hat", "face": "round_glasses", "neck": "scarf", "back": "cape"}
const LOADOUTS: Array[Dictionary] = [
	{"primary": "#e0303a", "secondary": "#fff1c1", "hat": "top_hat", "face": "round_glasses", "neck": "scarf", "back": "cape"},
	{"primary": "#2f7fe0", "secondary": "#cde8ff", "hat": "wizard", "face": "", "neck": "", "back": ""},
	{"primary": "#35b04a", "secondary": "#e8ffd0", "hat": "cowboy", "face": "round_glasses", "neck": "scarf", "back": "cape"},
	{"primary": "#f2b531", "secondary": "#fff6d8", "hat": "crown", "face": "round_glasses", "neck": "scarf", "back": "cape"},
	{"primary": "#9b4fd6", "secondary": "#f0dcff", "hat": "party_cone", "face": "", "neck": "", "back": ""},
	{"primary": "#22b8b0", "secondary": "#d4fffb", "hat": "chef", "face": "", "neck": "scarf", "back": ""},
	{"primary": "#ef7fb4", "secondary": "#ffe3f0", "hat": "viking", "face": "", "neck": "", "back": "cape"},
	{"primary": "#7a5634", "secondary": "#f3e2cc", "hat": "pirate", "face": "round_glasses", "neck": "", "back": ""},
]
const PARK := Vector3(0.0, 0.0, -60.0)

var hero: Player
var partner: Player
var crowd: Array[Player] = []
var _shot: StringName = &""
var _queue: Array[StringName] = []
var _mode: StringName = &"tour"  # tour | capture | shot
var _out_dir: String = ""
var _frame: int = 0
var _caps: Array[int] = []        # frames (this shot) at which to capture
var _images: Array[Image] = []
var _done_shot: bool = false
var _frozen: bool = false
var _jump_seen: int = -1
var _apex_seen: int = -1
var _land_seen: int = -1
var _ball: MeshInstance3D
var _ball_vel: Vector3 = Vector3.ZERO
var _ball_free: bool = false
var _cam_offset: Vector3 = Vector3(1.6, 1.25, 2.8)
var _cam_look: Vector3 = Vector3(0.0, 0.45, 0.0)
var _cam_fixed: Transform3D = Transform3D.IDENTITY
var _cam_follow: bool = true
var _remote_hero: bool = false

@onready var _camera: Camera3D = $Camera3D
@onready var _players: Node3D = $Players


func _ready() -> void:
	var only: Array[StringName] = []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_mode = &"shot"
			only = [StringName(arg.trim_prefix("--shot="))]
		elif arg.begins_with("--capture="):
			_mode = &"capture"
			_out_dir = arg.trim_prefix("--capture=")
		elif arg.begins_with("--only="):
			for s in arg.trim_prefix("--only=").split(",", false):
				only.append(StringName(s))
		elif arg == "--reduced":
			var settings := get_node_or_null(^"/root/Settings")
			if settings:
				settings.set(&"reduced_motion", true)
	_queue = only if not only.is_empty() else SHOTS.duplicate()
	if _mode == &"capture":
		DirAccess.make_dir_recursive_absolute(_out_dir)
	hero = _spawn(0)
	partner = _spawn(1)
	for i in 6:
		crowd.append(_spawn(2 + i))
	_ball = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.18
	sphere.height = 0.36
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.85, 0.2)
	sphere.material = m
	_ball.mesh = sphere
	add_child(_ball)
	hero.jumped.connect(func() -> void: _jump_seen = _frame)
	hero.landed.connect(_on_hero_landed)
	_start(_queue[0])


func _on_hero_landed(_impact: float) -> void:
	if _land_seen < 0 and (_shot != &"jump" or _jump_seen >= 0):
		_land_seen = _frame


func _spawn(slot: int) -> Player:
	var p := PLAYER_SCENE.instantiate() as Player
	p.slot = slot
	p.name = "P%d" % slot
	p.display_name = "Blob %d" % slot
	p.loadout = LOADOUTS[slot].duplicate()
	# Spawn apart: a body teleported out from under another one would carry it like a platform.
	p.place_at(Transform3D(Basis.IDENTITY, PARK + Vector3(3.0 * slot, 0.0, 0.0)))
	_players.add_child(p)
	(p.get_component(&"controller") as ControllerComponent).scripted = true
	return p


func _vis(p: Player) -> VisualsComponent:
	return p.get_component(&"visuals") as VisualsComponent


func _start(shot: StringName) -> void:
	_shot = shot
	_frame = 0
	_images.clear()
	_done_shot = false
	_jump_seen = -1
	_apex_seen = -1
	_land_seen = -1
	_ball.visible = false
	_ball_free = false
	_cam_follow = true
	if _remote_hero:
		hero.set_multiplayer_authority(1)
		_remote_hero = false
	var everyone: Array[Player] = [hero, partner]
	everyone.append_array(crowd)
	for i in everyone.size():
		var p := everyone[i]
		p.intent.clear()
		if not p.alive:
			p.respawn_at(Transform3D.IDENTITY)
		p.velocity = Vector3.ZERO
		p.loadout = LOADOUTS[p.slot].duplicate()
		var vis := _vis(p)
		vis.stop_emote()
		vis.set_carry_pose(&"none")
		vis._act = &""
		vis._idle_time = 0.0
		vis._panic_left = 0.0
		vis._sleep_w = 0.0
		_place(p, PARK + Vector3(3.0 * i, 0.0, 0.0), 0.0)
	_place(hero, Vector3.ZERO, 0.0)
	_place(partner, Vector3(-3.0, 0.0, -2.0), 0.6)
	_cam_offset = Vector3(1.5, 1.2, 2.7)
	_cam_look = Vector3(0.0, 0.45, 0.0)
	var side := Vector3(0.3, 1.0, 3.4)
	_caps = []
	match shot:
		&"run_start":
			_place(hero, Vector3(-2.0, 0.0, 0.0), PI * 0.5)
			_cam_offset = side
			_caps = [22, 25, 28, 33]
		&"skid":
			_place(hero, Vector3(-6.0, 0.0, 0.0), PI * 0.5)
			_cam_offset = side
			_caps = [47, 50, 54, 60]
		&"reverse":
			_place(hero, Vector3(-6.0, 0.0, 0.0), PI * 0.5)
			_cam_offset = side
			_caps = [47, 51, 56, 63]
		&"bank":
			_place(hero, Vector3(0.0, 0.0, -2.0), PI * 0.5)
			_cam_offset = Vector3(0.0, 1.4, 3.6)
			_caps = [40, 47, 54, 61]
		&"panic":
			_place(hero, Vector3(-3.0, 0.0, 0.0), PI * 0.5)
			_cam_offset = Vector3(3.0, 1.1, 2.0)
			_caps = [56, 60, 64, 68]
		&"backpedal":
			_remote_hero = true
			hero.set_multiplayer_authority(2)
			_place(hero, Vector3(0.0, 0.0, 2.0), 0.0)
			_cam_offset = Vector3(2.6, 1.1, 1.0)
			_caps = [30, 34, 38, 42]
		&"jump":
			_place(hero, Vector3(-1.5, 0.0, 0.0), PI * 0.5)
			_cam_offset = Vector3(0.3, 1.1, 3.8)
			_cam_look = Vector3(0.0, 0.8, 0.0)
		&"heavy_land":
			_place(hero, Vector3(0.0, 4.5, 0.0), 0.3)
			_cam_offset = Vector3(1.2, 1.0, 3.0)
		&"knock_spin":
			_place(hero, Vector3(-3.0, 0.0, 0.0), 0.0)
			_cam_follow = false
			_cam_fixed = _look_from(Vector3(0.5, 2.2, 7.5), Vector3(0.5, 1.0, 0.0))
			_caps = [25, 30, 35, 40]
		&"teeter":
			_place(hero, Vector3(13.15, 1.0, 0.0), PI * 0.5)
			_cam_offset = Vector3(2.2, 0.9, 2.4)
			_cam_look = Vector3(0.2, 0.4, 0.0)
			_caps = [50, 57, 64, 71]
		&"fidget_stretch", &"fidget_yawn", &"fidget_scratch", &"fidget_hat", &"fidget_tap", &"fidget_wrist":
			var length: float = VisualsComponent.ACTIONS[StringName(String(shot).trim_prefix("fidget_"))]
			_caps = _spread(10, length, [0.2, 0.42, 0.62, 0.82])
		&"sleep":
			_caps = [150, 172, 194, 216]
		&"look":
			_place(partner, Vector3(1.4, 0.0, -0.6), -0.3)
			_cam_offset = Vector3(0.7, 1.2, 3.4)
			_caps = [12, 32, 52, 72]
		&"flinch":
			_place(hero, Vector3(0.0, 0.0, 0.0), PI * 0.5)
			_place(partner, Vector3(2.3, 0.0, 0.0), -PI * 0.5)
			_cam_offset = Vector3(1.15, 1.2, 3.6)
			_cam_look = Vector3(1.15, 0.45, 0.0)
			_caps = [22, 26, 31, 38]
		&"gloat":
			_place(hero, Vector3(0.0, 0.0, 0.0), PI * 0.5)
			_place(partner, Vector3(1.05, 0.0, 0.0), -PI * 0.5)
			_cam_offset = Vector3(2.6, 1.2, 1.6)
			_caps = [45, 51, 57, 63]
		&"wince":
			_place(partner, Vector3(1.8, 0.0, -0.8), -0.8)
			_cam_offset = Vector3(1.0, 1.2, 3.2)
			_cam_look = Vector3(0.6, 0.45, 0.0)
			_caps = [23, 28, 34, 42]
		&"emote_wave", &"emote_taunt", &"emote_cry":
			var length: float = VisualsComponent.EMOTES[StringName(String(shot).trim_prefix("emote_"))]
			_caps = _spread(10, length, [0.2, 0.4, 0.6, 0.82])
		&"emote_dance":
			_caps = [30, 45, 60, 75]
		&"pose_victory":
			_cam_offset = Vector3(1.8, 1.5, 3.4)
			_cam_look = Vector3(0.0, 0.7, 0.0)
			_caps = [17, 47, 62, 100]
		&"pose_clap_nod", &"pose_clap":
			_caps = [30, 37, 44, 51]
		&"pose_sulk":
			_caps = [30, 75, 120, 165]
		&"carry":
			_place(hero, Vector3(-3.0, 0.0, 0.0), PI * 0.5)
			_cam_offset = Vector3(1.4, 1.3, 3.2)
			_caps = [40, 55, 100, 115]
		&"throw":
			_place(hero, Vector3(0.0, 0.0, 0.0), PI * 0.5)
			_cam_offset = Vector3(0.6, 1.3, 3.6)
			_cam_look = Vector3(0.6, 0.7, 0.0)
			_caps = [34, 39, 44, 52]
		&"sizes", &"sizes_emote":
			var sizes: Array[Player] = [crowd[0], hero, crowd[1]]
			var ids := ["small", "normal", "big"]
			for i in 3:
				var lo: Dictionary = LOADOUTS[sizes[i].slot].duplicate()
				lo.merge(ALL_ITEMS, true)
				lo["size"] = ids[i]
				sizes[i].loadout = lo
				if shot == &"sizes":
					_place(sizes[i], Vector3(-4.0, 0.0, -1.5 * (i - 1)), PI * 0.5)
				else:
					_place(sizes[i], Vector3(1.4 * (i - 1), 0.0, 0.0), 0.0)
			_cam_offset = Vector3(0.0, 2.6, 6.5) if shot == &"sizes" else Vector3(0.0, 1.3, 4.2)
			_caps.assign([34, 40, 46, 52] if shot == &"sizes" else [30, 45, 60, 75])
		&"crowd":
			var ring: Array[Player] = [hero, partner]
			ring.append_array(crowd)
			for i in ring.size():
				var a := TAU * i / ring.size()
				_place(ring[i], Vector3(sin(a) * 2.6, 0.0, cos(a) * 2.6), 0.0)
			_cam_follow = false
			_cam_fixed = _look_from(Vector3(0.0, 4.2, 7.8), Vector3(0.0, 0.4, 0.0))
			_caps = [40, 70, 100, 130]


func _spread(start: int, length: float, at: Array) -> Array[int]:
	var out: Array[int] = []
	for u: float in at:
		out.append(start + int(round(length * 60.0 * u)))
	return out


func _look_from(from: Vector3, to: Vector3) -> Transform3D:
	return Transform3D(Basis.IDENTITY, from).looking_at(to, Vector3.UP)


func _place(p: Player, pos: Vector3, yaw: float) -> void:
	p.place_at(Transform3D(Basis(Vector3.UP, yaw), pos))
	var vis := _vis(p)
	if vis:
		vis._snap_to_player()


func _physics_process(_delta: float) -> void:
	if _frozen or _done_shot:
		return
	var f := _frame
	for p: Player in [hero, partner]:
		p.intent.jump_pressed = false
		p.intent.action_pressed = false
		p.intent.emote = 0
	for p in crowd:
		p.intent.emote = 0
	var vis := _vis(hero)
	match _shot:
		&"run_start":
			if f >= 20:
				hero.intent.move = Vector2(1.0, 0.0)
		&"skid":
			hero.intent.move = Vector2(1.0, 0.0) if f < 45 else Vector2.ZERO
		&"reverse":
			hero.intent.move = Vector2(1.0, 0.0) if f < 45 else Vector2(-1.0, 0.0)
		&"bank":
			var a := f * 0.075
			hero.intent.move = Vector2(cos(a), -sin(a))
		&"panic":
			if f == 5:
				hero.apply_impulse(Vector3(-4.0, 1.5, 0.0))
			if f >= 40:
				hero.intent.move = Vector2(1.0, 0.0)
		&"backpedal":
			hero.facing = Vector3.BACK
			hero.global_position += Vector3(0.0, 0.0, -0.06 if f >= 10 else 0.0)
		&"jump":
			hero.intent.move = Vector2(0.45, 0.0)
			hero.intent.jump_pressed = f == 30
			hero.intent.jump_held = f >= 30
			if _jump_seen >= 0 and _apex_seen < 0 and hero.velocity.y <= 0.0:
				_apex_seen = f
			if _jump_seen >= 0 and f == _jump_seen + 5:
				_caps.append(f)
			if f == _apex_seen and f > 0:
				_caps.append(f)
			if _apex_seen > 0 and f == _apex_seen + 9:
				_caps.append(f)
			if _land_seen > 0 and f == _land_seen + 1:
				_caps.append(f)
		&"heavy_land":
			if _land_seen > 0 and f in [_land_seen + 1, _land_seen + 5, _land_seen + 10, _land_seen + 18]:
				_caps.append(f)
		&"knock_spin":
			if f == 20:
				hero.apply_impulse(Vector3(12.5, 6.5, 0.0))
		&"fidget_stretch", &"fidget_yawn", &"fidget_scratch", &"fidget_hat", &"fidget_tap", &"fidget_wrist":
			if f == 10:
				vis.play_fidget(StringName(String(_shot).trim_prefix("fidget_")))
		&"sleep":
			if f == 1:
				vis._idle_time = VisualsComponent.SLEEP_AFTER + 1.0
		&"look":
			_ball.visible = true
			_ball.global_position = Vector3(-4.0 + f * 0.11, 0.8 + 0.9 * sin(f * 0.045), 1.4)
			vis.set_interest_point(_ball.global_position, 1.0)
			_vis(partner).set_interest_point(_ball.global_position, 1.0)
		&"flinch":
			partner.intent.action_pressed = f == 20
		&"gloat":
			hero.intent.action_pressed = f == 20
		&"wince":
			if f == 20:
				partner.eliminate(&"showcase")
		&"emote_wave", &"emote_dance", &"emote_taunt", &"emote_cry":
			if f == 10:
				hero.intent.emote = {&"emote_wave": 1, &"emote_dance": 2, &"emote_taunt": 3, &"emote_cry": 4}[_shot]
		&"pose_victory", &"pose_clap_nod", &"pose_clap", &"pose_sulk":
			if f == 5:
				var place := {&"pose_victory": 1, &"pose_clap_nod": 2, &"pose_clap": 5, &"pose_sulk": 8}[_shot] as int
				vis.play_result_pose(place, 8)
		&"carry":
			hero.intent.move = Vector2(0.5, 0.0)
			if f == 1:
				vis.set_carry_pose(&"overhead")
			if f == 70:
				vis.set_carry_pose(&"front")
			_ball.visible = true
			_ball.global_position = vis.get_carry_point()
		&"throw":
			if f == 1:
				vis.set_carry_pose(&"overhead")
			if f == 32:
				vis.play_throw()
			if f == 38:
				_ball_free = true
				_ball_vel = Basis(Vector3.UP, PI * 0.5) * Vector3(0.0, 3.0, 7.0)
			_ball.visible = true
			if _ball_free:
				_ball_vel.y -= 9.8 / 60.0
				_ball.global_position += _ball_vel / 60.0
			else:
				_ball.global_position = vis.get_carry_point()
		&"sizes":
			for p: Player in [crowd[0], hero, crowd[1]]:
				p.intent.move = Vector2(1.0, 0.0) if f >= 10 else Vector2.ZERO
		&"sizes_emote":
			if f == 10:
				for p: Player in [crowd[0], hero, crowd[1]]:
					p.intent.emote = 2
		&"crowd":
			var ring: Array[Player] = [hero, partner]
			ring.append_array(crowd)
			for i in ring.size():
				if f == 10 + i * 3:
					ring[i].intent.emote = [1, 2, 3, 4][i % 4]
	if _caps.has(f):
		_capture.call_deferred()
		if _mode == &"capture":
			print("  %s f=%d y=%.2f vy=%.2f reaction=%s expression=%s action=%s" % [_shot, f,
				hero.global_position.y, hero.velocity.y, vis.get_reaction(), vis.get_expression(), vis.get_action()])
	_frame += 1
	var last := -1
	for c in _caps:
		last = maxi(last, c)
	var length := last + 2 if last >= 0 else 240
	if _shot in [&"jump", &"heavy_land"] and _caps.size() < 4:
		length = 400
	match _mode:
		&"shot":
			if _caps.size() >= 4 and f >= last:
				_frozen = true
				print("showcase_anim: frozen '%s' at frame %d, reaction=%s expression=%s" % [
					_shot, f, vis.get_reaction(), vis.get_expression()])
				get_tree().paused = true
		&"tour":
			if _frame > maxi(length, 150):
				_next()
		&"capture":
			if _frame > length + 1 and not _done_shot:
				_done_shot = true
				_finish_shot.call_deferred()


## Grabs this frame once drawn.
func _capture() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img:
		_images.append(img)


func _finish_shot() -> void:
	# Let the last pending capture land.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if _mode == &"capture" and not _images.is_empty():
		var w := _images[0].get_width() / 2
		var h := _images[0].get_height() / 2
		var sheet := Image.create(w * 2 + 6, h * 2 + 6, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0.05, 0.05, 0.08))
		for i in mini(_images.size(), 4):
			var img := _images[i]
			img.convert(Image.FORMAT_RGBA8)
			img.resize(w, h, Image.INTERPOLATE_BILINEAR)
			sheet.blit_rect(img, Rect2i(0, 0, w, h), Vector2i((i % 2) * (w + 6), (i / 2) * (h + 6)))
		var path := _out_dir.path_join("%s.png" % _shot)
		sheet.save_png(path)
		print("showcase_anim: %s (%d frames) -> %s" % [_shot, _images.size(), path])
	_next()


func _next() -> void:
	var i := _queue.find(_shot)
	if _mode == &"capture" and i == _queue.size() - 1:
		get_tree().quit()
		return
	_start(_queue[(i + 1) % _queue.size()])


func _process(_delta: float) -> void:
	if not _cam_follow:
		_camera.global_transform = _cam_fixed
		return
	if hero:
		var target := hero.global_position
		_camera.position = target + _cam_offset
		_camera.look_at(target + _cam_look)
