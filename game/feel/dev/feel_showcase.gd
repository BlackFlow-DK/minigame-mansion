extends Node3D
## Dev scene for the game-feel pass: a real offline session (Stage + RoundUI + Session) with
## scripted moments at fixed frames, for screenshots. Owner: look and effects (juice).
##   godot-screenshot -Scene res://feel/dev/feel_showcase.tscn -Frames N -GameArgs "--shot=hit"
## --shot=intro   normal intro started at frame INTRO_AT (past the start-up hitches): curtain
##                wipe, title card, camera sweep, letterbox; shoot at INTRO_AT + 3..170
## --shot=hit     P1 is shoved by P0 at frame HIT_AT (shoot HIT_AT+1..3: hit-stop + flash)
## --shot=elim    P1 knocked out at HIT_AT with --reason (default fell)
## --shot=ko      everyone but P0 knocked out, the last at HIT_AT (shoot +6..36: slow-motion)
## --shot=podium  podium at frame 20 (shoot 20+: blocks rising, winner last)
## --minigame=<id> (default bumper_sumo), --players=N (default 4), --low (quality LOW)

const HIT_AT := 120
const INTRO_AT := 40

var _args: Dictionary = {}
var _shot: String = "hit"
var _stage: Stage
var _start_frame: int = 0
var _done: Dictionary = {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.trim_prefix("--").split("=", true, 1)
			_args[kv[0]] = kv[1]
		elif a == "--low":
			Look.set_quality(Look.Quality.LOW)
	_shot = str(_args.get("shot", "hit"))
	Engine.max_fps = 60
	_stage = $Stage as Stage
	_stage.name_tags = true
	Net.start_offline()
	for i in int(_args.get("players", "4")) - 1:
		Net.add_bot()
	var id := StringName(str(_args.get("minigame", "bumper_sumo")))
	Session.scene_override = load(MinigameRegistry.scene_path(id)) as PackedScene
	if _shot != "intro":
		Session.intro_time = 0.5
		Session.countdown_time = 0.5
	Session.results_time = 30.0
	_start_frame = Engine.get_process_frames()
	if _shot != "intro" and _shot != "podium":
		Session.start_session.call_deferred(1)


func _process(_delta: float) -> void:
	var f := Engine.get_process_frames() - _start_frame
	match _shot:
		"intro":
			_once(&"start", f >= INTRO_AT, func() -> void: Session.start_session(1))
		"hit":
			_once(&"place", f >= HIT_AT - 20, _place_pair)
			_once(&"hit", f >= HIT_AT, _hit)
		"elim":
			_once(&"place", f >= HIT_AT - 20, _place_pair)
			_once(&"elim", f >= HIT_AT, func() -> void:
				_stage.minigame.knock_out(_stage.get_player(1), StringName(str(_args.get("reason", "fell")))))
		"ko":
			_once(&"place", f >= HIT_AT - 20, _place_pair)
			for s in range(2, _stage.players.size()):
				_once(StringName("ko%d" % s), f >= HIT_AT - 40 + s, _knock.bind(s))
			_once(&"ko1", f >= HIT_AT, _knock.bind(1))
		"podium":
			_once(&"podium", f >= 20, _podium)


func _once(key: StringName, when: bool, what: Callable) -> void:
	if when and not _done.has(key):
		_done[key] = true
		what.call()


func _freeze_bots() -> void:
	for p: Player in _stage.players.values():
		var c := p.get_component(&"controller") as ControllerComponent
		if c:
			c.scripted = true
		p.intent.clear()


## P0 and P1 close together near the arena centre, facing each other.
func _place_pair() -> void:
	_freeze_bots()
	var a := _stage.get_player(0)
	var b := _stage.get_player(1)
	if a == null or b == null:
		return
	a.place_at(Transform3D(Basis.looking_at(Vector3.LEFT, Vector3.UP, true), Vector3(0.8, 0.0, 1.0)))
	b.place_at(Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP, true), Vector3(-0.5, 0.0, 1.0)))
	a.facing = Vector3.LEFT
	b.facing = Vector3.RIGHT


func _hit() -> void:
	print("feel_showcase: hit at process frame %d" % Engine.get_process_frames())
	var a := _stage.get_player(0)
	var b := _stage.get_player(1)
	a.emit_event(&"shove_started")
	a.emit_event(&"shove_hit", [1])
	b.apply_impulse(Vector3(-11.0, 3.0, 0.0), a)


func _knock(slot: int) -> void:
	var p := _stage.get_player(slot)
	if p and p.alive and _stage.minigame:
		_stage.minigame.knock_out(p, StringName(str(_args.get("reason", "fell"))))


func _podium() -> void:
	Session.scores = {0: 11, 1: 8, 2: 6, 3: 3} as Dictionary[int, int]
	Session.session_finished.emit([0, 1, 2, 3] as Array[int])
